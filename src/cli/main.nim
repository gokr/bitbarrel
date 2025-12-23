## BitBarrel Command Line Interface
##
## This module provides the main entry point for the BitBarrel server
## using standard library parseopt for argument parsing

import std/[os, parseopt, strformat, strutils, osproc, posix, net]
import ../bitbarrel/[config, config_parser]
import ../network/server

type
  CliArgs = object
    configFile: string
    dataDir: string
    port: int
    logLevel: string
    daemon: bool
    pidFile: string
    help: bool
    version: bool
    command: string  # "server", "client", etc.

# Global server instance for signal handler
var gServer: BitBarrelServer

proc showHelp*() =
  ## Display help information
  echo """
BitBarrel - High-Performance Bitcask Key/Value Store

USAGE:
  bitbarrel [OPTIONS] COMMAND

COMMANDS:
  serve     Start the BitBarrel server
  client    Run BitBarrel client interface (coming in Phase 2)
  bench     Run benchmark tests
  test      Run all tests

OPTIONS:
  -c=FILE, --config=FILE      Path to configuration file (default: bitbarrel.yaml)
  -d=DIR, --data-dir=DIR      Override data directory
  -p=PORT, --port=PORT        Override server port
  --log-level=LEVEL           Override log level (debug, info, warn, error)
  -D, --daemon                Run as daemon (no value needed)
  --pid-file=FILE             PID file path for daemon mode
  -h, --help                  Show this help message (no value needed)
  -v, --version               Show version information (no value needed)

EXAMPLES:
  bitbarrel serve                            # Start server with default config
  bitbarrel -c=prod.yaml serve               # Start server with custom config
  bitbarrel --config=prod.yaml serve         # Long form with equals
  bitbarrel -d=/data -p=9090 serve           # Override data dir and port
  bitbarrel -D serve                         # Daemon flag (no value needed)
  bitbarrel -h                               # Show help (no value needed)
"""

proc showVersion*() =
  ## Display version information
  echo "BitBarrel version 0.2.0"
  echo "High-Performance Bitcask style Key/Value Store"
  echo ""

proc parseCliArgs*(): CliArgs =
  ## Parse command line arguments using parseopt
  result = CliArgs(
    configFile: "bitbarrel.yaml",
    dataDir: "",
    port: 0,
    logLevel: "",
    daemon: false,
    pidFile: "",
    help: false,
    version: false,
    command: ""
  )

  # Initialize option parser with flags that don't take values
  # Options not in shortNoVal/longNoVal automatically support = syntax for values
  var p = initOptParser(shortNoVal = {'h', 'v', 'D'}, longNoVal = @["help", "version", "daemon"])

  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      # Handle positional arguments (commands)
      if result.command == "":
        result.command = key
      else:
        echo &"Error: Unexpected argument: {key}"
        quit(1)

    of cmdLongOption, cmdShortOption:
      case key
      of "config", "c":
        result.configFile = val
      of "data-dir", "d":
        result.dataDir = val
      of "port", "p":
        result.port = parseInt(val)
      of "log-level":
        result.logLevel = val
      of "daemon", "D":
        result.daemon = true
      of "pid-file":
        result.pidFile = val
      of "help", "h":
        result.help = true
      of "version", "v":
        result.version = true
      else:
        echo &"Error: Unknown option: {key}"
        quit(1)

    of cmdEnd:
      break

proc applyCliOverrides*(config: var BitBarrelConfig, args: CliArgs) =
  ## Apply command-line argument overrides to configuration
  if args.dataDir.len > 0:
    config.storage.dataDir = args.dataDir

  if args.port > 0:
    config.server.port = args.port

  if args.logLevel.len > 0:
    config.logging.level = args.logLevel

proc runAsDaemon*(pidFile: string) =
  ## Fork process to run as daemon
  when defined(posix):
    let pid = fork()
    if pid < 0:
      echo "Error: Failed to fork process"
      quit(1)
    elif pid > 0:
      # Parent process exits
      echo &"Daemon started with PID: {pid}"
      if pidFile.len > 0:
        writeFile(pidFile, $pid)
      quit(0)

    # Child process continues
    # Create new session
    discard setsid()

    # Change working directory to root
    discard chdir("/")

    # Set umask
    discard umask(0)

    # Close standard file descriptors
    discard close(STDIN_FILENO)
    discard close(STDOUT_FILENO)
    discard close(STDERR_FILENO)
  else:
    echo "Error: Daemon mode not supported on this platform"
    quit(1)

proc runServer*(args: CliArgs) =
  ## Run the BitBarrel server
  # Initialize configuration
  var config = initConfig(args.configFile)

  # Apply CLI overrides
  applyCliOverrides(config, args)

  # Validate configuration
  if not validateConfig(config):
    echo "Error: Invalid configuration"
    quit(1)

  # Run as daemon if requested
  if args.daemon:
    runAsDaemon(args.pidFile)

  echo "Starting BitBarrel server..."
  echo &"Server: {config.server.address}:{config.server.port}"
  echo &"Data dir: {config.storage.dataDir}"
  echo &"Log level: {config.logging.level}"
  echo ""

  # Convert BitBarrelConfig to ServerConfig for the network module
  let serverConfig = server.ServerConfig(
    address: config.server.address,
    port: Port(config.server.port),
    dataDir: config.storage.dataDir,
    workerThreads: config.performance.workerThreads
  )

  # Create and start the server
  gServer = server.newServer(serverConfig)

  # Handle Ctrl+C gracefully
  proc ctrlCHook() {.noconv.} =
    echo "\nReceived interrupt signal, shutting down..."
    if gServer != nil:
      gServer.stop()
    quit(0)

  setControlCHook(ctrlCHook)

  gServer.start()

proc runClient*(args: CliArgs) =
  ## Run the BitBarrel client
  echo "Client implementation coming in Phase 2"

proc runBenchmark*(args: CliArgs) =
  ## Run benchmark tests
  echo "Running benchmark..."
  discard execCmd(&"cd {getCurrentDir()} && nimble bench")

proc runTests*(args: CliArgs) =
  ## Run all tests
  echo "Running BitBarrel tests..."
  discard execCmd(&"cd {getCurrentDir()} && nimble test")

proc main*() =
  ## Main entry point
  let args = parseCliArgs()

  # Handle help and version first
  if args.help:
    showHelp()
    quit(0)

  if args.version:
    showVersion()
    quit(0)

  # Validate command
  if args.command == "":
    echo "Error: No command specified"
    showHelp()
    quit(1)

  # Dispatch to appropriate handler
  case args.command
  of "serve":
    runServer(args)
  of "client":
    runClient(args)
  of "bench", "benchmark":
    runBenchmark(args)
  of "test":
    runTests(args)
  else:
    echo &"Error: Unknown command: {args.command}"
    showHelp()
    quit(1)

# Entry point when compiled as binary
when isMainModule:
  main()