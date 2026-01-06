## BitBarrel Network Server
##
## WebSocket/HTTP server built on MummyX for remote BitBarrel access

import std/[net, locks, tables, strutils, os, sequtils, strformat]
import mummy
import mummy/routers
import session
import auth as authjwt
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
    auth*: authjwt.AuthConfig  ## Authentication configuration
    webadminPath*: string ## Path to webadmin build files
    webadminEnabled*: bool ## Enable webadmin UI serving

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
      headers["Content-Length"] = $content.len
      headers["Cache-Control"] = "public, max-age=3600"
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
    if not session.authSession.canManageBarrels():
      resp.status = statusUnauthorized
      resp.value = "Unauthorized: admin role required"
    else:
      echo fmt"[DEBUG] cmdCreateBarrel: name='{req.key}', configLen={req.value.len}"
      try:
        let config = if req.value.len > 0:
          parseBarrelConfigJson(req.value)
        else:
          defaultBarrelConfig()
        echo fmt"[DEBUG] config parsed, dataDir={server.config.dataDir}, calling createBarrel..."

        if server.registry.createBarrel(req.key, config):
          resp.status = statusOk
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
          echo fmt"[DEBUG] createBarrel failed for '{req.key}' (status: {resp.status}, msg: {resp.value})"
      except ConfigValidationError as e:
        resp.status = statusInvalid
        resp.value = e.msg
        echo fmt"[DEBUG] ConfigValidationError: {e.msg}"
      except CatchableError as e:
        resp.status = statusError
        resp.value = fmt"Failed to create barrel: {e.msg}"
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
        resp.value = serializeBarrelConfig(barrel.get().config)
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
          let newConfig = applyJsonUpdatesToConfig(barrel.get().config, req.value)

          # Validate mode hasn't changed (not allowed at runtime)
          if newConfig.mode != barrel.get().config.mode:
            resp.status = statusError
            resp.value = "Cannot change barrel mode at runtime"
          else:
            # Update config and persist to YAML
            barrel.get().setConfig(newConfig)
            resp.status = statusOk
            resp.value = serializeBarrelConfig(barrel.get().config)
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
          let b = barrel.get()
          let authSess = server.sessions[ws.clientId].authSession

          case req.command:
          of cmdGet:
            if not authSess.canReadData():
              resp.status = statusUnauthorized
              resp.value = "Unauthorized: read access required"
            else:
              let value = b.get(req.key)
              if value.len > 0:
                resp.status = statusOk
                resp.value = value
              else:
                resp.status = statusNotFound

          of cmdSet:
            if not authSess.canWriteData():
              resp.status = statusUnauthorized
              resp.value = "Unauthorized: write access required"
            elif b.set(req.key, req.value):
              resp.status = statusOk
            else:
              resp.status = statusError

          of cmdDelete:
            if not authSess.canWriteData():
              resp.status = statusUnauthorized
              resp.value = "Unauthorized: write access required"
            elif b.delete(req.key):
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

          of cmdGetBarrelConfig, cmdSetBarrelConfig, cmdGetBarrelStats:
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
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
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
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
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
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
            try:
              # Decode count request (similar to range query format)
              let params = protocol.decodeRangeRequest(req.value)
              let count = b.keysInRange(params.startKey, params.endKey).len
              resp.status = statusOk
              resp.value = $count

            except CatchableError as e:
              resp.status = statusError
              resp.value = "Range count error: " & e.msg

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
          let b = barrel.get()
          let authSess = server.sessions[ws.clientId].authSession
          if not authSess.canReadData():
            resp.status = statusUnauthorized
            resp.value = "Unauthorized: read access required"
          else:
            try:
              # Get statistics from the barrel
              let stats = b.getStats()
              # Encode to JSON and send response
              resp.status = statusOk
              resp.value = encodeBarrelStats(stats)
            except CatchableError as e:
              resp.status = statusError
              resp.value = "Failed to get barrel stats: " & e.msg

  else:
    resp.status = statusInvalid
    resp.value = "Unknown command"

  # Send response
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

  var headers = emptyHttpHeaders()
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

      var headers = emptyHttpHeaders()
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

  # Webadmin static file routes (only if webadmin is enabled)
  if config.webadminEnabled and config.webadminPath.len > 0:
    router.get("/admin/*", proc(req: mummy.Request) {.gcsafe.} = serveStaticFile(serverRef, req))
    router.get("/favicon.ico", proc(req: mummy.Request) {.gcsafe.} = serveStaticFile(serverRef, req))
    router.get("/", proc(req: mummy.Request) {.gcsafe.} = serveWebadminRoot(serverRef, req))

  result.mummyServer = newServer(
    router.toHandler(),
    websocketHandler = proc(ws: WebSocket, event: WebSocketEvent, msg: Message) {.gcsafe.} =
      websocketHandler(serverRef, ws, event, msg),
    maxMessageLen = 33 * 1024 * 1024  # 33MB to match protocol MaxValueSize with overhead
  )

proc start*(server: BitBarrelServer) =
  ## Start the server
  echo "BitBarrel server starting on ", server.config.address, ":", server.config.port
  echo "Data directory: ", server.config.dataDir

  # Ensure data directory exists
  createDir(server.config.dataDir)

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
      quit(1)
    else:
      raise

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