## Range Queries Example
##
## Demonstrates advanced query features:
## - Range queries (key-value pairs)
## - Keys-only queries (more efficient)
## - Iterator-based queries (memory-efficient streaming)
##
## Prerequisites:
## - BitBarrel server running on localhost:9876
## - Range queries require a barrel in bmCritBit mode
##
## Run:
##   nim c -r examples/range_queries.nim

import ../src/bitbarrel_client
import std/net

proc main() =
  echo "BitBarrel Client - Range Queries Example"
  echo "========================================="

  var client = newClient("localhost", 9876.Port)

  try:
    echo "\n1. Connecting to server..."
    client.connect()
    echo "   Connected!"

    # Create a barrel in bmCritBit mode for ordered queries
    echo "\n2. Creating ordered barrel 'range_test'..."
    let config = """{"mode": "bmCritBit"}"""
    if client.createBarrel("range_test", config):
      echo "   Ordered barrel created!"
    else:
      echo "   Barrel already exists"

    discard client.useBarrel("range_test")

    # Add test data with ordered keys
    echo "\n3. Adding test data..."
    for i in 0..<100:
      let key = fmt"user:{i:03d}"
      let value = fmt"User {i} Data"
      discard client.set(key, value)
    echo "   Added 100 users (user:000 to user:099)"

    # Demonstrate range query
    echo "\n4. Range Query (key-value pairs):"
    echo "   Query: user:010 to user:019, limit=5"
    let (items, nextCursor, hasMore) = client.rangeQuery("user:010", "user:020", limit=5)
    echo fmt"   Found {items.len} items:"
    for (key, value) in items:
      echo fmt"     {key} => {value}"
    echo fmt"   Has more: {hasMore}"
    echo fmt"   Next cursor: {nextCursor}"

    if hasMore:
      echo "\n5. Getting next page..."
      let (nextItems, _, _) = client.rangeQuery("user:010", "user:020", limit=5, cursor=nextCursor)
      echo fmt"   Next page has {nextItems.len} items"
      for (key, value) in nextItems:
        echo fmt"     {key} => {value}"

    # Demonstrate keys-only query
    echo "\n6. Keys-Only Query:"
    echo "   Query: user:030 to user:039, limit=5"
    let (keys, keysCursor, keysHasMore) = client.rangeQueryKeys("user:030", "user:040", limit=5)
    echo fmt"   Found {keys.len} keys (values not fetched):"
    for key in keys:
      echo fmt"     {key}"
    echo fmt"   Has more: {keysHasMore}"

    # Demonstrate prefix query
    echo "\n7. Prefix Query:"
    echo "   Query: keys starting with 'user:0'"
    let (prefixItems, _, _) = client.prefixQuery("user:0", limit=10)
    echo fmt"   First 10 users:"
    for (key, value) in prefixItems:
      echo fmt"     {key} => {value}"

    # Demonstrate iterator-based range query
    echo "\n8. Iterator-Based Range Query:"
    echo "   Streaming through all users with automatic pagination..."
    var iter = client.newRangeIterator("user:000", "user:100", pageSize=10)
    var count = 0
    for (key, value) in iter:
      if count < 5:  # Only show first 5
        echo fmt"     {key} => {value}"
      elif count == 5:
        echo "     ... (skipping remaining items)"
      count += 1
    echo fmt"   Total items iterated: {count}"

    # Demonstrate keys-only iterator
    echo "\n9. Keys-Only Iterator:"
    echo "   Streaming keys only (more memory efficient)..."
    var keysIter = client.newKeysIterator("user:000", "user:100", pageSize=10)
    var keysCount = 0
    for key in keysIter:
      if keysCount < 5:
        echo fmt"     {key}"
      elif keysCount == 5:
        echo "     ... (skipping remaining keys)"
      keysCount += 1
    echo fmt"   Total keys iterated: {keysCount}"

    # Demonstrate prefix iterator for large result sets
    echo "\n10. Prefix Iterator for Large Datasets:"
    echo "    Use when result set is too large for memory..."
    var prefixIter = client.newPrefixIterator("user:", pageSize=20)
    var prefixCount = 0
    for (key, value) in prefixIter:
      # Process each item (e.g., write to file, send to another service)
      if prefixCount < 3:
        echo fmt"     Processing: {key}"
      elif prefixCount == 3:
        echo "     ... (processing continues)"
      prefixCount += 1
      if prefixCount >= 100:  # Stop after 100 for demo
        break
    echo fmt"    Processed {prefixCount} items from iterator"

    # Demonstrate keys-only prefix iterator
    echo "\n11. Keys-Only Prefix Iterator:"
    echo "    When you only need to know what keys exist..."
    var keysPrefixIter = client.newKeysPrefixIterator("user:", pageSize=20)
    var matchingKeys: seq[string]
    for key in keysPrefixIter:
      # You might filter or validate keys
      matchingKeys.add(key)
      if matchingKeys.len >= 50:  # Collect first 50
        break
    echo fmt"    Found {matchingKeys.len} keys matching prefix"
    if matchingKeys.len > 0:
      echo "    Sample keys:"
      for i in 0..<min(5, matchingKeys.len):
        echo fmt"      {matchingKeys[i]}"

    # Cleanup
    echo "\n12. Cleaning up..."
    discard client.dropBarrel("range_test")
    echo "   Test barrel dropped"

  except ClientError as e:
    echo "Error: ", e.msg

  finally:
    client.close()
    echo "\nConnection closed."

when isMainModule:
  main()
