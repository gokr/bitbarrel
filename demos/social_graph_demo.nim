## BitBarrel Reference Model - Social Graph Demo
##
## This example demonstrates how to use the reference model for
## social network features like friends, posts, and interactions.

import std/[json, strformat, strutils]
import network/client
from std/net import Port

proc main() =
  echo "=== BitBarrel Social Graph Demo ==="
  echo()

  # Setup server connection
  var client = newClient("localhost", Port(9876))

  # Create and use a barrel
  if not client.createBarrel("social"):
    echo "Failed to create barrel, trying to open existing..."
    if not client.openBarrel("social"):
      echo "Error: Cannot access barrel"
      return

  if not client.useBarrel("social"):
    echo "Error: Cannot use barrel"
    return

  echo "✓ Connected to BitBarrel server"
  echo()

  # Store users with friend relationships
  echo "Creating users with friend relationships..."

  let aliceData = %*{
    "name": "Alice",
    "email": "alice@example.com",
    "joined": "2024-01-15",
    "_refs": {
      "friends": ["user:bob", "user:charlie", "user:diana"],
      "posts": ["post:alice1", "post:alice2"]
    }
  }
  discard client.set("user:alice", $aliceData)

  let bobData = %*{
    "name": "Bob",
    "email": "bob@example.com",
    "joined": "2024-01-20",
    "_refs": {
      "friends": ["user:alice", "user:charlie"],
      "posts": ["post:bob1"]
    }
  }
  discard client.set("user:bob", $bobData)

  let charlieData = %*{
    "name": "Charlie",
    "email": "charlie@example.com",
    "joined": "2024-02-01",
    "_refs": {
      "friends": ["user:alice", "user:bob", "user:diana"],
      "posts": ["post:charlie1", "post:charlie2", "post:charlie3"]
    }
  }
  discard client.set("user:charlie", $charlieData)

  let dianaData = %*{
    "name": "Diana",
    "email": "diana@example.com",
    "joined": "2024-02-10",
    "_refs": {
      "friends": ["user:alice"],
      "posts": ["post:diana1"]
    }
  }
  discard client.set("user:diana", $dianaData)

  echo "✓ Created 4 users with friend relationships"
  echo()

  # Store posts
  echo "Creating posts..."

  let post1 = %*{
    "author": "user:alice",
    "content": "Hello BitBarrel world!",
    "timestamp": "2024-03-01T10:00:00Z",
    "_refs": {
      "likes": ["user:bob", "user:charlie"],
      "comments": ["comment:post1_1", "comment:post1_2"]
    }
  }
  discard client.set("post:alice1", $post1)

  let post2 = %*{
    "author": "user:bob",
    "content": "Exploring graph traversals in BitBarrel",
    "timestamp": "2024-03-02T14:30:00Z",
    "_refs": {
      "likes": ["user:alice", "user:diana"],
      "comments": ["comment:post2_1"]
    }
  }
  discard client.set("post:bob1", $post2)

  echo "✓ Created 2 posts with likes and comments"
  echo()

  # Demo 1: Get Alice's friends
  echo "Demo 1: Alice's direct friends"
  echo "Path: friends"
  let friends = client.traversePath("user:alice", "friends")
  for f in friends:
    let friendData = parseJson(f.value)
    echo fmt("  - {friendData[\"name\"].getStr()} ({f.key})")
  echo()

  # Demo 2: Friends of friends (2nd degree connections)
  echo "Demo 2: Alice's friends-of-friends (potential new connections)"
  echo "Path: friends->friends"
  let fof = client.traversePath("user:alice", "friends->friends")
  for f in fof:
    # Skip direct friends
    if f.key notin ["user:alice"] and f.path.find("->friends->friends->") == -1:
      let personData = parseJson(f.value)
      echo fmt("  - {personData[\"name\"].getStr()} ({f.key})")
      echo fmt("    via path: {f.path}")
  echo()

  # Demo 3: Get all posts from Alice's friends
  echo "Demo 3: Posts from Alice's friends (most recent 3 per friend)"
  echo "Path: friends->posts[-3:]"
  let posts = client.traverse("user:alice", "friends->posts[-3:]",
                               TraverseOptions(includeFullData: true))
  for p in posts:
    let postData = parseJson(p.value)
    echo fmt("  - {postData[\"content\"].getStr()}")
    echo fmt("    by: {postData[\"author\"].getStr()}")
    echo fmt("    path: {p.path}")
  echo()

  # Demo 4: Who liked Alice's posts?
  echo "Demo 4: People who liked Alice's posts"
  echo "Path: posts->likes"
  let likers = client.traversePath("user:alice", "posts->likes")
  var uniqueLikers: seq[string] = @[]
  for l in likers:
    if l.key notin uniqueLikers:
      uniqueLikers.add(l.key)
      let personData = parseJson(l.value)
      echo fmt("  - {personData[\"name\"].getStr()} ({l.key})")
  echo()

  # Demo 5: Find commenters on Alice's posts
  echo "Demo 5: Commenters on Alice's posts (any comment)"
  echo "Path: posts->comments"
  let commenters = client.traversePath("user:alice", "posts->comments")
  echo fmt("  Found {commenters.len} comment threads")
  for c in commenters:
    echo fmt("    - Comment key: {c.key}")
  echo()

  # Demo 6: Path-only query (faster, less data)
  echo "Demo 6: Just checking connection paths (no data retrieval)"
  let options = TraverseOptions(
    includeFullData: false,
    extractArrays: false,
    firstOnly: false
  )
  let paths = client.traverse("user:alice", "friends->friends",
                              options)
  echo fmt("  Found {paths.len} paths to 2nd-degree connections")
  for p in paths:
    echo fmt("    - {p.path}")
  echo()

  # Demo 7: Common friends between Alice and Bob
  echo "Demo 7: Common friends between Alice and Bob"
  let aliceFriends = client.traversePath("user:alice", "friends")
  let bobFriends = client.traversePath("user:bob", "friends")

  var common: seq[string] = @[]
  for af in aliceFriends:
    for bf in bobFriends:
      if af.key == bf.key:
        common.add(af.key)

  for personKey in common:
    let personData = parseJson(client.get(personKey))
    echo fmt("  - {personData[\"name\"].getStr()} ({personKey})")
  echo()

  # Demo 8: Wildcard traversal (all relationships)
  echo "Demo 8: Everything connected to Alice (wildcard)"
  echo "Path: *->* (first 10 results only)"
  let wildcard = client.traverse("user:alice", "*->*",
                                 TraverseOptions(firstOnly: false))
  echo fmt("  Found {wildcard.len} connected items:")
  for w in wildcard:
    echo fmt("    - {w.key} via {w.path}")
  echo()

  echo "=== Demo Complete ==="
  echo()
  echo "Key features demonstrated:"
  echo "✓ Multi-step path traversals (friends->posts)"
  echo "✓ Array slicing (posts[-3:], comments)"
  echo "✓ Wildcard traversal (*)"
  echo "✓ Path-only queries (includeFullData=false)"
  echo "✓ Connection discovery and analysis"
  echo "✓ Efficient server-side processing"

when isMainModule:
  main()
