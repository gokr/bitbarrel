## BitBarrel Network Client
##
## WebSocket client library for BitBarrel network operations using the
## https://github.com/gokr/whisky library.
##
## To use a different WebSocket implementation, modify this file to replace
## the whisky dependency with another library.

import std/[locks, tables, strformat, net, strutils, os, httpclient, times]
import whisky
import protocol

type
  ServerInfo* = object
    ## Information received from server during handshake
    versionMajor*: int
    versionMinor*: int
    serverId*: string
    availablePlugins*: seq[string]

  BitBarrelClient* = object
    ## Client for BitBarrel network operations
    ##
    ## Manages a single WebSocket connection to a BitBarrel server
    ## and provides a high-level API for barrel and key-value operations
    host*: string
    port*: Port
    ws: WebSocket
    wsUrl: string
    connected*: bool
    seqCounter*: uint32
    currentBarrel*: string
    pending*: Table[uint32, protocol.Response]
    lock: Lock
    token*: string            ## JWT authorization token
    serverInfo*: ServerInfo    ## Server information from handshake

  ClientConfig* = object
    ## Configuration for BitBarrel client connections
    host*: string              ## Server host (default: "localhost")
    port*: Port              ## Server port (default: 9876)
    connectTimeout*: int     ## Connection timeout in ms (default: 5000)
    token*: string            ## JWT authorization token

  ClientError* = object of CatchableError
    ## Raised when client operations fail

  TraverseOptions* = object
    ## Options for reference traversal operations
    includeFullData*: bool    ## Return full values or just paths
    extractArrays*: bool      ## Extract array elements individually
    firstOnly*: bool          ## Stop after first result

  Pipeline* = object
    ## Pipeline for sending multiple requests without waiting
    ## Improves throughput by batching operations
    client*: ptr BitBarrelClient
    pendingSeqs*: seq[uint32]  ## Sequence numbers of sent requests
    responses*: seq[protocol.Response]  ## Collected responses
    lock*: Lock

proc newClient*(config: ClientConfig): BitBarrelClient =
  ## Create a new BitBarrel client
  ##
  ## **Example:**
  ## ```nim
  ## var config = ClientConfig(
  ##   host: "localhost",
  ##   port: 9876.Port,
  ##   connectTimeout: 5000,
  ##   token: "your-jwt-token"
  ## )
  ## var client = newClient(config)
  ## ```
  let url = fmt"ws://{config.host}:{config.port}/ws"
  result = BitBarrelClient(
    host: config.host,
    port: config.port,
    wsUrl: url,
    connected: false,
    seqCounter: 0,
    currentBarrel: "",
    pending: initTable[uint32, protocol.Response](),
    token: config.token
  )
  initLock(result.lock)

proc newClient*(host: string = "localhost", port: Port = 9876.Port, token: string = ""): BitBarrelClient =
  ## Create client with default config
  ##
  ## **Example:**
  ## ```nim
  ## # Create with defaults (localhost:9876)
  ## var client = newClient()
  ##
  ## # Create with custom host
  ## var client2 = newClient("192.168.1.100", 8080.Port)
  ##
  ## # Create with auth token
  ## var client3 = newClient("localhost", 9876.Port, "your-jwt-token")
  ## ```
  newClient(ClientConfig(host: host, port: port, token: token))

proc connect*(client: var BitBarrelClient) =
  ## Connect to the server
  ##
  ## Performs WebSocket handshake with the BitBarrel server.
  ## Automatically called by operations if not already connected.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient("localhost", 9876.Port)
  ## client.connect()  # Explicit connect
  ##
  ## # Or let operations auto-connect
  ## client.createBarrel("mydb")  # Connects automatically
  ##
  ## # With authentication
  ## var client = newClient("localhost", 9876.Port, "your-jwt-token")
  ## client.connect()
  ## ```
  if client.connected:
    return  # Already connected

  let url = fmt"ws://{client.host}:{client.port}/ws"
  try:
    if client.token.len > 0:
      var headers = newHttpHeaders()
      headers["Authorization"] = "Bearer " & client.token
      client.ws = newWebSocket(url, extraHeaders=headers)
    else:
      client.ws = newWebSocket(url)

    # Wait for binary handshake message (protocol v1.1+)
    const maxAttempts = 50  # 50 * 100ms = 5 seconds
    var attempts = 0

    while attempts < maxAttempts:
      let msg = client.ws.receiveMessage(timeout = 100)
      if msg.isSome():
        let m = msg.get()
        if m.kind == BinaryMessage:
          try:
            let handshake = protocol.decodeHandshake(m.data)
            client.serverInfo = ServerInfo(
              versionMajor: int(handshake.versionMajor),
              versionMinor: int(handshake.versionMinor),
              serverId: handshake.serverId,
              availablePlugins: handshake.plugins
            )
            client.connected = true
            return
          except CatchableError:
            # Not a valid handshake, might be old server
            discard
        elif m.kind == TextMessage and m.data.contains("Connected to BitBarrel"):
          # Fallback for v1.0 servers
          client.serverInfo = ServerInfo(
            versionMajor: 1,
            versionMinor: 0,
            serverId: "",
            availablePlugins: @[]
          )
          client.connected = true
          return

      inc attempts
    raise newException(ClientError, "No handshake message received from server")

  except CatchableError as e:
    raise newException(ClientError, fmt("Failed to connect: {e.msg}"))

proc close*(client: var BitBarrelClient) {.raises: [].} =
  ## Close connection
  ##
  ## Closes the WebSocket connection to the server.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ##
  ## # Done with operations
  ## client.close()
  ## ```
  if client.connected:
    try:
      client.ws.close()
    except:
      discard
    client.connected = false

proc sendAndWait*(client: var BitBarrelClient, req: Request, timeoutMs: int = 30000): protocol.Response =
  ## Send request and wait for response
  var mutableReq = req
  mutableReq.seq = client.seqCounter
  client.seqCounter += 1

  try:
    # Send request as binary frame
    when defined(debug):
      echo &"[Client] sendAndWait: seq={mutableReq.seq} timeout={timeoutMs}ms"
    client.ws.send(encodeRequest(mutableReq), kind = BinaryMessage)

    # Wait for response
    var attempts = 0
    const pollTimeout = 100  # 100ms per poll
    let maxAttempts = timeoutMs div pollTimeout

    while attempts < maxAttempts:
      let msg = client.ws.receiveMessage(timeout = pollTimeout)
      if msg.isSome() and msg.get().kind == BinaryMessage:
        let resp = decodeResponse(msg.get().data)
        when defined(debug):
          echo &"[Client] sendAndWait: received response seq={resp.seq}"
        if resp.seq == mutableReq.seq:
          return resp
      inc attempts

    raise newException(ClientError, "Response timeout")

  except CatchableError as e:
    raise newException(ClientError, fmt"Communication error: {e.msg}")

# Barrel management operations
proc createBarrel*(client: var BitBarrelClient, name: string, config: string = ""): bool =
  ## Create a new barrel on the server
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.createBarrel("ordered", """{"mode": "bmCritBit"}""")
  ## ```
  client.connect()

  let req = Request(command: cmdCreateBarrel, key: name, value: config)
  let resp = client.sendAndWait(req)
  if resp.status != statusOk:
    echo "[Client] createBarrel failed: status=", resp.status, ", error=", resp.value
  return resp.status == statusOk

proc openBarrel*(client: var BitBarrelClient, name: string): bool =
  ## Open an existing barrel on the server
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.openBarrel("existing_db")
  ## ```
  client.connect()

  let req = Request(command: cmdOpenBarrel, key: name)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc useBarrel*(client: var BitBarrelClient, name: string): bool =
  ## Set current barrel for this client session
  ##
  ## All key-value operations will use the selected barrel
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.useBarrel("mydb")
  ##
  ## client.set("key", "value")
  ## ```
  client.connect()

  let req = Request(command: cmdUseBarrel, key: name)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk:
    client.currentBarrel = name
    return true
  return false

proc listBarrels*(client: var BitBarrelClient): seq[string] =
  ## List all available barrels on the server
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ##
  ## let barrels = client.listBarrels()
  ## for name in barrels:
  ##   echo name
  ## ```
  client.connect()

  let req = Request(command: cmdListBarrels)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk and resp.value.len > 0:
    return resp.value.split(',')
  return @[]

proc deleteBarrel*(client: var BitBarrelClient, name: string): bool =
  ## Delete a barrel and all its data
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ##
  ## client.createBarrel("temp")
  ## client.deleteBarrel("temp")
  ## ```
  client.connect()

  let req = Request(command: cmdDropBarrel, key: name)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk:
    if name == client.currentBarrel:
      client.currentBarrel = ""
    return true
  return false

# Basic key-value operations (require current barrel)
proc get*(client: var BitBarrelClient, key: string): string =
  ## Get value by key
  ##
  ## Raises `ClientError` if no barrel is selected or key is not found
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.useBarrel("mydb")
  ##
  ## client.set("user:1", "Alice")
  ## let value = client.get("user:1")  # Returns "Alice"
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  let req = Request(command: cmdGet, key: key)
  let resp = client.sendAndWait(req)

  if resp.status == statusNotFound:
    raise newException(ClientError, fmt"Key not found: {key}")
  elif resp.status != statusOk:
    raise newException(ClientError, fmt"GET failed: {resp.status}")

  return resp.value

proc set*(client: var BitBarrelClient, key, value: string): bool =
  ## Set key-value pair
  ##
  ## Raises `ClientError` if no barrel is selected
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.useBarrel("mydb")
  ##
  ## client.set("user:1", "Alice")
  ## client.set("config", """{"setting": 42}""")
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  # Use protocol v1.1 format with flags (v1.1 compatible)
  let req = Request(command: protocol.cmdSet, key: key, value: value,
                    flags: protocol.rfNone, ttl: -1.int32)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc setWithTtl*(client: var BitBarrelClient, key, value: string, ttlSeconds: int): bool =
  ## Set key-value pair with TTL
  ##
  ## The key will expire after `ttlSeconds` seconds.
  ## ttlSeconds must be >= 0 for TTL to be applied.
  ##
  ## Raises `ClientError` if no barrel is selected
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.useBarrel("mydb")
  ##
  ## client.setWithTtl("temp:session", "Active", 60)  # Expires in 60 seconds
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if ttlSeconds < 0:
    raise newException(ClientError, "TTL must be >= 0")

  client.connect()

  # Use protocol v1.1 format with flags and TTL
  let req = Request(command: protocol.cmdSet, key: key, value: value,
                    flags: protocol.rfHasTtl, ttl: int32(ttlSeconds))
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc watchKeys*(client: var BitBarrelClient, pattern: string): string =
  ## Watch keys matching pattern for changes
  ##
  ## Uses Pub/Sub internally to subscribe to key change events.
  ## Client will receive async messages when keys matching the pattern change.
  ##
  ## Returns a watch ID for later unwatching.
  ##
  ## Raises `ClientError` if no barrel is selected
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.useBarrel("mydb")
  ##
  ## let watchId = client.watchKeys("user:*")  # Watch user keys
  ## # Set a key that will trigger event
  ## client.set("user:123", "Bob")
  ## # Later: stop watching
  ## client.unwatchKeys(watchId)
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  let watchReq = protocol.WatchRequest(barrelName: "", pattern: pattern, includeValues: true)
  let encodedWatch = protocol.encodeWatchRequest(watchReq)
  let req = Request(command: protocol.cmdWatchKey, key: "", value: encodedWatch)
  let resp = client.sendAndWait(req)

  if resp.status != protocol.statusOk:
    raise newException(ClientError, "Watch failed: " & resp.value)

  return resp.value

proc unwatchKeys*(client: var BitBarrelClient, watchId: string): bool =
  ## Stop watching keys by watch ID
  ##
  ## Raises `ClientError` if operation fails
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.useBarrel("mydb")
  ##
  ## let watchId = client.watchKeys("user:*")
  ## # ... do work ...
  ## client.unwatchKeys(watchId)  # Stop watching
  ## ```
  client.connect()

  let req = Request(command: protocol.cmdUnwatchKey, key: watchId, value: "")
  let resp = client.sendAndWait(req)
  return resp.status == protocol.statusOk

proc delete*(client: var BitBarrelClient, key: string): bool =
  ## Delete a key (using tombstone)
  ##
  ## Raises `ClientError` if no barrel is selected
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.useBarrel("mydb")
  ##
  ## client.set("temp", "data")
  ## client.delete("temp")
  ##
  ## echo client.exists("temp")  # false
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  let req = Request(command: cmdDelete, key: key)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc exists*(client: var BitBarrelClient, key: string): bool =
  ## Check if key exists
  ##
  ## Raises `ClientError` if no barrel is selected
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.useBarrel("mydb")
  ##
  ## client.set("key", "value")
  ## echo client.exists("key")    # true
  ## echo client.exists("missing")  # false
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  let req = Request(command: cmdExists, key: key)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk and resp.value == "true"

proc ping*(client: var BitBarrelClient): bool =
  ## Ping the server to check connectivity
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ##
  ## if client.ping():
  ##   echo "Server is reachable"
  ##
  ## client.close()
  ## ```
  client.connect()

  let req = Request(command: cmdPing)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk and resp.value == "pong"

# Range query operations (require bmCritBit mode barrel)

proc rangeQuery*(client: var BitBarrelClient, startKey: string = "", endKey: string = "",
                 limit: int = 1000, cursor: string = "", plugins: seq[string] = @[]): (seq[(string, string)], string, bool) =
  ## Query key-value pairs in range [startKey, endKey) with cursor-based pagination
  ## Requires barrel opened in bmCritBit mode
  ## Use empty strings for startKey/endKey to query entire barrel
  ## Returns: ``(items: seq[(string, string)], nextCursor: string, hasMore: bool)``
  ## plugins: Names of query result plugins to apply (optional)
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## let (items, nextCursor, hasMore) = client.rangeQuery("user:0", "user:999", 100)
  ##
  ## # Get next page
  ## if hasMore:
  ##   let (nextPage, nextCursor2, hasMore2) = client.rangeQuery("user:0", "user:999", 100, nextCursor)
  ##
  ## # Query entire barrel with defaults
  ## let (allItems, nextCursor3, hasMore3) = client.rangeQuery()
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  let params = protocol.RangeRequest(
    startKey: startKey,
    endKey: endKey,
    limit: limit,
    cursor: cursor,
    plugins: plugins
  )

  let req = Request(command: cmdRangeQuery, value: protocol.encodeRangeRequest(params))
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Range query failed: {resp.status}")

  let rangeResp = protocol.decodeRangeResponse(resp.value)
  result = (rangeResp.items, rangeResp.nextCursor, rangeResp.hasMore)

proc prefixQuery*(client: var BitBarrelClient, prefix: string,
                  limit: int = 1000, cursor: string = "", plugins: seq[string] = @[]): (seq[(string, string)], string, bool) =
  ## Query key-value pairs with prefix with cursor-based pagination
  ## Requires barrel opened in bmCritBit mode
  ## Returns: ``(items: seq[(string, string)], nextCursor: string, hasMore: bool)``
  ## plugins: Names of query result plugins to apply (optional)
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## # Get all users (keys starting with "user:")
  ## var cursor = ""
  ## var allUsers: seq[(string, string)]
  ##
  ## while true:
  ##   let (items, nextCursor, hasMore) = client.prefixQuery("user:", 100, cursor)
  ##   if items.len == 0: break
  ##   allUsers.add(items)
  ##   if not hasMore: break
  ##   cursor = nextCursor
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  let params = protocol.PrefixRequest(
    prefix: prefix,
    limit: limit,
    cursor: cursor,
    plugins: plugins
  )

  let req = Request(command: cmdPrefixQuery, value: protocol.encodePrefixRequest(params))
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Prefix query failed: {resp.status}")

  let rangeResp = protocol.decodeRangeResponse(resp.value)
  result = (rangeResp.items, rangeResp.nextCursor, rangeResp.hasMore)

# Reference traversal operations
proc traverse*(client: var BitBarrelClient, key: string, pathSpec: string,
               options: TraverseOptions): seq[protocol.TraverseResult] =
  ## Traverse references from a key using path specification
  ##
  ## PathSpec syntax: ``*`` for single reference, ``->*`` for following a reference
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.useBarrel("mydb")
  ##
  ## # Store interconnected data
  ## client.set("user:1", """{"name": "Alice", "friend": "user:2"}""")
  ## client.set("user:2", """{"name": "Bob"}""")
  ##
  ## # Traverse to find friends
  ## let options = TraverseOptions(
  ##   includeFullData: true,
  ##   extractArrays: false,
  ##   firstOnly: false
  ## )
  ## let results = client.traverse("user:1", "->friend", options)
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  var optionsByte: uint8 = 0
  if options.includeFullData:
    optionsByte = optionsByte or 0x01
  if options.extractArrays:
    optionsByte = optionsByte or 0x02
  if options.firstOnly:
    optionsByte = optionsByte or 0x04

  let tReq = TraverseRequest(
    seq: client.seqCounter,
    key: key,
    pathSpec: pathSpec,
    options: optionsByte
  )
  client.seqCounter += 1

  let encoded = encodeTraverseRequest(tReq)
  let req = Request(command: cmdTraverse, value: encoded)
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Traversal failed: {resp.status}")

  let (status, _, results) = decodeTraverseResults(resp.value)
  if status != statusOk:
    raise newException(ClientError, "Invalid traversal response")

  result = newSeq[protocol.TraverseResult](results.len)
  for i, res in results:
    result[i] = protocol.TraverseResult(
      path: res.path,
      key: res.key,
      value: res.value,
      extractedData: res.extractedData
    )

# Convenience overloads
proc traversePath*(client: var BitBarrelClient, key: string,
                   pathSpec: string): seq[protocol.TraverseResult] =
  ## Traverse with default options (include full data, no extraction)
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb")
  ## client.useBarrel("mydb")
  ##
  ## # Get all friends (traverse with defaults)
  ## let results = client.traversePath("user:1", "->friend")
  ##
  ## for res in results:
  ##   echo res.path, " => ", res.value
  ## ```
  let options = TraverseOptions(
    includeFullData: true,
    extractArrays: false,
    firstOnly: false
  )
  result = client.traverse(key, pathSpec, options)

proc traverseDepth*(client: var BitBarrelClient, key: string,
                    maxDepth: int): seq[protocol.TraverseResult] =
  ## Simple depth-based traversal (deprecated, use traversePath instead)
  ## This creates a path spec that follows all refs for N levels
  if maxDepth <= 0:
    return @[]

  var pathSpec = "*"
  for i in 1..<maxDepth:
    pathSpec.add("->*")

  let options = TraverseOptions(
    includeFullData: true,
    extractArrays: false,
    firstOnly: false
  )
  result = client.traverse(key, pathSpec, options)

# Keys-only range query operations (require bmCritBit mode barrel)

proc rangeQueryKeys*(client: var BitBarrelClient, startKey: string = "", endKey: string = "",
                     limit: int = 1000, cursor: string = ""): (seq[string], string, bool) =
  ## Query keys in range [startKey, endKey) with cursor-based pagination
  ## Requires barrel opened in bmCritBit mode
  ## Returns: ``(keys: seq[string], nextCursor: string, hasMore: bool)``
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## let (keys, nextCursor, hasMore) = client.rangeQueryKeys("user:0", "user:999", 100)
  ##
  ## # Get next page
  ## if hasMore:
  ##   let (nextPage, nextCursor2, hasMore2) = client.rangeQueryKeys("user:0", "user:999", 100, nextCursor)
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  let params = protocol.RangeRequest(
    startKey: startKey,
    endKey: endKey,
    limit: limit,
    cursor: cursor
  )

  let req = Request(command: cmdRangeKeys, value: protocol.encodeRangeRequest(params))
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Range keys query failed: {resp.status}")

  let keysResp = protocol.decodeKeysResponse(resp.value)
  result = (keysResp.keys, keysResp.nextCursor, keysResp.hasMore)

proc prefixQueryKeys*(client: var BitBarrelClient, prefix: string,
                      limit: int = 1000, cursor: string = ""): (seq[string], string, bool) =
  ## Query keys with prefix with cursor-based pagination
  ## Requires barrel opened in bmCritBit mode
  ## Returns: ``(keys: seq[string], nextCursor: string, hasMore: bool)``
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## # Get all user keys (keys starting with "user:")
  ## var cursor = ""
  ## var allKeys: seq[string]
  ##
  ## while true:
  ##   let (keys, nextCursor, hasMore) = client.prefixQueryKeys("user:", 100, cursor)
  ##   if keys.len == 0: break
  ##   allKeys.add(keys)
  ##   if not hasMore: break
  ##   cursor = nextCursor
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  let params = protocol.PrefixRequest(
    prefix: prefix,
    limit: limit,
    cursor: cursor
  )

  let req = Request(command: cmdPrefixKeys, value: protocol.encodePrefixRequest(params))
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Prefix keys query failed: {resp.status}")

  let keysResp = protocol.decodeKeysResponse(resp.value)
  result = (keysResp.keys, keysResp.nextCursor, keysResp.hasMore)

# Updated rangeCount with default values

proc rangeCount*(client: var BitBarrelClient, startKey: string = "", endKey: string = ""): int =
  ## Count keys in range [startKey, endKey)
  ##
  ## Requires barrel opened in bmCritBit mode
  ## Use empty strings for entire barrel
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## # Count keys in range
  ## let count = client.rangeCount("user:0", "user:999")
  ## echo "Found ", count, " users"
  ##
  ## # Count all keys in barrel
  ## let total = client.rangeCount()
  ## echo "Total keys: ", total
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  let params = protocol.RangeRequest(
    startKey: startKey,
    endKey: endKey,
    limit: 0,
    cursor: ""
  )

  let req = Request(command: cmdRangeCount, value: protocol.encodeRangeRequest(params))
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Range count failed: {resp.status}")

  result = parseInt(resp.value)

# Lazy pagination iterator for Nim client

type
  RangeIterator*[T] = object
    client*: ptr BitBarrelClient  ## ptr for safe GC in lazy iteration
    queryType*: string            ## "range" or "prefix"
    startKey*: string
    endKey*: string
    prefix*: string
    pageSize*: int
    buffer*: seq[T]               ## T = (string, string) or string
    cursor*: string
    exhausted*: bool

proc fetchNextPage*[T](it: var RangeIterator[T]) =
  ## Fetch next page into buffer
  ## Called automatically by iterator when buffer is empty
  if it.exhausted:
    return

  it.client[].connect()

  try:
    case it.queryType
    of "range":
      when T is string:
        let (keys, nextCursor, hasMore) = it.client.rangeQueryKeys(
          it.startKey, it.endKey, it.pageSize, it.cursor)
        it.buffer = keys
        it.cursor = nextCursor
        it.exhausted = not hasMore
      else:
        let (items, nextCursor, hasMore) = it.client.rangeQuery(
          it.startKey, it.endKey, it.pageSize, it.cursor)
        it.buffer = cast[seq[T]](items)
        it.cursor = nextCursor
        it.exhausted = not hasMore
    of "prefix":
      when T is string:
        let (keys, nextCursor, hasMore) = it.client.prefixQueryKeys(
          it.prefix, it.pageSize, it.cursor)
        it.buffer = keys
        it.cursor = nextCursor
        it.exhausted = not hasMore
      else:
        let (items, nextCursor, hasMore) = it.client.prefixQuery(
          it.prefix, it.pageSize, it.cursor)
        it.buffer = cast[seq[T]](items)
        it.cursor = nextCursor
        it.exhausted = not hasMore
    else:
      it.exhausted = true
  except CatchableError:
    it.exhausted = true

iterator items*[T](it: var RangeIterator[T]): T =
  ## Lazy iterator over range query results
  ## Fetches pages on-demand as items are consumed
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## # Iterate over entire barrel with lazy pagination
  ## var iter = newRangeIterator(client, "", "")
  ## for key, value in iter:
  ##   echo key, " => ", value
  ## ```
  defer: it.exhausted = true
  while not it.exhausted:
    if it.buffer.len == 0:
      it.fetchNextPage()
    if it.buffer.len == 0:
      break
    yield it.buffer[0]
    it.buffer.delete(0)

# Convenience procedures to create iterators

proc newRangeIterator*(client: var BitBarrelClient, startKey: string, endKey: string,
                       pageSize: int = 1000): RangeIterator[(string, string)] =
  ## Create a new lazy range query iterator for key-value pairs
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## var iter = newRangeIterator(client, "user:0", "user:999")
  ## for key, value in iter:
  ##   echo key, " => ", value
  ## ```
  result = RangeIterator[(string, string)](
    client: addr(client),
    queryType: "range",
    startKey: startKey,
    endKey: endKey,
    pageSize: pageSize,
    buffer: @[],
    cursor: "",
    exhausted: false
  )

proc newKeysIterator*(client: var BitBarrelClient, startKey: string, endKey: string,
                      pageSize: int = 1000): RangeIterator[string] =
  ## Create a new lazy range query iterator for keys only
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## var iter = newKeysIterator(client, "user:0", "user:999")
  ## for key in iter:
  ##   echo key
  ## ```
  result = RangeIterator[string](
    client: addr(client),
    queryType: "range",
    startKey: startKey,
    endKey: endKey,
    pageSize: pageSize,
    buffer: @[],
    cursor: "",
    exhausted: false
  )

proc newPrefixIterator*(client: var BitBarrelClient, prefix: string,
                        pageSize: int = 1000): RangeIterator[(string, string)] =
  ## Create a new lazy prefix query iterator for key-value pairs
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## var iter = newPrefixIterator(client, "user:")
  ## for key, value in iter:
  ##   echo key, " => ", value
  ## ```
  result = RangeIterator[(string, string)](
    client: addr(client),
    queryType: "prefix",
    prefix: prefix,
    pageSize: pageSize,
    buffer: @[],
    cursor: "",
    exhausted: false
  )

proc newKeysPrefixIterator*(client: var BitBarrelClient, prefix: string,
                            pageSize: int = 1000): RangeIterator[string] =
  ## Create a new lazy prefix query iterator for keys only
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.createBarrel("mydb", """{"mode": "bmCritBit"}""")
  ## client.useBarrel("mydb")
  ##
  ## var iter = newKeysPrefixIterator(client, "user:")
  ## for key in iter:
  ##   echo key
  ## ```
  result = RangeIterator[string](
    client: addr(client),
    queryType: "prefix",
    prefix: prefix,
    pageSize: pageSize,
    buffer: @[],
    cursor: "",
    exhausted: false
  )

# Pipelined batch operations for high-throughput scenarios

proc setMany*(client: var BitBarrelClient, pairs: openArray[(string, string)]): int =
  ## Set multiple key-value pairs using batch protocol
  ## Returns number of successful sets
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  # Create and encode batch set request
  let batchPairs = @pairs
  let batchReq = BatchSetRequest(seq: client.seqCounter, pairs: batchPairs)
  client.seqCounter += 1

  # Calculate timeout: base 30s + 50ms per item
  let timeoutMs = 30000 + 50 * batchPairs.len
  let req = Request(command: cmdBatchSet, value: encodeBatchSetRequest(batchReq), seq: batchReq.seq)
  let resp = client.sendAndWait(req, timeoutMs)

  if resp.status == statusOk and resp.value.len > 0:
    # Decode batch response
    try:
      let batchResp = decodeBatchSetResponse(resp.value)
      # Count successful operations
      var successCount = 0
      for status in batchResp.statuses:
        if status == uint8(ord(statusOk)):
          successCount += 1
      return successCount
    except CatchableError as e:
      raise newException(ClientError, "Failed to decode batch set response: " & e.msg)
  else:
    # Handle error
    if resp.status == statusNoBarrel:
      raise newException(ClientError, "No barrel selected")
    elif resp.status == statusUnauthorized:
      raise newException(ClientError, "Unauthorized: write access required")
    elif resp.status == statusBarrelNotFound:
      raise newException(ClientError, "Barrel not found")
    else:
      raise newException(ClientError, "Batch set failed: " & resp.value)

proc getMany*(client: var BitBarrelClient, keys: openArray[string]): seq[(string, string)] =
  ## Get multiple key-value pairs using batch protocol
  ## Returns seq of (key, value) for found keys
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  # Create and encode batch get request
  let batchKeys = @keys
  let batchReq = BatchGetRequest(seq: client.seqCounter, keys: batchKeys)
  client.seqCounter += 1

  # Calculate timeout: base 30s + 50ms per item
  let timeoutMs = 30000 + 50 * batchKeys.len
  let req = Request(command: cmdBatchGet, value: encodeBatchGetRequest(batchReq), seq: batchReq.seq)
  let resp = client.sendAndWait(req, timeoutMs)

  if resp.status == statusOk and resp.value.len > 0:
    # Decode batch response
    try:
      let batchResp = decodeBatchGetResponse(resp.value)
      result = @[]

      # Collect found items
      for i, item in batchResp.results:
        if item.status == uint8(ord(statusOk)):
          result.add((batchReq.keys[i], item.value))

      return result
    except CatchableError as e:
      raise newException(ClientError, "Failed to decode batch get response: " & e.msg)
  else:
    # Handle error
    if resp.status == statusNoBarrel:
      raise newException(ClientError, "No barrel selected")
    elif resp.status == statusUnauthorized:
      raise newException(ClientError, "Unauthorized: read access required")
    elif resp.status == statusBarrelNotFound:
      raise newException(ClientError, "Barrel not found")
    else:
      raise newException(ClientError, "Batch get failed: " & resp.value)

# ==================== Pipeline Operations ====================
# Pipelining sends multiple requests without waiting, improving throughput

proc startPipeline*(client: var BitBarrelClient): Pipeline =
  ## Start a new pipeline for batched operations
  ##
  ## Pipelining allows sending multiple requests without waiting for responses,
  ## significantly reducing network round-trip latency.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.useBarrel("mydb")
  ##
  ## var p = client.startPipeline()
  ## p.pipelineSet("key1", "value1")
  ## p.pipelineSet("key2", "value2")
  ## p.pipelineGet("key1")
  ## let results = p.waitAll()  # Returns all responses
  ## ```
  result = Pipeline(
    client: addr(client),
    pendingSeqs: @[],
    responses: @[],
  )
  initLock(result.lock)

proc pipelineSend*(pipeline: var Pipeline, req: Request): uint32 =
  ## Send a request through the pipeline (does not wait)
  ##
  ## Returns the sequence number of the sent request
  ##
  ## **Example:**
  ## ```nim
  ## var p = client.startPipeline()
  ## let req = newRequest(cmdSet, "key", "value")
  ## let seqNum = p.pipelineSend(req)
  ## # ... send more operations ...
  ## let results = p.waitAll()
  ## ```
  let client = pipeline.client
  client[].connect()

  var mutableReq = req
  mutableReq.seq = client[].seqCounter
  client[].seqCounter += 1

  withLock pipeline.lock:
    pipeline.pendingSeqs.add(mutableReq.seq)

  try:
    client[].ws.send(encodeRequest(mutableReq), kind = BinaryMessage)
    return mutableReq.seq
  except CatchableError as e:
    raise newException(ClientError, fmt("Pipeline send error: {e.msg}"))

proc pipelineGet*(pipeline: var Pipeline, key: string): uint32 =
  ## Queue a GET operation in the pipeline
  ##
  ## **Example:**
  ## ```nim
  ## var p = client.startPipeline()
  ## let seq1 = p.pipelineGet("user:1")
  ## let seq2 = p.pipelineGet("user:2")
  ## let results = p.waitAll()
  ## ## results[0] is response for seq1, results[1] is response for seq2
  ## ```
  let req = Request(command: protocol.cmdGet, key: key)
  pipeline.pipelineSend(req)

proc pipelineSet*(pipeline: var Pipeline, key, value: string): uint32 =
  ## Queue a SET operation in the pipeline
  ##
  ## **Example:**
  ## ```nim
  ## var p = client.startPipeline()
  ## p.pipelineSet("key1", "value1")
  ## p.pipelineSet("key2", "value2")
  ## let results = p.waitAll()
  ## ```
  let req = Request(command: protocol.cmdSet, key: key, value: value)
  pipeline.pipelineSend(req)

proc pipelineDelete*(pipeline: var Pipeline, key: string): uint32 =
  ## Queue a DELETE operation in the pipeline
  ##
  ## **Example:**
  ## ```nim
  ## var p = client.startPipeline()
  ## p.pipelineDelete("old:1")
  ## p.pipelineDelete("old:2")
  ## let results = p.waitAll()
  ## ```
  let req = Request(command: protocol.cmdDelete, key: key)
  pipeline.pipelineSend(req)

proc pipelineExists*(pipeline: var Pipeline, key: string): uint32 =
  ## Queue an EXISTS operation in the pipeline
  ##
  ## **Example:**
  ## ```nim
  ## var p = client.startPipeline()
  ## p.pipelineExists("user:1")
  ## let results = p.waitAll()
  ## echo results[0].value  ## "true" or "false"
  ## ```
  let req = Request(command: protocol.cmdExists, key: key)
  pipeline.pipelineSend(req)

proc waitAll*(pipeline: var Pipeline, timeoutMs: int = 30000): seq[protocol.Response] =
  ## Wait for all pipelined requests to complete
  ##
  ## Returns responses in the same order as requests were sent
  ##
  ## **Example:**
  ## ```nim
  ## var p = client.startPipeline()
  ## p.pipelineSet("k1", "v1")
  ## p.pipelineGet("k1")
  ## let results = p.waitAll()
  ## echo results[0].status  ## status set result
  ## echo results[1].value   ## "v1"
  ## ```
  result = @[]
  let client = pipeline.client

  # Collect responses for all pending seqs
  var remaining: Table[uint32, int]  # seq -> index in result

  withLock pipeline.lock:
    for i, seqNum in pipeline.pendingSeqs:
      remaining[seqNum] = i
    result.setLen(pipeline.pendingSeqs.len)

  # Wait for responses
  let startTime = epochTime()
  while remaining.len > 0:
    let elapsed = int((epochTime() - startTime) * 1000)
    if elapsed >= timeoutMs:
      raise newException(ClientError, "Pipeline timeout: " & $remaining.len & " requests pending")

    let msg = client[].ws.receiveMessage(timeout = 100)
    if msg.isSome() and msg.get().kind == BinaryMessage:
      try:
        let resp = decodeResponse(msg.get().data)
        withLock pipeline.lock:
          if resp.seq in remaining:
            let idx = remaining[resp.seq]
            result[idx] = resp
            remaining.del(resp.seq)
      except CatchableError:
        discard  # Ignore decode errors - might be for other concurrent operations

  # Clear pending seqs
  withLock pipeline.lock:
    pipeline.pendingSeqs.setLen(0)

proc close*(pipeline: var Pipeline) =
  ## Close the pipeline and clear pending operations
  ##
  ## Any pending requests will not receive responses
  ##
  ## **Example:**
  ## ```nim
  ## var p = client.startPipeline()
  ## p.pipelineSet("key", "value")
  ## p.close()  # Discard pending operations
  ## ```
  withLock pipeline.lock:
    pipeline.pendingSeqs.setLen(0)
    pipeline.responses.setLen(0)

proc deleteMany*(client: var BitBarrelClient, keys: openArray[string]): int =
  ## Delete multiple keys using batch protocol
  ## Returns number of successful deletions
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  client.connect()

  # Create and encode batch delete request
  let batchKeys = @keys
  let batchReq = BatchDeleteRequest(seq: client.seqCounter, keys: batchKeys)
  client.seqCounter += 1

  let req = Request(command: cmdBatchDelete, value: encodeBatchDeleteRequest(batchReq), seq: batchReq.seq)
  let resp = client.sendAndWait(req)

  if resp.status == statusOk and resp.value.len > 0:
    # Decode batch response
    try:
      let batchResp = decodeBatchDeleteResponse(resp.value)
      # Count successful operations
      var successCount = 0
      for status in batchResp.statuses:
        if status == uint8(ord(statusOk)):
          successCount += 1
      return successCount
    except CatchableError as e:
      raise newException(ClientError, "Failed to decode batch delete response: " & e.msg)
  else:
    # Handle error
    if resp.status == statusNoBarrel:
      raise newException(ClientError, "No barrel selected")
    elif resp.status == statusUnauthorized:
      raise newException(ClientError, "Unauthorized: write access required")
    elif resp.status == statusBarrelNotFound:
      raise newException(ClientError, "Barrel not found")
    else:
      raise newException(ClientError, "Batch delete failed: " & resp.value)
