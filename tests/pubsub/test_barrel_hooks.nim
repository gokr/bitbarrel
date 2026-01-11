## Test Barrel Hooks Module
##
## Tests for global barrel hook registry and k/v change event triggering

import std/[unittest, strutils]
import ../../src/pubsub/barrel_hooks
import ../../src/pubsub/pubsub

suite "Barrel Hooks":
  setup:
    clearAllHooks()  # Reset global registry before each test

  teardown:
    clearAllHooks()  # Clean up after each test

  test "registerBarrelHook returns ID":
    proc myHook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      discard

    let hookId = registerBarrelHook(myHook)
    check hookId.len > 0
    check hookId.startsWith("hook_")
    check getHookCount() == 1

  test "registerBarrelHook multiple hooks":
    proc hook1(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      discard

    proc hook2(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      discard

    let id1 = registerBarrelHook(hook1)
    let id2 = registerBarrelHook(hook2)

    check id1 != id2
    check getHookCount() == 2

  test "triggerBarrelHooks calls all hooks":
    var called = 0

    proc hook1(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      inc called

    proc hook2(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      inc called

    discard registerBarrelHook(hook1)
    discard registerBarrelHook(hook2)

    triggerBarrelHooks("testdb", "key1", kvSet, "value1")
    check called == 2

  test "triggerBarrelHooks passes correct parameters":
    type
      TestData = ref object
        barrel: string
        key: string
        changeType: KvChangeType
        value: string

    let received = TestData()

    proc hook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      {.gcsafe.}:
        received.barrel = barrel
        received.key = key
        received.changeType = changeType
        received.value = value

    discard registerBarrelHook(hook)

    triggerBarrelHooks("mydb", "user:1000", kvSet, "Alice")

    check received.barrel == "mydb"
    check received.key == "user:1000"
    check received.changeType == kvSet
    check received.value == "Alice"

  test "triggerBarrelHooks with delete":
    type TestData = ref object
      changeType: KvChangeType

    let received = TestData(changeType: kvSet)

    proc hook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      {.gcsafe.}:
        received.changeType = changeType

    discard registerBarrelHook(hook)

    triggerBarrelHooks("mydb", "key1", kvDelete, "")

    check received.changeType == kvDelete

  test "hook priority ordering":
    type TestData = ref object
      order: seq[int]

    let received = TestData(order: @[])

    proc lowPriority(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      {.gcsafe.}:
        received.order.add(1)

    proc highPriority(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      {.gcsafe.}:
        received.order.add(2)

    proc mediumPriority(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      {.gcsafe.}:
        received.order.add(3)

    discard registerBarrelHook(lowPriority, priority=0)
    discard registerBarrelHook(highPriority, priority=10)
    discard registerBarrelHook(mediumPriority, priority=5)

    triggerBarrelHooks("testdb", "key1", kvSet, "value1")

    check received.order == @[2, 3, 1]  # High (10), medium (5), low (0)

  test "unregisterBarrelHook removes hook":
    var called = false

    proc myHook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      called = true

    let hookId = registerBarrelHook(myHook)
    check unregisterBarrelHook(hookId)
    check getHookCount() == 0

    triggerBarrelHooks("testdb", "key1", kvSet, "value1")
    check not called

  test "unregisterBarrelHook non-existent returns false":
    check not unregisterBarrelHook("non-existent-id")

  test "unregisterBarrelHook removes correct hook":
    var hook1Called = false
    var hook2Called = false

    proc hook1(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      hook1Called = true

    proc hook2(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      hook2Called = true

    discard registerBarrelHook(hook1)
    let id2 = registerBarrelHook(hook2)

    check unregisterBarrelHook(id2)
    check getHookCount() == 1

    triggerBarrelHooks("testdb", "key1", kvSet, "value1")

    check hook1Called
    check not hook2Called

  test "enableHook enables disabled hook":
    var called = false

    proc myHook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      called = true

    let hookId = registerBarrelHook(myHook, enabled=false)

    triggerBarrelHooks("testdb", "key1", kvSet, "value1")
    check not called

    check enableHook(hookId)

    triggerBarrelHooks("testdb", "key1", kvSet, "value1")
    check called

  test "enableHook non-existent returns false":
    check not enableHook("non-existent-id")

  test "disableHook disables enabled hook":
    var called = false

    proc myHook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      called = true

    let hookId = registerBarrelHook(myHook, enabled=true)

    check disableHook(hookId)

    triggerBarrelHooks("testdb", "key1", kvSet, "value1")
    check not called

  test "disableHook non-existent returns false":
    check not disableHook("non-existent-id")

  test "disabled hook not called":
    var called = false

    proc myHook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      called = true

    discard registerBarrelHook(myHook, enabled=false)

    triggerBarrelHooks("testdb", "key1", kvSet, "value1")
    check not called

  test "hook error does not stop other hooks":
    var hook1Called = false
    var hook2Called = false

    proc errorHook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      raise newException(CatchableError, "Test error")

    proc goodHook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      hook2Called = true

    discard registerBarrelHook(errorHook)
    discard registerBarrelHook(goodHook)

    # Should not raise, should call goodHook despite errorHook failing
    triggerBarrelHooks("testdb", "key1", kvSet, "value1")
    check hook2Called

  test "listHooks returns all hooks":
    proc hook1(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      discard

    proc hook2(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      discard

    discard registerBarrelHook(hook1)
    discard registerBarrelHook(hook2)

    let hooks = listHooks()
    check hooks.len == 2

  test "listHooks returns empty when no hooks":
    let hooks = listHooks()
    check hooks.len == 0

  test "clearAllHooks removes all hooks":
    proc hook1(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      discard

    proc hook2(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      discard

    discard registerBarrelHook(hook1)
    discard registerBarrelHook(hook2)
    check getHookCount() == 2

    clearAllHooks()
    check getHookCount() == 0

  test "multiple sequential triggers":
    var callCount = 0

    proc counter(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      inc callCount

    discard registerBarrelHook(counter)

    triggerBarrelHooks("db1", "key1", kvSet, "val1")
    triggerBarrelHooks("db1", "key2", kvSet, "val2")
    triggerBarrelHooks("db2", "key1", kvDelete, "")

    check callCount == 3

  test "hook receives empty value on delete":
    type TestData = ref object
      value: string

    let received = TestData(value: "not empty")

    proc hook(barrel: string, key: string, changeType: KvChangeType, value: string) {.gcsafe.} =
      {.gcsafe.}:
        received.value = value

    discard registerBarrelHook(hook)

    triggerBarrelHooks("mydb", "key1", kvDelete, "")

    check received.value == ""
