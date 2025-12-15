## Data Generation Utilities
## Provides tools to generate test data for examples

import strformat
import times

type
  DataGenerator* = object
    prefixes: seq[string]
    valueTemplates: seq[string]

proc initDataGenerator*(): DataGenerator =
  ## Initialize a data generator
  result = DataGenerator(
    prefixes: @[
      "user:", "session:", "order:", "product:", "category:",
      "config:", "cache:", "temp:", "log:", "metric:"
    ],
    valueTemplates: @[
      "value:$1",
      "data:$1:$2",
      "json:{\"id\":$1,\"value\":\"$2\"}",
      "blob:$1_base64encoded",
      "counter:$1",
      "timestamp:$1",
      "status:$1",
      "payload:$1:$2:$3"
    ]
  )

proc randomKey*(gen: DataGenerator, length: int = 16): string =
  ## Generate a random key with a prefix
  let timestamp = getTime().toUnix() mod 1000000
  let prefix = gen.prefixes[timestamp.int mod gen.prefixes.len]
  result = &"{prefix}{timestamp}"

proc randomValue*(gen: DataGenerator, size: int = 64): string =
  ## Generate a random value of specified size
  if size <= 0:
    result = ""
  elif size <= 100:
    # Small values use simple pattern
    let timestamp = getTime().toUnix()
    result = &"test_value_{timestamp}_data"
  else:
    # Large values are repeated pattern
    let base = "test_data_x"
    result = ""
    while result.len < size:
      result.add(base)

proc generatePairs*(
  gen: DataGenerator,
  count: int,
  keySize: int = 16,
  valueSize: int = 64
): seq[tuple[key: string, value: string]] =
  ## Generate a sequence of key-value pairs
  result = @[]
  for i in 0..<count:
    let key = gen.randomKey(keySize)
    let value = gen.randomValue(valueSize)
    result.add((key, value))

proc generateUsers*(count: int): seq[tuple[key: string, value: string]] =
  ## Generate realistic user data
  let cities = @[
    "New York", "Los Angeles", "Chicago", "Houston", "Phoenix",
    "Philadelphia", "San Antonio", "San Diego", "Dallas", "San Jose"
  ]

  for i in 0..<count:
    let userId = 1000 + i
    let city = cities[i mod cities.len]

    let key = &"user:{userId}"
    let value = &"{{\"id\":{userId},\"name\":\"User {userId}\",\"city\":\"{city}\",\"age\":{20 + (userId mod 50)}}}"
    result.add((key, value))

proc generateSessions*(count: int): seq[tuple[key: string, value: string]] =
  ## Generate session data
  let now = getTime().toUnix()

  for i in 0..<count:
    let sessionId = 10000 + i
    let userId = 1000 + (i mod 100)
    let expires = now + 3600 + (i * 60)  # 1h to 24h
    let active = (i mod 10) != 0

    let key = &"session:{sessionId}"
    let value = &"{{\"user_id\":{userId},\"expires\":{expires},\"active\":{active}}}"
    result.add((key, value))

proc generateOrders*(count: int): seq[tuple[key: string, value: string]] =
  ## Generate order data
  let now = getTime().toUnix()

  for i in 0..<count:
    let orderId = 10000 + i
    let userId = 1000 + (i mod 100)
    let total = 10.0 + (float(i mod 500))
    let timestamp = now - (i * 3600)  # Last N hours

    let key = &"order:{orderId}"
    let value = &"{{\"order_id\":{orderId},\"user_id\":{userId},\"total\":{total:.2f},\"timestamp\":{timestamp}}}"
    result.add((key, value))

proc generateLogEntries*(count: int): seq[tuple[key: string, value: string]] =
  ## Generate log entry data
  let levels = @["DEBUG", "INFO", "WARN", "ERROR"]
  let messages = @[
    "User login successful",
    "Database connection established",
    "Cache hit for key",
    "File written to disk",
    "Configuration loaded",
    "Memory threshold exceeded",
    "Network timeout occurred",
    "Backup completed"
  ]

  for i in 0..<count:
    let logId = 10000 + i
    let level = levels[i mod levels.len]
    let message = messages[i mod messages.len]
    let timestamp = getTime().toUnix() - (i * 60)  # Last N minutes

    let key = &"log:{logId}"
    let value = &"[{timestamp}] [{level}] {message}"
    result.add((key, value))

proc generateMetrics*(count: int): seq[tuple[key: string, value: string]] =
  ## Generate metric data
  let metricNames = @[
    "cpu_usage", "memory_usage", "disk_io", "network_throughput",
    "request_rate", "response_time", "error_rate", "cache_hit_rate"
  ]

  for i in 0..<count:
    let metricName = metricNames[i mod metricNames.len]
    let timestamp = getTime().toUnix() - (i * 60)  # Last N minutes
    let value = 10.0 + float(i mod 1000) / 10.0  # 0.1 to 100.0

    let key = &"metric:{metricName}:{timestamp}"
    let valueStr = &"{value:.1f}"
    result.add((key, valueStr))

proc generateMixedData*(
  count: int
): seq[tuple[key: string, value: string]] =
  ## Generate a mix of different data types
  var allData: seq[tuple[key: string, value: string]]

  # Generate different types
  allData.add(generateUsers(count div 5))
  allData.add(generateSessions(count div 5))
  allData.add(generateOrders(count div 5))
  allData.add(generateLogEntries(count div 5))
  allData.add(generateMetrics(count - (count div 5) * 4))

  # Return in order (no shuffle needed for demo)
  result = allData[0..<min(count, allData.len)]

# Helper function to estimate space usage
proc estimateSpace*(pairs: seq[tuple[key: string, value: string]]): int64 =
  ## Estimate space in bytes for key-value pairs
  # Rough estimation: key + value + 20 bytes overhead per record
  for pair in pairs:
    result += pair.key.len + pair.value.len + 20