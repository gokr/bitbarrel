## Test metrics endpoint functionality
import std/[unittest, strutils]
import ../../src/network/metrics

suite "Metrics Collector Tests":
  test "metrics collector initializes":
    ## Test that metrics collector can be created
    let collector = newMetricsCollector(persistEnabled = false)
    check collector != nil

  test "record operations":
    ## Test operation tracking
    let collector = newMetricsCollector(persistEnabled = false)

    # Record some operations
    collector.recordOperation(opGet, stSuccess, 5.0)
    collector.recordOperation(opGet, stSuccess, 10.0)
    collector.recordOperation(opSet, stSuccess, 15.0)
    collector.recordOperation(opGet, stFailure, 2.0)

    # Generate metrics
    let output = collector.generatePrometheusFormat()

    # Verify operations are tracked
    check output.contains("bitbarrel_operations_total{operation=\"get\",status=\"success\"} 2")
    check output.contains("bitbarrel_operations_total{operation=\"set\",status=\"success\"} 1")
    check output.contains("bitbarrel_operations_total{operation=\"get\",status=\"failure\"} 1")

  test "generatePrometheusFormat produces valid output":
    ## Test that Prometheus format generation works
    let collector = newMetricsCollector(persistEnabled = false)

    # Update some metrics
    collector.updateStorageMetrics(5, 1024000'i64, 0.25, 1000'i64, 50'i64)
    collector.updateServerMetrics(3, 2)
    collector.recordOperation(opGet, stSuccess, 5.5)

    let output = collector.generatePrometheusFormat()

    # Verify HELP and TYPE comments
    check output.contains("# HELP bitbarrel_operations_total")
    check output.contains("# TYPE bitbarrel_operations_total counter")
    check output.contains("# HELP bitbarrel_storage_size_bytes")
    check output.contains("# TYPE bitbarrel_storage_size_bytes gauge")
    check output.contains("# HELP bitbarrel_server_uptime_seconds")
    check output.contains("# HELP bitbarrel_operation_duration_seconds")
    check output.contains("# TYPE bitbarrel_operation_duration_seconds histogram")

    # Verify metric values
    check output.contains("bitbarrel_storage_files_total 5")
    check output.contains("bitbarrel_storage_size_bytes 1024000")
    check output.contains("bitbarrel_storage_fragmentation_ratio 0.25")
    check output.contains("bitbarrel_keys_total{state=\"active\"} 1000")
    check output.contains("bitbarrel_keys_total{state=\"deleted\"} 50")
    check output.contains("bitbarrel_server_sessions_active 3")
    check output.contains("bitbarrel_server_barrels_open 2")

  test "histogram buckets are cumulative":
    ## Test that histogram buckets show cumulative counts
    let collector = newMetricsCollector(persistEnabled = false)

    # Record operations with various durations (in milliseconds)
    collector.recordOperation(opGet, stSuccess, 0.5)   # 0.0005s -> bucket 0
    collector.recordOperation(opGet, stSuccess, 0.8)   # 0.0008s -> bucket 0
    collector.recordOperation(opGet, stSuccess, 3.0)   # 0.003s  -> bucket 1
    collector.recordOperation(opGet, stSuccess, 8.0)   # 0.008s  -> bucket 2
    collector.recordOperation(opGet, stSuccess, 20.0)  # 0.02s   -> bucket 3

    let output = collector.generatePrometheusFormat()

    # Verify cumulative buckets
    check output.contains("bitbarrel_operation_duration_seconds_bucket{operation=\"get\",le=\"0.001\"} 2")
    check output.contains("bitbarrel_operation_duration_seconds_bucket{operation=\"get\",le=\"0.005\"} 3")
    check output.contains("bitbarrel_operation_duration_seconds_bucket{operation=\"get\",le=\"0.01\"} 4")
    check output.contains("bitbarrel_operation_duration_seconds_bucket{operation=\"get\",le=\"0.025\"} 5")

    # Verify count and sum (sum should be around 0.0323 seconds)
    check output.contains("bitbarrel_operation_duration_seconds_count{operation=\"get\"} 5")
    check output.contains("bitbarrel_operation_duration_seconds_sum{operation=\"get\"}")  # Just check it exists
