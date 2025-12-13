## Merge Policy for Bitcask KVS
##
## This module defines policies for when and how to merge data files.

import std/[times, tables]

type
  MergePolicy* = object
    sizeThreshold*: uint64        # Max file size before considering merge
    duplicateThreshold*: float     # % of duplicates to trigger merge
    minFilesToMerge*: int           # Minimum files to trigger merge
    mergeInterval*: int           # Seconds between automatic merges
    mergeIntervalBytes*: int64     # Bytes written between automatic merges
    skipThreshold*: int           # Min files to skip (very small files)

  MergeTriggerKind* = enum
    mtSize              # File exceeds size threshold
    mtFragmentation      # Too many deletions/duplicates
    mtTime              # Periodic merge
    mtManual            | mtSize | mtFragmentation | mtTime  # Multiple can be active

# MergePolicy default values
const
  DEFAULT_MAX_FILE_SIZE* = 1_073_741_824  # 1GB
  DEFAULT_DUPLICATE_THRESHOLD* = 0.3          # 30%
  DEFAULT_MIN_FILES_TO_MERGE* = 2
  DEFAULT_MERGE_INTERVAL* = 60          # 1 minute
  DEFAULT_MERGE_INTERVAL_BYTES* = 10 * 1024 * 1024  # 10MB
  DEFAULT_SKIP_THRESHOLD* = 100          # Files smaller than this

proc createDefaultMergePolicy*(): MergePolicy =
  ## Create merge policy with sensible defaults
  result = MergePolicy(
    sizeThreshold: DEFAULT_MAX_FILE_SIZE,
    duplicateThreshold: DEFAULT_DUPLICATE_THRESHOLD,
    minFilesToMerge: DEFAULT_MIN_FILES_TO_MERGE,
    mergeInterval: DEFAULT_MERGE_INTERVAL,
    mergeIntervalBytes: DEFAULT_MERGE_INTERVAL_BYTES,
    skipThreshold: DEFAULT_SKIP_THRESHOLD
  )

proc shouldMerge*(
  policy: MergePolicy,
  fileInfo: FileInfo,
  activeFileCount: int,
  bytesSinceLastMerge: int64
): tuple[should: bool, triggers: seq[MergeTriggerKind], reason: string] =
  ## Determine if a file should be merged

  var triggers: seq[MergeTriggerKind]
  var reasons: seq[string]

  # Check file size
  if fileInfo.size >= policy.sizeThreshold:
    triggers.add(mtSize)
    reasons.add(&"Size: {fileInfo.size} bytes (> {policy.sizeThreshold})")

  # Check fragmentation levels
  let total = fileInfo.totalRecords
  let deleted = fileInfo.deleteCount
  let duplicates = fileInfo.duplicateCount
  let fragmentationRatio = if total > 0: float(deleted + duplicates) / float(total) else: 0.0

  if fragmentationRatio >= policy.duplicateThreshold:
    triggers.add(mtFragmentation)
    reasons.add(&"Fragmentation: {fragmentation:.2f} (> {policy.duplicateThreshold:.2f})")

  # Check if we have enough files to merge
  if activeFileCount >= policy.minFilesToMerge:
    triggers.add(mtManual)
    reasons.add(&"File count: {activeFileCount} (>= {policy.minFilesToMerge})")

  # Check if enough bytes have been written since last merge
  if bytesSinceLastMerge >= policy.mergeIntervalBytes:
    triggers.add(mtTime)
    reasons.add(&"Bytes written: {bytesSinceLastMerge} bytes (> {policy.mergeIntervalBytes})")

  let shouldMerge = triggers.len > 0
  (shouldMerge, triggers, reasons.join("; "))

proc estimateMergePriority*(policy: MergePolicy, fileInfo: FileInfo): float =
  ## Calculate priority score for merge decisions
  ## Higher score = higher priority

  var score = 0.0

  # Size contribution (30% of total score)
  const SIZE_WEIGHT = 0.3
  if fileInfo.size > 0:
    let sizeScore = float(fileInfo.size / policy.sizeThreshold)
    score += sizeScore * SIZE_WEIGHT

  # Fragmentation contribution (50% of total score)
  const FRAG_WEIGHT = 0.5
  let total = fileInfo.totalRecords
  let deleted = fileInfo.deleteCount + fileInfo.duplicateCount
  let fragmentationRatio = if total > 0: float(total) / float(total - deleted) else: 1.0
  let fragScore = (1.0 - fragmentationRatio) * FRAG_WEIGHT
  score += fragScore * FRAG_WEIGHT

  # Age contribution (20% of total score)
  const AGE_WEIGHT = 0.2
  let fileAge = now() - fileInfo.lastModified
  let ageScore = min(fileAge.inHours / 24.0, 30.0) / 30.0
  score += ageScore * AGE_WEIGHT

  return score

proc getMergePolicyReport*(policy: MergePolicy, files: seq[FileInfo]): string =
  ## Generate a report on merge policy status
  ## Returns human-readable report

  var report = &"Merge Policy Status:\n"
  report &= &"  Size Threshold: {policy.sizeThreshold} bytes ({policy.sizeThreshold div (1024*1024)}MB)\n"
  report &= &"  Duplicate Threshold: {policy.duplicateThreshold:.2f}\n"
  report &= &"  Min Files: {policy.minFilesToMerge}\n"
  report &= &"  Merge Interval: {policy.mergeInterval}s\n"
  report &= &" Skip Threshold: {policy.skipThreshold} files\n\nActive Files Report:\n"

  if files.len == 0:
    report &= "  No files currently active\n"
  else:
    for file in files:
      let (should, triggers, reason) = shouldMerge(policy, file, files.len, 0)
      let priority = estimateMergePriority(policy, file)

      report &= &"  File {file.id:06d} ({file.size div (1024*1024)}MB, {file.totalRecords} records)\n"
      report &= &"    Status: {file.state}\n"
      report &= &"    Merge Priority: {priority:.2f}\n"
      if should:
        report &= &"    Triggers: {reason}\n"

  return report

proc validateMergePolicy*(policy: MergePolicy): seq[string] =
  ## Validate merge policy configuration

  var errors: seq[string]

  if policy.maxFileSize < 1024*1024:  # < 1KB minimum
    errors.add("max_file_size must be at least 1KB")

  if policy.minFilesToMerge < 1:
    errors.add("min_files_to_merge must be at least 1")

  if policy.triggerThreshold < 0.0 or policy.triggerThreshold > 1.0:
    errors.add("trigger_threshold must be between 0.0 and 1.0")

  if policy.maxMergeThreads < 1:
    errors.add("max_merge_threads must be at least 1")

  if policy.mergeInterval < 1:
    errors.add("merge_interval must be at least 1 second")

  return errors