## BitBarrel Command Line Interface
##
## This module provides the main entry point for the BitBarrel server
## using standard library parseopt for argument parsing

import std/[os, parseopt, strformat, strutils, osproc, posix]
import ../bitbarrel/[config, config_parser]
import ../storage

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

proc showHelp*() =
  ## Display help information
  echo """
BitBarrel - High-Performance Bitcask Key/Value Store

USAGE:
  bitbarrel [OPTIONS] COMMAND

COMMANDS:
  server    Start the BitBarrel server
  client    Run BitBarrel client interface (coming in Phase 2)
  bench     Run benchmark tests
  test      Run all tests

OPTIONS:
  -c, --config FILE      Path to configuration file (default: bitbarrel.yaml)
  -d, --data-dir DIR     Override data directory
  -p, --port PORT        Override server port
  --log-level LEVEL      Override log level (debug, info, warn, error)
  -D, --daemon           Run as daemon
  --pid-file FILE        PID file path for daemon mode
  -h, --help             Show this help message
  -v, --version          Show version information

EXAMPLES:
  bitbarrel server                            # Start server with default config
  bitbarrel -c prod.yaml server               # Start server with custom config
  bitbarrel -d /data -p 9090 server           # Override data dir and port
  BITBARREL_SERVER_PORT=9090 bitbarrel server      # Override via environment variable
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

  for kind, key, val in getopt():
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
        try:
          result.port = parseInt(val)
        except ValueError:
          echo "Error: Port must be a number"
          quit(1)
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

  # TODO: Start actual server
  echo "Server implementation coming in Phase 2"
  echo "In the meantime, you can test using the demos:"
  echo &"  nim c -r examples/basic_demo.nim -d \"{config.storage.dataDir}\""

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
  of "server":
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