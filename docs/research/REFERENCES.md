# BitBarrel Reference Model Documentation

## Overview

The BitBarrel Reference Model adds lightweight graph-like traversal capabilities to BitBarrel's key-value store. It allows you to store references between records and traverse them efficiently on the server side.

## Key Concepts

### Reference Storage

References are stored inline within your JSON values using a special `_refs` field:

```json
{
  "data": {
    "name": "Alice",
    "email": "alice@example.com"
  },
  "_refs": {
    "friends": ["user:1001", "user:1002", "user:1003"],
    "posts": ["post:5001", "post:5002"],
    "team": ["team:42"]
  }
}
```

**Key characteristics:**
- References are stored as simple string keys
- Multiple relationship types per record
- Full control over relationship management (bidirectional refs must be maintained by your application)
- No separate edge tables or complex graph structures

## Path Expression Syntax

The reference model uses a simple path expression syntax for traversals:

### Basic Paths

```
friends                    # Follow only 'friends' references
friends->team              # Two-level traversal
friends->team->matches     # Multi-level traversal
```

### Wildcards

```
*                          # Follow all reference types
*->comments               # Comments from any relationship
```

### Array Slicing

```
friends[0]                 # First friend only
friends[-1]                # Last friend (negative indexing)
friends[0:5]               # First 5 friends (range)
posts[5:]                  # Posts from index 5 to end
```

### Complex Examples

```
friends[0:5]->posts[0:10]      # First 5 friends' first 10 posts
team->matches[-1]->players     # Latest match players
*->comments[0:3]              # First 3 comments from any source
```

## API Usage

### Client Library

```nim
import bitbarrel, network/client

# Connect to server
var client = newClient("localhost", 9876.Port)
client.useBarrel("mydb")

# Store data with references
let user1 = """{
  "data": {"name": "Alice"},
  "_refs": {
    "friends": ["user:2", "user:3"],
    "team": ["team:1"]
  }
}"""
client.set("user:1", user1)

# Simple path traversal
let results = client.traversePath("user:1", "friends->team->matches")
for r in results:
  echo fmt("Found: {r.path} = {r.key}")

# With options
let options = TraverseOptions(
  includeFullData: true,  # Return full values
  extractArrays: false,    # Keep arrays intact
  firstOnly: false         # Return all results
)
let posts = client.traverse("user:1", "friends[0:5]->posts[-1]", options)
```

### REST API

```http
# Basic traversal
GET /barrels/mydb/traverse/user:1?path=friends->team->matches

# With options
GET /barrels/mydb/traverse/user:1?path=friends[0:5]&includeData=true&firstOnly=false

# Response
{
  "startKey": "user:1",
  "pathSpec": "friends->team->matches",
  "resultsCount": 3,
  "results": [
    {
      "path": "user:1->friends->user:2->team->team:1->matches->match:7",
      "key": "match:7",
      "value": "{...}"
    }
  ]
}
```

### Binary Protocol

```nim
# Low-level binary protocol usage
import network/protocol

# Build traversal request
var options: uint8 = 0x01  # includeFullData
let tReq = TraverseRequest(
  seq: 1,
  key: "user:1",
  pathSpec: "friends->team->matches",
  options: options
)

# Encode and send
let encoded = encodeTraverseRequest(tReq)
let req = Request(command: cmdTraverse, value: encoded)
```

## Performance Considerations

### Server-Side Benefits

- **Single round-trip**: Complex traversals complete in one request
- **No network overhead**: All traversal happens on the server
- **Fast local I/O**: Direct access to storage
- **Built-in caching**: Path expressions can be cached

### Expected Performance

```
Reference extraction: ~1-2μs per record (JSON parse)
Traversal: ~5-10μs per hop (network + storage)
Example: 3-level traversal of 10-node graph ≈ 30-50μs
```

### Limits

- Max traversal depth: 5-10 levels (configurable)
- Max results per query: 1000 records (prevent runaway)
- Reference count per record: 1000 (storage efficiency)

## Use Cases

### Social Graphs

```nim
# Get user's friends
let friends = client.traversePath("user:alice", "friends")

# Friends of friends (2 levels)
let fof = client.traversePath("user:alice", "friends->friends")

# Common interests
let interests = client.traversePath("user:alice", "friends->interests")
```

### Hierarchical Data

```nim
# Navigate org chart
team = client.traversePath("employee:ceo", "direct_reports->team")

# File system traversal
files = client.traversePath("dir:root", "subdirs->files[0:10]")
```

### Content Relationships

```nim
# Get recent comments on user's posts
comments = client.traverse("user:alice", "posts[-5:]->comments", options)

# Related content
tags = client.traversePath("article:123", "tags->articles")
```

## Best Practices

### Data Modeling

1. **Keep refs up to date**: When you update relationships, update both sides if bidirectional
2. **Use meaningful types**: Choose clear relationship names (`"author"` vs `"user"`)
3. **Avoid deep nesting**: More than 3-4 levels becomes hard to maintain
4. **Limit ref counts**: Consider pagination for large collections

### Query Optimization

1. **Use specific paths**: `friends->team` is faster than `*->*`
2. **Slice early**: `friends[0:5]->posts` better than `friends->posts[0:5]`
3. **Path-only queries**: When you don't need data, set `includeFullData=false`
4. **First-only**: Use `firstOnly=true` when you just need one result

### Error Handling

```nim
try:
  let results = client.traversePath("user:1", "invalid->path")
  if results.len == 0:
    echo "No results (path may be invalid or no data)"
except RefError as e:
  echo fmt("Invalid path: {e.msg}")
```

## Comparison with Other Systems

### vs SurrealDB Graph

- **Similar**: Arrow notation, path expressions, wildcards
- **Different**: No separate edge tables, refs stored inline with data
- **Trade-off**: Simpler but less powerful than full graph databases

### vs Manual Client-Side Traversal

```nim
# Client-side (N round-trips)
let user = client.get("user:1")
let friends = extractRefs(user)["friends"]
for friend in friends:
  let fdata = client.get(friend)  # N requests!

# Server-side (1 round-trip)
let results = client.traversePath("user:1", "friends")
```

## Implementation Details

### Storage Format

- References are stored in the `_refs` field of JSON values
- No changes to BitBarrel's core storage format
- Backward compatible: values without `_refs` work normally

### Protocol Extensions

- New command: `cmdTraverse = 0x20`
- Request format: `[seq:4][keyLen:2][key][pathLen:2][path][options:1]`
- Response format: Array of results with paths and optional values

### Thread Safety

All reference operations are thread-safe and can be used concurrently.

## Cycle Detection

The reference model includes built-in cycle detection to prevent infinite loops during graph traversal. This ensures that traversals complete even when circular references exist in the data.

### How It Works

**Path Tracking**: The traversal algorithm maintains a path of visited keys (sequence of strings).

**Cycle Check**: Before following a reference to a new key, the system checks if that key already exists in the current path:

```nim
proc detectCycle*(path: seq[string], nextKey: string): bool =
  ## Returns true if nextKey would create a cycle in the path
  result = nextKey in path
```

**Complexity**: Simple O(n) membership check where n is the current path length (typically small).

**Implementation Location**: `src/bitbarrel/refs.nim` (lines 181-184)

### Example Scenario

Consider a social graph where users follow each other:
- User A follows User B
- User B follows User C
- User C follows User A (creates a cycle)

Traversal path: `["user:A", "user:B", "user:C"]`
Next key: `"user:A"` (already in path) → **cycle detected, traversal stops**

### Behavior When Cycles Are Detected

1. **Traversal stops** at the cycle-creating reference
2. **Path is recorded** showing the circular reference
3. **Results include** all nodes visited before the cycle
4. **No infinite loop** - traversal completes predictably

### Configuration

Cycle detection is always enabled and cannot be disabled (safety feature).

### Performance Impact

- **Minimal overhead**: O(n) check with small n (path length)
- **Memory efficient**: Path stored as sequence of string references
- **No additional I/O**: Pure in-memory operation

## Troubleshooting

### Common Issues

**No results returned**
- Check that the starting key exists
- Verify `_refs` field is present and valid JSON
- Ensure relationship types match exactly (case-sensitive)

**Performance issues**
- Reduce traversal depth
- Use more specific paths (avoid wildcards)
- Add array slicing to limit result sets
- Set `includeFullData=false` for path-only queries

**Circular references**
- Built-in cycle detection prevents infinite loops
- Each node visited only once per traversal
- Path shows cycles as repeated keys

## Future Enhancements

Potential future additions:
- Predicate filtering during traversal
- Weighted relationship support
- Graph analytics (shortest path, centrality)
- Async streaming results for large traversals
- Reference indexing for faster lookups

## Summary

The BitBarrel Reference Model provides a lightweight, efficient way to add graph-like capabilities to your key-value store without the complexity of a full graph database. It excels at:

- Social graphs and networks
- Hierarchical data navigation
- Relationship discovery
- Content recommendation engines

The design prioritizes simplicity, performance, and backward compatibility while enabling powerful traversal capabilities.
