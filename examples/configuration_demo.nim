## Configuration Management Demo
##
## Demonstrates the KVS configuration system, showing how different
## configuration sources interact and override each other.
##
## Run with: nim c -r examples/configuration_demo.nim

import os
import strformat
import tables
import parsecfg
import strutils
import posix
import utils/demo_output

type
  KVSConfig* = object
    # Server settings
    serverAddress*: string
    serverPort*: int = 8080
    maxConnections*: int = 100
    timeout*: int = 30

    # Storage settings
    dataDir*: string = "data"
    maxFileSize*: int64 = 1073741824  # 1GB
    maxKeySize*: int = 256
    maxValueSize*: int = 1048576  # 1MB
    syncMode*: string = "normal"

    # Performance settings
    workerThreads*: int = 4
    writeBufferSize*: int = 65536  # 64KB
    readAheadSize*: int = 8192  # 8KB
    enableCache*: bool = true
    cacheSize*: int64 = 134217728  # 128MB

    # Merge settings
    mergeEnabled*: bool = true
    mergeThreshold*: float = 0.7
    minFilesToMerge*: int = 3
    maxMergeFiles*: int = 10
    mergeInterval*: int = 3600  # 1 hour

    # Recovery settings
    recoveryEnabled*: bool = true
    checkpointInterval*: int = 300  # 5 minutes
    incrementalCheckpoints*: bool = true
    onCorruption*: string = "skip"

proc loadConfigFromFile*(path: string): KVSConfig =
  ## Load configuration from YAML-like config file
  result = KVSConfig()

  if not fileExists(path):
    warning(&"Config file not found: {path}")
    return result

  info(&"Loading configuration from: {path}")

  try:
    # For simplicity, we'll parse a basic INI-like format
    let dict = loadConfig(path)

    # Server section
    if dict.hasKey("server"):
      let section = dict["server"]
      result.serverAddress = section.getOrDefault("address", "127.0.0.1")
      result.serverPort = parseInt(section.getOrDefault("port", "8080"))
      result.maxConnections = parseInt(section.getOrDefault("max_connections", "100"))
      result.timeout = parseInt(section.getOrDefault("timeout", "30"))

    # Storage section
    if dict.hasKey("storage"):
      let section = dict["storage"]
      result.dataDir = section.getOrDefault("data_dir", "data")
      result.maxFileSize = parseInt(section.getOrDefault("max_file_size", "1073741824"))
      result.maxKeySize = parseInt(section.getOrDefault("max_key_size", "256"))
      result.maxValueSize = parseInt(section.getOrDefault("max_value_size", "1048576"))
      result.syncMode = section.getOrDefault("sync_mode", "normal")

    # Performance section
    if dict.hasKey("performance"):
      let section = dict["performance"]
      result.workerThreads = parseInt(section.getOrDefault("worker_threads", "4"))
      result.writeBufferSize = parseInt(section.getOrDefault("write_buffer_size", "65536"))
      result.readAheadSize = parseInt(section.getOrDefault("read_ahead_size", "8192"))
      result.enableCache = parseBool(section.getOrDefault("enable_cache", "true"))
      result.cacheSize = parseInt(section.getOrDefault("cache_size", "134217728"))

    # Merge section
    if dict.hasKey("merge"):
      let section = dict["merge"]
      result.mergeEnabled = parseBool(section.getOrDefault("enabled", "true"))
      result.mergeThreshold = parseFloat(section.getOrDefault("threshold", "0.7"))
      result.minFilesToMerge = parseInt(section.getOrDefault("min_files_to_merge", "3"))
      result.maxMergeFiles = parseInt(section.getOrDefault("max_merge_files", "10"))
      result.mergeInterval = parseInt(section.getOrDefault("merge_interval", "3600"))

    # Recovery section
    if dict.hasKey("recovery"):
      let section = dict["recovery"]
      result.recoveryEnabled = parseBool(section.getOrDefault("enabled", "true"))
      result.checkpointInterval = parseInt(section.getOrDefault("checkpoint_interval", "300"))
      result.incrementalCheckpoints = parseBool(section.getOrDefault("incremental_checkpoints", "true"))
      result.onCorruption = section.getOrDefault("on_corruption", "skip")

    success("Configuration loaded successfully")
  except Exception as e:
    error(&"Failed to load config: {e.msg}")

proc countEnvVars(): int =
  ## Count KVS_ environment variables
  result = 0
  for key, val in envPairs():
    if key.startsWith("KVS_"):
      inc result

proc loadConfigFromEnv*(): KVSConfig =
  ## Load configuration from environment variables
  result = KVSConfig()

  info("Loading configuration from environment variables")

  # Environment variables use KVS_ prefix
  if existsEnv("KVS_SERVER_ADDRESS"):
    result.serverAddress = getEnv("KVS_SERVER_ADDRESS")
  if existsEnv("KVS_SERVER_PORT"):
    result.serverPort = parseInt(getEnv("KVS_SERVER_PORT"))
  if existsEnv("KVS_MAX_CONNECTIONS"):
    result.maxConnections = parseInt(getEnv("KVS_MAX_CONNECTIONS"))
  if existsEnv("KVS_TIMEOUT"):
    result.timeout = parseInt(getEnv("KVS_TIMEOUT"))

  if existsEnv("KVS_DATA_DIR"):
    result.dataDir = getEnv("KVS_DATA_DIR")
  if existsEnv("KVS_MAX_FILE_SIZE"):
    result.maxFileSize = parseInt(getEnv("KVS_MAX_FILE_SIZE"))
  if existsEnv("KVS_SYNC_MODE"):
    result.syncMode = getEnv("KVS_SYNC_MODE")

  if existsEnv("KVS_WORKER_THREADS"):
    result.workerThreads = parseInt(getEnv("KVS_WORKER_THREADS"))
  if existsEnv("KVS_WRITE_BUFFER_SIZE"):
    result.writeBufferSize = parseInt(getEnv("KVS_WRITE_BUFFER_SIZE"))
  if existsEnv("KVS_ENABLE_CACHE"):
    result.enableCache = parseBool(getEnv("KVS_ENABLE_CACHE"))
  if existsEnv("KVS_CACHE_SIZE"):
    result.cacheSize = parseInt(getEnv("KVS_CACHE_SIZE"))

  if existsEnv("KVS_MERGE_ENABLED"):
    result.mergeEnabled = parseBool(getEnv("KVS_MERGE_ENABLED"))
  if existsEnv("KVS_MERGE_THRESHOLD"):
    result.mergeThreshold = parseFloat(getEnv("KVS_MERGE_THRESHOLD"))

  if existsEnv("KVS_RECOVERY_ENABLED"):
    result.recoveryEnabled = parseBool(getEnv("KVS_RECOVERY_ENABLED"))
  if existsEnv("KVS_CHECKPOINT_INTERVAL"):
    result.checkpointInterval = parseInt(getEnv("KVS_CHECKPOINT_INTERVAL"))
  if existsEnv("KVS_ON_CORRUPTION"):
    result.onCorruption = getEnv("KVS_ON_CORRUPTION")

  let envCount = countEnvVars()
  if envCount > 0:
    success(&"Loaded {envCount} environment variables")
  else:
    warning("No environment variables found")

proc loadConfigWithPrecedence*(filePath: string): KVSConfig =
  ## Load configuration with proper precedence:
  ## 1. Default values
  ## 2. Configuration file
  ## 3. Environment variables
  ## 4. Command line arguments (highest precedence)

  info("Loading configuration with precedence hierarchy")

  subsectionHeader("1. Loading defaults")
  result = KVSConfig()  # Uses Nim's default values
  echo "   ✓ Loaded default configuration"

  subsectionHeader("2. Loading from file")
  let fileConfig = loadConfigFromFile(filePath)
  # Apply file config (override defaults)
  if fileConfig.serverAddress != "":
    result.serverAddress = fileConfig.serverAddress
  if fileConfig.serverPort != 0:
    result.serverPort = fileConfig.serverPort
  # ... apply all fields (simplified for demo)

  subsectionHeader("3. Loading from environment")
  let envConfig = loadConfigFromEnv()
  # Apply env config (override file)
  if envConfig.serverAddress != "":
    result.serverAddress = envConfig.serverAddress
  if envConfig.serverPort != 0:
    result.serverPort = envConfig.serverPort
  # ... apply all fields (simplified for demo)

  subsectionHeader("4. Command-line arguments (if any)")
  # In a real implementation, you'd parse command line args
  # For demo, we'll simulate it
  let args = commandLineParams()
  if "--port" in args:
    let idx = args.find("--port")
    if idx + 1 < args.len:
      result.serverPort = parseInt(args[idx + 1])
      info(&"Port overridden to {result.serverPort} from command line")

  success("Configuration loading completed with precedence")

proc printConfig*(config: KVSConfig) =
  ## Print configuration in a formatted way
  echo "\nCurrent Configuration:"
  echo "─────────────────────────────────────────────────"

  subsectionHeader("Server Settings")
  keyValue("Address", config.serverAddress)
  keyValue("Port", config.serverPort)
  keyValue("Max Connections", config.maxConnections)
  keyValue("Timeout (s)", config.timeout)

  subsectionHeader("Storage Settings")
  keyValue("Data Dir", config.dataDir)
  keyValue("Max File Size", formatBytes(config.maxFileSize))
  keyValue("Max Key Size", config.maxKeySize)
  keyValue("Max Value Size", formatBytes(config.maxValueSize))
  keyValue("Sync Mode", config.syncMode)

  subsectionHeader("Performance Settings")
  keyValue("Worker Threads", config.workerThreads)
  keyValue("Write Buffer", formatBytes(config.writeBufferSize))
  keyValue("Read Ahead", formatBytes(config.readAheadSize))
  keyValue("Cache Enabled", config.enableCache)
  keyValue("Cache Size", formatBytes(config.cacheSize))

  subsectionHeader("Merge Settings")
  keyValue("Merge Enabled", config.mergeEnabled)
  keyValue("Merge Threshold", &"{config.mergeThreshold:.1f}%")
  keyValue("Min Files to Merge", config.minFilesToMerge)
  keyValue("Max Merge Files", config.maxMergeFiles)
  keyValue("Merge Interval (s)", config.mergeInterval)

  subsectionHeader("Recovery Settings")
  keyValue("Recovery Enabled", config.recoveryEnabled)
  keyValue("Checkpoint Interval (s)", config.checkpointInterval)
  keyValue("Incremental Checkpoints", config.incrementalCheckpoints)
  keyValue("On Corruption", config.onCorruption)

proc demonstrateConfigProfiles*() =
  ## Demonstrate different configuration profiles

  subsectionHeader("Default Configuration Profile")
  let defaultConfig = KVSConfig()
  printConfig(defaultConfig)

  separator()

  subsectionHeader("Performance Configuration Profile")
  let perfConfig = loadConfigFromFile("examples/configs/performance.ini")
  info("Performance optimizations:")
  if perfConfig.writeBufferSize > defaultConfig.writeBufferSize:
    success(&"Write buffer increased: {formatBytes(perfConfig.writeBufferSize)}")
  if perfConfig.workerThreads > defaultConfig.workerThreads:
    success(&"More worker threads: {perfConfig.workerThreads}")
  if perfConfig.syncMode == "none":
    warning("Sync mode disabled for maximum performance")

  separator()

  subsectionHeader("Production Configuration Profile")
  let prodConfig = loadConfigFromFile("examples/configs/production.ini")
  info("Production safety features:")
  if prodConfig.syncMode == "full":
    success("Full sync enabled for durability")
  if prodConfig.mergeEnabled:
    success("Merge enabled for space management")
  if prodConfig.recoveryEnabled:
    success("Recovery system enabled")

proc demonstrateDynamicConfig*() =
  ## Demonstrate dynamic configuration updates

  subsectionHeader("Dynamic Configuration Updates")

  var config = KVSConfig()

  # Scenario 1: Runtime configuration change
  info("Scenario 1: Increasing cache size at runtime")
  echo &"   Current cache size: {formatBytes(config.cacheSize)}"
  config.cacheSize = config.cacheSize * 2
  echo &"   New cache size: {formatBytes(config.cacheSize)}"
  success("Cache size doubled for better performance")

  # Scenario 2: Conditional configuration based on environment
  info("Scenario 2: Adaptive configuration")
  let isProduction = getEnv("ENVIRONMENT", "development") == "production"
  if isProduction:
    config.syncMode = "full"
    config.mergeThreshold = 0.8
    info("Production mode: Enabled safety features")
  else:
    config.syncMode = "none"
    config.mergeThreshold = 0.5
    info("Development mode: Optimized for speed")

  # Scenario 3: Configuration validation
  info("Scenario 3: Configuration validation")
  var errors: seq[string]

  if config.serverPort < 1024 and config.serverPort != 80:
    errors.add("Port should be >= 1024 or 80 for HTTP")
  if config.maxKeySize > 1024:
    errors.add("Key size too large (> 1KB)")
  if config.writeBufferSize < 4096:
    errors.add("Write buffer too small (< 4KB)")

  if errors.len > 0:
    error("Configuration validation failed:")
    for err in errors:
      error(&"  - {err}")
  else:
    success("Configuration validation passed")

proc main() =
  sectionHeader("KVS Configuration Management Demo")

  subsectionHeader("Configuration Precedence Demonstration")
  let configFile = "examples/configs/default.ini"
  let config = loadConfigWithPrecedence(configFile)
  printConfig(config)

  separator()

  subsectionHeader("Configuration Profiles Comparison")
  demonstrateConfigProfiles()

  separator()

  subsectionHeader("Dynamic Configuration")
  demonstrateDynamicConfig()

  separator()

  subsectionHeader("Configuration Best Practices")
  info("✓ Use environment variables for deployment-specific settings")
  info("✓ Store secrets in environment, never in config files")
  info("✓ Version control your configuration files")
  info("✓ Validate configuration before applying")
  info("✓ Document all configuration options")

  echo "\n✨ Configuration demo completed!"

when isMainModule:
  main()