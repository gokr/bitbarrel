import std/[osproc, os, streams]
import unittest

proc checkDocExamples(): bool =
  ## Run the doc examples checker and report result
  let process = startProcess(
    "nim",
    args = ["c", "-r", "--verbosity:0", "tools/check_doc_examples.nim"],
    options = {poUsePath}
  )

  var output = ""
  var stream = process.outputStream()
  while true:
    let line = stream.readLine()
    if line.len == 0 and stream.atEnd: break
    output &= line & "\n"
  discard process.waitForExit()
  process.close()

  if output.len > 0:
    echo output
    return false
  return true

suite "Doc Examples Compilation":
  test "All marked doc examples compile":
    check checkDocExamples()
