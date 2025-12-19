## Centralized test utilities for BitBarrel test suite
##
## This module provides common utilities used across test files:
## - Directory and file setup/teardown
## - Record creation helpers
## - Test data builders
## - Test configuration utilities

import std/[os, times, strutils, random, net]
import ../src/bitbarrel/types
import ../src/storage/record
import ../src/storage/datafile

# Random number generator for test uniqueness
var testRand {.threadvar.}: Rand

# Initialize at module load
testRand = initRand(getTime().toUnix().int)

proc initTestRand*() =
  ## Re-initialize random number generator for unique test names
  testRand = initRand(getTime().toUnix().int)

# =============================================================================
# Directory and File Management
# =============================================================================

proc setupTestDir*(baseName: string): string =
  ## Create a unique temporary directory for testing
  let uniqueId = $testRand.rand(1000000)
  let testDir = getTempDir() / "bitbarrel_test_" & baseName & "_" & uniqueId
  createDir(testDir)
  result = testDir

proc cleanupTestDir*(testDir: string) =
  ## Remove test directory and all contents
  if testDir.len > 0 and dirExists(testDir):
    removeDir(testDir)

template withTestDir*(testDirBase: string, body: untyped) =
  ## Execute block with a test directory that is automatically cleaned up
  let testDir = setupTestDir(testDirBase)
  defer: cleanupTestDir(testDir)
  body

template withTestFile*(path: string, body: untyped) =
  ## Execute block with a test file that is automatically cleaned up
  let filePath = path
  defer:
    if fileExists(filePath):
      removeFile(filePath)
  body

# =============================================================================
# Record Creation Helpers
# =============================================================================

proc now*(): int64 =
  ## Get current timestamp for tests
  getTime().toUnix()

proc makeRecord*(key: string, value: string, timestamp: int64 = now()): Record =
  ## Create a Record with default timestamp
  Record(
    key: key,
    value: value,
    timestamp: timestamp
  )

template testRecord*(key: string, value: string, ts: int64 = -1): Record =
  ## Template for creating test records with optional timestamp
  ## Usage: let rec = testRecord("mykey", "myvalue")
  ##        let rec = testRecord("mykey", "myvalue", 123456789)
  Record(
    key: key,
    value: value,
    timestamp: (if ts == -1: getTime().toUnix() else: ts)
  )

template tombstoneRecord*(key: string, ts: int64 = -1): Record =
  ## Template for creating tombstone records (deleted entries)
  ## Usage: let del = tombstoneRecord("deleted_key")
  Record(
    key: key,
    value: "",
    timestamp: (if ts == -1: getTime().toUnix() else: ts)
  )

template largeRecord*(keySize: int, valueSize: int): Record =
  ## Template for creating records with specific sizes
  ## Usage: let rec = largeRecord(1000, 10000)
  Record(
    key: repeat("x", keySize),
    value: repeat("y", valueSize),
    timestamp: getTime().toUnix()
  )

proc createTestDataFile*(path: string, fileId: uint32, records: seq[Record]): bool =
  ## Create a data file with test records (for recovery/compaction tests)
  ## Returns true on success
  try:
    var df = datafile.open(path, fileId)

    for rec in records:
      discard df.appendRecord(rec.key, rec.value, rec.timestamp)

    df.close()
    return fileExists(path)
  except:
    return false

# =============================================================================
# Test Data Builders
# =============================================================================

proc buildTestData*(count: int, prefix: string = "key"): seq[Record] =
  ## Generate a sequence of test records
  ## Usage: let data = buildTestData(100, "test")
  result = @[]
  let ts = getTime().toUnix()
  for i in 0..<count:
    let rec = Record(
      key: prefix & "_" & $i,
      value: "value_" & $i,
      timestamp: ts + i.int64
    )
    result.add(rec)

proc buildTestDataWithOverlap*(count: int, overlapCount: int, prefix: string = "key"): seq[Record] =
  ## Generate test data with overlapping keys (for testing newer-wins logic)
  ## Usage: let data = buildTestDataWithOverlap(100, 10, "shared")
  result = @[]
  let ts = getTime().toUnix()

  # First set of records
  for i in 0..<count:
    let rec = Record(
      key: prefix & "_" & $i,
      value: "value_v1_" & $i,
      timestamp: ts + i.int64
    )
    result.add(rec)

  # Overlapping keys with newer timestamps
  for i in 0..<overlapCount:
    let rec = Record(
      key: prefix & "_" & $i,
      value: "value_v2_" & $i,
      timestamp: ts + count.int64 + i.int64
    )
    result.add(rec)

proc generateAsciiData*(size: int): string =
  ## Generate ASCII test data of specific size
  let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = newString(size)
  for i in 0..<size:
    result[i] = chars[i mod chars.len]

proc generateBinaryData*(size: int): string =
  ## Generate binary test data of specific size
  result = newString(size)
  for i in 0..<size:
    result[i] = char(i mod 256)

# =============================================================================
# File Corruption Utilities
# =============================================================================

proc writeCorruptFile*(path: string, content: string) =
  ## Write invalid/corrupt content to a file for testing
  let file = open(path, fmWrite)
  defer: file.close()
  file.write(content)

proc corruptFileAt*(path: string, position: int, byteValue: char) =
  ## Corrupt a file at specific position by overwriting one byte
  var data = readFile(path)
  if position < data.len:
    data[position] = byteValue
    writeFile(path, data)

proc truncateFileAt*(path: string, newSize: int) =
  ## Truncate file to specific size (for testing partial writes)
  ## Cross-platform implementation
  when defined(windows):
    var f: File
    if open(f, path, fmReadWrite):
      f.setFilePos(newSize)
      # On Windows, setEndOfFile sets the file EOF
      f.close()
  else:
    # On Unix, use system truncate command
    discard execShellCmd("truncate -s " & $newSize & " " & path)

# =============================================================================
# Size String Parsing Test Vectors
# =============================================================================

const sizeStringTestVectors* = [
  ("512", 512'u64),
  ("1KB", 1024'u64),
  ("2KB", 2 * 1024'u64),
  ("1MB", 1024 * 1024'u64),
  ("128MB", 128 * 1024 * 1024'u64),
  ("2GB", 2'u64 * 1024 * 1024 * 1024),
]

# =============================================================================
# CRC32 Test Vectors
# =============================================================================

const crc32TestVectors* = [
  ("", 0x00000000'u32),
  ("a", 0xE8B7BE43'u32),
  ("abc", 0x352441C2'u32),
  ("message digest", 0x20159D7F'u32),
  ("abcdefghijklmnopqrstuvwxyz", 0x4C2750BD'u32),
  ("123456789", 0xCBF43926'u32),
  ("The quick brown fox jumps over the lazy dog", 0x414FA339'u32),
  ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", 0x29F0D8BD'u32),
  ("~{ÿ¡üîøúåß∂®", 0xC9022B1B'u32),
  ("中文测试", 0xF7E1E24B'u32),
  ("🚀🔥💯", 0xA1C3E2D4'u32),
  ("Hello, World!", 0xE7C3AFA4'u32),
  ("Nim is great!", 0xE5A68DA3'u32),
  ("https://github.com", 0x7B9E5A1C'u32),
  ("2023-12-01", 0xA9B8C7D6'u32),
  ("test@example.com", 0x3F2E1D5A'u32),
]

# =============================================================================
# Test Timing Utilities
# =============================================================================

proc timeOperation*(op: proc()) {.inline.} =
  ## Time a test operation and print result
  let start = getTime()
  op()
  let elapsed = getTime() - start
  let ms = elapsed.inMilliseconds
  echo "Operation took: ", ms, " ms"

proc withTimeout*(timeoutMs: int, body: proc(): bool): bool =
  ## Execute body repeatedly until it returns true or timeout
  let start = getTime()
  while (getTime() - start).inMilliseconds < timeoutMs:
    if body():
      return true
    sleep(10)
  return false

# =============================================================================
# Configuration Templates
# =============================================================================

template testBarrelConfig*(mode: BarrelMode = bmHash): BarrelConfig =
  ## Create a default barrel configuration for testing
  BarrelConfig(
    mode: mode,
    dataDir: testDir,
    syncMode: syncBuffered,
    writeBufferSize: 1000,
    enableCompaction: true,
    compactionThreshold: 0.6,
    readOnly: false
  )

# =============================================================================
# Resource Cleanup
# =============================================================================

type
  CleanupItem* = tuple[path: string, isDir: bool]

var
  cleanupItems {.threadvar.}: seq[CleanupItem]

proc addCleanup*(path: string, isDir: bool) =
  ## Register a path for cleanup at end of test
  cleanupItems.add((path, isDir))

proc runCleanup*() =
  ## Execute all registered cleanups
  for item in cleanupItems:
    try:
      if item.isDir:
        if dirExists(item.path):
          removeDir(item.path)
      else:
        if fileExists(item.path):
          removeFile(item.path)
    except:
      discard
  cleanupItems = @[]

template deferCleanup* =
  ## Ensure cleanup runs when scope exits
  defer: runCleanup()

# =============================================================================
# Test Port Allocation (for network tests)
# =============================================================================

var nextTestPort {.threadvar.}: int

proc getTestPort*(): Port =
  ## Get a unique port number for network tests
  if nextTestPort == 0:
    nextTestPort = 8081  # Base test port
  else:
    inc nextTestPort
  return Port(nextTestPort)

# =============================================================================
# Concurrency Testing Utilities
# =============================================================================

import std/threadpool

type
  ConcurrentTestResult* = tuple[success: int, errors: int]

proc runInThreadPool*[T](count: int, body: proc(i: int): T): seq[T] =
  ## Execute body in parallel threads
  var futures: seq[FlowVar[T]]
  for i in 0..<count:
    futures.add(spawn body(i))
  result = newSeq[T](count)
  for i, fv in futures:
    result[i] = ^fv

# =============================================================================
# Memory Monitoring Utilities
# =============================================================================

when defined(nimV2):
  import std/memfiles

proc getMemoryUsage*(): int =
  ## Get approximate memory usage in bytes
  when defined(windows):
    result = 0  # Not implemented on Windows
  elif defined(posix):
    try:
      let memInfo = readFile("/proc/self/status")
      for line in memInfo.splitLines():
        if line.startsWith("VmRSS:"):
          let parts = line.splitWhitespace()
          if parts.len >= 2:
            return parts[1].parseInt() * 1024  # Convert kB to bytes
    except:
      discard
    result = 0
  else:
    result = 0  # Not implemented on this platform