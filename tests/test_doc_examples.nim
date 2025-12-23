import std/[osproc, os]
import unittest

proc checkDocExamples(): bool =
  ## Run the doc examples checker and report result
  let process = startProcess(
    "nim",
    args = ["c", "-r", "--verbosity:0", "tools/check_doc_examples.nim"],
    options = {poUsePath}
  )

  let output = waitForOutput(process, 5.minutes)
  let exitCode = process.waitForExit()
  process.close()

  if exitCode != 0:
    echo output
    return false
  return true

suite "Doc Examples Compilation":
  test "All marked doc examples compile":
    check checkDocExamples()
