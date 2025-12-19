## Ordered Range Management
##
## Dynamic range splitting and merging for bmRangedCritBit mode.
## Provides automatic load balancing to prevent range hotspots.

import std/[os, locks, algorithm, strutils, times, options, math]
import ../bitbarrel/types
import rangeindex
import keydir
import critbitindex
import rangehint
import critbithint

type
  RangeHealthStatus* = enum
    rhsHealthy      # Range is within normal parameters
    rhsNeedsSplit   # Range has too many keys, should split
    rhsNeedsMerge   # Range is too small, could merge with neighbor
    rhsCritical     # Range is extremely oversized (urgent split needed)

  SplitResult* = tuple
    success: bool
    leftRangeId: RangeId
    rightRangeId: RangeId
    splitKey: string

  MergeResult* = tuple
    success: bool
    mergedRangeId: RangeId
    keysMerged: int64

proc shouldSplitRange*(rangeMeta: RangeMetadata, config: RangeManagementConfig): bool =
  ## Determine if a range should be split based on configuration
  if not config.enabled or not config.autoSplit:
    return false

  # Check key count threshold
  if rangeMeta.keyCount > config.splitThresholdKeys:
    return true

  # Check hint file size (if available and threshold set)
  if config.maxRangeSizeHintMB > 0 and rangeMeta.hintPath.len > 0:
    if fileExists(rangeMeta.hintPath):
      let hintSize = getFileSize(rangeMeta.hintPath)
      let maxSizeBytes = config.maxRangeSizeHintMB * 1024 * 1024
      if hintSize > maxSizeBytes:
        return true

  false

proc shouldMergeRanges*(left: RangeMetadata, right: RangeMetadata, config: RangeManagementConfig): bool =
  ## Determine if two adjacent ranges should be merged
  ## Only merges ranges that are BOTH below the merge threshold
  if not config.enabled or not config.autoMerge:
    return false

  # Both ranges must be small enough to merge
  if left.keyCount <= config.mergeThresholdKeys and
     right.keyCount <= config.mergeThresholdKeys:
    # Check combined size wouldn't be too large
    let combinedSize = left.keyCount + right.keyCount
    if combinedSize < config.splitThresholdKeys:
      return true

  false

proc checkRangeHealth*(rangeMeta: RangeMetadata, config: RangeManagementConfig): RangeHealthStatus =
  ## Check the health of a range and return status
  if shouldSplitRange(rangeMeta, config):
    # If range is 2x over threshold, mark as critical
    if rangeMeta.keyCount > config.splitThresholdKeys * 2:
      return rhsCritical
    else:
      return rhsNeedsSplit

  # For merge checks, caller needs to provide adjacent range
  # We'll just check if this range is very small
  if rangeMeta.keyCount < config.mergeThresholdKeys div 2:
    return rhsNeedsMerge

  rhsHealthy

proc collectRangeKeys*(dataDir: string, rangeId: RangeId, accessModel: AccessModel): seq[string] =
  ## Collect all keys from a range by loading its hint file
  result = @[]

  let hintPath = getRangeHintPath(dataDir, rangeId, accessModel)
  if not fileExists(hintPath):
    return

  case accessModel
  of amHash:
    # For hash mode, load KeyDir and extract keys
    var keyDir = keydir.init()
    discard loadKeyDirFromRangeHint(hintPath, keyDir)
    for key, _ in keyDir.pairs():
      result.add(key)
    keyDir.deinit()
  of amCritBit:
    # For critbit mode, load CritBitIndex and extract keys
    let loadResult = loadCritBitHint(hintPath)
    var index = loadResult.index
    for key, _ in index.pairs():
      result.add(key)

proc calculateSplitKey*(keys: seq[string]): string =
  ## Find the optimal key to split a range
  ## Returns a key that roughly divides the set in half

  if keys.len <= 1:
    return ""  # Can't split a range with 0 or 1 key

  # Sort the keys to find median
  let sorted = keys.sorted()

  # For even number of keys, pick the key at the midpoint
  # This ensures roughly equal distribution
  let midIndex = sorted.len div 2
  result = sorted[midIndex]

proc createRangeDirectory*(dataDir: string, rangeId: RangeId, accessModel: AccessModel): bool =
  ## Create directory for a new range
  let rangeDir = getRangeDir(dataDir, accessModel)
  let rangeFileDir = rangeDir / ("range_" & $rangeId)

  try:
    if not dirExists(rangeFileDir):
      createDir(rangeFileDir)
    return true
  except OSError:
    return false

proc splitRange*(index: var RangeIndex, rangeId: RangeId, accessModel: AccessModel): SplitResult =
  ## Split a range into two ranges
  ## Returns result with new range IDs and split key

  result.success = false
  result.leftRangeId = rangeId  # Keep original ID for left half
  result.rightRangeId = RangeId(index.numRanges)  # New ID for right half

  withLock(index.lock):
    # Check if we can create a new range
    if index.numRanges >= 10000:  # Arbitrary max to prevent runaway
      echo "Warning: Maximum number of ranges reached"
      return

    # Get current range metadata
    let currentMeta = index.ranges[rangeId.int]

    # Collect all keys in the range
    let keys = collectRangeKeys(index.dataDir, rangeId, accessModel)

    if keys.len <= 1:
      echo "Warning: Cannot split range with ", keys.len, " keys"
      return

    # Calculate split key
    let splitKey = calculateSplitKey(keys)
    result.splitKey = splitKey

    # Create new range metadata
    let newRangeId = RangeId(index.numRanges)
    var newRangeMeta = RangeMetadata(
      id: newRangeId,
      keyCount: 0,
      lastAccess: getTime().toUnix(),
      hintPath: getRangeHintPath(index.dataDir, newRangeId, accessModel),
      isLoaded: false,
      isDirty: false,
      minKey: "",
      maxKey: "",
      accessModel: accessModel
    )

    # Update original range metadata
    index.ranges[rangeId.int].keyCount = 0  # Will be recalculated
    index.ranges[rangeId.int].minKey = currentMeta.minKey
    index.ranges[rangeId.int].maxKey = splitKey
    index.ranges[rangeId.int].isDirty = true

    # Add new range to index
    index.ranges.add(newRangeMeta)
    index.numRanges.inc()

    # Note: Actual key redistribution happens during hint file reload
    # The split key sets the boundary, keys will be placed in correct range
    # on next load based on computeOrderedRangeId()

    result.success = true
    result.rightRangeId = newRangeId

    index.lastModified = getTime().toUnix()

proc mergeRanges*(index: var RangeIndex, leftId: RangeId, rightId: RangeId): MergeResult =
  ## Merge two adjacent ranges into one
  ## Returns result with merged range ID

  result.success = false
  result.mergedRangeId = leftId  # Use left range ID for merged result

  # Must be adjacent ranges (rightId = leftId + 1)
  if rightId != leftId + 1:
    echo "Warning: Can only merge adjacent ranges"
    return

  withLock(index.lock):
    let leftMeta = index.ranges[leftId.int]
    let rightMeta = index.ranges[rightId.int]

    # Update left range to encompass both
    index.ranges[leftId.int].keyCount = leftMeta.keyCount + rightMeta.keyCount
    index.ranges[leftId.int].maxKey = rightMeta.maxKey
    index.ranges[leftId.int].isDirty = true

    # Remove right range from the sequence
    # Note: We're not actually deleting files, just the metadata
    # The actual data will be consolidated on next compaction
    index.ranges.delete(rightId.int)
    index.numRanges.dec()

    result.success = true
    result.keysMerged = rightMeta.keyCount
    result.mergedRangeId = leftId

    index.lastModified = getTime().toUnix()

proc processRangeManagement*(index: var RangeIndex, accessModel: AccessModel): int =
  ## Process all ranges and perform necessary splits/merges
  ## Returns number of management actions taken

  result = 0

  if not index.managementConfig.enabled:
    return

  # First pass: check for ranges needing split
  if index.managementConfig.autoSplit:
    for i in 0..<index.ranges.len:
      let rangeId = RangeId(i)
      let health = checkRangeHealth(index.ranges[i], index.managementConfig)

      if health in {rhsNeedsSplit, rhsCritical}:
        echo "Splitting range ", rangeId, " (", index.ranges[i].keyCount, " keys)"
        let splitResult = splitRange(index, rangeId, accessModel)
        if splitResult.success:
          inc(result)
          # If we split a range, skip the next range (it's the new one)
          # and recheck from beginning since indices may have shifted
          break

  # Second pass: check for ranges needing merge
  if index.managementConfig.autoMerge and result == 0:
    # Check adjacent pairs
    var i = 0
    while i < index.ranges.len - 1:
      let leftId = RangeId(i)
      let rightId = RangeId(i + 1)

      if shouldMergeRanges(index.ranges[i], index.ranges[i + 1], index.managementConfig):
        echo "Merging ranges ", leftId, " and ", rightId
        let mergeResult = mergeRanges(index, leftId, rightId)
        if mergeResult.success:
          inc(result)
          # Continue checking from current position
          continue

      inc(i)

proc getManagementStats*(index: var RangeIndex): tuple[
    totalRanges: int,
    healthyRanges: int,
    rangesNeedingSplit: int,
    rangesNeedingMerge: int,
    criticalRanges: int
  ] =
  ## Get statistics about range health across the index

  withLock(index.lock):
    result.totalRanges = index.ranges.len

    for meta in index.ranges:
      let health = checkRangeHealth(meta, index.managementConfig)

      case health
      of rhsHealthy:
        inc(result.healthyRanges)
      of rhsNeedsSplit:
        inc(result.rangesNeedingSplit)
      of rhsNeedsMerge:
        inc(result.rangesNeedingMerge)
      of rhsCritical:
        inc(result.criticalRanges)
        inc(result.rangesNeedingSplit)
