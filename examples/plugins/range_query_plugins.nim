## Range Query Plugins - Example plugins for query result transformation
##
## This file demonstrates how to create plugins that transform query results
## from range and prefix queries before they are returned to the client.

import hooks/query_result_hooks
import std/[strutils, json, algorithm]

# Plugin 1: Filter keys with specific prefix
## This plugin filters out items whose keys start with "hidden:"
discard registerHook(
  name = "filter_hidden",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    var filtered: seq[(string, string)] = @[]
    for (k, v) in items:
      if not k.startsWith("hidden:"):
        filtered.add((k, v))
    items = filtered
  ,
  kind = hkAny,
  description = "Filters out keys starting with 'hidden:'"
)

# Plugin 2: Limit results
## This plugin limits query results to 50 items
## Updates cursor if more items are available
discard registerHook(
  name = "limit_results",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    const limit = 50
    if items.len > limit:
      items.setLen(limit)
      nextCursor = items[limit - 1][0]
      hasMore = true
  ,
  kind = hkAny,
  description = "Limits query results to 50 items"
)

# Plugin 3: Extract JSON field
## This plugin extracts the 'name' field from JSON values
## If value is not valid JSON or doesn't have 'name' field, keeps original value
discard registerHook(
  name = "extract_json_name",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    for i in 0..<items.len:
      try:
        let parsed = parseJson(items[i][1])
        if parsed.hasKey("name"):
          items[i] = (items[i][0], parsed["name"].getStr())
      except JsonParsingError:
        discard
  ,
  kind = hkAny,
  description = "Extracts 'name' field from JSON values"
)

# Plugin 4: Filter by key pattern
## This plugin only includes keys that match a pattern (e.g., contain specific substring)
## This is a simple example - you can customize the pattern
discard registerHook(
  name = "filter_pattern_active",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    var filtered: seq[(string, string)] = @[]
    const pattern = ":active:"
    for (k, v) in items:
      if pattern in k:
        filtered.add((k, v))
    items = filtered
  ,
  kind = hkAny,
  description = "Filters to only include keys containing ':active:'"
)

# Plugin 5: Sort results by value
## This plugin sorts query results by their values alphabetically
discard registerHook(
  name = "sort_by_value",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    items.sort(proc(a, b: (string, string)): int = cmp(a[1], b[1]))
  ,
  kind = hkAny,
  description = "Sorts query results by value alphabetically"
)

# Plugin 6: Redact sensitive values
## This plugin redacts values for keys starting with "secret:"
discard registerHook(
  name = "redact_sensitive",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    for i in 0..<items.len:
      if items[i][0].startsWith("secret:"):
        items[i] = (items[i][0], "[REDACTED]")
  ,
  kind = hkAny,
  description = "Redacts values for keys starting with 'secret:'"
)
