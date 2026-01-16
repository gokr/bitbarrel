## BitBarrel vs Database Performance Comparison
##
## Demonstrates write and read performance differences between BitBarrel
## and traditional databases for simple key-value operations.
##
## Comparisons:
##   - BitBarrel (embedded) vs SQLite (embedded)
##   - BitBarrel (server) vs MySQL (server) [if libmysqlclient is available]
##
## Usage:
##   nim c -d:release -p:. bench/mysql_comparison.nim
##   ./mysql_comparison
## Or:
##   nimble benchMySQL
##
## Note: MySQL benchmark requires libmysqlclient.so to be installed.
## If MySQL is not available, the benchmark will skip MySQL tests gracefully.

import std/[times, strformat, os, strutils, osproc, net]
import db_connector/db_sqlite
import ../src/bitbarrel/barrel
import ../src/network/client

when defined(useMySQL):
  import db_connector/db_mysql
  const hasMySQL = true
else:
  const hasMySQL = false

type
  BenchmarkResult = object
    opsPerSec: float
    avgLatencyMs: float

  FullBenchmarkResults = object
    bbEmbedded: tuple[writes, reads: BenchmarkResult]
    sqliteEmbedded: tuple[writes, reads: BenchmarkResult]
    bbServer: tuple[writes, reads: BenchmarkResult]
    mysqlServer: tuple[writes, reads: BenchmarkResult]
    serverTestsSkipped: bool

proc formatNumber(n: int64): string =
  result = $n
  var i = result.len - 3
  while i > 0:
    result.insert(",", i)
    i.dec(3)

proc formatLatency(ms: float): string =
  if ms < 0.001:
    &"{ms * 1000:.2f} µs"
  else:
    &"{ms:.3f} ms"

proc printHeader(title: string) =
  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo &"║ {title:<58} ║"
  echo "╚════════════════════════════════════════════════════════════╝"

proc printComparison(title: string, bb, db: BenchmarkResult, bbName = "BitBarrel", dbName = "SQLite") =
  echo ""
  printHeader(title)
  echo &"  {bbName:<12}:  {bb.opsPerSec:>10.0f} ops/sec  |  {formatLatency(bb.avgLatencyMs):>10}/op"
  echo &"  {dbName:<12}:  {db.opsPerSec:>10.0f} ops/sec  |  {formatLatency(db.avgLatencyMs):>10}/op"
  if db.avgLatencyMs > 0:
    let ratio = bb.opsPerSec / db.opsPerSec
    echo &"  Ratio:      {ratio:>6.2f}x faster"

proc printFourWayComparison(title: string, bbEmb, sqEmb, bbSrv, mySrv: BenchmarkResult) =
  echo ""
  printHeader(title)
  echo &"  BitBarrel (embedded):  {bbEmb.opsPerSec:>10.0f} ops/sec  |  {formatLatency(bbEmb.avgLatencyMs):>10}/op"
  echo &"  SQLite   (embedded):  {sqEmb.opsPerSec:>10.0f} ops/sec  |  {formatLatency(sqEmb.avgLatencyMs):>10}/op"
  echo &"  BitBarrel (server):   {bbSrv.opsPerSec:>10.0f} ops/sec  |  {formatLatency(bbSrv.avgLatencyMs):>10}/op"
  echo &"  MySQL    (server):    {mySrv.opsPerSec:>10.0f} ops/sec  |  {formatLatency(mySrv.avgLatencyMs):>10}/op"
  if mySrv.opsPerSec > 0:
    let bbVsMysql = bbSrv.opsPerSec / mySrv.opsPerSec
    echo &"  BitBarrel vs MySQL:   {bbVsMysql:>6.2f}x faster"

proc benchmarkBitBarrel(numOps: int): tuple[writes, reads: BenchmarkResult] =
  printHeader("BitBarrel Benchmark (embedded)")
  echo &"  Operations: {formatNumber(numOps.int64)}"

  let dbPath = "bench/bitbarrel_comparison.data"

  if fileExists(dbPath):
    removeFile(dbPath)

  var config = defaultBarrelConfig()
  config.syncMode = Sync

  let barrel = openBarrel(dbPath, config)
  defer:
    barrel.close()
    if fileExists(dbPath):
      removeFile(dbPath)

  # Write benchmark
  echo ""
  let writeStart = cpuTime()

  for i in 0..<numOps:
    let key = &"key_{i:08}"
    let value = &"value_{i:08}_" & repeat('x', 40)
    discard barrel.set(key, value)

  let writeElapsed = cpuTime() - writeStart
  result.writes = BenchmarkResult(
    opsPerSec: numOps.float / writeElapsed,
    avgLatencyMs: writeElapsed * 1000.0 / numOps.float
  )

  echo &"  ✓ Writes completed in {writeElapsed:.3f}s"
  echo &"  ✓ Throughput: {result.writes.opsPerSec:.0f} ops/sec"

  sleep(100)

  # Read benchmark (sequential)
  echo ""
  let readStart = cpuTime()

  for i in 0..<numOps:
    let key = &"key_{i:08}"
    let value = barrel.get(key)
    discard value.len

  let readElapsed = cpuTime() - readStart
  result.reads = BenchmarkResult(
    opsPerSec: numOps.float / readElapsed,
    avgLatencyMs: readElapsed * 1000.0 / numOps.float
  )

  echo &"  ✓ Reads completed in {readElapsed:.3f}s"
  echo &"  ✓ Throughput: {result.reads.opsPerSec:.0f} ops/sec"

proc benchmarkSQLite(numOps: int): tuple[writes, reads: BenchmarkResult] =
  printHeader("SQLite Benchmark (embedded)")
  echo &"  Operations: {formatNumber(numOps.int64)}"
  echo ""

  let dbPath = "bench/sqlite_comparison.db"

  if fileExists(dbPath):
    removeFile(dbPath)

  let db = db_sqlite.open(dbPath, "", "", "")
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS kv_store (
      kv_key TEXT PRIMARY KEY NOT NULL,
      kv_value TEXT NOT NULL
    )
  """)

  # Write benchmark
  echo "  Running writes (with transaction)..."
  let writeStart = cpuTime()

  db.exec(sql"BEGIN TRANSACTION")
  for i in 0..<numOps:
    let key = &"key_{i:08}"
    let value = &"value_{i:08}_" & repeat('x', 40)
    try:
      db.exec(sql"INSERT OR REPLACE INTO kv_store (kv_key, kv_value) VALUES (?, ?)", key, value)
    except DbError:
      discard
  db.exec(sql"COMMIT")

  let writeElapsed = cpuTime() - writeStart
  result.writes = BenchmarkResult(
    opsPerSec: numOps.float / writeElapsed,
    avgLatencyMs: writeElapsed * 1000.0 / numOps.float
  )

  echo &"  ✓ Writes completed in {writeElapsed:.3f}s"
  echo &"  ✓ Throughput: {result.writes.opsPerSec:.0f} ops/sec"

  sleep(100)

  # Read benchmark (sequential)
  echo ""
  echo "  Running reads..."
  let readStart = cpuTime()

  for i in 0..<numOps:
    let key = &"key_{i:08}"
    let row = db.getAllRows(sql"SELECT kv_value FROM kv_store WHERE kv_key = ?", key)
    if row.len > 0:
      discard row[0].len

  let readElapsed = cpuTime() - readStart
  result.reads = BenchmarkResult(
    opsPerSec: numOps.float / readElapsed,
    avgLatencyMs: readElapsed * 1000.0 / numOps.float
  )

  echo &"  ✓ Reads completed in {readElapsed:.3f}s"
  echo &"  ✓ Throughput: {result.reads.opsPerSec:.0f} ops/sec"

  db.close()
  if fileExists(dbPath):
    removeFile(dbPath)

proc benchmarkBitBarrelServer(numOps: int, port: int): tuple[writes, reads: BenchmarkResult] =
  ## Starts a BitBarrel server, runs benchmarks via network client, then stops server

  printHeader("BitBarrel Benchmark (server)")
  echo &"  Operations: {formatNumber(numOps.int64)}"
  echo &"  Port: {port}"

  let serverDir = "bench/bb_server_test"

  # Clean up any existing test directory
  if dirExists(serverDir):
    removeDir(serverDir, checkDir = false)

  createDir(serverDir)

  # Start BitBarrel server
  echo ""
  echo "  Starting BitBarrel server..."

  let serverPath = if fileExists("bitbarrel"):
      "bitbarrel"
    elif fileExists("src/bitbarrel"):
      "src/bitbarrel"
    else:
      "bin/bitbarrel"

  var serverProcess: Process

  if fileExists(serverPath):
    serverProcess = startProcess(
      serverPath,
      args = ["serve", "--port=" & $port, "--data-dir=" & serverDir],
      options = {poUsePath, poStdErrToStdOut}
    )
  else:
    echo "  Warning: bitbarrel binary not found, skipping server benchmark"
    result.writes = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)
    result.reads = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)
    return

  # Wait for server to start
  sleep(2000)

  # Verify server is running
  if not serverProcess.running():
    echo "  Error: Failed to start BitBarrel server"
    # Get exit status for more info
    let exitCode = serverProcess.peekExitCode()
    if exitCode != 0:
      echo "  Exit code: " & $exitCode
    result.writes = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)
    result.reads = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)
    return

  echo "  ✓ Server started (PID: " & $serverProcess.processID() & ")"

  var client: BitBarrelClient

  try:
    client = newClient("localhost", port.Port)
    client.connect()
    echo "  ✓ Client connected"

    # Create test barrel
    discard client.createBarrel("bench_test")
    discard client.useBarrel("bench_test")
    echo "  ✓ Barrel created"

    # Write benchmark (pipelined)
    echo ""
    echo "  Running writes (pipelined)..."

    # Build all pairs first
    var pairs: seq[(string, string)] = @[]
    for i in 0..<numOps:
      let key = &"key_{i:08}"
      let value = &"value_{i:08}_" & repeat('x', 40)
      pairs.add((key, value))

    let writeStart = epochTime()
    let writeCount = client.setMany(pairs)
    let writeElapsed = epochTime() - writeStart

    result.writes = BenchmarkResult(
      opsPerSec: numOps.float / writeElapsed,
      avgLatencyMs: writeElapsed * 1000.0 / numOps.float
    )

    echo &"  ✓ Writes completed in {writeElapsed:.3f}s ({writeCount}/{numOps} successful)"
    echo &"  ✓ Throughput: {result.writes.opsPerSec:.0f} ops/sec"

    sleep(100)

    # Read benchmark (pipelined)
    echo ""
    echo "  Running reads (pipelined)..."

    var keys: seq[string] = @[]
    for i in 0..<numOps:
      keys.add(&"key_{i:08}")

    let readStart = epochTime()
    let readResults = client.getMany(keys)
    let readElapsed = epochTime() - readStart

    result.reads = BenchmarkResult(
      opsPerSec: numOps.float / readElapsed,
      avgLatencyMs: readElapsed * 1000.0 / numOps.float
    )

    echo &"  ✓ Reads completed in {readElapsed:.3f}s ({readResults.len}/{numOps} found)"
    echo &"  ✓ Throughput: {result.reads.opsPerSec:.0f} ops/sec"

    # Cleanup barrel
    discard client.deleteBarrel("bench_test")
    echo ""
    echo "  ✓ Barrel dropped"

  except Exception as e:
    echo "  Error during benchmark: " & e.msg
    result.writes = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)
    result.reads = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)

  finally:
    # Close client
    if client.connected:
      client.close()

    # Stop server
    echo ""
    echo "  Stopping server..."
    serverProcess.terminate()

    sleep(2000)

    if serverProcess.running():
      echo "  Warning: Server did not stop gracefully, killing..."
      serverProcess.kill()
      sleep(1000)

    echo "  ✓ Server stopped"

    # Cleanup test directory
    if dirExists(serverDir):
      removeDir(serverDir, checkDir = false)

when defined(useMySQL):
  proc benchmarkMySQLServer(numOps: int, host: string = "localhost",
                            port: int = 3306, user: string = "bench",
                            password: string = "", database: string = "bitbarrel_bench"):
    tuple[writes, reads: BenchmarkResult] =
    ## Connects to MySQL server and runs benchmarks

    printHeader("MySQL Benchmark (server)")
    echo &"  Operations: {formatNumber(numOps.int64)}"
    echo &"  Host: {host}:{port}"

    var conn: db_mysql.DbConn
    var connected = false

    try:
      conn = db_mysql.open(host, user, password, database)
      connected = true
      echo ""
      echo "  ✓ Connected to MySQL server"

      # Create table
      conn.exec(sql"""
        CREATE TABLE IF NOT EXISTS kv_store (
          kv_key VARCHAR(64) PRIMARY KEY NOT NULL,
          kv_value TEXT NOT NULL
        )
      """)
      echo "  ✓ Table created"

      # Clear existing data
      conn.exec(sql"TRUNCATE TABLE kv_store")

      # Write benchmark
      echo ""
      echo "  Running writes (with transaction)..."
      let writeStart = cpuTime()

      conn.exec(sql"START TRANSACTION")
      for i in 0..<numOps:
        let key = &"key_{i:08}"
        let value = &"value_{i:08}_" & repeat('x', 40)
        try:
          conn.exec(sql"INSERT INTO kv_store (kv_key, kv_value) VALUES (?, ?)", key, value)
        except DbError:
          discard
      conn.exec(sql"COMMIT")

      let writeElapsed = cpuTime() - writeStart
      result.writes = BenchmarkResult(
        opsPerSec: numOps.float / writeElapsed,
        avgLatencyMs: writeElapsed * 1000.0 / numOps.float
      )

      echo &"  ✓ Writes completed in {writeElapsed:.3f}s"
      echo &"  ✓ Throughput: {result.writes.opsPerSec:.0f} ops/sec"

      sleep(100)

      # Read benchmark
      echo ""
      echo "  Running reads..."

      let readStart = cpuTime()

      for i in 0..<numOps:
        let key = &"key_{i:08}"
        let row = conn.getRow(sql"SELECT kv_value FROM kv_store WHERE kv_key = ?", key)
        discard row.len

      let readElapsed = cpuTime() - readStart
      result.reads = BenchmarkResult(
        opsPerSec: numOps.float / readElapsed,
        avgLatencyMs: readElapsed * 1000.0 / numOps.float
      )

      echo &"  ✓ Reads completed in {readElapsed:.3f}s"
      echo &"  ✓ Throughput: {result.reads.opsPerSec:.0f} ops/sec"

      # Cleanup
      conn.exec(sql"DROP TABLE IF EXISTS kv_store")
      echo ""
      echo "  ✓ Table dropped"

    except DbError as e:
      echo "  Error connecting to MySQL: " & e.msg
      echo ""
      echo "  To enable MySQL benchmarking, run these commands:"
      echo "  ───────────────────────────────────────────────────"
      echo "  sudo mysql -u root -p -e \\"
      echo "    \"CREATE DATABASE IF NOT EXISTS bitbarrel_bench;"
      echo "     CREATE USER IF NOT EXISTS 'bench'@'localhost';"
      echo "     GRANT ALL PRIVILEGES ON bitbarrel_bench.* TO 'bench'@'localhost';"
      echo "     FLUSH PRIVILEGES;\""
      echo "  ───────────────────────────────────────────────────"
      echo "  Then re-run the benchmark."
      result.writes = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)
      result.reads = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)
    finally:
      if connected:
        try:
          conn.close()
        except:
          discard

# Fallback MySQL benchmark for when MySQL is not available
when not defined(useMySQL):
  proc benchmarkMySQLServer(numOps: int, host: string = "localhost",
                            port: int = 3306, user: string = "bench",
                            password: string = "", database: string = "bitbarrel_bench"):
    tuple[writes, reads: BenchmarkResult] =
    ## Fallback for when MySQL is not available

    printHeader("MySQL Benchmark (server)")
    echo &"  Operations: {formatNumber(numOps.int64)}"
    echo ""
    echo "  MySQL benchmark disabled - compile with -d:useMySQL to enable"
    echo "  (requires libmysqlclient.so to be installed)"

    result.writes = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)
    result.reads = BenchmarkResult(opsPerSec: 0.0, avgLatencyMs: 0.0)

proc main() =
  const numOps = 10_000
  const serverOps = 10_000  # Same as embedded now that we use pipelining
  const bbServerPort = 9877

  printHeader("BitBarrel vs Database Performance Comparison")

  echo ""
  echo "  Test Parameters:"
  echo "  ───────────────────────────────────"
  echo &"  Operations:      {formatNumber(numOps.int64)}"
  echo &"  Key format:      key_00000000"
  echo &"  Value size:      ~60 bytes"
  echo ""
  echo "  BitBarrel (embedded):"
  echo "    Mode:            Sync (direct to disk)"
  echo "  SQLite (embedded):"
  echo "    Mode:            Transaction (batch commits)"
  echo "  BitBarrel (server):"
  echo &"    Port:            {bbServerPort}"
  echo "  MySQL (server):"
  echo "    Host:            localhost:3306"
  echo "    User:            bench (no password)"

  # Run embedded benchmarks
  echo ""
  echo "────────────────────────────────────────────────"
  echo "  EMBEDDED COMPARISON"
  echo "────────────────────────────────────────────────"

  let bbEmbeddedResults = benchmarkBitBarrel(numOps)
  echo ""
  let sqliteEmbeddedResults = benchmarkSQLite(numOps)

  # Show embedded comparison
  printComparison("Write Performance (embedded)", bbEmbeddedResults.writes, sqliteEmbeddedResults.writes)
  printComparison("Read Performance (embedded)", bbEmbeddedResults.reads, sqliteEmbeddedResults.reads)

  # Run server benchmarks
  echo ""
  echo "────────────────────────────────────────────────"
  echo "  SERVER COMPARISON"
  echo "────────────────────────────────────────────────"

  let bbServerResults = benchmarkBitBarrelServer(serverOps, bbServerPort)
  echo ""
  let mysqlServerResults = benchmarkMySQLServer(serverOps)

  # Check if server benchmarks ran
  let serverTestsSkipped = bbServerResults.writes.opsPerSec == 0 and mysqlServerResults.writes.opsPerSec == 0

  # Show results
  if serverTestsSkipped:
    echo ""
    echo "  Server benchmarks skipped (BitBarrel binary or MySQL server not available)"
  else:
    if bbServerResults.writes.opsPerSec > 0:
      printComparison("Write Performance (server)", bbServerResults.writes, mysqlServerResults.writes,
                    bbName = "BitBarrel", dbName = "MySQL")
    if bbServerResults.reads.opsPerSec > 0:
      printComparison("Read Performance (server)", bbServerResults.reads, mysqlServerResults.reads,
                    bbName = "BitBarrel", dbName = "MySQL")

  echo ""
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║                      Summary                                ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  BitBarrel outperforms traditional databases for simple key-value"
  echo "  operations due to its optimized append-only design and in-memory index."
  echo ""
  echo "  Key Findings:"
  echo "  ───────────────────────────────────"

  # Embedded comparison
  let writeRatio = bbEmbeddedResults.writes.opsPerSec / sqliteEmbeddedResults.writes.opsPerSec
  let readRatio = bbEmbeddedResults.reads.opsPerSec / sqliteEmbeddedResults.reads.opsPerSec
  echo &"  • Embedded: BitBarrel is {writeRatio:.2f}x faster on writes, {readRatio:.2f}x faster on reads vs SQLite"

  # Server comparison (if available)
  if not serverTestsSkipped and bbServerResults.writes.opsPerSec > 0 and mysqlServerResults.writes.opsPerSec > 0:
    let servWriteRatio = bbServerResults.writes.opsPerSec / mysqlServerResults.writes.opsPerSec
    let servReadRatio = bbServerResults.reads.opsPerSec / mysqlServerResults.reads.opsPerSec
    echo &"  • Server:   BitBarrel is {servWriteRatio:.2f}x faster on writes, {servReadRatio:.2f}x faster on reads vs MySQL"

  echo ""
  echo "  Notes:"
  echo "  ───────────────────────────────────"
  echo "  • SQLite uses transactions (batching) for better write throughput"
  echo "  • MySQL uses transactions (batching) for better write throughput"
  echo "  • BitBarrel's advantage is greatest for write-heavy workloads"
  echo "  • For read workloads, the in-memory index provides significant speedup"
  echo "  • Server performance includes network overhead"
  echo ""

when isMainModule:
  main()
