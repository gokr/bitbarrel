## Binary protocol for BitBarrel network communication
##
## Request Format: ``[type:1][seq:4][keyLen:2][key:N][valLen:4][value:M]``
## Response Format: ``[status:1][seq:4][valLen:4][value:M]``
##
## All multi-byte integers use big-endian encoding.

import std/strutils

type
  Command* = enum
    ## Data operations
    cmdGet = 0x01
    cmdSet = 0x02
    cmdDelete = 0x03
    cmdExists = 0x04
    cmdCount = 0x05
    cmdListKeys = 0x06
    cmdPing = 0x09
    ## Barrel management
    cmdCreateBarrel = 0x10
    cmdOpenBarrel = 0x11
    cmdUseBarrel = 0x12
    cmdCloseBarrel = 0x13
    cmdListBarrels = 0x14
    cmdDropBarrel = 0x15
    ## Configuration commands
    cmdGetBarrelConfig = 0x16
    cmdSetBarrelConfig = 0x17
    ## Statistics
    cmdGetBarrelStats = 0x18
    ## Reference traversal
    cmdTraverse = 0x20
    ## Range queries
    cmdRangeQuery = 0x21
    cmdPrefixQuery = 0x22
    cmdRangeCount = 0x23
    cmdRangeKeys = 0x24  ## Keys-only range query (bmCritBit only)
    cmdPrefixKeys = 0x25 ## Keys-only prefix query (bmCritBit only)
    ## Pub/Sub commands (0x40-0x4F)
    cmdSubscribe = 0x40
    cmdUnsubscribe = 0x41
    cmdPublish = 0x42
    cmdListSubscribers = 0x43
    cmdHistory = 0x44
    cmdListTopics = 0x45
    cmdPresence = 0x46

  PubSubMessageType* = enum
    mtData = 0
    mtPresence
    mtKvChange

  PresenceEventType* = enum
    peJoin = 0
    peLeave = 0x01
    peUpdate = 0x02

  KvChangeType* = enum
    kvSet = 0
    kvDelete = 0x01

  ResponseStatus* = enum
    statusOk = 0x00
    statusNotFound = 0x01
    statusError = 0x02
    statusInvalid = 0x03
    statusNoBarrel = 0x04
    statusBarrelExists = 0x05
    statusBarrelNotFound = 0x06
    statusUnauthorized = 0x07

  Request* = object
    command*: Command
    seq*: uint32
    key*: string      ## Also used for barrel name
    value*: string    ## Also used for barrel config JSON

  Response* = object
    status*: ResponseStatus
    seq*: uint32
    value*: string

  ## Statistics structure for barrel metrics
  BarrelStats* = object
    totalKeys*: int64          ## Total keys including tombstones
    activeKeys*: int64         ## Active keys (excluding tombstones)
    deletedKeys*: int64        ## Tombstone/deleted keys

    fileCount*: int            ## Number of data files
    totalSize*: int64          ## Total bytes on disk for all files
    activeFileSize*: int64     ## Size of active data file

    avgKeySize*: float         ## Average key size in bytes
    avgValueSize*: float       ## Average value size in bytes
    avgRecordSize*: float      ## Average record size in bytes

    fragmentationRatio*: float ## Fragmentation ratio (0.0 to 1.0)
    isCompacting*: bool        ## Is compaction currently in progress
    lastCompactTime*: string   ## ISO timestamp of last compaction
    recordsScanned*: int64     ## Records scanned in last compaction
    recordsKept*: int64        ## Records kept in last compaction
    recordsDropped*: int64     ## Records dropped in last compaction

    indexMode*: string         ## Index mode (hash, critbit, hugecritbit)
    syncMode*: string          ## Sync mode (none, sync, fsync)

    dataPath*: string          ## Path to data files
    lastModified*: string      ## ISO timestamp of last modification

  ProtocolError* = object of CatchableError

const
  MaxKeySize* = 65535       ## 64KB max key size (2 bytes for length)
  MaxValueSize* = 32 * 1024 * 1024  ## 32MB max value size


proc writeByte(s: var string, b: byte) =
  s.add(char(b))

proc writeUint16BE(s: var string, v: uint16) =
  s.add(char((v shr 8) and 0xFF))
  s.add(char(v and 0xFF))

proc writeUint32BE(s: var string, v: uint32) =
  s.add(char((v shr 24) and 0xFF))
  s.add(char((v shr 16) and 0xFF))
  s.add(char((v shr 8) and 0xFF))
  s.add(char(v and 0xFF))

proc writeUint64BE*(s: var string, v: uint64) =
  s.add(char((v shr 56) and 0xFF))
  s.add(char((v shr 48) and 0xFF))
  s.add(char((v shr 40) and 0xFF))
  s.add(char((v shr 32) and 0xFF))
  s.add(char((v shr 24) and 0xFF))
  s.add(char((v shr 16) and 0xFF))
  s.add(char((v shr 8) and 0xFF))
  s.add(char(v and 0xFF))

proc readByte(data: string, pos: var int): byte =
  if pos >= data.len:
    raise newException(ProtocolError, "Unexpected end of data reading byte")
  result = byte(data[pos])
  inc pos

proc readUint16BE(data: string, pos: var int): uint16 =
  if pos + 2 > data.len:
    raise newException(ProtocolError, "Unexpected end of data reading uint16")
  result = (uint16(data[pos]) shl 8) or uint16(data[pos + 1])
  pos += 2

proc readUint32BE(data: string, pos: var int): uint32 =
  if pos + 4 > data.len:
    raise newException(ProtocolError, "Unexpected end of data reading uint32")
  result = (uint32(data[pos]) shl 24) or
           (uint32(data[pos + 1]) shl 16) or
           (uint32(data[pos + 2]) shl 8) or
           uint32(data[pos + 3])
  pos += 4

proc readUint64BE(data: string, pos: var int): uint64 =
  if pos + 8 > data.len:
    raise newException(ProtocolError, "Unexpected end of data reading uint64")
  result = (uint64(data[pos]) shl 56) or
           (uint64(data[pos + 1]) shl 48) or
           (uint64(data[pos + 2]) shl 40) or
           (uint64(data[pos + 3]) shl 32) or
           (uint64(data[pos + 4]) shl 24) or
           (uint64(data[pos + 5]) shl 16) or
           (uint64(data[pos + 6]) shl 8) or
           uint64(data[pos + 7])
  pos += 8

proc readString(data: string, pos: var int, length: int): string =
  if pos + length > data.len:
    raise newException(ProtocolError, "Unexpected end of data reading string")
  result = data[pos ..< pos + length]
  pos += length


proc encodeRequest*(req: Request): string =
  ## Encode a request to binary format.
  ## Format: ``[type:1][seq:4][keyLen:2][key:N][valLen:4][value:M]``
  if req.key.len > MaxKeySize:
    raise newException(ProtocolError, "Key too large: " & $req.key.len)
  if req.value.len > MaxValueSize:
    raise newException(ProtocolError, "Value too large: " & $req.value.len)

  result = newStringOfCap(1 + 4 + 2 + req.key.len + 4 + req.value.len)
  result.writeByte(byte(ord(req.command)))
  result.writeUint32BE(req.seq)
  result.writeUint16BE(uint16(req.key.len))
  result.add(req.key)
  result.writeUint32BE(uint32(req.value.len))
  result.add(req.value)

proc decodeRequest*(data: string): Request =
  ## Decode a request from binary format.
  var pos = 0

  let cmdByte = readByte(data, pos)
  # Validate command byte - must include all Command enum values
  if cmdByte notin {0x01'u8, 0x02, 0x03, 0x04, 0x05, 0x06, 0x09,  # Data ops + ping
                     0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,  # Barrel ops + config + stats
                     0x20,                                       # Traverse
                     0x21, 0x22, 0x23, 0x24, 0x25,              # Range queries
                     0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46}:     # Pub/Sub commands
    raise newException(ProtocolError, "Invalid command: 0x" & cmdByte.toHex)

  result.command = cast[Command](cmdByte)
  result.seq = readUint32BE(data, pos)

  let keyLen = readUint16BE(data, pos)
  if keyLen > MaxKeySize:
    raise newException(ProtocolError, "Key too large: " & $keyLen)
  result.key = readString(data, pos, int(keyLen))

  let valLen = readUint32BE(data, pos)
  if valLen > MaxValueSize:
    raise newException(ProtocolError, "Value too large: " & $valLen)
  result.value = readString(data, pos, int(valLen))

proc encodeResponse*(resp: Response): string =
  ## Encode a response to binary format.
  ## Format: ``[status:1][seq:4][valLen:4][value:M]``
  if resp.value.len > MaxValueSize:
    raise newException(ProtocolError, "Value too large: " & $resp.value.len)

  result = newStringOfCap(1 + 4 + 4 + resp.value.len)
  result.writeByte(byte(ord(resp.status)))
  result.writeUint32BE(resp.seq)
  result.writeUint32BE(uint32(resp.value.len))
  result.add(resp.value)

proc decodeResponse*(data: string): Response =
  ## Decode a response from binary format.
  var pos = 0

  let statusByte = readByte(data, pos)
  if statusByte > byte(0x07):
    raise newException(ProtocolError, "Invalid status: 0x" & statusByte.toHex)

  result.status = ResponseStatus(statusByte)
  result.seq = readUint32BE(data, pos)

  let valLen = readUint32BE(data, pos)
  if valLen > MaxValueSize:
    raise newException(ProtocolError, "Value too large: " & $valLen)
  result.value = readString(data, pos, int(valLen))


## Traversal request/response extensions

type
  TraverseRequest* = object
    seq*: uint32
    key*: string           ## Starting key for traversal
    pathSpec*: string      ## Path specification string
    options*: uint8        ## Options bitfield

  TraverseResult* = object
    path*: string          ## Full traversal path
    key*: string           ## Key of the result
    value*: string         ## Value at the path end (if requested)
    extractedData*: string ## Extracted array data (if requested)

proc encodeTraverseRequest*(req: TraverseRequest): string =
  ## Encode a traversal request
  ## Format: ``[seq:4][keyLen:2][key:N][pathLen:2][path:N][options:1]``
  result = newStringOfCap(4 + 2 + req.key.len + 2 + req.pathSpec.len + 1)
  result.writeUint32BE(req.seq)
  result.writeUint16BE(uint16(req.key.len))
  result.add(req.key)
  result.writeUint16BE(uint16(req.pathSpec.len))
  result.add(req.pathSpec)
  result.writeByte(byte(req.options))

proc decodeTraverseRequest*(data: string): TraverseRequest =
  ## Decode a traversal request
  var pos = 0
  result.seq = readUint32BE(data, pos)

  let keyLen = readUint16BE(data, pos)
  if keyLen > MaxKeySize:
    raise newException(ProtocolError, "Key too large: " & $keyLen)
  result.key = readString(data, pos, int(keyLen))

  let pathLen = readUint16BE(data, pos)
  if pathLen > 1024:  # Reasonable limit for path spec
    raise newException(ProtocolError, "Path spec too large: " & $pathLen)
  result.pathSpec = readString(data, pos, int(pathLen))

  result.options = uint8(readByte(data, pos))

proc encodeTraverseResults*(results: seq[TraverseResult], seq: uint32): string =
  ## Encode traversal results
  ## Format: ``[status:1][seq:4][count:4][results...]``
  ## Each result: ``[pathLen:2][path:N][valLen:4][val:M][extFlags:1][extLen:4][ext:M]``
  result = newStringOfCap(1 + 4 + 4)
  result.writeByte(byte(ord(statusOk)))
  result.writeUint32BE(seq)
  result.writeUint32BE(uint32(results.len))

  for res in results:
    # Path
    result.writeUint16BE(uint16(res.path.len))
    result.add(res.path)

    # Value (if present)
    result.writeUint32BE(uint32(res.value.len))
    if res.value.len > 0:
      result.add(res.value)

    # Extracted data flag and length
    let hasExtracted = if res.extractedData.len > 0: 1'u8 else: 0'u8
    result.writeByte(byte(hasExtracted))
    result.writeUint32BE(uint32(res.extractedData.len))
    if res.extractedData.len > 0:
      result.add(res.extractedData)

proc decodeTraverseResults*(data: string): (ResponseStatus, uint32, seq[TraverseResult]) =
  ## Decode traversal results
  var pos = 0

  let statusByte = readByte(data, pos)
  if statusByte > byte(ord(high(ResponseStatus))):
    raise newException(ProtocolError, "Invalid status: 0x" & statusByte.toHex)

  result[0] = ResponseStatus(statusByte)
  result[1] = readUint32BE(data, pos)

  let count = readUint32BE(data, pos)
  result[2] = newSeq[TraverseResult](count)

  for i in 0..<count:
    var res: TraverseResult

    # Path
    let pathLen = readUint16BE(data, pos)
    res.path = readString(data, pos, int(pathLen))

    # Value
    let valLen = readUint32BE(data, pos)
    if valLen > 0:
      res.value = readString(data, pos, int(valLen))

    # Extracted data
    let hasExtracted = readByte(data, pos)
    let extLen = readUint32BE(data, pos)
    if hasExtracted != 0 and extLen > 0:
      res.extractedData = readString(data, pos, int(extLen))

    result[2][i] = res


## Range query request/response extensions

type
  RangeRequest* = object
    startKey*: string
    endKey*: string
    limit*: int
    cursor*: string
    plugins*: seq[string]  ## Names of plugins to apply (optional)

  PrefixRequest* = object
    prefix*: string
    limit*: int
    cursor*: string
    plugins*: seq[string]  ## Names of plugins to apply (optional)

  RangeResponse* = object
    items*: seq[(string, string)]
    nextCursor*: string
    hasMore*: bool

  KeysResponse* = object
    keys*: seq[string]
    nextCursor*: string
    hasMore*: bool

proc encodeRangeRequest*(req: RangeRequest): string =
  ## Encode a range query request
  ## Format: ``[startKeyLen:2][startKey:N][endKeyLen:2][endKey:N][limit:4][cursorLen:2][cursor:M][pluginCount:1][p1Len:2][p1Name:X]...``
  result = newStringOfCap(2 + req.startKey.len + 2 + req.endKey.len + 4 + 2 + req.cursor.len)
  result.writeUint16BE(uint16(req.startKey.len))
  result.add(req.startKey)
  result.writeUint16BE(uint16(req.endKey.len))
  result.add(req.endKey)
  result.writeUint32BE(uint32(req.limit))
  result.writeUint16BE(uint16(req.cursor.len))
  result.add(req.cursor)

  # Encode plugins array
  if req.plugins.len > 255:
    raise newException(ProtocolError, "Too many plugins: " & $req.plugins.len)
  result.writeByte(byte(req.plugins.len))

  for plugin in req.plugins:
    if plugin.len > 255:
      raise newException(ProtocolError, "Plugin name too long: " & $plugin.len)
    result.writeUint16BE(uint16(plugin.len))
    result.add(plugin)

proc decodeRangeRequest*(data: string): RangeRequest =
  ## Decode a range query request
  var pos = 0
  let startKeyLen = readUint16BE(data, pos)
  if startKeyLen > MaxKeySize:
    raise newException(ProtocolError, "Start key too large: " & $startKeyLen)
  result.startKey = readString(data, pos, int(startKeyLen))

  let endKeyLen = readUint16BE(data, pos)
  if endKeyLen > MaxKeySize:
    raise newException(ProtocolError, "End key too large: " & $endKeyLen)
  result.endKey = readString(data, pos, int(endKeyLen))

  result.limit = int(readUint32BE(data, pos))

  let cursorLen = readUint16BE(data, pos)
  if cursorLen > MaxKeySize:
    raise newException(ProtocolError, "Cursor too large: " & $cursorLen)
  result.cursor = readString(data, pos, int(cursorLen))

  # Decode plugins array (if present)
  result.plugins = @[]
  if pos < data.len:
    let pluginCount = int(readByte(data, pos))
    if pluginCount > 0:
      result.plugins = newSeq[string](pluginCount)
      for i in 0..<pluginCount:
        let pluginLen = readUint16BE(data, pos)
        if pluginLen > 255:
          raise newException(ProtocolError, "Plugin name too long: " & $pluginLen)
        result.plugins[i] = readString(data, pos, int(pluginLen))

proc encodePrefixRequest*(req: PrefixRequest): string =
  ## Encode a prefix query request
  ## Format: ``[prefixLen:2][prefix:N][limit:4][cursorLen:2][cursor:M][pluginCount:1][p1Len:2][p1Name:X]...``
  result = newStringOfCap(2 + req.prefix.len + 4 + 2 + req.cursor.len)
  result.writeUint16BE(uint16(req.prefix.len))
  result.add(req.prefix)
  result.writeUint32BE(uint32(req.limit))
  result.writeUint16BE(uint16(req.cursor.len))
  result.add(req.cursor)

  # Encode plugins array
  if req.plugins.len > 255:
    raise newException(ProtocolError, "Too many plugins: " & $req.plugins.len)
  result.writeByte(byte(req.plugins.len))

  for plugin in req.plugins:
    if plugin.len > 255:
      raise newException(ProtocolError, "Plugin name too long: " & $plugin.len)
    result.writeUint16BE(uint16(plugin.len))
    result.add(plugin)

proc decodePrefixRequest*(data: string): PrefixRequest =
  ## Decode a prefix query request
  var pos = 0
  let prefixLen = readUint16BE(data, pos)
  if prefixLen > MaxKeySize:
    raise newException(ProtocolError, "Prefix too large: " & $prefixLen)
  result.prefix = readString(data, pos, int(prefixLen))

  result.limit = int(readUint32BE(data, pos))

  let cursorLen = readUint16BE(data, pos)
  if cursorLen > MaxKeySize:
    raise newException(ProtocolError, "Cursor too large: " & $cursorLen)
  result.cursor = readString(data, pos, int(cursorLen))

  # Decode plugins array (if present)
  result.plugins = @[]
  if pos < data.len:
    let pluginCount = int(readByte(data, pos))
    if pluginCount > 0:
      result.plugins = newSeq[string](pluginCount)
      for i in 0..<pluginCount:
        let pluginLen = readUint16BE(data, pos)
        if pluginLen > 255:
          raise newException(ProtocolError, "Plugin name too long: " & $pluginLen)
        result.plugins[i] = readString(data, pos, int(pluginLen))

proc encodeRangeResponse*(resp: RangeResponse): string =
  ## Encode a range query response
  ## Format: ``[count:4][items...][hasMore:1][nextCursorLen:2][nextCursor:N]``
  result = newStringOfCap(4 + resp.nextCursor.len + 20)  # Reasonable capacity
  result.writeUint32BE(uint32(resp.items.len))

  for item in resp.items:
    result.writeUint16BE(uint16(item[0].len))
    result.add(item[0])
    result.writeUint32BE(uint32(item[1].len))
    result.add(item[1])

  result.writeByte(byte(if resp.hasMore: 1 else: 0))
  result.writeUint16BE(uint16(resp.nextCursor.len))
  result.add(resp.nextCursor)

proc decodeRangeResponse*(data: string): RangeResponse =
  ## Decode a range query response
  var pos = 0
  let count = readUint32BE(data, pos)
  result.items = newSeq[(string, string)](count)

  for i in 0..<count:
    let keyLen = readUint16BE(data, pos)
    if keyLen > MaxKeySize:
      raise newException(ProtocolError, "Key too large: " & $keyLen)
    let key = readString(data, pos, int(keyLen))

    let valLen = readUint32BE(data, pos)
    if valLen > MaxValueSize:
      raise newException(ProtocolError, "Value too large: " & $valLen)
    let value = readString(data, pos, int(valLen))

    result.items[i] = (key, value)

  let hasMoreByte = readByte(data, pos)
  result.hasMore = hasMoreByte != 0

  let nextCursorLen = readUint16BE(data, pos)
  if nextCursorLen > MaxKeySize:
    raise newException(ProtocolError, "Next cursor too large: " & $nextCursorLen)
  result.nextCursor = readString(data, pos, int(nextCursorLen))

proc encodeKeysResponse*(resp: KeysResponse): string =
  ## Encode a keys-only query response
  ## Format: ``[count:4][keys...][hasMore:1][nextCursorLen:2][nextCursor:N]``
  result = newStringOfCap(4 + resp.nextCursor.len + 20)  # Reasonable capacity
  result.writeUint32BE(uint32(resp.keys.len))

  for key in resp.keys:
    result.writeUint16BE(uint16(key.len))
    result.add(key)

  result.writeByte(byte(if resp.hasMore: 1 else: 0))
  result.writeUint16BE(uint16(resp.nextCursor.len))
  result.add(resp.nextCursor)

proc decodeKeysResponse*(data: string): KeysResponse =
  ## Decode a keys-only query response
  var pos = 0
  let count = readUint32BE(data, pos)
  result.keys = newSeq[string](count)

  for i in 0..<count:
    let keyLen = readUint16BE(data, pos)
    if keyLen > MaxKeySize:
      raise newException(ProtocolError, "Key too large: " & $keyLen)
    result.keys[i] = readString(data, pos, int(keyLen))

  let hasMoreByte = readByte(data, pos)
  result.hasMore = hasMoreByte != 0

  let nextCursorLen = readUint16BE(data, pos)
  if nextCursorLen > MaxKeySize:
    raise newException(ProtocolError, "Next cursor too large: " & $nextCursorLen)
  result.nextCursor = readString(data, pos, int(nextCursorLen))


proc newRequest*(command: Command, key: string = "", value: string = "", seq: uint32 = 0): Request =
  ## Create a new request.
  Request(command: command, seq: seq, key: key, value: value)

proc newResponse*(status: ResponseStatus, seq: uint32, value: string = ""): Response =
  ## Create a new response.
  Response(status: status, seq: seq, value: value)

proc okResponse*(seq: uint32, value: string = ""): Response =
  ## Create an OK response.
  newResponse(statusOk, seq, value)

proc errorResponse*(seq: uint32, message: string = ""): Response =
  ## Create an error response.
  newResponse(statusError, seq, message)

proc notFoundResponse*(seq: uint32): Response =
  ## Create a not found response.
  newResponse(statusNotFound, seq)

proc noBarrelResponse*(seq: uint32): Response =
  ## Create a no barrel selected response.
  newResponse(statusNoBarrel, seq)

proc barrelExistsResponse*(seq: uint32): Response =
  ## Create a barrel already exists response.
  newResponse(statusBarrelExists, seq)

proc barrelNotFoundResponse*(seq: uint32): Response =
  ## Create a barrel not found response.
  newResponse(statusBarrelNotFound, seq)

proc invalidResponse*(seq: uint32, message: string = ""): Response =
  ## Create an invalid request response.
  newResponse(statusInvalid, seq, message)

proc unauthorizedResponse*(seq: uint32, message: string = ""): Response =
  ## Create an unauthorized response.
  newResponse(statusUnauthorized, seq, message)


proc `$`*(cmd: Command): string =
  ## String representation of command.
  case cmd
  of cmdGet: "GET"
  of cmdSet: "SET"
  of cmdDelete: "DELETE"
  of cmdExists: "EXISTS"
  of cmdCount: "COUNT"
  of cmdListKeys: "LIST_KEYS"
  of cmdPing: "PING"
  of cmdRangeQuery: "RANGE_QUERY"
  of cmdPrefixQuery: "PREFIX_QUERY"
  of cmdRangeCount: "RANGE_COUNT"
  of cmdRangeKeys: "RANGE_KEYS"
  of cmdPrefixKeys: "PREFIX_KEYS"
  of cmdCreateBarrel: "CREATE_BARREL"
  of cmdOpenBarrel: "OPEN_BARREL"
  of cmdUseBarrel: "USE_BARREL"
  of cmdCloseBarrel: "CLOSE_BARREL"
  of cmdListBarrels: "LIST_BARRELS"
  of cmdDropBarrel: "DROP_BARREL"
  of cmdGetBarrelConfig: "GET_BARREL_CONFIG"
  of cmdSetBarrelConfig: "SET_BARREL_CONFIG"
  of cmdGetBarrelStats: "GET_BARREL_STATS"
  of cmdTraverse: "TRAVERSE"
  of cmdSubscribe: "SUBSCRIBE"
  of cmdUnsubscribe: "UNSUBSCRIBE"
  of cmdPublish: "PUBLISH"
  of cmdListSubscribers: "LIST_SUBSCRIBERS"
  of cmdHistory: "HISTORY"
  of cmdListTopics: "LIST_TOPICS"
  of cmdPresence: "PRESENCE"

proc `$`*(status: ResponseStatus): string =
  ## String representation of status.
  case status
  of statusOk: "OK"
  of statusNotFound: "NOT_FOUND"
  of statusError: "ERROR"
  of statusInvalid: "INVALID"
  of statusNoBarrel: "NO_BARREL"
  of statusBarrelExists: "BARREL_EXISTS"
  of statusBarrelNotFound: "BARREL_NOT_FOUND"
  of statusUnauthorized: "UNAUTHORIZED"

proc `$`*(req: Request): string =
  ## String representation of request.
  result = $req.command & "(seq=" & $req.seq
  if req.key.len > 0:
    result.add(", key=\"" & req.key & "\"")
  if req.value.len > 0:
    if req.value.len <= 50:
      result.add(", value=\"" & req.value & "\"")
    else:
      result.add(", value=<" & $req.value.len & " bytes>")
  result.add(")")

proc `$`*(resp: Response): string =
  ## String representation of response.
  result = $resp.status & "(seq=" & $resp.seq
  if resp.value.len > 0:
    if resp.value.len <= 50:
      result.add(", value=\"" & resp.value & "\"")
    else:
      result.add(", value=<" & $resp.value.len & " bytes>")
  result.add(")")


## BarrelStats JSON serialization

import std/json

proc encodeBarrelStats*(stats: BarrelStats): string =
  ## Encode BarrelStats to JSON string
  var jsonObj = newJObject()

  # Key statistics
  jsonObj["totalKeys"] = %stats.totalKeys
  jsonObj["activeKeys"] = %stats.activeKeys
  jsonObj["deletedKeys"] = %stats.deletedKeys

  # Storage statistics
  jsonObj["fileCount"] = %stats.fileCount
  jsonObj["totalSize"] = %stats.totalSize
  jsonObj["activeFileSize"] = %stats.activeFileSize

  # Performance statistics
  jsonObj["avgKeySize"] = %stats.avgKeySize
  jsonObj["avgValueSize"] = %stats.avgValueSize
  jsonObj["avgRecordSize"] = %stats.avgRecordSize

  # Compaction statistics
  jsonObj["fragmentationRatio"] = %stats.fragmentationRatio
  jsonObj["isCompacting"] = %stats.isCompacting
  jsonObj["lastCompactTime"] = %stats.lastCompactTime
  jsonObj["recordsScanned"] = %stats.recordsScanned
  jsonObj["recordsKept"] = %stats.recordsKept
  jsonObj["recordsDropped"] = %stats.recordsDropped

  # Configuration
  jsonObj["indexMode"] = %stats.indexMode
  jsonObj["syncMode"] = %stats.syncMode

  # Additional metadata
  jsonObj["dataPath"] = %stats.dataPath
  jsonObj["lastModified"] = %stats.lastModified

  result = $jsonObj

proc decodeBarrelStats*(jsonStr: string): BarrelStats =
  ## Decode BarrelStats from JSON string
  let jsonObj = parseJson(jsonStr)

  result.totalKeys = int64(jsonObj["totalKeys"].getInt())
  result.activeKeys = int64(jsonObj["activeKeys"].getInt())
  result.deletedKeys = int64(jsonObj["deletedKeys"].getInt())

  result.fileCount = jsonObj["fileCount"].getInt()
  result.totalSize = int64(jsonObj["totalSize"].getInt())
  result.activeFileSize = int64(jsonObj["activeFileSize"].getInt())

  result.avgKeySize = jsonObj["avgKeySize"].getFloat()
  result.avgValueSize = jsonObj["avgValueSize"].getFloat()
  result.avgRecordSize = jsonObj["avgRecordSize"].getFloat()

  result.fragmentationRatio = jsonObj["fragmentationRatio"].getFloat()
  result.isCompacting = jsonObj["isCompacting"].getBool()
  result.lastCompactTime = jsonObj["lastCompactTime"].getStr()
  result.recordsScanned = int64(jsonObj["recordsScanned"].getInt())
  result.recordsKept = int64(jsonObj["recordsKept"].getInt())
  result.recordsDropped = int64(jsonObj["recordsDropped"].getInt())

  result.indexMode = jsonObj["indexMode"].getStr()
  result.syncMode = jsonObj["syncMode"].getStr()

  result.dataPath = jsonObj["dataPath"].getStr()
  result.lastModified = jsonObj["lastModified"].getStr()


## Pub/Sub protocol extensions

type
  SubscribeRequest* = object
    topic*: string                 ## Exact topic name
    pattern*: string               ## Optional pattern for wildcard subscriptions
    options*: SubscribeOptions

  SubscribeOptions* = object
    enableKvEvents*: bool          ## Receive k/v change events
    enablePresence*: bool          ## Receive presence events
    replayHistory*: bool           ## Replay history on subscribe

  UnsubscribeRequest* = object
    topicOrPattern*: string        ## Topic or pattern to unsubscribe from (empty = all)

  PublishRequest* = object
    topic*: string
    messageType*: PubSubMessageType
    headers*: string               ## JSON-encoded headers
    payload*: string

  HistoryRequest* = object
    topic*: string
    count*: int                    ## Max messages to return (0 = use topic config)
    sinceSeq*: uint64              ## Only return messages with sequence >= this value

  ListTopicsRequest* = object
    pattern*: string               ## Optional pattern to filter topics (empty = all)

  PresenceRequest* = object
    operation*: uint8              ## 0 = get_online, 1 = broadcast_update

  PubSubEvent* = object
    topic*: string
    messageType*: PubSubMessageType
    sequence*: uint64
    timestamp*: int64
    headers*: string               ## JSON-encoded headers
    payload*: string

  SubscriptionInfo* = object
    subscriptionId*: string        ## UUID of the subscription
    clientId*: uint64              ## Client ID that owns the subscription
    topic*: string                 ## Exact topic (empty if pattern subscription)
    pattern*: string               ## Pattern (empty if exact topic subscription)

  TopicInfo* = object
    name*: string
    sequence*: uint64
    subscriberCount*: int
    messageCount*: int64

proc encodeSubscribeRequest*(req: SubscribeRequest): string =
  ## Encode a subscribe request
  ## Format: ``[options:1][topicLen:2][topic:N][patternLen:2][pattern:M]``

  var options: byte = 0
  if req.options.enableKvEvents:
    options = options or 0x01
  if req.options.enablePresence:
    options = options or 0x02
  if req.options.replayHistory:
    options = options or 0x04

  result = newStringOfCap(1 + 2 + req.topic.len + 2 + req.pattern.len)
  result.writeByte(options)
  result.writeUint16BE(uint16(req.topic.len))
  result.add(req.topic)
  result.writeUint16BE(uint16(req.pattern.len))
  result.add(req.pattern)

proc decodeSubscribeRequest*(data: string): SubscribeRequest =
  ## Decode a subscribe request
  var pos = 0

  let optionsByte = readByte(data, pos)
  result.options.enableKvEvents = (optionsByte and 0x01) != 0
  result.options.enablePresence = (optionsByte and 0x02) != 0
  result.options.replayHistory = (optionsByte and 0x04) != 0

  let topicLen = readUint16BE(data, pos)
  if topicLen > MaxKeySize:
    raise newException(ProtocolError, "Topic too large: " & $topicLen)
  result.topic = readString(data, pos, int(topicLen))

  let patternLen = readUint16BE(data, pos)
  if patternLen > MaxKeySize:
    raise newException(ProtocolError, "Pattern too large: " & $patternLen)
  result.pattern = readString(data, pos, int(patternLen))

proc encodePublishRequest*(req: PublishRequest): string =
  ## Encode a publish request
  ## Format: ``[topicLen:2][topic:N][msgType:1][headersLen:4][headers:M][payloadLen:4][payload:P]``

  result = newStringOfCap(2 + req.topic.len + 1 + 4 + req.headers.len + 4 + req.payload.len)
  result.writeUint16BE(uint16(req.topic.len))
  result.add(req.topic)
  result.writeByte(byte(ord(req.messageType)))
  result.writeUint32BE(uint32(req.headers.len))
  if req.headers.len > 0:
    result.add(req.headers)
  result.writeUint32BE(uint32(req.payload.len))
  if req.payload.len > 0:
    result.add(req.payload)

proc decodePublishRequest*(data: string): PublishRequest =
  ## Decode a publish request
  var pos = 0

  let topicLen = readUint16BE(data, pos)
  if topicLen > MaxKeySize:
    raise newException(ProtocolError, "Topic too large: " & $topicLen)
  result.topic = readString(data, pos, int(topicLen))

  result.messageType = PubSubMessageType(readByte(data, pos))

  let headersLen = readUint32BE(data, pos)
  if headersLen > MaxValueSize:
    raise newException(ProtocolError, "Headers too large: " & $headersLen)
  if headersLen > 0:
    result.headers = readString(data, pos, int(headersLen))
  else:
    result.headers = ""

  let payloadLen = readUint32BE(data, pos)
  if payloadLen > MaxValueSize:
    raise newException(ProtocolError, "Payload too large: " & $payloadLen)
  if payloadLen > 0:
    result.payload = readString(data, pos, int(payloadLen))
  else:
    result.payload = ""

proc encodeHistoryRequest*(req: HistoryRequest): string =
  ## Encode a history request
  ## Format: ``[topicLen:2][topic:N][count:4][sinceSeq:8]``

  result = newStringOfCap(2 + req.topic.len + 4 + 8)
  result.writeUint16BE(uint16(req.topic.len))
  result.add(req.topic)
  result.writeUint32BE(uint32(req.count))
  result.writeUint64BE(req.sinceSeq)

proc decodeHistoryRequest*(data: string): HistoryRequest =
  ## Decode a history request
  var pos = 0

  let topicLen = readUint16BE(data, pos)
  if topicLen > MaxKeySize:
    raise newException(ProtocolError, "Topic too large: " & $topicLen)
  result.topic = readString(data, pos, int(topicLen))

  result.count = int(readUint32BE(data, pos))
  result.sinceSeq = readUint64BE(data, pos)

proc encodePresenceRequest*(req: PresenceRequest): string =
  ## Encode a presence request
  ## Format: ``[operation:1]``

  result = newStringOfCap(1)
  result.writeByte(req.operation)

proc decodePresenceRequest*(data: string): PresenceRequest =
  ## Decode a presence request
  var pos = 0
  result.operation = uint8(readByte(data, pos))

## Pub/Sub event message encoding (server to client, async)
## Uses cmd byte 0xFF for events

proc encodePubSubEvent*(event: PubSubEvent): string =
  ## Encode a pub/sub event message for WebSocket transmission
  ## Format: ``[cmd:1][seq:4][topicLen:2][topic:N][msgType:1][seq:8][ts:8][headersLen:4][headers:M][payloadLen:4][payload:P]``

  result = newStringOfCap(1 + 4 + 2 + event.topic.len + 1 + 8 + 8 +
                          4 + event.headers.len + 4 + event.payload.len)

  # Command byte (0xFF for pub/sub events)
  result.writeByte(0xFF)

  # Sequence placeholder (not used for async events)
  result.writeByte(0)
  result.writeByte(0)
  result.writeByte(0)
  result.writeByte(0)

  # Topic
  result.writeUint16BE(uint16(event.topic.len))
  result.add(event.topic)

  # Message type
  result.writeByte(byte(ord(event.messageType)))

  # Message sequence
  result.writeUint64BE(event.sequence)

  # Timestamp
  result.writeUint64BE(uint64(event.timestamp))

  # Headers
  result.writeUint32BE(uint32(event.headers.len))
  if event.headers.len > 0:
    result.add(event.headers)

  # Payload
  result.writeUint32BE(uint32(event.payload.len))
  if event.payload.len > 0:
    result.add(event.payload)

proc decodePubSubEvent*(data: string): PubSubEvent =
  ## Decode a pub/sub event message
  var pos = 0

  # Skip command byte and seq placeholder
  discard readByte(data, pos)
  discard readUint32BE(data, pos)

  # Topic
  let topicLen = readUint16BE(data, pos)
  if topicLen > MaxKeySize:
    raise newException(ProtocolError, "Event topic too large: " & $topicLen)
  result.topic = readString(data, pos, int(topicLen))

  # Message type
  result.messageType = PubSubMessageType(readByte(data, pos))

  # Message sequence
  result.sequence = readUint64BE(data, pos)

  # Timestamp
  result.timestamp = int64(readUint64BE(data, pos))

  # Headers
  let headersLen = readUint32BE(data, pos)
  if headersLen > MaxValueSize:
    raise newException(ProtocolError, "Event headers too large: " & $headersLen)
  if headersLen > 0:
    result.headers = readString(data, pos, int(headersLen))
  else:
    result.headers = ""

  # Payload
  let payloadLen = readUint32BE(data, pos)
  if payloadLen > MaxValueSize:
    raise newException(ProtocolError, "Event payload too large: " & $payloadLen)
  if payloadLen > 0:
    result.payload = readString(data, pos, int(payloadLen))
  else:
    result.payload = ""


## Pub/Sub response decoding

proc isPubSubEvent*(data: string): bool =
  ## Check if binary data is a pub/sub event (command byte 0xFF)
  if data.len == 0:
    return false
  return byte(data[0]) == 0xFF

proc decodeSubscribeResponse*(value: string): string =
  ## Decode subscribe response
  ## The value field contains the subscription ID (UUID string)
  result = value

proc decodePublishResponse*(value: string): uint64 =
  ## Decode publish response
  ## The value field contains the sequence number as 8-byte big-endian uint64
  var pos = 0
  result = readUint64BE(value, pos)

type
  SubscriptionOptions* = SubscribeOptions  ## Alias for SubscribeOptions
