## Crash Recovery Engine for Bitcask KVS
##
## This module handles recovery from crashes by scanning data files
## and rebuilding the in-memory KeyDir index.

import std/[os, strformat, strutils, times, sequtils, math, algorithm, endians, locks]
import ../kvs/types, keydir, record, crc32, hintfile

type
  RecoveryProgress* = object
    filesScanned*: int
    totalFiles*: int
    recordsProcessed*: int
    recordsValid*: int
    recordsCorrupt*: int
    recordsSkipped*: int
    bytesScanned*: int64
    lastError*: string
    startTime*: float  # CPU time start
    currentFile*: string

  RecoveryOptions* = object
    validateChecksums*: bool = true      # Validate CRC32 on recovery
    skipCorruptRecords*: bool = true     # Skip bad records vs abort
    maxProgressInterval*: int = 1000     # Report progress every N records
    enableVerboseLogging*: bool = false  # Detailed logging
    useHintFiles*: bool = true           # Use hint files for fast recovery
    validateHintFiles*: bool = true      # Validate hint file checksums

  RecoveryStats* = object
    totalFiles*: int
    totalRecords*: int
    validRecords*: int
    corruptRecords*: int
    skippedRecords*: int
    deletedRecords*: int
    bytesRecovered*: int64
    recoveryTime*: Duration
    keyCount*: int
    errorCount*: int
    hintFilesUsed*: int              # Number of hint files used
    hintFilesInvalid*: int           # Number of invalid hint files
    filesFromHint*: int              # Files recovered via hint
    filesFromScan*: int              # Files recovered via full scan

  RecoveryEngine* = ref object
    dataDir*: string
    options*: RecoveryOptions
    stats*: RecoveryStats
    progress*: RecoveryProgress
    keyDir*: KeyDir
    isRunning*: bool
    recoveryLock*: Lock

proc initRecoveryEngine*(dataDir: string, options: RecoveryOptions = RecoveryOptions()): RecoveryEngine =
  ## Initialize recovery engine
  result = RecoveryEngine(
    dataDir: dataDir,
    options: options,
    stats: RecoveryStats(),
    progress: RecoveryProgress(
      startTime: 0.0
    ),
    keyDir: init(),
    isRunning: false
  )
  initLock(result.recoveryLock)

proc scanDataFiles*(engine: RecoveryEngine): seq[string] =
  ## Scan data directory for data files
  result = @[]

  for kind, path in walkDir(engine.dataDir):
    if kind == pcFile:
      let filename = path.extractFilename()
      if filename.endsWith(".data"):
        # Validate filename format (NNNNNN.data)
        let baseName = filename[0..^6]
        if baseName.len == 6 and baseName.allCharsInSet(Digits):
          result.add(path)

  # Sort by file ID (numeric order)
  result = result.sorted(proc(x, y: string): int =
    let xId = parseInt(x.extractFilename()[0..5])
    let yId = parseInt(y.extractFilename()[0..5])
    cmp(xId, yId)
  )

proc validateFileHeader*(engine: RecoveryEngine, filePath: string): bool =
  ## Validate data file header
  try:
    let file = open(filePath, fmRead)
    defer: file.close()

    # Read header
    var header: FileHeader
    let bytesRead = file.readBuffer(addr header, sizeof(header))

    if bytesRead != sizeof(header):
      if engine.options.enableVerboseLogging:
        echo &"Warning: Incomplete header in {filePath}"
      return false

    # Validate magic number
    let expectedMagic = ['B', 'C', 'K', 'S']
    if header.magic != expectedMagic:
      if engine.options.enableVerboseLogging:
        echo &"Warning: Invalid magic number in {filePath}"
      return false

    # Validate version
    if header.version != VERSION:
      if engine.options.enableVerboseLogging:
        echo &"Warning: Unsupported version in {filePath}: {header.version}"
      return false

    return true
  except OSError as e:
    if engine.options.enableVerboseLogging:
      echo &"Warning: Error reading header from {filePath}: {e.msg}"
    return false

proc readRecordFromFile*(engine: RecoveryEngine, filePath: string, offset: int64): tuple[record: Record, bytesRead: int, isValid: bool] =
  ## Read and validate a record at specific offset using actual datafile format
  try:
    let file = open(filePath, fmRead)
    defer: file.close()

    file.setFilePos(offset)

    # Read CRC32 first (4 bytes)
    var storedCrc: uint32
    let crcBytesRead = file.readBuffer(addr storedCrc, 4)
    if crcBytesRead != 4:
      return (Record(), 0, false)

    # Read timestamp (8 bytes, little-endian)
    var timestamp: int64
    let tsBytesRead = file.readBuffer(addr timestamp, 8)
    if tsBytesRead != 8:
      return (Record(), 0, false)

    # Convert from little-endian
    var ts: int64
    littleEndian64(addr ts, addr timestamp)

    # Validate timestamp (basic sanity check)
    if ts < 0 or ts > int64(epochTime() + 86400):
      if engine.options.enableVerboseLogging:
        echo &"Warning: Invalid timestamp {ts} at offset {offset}"
      return (Record(), 0, false)

    # Read key length (4 bytes, little-endian)
    var keyLen: uint32
    let keyLenBytesRead = file.readBuffer(addr keyLen, 4)
    if keyLenBytesRead != 4:
      return (Record(), 0, false)

    # Convert from little-endian
    var keySize: uint32
    littleEndian32(addr keySize, addr keyLen)

    if keySize == 0 or keySize > MAX_KEY_SIZE:
      if engine.options.enableVerboseLogging:
        echo &"Warning: Invalid key size {keySize} at offset {offset}"
      return (Record(), 0, false)

    # Read key
    var key = newString(keySize)
    let keyBytesRead = file.readBuffer(addr key[0], keySize)
    if keyBytesRead != int(keySize):
      return (Record(), 0, false)

    # Read value length (4 bytes, little-endian)
    var valLen: uint32
    let valLenBytesRead = file.readBuffer(addr valLen, 4)
    if valLenBytesRead != 4:
      return (Record(), 0, false)

    # Convert from little-endian
    var valueSize: uint32
    littleEndian32(addr valueSize, addr valLen)

    if valueSize > MAX_VALUE_SIZE:
      if engine.options.enableVerboseLogging:
        echo &"Warning: Invalid value size {valueSize} at offset {offset}"
      return (Record(), 0, false)

    # Read value
    var value = newString(valueSize)
    var valueBytesRead = 0
    if valueSize > 0:
      valueBytesRead = file.readBuffer(addr value[0], valueSize)
      if valueBytesRead != int(valueSize):
        return (Record(), 0, false)

    # Create record
    let record = Record(
      timestamp: ts,
      key: key,
      value: value
    )

    # Validate CRC32 if enabled
    var isValid = true
    if engine.options.validateChecksums:
      # Create record data as it would be stored
      let recordData = encode(record)
      let calculatedChecksum = crc32(recordData)
      if calculatedChecksum != storedCrc:
        if engine.options.enableVerboseLogging:
          echo &"Warning: CRC32 mismatch at offset {offset}: expected {storedCrc}, got {calculatedChecksum}"
        isValid = false

    let totalBytesRead = crcBytesRead + tsBytesRead + keyLenBytesRead + keyBytesRead + valLenBytesRead + valueBytesRead
    return (record, totalBytesRead, isValid)

  except OSError as e:
    if engine.options.enableVerboseLogging:
      echo &"Warning: Error reading record from {filePath} at {offset}: {e.msg}"
    return (Record(), 0, false)

proc recoverFromHintFile*(engine: RecoveryEngine, filePath: string): bool =
  ## Attempt to recover using a hint file (much faster than full scan)
  let hintPath = getHintPath(filePath)

  if not hintFileExists(hintPath):
    return false

  if engine.options.enableVerboseLogging:
    echo &"Attempting recovery from hint file: {hintPath.extractFilename()}"

  # Validate hint file
  if not validateHintFile(hintPath):
    engine.stats.hintFilesInvalid += 1
    if engine.options.enableVerboseLogging:
      echo &"Hint file validation failed: {hintPath.extractFilename()}"
    return false

  # Load KeyDir from hint file
  try:
    engine.stats.hintFilesUsed += 1
    let loaded = loadKeyDirFromHint(hintPath, engine.keyDir)

    if loaded < 0:
      engine.stats.errorCount += 1
      if engine.options.enableVerboseLogging:
        echo &"Failed to load hint file: {hintPath.extractFilename()}"
      return false

    if engine.options.enableVerboseLogging:
      echo &"Successfully loaded {loaded} entries from hint file: {hintPath.extractFilename()}"

    return true
  except Exception as e:
    engine.stats.errorCount += 1
    if engine.options.enableVerboseLogging:
      echo &"Error loading hint file {hintPath.extractFilename()}: {e.msg}"
    return false

proc recoverFromFile*(engine: RecoveryEngine, filePath: string): bool =
  ## Recover records from a single data file
  if not engine.validateFileHeader(filePath):
    engine.stats.errorCount += 1
    return false

  try:
    let file = open(filePath, fmRead)
    defer: file.close()

    let fileSize = file.getFileSize()
    var offset: int64 = sizeof(FileHeader)  # Skip header

    engine.progress.currentFile = filePath.extractFilename()

    while offset < fileSize - 16:  # Minimum record size
      let (record, bytesRead, isValid) = engine.readRecordFromFile(filePath, offset)

      if not isValid or record == Record():
        if engine.options.skipCorruptRecords:
          offset += 1  # Skip to next byte and try again
          engine.stats.corruptRecords += 1
          continue
        else:
          engine.stats.errorCount += 1
          return false

      # Update progress
      engine.progress.recordsProcessed += 1
      engine.stats.totalRecords += 1
      offset += int64(bytesRead)
      engine.progress.bytesScanned += bytesRead

      # Report progress periodically
      if engine.progress.recordsProcessed mod engine.options.maxProgressInterval == 0:
        let elapsed = cpuTime() - engine.progress.startTime
        let rate = float(engine.progress.recordsProcessed) / elapsed
        echo &"Recovery progress: {engine.progress.recordsProcessed} records, {rate:.0f} records/sec"

      # Check if this is a tombstone (deleted record)
      if record.value.len == 0:
        engine.stats.deletedRecords += 1
        engine.stats.skippedRecords += 1
        continue

      # Extract file ID from filename
      let filename = filePath.extractFilename()
      let fileIdStr = filename[0..5]
      let fileId = uint32(parseInt(fileIdStr))

      # Calculate value position within file
      let valuePos = offset - int64(record.value.len)

      # Create KeyDir entry
      let entry = KeyDirEntry(
        fileId: fileId,
        recordPos: uint64(offset - int64(record.key.len + record.value.len + 16)),  # Position of record (after CRC)
        valuePos: uint64(valuePos),
        valueSize: record.value.len.uint32,
        timestamp: record.timestamp,
        recordSize: uint32(16 + record.key.len + record.value.len)
      )

      # Update KeyDir (this automatically handles timestamp conflicts)
      engine.keyDir.add(record.key, entry)
      engine.stats.validRecords += 1

      # Update recovery stats
      engine.stats.bytesRecovered += record.key.len + record.value.len

    return true

  except OSError as e:
    engine.progress.lastError = &"Error processing {filePath}: {e.msg}"
    engine.stats.errorCount += 1
    return false

proc recover*(engine: RecoveryEngine): RecoveryStats =
  ## Perform full recovery from all data files
  withLock(engine.recoveryLock):
    if engine.isRunning:
      raise newException(CatchableError, "Recovery already in progress")

    engine.isRunning = true
    engine.progress.startTime = cpuTime()

  try:
    # Scan for data files
    let dataFiles = engine.scanDataFiles()
    engine.progress.totalFiles = dataFiles.len
    engine.stats.totalFiles = dataFiles.len

    if engine.options.enableVerboseLogging:
      echo &"Starting recovery from {dataFiles.len} data files in {engine.dataDir}"

    if dataFiles.len == 0:
      if engine.options.enableVerboseLogging:
        echo "No data files found, starting with empty KeyDir"
      return engine.stats

    # Recover from each file
    for filePath in dataFiles:
      var recovered = false

      # Try hint file first if enabled (much faster)
      if engine.options.useHintFiles:
        recovered = engine.recoverFromHintFile(filePath)
        if recovered:
          engine.stats.filesFromHint += 1
          engine.progress.filesScanned += 1
          continue

      # Fall back to full scan
      engine.stats.filesFromScan += 1
      if not engine.recoverFromFile(filePath):
        if engine.options.skipCorruptRecords:
          echo &"Warning: Failed to recover from {filePath}, continuing..."
          continue
        else:
          echo &"Error: Failed to recover from {filePath}"
          break

      engine.progress.filesScanned += 1

    # Final statistics
    engine.stats.recoveryTime = initDuration(seconds = int((cpuTime() - engine.progress.startTime) * 1000))
    engine.stats.keyCount = engine.keyDir.len

    if engine.options.enableVerboseLogging:
      echo &"Recovery completed in {engine.stats.recoveryTime.inMilliseconds}ms"
      echo &"Files: {engine.stats.totalFiles}, Records: {engine.stats.totalRecords}"
      echo &"Valid: {engine.stats.validRecords}, Corrupt: {engine.stats.corruptRecords}"
      echo &"Keys recovered: {engine.stats.keyCount}"
      if engine.options.useHintFiles:
        echo &"Hint files used: {engine.stats.hintFilesUsed}, Files from hint: {engine.stats.filesFromHint}"
        echo &"Files scanned: {engine.stats.filesFromScan}, Invalid hints: {engine.stats.hintFilesInvalid}"

    return engine.stats

  finally:
    withLock(engine.recoveryLock):
      engine.isRunning = false

proc getKeyDir*(engine: RecoveryEngine): KeyDir =
  ## Get recovered KeyDir
  return engine.keyDir

proc getProgress*(engine: RecoveryEngine): RecoveryProgress =
  ## Get current recovery progress
  return engine.progress

proc getStats*(engine: RecoveryEngine): RecoveryStats =
  ## Get recovery statistics
  return engine.stats

proc isRunning*(engine: RecoveryEngine): bool =
  ## Check if recovery is in progress
  withLock(engine.recoveryLock):
    return engine.isRunning

proc cancel*(engine: RecoveryEngine): bool =
  ## Cancel ongoing recovery
  withLock(engine.recoveryLock):
    if engine.isRunning:
      engine.isRunning = false
      return true
    return false

# Utility functions for recovery testing
proc createTestDataFile*(filePath: string, fileId: uint32, records: seq[Record]): bool =
  ## Create a test data file with specific records using actual datafile format
  try:
    let file = open(filePath, fmWrite)
    defer: file.close()

    # Write header using proper FileHeader structure
    var header = FileHeader(
      magic: ['B', 'C', 'K', 'S'],
      version: VERSION,
      created: int64(epochTime()),
      fileSize: uint64(sizeof(FileHeader))
    )
    discard file.writeBuffer(addr header, sizeof(FileHeader))

    # Write records with CRC32
    var offset: int64 = sizeof(FileHeader)
    for record in records:
      let recordData = encode(record)
      let recordCrc = crc32(recordData)

      # Write: CRC32 + record data
      var crcVal = recordCrc
      discard file.writeBuffer(addr crcVal, 4)
      file.write(recordData)
      offset += (recordData.len + 4).int64

    # Update file size in header
    file.setFilePos(16)  # Position of fileSize in FileHeader
    var fileSize = uint64(offset)
    discard file.writeBuffer(addr fileSize, 8)

    return true
  except OSError:
    return false

proc simulateCrashRecovery*(dataDir: string, validateChecksums: bool = true): RecoveryStats =
  ## Simulate crash recovery for testing
  let options = RecoveryOptions(
    validateChecksums: validateChecksums,
    skipCorruptRecords: true,
    enableVerboseLogging: false
  )

  let engine = initRecoveryEngine(dataDir, options)
  result = engine.recover()