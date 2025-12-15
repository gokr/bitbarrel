## Demo Output Utilities
## Provides consistent formatting for demo examples

import strformat
import times
import strutils

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

proc formatBytes*(bytes: int64): string =
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

proc formatDuration*(ms: int64): string =
  ## Format duration in human-readable format
  if ms < 1000:
    result = &"{ms}ms"
  elif ms < 60_000:
    result = &"{ms / 1000:.2f}s"
  else:
    let minutes = ms div 60_000
    let seconds = (ms mod 60_000) / 1000
    result = &"{minutes}m {seconds:.0f}s"

proc tableHeader*(columns: seq[string]) =
  ## Print a simple table header
  echo ""
  for col in columns:
    stdout.write &"{col:<22} "
  echo ""

proc tableRow*(values: seq[string]) =
  ## Print a simple table row
  for val in values:
    let display = if val.len > 22: val[0..<19] & "..." else: val
    stdout.write &"{display:<22} "
  echo ""

proc tableFooter*() =
  ## Print a table separator
  echo "-".repeat(66)

proc progressBar*(current: int, total: int, width: int = 30) =
  ## Print a progress bar
  let progress = current.float / total.float
  let filled = int(width.float * progress)
  let bar = "█".repeat(filled) & "░".repeat(width - filled)
  let percent = int(progress * 100)
  echo &"   [{bar}] {percent}% ({current}/{total})"

proc timestamp*(): string =
  ## Get current timestamp in readable format
  let now = getTime()
  now.format("yyyy-MM-dd HH:mm:ss")