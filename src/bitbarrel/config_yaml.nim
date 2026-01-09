## YAML Persistence for Barrel Configuration
##
## Provides save/load functions for per-barrel configuration files.
## Config is stored as YAML alongside the data file (e.g., mydb.data -> mydb.yaml)

import std/[os, streams, strformat, strutils, options, tables]
import yaml
import types

proc getBarrelConfigPath*(dataPath: string): string =
  ## Get the config file path for a data file
  ## Example: "mydb.data" -> "mydb.yaml"
  dataPath.changeFileExt("yaml")

proc `$`(mode: UserSyncMode): string =
  case mode:
    of UserSyncMode.None: "none"
    of UserSyncMode.Sync: "sync"
    of UserSyncMode.Fsync: "fsync"

proc `$`(mode: BarrelMode): string =
  case mode:
    of bmHash: "hash"
    of bmCritBit: "critbit"
    of bmHugeCritBit: "hugecritbit"

proc barrelConfigToYaml*(config: BarrelConfig): string =
  ## Serialize BarrelConfig to YAML string
  result = "# BitBarrel per-barrel configuration\n\n"
  result.add(fmt("write_buffer_size: {config.writeBufferSize}\n"))
  result.add(fmt("sync_mode: \"{$config.syncMode}\"\n"))
  result.add(fmt("auto_compact: {config.autoCompact}\n"))
  result.add(fmt("compact_threshold: {config.compactThreshold}\n"))
  result.add(fmt("compact_interval: {config.compactInterval}\n"))
  result.add(fmt("validate_crc: {config.validateCrc}\n"))
  result.add(fmt("default_ttl: {config.defaultTtl}\n"))
  result.add(fmt("check_expiration_on_read: {config.checkExpirationOnRead}\n"))
  result.add(fmt("delete_expired_on_read: {config.deleteExpiredOnRead}\n"))
  result.add(fmt("mode: \"{$config.mode}\"\n"))

  # HugeBarrel config section
  result.add("\nhuge_config:\n")
  result.add(fmt("  max_entries_per_range: {config.hugeConfig.maxEntriesPerRange}\n"))
  result.add(fmt("  range_cache_size: {config.hugeConfig.rangeCacheSize}\n"))
  result.add(fmt("  max_data_file_size_mb: {config.hugeConfig.maxDataFileSizeMB}\n"))
  result.add(fmt("  auto_split_enabled: {config.hugeConfig.autoSplitEnabled}\n"))
  result.add(fmt("  flush_interval_ms: {config.hugeConfig.flushIntervalMs}\n"))
  result.add(fmt("  enable_barrel2_recovery: {config.hugeConfig.enableBarrel2Recovery}\n"))

proc saveBarrelConfigYaml*(dataPath: string, config: BarrelConfig) =
  ## Save barrel config to YAML file alongside data file
  let configPath = getBarrelConfigPath(dataPath)
  writeFile(configPath, barrelConfigToYaml(config))

# YAML parsing helpers (following config_parser.nim patterns)
proc getYamlString(fields: TableRef[yaml.YamlNode, yaml.YamlNode], key: string, default: string = ""): string =
  for k, v in fields.pairs:
    if k.content == key and v.kind == yScalar:
      return v.content
  return default

proc getYamlInt(fields: TableRef[yaml.YamlNode, yaml.YamlNode], key: string, default: int): int =
  for k, v in fields.pairs:
    if k.content == key and v.kind == yScalar:
      try:
        return parseInt(v.content)
      except:
        return default
  return default

proc getYamlBool(fields: TableRef[yaml.YamlNode, yaml.YamlNode], key: string, default: bool): bool =
  for k, v in fields.pairs:
    if k.content == key and v.kind == yScalar:
      let content = v.content.toLowerAscii()
      return content == "true" or content == "yes" or content == "1"
  return default

proc getYamlFloat(fields: TableRef[yaml.YamlNode, yaml.YamlNode], key: string, default: float): float =
  for k, v in fields.pairs:
    if k.content == key and v.kind == yScalar:
      try:
        return parseFloat(v.content)
      except:
        return default
  return default

proc parseUserSyncMode(s: string): UserSyncMode =
  case s.toLowerAscii():
    of "none": result = UserSyncMode.None
    of "sync": result = UserSyncMode.Sync
    of "fsync": result = UserSyncMode.Fsync
    else: result = UserSyncMode.Sync  # Default

proc parseBarrelMode(s: string): BarrelMode =
  case s.toLowerAscii():
    of "hash": result = bmHash
    of "critbit": result = bmCritBit
    of "hugecritbit": result = bmHugeCritBit
    else: result = bmHash  # Default

proc parseHugeConfig(node: YamlNode): HugeBarrelConfig =
  ## Parse HugeBarrelConfig from YAML node
  result = HugeBarrelConfig(
    maxEntriesPerRange: 100_000,
    rangeCacheSize: 10,
    maxDataFileSizeMB: 1024,
    autoSplitEnabled: true,
    flushIntervalMs: 0,
    enableBarrel2Recovery: true
  )

  if node.kind != yMapping:
    return

  let fields = node.fields
  result.maxEntriesPerRange = getYamlInt(fields, "max_entries_per_range", result.maxEntriesPerRange)
  result.rangeCacheSize = getYamlInt(fields, "range_cache_size", result.rangeCacheSize)
  result.maxDataFileSizeMB = getYamlInt(fields, "max_data_file_size_mb", result.maxDataFileSizeMB)
  result.autoSplitEnabled = getYamlBool(fields, "auto_split_enabled", result.autoSplitEnabled)
  result.flushIntervalMs = getYamlInt(fields, "flush_interval_ms", result.flushIntervalMs)
  result.enableBarrel2Recovery = getYamlBool(fields, "enable_barrel2_recovery", result.enableBarrel2Recovery)

proc loadBarrelConfigYaml*(dataPath: string): Option[BarrelConfig] =
  ## Load barrel config from YAML file if it exists
  ## Returns none if file doesn't exist or parsing fails
  let configPath = getBarrelConfigPath(dataPath)
  if not fileExists(configPath):
    return none(BarrelConfig)

  var yamlStream = newFileStream(configPath, fmRead)
  if yamlStream == nil:
    return none(BarrelConfig)

  try:
    var yamlRoot: YamlNode
    load(yamlStream, yamlRoot)
    yamlStream.close()

    if yamlRoot.kind != yMapping:
      return none(BarrelConfig)

    let fields = yamlRoot.fields

    # Start with defaults
    var config = BarrelConfig(
      writeBufferSize: 64 * 1024,
      syncMode: UserSyncMode.Sync,
      autoCompact: false,
      compactThreshold: 0.3,
      compactInterval: 60,
      validateCrc: true,
      defaultTtl: 0,
      checkExpirationOnRead: true,
      deleteExpiredOnRead: false,
      mode: bmHash,
      hugeConfig: HugeBarrelConfig()
    )

    # Parse each field
    config.writeBufferSize = getYamlInt(fields, "write_buffer_size", config.writeBufferSize)
    config.syncMode = parseUserSyncMode(getYamlString(fields, "sync_mode", "sync"))
    config.autoCompact = getYamlBool(fields, "auto_compact", config.autoCompact)
    config.compactThreshold = getYamlFloat(fields, "compact_threshold", config.compactThreshold)
    config.compactInterval = getYamlInt(fields, "compact_interval", config.compactInterval)
    config.validateCrc = getYamlBool(fields, "validate_crc", config.validateCrc)
    config.defaultTtl = getYamlInt(fields, "default_ttl", config.defaultTtl)
    config.checkExpirationOnRead = getYamlBool(fields, "check_expiration_on_read", config.checkExpirationOnRead)
    config.deleteExpiredOnRead = getYamlBool(fields, "delete_expired_on_read", config.deleteExpiredOnRead)
    config.mode = parseBarrelMode(getYamlString(fields, "mode", "hash"))

    # Parse huge_config if present
    for k, v in fields.pairs:
      if k.content == "huge_config":
        config.hugeConfig = parseHugeConfig(v)
        break

    return some(config)

  except Exception:
    if yamlStream != nil:
      yamlStream.close()
    return none(BarrelConfig)
