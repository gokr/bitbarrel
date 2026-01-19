## Barrel Hook Integration Tests
##
## Integration tests for barrel event hooks
## Tests hook registration, triggering on set/delete operations, and priority ordering
## Uses direct barrel access (not network) for reliable testing

import std/[unittest, os, atomics, strutils]
import ../../src/pubsub/barrel_hooks
import ../../src/pubsub/pubsub
import ../../src/bitbarrel/barrel
import ../testutils

# Module-level test state (reset in setup/teardown)
var
  testHookCalled: Atomic[bool]
  testDeleteHookCalled: Atomic[bool]
  testDeleteType: Atomic[int]  # store KvChangeType as int
  testExecCounter: Atomic[int]  # global counter for execution order
  testExecMarker1: Atomic[int]
  testExecMarker2: Atomic[int]
  testExecMarker3: Atomic[int]
  testSecondHookCalled: Atomic[bool]

suite "Barrel Hook Integration Tests":
  setup:
    clearAllHooks()
    # Reset module-level test state
    testHookCalled.store(false)
    testDeleteHookCalled.store(false)
    testDeleteType.store(0)
    testExecCounter.store(0)
    testExecMarker1.store(0)
    testExecMarker2.store(0)
    testExecMarker3.store(0)
    testSecondHookCalled.store(false)

  teardown:
    clearAllHooks()

  test "delete operation triggers hook":
    withTestDir("hook_delete_test"):
      proc deleteHook(barrelName: string, key: string,
                      changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        testDeleteHookCalled.store(true, moSequentiallyConsistent)
        testDeleteType.store(ord(changeType), moSequentiallyConsistent)

      discard registerBarrelHook(deleteHook, enabled = true)

      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath)
      defer: barrel.close()

      # Set a key
      discard barrel.set("to_delete", "value")

      # Delete the key - this triggers the hook
      discard barrel.delete("to_delete")

      check testDeleteHookCalled.load()
      check testDeleteType.load() == ord(pubsub.kvDelete)

  test "set operation triggers hook":
    withTestDir("hook_set_test"):
      proc setHook(barrelName: string, key: string,
                   changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        testHookCalled.store(true, moSequentiallyConsistent)

      discard registerBarrelHook(setHook, enabled = true)

      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath)
      defer: barrel.close()

      discard barrel.set("key", "value")

      check testHookCalled.load()

  test "hook priority ordering":
    withTestDir("hook_priority_test"):
      proc highPriorityHook(barrelName: string, key: string,
                            changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        testExecMarker1.store(testExecCounter.fetchAdd(1, moSequentiallyConsistent), moSequentiallyConsistent)

      proc mediumPriorityHook(barrelName: string, key: string,
                              changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        testExecMarker2.store(testExecCounter.fetchAdd(1, moSequentiallyConsistent), moSequentiallyConsistent)

      proc lowPriorityHook(barrelName: string, key: string,
                           changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        testExecMarker3.store(testExecCounter.fetchAdd(1, moSequentiallyConsistent), moSequentiallyConsistent)

      # Register hooks with different priorities
      discard registerBarrelHook(highPriorityHook, enabled = true, priority = 10)
      discard registerBarrelHook(mediumPriorityHook, enabled = true, priority = 5)
      discard registerBarrelHook(lowPriorityHook, enabled = true, priority = 0)

      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath)
      defer: barrel.close()

      discard barrel.set("key", "value")

      # Higher priority hooks should be called first
      let m1 = testExecMarker1.load()
      let m2 = testExecMarker2.load()
      let m3 = testExecMarker3.load()
      check m1 >= 0 and m2 >= 0 and m3 >= 0  # All hooks called
      check m1 < m2 and m2 < m3  # Correct priority order

  test "disabled hook is not called":
    withTestDir("hook_disabled_test"):
      proc disabledHook(barrelName: string, key: string,
                        changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        testHookCalled.store(true, moSequentiallyConsistent)

      let hookId = registerBarrelHook(disabledHook, enabled = false)

      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath)
      defer: barrel.close()

      discard barrel.set("key", "value")

      check not testHookCalled.load()

      # Enable hook and test again
      check enableHook(hookId)
      discard barrel.set("key2", "value2")
      check testHookCalled.load()

  test "hook error does not break subsequent hooks":
    withTestDir("hook_error_test"):
      proc errorHook(barrelName: string, key: string,
                     changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        raise newException(CatchableError, "Intentional hook error")

      proc secondHook(barrelName: string, key: string,
                      changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        testSecondHookCalled.store(true, moSequentiallyConsistent)

      # First hook throws exception
      discard registerBarrelHook(errorHook, enabled = true)
      # Second hook should still be called
      discard registerBarrelHook(secondHook, enabled = true)

      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath)
      defer: barrel.close()

      # Should not raise exception
      discard barrel.set("key", "value")

      # Second hook should have been called
      check testSecondHookCalled.load()

  test "hook receives correct barrel name":
    withTestDir("hook_barrel_name_test"):
      type TestData = ref object
        barrelName: string

      let received = TestData(barrelName: "")

      proc nameHook(barrelName: string, key: string,
                    changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        {.gcsafe.}:
          received.barrelName = barrelName

      discard registerBarrelHook(nameHook, enabled = true)

      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath)
      defer: barrel.close()

      discard barrel.set("key", "value")

      check received.barrelName.len > 0
      check received.barrelName.contains("test.data")

  test "hook receives correct key and value":
    withTestDir("hook_key_value_test"):
      type TestData = ref object
        key: string
        value: string

      let received = TestData(key: "", value: "")

      proc kvHook(barrelName: string, key: string,
                  changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        {.gcsafe.}:
          received.key = key
          received.value = value

      discard registerBarrelHook(kvHook, enabled = true)

      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath)
      defer: barrel.close()

      discard barrel.set("test_key", "test_value")

      check received.key == "test_key"
      check received.value == "test_value"

  test "multiple sequential operations trigger hooks":
    withTestDir("hook_sequential_test"):
      var callCount: Atomic[int]
      callCount.store(0)

      proc countHook(barrelName: string, key: string,
                     changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        discard callCount.fetchAdd(1, moSequentiallyConsistent)

      discard registerBarrelHook(countHook, enabled = true)

      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath)
      defer: barrel.close()

      discard barrel.set("key1", "value1")
      discard barrel.set("key2", "value2")
      discard barrel.set("key3", "value3")
      discard barrel.delete("key1")

      check callCount.load() == 4
