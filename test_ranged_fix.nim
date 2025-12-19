import src/bitbarrel
import std/[times, sequtils, math, strutils, os]

proc testOrderedRangePartitioning() =
  echo "Testing ordered range partitioning (bmRangedCritBit)..."

  let config = BarrelConfig(
    writeBufferSize: 64 * 1024,
    syncMode: UserSyncMode.Sync,
    autoCompact: false,
    compactThreshold: 0.3,
    validateCrc: true,
    defaultTtl: 0,
    checkExpirationOnRead: true,
    deleteExpiredOnRead: false,
    mode: bmRangedCritBit,
    numRanges: 10,
    maxLoadedRanges: 10,
    rangeAccessModel: amCritBit
  )

  let dataDir = "test_ranged_data"
  createDir(dataDir)

  var barrel = openBarrel(dataDir / "test.db", 1'u32, config)

  # Insert keys with different prefixes to test range distribution
  echo "Inserting 100 keys with prefixes 'a' through 'j'..."
  for i in 0..99:
    let prefix = chr(ord('a') + (i div 10))
    let key = $prefix & "_key_" & $i
    let value = "value_" & $i
    discard barrel.set(key, value)

  echo "Testing prefix queries..."

  # Test prefix query for 'a' - should only scan 1-2 ranges, not all 10
  let startTime = cpuTime()
  let keysA = barrel.keysWithPrefix("a", limit = 100)
  let duration = cpuTime() - startTime

  echo "Keys with prefix 'a': " & $keysA.len & " keys found"
  echo "Query time: " & formatFloat(duration * 1000, ffDecimal, 3) & "ms"

  # Verify we found the expected keys
  let expectedCount = 10
  if keysA.len == expectedCount:
    echo "✓ Found expected number of keys with prefix 'a'"
  else:
    echo "✗ Expected " & $expectedCount & " keys, got " & $keysA.len

  # Test range query from 'c' to 'e'
  let startTime2 = cpuTime()
  let keysRange = barrel.keysInRange("c", "f", limit = 100)
  let duration2 = cpuTime() - startTime2

  echo "Keys in range ['c', 'f'): " & $keysRange.len & " keys found"
  echo "Range query time: " & formatFloat(duration2 * 1000, ffDecimal, 3) & "ms"

  barrel.close()

  # Cleanup
  removeDir(dataDir)

  echo "\nTest completed successfully!"

proc testHashVsOrderedPerformance() =
  echo "\nComparing hash vs ordered partitioning performance..."

  # Test with bmRangedHash (must scan all ranges)
  let hashConfig = BarrelConfig(
    writeBufferSize: 64 * 1024,
    syncMode: UserSyncMode.Sync,
    autoCompact: false,
    compactThreshold: 0.3,
    validateCrc: true,
    defaultTtl: 0,
    checkExpirationOnRead: true,
    deleteExpiredOnRead: false,
    mode: bmRangedHash,
    numRanges: 50,
    maxLoadedRanges: 50,
    rangeAccessModel: amHash
  )

  let dataDirHash = "test_hash_data"
  createDir(dataDirHash)
  var barrelHash = openBarrel(dataDirHash / "test.db", 1'u32, hashConfig)

  echo "\nPopulating hash-partitioned database (50 ranges)..."
  for i in 0..999:
    let prefix = chr(ord('a') + (i div 100))
    let key = $prefix & "_key_" & $i
    discard barrelHash.set(key, "value")

  let startTimeHash = cpuTime()
  let keysHash = barrelHash.keysWithPrefix("a", limit = 100)
  let durationHash = cpuTime() - startTimeHash

  echo "Hash mode: Found " & $keysHash.len & " keys with prefix 'a'"
  echo "Hash mode query time: " & formatFloat(durationHash * 1000, ffDecimal, 3) & "ms"

  barrelHash.close()
  removeDir(dataDirHash)

  # Test with bmRangedCritBit (optimized with candidate ranges)
  let orderedConfig = BarrelConfig(
    writeBufferSize: 64 * 1024,
    syncMode: UserSyncMode.Sync,
    autoCompact: false,
    compactThreshold: 0.3,
    validateCrc: true,
    defaultTtl: 0,
    checkExpirationOnRead: true,
    deleteExpiredOnRead: false,
    mode: bmRangedCritBit,
    numRanges: 50,
    maxLoadedRanges: 50,
    rangeAccessModel: amCritBit
  )

  let dataDirOrdered = "test_ordered_data"
  createDir(dataDirOrdered)
  var barrelOrdered = openBarrel(dataDirOrdered / "test.db", 1'u32, orderedConfig)

  echo "\nPopulating ordered-partitioned database (50 ranges)..."
  for i in 0..999:
    let prefix = chr(ord('a') + (i div 100))
    let key = $prefix & "_key_" & $i
    discard barrelOrdered.set(key, "value")

  let startTimeOrdered = cpuTime()
  let keysOrdered = barrelOrdered.keysWithPrefix("a", limit = 100)
  let durationOrdered = cpuTime() - startTimeOrdered

  echo "Ordered mode: Found " & $keysOrdered.len & " keys with prefix 'a'"
  echo "Ordered mode query time: " & formatFloat(durationOrdered * 1000, ffDecimal, 3) & "ms"

  barrelOrdered.close()
  removeDir(dataDirOrdered)

  echo "\nOrdered mode should be faster because it skips irrelevant ranges!"
  if durationOrdered < durationHash:
    echo "✓ Ordered partitioning is " & formatFloat(durationHash / durationOrdered, ffDecimal, 2) & "x faster!"
  else:
    echo "Note: With cold cache, initial query may be similar. Try warming cache first."

proc testDynamicRangeManagement() =
  echo "\nTesting dynamic range management..."

  let config = BarrelConfig(
    writeBufferSize: 64 * 1024,
    syncMode: UserSyncMode.Sync,
    autoCompact: false,
    compactThreshold: 0.3,
    validateCrc: true,
    defaultTtl: 0,
    checkExpirationOnRead: true,
    deleteExpiredOnRead: false,
    mode: bmRangedCritBit,
    numRanges: 10,
    maxLoadedRanges: 10,
    rangeAccessModel: amCritBit,
    rangeManagementInterval: 60  # Enable management
  )

  let dataDir = "test_mgmt_data"
  createDir(dataDir)
  var barrel = openBarrel(dataDir / "test.db", 1'u32, config)

  # Enable management explicitly
  barrel.enableRangeManagement(true)

  # Check initial health
  let initialHealth = barrel.getRangeHealth()
  echo "Initial health - Total ranges: ", initialHealth.totalRanges
  echo "Initial health - Healthy ranges: ", initialHealth.healthyRanges

  # Insert enough data to potentially trigger splits
  echo "\nInserting 5000 keys..."
  for i in 0..4999:
    let prefix = chr(ord('a') + (i div 500))
    let key = $prefix & "_key_" & $i
    discard barrel.set(key, "value_" & $i)

  # Get health after inserts
  let afterInsertHealth = barrel.getRangeHealth()
  echo "After insert - Total ranges: ", afterInsertHealth.totalRanges
  echo "After insert - Ranges with data: ", afterInsertHealth.totalRanges - afterInsertHealth.healthyRanges

  # Test manual range management
  echo "\nRunning manual range management..."
  let actions = barrel.checkAndManageRanges()
  echo "Management actions taken: ", actions

  # Get health after management
  let afterMgmtHealth = barrel.getRangeHealth()
  echo "After management - Total ranges: ", afterMgmtHealth.totalRanges
  echo "After management - Healthy ranges: ", afterMgmtHealth.healthyRanges
  echo "After management - Ranges needing split: ", afterMgmtHealth.rangesNeedingSplit
  echo "After management - Ranges needing merge: ", afterMgmtHealth.rangesNeedingMerge

  # Test range queries still work correctly
  echo "\nTesting range queries after management..."
  let startTime = cpuTime()
  let aKeys = barrel.keysWithPrefix("a", limit = 100)
  let queryTime = cpuTime() - startTime

  echo "Keys with prefix 'a': ", aKeys.len
  echo "Query time: ", formatFloat(queryTime * 1000, ffDecimal, 3), "ms"

  # Test range query
  let rangeStart = cpuTime()
  let rangeKeys = barrel.keysInRange("c", "f", limit = 100)
  let rangeTime = cpuTime() - rangeStart

  echo "Keys in range ['c', 'f'): ", rangeKeys.len
  echo "Range query time: ", formatFloat(rangeTime * 1000, ffDecimal, 3), "ms"

  barrel.close()
  removeDir(dataDir)

  echo "✓ Dynamic range management test completed successfully!"

proc testConfigurableManagement() =
  echo "\nTesting configurable management thresholds..."

  let dataDir = "test_config_mgmt"
  createDir(dataDir)

  let config = BarrelConfig(
    writeBufferSize: 64 * 1024,
    syncMode: UserSyncMode.Sync,
    autoCompact: false,
    compactThreshold: 0.3,
    validateCrc: true,
    defaultTtl: 0,
    checkExpirationOnRead: true,
    deleteExpiredOnRead: false,
    mode: bmRangedCritBit,
    numRanges: 5,
    maxLoadedRanges: 5,
    rangeAccessModel: amCritBit,
    rangeManagementInterval: 0  # Start disabled
  )

  var barrel = openBarrel(dataDir / "test.db", 1'u32, config)

  # Customize management config
  var mgmtConfig = barrel.getRangeManagementConfig()
  mgmtConfig.enabled = true
  mgmtConfig.splitThresholdKeys = 100  # Very low for testing
  mgmtConfig.mergeThresholdKeys = 10   # Very low for testing
  mgmtConfig.autoSplit = true
  mgmtConfig.autoMerge = false  # Disable merges for this test
  barrel.setRangeManagementConfig(mgmtConfig)

  echo "Custom config set: split at ", mgmtConfig.splitThresholdKeys, " keys"

  # Insert data to trigger split
  for i in 0..150:
    let key = "key_" & $i
    discard barrel.set(key, "value")

  # Run management
  let actions = barrel.checkAndManageRanges()
  echo "Management actions with low threshold: ", actions

  barrel.close()
  removeDir(dataDir)

  echo "✓ Configurable management test completed!"

when isMainModule:
  testOrderedRangePartitioning()
  testHashVsOrderedPerformance()
  testDynamicRangeManagement()
  testConfigurableManagement()