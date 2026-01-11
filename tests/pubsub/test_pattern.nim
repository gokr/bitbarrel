## Test Pattern Matching Module
##
## Tests for Redis-style glob pattern matching used in pub/sub subscriptions

import std/[unittest, strutils]
import ../../src/pubsub/pattern

suite "Pattern Matching":
  test "exact match works":
    check matchesPattern("chat:room1", "chat:room1")
    check not matchesPattern("chat:room1", "chat:room2")
    check not matchesPattern("chat:room1:private", "chat:room1")

  test "wildcard * matches everything":
    check matchesPattern("anything", "*")
    check matchesPattern("user:1000", "*")
    check matchesPattern("", "*")
    check matchesPattern("complex:topic:with:many:parts", "*")

  test "prefix wildcard user:*":
    check matchesPattern("user:1000", "user:*")
    check matchesPattern("user:1000:profile", "user:*")
    check matchesPattern("user:alice", "user:*")
    check not matchesPattern("users:1000", "user:*")
    check not matchesPattern("admin:1000", "user:*")

  test "suffix wildcard *:profile":
    check matchesPattern("user:1000:profile", "*:profile")
    check matchesPattern("admin:alice:profile", "*:profile")
    check not matchesPattern("user:1000:settings", "*:profile")
    check not matchesPattern("profile", "*:profile")

  test "multi-part wildcard user:*:profile":
    check matchesPattern("user:1000:profile", "user:*:profile")
    check matchesPattern("user:alice:profile", "user:*:profile")
    check not matchesPattern("user:1000", "user:*:profile")
    check not matchesPattern("user:1000:settings", "user:*:profile")
    check not matchesPattern("admin:1000:profile", "user:*:profile")

  test "multiple wildcards user:*:*":
    check matchesPattern("user:1000:profile", "user:*:*")
    check matchesPattern("user:alice:settings", "user:*:*")
    check matchesPattern("user:1000:profile:public", "user:*:*")
    check not matchesPattern("user:1000", "user:*:*")

  test "complex pattern kv:*:profile":
    check matchesPattern("kv:mydb:profile", "kv:*:profile")
    check matchesPattern("kv:production:profile", "kv:*:profile")
    check not matchesPattern("kv:mydb:settings", "kv:*:profile")

  test "pattern validation rejects empty":
    check not validatePattern("")

  test "pattern validation rejects spaces":
    check not validatePattern("topic with spaces")
    check not validatePattern("topic\twith\ttabs")

  test "pattern validation rejects control characters":
    check not validatePattern("topic\nwith\nnewlines")
    check not validatePattern("topic\rwith\rcarriage")
    check not validatePattern("topic\0with\0nulls")

  test "pattern validation rejects invalid characters":
    check not validatePattern("topic,with,commas")
    check not validatePattern("topic/with/slashes")
    check not validatePattern("topic\\with\\backslashes")

  test "pattern validation accepts valid patterns":
    check validatePattern("user:*")
    check validatePattern("kv:mydb:*")
    check validatePattern("chat:room1")
    check validatePattern("user:1000:profile")
    check validatePattern("*")
    check validatePattern("topic-with-dashes")
    check validatePattern("topic_with_underscores")
    check validatePattern("topic.with.dots")

  test "pattern validation rejects too long":
    let longPattern = "a".repeat(1025)
    check not validatePattern(longPattern)

  test "topic validation rejects wildcards":
    check not validateTopic("user:*")
    check not validateTopic("*")
    check not validateTopic("kv:*:profile")

  test "topic validation accepts valid topics":
    check validateTopic("chat:room1")
    check validateTopic("user:1000:profile")
    check validateTopic("kv:mydb:key1")

  test "topic validation rejects empty":
    check not validateTopic("")

  test "topic validation rejects too long":
    let longTopic = "a".repeat(1025)
    check not validateTopic(longTopic)

  test "pattern complexity calculation":
    check getPatternComplexity("exact:topic") == 0
    check getPatternComplexity("*") >= 0
    check getPatternComplexity("prefix:*") >= 0
    check getPatternComplexity("*:suffix") >= 0
    check getPatternComplexity("prefix:*:suffix") >= 1

  test "pattern has wildcards detection":
    check patternHasWildcards("user:*")
    check patternHasWildcards("*")
    check patternHasWildcards("kv:*:profile")
    check not patternHasWildcards("exact:topic")

  test "exact match pattern detection":
    check isExactMatchPattern("exact:topic")
    check isExactMatchPattern("user:1000")
    check not isExactMatchPattern("user:*")
    check not isExactMatchPattern("*")

  test "extract topic parts":
    let parts1 = extractTopicParts("user:1000:profile")
    check parts1 == @["user", "1000", "profile"]

    let parts2 = extractTopicParts("chat:room1")
    check parts2 == @["chat", "room1"]

    let parts3 = extractTopicParts("simple")
    check parts3 == @["simple"]

  test "build topic from parts":
    let topic1 = buildTopic("user", "1000", "profile", delimiter = ":")
    check topic1 == "user:1000:profile"

    let topic2 = buildTopic("chat", "room1", delimiter = ":")
    check topic2 == "chat:room1"

  test "pattern cache stores parts":
    let cache = newPatternCache()
    let parts1 = cache.getPatternParts("user:*:profile")
    check parts1 == @["user:", ":profile"]

    let parts2 = cache.getPatternParts("kv:*")
    check parts2 == @["kv:"]

    # Verify cached (should be same instance)
    let parts3 = cache.getPatternParts("user:*:profile")
    check parts3 == @["user:", ":profile"]

  test "pattern cache clear":
    let cache = newPatternCache()
    discard cache.getPatternParts("user:*")
    discard cache.getPatternParts("kv:*")

    cache.clearCache()

    # After clear, still works
    let parts = cache.getPatternParts("user:*")
    check parts == @["user:"]

  test "edge case: consecutive wildcards":
    check matchesPattern("user:1000:profile", "user:**")
    check matchesPattern("anything", "***")

  test "edge case: wildcard at both ends":
    check matchesPattern("user:1000:profile", "*:profile")
    check matchesPattern("user:1000:profile", "user:*")
    check matchesPattern("user:1000:profile", "*")

  test "edge case: pattern with only wildcard parts":
    check matchesPattern("user:1000", "*:*")
    check matchesPattern("a:b:c:d", "*:*:*:*")

  test "regression: kv topic matching":
    # Regression test for k/v change events
    check matchesPattern("kv:mydb:user:1000", "kv:mydb:*")
    check matchesPattern("kv:production:settings", "kv:*:settings")
    check matchesPattern("kv:test:key", "kv:*")
