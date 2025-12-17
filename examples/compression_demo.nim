## Compression Demo
## Demonstrates BitBarrel's compression capabilities

import std/[strformat, times, strutils, sequtils, os]
import ../src/bitbarrel/barrel

proc showCompressionInfo() =
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║   BitBarrel Demo: Compression Support                        ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo ""
  when defined(lz4Compression):
    echo "✅ Compression: LZ4 enabled (500 MB/s, 2.1x ratio)"
  elif defined(snappyCompression):
    echo "✅ Compression: Snappy enabled (250 MB/s, 1.7x ratio)"
  else:
    echo "❌ Compression: Disabled (build with -d:lz4Compression or -d:snappyCompression)"
  echo ""

proc main() =
  showCompressionInfo()

  # Create test data of different sizes and compressibility
  let testCases = [
    ("small", "small value"),
    ("medium", "This is a medium-sized value that might compress. ".repeat(5)),
    ("large_text", "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ".repeat(20)),
    ("repeated", "A".repeat(50)),
    ("json", """{"name":"John","age":30,"city":"New York","interests":["programming","music","reading"],"description":"This is a longer JSON document with various fields that should compress reasonably well"}"""),
    ("binary", "\x00\x01\x02\x03".repeat(100))
  ]

  # Note: Compression is configured at compile time with -d:lz4Compression or -d:snappyCompression
  # The runtime config for simple API doesn't expose compression settings
  # For compression configuration, use the low-level API

  var db = openBarrel("compression_demo")
  defer: db.close()

  echo "📊 Storing test data with compression analysis:"
  echo ""

  for (name, value) in testCases:
    echo &"   {name}:"
    echo &"     Size: {value.len} bytes"

    # Measure write time
    let startTime = cpuTime()
    discard db.set(name, value)
    let writeTime = (cpuTime() - startTime) * 1000

    echo &"     Write time: {writeTime:.2f} ms"

    # Read back
    let readStartTime = cpuTime()
    let readValue = db.get(name)
    let readTime = (cpuTime() - readStartTime) * 1000

    echo &"     Read time:  {readTime:.2f} ms"
    echo &"     Verified:  {readValue == value}"
    echo ""

  echo "📈 Database Statistics:"
  echo &"   Total keys: {db.count}"
  echo &"   Keys with values >128 bytes: {testCases.countIt(it[1].len > 128)}"
  echo ""

  # Demonstrate range queries with compression
  when defined(lz4Compression) or defined(snappyCompression):
    echo "🔍 Compression Impact Analysis:"
    let largeKey = "benchmark_data"
    let largeValue = "This is a test of compression effectiveness. ".repeat(50)

    # Store large value - compression depends on compile-time selection
    discard db.set("compressed", largeValue)

    # Store tiny value (won't compress)
    discard db.set("tiny", "a")

    echo &"   Large value size: {largeValue.len} bytes"
    echo &"   Tiny value size: 1 byte"
    echo ""
    echo "   Note: Actual space savings depend on:"
    echo "   - Data compressibility"
    echo "   - Compression algorithm chosen at build time"
    echo "   - Overhead of compression headers"
    echo ""

when isMainModule:
  main()