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

  LoggingConfig* = object
    level*: string
    file*: string
    maxSize*: int64
    maxBackups*: int
    format*: string

  AuthConfig* = object
    enabled*: bool
    secret*: string
    defaultTokenExpiryHours*: int

  UserConfig* = object
    username*: string
    roles*: seq[string]

  WebadminConfig* = object
    enabled*: bool
    path*: string

  PubSubConfig* = object
    maxTopics*: int
    maxSubscriptionsPerClient*: int
    heartbeatTimeoutMs*: int

  BitBarrelConfig* = object
    server*: ServerConfig
    serverId*: string
    storage*: StorageConfig
    performance*: PerformanceConfig
    compact*: CompactConfig
    recovery*: RecoveryConfig
    logging*: LoggingConfig
    auth*: AuthConfig
    users*: seq[UserConfig]
    webadmin*: WebadminConfig
    pubsub*: PubSubConfig

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
  result.port = getYamlInt(fields, "port", 9876)
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
  result.maxValueSize = getYamlInt64(fields, "max_value_size", 32 * 1024 * 1024)

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

proc parseAuthConfig*(yamlNode: YamlNode): AuthConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Auth config must be a mapping")

  let fields = yamlNode.fields
  result.enabled = getYamlBool(fields, "enabled", false)
  result.secret = getYamlString(fields, "secret", "")
  result.defaultTokenExpiryHours = getYamlInt(fields, "default_token_expiry_hours", 24)

proc parseUserConfig*(yamlNode: YamlNode): UserConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "User config must be a mapping")

  let fields = yamlNode.fields
  result.username = getYamlString(fields, "username", "")

  var roles: seq[string] = @[]
  for k, v in fields.pairs:
    if k.content == "roles":
      if v.kind == ySequence:
        for i in 0 ..< v.len:
          let roleNode = v[int(i)]
          if roleNode.kind == yScalar:
            roles.add(roleNode.content)
      elif v.kind == yScalar:
        roles.add(v.content)
  result.roles = roles

proc parseUsersConfig*(yamlNode: YamlNode): seq[UserConfig] =
  result = @[]
  if yamlNode.kind != ySequence:
    raise newException(ValueError, "Users config must be a sequence")

  for i in 0 ..< yamlNode.len:
    result.add(parseUserConfig(yamlNode[int(i)]))

proc parseWebadminConfig*(yamlNode: YamlNode): WebadminConfig =
  if yamlNode != nil and yamlNode.kind != yMapping:
    raise newException(ValueError, "Webadmin config must be a mapping")

  let fields = if yamlNode != nil: yamlNode.fields else: nil
  result.enabled = getYamlBool(fields, "enabled", false)
  result.path = getYamlString(fields, "path", "")

proc parsePubSubConfig*(yamlNode: YamlNode): PubSubConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "PubSub config must be a mapping")

  let fields = yamlNode.fields
  result.maxTopics = getYamlInt(fields, "max_topics", 0)
  result.maxSubscriptionsPerClient = getYamlInt(fields, "max_subscriptions_per_client", 0)
  result.heartbeatTimeoutMs = getYamlInt(fields, "heartbeat_timeout_ms", 30000)

proc getDefaultConfig*(): BitBarrelConfig =
  ## Get default configuration values
  result = BitBarrelConfig(
    serverId: "",
    server: ServerConfig(
      address: "0.0.0.0",
      port: 9876,
      maxConnections: 10000,
      timeout: 30000
    ),
    storage: StorageConfig(
      dataDir: "./data",
      maxFileSize: 1024 * 1024 * 1024,  # 1GB
      maxKeySize: 64 * 1024,            # 64KB
      maxValueSize: 32 * 1024 * 1024,   # 32MB
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
      autoRecovery: true
    ),
    logging: LoggingConfig(
      level: "info",
      file: "barrel.log",
      maxSize: 100 * 1024 * 1024,  # 100MB
      maxBackups: 5,
      format: "text"
    ),
    auth: AuthConfig(
      enabled: false,
      secret: "",
      defaultTokenExpiryHours: 24
    ),
    users: @[],
    webadmin: WebadminConfig(
      enabled: false,
      path: ""
    ),
    pubsub: PubSubConfig(
      maxTopics: 0,
      maxSubscriptionsPerClient: 0,
      heartbeatTimeoutMs: 30000
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
      of "serverId": result.serverId = value.content
      of "storage": result.storage = parseStorageConfig(value)
      of "performance": result.performance = parsePerformanceConfig(value)
      of "compact": result.compact = parseCompactConfig(value)
      of "recovery": result.recovery = parseRecoveryConfig(value)
      of "logging": result.logging = parseLoggingConfig(value)
      of "auth": result.auth = parseAuthConfig(value)
      of "users": result.users = parseUsersConfig(value)
      of "webadmin": result.webadmin = parseWebadminConfig(value)
      of "pubsub": result.pubsub = parsePubSubConfig(value)
      else: discard

  except Exception as e:
    raise newException(ValueError, &"Error parsing YAML config: {e.msg}")
  finally:
    yamlStream.close()


proc saveConfigToYaml*(config: BitBarrelConfig, filePath: string) =
  ## Save configuration to a YAML file
  const yamlContent = """
# BitBarrel Configuration File
# All values have reasonable defaults

server:
  address: "0.0.0.0"
  port: 9876
  max_connections: 10000
  timeout: 30000

# serverId: ""

storage:
  data_dir: "./data"
  max_file_size: 1073741824
  max_key_size: 65536
  max_value_size: 33554432
  sync_mode: "immediate"
  fsync_interval: 100
  compression:
    enabled: false
    threshold: 256
    level: "default"

performance:
  worker_threads: 4
  write_buffer_size: 1000
  write_buffer_timeout: 10
  read_ahead_size: 64
  cache_size: 256

compact:
  enabled: true
  trigger_threshold: 0.3
  compact_interval: 60
  compact_interval_bytes: 10485760
  max_file_size: 1073741824

recovery:
  enabled: true
  validate_checksums: true
  skip_corrupt_records: true
  auto_recovery: true

logging:
  level: "info"
  file: "barrel.log"
  max_size: 104857600
  max_backups: 5
  format: "text"

auth:
  enabled: false
  # Uncomment and set a secret for JWT authentication
  # secret: "your-secret-key-32-characters-minimum"
  default_token_expiry_hours: 24
# users:
#   - username: "admin"
#     roles:
#       - "admin"
#   - username: "readwrite"
#     roles:
#       - "readwrite"
#   - username: "readonly"
#     roles:
#       - "readonly"

webadmin:
  enabled: false
  # path: "/opt/bitbarrel/webadmin"

pubsub:
  max_topics: 0           # 0 = unlimited
  max_subscriptions_per_client: 0  # 0 = unlimited
  heartbeat_timeout_ms: 30000
"""
  writeFile(filePath, yamlContent)
