## BitBarrel Reference Model - Content Graph Demo
##
## This example shows how to use reference traversal for content
## management systems: articles, tags, comments, and related content.

import std/[json, strformat, os, tables]
import bitbarrel
import network/client

proc main() =
  echo "=== BitBarrel Content Graph Demo ==="
  echo()

  # Setup
  var client = newClient("localhost", 9876.Port)
  if not client.createBarrel("content"):
    discard client.openBarrel("content")
  discard client.useBarrel("content")

  echo "✓ Connected to BitBarrel server"
  echo()

  # Create content graph
  echo "Building content graph..."

  # Articles
  let article1 = %*{
    "title": "Getting Started with BitBarrel",
    "author": "Alice",
    "published": "2024-01-15",
    "_refs": {
      "tags": ["tag:nosql", "tag:database", "tag:tutorial"],
      "related": ["article:2", "article:3"],
      "comments": ["comment:1_1", "comment:1_2"]
    }
  }
  client.set("article:1", $article1)

  let article2 = %*{
    "title": "Advanced Bitcask Techniques",
    "author": "Bob",
    "published": "2024-01-20",
    "_refs": {
      "tags": ["tag:nosql", "tag:performance", "tag:advanced"],
      "related": ["article:1", "article:4"],
      "comments": ["comment:2_1"]
    }
  }
  client.set("article:2", $article2)

  let article3 = %*{
    "title": "Understanding Log-Structured Merge Trees",
    "author": "Charlie",
    "published": "2024-02-01",
    "_refs": {
      "tags": ["tag:database", "tag:lsm", "tag:theory"],
      "related": ["article:1"],
      "comments": []
    }
  }
  client.set("article:3", $article3)

  let article4 = %*{
    "title": "BitBarrel in Production: A Case Study",
    "author": "Diana",
    "published": "2024-02-15",
    "_refs": {
      "tags": ["tag:case-study", "tag:production", "tag:performance"],
      "related": ["article:2"],
      "comments": ["comment:4_1", "comment:4_2", "comment:4_3"]
    }
  }
  client.set("article:4", $article4)

  # Comments
  let comment1 = %*{
    "article": "article:1",
    "author": "Eve",
    "content": "Great introduction! Very helpful.",
    "_refs": {}
  }
  client.set("comment:1_1", $comment1)

  let comment2 = %*{
    "article": "article:1",
    "author": "Frank",
    "content": "Should mention the reference model feature!",
    "_refs": {}
  }
  client.set("comment:1_2", $comment2)

  let comment3 = %*{
    "article": "article:4",
    "author": "Grace",
    "content": "Performance numbers would be helpful.",
    "_refs": {}
  }
  client.set("comment:4_1", $comment3)

  # Tags
  client.set("tag:nosql", %*{ "description": "NoSQL databases" })
  client.set("tag:database", %*{ "description": "Database technologies" })
  client.set("tag:performance", %*{ "description": "Performance optimization" })
  client.set("tag:tutorial", %*{ "description": "Tutorial articles" })

  echo "✓ Created 4 articles, 3 comments, 4 tags"
  echo()

  # Demo 1: Related articles
  echo "Demo 1: Articles related to 'Getting Started with BitBarrel'"
  echo "Path: related"
  let related = client.traversePath("article:1", "related")
  for r in related:
    let article = parseJson(r.value)
    echo fmt("  - {article["title"].getStr()}")
  echo()

  # Demo 2: Tags for an article
  echo "Demo 2: Tags for 'Getting Started with BitBarrel'"
  echo "Path: tags"
  let tags = client.traversePath("article:1", "tags")
  for t in tags:
    let tagData = parseJson(t.value)
    echo fmt("  - {tagData["description"].getStr()}")
  echo()

  # Demo 3: Find all articles with a specific tag
  echo "Demo 3: All articles tagged 'performance'"
  # Get all articles and filter by tag
  let allArticles = ["article:1", "article:2", "article:3", "article:4"]
  var performanceArticles: seq[string] = @[]

  for articleKey in allArticles:
    let refs = extractRefs(client.get(articleKey))
    if refs.hasKey("tags") and "tag:performance" in refs["tags"]:
      let article = parseJson(client.get(articleKey))
      performanceArticles.add(article["title"].getStr())

  for title in performanceArticles:
    echo fmt("  - {title}")
  echo()

  # Demo 4: Article recommendations (similar tags)
  echo "Demo 4: Article recommendations based on similar tags"
  echo "Path: tags->articles (simulating tag to article mapping)"
  echo "Recommendations for article:1 readers:"

  let articleTags = client.traversePath("article:1", "tags")
  var recommendations: seq[string] = @[]

  for tag in articleTags:
    # Find other articles with this tag
    let tagName = tag.key
    for checkKey in allArticles:
      if checkKey != "article:1":  # Don't recommend the same article
        let refs = extractRefs(client.get(checkKey))
        if refs.hasKey("tags") and tagName in refs["tags"]:
          let article = parseJson(client.get(checkKey))
          let title = article["title"].getStr()
          if title notin recommendations:
            recommendations.add(title)
            echo fmt("  - {title} (shares tag: {tagName})")
  echo()

  # Demo 5: Comment threads for an article
  echo "Demo 5: Comments on 'Getting Started with BitBarrel'"
  echo "Path: comments"
  let comments = client.traversePath("article:1", "comments")
  echo fmt("  Found {comments.len} comments:"
  for c in comments:
    let comment = parseJson(c.value)
    echo fmt("    - {comment["author"].getStr()}: {comment["content"].getStr()}")
  echo()

  # Demo 6: Content graph analysis
  echo "Demo 6: Content graph analysis"

  # Count refs per article
  var stats: seq[tuple[key: string, title: string, tagCount: int,
                       relatedCount: int, commentCount: int]]

  for articleKey in allArticles:
    let article = parseJson(client.get(articleKey))
    let title = article["title"].getStr()
    let refs = extractRefs(client.get(articleKey))

    let tagCount = if refs.hasKey("tags"):
      refs["tags"].len else: 0
    let relatedCount = if refs.hasKey("related"):
      refs["related"].len else: 0
    let commentCount = if refs.hasKey("comments"):
      refs["comments"].len else: 0

    stats.add((articleKey, title, tagCount, relatedCount, commentCount))

  echo "  Article statistics:"
  for s in stats:
    echo fmt("  - {s.title}")
    echo fmt("    Tags: {s.tagCount}, Related: {s.relatedCount}, Comments: {s.commentCount}")
  echo()

  # Demo 7: Most connected content
  echo "Demo 7: Most connected content pieces"
  var totalConnections: seq[tuple[key: string, title: string, total: int]]

  for articleKey in allArticles:
    let article = parseJson(client.get(articleKey))
    let title = article["title"].getStr()
    let refs = extractRefs(client.get(articleKey))

    var total = 0
    for keys in refs.values:
      total += keys.len

    totalConnections.add((articleKey, title, total))

  # Sort by total connections
  totalConnections.sort(proc (a, b: auto): int =
    return b.total - a.total)

  echo "  Content ranked by total connections:"
  for i, tc in totalConnections:
    echo fmt("  {i+1}. {tc.title} ({tc.total} connections)")
  echo()

  # Demo 8: Tag co-occurrence analysis
  echo "Demo 8: Frequently co-occurring tags"
  var tagPairs: Table[string, int]

  for articleKey in allArticles:
    let refs = extractRefs(client.get(articleKey))
    if refs.hasKey("tags") and refs["tags"].len > 1:
      let tags = refs["tags"]
      for i in 0..<tags.len:
        for j in i+1..<tags.len:
          let pair = if tags[i] < tags[j]:
            tags[i] & "-" & tags[j]
          else:
            tags[j] & "-" & tags[i]
          tagPairs[pair] = tagPairs.getOrDefault(pair, 0) + 1

  # Show top pairs
  var sortedPairs = toSeq(tagPairs.pairs)
  sortedPairs.sort(proc (a, b: auto): int = b.val - a.val)

  echo "  Top tag co-occurrences:"
  for i, pair in sortedPairs:
    if i >= 3: break
    let tags = pair.key.split("-")
    echo fmt("  - {tags[0]} + {tags[1]} (appears together {pair.val} times)")
  echo()

  echo "=== Content Graph Demo Complete ==="
  echo()
  echo "Features demonstrated:"
  echo "✓ Related content discovery"
  echo "✓ Tag-based navigation and filtering"
  echo "✓ Content recommendations"
  echo "✓ Comment thread analysis"
  echo "✓ Content graph metrics"
  echo "✓ Tag co-occurrence analysis"

when isMainModule:
  main()
