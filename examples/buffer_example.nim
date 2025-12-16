## Simple Buffer Performance Test
##
## Demonstrates write and read buffer benefits

import os, times, strformat
import ../src/bitbarrel

const NUM_OPS = 10000

proc testDirectWrites(): float64 =
  let db = openBarrel("bench_direct")
  let start = cpuTime()
  for i in 0..<NUM_OPS:
    discard db.set(&"key{i}", &"value{i}")
  db.close()
  result = cpuTime() - start
  removeDir("bench_direct", true)

proc testBufferedWrites(): float64 =
  var cfg = defaultConfig()
  cfg.syncMode = UserSyncMode.Sync  # Buffer sync
  cfg.writeBufferSize = 64 * 1024  # 64KB buffer

  let db = openBarrel("bench_buffered", cfg)
  let start = cpuTime()
  for i in 0..<NUM_OPS:
    discard db.set(&"key{i}", &"value{i}")
  db.close()
  result = cpuTime() - start
  removeDir("bench_buffered", true)

proc testPerformance() =
  echo "\n=== Buffer Performance Test ==="
  echo &"Testing with {NUM_OPS} operations\n"

  let directTime = testDirectWrites()
  echo &"Direct writes:        {directTime:.3f}s ({int(NUM_OPS / directTime)} ops/sec)"

  let bufferedTime = testBufferedWrites()
  echo &"Buffered writes:      {bufferedTime:.3f}s ({int(NUM_OPS / bufferedTime)} ops/sec)"

  if bufferedTime < directTime:
    echo &"Speedup: {directTime / bufferedTime:.2f}x faster"
  else:
    echo &"Slowdown: {bufferedTime / directTime:.2f}x slower"

when isMainModule:
  testPerformance()