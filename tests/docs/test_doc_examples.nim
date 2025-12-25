import std/[osproc, streams]
import unittest

proc checkDocExamples(): bool =
  ## Run the doc examples checker and report result
  let command = "nim c -r --verbosity:0 tools/check_doc_examples.nim"
  let (output, exitCode) = execCmdEx(command)

  if exitCode != 0:
    echo output
    return false
  return true

suite "Doc Examples Compilation":
  test "All marked doc examples compile":
    check checkDocExamples()
