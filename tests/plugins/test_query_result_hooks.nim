## Unit tests for query result hooks plugin system

import std/[unittest, options, locks, strutils]
import ../../src/hooks/query_result_hooks

# Global thread-safe call order for testing
var
  testCallOrder: seq[string] = @[]
  testCallLock: Lock
  testHookCalled: bool = false
  testHookCalledLock: Lock

initLock(testCallLock)
initLock(testHookCalledLock)

# Helper templates for var parameters (need to be defined before use)
template toSeq(s: seq[(string, string)]): var seq[(string, string)] =
  var result = s
  result

template toVar(s: string): var string =
  var result = s
  result

template toVar(b: bool): var bool =
  var result = b
  result

suite "Query Result Hooks - Plugin Registry":

  setup:
    # Clear all plugins before each test
    clearAllHooks()

  teardown:
    # Clear all plugins after each test
    clearAllHooks()

  test "registerPlugin with unique name":
    let id = registerHook(
      name = "test_plugin",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkAny,
      description = "Test plugin"
    )
    check:
      id.startsWith("hook_")
      getHookCount() == 1

  test "registerPlugin with duplicate name raises error":
    discard registerHook(
      name = "duplicate",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkAny
    )

    expect ValueError:
      discard registerHook(
        name = "duplicate",
        hook = proc(m: HookMetadata, items: var seq[(string, string)],
                    nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
        kind = hkAny
      )

  test "getHookByName returns plugin when found":
    discard registerHook(
      name = "lookup_test",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkRangeQuery
    )

    let result = getHookByName("lookup_test")
    check:
      result.isSome()
      result.get().name == "lookup_test"
      result.get().kind == hkRangeQuery

  test "getHookByName returns none when not found":
    let result = getHookByName("nonexistent")
    check:
      result.isNone()

  test "unregisterPlugin removes plugin by id":
    let id = registerHook(
      name = "remove_by_id",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkAny
    )

    let removed = unregisterHook(id)
    check:
      removed
      getHookCount() == 0
      getHookByName("remove_by_id").isNone

  test "unregisterPlugin returns false for nonexistent id":
    let removed = unregisterHook("nonexistent_id")
    check:
      not removed

  test "unregisterPluginByName removes plugin by name":
    discard registerHook(
      name = "remove_by_name",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkAny
    )

    let removed = unregisterHookByName("remove_by_name")
    check:
      removed
      getHookCount() == 0

  test "listHooks returns all registered plugins":
    discard registerHook(
      name = "plugin1",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkRangeQuery
    )
    discard registerHook(
      name = "plugin2",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkPrefixQuery
    )

    let plugins = listHooks()
    check:
      plugins.len == 2
      plugins[0].name == "plugin1"
      plugins[1].name == "plugin2"

  test "isHookCompatible with matching kind":
    let plugin = HookRegistration(
      id: "test",
      name: "test",
      hook: nil,
      kind: hkRangeQuery,
      description: ""
    )
    check:
      plugin.isHookCompatible(hkRangeQuery)

  test "isHookCompatible with hkAny":
    let plugin = HookRegistration(
      id: "test",
      name: "test",
      hook: nil,
      kind: hkAny,
      description: ""
    )
    check:
      plugin.isHookCompatible(hkRangeQuery)
      plugin.isHookCompatible(hkPrefixQuery)
      plugin.isHookCompatible(hkAny)

  test "isHookCompatible returns false for mismatched kind":
    let plugin = HookRegistration(
      id: "test",
      name: "test",
      hook: nil,
      kind: hkRangeQuery,
      description: ""
    )
    check:
      not plugin.isHookCompatible(hkPrefixQuery)

suite "Query Result Hooks - Plugin Application":

  setup:
    clearAllHooks()

  teardown:
    clearAllHooks()

  test "applyQueryResultPlugins with empty list does nothing":
    var items = @[(("key1", "val1")), (("key2", "val2"))]
    var cursor = ""
    var hasMore = false

    let result = applyQueryResultHooks(@[], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items.len == 2
      items[0] == ("key1", "val1")

  test "applyQueryResultPlugins executes in client-specified order":
    testCallOrder.setLen(0)

    discard registerHook(
      name = "plugin_a",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        {.gcsafe.}:
          withLock testCallLock:
            testCallOrder.add("a"),
      kind = hkAny
    )
    discard registerHook(
      name = "plugin_b",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        {.gcsafe.}:
          withLock testCallLock:
            testCallOrder.add("b"),
      kind = hkAny
    )

    discard applyQueryResultHooks(@["plugin_b", "plugin_a"], HookMetadata(), (newSeq[(string, string)]()).toSeq, "".toVar, false.toVar)

    check:
      testCallOrder == @["b", "a"]

  test "applyQueryResultPlugins returns false for non-existent plugin":
    let result = applyQueryResultHooks(@["nonexistent"], HookMetadata(), (newSeq[(string, string)]()).toSeq, "".toVar, false.toVar)
    check:
      not result

  test "applyQueryResultPlugins returns false for incompatible plugin kind":
    discard registerHook(
      name = "range_only",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkRangeQuery
    )

    let metadata = HookMetadata(hookKind: hkPrefixQuery)
    let result = applyQueryResultHooks(@["range_only"], metadata, (newSeq[(string, string)]()).toSeq, "".toVar, false.toVar)

    check:
      not result

  test "plugin filters items":
    discard registerHook(
      name = "filter_test",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        var filtered: seq[(string, string)] = @[]
        for (k, v) in items:
          if not k.startsWith("_"):
            filtered.add((k, v))
        items = filtered,
      kind = hkAny
    )

    var items = @[("key1", "val1"), ("_hidden", "val2"), ("key2", "val3")]
    var cursor = ""
    var hasMore = false

    let result = applyQueryResultHooks(@["filter_test"], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items.len == 2
      items[0] == ("key1", "val1")
      items[1] == ("key2", "val3")

  test "plugin modifies items":
    discard registerHook(
      name = "modify_test",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        for i in 0..<items.len:
          items[i] = (items[i][0].toUpperAscii(), items[i][1]),
      kind = hkAny
    )

    var items = @[("key1", "val1"), ("key2", "val2")]
    var cursor = ""
    var hasMore = false

    let result = applyQueryResultHooks(@["modify_test"], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items[0] == ("KEY1", "val1")

  test "plugin modifies nextCursor and hasMore":
    discard registerHook(
      name = "limit_test",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        if items.len > 2:
          items.setLen(2)
          nextCursor = items[1][0]
          hasMore = true,
      kind = hkAny
    )

    var items = @[("key1", "val1"), ("key2", "val2"), ("key3", "val3")]
    var cursor = ""
    var hasMore = false

    let result = applyQueryResultHooks(@["limit_test"], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items.len == 2
      cursor == "key2"
      hasMore

  test "multiple plugins are chained":
    discard registerHook(
      name = "filter_a",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        var filtered: seq[(string, string)] = @[]
        for (k, v) in items:
          if k != "remove":
            filtered.add((k, v))
        items = filtered,
      kind = hkAny
    )
    discard registerHook(
      name = "modify_b",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        for i in 0..<items.len:
          items[i] = ("modified_" & items[i][0], items[i][1]),
      kind = hkAny
    )

    var items = @[("keep1", "val1"), ("remove", "val2"), ("keep2", "val3")]
    var cursor = ""
    var hasMore = false

    let result = applyQueryResultHooks(@["filter_a", "modify_b"], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items.len == 2
      items[0] == ("modified_keep1", "val1")
      items[1] == ("modified_keep2", "val3")

  test "plugin with hkAny works with all query kinds":
    discard registerHook(
      name = "any_test",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        for i in 0..<items.len:
          items[i] = ("any_" & items[i][0], items[i][1]),
      kind = hkAny
    )

    var items = @[("key1", "val1")]
    var cursor = ""
    var hasMore = false

    # Test with different query kinds
    for kind in [hkRangeQuery, hkPrefixQuery]:
      var testItems = items
      var testCursor = cursor
      var testHasMore = hasMore
      let metadata = HookMetadata(hookKind: kind)
      let result = applyQueryResultHooks(@["any_test"], metadata, testItems, testCursor, testHasMore)
      check:
        result
        testItems[0][0].startsWith("any_")

  test "hook error doesn't stop other hooks":
    testHookCalled = false
    discard registerHook(
      name = "error_trigger",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        raise newException(ValueError, "test error"),
      kind = hkAny
    )
    discard registerHook(
      name = "after_error",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        {.gcsafe.}:
          withLock testHookCalledLock:
            testHookCalled = true,
      kind = hkAny
    )

    var items = @[("key1", "val1")]
    var cursor = ""
    var hasMore = false

    # Should still return true and call subsequent hooks
    let result = applyQueryResultHooks(@["error_trigger", "after_error"], HookMetadata(), items, cursor, hasMore)

    check:
      result  # All plugins existed
      testHookCalled  # Second hook was called despite error in first
