## Presence Manager - Join/leave events and heartbeat tracking
##
## Manages:
## - Client presence per topic (who's online)
## - Join/leave event broadcasting
## - Heartbeat tracking and cleanup of stale clients

import std/[tables, locks, sets, times, strformat, os, json, sequtils]
import std/options
import sunny
import ./pubsub
import ./eventbroker

type
  ## Thread arguments for presence cleanup
  PresenceCleanupArgs* = object
    manager*: ptr PresenceManager
    running*: ptr bool

  ## Presence Manager
  PresenceManager* = ref PresenceManagerObj
  PresenceManagerObj {.acyclic.} = object
    ## Per-topic presence
    presence*: Table[string, PresenceInfo]  ## topic -> PresenceInfo
    presenceLock*: Lock

    ## Heartbeat tracking
    heartbeatTracker*: HeartbeatTracker

    ## Event broker for broadcasting presence events
    eventBroker*: EventBroker

    ## Cleanup thread
    cleanupThread*: ref Thread[PresenceCleanupArgs]
    threadRunning*: bool
    threadLock*: Lock

    ## Configuration
    checkIntervalMs*: int    ## Default: 5000 (5s)
    heartbeatTimeoutMs*: int ## Default: 30000 (30s)

proc cleanupWorker(args: PresenceCleanupArgs) {.thread.} =
  ## Background thread that removes stale clients

  # Cast the pointer back to PresenceManager ref
  let manager = cast[PresenceManager](args.manager)
  var running = cast[ptr bool](args.running)

  echo "[Presence] Cleanup worker started"

  while running[]:
    os.sleep(manager.checkIntervalMs)

    # Remove stale clients
    let stale = manager.heartbeatTracker.removeStaleClients()

    if stale.len > 0:
      echo fmt"[Presence] Found {stale.len} stale clients"

      withLock manager.presenceLock:
        # Remove from all topic presence
        for clientId in stale:
          for topic, info in manager.presence:
            let idStr = $clientId
            if idStr in info.members:
              # Broadcast leave event
              let member = info.members[idStr]
              if manager.eventBroker != nil:
                try:
                  discard manager.eventBroker.publishPresence(
                    topic, peLeave, clientId, member.username
                  )
                except CatchableError as e:
                  echo fmt"[Presence] Error broadcasting leave: {e.msg}"

              # Remove from presence
              discard info.removeMember(clientId)

  echo "[Presence] Cleanup worker stopped"

proc newPresenceManager*(eventBroker: EventBroker = nil,
                         checkIntervalMs: int = 5000,
                         heartbeatTimeoutMs: int = 30000): PresenceManager =
  ## Create a new presence manager

  result = PresenceManager(
    presence: initTable[string, PresenceInfo](),
    presenceLock: Lock(),

    heartbeatTracker: newHeartbeatTracker(heartbeatTimeoutMs, checkIntervalMs),

    eventBroker: eventBroker,

    threadRunning: false,
    threadLock: Lock(),

    checkIntervalMs: checkIntervalMs,
    heartbeatTimeoutMs: heartbeatTimeoutMs
  )
  initLock(result.presenceLock)
  initLock(result.threadLock)

proc startCleanupThread*(manager: PresenceManager) =
  ## Start the background cleanup thread

  withLock manager.threadLock:
    if manager.threadRunning:
      return

    # Allocate thread object if not already allocated
    if manager.cleanupThread == nil:
      manager.cleanupThread = new(Thread[PresenceCleanupArgs])

    # Get pointer to the object that the ref points to
    var args = PresenceCleanupArgs(
      manager: cast[ptr PresenceManager](cast[pointer](manager)),
      running: addr manager.threadRunning
    )
    manager.threadRunning = true

    try:
      createThread(manager.cleanupThread[], cleanupWorker, args)
    except ResourceExhaustedError as e:
      echo fmt"[Presence] Failed to start cleanup thread: {e.msg}"
      manager.threadRunning = false

proc stopCleanupThread*(manager: PresenceManager) =
  ## Stop the background cleanup thread

  withLock manager.threadLock:
    if manager.threadRunning:
      manager.threadRunning = false

  # Wait for thread to finish
  if manager.cleanupThread != nil:
    joinThread(manager.cleanupThread[])

proc joinTopic*(manager: PresenceManager, topic: string,
                clientId: uint64, username: string,
                metadata: RawJson = RawJson("{}")): bool =
  ## Client joins a topic, notifies other subscribers

  withLock manager.presenceLock:
    # Get or create presence info
    if topic notin manager.presence:
      manager.presence[topic] = newPresenceInfo(topic)

    let info = manager.presence[topic]

    # Check if already a member
    let idStr = $clientId
    if idStr in info.members:
      # Update metadata if provided
      if metadata.string.len > 0 and metadata.string != "{}":
        info.members[idStr].metadata = metadata
      return false

    # Add member
    info.addMember(clientId, username, metadata)

    # Broadcast join event
    if manager.eventBroker != nil:
      try:
        discard manager.eventBroker.publishPresence(
          topic, peJoin, clientId, username
        )
      except CatchableError as e:
        echo fmt"[Presence] Error broadcasting join: {e.msg}"

  return true

proc leaveTopic*(manager: PresenceManager, topic: string,
                 clientId: uint64): bool =
  ## Client leaves a topic, notifies other subscribers

  var member: PresenceMember

  withLock manager.presenceLock:
    if topic notin manager.presence:
      return false

    let info = manager.presence[topic]
    let idStr = $clientId

    if idStr notin info.members:
      return false

    member = info.members[idStr]

    # Broadcast leave event
    if manager.eventBroker != nil:
      try:
        discard manager.eventBroker.publishPresence(
          topic, peLeave, clientId, member.username
        )
      except CatchableError as e:
        echo fmt"[Presence] Error broadcasting leave: {e.msg}"

    # Remove member
    discard info.removeMember(clientId)

    # Clean up empty presence info
    if info.members.len == 0:
      manager.presence.del(topic)

  return true

proc leaveAllTopics*(manager: PresenceManager, clientId: uint64): int =
  ## Remove a client from all topics
  ##
  ## Returns: Number of topics the client left

  var leftCount = 0
  var topicsToLeave: seq[string]

  withLock manager.presenceLock:
    let idStr = $clientId
    for topic, info in manager.presence:
      if idStr in info.members:
        topicsToLeave.add(topic)

  for topic in topicsToLeave:
    if manager.leaveTopic(topic, clientId):
      inc leftCount

  return leftCount

proc updatePing*(manager: PresenceManager, clientId: uint64): bool =
  ## Update the last ping timestamp for a client

  withLock manager.presenceLock:
    for topic, info in manager.presence:
      if info.updatePing(clientId):
        # Also update heartbeat tracker
        manager.heartbeatTracker.updateHeartbeat(clientId)
        return true

  return false

proc updateMetadata*(manager: PresenceManager, topic: string,
                     clientId: uint64, metadata: RawJson) =
  ## Update client metadata for a topic

  withLock manager.presenceLock:
    if topic in manager.presence:
      let info = manager.presence[topic]
      let idStr = $clientId
      if idStr in info.members:
        info.members[idStr].metadata = metadata
        info.lastUpdate = toUnix(getTime()) * 1000

        # Broadcast update event
        if manager.eventBroker != nil:
          try:
            discard manager.eventBroker.publishPresence(
              topic, peUpdate, clientId, info.members[idStr].username
            )
          except CatchableError as e:
            echo fmt"[Presence] Error broadcasting update: {e.msg}"

proc getPresence*(manager: PresenceManager, topic: string): Option[PresenceInfo] =
  ## Get presence info for a topic

  withLock manager.presenceLock:
    if topic in manager.presence:
      return some(manager.presence[topic])
    return none(PresenceInfo)

proc getAllPresence*(manager: PresenceManager): Table[string, PresenceInfo] =
  ## Get presence info for all topics

  withLock manager.presenceLock:
    result = manager.presence

proc getTopicsWithPresence*(manager: PresenceManager): seq[string] =
  ## Get list of topics that have presence info

  withLock manager.presenceLock:
    return toSeq(manager.presence.keys)

proc cleanupEmptyTopics*(manager: PresenceManager): int =
  ## Remove topics with no active members
  ##
  ## Returns: Number of topics removed

  var removedCount = 0
  var topicsToRemove: seq[string]

  withLock manager.presenceLock:
    for topic, info in manager.presence:
      if info.members.len == 0:
        topicsToRemove.add(topic)

  for topic in topicsToRemove:
    withLock manager.presenceLock:
      if topic in manager.presence and manager.presence[topic].members.len == 0:
        manager.presence.del(topic)
        inc removedCount

  return removedCount

proc getPresenceStats*(manager: PresenceManager): tuple[
  topicCount: int,
  totalMembers: int,
  uniqueClients: int
] =
  ## Get statistics about presence

  var totalMembers = 0
  var uniqueClients = initHashSet[uint64]()
  var topicCount = 0
  withLock manager.presenceLock:
    topicCount = manager.presence.len

    for _, info in manager.presence:
      totalMembers += info.members.len
      for _, member in info.members:
        uniqueClients.incl(member.clientId)

  return (
    topicCount: topicCount,
    totalMembers: totalMembers,
    uniqueClients: uniqueClients.len
  )

proc cleanup*(manager: PresenceManager) =
  ## Clean up resources (call during shutdown)

  manager.stopCleanupThread()

  withLock manager.presenceLock:
    manager.presence.clear()

  # Clear heartbeat tracker
  #withLock manager.heartbeatTracker.clientLastSeen:
  #  manager.heartbeatTracker.clientLastSeen.clear()
