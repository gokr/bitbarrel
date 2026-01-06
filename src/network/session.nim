## Session and Barrel Registry management for BitBarrel network server

import std/[tables, locks, os, options, strformat, sequtils]
import ../bitbarrel/types
import ../bitbarrel/barrel
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
  Session* = object
    id*: uint64               ## WebSocket client ID
    currentBarrel*: string    ## Name of current barrel (empty = none)
    authSession*: authjwt.AuthSession  ## Authentication session data

  BarrelRegistry* = object
    barrels*: Table[string, BarrelWrapper]  ## name -> BarrelWrapper
    dataDir*: string                  ## Base directory for barrel data
    lock*: Lock
    lastError*: string               ## Last error message for debugging

  BarrelError* = object of CatchableError


proc createBarrel*(reg: var BarrelRegistry, name: string, config: BarrelConfig): bool =
  ## Create a new barrel with the given configuration.
  ## Returns true if successful, false if barrel already exists or creation fails.
  ## Sets reg.lastError with detailed error message on failure.
  echo fmt"[DEBUG Session] createBarrel called: name='{name}', dataDir='{reg.dataDir}', mode={config.mode}"

  withLock reg.lock:
    reg.lastError = ""

    if name in reg.barrels:
      reg.lastError = fmt"Barrel '{name}' already exists"
      echo fmt"[DEBUG Session] createBarrel failed: {reg.lastError}"
      return false

    try:
      if config.mode == bmHugeCritBit:
        # HugeBarrel uses a directory, not a .data file
        let hugeBarrelPath = reg.dataDir / name
        echo fmt"[DEBUG Session] Creating HugeBarrel at '{hugeBarrelPath}'"
        let hb = openHugeBarrel(hugeBarrelPath, config)
        reg.barrels[name] = BarrelWrapper(kind: bkHuge, hugeBarrel: hb)
        echo fmt"[DEBUG Session] HugeBarrel created successfully for '{name}'"
      else:
        # Regular Barrel uses a .data file
        let dataPath = reg.dataDir / (name & ".data")
        echo fmt"[DEBUG Session] Creating regular Barrel at '{dataPath}'"
        let barrel = openBarrel(dataPath, config)
        reg.barrels[name] = BarrelWrapper(kind: bkRegular, regularBarrel: barrel)
        echo fmt"[DEBUG Session] Regular Barrel created successfully for '{name}'"
      return true
    except CatchableError as e:
      reg.lastError = fmt"Failed to create barrel '{name}': {e.msg}"
      echo fmt"[DEBUG Session] createBarrel exception: {reg.lastError}"
      echo fmt"[DEBUG Session] Exception type: {e.name}, full repr: {e.repr}"
      return false

proc openBarrel*(reg: var BarrelRegistry, name: string): bool =
  ## Open an existing barrel.
  ## Returns true if successful, false if barrel doesn't exist or fails to open.
  echo fmt"[DEBUG Session] openBarrel called: name='{name}'"

  withLock reg.lock:
    if name in reg.barrels:
      return true  # Already open

    # Try regular barrel first (.data file)
    let dataPath = reg.dataDir / (name & ".data")
    echo fmt"[DEBUG Session] openBarrel dataPath='{dataPath}'"

    if fileExists(dataPath):
      try:
        let barrel = openBarrel(dataPath, defaultBarrelConfig())
        reg.barrels[name] = BarrelWrapper(kind: bkRegular, regularBarrel: barrel)
        echo fmt"[DEBUG Session] Opened regular barrel for '{name}'"
        return true
      except CatchableError as e:
        echo fmt"[DEBUG Session] openBarrel exception: {e.msg}"
        return false

    # Try HugeBarrel (directory-based)
    let hugePath = reg.dataDir / name
    if dirExists(hugePath):
      try:
        let hb = openHugeBarrel(hugePath, defaultBarrelConfig())
        reg.barrels[name] = BarrelWrapper(kind: bkHuge, hugeBarrel: hb)
        echo fmt"[DEBUG Session] Opened HugeBarrel for '{name}'"
        return true
      except CatchableError as e:
        echo fmt"[DEBUG Session] openHugeBarrel exception: {e.msg}"
        return false

    echo fmt"[DEBUG Session] openBarrel failed: neither file nor directory exists"
    return false

proc getBarrel*(reg: var BarrelRegistry, name: string): Option[BarrelWrapper] =
  ## Get a barrel wrapper by name.
  ## Returns none if barrel doesn't exist.
  withLock reg.lock:
    if name in reg.barrels:
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

    # Delete the data file (regular barrel)
    let dataPath = reg.dataDir / (name & ".data")
    if fileExists(dataPath):
      try:
        removeFile(dataPath)
        return true
      except CatchableError:
        return false

    # Delete the directory (HugeBarrel)
    let hugePath = reg.dataDir / name
    if dirExists(hugePath):
      try:
        removeDir(hugePath)
        return true
      except CatchableError:
        return false

    return false  # Barrel doesn't exist

proc listBarrels*(reg: var BarrelRegistry): seq[string] =
  ## List all open barrels.
  result = @[]
  withLock reg.lock:
    for name in reg.barrels.keys:
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
  Session(id: id, currentBarrel: "", authSession: authjwt.AuthSession(authenticated: false))

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
    dataDir: dataDir,
    lock: Lock(),
    lastError: ""
  )
  initLock(result.lock)

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