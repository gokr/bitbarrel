## Standalone BitBarrel network server

import std/[os, strformat, parseopt]
import network/server
import bitbarrel/types

proc printUsage() =
  echo """BitBarrel Network Server

Usage:
  bitbarrel_server [options]

Options:
  --address, -a    Bind address (default: 0.0.0.0)
  --port, -p        Port number (default: 9876)
  --dataDir, -d     Data directory (default: ./data)
  --threads, -t     Number of worker threads (default: CPU count * 10)
  --help, -h       Show this help

Examples:
  bitbarrel_server
  bitbarrel_server --port 8080 --dataDir /var/lib/bitbarrel
  bitbarrel_server --address 127.0.0.1 --port 1234"""

when isMainModule:
  var config = ServerConfig(
    address: "0.0.0.0",
    port: Port(9876),
    dataDir: "data",
    workerThreads: 0  # Auto-detect
  )

  var p = initOptParser(commandLineParams())

  while true:
    case p.nextKind:
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key:
      of "help", "h":
        printUsage()
        quit(0)
      of "address", "a":
        config.address = p.val
      of "port", "p":
        config.port = Port(parseInt(p.val))
      of "dataDir", "d":
        config.dataDir = p.val
      of "threads", "t":
        config.workerThreads = parseInt(p.val)
      else:
        echo &"Unknown option: {p.key}"
        printUsage()
        quit(1)
    of cmdArgument:
      echo &"Unexpected argument: {p.key}"
      printUsage()
      quit(1)

  # Create absolute path for data dir
  config.dataDir = config.dataDir.absolutePath()

  # Create and start server
  var server = newServer(config)

  # Handle Ctrl+C gracefully
  proc ctrlcHandler() {.noconv.} =
    echo "\nReceived interrupt signal, shutting down..."
    server.stop()
    quit(0)

  setControlCHook(ctrlcHandler)

  try:
    server.start()
  except KeyboardInterrupt:
    echo "\nShutdown requested"
  finally:
    server.stop()