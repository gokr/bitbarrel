## YAML Configuration Parser
##
## This module handles loading and parsing YAML configuration files

import std/[os, streams, strformat, strutils, tables]
import yaml
import types
import ../storage/compression

# Forward declare configuration types to avoid circular imports
type
  ServerConfig* = object
    address*: string
    port*: int
    maxConnections*: int
    timeout*: int

  StorageConfig* = object
    dataDir*: string
    maxFileSize*: int64
    maxKeySize*: int
    maxValueSize*: int64
    syncMode*: SyncMode
    fsyncInterval*: int
    compression*: CompressionConfig

  PerformanceConfig* = object
    workerThreads*: int
    writeBufferSize*: int
    writeBufferTimeout*: int
    readAheadSize*: int
    cacheSize*: int

  CompactConfig* = object
    enabled*: bool
    triggerThreshold*: float
    compactInterval*: int
    compactIntervalBytes*: int64
    maxFileSize*: uint64

  LoggingConfig* = object
    level*: string
    file*: string
    maxSize*: int64
    maxBackups*: int
    format*: string

  BitBarrelConfig* = object
    server*: ServerConfig
    storage*: StorageConfig
    performance*: PerformanceConfig
    compact*: CompactConfig
    recovery*: RecoveryConfig
    logging*: LoggingConfig

# YAML field access helpers - works with YamlNode.fields (TableRef[YamlNode, YamlNode])
proc getYamlString*(fields: TableRef[yaml.YamlNode, yaml.YamlNode], key: string, default: string = ""): string =
  for k, v in fields.pairs:
    if k.content == key and v.kind == yScalar:
      return v.content
  return default

proc getYamlInt*(fields: TableRef[yaml.YamlNode, yaml.YamlNode], key: string, default: int): int =
  for k, v in fields.pairs:
    if k.content == key and v.kind == yScalar:
      try:
        return parseInt(v.content)
      except:
        return default
  return default

proc getYamlInt64*(fields: TableRef[yaml.YamlNode, yaml.YamlNode], key: string, default: int64): int64 =
  for k, v in fields.pairs:
    if k.content == key and v.kind == yScalar:
      try:
        let content = v.content.toLowerAscii()
        if content.endswith("gb"):
          let numStr = content[0..^3]
          return parseBiggestInt(numStr) * 1024 * 1024 * 1024
        elif content.endswith("mb"):
          let numStr = content[0..^3]
          return parseBiggestInt(numStr) * 1024 * 1024
        elif content.endswith("kb"):
          let numStr = content[0..^3]
          return parseBiggestInt(numStr) * 1024
        else:
          return parseBiggestInt(content)
      except:
        return default
  return default

proc getYamlBool*(fields: TableRef[yaml.YamlNode, yaml.YamlNode], key: string, default: bool): bool =
  for k, v in fields.pairs:
    if k.content == key and v.kind == yScalar:
      let content = v.content.toLowerAscii()
      return content == "true" or content == "yes" or content == "1"
  return default

proc getYamlFloat*(fields: TableRef[yaml.YamlNode, yaml.YamlNode], key: string, default: float): float =
  for k, v in fields.pairs:
    if k.content == key and v.kind == yScalar:
      try:
        return parseFloat(v.content)
      except:
        return default
  return default

proc parseSyncMode*(s: string): SyncMode =
  ## Parse sync mode from string
  case s.toLowerAscii():
    of "immediate": result = syncImmediate
    of "buffered": result = syncBuffered
    of "batched": result = syncBatched
    of "time_based", "timebased": result = syncTimeBased
    else:
      raise newException(ValueError, &"Invalid sync mode: {s}")

proc parseServerConfig*(yamlNode: YamlNode): ServerConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Server config must be a mapping")

  let fields = yamlNode.fields
  result.address = getYamlString(fields, "address", "0.0.0.0")
  result.port = getYamlInt(fields, "port", 8080)
  result.maxConnections = getYamlInt(fields, "max_connections", 10000)
  result.timeout = getYamlInt(fields, "timeout", 30000)

proc parseCompressionLevel(s: string): CompressionLevel =
  case s.toLowerAscii():
    of "fast": result = clFast
    of "best": result = clBest
    else: result = clDefault

proc parseStorageConfig*(yamlNode: YamlNode): StorageConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Storage config must be a mapping")

  let fields = yamlNode.fields
  result.dataDir = getYamlString(fields, "data_dir", "./data")
  result.maxFileSize = getYamlInt64(fields, "max_file_size", 1024 * 1024 * 1024)
  result.maxKeySize = getYamlInt64(fields, "max_key_size", 64 * 1024)
  result.maxValueSize = getYamlInt64(fields, "max_value_size", 1024 * 1024)

  let syncMode = getYamlString(fields, "sync_mode", "immediate")
  result.syncMode = parseSyncMode(syncMode)

  result.fsyncInterval = getYamlInt(fields, "fsync_interval", 100)

  # Parse compression configuration if present
  var foundCompression = false
  var compressionNode: YamlNode
  for k, v in fields.pairs:
    if k.content == "compression":
      compressionNode = v
      foundCompression = true
      break

  if foundCompression and compressionNode.kind == yMapping:
    let compFields = compressionNode.fields
    result.compression.enabled = getYamlBool(compFields, "enabled", false)
    result.compression.threshold = getYamlInt(compFields, "threshold", 256)
    let levelStr = getYamlString(compFields, "level", "default")
    result.compression.level = parseCompressionLevel(levelStr)
  else:
    # Default compression configuration
    result.compression.enabled = compressionEnabled  # Based on compile-time flag
    result.compression.threshold = 256
    result.compression.level = clDefault

proc parsePerformanceConfig*(yamlNode: YamlNode): PerformanceConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Performance config must be a mapping")

  let fields = yamlNode.fields
  result.workerThreads = getYamlInt(fields, "worker_threads", 4)
  result.writeBufferSize = getYamlInt(fields, "write_buffer_size", 1000)
  result.writeBufferTimeout = getYamlInt(fields, "write_buffer_timeout", 10)
  result.readAheadSize = getYamlInt(fields, "read_ahead_size", 64)
  result.cacheSize = getYamlInt(fields, "cache_size", 256)

proc parseCompactConfig*(yamlNode: YamlNode): CompactConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Compact config must be a mapping")

  let fields = yamlNode.fields
  result.enabled = getYamlBool(fields, "enabled", true)
  result.triggerThreshold = getYamlFloat(fields, "trigger_threshold", 0.3)
  result.compactInterval = getYamlInt(fields, "compact_interval", 60)
  result.compactIntervalBytes = getYamlInt64(fields, "compact_interval_bytes", 10 * 1024 * 1024)
  result.maxFileSize = getYamlInt64(fields, "max_file_size", 1024 * 1024 * 1024).uint64

proc parseRecoveryConfig*(yamlNode: YamlNode): RecoveryConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Recovery config must be a mapping")

  let fields = yamlNode.fields
  result.enabled = getYamlBool(fields, "enabled", true)
  result.validateChecksums = getYamlBool(fields, "validate_checksums", true)
  result.skipCorruptRecords = getYamlBool(fields, "skip_corrupt_records", true)
  result.checkpointInterval = getYamlInt(fields, "checkpoint_interval", 300)  # 5 minutes
  result.checkpointSizeThreshold = getYamlInt64(fields, "checkpoint_size_threshold", 10 * 1024 * 1024)  # 10MB
  result.maxIncrementalCheckpoints = getYamlInt(fields, "max_incremental_checkpoints", 5)
  result.autoRecovery = getYamlBool(fields, "auto_recovery", true)

proc parseLoggingConfig*(yamlNode: YamlNode): LoggingConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Logging config must be a mapping")

  let fields = yamlNode.fields
  result.level = getYamlString(fields, "level", "info")
  result.file = getYamlString(fields, "file", "barrel.log")
  result.maxSize = getYamlInt64(fields, "max_size", 100 * 1024 * 1024)
  result.maxBackups = getYamlInt(fields, "max_backups", 5)
  result.format = getYamlString(fields, "format", "text")

proc getDefaultConfig*(): BitBarrelConfig =
  ## Get default configuration values
  result = BitBarrelConfig(
    server: ServerConfig(
      address: "0.0.0.0",
      port: 8080,
      maxConnections: 10000,
      timeout: 30000
    ),
    storage: StorageConfig(
      dataDir: "./data",
      maxFileSize: 1024 * 1024 * 1024,  # 1GB
      maxKeySize: 64 * 1024,            # 64KB
      maxValueSize: 1024 * 1024,        # 1MB
      syncMode: syncImmediate,
      fsyncInterval: 100
    ),
    performance: PerformanceConfig(
      workerThreads: 4,
      writeBufferSize: 1000,
      writeBufferTimeout: 10,
      readAheadSize: 64,
      cacheSize: 256
    ),
    compact: CompactConfig(
      enabled: true,
      triggerThreshold: 0.3,
      compactInterval: 60,
      compactIntervalBytes: 10 * 1024 * 1024,  # 10MB
      maxFileSize: 1024 * 1024 * 1024  # 1GB
    ),
    recovery: RecoveryConfig(
      enabled: true,
      validateChecksums: true,
      skipCorruptRecords: true,
      checkpointInterval: 300,  # 5 minutes
      checkpointSizeThreshold: 10 * 1024 * 1024,  # 10MB
      maxIncrementalCheckpoints: 5,
      autoRecovery: true
    ),
    logging: LoggingConfig(
      level: "info",
      file: "barrel.log",
      maxSize: 100 * 1024 * 1024,  # 100MB
      maxBackups: 5,
      format: "text"
    )
  )

proc loadConfigFromYaml*(filePath: string): BitBarrelConfig =
  ## Load configuration from a YAML file
  if not fileExists(filePath):
    raise newException(IOError, &"Configuration file not found: {filePath}")

  var yamlStream = newFileStream(filePath, fmRead)
  if yamlStream == nil:
    raise newException(IOError, &"Could not open config file: {filePath}")

  try:
    var yamlRoot: YamlNode
    load(yamlStream, yamlRoot)
    yamlStream.close()

    if yamlRoot.kind != yMapping:
      raise newException(ValueError, "Root of configuration must be a mapping")

    # Start with defaults
    result = getDefaultConfig()

    # Parse configuration sections
    for key, value in yamlRoot.fields.pairs:
      case key.content
      of "server": result.server = parseServerConfig(value)
      of "storage": result.storage = parseStorageConfig(value)
      of "performance": result.performance = parsePerformanceConfig(value)
      of "compact": result.compact = parseCompactConfig(value)
      of "recovery": result.recovery = parseRecoveryConfig(value)
      of "logging": result.logging = parseLoggingConfig(value)
      else: discard

  except Exception as e:
    raise newException(ValueError, &"Error parsing YAML config: {e.msg}")
  finally:
    yamlStream.close()

proc saveConfigToYaml*(config: BitBarrelConfig, filePath: string) =
  ## Save configuration to a YAML file
  let stream = newFileStream(filePath, fmWrite)
  if stream == nil:
    raise newException(IOError, &"Could not create config file: {filePath}")

  try:
    stream.write("# BitBarrel Configuration File\n")
    stream.write("# All values have reasonable defaults\n\n")

    # Write server config
    stream.write("[server]\n")
    stream.write(&"address = \"{config.server.address}\"\n")
    stream.write(&"port = {config.server.port}\n")
    stream.write(&"max_connections = {config.server.maxConnections}\n")
    stream.write(&"timeout = {config.server.timeout}  # 30 seconds\n\n")

    # Write storage config
    stream.write("[storage]\n")
    stream.write(&"data_dir = \"{config.storage.dataDir}\"\n")
    stream.write(&"max_file_size = {config.storage.maxFileSize}  # {config.storage.maxFileSize div (1024*1024)}MB\n")
    stream.write(&"max_key_size = {config.storage.maxKeySize}  # {config.storage.maxKeySize div 1024}KB\n")
    stream.write(&"max_value_size = {config.storage.maxValueSize}  # {config.storage.maxValueSize div (1024*1024)}MB\n")
    stream.write(&"sync_mode = \"{config.storage.syncMode}\"\n")
    stream.write(&"fsync_interval = {config.storage.fsyncInterval}  # ms\n\n")

    # Write performance config
    stream.write("[performance]\n")
    stream.write(&"worker_threads = {config.performance.workerThreads}\n")
    stream.write(&"write_buffer_size = {config.performance.writeBufferSize}\n")
    stream.write(&"write_buffer_timeout = {config.performance.writeBufferTimeout}    # ms\n")
    stream.write(&"read_ahead_size = {config.performance.readAheadSize}         # KB\n")
    stream.write(&"cache_size = {config.performance.cacheSize}             # MB\n\n")

    # Write merge config
    # Note: Merge config fields don't exist in BitBarrelConfig - commenting out
    # stream.write("[merge]\n")
    # stream.write(&"enabled = {config.merge.enabled}\n")
    # stream.write(&"trigger_threshold = {config.merge.triggerThreshold}      # {config.merge.triggerThreshold * 100}% fragmentation\n")
    # stream.write(&"max_merge_threads = {config.merge.maxMergeThreads}\n")
    # stream.write(&"merge_interval = {config.merge.mergeInterval}          # minutes\n")
    # stream.write(&"min_file_size = {config.merge.minFileSize}      # {config.merge.minFileSize div (1024*1024)}MB\n\n")

    # Write logging config
    stream.write("[logging]\n")
    stream.write(&"level = \"{config.logging.level}\"               # debug, info, warn, error\n")
    stream.write(&"file = \"{config.logging.file}\"\n")
    stream.write(&"max_size = {config.logging.maxSize}         # {config.logging.maxSize div (1024*1024)}MB\n")
    stream.write(&"max_backups = {config.logging.maxBackups}\n")
    stream.write(&"format = \"{config.logging.format}\"              # text or json\n")

  finally:
    stream.close()