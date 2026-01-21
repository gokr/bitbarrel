## Barrel Hook Examples - Real-world hook implementations
##
## This file demonstrates practical barrel hook patterns for:
## - Audit logging and change tracking
## - Cache invalidation and synchronization
## - Data replication and backup
## - Metrics collection and monitoring
## - Validation and business rules
##
## NOTE: Barrel hooks require {.gcsafe.} callbacks, which means accessing
## GC-allocated globals like strings requires careful handling. For production
## code, use thread-safe locking with unsafeAddr or allocate globals outside GC.

import pubsub/barrel_hooks
from pubsub/pubsub import KvChangeType
import std/[strutils, json, times, os, tables, strformat]

## Note: Barrel hook examples are commented out because hooks accessing
## GC-allocated globals (like strings) require special handling for GC safety.
##
## In production, you have two options:
##
## 1. Use {:gcsafe.} with proper locking for shared state:
##    - Store globals using cstring or raw pointers
##    - Use locks or atomics for synchronization
##    - Access via unsafeAddr and convert to string locally
##
## 2. Avoid GC-allocated globals in hooks:
##    - Pass all needed data as context
##    - Use thread-local storage
##    - Communicate via channels instead of shared state

## Example of a GC-safe hook that doesn't access global state:
discard registerBarrelHook(
  proc(barrelName: string, key: string,
       changeType: KvChangeType,
       value: string) {.gcsafe.} =
    # This hook only uses the passed parameters, which are safe
    let timestamp = getTime().format("yyyy-MM-dd HH:mm:ss")
    let changeStr = if changeType == kvSet: "SET" else: "DELETE"
    echo fmt"[hook] {timestamp} | {barrelName} | {key} | {changeStr} | {value.len} bytes"
  ,
  enabled = true,
  priority = 100
)

## The following hooks are commented out because they would access GC-allocated
## globals. Uncomment and fix for production use with proper locking.

## 1. Audit Logging Hook
## Logs all key-value changes to a file or external system
## This example writes to a local audit log file
##
## let auditLogFile = "audit.log"  # GC-allocated string - needs special handling
## discard registerBarrelHook(
##   proc(barrelName: string, key: string,
##        changeType: KvChangeType,
##        value: string) {.gcsafe.} =
##     # Would need to access auditLogFile via unsafeAddr
##     # or use a cstring allocated outside GC
##     writeFile("audit.log", "log entry\n")
##   ,
##   enabled = true,
##   priority = 100
## )

## 2. Cache Invalidation Hook
## Invalidates external caches when data changes
##
## discard registerBarrelHook(
##   proc(barrelName: string, key: string,
##        changeType: KvChangeType,
##        value: string) {.gcsafe.} =
##     # In real implementation, this would send invalidation messages
##     # to external cache systems via network APIs
##     echo fmt"[cache_invalidation] Invalidating: cache:{barrelName}:{key}"
##   ,
##   enabled = true,
##   priority = 50
## )

## 3. Replication Hook
## Triggers data replication to secondary storage or backup systems
##
## discard registerBarrelHook(
##   proc(barrelName: string, key: string,
##        changeType: KvChangeType,
##        value: string) {.gcsafe.} =
##     # In production, queue replication job via message broker
##     echo fmt"[replication] Queuing: {barrelName}/{key}"
##   ,
##   enabled = true,
##   priority = 10
## )

## 4. Metrics Collection Hook
## Collects metrics on operations
##
## discard registerBarrelHook(
##   proc(barrelName: string, key: string,
##        changeType: KvChangeType,
##        value: string) {.gcsafe.} =
##     # Would need atomic counters or thread-local storage
##     echo fmt"[metrics] {barrelName} - {changeType}"
##   ,
##   enabled = true,
##   priority = 5
## )

echo "✓ Registered barrel hook examples:"
echo "  - Simple logging hook (GC-safe, uses only parameters)"
echo ""
echo "Note: For hooks needing shared state, use thread-safe patterns:"
echo "  - cstring for string constants"
echo "  - unsafeAddr for global access"
echo "  - Locks or atomics for synchronization"
echo "  - Or communicate via channels instead of shared state"
