## Demo Utilities
## Common utility functions for KVS examples

import strformat
import strutils
import times

proc sectionHeader*(title: string, width: int = 54) =
  ## Print a section header with the given title
  let padding = width - title.len - 4
  let leftPad = padding div 2
  let rightPad = padding - leftPad

  echo "╔" & "═".repeat(width) & "╗"
  echo "║" & " ".repeat(leftPad) & title & " ".repeat(rightPad) & "║"
  echo "╚" & "═".repeat(width) & "╝"

proc subsectionHeader*(title: string) =
  ## Print a subsection header
  echo ""
  echo "▶ " & title

proc success*(message: string) =
  ## Print a success message
  echo "   ✅ " & message

proc error*(message: string) =
  ## Print an error message
  echo "   ❌ " & message

proc info*(message: string) =
  ## Print an info message
  echo "   ℹ️  " & message

proc warning*(message: string) =
  ## Print a warning message
  echo "   ⚠️  " & message

proc keyValue*(key: string, value: string, padding: int = 20) =
  ## Print a key-value pair with alignment
  let paddedKey = key & " ".repeat(max(0, padding - key.len))
  echo &"   {paddedKey}: {value}"

proc keyValue*(key: string, value: int, padding: int = 20) =
  ## Print a key-value pair with int value
  keyValue(key, $value, padding)

proc keyValue*(key: string, value: int64, padding: int = 20) =
  ## Print a key-value pair with int64 value
  keyValue(key, $value, padding)

proc keyValue*(key: string, value: bool, padding: int = 20) =
  ## Print a key-value pair with bool value
  keyValue(key, $value, padding)

proc separator*() =
  ## Print a separator line
  echo ""
  echo "─".repeat(56)

proc formatSize*(bytes: int64): string =
  ## Format bytes in human-readable format
  const units = ["B", "KB", "MB", "GB", "TB"]
  var size = bytes.float
  var unitIndex = 0

  while size >= 1024.0 and unitIndex < units.len - 1:
    size /= 1024.0
    unitIndex += 1

  if unitIndex == 0:
    result = &"{bytes} {units[unitIndex]}"
  else:
    result = &"{size:.2f} {units[unitIndex]}"

type
  Timer* = object
    startTime: int64
    measurements: seq[int64]

proc startTimer*(): Timer =
  ## Start a new timer
  result = Timer(
    startTime: int64(cpuTime() * 1000),
    measurements: @[]
  )

proc stop*(timer: var Timer) =
  ## Stop the timer and record measurement
  let elapsed = int64(cpuTime() * 1000) - timer.startTime
  if elapsed == 0:
    timer.measurements.add(1)  # Minimum 1ms to avoid division by zero
  else:
    timer.measurements.add(elapsed)

proc elapsed*(timer: Timer): int64 =
  ## Get elapsed time in milliseconds
  if timer.measurements.len > 0:
    result = timer.measurements[^1]
  else:
    let elapsed = int64(cpuTime() * 1000) - timer.startTime
    result = if elapsed == 0: 1 else: elapsed