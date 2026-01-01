## HugeBarrel Stress Test
##
## Stress tests HugeBarrel with large datasets (1M to 50M keys)
## Tests write performance, data integrity, and compaction behavior at scale

import std/[os, strformat, strutils, times, random, tables, math, sequtils, cpuinfo]
import ../src/bitbarrel/types
import ../src/bitbarrel/barrel
import ../src/storage/hugebarrel

# Test profiles
const
  PROFILE_QUICK = "quick"       # 1M keys, ~2GB
  PROFILE_STANDARD = "standard" # 10M keys, ~20GB
  PROFILE_STRESS = "stress"     # 50M keys, ~50GB
  PROFILE_EXHAUSTIVE = "exhaustive" # 50M keys with full validation

# Key configuration
const
  KEY_PREFIX = "stress:key:"
  MIN_VALUE_SIZE = 800  # bytes
  MAX_VALUE_SIZE = 1000 # bytes

# Default values for stress profile
var
  gTotalKeys = 50_000_000      # 50 million
  gAvgKeySize = 100             # 100 bytes
  gAvgValueSize = 900           # 900 bytes
  gProgressInterval = 100_000   # Report every 100K writes
  gSpotCheckRate = 0.01         # Validate 1% of writes
  gStartTime: float
  gLastProgressTime: float

# Metrics collection
type
  StressTestMetrics = object
    # Write phase
    writeStartTime: float
    writeEndTime: float
    keysWritten: int
    bytesWritten: int64
    peakWriteOps: float
    avgWriteOps: float

    # Memory
    peakMemoryMB: float
    avgMemoryMB: float
    memorySamples: int

    # Range/file info
    peakRanges: int
    finalRanges: int
    barrel2Files: int
    peakFileSizeMB: float

    # Validation
    keysValidated: int
    validationErrors: int
    spotCheckErrors: int

    # Read performance
    readStartTime: float
    readEndTime: float
    keysRead: int
    readOpsPerSec: float
    avgReadLatencyMs: float

    # Compaction
    compactionStartTime: float
    compactionEndTime: float
    compactionEvents: int
    spaceReclaimedMB: float
    bytesBeforeCompaction: int64
    bytesAfterCompaction: int64

proc formatBytes(bytes: int64): string =
  ## Format bytes to human-readable string
  if bytes < 1024:
    return fmt"{bytes} B"
  elif bytes < 1024 * 1024:
    return fmt"{bytes.float / 1024:.1f} KB"
  elif bytes < 1024 * 1024 * 1024:
    return fmt"{bytes.float / (1024 * 1024):.1f} MB"
  else:
    return fmt"{bytes.float / (1024.0 * 1024 * 1024):.1f} GB"

proc formatDuration(seconds: float): string =
  ## Format duration in seconds to human-readable string
  if seconds < 60:
    return fmt"{seconds:.1f}s"
  elif seconds < 3600:
    return fmt"{seconds / 60:.1f}min"
  else:
    let hours = seconds / 3600
    let minutes = (seconds mod 3600) / 60
    return fmt"{hours:.1f}h {minutes:.0f}m"

proc getMemoryUsageMB(): float =
  ## Get current memory usage in MB from /proc/self/status
  when defined(linux):
    try:
      let status = readFile("/proc/self/status")
      for line in status.splitLines():
        if line.startsWith("VmRSS:"):
          let parts = line.splitWhitespace()
          if parts.len >= 3 and parts[2] == "kB":
            return parseFloat(parts[1]) / 1024.0
    except IOError:
      discard
  return 0.0

proc getDiskUsage(path: string): int64 =
  ## Get total disk usage for a directory in bytes
  var total: int64 = 0
  try:
    for kind, filePath in walkDir(path):
      if kind == pcFile:
        total += getFileSize(filePath)
      elif kind == pcDir:
        total += getDiskUsage(filePath)
  except IOError:
    discard
  return total

proc calculateETA(elapsed: float, completed: int, total: int): string =
  ## Calculate estimated time remaining
  if completed == 0:
    return "unknown"

  let rate = completed.float / elapsed
  let remaining = total - completed
  let etaSeconds = remaining.float / rate

  if etaSeconds < 60:
    return fmt"{etaSeconds:.0f} sec"
  elif etaSeconds < 3600:
    return fmt"{etaSeconds / 60:.0f} min"
  else:
    let hours = etaSeconds / 3600
    let minutes = (etaSeconds mod 3600) / 60
    return fmt"{hours:.0f}h {minutes:.0f}m"

proc printProgress(hb: HugeBarrel, metrics: var StressTestMetrics,
                   completed: int, total: int, isWrite: bool) =
  ## Print progress with metrics
  let now = cpuTime()
  let elapsed = now - gStartTime
  let percent = (completed.float / total.float) * 100
  let rate = completed.float / elapsed
  let mibPerSec = (rate * gAvgValueSize.float) / (1024 * 1024)

  # Update peak metrics
  if rate > metrics.peakWriteOps:
    metrics.peakWriteOps = rate

  let memoryMB = getMemoryUsageMB()
  if memoryMB > metrics.peakMemoryMB:
    metrics.peakMemoryMB = memoryMB

  metrics.avgMemoryMB += memoryMB
  inc metrics.memorySamples

  # Print progress line
  echo fmt"[{formatDuration(elapsed)}] Progress: {percent:.1f}% ({completed}/{total})"
  echo fmt"  Rate: {rate:.0f} ops/sec ({mibPerSec:.1f} MiB/s)"
  echo fmt"  ETA: {calculateETA(elapsed, completed, total)}"
  echo fmt"  Memory: {memoryMB:.1f} MB"
  echo fmt"  Ranges: {hb.ranges.len}, Files: {hb.nextFileId - 1}"
  echo ""

  # Throttle progress updates
  if now - gLastProgressTime < 1.0:
    return
  gLastProgressTime = now

proc generateValue(size: int): string =
  ## Generate a random value of approximately the given size
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  result = newString(size)
  for i in 0..<size:
    result[i] = chars[rand(chars.len - 1)]

proc runWritePhase(hb: var HugeBarrel, metrics: var StressTestMetrics) =
  ## Run the sequential write phase
  echo "=== Write Phase ==="
  echo fmt"Writing {gTotalKeys} keys to HugeBarrel..."
  echo ""

  metrics.writeStartTime = cpuTime()
  gStartTime = metrics.writeStartTime
  gLastProgressTime = gStartTime

  randomize()

  for i in 0..<gTotalKeys:
    let key = fmt"{KEY_PREFIX}{i:010d}"
    let valueSize = MIN_VALUE_SIZE + rand(MAX_VALUE_SIZE - MIN_VALUE_SIZE)
    let value = generateValue(valueSize)

    let success = hb.set(key, value)
    if not success:
      echo fmt"ERROR: Failed to write key {i}"
      inc metrics.validationErrors

    inc metrics.keysWritten
    metrics.bytesWritten += key.len + value.len

    # Spot check validation during write
    if rand(99) < int(gSpotCheckRate * 100):
      let retrieved = hb.get(key)
      if retrieved != value:
        echo fmt"ERROR: Data mismatch for key {i}"
        inc metrics.spotCheckErrors
      inc metrics.keysValidated

    # Progress reporting
    if (i + 1) mod gProgressInterval == 0:
      printProgress(hb, metrics, i + 1, gTotalKeys, isWrite = true)

  # Flush all dirty ranges
  let flushed = hb.flushDirtyRanges()
  echo fmt"Flushed {flushed} dirty ranges"

  metrics.writeEndTime = cpuTime()
  let elapsed = metrics.writeEndTime - metrics.writeStartTime
  metrics.avgWriteOps = gTotalKeys.float / elapsed

  echo ""
  echo "=== Write Phase Complete ==="
  echo fmt"  Keys written: {metrics.keysWritten}"
  echo fmt"  Data size: {formatBytes(metrics.bytesWritten)}"
  echo fmt"  Time: {formatDuration(elapsed)}"
  echo fmt"  Avg rate: {metrics.avgWriteOps:.0f} ops/sec"
  echo fmt"  Peak rate: {metrics.peakWriteOps:.0f} ops/sec"
  echo fmt"  Avg memory: {metrics.avgMemoryMB / metrics.memorySamples.float:.1f} MB"
  echo fmt"  Peak memory: {metrics.peakMemoryMB:.1f} MB"
  echo ""

proc runValidationPhase(hb: var HugeBarrel, metrics: var StressTestMetrics) =
  ## Run validation phase - read all keys and verify
  echo "=== Validation Phase ==="
  echo "Reading all keys to verify data integrity..."
  echo ""

  metrics.readStartTime = cpuTime()

  var errors = 0
  var lastErrorKey = ""
  var lastErrorExpected = ""
  var lastErrorRetrieved = ""

  for i in 0..<gTotalKeys:
    let key = fmt"{KEY_PREFIX}{i:010d}"
    let expectedValueSize = MIN_VALUE_SIZE + ((i * 789) mod (MAX_VALUE_SIZE - MIN_VALUE_SIZE))
    let expectedValue = generateValue(expectedValueSize)

    let retrieved = hb.get(key)
    if retrieved != expectedValue:
      inc errors
      if errors <= 3:  # Track first few errors
        lastErrorKey = key
        lastErrorExpected = expectedValue[0..min(50, expectedValue.len - 1)]
        lastErrorRetrieved = if retrieved.len > 0: retrieved[0..min(50, retrieved.len - 1)] else: "<empty>"

    # Log progress
    if (i + 1) mod gProgressInterval == 0:
      let percent = (i.float / gTotalKeys.float) * 100
      echo fmt"  Validation: {percent:.1f}% ({i + 1}/{gTotalKeys})"

  metrics.readEndTime = cpuTime()
  metrics.keysRead = gTotalKeys
  let elapsed = metrics.readEndTime - metrics.readStartTime
  metrics.readOpsPerSec = gTotalKeys.float / elapsed

  echo ""
  if errors == 0:
    echo "✓ All keys validated successfully!"
  else:
    echo fmt"✗ {errors} validation errors!"
    for i in 0..<min(errors, 3):
      echo fmt"  Key: {lastErrorKey}"
      echo fmt"  Expected: {lastErrorExpected}..."
      echo fmt"  Got: {lastErrorRetrieved}..."
      echo ""

  echo ""
  echo "=== Validation Complete ==="
  echo fmt"  Keys validated: {metrics.keysRead}"
  echo fmt"  Errors: {errors}"
  echo fmt"  Time: {formatDuration(elapsed)}"
  echo fmt"  Rate: {metrics.readOpsPerSec:.0f} ops/sec"
  echo ""

proc runRandomReadTest(hb: var HugeBarrel, metrics: var StressTestMetrics,
                       numReads: int = 1_000_000) =
  ## Run random read performance test
  echo "=== Random Read Performance Test ==="
  echo fmt"Performing {numReads} random reads..."
  echo ""

  let startTime = cpuTime()
  var errors = 0
  var totalLatency = 0.0

  for i in 0..<numReads:
    let randomKey = rand(gTotalKeys - 1)
    let key = fmt"{KEY_PREFIX}{randomKey:010d}"
    let expectedSize = MIN_VALUE_SIZE + ((randomKey * 789) mod (MAX_VALUE_SIZE - MIN_VALUE_SIZE))

    let readStart = cpuTime()
    let retrieved = hb.get(key)
    let readEnd = cpuTime()

    totalLatency += (readEnd - readStart) * 1000  # Convert to ms

    if retrieved.len != expectedSize:
      inc errors

    # Progress
    if (i + 1) mod 100_000 == 0:
      let percent = ((i + 1).float / numReads.float) * 100
      echo fmt"  Progress: {percent:.1f}% ({i + 1}/{numReads})"

  let elapsed = cpuTime() - startTime
  let opsPerSec = numReads.float / elapsed
  metrics.avgReadLatencyMs = totalLatency / numReads.float

  echo ""
  echo "=== Random Read Test Complete ==="
  echo fmt"  Reads: {numReads}"
  echo fmt"  Errors: {errors}"
  echo fmt"  Time: {formatDuration(elapsed)}"
  echo fmt"  Rate: {opsPerSec:.0f} ops/sec"
  echo fmt"  Avg latency: {metrics.avgReadLatencyMs:.3f} ms"
  echo ""

proc runCompactionTest(hb: var HugeBarrel, metrics: var StressTestMetrics) =
  ## Run compaction test: delete 20% of keys and compact
  echo "=== Compaction Test ==="
  echo "Deleting 20% of keys to create fragmentation..."
  echo ""

  let numDeletes = gTotalKeys div 5
  let deleteStart = cpuTime()

  for i in 0..<numDeletes:
    let randomKey = rand(gTotalKeys - 1)
    let key = fmt"{KEY_PREFIX}{randomKey:010d}"
    discard hb.set(key, "")  # Tombstone

    if (i + 1) mod 10_000 == 0:
      let percent = ((i + 1).float / numDeletes.float) * 100
      echo fmt"  Deleting: {percent:.1f}% ({i + 1}/{numDeletes})"

  let deleteEnd = cpuTime()
  echo fmt"  Deletion time: {formatDuration(deleteEnd - deleteStart)}"
  echo ""

  # Flush before measuring
  discard hb.flushDirtyRanges()
  echo "All ranges flushed"
  echo ""

  # Measure space before compaction
  let barrel2Path = hb.path / "barrel2"
  metrics.bytesBeforeCompaction = getDiskUsage(barrel2Path)

  echo fmt"Space before compaction: {formatBytes(metrics.bytesBeforeCompaction)}"
  echo ""

  # Find all Barrel2 files and compact them
  echo "Compacting all Barrel2 files..."
  metrics.compactionStartTime = cpuTime()

  var filesCompacted = 0
  for fileId in 1'u32 ..< hb.nextFileId:
    let filePath = hb.path / "barrel2" / fmt"file_{fileId:06d}.data"
    if fileExists(filePath):
      let result = hb.compactFile(fileId)
      if result:
        inc filesCompacted
        echo fmt"  Compact file_{fileId:06d}.data: ✓"
        inc metrics.compactionEvents
      else:
        echo fmt"  Compact file_{fileId:06d}.data: skipped"

  metrics.compactionEndTime = cpuTime()

  echo ""
  echo fmt"  Files compacted: {filesCompacted}"
  echo ""

  # Measure space after compaction
  metrics.bytesAfterCompaction = getDiskUsage(barrel2Path)
  let compactionTime = metrics.compactionEndTime - metrics.compactionStartTime

  metrics.spaceReclaimedMB = (metrics.bytesBeforeCompaction - metrics.bytesAfterCompaction).float / (1024 * 1024)

  let reclamationPercent = if metrics.bytesBeforeCompaction > 0:
    ((metrics.bytesBeforeCompaction - metrics.bytesAfterCompaction).float / metrics.bytesBeforeCompaction.float) * 100
  else:
    0.0

  echo "=== Compaction Test Complete ==="
  echo fmt"  Events: {metrics.compactionEvents}"
  echo fmt"  Time: {formatDuration(compactionTime)}"
  echo fmt"  Space before: {formatBytes(metrics.bytesBeforeCompaction)}"
  echo fmt"  Space after: {formatBytes(metrics.bytesAfterCompaction)}"
  echo fmt"  Space reclaimed: {metrics.spaceReclaimedMB:.1f} MB ({reclamationPercent:.1f}%)"
  echo ""

proc printSummary(metrics: StressTestMetrics) =
  ## Print final summary
  echo ""
  echo "=" * 70
  echo "                    HUGE BARREL STRESS TEST SUMMARY"
  echo "=" * 70
  echo ""

  # Write phase
  let writeTime = metrics.writeEndTime - metrics.writeStartTime
  echo "Write Phase:"
  echo fmt"  Keys written: {metrics.keysWritten}"
  echo fmt"  Data size: {formatBytes(metrics.bytesWritten)}"
  echo fmt"  Time: {formatDuration(writeTime)}"
  echo fmt"  Avg rate: {metrics.avgWriteOps:.0f} ops/sec"
  echo fmt"  Peak rate: {metrics.peakWriteOps:.0f} ops/sec"
  echo ""

  # Memory
  echo "Memory Usage:"
  echo fmt"  Peak: {metrics.peakMemoryMB:.1f} MB"
  echo fmt"  Average: {metrics.avgMemoryMB / metrics.memorySamples:.1f} MB"
  echo ""

  # Ranges and files
  echo "Storage Structure:"
  echo fmt"  Final ranges: {metrics.finalRanges}"
  echo fmt"  Barrel2 files: {metrics.barrel2Files}"
  echo ""

  # Validation
  let readTime = metrics.readEndTime - metrics.readStartTime
  echo "Validation:"
  echo fmt"  Keys validated: {metrics.keysRead}"
  echo fmt"  Errors: {metrics.validationErrors}"
  echo fmt"  Spot check errors: {metrics.spotCheckErrors}"
  echo fmt"  Validation time: {formatDuration(readTime)}"
  echo fmt"  Read rate: {metrics.readOpsPerSec:.0f} ops/sec"
  echo fmt"  Avg read latency: {metrics.avgReadLatencyMs:.3f} ms"
  echo ""

  # Compaction
  let compactionTime = metrics.compactionEndTime - metrics.compactionStartTime
  echo "Compaction:"
  echo fmt"  Files compacted: {metrics.compactionEvents}"
  echo fmt"  Compaction time: {formatDuration(compactionTime)}"
  if metrics.bytesBeforeCompaction > 0:
    let reclamationPercent = ((metrics.bytesBeforeCompaction - metrics.bytesAfterCompaction).float / metrics.bytesBeforeCompaction.float) * 100
    echo fmt"  Space reclamation: {reclamationPercent:.1f}%"
  echo ""

  echo "=" * 70

proc configureForProfile(profile: string) =
  ## Configure test parameters based on profile
  case profile
  of PROFILE_QUICK:
    gTotalKeys = 1_000_000
    gProgressInterval = 10_000
    echo "Profile: QUICK (1M keys, ~2GB)"
  of PROFILE_STANDARD:
    gTotalKeys = 10_000_000
    gProgressInterval = 50_000
    echo "Profile: STANDARD (10M keys, ~20GB)"
  of PROFILE_STRESS, PROFILE_EXHAUSTIVE:
    gTotalKeys = 50_000_000
    gProgressInterval = 100_000
    echo "Profile: STRESS (50M keys, ~50GB)"
  else:
    echo fmt"Unknown profile: {profile}. Using defaults."

  echo ""
  echo fmt"Test parameters:"
  echo fmt"  Keys: {gTotalKeys}"
  echo fmt"  Avg record size: {gAvgKeySize + gAvgValueSize} bytes (~{formatBytes((gAvgKeySize + gAvgValueSize) * gTotalKeys)})"
  echo ""

proc checkDiskSpace(requiredGB: int): bool =
  ## Check if enough disk space is available
  when defined(linux):
    try:
      let statvfs = getFileSystemState("/")
      let availableGB = (statvfs.freeSpace.int64) div (1024 * 1024 * 1024)
      if availableGB < requiredGB:
        echo fmt"WARNING: Only {availableGB} GB available. Need {requiredGB} GB."
        return false
    except:
      discard
  return true

# Main test runner
when isMainModule:
  # Parse command line
  var profile = PROFILE_STRESS
  if paramCount() > 0:
    profile = paramStr(1)

  configureForProfile(profile)

  # Check disk space
  let requiredGB = if profile == PROFILE_QUICK: 10
                   elif profile == PROFILE_STANDARD: 30
                   else: 100

  if not checkDiskSpace(requiredGB):
    echo "Continue anyway? (y/n)"
    let response = readLine(stdin)
    if response != "y":
      quit(0)
  else:
    echo "✓ Disk space check passed"
    echo ""

  # Initialize HugeBarrel
  var config = defaultBarrelConfig()
  config.mode = bmHugeCritBit
  config.hugeConfig.maxEntriesPerRange = 200_000
  config.hugeConfig.rangeCacheSize = 50
  config.hugeConfig.maxDataFileSizeMB = 2048
  config.hugeConfig.autoSplitEnabled = true
  config.hugeConfig.flushIntervalMs = 5000
  config.syncMode = UserSyncMode.None
  config.writeBufferSize = 256 * 1024
  config.autoCompact = false

  var hb = openHugeBarrel("stress_test_db", config)
  defer:
    echo "Closing HugeBarrel..."
    hb.close()
    echo "Cleaning up test data..."
    if dirExists("stress_test_db"):
      removeDir("stress_test_db")
    echo "Done."

  if hb.isClosed():
    echo "ERROR: Failed to open HugeBarrel"
    quit(1)

  echo "✓ HugeBarrel initialized"
  echo ""

  # Initialize metrics
  var metrics = StressTestMetrics()

  # Run test phases
  runWritePhase(hb, metrics)
  metrics.finalRanges = hb.ranges.len
  metrics.barrel2Files = hb.nextFileId - 1

  # Run validation (skip for quick profile to save time)
  if profile != PROFILE_QUICK:
    runValidationPhase(hb, metrics)
    runRandomReadTest(hb, metrics)
  else:
    echo "=== Validation Skipped (quick profile) ==="
    echo ""

  # Run compaction test
  runCompactionTest(hb, metrics)

  # Print summary
  printSummary(metrics)

  # Check for errors
  if metrics.validationErrors > 0 or metrics.spotCheckErrors > 0:
    echo ""
    echo "ERROR: Test failed due to data integrity issues!"
    quit(1)
  else:
    echo ""
    echo "✓ All tests passed!"
