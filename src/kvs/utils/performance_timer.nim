## Performance Timer Utilities
## Provides timing utilities for benchmarking examples

import times
import strformat
import math

type
  Timer* = object
    startTime: Time
    endTime: Time
    measurements: seq[int64]
    isRunning: bool

proc startTimer*(): Timer =
  ## Start a new timer
  result = Timer(
    startTime: getTime(),
    measurements: @[],
    isRunning: true
  )

proc stop*(timer: var Timer) =
  ## Stop the timer and record measurement
  if timer.isRunning:
    timer.endTime = getTime()
    let elapsed = inMilliseconds(timer.endTime - timer.startTime)
    timer.measurements.add(elapsed)
    timer.isRunning = false

proc lap*(timer: var Timer): int64 =
  ## Record a lap time without stopping
  let now = getTime()
  let elapsed = inMilliseconds(now - timer.startTime)
  timer.measurements.add(elapsed)
  timer.startTime = now  # Reset for next lap
  result = elapsed

proc elapsed*(timer: Timer): int64 =
  ## Get elapsed time in milliseconds
  if timer.isRunning:
    inMilliseconds(getTime() - timer.startTime)
  else:
    if timer.measurements.len > 0:
      timer.measurements[^1]
    else:
      0

proc reset*(timer: var Timer) =
  ## Reset the timer
  timer.startTime = getTime()
  timer.endTime = timer.startTime  # Set to same as start
  timer.measurements = @[]
  timer.isRunning = true

proc averageTime*(timer: Timer): float =
  ## Get average time of all measurements
  if timer.measurements.len == 0:
    return 0.0

  var sum: int64 = 0
  for m in timer.measurements:
    sum += m
  result = sum.float / timer.measurements.len.float

proc minTime*(timer: Timer): int64 =
  ## Get minimum time
  if timer.measurements.len == 0:
    return 0
  result = timer.measurements[0]
  for m in timer.measurements:
    if m < result:
      result = m

proc maxTime*(timer: Timer): int64 =
  ## Get maximum time
  if timer.measurements.len == 0:
    return 0
  result = timer.measurements[0]
  for m in timer.measurements:
    if m > result:
      result = m

proc stdDev*(timer: Timer): float =
  ## Get standard deviation of measurements
  if timer.measurements.len <= 1:
    return 0.0

  let avg = timer.averageTime()
  var sumSquares: float = 0.0
  for m in timer.measurements:
    let diff = m.float - avg
    sumSquares += diff * diff

  result = sqrt(sumSquares / (timer.measurements.len - 1).float)

proc count*(timer: Timer): int =
  ## Get number of measurements
  result = timer.measurements.len

proc summary*(timer: Timer): string =
  ## Get a summary string of timer statistics
  if timer.measurements.len == 0:
    result = "No measurements"
  elif timer.measurements.len == 1:
    result = &"{timer.elapsed()}ms"
  else:
    result = &"avg: {timer.averageTime():.2f}ms, " &
            &"min: {timer.minTime()}ms, " &
            &"max: {timer.maxTime()}ms, " &
            &"stddev: {timer.stdDev():.2f}ms"

type
  Benchmark* = object
    name: string
    timer: Timer
    operationCount: int64

proc startBenchmark*(name: string): Benchmark =
  ## Start a new benchmark
  result = Benchmark(
    name: name,
    timer: startTimer(),
    operationCount: 0
  )

proc stopBenchmark*(bench: var Benchmark, operationCount: int64 = 0) =
  ## Stop the benchmark and record operation count
  bench.operationCount = operationCount
  bench.timer.stop()

proc opsPerSecond*(bench: Benchmark): float =
  ## Calculate operations per second
  if bench.timer.elapsed() == 0:
    result = 0.0
  else:
    let seconds = bench.timer.elapsed().float / 1000.0
    result = bench.operationCount.float / seconds

proc printBenchmark*(bench: Benchmark, detailLevel: int = 1) =
  ## Print benchmark results
  echo &"\n📊 Benchmark: {bench.name}"
  echo &"   Operations: {bench.operationCount}"

  if detailLevel >= 1:
    echo &"   Total time: {bench.timer.elapsed()}ms"
    echo &"   Ops/sec: {bench.opsPerSecond():.0f}"

  if detailLevel >= 2:
    if bench.timer.count() > 1:
      echo &"   Avg per op: {bench.timer.averageTime():.4f}ms"
      echo &"   Min/Max: {bench.timer.minTime()}ms / {bench.timer.maxTime()}ms"
      echo &"   StdDev: {bench.timer.stdDev():.4f}ms"

proc compare*(
  name1: string, time1: int64, ops1: int64,
  name2: string, time2: int64, ops2: int64
) =
  ## Compare two benchmark results
  echo "\n📈 Comparison:"
  echo &"   {name1}: {time1}ms ({ops1} ops)"
  echo &"   {name2}: {time2}ms ({ops2} ops)"

  let timeImprovement = ((time1 - time2).float / time1.float * 100)
  let speedRatio = ops2.float / ops1.float

  if timeImprovement > 0:
    echo &"   Time improvement: {timeImprovement:.1f}% (faster)"
  else:
    echo &"   Time penalty: {abs(timeImprovement):.1f}% (slower)"

  echo &"   Speed ratio: {speedRatio:.2f}x"

# Helpful macros for timing operations
template timed*[T](operation: untyped): T =
  ## Time an operation and return the result
  let timer = startTimer()
  result = operation
  timer.stop()
  echo &"   ⏱️  Time: {timer.elapsed()}ms"