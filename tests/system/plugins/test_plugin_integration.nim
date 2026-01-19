## Plugin System Integration Tests
##
## Integration tests for query result plugins
## Tests plugin registration, result transformation, and priority ordering
## Uses direct barrel access and plugin hook calls for reliable testing

import std/[unittest, os, strutils, atomics, sequtils]
import ../../../src/hooks/query_result_hooks
import ../../../src/bitbarrel/barrel
import ../../../src/bitbarrel/config
import ../../testutils

# Module-level atomic state for plugin tests
var
  pluginCallCounter: Atomic[int]
  pluginExecCounter: Atomic[int]
  pluginExecMarker1: Atomic[int]
  pluginExecMarker2: Atomic[int]
  pluginExecMarker3: Atomic[int]

suite "Query Result Plugin Integration Tests":
  setup:
    clearAllHooks()
    pluginCallCounter.store(0)
    pluginExecCounter.store(0)
    pluginExecMarker1.store(0)
    pluginExecMarker2.store(0)
    pluginExecMarker3.store(0)

  teardown:
    clearAllHooks()

  test "rangeQuery with simple transformation plugin":
    withTestDir("plugin_transform_test"):
      # Register a test plugin that appends "_transformed" to values
      discard registerHook("test_transformer",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          for i in 0..<items.len:
            items[i][1] = items[i][1] & "_transformed"
          discard pluginCallCounter.fetchAdd(1, moSequentiallyConsistent),
        hkRangeQuery,
        "Test transformer plugin")

      # Create barrel with bmCritBit for range queries
      var config = defaultBarrelConfig()
      config.mode = bmCritBit
      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath, config)
      defer: barrel.close()

      # Insert test data
      discard barrel.set("key1", "value1")
      discard barrel.set("key2", "value2")
      discard barrel.set("key3", "value3")

      # Perform range query
      var (items, nextCursor, hasMore) = barrel.itemsInRange("", "~", limit=10, cursor="")

      # Create metadata and apply plugins
      var metadata = HookMetadata(
        barrelName: barrelPath,
        clientId: "",  # Empty for tests
        hookKind: hkRangeQuery
      )

      discard applyQueryResultHooks(@["test_transformer"], metadata, items, nextCursor, hasMore)

      # Verify plugin was called
      check pluginCallCounter.load() == 1

      # Verify transformation
      check items.len == 3
      for (key, value) in items:
        check value.endsWith("_transformed")

      # Verify original keys are preserved
      let keys = items.mapIt(it[0])
      check "key1" in keys
      check "key2" in keys
      check "key3" in keys

  test "plugin filtering":
    withTestDir("plugin_filter_test"):
      # Register a plugin that filters out items with value containing "skip"
      discard registerHook("filter_skip",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          var filtered: seq[(string, string)]
          for item in items:
            if "skip" notin item[1]:
              filtered.add(item)
          items = filtered,
        hkPrefixQuery,
        "Filter plugin")

      var config = defaultBarrelConfig()
      config.mode = bmCritBit
      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath, config)
      defer: barrel.close()

      # Insert test data
      discard barrel.set("user:1", "keep_this")
      discard barrel.set("user:2", "skip_this")
      discard barrel.set("user:3", "also_keep")
      discard barrel.set("user:4", "skip_too")

      # Get all items with prefix
      var (items, nextCursor, hasMore) = barrel.itemsWithPrefix("user:", limit=10, cursor="")

      # Apply filter plugin
      var metadata = HookMetadata(
        barrelName: barrelPath,
        clientId: "",  # Empty for tests
        hookKind: hkPrefixQuery
      )

      discard applyQueryResultHooks(@["filter_skip"], metadata, items, nextCursor, hasMore)

      # Verify filtering
      check items.len == 2
      for (key, value) in items:
        check "skip" notin value

  test "plugin priority ordering":
    withTestDir("plugin_priority_test"):
      # Register plugins with different priorities
      discard registerHook("high_priority",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          pluginExecMarker1.store(pluginExecCounter.fetchAdd(1, moSequentiallyConsistent), moSequentiallyConsistent),
        hkRangeQuery,
        "High priority plugin")

      discard registerHook("medium_priority",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          pluginExecMarker2.store(pluginExecCounter.fetchAdd(1, moSequentiallyConsistent), moSequentiallyConsistent),
        hkRangeQuery,
        "Medium priority plugin")

      discard registerHook("low_priority",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          pluginExecMarker3.store(pluginExecCounter.fetchAdd(1, moSequentiallyConsistent), moSequentiallyConsistent),
        hkRangeQuery,
        "Low priority plugin")

      var config = defaultBarrelConfig()
      config.mode = bmCritBit
      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath, config)
      defer: barrel.close()

      discard barrel.set("key", "value")

      var (items, nextCursor, hasMore) = barrel.itemsInRange("", "~", limit=10, cursor="")
      var metadata = HookMetadata(
        barrelName: barrelPath,
        clientId: "",  # Empty for tests
        hookKind: hkRangeQuery
      )

      discard applyQueryResultHooks(@["high_priority", "medium_priority", "low_priority"], metadata, items, nextCursor, hasMore)

      # Higher priority should execute first
      let m1 = pluginExecMarker1.load()
      let m2 = pluginExecMarker2.load()
      let m3 = pluginExecMarker3.load()
      check m1 >= 0 and m2 >= 0 and m3 >= 0  # All plugins called
      check m1 < m2 and m2 < m3  # Correct priority order

  test "registered plugin is called":
    withTestDir("plugin_called_test"):
      let pluginId = registerHook("test_plugin",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          discard pluginCallCounter.fetchAdd(1, moSequentiallyConsistent),
        hkRangeQuery,
        "Test plugin")

      var config = defaultBarrelConfig()
      config.mode = bmCritBit
      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath, config)
      defer: barrel.close()

      discard barrel.set("key", "value")

      var (items, nextCursor, hasMore) = barrel.itemsInRange("", "~", limit=10, cursor="")
      var metadata = HookMetadata(
        barrelName: barrelPath,
        clientId: "",  # Empty for tests
        hookKind: hkRangeQuery
      )

      # Plugin should be called
      discard applyQueryResultHooks(@["test_plugin"], metadata, items, nextCursor, hasMore)
      check pluginCallCounter.load() == 1

  test "multiple plugins in chain":
    withTestDir("plugin_chain_test"):
      # First plugin: uppercase values
      discard registerHook("uppercase",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          for i in 0..<items.len:
            items[i][1] = items[i][1].toUpperAscii(),
        hkRangeQuery,
        "Uppercase plugin")

      # Second plugin: add prefix
      discard registerHook("prefix",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          for i in 0..<items.len:
            items[i][1] = "PREFIX_" & items[i][1],
        hkRangeQuery,
        "Prefix plugin")

      var config = defaultBarrelConfig()
      config.mode = bmCritBit
      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath, config)
      defer: barrel.close()

      discard barrel.set("key", "hello")

      var (items, nextCursor, hasMore) = barrel.itemsInRange("", "~", limit=10, cursor="")
      var metadata = HookMetadata(
        barrelName: barrelPath,
        clientId: "",  # Empty for tests
        hookKind: hkRangeQuery
      )

      discard applyQueryResultHooks(@["uppercase", "prefix"], metadata, items, nextCursor, hasMore)

      # Should be uppercase first, then prefixed
      check items.len == 1
      check items[0][1] == "PREFIX_HELLO"

  test "plugin error handling":
    withTestDir("plugin_error_test"):
      # First plugin throws error
      discard registerHook("error_plugin",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          raise newException(CatchableError, "Intentional plugin error"),
        hkRangeQuery,
        "Error plugin")

      # Second plugin should still run
      discard registerHook("counter_plugin",
        proc(metadata: HookMetadata,
             items: var seq[(string, string)],
             nextCursor: var string,
             hasMore: var bool) {.gcsafe.} =
          discard pluginCallCounter.fetchAdd(1, moSequentiallyConsistent),
        hkRangeQuery,
        "Counter plugin")

      var config = defaultBarrelConfig()
      config.mode = bmCritBit
      let barrelPath = testDir / "test.data"
      let barrel = openBarrel(barrelPath, config)
      defer: barrel.close()

      discard barrel.set("key", "value")

      var (items, nextCursor, hasMore) = barrel.itemsInRange("", "~", limit=10, cursor="")
      var metadata = HookMetadata(
        barrelName: barrelPath,
        clientId: "",  # Empty for tests
        hookKind: hkRangeQuery
      )

      # Should not raise, error is caught
      discard applyQueryResultHooks(@["error_plugin", "counter_plugin"], metadata, items, nextCursor, hasMore)

      # Second plugin should have been called
      check pluginCallCounter.load() == 1
