## Storage Configuration for Pub/Sub History
##
## Defines configuration types for history storage strategies.
## Supports memory-only, shared barrel, per-topic barrel, and hybrid modes.

import std/[tables, strutils, os]
import ../bitbarrel/barrel

type
  ## Storage strategy for topic history
  StorageStrategy* = enum
    ssMemoryOnly          ## In-memory only, volatile
    ssSharedBarrel        ## Single barrel for all topics
    ssPerTopicBarrel      ## Separate barrel per topic
    ssHybrid             ## Mixed strategy (some shared, some per-topic)

  ## Per-topic storage configuration
  TopicStorageConfig* = object
    ## Storage strategy for this topic
    strategy*: StorageStrategy

    ## For ssPerTopicBarrel: custom barrel path (optional)
    customPath*: string

    ## Barrel index mode (for persistent backends)
    indexMode*: BarrelMode

    ## Compression settings
    compressionEnabled*: bool
    compressionThreshold*: int  ## Min size to compress (bytes)

    ttlSeconds*: int

    ## Retention settings
    maxMessages*: int        ## 0 = unlimited, applies to memory backends
    retentionHours*: int     ## 0 = forever, applies to persistent backends

  ## Global storage configuration
  StorageConfig* = object
    ## Default storage strategy
    defaultStrategy*: StorageStrategy

    ## Default settings for new topics
    defaultTopicConfig*: TopicStorageConfig

    ## Shared barrel configuration
    sharedBarrelPath*: string
    sharedBarrelConfig*: BarrelConfig

    ## Per-topic barrel configuration
    topicBarrelDir*: string         ## Base directory for topic barrels
    topicBarrelConfig*: BarrelConfig

    ## Topic pattern overrides
    topicOverrides*: Table[string, TopicStorageConfig]

    ## Runtime settings
    backendCacheSize*: int     ## Max cached backends (for per-topic)
    backendIdleTimeout*: int   ## Seconds before closing idle backends
    batchSize*: int            ## Batch write size

# Forward declaration
proc matchesTopicPattern(pattern, topic: string): bool

proc initStorageConfig*(): StorageConfig =
  ## Initialize default storage configuration
  result = StorageConfig(
    defaultStrategy: ssMemoryOnly,
    defaultTopicConfig: TopicStorageConfig(
      strategy: ssMemoryOnly,
      indexMode: bmHash,
      compressionEnabled: false,
      compressionThreshold: 256,
      ttlSeconds: 0,
      maxMessages: 100,
      retentionHours: 0
    ),
    sharedBarrelPath: "",
    sharedBarrelConfig: defaultBarrelConfig(),
    topicBarrelDir: "",
    topicBarrelConfig: defaultBarrelConfig(),
    topicOverrides: initTable[string, TopicStorageConfig](),
    backendCacheSize: 1000,
    backendIdleTimeout: 3600,  # 1 hour
    batchSize: 100
  )

proc setSharedBarrelConfig*(config: var StorageConfig,
                             path: string,
                             barrelConfig: BarrelConfig) =
  ## Configure shared barrel storage
  config.defaultStrategy = ssSharedBarrel
  config.sharedBarrelPath = path
  config.sharedBarrelConfig = barrelConfig

proc setPerTopicBarrelConfig*(config: var StorageConfig,
                               baseDir: string,
                               barrelConfig: BarrelConfig) =
  ## Configure per-topic barrel storage
  config.defaultStrategy = ssPerTopicBarrel
  config.topicBarrelDir = baseDir
  config.topicBarrelConfig = barrelConfig

proc addTopicOverride*(config: var StorageConfig,
                       pattern: string,
                       topicConfig: TopicStorageConfig) =
  ## Add storage configuration override for topic pattern
  ##
  ## Pattern matching uses glob-style wildcards:
  ## - "*" matches zero or more characters
  ## - "?" matches exactly one character
  config.topicOverrides[pattern] = topicConfig

proc resolveStrategy*(config: StorageConfig, topic: string): StorageStrategy =
  ## Resolve storage strategy for a topic
  ## Checks overrides first, then returns default
  for pattern, override in config.topicOverrides:
    if matchesTopicPattern(pattern, topic):
      return override.strategy

  return config.defaultStrategy

proc resolveTopicConfig*(config: StorageConfig,
                         topic: string): TopicStorageConfig =
  ## Resolve full storage config for a topic
  ## Returns overridden config if pattern matches, otherwise default
  for pattern, override in config.topicOverrides:
    if matchesTopicPattern(pattern, topic):
      return override

  return config.defaultTopicConfig

## Helper functions

proc matchesTopicPattern(pattern, topic: string): bool =
  ## Check if topic matches glob pattern
  ## Simple wildcard matching: "*" matches any characters
  if "*" notin pattern:
    return pattern == topic

  let parts = pattern.split("*")
  if parts.len == 0:
    return true

  # Pattern must start with first part
  if not topic.startsWith(parts[0]):
    return false

  var pos = parts[0].len

  # Check middle parts
  for i in 1..<parts.len:
    if parts[i].len == 0:
      continue

    let part = parts[i]
    let found = find(topic, part, pos)
    if found == -1:
      return false

    pos = found + part.len

  # Check last part if pattern doesn't end with "*"
  if not pattern.endsWith("*") and parts[^1].len > 0:
    return topic.endsWith(parts[^1])

  return true

proc getTopicBarrelPath*(config: StorageConfig, topic: string): string =
  ## Get barrel file path for a topic (per-topic strategy)
  let sanitized = topic.replace("/", "_").replace("\\", "_").replace(":", "_")
  return config.topicBarrelDir / sanitized & ".data"

proc parseStorageStrategy*(strategyStr: string): StorageStrategy =
  ## Parse strategy from string (for config files)
  case strategyStr.toLowerAscii()
  of "memory", "memoryonly":
    result = ssMemoryOnly
  of "shared", "sharedbarrel":
    result = ssSharedBarrel
  of "per_topic", "per_topic_barrel":
    result = ssPerTopicBarrel
  of "hybrid":
    result = ssHybrid
  else:
    raise newException(ValueError, "Unknown storage strategy: " & strategyStr)

proc `$`*(strategy: StorageStrategy): string =
  ## Convert strategy enum to string
  case strategy
  of ssMemoryOnly:
    result = "MemoryOnly"
  of ssSharedBarrel:
    result = "SharedBarrel"
  of ssPerTopicBarrel:
    result = "PerTopicBarrel"
  of ssHybrid:
    result = "Hybrid"
