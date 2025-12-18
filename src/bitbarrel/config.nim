## BitBarrel Configuration System
##
## This module provides the main configuration types and loading logic.
## Configuration is loaded with the following precedence:
## 1. CLI arguments (highest)
## 2. Environment variables
## 3. Configuration file (YAML)
## 4. Default values (lowest)

import std/[os, strformat, strutils]
import config_parser
import types

# Global configuration instance
var gConfig*: BitBarrelConfig



proc loadFromEnvironment*(config: var BitBarrelConfig) =
  ## Load configuration from environment variables
  ## Pattern: BITBARREL_SECTION_SETTING
  # Server settings
  if existsEnv("BITBARREL_SERVER_ADDRESS"):
    config.server.address = getEnv("BITBARREL_SERVER_ADDRESS")
  if existsEnv("BITBARREL_SERVER_PORT"):
    config.server.port = parseInt(getEnv("BITBARREL_SERVER_PORT"))
  if existsEnv("BITBARREL_SERVER_MAX_CONNECTIONS"):
    config.server.maxConnections = parseInt(getEnv("BITBARREL_SERVER_MAX_CONNECTIONS"))
  if existsEnv("BITBARREL_SERVER_TIMEOUT"):
    config.server.timeout = parseInt(getEnv("BITBARREL_SERVER_TIMEOUT"))

  # Storage settings
  if existsEnv("BITBARREL_STORAGE_DATA_DIR"):
    config.storage.dataDir = getEnv("BITBARREL_STORAGE_DATA_DIR")
  if existsEnv("BITBARREL_STORAGE_MAX_FILE_SIZE"):
    config.storage.maxFileSize = parseBiggestInt(getEnv("BITBARREL_STORAGE_MAX_FILE_SIZE"))
  if existsEnv("BITBARREL_STORAGE_MAX_KEY_SIZE"):
    config.storage.maxKeySize = parseInt(getEnv("BITBARREL_STORAGE_MAX_KEY_SIZE"))
  if existsEnv("BITBARREL_STORAGE_MAX_VALUE_SIZE"):
    config.storage.maxValueSize = parseBiggestInt(getEnv("BITBARREL_STORAGE_MAX_VALUE_SIZE"))
  if existsEnv("BITBARREL_STORAGE_SYNC_MODE"):
    config.storage.syncMode = parseSyncMode(getEnv("BITBARREL_STORAGE_SYNC_MODE"))
  if existsEnv("BITBARREL_STORAGE_FSYNC_INTERVAL"):
    config.storage.fsyncInterval = parseInt(getEnv("BITBARREL_STORAGE_FSYNC_INTERVAL"))

  # Performance settings
  if existsEnv("BITBARREL_PERFORMANCE_WORKER_THREADS"):
    config.performance.workerThreads = parseInt(getEnv("BITBARREL_PERFORMANCE_WORKER_THREADS"))
  if existsEnv("BITBARREL_PERFORMANCE_WRITE_BUFFER_SIZE"):
    config.performance.writeBufferSize = parseInt(getEnv("BITBARREL_PERFORMANCE_WRITE_BUFFER_SIZE"))
  if existsEnv("BITBARREL_PERFORMANCE_WRITE_BUFFER_TIMEOUT"):
    config.performance.writeBufferTimeout = parseInt(getEnv("BITBARREL_PERFORMANCE_WRITE_BUFFER_TIMEOUT"))
  if existsEnv("BITBARREL_PERFORMANCE_READ_AHEAD_SIZE"):
    config.performance.readAheadSize = parseInt(getEnv("BITBARREL_PERFORMANCE_READ_AHEAD_SIZE"))
  if existsEnv("BITBARREL_PERFORMANCE_CACHE_SIZE"):
    config.performance.cacheSize = parseInt(getEnv("BITBARREL_PERFORMANCE_CACHE_SIZE"))

  # Compact settings
  if existsEnv("BITBARREL_COMPACT_ENABLED"):
    config.compact.enabled = parseBool(getEnv("BITBARREL_COMPACT_ENABLED"))
  if existsEnv("BITBARREL_COMPACT_TRIGGER_THRESHOLD"):
    config.compact.triggerThreshold = parseFloat(getEnv("BITBARREL_COMPACT_TRIGGER_THRESHOLD"))
  if existsEnv("BITBARREL_COMPACT_COMPACT_INTERVAL"):
    config.compact.compactInterval = parseInt(getEnv("BITBARREL_COMPACT_COMPACT_INTERVAL"))
  if existsEnv("BITBARREL_COMPACT_COMPACT_INTERVAL_BYTES"):
    config.compact.compactIntervalBytes = parseBiggestInt(getEnv("BITBARREL_COMPACT_COMPACT_INTERVAL_BYTES"))
  if existsEnv("BITBARREL_COMPACT_MAX_FILE_SIZE"):
    config.compact.maxFileSize = parseBiggestInt(getEnv("BITBARREL_COMPACT_MAX_FILE_SIZE")).uint64

  # Recovery settings
  if existsEnv("BITBARREL_RECOVERY_ENABLED"):
    config.recovery.enabled = parseBool(getEnv("BITBARREL_RECOVERY_ENABLED"))
  if existsEnv("BITBARREL_RECOVERY_VALIDATE_CHECKSUMS"):
    config.recovery.validateChecksums = parseBool(getEnv("BITBARREL_RECOVERY_VALIDATE_CHECKSUMS"))
  if existsEnv("BITBARREL_RECOVERY_SKIP_CORRUPT_RECORDS"):
    config.recovery.skipCorruptRecords = parseBool(getEnv("BITBARREL_RECOVERY_SKIP_CORRUPT_RECORDS"))
  if existsEnv("BITBARREL_RECOVERY_CHECKPOINT_INTERVAL"):
    config.recovery.checkpointInterval = parseInt(getEnv("BITBARREL_RECOVERY_CHECKPOINT_INTERVAL"))
  if existsEnv("BITBARREL_RECOVERY_CHECKPOINT_SIZE_THRESHOLD"):
    config.recovery.checkpointSizeThreshold = parseBiggestInt(getEnv("BITBARREL_RECOVERY_CHECKPOINT_SIZE_THRESHOLD"))
  if existsEnv("BITBARREL_RECOVERY_MAX_INCREMENTAL_CHECKPOINTS"):
    config.recovery.maxIncrementalCheckpoints = parseInt(getEnv("BITBARREL_RECOVERY_MAX_INCREMENTAL_CHECKPOINTS"))
  if existsEnv("BITBARREL_RECOVERY_AUTO_RECOVERY"):
    config.recovery.autoRecovery = parseBool(getEnv("BITBARREL_RECOVERY_AUTO_RECOVERY"))

  # Logging settings
  if existsEnv("BITBARREL_LOGGING_LEVEL"):
    config.logging.level = getEnv("BITBARREL_LOGGING_LEVEL")
  if existsEnv("BITBARREL_LOGGING_FILE"):
    config.logging.file = getEnv("BITBARREL_LOGGING_FILE")
  if existsEnv("BITBARREL_LOGGING_MAX_SIZE"):
    config.logging.maxSize = parseBiggestInt(getEnv("BITBARREL_LOGGING_MAX_SIZE"))
  if existsEnv("BITBARREL_LOGGING_MAX_BACKUPS"):
    config.logging.maxBackups = parseInt(getEnv("BITBARREL_LOGGING_MAX_BACKUPS"))
  if existsEnv("BITBARREL_LOGGING_FORMAT"):
    config.logging.format = getEnv("BITBARREL_LOGGING_FORMAT")

proc initConfig*(configFile: string = "bitbarrel.yaml"): BitBarrelConfig {.discardable.} =
  ## Initialize configuration with the specified file
  ## Returns the loaded config and stores it in global variable

  # Start with defaults
  result = getDefaultConfig()

  # Load from YAML file if it exists
  if fileExists(configFile):
    try:
      result = loadConfigFromYaml(configFile)
    except Exception as e:
      echo &"Warning: Failed to load config from {configFile}: {e.msg}"
      echo "Using default configuration values"

  # Override with environment variables
  loadFromEnvironment(result)

  # Store in global variable for easy access
  gConfig = result

proc getConfig*(): BitBarrelConfig =
  ## Get the current configuration
  ## Should be called after initConfig()
  if gConfig.storage.dataDir.len == 0:
    raise newException(Exception, "Configuration not initialized. Call initConfig() first.")
  result = gConfig

proc validateConfig*(config: BitBarrelConfig): bool =
  ## Validate configuration values
  result = true

  # Validate server settings
  if config.server.port < 1 or config.server.port > 65535:
    echo "Error: Server port must be between 1 and 65535"
    result = false

  if config.server.maxConnections < 1:
    echo "Error: Max connections must be positive"
    result = false

  # Validate storage settings
  if config.storage.maxKeySize < 1:
    echo "Error: Max key size must be positive"
    result = false

  if config.storage.maxValueSize < 1:
    echo "Error: Max value size must be positive"
    result = false

  if config.storage.fsyncInterval < 1:
    echo "Error: Fsync interval must be positive"
    result = false

  # Validate performance settings
  if config.performance.workerThreads < 1:
    echo "Error: Worker threads must be positive"
    result = false

  # Validate merge settings
  # Note: Merge config doesn't exist in BitBarrelConfig - commenting out
  # if config.merge.triggerThreshold < 0.0 or config.merge.triggerThreshold > 1.0:
  #   echo "Error: Merge trigger threshold must be between 0.0 and 1.0"
  #   result = false

  # if config.merge.enabled and config.merge.maxMergeThreads < 1:
  #   echo "Error: Max merge threads must be positive when merge is enabled"
  #   result = false

