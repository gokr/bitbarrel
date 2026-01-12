## Simple profiling test for HugeBarrel
## Run this with: nim c -r bench/profile_hugebarrel.nim
## Then use gprof to analyze: gprof bench/profile_hugebarrel > profile.txt

when isMainModule:
  echo "=== Running HugeBarrel with gprof profiling ==="
  echo "Note: Run gprof after completion to see detailed results\n"

  # Import only what we need to avoid compilation issues
  import std/[os, strformat, times, strutils]
  import ../src/storage/hugebarrel
  import ../src/bitbarrel/barrel

  var config = defaultBarrelConfig()
  config.mode = bmHugeCritBit
  config.hugeConfig.maxEntriesPerRange = 200000
  config.syncMode = UserSyncMode.None

  let testPath = "/tmp/profile_hugebarrel"
  if dirExists(testPath):
    removeDir(testPath)

  var hb = openHugeBarrel(testPath, config)
  if hb.barrel1.isClosed():
    echo "Failed to open"
    quit(1)

  echo "Writing 5000 keys..."
  let start = cpuTime()
  for i in 0..<5000:
    let key = fmt"key:{i:06d}"
    let value = repeat('x', 900)
    discard hb.set(key, value)

  let writeDuration = cpuTime() - start
  echo fmt"Write complete: {writeDuration:.3f}s"
  echo fmt"Write rate: {5000.0 / writeDuration:.0f} ops/sec"

  echo "\nReading 5000 keys..."
  let readStart = cpuTime()
  for i in 0..<5000:
    let key = fmt"key:{i:06d}"
    discard hb.get(key)

  let readDuration = cpuTime() - readStart
  echo fmt"Read complete: {readDuration:.3f}s"
  echo fmt"Read rate: {5000.0 / readDuration:.0f} ops/sec"

  echo fmt"\nTotal time: {cpuTime() - start:.3f}s"
  echo "Run: gprof bench/profile_hugebarrel > profile.txt"
  echo "Then view profile.txt to see detailed profiling info"

  hb.close()
  if dirExists(testPath):
    removeDir(testPath)