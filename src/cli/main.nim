## BitBarrel Command Line Interface
##
## This module provides the main entry point for the BitBarrel server
## using standard library parseopt for argument parsing

import std/[os, parseopt, strformat, strutils, posix, net, tables]
import ../bitbarrel/[config, config_parser]
import ../network/auth as authjwt
import ../network/server
import bench, smoketest

const BitBarrelVersion* = staticExec("cd " & currentSourcePath().parentDir().parentDir().parentDir() & " && nimble dump | grep '^version:' | cut -d'\"' -f2")

type
  CliArgs = object
    configFile: string
    dataDir: string
    port: int
    logLevel: string
    daemon: bool
    pidFile: string
    webadminPath: string
    help: bool
    version: bool
    command: string  # "server", "client", etc.

# Global server instance for signal handler
var gServer: BitBarrelServer

proc showHelp*() =
  ## Display help information
  echo """
BitBarrel - High-Performance Bitcask style Key/Value Store

USAGE:
  bitbarrel [OPTIONS] COMMAND

COMMANDS:
  init      Generate default configuration file
  serve     Start the BitBarrel server
  token     Generate JWT tokens for authentication
  bench     Run quick benchmark (100K write + 100K read test)
  test      Run basic smoke test (1K write, 500 delete verification)

OPTIONS:
  -c=FILE, --config=FILE       Path to configuration file (default: bitbarrel.yaml)
  -d=DIR, --data-dir=DIR       Override data directory
  -p=PORT, --port=PORT         Override server port
  --log-level=LEVEL            Override log level (debug, info, warn, error)
  -D, --daemon                 Run as daemon (no value needed)
  --pid-file=FILE              PID file path for daemon mode
  --webadmin-path=DIR          Path to webadmin build files (auto-enables webadmin)
  -h, --help                   Show this help message (no value needed)
  -v, --version                Show version information (no value needed)

EXAMPLES:
  bitbarrel init                             # Generate default config file
  bitbarrel serve                            # Start server with default config
  bitbarrel -c=prod.yaml serve               # Start server with custom config
  bitbarrel --config=prod.yaml serve         # Long form with equals
  bitbarrel -d=/data -p=9090 serve           # Override data dir and port
  bitbarrel -D serve                         # Daemon flag (no value needed)
  bitbarrel serve --webadmin-path=/opt/webadmin  # With webadmin
  bitbarrel token                            # Generate JWT tokens for all users
  bitbarrel -h                               # Show help (no value needed)
"""

proc showVersion*() =
  ## Display version information
  echo &"BitBarrel version {BitBarrelVersion}"

proc parseCliArgs*(): CliArgs =
  ## Parse command line arguments using parseopt
  result = CliArgs(
    configFile: "bitbarrel.yaml",
    dataDir: "",
    port: 0,
    logLevel: "",
    daemon: false,
    pidFile: "",
    webadminPath: "",
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
      of "webadmin-path":
        result.webadminPath = val
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

  if args.webadminPath.len > 0:
    config.webadmin.path = args.webadminPath
    config.webadmin.enabled = true

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

  # Convert users to auth format
  var authUsers = initTable[string, seq[authjwt.Role]]()
  for u in config.users:
    var roles: seq[authjwt.Role] = @[]
    for r in u.roles:
      roles.add(authjwt.parseRole(r))
    authUsers[u.username] = roles

  # Convert BitBarrelConfig to ServerConfig for the network module
  let serverConfig = server.ServerConfig(
    address: config.server.address,
    port: Port(config.server.port),
    dataDir: config.storage.dataDir,
    workerThreads: config.performance.workerThreads,
    auth: authjwt.AuthConfig(
      enabled: config.auth.enabled,
      secret: config.auth.secret,
      users: authUsers,
      defaultTokenExpiryHours: config.auth.defaultTokenExpiryHours
    ),
    webadminPath: config.webadmin.path,
    webadminEnabled: config.webadmin.enabled
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

proc runInit*(args: CliArgs) =
  ## Generate a default configuration file
  let configFile = args.configFile
  if fileExists(configFile):
    echo "Error: Config file already exists: ", configFile
    echo "Delete it first or choose a different file with -c=FILE"
    quit(1)

  var config = getDefaultConfig()
  saveConfigToYaml(config, configFile)
  echo "Created default configuration: ", configFile
  echo ""
  echo "To start the server:"
  echo "  bitbarrel serve"
  echo ""
  echo "To enable authentication, edit the config file and uncomment:"
  echo "  auth:"
  echo "    enabled: true"
  echo "    secret: \"your-32-char-secret-key\""

proc runToken*(args: CliArgs) =
  ## Generate JWT tokens for authenticated users
  # Load configuration
  var config = initConfig(args.configFile)

  if not config.auth.enabled:
    echo "Error: Authentication is not enabled in configuration"
    echo "Add the following to your config file to enable auth:"
    echo ""
    echo "auth:"
    echo "  enabled: true"
    echo "  secret: \"your-secret-key-32-chars-minimum\""
    echo ""
    echo "users:"
    echo "  - username: \"admin\""
    echo "    roles:"
    echo "      - \"admin\""
    quit(1)

  if config.auth.secret.len < 32:
    echo "Error: JWT secret must be at least 32 characters long"
    echo "Please set a secure secret in your configuration"
    quit(1)

  if config.users.len == 0:
    echo "Error: No users defined in configuration"
    echo "Add users to your config file:"
    echo ""
    echo "users:"
    echo "  - username: \"admin\""
    echo "    roles:"
    echo "      - \"admin\""
    echo "  - username: \"readwrite\""
    echo "    roles:"
    echo "      - \"readwrite\""
    quit(1)

  # Build AuthConfig
  var authConfig = authjwt.AuthConfig(
    enabled: true,
    secret: config.auth.secret,
    users: initTable[string, seq[authjwt.Role]](),
    defaultTokenExpiryHours: config.auth.defaultTokenExpiryHours
  )

  for user in config.users:
    var roles: seq[authjwt.Role]
    for r in user.roles:
      roles.add(authjwt.parseRole(r))
    authConfig.users[user.username] = roles

  # Generate tokens for all users
  echo "Generating JWT tokens using secret from: ", args.configFile
  echo ""

  for user in config.users:
    try:
      let token = authjwt.generateToken(authConfig, user.username)
      echo "User: ", user.username
      echo "  Roles: ", user.roles.join(", ")
      echo "  Token: ", token
      echo ""
    except authjwt.AuthError as e:
      echo "Error generating token for user '", user.username, "': ", e.msg
      quit(1)

  # Show expiry information
  if authConfig.defaultTokenExpiryHours > 0:
    echo "Token expires in ", authConfig.defaultTokenExpiryHours, " hours"


proc runBenchmark*(args: CliArgs) =
  ## Run embedded benchmark tests
  let success = runEmbeddedBench()
  if not success:
    quit(1)

proc runTests*(args: CliArgs) =
  ## Run embedded smoke test
  let success = runEmbeddedTest()
  if not success:
    quit(1)

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
  of "init":
    runInit(args)
  of "serve":
    runServer(args)
  of "token":
    runToken(args)
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