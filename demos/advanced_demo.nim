## BitBarrel Advanced Features Demo
##
## Demonstrates advanced BitBarrel features:
## - Barrel modes (bmHash, bmCritBit, bmHugeCritBit)
## - Compression (LZ4, Snappy)
## - Configuration (BarrelConfig, YAML, environment variables)
##
## Run with: nim c -r demos/advanced_demo.nim

import std/[os, strformat, times, random]
import std/strutils except formatSize
import demo_utils
import bitbarrel
from bitbarrel/types import BarrelMode, BarrelConfig, UserSyncMode

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

proc demoBarrelModes() =
  ## Demonstrate barrel modes (bmHash, bmCritBit)
  printSection("Barrel Modes Demo")

  echo "Available modes:"
  echo "  📦 bmHash  - Hash table for O(1) lookups (default)"
  echo "  🌳 bmCritBit - Sorted keys with range queries"
  echo ""

  # Demo: bmHash mode (default)
  echo "Demo 1: bmHash mode for session storage"
  echo "Use case: High-performance session cache, simple key-value"

  var hashConfig = defaultBarrelConfig()
  hashConfig.mode = BarrelMode.bmHash
  hashConfig.syncMode = UserSyncMode.Sync
  hashConfig.writeBufferSize = 64 * 1024

  var sessionDb = openBarrel("demos/data/session_store.data", hashConfig)
  defer: sessionDb.close()

  # Store session data
  let numSessions = 100
  for i in 0..<numSessions:
    let sessionId = &"sess_{i:04d}_{rand(1000000)}"
    let userId = &"user_{i mod 10}"
    let sessionData = &"{{\"user_id\": \"{userId}\", \"last_active\": {getTime().toUnix()}}}"
    discard sessionDb.set(sessionId, sessionData)

  echo &"  ✓ Stored {numSessions} sessions"

  # Lookup sessions
  var foundCount = 0
  for i in 0..<10:
    let sessionId = &"sess_{i*10:04d}_{rand(1000000)}"
    let sessionData = sessionDb.get(sessionId)
    if sessionData.len > 0:
      inc foundCount

  echo &"  ✓ Looked up {foundCount} sessions"
  echo "  ★ bmHash is perfect for: Session storage, caching, simple key-value"
  echo ""

  # Demo: bmCritBit mode for range queries
  echo "Demo 2: bmCritBit mode for ordered data"
  echo "Use case: Time-series data, leaderboards, prefix searches"

  var critBitConfig = defaultBarrelConfig()
  critBitConfig.mode = BarrelMode.bmCritBit
  critBitConfig.syncMode = UserSyncMode.Sync

  var timeSeriesDb = openBarrel("demos/data/timeseries.data", critBitConfig)
  defer: timeSeriesDb.close()

  # Store time-series data
  let baseTime = getTime().toUnix()
  for i in 0..<100:
    let timestamp = baseTime + i
    let temp = 20.0 + rand(10.0)
    let key = &"sensor:temp:{timestamp}"
    let value = &"{temp:.1f}"
    discard timeSeriesDb.set(key, value)

  echo "  ✓ Stored 100 temperature readings"

  # Range query
  let startRange = baseTime
  let endRange = baseTime + 50
  let keysInRange = timeSeriesDb.keysInRange(
    &"sensor:temp:{startRange}", &"sensor:temp:{endRange}")
  echo &"  ✓ Range query found {keysInRange.len} readings"

  # Prefix search
  let tempKeys = timeSeriesDb.keysWithPrefix("sensor:temp:")
  echo &"  ✓ Prefix search found {tempKeys.len} temperature readings"

  # Count with prefix
  let count = timeSeriesDb.countWithPrefix("sensor:temp:")
  echo &"  ✓ Count with prefix: {count} temperature readings"

  echo "  ★ bmCritBit is perfect for: Time-series, leaderboards, ordered traversal"
  echo ""

  # Cleanup
  for path in ["demos/data/session_store.data", "demos/data/timeseries.data"]:
    if fileExists(path):
      removeFile(path)

proc demoCompression() =
  ## Demonstrate compression capabilities
  printSection("Compression Demo")

  echo "BitBarrel includes LZ4 compression by default."
  echo "Alternative compression options:"
  echo "  -d:noCompression     Disable compression"
  echo "  -d:snappyCompression Use Snappy instead of LZ4"
  echo ""

  when defined(noCompression):
    warning("⚠️  Compression: Disabled (built with -d:noCompression)")
  elif defined(snappyCompression):
    success("✅ Compression: Snappy enabled (built with -d:snappyCompression)")
  else:
    success("✅ Compression: LZ4 enabled (default)")

  echo ""

  # Test different data types
  var db = openBarrel("demos/data/compression_test.data")
  defer: db.close()

  echo "Testing compression with different data patterns:"
  echo ""

  # Test 1: Small data (won't compress well)
  var smallStart = cpuTime()
  discard db.set("small", "abc")
  let smallTime = (cpuTime() - smallStart) * 1000
  echo &"  Small data: {smallTime:.2f} ms (typically no compression benefit)"

  # Test 2: Repeated data (compresses well)
  var repeatedStart = cpuTime()
  discard db.set("repeated", "A".repeat(1000))
  let repeatedTime = (cpuTime() - repeatedStart) * 1000
  echo &"  Repeated data: {repeatedTime:.2f} ms (high compression benefit)"

  # Test 3: Text data
  var textStart = cpuTime()
  let text = "This is a test of compression effectiveness. ".repeat(50)
  discard db.set("text", text)
  let textTime = (cpuTime() - textStart) * 1000
  echo &"  Text data: {textTime:.2f} ms (moderate compression benefit)"

  # Verify data integrity
  let retrieved = db.get("repeated")
  echo ""
  if retrieved == "A".repeat(1000):
    success("✓ Data integrity verified after compression")

  # Cleanup
  if fileExists("demos/data/compression_test.data"):
    removeFile("demos/data/compression_test.data")

proc demoConfiguration() =
  ## Demonstrate configuration usage
  printSection("Configuration Demo")

  echo "BarrelConfig provides control over:"
  echo "  - Sync mode (None, Sync, Fsync)"
  echo "  - Write buffer size"
  echo "  - Barrel mode"
  echo "  - CRC validation"
  echo "  - Auto-compaction"
  echo ""

  # Example 1: Default configuration
  echo "Demo 1: Using default BarrelConfig"
  var db1 = openBarrel("demos/data/default_test.data")
  defer: db1.close()

  discard db1.set("test", "data")
  let config1 = db1.getConfig()
  echo &"  ✓ Database opened with defaults"
  echo &"    Sync mode: {config1.syncMode}"
  echo &"    Buffer size: {formatSize(config1.writeBufferSize)}"
  echo &"    Barrel mode: {config1.mode}"
  echo ""

  # Example 2: High performance configuration
  echo "Demo 2: High performance configuration"
  var perfConfig = defaultBarrelConfig()
  perfConfig.syncMode = UserSyncMode.None
  perfConfig.writeBufferSize = 1024 * 1024  # 1MB buffer
  perfConfig.mode = BarrelMode.bmHash

  var db2 = openBarrel("demos/data/fast_test.data", perfConfig)
  defer: db2.close()

  let config2 = db2.getConfig()
  echo &"  ✓ Database opened for max performance"
  echo &"    Sync mode: {config2.syncMode} (no sync)"
  echo &"    Buffer size: {formatSize(config2.writeBufferSize)}"
  echo &"    Barrel mode: {config2.mode}"
  echo ""

  # Example 3: Maximum durability configuration
  echo "Demo 3: Maximum durability configuration"
  var durableConfig = defaultBarrelConfig()
  durableConfig.syncMode = UserSyncMode.Fsync
  durableConfig.writeBufferSize = 32 * 1024  # Smaller buffer
  durableConfig.validateCrc = true

  var db3 = openBarrel("demos/data/safe_test.data", durableConfig)
  defer: db3.close()

  let config3 = db3.getConfig()
  echo &"  ✓ Database opened for max durability"
  echo &"    Sync mode: {config3.syncMode} (fsync on writes)"
  echo &"    Buffer size: {formatSize(config3.writeBufferSize)}"
  echo &"    Validate CRC: {config3.validateCrc}"
  echo ""

  # Example 4: Range query configuration
  echo "Demo 4: Range query configuration (bmCritBit mode)"
  var rangeConfig = defaultBarrelConfig()
  rangeConfig.mode = BarrelMode.bmCritBit
  rangeConfig.syncMode = UserSyncMode.Sync

  var db4 = openBarrel("demos/data/range_test.data", rangeConfig)
  defer: db4.close()

  # Add some data and test range query
  for i in 0..<10:
    discard db4.set(&"range:{i}", &"value{i}")

  let inRange = db4.keysInRange("range:2", "range:7")
  echo &"  ✓ Range query found {inRange.len} keys"
  echo ""

  # Cleanup
  for path in ["demos/data/default_test.data", "demos/data/fast_test.data",
               "demos/data/safe_test.data", "demos/data/range_test.data"]:
    if fileExists(path):
      removeFile(path)

proc printConfigurationBestPractices() =
  ## Print configuration best practices
  printSection("Configuration Best Practices")

  echo "Sync Mode Selection:"
  info("  • None mode - Max performance, data loss on process crash")
  info("  • Sync mode - Balanced (default), synced to OS on each write")
  info("  • Fsync mode - Max durability, waits for disk I/O")
  echo ""

  echo "Write Buffer Size:"
  info("  • 16KB - Low latency, for low-load applications")
  info("  • 256KB - Balanced performance and memory (recommended)")
  info("  • 1MB - High throughput, for bulk writes")
  echo ""

  echo "Barrel Mode Selection:"
  info("  • bmHash - Use for simple key-value, session storage")
  info("  • bmCritBit - Use for time-series, leaderboards, ordered data")
  echo ""

  echo "When to use each feature:"
  info("  • Range queries - Set mode to bmCritBit")
  info("  • Prefix search - Set mode to bmCritBit")
  info("  • Compression - Build with -d:lz4Compression or -d:snappyCompression")
  info("  • Maximum durability - Set syncMode to Fsync")
  info("  • Maximum performance - Set syncMode to None, increase buffer size")

proc main() =
  printHeader("BitBarrel Advanced Features Demo")

  echo "This demo showcases advanced BitBarrel features."
  echo ""

  demoBarrelModes()
  demoCompression()
  demoConfiguration()
  printConfigurationBestPractices()

  printHeader("Demo Complete!")

  echo "Advanced features demonstrated:"
  success("- Barrel modes - bmHash for speed, bmCritBit for range queries")
  success("- Compression - LZ4/Snappy for space savings")
  success("- Configuration - BarrelConfig for different use cases")
  echo ""
  echo "Best practices:"
  echo "  - Choose barrel mode based on your query patterns"
  echo "  - Use compression for large, repetitive values"
  echo "  - Configure sync mode based on durability needs"
  echo "  - Tune buffer size for your workload"
  echo ""

when isMainModule:
  main()
