## BitBarrel Network Server
##
## WebSocket/HTTP server built on MummyX for remote BitBarrel access

import std/[net, locks, tables, strutils, os, cpuinfo]
import mummy
import mummy/routers
import session
import ../bitbarrel/barrel

# Import protocol module
import protocol
# Alias to avoid conflict with mummy.Request
type ProtoRequest = protocol.Request

type
  BitBarrelServer* = object
    registry*: BarrelRegistry         ## All open barrels
    sessions*: Table[uint64, Session] ## WebSocket client -> session
    mummyServer: Server
    config: ServerConfig
    sessionsLock: Lock
    seqCounter: uint64                ## Global seq counter for requests
    startTime: float                  ## Server start time (epochTime)

  ServerConfig* = object
    address*: string       ## Default: "0.0.0.0"
    port*: Port           ## Default: 9876
    dataDir*: string      ## Base directory for barrels
    workerThreads*: int   ## Default: CPU * 10


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
  server: var BitBarrelServer,
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
        # TODO: Parse config from JSON
        defaultBarrelConfig()
      else:
        defaultBarrelConfig()

      if server.registry.createBarrel(req.key, config):
        resp.status = statusOk
      else:
        resp.status = statusBarrelExists
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

          else:
            discard  # Never reached

  else:
    resp.status = statusInvalid
    resp.value = "Unknown command"

  # Send response
  ws.send(encodeResponse(resp), BinaryMessage)

proc websocketUpgradeHandler*(server: var BitBarrelServer, request: mummy.Request) =
  ## Handle WebSocket upgrade request
  try:
    let ws = request.upgradeToWebSocket()
    # Session will be created on first message
    ws.send("Connected to BitBarrel network server")
  except CatchableError:
    request.respond(400, body = "WebSocket upgrade failed")

proc websocketHandler*(
  server: var BitBarrelServer,
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

proc handleRestBarrels*(server: var BitBarrelServer, request: mummy.Request) =
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

proc handleRestBarrel*(server: var BitBarrelServer, request: mummy.Request, barrelName: string) =
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

proc handleRestKV*(server: var BitBarrelServer, request: mummy.Request, barrelName: string, key: string) =
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

proc handleRestStatus*(server: var BitBarrelServer, request: mummy.Request) =
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

proc restHandler*(server: var BitBarrelServer, request: mummy.Request) =
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

proc newServer*(config: ServerConfig): BitBarrelServer =
  ## Create a new BitBarrel server instance
  result = BitBarrelServer(
    registry: newBarrelRegistry(config.dataDir),
    sessions: initTable[uint64, Session](),
    config: config,
    sessionsLock: Lock(),
    seqCounter: 0,
    startTime: epochTime()
  )
  initLock(result.sessionsLock)

  # Create MummyX router
  var router: Router
  router.get("/status", proc(req: mummy.Request) = restHandler(result, req))
  router.get("/ws", proc(req: mummy.Request) = websocketUpgradeHandler(result, req))
  router.post("/barrels", proc(req: mummy.Request) = restHandler(result, req))
  router.get("/barrels", proc(req: mummy.Request) = restHandler(result, req))
  router.delete("/barrels/*", proc(req: mummy.Request) = restHandler(result, req))
  router.get("/barrels/*", proc(req: mummy.Request) = restHandler(result, req))
  router.put("/barrels/*/kv/*", proc(req: mummy.Request) = restHandler(result, req))
  router.get("/barrels/*/kv/*", proc(req: mummy.Request) = restHandler(result, req))
  router.delete("/barrels/*/kv/*", proc(req: mummy.Request) = restHandler(result, req))
  router.head("/barrels/*/kv/*", proc(req: mummy.Request) = restHandler(result, req))

  # Create server with TaskPools for performance
  result.mummyServer = newServer(
    router.toHandler(),
    websocketHandler = proc(ws: WebSocket, event: WebSocketEvent, msg: Message) =
      websocketHandler(result, ws, event, msg),
    workerThreads = if config.workerThreads > 0: config.workerThreads else: countProcessors() * 10,
    executionModel = TaskPools  # 25x faster for I/O-bound work
  )

proc start*(server: var BitBarrelServer) =
  ## Start the server
  echo "BitBarrel server starting on ", server.config.address, ":", server.config.port
  echo "Data directory: ", server.config.dataDir

  # Ensure data directory exists
  createDir(server.config.dataDir)

  server.mummyServer.serve(Port(server.config.port), server.config.address)

proc stop*(server: var BitBarrelServer) =
  ## Gracefully stop the server
  echo "Shutting down BitBarrel server..."

  # Close all barrels
  server.registry.closeAll()

  # Close MummyX server
  server.mummyServer.close()

  echo "Server stopped"