import std/[os, tempfiles, times, random, strformat]
import bitbarrel/barrel
import bitbarrel/config

type
  BarrelRegistry = object
    barrels: Table[string, Barrel]
    dataDir: string

proc newBarrelRegistry(dataDir: string): BarrelRegistry =
  BarrelRegistry(barrels: initTable[string, Barrel](), dataDir: dataDir)

proc createBarrel(reg: var BarrelRegistry, name: string, config: BarrelConfig): bool =
  if name in reg.barrels:
    return false
  let dataPath = reg.dataDir / (name & ".data")
  try:
    let barrel = openBarrel(dataPath, config)
    reg.barrels[name] = barrel
    return true
  except CatchableError:
    return false

proc getBarrel(reg: var BarrelRegistry, name: string): Option[Barrel] =
  if name in reg.barrels:
    return some(reg.barrels[name])
  return none(Barrel)

proc dropBarrel(reg: var BarrelRegistry, name: string): bool =
  if name in reg.barrels:
    let barrel = reg.barrels[name]
    try:
      barrel.close()
    except CatchableError:
      discard
    reg.barrels.del(name)
  let dataPath = reg.dataDir / (name & ".data")
  if fileExists(dataPath):
    try:
      removeFile(dataPath)
      return true
    except CatchableError:
      return false
  return false

proc testDropBarrelAfterOperations() =
  echo "Testing dropBarrel after operations..."

  let dataDir = getTempDir() / "bb_drop_test_" & $epochTime()
  createDir(dataDir)
  defer: removeDir(dataDir)

  var reg = newBarrelRegistry(dataDir)

  # Create barrel
  let barrelName = "test_barrel"
  let config = defaultBarrelConfig()

  if not reg.createBarrel(barrelName, config):
    echo "FAILED: Could not create barrel"
    return

  echo "Created barrel: ", barrelName

  # Get barrel and do some operations
  let barrelOpt = reg.getBarrel(barrelName)
  if barrelOpt.isNone:
    echo "FAILED: Could not get barrel"
    return

  let barrel = barrelOpt.get[]

  # Add some data
  for i in 0..<100:
    let key = format("key_$1", i)
    let value = format("value_$1", rand(1000))
    if not barrel.set(key, value):
      echo "FAILED: Could not set ", key
      return

  echo "Added 100 keys"

  # Read some data
  assert barrel.get("key_0") != ""
  assert barrel.get("key_50") != ""

  echo "Read test passed"

  # Now drop the barrel - this should NOT crash
  if not reg.dropBarrel(barrelName):
    echo "FAILED: Could not drop barrel"
    return

  echo "Dropped barrel successfully"

  echo "SUCCESS: dropBarrel test passed!"

testDropBarrelAfterOperations()
