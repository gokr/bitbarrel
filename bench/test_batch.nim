import std/[times, strformat, net]
import ../src/network/client

proc main() =
  var client = newClient("localhost", Port(9888))
  try:
    client.connect()
    echo "Connected"

    # Create test barrel
    discard client.createBarrel("test_batch")
    discard client.useBarrel("test_batch")
    echo "Barrel created and selected"

    # Try small batch first
    var pairs: seq[(string, string)]
    for i in 0..<1000:
      pairs.add((fmt"key{i}", fmt"value{i}"))

    echo "Calling setMany for ", pairs.len, " items..."
    let start = epochTime()
    let count = client.setMany(pairs)
    let elapsed = epochTime() - start

    echo "Set ", count, " items in ", elapsed, "s"

    # Try to read them back
    var keys: seq[string]
    for i in 0..<1000:
      keys.add(fmt"key{i}")

    echo "Calling getMany for ", keys.len, " items..."
    let readStart = epochTime()
    let results = client.getMany(keys)
    let readElapsed = epochTime() - readStart

    echo "Got ", results.len, " items in ", readElapsed, "s"

    discard client.deleteBarrel("test_batch")
    echo "Cleaned up"
  except Exception as e:
    echo "Error: ", e.msg
    echo "Traceback: "
    echo e.getStackTrace()
  finally:
    client.close()

main()
