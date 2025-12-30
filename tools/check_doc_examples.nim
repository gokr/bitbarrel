import std/[os, osproc, strutils, streams, algorithm, tables]

type
  Example = object
    file: string
    line: int
    code: string
    name: string
    language: string      # nim, python, go, dart
    needsWrap: bool

const
  SupportedLanguages = ["nim", "python", "go", "dart"]

proc findMarkdownFiles(baseDir: string): seq[string] =
  ## Find all markdown files recursively
  result = @[]
  for path in walkDirRec(baseDir, {pcFile}, {pcDir}):
    if path.endsWith(".md"):
      result.add(path)
  result.sort()

proc extractCompilableExamples(filePath: string): seq[Example] =
  ## Extract all ```lang and ```lang.compilable code blocks from a markdown file
  result = @[]
  let content = readFile(filePath)
  let lines = content.splitLines()

  var inCodeBlock = false
  var isCompilable = false
  var currentBlock: seq[string] = @[]
  var blockStartLine = 0
  var currentLang = ""

  for i, line in lines:
    if line.startsWith("```"):
      if not inCodeBlock:
        # Extract language from fence
        let fence = line.strip()
        # Check for .compilable suffix first
        for lang in SupportedLanguages:
          if fence == "```" & lang & ".compilable":
            inCodeBlock = true
            isCompilable = true
            currentLang = lang
            blockStartLine = i + 1
            currentBlock = @[]
            break
          elif fence == "```" & lang:
            inCodeBlock = true
            isCompilable = false
            currentLang = lang
            blockStartLine = i + 1
            currentBlock = @[]
            break
      else:
        inCodeBlock = false
        if currentBlock.len > 0 and isCompilable:
          let code = currentBlock.join("\n")
          let relPath = filePath.relativePath(getCurrentDir())
          result.add(Example(
            file: relPath,
            line: blockStartLine,
            code: code,
            name: relPath & ":" & $blockStartLine & " (" & currentLang & ")",
            language: currentLang,
            needsWrap: false  # Will be determined per language
          ))
        currentBlock = @[]
        isCompilable = false
        currentLang = ""
    elif inCodeBlock:
      currentBlock.add(line)

proc needsBoilerplate(code: string, language: string): bool =
  ## Determine if code snippet needs boilerplate wrapping
  case language:
  of "nim":
    # Check if it's a complete program
    return not (code.contains("import ") and
                (code.contains("proc main") or code.contains("when isMainModule")))
  of "python":
    # Check if it's a complete script or just a snippet
    return not (code.contains("import ") or code.contains("def ") or code.contains("class ")) and
           code.count('\n') < 10
  of "go":
    # Check if it has package main and main func
    return not (code.contains("package main") and code.contains("func main"))
  of "dart":
    # Check if it has main function or complete class
    return not (code.contains("void main") or code.contains("Future<void> main"))
  else:
    return false

proc getBoilerplate(language: string, code: string): string =
  ## Get appropriate boilerplate template based on language and code content
  let templateDir = getCurrentDir() / "tools" / "doc_test_templates"

  case language:
  of "python":
    # Use module wrapper for most Python examples
    let wrapperPath = templateDir / "python" / "wrapper_module.py"
    if fileExists(wrapperPath):
      let wrapper = readFile(wrapperPath)
      return wrapper.replace("{CODE_SNIPPET}", code)
    else:
      return code
  of "go":
    let wrapperPath = templateDir / "go" / "wrapper_main.go"
    if fileExists(wrapperPath):
      let wrapper = readFile(wrapperPath)
      return wrapper.replace("{CODE_SNIPPET}", code)
    else:
      return code
  of "dart":
    let wrapperPath = templateDir / "dart" / "wrapper_main.dart"
    if fileExists(wrapperPath):
      let wrapper = readFile(wrapperPath)
      return wrapper.replace("{CODE_SNIPPET}", code)
    else:
      return code
  else:
    return code

proc compileNimExample(ex: Example, tempDir: string): bool =
  ## Compile Nim example
  let fileName = ex.file.extractFilename.replace(".md", "").replace("-", "_") &
                 "_line" & $ex.line
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
      echo "  FAILED: Nim compilation error"
      echo output.strip()
      return false

    # Cleanup
    discard tryRemoveFile(tempDir / fileName)
    for ext in [".nim.c", ".nim.o", ".nim.json", ".nim.json.json"]:
      discard tryRemoveFile(tempDir / fileName & ext)
    return true
  except IOError:
    echo "  ERROR: ", getCurrentExceptionMsg()
    return false

proc compilePythonExample(ex: Example, tempDir: string): bool =
  ## Compile Python example
  let fileName = ex.file.extractFilename.replace(".md", "").replace("-", "_") &
                 "_line" & $ex.line
  let tempFile = tempDir / fileName & ".py"

  # Apply boilerplate if needed
  let codeToCheck = if ex.needsWrap: getBoilerplate("python", ex.code) else: ex.code

  try:
    writeFile(tempFile, codeToCheck)

    # Use py_compile for syntax checking
    let process = startProcess(
      "python",
      args = ["-m", "py_compile", tempFile],
      options = {poUsePath, poStdErrToStdOut}
    )

    var output = ""
    var line = ""
    while process.outputStream.readLine(line):
      output.add(line & "\n")
    let exitCode = process.waitForExit()
    process.close()

    if exitCode != 0:
      echo "  FAILED: Python syntax error"
      echo output.strip()
      return false

    # Cleanup
    discard tryRemoveFile(tempFile)
    discard tryRemoveFile(tempDir / "__pycache__")
    return true
  except IOError:
    echo "  ERROR: ", getCurrentExceptionMsg()
    return false

proc compileGoExample(ex: Example, tempDir: string): bool =
  ## Compile Go example
  let fileName = ex.file.extractFilename.replace(".md", "").replace("-", "_") &
                 "_line" & $ex.line
  let tempFile = tempDir / fileName & ".go"

  # Apply boilerplate if needed
  let codeToCheck = if ex.needsWrap: getBoilerplate("go", ex.code) else: ex.code

  try:
    writeFile(tempFile, codeToCheck)

    # For Go, just check syntax with 'go fmt'
    let process = startProcess(
      "go",
      args = ["fmt", tempFile],
      options = {poUsePath, poStdErrToStdOut}
    )

    var output = ""
    var line = ""
    while process.outputStream.readLine(line):
      output.add(line & "\n")
    let exitCode = process.waitForExit()
    process.close()

    if exitCode != 0:
      echo "  FAILED: Go fmt error"
      echo output.strip()
      return false

    # Cleanup
    discard tryRemoveFile(tempFile)
    return true
  except IOError:
    echo "  ERROR: ", getCurrentExceptionMsg()
    return false

proc compileDartExample(ex: Example, tempDir: string): bool =
  ## Compile Dart example
  let fileName = ex.file.extractFilename.replace(".md", "").replace("-", "_") &
                 "_line" & $ex.line
  let tempFile = tempDir / fileName & ".dart"

  # Apply boilerplate if needed
  let codeToCheck = if ex.needsWrap: getBoilerplate("dart", ex.code) else: ex.code

  try:
    writeFile(tempFile, codeToCheck)

    # Use dart analyze for static checking
    let process = startProcess(
      "dart",
      args = ["analyze", tempFile],
      options = {poUsePath, poStdErrToStdOut}
    )

    var output = ""
    var line = ""
    while process.outputStream.readLine(line):
      output.add(line & "\n")
    let exitCode = process.waitForExit()
    process.close()

    if exitCode != 0:
      echo "  FAILED: Dart analysis error"
      echo output.strip()
      return false

    # Cleanup
    discard tryRemoveFile(tempFile)
    return true
  except IOError:
    echo "  ERROR: ", getCurrentExceptionMsg()
    return false

proc compileExample(ex: Example, tempDir: string): bool =
  ## Dispatch to language-specific compiler
  case ex.language:
  of "nim":
    return compileNimExample(ex, tempDir)
  of "python":
    return compilePythonExample(ex, tempDir)
  of "go":
    return compileGoExample(ex, tempDir)
  of "dart":
    return compileDartExample(ex, tempDir)
  else:
    echo "  ERROR: Unsupported language: ", ex.language
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

  # Group by language for reporting
  var langCounts: CountTable[string]
  for ex in allExamples:
    if ex.name.len > 0:
      langCounts.inc(ex.language)

  echo "Found ", allExamples.len, " code blocks total"
  for lang, count in langCounts:
    echo "  ", lang, ": ", count, " compilable examples"
  echo ""

  if compilableCount == 0:
    echo "No compilable blocks found. Use ```lang.compilable to mark examples."
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
      # Check if needs wrapping
      let needsWrap = needsBoilerplate(ex.code, ex.language)

      echo "Checking: ", ex.name
      if needsWrap:
        echo "  (using boilerplate wrapper)"

      # Create a mutable copy with updated needsWrap
      var mutableEx = ex
      mutableEx.needsWrap = needsWrap

      if compileExample(mutableEx, tempDir):
        successCount += 1
        echo "  ✓ OK"
      else:
        failedCount += 1
        failedExamples.add(ex)
      echo ""

  echo "=========================================="
  echo "Summary"
  echo "=========================================="
  echo "Total compilable blocks: ", compilableCount
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
    echo "All doc examples compiled successfully!"

main()
