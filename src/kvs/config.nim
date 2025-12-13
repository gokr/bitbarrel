## KVS Configuration System
##
## This module provides the main configuration types and loading logic.
## Configuration is loaded with the following precedence:
## 1. CLI arguments (highest)
## 2. Environment variables
## 3. Configuration file (YAML)
## 4. Default values (lowest)

import std/[os, strformat, strutils, tables]
import config_parser
import types

# Global configuration instance
var gConfig*: KVSConfig



proc loadFromEnvironment*(config: var KVSConfig) =
  ## Load configuration from environment variables
  ## Pattern: KVS_SECTION__SETTING
  # Server settings
  if existsEnv("KVS_SERVER__ADDRESS"):
    config.server.address = getEnv("KVS_SERVER__ADDRESS")
  if existsEnv("KVS_SERVER__PORT"):
    config.server.port = parseInt(getEnv("KVS_SERVER__PORT"))
  if existsEnv("KVS_SERVER__MAX_CONNECTIONS"):
    config.server.maxConnections = parseInt(getEnv("KVS_SERVER__MAX_CONNECTIONS"))
  if existsEnv("KVS_SERVER__TIMEOUT"):
    config.server.timeout = parseInt(getEnv("KVS_SERVER__TIMEOUT"))

  # Storage settings
  if existsEnv("KVS_STORAGE__DATA_DIR"):
    config.storage.dataDir = getEnv("KVS_STORAGE__DATA_DIR")
  if existsEnv("KVS_STORAGE__MAX_FILE_SIZE"):
    config.storage.maxFileSize = parseBiggestInt(getEnv("KVS_STORAGE__MAX_FILE_SIZE"))
  if existsEnv("KVS_STORAGE__MAX_KEY_SIZE"):
    config.storage.maxKeySize = parseInt(getEnv("KVS_STORAGE__MAX_KEY_SIZE"))
  if existsEnv("KVS_STORAGE__MAX_VALUE_SIZE"):
    config.storage.maxValueSize = parseBiggestInt(getEnv("KVS_STORAGE__MAX_VALUE_SIZE"))
  if existsEnv("KVS_STORAGE__SYNC_MODE"):
    config.storage.syncMode = parseSyncMode(getEnv("KVS_STORAGE__SYNC_MODE"))
  if existsEnv("KVS_STORAGE__FSYNC_INTERVAL"):
    config.storage.fsyncInterval = parseInt(getEnv("KVS_STORAGE__FSYNC_INTERVAL"))

  # Performance settings
  if existsEnv("KVS_PERFORMANCE__WORKER_THREADS"):
    config.performance.workerThreads = parseInt(getEnv("KVS_PERFORMANCE__WORKER_THREADS"))
  if existsEnv("KVS_PERFORMANCE__WRITE_BUFFER_SIZE"):
    config.performance.writeBufferSize = parseInt(getEnv("KVS_PERFORMANCE__WRITE_BUFFER_SIZE"))
  if existsEnv("KVS_PERFORMANCE__WRITE_BUFFER_TIMEOUT"):
    config.performance.writeBufferTimeout = parseInt(getEnv("KVS_PERFORMANCE__WRITE_BUFFER_TIMEOUT"))
  if existsEnv("KVS_PERFORMANCE__READ_AHEAD_SIZE"):
    config.performance.readAheadSize = parseInt(getEnv("KVS_PERFORMANCE__READ_AHEAD_SIZE"))
  if existsEnv("KVS_PERFORMANCE__CACHE_SIZE"):
    config.performance.cacheSize = parseInt(getEnv("KVS_PERFORMANCE__CACHE_SIZE"))

  # Merge settings
  if existsEnv("KVS_MERGE__ENABLED"):
    config.merge.enabled = parseBool(getEnv("KVS_MERGE__ENABLED"))
  if existsEnv("KVS_MERGE__TRIGGER_THRESHOLD"):
    config.merge.triggerThreshold = parseFloat(getEnv("KVS_MERGE__TRIGGER_THRESHOLD"))
  if existsEnv("KVS_MERGE__MAX_MERGE_THREADS"):
    config.merge.maxMergeThreads = parseInt(getEnv("KVS_MERGE__MAX_MERGE_THREADS"))
  if existsEnv("KVS_MERGE__MERGE_INTERVAL"):
    config.merge.mergeInterval = parseInt(getEnv("KVS_MERGE__MERGE_INTERVAL"))
  if existsEnv("KVS_MERGE__MIN_FILE_SIZE"):
    config.merge.minFileSize = parseBiggestInt(getEnv("KVS_MERGE__MIN_FILE_SIZE"))

  # Logging settings
  if existsEnv("KVS_LOGGING__LEVEL"):
    config.logging.level = getEnv("KVS_LOGGING__LEVEL")
  if existsEnv("KVS_LOGGING__FILE"):
    config.logging.file = getEnv("KVS_LOGGING__FILE")
  if existsEnv("KVS_LOGGING__MAX_SIZE"):
    config.logging.maxSize = parseBiggestInt(getEnv("KVS_LOGGING__MAX_SIZE"))
  if existsEnv("KVS_LOGGING__MAX_BACKUPS"):
    config.logging.maxBackups = parseInt(getEnv("KVS_LOGGING__MAX_BACKUPS"))
  if existsEnv("KVS_LOGGING__FORMAT"):
    config.logging.format = getEnv("KVS_LOGGING__FORMAT")

proc initConfig*(configFile: string = "kvs.yaml"): KVSConfig {.discardable.} =
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

proc getConfig*(): KVSConfig =
  ## Get the current configuration
  ## Should be called after initConfig()
  if gConfig.storage.dataDir.len == 0:
    raise newException(Exception, "Configuration not initialized. Call initConfig() first.")
  result = gConfig

proc validateConfig*(config: KVSConfig): bool =
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
  if config.merge.triggerThreshold < 0.0 or config.merge.triggerThreshold > 1.0:
    echo "Error: Merge trigger threshold must be between 0.0 and 1.0"
    result = false

  if config.merge.enabled and config.merge.maxMergeThreads < 1:
    echo "Error: Max merge threads must be positive when merge is enabled"
    result = false

# Backward compatibility - expose old constants as deprecated
{.deprecated: "Use config.storage.maxKeySize instead".}
proc getMaxKeySize*(): int =
  if gConfig.storage.maxKeySize > 0: gConfig.storage.maxKeySize
  else: 64 * 1024

{.deprecated: "Use config.storage.maxValueSize instead".}
proc getMaxValueSize*(): int =
  if gConfig.storage.maxValueSize > 0: gConfig.storage.maxValueSize
  else: 1024 * 1024