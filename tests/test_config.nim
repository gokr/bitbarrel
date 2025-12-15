## Configuration Tests

import std/[os, unittest, strformat]
import ../src/bitbarrel/[config, config_parser]
import ../src/bitbarrel/types

suite "Configuration Tests":

  test "Default configuration":
    let config = getDefaultConfig()

    # Test server defaults
    check config.server.address == "0.0.0.0"
    check config.server.port == 8080
    check config.server.maxConnections == 10000

    # Test storage defaults
    check config.storage.dataDir == "./data"
    check config.storage.maxFileSize == 1024 * 1024 * 1024
    check config.storage.maxKeySize == 64 * 1024
    check config.storage.maxValueSize == 1024 * 1024
    check config.storage.syncMode == syncImmediate

    # Test performance defaults
    check config.performance.workerThreads == 4
    check config.performance.writeBufferSize == 1000

    # Test merge defaults
    check config.merge.enabled == true
    check config.merge.triggerThreshold == 0.3

    # Test logging defaults
    check config.logging.level == "info"
    check config.logging.file == "barrel.log"

  test "YAML loading":
    # Create a temporary YAML file
    let tempFile = getTempDir() / "test_config.yaml"

    let yamlContent = """
server:
  address: "127.0.0.1"
  port: 9999
  max_connections: 500

storage:
  data_dir: "/tmp/kvs_data"
  max_key_size: "128KB"
  sync_mode: "batched"

performance:
  worker_threads: 8

merge:
  enabled: false

logging:
  level: "debug"
"""

    writeFile(tempFile, yamlContent)

    try:
      let config = loadConfigFromYaml(tempFile)

      # Check that values were loaded correctly
      check config.server.address == "127.0.0.1"
      check config.server.port == 9999
      check config.server.maxConnections == 500

      check config.storage.dataDir == "/tmp/kvs_data"
      check config.storage.maxKeySize == 128 * 1024
      check config.storage.syncMode == syncBatched

      check config.performance.workerThreads == 8

      check config.merge.enabled == false

      check config.logging.level == "debug"

    finally:
      removeFile(tempFile)

  test "Environment variable overrides":
    # Set some environment variables
    putEnv("KVS_SERVER_PORT", "7777")
    putEnv("KVS_STORAGE_DATA_DIR", "/env/data")
    putEnv("KVS_LOGGING_LEVEL", "warn")
    putEnv("KVS_MERGE_ENABLED", "false")

    var config = getDefaultConfig()

    # Apply environment overrides
    loadFromEnvironment(config)

    try:
      check config.server.port == 7777
      check config.storage.dataDir == "/env/data"
      check config.logging.level == "warn"
      check config.merge.enabled == false

    finally:
      # Clean up environment
      delEnv("KVS_SERVER_PORT")
      delEnv("KVS_STORAGE_DATA_DIR")
      delEnv("KVS_LOGGING_LEVEL")
      delEnv("KVS_MERGE_ENABLED")

  test "Configuration validation":
    var config = getDefaultConfig()

    # Valid configuration should pass
    check validateConfig(config) == true

    # Invalid port should fail
    config.server.port = 0
    check validateConfig(config) == false

    # Fix port and test other invalid values
    config.server.port = 8080
    config.storage.maxKeySize = 0
    check validateConfig(config) == false

    # Fix key size but add invalid merge threshold
    config.storage.maxKeySize = 64 * 1024
    config.merge.triggerThreshold = 1.5  # Above 1.0
    check validateConfig(config) == false

  test "Size parsing from YAML":
    let tempFile = getTempDir() / "test_sizes.yaml"

    let yamlContent = """
storage:
  max_file_size: "2GB"
  max_key_size: "128KB"
  max_value_size: "5MB"
  min_file_size: "512KB"
"""

    writeFile(tempFile, yamlContent)

    try:
      let config = loadConfigFromYaml(tempFile)

      check config.storage.maxFileSize == 2 * 1024 * 1024 * 1024
      check config.storage.maxKeySize == 128 * 1024
      check config.storage.maxValueSize == 5 * 1024 * 1024

    finally:
      removeFile(tempFile)

  test "Sync mode parsing":
    let tempFile = getTempDir() / "test_sync.yaml"

    let syncModes = ["immediate", "buffered", "batched", "time_based"]

    for mode in syncModes:
      let yamlContent = fmt"""
storage:
  sync_mode: "{mode}"
"""
      writeFile(tempFile, yamlContent)

      let config = loadConfigFromYaml(tempFile)

      case mode:
        of "immediate": check config.storage.syncMode == syncImmediate
        of "buffered": check config.storage.syncMode == syncBuffered
        of "batched": check config.storage.syncMode == syncBatched
        of "time_based": check config.storage.syncMode == syncTimeBased

    removeFile(tempFile)

  test "Missing config file defaults":
    # Try to load a non-existent file
    expect IOError:
      discard loadConfigFromYaml("/non/existent/file.yaml")

  test "Init config with defaults and overrides":
    # Create a temporary YAML file
    let tempFile = getTempDir() / "test_init.yaml"

    let yamlContent = """
server:
  port: 6666
"""

    writeFile(tempFile, yamlContent)

    # Set environment variable
    putEnv("KVS_SERVER__ADDRESS", "1.1.1.1")

    try:
      let config = initConfig(tempFile)

      # Check that it started with defaults, applied YAML, then env
      check config.server.port == 6666  # From YAML
      check config.server.address == "1.1.1.1"  # From environment
      check config.server.maxConnections == 10000  # Default

    finally:
      removeFile(tempFile)
      delEnv("KVS_SERVER__ADDRESS")

suite "Configuration Integration Tests":

  test "Full configuration pipeline":
    # Simulate a full initialization sequence
    let tempFile = getTempDir() / "test_full.yaml"

    # Create config file
    let yamlContent = """
server:
  port: 5555

storage:
  data_dir: "/kvs/data"

logging:
  level: "debug"
"""

    writeFile(tempFile, yamlContent)

    # Set environment variable
    putEnv("KVS_SERVER_MAX_CONNECTIONS", "2000")

    try:
      # Initialize configuration
      let config = initConfig(tempFile)

      # Get via global accessor
      let retrieved = getConfig()

      # Everything should be properly merged
      check retrieved.server.port == 5555  # From file
      check retrieved.server.address == "0.0.0.0"  # Default
      check retrieved.server.maxConnections == 2000  # From env
      check retrieved.storage.dataDir == "/kvs/data"  # From file
      check retrieved.logging.level == "debug"  # From file

    finally:
      removeFile(tempFile)
      delEnv("KVS_SERVER_MAX_CONNECTIONS")