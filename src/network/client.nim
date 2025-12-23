## BitBarrel Network Client
##
## WebSocket client library for BitBarrel network operations

import std/[net, strformat, locks, tables, times, random, base64, strutils, os]
import protocol

# Simple WebSocket client implementation
type
  WebSocket* = ref object
    ## WebSocket transport connection for BitBarrel client
    socket: Socket
    host: string
    port: int
    buffer: string
    connected*: bool
    clientId*: uint64

  WebSocketException* = object of CatchableError
    ## Raised when WebSocket protocol errors occur

  BitBarrelClient* = object
    ## Client for BitBarrel network operations
    ##
    ## Manages a single WebSocket connection to a BitBarrel server
    ## and provides a high-level API for barrel and key-value operations
    host*: string
    port*: Port
    conn*: WebSocket  # Single connection for simplicity
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
  result = BitBarrelClient(
    host: config.host,
    port: config.port,
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

proc handshakeWebSocket(ws: var WebSocket, host: string, port: int) =
  ## Perform WebSocket handshake
  # Generate 16 random bytes
  var keyData = newString(16)
  for i in 0..15:
    keyData[i] = char(rand(255))
  let key = encode(keyData)

  ws.socket = newSocket()
  ws.socket.connect(host, Port(port), timeout=5000)

  let handshake = fmt"GET /ws HTTP/1.1\r\nHost: {host}:{port}\r\n" &
                 "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
                 fmt"Sec-WebSocket-Key: {key}\r\n" &
                 "Sec-WebSocket-Version: 13\r\n\r\n"

  ws.socket.send(handshake)

  # Small delay to ensure server processes the request
  os.sleep(100)

  # Read response - use recv() instead of recvLine() to avoid blocking issues
  var buffer = newString(4096)
  let bytesReceived = ws.socket.recv(buffer, 4096)
  if bytesReceived <= 0:
    raise newException(WebSocketException, "No response from server")

  var response = buffer[0..<bytesReceived]

  if not response.startsWith("101 Switching Protocols"):
    echo "DEBUG: Received response (", bytesReceived, " bytes):", repr(response)
    raise newException(WebSocketException, "WebSocket handshake failed")

  ws.connected = true

proc sendFrame(ws: WebSocket, data: string) =
  ## Send WebSocket frame (binary mode) with masking per RFC 6455
  var frame = ""
  frame.add(char(0x82))  # FIN bit (0x80) + Binary opcode (0x02)

  # Generate 4-byte mask for client-to-server frames (required by RFC 6455)
  var mask: array[4, byte]
  for i in 0..3:
    mask[i] = byte(rand(255))

  # Length with mask bit set (0x80)
  if data.len < 126:
    frame.add(char(0x80 or data.len))
  elif data.len < 65536:
    frame.add(char(0x80 or 126))
    frame.add(char((data.len shr 8) and 0xFF))
    frame.add(char(data.len and 0xFF))
  else:
    # 64-bit length not implemented
    raise newException(WebSocketException, "Message too large")

  # Add mask bytes
  for i in 0..3:
    frame.add(char(mask[i]))

  # Add masked payload
  for i in 0..<data.len:
    frame.add(char(byte(data[i]) xor mask[i mod 4]))

  ws.socket.send(frame)

proc recvFrame(ws: WebSocket): string =
  ## Receive WebSocket frame
  var header: array[2, byte]
  if ws.socket.recv(addr header[0], 2) != 2:
    raise newException(WebSocketException, "Failed to read frame header")

  let hasMask = (header[1] and 0x80) != 0

  var length = int(header[1] and 0x7F)
  if length == 126:
    var lenBytes: array[2, byte]
    if ws.socket.recv(addr lenBytes[0], 2) != 2:
      raise newException(WebSocketException, "Failed to read extended length")
    length = (int(lenBytes[0]) shl 8) or int(lenBytes[1])
  elif length == 127:
    raise newException(WebSocketException, "64-bit lengths not supported")

  if hasMask:
    var mask: array[4, byte]
    if ws.socket.recv(addr mask[0], 4) != 4:
      raise newException(WebSocketException, "Failed to read mask")

    result = newString(length)
    if ws.socket.recv(cstring(result), length) != length:
      raise newException(WebSocketException, "Failed to read frame data")

    # Unmask data
    for i in 0..<length:
      result[i] = char(byte(result[i]) xor mask[i mod 4])
  else:
    result = newString(length)
    if ws.socket.recv(cstring(result), length) != length:
      raise newException(WebSocketException, "Failed to read frame data")

proc newWebSocket(host: string, port: int): WebSocket =
  ## Create new WebSocket connection
  result = WebSocket(host: host, port: port, clientId: uint64(rand(1000000)))
  try:
    handshakeWebSocket(result, host, port)
  except OSError as e:
      raise newException(WebSocketException, "OS error: " & e.msg)
  except TimeoutError as e:
      raise newException(WebSocketException, "Timeout: " & e.msg)

proc send*(ws: WebSocket, data: string, isBinary: bool = true) =
  ## Send message over WebSocket
  if not ws.connected:
    raise newException(WebSocketException, "Not connected")

  if isBinary:
    sendFrame(ws, data)  # Binary mode with proper masking
  else:
    # Text frame with FIN bit and masking
    var frame = ""
    frame.add(char(0x81))  # FIN bit (0x80) + Text opcode (0x01)

    # Generate mask
    var mask: array[4, byte]
    for i in 0..3:
      mask[i] = byte(rand(255))

    # Length with mask bit set
    if data.len < 126:
      frame.add(char(0x80 or data.len))
    elif data.len < 65536:
      frame.add(char(0x80 or 126))
      frame.add(char((data.len shr 8) and 0xFF))
      frame.add(char(data.len and 0xFF))
    else:
      raise newException(WebSocketException, "Message too large")

    # Add mask bytes
    for i in 0..3:
      frame.add(char(mask[i]))

    # Add masked payload
    for i in 0..<data.len:
      frame.add(char(byte(data[i]) xor mask[i mod 4]))

    ws.socket.send(frame)

proc receive*(ws: WebSocket, timeoutMs: int = 5000): string =
  ## Receive message from WebSocket
  if not ws.connected:
    raise newException(WebSocketException, "Not connected")

  let startTime = epochTime()
  while true:
    try:
      let data = recvFrame(ws)
      # Simple protocol handling
      if data.startsWith("Connected to"):
        return data
      return data
    except WebSocketException:
      # Try again
      if epochTime() - startTime > float(timeoutMs) / 1000.0:
        raise newException(WebSocketException, "Receive timeout")
      sleep(100)

proc close*(ws: WebSocket) {.raises: [].} =
  ## Close WebSocket
  if ws.connected:
    try:
      var frame = ""
      frame.add(char(0x08))  # Close frame
      frame.add(char(0x00))  # Length 0
      ws.socket.send(frame)
    except:
      discard
    try:
      ws.socket.close()
    except:
      discard
    ws.connected = false

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
  try:
    client.conn = newWebSocket(client.host, int(client.port))

    # Wait for welcome
    let welcome = client.conn.receive()
    if not welcome.contains("Connected to BitBarrel"):
      raise newException(ClientError, "Invalid welcome from server")

  except WebSocketException as e:
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
  if client.conn != nil:
    client.conn.close()
    client.conn = nil

proc sendAndWait*(client: var BitBarrelClient, req: Request): Response =
  ## Send request and wait for response
  if client.conn == nil:
    raise newException(ClientError, "Not connected")

  var mutableReq = req
  mutableReq.seq = client.seqCounter
  client.seqCounter += 1

  try:
    # Send request
    client.conn.send(encodeRequest(mutableReq), isBinary=true)

    # Wait for response
    var attempts = 0
    const maxAttempts = 30  # 30 * 100ms = 3 seconds

    while attempts < maxAttempts:
      let data = client.conn.receive(timeoutMs=100)
      if data.len > 0:
        let resp = decodeResponse(data)
        if resp.seq == mutableReq.seq:
          return resp

      inc attempts
      sleep(100)

    raise newException(ClientError, "Response timeout")

  except WebSocketException as e:
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
  if client.conn == nil:
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
  if client.conn == nil:
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
  if client.conn == nil:
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
  if client.conn == nil:
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
  if client.conn == nil:
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

  if client.conn == nil:
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

  if client.conn == nil:
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

  if client.conn == nil:
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

  if client.conn == nil:
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
  if client.conn == nil:
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

  if client.conn == nil:
    client.connect()

  # Build range query request
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

  # Decode range response
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

  if client.conn == nil:
    client.connect()

  # Build prefix query request
  let params = protocol.PrefixRequest(
    prefix: prefix,
    limit: limit,
    cursor: cursor
  )

  let req = Request(command: cmdPrefixQuery, value: protocol.encodePrefixRequest(params))
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Prefix query failed: {resp.status}")

  # Decode range response (same format for both range and prefix)
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

  if client.conn == nil:
    client.connect()

  # Build count request (using range query format)
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

  if client.conn == nil:
    client.connect()

  # Build traversal request
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

  # Encode and send
  let encoded = encodeTraverseRequest(tReq)
  let req = Request(command: cmdTraverse, value: encoded)
  let resp = client.sendAndWait(req)

  if resp.status != statusOk:
    raise newException(ClientError, fmt"Traversal failed: {resp.status}")

  # Decode results
  let (status, _, results) = decodeTraverseResults(resp.value)
  if status != statusOk:
    raise newException(ClientError, "Invalid traversal response")

  # Convert to client format
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