import std/[os, osproc, strutils, streams, algorithm]

type
  Example = object
    file: string
    line: int
    code: string
    name: string

proc findMarkdownFiles(baseDir: string): seq[string] =
  ## Find all markdown files recursively
  result = @[]
  for path in walkDirRec(baseDir, {pcFile}, {pcDir}):
    if path.endsWith(".md"):
      result.add(path)
  result.sort()

proc extractCompilableExamples(filePath: string): seq[Example] =
  ## Extract all ```nim and ```nim.compilable code blocks from a markdown file
  result = @[]
  let content = readFile(filePath)
  let lines = content.splitLines()

  var inCodeBlock = false
  var isCompilable = false
  var currentBlock: seq[string] = @[]
  var blockStartLine = 0

  for i, line in lines:
    if line.startsWith("```"):
      if not inCodeBlock:
        # Check for compilable first (must match exact pattern)
        if line.strip() == "```nim.compilable":
          inCodeBlock = true
          isCompilable = true
          blockStartLine = i + 1
          currentBlock = @[]
        elif line.strip() == "```nim":
          inCodeBlock = true
          isCompilable = false
          blockStartLine = i + 1
          currentBlock = @[]
      else:
        inCodeBlock = false
        if currentBlock.len > 0:
          let code = currentBlock.join("\n")
          let relPath = filePath.relativePath(getCurrentDir())
          result.add(Example(
            file: relPath,
            line: blockStartLine,
            code: code,
            name: if isCompilable: relPath & ":" & $blockStartLine else: ""
          ))
        currentBlock = @[]
        isCompilable = false
    elif inCodeBlock:
      currentBlock.add(line)

proc compileExample(ex: Example, tempDir: string): bool =
  ## Try to compile a code block and return true if successful
  let fileName = extractFilename(ex.file).replace(".md", "").replace("-", "_") & "_line" & $ex.line
  let tempFile = tempDir / fileName & ".nim"

  try:
    writeFile(tempFile, ex.code)

    let process = startProcess(
      "nim",
      args = ["c", "--verbosity:0", "--path:src", tempFile],
      options = {poUsePath, poStdErrToStdOut}
    )

    var output = ""
    var line = ""
    while process.outputStream.readLine(line):
      output.add(line & "\n")
    let exitCode = process.waitForExit()
    process.close()

    if exitCode != 0:
      echo "  FAILED: ", output.strip()
      return false

    # Remove compiled files on success
    discard tryRemoveFile(tempDir / fileName)
    discard tryRemoveFile(tempDir / fileName & ".nim.c")
    discard tryRemoveFile(tempDir / fileName & ".nim.o")
    discard tryRemoveFile(tempDir / fileName & ".nim.json.json")
    discard tryRemoveFile(tempDir / fileName & ".nim.json")
    return true
  except IOError:
    echo "  ERROR: ", getCurrentExceptionMsg()
    return false

proc main() =
  echo "=========================================="
  echo "Checking Doc Examples Compilation"
  echo "=========================================="
  echo ""

  let baseDir = getCurrentDir()
  let mdFiles = findMarkdownFiles(baseDir)

  echo "Found ", mdFiles.len, " markdown files"
  echo ""

  var allExamples: seq[Example] = @[]
  var compilableCount = 0

  for mdFile in mdFiles:
    let examples = extractCompilableExamples(mdFile)
    allExamples.add(examples)
    for ex in examples:
      if ex.name.len > 0:
        compilableCount += 1

  echo "Found ", allExamples.len, " Nim code blocks total"
  echo "Found ", compilableCount, " marked as compilable (nim.compilable)"
  echo ""

  if compilableCount == 0:
    echo "No compilable blocks found. Use ```nim.compilable to mark examples."
    echo "Goodbye!"
    return

  # Create temp directory
  let tempDir = getTempDir() / "bitbarrel_doc_check"
  createDir(tempDir)
  defer:
    # Cleanup temp directory
    removeDir(tempDir)

  var successCount = 0
  var failedCount = 0
  var failedExamples: seq[Example] = @[]

  for ex in allExamples:
    if ex.name.len > 0:
      echo "Checking: ", ex.name
      if compileExample(ex, tempDir):
        successCount += 1
        echo "  ✓ OK"
      else:
        failedCount += 1
        failedExamples.add(ex)
      echo ""

  echo "=========================================="
  echo "Summary"
  echo "=========================================="
  echo "Compilable blocks: ", compilableCount
  echo "Passed: ", successCount
  echo "Failed: ", failedCount
  echo ""

  if failedCount > 0:
    echo "Failed examples:"
    for ex in failedExamples:
      echo "  - ", ex.name
    echo ""
    quit(1)
  else:
    echo "All doc examples compile successfully!"

main()
