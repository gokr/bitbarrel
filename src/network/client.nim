## BitBarrel Network Client
##
## WebSocket client library for BitBarrel network operations using the
## https://github.com/gokr/whisky library.
##
## To use a different WebSocket implementation, modify this file to replace
## the whisky dependency with another library.

import std/[locks, tables, strformat, net, strutils, os]
import whisky
import protocol

type
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
    pending*: Table[uint32, Response]
    lock: Lock

  ClientConfig* = object
    ## Configuration for BitBarrel client connections
    host*: string              ## Server host (default: "localhost")
    port*: Port              ## Server port (default: 9876)
    connectTimeout*: int     ## Connection timeout in ms (default: 5000)

  ClientError* = object of CatchableError
    ## Raised when client operations fail

  TraverseOptions* = object
    ## Options for reference traversal operations
    includeFullData*: bool    ## Return full values or just paths
    extractArrays*: bool      ## Extract array elements individually
    firstOnly*: bool          ## Stop after first result

proc newClient*(config: ClientConfig): BitBarrelClient =
  ## Create a new BitBarrel client
  ##
  ## **Example:**
  ## ```nim
  ## var config = ClientConfig(
  ##   host: "localhost",
  ##   port: 9876.Port,
  ##   connectTimeout: 5000
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
    pending: initTable[uint32, Response]()
  )
  initLock(result.lock)

proc newClient*(host: string = "localhost", port: Port = 9876.Port): BitBarrelClient =
  ## Create client with default config
  ##
  ## **Example:**
  ## ```nim
  ## # Create with defaults (localhost:9876)
  ## var client = newClient()
  ##
  ## # Create with custom host
  ## var client2 = newClient("192.168.1.100", 8080.Port)
  ## ```
  newClient(ClientConfig(host: host, port: port))

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
  ## ```
  if client.connected:
    return  # Already connected

  let url = fmt"ws://{client.host}:{client.port}/ws"
  try:
    client.ws = newWebSocket(url)

    # Wait for welcome message
    const maxAttempts = 50  # 50 * 100ms = 5 seconds
    var attempts = 0

    while attempts < maxAttempts:
      let msg = client.ws.receiveMessage(timeout = 100)
      if msg.isSome():
        let m = msg.get()
        if m.kind == TextMessage and m.data.contains("Connected to BitBarrel"):
          client.connected = true
          return

      inc attempts
    raise newException(ClientError, "No welcome message received from server")

  except CatchableError as e:
    raise newException(ClientError, fmt"Failed to connect: {e.msg}")

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

proc sendAndWait*(client: var BitBarrelClient, req: Request): Response =
  ## Send request and wait for response
  var mutableReq = req
  mutableReq.seq = client.seqCounter
  client.seqCounter += 1

  try:
    # Send request as binary frame
    client.ws.send(encodeRequest(mutableReq), kind = BinaryMessage)

    # Wait for response
    var attempts = 0
    const maxAttempts = 30  # 30 * 100ms = 3 seconds

    while attempts < maxAttempts:
      let msg = client.ws.receiveMessage(timeout = 100)
      if msg.isSome() and msg.get().kind == BinaryMessage:
        let resp = decodeResponse(msg.get().data)
        if resp.seq == mutableReq.seq:
          return resp

      inc attempts
      sleep(100)

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

  let req = Request(command: cmdSet, key: key, value: value)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

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

proc rangeQuery*(client: var BitBarrelClient, startKey: string, endKey: string,
                 limit: int = 1000, cursor: string = ""): (seq[(string, string)], string, bool) =
  ## Query key-value pairs in range [startKey, endKey) with cursor-based pagination
  ## Requires barrel opened in bmCritBit mode
  ## Returns: ``(items: seq[(string, string)], nextCursor: string, hasMore: bool)``
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

  let req = Request(command: cmdRangeQuery, value: protocol.encodeRangeRequest(params))
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Range query failed: {resp.status}")

  let rangeResp = protocol.decodeRangeResponse(resp.value)
  result = (rangeResp.items, rangeResp.nextCursor, rangeResp.hasMore)

proc prefixQuery*(client: var BitBarrelClient, prefix: string,
                  limit: int = 1000, cursor: string = ""): (seq[(string, string)], string, bool) =
  ## Query key-value pairs with prefix with cursor-based pagination
  ## Requires barrel opened in bmCritBit mode
  ## Returns: ``(items: seq[(string, string)], nextCursor: string, hasMore: bool)``
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
    cursor: cursor
  )

  let req = Request(command: cmdPrefixQuery, value: protocol.encodePrefixRequest(params))
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Prefix query failed: {resp.status}")

  let rangeResp = protocol.decodeRangeResponse(resp.value)
  result = (rangeResp.items, rangeResp.nextCursor, rangeResp.hasMore)

proc rangeCount*(client: var BitBarrelClient, startKey: string, endKey: string): int =
  ## Count keys in range [startKey, endKey)
  ##
  ## Requires barrel opened in bmCritBit mode
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
