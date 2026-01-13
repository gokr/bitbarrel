## Unit tests for query result hooks plugin system

import std/[unittest, strutils, json, options]
import ../../src/plugins/query_result_hooks

suite "Query Result Hooks - Plugin Registry":

  setup:
    # Clear all plugins before each test
    clearAllPlugins()

  teardown:
    # Clear all plugins after each test
    clearAllPlugins()

  test "registerPlugin with unique name":
    let id = registerPlugin(
      name = "test_plugin",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkAny,
      description = "Test plugin"
    )
    check:
      id.startsWith("plugin_")
      getPluginCount() == 1

  test "registerPlugin with duplicate name raises error":
    discard registerPlugin(
      name = "duplicate",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkAny
    )

    expect ValueError:
      discard registerPlugin(
        name = "duplicate",
        hook = proc(m: HookMetadata, items: var seq[(string, string)],
                    nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
        kind = hkAny
      )

  test "getPluginByName returns plugin when found":
    discard registerPlugin(
      name = "lookup_test",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkRangeQuery
    )

    let result = getPluginByName("lookup_test")
    check:
      result.isSome()
      result.get().name == "lookup_test"
      result.get().kind == hkRangeQuery

  test "getPluginByName returns none when not found":
    let result = getPluginByName("nonexistent")
    check:
      result.isNone()

  test "unregisterPlugin removes plugin by id":
    let id = registerPlugin(
      name = "remove_by_id",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkAny
    )

    let removed = unregisterPlugin(id)
    check:
      removed
      getPluginCount() == 0
      getPluginByName("remove_by_id").isNone

  test "unregisterPlugin returns false for nonexistent id":
    let removed = unregisterPlugin("nonexistent_id")
    check:
      not removed

  test "unregisterPluginByName removes plugin by name":
    discard registerPlugin(
      name = "remove_by_name",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkAny
    )

    let removed = unregisterPluginByName("remove_by_name")
    check:
      removed
      getPluginCount() == 0

  test "listPlugins returns all registered plugins":
    discard registerPlugin(
      name = "plugin1",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkRangeQuery
    )
    discard registerPlugin(
      name = "plugin2",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkPrefixQuery
    )

    let plugins = listPlugins()
    check:
      plugins.len == 2
      plugins[0].name == "plugin1"
      plugins[1].name == "plugin2"

  test "isPluginCompatible with matching kind":
    let plugin = PluginRegistration(
      id: "test",
      name: "test",
      hook: nil,
      kind: hkRangeQuery,
      description: ""
    )
    check:
      plugin.isPluginCompatible(hkRangeQuery)

  test "isPluginCompatible with hkAny":
    let plugin = PluginRegistration(
      id: "test",
      name: "test",
      hook = nil,
      kind = hkAny,
      description = ""
    )
    check:
      plugin.isPluginCompatible(hkRangeQuery)
      plugin.isPluginCompatible(hkPrefixQuery)
      plugin.isPluginCompatible(hkAny)

  test "isPluginCompatible returns false for mismatched kind":
    let plugin = PluginRegistration(
      id: "test",
      name: "test",
      hook = nil,
      kind: hkRangeQuery,
      description = ""
    )
    check:
      not plugin.isPluginCompatible(hkPrefixQuery)

suite "Query Result Hooks - Plugin Application":

  setup:
    clearAllPlugins()

  teardown:
    clearAllPlugins()

  test "applyQueryResultPlugins with empty list does nothing":
    var items = @[(("key1", "val1")), (("key2", "val2"))]
    var cursor = ""
    var hasMore = false

    let result = applyQueryResultPlugins(@[], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items.len == 2
      items[0] == ("key1", "val1")

  test "applyQueryResultPlugins executes in client-specified order":
    var callOrder: seq[string] = @[]

    discard registerPlugin(
      name = "plugin_a",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        callOrder.add("a"),
      kind = hkAny
    )
    discard registerPlugin(
      name = "plugin_b",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        callOrder.add("b"),
      kind = hkAny
    )

    discard applyQueryResultPlugins(@["plugin_b", "plugin_a"], HookMetadata(), @[].toSeq, "".toVar, false.toVar)

    check:
      callOrder == @["b", "a"]

  test "applyQueryResultPlugins returns false for non-existent plugin":
    let result = applyQueryResultPlugins(@["nonexistent"], HookMetadata(), @[].toSeq, "".toVar, false.toVar)
    check:
      not result

  test "applyQueryResultPlugins returns false for incompatible plugin kind":
    discard registerPlugin(
      name = "range_only",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} = discard,
      kind = hkRangeQuery
    )

    let metadata = HookMetadata(hookKind: hkPrefixQuery)
    let result = applyQueryResultPlugins(@["range_only"], metadata, @[].toSeq, "".toVar, false.toVar)

    check:
      not result

  test "plugin filters items":
    discard registerPlugin(
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

    let result = applyQueryResultPlugins(@["filter_test"], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items.len == 2
      items[0] == ("key1", "val1")
      items[1] == ("key2", "val3")

  test "plugin modifies items":
    discard registerPlugin(
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

    let result = applyQueryResultPlugins(@["modify_test"], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items[0] == ("KEY1", "val1")

  test "plugin modifies nextCursor and hasMore":
    discard registerPlugin(
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

    let result = applyQueryResultPlugins(@["limit_test"], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items.len == 2
      cursor == "key2"
      hasMore

  test "multiple plugins are chained":
    discard registerPlugin(
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
    discard registerPlugin(
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

    let result = applyQueryResultPlugins(@["filter_a", "modify_b"], HookMetadata(), items, cursor, hasMore)

    check:
      result
      items.len == 2
      items[0] == ("modified_keep1", "val1")
      items[1] == ("modified_keep2", "val3")

  test "plugin with hkAny works with all query kinds":
    discard registerPlugin(
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
      let result = applyQueryResultPlugins(@["any_test"], metadata, testItems, testCursor, testHasMore)
      check:
        result
        testItems[0][0].startsWith("any_")

  test "hook error doesn't stop other hooks":
    discard registerPlugin(
      name = "error_trigger",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        raise newException(ValueError, "test error"),
      kind = hkAny
    )
    var called = false
    discard registerPlugin(
      name = "after_error",
      hook = proc(m: HookMetadata, items: var seq[(string, string)],
                  nextCursor: var string, hasMore: var bool) {.gcsafe.} =
        called = true,
      kind = hkAny
    )

    var items = @[("key1", "val1")]
    var cursor = ""
    var hasMore = false

    # Should still return true and call subsequent hooks
    let result = applyQueryResultPlugins(@["error_trigger", "after_error"], HookMetadata(), items, cursor, hasMore)

    check:
      result  # All plugins existed
      called  # Second hook was called despite error in first

# Helper for var string/bool parameters
template toVar(s: string): var string =
  var result = s
  result

template toVar(b: bool): var bool =
  var result = b
  result

# Helper for seq conversion
template toSeq(s: seq[(string, string)]): var seq[(string, string)] =
  var result = s
  result
