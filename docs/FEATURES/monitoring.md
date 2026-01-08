# Monitoring and Metrics

BitBarrel provides production-ready metrics via a Prometheus-compatible `/metrics` endpoint, enabling comprehensive observability for your key-value storage infrastructure.

## Prometheus Metrics Endpoint

The `/metrics` endpoint exposes metrics in Prometheus text exposition format, compatible with Prometheus, Grafana, and other monitoring systems.

### Accessing Metrics

```bash
# Query metrics directly
curl http://localhost:8080/metrics

# With authentication (if enabled)
curl -H "Authorization: Bearer YOUR_JWT_TOKEN" http://localhost:8080/metrics
```

## Available Metrics

### Operation Metrics

Track all database operations with success/failure rates and latency:

#### bitbarrel_operations_total (Counter)
Total number of operations performed.

**Labels:**
- `operation`: Operation type (`get`, `set`, `delete`)
- `status`: Operation result (`success`, `failure`)

**Example:**
```
bitbarrel_operations_total{operation="get",status="success"} 152345
bitbarrel_operations_total{operation="set",status="success"} 98234
bitbarrel_operations_total{operation="delete",status="success"} 1204
```

#### bitbarrel_operation_duration_seconds (Histogram)
Operation latency distribution across percentile buckets.

**Labels:**
- `operation`: Operation type (`get`, `set`, `delete`)
- `le`: Bucket upper bound in seconds

**Buckets:** 1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, +Inf

**Example:**
```
bitbarrel_operation_duration_seconds_bucket{operation="get",le="0.001"} 145231
bitbarrel_operation_duration_seconds_bucket{operation="get",le="0.005"} 149874
bitbarrel_operation_duration_seconds_bucket{operation="get",le="+Inf"} 152345
bitbarrel_operation_duration_seconds_count{operation="get"} 152345
bitbarrel_operation_duration_seconds_sum{operation="get"} 234.56
```

### Storage Metrics

Monitor disk usage, fragmentation, and key counts:

#### bitbarrel_storage_files_total (Gauge)
Total number of data files across all barrels.

#### bitbarrel_storage_size_bytes (Gauge)
Total storage size in bytes.

#### bitbarrel_storage_fragmentation_ratio (Gauge)
Average fragmentation ratio (0.0 to 1.0) across all barrels.

#### bitbarrel_keys_total (Gauge)
Total number of keys by state.

**Labels:**
- `state`: Key state (`active`, `deleted`)

**Example:**
```
bitbarrel_storage_files_total 12
bitbarrel_storage_size_bytes 524288000
bitbarrel_storage_fragmentation_ratio 0.15
bitbarrel_keys_total{state="active"} 1000000
bitbarrel_keys_total{state="deleted"} 50000
```

### Server Metrics

Track server health and resource usage:

#### bitbarrel_server_sessions_active (Gauge)
Number of active client sessions.

#### bitbarrel_server_barrels_open (Gauge)
Number of open barrels.

#### bitbarrel_server_uptime_seconds (Gauge)
Server uptime in seconds.

**Example:**
```
bitbarrel_server_sessions_active 45
bitbarrel_server_barrels_open 8
bitbarrel_server_uptime_seconds 864230
```

## Prometheus Configuration

### Basic Setup

Add BitBarrel to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'bitbarrel'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
    scrape_interval: 15s
```

### With Authentication

If BitBarrel authentication is enabled, provide JWT token:

```yaml
scrape_configs:
  - job_name: 'bitbarrel'
    static_configs:
      - targets: ['localhost:8080']
    metrics_path: '/metrics'
    scrape_interval: 15s
    authorization:
      type: Bearer
      credentials: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...'
```

### Service Discovery

For dynamic environments:

```yaml
scrape_configs:
  - job_name: 'bitbarrel'
    consul_sd_configs:
      - server: 'consul.example.com:8500'
        services: ['bitbarrel']
    relabel_configs:
      - source_labels: [__meta_consul_service]
        target_label: service
```

## Common PromQL Queries

### Request Rate

```promql
# Operations per second
rate(bitbarrel_operations_total[5m])

# Write rate
rate(bitbarrel_operations_total{operation="set"}[5m])

# Read rate
rate(bitbarrel_operations_total{operation="get"}[5m])
```

### Latency Percentiles

```promql
# P50 latency for GET operations
histogram_quantile(0.50, rate(bitbarrel_operation_duration_seconds_bucket{operation="get"}[5m]))

# P95 latency
histogram_quantile(0.95, rate(bitbarrel_operation_duration_seconds_bucket{operation="get"}[5m]))

# P99 latency
histogram_quantile(0.99, rate(bitbarrel_operation_duration_seconds_bucket{operation="get"}[5m]))
```

### Error Rates

```promql
# Error rate (percentage)
sum(rate(bitbarrel_operations_total{status="failure"}[5m]))
  / sum(rate(bitbarrel_operations_total[5m])) * 100

# Failed GET operations per second
rate(bitbarrel_operations_total{operation="get",status="failure"}[5m])
```

### Storage Growth

```promql
# Storage growth rate (bytes per hour)
rate(bitbarrel_storage_size_bytes[1h]) * 3600

# Fragmentation trend
deriv(bitbarrel_storage_fragmentation_ratio[1h])

# Key growth rate
rate(bitbarrel_keys_total{state="active"}[1h]) * 3600
```

### Server Health

```promql
# Active sessions
bitbarrel_server_sessions_active

# Barrels per server
bitbarrel_server_barrels_open

# Server uptime (days)
bitbarrel_server_uptime_seconds / 86400
```

## Grafana Dashboards

### Quick Start Dashboard

Create a basic dashboard with these panels:

1. **Operations Rate**
   - Query: `rate(bitbarrel_operations_total[5m])`
   - Type: Graph
   - Legend: `{{operation}} ({{status}})`

2. **P95 Latency**
   - Query: `histogram_quantile(0.95, rate(bitbarrel_operation_duration_seconds_bucket[5m]))`
   - Type: Graph
   - Unit: seconds
   - Legend: `{{operation}}`

3. **Storage Usage**
   - Query: `bitbarrel_storage_size_bytes`
   - Type: Graph
   - Unit: bytes
   - Format: IEC

4. **Active Keys**
   - Query: `bitbarrel_keys_total{state="active"}`
   - Type: Stat
   - Format: Short

5. **Error Rate**
   - Query: `sum(rate(bitbarrel_operations_total{status="failure"}[5m])) / sum(rate(bitbarrel_operations_total[5m]))`
   - Type: Gauge
   - Unit: percentunit (0.0-1.0)
   - Thresholds: Green (< 0.01), Yellow (< 0.05), Red (>= 0.05)

6. **Fragmentation**
   - Query: `bitbarrel_storage_fragmentation_ratio`
   - Type: Gauge
   - Unit: percentunit (0.0-1.0)
   - Thresholds: Green (< 0.3), Yellow (< 0.5), Red (>= 0.5)

### Full Dashboard Example

```json
{
  "dashboard": {
    "title": "BitBarrel Metrics",
    "panels": [
      {
        "title": "Request Rate",
        "targets": [
          {
            "expr": "rate(bitbarrel_operations_total[5m])",
            "legendFormat": "{{operation}} ({{status}})"
          }
        ]
      }
    ]
  }
}
```

## Alerting Rules

### Prometheus Alerts

Create `bitbarrel_alerts.yml`:

```yaml
groups:
  - name: bitbarrel
    interval: 30s
    rules:
      - alert: HighErrorRate
        expr: |
          sum(rate(bitbarrel_operations_total{status="failure"}[5m]))
            / sum(rate(bitbarrel_operations_total[5m])) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "BitBarrel error rate above 5%"
          description: "Error rate is {{ $value | humanizePercentage }}"

      - alert: HighLatency
        expr: |
          histogram_quantile(0.95,
            rate(bitbarrel_operation_duration_seconds_bucket[5m])) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "BitBarrel P95 latency above 100ms"
          description: "P95 latency: {{ $value }}s"

      - alert: HighFragmentation
        expr: bitbarrel_storage_fragmentation_ratio > 0.5
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "BitBarrel fragmentation above 50%"
          description: "Fragmentation: {{ $value | humanizePercentage }}"
          action: "Consider running manual compaction"

      - alert: DiskSpaceGrowth
        expr: |
          predict_linear(bitbarrel_storage_size_bytes[1h], 24*3600)
            > 100 * 1024 * 1024 * 1024
        for: 1h
        labels:
          severity: info
        annotations:
          summary: "BitBarrel storage will exceed 100GB in 24h"
          description: "Current size: {{ $value | humanize1024 }}B"
```

## Performance Considerations

### Metrics Collection Overhead

- **CPU**: < 0.1% overhead from atomic counters
- **Memory**: ~1KB per operation type
- **Network**: Metrics aggregated only on `/metrics` request

### Scraping Best Practices

1. **Scrape Interval**: 15-30 seconds recommended
2. **Timeout**: Set scrape timeout to 10 seconds
3. **Rate Limiting**: Built-in protection against excessive scraping

### High-Traffic Environments

For servers handling > 10K ops/sec:
- Increase scrape interval to 30-60s
- Use Prometheus remote write for long-term storage
- Consider aggregation via recording rules

## Troubleshooting

### Metrics Endpoint Not Responding

```bash
# Check if server is running
curl http://localhost:8080/status

# Verify metrics endpoint
curl -v http://localhost:8080/metrics
```

### Missing Metrics

If certain metrics show no data:
- Verify barrels are open and receiving traffic
- Check that operations are being performed
- Ensure correct label filters in queries

### Authentication Issues

```bash
# Test with authentication
TOKEN="your-jwt-token"
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/metrics

# If 401 Unauthorized, verify token:
# - Token not expired
# - Correct signing key
# - User has required permissions
```

## Best Practices

1. **Dashboard Organization**
   - Create separate dashboards for operations, storage, and server health
   - Use template variables for filtering by barrel or operation

2. **Alert Tuning**
   - Start with conservative thresholds
   - Adjust based on baseline performance
   - Add `for` clauses to avoid flapping

3. **Retention Policy**
   - Keep high-resolution data for 15 days
   - Downsample to 5-minute resolution after 15 days
   - Archive to cold storage after 90 days

4. **Capacity Planning**
   - Monitor storage growth trends
   - Set up predictive alerts for disk space
   - Track fragmentation and schedule compaction

## Integration Examples

### With Telegraf

```toml
[[inputs.prometheus]]
  urls = ["http://localhost:8080/metrics"]
  metric_version = 2
```

### With Datadog

```yaml
init_config:

instances:
  - prometheus_url: http://localhost:8080/metrics
    namespace: bitbarrel
    metrics:
      - bitbarrel_*
```

### With CloudWatch

Use Prometheus CloudWatch Exporter:
```bash
prometheus_cloudwatch_exporter \
  --config.file=cloudwatch_config.yml \
  --web.listen-address=:9106
```

## Future Enhancements

Planned metrics features (see `TODO.md`):
- Per-barrel metrics breakdown
- Compaction metrics (runs, duration, bytes reclaimed)
- Cache hit/miss rates
- Network throughput per session
- Custom metric labels via configuration

## See Also

- [Prometheus Documentation](https://prometheus.io/docs/)
- [PromQL Query Examples](https://prometheus.io/docs/prometheus/latest/querying/examples/)
- [Grafana Dashboards](https://grafana.com/docs/grafana/latest/dashboards/)
- [BitBarrel Configuration](../USER_GUIDE/configuration.md)
