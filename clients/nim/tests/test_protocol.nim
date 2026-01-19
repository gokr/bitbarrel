## Protocol Tests for BitBarrel Client
##
## Tests the binary protocol encoding/decoding without requiring a server.

import std/[unittest, strutils]
import ../src/bitbarrel_client/protocol

suite "Protocol Command Constants":
  test "command values match specification":
    check cmdGet.uint8 == 0x01
    check cmdSet.uint8 == 0x02
    check cmdDelete.uint8 == 0x03
    check cmdExists.uint8 == 0x04
    check cmdCount.uint8 == 0x05
    check cmdListKeys.uint8 == 0x06
    check cmdPing.uint8 == 0x09
    check cmdCreateBarrel.uint8 == 0x10
    check cmdOpenBarrel.uint8 == 0x11
    check cmdUseBarrel.uint8 == 0x12
    check cmdCloseBarrel.uint8 == 0x13
    check cmdListBarrels.uint8 == 0x14
    check cmdDropBarrel.uint8 == 0x15
    check cmdRangeQuery.uint8 == 0x21
    check cmdPrefixQuery.uint8 == 0x22
    check cmdRangeCount.uint8 == 0x23
    check cmdTraverse.uint8 == 0x20

suite "Protocol Status Constants":
  test "status values match specification":
    check statusOk.uint8 == 0x00
    check statusNotFound.uint8 == 0x01
    check statusError.uint8 == 0x02
    check statusInvalid.uint8 == 0x03
    check statusNoBarrel.uint8 == 0x04
    check statusBarrelExists.uint8 == 0x05
    check statusBarrelNotFound.uint8 == 0x06

suite "Request Encoding/Decoding":
  test "simple GET request":
    let req = Request(command: cmdGet, seq: 1, key: "test_key", value: "")
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.command == cmdGet
    check decoded.seq == 1
    check decoded.key == "test_key"
    check decoded.value == ""

  test "SET request with value":
    let req = Request(command: cmdSet, seq: 42, key: "mykey", value: "myvalue")
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.command == cmdSet
    check decoded.seq == 42
    check decoded.key == "mykey"
    check decoded.value == "myvalue"

  test "DELETE request":
    let req = Request(command: cmdDelete, seq: 100, key: "delete_me", value: "")
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.command == cmdDelete
    check decoded.seq == 100
    check decoded.key == "delete_me"

  test "request with sequence number":
    let req = Request(command: cmdPing, seq: 0xFFFFFFFF'u32, key: "", value: "")
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.seq == 0xFFFFFFFF'u32

  test "request with key and value":
    let longKey = "a".repeat(1000)
    let longValue = "b".repeat(5000)
    let req = Request(command: cmdSet, seq: 5, key: longKey, value: longValue)
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.key == longKey
    check decoded.value == longValue

suite "Response Encoding/Decoding":
  test "OK response without value":
    let resp = Response(status: statusOk, seq: 1, value: "")
    let encoded = encodeResponse(resp)
    let decoded = decodeResponse(encoded)

    check decoded.status == statusOk
    check decoded.seq == 1
    check decoded.value == ""

  test "OK response with value":
    let resp = Response(status: statusOk, seq: 10, value: "hello world")
    let encoded = encodeResponse(resp)
    let decoded = decodeResponse(encoded)

    check decoded.status == statusOk
    check decoded.seq == 10
    check decoded.value == "hello world"

  test "error response":
    let resp = Response(status: statusError, seq: 5, value: "something went wrong")
    let encoded = encodeResponse(resp)
    let decoded = decodeResponse(encoded)

    check decoded.status == statusError
    check decoded.value == "something went wrong"

  test "not found response":
    let resp = Response(status: statusNotFound, seq: 7, value: "")
    let encoded = encodeResponse(resp)
    let decoded = decodeResponse(encoded)

    check decoded.status == statusNotFound

suite "Request Binary Format":
  test "binary format matches specification":
    let req = Request(command: cmdGet, seq: 0x01020304'u32, key: "AB", value: "")
    let encoded = encodeRequest(req)

    # [command:1][seq:4][flags:1][keyLen:2][key:N][valLen:4][value:M]
    check encoded[0] == char(0x01)  # cmdGet
    check encoded[1] == char(0x01)  # seq byte 0 (big-endian)
    check encoded[2] == char(0x02)  # seq byte 1
    check encoded[3] == char(0x03)  # seq byte 2
    check encoded[4] == char(0x04)  # seq byte 3
    check encoded[5] == char(0x00)  # flags
    check encoded[6] == char(0x00)  # keyLen high byte
    check encoded[7] == char(0x02)  # keyLen low byte
    check encoded[8] == 'A'
    check encoded[9] == 'B'
    check encoded[10] == char(0x00)  # valLen bytes (0)
    check encoded[11] == char(0x00)
    check encoded[12] == char(0x00)
    check encoded[13] == char(0x00)

suite "Response Binary Format":
  test "binary format matches specification":
    let resp = Response(status: statusOk, seq: 0x01020304'u32, value: "XY")
    let encoded = encodeResponse(resp)

    # [status:1][seq:4][valLen:4][value:M]
    check encoded[0] == char(0x00)  # statusOk
    check encoded[1] == char(0x01)  # seq byte 0 (big-endian)
    check encoded[2] == char(0x02)  # seq byte 1
    check encoded[3] == char(0x03)  # seq byte 2
    check encoded[4] == char(0x04)  # seq byte 3
    check encoded[5] == char(0x00)  # valLen bytes
    check encoded[6] == char(0x00)
    check encoded[7] == char(0x00)
    check encoded[8] == char(0x02)  # valLen = 2
    check encoded[9] == 'X'
    check encoded[10] == 'Y'

suite "Decode Errors":
  test "empty data":
    expect ProtocolError:
      discard decodeRequest("")

  test "too short request":
    expect ProtocolError:
      discard decodeRequest("123")  # Less than minimum

  test "truncated key":
    # Create a request that claims key length of 100 but only has 2 bytes
    var data = ""
    data.add char(0x01)  # command
    data.add char(0x00)  # seq (4 bytes)
    data.add char(0x00)
    data.add char(0x00)
    data.add char(0x01)
    data.add char(0x00)  # keyLen = 100
    data.add char(0x64)
    data.add "AB"  # Only 2 bytes of key

    expect ProtocolError:
      discard decodeRequest(data)

suite "Range Request Encoding":
  test "basic range query":
    let req = RangeRequest(startKey: "a", endKey: "z", limit: 100, cursor: "")
    let encoded = encodeRangeRequest(req)
    let decoded = decodeRangeRequest(encoded)

    check decoded.startKey == "a"
    check decoded.endKey == "z"
    check decoded.limit == 100
    check decoded.cursor == ""

  test "range with cursor":
    let req = RangeRequest(startKey: "user:0", endKey: "user:999", limit: 50, cursor: "user:100")
    let encoded = encodeRangeRequest(req)
    let decoded = decodeRangeRequest(encoded)

    check decoded.startKey == "user:0"
    check decoded.endKey == "user:999"
    check decoded.limit == 50
    check decoded.cursor == "user:100"

suite "Prefix Request Encoding":
  test "basic prefix query":
    let req = PrefixRequest(prefix: "user:", limit: 100, cursor: "")
    let encoded = encodePrefixRequest(req)
    let decoded = decodePrefixRequest(encoded)

    check decoded.prefix == "user:"
    check decoded.limit == 100
    check decoded.cursor == ""

  test "prefix with cursor":
    let req = PrefixRequest(prefix: "item:", limit: 25, cursor: "item:50")
    let encoded = encodePrefixRequest(req)
    let decoded = decodePrefixRequest(encoded)

    check decoded.prefix == "item:"
    check decoded.cursor == "item:50"

suite "Command String Conversion":
  test "command to string":
    check $cmdGet == "GET"
    check $cmdSet == "SET"
    check $cmdDelete == "DELETE"
    check $cmdPing == "PING"
    check $cmdCreateBarrel == "CREATE_BARREL"

suite "Status String Conversion":
  test "status to string":
    check $statusOk == "OK"
    check $statusNotFound == "NOT_FOUND"
    check $statusError == "ERROR"
    check $statusNoBarrel == "NO_BARREL"
