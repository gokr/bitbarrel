## Redis-style glob pattern matching for BitBarrel pub/sub
##
## Supports:
## - Exact matching: `chat:room1` matches `chat:room1` only
## - Wildcard matching: `*` matches any sequence of characters
## - Prefix patterns: `user:*` matches `user:1000`, `user:name`, etc.
## - Multiple wildcards: `user:*:profile` matches `user:1000:profile`

import std/[strutils, sequtils, tables, locks]

proc matchesPattern*(topic: string, pattern: string): bool =
  ## Check if topic matches Redis-style glob pattern
  ##
  ## Examples:
  ##   - `"chat:123"` matches `"chat:*"` → true
  ##   - `"user:1000:profile"` matches `"user:*:profile"` → true
  ##   - `"chat:room:123"` matches `"chat:*"` → false (only one wildcard)
  ##   - `"chat:room:123"` matches `"chat:*:*"` → true
  ##   - `"any"` matches `"*"` → true
  ##   - `"exact"` matches `"exact"` → true

  if pattern == "*":
    return true  # Wildcard matches everything

  if not pattern.contains('*'):
    return topic == pattern  # Exact match

  # Split pattern by wildcard
  let parts = pattern.split('*')

  # Filter out empty parts (from consecutive wildcards or leading/trailing)
  let nonEmptyParts = parts.filterIt(it.len > 0)

  if nonEmptyParts.len == 0:
    # Pattern is all wildcards, matches everything
    return true

  # Pattern must start with non-wildcard if topic doesn't start with wildcard
  if not pattern.startsWith('*'):
    if not topic.startsWith(nonEmptyParts[0]):
      return false

  # Pattern must end with non-wildcard if topic doesn't end with wildcard
  if not pattern.endsWith('*'):
    if not topic.endsWith(nonEmptyParts[^1]):
      return false

  # Check that all non-wildcard parts appear in order in the topic
  var searchPos = 0
  for part in nonEmptyParts:
    let pos = topic.find(part, searchPos)
    if pos == -1:
      return false
    searchPos = pos + part.len

  return true

proc extractTopicParts*(topic: string, delimiter: string = ":"): seq[string] =
  ## Extract parts from a topic string
  ##
  ## Example: `"user:1000:profile"` → `@["user", "1000", "profile"]`
  topic.split(delimiter)

proc buildTopic*(parts: varargs[string], delimiter: string = ":"): string =
  ## Build a topic from parts
  parts.join(delimiter)

proc patternHasWildcards*(pattern: string): bool =
  ## Check if pattern contains wildcards
  pattern.contains('*')

proc isExactMatchPattern*(pattern: string): bool =
  ## Check if pattern is an exact match (no wildcards)
  not patternHasWildcards(pattern)

proc validatePattern*(pattern: string): bool =
  ## Validate a topic pattern
  ##
  ## Rules:
  ## - Must not be empty
  ## - Must not exceed 1024 characters
  ## - Must contain printable ASCII characters
  ##
  ## Returns true if pattern is valid
  if pattern.len == 0:
    return false

  if pattern.len > 1024:
    return false

  for c in pattern:
    # Allow: alphanumeric, :, *, -, _, ., and printable ASCII
    if ord(c) < 32 or ord(c) > 126:
      return false
    # Disallow control characters and problematic ones
    if c in {'\n', '\r', '\t', '\0', '\\', '/', ' ', ','}:
      return false

  return true

proc validateTopic*(topic: string): bool =
  ## Validate a topic name
  ##
  ## Rules:
  ## - Must not be empty
  ## - Must not exceed 1024 characters
  ## - Must not contain wildcards (topics should be exact)
  ##
  ## Returns true if topic is valid
  if topic.len == 0:
    return false

  if topic.len > 1024:
    return false

  if patternHasWildcards(topic):
    return false

  return validatePattern(topic)

## Matching statistics for optimization

proc getPatternComplexity*(pattern: string): int =
  ## Estimate complexity of a pattern (0 = exact, higher = more complex)
  ##
  ## Used for pattern selection optimization
  if not patternHasWildcards(pattern):
    return 0

  result = pattern.count('*')

  # Add weight for exact prefixes/suffixes (they make matching faster)
  if pattern.startsWith('*'):
    result -= 1
  if pattern.endsWith('*'):
    result -= 1

  # Ensure non-negative
  if result < 0:
    result = 0

## Pattern cache optimization

type
  PatternCache* = ref PatternCacheObj
  PatternCacheObj = object
    cachedPatterns: Table[string, seq[string]]  ## pattern -> split parts
    cacheLock: Lock

proc newPatternCache*(): PatternCache =
  ## Create a new pattern cache for optimization
  result = PatternCache(
    cachedPatterns: initTable[string, seq[string]](),
    cacheLock: Lock()
  )
  initLock(result.cacheLock)

proc getPatternParts*(cache: PatternCache, pattern: string): seq[string] =
  ## Get split parts of a pattern (cached for performance)
  withLock cache.cacheLock:
    if pattern in cache.cachedPatterns:
      return cache.cachedPatterns[pattern]

    let parts = pattern.split('*').filterIt(it.len > 0)
    cache.cachedPatterns[pattern] = parts
    return parts

proc clearCache*(cache: PatternCache) =
  ## Clear the pattern cache
  withLock cache.cacheLock:
    cache.cachedPatterns.clear()
