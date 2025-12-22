## BitBarrel Network Client
##
## WebSocket client library for BitBarrel network operations

import std/[net, strformat, locks, tables, times, random, base64, strutils, os]
import protocol

# Simple WebSocket client implementation
type
  WebSocket* = ref object
    socket: Socket
    host: string
    port: int
    buffer: string
    connected*: bool
    clientId*: uint64

  WebSocketException* = object of CatchableError

  BitBarrelClient* = object
    host*: string
    port*: Port
    conn*: WebSocket  # Single connection for simplicity
    seqCounter*: uint32
    currentBarrel*: string
    pending*: Table[uint32, Response]
    lock: Lock

  ClientConfig* = object
    host*: string              # Default: "localhost"
    port*: Port              # Default: 9876
    connectTimeout*: int     # ms, default: 5000

  ClientError* = object of CatchableError


proc newClient*(config: ClientConfig): BitBarrelClient =
  ## Create a new BitBarrel client
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

  # Read response
  var response = ""
  while true:
    let line = ws.socket.recvLine()
    response.add(line & "\r\n")
    if line.len == 0: break

  if not response.startsWith("101 Switching Protocols"):
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
  ## Create a new barrel
  if client.conn == nil:
    client.connect()

  let req = Request(command: cmdCreateBarrel, key: name, value: config)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc openBarrel*(client: var BitBarrelClient, name: string): bool =
  ## Open an existing barrel
  if client.conn == nil:
    client.connect()

  let req = Request(command: cmdOpenBarrel, key: name)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc useBarrel*(client: var BitBarrelClient, name: string): bool =
  ## Set current barrel for this client session
  if client.conn == nil:
    client.connect()

  let req = Request(command: cmdUseBarrel, key: name)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk:
    client.currentBarrel = name
    return true
  return false

proc listBarrels*(client: var BitBarrelClient): seq[string] =
  ## List all available barrels
  if client.conn == nil:
    client.connect()

  let req = Request(command: cmdListBarrels)
  let resp = client.sendAndWait(req)
  if resp.status == statusOk and resp.value.len > 0:
    return resp.value.split(',')
  return @[]

# Basic key-value operations (require current barrel)
proc get*(client: var BitBarrelClient, key: string): string =
  ## Get value by key
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
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if client.conn == nil:
    client.connect()

  let req = Request(command: cmdSet, key: key, value: value)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc delete*(client: var BitBarrelClient, key: string): bool =
  ## Delete a key
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if client.conn == nil:
    client.connect()

  let req = Request(command: cmdDelete, key: key)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk

proc exists*(client: var BitBarrelClient, key: string): bool =
  ## Check if key exists
  if client.currentBarrel.len == 0:
    raise newException(ClientError, "No barrel selected. Call useBarrel() first.")

  if client.conn == nil:
    client.connect()

  let req = Request(command: cmdExists, key: key)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk and resp.value == "true"

proc ping*(client: var BitBarrelClient): bool =
  ## Ping the server
  if client.conn == nil:
    client.connect()

  let req = Request(command: cmdPing)
  let resp = client.sendAndWait(req)
  return resp.status == statusOk and resp.value == "pong"

# Reference traversal operations
type
  TraverseOptions* = object
    includeFullData*: bool    ## Return full values or just paths
    extractArrays*: bool      ## Extract array elements individually
    firstOnly*: bool          ## Stop after first result

proc traverse*(client: var BitBarrelClient, key: string, pathSpec: string,
               options: TraverseOptions): seq[protocol.TraverseResult] =
  ## Traverse references from a key using path specification
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