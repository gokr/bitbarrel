## Storage Backend Interface for Pub/Sub History
##
## Defines abstract interface for pluggable history storage strategies
## Supports memory-only, shared barrel, per-topic barrel, and future backends

import ./pubsub

type
  ## Query parameters for retrieving history
  HistoryQueryParams* = object
    limit*: int           ## Max messages to return (0 = unlimited)
    sinceSeq*: uint64     ## Return messages with sequence >= this
    beforeSeq*: uint64    ## Return messages with sequence < this
    sinceTime*: int64     ## Return messages after timestamp (ms)
    cursor*: string       ## Cursor-based pagination support

  ## Result of history query
  HistoryQueryResult* = object
    messages*: seq[Message]    ## Retrieved messages
    nextCursor*: string        ## Cursor for next page (empty if no more)
    hasMore*: bool             ## Whether more messages available

  ## Abstract storage backend for message history
  ## All backends must implement these operations
  HistoryStorageBackend* = ref object of RootObj
    ## Base type for all storage strategies
    name*: string           ## Backend name for logging
    isPersistent*: bool     ## Whether backend persists to disk

## Storage backend operations - must be implemented by all backends

method store*(backend: HistoryStorageBackend, topic: string,
              message: Message): bool {.base, gcsafe.} =
  ## Store a message in history
  ##
  ## Parameters:
  ##   - topic: Topic name
  ##   - message: Message to store (will update sequence)
  ##
  ## Returns: true on success, false on failure
  raise newException(CatchableError, "store not implemented")

method retrieve*(backend: HistoryStorageBackend, topic: string,
                 params: HistoryQueryParams): seq[Message] {.base, gcsafe.} =
  ## Retrieve messages from history
  ##
  ## Parameters:
  ##   - topic: Topic name
  ##   - params: Query parameters (limit, sinceSeq, etc.)
  ##
  ## Returns: Sequence of messages matching query
  raise newException(CatchableError, "retrieve not implemented")

method clear*(backend: HistoryStorageBackend, topic: string): bool {.base, gcsafe.} =
  ## Clear all history for a topic
  ##
  ## Parameters:
  ##   - topic: Topic name to clear
  ##
  ## Returns: true if history was cleared
  raise newException(CatchableError, "clear not implemented")

method count*(backend: HistoryStorageBackend, topic: string): int {.base, gcsafe.} =
  ## Get the number of messages stored for a topic
  ##
  ## Parameters:
  ##   - topic: Topic name
  ##
  ## Returns: Message count (0 if topic has no history)
  raise newException(CatchableError, "count not implemented")

method close*(backend: HistoryStorageBackend) {.base, gcsafe.} =
  ## Close backend and cleanup resources
  ## Should be called during shutdown
  discard

## Optional operations (implemented where appropriate)

method supportsTtl*(backend: HistoryStorageBackend): bool {.base, gcsafe.} =
  ## Check if backend supports automatic TTL/expiration
  ##
  ## Returns: true if backend can auto-expire messages
  false

method configureTtl*(backend: HistoryStorageBackend, topic: string,
                     ttlSeconds: int) {.base, gcsafe.} =
  ## Configure TTL for a topic (if supported by backend)
  ##
  ## Parameters:
  ##   - topic: Topic name
  ##   - ttlSeconds: TTL in seconds (0 = no TTL)
  discard

method getMemoryUsage*(backend: HistoryStorageBackend): tuple[
  topics: int,
  messages: int,
  bytes: int
] {.base, gcsafe.} =
  ## Get memory usage estimate
  ##
  ## Returns: (topic count, message count, estimated bytes)
  (0, 0, 0)

## Helper operations that can be overridden for optimization

method storeBatch*(backend: HistoryStorageBackend, topic: string,
                   messages: seq[Message]): bool {.base, gcsafe.} =
  ## Store multiple messages in batch (default: call store() for each)
  ##
  ## Parameters:
  ##   - topic: Topic name
  ##   - messages: Messages to store
  for msg in messages:
    if not backend.store(topic, msg):
      return false
  true
