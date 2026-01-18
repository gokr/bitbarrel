import std/[times, strformat, net]
import ../src/network/client

proc main() =
  let client = newClient("localhost", 9876.Port)
  try:
    client.connect()
    echo "Connected"

    # Try set first
    let singleSet = client.set("single_key", "single_value")
    echo "Single set: ", singleSet

    # Create barrel for batch test
    discard client.createBarrel("test_batch")
    discard client.useBarrel("test_batch")
    echo "Barrel created and selected"

    # Try small batch first
    var pairs: seq[(string, string)]
    for i in 0..<10:
      pairs.add((fmt"key{i}", fmt"value{i}"))
    
    echo "Sending batch of ", pairs.len, " items..."
    let start = epochTime()
    let count = client.setMany(pairs)
    let elapsed = epochTime() - start
    
    echo "Set ", count, " items in ", elapsed, "s"

    client.close()
    
    # Try small batch first
    var pairs2: seq[(string, string)]
    for i in 0..<100:
      pairs2.add((fmt"key_{i}", fmt"value_{i}"))
    
    let client2 = newClient("localhost", 9876.Port)
    client2.connect()
    discard client2.useBarrel("test_batch")
    
    echo "Sending batch of ", pairs2.len, " items..."
    let start2 = epochTime()
    let count2 = client2.setMany(pairs2)
    let elapsed2 = epochTime() - start2
    
    echo "Set ", count2, " items in ", elapsed2, "s"

    discard client2.deleteBarrel("test_batch")
    echo "Cleaned up"
  except Exception as e:
    echo "Error: ", e.msg
    echo "Traceback: "
    echo e.getStackTrace()
  finally:
    client.close()

main()
