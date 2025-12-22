## BitBarrel Network Server
##
## WebSocket/HTTP server built on MummyX for remote BitBarrel access

import std/[net, locks, tables, strutils, os, sequtils, strformat]
import mummy
import mummy/routers
import session
import ../bitbarrel/barrel
import ../bitbarrel/refs
import ../bitbarrel/config_json

# Import protocol module
import protocol
# Alias to avoid conflict with mummy.Request
type ProtoRequest = protocol.Request

type
  BitBarrelServerObj* = object
    registry*: BarrelRegistry         ## All open barrels
    sessions*: Table[uint64, Session] ## WebSocket client -> session
    mummyServer: Server
    config*: ServerConfig              ## Server configuration (public for tests)
    sessionsLock: Lock
    seqCounter: uint64                ## Global seq counter for requests
    startTime: float                  ## Server start time (epochTime)

  BitBarrelServer* = ref BitBarrelServerObj  # Use ref to avoid ORC cleanup issues

  ServerConfig* = object
    address*: string       ## Default: "0.0.0.0"
    port*: Port           ## Default: 9876
    dataDir*: string      ## Base directory for barrels
    workerThreads*: int   ## Default: CPU * 10

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


proc handleWebSocketMessage*(
  server: BitBarrelServer,
  ws: WebSocket,
  data: string
) =
  ## Process a binary WebSocket message from client
  var req: ProtoRequest
  try:
    req = decodeRequest(data)
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
    try:
      let config = if req.value.len > 0:
        parseBarrelConfigJson(req.value)
      else:
        defaultBarrelConfig()

      if server.registry.createBarrel(req.key, config):
        resp.status = statusOk
      else:
        resp.status = statusBarrelExists
    except ConfigValidationError as e:
      resp.status = statusInvalid
      resp.value = e.msg
    except CatchableError:
      resp.status = statusError

  of cmdOpenBarrel:
    if server.registry.openBarrel(req.key):
      resp.status = statusOk
    else:
      resp.status = statusBarrelNotFound

  of cmdUseBarrel:
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
    if server.registry.closeBarrel(req.key):
      resp.status = statusOk
      # Clear current barrel if it was the one being closed
      withLock server.sessionsLock:
        if server.sessions[ws.clientId].getCurrentBarrel() == req.key:
          server.sessions[ws.clientId].clearCurrentBarrel()
    else:
      resp.status = statusBarrelNotFound

  of cmdDropBarrel:
    if server.registry.dropBarrel(req.key):
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
        resp.value = serializeBarrelConfig(barrel.get().config)
    except CatchableError as e:
      resp.status = statusError
      resp.value = e.msg

  of cmdSetBarrelConfig:
    # TODO: Implement setBarrelConfig in BarrelRegistry
    resp.status = statusError
    resp.value = "setBarrelConfig not yet implemented"

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
          let b = barrel.get()

          case req.command:
          of cmdGet:
            let value = b.get(req.key)
            if value.len > 0:
              resp.status = statusOk
              resp.value = value
            else:
              resp.status = statusNotFound

          of cmdSet:
            if b.set(req.key, req.value):
              resp.status = statusOk
            else:
              resp.status = statusError

          of cmdDelete:
            if b.delete(req.key):
              resp.status = statusOk
            else:
              resp.status = statusError

          of cmdExists:
            if b.exists(req.key):
              resp.status = statusOk
              resp.value = "true"
            else:
              resp.status = statusOk
              resp.value = "false"

          of cmdCount:
            resp.status = statusOk
            resp.value = $b.count()

          of cmdListKeys:
            # TODO: Support pagination via req.value
            let keys = b.listKeys()
            resp.status = statusOk
            resp.value = keys.join(",")

          of cmdPing, cmdCreateBarrel, cmdOpenBarrel, cmdUseBarrel, cmdCloseBarrel, cmdListBarrels, cmdDropBarrel:
            # These commands are handled at the outer level
            discard

          of cmdGetBarrelConfig, cmdSetBarrelConfig:
            # These commands are handled at the outer level
            discard

          of cmdRangeQuery, cmdPrefixQuery, cmdRangeCount:
            # These commands are handled at the outer level
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
                  result.value = b.get(key)

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

                let value = b.get(currentKey)
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
          let b = barrel.get()
          try:
            # Decode range query request
            let params = protocol.decodeRangeRequest(req.value)

            # Execute range query
            let (items, nextCursor, hasMore) = b.itemsInRange(
              params.startKey, params.endKey, params.limit, params.cursor)

            # Encode and send response
            let respData = protocol.encodeRangeResponse(
              protocol.RangeResponse(items: items, nextCursor: nextCursor, hasMore: hasMore))
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
          let b = barrel.get()
          try:
            # Decode prefix query request
            let params = protocol.decodePrefixRequest(req.value)

            # Execute prefix query
            let (items, nextCursor, hasMore) = b.itemsWithPrefix(
              params.prefix, params.limit, params.cursor)

            # Encode and send response
            let respData = protocol.encodeRangeResponse(
              protocol.RangeResponse(items: items, nextCursor: nextCursor, hasMore: hasMore))
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
          let b = barrel.get()
          try:
            # Decode count request (similar to range query format)
            let params = protocol.decodeRangeRequest(req.value)
            let count = b.keysInRange(params.startKey, params.endKey).len
            resp.status = statusOk
            resp.value = $count

          except CatchableError as e:
            resp.status = statusError
            resp.value = "Range count error: " & e.msg

  else:
    resp.status = statusInvalid
    resp.value = "Unknown command"

  # Send response
  ws.send(encodeResponse(resp), BinaryMessage)

proc websocketUpgradeHandler*(server: BitBarrelServer, request: mummy.Request) =
  ## Handle WebSocket upgrade request
  try:
    let ws = request.upgradeToWebSocket()
    # Session will be created on first message
    ws.send("Connected to BitBarrel network server")
  except CatchableError:
    request.respond(400, body = "WebSocket upgrade failed")

proc websocketHandler*(
  server: BitBarrelServer,
  ws: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  ## Handle WebSocket events
  {.gcsafe.}:
    case event:
    of OpenEvent:
      # Session created lazily on first message
      echo "WebSocket connection opened: clientId=", ws.clientId

    of MessageEvent:
      if message.kind == BinaryMessage:
        server.handleWebSocketMessage(ws, message.data)
      else:
        # Text messages not supported for binary protocol
        ws.send(encodeResponse(invalidResponse(0, "Use binary protocol")), BinaryMessage)

    of ErrorEvent:
      echo "WebSocket error: clientId=", ws.clientId

    of CloseEvent:
      echo "WebSocket connection closed: clientId=", ws.clientId
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

  let b = barrel.get()

  case request.httpMethod:
  of "GET":
    let value = b.get(key)
    if value.len > 0:
      request.respond(200, body = value)
    else:
      request.respond(404)

  of "PUT":
    let value = request.body
    if b.set(key, value):
      var hdrs: HttpHeaders
      hdrs["Location"] = "/barrels/" & barrelName & "/kv/" & key
      request.respond(201, hdrs)
    else:
      request.respond(500, body = """{"error":"Failed to set key"}""")

  of "DELETE":
    if b.delete(key):
      request.respond(204)
    else:
      request.respond(500, body = """{"error":"Failed to delete key"}""")

  of "HEAD":
    if b.exists(key):
      request.respond(200)
    else:
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

  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, statsJson)

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

    let b = barrel.get()

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
          result.value = b.get(key)

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

        let value = b.get(currentKey)
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

      var headers: HttpHeaders
      headers["Content-Type"] = "application/json"
      request.respond(200, headers, jsonResponse)

    except CatchableError as e:
      request.respond(500, body = fmt("{{\"error\":\"{e.msg}\"}}"))

# Routes are registered directly in newServer() to properly capture the server reference

proc newServer*(config: ServerConfig): BitBarrelServer =
  ## Create a new BitBarrel server instance
  new(result)
  result.registry = newBarrelRegistry(config.dataDir)
  result.sessions = initTable[uint64, Session]()
  result.config = config
  result.sessionsLock = Lock()
  result.seqCounter = 0
  result.startTime = epochTime()
  initLock(result.sessionsLock)

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

  result.mummyServer = newServer(
    router.toHandler(),
    websocketHandler = proc(ws: WebSocket, event: WebSocketEvent, msg: Message) {.gcsafe.} =
      websocketHandler(serverRef, ws, event, msg)
  )

proc start*(server: BitBarrelServer) =
  ## Start the server
  echo "BitBarrel server starting on ", server.config.address, ":", server.config.port
  echo "Data directory: ", server.config.dataDir

  # Ensure data directory exists
  createDir(server.config.dataDir)

  server.mummyServer.serve(Port(server.config.port), server.config.address)

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