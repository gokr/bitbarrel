# Query Result Hooks

BitBarrel's hook system allows you to transform query results dynamically before they are returned to clients. Hooks can filter, modify, or enrich range and prefix query results based on your application needs.

## Overview

The query result hook system provides:

- **Dynamic result transformation** - Modify query results at runtime
- **Type-safe hook registration** - Register hooks with clear boundaries
- **Hook-based architecture** - Apply hooks to range and prefix queries
- **Thread-safe registry** - Safe concurrent hook management
- **Client-transparent** - Hooks work seamlessly with network clients

## Current Hook Coverage

BitBarrel has two distinct hook systems:

### 1. Query Result Hooks (`src/hooks/query_result_hooks.nim`)
Transform results from range and prefix queries before returning to clients.

**Supported Commands:**
- `cmdRangeQuery` (0x21) - Range queries with key-value pairs ✅
- `cmdPrefixQuery` (0x22) - Prefix queries with key-value pairs ✅
- `cmdRangeKeys` (0x24) - Keys-only range queries ❌ (no hook support)
- `cmdPrefixKeys` (0x25) - Keys-only prefix queries ❌ (no hook support)
- `cmdRangeCount` (0x23) - Range count queries ❌ (no hook support)

**Protocol Support:** RangeRequest and PrefixRequest have `hooks: seq[string]` fields.

**Client API:** `rangeQuery()` and `prefixQuery()` accept optional `hooks` parameter.

### 2. Barrel Event Hooks (`src/pubsub/barrel_hooks.nim`)
Trigger callbacks when keys are set or deleted in a barrel.

**Supported Operations:**
- `set()` - Triggers `kvSet` events ✅
- `delete()` - Triggers `kvDelete` events ✅

**Event Types:** `kvSet`, `kvDelete`

**Registry:** Thread-safe with priority-based execution.

**Coverage Gaps:** The following operations currently have NO hook support:
- `cmdGet` (0x01) - Single key retrieval
- `cmdListKeys` (0x06) - List all keys
- All batch operations (`cmdBatchGet`, `cmdBatchSet`, `cmdBatchDelete`)
- All barrel management commands
- All pub/sub commands

See the [Extension Proposals](#extension-proposals) section for future enhancements.

## Plugin Types

### Range Query Hooks (`hkRangeQuery`)
Applied to range query results:
- `itemsInRange()` / `rangeQuery()`
- Affects both key-value pairs and keys-only variants

### Prefix Query Hooks (`hkPrefixQuery`)
Applied to prefix query results:
- `itemsWithPrefix()` / `prefixQuery()`
- Affects both key-value pairs and keys-only variants

## Creating a Plugin

### Basic Plugin Structure

```nim
import hooks/query_result_hooks

# Define your hook logic
proc myFilterPlugin(metadata: HookMetadata,
                    items: var seq[(string, string)],
                    nextCursor: var string,
                    hasMore: var bool) =
  ## Filter items based on custom logic
  items.keepItIf(it[1].contains("active"))

# Register the hook
let hookId = registerHook(
  "activeItemsOnly",     # Unique hook name
  myFilterHook,        # Plugin procedure
  hkRangeQuery,          # Hook type
  "Filter to active items only"  # Description
)
```

### Plugin Parameters

Hooks receive four parameters:

1. **metadata** - HookMetadata containing:
   - `hookType` - Type of query (range or prefix)
   - `queryParams` - Original query parameters (startKey, endKey, prefix, etc.)
   - `hookParams` - Additional parameters from query (if any)

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

let hookId = registerHook(
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

let hookId = registerHook(
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

let hookId = registerHook(
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

let hookId = registerHook(
  "userAccessOnly",
  userAccessFilter,
  hkRangeQuery,
  "Filter to user's own data only"
)
```

## Using Hooks

### Server-Side Usage (Direct API)

```nim
import bitbarrel
import hooks/query_result_hooks

# Register hook first
let hookId = registerHook("myPlugin", myHookProc, hkRangeQuery, "Description")

# Open barrel in bmCritBit mode for range queries
var barrel = openBarrel("data.db", bmCritBit)

// Use hook in range query
let (items, cursor, hasMore) = barrel.itemsInRange(
  startKey = "user:1000",
  endKey = "user:2000",
  limit = 100,
  cursor = "",
  hooks = @["myPlugin"]  // Apply plugin
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
  hooks = @["activeOnly", "maxResults"]  // Multiple hooks
)

// Prefix query with hook
let (items, cursor, hasMore) = client.prefixQuery(
  prefix = "order:2024-",
  limit = 50,
  cursor = "",
  hooks = @["filterByStatus"]  // Plugin applied
)
```

### Plugin Chaining

Multiple hooks can be applied to the same query. They execute in the order specified:

```nim
// Hooks execute in order: filter1 → filter2 → transform
let hooks = @["filter1", "filter2", "transform"]
let (items, cursor, hasMore) = client.rangeQuery(
  "start", "end", 100, "", hooks
)
```

**Plugin execution order matters** - later hooks receive results from earlier hooks.

## Managing Hooks

### Listing Registered Hooks

```nim
import hooks/query_result_hooks

let registeredHooks = getRegisteredHooks())
for name, hookType in registeredHooks:
  echo fmt"Hook: {name}, Type: {hookType}"
```

### Unregistering Hooks

```nim
import hooks/query_result_hooks

# Unregister by name
unregisterHook("myPlugin")

# After unregistering, hook is no longer available for queries
```

### Plugin Lifecycle

1. **Registration**: Plugin is registered with the global registry
2. **Validation**: Hook type is verified (range or prefix)
3. **Usage**: Plugin is referenced by name in queries
4. **Execution**: Plugin transforms results when query runs
5. **Unregistration**: Plugin can be removed from registry

## Best Practices

### Do's

✅ **Register hooks at startup** - Register all hooks during application initialization

✅ **Use descriptive names** - Choose clear, unique hook names

✅ **Handle empty results** - Hooks should work correctly with empty item lists

✅ **Document hook behavior** - Provide clear descriptions for each plugin

✅ **Test with pagination** - Ensure hooks work correctly with cursor-based pagination

✅ **Use appropriate hook types** - Register range hooks as `hkRangeQuery`, prefix as `hkPrefixQuery`

### Don'ts

❌ **Don't modify key structure** - Avoid changing keys in ways that break cursor pagination

❌ **Don't make hooks stateful** - Hooks should be stateless and deterministic

❌ **Don't perform I/O in hooks** - Keep hooks fast and in-memory only

❌ **Don.t depend on hook order** - Design hooks to be composable in any order

❌ **Don't throw exceptions** - Handle errors gracefully within hooks

## Security Considerations

### Plugin Trust Model

- Hooks execute with server privileges
- Only register hooks from trusted sources
- Review hook code before registration
- Consider hook behavior in multi-tenant scenarios

### Client-Specified Hooks

When clients can specify hooks (network API):

```nim
// Server can restrict which hooks clients can use
proc validateClientHook(hookName: string): bool =
  # Only allow safe, audited hooks
  result = hookName in ["safeFilter1", "safeFilter2"]
```

## Performance Considerations

### Plugin Overhead

- Each plugin adds processing time to queries
- Minimal overhead for simple filters (< 1μs per item)
- Complex transformations may impact latency
- Measure performance impact in your use case

### Optimization Tips

1. **Keep hooks simple** - Avoid complex logic in frequently-called hooks
2. **Batch operations** - Process all items in a single pass
3. **Avoid allocations** - Minimize memory allocations in hot paths
4. **Use efficient algorithms** - Prefer O(n) operations over O(n²)

### When to Use Hooks vs. Application Logic

**Use hooks when:**
- Transformation needs to be applied consistently across multiple queries
- You want to enforce constraints at the data layer
- You need to modify results before network transmission
- Logic is reusable across different query types

**Use application logic when:**
- Transformation is specific to one use case
- You need access to external services or databases
- Logic is complex and better handled in application code
- You want to keep data layer simple

## Debugging Hooks

### Logging in Hooks

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

### Testing Hooks

```nim
import unittest

suite "Plugin Tests":
  test "filter hook removes inactive items":
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
import hooks/query_result_hooks

# Define hooks
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

# Register hooks
discard registerHook("premiumOnly", filterPremium, hkRangeQuery,
                      "Show only premium accounts")
discard registerHook("addQueryMetadata", addMetadata, hkRangeQuery,
                      "Add processing metadata to values")

# Use in application
proc getPremiumUsers(): seq[(string, string)] =
  var barrel = openBarrel("users.db", bmCritBit)

  let (items, cursor, hasMore) = barrel.itemsInRange(
    startKey = "user:0000",
    endKey = "user:9999",
    limit = 100,
    cursor = "",
    hooks = @["premiumOnly", "addQueryMetadata"]
  )

  return items

# For network clients, hooks work the same way
import network/client

var client = newClient("localhost", 9876.Port)
client.connect()
discard client.useBarrel("users")

let (items, cursor, hasMore) = client.rangeQuery(
  "user:0000", "user:9999", 100, "",
  hooks = @["premiumOnly", "addQueryMetadata"]
)
```

## Barrel Event Hooks

Barrel event hooks provide a way to execute callbacks when key-value pairs are set or deleted in a barrel. Unlike query result hooks which transform query results, barrel hooks are triggered by write operations and are useful for:

- Audit logging and change tracking
- Cache invalidation
- Data replication
- Metrics collection
- Real-time notifications

### Registering Barrel Hooks

```nim
import pubsub/barrel_hooks

proc auditHook(barrelName: string, key: string,
               changeType: KvChangeType,
               value: string) {.gcsafe.} =
  echo fmt"Change in {barrelName}: {key} -> {changeType} (value length: {value.len})"

let hookId = registerBarrelHook(
  auditHook,
  enabled = true,
  priority = 0  # Higher priority = called earlier
)
```

### Hook Parameters

1. **barrelName** - Name/ID of the barrel where change occurred
2. **key** - The key that was modified
3. **changeType** - Either `kvSet` (key was set) or `kvDelete` (key was deleted)
4. **value** - The new value (empty string for delete operations)

### Priority-Based Execution

Hooks are executed in priority order (higher priority first). Use priorities to ensure critical hooks (like audit logging) run before other hooks (like cache invalidation).

```nim
# Audit hook runs first (priority 100)
discard registerBarrelHook(auditHook, priority = 100)

# Cache invalidation runs second (priority 50)
discard registerBarrelHook(cacheHook, priority = 50)

# Metrics collection runs last (priority 0)
discard registerBarrelHook(metricsHook, priority = 0)
```

### Managing Hooks

```nim
# Enable/disable hooks
disableHook(hookId)  # Temporarily disable
enableHook(hookId)   # Re-enable

# Unregister hook
unregisterBarrelHook(hookId)

# List all registered hooks
let hooks = listHooks()
for hook in hooks:
  echo fmt"Hook {hook.id}: priority={hook.priority}, enabled={hook.enabled}"
```

### Example: Comprehensive Audit System

```nim
import std/[times, json]

proc comprehensiveAuditHook(barrelName: string, key: string,
                            changeType: KvChangeType,
                            value: string) {.gcsafe.} =
  let timestamp = getTime().format("yyyy-MM-dd HH:mm:ss")
  let operation = if changeType == kvSet: "SET" else: "DELETE"
  let auditRecord = %*{
    "timestamp": timestamp,
    "barrel": barrelName,
    "key": key,
    "operation": operation,
    "value_length": value.len,
    "client_ip": "..."  # Would come from session context
  }

  # Write to audit log, send to SIEM, etc.
  echo fmt"AUDIT: {auditRecord}"

# Register with high priority
discard registerBarrelHook(comprehensiveAuditHook, priority = 100)
```

### Error Handling

Hook exceptions are caught and logged, but don't affect the original operation or other hooks:

```nim
proc faultyHook(barrelName: string, key: string,
                changeType: KvChangeType,
                value: string) {.gcsafe.} =
  raise newException(Exception, "Hook failure")

# Even if faultyHook throws, other hooks still execute
discard registerBarrelHook(faultyHook)
discard registerBarrelHook(workingHook)  # This will still run
```

### Best Practices

- **Keep hooks fast** - Hooks execute synchronously during write operations
- **Handle exceptions** - Don't let hook failures affect data integrity
- **Use priorities wisely** - Critical hooks should have higher priority
- **Monitor hook performance** - Slow hooks can impact write latency
- **Consider idempotency** - Hooks may be retried during recovery

### Integration with Pub/Sub

Barrel hooks are integrated with the Pub/Sub system. When hooks are triggered, they can forward events to the Pub/Sub manager for real-time messaging to subscribers.

See the [Pub/Sub documentation](../USER_GUIDE/pubsub.md) for details on integrating hooks with messaging.

## Extension Proposals

Future enhancements to the plugin/hook system could include:

### 1. Plugin Support for Keys-Only Queries
- New hook types: `hkRangeKeys`, `hkPrefixKeys`
- Transform sequences of keys (not key-value pairs)

### 2. Single Get Operation Plugin Support
- New hook type: `hkGet`
- Transform single values before returning to client

### 3. Plugin Parameter Enhancement
- Allow clients to pass custom parameters to hooks
- Extend protocol with `hookParams: Table[string, string]`

### 4. Batch Operation Plugin Support
- New hook types: `hkBatchGet`, `hkBatchSet`, `hkBatchDelete`
- Transform entire batch results

### 5. Barrel Management Hooks
- Hooks for barrel lifecycle events (create, open, close, drop)

### 6. Unified Plugin Registry
- Single registry for both query hooks and barrel hooks
- Consistent API and management

## API Reference

### registerPlugin

```nim
proc registerPlugin*(name: string,
                     hookProc: QueryResultHook,
                     hookType: HookKind,
                     description: string = ""): PluginId
```

Register a new query result hook.

**Parameters:**
- `name`: Unique hook identifier
- `hookProc`: Plugin procedure to execute
- `hookType`: Hook kind (`hkRangeQuery` or `hkPrefixQuery`)
- `description`: Human-readable description

**Returns:** Hook ID (used for internal tracking)

**Raises:** `PluginAlreadyRegisteredError` if name already exists

### unregisterPlugin

```nim
proc unregisterPlugin*(name: string)
```

Remove a hook from the registry.

**Parameters:**
- `name`: Hook name to unregister

**Raises:** `HookNotFoundError` if plugin doesn't exist

### getRegisteredHooks

```nim
proc getRegisteredHooks*(): Table[string, HookKind]
```

Get all currently registered hooks.

**Returns:** Table mapping hook names to hook types

### applyHooks (Internal)

```nim
proc applyHooks*(hookType: HookKind,
                   items: var seq[(string, string)],
                   nextCursor: var string,
                   hasMore: var bool,
                   hookNames: seq[string],
                   queryParams: string)
```

Apply multiple hooks to query results (called internally).

## Troubleshooting

### Plugin Not Found Error

**Problem:** `HookNotFoundError: Plugin 'myPlugin' not found`

**Cause:** Plugin not registered or misspelled name

**Solution:**
```nim
// Verify plugin is registered
if "myPlugin" notin getRegisteredHooks()):
  echo "Plugin not registered!"
  registerHook("myPlugin", myProc, hkRangeQuery, "")
```

### Wrong Hook Type Error

**Problem:** Plugin registered for wrong query type

**Cause:** Range query plugin used in prefix query or vice versa

**Solution:**
```nim
// Register separate hooks for each hook type
let rangeId = registerHook("myFilter", filterProc, hkRangeQuery, "")
let prefixId = registerHook("myFilter", filterProc, hkPrefixQuery, "")
```

### Plugin Order Issues

**Problem:** Results not as expected with multiple hooks

**Cause:** Plugin execution order affects final result

**Solution:**
```nim
// Reorder hooks to achieve desired result
// Filter → Transform → Limit (example order)
let hooks = @["filter", "transform", "limit"]
```

## Related Documentation

- [Pub/Sub Messaging Guide](../USER_GUIDE/pubsub.md) - Real-time messaging with hooks
- [Network Client Guide](./networking-guide.md) - Using hooks with network clients
- [Plugin Tests](../../tests/hooks/test_query_result_hooks.nim) - Comprehensive test examples
