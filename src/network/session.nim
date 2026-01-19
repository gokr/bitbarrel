## Session and Barrel Registry management for BitBarrel network server

import std/[tables, locks, os, options, strformat, sequtils, sets, strutils]
import ../bitbarrel/types
import ../bitbarrel/barrel
import ../bitbarrel/config_yaml
import ../storage/hugebarrel
import auth as authjwt

type
  # Wrapper type to hold either a regular Barrel or a HugeBarrel
  BarrelKind* = enum
    bkRegular
    bkHuge

  BarrelWrapper* = object
    case kind*: BarrelKind
    of bkRegular:
      regularBarrel*: Barrel
    of bkHuge:
      hugeBarrel*: HugeBarrel

# Forward declarations for BarrelWrapper methods
proc getStats*(wrapper: BarrelWrapper): BarrelStats
proc get*(wrapper: BarrelWrapper, key: string): string
proc set*(wrapper: var BarrelWrapper, key: string, value: string): bool
proc delete*(wrapper: var BarrelWrapper, key: string): bool
proc exists*(wrapper: BarrelWrapper, key: string): bool
proc count*(wrapper: BarrelWrapper): int

type
  BarrelInfo* = object
    name*: string
    kind*: BarrelKind
    hasConfig*: bool
    discovered*: bool

  Session* = object
    id*: uint64               ## WebSocket client ID
    currentBarrel*: string    ## Name of current barrel (empty = none)
    authSession*: authjwt.AuthSession  ## Authentication session data
    watches*: ref Table[string, tuple[subId: string, topic: string]]  ## watchId -> (subId, topicPattern)

  BarrelRegistry* = object
    barrels*: Table[string, BarrelWrapper]  ## name -> BarrelWrapper
    availableBarrels*: HashSet[string]      ## NEW: discovered barrel names
    barrelInfo*: Table[string, BarrelInfo]  ## NEW: metadata for all barrels
    dataDir*: string                        ## Base directory for barrel data
    lock*: Lock
    lastError*: string                      ## Last error message for debugging

  BarrelError* = object of CatchableError


proc createBarrel*(reg: var BarrelRegistry, name: string, config: BarrelConfig): bool =
  ## Create a new barrel with the given configuration.
  ## Returns true if successful, false if barrel already exists or creation fails.
  ## Sets reg.lastError with detailed error message on failure.

  withLock reg.lock:
    reg.lastError = ""

    if name in reg.barrels:
      reg.lastError = fmt"Barrel '{name}' already exists"
      return false

    try:
      if config.mode == bmHugeCritBit:
        # HugeBarrel uses a directory, not a .data file
        let hugeBarrelPath = reg.dataDir / name
        let hb = openHugeBarrel(hugeBarrelPath, config)
        reg.barrels[name] = BarrelWrapper(kind: bkHuge, hugeBarrel: hb)

        # Track as available and save YAML
        reg.availableBarrels.incl(name)
        reg.barrelInfo[name] = BarrelInfo(
          name: name,
          kind: bkHuge,
          hasConfig: true,
          discovered: false
        )

        # Create YAML config
        let configPath = hugeBarrelPath & ".yaml"
        try:
          writeFile(configPath, barrelConfigToYaml(config))
        except CatchableError as e:
          reg.lastError = fmt"Warning: Failed to create YAML config: {e.msg}"
          # Continue - non-fatal, barrel still usable
      else:
        # Regular Barrel uses a .data file
        let dataPath = reg.dataDir / (name & ".data")
        let barrel = openBarrel(dataPath, config)
        reg.barrels[name] = BarrelWrapper(kind: bkRegular, regularBarrel: barrel)

        # Track as available and save YAML
        reg.availableBarrels.incl(name)
        reg.barrelInfo[name] = BarrelInfo(
          name: name,
          kind: bkRegular,
          hasConfig: true,
          discovered: false
        )

        # Create YAML config
        try:
          saveBarrelConfigYaml(dataPath, config)
        except CatchableError as e:
          reg.lastError = fmt"Warning: Failed to create YAML config: {e.msg}"
          # Continue - non-fatal, barrel still usable
      return true
    except CatchableError as e:
      reg.lastError = fmt"Failed to create barrel '{name}': {e.msg}"
      return false

proc openBarrelUnlocked(reg: var BarrelRegistry, name: string): bool =
  ## Internal version of openBarrel that assumes lock is already held
  ## Returns true if successful, false if barrel doesn't exist or fails to open.

  # Already open?
  if name in reg.barrels:
    return true

  # Get barrel info if we have it
  let info = if name in reg.barrelInfo: reg.barrelInfo[name]
             else: BarrelInfo(name: name, kind: bkRegular, hasConfig: false, discovered: false)

  # Try to open based on kind
  try:
    case info.kind
    of bkRegular:
      let dataPath = reg.dataDir / (name & ".data")

      # Check if data file exists
      if not fileExists(dataPath):
        return false

      # Load config from YAML if it exists, otherwise use defaults
      let configOpt = loadBarrelConfigYaml(dataPath)
      let config = if configOpt.isSome(): configOpt.get()
                   else: defaultBarrelConfig()

      let barrel = openBarrel(dataPath, config)
      reg.barrels[name] = BarrelWrapper(kind: bkRegular, regularBarrel: barrel)

    of bkHuge:
      let hugePath = reg.dataDir / name

      # Check if directory exists
      if not dirExists(hugePath):
        return false

      # Load config from YAML if it exists
      let configPath = hugePath & ".yaml"
      let configOpt = if fileExists(configPath):
                        loadBarrelConfigYaml(configPath)
                      else:
                        none(BarrelConfig)

      var config = if configOpt.isSome(): configOpt.get()
                   else: defaultBarrelConfig()
      config.mode = bmHugeCritBit  # Ensure mode is correct

      let hb = openHugeBarrel(hugePath, config)
      reg.barrels[name] = BarrelWrapper(kind: bkHuge, hugeBarrel: hb)

    return true

  except CatchableError as e:
    reg.lastError = fmt"Failed to open barrel '{name}': {e.msg}"
    return false

proc openBarrel*(reg: var BarrelRegistry, name: string): bool =
  ## Open an existing barrel (lazy loading from discovered barrels).
  ## Returns true if successful, false if barrel doesn't exist or fails to open.
  withLock reg.lock:
    result = openBarrelUnlocked(reg, name)

proc getBarrel*(reg: var BarrelRegistry, name: string): Option[BarrelWrapper] =
  ## Get a barrel wrapper by name.
  ## Lazy loads the barrel if it exists but isn't open yet.
  ## Returns none if barrel doesn't exist or fails to open.

  withLock reg.lock:
    # Check if already open
    if name in reg.barrels:
      return some(reg.barrels[name])

    # Try lazy loading if barrel was discovered
    if openBarrelUnlocked(reg, name):
      return some(reg.barrels[name])
    else:
      return none(BarrelWrapper)

proc closeBarrel*(reg: var BarrelRegistry, name: string): bool =
  ## Close a barrel.
  ## Returns true if successful, false if barrel doesn't exist.
  withLock reg.lock:
    if name in reg.barrels:
      var wrapper = reg.barrels[name]
      try:
        case wrapper.kind
        of bkRegular:
          wrapper.regularBarrel.close()
        of bkHuge:
          wrapper.hugeBarrel.close()
      except CatchableError:
        discard  # Continue with cleanup even if close fails
      finally:
        reg.barrels.del(name)
      return true
    else:
      return false

proc dropBarrel*(reg: var BarrelRegistry, name: string): bool =
  ## Delete a barrel and its data files.
  ## Returns true if successful, false if barrel doesn't exist or deletion fails.
  withLock reg.lock:
    # First close the barrel if open
    if name in reg.barrels:
      var wrapper = reg.barrels[name]
      try:
        case wrapper.kind
        of bkRegular:
          wrapper.regularBarrel.close()
        of bkHuge:
          wrapper.hugeBarrel.close()
      except CatchableError:
        discard
      reg.barrels.del(name)

    # Remove from tracking
    reg.availableBarrels.excl(name)
    reg.barrelInfo.del(name)

    # Delete the data file (regular barrel)
    let dataPath = reg.dataDir / (name & ".data")
    if fileExists(dataPath):
      try:
        removeFile(dataPath)
        # Also remove YAML config if it exists
        let yamlPath = getBarrelConfigPath(dataPath)
        if fileExists(yamlPath):
          removeFile(yamlPath)
        return true
      except CatchableError:
        return false

    # Delete the directory (HugeBarrel)
    let hugePath = reg.dataDir / name
    if dirExists(hugePath):
      try:
        removeDir(hugePath)
        # Also remove YAML config if it exists
        let yamlPath = hugePath & ".yaml"
        if fileExists(yamlPath):
          removeFile(yamlPath)
        return true
      except CatchableError:
        return false

    return false  # Barrel doesn't exist

proc listBarrels*(reg: var BarrelRegistry): seq[string] =
  ## List all available barrels (both discovered and open).
  result = @[]
  withLock reg.lock:
    # Add all available barrels (discovered + manually created)
    for name in reg.availableBarrels:
      result.add(name)

    # Also add any barrels that are open but weren't discovered
    # (e.g., created during this session)
    for name in reg.barrels.keys:
      if name notin reg.availableBarrels:
        result.add(name)

proc getAllBarrels*(reg: var BarrelRegistry): Table[string, BarrelWrapper] =
  ## Get a copy of all barrel wrappers (for stats etc.)
  result = initTable[string, BarrelWrapper]()
  withLock reg.lock:
    for name, wrapper in reg.barrels.pairs:
      result[name] = wrapper

proc closeAll*(reg: var BarrelRegistry) =
  ## Close all barrels. Call during server shutdown.
  withLock reg.lock:
    for name in toSeq(reg.barrels.keys):
      var wrapper = reg.barrels[name]
      try:
        case wrapper.kind
        of bkRegular:
          wrapper.regularBarrel.close()
        of bkHuge:
          wrapper.hugeBarrel.close()
      except CatchableError:
        discard
    reg.barrels.clear()

proc newSession*(id: uint64): Session =
  ## Create a new session with the given ID.
  result = Session(id: id, currentBarrel: "", authSession: authjwt.AuthSession(authenticated: false))
  result.watches = new(Table[string, tuple[subId: string, topic: string]])

proc setCurrentBarrel*(session: var Session, barrelName: string) =
  ## Set the current barrel for a session.
  session.currentBarrel = barrelName

proc getCurrentBarrel*(session: Session): string =
  ## Get the current barrel name for a session.
  session.currentBarrel

proc clearCurrentBarrel*(session: var Session) =
  ## Clear the current barrel for a session.
  session.currentBarrel = ""

proc hasCurrentBarrel*(session: Session): bool =
  ## Check if a session has a current barrel selected.
  session.currentBarrel.len > 0

proc newBarrelRegistry*(dataDir: string): BarrelRegistry =
  ## Create a new barrel registry.
  result = BarrelRegistry(
    barrels: initTable[string, BarrelWrapper](),
    availableBarrels: initHashSet[string](),
    barrelInfo: initTable[string, BarrelInfo](),
    dataDir: dataDir,
    lock: Lock(),
    lastError: ""
  )
  initLock(result.lock)

# Barrel Discovery

proc inferBarrelKind(dataDir: string, name: string): BarrelKind =
  ## Infer barrel kind from filesystem structure
  let dirPath = dataDir / name
  if dirExists(dirPath):
    # Check for HugeBarrel structure (barrel1/ and barrel2/ subdirectories)
    if dirExists(dirPath / "barrel1") and dirExists(dirPath / "barrel2"):
      return bkHuge
  return bkRegular

proc inferBarrelMode(dataDir: string, name: string, kind: BarrelKind): BarrelMode =
  ## Infer barrel mode from structure and config
  if kind == bkHuge:
    return bmHugeCritBit

  # For regular barrels, check if YAML config exists
  let dataPath = dataDir / (name & ".data")
  let configOpt = loadBarrelConfigYaml(dataPath)
  if configOpt.isSome():
    return configOpt.get().mode

  # Default to hash mode (safe assumption)
  return bmHash

proc discoverBarrels*(reg: var BarrelRegistry): (int, int) =
  ## Discover barrels in data directory
  ## Returns: (barrels_discovered, yaml_files_created)
  var discovered = 0
  var yamlsCreated = 0

  echo fmt"[BarrelRegistry] Discovering barrels in '{reg.dataDir}'"

  if not dirExists(reg.dataDir):
    echo "[BarrelRegistry] Data directory does not exist, skipping discovery"
    return (0, 0)

  # Scan for .data files (regular barrels)
  for kind, path in walkDir(reg.dataDir):
    if kind == pcFile and path.endsWith(".data"):
      let fullName = extractFilename(path)
      let name = fullName[0..^6]  # Remove ".data" extension

      try:
        let barrelKind = bkRegular
        let hasConfig = fileExists(getBarrelConfigPath(path))

        # Create YAML if it doesn't exist
        if not hasConfig:
          echo fmt"[BarrelRegistry] Creating YAML config for '{name}'"
          let mode = inferBarrelMode(reg.dataDir, name, barrelKind)
          var config = defaultBarrelConfig()
          config.mode = mode

          try:
            saveBarrelConfigYaml(path, config)
            inc yamlsCreated
          except CatchableError as e:
            echo fmt"[BarrelRegistry] Warning: Failed to create YAML for '{name}': {e.msg}"
            continue  # Skip this barrel if we can't create config

        # Track as available
        withLock(reg.lock):
          reg.availableBarrels.incl(name)
          reg.barrelInfo[name] = BarrelInfo(
            name: name,
            kind: barrelKind,
            hasConfig: hasConfig or (not hasConfig and yamlsCreated > 0),
            discovered: true
          )

        inc discovered
        echo fmt"[BarrelRegistry] Discovered regular barrel '{name}'"
      except CatchableError as e:
        echo fmt"[BarrelRegistry] Warning: Error processing barrel '{name}': {e.msg}"
        continue

  # Scan for directories (potential HugeBarrels)
  for kind, path in walkDir(reg.dataDir):
    if kind == pcDir:
      let name = extractFilename(path)

      # Skip special directories
      if name.startsWith("."):
        continue

      # Check if it's a HugeBarrel (has barrel1/ and barrel2/ subdirs)
      if dirExists(path / "barrel1") and dirExists(path / "barrel2"):
        try:
          let barrelKind = bkHuge
          let configPath = path & ".yaml"  # HugeBarrels use {name}.yaml
          let hasConfig = fileExists(configPath)

          # Create YAML if it doesn't exist
          if not hasConfig:
            echo fmt"[BarrelRegistry] Creating YAML config for HugeBarrel '{name}'"
            var config = defaultBarrelConfig()
            config.mode = bmHugeCritBit

            try:
              writeFile(configPath, barrelConfigToYaml(config))
              inc yamlsCreated
            except CatchableError as e:
              echo fmt"[BarrelRegistry] Warning: Failed to create YAML for HugeBarrel '{name}': {e.msg}"
              continue

          # Track as available
          withLock(reg.lock):
            reg.availableBarrels.incl(name)
            reg.barrelInfo[name] = BarrelInfo(
              name: name,
              kind: barrelKind,
              hasConfig: hasConfig or (not hasConfig and yamlsCreated > 0),
              discovered: true
            )

          inc discovered
          echo fmt"[BarrelRegistry] Discovered HugeBarrel '{name}'"
        except CatchableError as e:
          echo fmt"[BarrelRegistry] Warning: Error processing HugeBarrel '{name}': {e.msg}"
          continue

  echo fmt"[BarrelRegistry] Discovery complete: {discovered} barrels found, {yamlsCreated} YAML configs created"
  return (discovered, yamlsCreated)

# BarrelWrapper method implementations
proc getStats*(wrapper: BarrelWrapper): BarrelStats =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.getStats()
  of bkHuge:
    var stats: BarrelStats
    stats.indexMode = "bmHugeCritBit"
    stats

proc get*(wrapper: BarrelWrapper, key: string): string =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.get(key)
  of bkHuge:
    wrapper.hugeBarrel.get(key)

proc set*(wrapper: var BarrelWrapper, key: string, value: string): bool =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.set(key, value)
  of bkHuge:
    wrapper.hugeBarrel.set(key, value)

proc delete*(wrapper: var BarrelWrapper, key: string): bool =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.delete(key)
  of bkHuge:
    wrapper.hugeBarrel.delete(key)

proc exists*(wrapper: BarrelWrapper, key: string): bool =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.exists(key)
  of bkHuge:
    wrapper.hugeBarrel.exists(key)

proc count*(wrapper: BarrelWrapper): int =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.count()
  of bkHuge:
    0  # HugeBarrel doesn't support count