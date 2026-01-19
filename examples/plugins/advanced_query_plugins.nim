## Advanced Query Plugins - Sophisticated plugin examples
##
## This file demonstrates advanced plugin patterns for query result transformation:
## - Data validation and schema enforcement
## - Access control and permission filtering
## - Performance monitoring and statistics
## - Data format conversion
## - Field masking for sensitive data

import ../../src/plugins/query_result_hooks
import std/[strutils, json, times, tables, os]

## 1. Data Validation Plugin
## Validates JSON values against a schema and filters out invalid records
## This example checks for required "id" and "name" fields in JSON objects
discard registerPlugin(
  name = "validate_json_schema",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    var validItems: seq[(string, string)] = @[]
    for (key, value) in items:
      try:
        let parsed = parseJson(value)
        # Simple schema validation: require "id" and "name" fields
        if parsed.hasKey("id") and parsed.hasKey("name"):
          validItems.add((key, value))
        else:
          echo fmt"[validate_json_schema] Skipping invalid record: {key}"
      except JsonParsingError:
        echo fmt"[validate_json_schema] Invalid JSON: {key}"
    items = validItems
  ,
  kind = hkAny,
  description = "Validates JSON values for required 'id' and 'name' fields"
)

## 2. Access Control Plugin
## Filters results based on user permissions (simulated)
## This example uses metadata.clientId to determine access rights
## In practice, you would integrate with your authentication system
discard registerPlugin(
  name = "access_control",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    # Simulated permission check based on client ID
    # In real implementation, you would look up permissions from a database
    let clientId = metadata.clientId

    # Example: client "admin" can see all, others only see public records
    if clientId != "admin":
      var filtered: seq[(string, string)] = @[]
      for (key, value) in items:
        # Assume keys starting with "public:" are accessible to all
        if key.startsWith("public:"):
          filtered.add((key, value))
        else:
          echo fmt"[access_control] Filtered out restricted key: {key} for client: {clientId}"
      items = filtered
  ,
  kind = hkAny,
  description = "Filters results based on client permissions"
)

## 3. Performance Monitoring Plugin
## Logs query performance metrics and tracks statistics
## This plugin demonstrates how to collect performance data
var queryStats = initTable[string, int]()  # Simple in-memory stats
discard registerPlugin(
  name = "performance_monitor",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    let startTime = getTime()

    # Store original item count for metrics
    let originalCount = items.len

    # Simulate some processing time (in real plugin, this would be actual work)
    sleep(1)  # 1ms delay for demonstration

    let endTime = getTime()
    let duration = (endTime - startTime).inMilliseconds()

    # Update statistics
    queryStats[metadata.barrelName] = queryStats.getOrDefault(metadata.barrelName) + 1

    # Log performance data (in production, send to monitoring system)
    echo fmt"[performance_monitor] Barrel: {metadata.barrelName}, " &
          fmt"Client: {metadata.clientId}, " &
          fmt"Items: {originalCount}, " &
          fmt"Duration: {duration}ms"
  ,
  kind = hkAny,
  description = "Collects and logs query performance metrics"
)

## 4. Data Transformation Plugin
## Converts values between formats (e.g., JSON to CSV)
## This example transforms JSON objects into CSV rows
discard registerPlugin(
  name = "json_to_csv",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    for i in 0..<items.len:
      try:
        let parsed = parseJson(items[i][1])
        # Convert simple JSON object to CSV: "field1,field2,field3"
        var csvRow = ""
        for field in ["id", "name", "email"]:
          if parsed.hasKey(field):
            if csvRow.len > 0:
              csvRow &= ","
            csvRow &= parsed[field].getStr()
        items[i] = (items[i][0], csvRow)
      except JsonParsingError:
        # Keep original value if not JSON
        discard
  ,
  kind = hkAny,
  description = "Converts JSON values to CSV format"
)

## 5. Field Masking Plugin
## Masks sensitive fields in nested JSON data
## This example masks email addresses and phone numbers
discard registerPlugin(
  name = "mask_sensitive_fields",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    for i in 0..<items.len:
      try:
        var parsed = parseJson(items[i][1])

        # Mask email field if present
        if parsed.hasKey("email"):
          let email = parsed["email"].getStr()
          if email.contains("@"):
            let parts = email.split("@")
            if parts.len == 2:
              let maskedEmail = parts[0][0..min(2, parts[0].high)] & "***@" & parts[1]
              parsed["email"] = %maskedEmail

        # Mask phone field if present
        if parsed.hasKey("phone"):
          let phone = parsed["phone"].getStr()
          if phone.len >= 10:
            let maskedPhone = phone[0..2] & "***" & phone[^4..^1]
            parsed["phone"] = %maskedPhone

        items[i] = (items[i][0], $parsed)
      except JsonParsingError:
        # If not JSON, apply simple masking to entire value
        if items[i][0].contains("sensitive"):
          items[i] = (items[i][0], "***MASKED***")
  ,
  kind = hkAny,
  description = "Masks sensitive fields in JSON data (email, phone)"
)

## 6. Rate Limiting Plugin
## Limits query results based on client rate limits
## This example uses simple in-memory tracking
var clientQueryCount = initTable[string, int]()
discard registerPlugin(
  name = "rate_limiter",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    let clientId = metadata.clientId
    let currentCount = clientQueryCount.getOrDefault(clientId) + 1
    clientQueryCount[clientId] = currentCount

    # Example rate limit: 100 queries per client
    const maxQueries = 100

    if currentCount > maxQueries:
      # Return empty results when rate limit exceeded
      items = @[]
      echo fmt"[rate_limiter] Rate limit exceeded for client: {clientId}"
    else:
      # Apply gradual throttling as limit approaches
      let remaining = maxQueries - currentCount
      if remaining < 10:
        # Limit results when approaching rate limit
        if items.len > 10:
          items.setLen(10)
          nextCursor = items[9][0]
          hasMore = true
          echo fmt"[rate_limiter] Approaching rate limit for client: {clientId}, limiting results"
  ,
  kind = hkAny,
  description = "Enforces rate limits on client queries"
)

## 7. Geographic Filtering Plugin
## Filters results based on geographic data in values
## This example assumes JSON values with "location" field
discard registerPlugin(
  name = "geo_filter",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    # Example: only include items from specific regions
    const allowedRegions = ["US", "EU", "APAC"]
    var filtered: seq[(string, string)] = @[]

    for (key, value) in items:
      try:
        let parsed = parseJson(value)
        if parsed.hasKey("location"):
          let region = parsed["location"].getStr()
          if region in allowedRegions:
            filtered.add((key, value))
      except JsonParsingError:
        # If not JSON, include by default
        filtered.add((key, value))

    items = filtered
  ,
  kind = hkAny,
  description = "Filters results based on geographic region"
)

## 8. Cache Warming Plugin
## Prepares data for caching systems
## This example extracts key fields for cache optimization
discard registerPlugin(
  name = "cache_warmer",
  hook = proc(metadata: HookMetadata,
              items: var seq[(string, string)],
              nextCursor: var string,
              hasMore: var bool) {.gcsafe.} =
    # In a real implementation, this would:
    # 1. Extract frequently accessed fields
    # 2. Pre-compute derived values
    # 3. Prepare data for caching layer

    # Example: Extract timestamp and add cache metadata
    for i in 0..<items.len:
      try:
        var parsed = parseJson(items[i][1])
        # Add cache metadata
        parsed["_cached_at"] = %(getTime().toUnix())
        parsed["_cache_ttl"] = %3600  # 1 hour TTL
        items[i] = (items[i][0], $parsed)
      except JsonParsingError:
        # Add simple cache metadata for non-JSON values
        items[i] = (items[i][0], fmt"{items[i][1]}||cached_at:{getTime().toUnix()}")

    echo fmt"[cache_warmer] Prepared {items.len} items for caching"
  ,
  kind = hkAny,
  description = "Prepares query results for optimal caching"
)

echo "✓ Registered advanced query plugins:"