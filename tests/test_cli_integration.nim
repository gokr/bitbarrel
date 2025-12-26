## BitBarrel CLI Integration Test
##
## This test starts a BitBarrel server using the CLI and runs client tests against it.
## Replaces: run_test_client.sh, test_server_process, and test_client_no_server

import unittest, os, osproc, strutils, times, net, httpclient, strformat, random
when defined(posix):
  import posix
import ../src/network/client

const SERVER_PORT = 8081
const MAX_WAIT_TIME = 15  # seconds

proc waitForServerReady(address: string, port: Port, timeout: int = MAX_WAIT_TIME): bool =
  ## Wait for server to be ready by checking HTTP endpoint
  echo "Waiting for server to be ready..."
  let client = newHttpClient()
  client.timeout = 1  # 1 second timeout for each attempt

  for i in 0..<timeout * 2:  # Check every 0.5 seconds
    try:
      let response = client.get(&"http://{address}:{port}/status")
      if response.code == Http200 and response.body.contains("\"status\"") and response.body.contains("\"ok\""):
        echo &"Server is ready (waited {float(i) / 2.0}s)"
        return true
    except:
      discard  # Server not ready yet

    sleep(500)  # Wait 500ms

  return false

proc cleanupProcess(process: Process) =
  ## Cleanup process if it's still running
  try:
    # Kill any processes on the server port (more reliable than process.terminate)
    when defined(posix):
      discard execCmd("fuser -k " & $SERVER_PORT & "/tcp 2>/dev/null || true")
      sleep(500)  # Give time for processes to die

    # Also try to terminate the process handle
    let exitCode = process.peekExitCode()
    if exitCode == -1:  # Still running
      process.terminate()
      sleep(100)
      if process.peekExitCode() == -1:
        process.kill()
  except:
    discard

suite "BitBarrel CLI Integration Tests":
  var serverProcess: Process
  var testDataDir: string

  setup:
    # Create temp directory for test data
    testDataDir = os.getTempDir() / &"bitbarrel_test_{getTime().toUnix}_{rand(10000)}"
    createDir(testDataDir)
    echo &"Test data directory: {testDataDir}"

    # Find bitbarrel binary (check common locations)
    var bitbarrelBinary = ""
    let possiblePaths = [
      "./src/cli/main",  # Direct compilation
      "./bitbarrel",     # Installed binary
      "../bitbarrel",    # Relative path
    ]

    for path in possiblePaths:
      if fileExists(path):
        bitbarrelBinary = path
        break

    if bitbarrelBinary == "":
      # Try to compile it
      echo "BitBarrel binary not found, attempting to compile..."
      let compileResult = execCmd("nim c -r src/cli/main.nim")
      if compileResult != 0:
        echo "Failed to compile bitbarrel CLI"
        quit(1)
      bitbarrelBinary = "./src/cli/main"

    # Start server using CLI
    echo "Starting BitBarrel server..."
    let serverCmd = &"{bitbarrelBinary} -d={testDataDir} -p={SERVER_PORT} serve"
    serverProcess = startProcess(
      "sh",
      args = ["-c", serverCmd],
      options = {poStdErrToStdOut, poUsePath}
    )

    # Wait for server to be ready
    if not waitForServerReady("127.0.0.1", Port(SERVER_PORT)):
      echo "ERROR: Server did not become ready in time"
      cleanupProcess(serverProcess)
      removeDir(testDataDir)
      quit(1)

    # Extra wait for WebSocket handlers to initialize
    echo "Waiting extra time for WebSocket handler..."
    sleep(5000)

  teardown:
    # Cleanup server process
    cleanupProcess(serverProcess)
    # Cleanup temp directory
    removeDir(testDataDir)
    echo "Cleanup complete"

  test "Basic connection to server":
    var client = newClient("localhost", Port(SERVER_PORT))

    client.connect()
    check client.connected

    check client.ping()

    client.close()

  test "Barrel management operations":
    var client = newClient("localhost", Port(SERVER_PORT))
    client.connect()
    defer: client.close()

    let barrelName = "test_barrel_" & $rand(10000)
    check client.createBarrel(barrelName)

    let barrels = client.listBarrels()
    check barrelName in barrels

    check client.openBarrel(barrelName)

    check client.useBarrel(barrelName)
    check client.currentBarrel == barrelName

  test "Key-value operations":
    var client = newClient("localhost", Port(SERVER_PORT))
    client.connect()
    defer: client.close()

    let barrelName = "kv_test_" & $rand(10000)
    check client.createBarrel(barrelName)
    check client.openBarrel(barrelName)
    check client.useBarrel(barrelName)

    check client.set("test_key", "test_value")

    let value = client.get("test_key")
    check value == "test_value"

    check client.exists("test_key")
    check not client.exists("nonexistent_key")

    check client.delete("test_key")
    check not client.exists("test_key")

  test "Unicode and binary data":
    var client = newClient("localhost", Port(SERVER_PORT))
    client.connect()
    defer: client.close()

    let barrelName = "unicode_test_" & $rand(10000)
    check client.createBarrel(barrelName)
    check client.openBarrel(barrelName)
    check client.useBarrel(barrelName)

    let unicodeKey = "测试_key_" & $rand(1000)
    let unicodeValue = "测试_value_" & $rand(1000)

    check client.set(unicodeKey, unicodeValue)
    check client.get(unicodeKey) == unicodeValue

    let binaryValue = "binary\0data\1with\2nulls"
    check client.set("binary_key", binaryValue)
    check client.get("binary_key") == binaryValue

  test "Error handling":
    var client = newClient("localhost", Port(SERVER_PORT))

    try:
      discard client.get("any_key")
      check false
    except CatchableError:
      check true

    client.connect()
    defer: client.close()

    try:
      discard client.get("any_key")
      check false
    except CatchableError:
      check true

    check not client.openBarrel("nonexistent_barrel_" & $rand(10000))

when isMainModule:
  echo "Running BitBarrel CLI integration tests..."
