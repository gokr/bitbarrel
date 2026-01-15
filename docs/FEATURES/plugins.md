# Query Result Plugins

BitBarrel's plugin system allows you to transform query results dynamically before they are returned to clients. Plugins can filter, modify, or enrich range and prefix query results based on your application needs.

## Overview

The query result plugin system provides:

- **Dynamic result transformation** - Modify query results at runtime
- **Type-safe plugin registration** - Register plugins with clear boundaries
- **Hook-based architecture** - Apply hooks to range and prefix queries
- **Thread-safe registry** - Safe concurrent plugin management
- **Client-transparent** - Plugins work seamlessly with network clients

## Plugin Types

### Range Query Plugins (`hkRangeQuery`)
Applied to range query results:
- `itemsInRange()` / `rangeQuery()`
- Affects both key-value pairs and keys-only variants

### Prefix Query Plugins (`hkPrefixQuery`)
Applied to prefix query results:
- `itemsWithPrefix()` / `prefixQuery()`
- Affects both key-value pairs and keys-only variants

## Creating a Plugin

### Basic Plugin Structure

```nim
import plugins/query_result_hooks

# Define your plugin logic
proc myFilterPlugin(metadata: HookMetadata,
                    items: var seq[(string, string)],
                    nextCursor: var string,
                    hasMore: var bool) =
  ## Filter items based on custom logic
  items.keepItIf(it[1].contains("active"))

# Register the plugin
let pluginId = registerPlugin(
  "activeItemsOnly",     # Unique plugin name
  myFilterPlugin,        # Plugin procedure
  hkRangeQuery,          # Hook type
  "Filter to active items only"  # Description
)
```

### Plugin Parameters

Plugins receive four parameters:

1. **metadata** - HookMetadata containing:
   - `hookType` - Type of query (range or prefix)
   - `queryParams` - Original query parameters (startKey, endKey, prefix, etc.)
   - `pluginParams` - Additional parameters from query (if any)

2. **items** - Sequence of (key, value) tuples to transform
   - Modify in-place to filter or transform results
   - Can add, remove, or modify items

3. **nextCursor** - Cursor for pagination
   - Can be updated for custom cursor logic

4. **hasMore** - Boolean indicating if more results available
   - Can be modified to control pagination

## Plugin Examples

### Example 1: Filter by Value Content

Filter results to only include values containing specific keywords:

```nim
proc filterByKeyword(metadata: HookMetadata,
                     items: var seq[(string, string)],
                     nextCursor: var string,
                     hasMore: var bool) =
  items.keepItIf(it[1].contains("premium"))

let pluginId = registerPlugin(
  "premiumOnly",
  filterByKeyword,
  hkRangeQuery,
  "Show only premium items"
)
```

### Example 2: Limit Result Count

Enforce maximum result count (different from query limit):

```nim
proc enforceMaxLimit(metadata: HookMetadata,
                     items: var seq[(string, string)],
                     nextCursor: var string,
                     hasMore: var bool) =
  if items.len > 100:
    items.setLen(100)
    hasMore = true  # Indicate more results available

let pluginId = registerPlugin(
  "max100Results",
  enforceMaxLimit,
  hkRangeQuery,
  "Limit to maximum 100 results"
)
```

### Example 3: Transform Values

Modify values before returning to client:

```nim
proc addTimestamp(metadata: HookMetadata,
                  items: var seq[(string, string)],
                  nextCursor: var string,
                  hasMore: var bool) =
  let timestamp = $epochTime()
  for item in items.mitems:
    item[1] = fmt"{item[1]}|retrieved_at={timestamp}"

let pluginId = registerPlugin(
  "addTimestamp",
  addTimestamp,
  hkPrefixQuery,
  "Add retrieval timestamp to values"
)
```

### Example 4: Access Control Filter

Filter results based on user permissions:

```nim
proc userAccessFilter(metadata: HookMetadata,
                      items: var seq[(string, string)],
                      nextCursor: var string,
                      hasMore: var bool) =
  # Assume we have currentUserId available
  items.keepItIf(it[0].startsWith(fmt"user:{currentUserId}:"))

let pluginId = registerPlugin(
  "userAccessOnly",
  userAccessFilter,
  hkRangeQuery,
  "Filter to user's own data only"
)
```

## Using Plugins

### Server-Side Usage (Direct API)

```nim
import bitbarrel
import plugins/query_result_hooks

# Register plugin first
let pluginId = registerPlugin("myPlugin", myPluginProc, hkRangeQuery, "Description")

# Open barrel in bmCritBit mode for range queries
var barrel = openBarrel("data.db", bmCritBit)

// Use plugin in range query
let (items, cursor, hasMore) = barrel.itemsInRange(
  startKey = "user:1000",
  endKey = "user:2000",
  limit = 100,
  cursor = "",
  plugins = @["myPlugin"]  // Apply plugin
)
```

### Network Client Usage

```nim
import network/client

var client = newClient("localhost", 9876.Port)
client.connect()
discard client.useBarrel("mydb")

// Plugin is specified in query parameters
let (items, cursor, hasMore) = client.rangeQuery(
  startKey = "user:1000",
  endKey = "user:2000",
  limit = 100,
  cursor = "",
  plugins = @["activeOnly", "maxResults"]  // Multiple plugins
)

// Prefix query with plugin
let (items, cursor, hasMore) = client.prefixQuery(
  prefix = "order:2024-",
  limit = 50,
  cursor = "",
  plugins = @["filterByStatus"]  // Plugin applied
)
```

### Plugin Chaining

Multiple plugins can be applied to the same query. They execute in the order specified:

```nim
// Plugins execute in order: filter1 → filter2 → transform
let plugins = @["filter1", "filter2", "transform"]
let (items, cursor, hasMore) = client.rangeQuery(
  "start", "end", 100, "", plugins
)
```

**Plugin execution order matters** - later plugins receive results from earlier plugins.

## Managing Plugins

### Listing Registered Plugins

```nim
import plugins/query_result_hooks

let registeredPlugins = getRegisteredPlugins()
for name, hookType in registeredPlugins:
  echo fmt"Plugin: {name}, Type: {hookType}"
```

### Unregistering Plugins

```nim
import plugins/query_result_hooks

# Unregister by name
unregisterPlugin("myPlugin")

# After unregistering, plugin is no longer available for queries
```

### Plugin Lifecycle

1. **Registration**: Plugin is registered with the global registry
2. **Validation**: Hook type is verified (range or prefix)
3. **Usage**: Plugin is referenced by name in queries
4. **Execution**: Plugin transforms results when query runs
5. **Unregistration**: Plugin can be removed from registry

## Best Practices

### Do's

✅ **Register plugins at startup** - Register all plugins during application initialization

✅ **Use descriptive names** - Choose clear, unique plugin names

✅ **Handle empty results** - Plugins should work correctly with empty item lists

✅ **Document plugin behavior** - Provide clear descriptions for each plugin

✅ **Test with pagination** - Ensure plugins work correctly with cursor-based pagination

✅ **Use appropriate hook types** - Register range plugins as `hkRangeQuery`, prefix as `hkPrefixQuery`

### Don'ts

❌ **Don't modify key structure** - Avoid changing keys in ways that break cursor pagination

❌ **Don't make plugins stateful** - Plugins should be stateless and deterministic

❌ **Don't perform I/O in plugins** - Keep plugins fast and in-memory only

❌ **Don't depend on plugin order** - Design plugins to be composable in any order

❌ **Don't throw exceptions** - Handle errors gracefully within plugins

## Security Considerations

### Plugin Trust Model

- Plugins execute with server privileges
- Only register plugins from trusted sources
- Review plugin code before registration
- Consider plugin behavior in multi-tenant scenarios

### Client-Specified Plugins

When clients can specify plugins (network API):

```nim
// Server can restrict which plugins clients can use
proc validateClientPlugin(pluginName: string): bool =
  # Only allow safe, audited plugins
  result = pluginName in ["safeFilter1", "safeFilter2"]
```

## Performance Considerations

### Plugin Overhead

- Each plugin adds processing time to queries
- Minimal overhead for simple filters (< 1μs per item)
- Complex transformations may impact latency
- Measure performance impact in your use case

### Optimization Tips

1. **Keep plugins simple** - Avoid complex logic in frequently-called plugins
2. **Batch operations** - Process all items in a single pass
3. **Avoid allocations** - Minimize memory allocations in hot paths
4. **Use efficient algorithms** - Prefer O(n) operations over O(n²)

### When to Use Plugins vs. Application Logic

**Use plugins when:**
- Transformation needs to be applied consistently across multiple queries
- You want to enforce constraints at the data layer
- You need to modify results before network transmission
- Logic is reusable across different query types

**Use application logic when:**
- Transformation is specific to one use case
- You need access to external services or databases
- Logic is complex and better handled in application code
- You want to keep data layer simple

## Debugging Plugins

### Logging in Plugins

```nim
proc debugPlugin(metadata: HookMetadata,
                 items: var seq[(string, string)],
                 nextCursor: var string,
                 hasMore: var bool) =
  echo fmt"Plugin called with {items.len} items"
  echo fmt"Query: {metadata.queryParams}"

  # Apply logic
  let before = items.len
  items.keepItIf(it[1].len > 0)
  let after = items.len

  echo fmt"Filtered from {before} to {after} items"
```

### Testing Plugins

```nim
import unittest

suite "Plugin Tests":
  test "filter plugin removes inactive items":
    var items = @[(
      "user:1", "active"
    ), (
      "user:2", "inactive"
    ), (
      "user:3", "active"
    )]
    var cursor = ""
    var hasMore = false
    var metadata = HookMetadata(hookType: hkRangeQuery)

    activeOnlyPlugin(metadata, items, cursor, hasMore)

    check items.len == 2
    check items[0][0] == "user:1"
    check items[1][0] == "user:3"
```

## Complete Example

```nim
import bitbarrel
import plugins/query_result_hooks

# Define plugins
proc filterPremium(metadata: HookMetadata,
                   items: var seq[(string, string)],
                   nextCursor: var string,
                   hasMore: var bool) =
  items.keepItIt(it[1].contains("premium"))

proc addMetadata(metadata: HookMetadata,
                 items: var seq[(string, string)],
                 nextCursor: var string,
                 hasMore: var bool) =
  let now = $epochTime()
  for item in items.mitems:
    item[1] = fmt"{item[1]}|processed={now}|query={metadata.queryParams}"

# Register plugins
discard registerPlugin("premiumOnly", filterPremium, hkRangeQuery,
                      "Show only premium accounts")
discard registerPlugin("addQueryMetadata", addMetadata, hkRangeQuery,
                      "Add processing metadata to values")

# Use in application
proc getPremiumUsers(): seq[(string, string)] =
  var barrel = openBarrel("users.db", bmCritBit)

  let (items, cursor, hasMore) = barrel.itemsInRange(
    startKey = "user:0000",
    endKey = "user:9999",
    limit = 100,
    cursor = "",
    plugins = @["premiumOnly", "addQueryMetadata"]
  )

  return items

# For network clients, plugins work the same way
import network/client

var client = newClient("localhost", 9876.Port)
client.connect()
discard client.useBarrel("users")

let (items, cursor, hasMore) = client.rangeQuery(
  "user:0000", "user:9999", 100, "",
  plugins = @["premiumOnly", "addQueryMetadata"]
)
```

## API Reference

### registerPlugin

```nim
proc registerPlugin*(name: string,
                     hookProc: QueryResultHook,
                     hookType: HookKind,
                     description: string = ""): PluginId
```

Register a new query result plugin.

**Parameters:**
- `name`: Unique plugin identifier
- `hookProc`: Plugin procedure to execute
- `hookType`: Hook kind (`hkRangeQuery` or `hkPrefixQuery`)
- `description`: Human-readable description

**Returns:** Plugin ID (used for internal tracking)

**Raises:** `PluginAlreadyRegisteredError` if name already exists

### unregisterPlugin

```nim
proc unregisterPlugin*(name: string)
```

Remove a plugin from the registry.

**Parameters:**
- `name`: Plugin name to unregister

**Raises:** `PluginNotFoundError` if plugin doesn't exist

### getRegisteredPlugins

```nim
proc getRegisteredPlugins*(): Table[string, HookKind]
```

Get all currently registered plugins.

**Returns:** Table mapping plugin names to hook types

### applyPlugins (Internal)

```nim
proc applyPlugins*(hookType: HookKind,
                   items: var seq[(string, string)],
                   nextCursor: var string,
                   hasMore: var bool,
                   pluginNames: seq[string],
                   queryParams: string)
```

Apply multiple plugins to query results (called internally).

## Troubleshooting

### Plugin Not Found Error

**Problem:** `PluginNotFoundError: Plugin 'myPlugin' not found`

**Cause:** Plugin not registered or misspelled name

**Solution:**
```nim
// Verify plugin is registered
if "myPlugin" notin getRegisteredPlugins():
  echo "Plugin not registered!"
  registerPlugin("myPlugin", myProc, hkRangeQuery, "")
```

### Wrong Hook Type Error

**Problem:** Plugin registered for wrong query type

**Cause:** Range query plugin used in prefix query or vice versa

**Solution:**
```nim
// Register separate plugins for each hook type
let rangeId = registerPlugin("myFilter", filterProc, hkRangeQuery, "")
let prefixId = registerPlugin("myFilter", filterProc, hkPrefixQuery, "")
```

### Plugin Order Issues

**Problem:** Results not as expected with multiple plugins

**Cause:** Plugin execution order affects final result

**Solution:**
```nim
// Reorder plugins to achieve desired result
// Filter → Transform → Limit (example order)
let plugins = @["filter", "transform", "limit"]
```

## Related Documentation

- [Pub/Sub Messaging Guide](../USER_GUIDE/pubsub.md) - Real-time messaging with plugins
- [Network Client Guide](./networking-guide.md) - Using plugins with network clients
- [Plugin Tests](../../tests/plugins/test_query_result_hooks.nim) - Comprehensive test examples
