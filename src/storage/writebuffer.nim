## Write Buffer Implementation for High-Performance Writes
##
## This module provides an in-memory buffer for write operations to reduce
## disk I/O and improve throughput. Configurable sync strategies allow
## trade-offs between durability and performance.

import std/[locks, times, strformat, deques, typedthreads, strutils]

import ../kvs/types

type
  ## Callback type for flushing entries to disk
  ## Returns true on success, false on failure
  FlushCallback* = proc(entries: seq[BufferedEntry]): bool {.gcsafe.}

  WriteBuffer* = object
    entries*: Deque[BufferedEntry]
    maxSize*: int
    currentSize*: int
    syncMode*: SyncMode
    batchSize*: int
    flushInterval*: Duration
    batchSizeCount*: int
    lock*: Lock
    condition*: Cond
    stats*: WriteBufferStats
    running*: bool
    flushing*: bool
    lastFlush*: Time
    flushCallback*: FlushCallback  # Buffer-level callback for flushing
    workerThread*: Thread[ptr WriteBuffer]  # Background worker thread
    hasWorker*: bool  # Whether worker was started

  FlushResult* = enum
    frSuccess,
    frBufferFull,
    frStopped

proc parseSizeString*(sizeStr: string): uint64 =
  ## Parse size string like "128MB", "2GB" to bytes
  let s = sizeStr.toLowerAscii()
  var multiplier = 1'u64
  var suffixLen = 0

  if s.endsWith("kb"):
    multiplier = 1024'u64
    suffixLen = 2
  elif s.endsWith("mb"):
    multiplier = 1024'u64 * 1024'u64
    suffixLen = 2
  elif s.endsWith("gb"):
    multiplier = 1024'u64 * 1024'u64 * 1024'u64
    suffixLen = 2
  elif s.endsWith("b"):
    multiplier = 1'u64
    suffixLen = 1
  else:
    # Assume bytes if no suffix
    multiplier = 1'u64
    suffixLen = 0

  var numStr = if suffixLen > 0:
    s[0..<s.len - suffixLen]
  else:
    s

  try:
    var num: uint64
    if numStr.startsWith("0x"):
      num = parseHexInt(numStr[2..^1]).uint64
    else:
      num = parseBiggestUInt(numStr)
    result = num * multiplier
  except:
    raise newException(ValueError, "Invalid size string: " & sizeStr)

proc initWriteBuffer*(
  maxSize: int,
  syncMode: SyncMode,
  batchSize: int = 1000,
  flushIntervalMs: int = 100,
  flushCallback: FlushCallback = nil
): WriteBuffer =
  ## Initialize a new write buffer
  ## flushCallback: Optional callback that receives batched entries for disk writes

  result = WriteBuffer(
    entries: initDeque[BufferedEntry](),
    maxSize: maxSize,
    currentSize: 0,
    syncMode: syncMode,
    batchSize: batchSize,
    flushInterval: initDuration(milliseconds = flushIntervalMs),
    batchSizeCount: 0,
    lock: Lock(),
    condition: Cond(),  # Initialize default
    stats: WriteBufferStats(),
    running: true,
    flushing: false,
    lastFlush: getTime(),
    flushCallback: flushCallback,
    hasWorker: false
  )
  initLock(result.lock)
  initCond(result.condition)

proc addEntry*(buffer: var WriteBuffer, key: string, value: string, timestamp: int64): FlushResult {.discardable.} =
  ## Add an entry to the write buffer
  ## Returns FlushResult indicating the buffer state

  withLock(buffer.lock):
    if not buffer.running:
      return frStopped

    # Check if buffer is full
    if buffer.currentSize >= buffer.maxSize:
      inc buffer.stats.entriesDropped
      buffer.condition.signal()  # Trigger flush
      return frBufferFull

    # Create buffered entry
    let entry = BufferedEntry(
      key: key,
      value: value,
      timestamp: timestamp
    )

    buffer.entries.addLast(entry)
    inc buffer.currentSize
    inc buffer.stats.entriesWritten

    # Update max depth if necessary
    if buffer.currentSize > buffer.stats.maxBufferDepth:
      buffer.stats.maxBufferDepth = buffer.currentSize

    # Trigger flush based on sync mode
    case buffer.syncMode:
    of syncImmediate:
      # Immediate mode: flush immediately (bypass buffer)
      buffer.condition.signal()

    of syncBatched:
      inc buffer.batchSizeCount
      if buffer.batchSizeCount >= buffer.batchSize:
        buffer.condition.signal()

    of syncTimeBased:
      let now = getTime()
      if (now - buffer.lastFlush) >= buffer.flushInterval:
        buffer.condition.signal()

    of syncBuffered:
      # Don't trigger flush immediately
      discard

    return frSuccess

proc flushBuffer*(buffer: var WriteBuffer): int {.discardable, gcsafe.} =
  ## Flush the buffer, returning number of entries flushed
  ## Uses buffer-level flushCallback if set, otherwise per-entry whenReady

  buffer.flushing = true
  result = 0

  # Collect all entries to flush
  var batch: seq[BufferedEntry] = @[]
  while buffer.entries.len > 0 and buffer.running:
    batch.add(buffer.entries.popFirst())
    dec buffer.currentSize

  # Use buffer-level callback if available
  if buffer.flushCallback != nil and batch.len > 0:
    try:
      {.gcsafe.}:
        if buffer.flushCallback(batch):
          result = batch.len
    except:
      # Callback failed
      discard
  else:
    # Fall back to per-entry callbacks (legacy behavior)
    for entry in batch:
      try:
        if entry.whenReady != nil:
          {.gcsafe.}:
            entry.whenReady(entry.key, entry.value, entry.timestamp)
          inc result
      except:
        continue

  # Reset counters
  buffer.batchSizeCount = 0
  buffer.lastFlush = getTime()
  buffer.flushing = false

  inc buffer.stats.buffersFlushed

proc workerThread*(buffer: ptr WriteBuffer) {.thread, gcsafe.} =
  ## Background worker thread for flushing buffers

  while buffer[].running:
    withLock(buffer[].lock):
      if not buffer[].running:
        break

      # Wait for flush condition or timeout
      var timeout = buffer[].flushInterval
      if buffer[].syncMode == syncTimeBased:
        timeout = buffer[].flushInterval

      if buffer[].entries.len == 0:
        buffer[].condition.wait(buffer[].lock)
      else:
        # Check if we should flush based on mode
        let shouldFlush = case buffer[].syncMode
        of syncBatched:
          buffer[].batchSizeCount >= buffer[].batchSize
        of syncTimeBased:
          (getTime() - buffer[].lastFlush) >= buffer[].flushInterval
        of syncImmediate:
          true  # Not used in immediate mode
        of syncBuffered:
          (getTime() - buffer[].lastFlush) >= buffer[].flushInterval

        if not shouldFlush:
          buffer[].condition.wait(buffer[].lock)

      # Flush the buffer
      if buffer[].running and buffer[].entries.len > 0:
        discard buffer[].flushBuffer()

  # Clear remaining entries on shutdown
  withLock(buffer[].lock):
    discard buffer[].flushBuffer()

proc startWorker*(buffer: var WriteBuffer) =
  ## Start the background worker thread
  if not buffer.hasWorker:
    createThread(buffer.workerThread, workerThread, addr(buffer))
    buffer.hasWorker = true

proc stopWorker*(buffer: var WriteBuffer) =
  ## Stop the background worker thread and wait for it to finish
  if buffer.hasWorker:
    withLock(buffer.lock):
      buffer.running = false
      buffer.condition.signal()
    # Wait for worker thread to finish
    joinThread(buffer.workerThread)
    buffer.hasWorker = false

proc getStats*(buffer: var WriteBuffer): WriteBufferStats =
  ## Get a copy of the current stats (thread-safe)
  withLock(buffer.lock):
    result = buffer.stats

proc resize*(buffer: var WriteBuffer, newSize: int) =
  ## Resize the buffer (not thread-safe with current operations)
  buffer.maxSize = newSize
  if buffer.currentSize > buffer.maxSize:
    buffer.currentSize = buffer.maxSize