## BitBarrel Barrel Modes Demo
##
## Demonstrates the three different barrel modes (bmHash, bmCritBit, bmHugeCritBit)
## with practical use cases for each mode.
##
## Run with: nim c -r examples/barrel_modes_demo.nim

import os
import strformat
import strutils
import times
import random
import bitbarrel
from bitbarrel/types import BarrelMode, BarrelConfig
from bitbarrel/barrel import defaultBarrelConfig

proc printHeader(title: string) =
  echo ""
  echo "╔" & "═".repeat(78) & "╗"
  echo "║ " & title.alignLeft(77) & "║"
  echo "╚" & "═".repeat(78) & "╝"
  echo ""

proc printSection(title: string) =
  echo ""
  echo "─".repeat(80)
  echo "  " & title
  echo "─".repeat(80)
  echo ""

proc demoNormalMode() =
  ## Demonstrate bmHash mode - hash table for O(1) lookups
  printSection("Barrel Mode 1: bmHash (Hash Table)")

  echo "Use case: Session storage, caching, general key-value operations"
  echo "Characteristics:"
  echo "  • O(1) lookup time complexity"
  echo "  • ~40 bytes memory per key"
  echo "  • Keys are not ordered"
  echo "  • Fastest for simple get/set operations"
  echo ""

  # Create bmHash barrel (this is the default)
  var cfg = defaultBarrelConfig()
  cfg.mode = BarrelMode.bmHash  # Explicitly set normal mode
  cfg.syncMode = UserSyncMode.Sync  # Balanced durability
  cfg.writeBufferSize = 64 * 1024  # 64KB buffer

  var sessionDb = openBarrel("examples/data/session_store.db", cfg)
  defer: sessionDb.close()

  echo "📊 Creating a session store for a web application..."
  echo ""

  # Store session data
  let numSessions = 1000
  let startTime = epochTime()

  for i in 0..<numSessions:
    let sessionId = &"sess_{i:06d}_{rand(1000000)}"
    let userId = &"user_{i mod 100}"
    let sessionData = &"{{\"user_id\": \"{userId}\", \"last_active\": {epochTime():.0f}}}"
    discard sessionDb.set(sessionId, sessionData)

  let storeTime = epochTime() - startTime
  echo &"   ✓ Stored {numSessions} sessions in {storeTime*1000:.2f}ms"
  echo &"   ✓ Average: {(storeTime*1000000)/numSessions.float:.2f}μs per session"
  echo ""

  # Simulate session lookups
  echo "🔍 Simulating session lookups..."
  var foundCount = 0
  let lookupStart = epochTime()

  for i in 0..<100:
    let sessionId = &"sess_{i*10:06d}_{rand(1000000)}"
    let sessionData = sessionDb.get(sessionId)
    if sessionData.len > 0:
      foundCount.inc()

  let lookupTime = epochTime() - lookupStart
  echo &"   ✓ Looked up {foundCount} sessions in {lookupTime*1000:.2f}ms"
  echo &"   ✓ Average lookup: {(lookupTime*1000000)/100:.2f}μs"
  echo ""
  echo "🏆 bmHash is perfect for: High-performance session stores, caching layers,"
  echo "   and any workload requiring fast O(1) key lookups"
  echo ""

  # Cleanup
  if dirExists("examples/data"):
    for file in walkDir("examples/data"):
      if file.path.endsWith("session_store.db") or file.path.endsWith("session_store.db"):
        removeFile(file.path)

proc demoCritBitMode() =
  ## Demonstrate bmCritBit mode - sorted keys with range queries
  printSection("Barrel Mode 2: bmCritBit (Sorted with Range Queries)")

  echo "Use case: Time-series data, leaderboards, ordered data, prefix searches"
  echo "Characteristics:"
  echo "  • O(k) lookup where k is key length"
  echo "  • Keys stored in sorted order (lexicographic)"
  echo "  • Supports range queries and prefix searches"
  echo "  • Ideal for ordered traversal and scanning"
  echo ""

  # Create bmCritBit barrel
  var cfg = defaultBarrelConfig()
  cfg.mode = BarrelMode.bmCritBit  # Enable CritBit tree mode
  cfg.syncMode = UserSyncMode.Sync

  var timeSeriesDb = openBarrel("examples/data/timeseries.db", cfg)
  defer: timeSeriesDb.close()

  echo "📈 Storing time-series sensor data..."
  echo ""

  # Store temperature readings for a month
  let baseTime = parse("2024-01-01", "yyyy-MM-dd").toTime()
  let baseSeconds = baseTime.toUnix()
  let readingsPerDay = 24  # Hourly readings
  let numDays = 30

  let startTime = epochTime()
  for day in 0..<numDays:
    for hour in 0..<readingsPerDay:
      let timestamp = baseSeconds + (day * 86400 + hour * 3600)
      let temp = 20.0 + rand(10.0)  # Random temp between 20-30°C
      let key = &"sensor:temp:{timestamp}"
      let value = &"{temp:.1f}"
      discard timeSeriesDb.set(key, value)

  let storeTime = epochTime() - startTime
  let totalReadings = numDays * readingsPerDay
  echo &"   ✓ Stored {totalReadings} temperature readings in {storeTime*1000:.2f}ms"
  echo ""

  echo "🔍 Range query: Getting all readings from January 15-17..."
  let startRange = baseSeconds + (14 * 86400)  # Jan 15
  let endRange = baseSeconds + (17 * 86400)     # Jan 17

  let rangeStart = epochTime()
  let readingsInRange = timeSeriesDb.keysInRange(&"sensor:temp:{startRange}",
                                                   &"sensor:temp:{endRange}")
  let rangeTime = epochTime() - rangeStart

  echo &"   ✓ Found {readingsInRange.len} readings in range"
  echo &"   ✓ Query time: {rangeTime*1000:.2f}ms"
  echo ""

  echo "🔍 Prefix search: Getting all temperature sensor readings..."
  let prefixStart = epochTime()
  let tempReadings = timeSeriesDb.keysWithPrefix("sensor:temp:")
  let prefixTime = epochTime() - prefixStart

  echo &"   ✓ Found {tempReadings.len} temperature readings"
  echo &"   ✓ Query time: {prefixTime*1000:.2f}ms"
  echo ""

  echo "📊 Prefix count: Counting humidity readings without retrieving them..."
  discard timeSeriesDb.set("sensor:humidity:1234567890", "65.2")
  discard timeSeriesDb.set("sensor:humidity:1234567891", "68.1")

  let countStart = epochTime()
  let humidityCount = timeSeriesDb.countWithPrefix("sensor:humidity:")
  let countTime = epochTime() - countStart

  echo &"   ✓ Found {humidityCount} humidity readings"
  echo &"   ✓ Count time: {countTime*1000:.3f}ms (very efficient)"
  echo ""

  echo "🏆 bmCritBit is perfect for: Time-series databases, leaderboards,"
  echo "   log analysis, and any application needing ordered key traversal"
  echo ""

  # Cleanup
  if dirExists("examples/data"):
    for file in walkDir("examples/data"):
      if file.path.endsWith("timeseries.db"):
        removeFile(file.path)

proc demoRangedMode() =
  ## Demonstrate bmHugeCritBit mode - two-tier for massive datasets
  printSection("Barrel Mode 3: bmHugeCritBit (Two-Tier Index)")

  echo "Use case: Massive datasets, time-series, analytics data"
  echo "Characteristics:"
  echo "  • O(key_len) lookup with two-tier indexing"
  echo "  • RangeKeyDir partitions for efficient range queries"
  echo "  • Configurable max entries per partition"
  echo "  • Optimized for workloads with sequential key access"
  echo ""

  # Create bmHugeCritBit barrel
  var cfg = defaultBarrelConfig()
  cfg.mode = BarrelMode.bmHugeCritBit  # Enable huge critbit mode
  cfg.hugeConfig.rangeCacheSize = 5    # Keep 5 partitions in memory
  cfg.syncMode = UserSyncMode.Sync

  var analyticsDb = openBarrel("examples/data/analytics.db", cfg)
  defer: analyticsDb.close()

  echo "📊 Storing user analytics events (1,000 users, 50 events each)..."
  echo ""

  # Simulate analytics data for many users
  let numUsers = 1000
  let eventsPerUser = 50
  let startTime = epochTime()

  for userId in 0..<numUsers:
    for eventId in 0..<eventsPerUser:
      let timestamp = epochTime().int64
      let key = &"analytics:user:{userId}:event:{timestamp}:{eventId}"
      let value = &"{{\"type\": \"page_view\", \"url\": \"/product/{rand(1000)}\"}}"
      discard analyticsDb.set(key, value)

  let storeTime = epochTime() - startTime
  let totalEvents = numUsers * eventsPerUser
  echo &"   ✓ Stored {totalEvents} events in {storeTime:.2f}s"
  echo &"   ✓ Average: {(storeTime*1000000)/totalEvents.float:.2f}μs per event"
  echo ""

  echo "🔍 Querying events for specific users..."
  echo ""

  # Query events for a few users (this will load their partitions)
  for userId in [0, 100, 500]:
    let queryStart = epochTime()
    let prefix = &"analytics:user:{userId}:"
    let userEvents = analyticsDb.keysWithPrefix(prefix)
    let queryTime = epochTime() - queryStart

    echo &"   ✓ User {userId}: {userEvents.len} events found in {queryTime*1000:.2f}ms"

  echo ""

  echo "📊 Checking statistics..."
  echo &"   ✓ Total keys: {analyticsDb.count()}"
  echo &"   ✓ Barrel mode: {analyticsDb.getMode()}"
  echo ""
  echo ""

  echo "🏆 bmHugeCritBit is perfect for: Analytics data, user activity logs,"
  echo "   large-scale event tracking, and datasets with billions of keys"
  echo ""

  # Cleanup
  if dirExists("examples/data"):
    for file in walkDir("examples/data"):
      if file.path.endsWith("analytics.db"):
        removeFile(file.path)

proc main() =
  printHeader("BitBarrel Barrel Modes Demo")

  echo "This demo showcases all three barrel modes with practical examples."
  echo ""
  echo "Available modes:"
  echo "  📦 bmHash  - Hash table for O(1) lookups (default)"
  echo "  🌳 bmCritBit - Sorted keys with range queries"
  echo "  🗂️  bmHugeCritBit  - Lazy-loaded partitions for large datasets"
  echo ""

  # Run demos
  demoNormalMode()
  demoCritBitMode()
  demoRangedMode()

  # Final comparison
  printSection("Mode Comparison Summary")
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────────┐"
  echo "│ Mode      │ Best For                      │ Performance │ Memory   │"
  echo "├───────────┼───────────────────────────────┼─────────────┼──────────┤"
  echo "│ bmHash  │ Session storage, caching      │ Fastest     │ Moderate │"
  echo "│ bmCritBit │ Time-series, leaderboards     │ Fast        │ Moderate │"
  echo "│ bmHugeCritBit  │ Analytics, large datasets     │ Good        │ Low      │"
  echo "└─────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "💡 Choose bmHash for maximum performance, bmCritBit for ordered data,"
  echo "   and bmHugeCritBit when you have more keys than can fit in memory."
  echo ""

  printHeader("Demo Complete!")
  echo "✨ Run this demo with: nim c -r examples/barrel_modes_demo.nim"

when isMainModule:
  main()
