##
##  BitBarrel Metrics Collector
##
##  Real-time metrics collection and Prometheus format generation
##
import std/[tables, times, strformat, locks]
import std/json

## Forward declarations for types not yet imported
type
  Barrel* = ref object  ## Will be properly imported later
  HugeBarrel* = ref object  ## Will be properly imported later

## Metric value types
type
  MetricType* = enum
    mtCounter
    mtGauge
    mtHistogram

  MetricValue* = object
    case kind: MetricType
    of mtCounter:
      counter: int64
    of mtGauge:
      gauge: float64
    of mtHistogram:
      histogram: Histogram

  Histogram* = object
    count*: int64
    sum*: float64
    buckets*: array[10, int64]  ## 10 buckets for p50, p75, p90, p95, p99

  OperationType* = enum
    opGet = "get"
    opSet = "set"
    opDelete = "delete"

  StatusType* = enum
    stSuccess = "success"
    stFailure = "failure"

## Metrics collector state
type
  MetricsCollector* = ref object
    ## Operation counters
    opsTotal*: Table[(OperationType, StatusType), int64]
    opsLock*: Lock

    ## Storage metrics
    storageFiles*: int
    storageBytes*: int64
    storageFragRatio*: float64
    keysTotalActive*: int64
    keysTotalDeleted*: int64
    storageLock*: Lock

    ## Response time histograms
    responseTimes*: Table[OperationType, Histogram]
    responseTimeLock*: Lock

    ## Server metrics
    sessionsActive*: int
    barrelsOpen*: int
    serverLock*: Lock
    startTime*: int64

    ## Optional persistence
    persistEnabled*: bool
    retentionHours*: int
    lastSnapshot*: int64
    persistLock*: Lock

## Initialize metrics collector
proc newMetricsCollector*(persistEnabled = false, retentionHours = 168): MetricsCollector =
  ## Create a new metrics collector
  new(result)

  ## Operation counters
  initLock(result.opsLock)
  result.opsTotal = initTable[(OperationType, StatusType), int64]()

  ## Storage metrics
  initLock(result.storageLock)
  result.storageFiles = 0
  result.storageBytes = 0
  result.storageFragRatio = 0.0
  result.keysTotalActive = 0
  result.keysTotalDeleted = 0

  ## Response times
  initLock(result.responseTimeLock)
  result.responseTimes = initTable[OperationType, Histogram]()
  for op in [opGet, opSet, opDelete]:
    result.responseTimes[op] = Histogram(count: 0, sum: 0.0)

  ## Server metrics
  initLock(result.serverLock)
  result.sessionsActive = 0
  result.barrelsOpen = 0
  result.startTime = int64(epochTime())

  ## Persistence
  initLock(result.persistLock)
  result.persistEnabled = persistEnabled
  result.retentionHours = retentionHours
  result.lastSnapshot = 0

## Record operation
proc recordOperation*(collector: MetricsCollector, op: OperationType,
                     status: StatusType, durationMs: float64 = 0.0) =
  ## Record an operation with optional duration
  withLock(collector.opsLock):
    let key = (op, status)
    collector.opsTotal[key] = collector.opsTotal.getOrDefault(key, 0) + 1

  ## Record response time if provided
  if durationMs > 0.0:
    withLock(collector.responseTimeLock):
      var hist = addr collector.responseTimes[op]
      hist.count += 1
      hist.sum += durationMs

      ## Update buckets for histogram (simple percentiles)
      let seconds = durationMs / 1000.0
      if seconds <= 0.001: hist.buckets[0] += 1
      elif seconds <= 0.005: hist.buckets[1] += 1
      elif seconds <= 0.01: hist.buckets[2] += 1
      elif seconds <= 0.025: hist.buckets[3] += 1
      elif seconds <= 0.05: hist.buckets[4] += 1
      elif seconds <= 0.1: hist.buckets[5] += 1
      elif seconds <= 0.25: hist.buckets[6] += 1
      elif seconds <= 0.5: hist.buckets[7] += 1
      elif seconds <= 1.0: hist.buckets[8] += 1
      else: hist.buckets[9] += 1

## Update storage metrics
proc updateStorageMetrics*(collector: MetricsCollector, files: int,
                         bytes: int64, fragRatio: float64,
                         activeKeys: int64, deletedKeys: int64) =
  ## Update storage-related metrics
  withLock(collector.storageLock):
    collector.storageFiles = files
    collector.storageBytes = bytes
    collector.storageFragRatio = fragRatio
    collector.keysTotalActive = activeKeys
    collector.keysTotalDeleted = deletedKeys

## Update server metrics
proc updateServerMetrics*(collector: MetricsCollector, sessions: int, barrels: int) =
  ## Update server-related metrics
  withLock(collector.serverLock):
    collector.sessionsActive = sessions
    collector.barrelsOpen = barrels

## Get uptime in seconds
proc getUptime*(collector: MetricsCollector): int64 =
  ## Get server uptime in seconds
  int64(epochTime()) - collector.startTime

## Generate Prometheus format output
proc generatePrometheusFormat*(collector: MetricsCollector): string =
  ## Generate Prometheus text exposition format
  result = ""

  ## Operation counters
  result.add("# HELP bitbarrel_operations_total Total number of operations\n")
  result.add("# TYPE bitbarrel_operations_total counter\n")

  withLock(collector.opsLock):
    for op in [opGet, opSet, opDelete]:
      for status in [stSuccess, stFailure]:
        let key = (op, status)
        let count = collector.opsTotal.getOrDefault(key, 0)
        result.add("bitbarrel_operations_total{operation=\"" & $op & "\",status=\"" & $status & "\"} " & $count & "\n")

  ## Storage metrics
  result.add("\n# HELP bitbarrel_storage_files_total Total number of storage files\n")
  result.add("# TYPE bitbarrel_storage_files_total gauge\n")

  result.add("# HELP bitbarrel_storage_size_bytes Total storage size in bytes\n")
  result.add("# TYPE bitbarrel_storage_size_bytes gauge\n")

  result.add("# HELP bitbarrel_storage_fragmentation_ratio Storage fragmentation ratio\n")
  result.add("# TYPE bitbarrel_storage_fragmentation_ratio gauge\n")

  result.add("# HELP bitbarrel_keys_total Total number of keys\n")
  result.add("# TYPE bitbarrel_keys_total gauge\n")

  withLock(collector.storageLock):
    result.add(&"bitbarrel_storage_files_total {collector.storageFiles}\n")
    result.add(&"bitbarrel_storage_size_bytes {collector.storageBytes}\n")
    result.add(&"bitbarrel_storage_fragmentation_ratio {collector.storageFragRatio}\n")
    result.add(&"bitbarrel_keys_total{{state=\"active\"}} {collector.keysTotalActive}\n")
    result.add(&"bitbarrel_keys_total{{state=\"deleted\"}} {collector.keysTotalDeleted}\n")

  ## Server metrics
  result.add("\n# HELP bitbarrel_server_sessions_active Number of active sessions\n")
  result.add("# TYPE bitbarrel_server_sessions_active gauge\n")

  result.add("# HELP bitbarrel_server_barrels_open Number of open barrels\n")
  result.add("# TYPE bitbarrel_server_barrels_open gauge\n")

  result.add("# HELP bitbarrel_server_uptime_seconds Server uptime in seconds\n")
  result.add("# TYPE bitbarrel_server_uptime_seconds gauge\n")

  withLock(collector.serverLock):
    result.add(&"bitbarrel_server_sessions_active {collector.sessionsActive}\n")
    result.add(&"bitbarrel_server_barrels_open {collector.barrelsOpen}\n")
    result.add(&"bitbarrel_server_uptime_seconds {collector.getUptime()}\n")

  ## Response time histograms
  result.add("\n# HELP bitbarrel_operation_duration_seconds Operation duration histogram\n")
  result.add("# TYPE bitbarrel_operation_duration_seconds histogram\n")

  withLock(collector.responseTimeLock):
    for op in [opGet, opSet, opDelete]:
      let hist = collector.responseTimes[op]

      ## Define bucket upper bounds
      const bucketBounds = [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0]

      var cumulative = 0'i64
      for i, bound in bucketBounds:
        cumulative += hist.buckets[i]
        result.add(&"bitbarrel_operation_duration_seconds_bucket{{operation=\"{op}\",le=\"{bound}\"}} {cumulative}\n")

      ## +Inf bucket
      cumulative += hist.buckets[9]
      result.add(&"bitbarrel_operation_duration_seconds_bucket{{operation=\"{op}\",le=\"+Inf\"}} {cumulative}\n")

      ## Count and sum (convert milliseconds to seconds)
      result.add(&"bitbarrel_operation_duration_seconds_count{{operation=\"{op}\"}} {hist.count}\n")
      result.add(&"bitbarrel_operation_duration_seconds_sum{{operation=\"{op}\"}} {hist.sum / 1000.0}\n")

## Check if snapshot is needed
proc isSnapshotNeeded*(collector: MetricsCollector): bool =
  ## Check if enough time has passed for a metrics snapshot
  if not collector.persistEnabled:
    return false

  let now = int64(epochTime())
  return (now - collector.lastSnapshot) >= 60  ## Every 60 seconds

## Mark snapshot as taken
proc markSnapshot*(collector: MetricsCollector) =
  ## Update last snapshot timestamp
  withLock(collector.persistLock):
    collector.lastSnapshot = int64(epochTime())

## Cleanup old metrics data
proc cleanupOldMetrics*(collector: MetricsCollector) =
  ## Remove metrics older than retention period
  if not collector.persistEnabled:
    return

  ## This will be implemented in metrics_persistence.nim
  ## when we have the BitBarrel barrel integration

## Get all current metrics as JSON
proc getMetricsJson*(collector: MetricsCollector): JsonNode =
  ## Get current metrics as JSON for API responses
  var root = newJObject()
  root["timestamp"] = %epochTime()

  var operations = newJObject()
  withLock(collector.opsLock):
    for op in [opGet, opSet, opDelete]:
      var opNode = newJObject()
      for status in [stSuccess, stFailure]:
        let key = (op, status)
        opNode[$status] = %collector.opsTotal.getOrDefault(key, 0)
      operations[$op] = %opNode
  root["operations"] = %operations

  var storage = newJObject()
  withLock(collector.storageLock):
    storage["files"] = %collector.storageFiles
    storage["bytes"] = %collector.storageBytes
    storage["fragmentation_ratio"] = %collector.storageFragRatio
    storage["keys_active"] = %collector.keysTotalActive
    storage["keys_deleted"] = %collector.keysTotalDeleted
  root["storage"] = %storage

  var server = newJObject()
  withLock(collector.serverLock):
    server["sessions_active"] = %collector.sessionsActive
    server["barrels_open"] = %collector.barrelsOpen
    server["uptime_seconds"] = %collector.getUptime()
  root["server"] = %server

  var responseTimes = newJObject()
  withLock(collector.responseTimeLock):
    for op in [opGet, opSet, opDelete]:
      let hist = collector.responseTimes[op]
      var histNode = newJObject()
      histNode["count"] = %hist.count
      histNode["sum_ms"] = %hist.sum
      var buckets = newJArray()
      for bucket in hist.buckets:
        buckets.add(%bucket)
      histNode["buckets"] = %buckets
      responseTimes[$op] = %histNode
  root["response_times"] = %responseTimes

  result = root
