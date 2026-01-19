## BitBarrel Network Server
##
## WebSocket/HTTP server built on MummyX for remote BitBarrel access

import std/[net, locks, tables, strutils, os, sequtils, strformat, times, json]
import mummy
import mummy/routers
import session
import auth as authjwt
import ../bitbarrel/barrel
import ../storage/hugebarrel
import ../bitbarrel/refs
import ../bitbarrel/config_json
import metrics
import ../pubsub/pubsub
import ../pubsub/manager
import ../pubsub/eventbroker
import ../pubsub/presence
import ../pubsub/barrel_hooks
import ../pubsub/history_v2
import ../pubsub/storage_manager
import ../plugins/query_result_hooks

# Import protocol module
import protocol
# Alias to avoid conflict with mummy.Request
type ProtoRequest = protocol.Request

# Helper procs for working with BarrelWrapper
proc wrapperGet(wrapper: BarrelWrapper, key: string): string =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.get(key)
  of bkHuge:
    wrapper.hugeBarrel.get(key)

proc wrapperSet(wrapper: var BarrelWrapper, key: string, value: string, ttl: int = -1): bool =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.set(key, value, ttl)
  of bkHuge:
    wrapper.hugeBarrel.set(key, value)

proc wrapperDelete(wrapper: var BarrelWrapper, key: string): bool =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.delete(key)
  of bkHuge:
    wrapper.hugeBarrel.delete(key)

proc wrapperExists(wrapper: BarrelWrapper, key: string): bool =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.exists(key)
  of bkHuge:
    wrapper.hugeBarrel.exists(key)

proc wrapperCount(wrapper: BarrelWrapper): int =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.count()
  of bkHuge:
    # HugeBarrel doesn't have an efficient count operation
    0

proc wrapperGetConfig(wrapper: BarrelWrapper): BarrelConfig =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.getConfig()
  of bkHuge:
    # HugeBarrel stores config differently - return a basic one
    var config = defaultBarrelConfig()
    config.mode = bmHugeCritBit
    config

proc wrapperSetConfig(wrapper: BarrelWrapper, config: BarrelConfig) =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.setConfig(config)
  of bkHuge:
    # HugeBarrel doesn't support setConfig - this is a limitation
    discard

proc wrapperGetStats(wrapper: BarrelWrapper): BarrelStats =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.getStats()
  of bkHuge:
    # HugeBarrel doesn't have full stats - return a basic one
    var stats: BarrelStats
    stats.indexMode = "bmHugeCritBit"
    return stats

proc wrapperListKeys(wrapper: BarrelWrapper, limit: int = 1000, offset: int = 0): seq[string] =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.listKeys(limit, offset)
  of bkHuge:
    # HugeBarrel doesn't support listKeys - return empty
    @[]

proc wrapperItemsInRange(wrapper: BarrelWrapper, startKey: string, endKey: string, limit: int = 1000, cursor: string = ""): (seq[(string, string)], string, bool) =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.itemsInRange(startKey, endKey, limit, cursor)
  of bkHuge:
    # HugeBarrel doesn't support itemsInRange yet - return empty
    (@[], "", false)

proc wrapperItemsWithPrefix(wrapper: BarrelWrapper, prefix: string, limit: int = 1000, cursor: string = ""): (seq[(string, string)], string, bool) =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.itemsWithPrefix(prefix, limit, cursor)
  of bkHuge:
    # HugeBarrel doesn't support itemsWithPrefix yet - return empty
    (@[], "", false)

proc wrapperKeysInRange(wrapper: BarrelWrapper, startKey: string, endKey: string, limit: int = 1000, offset: int = 0): seq[string] =
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.keysInRange(startKey, endKey, limit, offset)
  of bkHuge:
    # HugeBarrel doesn't support keysInRange - return empty
    @[]

proc wrapperKeysInRangeCursor(wrapper: BarrelWrapper, startKey: string, endKey: string,
                              limit: int = 1000, cursor: string = ""): (seq[string], string, bool) =
  ## Keys-only range query with cursor-based pagination
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.keysByRange(startKey, endKey, limit, cursor)
  of bkHuge:
    # HugeBarrel doesn't support keysByRange - return empty
    (@[], "", false)

proc wrapperKeysWithPrefix(wrapper: BarrelWrapper, prefix: string,
                           limit: int = 1000, cursor: string = ""): (seq[string], string, bool) =
  ## Keys-only prefix query with cursor-based pagination
  case wrapper.kind
  of bkRegular:
    wrapper.regularBarrel.keysByPrefix(prefix, limit, cursor)
  of bkHuge:
    # HugeBarrel doesn't support keysByPrefix - return empty
    (@[], "", false)

type
  BitBarrelServerObj* = object
    registry*: BarrelRegistry         ## All open barrels
    sessions*: Table[uint64, Session] ## WebSocket client -> session
    webSockets*: Table[uint64, WebSocket] ## WebSocket client ID -> WebSocket (stored during OpenEvent)
    mummyServer: Server
    config*: ServerConfig              ## Server configuration (public for tests)
    sessionsLock*: Lock               ## Lock for sessions and webSockets tables
    seqCounter: uint64                ## Global seq counter for requests
    startTime: float                  ## Server start time (epochTime)
    metrics*: MetricsCollector        ## Metrics collector for monitoring

    # Pub/Sub system components
    pubSubManager*: PubSubManager     ## Pub/sub topic and subscription manager
    eventBroker*: EventBroker         ## Event routing to WebSocket clients
    presenceManager*: PresenceManager ## Presence tracking (join/leave, heartbeat)
    historyStore*: HistoryStoreV2       ## Message history (in-memory or persistent)
    pubSubEnabled*: bool              ## Whether pub/sub is enabled

  BitBarrelServer* = ref BitBarrelServerObj  # Use ref to avoid ORC cleanup issues

  ServerConfig* = object
    address*: string       ## Default: "0.0.0.0"
    port*: Port           ## Default: 9876
    dataDir*: string      ## Base directory for barrels
    workerThreads*: int   ## Default: CPU * 10
    auth*: authjwt.AuthConfig  ## Authentication configuration
    webadminPath*: string ## Path to webadmin build files
    webadminEnabled*: bool ## Enable webadmin UI serving
    serverId*: string     ## Unique server identifier (auto-generated if empty)

    # Pub/Sub configuration
    pubSubEnabled*: bool              ## Enable pub/sub system (default: true)
    maxPubSubTopics*: int             ## Maximum topics (0 = unlimited)
    maxSubscriptionsPerClient*: int  ## Max subscriptions per client (0 = unlimited)
    pubSubHeartbeatTimeoutMs*: int   ## Client heartbeat timeout (default: 30000)

# Note: Avoid thread-local variables for server storage as closures capture them
# across thread boundaries, causing ORC cleanup issues.
# The server reference is now passed directly to handlers.


# Helper: URL decoding
proc decodeUrl(url: string): string =
  ## Decode URL-encoded string (percent-decoding per RFC 3986)
  result = ""
  var i = 0
  while i < url.len:
    if url[i] == '%' and i + 2 < url.len:
      let hex = url[i+1..i+2]
      try:
        let code = parseHexInt(hex)
        if code >= 0 and code <= 255:
          result.add(char(code))
          i += 3
          continue
      except ValueError:
        discard  # Fall through to add literal character
    elif url[i] == '+':
      # Plus sign means space in query strings
      result.add(' ')
      i += 1
      continue
    result.add(url[i])
    i += 1

# Static file serving for webadmin
proc getContentType*(path: string): string =
  ## Get MIME type based on file extension
  if path.endswith(".html"): return "text/html"
  if path.endswith(".css"): return "text/css"
  if path.endswith(".js"): return "application/javascript"
  if path.endswith(".json"): return "application/json"
  if path.endswith(".png"): return "image/png"
  if path.endswith(".jpg") or path.endswith(".jpeg"): return "image/jpeg"
  if path.endswith(".gif"): return "image/gif"
  if path.endswith(".svg"): return "image svg+xml"
  if path.endswith(".ico"): return "image/x-icon"
  if path.endswith(".woff2"): return "font/woff2"
  if path.endswith(".woff"): return "font/woff"
  if path.endswith(".ttf"): return "font/ttf"
  if path.endswith(".eot"): return "application/vnd.ms-fontobject"
  if path.endswith(".manifest"): return "application/json"
  if path.endswith(".wasm"): return "application/wasm"
  return "application/octet-stream"

proc serveStaticFile*(server: BitBarrelServer, request: mummy.Request) =
  ## Serve static files from webadmin directory
  {.gcsafe.}:
    if not server.config.webadminEnabled or server.config.webadminPath.len == 0:
      request.respond(404, body = "Webadmin not enabled")
      return

    # Get the file path from request
    let path = request.path
    var filePath: string

    # Handle /admin/* requests - strip /admin prefix
    if path.startsWith("/admin"):
      let suffix = path[6..^1]  # Remove /admin
      if suffix.len == 0 or suffix == "/":
        filePath = server.config.webadminPath / "index.html"
      else:
        # Remove leading slash if present
        let cleanSuffix = if suffix.startsWith("/"): suffix[1..^1] else: suffix
        filePath = server.config.webadminPath / cleanSuffix
    else:
      # Direct access
      if path == "/":
        filePath = server.config.webadminPath / "index.html"
      else:
        let cleanPath = if path.startsWith("/"): path[1..^1] else: path
        filePath = server.config.webadminPath / cleanPath

    # Security: verify path stays within webadmin directory
    # Use absolute paths for reliable comparison (absolutePath doesn't require file to exist)
    let resolvedPath = absolutePath(filePath).replace("\\", "/")
    let basePath = absolutePath(server.config.webadminPath).replace("\\", "/")

    # Ensure basePath ends with / for proper prefix matching
    let basePathWithSlash = if basePath.endsWith("/"): basePath else: basePath & "/"

    if not resolvedPath.startsWith(basePathWithSlash):
      request.respond(403, body = "Forbidden")
      return

    # Check if file exists
    if not fileExists(resolvedPath):
      request.respond(404, body = "Not Found")
      return

    try:
      let content = readFile(resolvedPath)
      var headers = emptyHttpHeaders()
      headers["Content-Type"] = getContentType(resolvedPath)
      # Let Mummy calculate Content-Length automatically
      request.respond(200, headers, content)
    except CatchableError:
      request.respond(500, body = "Error reading file")

proc serveWebadminRoot*(server: BitBarrelServer, request: mummy.Request) =
  ## Serve index.html for webadmin root (SPA fallback)
  {.gcsafe.}:
    if not server.config.webadminEnabled or server.config.webadminPath.len == 0:
      # Return simple API info for non-admin requests
      var statsJson = """
{
  "status": "ok",
  "message": "BitBarrel KVS Server",
   "webadmin": "disabled"
}"""
      var headers = emptyHttpHeaders()
      headers["Content-Type"] = "application/json"
      request.respond(200, headers, statsJson)
      return

    # Redirect root to /admin/
    var headers = emptyHttpHeaders()
    headers["Location"] = "/admin/"
    request.respond(302, headers)


proc handleWebSocketMessage*(
  server: BitBarrelServer,
  ws: mummy.WebSocket,
  data: string
) =
  ## Process a binary WebSocket message from client
  var req: ProtoRequest
  when not defined(testing):
    writeLine(stderr, "[DEBUG] handleWebSocketMessage: entered")
    flushFile(stderr)
  try:
    when not defined(testing):
      writeLine(stderr, "[DEBUG] handleWebSocketMessage: received data length=" & $data.len)
      flushFile(stderr)
    req = decodeRequest(data)
    when not defined(testing):
      writeLine(stderr, "[DEBUG] handleWebSocketMessage: seq=" & $req.seq & " command=" & $req.command)
      flushFile(stderr)
  except CatchableError as e:
    # Send error response with seq=0 since we couldn't decode the request
    let errResp = invalidResponse(0, "Invalid binary protocol: " & e.msg)
    ws.send(encodeResponse(errResp))
    return

  # Get session for this client
  var session: Session
  withLock server.sessionsLock:
    if ws.clientId notin server.sessions:
      # Auto-create session for new connection
      server.sessions[ws.clientId] = newSession(ws.clientId)
    session = server.sessions[ws.clientId]

  # Process command
  var resp: Response
  resp.seq = req.seq


  case req.command:
  of cmdPing:
    resp.status = statusOk
    resp.value = "pong"

  of cmdCreateBarrel:
    if not session.authSession.canManageBarrels():
      resp.status = statusUnauthorized
      resp.value = "Unauthorized: admin role required"
    else:
      when not defined(testing):
        echo fmt"[DEBUG] cmdCreateBarrel: name='{req.key}', configLen={req.value.len}"
      try:
        let config = if req.value.len > 0:
          parseBarrelConfigJson(req.value)
        else:
          defaultBarrelConfig()
        when not defined(testing):
          echo fmt"[DEBUG] config parsed, dataDir={server.config.dataDir}, calling createBarrel..."

        if server.registry.createBarrel(req.key, config):
          resp.status = statusOk
          when not defined(testing):
            echo fmt"[DEBUG] createBarrel succeeded for '{req.key}'"
        else:
          # Use detailed error from registry
          let errorMsg = server.registry.lastError
          # Check if barrel already exists based on error message
          if req.key in server.registry.barrels or errorMsg.contains("already exists"):
            resp.status = statusBarrelExists
            resp.value = if errorMsg.len > 0: errorMsg else: fmt"Barrel '{req.key}' already exists"
          else:
            resp.status = statusError
            resp.value = if errorMsg.len > 0: errorMsg else: fmt"Failed to create barrel '{req.key}'"
          when not defined(testing):
            echo fmt"[DEBUG] createBarrel failed for '{req.key}' (status: {resp.status}, msg: {resp.value})"
      except ConfigValidationError as e:
        resp.status = statusInvalid
        resp.value = e.msg
        when not defined(testing):
          echo fmt"[DEBUG] ConfigValidationError: {e.msg}"
      except CatchableError as e:
        resp.status = statusError
        resp.value = fmt"Failed to create barrel: {e.msg}"
        when not defined(testing):
          echo fmt"[DEBUG] createBarrel exception: {e.msg}, {e.repr}"

  of cmdOpenBarrel:
    if not session.authSession.canManageBarrels():
      resp.status = statusUnauthorized
      resp.value = "Unauthorized: admin role required"
    elif server.registry.openBarrel(req.key):
      resp.status = statusOk
    else:
      resp.status = statusBarrelNotFound

  of cmdUseBarrel:
    when not defined(testing):
      echo "cmdUseBarrel: key=" & req.key
      writeLine(stderr, fmt("[{epochTime():.3f}] cmdUseBarrel: key={req.key}"))
      flushFile(stderr)
    # Check if barrel exists
    let barrel = server.registry.getBarrel(req.key)
    if barrel.isSome():
      withLock server.sessionsLock:
        server.sessions[ws.clientId].setCurrentBarrel(req.key)
      resp.status = statusOk
    else:
      resp.status = statusBarrelNotFound

  of cmdListBarrels:
    let barrels = server.registry.listBarrels()
    resp.status = statusOk
    resp.value = barrels.join(",")

  of cmdCloseBarrel:
    if not session.authSession.canManageBarrels():
      resp.status = statusUnauthorized
      resp.value = "Unauthorized: admin role required"
    else:
      # If no key specified, close the session's current barrel
      var barrelName = req.key
      if barrelName == "":
        withLock server.sessionsLock:
          barrelName = server.sessions[ws.clientId].getCurrentBarrel()

      if barrelName != "" and server.registry.closeBarrel(barrelName):
        resp.status = statusOk
        # Clear current barrel if it was the one being closed
        withLock server.sessionsLock:
          if server.sessions[ws.clientId].getCurrentBarrel() == barrelName:
            server.sessions[ws.clientId].clearCurrentBarrel()
      else:
        resp.status = statusBarrelNotFound

  of cmdDropBarrel:
    if not session.authSession.canManageBarrels():
      resp.status = statusUnauthorized
      resp.value = "Unauthorized: admin role required"
    elif server.registry.dropBarrel(req.key):
      resp.status = statusOk
      # Clear current barrel if it was the one being dropped
      withLock server.sessionsLock:
        if server.sessions[ws.clientId].getCurrentBarrel() == req.key:
          server.sessions[ws.clientId].clearCurrentBarrel()
    else:
      resp.status = statusBarrelNotFound

  of cmdGetBarrelConfig:
    try:
      let barrel = server.registry.getBarrel(req.key)
      if barrel.isNone():
        resp.status = statusBarrelNotFound
      else:
        resp.status = statusOk
        resp.value = serializeBarrelConfig(wrapperGetConfig(barrel.get()))
    except CatchableError as e:
      resp.status = statusError
      resp.value = e.msg

  of cmdSetBarrelConfig:
    if not session.authSession.canManageBarrels():
      resp.status = statusUnauthorized
      resp.value = "Unauthorized: admin role required"
    else:
      try:
        let barrel = server.registry.getBarrel(req.key)
        if barrel.isNone():
          resp.status = statusBarrelNotFound
        else:
          # Parse JSON and apply to current config
          var wrapper = barrel.get()
          let currentConfig = wrapperGetConfig(wrapper)
          let newConfig = applyJsonUpdatesToConfig(currentConfig, req.value)

          # Validate mode hasn't changed (not allowed at runtime)
          if newConfig.mode != currentConfig.mode:
            resp.status = statusError
            resp.value = "Cannot change barrel mode at runtime"
          else:
            # Update config and persist to YAML
            wrapperSetConfig(wrapper, newConfig)
            resp.status = statusOk
            resp.value = serializeBarrelConfig(wrapperGetConfig(wrapper))
      except ConfigValidationError as e:
        resp.status = statusError
        resp.value = e.msg
      except CatchableError as e:
        resp.status = statusError
        resp.value = e.msg

  of cmdGet, cmdSet, cmdDelete, cmdExists, cmdCount, cmdListKeys:
    # These require a current barrel
    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        else:
          var wrapper = barrel.get()
          let authSess = server.sessions[ws.clientId].authSession

          case req.command:
          of cmdGet:
            let start = epochTime()
            if not authSess.canReadData():
              resp.status = statusUnauthorized
              resp.value = "Unauthorized: read access required"
            else:
              let value = wrapperGet(wrapper, req.key)
              if value.len > 0:
                server.metrics.recordOperation(opGet, stSuccess, (epochTime() - start) * 1000.0)
                resp.status = statusOk
                resp.value = value
              else:
                server.metrics.recordOperation(opGet, stFailure, (epochTime() - start) * 1000.0)
                resp.status = statusNotFound

          of cmdSet:
            let start = epochTime()
            if not authSess.canWriteData():
              resp.status = statusUnauthorized
              resp.value = "Unauthorized: write access required"
            else:
              # Extract TTL from v1.1 request (via flags byte)
              let ttl = if (ord(req.flags) and ord(rfHasTtl)) != 0: req.ttl else: -1
              if wrapperSet(wrapper, req.key, req.value, ttl):
                server.metrics.recordOperation(opSet, stSuccess, (epochTime() - start) * 1000.0)
                resp.status = statusOk
              else:
                server.metrics.recordOperation(opSet, stFailure, (epochTime() - start) * 1000.0)
                resp.status = statusError

          of cmdDelete:
            let start = epochTime()
            if not authSess.canWriteData():
              resp.status = statusUnauthorized
              resp.value = "Unauthorized: write access required"
            elif wrapperDelete(wrapper, req.key):
              server.metrics.recordOperation(opDelete, stSuccess, (epochTime() - start) * 1000.0)
              resp.status = statusOk
            else:
              server.metrics.recordOperation(opDelete, stFailure, (epochTime() - start) * 1000.0)
              resp.status = statusError

          of cmdExists:
            if wrapperExists(wrapper, req.key):
              resp.status = statusOk
              resp.value = "true"
            else:
              resp.status = statusOk
              resp.value = "false"

          of cmdCount:
            resp.status = statusOk
            resp.value = $wrapperCount(wrapper)

          of cmdListKeys:
            # TODO: Support pagination via req.value
            let keys = wrapperListKeys(wrapper)
            resp.status = statusOk
            resp.value = keys.join(",")

          of cmdPing, cmdCreateBarrel, cmdOpenBarrel, cmdUseBarrel, cmdCloseBarrel, cmdListBarrels, cmdDropBarrel:
            # These commands are handled at the outer level
            discard

          of cmdGetBarrelConfig, cmdSetBarrelConfig, cmdGetBarrelStats:
            # These commands are handled at the outer level
            discard

          of cmdRangeQuery, cmdPrefixQuery, cmdRangeCount, cmdRangeKeys, cmdPrefixKeys:
            # These commands are handled at the outer level
            discard

          of cmdBatchGet, cmdBatchSet, cmdBatchDelete:
            # Batch commands are handled at the outer level
            discard

          of cmdSubscribe, cmdUnsubscribe, cmdPublish, cmdListSubscribers, cmdHistory, cmdListTopics, cmdPresence, cmdWatchKey, cmdUnwatchKey:
            # Pub/sub commands are handled at the outer level
            discard

          of cmdTraverse:
            # Decode traversal request
            try:
              let tReq = decodeTraverseRequest(req.value)
              let pathSteps = parsePathSpec(tReq.pathSpec)
              var results: seq[protocol.TraverseResult]
              var visited = initHashSet[string]()

              proc buildResult(key: string, path: string): protocol.TraverseResult =
                result = protocol.TraverseResult(path: path, key: key)
                if (tReq.options and 0x01) != 0:  # includeFullData bit
                  result.value = wrapperGet(wrapper, key)

              proc followPath(currentKey: string, currentStep: int,
                             currentPath: seq[string]) =
                if currentStep >= pathSteps.len:
                  # Reached end of path
                  results.add(buildResult(currentKey, currentPath.join("->")))
                  if (tReq.options and 0x04) != 0:  # firstOnly bit
                    return
                  return

                if currentKey in visited:
                  return
                visited.incl(currentKey)

                let value = wrapperGet(wrapper, currentKey)
                if value.len == 0:
                  return

                let refs = extractRefs(value)
                if refs.len == 0:
                  return

                let step = pathSteps[currentStep]
                var refsToFollow: seq[string]

                if step.relType == "*":
                  # Wildcard: follow all reference types
                  for keys in refs.values:
                    refsToFollow = concat(refsToFollow, keys)
                else:
                  # Specific relationship type
                  refsToFollow = refs.getOrDefault(step.relType, @[])

                # Apply array slicing
                if step.isArraySlice:
                  refsToFollow = applySlice(refsToFollow, step.arraySlice)

                # Follow each reference
                for refKey in refsToFollow:
                  var newPath = currentPath
                  newPath.add(fmt("{step.relType}->{refKey}"))

                  if currentStep + 1 < pathSteps.len:
                    followPath(refKey, currentStep + 1, newPath)
                  else:
                    results.add(buildResult(refKey, newPath.join("->")))
                    if (tReq.options and 0x04) != 0:  # firstOnly bit
                      return

              # Start traversal
              var startPath = @[tReq.key]
              followPath(tReq.key, 0, startPath)

              # Encode and send results
              let resultData = encodeTraverseResults(results, req.seq)
              ws.send(resultData, BinaryMessage)
              return  # Skip normal response sending

            except CatchableError as e:
              resp.status = statusError
              resp.value = "Traversal error: " & e.msg

  of cmdRangeQuery:
    # Range query requires a current barrel
    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        else:
          var wrapper = barrel.get()
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
            try:
              # Decode range query request
              let params = protocol.decodeRangeRequest(req.value)

              # Execute range query
              let (items, nextCursor, hasMore) = wrapperItemsInRange(
                wrapper, params.startKey, params.endKey, params.limit, params.cursor)

              # Apply query plugins (if requested)
              var mutableItems = items
              var mutableCursor = nextCursor
              var mutableHasMore = hasMore
              if params.plugins.len > 0:
                let metadata = HookMetadata(
                  barrelName: barrelName,
                  clientId: $ws.clientId,
                  hookKind: hkRangeQuery
                )
                if not applyQueryResultPlugins(params.plugins, metadata, mutableItems, mutableCursor, mutableHasMore):
                  resp.status = statusError
                  resp.value = "Plugin not found or incompatible with query type"
                  return

              # Encode and send response
              let respData = protocol.encodeRangeResponse(
                protocol.RangeResponse(items: mutableItems, nextCursor: mutableCursor, hasMore: mutableHasMore))
              let finalResp = protocol.okResponse(req.seq, respData)
              ws.send(protocol.encodeResponse(finalResp), BinaryMessage)
              return  # Skip normal response sending

            except CatchableError as e:
              resp.status = statusError
              resp.value = "Range query error: " & e.msg

  of cmdPrefixQuery:
    # Prefix query requires a current barrel
    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        else:
          var wrapper = barrel.get()
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
            try:
              # Decode prefix query request
              let params = protocol.decodePrefixRequest(req.value)

              # Execute prefix query
              let (items, nextCursor, hasMore) = wrapperItemsWithPrefix(
                wrapper, params.prefix, params.limit, params.cursor)

              # Apply query plugins (if requested)
              var mutableItems = items
              var mutableCursor = nextCursor
              var mutableHasMore = hasMore
              if params.plugins.len > 0:
                let metadata = HookMetadata(
                  barrelName: barrelName,
                  clientId: $ws.clientId,
                  hookKind: hkPrefixQuery
                )
                if not applyQueryResultPlugins(params.plugins, metadata, mutableItems, mutableCursor, mutableHasMore):
                  resp.status = statusError
                  resp.value = "Plugin not found or incompatible with query type"
                  return

              # Encode and send response
              let respData = protocol.encodeRangeResponse(
                protocol.RangeResponse(items: mutableItems, nextCursor: mutableCursor, hasMore: mutableHasMore))
              let finalResp = protocol.okResponse(req.seq, respData)
              ws.send(protocol.encodeResponse(finalResp), BinaryMessage)
              return  # Skip normal response sending

            except CatchableError as e:
              resp.status = statusError
              resp.value = "Prefix query error: " & e.msg

  of cmdRangeCount:
    # Count query requires a current barrel
    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        else:
          var wrapper = barrel.get()
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
            try:
              # Decode count request (similar to range query format)
              let params = protocol.decodeRangeRequest(req.value)
              let count = wrapperKeysInRange(wrapper, params.startKey, params.endKey).len
              resp.status = statusOk
              resp.value = $count

            except CatchableError as e:
              resp.status = statusError
              resp.value = "Range count error: " & e.msg

  of cmdRangeKeys:
    # Keys-only range query requires a current barrel
    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        else:
          var wrapper = barrel.get()
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
            try:
              # Decode range query request
              let params = protocol.decodeRangeRequest(req.value)

              # Execute keys-only range query
              let (keys, nextCursor, hasMore) = wrapperKeysInRangeCursor(
                wrapper, params.startKey, params.endKey, params.limit, params.cursor)

              # Encode and send response
              let respData = protocol.encodeKeysResponse(
                protocol.KeysResponse(keys: keys, nextCursor: nextCursor, hasMore: hasMore))
              let finalResp = protocol.okResponse(req.seq, respData)
              ws.send(protocol.encodeResponse(finalResp), BinaryMessage)
              return  # Skip normal response sending

            except CatchableError as e:
              resp.status = statusError
              resp.value = "Range keys error: " & e.msg

  of cmdPrefixKeys:
    # Keys-only prefix query requires a current barrel
    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        else:
          var wrapper = barrel.get()
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
            try:
              # Decode prefix query request
              let params = protocol.decodePrefixRequest(req.value)

              # Execute keys-only prefix query
              let (keys, nextCursor, hasMore) = wrapperKeysWithPrefix(
                wrapper, params.prefix, params.limit, params.cursor)

              # Encode and send response
              let respData = protocol.encodeKeysResponse(
                protocol.KeysResponse(keys: keys, nextCursor: nextCursor, hasMore: hasMore))
              let finalResp = protocol.okResponse(req.seq, respData)
              ws.send(protocol.encodeResponse(finalResp), BinaryMessage)
              return  # Skip normal response sending

            except CatchableError as e:
              resp.status = statusError
              resp.value = "Prefix keys error: " & e.msg

  of cmdBatchGet:
    when not defined(testing):
      echo fmt"[DEBUG] cmdBatchGet: seq={req.seq}"
      flushFile(stdout)
    # Batch get requires a current barrel
    var wrapperOpt: Option[BarrelWrapper]
    var canRead = false

    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)
        let authSess = server.sessions[ws.clientId].authSession

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        elif not authSess.canReadData():
          resp.status = statusUnauthorized
          resp.value = "Unauthorized: read access required"
        else:
          wrapperOpt = barrel
          canRead = true

    # Process batch outside lock to avoid blocking other requests
    if resp.status == statusOk and canRead and wrapperOpt.isSome():
      when not defined(testing):
        echo fmt"[DEBUG] cmdBatchGet: starting processing, batch size={req.value.len}"
        flushFile(stdout)
      try:
        # Decode batch get request
        let batchReq = decodeBatchGetRequest(req.value)
        when not defined(testing):
          echo fmt"[DEBUG] cmdBatchGet: decoded batch size={batchReq.keys.len}"
          flushFile(stdout)
        var wrapper = wrapperOpt.get()

        # Execute batch get operations
        var results: seq[tuple[status: uint8, value: string]]
        results = newSeq[tuple[status: uint8, value: string]](batchReq.keys.len)

        for i, key in batchReq.keys:
          let start = epochTime()
          let value = wrapperGet(wrapper, key)
          if value.len > 0:
            server.metrics.recordOperation(opGet, stSuccess, (epochTime() - start) * 1000.0)
            results[i] = (uint8(ord(statusOk)), value)
          else:
            server.metrics.recordOperation(opGet, stFailure, (epochTime() - start) * 1000.0)
            results[i] = (uint8(ord(statusNotFound)), "")

        # Encode and send response
        when not defined(testing):
          echo fmt"[DEBUG] cmdBatchGet: processing complete, sending response seq={req.seq}"
          flushFile(stdout)
        let batchResp = BatchGetResponse(seq: req.seq, results: results)
        let batchRespData = okResponse(req.seq, encodeBatchGetResponse(batchResp))
        ws.send(encodeResponse(batchRespData), BinaryMessage)
        when not defined(testing):
          echo fmt"[DEBUG] cmdBatchGet: response sent seq={req.seq}"
          flushFile(stdout)
        return  # Skip normal response sending

      except CatchableError as e:
        resp.status = statusError
        resp.value = "Batch get error: " & e.msg

  of cmdBatchSet:
    when not defined(testing):
      echo fmt"[DEBUG] cmdBatchSet: seq={req.seq}"
      # flushFile(stdout)
    # Batch set requires a current barrel
    var wrapperOpt: Option[BarrelWrapper]
    var canWrite = false
    var errorMsg = ""

    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)
        let authSess = server.sessions[ws.clientId].authSession

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        elif not authSess.canWriteData():
          resp.status = statusUnauthorized
          resp.value = "Unauthorized: write access required"
        else:
          wrapperOpt = barrel
          canWrite = true

    # Process batch outside lock to avoid blocking other requests
    if resp.status == statusOk and canWrite and wrapperOpt.isSome():
      when not defined(testing):
        echo fmt"[DEBUG] cmdBatchSet: starting processing, batch size={req.value.len}"
        # flushFile(stdout)
      try:
        # Decode batch set request
        when not defined(testing):
          echo fmt"[DEBUG] cmdBatchSet: attempting decode, data len={req.value.len}"
          # flushFile(stdout)
        let batchReq = decodeBatchSetRequest(req.value)
        when not defined(testing):
          echo fmt"[DEBUG] cmdBatchSet: decoded batch size={batchReq.pairs.len}"
          # flushFile(stdout)
        var wrapper = wrapperOpt.get()

        # Execute batch set operations
        var statuses: seq[uint8]
        statuses = newSeq[uint8](batchReq.pairs.len)

        for i, pair in batchReq.pairs:
          let start = epochTime()
          if wrapperSet(wrapper, pair.key, pair.value):
            server.metrics.recordOperation(opSet, stSuccess, (epochTime() - start) * 1000.0)
            statuses[i] = uint8(ord(statusOk))
          else:
            server.metrics.recordOperation(opSet, stFailure, (epochTime() - start) * 1000.0)
            statuses[i] = uint8(ord(statusError))

        # Encode and send response
        when not defined(testing):
          echo fmt"[DEBUG] cmdBatchSet: processing complete, sending response seq={req.seq}"
          # flushFile(stdout)
        let batchResp = BatchSetResponse(seq: req.seq, statuses: statuses)
        let batchRespData = okResponse(req.seq, encodeBatchSetResponse(batchResp))
        ws.send(encodeResponse(batchRespData), BinaryMessage)
        when not defined(testing):
          echo fmt"[DEBUG] cmdBatchSet: response sent seq={req.seq}"
          # flushFile(stdout)
        return

      except CatchableError as e:
        when not defined(testing):
          echo fmt"[DEBUG] cmdBatchSet: exception caught: {e.msg}"
          echo "Stack trace: ", e.getStackTrace()
          # flushFile(stdout)
        resp.status = statusError
        resp.value = "Batch set error: " & e.msg

  of cmdBatchDelete:
    # Batch delete requires a current barrel
    var wrapperOpt: Option[BarrelWrapper]
    var canWrite = false

    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)
        let authSess = server.sessions[ws.clientId].authSession

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        elif not authSess.canWriteData():
          resp.status = statusUnauthorized
          resp.value = "Unauthorized: write access required"
        else:
          wrapperOpt = barrel
          canWrite = true

    # Process batch outside lock to avoid blocking other requests
    if resp.status == statusOk and canWrite and wrapperOpt.isSome():
      try:
        # Decode batch delete request
        let batchReq = decodeBatchDeleteRequest(req.value)
        var wrapper = wrapperOpt.get()

        # Execute batch delete operations
        var statuses: seq[uint8]
        statuses = newSeq[uint8](batchReq.keys.len)

        for i, key in batchReq.keys:
          let start = epochTime()
          if wrapperDelete(wrapper, key):
            server.metrics.recordOperation(opDelete, stSuccess, (epochTime() - start) * 1000.0)
            statuses[i] = uint8(ord(statusOk))
          else:
            server.metrics.recordOperation(opDelete, stFailure, (epochTime() - start) * 1000.0)
            statuses[i] = uint8(ord(statusError))

        # Encode and send response
        let batchResp = BatchDeleteResponse(seq: req.seq, statuses: statuses)
        let batchRespData = okResponse(req.seq, encodeBatchDeleteResponse(batchResp))
        ws.send(encodeResponse(batchRespData), BinaryMessage)
        return

      except CatchableError as e:
        resp.status = statusError
        resp.value = "Batch delete error: " & e.msg

  of cmdGetBarrelStats:
    # Get barrel statistics requires a current barrel
    withLock server.sessionsLock:
      if not server.sessions[ws.clientId].hasCurrentBarrel():
        resp.status = statusNoBarrel
      else:
        let barrelName = server.sessions[ws.clientId].getCurrentBarrel()
        let barrel = server.registry.getBarrel(barrelName)

        if barrel.isNone():
          resp.status = statusBarrelNotFound
        else:
          var wrapper = barrel.get()
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
            try:
              # Get statistics from the barrel
              let stats = wrapperGetStats(wrapper)
              # Encode to JSON and send response
              resp.status = statusOk
              resp.value = encodeBarrelStats(stats)
            except CatchableError as e:
              resp.status = statusError
              resp.value = "Failed to get barrel stats: " & e.msg

  of cmdSubscribe:
    ## Subscribe to a topic or pattern
    when not defined(testing):
      writeLine(stderr, "[DEBUG] SUBSCRIBE: Entered handler")
      flushFile(stderr)
    if not server.pubSubEnabled or server.pubSubManager == nil:
      resp.status = statusError
      resp.value = "Pub/sub not enabled"
    else:
      try:
        when not defined(testing):
          writeLine(stderr, "[DEBUG] SUBSCRIBE: About to decode request")
          flushFile(stderr)
        let subReq = protocol.decodeSubscribeRequest(req.value)
        when not defined(testing):
          writeLine(stderr, "[DEBUG] SUBSCRIBE: Decoded, topic=" & subReq.topic & " pattern=" & subReq.pattern)
          flushFile(stderr)
        let subOptions = pubsub.SubscriptionOptions(
          enableKvEvents: subReq.options.enableKvEvents,
          enablePresence: subReq.options.enablePresence,
          replayHistory: subReq.options.replayHistory
        )
        when not defined(testing):
          writeLine(stderr, "[DEBUG] SUBSCRIBE: About to call subscribe()")
          flushFile(stderr)
        let subId = server.pubSubManager.subscribe(
          ws.clientId, subReq.topic, subReq.pattern, subOptions
        )
        when not defined(testing):
          writeLine(stderr, "[DEBUG] SUBSCRIBE: subscribe() returned, subId=" & subId)
          flushFile(stderr)
        resp.status = statusOk
        resp.value = subId

        # If presence enabled, join the topic
        if subReq.options.enablePresence and server.presenceManager != nil:
          when not defined(testing):
            writeLine(stderr, "[DEBUG] SUBSCRIBE: Joining presence topic")
            flushFile(stderr)
          withLock server.sessionsLock:
            if ws.clientId in server.sessions:
              let username = server.sessions[ws.clientId].authSession.username
              if username.len == 0:
                # Use a default username based on client ID
                discard server.presenceManager.joinTopic(subReq.topic, ws.clientId, "client_" & $ws.clientId)
              else:
                discard server.presenceManager.joinTopic(subReq.topic, ws.clientId, username)

      except CatchableError as e:
        when not defined(testing):
          writeLine(stderr, "[DEBUG] SUBSCRIBE: Exception - " & e.msg)
          flushFile(stderr)
        resp.status = statusError
        resp.value = "Subscribe error: " & e.msg

  of cmdUnsubscribe:
    ## Unsubscribe from a topic or pattern (empty = unsubscribe all)
    if not server.pubSubEnabled or server.pubSubManager == nil:
      resp.status = statusError
      resp.value = "Pub/sub not enabled"
    else:
      try:
        if server.pubSubManager.unsubscribe(ws.clientId, req.key):
          resp.status = statusOk
        else:
          resp.status = statusInvalid
          resp.value = "Not subscribed to topic/pattern"
      except CatchableError as e:
        resp.status = statusError
        resp.value = "Unsubscribe error: " & e.msg

  of cmdPublish:
    ## Publish a message to a topic
    if not server.pubSubEnabled or server.pubSubManager == nil:
      resp.status = statusError
      resp.value = "Pub/sub not enabled"
    else:
      try:
        let pubReq = protocol.decodePublishRequest(req.value)
        let headers = if pubReq.headers.len > 0:
                        parseJson(pubReq.headers)
                      else:
                        nil

        let seqNo = server.pubSubManager.publish(pubReq.topic,
                                                     pubsub.PubSubMessageType(ord(pubReq.messageType)),
                                                     pubReq.payload, headers)

        resp.status = statusOk
        # Encode sequence number as binary uint64 (big-endian)
        resp.value.setLen(0)
        resp.value.writeUint64BE(seqNo)
      except CatchableError as e:
        resp.status = statusError
        resp.value = "Publish error: " & e.msg

  of cmdListSubscribers:
    ## Get subscribers for a topic
    if not server.pubSubEnabled or server.pubSubManager == nil:
      resp.status = statusError
      resp.value = "Pub/sub not enabled"
    else:
      try:
        # Client sends topic in req.value (not req.key)
        let subscribers = server.pubSubManager.getSubscribersForTopic(req.value)
        var respArray = newJArray()
        for sub in subscribers:
          var subJson = newJObject()
          subJson["subscriptionId"] = %sub.id
          subJson["clientId"] = %sub.clientId
          if sub.pattern.len > 0:
            subJson["pattern"] = %sub.pattern
          else:
            subJson["topic"] = %sub.topic
          respArray.add(subJson)
        resp.status = statusOk
        resp.value = $respArray
      except CatchableError as e:
        resp.status = statusError
        resp.value = "List subscribers error: " & e.msg

  of cmdHistory:
    ## Get message history for a topic
    if not server.pubSubEnabled or server.historyStore == nil:
      resp.status = statusError
      resp.value = "Pub/sub history not enabled"
    else:
      try:
        let histReq = protocol.decodeHistoryRequest(req.value)
        let messages = server.historyStore.getHistory(histReq.topic, histReq.count,
                                                        histReq.sinceSeq)
        var respArray = newJArray()
        for msg in messages:
          var msgJson = newJObject()
          msgJson["topic"] = %msg.topic
          msgJson["messageType"] = %ord(msg.messageType)
          msgJson["payload"] = %msg.payload
          msgJson["timestamp"] = %msg.timestamp
          msgJson["sequence"] = %msg.sequence
          if msg.headers != nil:
            msgJson["headers"] = msg.headers
          else:
            msgJson["headers"] = newJObject()
          respArray.add(msgJson)
        resp.status = statusOk
        resp.value = $respArray
      except CatchableError as e:
        resp.status = statusError
        resp.value = "History error: " & e.msg

  of cmdListTopics:
    ## List topics matching pattern
    if not server.pubSubEnabled or server.pubSubManager == nil:
      resp.status = statusError
      resp.value = "Pub/sub not enabled"
    else:
      try:
        let topics = server.pubSubManager.listTopics(req.value)
        var respArray = newJArray()
        for topic in topics:
          var topicJson = newJObject()
          topicJson["name"] = %topic.name
          topicJson["sequence"] = %topic.sequence
          topicJson["subscriberCount"] = %topic.subscribers.len
          topicJson["messageCount"] = %topic.messageCount
          respArray.add(topicJson)
        resp.status = statusOk
        resp.value = $respArray
      except CatchableError as e:
        resp.status = statusError
        resp.value = "List topics error: " & e.msg

  of cmdPresence:
    ## Get presence info or broadcast update
    if not server.pubSubEnabled or server.presenceManager == nil:
      resp.status = statusError
      resp.value = "Pub/sub presence not enabled"
    else:
      try:
        let presReq = protocol.decodePresenceRequest(req.value)
        if presReq.operation == 0:
          # Get online - return presence for subscribed topics
          var respArray = newJArray()
          let presenceData = server.presenceManager.getAllPresence()
          for _, info in presenceData:
            respArray.add(toJson(info))
          resp.status = statusOk
          resp.value = $respArray
        else:
          # Broadcast update - for future use
          resp.status = statusInvalid
          resp.value = "Operation not implemented"
      except CatchableError as e:
        resp.status = statusError
        resp.value = "Presence error: " & e.msg

  of cmdWatchKey:
    ## Watch keys matching pattern via Pub/Sub
    if not server.pubSubEnabled or server.pubSubManager == nil:
      resp.status = statusError
      resp.value = "Pub/sub not enabled"
    else:
      try:
        let watchReq = protocol.decodeWatchRequest(req.value)
        # Determine barrel name (from request or session current barrel)
        var barrelName = watchReq.barrelName
        if barrelName.len == 0:
          withLock server.sessionsLock:
            if ws.clientId in server.sessions:
              barrelName = server.sessions[ws.clientId].getCurrentBarrel()
            else:
              barrelName = ""

        if barrelName == "":
          resp.status = statusNoBarrel
          resp.value = "No barrel selected"
        else:
          # Build Pub/Sub topic pattern for key watching
          # Topic format: kv:{barrelName}:{pattern}
          const KvTopicPrefix = "kv:"
          let topicPattern = KvTopicPrefix & barrelName & ":" & watchReq.pattern

          # Create Pub/Sub subscription with KV events enabled
          let subOptions = pubsub.SubscriptionOptions(
            enableKvEvents: true,
            enablePresence: false,
            replayHistory: false
          )

          let subId = server.pubSubManager.subscribe(
            ws.clientId, "", topicPattern, subOptions
          )

          # Generate watch ID (UUID string)
          let watchId = pubsub.generateUuid()

          # Store watch mapping in session (for unwatch later)
          withLock server.sessionsLock:
            if ws.clientId in server.sessions:
              # Store watch entry: watchId -> (subscriptionId, topicPattern)
              if session.watches == nil:
                session.watches = new(Table[string, tuple[subId: string, topic: string]])
              session.watches[watchId] = (subId: subId, topic: topicPattern)

          resp.status = statusOk
          resp.value = watchId

      except CatchableError as e:
        resp.status = statusError
        resp.value = "Watch error: " & e.msg

  of cmdUnwatchKey:
    ## Stop watching keys by watch ID
    if not server.pubSubEnabled or server.pubSubManager == nil:
      resp.status = statusError
      resp.value = "Pub/sub not enabled"
    else:
      try:
        let watchId = req.key  # Watch ID passed as key

        # Find and remove the watch subscription
        var found = false
        withLock server.sessionsLock:
          if ws.clientId in server.sessions and session.watches != nil:
            if watchId in session.watches:
              let watchEntry = session.watches[watchId]
              # Unsubscribe from the Pub/Sub pattern
              discard server.pubSubManager.unsubscribe(ws.clientId, watchEntry.topic)
              # Remove from session
              session.watches.del(watchId)
              found = true

        if found:
          resp.status = statusOk
        else:
          resp.status = statusInvalid
          resp.value = "Watch not found"

      except CatchableError as e:
        resp.status = statusError
        resp.value = "Unwatch error: " & e.msg

  else:
    resp.status = statusInvalid
    resp.value = "Unknown command"

  # Send response
  when not defined(testing):
    writeLine(stderr, "[DEBUG] Sending response seq=" & $resp.seq & " status=" & $resp.status)
    flushFile(stderr)
  ws.send(encodeResponse(resp), BinaryMessage)

proc websocketUpgradeHandler*(server: BitBarrelServer, request: mummy.Request) =
  ## Handle WebSocket upgrade request with JWT authentication
  try:
    var authSession = authjwt.AuthSession(authenticated: false)

    if server.config.auth.enabled:
      if not request.headers.contains("Authorization"):
        request.respond(401, body = "Missing Authorization header")
        return

      let authHeader = request.headers["Authorization"]
      if not authHeader.startsWith("Bearer "):
        request.respond(401, body = "Invalid Authorization header format")
        return

      let token = authHeader[7..^1]
      try:
        authSession = authjwt.verifyToken(server.config.auth, token)
        if not authSession.authenticated:
          request.respond(401, body = "Invalid token")
          return
      except authjwt.AuthError as e:
        request.respond(401, body = e.msg)
        return

    let ws = request.upgradeToWebSocket()
    var session = newSession(ws.clientId)
    session.authSession = authSession
    withLock server.sessionsLock:
      server.sessions[ws.clientId] = session
    # Send server handshake (binary protocol v1.1)
    var sId = server.config.serverId
    if sId.len == 0:
      sId = pubsub.generateUuid()
    when not defined(testing):
      echo "[DEBUG] Upgrade: about to send handshake, clientId=" & $ws.clientId
      writeLine(stderr, "[DEBUG] Upgrade: about to send handshake, clientId=" & $ws.clientId)
      flushFile(stderr)
    try:
      # Get list of loaded plugins
      let plugins = if server.pubSubEnabled and server.eventBroker != nil:
        newSeq[string]()  # TODO: Get actual plugin list from query_result_hooks
      else:
        newSeq[string]()

      var handshake = ServerHandshake(
        versionMajor: 1,
        versionMinor: 1,
        serverId: sId,
        plugins: plugins
      )

      let encoded = protocol.encodeHandshake(handshake)
      ws.send(encoded, BinaryMessage)
      when not defined(testing):
        echo "[DEBUG] Sent handshake after upgrade, clientId=" & $ws.clientId
        writeLine(stderr, "[DEBUG] Sent handshake after upgrade, clientId=" & $ws.clientId)
        flushFile(stderr)
    except CatchableError as e:
      when not defined(testing):
        echo "[DEBUG] Failed to send handshake: " & e.msg
        echo "Stack trace: ", e.getStackTrace()
        writeLine(stderr, "[DEBUG] Failed to send handshake: " & e.msg)
        flushFile(stderr)
  except CatchableError:
    request.respond(400, body = "WebSocket upgrade failed")

proc websocketHandler*(
  server: BitBarrelServer,
  ws: mummy.WebSocket,
  event: WebSocketEvent,
  message: mummy.Message
) =
  ## Handle WebSocket events
  {.gcsafe.}:
    case event:
    of OpenEvent:
      # Session created lazily on first message
      when not defined(testing):
        writeLine(stderr, "DEBUG: OpenEvent entered, clientId=" & $ws.clientId)
        flushFile(stderr)
        echo "OPEN EVENT TRIGGERED"
        writeLine(stderr, "STDERR TEST1: OpenEvent")
        flushFile(stderr)
        writeLine(stderr, "STDERR TEST2: Time: " & $epochTime())
        flushFile(stderr)
        writeLine(stderr, "ZZZ WebSocket connection opened: clientId=" & $ws.clientId)
        flushFile(stderr)
        writeLine(stderr, "DEBUG: After ZZZ flush")

      # Store WebSocket in table for later use (e.g., pub/sub events)
      when not defined(testing):
        writeLine(stderr, "DEBUG: Before storing websocket")
        flushFile(stderr)
      withLock server.sessionsLock:
        server.webSockets[ws.clientId] = ws
      when not defined(testing):
        writeLine(stderr, "DEBUG: After storing websocket")
        flushFile(stderr)
        writeLine(stderr, "WebSocket handler initialized for clientId=" & $ws.clientId)
        flushFile(stderr)


      # Register client with event broker for pub/sub (just stores the clientId)
      if server.pubSubEnabled and server.eventBroker != nil:
        server.eventBroker.addClient(ws.clientId)

    of MessageEvent:
      when not defined(testing):
        writeLine(stderr, "[DEBUG] MessageEvent: data length=" & $message.data.len)
        flushFile(stderr)
      if message.kind == BinaryMessage:
        server.handleWebSocketMessage(ws, message.data)
      else:
        # Text messages not supported for binary protocol
        ws.send(encodeResponse(invalidResponse(0, "Use binary protocol")), BinaryMessage)

    of ErrorEvent:
      writeLine(stderr, "WebSocket error: clientId=" & $ws.clientId & " message data len=" & $message.data.len & " kind=" & $message.kind)
      if message.data.len > 0:
        writeLine(stderr, "WebSocket error data: " & $(message.data))
      flushFile(stderr)

    of CloseEvent:
      writeLine(stderr, "WebSocket connection closed: clientId=" & $ws.clientId)
      flushFile(stderr)

      # Remove WebSocket from storage table
      withLock server.sessionsLock:
        if ws.clientId in server.webSockets:
          server.webSockets.del(ws.clientId)

      # Clean up pub/sub subscriptions if enabled
      if server.pubSubEnabled:
        if server.pubSubManager != nil:
          # Unsubscribe client from all topics
          let count = server.pubSubManager.unsubscribeAll(ws.clientId)
          if count > 0:
            echo "[PubSub] Unsubscribed ", count, " subscriptions for client ", ws.clientId

        if server.presenceManager != nil:
          # Leave all presence topics
          let leftCount = server.presenceManager.leaveAllTopics(ws.clientId)
          if leftCount > 0:
            echo "[PubSub] Client ", ws.clientId, " left ", leftCount, " topics"

        if server.eventBroker != nil:
          # Remove client from event broker
          server.eventBroker.removeClient(ws.clientId)

      # Clean up session
      withLock server.sessionsLock:
        server.sessions.del(ws.clientId)


proc handleRestBarrels*(server: BitBarrelServer, request: mummy.Request) =
  ## Handle REST API for barrel management
  case request.httpMethod:
  of "GET":
    # List all barrels
    let barrels = server.registry.listBarrels()
    var responseJson = "["
    var first = true
    for barrel in barrels:
      if not first:
        responseJson.add(",")
      responseJson.add("""{"name":"""" & barrel & """"}""")
      first = false
    responseJson.add("]")
    request.respond(200, body = responseJson)

  of "POST":
    # Create new barrel
    # TODO: Parse JSON from request body
    var barrelName: string
    withLock server.sessionsLock:
      barrelName = "newbar" & $server.seqCounter
      server.seqCounter += 1

    let config = defaultBarrelConfig()
    if server.registry.createBarrel(barrelName, config):
      var hdrs: HttpHeaders
      hdrs["Location"] = "/barrels/" & barrelName
      request.respond(201, hdrs, """{"name":"""" & barrelName & """","created":true}""")
    else:
      request.respond(409, body = """{"error":"Barrel already exists"}""")

  else:
    var hdrs: HttpHeaders
    hdrs["Allow"] = "GET,POST"
    request.respond(405, hdrs)

proc handleRestBarrel*(server: BitBarrelServer, request: mummy.Request, barrelName: string) =
  ## Handle REST API for specific barrel
  case request.httpMethod:
  of "GET":
    # Get barrel info
    let barrel = server.registry.getBarrel(barrelName)
    if barrel.isSome():
      request.respond(200, body = """{"name":"""" & barrelName & """","dataFile":"""" & barrelName & """.data"}""")
    else:
      request.respond(404, body = """{"error":"Barrel not found"}""")

  of "DELETE":
    # Drop barrel
    if server.registry.dropBarrel(barrelName):
      request.respond(204)
    else:
      request.respond(404, body = """{"error":"Barrel not found"}""")

  else:
    var hdrs: HttpHeaders
    hdrs["Allow"] = "GET,DELETE"
    request.respond(405, hdrs)

proc handleRestKV*(server: BitBarrelServer, request: mummy.Request, barrelName: string, key: string) =
  ## Handle REST API for key-value operations
  let barrel = server.registry.getBarrel(barrelName)
  if barrel.isNone():
    request.respond(404, body = """{"error":"Barrel '""" & barrelName & """' not found"}""")
    return

  var wrapper = barrel.get()

  case request.httpMethod:
  of "GET":
    let start = epochTime()
    let value = wrapperGet(wrapper, key)
    let duration = (epochTime() - start) * 1000.0
    if value.len > 0:
      server.metrics.recordOperation(opGet, stSuccess, duration)
      request.respond(200, body = value)
    else:
      server.metrics.recordOperation(opGet, stFailure, duration)
      request.respond(404)

  of "PUT":
    let start = epochTime()
    let value = request.body
    if wrapperSet(wrapper, key, value):
      server.metrics.recordOperation(opSet, stSuccess, (epochTime() - start) * 1000.0)
      var hdrs: HttpHeaders
      hdrs["Location"] = "/barrels/" & barrelName & "/kv/" & key
      request.respond(201, hdrs)
    else:
      server.metrics.recordOperation(opSet, stFailure, (epochTime() - start) * 1000.0)
      request.respond(500, body = """{"error":"Failed to set key"}""")

  of "DELETE":
    let start = epochTime()
    if wrapperDelete(wrapper, key):
      server.metrics.recordOperation(opDelete, stSuccess, (epochTime() - start) * 1000.0)
      request.respond(204)
    else:
      server.metrics.recordOperation(opDelete, stFailure, (epochTime() - start) * 1000.0)
      request.respond(500, body = """{"error":"Failed to delete key"}""")

  of "HEAD":
    let start = epochTime()
    if wrapperExists(wrapper, key):
      server.metrics.recordOperation(opGet, stSuccess, (epochTime() - start) * 1000.0)
      request.respond(200)
    else:
      server.metrics.recordOperation(opGet, stFailure, (epochTime() - start) * 1000.0)
      request.respond(404)

  else:
    var hdrs: HttpHeaders
    hdrs["Allow"] = "GET,PUT,DELETE,HEAD"
    request.respond(405, hdrs)

# Forward declarations
proc handleRestTraverse(server: BitBarrelServer, request: mummy.Request,
                       barrelName: string, key: string)

proc handleRestStatus*(server: BitBarrelServer, request: mummy.Request) =
  ## Server health check and stats
  var sessionCount: int
  withLock server.sessionsLock:
    sessionCount = server.sessions.len

  let barrelCount = server.registry.listBarrels().len

  var statsJson = """
{
  "status": "ok",
  "uptime": """ & $int(epochTime() - server.startTime) & """,
  "sessions": """ & $sessionCount & """,
  "barrels": """ & $barrelCount & """
}"""

  var headers = emptyHttpHeaders()
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, statsJson)

proc handleRestMetrics*(server: BitBarrelServer, request: mummy.Request) =
  ## Prometheus-compatible metrics endpoint
  ## Generate metrics in Prometheus text exposition format
  {.gcsafe.}:
    ## Update server metrics before generating
    var sessionCount: int
    withLock server.sessionsLock:
      sessionCount = server.sessions.len

    let barrelNames = server.registry.listBarrels()
    server.metrics.updateServerMetrics(sessionCount, barrelNames.len)

    ## Aggregate storage metrics from all barrels
    var totalFiles = 0
    var totalBytes = 0'i64
    var totalActiveKeys = 0'i64
    var totalDeletedKeys = 0'i64
    var avgFragRatio = 0.0
    var barrelCount = 0

    for barrelName in barrelNames:
      let barrel = server.registry.getBarrel(barrelName)
      if barrel.isSome():
        var wrapper = barrel.get()
        let stats = wrapperGetStats(wrapper)
        totalFiles += stats.fileCount
        totalBytes += stats.totalSize
        totalActiveKeys += stats.activeKeys
        totalDeletedKeys += stats.deletedKeys
        avgFragRatio += stats.fragmentationRatio
        barrelCount += 1

    if barrelCount > 0:
      avgFragRatio = avgFragRatio / float64(barrelCount)

    server.metrics.updateStorageMetrics(
      totalFiles, totalBytes, avgFragRatio,
      totalActiveKeys, totalDeletedKeys
    )

    ## Generate Prometheus format metrics
    let metricsText = server.metrics.generatePrometheusFormat()

    var headers = emptyHttpHeaders()
    headers["Content-Type"] = "text/plain; version=0.0.4"
    request.respond(200, headers, metricsText)

proc restHandler*(server: BitBarrelServer, request: mummy.Request) =
  ## Dispatch REST API requests
  {.gcsafe.}:
    if request.path == "/status":
      handleRestStatus(server, request)

    elif request.path == "/barrels":
      handleRestBarrels(server, request)

    elif request.path.startsWith("/barrels/") and not request.path.contains("/kv/"):
      # Path: /barrels/{name} -> ["", "barrels", "{name}"]
      let parts = request.path.split('/')
      if parts.len >= 3:
        let barrelName = parts[2]
        handleRestBarrel(server, request, barrelName)
      else:
        request.respond(400)

    elif request.path.startsWith("/barrels/") and request.path.contains("/traverse/"):
      # Path: /barrels/{name}/traverse/{key} -> ["", "barrels", "{name}", "traverse", "{key}"]
      let parts = request.path.split('/')
      if parts.len >= 5 and parts[3] == "traverse":
        let barrelName = parts[2]
        let key = parts[4]
        handleRestTraverse(server, request, barrelName, key.decodeUrl())
      else:
        request.respond(400)

    elif request.path.startsWith("/barrels/") and request.path.contains("/kv/"):
      # Path: /barrels/{name}/kv/{key} -> ["", "barrels", "{name}", "kv", "{key}"]
      let parts = request.path.split('/')
      if parts.len >= 5 and parts[3] == "kv":
        let barrelName = parts[2]
        let key = parts[4]
        handleRestKV(server, request, barrelName, key.decodeUrl())
      else:
        request.respond(400)

    else:
      request.respond(404)

# Simple query string parser
proc parseQuery*(query: string): Table[string, string] =
  result = initTable[string, string]()
  if query.len == 0:
    return

  for param in query.split('&'):
    let eqPos = param.find('=')
    if eqPos > 0:
      let key = param[0..<eqPos].decodeUrl()
      let val = param[eqPos+1..^1].decodeUrl()
      result[key] = val

proc handleRestTraverse(server: BitBarrelServer, request: mummy.Request,
                       barrelName: string, key: string) =
  ## Handle REST API traversal requests
  ## GET /barrels/{name}/traverse/{key}?path=friends->team&includeData=true
  {.gcsafe.}:
    if request.httpMethod != "GET":
      request.respond(405, body = "Use GET for traversal")
      return

    let barrel = server.registry.getBarrel(barrelName)
    if barrel.isNone():
      request.respond(404, body = fmt("{{\"error\":\"Barrel not found: {barrelName}\"}}"))
      return

    var wrapper = barrel.get()

    # Parse query parameters from the URI
    # Mummy doesn't provide queryString directly, so extract from path
    let uri = request.path  # This might include query params
    let queryStart = uri.find('?')
    let queryString = if queryStart >= 0: uri[queryStart+1..^1] else: ""
    let queryParams = parseQuery(queryString)
    let pathSpec = queryParams.getOrDefault("path", "")
    let includeData = queryParams.getOrDefault("includeData", "false").toLower() == "true"
    let firstOnly = queryParams.getOrDefault("firstOnly", "false").toLower() == "true"

    if pathSpec.len == 0:
      request.respond(400, body = "{\"error\":\"Missing path parameter\"}")
      return

    # Perform traversal
    try:
      let pathSteps = parsePathSpec(pathSpec)
      var results: seq[protocol.TraverseResult]
      var visited = initHashSet[string]()

      proc buildResult(key: string, path: string): protocol.TraverseResult =
        result = protocol.TraverseResult(path: path, key: key)
        if includeData:
          result.value = wrapperGet(wrapper, key)

      proc followPath(currentKey: string, currentStep: int,
                     currentPath: seq[string]) =
        if currentStep >= pathSteps.len:
          results.add(buildResult(currentKey, currentPath.join("->")))
          if firstOnly:
            return
          return

        if currentKey in visited:
          return
        visited.incl(currentKey)

        let value = wrapperGet(wrapper, currentKey)
        if value.len == 0:
          return

        let refs = extractRefs(value)
        if refs.len == 0:
          return

        let step = pathSteps[currentStep]
        var refsToFollow: seq[string]

        if step.relType == "*":
          for keys in refs.values:
            refsToFollow = refsToFollow.concat(keys)
        else:
          refsToFollow = refs.getOrDefault(step.relType, @[])

        if step.isArraySlice:
          refsToFollow = applySlice(refsToFollow, step.arraySlice)

        for refKey in refsToFollow:
          var newPath = currentPath
          newPath.add(fmt("{step.relType}->{refKey}"))

          if currentStep + 1 < pathSteps.len:
            followPath(refKey, currentStep + 1, newPath)
          else:
            results.add(buildResult(refKey, newPath.join("->")))
            if firstOnly:
              return

      var startPath = @[key]
      followPath(key, 0, startPath)

      # Build JSON response
      var jsonResponse = "{"
      jsonResponse.add(fmt("\"startKey\":\"{key}\","))
      jsonResponse.add(fmt("\"pathSpec\":\"{pathSpec}\","))
      jsonResponse.add(fmt("\"resultsCount\":{results.len},"))
      jsonResponse.add("\"results\":[")

      for i, res in results:
        if i > 0: jsonResponse.add(",")
        jsonResponse.add("{")
        jsonResponse.add(fmt("\"path\":\"{res.path}\","))
        jsonResponse.add(fmt("\"key\":\"{res.key}\""))
        if includeData and res.value.len > 0:
          let escapedValue = res.value.multiReplace(
            ("\\", "\\\\"),
            ("\"", "\\\""),
            ("\n", "\\n"),
            ("\r", "\\r")
          )
          jsonResponse.add(fmt(",\"value\":\"{escapedValue}\""))
        jsonResponse.add("}")

      jsonResponse.add("]}")

      var headers = emptyHttpHeaders()
      headers["Content-Type"] = "application/json"
      request.respond(200, headers, jsonResponse)

    except CatchableError as e:
      request.respond(500, body = fmt("{{\"error\":\"{e.msg}\"}}"))

# Routes are registered directly in newServer() to properly capture the server reference

proc newServer*(config: ServerConfig): BitBarrelServer =
  ## Create a new BitBarrel server instance
  new(result)
  # Ensure data directory exists before initializing components
  try:
    createDir(config.dataDir)
  except OSError as e:
    echo "Warning: Failed to create data directory '", config.dataDir, "': ", e.msg
    # Continue anyway - some components may fail later

  result.registry = newBarrelRegistry(config.dataDir)

  # Discover existing barrels in data directory
  let (discovered, yamlsCreated) = result.registry.discoverBarrels()
  echo fmt("BitBarrel discovery: {discovered} barrels available, {yamlsCreated} configs created")

  result.sessions = initTable[uint64, Session]()
  result.webSockets = initTable[uint64, WebSocket]()
  result.config = config
  result.sessionsLock = Lock()
  result.seqCounter = 0
  result.startTime = epochTime()
  result.metrics = newMetricsCollector(persistEnabled = false, retentionHours = 168)
  initLock(result.sessionsLock)

  # Initialize pub/sub system if enabled
  result.pubSubEnabled = if result.config.pubSubEnabled:
    result.config.pubSubEnabled
  else:
    true  # Default to enabled if not specified

  if result.pubSubEnabled:
    echo "[PubSub] Initializing pub/sub system..."

    # Create pub/sub configuration
    let psConfig = PubSubConfig(
        enabled: true,
        maxTopics: if config.maxPubSubTopics > 0: config.maxPubSubTopics else: 0,
        maxSubscriptionsPerClient: if config.maxSubscriptionsPerClient > 0:
                                       config.maxSubscriptionsPerClient
                                     else: 0,
        heartbeatTimeoutMs: if config.pubSubHeartbeatTimeoutMs > 0:
                               config.pubSubHeartbeatTimeoutMs
                             else: 30000,
        heartbeatCheckIntervalMs: 5000,
        defaultTopicConfig: defaultTopicConfig()
      )

    # Create pub/sub manager with message callback
    type ServerRef = ptr BitBarrelServerObj

    proc buildMessageCallback(srv: ServerRef): MessageCallback =
      proc clientMsgCallback(clientId: uint64, topic: string,
                              messageType: pubsub.PubSubMessageType,
                              payload: string, headers: string) {.gcsafe.} =
        # Find the WebSocket connection for this client
        withLock srv.sessionsLock:
          if clientId notin srv.sessions:
            return

          # Build event message
          let event = PubSubEvent(
            topic: topic,
            messageType: protocol.PubSubMessageType(ord(messageType)),
            sequence: 0,
            timestamp: int64(epochTime() * 1000),
            headers: headers,
            payload: payload
          )

          # Encode and send
          let encoded = encodePubSubEvent(event)
          # Note: We'd need access to ws here, but we don't have it
          # For now, we'll rely on the event broker to send
          # This is a limitation - we may need to track WebSockets differently

      return clientMsgCallback

    # Create manager (without callback initially - will be set after broker)
    result.pubSubManager = newPubSubManager(psConfig)

    # Create event broker
    result.eventBroker = newEventBroker(result.pubSubManager)

    # Capture references for closures (cannot capture 'result' directly)
    let managerRef = result.pubSubManager
    let brokerRef = result.eventBroker
    let serverRef = result

    # Now set the message callback on the manager that uses the broker
    proc brokerMessageCallback(clientId: uint64, topic: string,
                                messageType: pubsub.PubSubMessageType,
                                payload: string, headers: string) {.gcsafe.} =
      {.gcsafe.}:
        # Encode message for client
        let encoded = brokerRef.sendToClient(clientId, topic, messageType, payload, headers)
        if encoded.len == 0:
          return  # Client not connected or not subscribed

        # Send via stored WebSocket
        withLock serverRef[].sessionsLock:
          if clientId in serverRef[].webSockets:
            let ws = serverRef[].webSockets[clientId]
            ws.send(encoded, BinaryMessage)

    result.pubSubManager.messageCallback = brokerMessageCallback

    # Create presence manager
    result.presenceManager = newPresenceManager(
      eventBroker = result.eventBroker,
      checkIntervalMs = 5000,
      heartbeatTimeoutMs = psConfig.heartbeatTimeoutMs
    )

    # Create history store with shared barrel backend (configure bmCritBit for ordered queries)
    var barrelConfig = defaultBarrelConfig()
    barrelConfig.mode = bmCritBit  # Required for range queries
    result.historyStore = newSharedBarrelHistoryStore(
      config.dataDir / "pubsub_history.data",
      barrelConfig
    )

    try:
      result.historyStore.storageManager.initSharedBackend()
      # Assign history store to manager so it can store published messages
      managerRef.historyStore = result.historyStore
    except CatchableError as e:
      echo "[PubSub] Error initializing shared backend: ", e.msg
      echo "Stack trace: ", e.getStackTrace()
      # Disable history store on error
      result.historyStore = nil

    # Register barrel hook for k/v change events
    managerRef.setKvChangeCallback(proc(barrelName: string, key: string,
                                        changeType: pubsub.KvChangeType,
                                        value: string) {.gcsafe.} =
      # Publish k/v change event via event broker
      {.gcsafe.}:
        let topic = "kv:" & barrelName & ":" & key
        var payload = ""
        if changeType == kvSet:
          payload = value
        let msg = newMessage(topic, mtKvChange, payload)
        # Get all subscribers for this topic
        let subscribers = managerRef.getAllSubscribersForTopic(topic)
        # Build headers
        var headers = newJObject()
        headers["barrel"] = %barrelName
        headers["key"] = %key
        headers["changeType"] = %ord(changeType)

        let headerStr = $headers
        for sub in subscribers:
          if sub.options.enableKvEvents:
            let encoded = brokerRef.sendToClient(sub.clientId, topic, mtKvChange,
                                                 payload, headerStr)
            if encoded.len > 0:
              withLock serverRef[].sessionsLock:
                if sub.clientId in serverRef[].webSockets:
                  let ws = serverRef[].webSockets[sub.clientId]
                  ws.send(encoded, BinaryMessage)
    )

    managerRef.kvHookId = registerBarrelHook(
      proc(barrelName: string, key: string,
           changeType: pubsub.KvChangeType, value: string) {.gcsafe.} =
        # Forward to the manager's callback
        if managerRef.kvChangeCallback != nil:
          managerRef.kvChangeCallback(barrelName, key, changeType, value)
    )

    # Start presence cleanup thread
    result.presenceManager.startCleanupThread()

    echo "[PubSub] Pub/sub system initialized"
  else:
    result.pubSubManager = nil
    result.eventBroker = nil
    result.presenceManager = nil
    result.historyStore = nil

  # Create MummyX router with server reference captured
  var router: Router
  let serverRef = result  # Capture for closures
  router.get("/status", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.get("/ws", proc(req: mummy.Request) {.gcsafe.} = websocketUpgradeHandler(serverRef, req))
  router.post("/barrels", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.get("/barrels", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.delete("/barrels/*", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.get("/barrels/*", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.put("/barrels/*/kv/*", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.get("/barrels/*/kv/*", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.delete("/barrels/*/kv/*", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.head("/barrels/*/kv/*", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.get("/barrels/*/traverse/*", proc(req: mummy.Request) {.gcsafe.} = restHandler(serverRef, req))
  router.get("/metrics", proc(req: mummy.Request) {.gcsafe.} = handleRestMetrics(serverRef, req))

  # Webadmin static file routes (only if webadmin is enabled)
  if config.webadminEnabled and config.webadminPath.len > 0:
    router.get("/admin/*", proc(req: mummy.Request) {.gcsafe.} = serveStaticFile(serverRef, req))
    router.get("/admin/*/*", proc(req: mummy.Request) {.gcsafe.} = serveStaticFile(serverRef, req))
    router.get("/admin/*/*/*", proc(req: mummy.Request) {.gcsafe.} = serveStaticFile(serverRef, req))
    router.get("/favicon.ico", proc(req: mummy.Request) {.gcsafe.} = serveStaticFile(serverRef, req))
    router.get("/", proc(req: mummy.Request) {.gcsafe.} = serveWebadminRoot(serverRef, req))

  result.mummyServer = newServer(
    router.toHandler(),
    websocketHandler = proc(ws: mummy.WebSocket, event: WebSocketEvent, msg: mummy.Message) {.gcsafe.} =
      websocketHandler(serverRef, ws, event, msg),
    maxMessageLen = 33 * 1024 * 1024  # 33MB to match protocol MaxValueSize with overhead
  )

proc start*(server: BitBarrelServer) =
  ## Start the server
  echo "BitBarrel server starting on ", server.config.address, ":", server.config.port
  echo "Data directory: ", server.config.dataDir

  # Ensure data directory exists
  try:
    createDir(server.config.dataDir)
  except OSError as e:
    echo ""
    echo "Error: Failed to create data directory: ", server.config.dataDir
    echo "OS Error: ", e.msg
    quit(1)

  try:
    server.mummyServer.serve(server.config.port, server.config.address)
  except MummyError as e:
    if e.msg.contains("Address already in use"):
      echo ""
      echo "Error: Port ", server.config.port, " is already in use."
      echo "Another BitBarrel server or process may be running on this port."
      echo ""
      echo "Solutions:"
      echo "  1. Stop the other process using: lsof -i :", server.config.port
      echo "  2. Use a different port: bitbarrel -p=9877 serve"
    else:
      echo ""
      echo "Error: Failed to start server - ", e.msg
      echo "Exception: ", e.repr
    quit(1)
  except CatchableError as e:
    echo ""
    echo "Error: Unexpected error while starting server - ", e.msg
    echo "Exception: ", e.repr
    quit(1)

proc stop*(server: BitBarrelServer) =
  ## Gracefully stop the server
  echo "Shutting down BitBarrel server..."

  # Close all barrels (this breaks the circular reference by closing barrels)
  echo "Closing all barrels..."
  server.registry.closeAll()
  echo "Barrels closed"

  # Close MummyX server
  echo "Closing Mummy server..."
  server.mummyServer.close()
  echo "Mummy server closed"

  echo "Server stopped"