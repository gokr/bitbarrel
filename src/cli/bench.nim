## Embedded Benchmark for BitBarrel CLI
##
## Simple throughput test: 10K writes + 10K reads
## Usage: call runEmbeddedBench() which returns true on success

import std/[os, times, strformat]
import ../bitbarrel

const
  WRITE_OPS = 100_000
  READ_OPS = 100_000

proc runEmbeddedBench*(): bool =
  ## Run embedded benchmark: 100K writes + 100K reads
  ## Returns true on success, false on failure

  let dbFile = "bitbarrel_bench_test.dat"

  echo ""
  echo "============================================================"
  echo "                BitBarrel Embedded Benchmark"
  echo "============================================================"
  echo ""

  # Clean up any existing test data
  if fileExists(dbFile):
    removeFile(dbFile)

  echo &"Opening database: {dbFile}"
  let bb = openDatabase(dbFile)
  if bb == nil:
    echo "Error: Failed to open database"
    return false

  # Write benchmark
  echo ""
  echo "Running write benchmark..."
  echo &"  Operations: {WRITE_OPS}"

  let writeStart = cpuTime()
  for i in 0..<WRITE_OPS:
    let key = &"bench_key_{i:06d}"
    let value = &"bench_value_{i:06d}"
    discard bb.set(key, value)
  let writeTime = cpuTime() - writeStart

  let writeOpsPerSec = WRITE_OPS.float / writeTime
  echo &"  Time: {writeTime:.3f} seconds"
  echo &"  Throughput: {int(writeOpsPerSec)} ops/sec"
  echo ""

  # Read benchmark
  echo "Running read benchmark..."
  echo &"  Operations: {READ_OPS}"

  let readStart = cpuTime()
  for i in 0..<READ_OPS:
    let key = &"bench_key_{i:06d}"
    let value = bb.get(key)
    if value.len == 0:
      echo &"  Error: Failed to read key {key}"
      bb.close()
      removeFile(dbFile)
      return false
    discard value.len  # Ensure read
  let readTime = cpuTime() - readStart

  let readOpsPerSec = READ_OPS.float / readTime
  echo &"  Time: {readTime:.3f} seconds"
  echo &"  Throughput: {int(readOpsPerSec)} ops/sec"
  echo ""

  bb.close()
  removeFile(dbFile)

  echo "============================================================"
  echo &"  Write: {int(writeOpsPerSec)} ops/sec"
  echo &"  Read:  {int(readOpsPerSec)} ops/sec"
  echo "============================================================"
  echo ""
  echo "Benchmark completed successfully!"

  return true