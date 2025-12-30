import std/[unittest, os, strformat, strutils]
import ../../src/bitbarrel/barrel

const TEST_DIR = "test_compression_rebuild"

suite "Compression Rebuild Tests":
  setup:
    if dirExists(TEST_DIR):
      removeDir(TEST_DIR)
    createDir(TEST_DIR)

  teardown:
    if dirExists(TEST_DIR):
      removeDir(TEST_DIR)

  test "Regular barrel rebuilds correctly with compression":
    let path = TEST_DIR / "test.data"

    # Create barrel with compression (default)
    block write_data:
      var barrel = openBarrel(path)

      # Write 1000 records with compressible data (>256 bytes to trigger compression)
      for i in 0..<1000:
        let value = ("x".repeat(300) & fmt"_{i:04d}")  # Compressible + unique suffix
        discard barrel.set(fmt"key_{i:04d}", value)

      let count = barrel.count()
      echo fmt"Wrote {count} records"
      check count == 1000

      barrel.close()

    # Reopen and verify all records are recovered
    block read_data:
      var barrel = openBarrel(path)

      let recoveredCount = barrel.count()
      echo fmt"Recovered {recoveredCount} records"
      check recoveredCount == 1000

      # Verify all data is correct
      for i in 0..<1000:
        let key = fmt"key_{i:04d}"
        let expectedValue = ("x".repeat(300) & fmt"_{i:04d}")
        let actualValue = barrel.get(key)
        if actualValue != expectedValue:
          echo fmt"Mismatch at {key}: expected length {expectedValue.len}, got {actualValue.len}"
        check actualValue == expectedValue

      barrel.close()
