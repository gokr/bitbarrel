## Compaction Stress Test
##
## Stress test for BitBarrel compaction system with continuous reads/writes
## Tracks compaction timing, file size changes, and verifies data integrity
##
## Usage: compaction_stress [quick|standard|stress]

import os, times, strformat, strutils, tables, random, math, sequtils
import ../src/bitbarrel
import ../src/bitbarrel/types

type
  CompactionProfile = object
    name: string
    totalOps: int
    readRatio: float
    compactThreshold: float
    valueSize: int
    keysPerBatch: int
    deletionRatio: float

  CompactionEvent = object
    eventId: int
    startTime: Time
    endTime: Time
    fileSizeBefore: int64
    fileSizeAfter: int64
    recordsScanned: int
    recordsKept: int
    recordsDropped: int
    bytesScanned: int64
    bytesWritten: int64
    durationMs: int64
    opsCompletedDuring: int

  BenchmarkMetrics = ref object
    compactions: seq[CompactionEvent]
    totalCompactions: int
    totalOps: int
    readOps: int
    writeOps: int
    opsCompletedDuringCompaction: int
    startTime: Time
    endTime: Time
    totalDurationMs: int64
    overallOpsPerSec: float
    readOpsPerSec: float
    writeOpsPerSec: float
    peakFileSize: int64
    finalFileSize: int64
    totalSpaceReclaimed: int64
    readErrors: int
    writeErrors: int
    compactionErrors: int
    keysVerified: int
    verificationErrors: int
    profileName: string
    currentEventOps: int

const
  QUICK_PROFILE = CompactionProfile(
    name: "Quick",
    totalOps: 10_000,
    readRatio: 0.7,
    compactThreshold: 0.3,
    valueSize: 128,
    keysPerBatch: 1000,
    deletionRatio: 0.5
  )

  STANDARD_PROFILE = CompactionProfile(
    name: "Standard",
    totalOps: 100_000,
    readRatio: 0.7,
    compactThreshold: 0.3,
    valueSize: 256,
    keysPerBatch: 5000,
    deletionRatio: 0.5
  )

  STRESS_PROFILE = CompactionProfile(
    name: "Stress",
    totalOps: 1_000_000,
    readRatio: 0.7,
    compactThreshold: 0.3,
    valueSize: 512,
    keysPerBatch: 10000,
    deletionRatio: 0.5
  )

var shutdownFlag: bool = false

proc generateKey(id: int): string =
  fmt("key:{id:010d}")

proc generateValue(id: int, size: int): string =
  let prefix = fmt("value:{id:010d}:")
  let padSize = max(0, size - prefix.len)
  return prefix & repeat('x', padSize)

proc getDataFileSize(barrelPath: string): int64 =
  let barrelDir = splitFile(barrelPath).dir
  let searchPattern = if barrelDir == "": "*.data" else: barrelDir / "*.data"

  for file in walkFiles(searchPattern):
    try:
      return getFileSize(file)
    except OSError:
      continue

  return 0

proc parseProfile(): CompactionProfile =
  if paramCount() == 0:
    return QUICK_PROFILE

  let arg = paramStr(1).toLowerAscii()
  case arg
  of "quick":
    return QUICK_PROFILE
  of "standard":
    return STANDARD_PROFILE
  of "stress":
    return STRESS_PROFILE
  else:
    echo fmt("Unknown profile: {arg}")
    echo "Available profiles: quick, standard, stress"
    quit(1)

proc populateInitialData(barrel: var Barrel, profile: CompactionProfile,
                        metrics: BenchmarkMetrics): Table[string, string] =
  echo fmt("Populating {profile.keysPerBatch} initial keys...")
  result = initTable[string, string]()

  for i in 1..profile.keysPerBatch:
    let key = generateKey(i)
    let value = generateValue(i, profile.valueSize)

    if not barrel.set(key, value):
      metrics.writeErrors += 1
    else:
      result[key] = value

    if i mod 1000 == 0:
      let progress = (i.float / profile.keysPerBatch.float) * 100
      echo fmt("  Progress: {progress:.1f}% ({i}/{profile.keysPerBatch})")

  echo fmt("Initial population complete: {result.len} keys")

proc createFragmentation(barrel: var Barrel, keySpace: var Table[string, string],
                        profile: CompactionProfile, metrics: BenchmarkMetrics) =
  echo "Creating fragmentation..."

  let keysToDelete = int(keySpace.len.float * profile.deletionRatio)
  let keysToUpdate = int(keySpace.len.float * 0.3)

  var deleted = 0
  var keysToProcess = toSeq(keySpace.keys)

  for key in keysToProcess:
    if deleted >= keysToDelete:
      break
    if barrel.delete(key):
      keySpace.del(key)
      deleted += 1

  var updated = 0
  keysToProcess = toSeq(keySpace.keys)

  for key in keysToProcess:
    if updated >= keysToUpdate:
      break
    let newValue = generateValue(rand(1000000), profile.valueSize)
    if barrel.set(key, newValue):
      keySpace[key] = newValue
      updated += 1

  echo fmt("Fragmentation created: {deleted} deletes, {updated} updates")

proc runMixedWorkload(barrel: var Barrel, metrics: BenchmarkMetrics,
                     profile: CompactionProfile, keySpace: var Table[string, string]) =
  echo "Running mixed workload..."
  var opsCompleted = 0
  var nextKeyId = profile.keysPerBatch + 1

  randomize()

  while opsCompleted < profile.totalOps:
    let compacting = barrel.isCompacting()

    if rand(1.0) < profile.readRatio:
      if keySpace.len > 0:
        let keys = toSeq(keySpace.keys)
        let key = keys[rand(keys.len - 1)]
        let expectedValue = keySpace[key]
        let actualValue = barrel.get(key)

        if actualValue != expectedValue:
          metrics.verificationErrors += 1
        else:
          metrics.keysVerified += 1

        metrics.readOps += 1
        if compacting:
          metrics.opsCompletedDuringCompaction += 1
          metrics.currentEventOps += 1
    else:
      let isUpdate = keySpace.len > 0 and rand(1.0) < 0.7

      if isUpdate:
        let keys = toSeq(keySpace.keys)
        let key = keys[rand(keys.len - 1)]
        let newValue = generateValue(rand(1000000), profile.valueSize)
        if barrel.set(key, newValue):
          keySpace[key] = newValue
        else:
          metrics.writeErrors += 1
      else:
        let key = generateKey(nextKeyId)
        let value = generateValue(nextKeyId, profile.valueSize)
        if barrel.set(key, value):
          keySpace[key] = value
          nextKeyId += 1
        else:
          metrics.writeErrors += 1

      metrics.writeOps += 1
      if compacting:
        metrics.opsCompletedDuringCompaction += 1
        metrics.currentEventOps += 1

    opsCompleted += 1

    if opsCompleted mod 10000 == 0:
      let progress = (opsCompleted.float / profile.totalOps.float) * 100
      let elapsed = (getTime() - metrics.startTime).inSeconds
      let throughput = if elapsed > 0: opsCompleted.float / elapsed.float else: 0.0
      echo fmt("  Progress: {progress:.1f}% ({opsCompleted}/{profile.totalOps}) - {throughput:.0f} ops/sec")

  echo "Mixed workload complete"

proc monitorCompaction(barrel: var Barrel, metrics: BenchmarkMetrics, barrelPath: string) {.thread.} =
  var wasCompacting = false
  var currentEvent: CompactionEvent

  while not shutdownFlag:
    let isCompacting = barrel.isCompacting()

    if isCompacting and not wasCompacting:
      currentEvent = CompactionEvent(
        eventId: metrics.totalCompactions + 1,
        startTime: getTime(),
        fileSizeBefore: getDataFileSize(barrelPath),
        opsCompletedDuring: 0
      )
      wasCompacting = true
      metrics.currentEventOps = 0

      let sizeMB = currentEvent.fileSizeBefore.float / (1024 * 1024)
      echo fmt("Compaction {currentEvent.eventId} started (file size: {sizeMB:.1f} MB)")

    elif not isCompacting and wasCompacting:
      currentEvent.endTime = getTime()
      currentEvent.fileSizeAfter = getDataFileSize(barrelPath)
      currentEvent.durationMs = (currentEvent.endTime - currentEvent.startTime).inMilliseconds
      currentEvent.opsCompletedDuring = metrics.currentEventOps

      let stats = barrel.getCompactStats()
      currentEvent.recordsScanned = stats.recordsScanned
      currentEvent.recordsKept = stats.recordsKept
      currentEvent.recordsDropped = stats.recordsDropped
      currentEvent.bytesScanned = stats.bytesScanned
      currentEvent.bytesWritten = stats.bytesWritten

      metrics.compactions.add(currentEvent)
      metrics.totalCompactions += 1
      metrics.totalSpaceReclaimed += (currentEvent.fileSizeBefore - currentEvent.fileSizeAfter)

      let reclaimedMB = (currentEvent.fileSizeBefore - currentEvent.fileSizeAfter).float / (1024 * 1024)
      echo fmt("Compaction {currentEvent.eventId} completed in {currentEvent.durationMs}ms (reclaimed {reclaimedMB:.1f} MB)")

      let currentSize = getDataFileSize(barrelPath)
      if currentSize > metrics.peakFileSize:
        metrics.peakFileSize = currentSize

      wasCompacting = false

    sleep(100)

proc verifyDataIntegrity(barrel: var Barrel, keySpace: Table[string, string]): int =
  echo "Verifying data integrity..."
  var errors = 0
  var checked = 0

  for key, expectedValue in keySpace:
    let actualValue = barrel.get(key)
    if actualValue != expectedValue:
      if errors < 10:
        echo fmt("ERROR: Key '{key}' mismatch!")
        let expPreview = if expectedValue.len > 50: expectedValue[0..49] & "..." else: expectedValue
        let actPreview = if actualValue.len > 50: actualValue[0..49] & "..." else: actualValue
        echo fmt("  Expected: {expPreview}")
        echo fmt("  Actual:   {actPreview}")
      errors += 1

    checked += 1
    if checked mod 10000 == 0:
      let progress = (checked.float / keySpace.len.float) * 100
      echo fmt("  Verified {progress:.1f}% ({checked}/{keySpace.len} keys)")

  echo fmt("Integrity check: {checked} keys verified, {errors} errors")
  return errors

proc formatBytes(bytes: int64): string =
  if bytes < 1024:
    return fmt("{bytes} B")
  elif bytes < 1024 * 1024:
    return fmt("{bytes.float / 1024:.1f} KB")
  elif bytes < 1024 * 1024 * 1024:
    return fmt("{bytes.float / (1024 * 1024):.1f} MB")
  else:
    return fmt("{bytes.float / (1024 * 1024 * 1024):.2f} GB")

proc formatDuration(ms: int64): string =
  if ms < 1000:
    return fmt("{ms}ms")
  elif ms < 60000:
    return fmt("{ms.float / 1000:.1f}s")
  else:
    let minutes = ms div 60000
    let seconds = (ms mod 60000).float / 1000
    return fmt("{minutes}m {seconds:.1f}s")

proc printResults(metrics: BenchmarkMetrics, profile: CompactionProfile) =
  echo ""
  echo "═".repeat(70)
  echo "  Compaction Stress Test Results"
  echo "═".repeat(70)
  echo ""
  echo fmt("Profile: {profile.name} ({profile.totalOps:,} operations)")
  echo fmt("Workload: {int(profile.readRatio * 100)}% reads, {int((1.0 - profile.readRatio) * 100)}% writes")
  echo fmt("Compaction Threshold: {int(profile.compactThreshold * 100)}%")
  echo ""

  echo "┌" & "─".repeat(68) & "┐"
  echo "│ " & "Overall Performance".alignLeft(66) & " │"
  echo "├" & "─".repeat(68) & "┤"
  echo fmt("│   Total Operations:        {metrics.totalOps:>10,}                          │")
  echo fmt("│   Total Duration:          {formatDuration(metrics.totalDurationMs):>10}                          │")
  echo fmt("│   Overall Throughput:      {metrics.overallOpsPerSec:>10,.0f} ops/sec                 │")
  echo fmt("│   Read Operations:         {metrics.readOps:>10,} ({metrics.readOpsPerSec:,.0f} ops/sec)      │")
  echo fmt("│   Write Operations:        {metrics.writeOps:>10,} ({metrics.writeOpsPerSec:,.0f} ops/sec)      │")
  echo "└" & "─".repeat(68) & "┘"
  echo ""

  echo "┌" & "─".repeat(68) & "┐"
  echo "│ " & "Compaction Summary".alignLeft(66) & " │"
  echo "├" & "─".repeat(68) & "┤"
  echo fmt("│   Total Compactions:       {metrics.totalCompactions:>10}                          │")
  echo fmt("│   Total Space Reclaimed:   {formatBytes(metrics.totalSpaceReclaimed):>10}                          │")

  if metrics.totalCompactions > 0:
    let avgTime = metrics.compactions.mapIt(it.durationMs).sum div metrics.totalCompactions
    echo fmt("│   Avg Compaction Time:     {formatDuration(avgTime):>10}                          │")
    let pct = (metrics.opsCompletedDuringCompaction.float / metrics.totalOps.float) * 100
    echo fmt("│   Ops During Compaction:   {metrics.opsCompletedDuringCompaction:>10,} ({pct:.1f}% of workload)       │")

  echo fmt("│   Peak File Size:          {formatBytes(metrics.peakFileSize):>10}                          │")
  echo fmt("│   Final File Size:         {formatBytes(metrics.finalFileSize):>10}                          │")
  echo "└" & "─".repeat(68) & "┘"
  echo ""

  if metrics.compactions.len > 0:
    echo "┌" & "─".repeat(68) & "┐"
    echo "│ " & "Compaction Events Detail".alignLeft(66) & " │"
    echo "├" & "─".repeat(68) & "┤"
    echo "│  ID │   Time │  Before │   After │ Reclaimed │ Duration │ Ops     │"
    echo "├" & "─".repeat(68) & "┤"

    for event in metrics.compactions:
      let timeS = (event.startTime - metrics.startTime).inSeconds
      let before = formatBytes(event.fileSizeBefore)
      let after = formatBytes(event.fileSizeAfter)
      let reclaimed = formatBytes(event.fileSizeBefore - event.fileSizeAfter)
      let duration = formatDuration(event.durationMs)
      echo fmt("│ {event.eventId:>3} │ {timeS:>5}s │ {before:>7} │ {after:>7} │ {reclaimed:>9} │ {duration:>8} │ {event.opsCompletedDuring:>7} │")

    echo "└" & "─".repeat(68) & "┘"
    echo ""

  echo "┌" & "─".repeat(68) & "┐"
  echo "│ " & "Data Integrity".alignLeft(66) & " │"
  echo "├" & "─".repeat(68) & "┤"
  echo fmt("│   Keys Verified:           {metrics.keysVerified:>10,}                          │")
  echo fmt("│   Verification Errors:     {metrics.verificationErrors:>10,}                          │")
  echo fmt("│   Read Errors:             {metrics.readErrors:>10,}                          │")
  echo fmt("│   Write Errors:            {metrics.writeErrors:>10,}                          │")
  echo "└" & "─".repeat(68) & "┘"
  echo ""

  if metrics.verificationErrors == 0 and metrics.readErrors == 0 and
     metrics.writeErrors == 0 and metrics.compactionErrors == 0:
    echo "✅ All tests passed - No data loss during compaction"
  else:
    echo "❌ Tests FAILED - Data integrity issues detected"
  echo ""

proc main() =
  let profile = parseProfile()

  echo "═".repeat(70)
  echo "  BitBarrel Compaction Stress Test"
  echo "═".repeat(70)
  echo ""

  var config = defaultBarrelConfig()
  config.autoCompact = true
  config.compactThreshold = profile.compactThreshold

  let barrelPath = "bench_compaction_stress.data"

  if fileExists(barrelPath):
    removeFile(barrelPath)

  var barrel = openDatabase(barrelPath, config)
  defer:
    echo "Waiting for compaction to complete..."
    barrel.waitForCompaction()
    barrel.close()

    if fileExists(barrelPath):
      try:
        removeFile(barrelPath)
      except OSError:
        discard

  var metrics = BenchmarkMetrics(
    compactions: @[],
    profileName: profile.name
  )

  echo fmt("Phase 1: Initial population ({profile.keysPerBatch} keys)")
  var keySpace = populateInitialData(barrel, profile, metrics)

  echo ""
  echo fmt("Phase 2: Creating fragmentation ({int(profile.deletionRatio * 100)}% deletions)")
  createFragmentation(barrel, keySpace, profile, metrics)

  echo ""
  echo fmt("Phase 3: Mixed workload ({profile.totalOps:,} operations)")

  var monitorThread: Thread[void]
  createThread(monitorThread, monitorCompaction, barrel, metrics, barrelPath)

  metrics.startTime = getTime()

  try:
    runMixedWorkload(barrel, metrics, profile, keySpace)
  finally:
    shutdownFlag = true
    joinThread(monitorThread)

  metrics.endTime = getTime()
  metrics.totalDurationMs = (metrics.endTime - metrics.startTime).inMilliseconds

  if metrics.totalDurationMs > 0:
    let durationSec = metrics.totalDurationMs.float / 1000.0
    metrics.overallOpsPerSec = metrics.totalOps.float / durationSec
    metrics.readOpsPerSec = metrics.readOps.float / durationSec
    metrics.writeOpsPerSec = metrics.writeOps.float / durationSec

  echo ""
  let verifyErrors = verifyDataIntegrity(barrel, keySpace)
  metrics.verificationErrors += verifyErrors

  metrics.finalFileSize = getDataFileSize(barrelPath)
  if metrics.peakFileSize == 0:
    metrics.peakFileSize = metrics.finalFileSize

  echo ""
  printResults(metrics, profile)

when isMainModule:
  try:
    main()
  except Exception as e:
    echo fmt("ERROR: {e.msg}")
    echo getStackTrace(e)
    quit(1)
