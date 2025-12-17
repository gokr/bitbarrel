## Session and Barrel Registry management for BitBarrel network server

import std/[tables, locks, os, options]
import ../bitbarrel/types
import ../bitbarrel/barrel

type
  Session* = object
    id*: uint64               ## WebSocket client ID
    currentBarrel*: string    ## Name of current barrel (empty = none)

  BarrelRegistry* = object
    barrels*: Table[string, Barrel]  ## name -> Barrel
    dataDir*: string                  ## Base directory for barrel data
    lock*: Lock

  BarrelError* = object of CatchableError


proc createBarrel*(reg: var BarrelRegistry, name: string, config: BarrelConfig): bool =
  ## Create a new barrel with the given configuration.
  ## Returns true if successful, false if barrel already exists or creation fails.
  withLock reg.lock:
    if name in reg.barrels:
      return false  # Barrel already exists

    let dataPath = reg.dataDir / (name & ".data")

    try:
      let barrel = openBarrel(dataPath, 1, config)
      reg.barrels[name] = barrel
      return true
    except CatchableError:
      return false

proc openBarrel*(reg: var BarrelRegistry, name: string): bool =
  ## Open an existing barrel.
  ## Returns true if successful, false if barrel doesn't exist or fails to open.
  withLock reg.lock:
    if name in reg.barrels:
      return true  # Already open

    let dataPath = reg.dataDir / (name & ".data")

    if not fileExists(dataPath):
      return false

    try:
      let barrel = openBarrel(dataPath, 1, defaultBarrelConfig())
      reg.barrels[name] = barrel
      return true
    except CatchableError:
      return false

proc getBarrel*(reg: var BarrelRegistry, name: string): Option[Barrel] =
  ## Get a barrel by name.
  ## Returns none if barrel doesn't exist.
  withLock reg.lock:
    if name in reg.barrels:
      return some(reg.barrels[name])
    else:
      return none(Barrel)

proc closeBarrel*(reg: var BarrelRegistry, name: string): bool =
  ## Close a barrel.
  ## Returns true if successful, false if barrel doesn't exist.
  withLock reg.lock:
    if name in reg.barrels:
      let barrel = reg.barrels[name]
      try:
        barrel.close()
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
      let barrel = reg.barrels[name]
      try:
        barrel.close()
      except CatchableError:
        discard
      reg.barrels.del(name)

    # Delete the data file
    let dataPath = reg.dataDir / (name & ".data")
    if fileExists(dataPath):
      try:
        removeFile(dataPath)
        return true
      except CatchableError:
        return false
    else:
      return false  # Barrel doesn't exist

proc listBarrels*(reg: var BarrelRegistry): seq[string] =
  ## List all open barrels.
  result = @[]
  withLock reg.lock:
    for name in reg.barrels.keys:
      result.add(name)

proc getAllBarrels*(reg: var BarrelRegistry): Table[string, Barrel] =
  ## Get a copy of all barrels (for stats etc.)
  result = initTable[string, Barrel]()
  withLock reg.lock:
    for name, barrel in reg.barrels.pairs:
      result[name] = barrel

proc closeAll*(reg: var BarrelRegistry) =
  ## Close all barrels. Call during server shutdown.
  withLock reg.lock:
    for name, barrel in reg.barrels.mpairs:
      try:
        barrel.close()
      except CatchableError:
        discard
    reg.barrels.clear()

proc newSession*(id: uint64): Session =
  ## Create a new session with the given ID.
  Session(id: id, currentBarrel: "")

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
    barrels: initTable[string, Barrel](),
    dataDir: dataDir,
    lock: Lock()
  )
  initLock(result.lock)