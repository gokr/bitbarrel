## BitBarrel Configuration Demo
##
## Demonstrates how to properly use the BitBarrel configuration system
## Shows BarrelConfig usage for different use cases
##
## Run with: nim c -r examples/configuration_demo.nim

import os
import strformat
import strutils
import demo_utils
import ../src/bitbarrel

proc demonstrateBarrelConfig*() =
  ## Demonstrate BarrelConfig usage for basic applications
  subsectionHeader("BarrelConfig Usage - For Basic Applications")

  echo "ℹ️  BarrelConfig is perfect for most applications that need basic control"
  echo "   over sync mode, write buffer size, and auto-compaction."
  echo ""

  # Example 1: Default configuration
  info("Example 1: Using default BarrelConfig")
  var db1 = openBarrel("examples/data/simple_default.db")
  defer: db1.close()

  discard db1.set("user:1", "Alice")
  discard db1.set("user:2", "Bob")
  echo &"   ✓ Created database with defaults - {db1.count()} keys"
  echo ""

  # Example 2: Custom configuration for performance
  info("Example 2: Custom BarrelConfig for high performance")
  var cfg = defaultBarrelConfig()
  cfg.writeBufferSize = 1024 * 1024  # 1MB write buffer
  cfg.syncMode = UserSyncMode.None  # Don't sync on every write
  cfg.autoCompact = true
  cfg.compactThreshold = 0.4  # Compact at 40% tombstones

  var db2 = openBarrel("examples/data/simple_fast.db", cfg)
  defer: db2.close()

  discard db2.set("session:1", "data-xxxx")
  discard db2.set("session:2", "data-yyyy")
  echo &"   ✓ Created high-performance database - write buffer: {cfg.writeBufferSize} bytes"
  echo ""

  # Example 3: Configuration for durability
  info("Example 3: BarrelConfig for maximum durability")
  var durableCfg = defaultBarrelConfig()
  durableCfg.syncMode = UserSyncMode.Fsync  # Fsync on every write
  durableCfg.writeBufferSize = 32 * 1024  # Smaller buffer for frequent syncs

  var db3 = openBarrel("examples/data/safe.db", durableCfg)
  defer: db3.close()

  discard db3.set("important:1", "critical-data-1")
  discard db3.set("important:2", "critical-data-2")
  echo &"   ✓ Created durable database - sync mode: {durableCfg.syncMode}"
  echo ""

  # Cleanup data files
  # Note: cleanupDataFiles() will be run later in demonstrateConfigurationInAction

proc demonstrateFullConfig*() =
  ## Demonstrate full BitBarrelConfig usage for advanced applications
  subsectionHeader("Full BitBarrelConfig Usage - For Advanced Applications")

  echo "ℹ️  Full BitBarrelConfig provides comprehensive control over all BitBarrel settings"
  echo "   Perfect for server deployments and production use cases."
  echo ""

  # Example 1: Load from YAML file
  info("Example 1: Loading configuration from YAML file")
  let configPath = "examples/bitbarrel_config.yaml"

  if fileExists(configPath):
    try:
      let config = initConfig(configPath)
      success(&"Configuration loaded from {configPath}")
      echo ""
      echo "Configuration values from YAML:"
      keyValue("Server Port", config.server.port)
      keyValue("Data Directory", config.storage.dataDir)
      keyValue("Sync Mode", $config.storage.syncMode)
      keyValue("Worker Threads", config.performance.workerThreads)
      keyValue("Compact Enabled", config.compact.enabled)
      echo ""
    except Exception as e:
      error(&"Failed to load config: {e.msg}")
  else:
    warning(&"Config file not found: {configPath}")

  # Example 2: Environment variable overrides
  info("Example 2: Environment variable overrides")
  echo "Environment variables take precedence over YAML config:"
  echo ""

  # Set some environment variables
  putEnv("BITBARREL_SERVER_PORT", "9090")
  putEnv("BITBARREL_STORAGE_DATA_DIR", "./examples/data/env_override")
  putEnv("BITBARREL_PERFORMANCE_WORKER_THREADS", "8")

  echo "Set environment variables:"
  echo "   BITBARREL_SERVER_PORT=9090"
  echo "   BITBARREL_STORAGE_DATA_DIR=./examples/data/env_override"
  echo "   BITBARREL_PERFORMANCE_WORKER_THREADS=8"
  echo ""

  try:
    let config = initConfig(configPath)  # Will also load env vars
    echo "Configuration after environment overrides:"
    keyValue("Server Port", config.server.port)
    keyValue("Data Directory", config.storage.dataDir)
    keyValue("Worker Threads", config.performance.workerThreads)
    echo ""
    success("Environment variables successfully override config!")
  except Exception as e:
    error(&"Error: {e.msg}")

  # Clean up environment variables
  delEnv("BITBARREL_SERVER_PORT")
  delEnv("BITBARREL_STORAGE_DATA_DIR")
  delEnv("BITBARREL_PERFORMANCE_WORKER_THREADS")

proc demonstrateConfigurationInAction*() =
  ## Show how configuration affects actual BitBarrel operations
  subsectionHeader("Configuration in Action - Real Operations")

  echo "ℹ️  Seeing how different configurations affect actual operations"
  echo ""

  # Compare write performance with different sync modes
  info("Comparing write operations with different sync modes:")
  echo ""

  # Fast mode - no syncing
  var fastCfg = defaultBarrelConfig()
  fastCfg.syncMode = UserSyncMode.None
  fastCfg.writeBufferSize = 256 * 1024

  var fastTimer = startTimer()
  var fastDb = openBarrel("examples/data/fast.db", fastCfg)
  defer: fastDb.close()

  for i in 0..<1000:
    let key = &"fast:test:{i}"
    let value = &"value-{i:04d}"
    discard fastDb.set(key, value)

  fastTimer.stop()
  echo "Fast mode (None sync):"
  keyValue("1000 writes", &"{fastTimer.elapsed()}ms")
  echo ""

  # Safe mode - full sync
  var safeCfg = defaultBarrelConfig()
  safeCfg.syncMode = UserSyncMode.Fsync
  safeCfg.writeBufferSize = 32 * 1024

  var safeTimer = startTimer()
  var safeDb = openBarrel("examples/data/safe.db", safeCfg)
  defer: safeDb.close()

  for i in 0..<1000:
    let key = &"safe:test:{i}"
    let value = &"value-{i:04d}"
    discard safeDb.set(key, value)

  safeTimer.stop()
  echo "Safe mode (Fsync):"
  keyValue("1000 writes", &"{safeTimer.elapsed()}ms")
  echo ""

  let speedRatio = safeTimer.elapsed() / fastTimer.elapsed()
  info(&"Performance ratio: {speedRatio:.1f}x (safe/fast)")

  # cleanupDataFiles()  # Optional cleanup

proc demonstrateBestPractices*() =
  ## Show configuration best practices
  subsectionHeader("Configuration Best Practices")

  echo "✓ Use BarrelConfig for most applications:"
  info("   import bitbarrel/barrel")
  info("   var db = openBarrel('myapp.db')")
  echo ""

  echo "✓ Customize BarrelConfig for specific needs:"
  info("   var cfg = defaultBarrelConfig()")
  info("   cfg.syncMode = UserSyncMode.Fsync  # For durability")
  info("   cfg.writeBufferSize = 1024 * 1024  # 1MB buffer")
  info("   var db = openBarrel('myapp.db', cfg)")
  echo ""

  echo "✓ Use full config for server deployment:"
  info("   import bitbarrel/config")
  info("   let config = initConfig('production.yaml')")
  info("   # Then use config values throughout app")
  echo ""

  echo "✓ Use environment variables for deployment:"
  info("   BITBARREL_SERVER_PORT=9090")
  info("   BITBARREL_STORAGE_DATA_DIR=/mnt/bitbarrel/data")
  info("   # These override YAML configuration")
  echo ""

  echo "✓ Validate configuration before use:"
  info("   if not validateConfig(config):")
  info("     quit('Invalid configuration')")
  echo ""

  echo "✓ Choose sync mode wisely:"
  info("   • None - Max performance, data loss on crash")
  info("   • Sync - Balanced (default)")
  info("   • Fsync - Max durability, slower")
  echo ""
proc main() =
  sectionHeader("BitBarrel Configuration Management Demo")

  echo ""
  echo "This demo shows how to PROPERLY use the BitBarrel configuration system."
  echo "It does NOT reimplement configuration logic - it USES the existing BitBarrel APIs!"
  echo ""

  demonstrateBarrelConfig()
  separator()

  demonstrateFullConfig()
  separator()

  demonstrateConfigurationInAction()
  separator()

  demonstrateBestPractices()

  echo ""
  echo "✨ Configuration demo completed!"
  echo ""
  echo "Key takeaways:"
  success("• Use BarrelConfig for most applications")
  success("• Use full BitBarrelConfig for server deployments")
  success("• Environment variables override configuration files")
  success("• Sync mode affects durability vs performance")

when isMainModule:
  main()