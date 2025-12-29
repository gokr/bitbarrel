## Session and Barrel Registry management for BitBarrel network server

import std/[tables, locks, os, options, strformat]
import ../bitbarrel/types
import ../bitbarrel/barrel
import auth as authjwt

type
  Session* = object
    id*: uint64               ## WebSocket client ID
    currentBarrel*: string    ## Name of current barrel (empty = none)
    authSession*: authjwt.AuthSession  ## Authentication session data

  BarrelRegistry* = object
    barrels*: Table[string, Barrel]  ## name -> Barrel
    dataDir*: string                  ## Base directory for barrel data
    lock*: Lock
    lastError*: string               ## Last error message for debugging

  BarrelError* = object of CatchableError


proc createBarrel*(reg: var BarrelRegistry, name: string, config: BarrelConfig): bool =
  ## Create a new barrel with the given configuration.
  ## Returns true if successful, false if barrel already exists or creation fails.
  ## Sets reg.lastError with detailed error message on failure.
  echo fmt"[DEBUG Session] createBarrel called: name='{name}', dataDir='{reg.dataDir}'"

  withLock reg.lock:
    reg.lastError = ""

    if name in reg.barrels:
      reg.lastError = fmt"Barrel '{name}' already exists"
      echo fmt"[DEBUG Session] createBarrel failed: {reg.lastError}"
      return false

    let dataPath = reg.dataDir / (name & ".data")
    echo fmt"[DEBUG Session] dataPath='{dataPath}', trying to open barrel..."

    try:
      let barrel = openBarrel(dataPath, config)
      reg.barrels[name] = barrel
      echo fmt"[DEBUG Session] createBarrel succeeded for '{name}'"
      return true
    except CatchableError as e:
      reg.lastError = fmt"Failed to open barrel at '{dataPath}': {e.msg}"
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

    let dataPath = reg.dataDir / (name & ".data")
    echo fmt"[DEBUG Session] openBarrel dataPath='{dataPath}'"

    if not fileExists(dataPath):
      echo fmt"[DEBUG Session] openBarrel failed: path does not exist"
      return false

    try:
      let barrel = openBarrel(dataPath, defaultBarrelConfig())
      reg.barrels[name] = barrel
      echo fmt"[DEBUG Session] openBarrel succeeded for '{name}'"
      return true
    except CatchableError as e:
      echo fmt"[DEBUG Session] openBarrel exception: {e.msg}"
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
    barrels: initTable[string, Barrel](),
    dataDir: dataDir,
    lock: Lock(),
    lastError: ""
  )
  initLock(result.lock)