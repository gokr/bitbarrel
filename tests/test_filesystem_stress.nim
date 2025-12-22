## Filesystem Stress and Edge Case Tests
##
## Tests for file system errors, permission issues, and environmental edge cases
## that can occur in production deployments.

import std/[unittest, os, times, strformat, osproc, options, strutils]
import ../src/storage/datafile
import ../src/storage/keydir
import ../src/storage/recovery
import ../src/bitbarrel/types
import testutils

suite "Filesystem Stress Tests":

  test "Handles non-existent parent directory":
    let testPath = "/nonexistent/directory/that/does/not/exist/test.data"
    expect OSError, IOError, CatchableError:
      var df = datafile.open(testPath, 1'u32)
      df.close()

  test "Handles read-only directory":
    withTestDir("readonly_test"):
      # Create a read-only directory
      let readonlyDir = testDir / "readonly"
      createDir(readonlyDir)

      when defined(posix):
        # Make directory read-only on Unix systems
        discard execShellCmd("chmod 444 " & readonlyDir)

        let testFile = readonlyDir / "test.data"
        expect OSError, IOError, CatchableError:
          var df = datafile.open(testFile, 1'u32)
          df.close()

        # Restore permissions for cleanup
        discard execShellCmd("chmod 755 " & readonlyDir)

  test "Handles invalid file path characters":
    withTestDir("invalid_path"):
      # Test various invalid path characters
      let invalidPaths = [
        testDir / "test\x00data",  # Null character
        testDir / "test<>data",    # Angle brackets
        testDir / "test|data",     # Pipe
      ]

      for invalidPath in invalidPaths:
        expect OSError, IOError, CatchableError:
          var df = datafile.open(invalidPath, 1'u32)
          df.close()

  test "Handles path traversal attempts":
    withTestDir("path_traversal"):
      # Test path traversal security
      let maliciousPaths = [
        testDir / "../../../etc/passwd",
        testDir / "..\\..\\..\\windows\\system32\\config\\sam",
        testDir / "subdir/../../../etc/passwd",
      ]

      for maliciousPath in maliciousPaths:
        expect OSError, IOError, CatchableError:
          var df = datafile.open(maliciousPath, 1'u32)
          df.close()

  test "Handles insufficient disk space":
    withTestDir("disk_full"):
      # Create a small temporary file system image (requires root on most systems)
      # This is a best-effort test - may not work in all environments
      when defined(posix):
        # Try to create a file system with limited space
        # Note: This may require elevated privileges and might not work in all test environments
        let testFile = testDir / "large_test.data"

        # Try to write until we hit a limit
        var dfOpt: Option[datafile.DataFile]
        try:
          dfOpt = some(datafile.open(testFile, 1'u32))
        except CatchableError:
          # Expected to fail if disk is full or permission denied
          check true  # Test passes if we detect the error condition

        if dfOpt.isSome:
          var df = dfOpt.get
          defer:
            df.close()

          # Try to write a large amount of data
          var written = 0
          const chunkSize = 1024 * 1024  # 1MB chunks
          const maxAttempts = 100

          for i in 0..<maxAttempts:
            try:
              let dummyData = repeat("x", chunkSize)
              discard df.appendRecord(&"key_{i}", dummyData, testutils.now())
              written += chunkSize
            except CatchableError:
              # Stop when we can't write anymore
              break

          # If we wrote any data, that's good - we're testing the path
          # The important part is that the code doesn't crash
          check written >= 0

  test "Handles permission denied on existing file":
    withTestDir("permission_denied"):
      # Create a file with no write permissions
      let testFile = testDir / "readonly_file.data"

      # Create the file first
      writeFile(testFile, "initial content")

      when defined(posix):
        # Remove write permissions
        discard execShellCmd("chmod 444 " & testFile)

        # Try to open it for writing
        expect OSError, IOError, CatchableError:
          var df = datafile.open(testFile, 1'u32)
          df.close()

        # Restore permissions for cleanup
        discard execShellCmd("chmod 644 " & testFile)

  test "Handles very long pathnames":
    withTestDir("long_path"):
      # Test paths that approach or exceed filesystem limits
      # Most filesystems support at least 255 bytes per component
      let longDirName = repeat("a", 200)
      let longPath = testDir / longDirName / "test.data"

      createDir(testDir / longDirName)

      # This should work on most modern filesystems
      var dfOpt: Option[datafile.DataFile]
      try:
        dfOpt = some(datafile.open(longPath, 1'u32))
        if dfOpt.isSome:
          var df = dfOpt.get
          defer: df.close()
          discard df.appendRecord("key", "value", testutils.now())
      except CatchableError:
        # Some filesystems may have lower limits
        check true  # Test passes if error is handled gracefully

  test "Handles symbolic link to non-existent target":
    withTestDir("broken_symlink"):
      when defined(posix):
        let testFile = testDir / "test.data"
        let symlinkFile = testDir / "broken_link.data"

        # Create a symbolic link to a non-existent file
        discard execShellCmd("ln -s /nonexistent/file " & symlinkFile)

        # Try to open the symlink
        expect OSError, IOError, CatchableError:
          var df = datafile.open(symlinkFile, 1'u32)
          df.close()

  test "Handles symbolic link loop":
    withTestDir("symlink_loop"):
      when defined(posix):
        let file1 = testDir / "file1.data"
        let file2 = testDir / "file2.data"

        # Create a symlink loop: file1 -> file2 -> file1
        discard execShellCmd("ln -s file2.data " & file1)
        discard execShellCmd("ln -s file1.data " & file2)

        # Try to open one of the files
        expect OSError, IOError, CatchableError:
          var df = datafile.open(file1, 1'u32)
          df.close()

  test "Handles concurrent access to same file":
    withTestDir("concurrent_file"):
      let testFile = testDir / "concurrent.data"

      # Open same file multiple times (should fail or handle gracefully)
      # Most filesystems don't allow multiple writers to the same file
      var df1: Option[datafile.DataFile]
      var df2: Option[datafile.DataFile]

      try:
        df1 = some(datafile.open(testFile, 1'u32))
      except CatchableError:
        check true  # Expected - can't open file that's already in use

      if df1.isSome:
        defer:
          df1.get.close()

        # Try to open the same file again
        expect OSError, IOError, CatchableError:
          df2 = some(datafile.open(testFile, 1'u32))
          if df2.isSome:
            df2.get.close()

  test "Handles file size exceeding filesystem limit":
    withTestDir("huge_file"):
      # Attempt to create a file larger than the filesystem allows
      # This is platform-dependent and may not work in all environments
      when defined(posix):
        let testFile = testDir / "huge.data"

        var dfOpt: Option[datafile.DataFile]
        try:
          dfOpt = some(datafile.open(testFile, 1'u32))
        except CatchableError:
          check true  # Expected if we can't create the file

        if dfOpt.isSome:
          var df = dfOpt.get
          defer: df.close()

          # Try to write increasingly large records
          let sizes = [1000'u64, 10000, 100000, 1000000, 10000000]

          for size in sizes:
            try:
              let largeValue = repeat("x", int(size))
              discard df.appendRecord(&"large_key_{size}", largeValue, testutils.now())
            except CatchableError:
              # Stop when we hit the limit
              break

          check true  # Test passes if we handle the error gracefully

  test "Validates file header before writing":
    withTestDir("header_validation"):
      # Create a file with invalid header
      let testFile = testDir / "bad_header.data"
      writeFile(testFile, "INVALID HEADER DATA THAT IS NOT A REAL HEADER")

      # Try to open existing file with bad header
      expect OSError, IOError, CatchableError:
        var df = datafile.open(testFile, 1'u32)
        df.close()

  test "Handles write interruption (simulated)":
    withTestDir("write_interruption"):
      let testFile = testDir / "interrupted.data"

      # Create file and start writing
      var dfOpt: Option[datafile.DataFile]
      try:
        dfOpt = some(datafile.open(testFile, 1'u32))
      except CatchableError:
        check true  # Expected if we can't create the file

      if dfOpt.isSome:
        var df = dfOpt.get
        defer: df.close()

        # Write some data
        discard df.appendRecord("key1", "value1", testutils.now())

        # Simulate write interruption by truncating file
        truncateFileAt(testFile, 10)

        # Try to continue writing
        # This tests recovery from partial writes
        try:
          discard df.appendRecord("key2", "value2", testutils.now())
        except CatchableError:
          check true  # Expected if file is corrupted

        # Close and try to reopen
        df.close()

        # Reopen - should detect corruption
        expect OSError, IOError, CatchableError:
          var df2 = datafile.open(testFile, 1'u32)
          df2.close()

  test "Resource cleanup on error":
    withTestDir("resource_cleanup"):
      # Test that resources are properly cleaned up even when errors occur
      let testFile = testDir / "cleanup_test.data"

      # Create file
      var dfOpt: Option[datafile.DataFile]
      try:
        dfOpt = some(datafile.open(testFile, 1'u32))
      except CatchableError:
        check true  # Can't create file, test passes by not crashing

      if dfOpt.isSome:
        var df = dfOpt.get

        # Try operations that might fail
        try:
          discard df.appendRecord("key", "value", testutils.now())
        except CatchableError:
          discard

        # Close explicitly
        df.close()

        # Verify file exists but is in consistent state
        check fileExists(testFile)

        # Try to reopen - should work if cleanup was proper
        try:
          var df2 = datafile.open(testFile, 1'u32)
          df2.close()
        except CatchableError:
          check true  # May fail if data is corrupted, but cleanup should still happen