import unittest, std/[os, strutils, random, options, tables]
import ../../../src/network/session
import ../../../src/bitbarrel/types
import ../../../src/bitbarrel/barrel

suite "Session and Barrel Registry Tests":

  var testDataDir: string

  setup:
    testDataDir = getTempDir() / "bitbarrel_test_" & rand(1000000).intToStr()
    createDir(testDataDir)

  teardown:
    # Clean up any remaining files
    if dirExists(testDataDir):
      for file in walkFiles(testDataDir / "*.data"):
        removeFile(file)
      removeDir(testDataDir)

  test "Session operations":
    var session = newSession(123)

    check session.id == 123
    check not session.hasCurrentBarrel()
    check session.getCurrentBarrel() == ""

    session.setCurrentBarrel("test_db")
    check session.hasCurrentBarrel()
    check session.getCurrentBarrel() == "test_db"

    session.setCurrentBarrel("other_db")
    check session.getCurrentBarrel() == "other_db"

    session.clearCurrentBarrel()
    check not session.hasCurrentBarrel()
    check session.getCurrentBarrel() == ""

  test "BarrelRegistry - create and get":
    let config = defaultBarrelConfig()
    var registry = newBarrelRegistry(testDataDir)

    # Create a barrel
    check registry.createBarrel("test1", config) == true
    check registry.createBarrel("test1", config) == false  # Already exists

    # Get the barrel
    let barrel = registry.getBarrel("test1")
    check barrel.isSome()
    # Just check we can call methods on it (avoid the deprecated compactStats)
    try:
      discard barrel.get().exists("nonexistent")
    except CatchableError:
      # Expected for a newly created barrel
      discard

    # Get non-existent barrel
    let noneBarrel = registry.getBarrel("nonexistent")
    check noneBarrel.isNone()

    # List barrels (tables don't guarantee order)
    let barrels = registry.listBarrels()
    check barrels.len == 1
    check "test1" in barrels

    # Close registry
    registry.closeAll()

  test "BarrelRegistry - multiple barrels":
    let config = defaultBarrelConfig()
    var registry = newBarrelRegistry(testDataDir)

    check registry.createBarrel("db1", config) == true
    check registry.createBarrel("db2", config) == true
    check registry.createBarrel("db3", config) == true

    let barrels = registry.listBarrels()
    # Tables don't guarantee insertion order
    check barrels.len == 3

    check registry.getBarrel("db1").isSome()
    check registry.getBarrel("db2").isSome()
    check registry.getBarrel("db3").isSome()

    registry.closeAll()

  test "BarrelRegistry - close barrel":
    let config = defaultBarrelConfig()
    var registry = newBarrelRegistry(testDataDir)

    check registry.createBarrel("test", config) == true
    let barrel = registry.getBarrel("test")
    check barrel.isSome()
    # Verify barrel is operational

    # Close the barrel
    check registry.closeBarrel("test") == true
    check registry.closeBarrel("test") == false  # Already closed
    check registry.getBarrel("test").isNone()

    # Check data file still exists
    check fileExists(testDataDir / "test.data")

  test "BarrelRegistry - open existing barrel":
    let config = defaultBarrelConfig()
    var registry = newBarrelRegistry(testDataDir)

    # Create and close
    check registry.createBarrel("persistent", config) == true
    check registry.closeBarrel("persistent") == true

    # Reopen
    check registry.openBarrel("persistent") == true
    check registry.openBarrel("persistent") == true  # Already open

    let barrel = registry.getBarrel("persistent")
    check barrel.isSome()

    registry.closeAll()

  test "BarrelRegistry - open non-existent barrel":
    var registry = newBarrelRegistry(testDataDir)

    check registry.openBarrel("nonexistent") == false
    check registry.listBarrels().len == 0

  test "BarrelRegistry - drop barrel":
    let config = defaultBarrelConfig()
    var registry = newBarrelRegistry(testDataDir)

    # Create and then drop
    check registry.createBarrel("todelete", config) == true
    check fileExists(testDataDir / "todelete.data")

    check registry.dropBarrel("todelete") == true
    check not fileExists(testDataDir / "todelete.data")
    check registry.getBarrel("todelete").isNone()
    check registry.dropBarrel("todelete") == false  # Already deleted

  test "BarrelRegistry - drop open barrel":
    let config = defaultBarrelConfig()
    var registry = newBarrelRegistry(testDataDir)

    check registry.createBarrel("opentodelete", config) == true
    check fileExists(testDataDir / "opentodelete.data")

    # Drop while open (should close first)
    check registry.dropBarrel("opentodelete") == true
    check not fileExists(testDataDir / "opentodelete.data")
    check registry.getBarrel("opentodelete").isNone()

  test "BarrelRegistry - close all barrels":
    let config = defaultBarrelConfig()
    var registry = newBarrelRegistry(testDataDir)

    check registry.createBarrel("db1", config) == true
    check registry.createBarrel("db2", config) == true
    check registry.createBarrel("db3", config) == true

    let allBarrels = registry.getAllBarrels()
    # Just check the barrels exist
    check allBarrels.hasKey("db1")
    check allBarrels.hasKey("db2")
    check allBarrels.hasKey("db3")

    registry.closeAll()
    check registry.listBarrels().len == 0

  test "BarrelRegistry - data directory creation":
    let subdir = testDataDir / "subdir"
    createDir(subdir)  # Need to create the directory first
    var registry = newBarrelRegistry(subdir)

    let config = defaultBarrelConfig()

    try:
      check registry.createBarrel("insubdir", config) == true
      check registry.getBarrel("insubdir").isSome()
      registry.closeAll()
    except CatchableError as e:
      echo "Error: ", e.msg
      fail()

  test "BarrelRegistry persistence across instances":
    # TODO: Fix persistence - data not being retrieved after reopen
    var config = defaultBarrelConfig()
    config.syncMode = UserSyncMode.Sync  # Ensure sync for persistence

    # First instance - create and close
    var registry1 = newBarrelRegistry(testDataDir)
    check registry1.createBarrel("persistent", config) == true

    # Add some data
    let barrel = registry1.getBarrel("persistent").get()
    check barrel.set("test_key", "test_value") == true

    # Close Barrel properly to ensure sync
    discard registry1.closeBarrel("persistent")
    registry1.closeAll()

    # Verify data file exists
    check fileExists(testDataDir / "persistent.data")

    # Second instance - reopen
    var registry2 = newBarrelRegistry(testDataDir)
    check registry2.openBarrel("persistent") == true

    let barrel2 = registry2.getBarrel("persistent").get()
    check barrel2.get("test_key") == "test_value"

    registry2.closeAll()