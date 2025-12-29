## BitBarrel Graph Traversal Demo
##
## Demonstrates graph traversal patterns using the network client API.
## Shows social graphs, content graphs, and organization charts.
##
## Note: Requires a running BitBarrel server on port 9876.
## Start with: ./bitbarrel -p=9876 serve
##
## Run with: nim c -r demos/graph_demo.nim

import std/[json, strformat, strutils, tables, algorithm, sets]
import network/client
from std/net import Port

proc printHeader(title: string) =
  echo ""
  echo "╔" & "═".repeat(78) & "╗"
  echo "║ " & title.alignLeft(77) & "║"
  echo "╚" & "═".repeat(78) & "╝"
  echo ""

proc printSection(title: string) =
  echo ""
  echo "─".repeat(80)
  echo "  " & title
  echo "─".repeat(80)
  echo ""

proc demoSocialGraph(client: var BitBarrelClient) =
  ## Demonstrate social graph traversal (friends, posts, interactions)
  printSection("Social Graph Demo")

  echo "Use case: Social network with friends, posts, likes, and comments"

  # Setup barrel for social data
  if not client.createBarrel("social"):
    discard client.openBarrel("social")
  discard client.useBarrel("social")

  echo "✓ Connected to social barrel"

  # Create users with friend relationships
  echo "\nCreating users with friend relationships..."

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

  # Store posts
  echo "\nCreating posts..."

  let post1 = %*{
    "author": "user:alice",
    "content": "Hello BitBarrel world!",
    "_refs": {
      "likes": ["user:bob", "user:charlie"],
      "comments": ["comment:post1_1", "comment:post1_2"]
    }
  }
  discard client.set("post:alice1", $post1)

  let post2 = %*{
    "author": "user:bob",
    "content": "Exploring graph traversals in BitBarrel",
    "_refs": {
      "likes": ["user:alice", "user:diana"],
      "comments": ["comment:post2_1"]
    }
  }
  discard client.set("post:bob1", $post2)

  echo "✓ Created 2 posts with likes and comments"

  # Demo 1: Get Alice's friends
  echo "\nDemo 1: Alice's direct friends"
  echo "Path: friends"
  let friends = client.traversePath("user:alice", "friends")
  for f in friends:
    let friendData = parseJson(f.value)
    let name = friendData["name"].getStr()
    echo fmt("  - {name} ({f.key})")

  # Demo 2: Friends of friends
  echo "\nDemo 2: Alice's friends-of-friends (potential connections)"
  echo "Path: friends->friends"
  let fof = client.traversePath("user:alice", "friends->friends")
  var seen = initHashSet[string]()
  for f in fof:
    if f.key notin ["user:alice"] and f.key notin seen:
      seen.incl(f.key)
      let personData = parseJson(f.value)
      let name = personData["name"].getStr()
      echo fmt("  - {name} ({f.key})")

  # Demo 3: Posts from Alice's friends
  echo "\nDemo 3: Posts from Alice's friends"
  echo "Path: friends->posts"
  let posts = client.traversePath("user:alice", "friends->posts")
  for p in posts:
    let postData = parseJson(p.value)
    let content = postData["content"].getStr()
    echo fmt("  - {content}")

proc demoContentGraph(client: var BitBarrelClient) =
  ## Demonstrate content graph traversal (articles, tags, comments)
  printSection("Content Graph Demo")

  echo "Use case: Content management with articles, tags, and relationships"

  # Setup barrel for content data
  if not client.createBarrel("content"):
    discard client.openBarrel("content")
  discard client.useBarrel("content")

  echo "✓ Connected to content barrel"

  # Create content graph
  echo "\nBuilding content graph..."

  # Articles
  let article1 = %*{
    "title": "Getting Started with BitBarrel",
    "author": "Alice",
    "_refs": {
      "tags": ["tag:nosql", "tag:database", "tag:tutorial"],
      "related": ["article:2", "article:3"]
    }
  }
  discard client.set("article:1", $article1)

  let article2 = %*{
    "title": "Advanced Bitcask Techniques",
    "author": "Bob",
    "_refs": {
      "tags": ["tag:nosql", "tag:performance", "tag:advanced"],
      "related": ["article:1"]
    }
  }
  discard client.set("article:2", $article2)

  # Tags
  discard client.set("tag:nosql", $(%*{ "description": "NoSQL databases" }))
  discard client.set("tag:database", $(%*{ "description": "Database technologies" }))
  discard client.set("tag:performance", $(%*{ "description": "Performance optimization" }))

  echo "✓ Created articles and tags"

  # Demo 1: Related articles
  echo "\nDemo 1: Articles related to 'Getting Started with BitBarrel'"
  echo "Path: related"
  let related = client.traversePath("article:1", "related")
  for r in related:
    let article = parseJson(r.value)
    let title = article["title"].getStr()
    echo fmt("  - {title}")

  # Demo 2: Tags for an article
  echo "\nDemo 2: Tags for 'Getting Started with BitBarrel'"
  echo "Path: tags"
  let tags = client.traversePath("article:1", "tags")
  for t in tags:
    let tagData = parseJson(t.value)
    let desc = tagData["description"].getStr()
    echo fmt("  - {desc}")

proc demoOrgChart(client: var BitBarrelClient) =
  ## Demonstrate organization chart traversal (hierarchical data)
  printSection("Organization Chart Demo")

  echo "Use case: Hierarchical org structure with management chains"

  # Setup barrel for org data
  if not client.createBarrel("org"):
    discard client.openBarrel("org")
  discard client.useBarrel("org")

  echo "✓ Connected to org barrel"

  # Create org structure
  echo "\nBuilding organization hierarchy..."

  let ceoData = %*{
    "name": "John Smith",
    "title": "CEO",
    "_refs": {
      "direct_reports": ["emp:cto", "emp:cfo", "emp:vp_sales"]
    }
  }
  discard client.set("emp:ceo", $ceoData)

  let ctoData = %*{
    "name": "Sarah Johnson",
    "title": "Chief Technology Officer",
    "_refs": {
      "direct_reports": ["emp:eng_mgr"],
      "manager": ["emp:ceo"]
    }
  }
  discard client.set("emp:cto", $ctoData)

  let cfoData = %*{
    "name": "Michael Brown",
    "title": "Chief Financial Officer",
    "_refs": {
      "direct_reports": ["emp:finance_mgr"],
      "manager": ["emp:ceo"]
    }
  }
  discard client.set("emp:cfo", $cfoData)

  let vpSalesData = %*{
    "name": "Emily Davis",
    "title": "VP of Sales",
    "_refs": {
      "direct_reports": ["emp:sales_mgr"],
      "manager": ["emp:ceo"]
    }
  }
  discard client.set("emp:vp_sales", $vpSalesData)

  echo "✓ Created org hierarchy"

  # Demo 1: CEO's direct reports
  echo "\nDemo 1: CEO's direct reports"
  echo "Path: direct_reports"
  let ceoReports = client.traversePath("emp:ceo", "direct_reports")
  for r in ceoReports:
    let emp = parseJson(r.value)
    let title = emp["title"].getStr()
    let name = emp["name"].getStr()
    echo fmt("  - {title}: {name}")

proc main() =
  printHeader("BitBarrel Graph Traversal Demo")

  echo "This demo showcases graph traversal patterns using the network client API."
  echo ""
  echo "Prerequisites:"
  echo "  • BitBarrel server must be running on port 9876"
  echo "  • Start server with: ./bitbarrel -p=9876 serve"
  echo ""

  # Setup server connection
  var client = newClient(ClientConfig(host: "localhost", port: 9876.Port))

  demoSocialGraph(client)
  demoContentGraph(client)
  demoOrgChart(client)

  printHeader("Demo Complete!")

  echo "Key features demonstrated:"
  echo "✓ Multi-step path traversals (friends->posts)"
  echo "✓ Array slicing and filtering"
  echo "✓ Wildcard traversal for deep searches"
  echo "✓ Connection discovery and analysis"
  echo ""

when isMainModule:
  main()
