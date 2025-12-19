## Network Benchmark for BitBarrel
##
## Measures network performance for BitBarrel operations

import std/[os, strformat, times, monotimes, random, threadpool, sequtils, math]
import src/network/[client, protocol]
import src/network/server

type
  BenchmarkResult = object
    operations*: int
    durationMs*: float
    opsPerSec*: float
    avgLatencyMs*: float
    p95LatencyMs*: float
    p99LatencyMs*: float
    errors*: int

proc runQuick(client: var BitBarrelClient): BenchmarkResult =
  ## Quick benchmark with 1000 operations
  const numOps = 1000
  var latencies: seq[float] = @[]

  echo "Running quick network benchmark (1000 operations)..."

  let startTime = getMonotime()
  var errors = 0

  try:
    # Create and use barrel
    if not client.useBarrel("benchdb_quick"):
      client.createBarrel("benchdb_quick")
      discard client.useBarrel("benchdb_quick")

    # Mixed operations: 40% SET, 40% GET, 15% DELETE, 5% PING
    for i in 0..<numOps:
      let opStart = getMonotime()

      let randOp = rand(99)
      try:
        if randOp < 40:  # SET
          let key = fmt"key_{i}"
          let value = fmt"value_{i}"
          discard client.set(key, value)
        elif randOp < 80:  # GET
          let key = fmt"key_{rand(i)}"
          discard client.get(key)
        elif randOp < 95:  # DELETE
          let key = fmt"key_{rand(i)}"
          discard client.delete(key)
        else:  # PING
          discard client.ping()

        let latency = (getMonotime() - opStart).inMilliseconds.float
        latencies.add(latency)
      except:
        errors += 1

      if i mod 100 == 0:
        stdout.write fmt"\rProgress: {i}/{numOps} ops"
        stdout.flushFile()

    echo "\rProgress: Complete                 "

  except Exception as e:
    echo "Error during benchmark: ", e.msg
    errors = numOps

  let endTime = getMonotime()
  let durationMs = (endTime - startTime).inMilliseconds.float

  result = BenchmarkResult(
    operations: numOps - errors,
    durationMs: durationMs,
    opsPerSec: (numOps - errors) / (durationMs / 1000.0),
    avgLatencyMs: if latencies.len > 0: latencies.sum() / latencies.len.float else: 0,
    p95LatencyMs: if latencies.len > 0: latencies.sorted[int(latencies.len * 0.95)] else: 0,
    p99LatencyMs: if latencies.len > 0: latencies.sorted[int(latencies.len * 0.99)] else: 0,
    errors: errors
  )

proc runComprehensive(client: var BitBarrelClient): BenchmarkResult =
  ## Comprehensive benchmark with 100,000 operations and concurrent clients
  const numOps = 100_000
  const numClients = 10
  const opsPerClient = numOps div numClients

  echo fmt"Running comprehensive benchmark ({numOps} operations, {numClients} clients)..."

  let startTime = getMonotime()
  var totalLatencies: seq[float] = @[]
  var totalErrors = 0

  # Function for each client thread
  proc clientWorker(clientId: int): (int, seq[float]) =
    var client = newClient("localhost", 9876.Port)
    var latencies: seq[float] = @[]
    var errors = 0

    try:
      client.connect()

      # Each client uses its own barrel to avoid conflicts
      let barrelName = fmt"benchdb_conc_{clientId}"
      if not client.useBarrel(barrelName):
        discard client.createBarrel(barrelName)
        discard client.useBarrel(barrelName)

      # Run operations
      for i in 0..<opsPerClient:
        let opStart = getMonotime()

        let randOp = rand(99)
        try:
          if randOp < 40:  # SET
            let key = fmt"client_{clientId}_key_{i}"
            let value = fmt"client_{clientId}_value_{i}"
            discard client.set(key, value)
          elif randOp < 80:  # GET
            let key = fmt"client_{clientId}_key_{rand(i)}"
            discard client.get(key)
          elif randOp < 95:  # DELETE
            let key = fmt"client_{clientId}_key_{rand(i)}"
            discard client.delete(key)
          else:  # PING
            discard client.ping()

          let latency = (getMonotime() - opStart).inMilliseconds.float
          latencies.add(latency)
        except:
          errors += 1

        if i mod 1000 == 0:
          stdout.write fmt"\rClient {clientId}: {i}/{opsPerClient} ops"
          stdout.flushFile()

      echo fmt"\rClient {clientId}: Complete                 "
      client.close()

    except Exception as e:
      echo fmt"Client {clientId} error: ", e.msg
      errors = opsPerClient

    result = (errors, latencies)

  # Spawn client threads
  var futures: seq[FlowVar[(int, seq[float])]] = @[]
  for i in 0..<numClients:
    futures.add(spawn clientWorker(i))


  # Collect results
  for i in 0..<numClients:
    let (errors, latencies) = ^futures[i]
    totalErrors += errors
    totalLatencies.add(latencies)

  let endTime = getMonotime()
  let durationMs = (endTime - startTime).inMilliseconds.float

  result = BenchmarkResult(
    operations: numOps - totalErrors,
    durationMs: durationMs,
    opsPerSec: (numOps - totalErrors) / (durationMs / 1000.0),
    avgLatencyMs: if totalLatencies.len > 0: totalLatencies.sum() / totalLatencies.len.float else: 0,
    p95LatencyMs: if totalLatencies.len > 0: totalLatencies.sorted[int(totalLatencies.len * 0.95)] else: 0,
    p99LatencyMs: if totalLatencies.len > 0: totalLatencies.sorted[int(totalLatencies.len * 0.99)] else: 0,
    errors: totalErrors
  )

proc printResults(result: BenchmarkResult, testType: string) =
  ## Print benchmark results
  echo ""
  echo fmt"=== {testType} Network Benchmark Results ==="
  echo fmt"Operations completed: {result.operations:,}"
  echo fmt"Total duration: {result.durationMs:.2f} ms"
  echo fmt"Throughput: {result.opsPerSec:,.0f} ops/sec"
  echo fmt"Avg latency: {result.avgLatencyMs:.3f} ms"
  echo fmt"95th percentile: {result.p95LatencyMs:.3f} ms"
  echo fmt"99th percentile: {result.p99LatencyMs:.3f} ms"
  echo fmt"Errors: {result.errors}"

  # Performance assessment
  echo ""
  if result.opsPerSec >= 30000:
    echo "✓ Performance target met (>=30K ops/sec)"
  elif result.opsPerSec >= 20000:
    echo "⚠ Good performance (20-30K ops/sec)"
  else:
    echo "✗ Below target (<20K ops/sec)"

  if result.avgLatencyMs <= 2.0:
    echo "✓ Latency target met (<=2ms avg)"
  elif result.avgLatencyMs <= 5.0:
    echo "⚠ Reasonable latency (2-5ms avg)"
  else:
    echo "✗ High latency (>5ms avg)"

  if result.errors == 0:
    echo "✓ No errors"
  else:
    echo fmt"✗ {result.errors} errors occurred"

proc main() =
  randomize()

  let args = commandLineParams()
  let testType = if args.len > 0: args[0] else: "quick"

  echo "BitBarrel Network Benchmark"
  echo "==========================="
  echo ""

  var client = newClient("localhost", 9876.Port)

  try:
    client.connect()
    echo "✓ Connected to BitBarrel server"

    # Check if server is responding
    if client.ping():
      echo "✓ Server is responding"
    else:
      echo "✗ Server ping failed"
      quit(1)

    # Run benchmarks
    if testType == "comprehensive":
      let result = client.runComprehensive()
      result.printResults("Comprehensive")
    else:
      let result = client.runQuick()
      result.printResults("Quick")

    client.close()

  except Exception as e:
    echo "Error: ", e.msg
    echo ""
    echo "Make sure BitBarrel server is running:"
    echo "  nimble server"
    quit(1)

when isMainModule:
  main()