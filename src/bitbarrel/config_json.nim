## JSON Serialization for Barrel Configuration
##
## Provides conversion between BarrelConfig objects and JSON format
## for network transmission. Supports partial updates, validation,
## and forward compatibility (ignores unknown fields).

import std/[json, strutils, strformat]
import types

type
  ConfigValidationError* = object of CatchableError
    ## Raised when configuration validation fails


# Forward declarations
proc fromJson*(node: JsonNode): BarrelConfig
proc toJson*(config: BarrelConfig): JsonNode

# Helper procs for enum serialization
proc parseUserSyncMode*(s: string): UserSyncMode =
  case s.toLowerAscii():
    of "none": result = UserSyncMode.None
    of "sync": result = UserSyncMode.Sync
    of "fsync": result = UserSyncMode.Fsync
    else:
      raise newException(ConfigValidationError, &"Invalid sync mode: '{s}'")

proc parseBarrelMode*(s: string): BarrelMode =
  case s.toLowerAscii():
    of "hash": result = bmHash
    of "critbit": result = bmCritBit
    of "hugecritbit": result = bmHugeCritBit
    else:
      raise newException(ConfigValidationError, &"Invalid barrel mode: '{s}'")

proc `$`*(mode: UserSyncMode): string =
  case mode:
    of UserSyncMode.None: "none"
    of UserSyncMode.Sync: "sync"
    of UserSyncMode.Fsync: "fsync"

proc `$`*(mode: BarrelMode): string =
  case mode:
    of bmHash: "hash"
    of bmCritBit: "critbit"
    of bmHugeCritBit: "hugecritbit"

# HugeBarrelConfig serialization
proc hugeConfigToJson*(config: HugeBarrelConfig): JsonNode =
  result = newJObject()
  result["maxEntriesPerRange"] = newJInt(config.maxEntriesPerRange)
  result["rangeCacheSize"] = newJInt(config.rangeCacheSize)
  result["maxDataFileSizeMB"] = newJInt(config.maxDataFileSizeMB)
  result["autoSplitEnabled"] = newJBool(config.autoSplitEnabled)
  result["flushIntervalMs"] = newJInt(config.flushIntervalMs)
  result["enableBarrel2Recovery"] = newJBool(config.enableBarrel2Recovery)

proc hugeConfigFromJson*(node: JsonNode): HugeBarrelConfig =
  if node.kind != JObject:
    raise newException(ConfigValidationError, "HugeBarrelConfig must be a JSON object")

  result.maxEntriesPerRange = 100_000
  result.rangeCacheSize = 10
  result.maxDataFileSizeMB = 1024
  result.autoSplitEnabled = true
  result.flushIntervalMs = 0
  result.enableBarrel2Recovery = true

  for key, value in node.pairs:
    case key:
      of "maxEntriesPerRange":
        if value.kind == JInt:
          let val = value.getInt
          if val <= 0:
            raise newException(ConfigValidationError, "maxEntriesPerRange must be positive")
          result.maxEntriesPerRange = val
      of "rangeCacheSize":
        if value.kind == JInt:
          let val = value.getInt
          if val <= 0:
            raise newException(ConfigValidationError, "rangeCacheSize must be positive")
          result.rangeCacheSize = val
      of "maxDataFileSizeMB":
        if value.kind == JInt:
          let val = value.getInt
          if val <= 0:
            raise newException(ConfigValidationError, "maxDataFileSizeMB must be positive")
          result.maxDataFileSizeMB = val
      of "autoSplitEnabled":
        if value.kind == JBool:
          result.autoSplitEnabled = value.getBool
      of "flushIntervalMs":
        if value.kind == JInt:
          let val = value.getInt
          if val < 0:
            raise newException(ConfigValidationError, "flushIntervalMs must be non-negative")
          result.flushIntervalMs = val
      of "enableBarrel2Recovery":
        if value.kind == JBool:
          result.enableBarrel2Recovery = value.getBool
      else:
        # Ignore unknown fields for forward compatibility
        discard

# Main BarrelConfig serialization
proc toJson*(config: BarrelConfig): JsonNode =
  result = newJObject()
  result["writeBufferSize"] = newJInt(config.writeBufferSize)
  result["syncMode"] = newJString($config.syncMode)
  result["autoCompact"] = newJBool(config.autoCompact)
  result["compactThreshold"] = newJFloat(config.compactThreshold)
  result["validateCrc"] = newJBool(config.validateCrc)
  result["defaultTtl"] = newJInt(config.defaultTtl)
  result["checkExpirationOnRead"] = newJBool(config.checkExpirationOnRead)
  result["deleteExpiredOnRead"] = newJBool(config.deleteExpiredOnRead)
  result["mode"] = newJString($config.mode)
  result["hugeConfig"] = hugeConfigToJson(config.hugeConfig)

proc fromJson*(node: JsonNode): BarrelConfig =
  if node.kind != JObject:
    raise newException(ConfigValidationError, "BarrelConfig must be a JSON object")

  # Start with default values
  result.writeBufferSize = 64 * 1024  # 64KB
  result.syncMode = UserSyncMode.Sync
  result.autoCompact = true
  result.compactThreshold = 0.3
  result.validateCrc = true
  result.defaultTtl = 0
  result.checkExpirationOnRead = true
  result.deleteExpiredOnRead = false
  result.mode = bmHash
  result.hugeConfig = HugeBarrelConfig()

  for key, value in node.pairs:
    case key:
      of "writeBufferSize":
        if value.kind == JInt:
          let val = value.getInt
          if val <= 0:
            raise newException(ConfigValidationError, "writeBufferSize must be positive")
          result.writeBufferSize = val
      of "syncMode":
        if value.kind == JString:
          result.syncMode = parseUserSyncMode(value.getStr)
      of "autoCompact":
        if value.kind == JBool:
          result.autoCompact = value.getBool
      of "compactThreshold":
        if value.kind == JFloat:
          let val = value.getFloat
          if val < 0.0 or val > 1.0:
            raise newException(ConfigValidationError, "compactThreshold must be between 0.0 and 1.0")
          result.compactThreshold = val
        elif value.kind == JInt:
          let val = value.getInt.float
          if val < 0.0 or val > 1.0:
            raise newException(ConfigValidationError, "compactThreshold must be between 0.0 and 1.0")
          result.compactThreshold = val
      of "validateCrc":
        if value.kind == JBool:
          result.validateCrc = value.getBool
      of "defaultTtl":
        if value.kind == JInt:
          let val = value.getInt
          if val < 0:
            raise newException(ConfigValidationError, "defaultTtl must be non-negative")
          result.defaultTtl = val
      of "checkExpirationOnRead":
        if value.kind == JBool:
          result.checkExpirationOnRead = value.getBool
      of "deleteExpiredOnRead":
        if value.kind == JBool:
          result.deleteExpiredOnRead = value.getBool
      of "mode":
        if value.kind == JString:
          result.mode = parseBarrelMode(value.getStr)
      of "hugeConfig":
        if value.kind == JObject:
          result.hugeConfig = hugeConfigFromJson(value)
      else:
        # Ignore unknown fields for forward compatibility
        discard

# Public API procs
proc parseBarrelConfigJson*(jsonStr: string): BarrelConfig =
  ## Parse a BarrelConfig from JSON string
  ## Raises ConfigValidationError on validation failure
  try:
    let node = parseJson(jsonStr)
    result = fromJson(node)
  except JsonParsingError as e:
    raise newException(ConfigValidationError, &"Invalid JSON: {e.msg}")
  except ConfigValidationError:
    raise
  except CatchableError as e:
    raise newException(ConfigValidationError, &"Failed to parse config: {e.msg}")

proc serializeBarrelConfig*(config: BarrelConfig): string =
  ## Convert a BarrelConfig to JSON string
  toJson(config).pretty()

proc applyJsonUpdatesToConfig*(current: BarrelConfig, jsonStr: string): BarrelConfig =
  ## Apply partial JSON updates to current configuration
  ## Only fields present in JSON are updated; others remain unchanged
  ## Raises ConfigValidationError on validation failure
  result = current

  let node = try:
    parseJson(jsonStr)
  except JsonParsingError as e:
    raise newException(ConfigValidationError, &"Invalid JSON: {e.msg}")

  if node.kind != JObject:
    raise newException(ConfigValidationError, "Configuration must be a JSON object")

  for key, value in node.pairs:
    case key:
      of "writeBufferSize":
        if value.kind == JInt:
          let val = value.getInt
          if val <= 0:
            raise newException(ConfigValidationError, "writeBufferSize must be positive")
          result.writeBufferSize = val
        else:
          raise newException(ConfigValidationError, "writeBufferSize must be integer")
      of "syncMode":
        if value.kind == JString:
          result.syncMode = parseUserSyncMode(value.getStr)
        else:
          raise newException(ConfigValidationError, "syncMode must be string")
      of "autoCompact":
        if value.kind == JBool:
          result.autoCompact = value.getBool
        else:
          raise newException(ConfigValidationError, "autoCompact must be boolean")
      of "compactThreshold":
        if value.kind == JFloat:
          let val = value.getFloat
          if val < 0.0 or val > 1.0:
            raise newException(ConfigValidationError, "compactThreshold must be between 0.0 and 1.0")
          result.compactThreshold = val
        elif value.kind == JInt:
          let val = value.getInt.float
          if val < 0.0 or val > 1.0:
            raise newException(ConfigValidationError, "compactThreshold must be between 0.0 and 1.0")
          result.compactThreshold = val
        else:
          raise newException(ConfigValidationError, "compactThreshold must be number")
      of "validateCrc":
        if value.kind == JBool:
          result.validateCrc = value.getBool
        else:
          raise newException(ConfigValidationError, "validateCrc must be boolean")
      of "defaultTtl":
        if value.kind == JInt:
          let val = value.getInt
          if val < 0:
            raise newException(ConfigValidationError, "defaultTtl must be non-negative")
          result.defaultTtl = val
        else:
          raise newException(ConfigValidationError, "defaultTtl must be integer")
      of "checkExpirationOnRead":
        if value.kind == JBool:
          result.checkExpirationOnRead = value.getBool
        else:
          raise newException(ConfigValidationError, "checkExpirationOnRead must be boolean")
      of "deleteExpiredOnRead":
        if value.kind == JBool:
          result.deleteExpiredOnRead = value.getBool
        else:
          raise newException(ConfigValidationError, "deleteExpiredOnRead must be boolean")
      of "mode":
        if value.kind == JString:
          result.mode = parseBarrelMode(value.getStr)
        else:
          raise newException(ConfigValidationError, "mode must be string")
      of "hugeConfig":
        if value.kind == JObject:
          # Apply partial updates to hugeConfig
          for hkey, hvalue in value.pairs:
            case hkey:
              of "maxEntriesPerRange":
                if hvalue.kind == JInt:
                  let val = hvalue.getInt
                  if val <= 0:
                    raise newException(ConfigValidationError, "maxEntriesPerRange must be positive")
                  result.hugeConfig.maxEntriesPerRange = val
                else:
                  raise newException(ConfigValidationError, "maxEntriesPerRange must be integer")
              of "rangeCacheSize":
                if hvalue.kind == JInt:
                  let val = hvalue.getInt
                  if val <= 0:
                    raise newException(ConfigValidationError, "rangeCacheSize must be positive")
                  result.hugeConfig.rangeCacheSize = val
                else:
                  raise newException(ConfigValidationError, "rangeCacheSize must be integer")
              of "maxDataFileSizeMB":
                if hvalue.kind == JInt:
                  let val = hvalue.getInt
                  if val <= 0:
                    raise newException(ConfigValidationError, "maxDataFileSizeMB must be positive")
                  result.hugeConfig.maxDataFileSizeMB = val
                else:
                  raise newException(ConfigValidationError, "maxDataFileSizeMB must be integer")
              of "autoSplitEnabled":
                if hvalue.kind == JBool:
                  result.hugeConfig.autoSplitEnabled = hvalue.getBool
                else:
                  raise newException(ConfigValidationError, "autoSplitEnabled must be boolean")
              of "flushIntervalMs":
                if hvalue.kind == JInt:
                  let val = hvalue.getInt
                  if val < 0:
                    raise newException(ConfigValidationError, "flushIntervalMs must be non-negative")
                  result.hugeConfig.flushIntervalMs = val
                else:
                  raise newException(ConfigValidationError, "flushIntervalMs must be integer")
              of "enableBarrel2Recovery":
                if hvalue.kind == JBool:
                  result.hugeConfig.enableBarrel2Recovery = hvalue.getBool
                else:
                  raise newException(ConfigValidationError, "enableBarrel2Recovery must be boolean")
              else:
                # Ignore unknown fields
                discard
        else:
          raise newException(ConfigValidationError, "hugeConfig must be object")
      else:
        # Ignore unknown fields for forward compatibility
        discard

export ConfigValidationError, parseBarrelConfigJson, serializeBarrelConfig, applyJsonUpdatesToConfig