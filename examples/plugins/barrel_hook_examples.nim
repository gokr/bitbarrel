## Barrel Hook Examples - Real-world hook implementations
##
## This file demonstrates practical barrel hook patterns for:
## - Audit logging and change tracking
## - Cache invalidation and synchronization
## - Data replication and backup
## - Metrics collection and monitoring
## - Validation and business rules

import ../../src/pubsub/barrel_hooks
import std/[strutils, json, times, os, tables]

## 1. Audit Logging Hook
## Logs all key-value changes to a file or external system
## This example writes to a local audit log file
let auditLogFile = "audit.log"
discard registerBarrelHook(
  proc(barrelName: string, key: string,
       changeType: KvChangeType,
       value: string) {.gcsafe.} =
    let timestamp = getTime().format("yyyy-MM-dd HH:mm:ss")
    let changeStr = case changeType
      of kvSet: "SET"
      of kvDelete: "DELETE"
    let logEntry = fmt"{timestamp} | {barrelName} | {key} | {changeStr} | {value.len} bytes"

    # In production, you might want to buffer writes or use async logging
    writeFile(auditLogFile, logEntry & "\n", mode = fmAppend)

    echo fmt"[audit_log] {logEntry}"
  ,
  enabled = true,
  priority = 100  # High priority - audit should happen first
)

## 2. Cache Invalidation Hook
## Invalidates external caches when data changes
## This example simulates cache invalidation for a distributed cache
discard registerBarrelHook(
  proc(barrelName: string, key: string,
       changeType: KvChangeType,
       value: string) {.gcsafe.} =
    # In real implementation, this would:
    # 1. Send cache invalidation message to Redis/Memcached
    # 2. Update CDN purging systems
    # 3. Notify application servers

    # Example cache key patterns
    let cacheKeys = @[
      fmt"cache:{barrelName}:{key}",
      fmt"cache:{barrelName}:*"  # Wildcard for related entries
    ]

    for cacheKey in cacheKeys:
      echo fmt"[cache_invalidation] Invalidating: {cacheKey}"
      # Simulated cache invalidation API call
      # redis.del(cacheKey)
      # memcached.delete(cacheKey)
  ,
  enabled = true,
  priority = 50
)

## 3. Replication Hook
## Triggers data replication to secondary storage or backup systems
## This example demonstrates asynchronous replication
discard registerBarrelHook(
  proc(barrelName: string, key: string,
       changeType: KvChangeType,
       value: string) {.gcsafe.} =
    # In production, this would:
    # 1. Queue replication job
    # 2. Send to message broker (Kafka, RabbitMQ)
    # 3. Update secondary databases

    let replicationData = %*{
      "barrel": barrelName,
      "key": key,
      "operation": (if changeType == kvSet: "set" else: "delete"),
      "value": value,
      "timestamp": getTime().toUnix(),
      "source": "primary"
    }

    echo fmt"[replication] Queuing replication: {barrelName}/{key}"

    # Simulated replication queue
    # replicationQueue.add($replicationData)
    # kafka.send("replication-topic", replicationData)
  ,
  enabled = true,
  priority = 10
)

## 4. Metrics Collection Hook
## Updates metrics counters for monitoring and analytics
## This example tracks operation counts and data sizes
var metrics = initTable[string, int]()
discard registerBarrelHook(
  proc(barrelName: string, key: string,
       changeType: KvChangeType,
       value: string) {.gcsafe.} =
    # Update operation counters
    let opKey = fmt"ops.{barrelName}.{changeType}"
    metrics[opKey] = metrics.getOrDefault(opKey) + 1

    # Track data size for SET operations
    if changeType == kvSet:
      let sizeKey = fmt"bytes.{barrelName}.set"
      metrics[sizeKey] = metrics.getOrDefault(sizeKey) + value.len

    # Periodically log metrics (every 100 operations)
    let totalOps = metrics.getOrDefault(fmt"ops.{barrelName}.kvSet") +
                   metrics.getOrDefault(fmt"ops.{barrelName}.kvDelete")

    if totalOps mod 100 == 0:
      echo fmt"[metrics] Barrel {barrelName}: {totalOps} operations"
      echo fmt"[metrics] SET bytes: {metrics.getOrDefault(fmt\"bytes.{barrelName}.set\")}"
  ,
  enabled = true,
  priority = 5
)

## 5. Validation Hook (Read-Only Observer)
## Validates data before allowing changes (read-only observation)
## Note: Hooks cannot prevent operations, but can log/alert on violations
discard registerBarrelHook(
  proc(barrelName: string, key: string,
       changeType: KvChangeType,
       value: string) {.gcsafe.} =
    # Example validation rules:

    # 1. Check key length
    if key.len > 1024:
      echo fmt"[validation] Warning: Key too long: {key.len} chars"

    # 2. Check value size for SET operations
    if changeType == kvSet and value.len > 10_000_000:
      echo fmt"[validation] Warning: Large value: {value.len} bytes"

    # 3. Validate JSON structure for specific keys
    if key.startsWith("config:"):
      try:
        discard parseJson(value)
      except JsonParsingError:
        echo fmt"[validation] Invalid JSON in config key: {key}"

    # 4. Business rule: prevent deletion of system keys
    if changeType == kvDelete and key.startsWith("system:"):
      echo fmt"[validation] Alert: Attempt to delete system key: {key}"
      # In production, could trigger alerting system (PagerDuty, Slack, etc.)
  ,
  enabled = true,
  priority = 80  # Higher priority than replication but after audit
)

## 6. Search Index Update Hook
## Updates search indexes when data changes
## This example demonstrates updating Elasticsearch/Solr indexes
discard registerBarrelHook(
  proc(barrelName: string, key: string,
       changeType: KvChangeType,
       value: string) {.gcsafe.} =
    # Determine index name based on barrel and key pattern
    let indexName = fmt"{barrelName}-index"

    case changeType:
    of kvSet:
      # Index the document
      let document = %*{
        "id": key,
        "value": value,
        "barrel": barrelName,
        "timestamp": getTime().toUnix(),
        "value_length": value.len
      }
      echo fmt"[search_index] Updating index {indexName} for key: {key}"
      # In production: elasticsearch.index(indexName, document)

    of kvDelete:
      # Remove from index
      echo fmt"[search_index] Removing from index {indexName} for key: {key}"
      # In production: elasticsearch.delete(indexName, key)
  ,
  enabled = true,
  priority = 20
)

## 7. Notification Hook
## Sends notifications for specific data changes
## This example demonstrates sending email/Slack notifications
discard registerBarrelHook(
  proc(barrelName: string, key: string,
       changeType: KvChangeType,
       value: string) {.gcsafe.} =
    # Only notify for important keys
    if key.startsWith("alert:") or key.startsWith("announcement:"):
      let operation = if changeType == kvSet: "created/updated" else: "deleted"

      # Prepare notification message
      let message = fmt"""
      🚨 Data Change Notification
      Barrel: {barrelName}
      Key: {key}
      Operation: {operation}
      Timestamp: {getTime().format("yyyy-MM-dd HH:mm:ss")}
      """

      echo fmt"[notification] {message}"

      # In production:
      # - Send email: sendEmail("admin@example.com", "Data Change Alert", message)
      # - Send Slack: slack.send("#alerts", message)
      # - Send SMS: twilio.send("+1234567890", message)
  ,
  enabled = true,
  priority = 30
)

## 8. Data Retention Hook
## Enforces data retention policies
## This example checks if data should be archived or deleted based on age
discard registerBarrelHook(
  proc(barrelName: string, key: string,
       changeType: KvChangeType,
       value: string) {.gcsafe.} =
    # Example: Archive old configuration versions
    if key.startsWith("config:") and key.contains(":v"):
      # Extract version timestamp from key pattern "config:app:v1633046400"
      let parts = key.split(":v")
      if parts.len == 2:
        try:
          let versionTime = parseBiggestInt(parts[1])
          let currentTime = getTime().toUnix()
          let ageDays = (currentTime - versionTime) div (24 * 3600)

          # Archive versions older than 30 days
          if ageDays > 30:
            echo fmt"[retention] Archiving old config version: {key} ({ageDays} days old)"
            # archiveSystem.archive(key, value, barrelName)
        except ValueError:
          discard
  ,
  enabled = true,
  priority = 40
)

echo "✓ Registered barrel hook examples:"
echo "  - Audit logging (priority: 100)"
echo "  - Cache invalidation (priority: 50)"
echo "  - Replication (priority: 10)"
echo "  - Metrics collection (priority: 5)"
echo "  - Validation (priority: 80)"
echo "  - Search index update (priority: 20)"
echo "  - Notifications (priority: 30)"
echo "  - Data retention (priority: 40)"