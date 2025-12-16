## Binary protocol for BitBarrel network communication
##
## Request Format: [type:1][seq:4][keyLen:2][key:N][valLen:4][value:M]
## Response Format: [status:1][seq:4][valLen:4][value:M]
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

  ResponseStatus* = enum
    statusOk = 0x00
    statusNotFound = 0x01
    statusError = 0x02
    statusInvalid = 0x03
    statusNoBarrel = 0x04
    statusBarrelExists = 0x05
    statusBarrelNotFound = 0x06

  Request* = object
    command*: Command
    seq*: uint32
    key*: string      ## Also used for barrel name
    value*: string    ## Also used for barrel config JSON

  Response* = object
    status*: ResponseStatus
    seq*: uint32
    value*: string

  ProtocolError* = object of CatchableError

const
  MaxKeySize* = 65535       ## 64KB max key size (2 bytes for length)
  MaxValueSize* = 1048576   ## 1MB max value size


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

proc readString(data: string, pos: var int, length: int): string =
  if pos + length > data.len:
    raise newException(ProtocolError, "Unexpected end of data reading string")
  result = data[pos ..< pos + length]
  pos += length


proc encodeRequest*(req: Request): string =
  ## Encode a request to binary format.
  ## Format: [type:1][seq:4][keyLen:2][key:N][valLen:4][value:M]
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
  # Validate command byte
  if cmdByte notin {0x01'u8, 0x02, 0x03, 0x04, 0x05, 0x06, 0x09,
                     0x10, 0x11, 0x12, 0x13, 0x14, 0x15}:
    raise newException(ProtocolError, "Invalid command: 0x" & cmdByte.toHex)

  result.command = Command(cmdByte)
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
  ## Format: [status:1][seq:4][valLen:4][value:M]
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
  if statusByte > byte(ord(high(ResponseStatus))):
    raise newException(ProtocolError, "Invalid status: 0x" & statusByte.toHex)

  result.status = ResponseStatus(statusByte)
  result.seq = readUint32BE(data, pos)

  let valLen = readUint32BE(data, pos)
  if valLen > MaxValueSize:
    raise newException(ProtocolError, "Value too large: " & $valLen)
  result.value = readString(data, pos, int(valLen))


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
  of cmdCreateBarrel: "CREATE_BARREL"
  of cmdOpenBarrel: "OPEN_BARREL"
  of cmdUseBarrel: "USE_BARREL"
  of cmdCloseBarrel: "CLOSE_BARREL"
  of cmdListBarrels: "LIST_BARRELS"
  of cmdDropBarrel: "DROP_BARREL"

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
