## BitBarrel Network Client
##
## WebSocket client library for BitBarrel network operations using the
## whisky WebSocket library (https://github.com/gokr/whisky).

import std/[locks, tables, strformat, net, strutils]
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
    port*: Port                ## Server port (default: 9876)
    connectTimeout*: int       ## Connection timeout in ms (default: 5000)
    requestTimeout*: int       ## Request timeout in ms (default: 3000)

  ClientError* = object of CatchableError
    ## Raised when client operations fail

  TraverseOptions* = object
    ## Options for reference traversal operations
    includeFullData*: bool    ## Return full values or just paths
    extractArrays*: bool      ## Extract array elements individually
    firstOnly*: bool          ## Stop after first result

const
  DefaultHost* = "localhost"
  DefaultPort* = 9876.Port
  DefaultConnectTimeout* = 5000
  DefaultRequestTimeout* = 3000

proc defaultConfig*(): ClientConfig =
  ## Returns default client configuration
  ClientConfig(
    host: DefaultHost,
    port: DefaultPort,
    connectTimeout: DefaultConnectTimeout,
    requestTimeout: DefaultRequestTimeout
  )

proc newClient*(config: ClientConfig): BitBarrelClient =
  ## Create a new BitBarrel client with configuration
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

proc newClient*(host: string = DefaultHost, port: Port = DefaultPort): BitBarrelClient =
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
  newClient(ClientConfig(host: host, port: port,
                         connectTimeout: DefaultConnectTimeout,
                         requestTimeout: DefaultRequestTimeout))

proc isConnected*(client: BitBarrelClient): bool =
  ## Check if client is connected
  client.connected

proc connect*(client: var BitBarrelClient) =
  ## Connect to the server
  ##
  ## Performs WebSocket handshake with the BitBarrel server.
  ## Raises ClientError if connection fails.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient("localhost", 9876.Port)
  ## client.connect()  # Explicit connect
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
  ## Close connection to the server
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## # ... do work ...
  ## client.close()
  ## ```
  if client.connected:
    try:
      client.ws.close()
    except:
      discard
    client.connected = false
    client.currentBarrel = ""

proc sendAndWait*(client: var BitBarrelClient, req: Request): Response =
  ## Send request and wait for response
  ##
  ## Thread-safe: uses lock to prevent concurrent access.
  ## Raises ClientError on timeout or communication error.
  withLock client.lock:
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

      raise newException(ClientError, "Response timeout")

    except ClientError:
      raise
    except CatchableError as e:
      raise newException(ClientError, fmt"Communication error: {e.msg}")

# Barrel management operations

proc createBarrel*(client: var BitBarrelClient, name: string, config: string = ""): bool =
  ## Create a new barrel on the server
  ##
  ## Returns true if successful, false if barrel already exists.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## discard client.createBarrel("mydb")
  ## discard client.createBarrel("ordered", """{"mode": "bmCritBit"}""")
  ## ```
  if not client.connected:
    client.connect()

  let req = Request(command: cmdCreateBarrel, key: name, value: config)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc openBarrel*(client: var BitBarrelClient, name: string): bool =
  ## Open an existing barrel on the server
  ##
  ## Returns true if successful, false if barrel not found.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## discard client.openBarrel("existing_db")
  ## ```
  if not client.connected:
    client.connect()

  let req = Request(command: cmdOpenBarrel, key: name)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc useBarrel*(client: var BitBarrelClient, name: string): bool =
  ## Set current barrel for this client session
  ##
  ## All key-value operations will use the selected barrel.
  ## Returns true if successful, false if barrel not found.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## discard client.createBarrel("mydb")
  ## discard client.useBarrel("mydb")
  ## discard client.set("key", "value")
  ## ```
  if not client.connected:
    client.connect()

  let req = Request(command: cmdUseBarrel, key: name)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk:
    client.currentBarrel = name
    return true
  return false

proc closeBarrel*(client: var BitBarrelClient): bool =
  ## Close the current barrel
  ##
  ## Returns true if successful, false if no barrel was selected.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## discard client.useBarrel("mydb")
  ## discard client.closeBarrel()
  ## ```
  if not client.connected:
    return false

  let req = Request(command: cmdCloseBarrel)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk:
    client.currentBarrel = ""
    return true
  return false

proc listBarrels*(client: var BitBarrelClient): seq[string] =
  ## List all available barrels on the server
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## let barrels = client.listBarrels()
  ## for name in barrels:
  ##   echo name
  ## ```
  if not client.connected:
    client.connect()

  let req = Request(command: cmdListBarrels)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk and resp.value.len > 0:
    return resp.value.split(',')
  return @[]

proc dropBarrel*(client: var BitBarrelClient, name: string): bool =
  ## Delete a barrel and all its data
  ##
  ## Returns true if successful, false if barrel not found.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## discard client.createBarrel("temp")
  ## discard client.dropBarrel("temp")
  ## ```
  if not client.connected:
    client.connect()

  let req = Request(command: cmdDropBarrel, key: name)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk:
    if name == client.currentBarrel:
      client.currentBarrel = ""
    return true
  return false

# Key-value operations (require current barrel)

proc get*(client: var BitBarrelClient, key: string): string =
  ## Get value by key
  ##
  ## Raises ClientError if no barrel is selected or key is not found.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## discard client.createBarrel("mydb")
  ## discard client.useBarrel("mydb")
  ## discard client.set("user:1", "Alice")
  ## let value = client.get("user:1")  # Returns "Alice"
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
    client.connect()

  let req = Request(command: cmdGet, key: key)
  let resp = client.sendAndWait(req)

  if resp.status == statusNotFound:
    raise newException(ClientError, fmt"Key not found: {key}")
  elif resp.status != statusOk:
    raise newException(ClientError, fmt"GET failed: {resp.status}")

  return resp.value

proc getOrDefault*(client: var BitBarrelClient, key: string, default: string = ""): string =
  ## Get value by key, returning default if not found
  ##
  ## **Example:**
  ## ```nim
  ## let value = client.getOrDefault("missing", "default_value")
  ## ```
  try:
    return client.get(key)
  except ClientError:
    return default

proc set*(client: var BitBarrelClient, key, value: string): bool =
  ## Set key-value pair
  ##
  ## Raises ClientError if no barrel is selected.
  ## Returns true if successful.
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## discard client.createBarrel("mydb")
  ## discard client.useBarrel("mydb")
  ## discard client.set("user:1", "Alice")
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
    client.connect()

  let req = Request(command: cmdSet, key: key, value: value)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc delete*(client: var BitBarrelClient, key: string): bool =
  ## Delete a key
  ##
  ## Raises ClientError if no barrel is selected.
  ## Returns true if successful.
  ##
  ## **Example:**
  ## ```nim
  ## discard client.set("temp", "data")
  ## discard client.delete("temp")
  ## echo client.exists("temp")  # false
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
    client.connect()

  let req = Request(command: cmdDelete, key: key)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc exists*(client: var BitBarrelClient, key: string): bool =
  ## Check if key exists
  ##
  ## Raises ClientError if no barrel is selected.
  ##
  ## **Example:**
  ## ```nim
  ## discard client.set("key", "value")
  ## echo client.exists("key")    # true
  ## echo client.exists("missing")  # false
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
    client.connect()

  let req = Request(command: cmdExists, key: key)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk and resp.value == "true"

proc count*(client: var BitBarrelClient): int =
  ## Count keys in the current barrel
  ##
  ## Raises ClientError if no barrel is selected.
  ##
  ## **Example:**
  ## ```nim
  ## let keyCount = client.count()
  ## echo "Barrel has ", keyCount, " keys"
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
    client.connect()

  let req = Request(command: cmdCount)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk:
    return parseInt(resp.value)
  return 0

proc listKeys*(client: var BitBarrelClient): seq[string] =
  ## List all keys in the current barrel
  ##
  ## Raises ClientError if no barrel is selected.
  ##
  ## **Example:**
  ## ```nim
  ## let keys = client.listKeys()
  ## for key in keys:
  ##   echo key
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
    client.connect()

  let req = Request(command: cmdListKeys)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk and resp.value.len > 0:
    return resp.value.split(',')
  return @[]

proc ping*(client: var BitBarrelClient): bool =
  ## Ping the server to check connectivity
  ##
  ## Returns true if server responds with "pong".
  ##
  ## **Example:**
  ## ```nim
  ## var client = newClient()
  ## client.connect()
  ## if client.ping():
  ##   echo "Server is reachable"
  ## ```
  if not client.connected:
    client.connect()

  let req = Request(command: cmdPing)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk and resp.value == "pong"

# Range query operations (require bmCritBit mode barrel)

proc rangeQuery*(client: var BitBarrelClient, startKey: string, endKey: string,
                 limit: int = 1000, cursor: string = ""): (seq[(string, string)], string, bool) =
  ## Query key-value pairs in range [startKey, endKey) with cursor-based pagination
  ##
  ## Requires barrel opened in bmCritBit mode.
  ## Returns: (items, nextCursor, hasMore)
  ##
  ## **Example:**
  ## ```nim
  ## let (items, nextCursor, hasMore) = client.rangeQuery("user:0", "user:999", 100)
  ## if hasMore:
  ##   let (nextPage, _, _) = client.rangeQuery("user:0", "user:999", 100, nextCursor)
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
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
  ##
  ## Requires barrel opened in bmCritBit mode.
  ## Returns: (items, nextCursor, hasMore)
  ##
  ## **Example:**
  ## ```nim
  ## let (items, nextCursor, hasMore) = client.prefixQuery("user:", 100)
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
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
  ## Requires barrel opened in bmCritBit mode.
  ##
  ## **Example:**
  ## ```nim
  ## let count = client.rangeCount("user:0", "user:999")
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
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
  ## PathSpec syntax: `*` for all references, `->` to follow
  ##
  ## **Example:**
  ## ```nim
  ## let options = TraverseOptions(includeFullData: true)
  ## let results = client.traverse("user:1", "->friend", options)
  ## ```
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if not client.connected:
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

proc traversePath*(client: var BitBarrelClient, key: string,
                   pathSpec: string): seq[protocol.TraverseResult] =
  ## Traverse with default options (include full data)
  let options = TraverseOptions(
    includeFullData: true,
    extractArrays: false,
    firstOnly: false
  )
  result = client.traverse(key, pathSpec, options)
