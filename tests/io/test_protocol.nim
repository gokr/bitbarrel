import unittest, std/strutils
import ../../src/network/protocol

suite "Binary Protocol Tests":

  test "encode/decode GET request roundtrip":
    let req = Request(command: cmdGet, key: "test_key", seq: 1234)
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.command == cmdGet
    check decoded.seq == 1234
    check decoded.key == "test_key"
    check decoded.value == ""

  test "encode/decode SET request roundtrip":
    let req = Request(command: cmdSet, key: "user:123", value: "{\"name\":\"John\"}", seq: 5678)
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.command == cmdSet
    check decoded.seq == 5678
    check decoded.key == "user:123"
    check decoded.value == "{\"name\":\"John\"}"

  test "encode/decode CREATE_BARREL request with config":
    let config = """{"mode":"normal","syncMode":"sync"}"""
    let req = Request(command: cmdCreateBarrel, key: "mydb", value: config, seq: 42)
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.command == cmdCreateBarrel
    check decoded.seq == 42
    check decoded.key == "mydb"
    check decoded.value == config

  test "encode/decode response roundtrip":
    let resp = Response(status: statusOk, seq: 999, value: "success")
    let encoded = encodeResponse(resp)
    let decoded = decodeResponse(encoded)

    check decoded.status == statusOk
    check decoded.seq == 999
    check decoded.value == "success"

  test "encode/decode empty key and value":
    let req = Request(command: cmdPing, seq: 0)
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.command == cmdPing
    check decoded.seq == 0
    check decoded.key.len == 0
    check decoded.value.len == 0

  test "encode/decode not found response":
    let resp = Response(status: statusNotFound, seq: 100)
    let encoded = encodeResponse(resp)
    let decoded = decodeResponse(encoded)

    check decoded.status == statusNotFound
    check decoded.seq == 100
    check decoded.value.len == 0

  test "encodeRequest validates key size limit":
    let longKey = "x".repeat(MaxKeySize + 1)
    let req = Request(command: cmdGet, key: longKey)

    expect ProtocolError:
      discard encodeRequest(req)

  test "encodeRequest validates value size limit":
    let longValue = "x".repeat(MaxValueSize + 1)
    let req = Request(command: cmdSet, key: "test", value: longValue)

    expect ProtocolError:
      discard encodeRequest(req)

  test "decodeRequest rejects invalid command byte":
    let data = "\xFF\0\0\0\x01\0\0"  # Invalid command 0xFF
    expect ProtocolError:
      discard decodeRequest(data)

  test "decodeRequest handles truncated data":
    let data = "\x01\0\0\0\x01"  # Missing key length
    expect ProtocolError:
      discard decodeRequest(data)

  test "decodeRequest handles oversize key length":
    let data = "\x01\0\0\0\x01\xFF\xFF"  # Key length = 65535 (too large for remaining data)
    expect ProtocolError:
      discard decodeRequest(data)

  test "big-endian encoding verification":
    # Test specific byte patterns to ensure big-endian encoding
    let req = Request(command: cmdGet, key: "AB", value: "XYZ", seq: 0x12345678)
    let encoded = encodeRequest(req)

    # Verify specific byte positions
    # [0x01] = cmdGet
    check encoded[0] == char(0x01)
    # [1-4] = seq = 0x12345678 in big-endian
    check encoded[1] == char(0x12)
    check encoded[2] == char(0x34)
    check encoded[3] == char(0x56)
    check encoded[4] == char(0x78)
    # [5-6] = key_len = 2 in big-endian
    check encoded[5] == char(0x00)
    check encoded[6] == char(0x02)
    # [7-8] = "AB"
    check encoded[7] == 'A'
    check encoded[8] == 'B'
    # [9-12] = val_len = 3 in big-endian
    check encoded[9] == char(0x00)
    check encoded[10] == char(0x00)
    check encoded[11] == char(0x00)
    check encoded[12] == char(0x03)
    # [13-15] = "XYZ"
    check encoded[13] == 'X'
    check encoded[14] == 'Y'
    check encoded[15] == 'Z'

  test "unicode support in strings":
    let unicodeKey = "键"  # Chinese character
    let unicodeValue = "值🦄"  # Value with emoji
    let req = Request(command: cmdSet, key: unicodeKey, value: unicodeValue, seq: 100)
    let encoded = encodeRequest(req)
    let decoded = decodeRequest(encoded)

    check decoded.key == unicodeKey
    check decoded.value == unicodeValue
    check decoded.seq == 100

  test "response helpers create correct responses":
    check okResponse(100, "data").status == statusOk
    check okResponse(100).value == ""

    check errorResponse(200, "bad").status == statusError
    check errorResponse(200, "bad").value == "bad"
    check errorResponse(200).status == statusError
    check errorResponse(200).value == ""  # No message parameter

    check notFoundResponse(300).status == statusNotFound
    check notFoundResponse(300).value.len == 0

    check noBarrelResponse(400).status == statusNoBarrel

    check barrelExistsResponse(500).status == statusBarrelExists

    check barrelNotFoundResponse(600).status == statusBarrelNotFound

    check invalidResponse(700, "format").status == statusInvalid
    check invalidResponse(700, "format").value == "format"

  test "string representations":
    let req = Request(command: cmdSet, key: "user", value: "data", seq: 42)
    check $req == "SET(seq=42, key=\"user\", value=\"data\")"

    let longValue = "x".repeat(100)
    let longReq = Request(command: cmdSet, key: "test", value: longValue, seq: 1)
    check $longReq == "SET(seq=1, key=\"test\", value=<100 bytes>)"

    let resp = okResponse(123, "success")
    check $resp == "OK(seq=123, value=\"success\")"

    let longResp = errorResponse(456, longValue)
    check $longResp == "ERROR(seq=456, value=<100 bytes>)"

  test "all command codes are covered":
    let allCommands = [
      cmdGet, cmdSet, cmdDelete, cmdExists, cmdCount, cmdListKeys, cmdPing,
      cmdCreateBarrel, cmdOpenBarrel, cmdUseBarrel, cmdCloseBarrel, cmdListBarrels, cmdDropBarrel
    ]

    for cmd in allCommands:
      let req = Request(command: cmd, key: "test", seq: 123)
      let encoded = encodeRequest(req)
      let decoded = decodeRequest(encoded)
      check decoded.command == cmd

  test "all status codes are covered":
    let allStatuses = [
      statusOk, statusNotFound, statusError, statusInvalid, statusNoBarrel,
      statusBarrelExists, statusBarrelNotFound
    ]

    for status in allStatuses:
      let resp = Response(status: status, seq: 456, value: "test")
      let encoded = encodeResponse(resp)
      let decoded = decodeResponse(encoded)
      check decoded.status == status
  # Batch operation tests

  test "BatchGet request encode/decode roundtrip":
    let req = BatchGetRequest(
      seq: 1234,
      keys: @["key1", "key2", "key3"]
    )
    let encoded = encodeBatchGetRequest(req)
    let decoded = decodeBatchGetRequest(encoded)

    check decoded.seq == 1234
    check decoded.keys.len == 3
    check decoded.keys[0] == "key1"
    check decoded.keys[1] == "key2"
    check decoded.keys[2] == "key3"

  test "BatchGet response encode/decode roundtrip":
    let resp = BatchGetResponse(
      seq: 5678,
      results: @[(uint8(ord(statusOk)), "value1"),
                 (uint8(ord(statusNotFound)), ""),
                 (uint8(ord(statusOk)), "value3")]
    )
    let encoded = encodeBatchGetResponse(resp)
    let decoded = decodeBatchGetResponse(encoded)

    check decoded.seq == 5678
    check decoded.results.len == 3
    check decoded.results[0].status == uint8(ord(statusOk))
    check decoded.results[0].value == "value1"
    check decoded.results[1].status == uint8(ord(statusNotFound))
    check decoded.results[1].value == ""
    check decoded.results[2].status == uint8(ord(statusOk))
    check decoded.results[2].value == "value3"

  test "BatchSet request encode/decode roundtrip":
    let req = BatchSetRequest(
      seq: 9999,
      pairs: @[("key1", "value1"), ("key2", "value2")]
    )
    let encoded = encodeBatchSetRequest(req)
    let decoded = decodeBatchSetRequest(encoded)

    check decoded.seq == 9999
    check decoded.pairs.len == 2
    check decoded.pairs[0].key == "key1"
    check decoded.pairs[0].value == "value1"
    check decoded.pairs[1].key == "key2"
    check decoded.pairs[1].value == "value2"

  test "BatchSet response encode/decode roundtrip":
    let resp = BatchSetResponse(
      seq: 1111,
      statuses: @[uint8(ord(statusOk)), uint8(ord(statusError)), uint8(ord(statusOk))]
    )
    let encoded = encodeBatchSetResponse(resp)
    let decoded = decodeBatchSetResponse(encoded)

    check decoded.seq == 1111
    check decoded.statuses.len == 3
    check decoded.statuses[0] == uint8(ord(statusOk))
    check decoded.statuses[1] == uint8(ord(statusError))
    check decoded.statuses[2] == uint8(ord(statusOk))

  test "BatchDelete request encode/decode roundtrip":
    let req = BatchDeleteRequest(
      seq: 2222,
      keys: @["key1", "key2", "key3", "key4"]
    )
    let encoded = encodeBatchDeleteRequest(req)
    let decoded = decodeBatchDeleteRequest(encoded)

    check decoded.seq == 2222
    check decoded.keys.len == 4
    check decoded.keys[0] == "key1"
    check decoded.keys[1] == "key2"
    check decoded.keys[2] == "key3"
    check decoded.keys[3] == "key4"

  test "BatchDelete response encode/decode roundtrip":
    let resp = BatchDeleteResponse(
      seq: 3333,
      statuses: @[uint8(ord(statusOk)), uint8(ord(statusOk)), uint8(ord(statusError))]
    )
    let encoded = encodeBatchDeleteResponse(resp)
    let decoded = decodeBatchDeleteResponse(encoded)

    check decoded.seq == 3333
    check decoded.statuses.len == 3
    check decoded.statuses[0] == uint8(ord(statusOk))
    check decoded.statuses[1] == uint8(ord(statusOk))
    check decoded.statuses[2] == uint8(ord(statusError))

  test "BatchGet request with empty keys":
    let req = BatchGetRequest(seq: 4444, keys: @[])
    let encoded = encodeBatchGetRequest(req)
    let decoded = decodeBatchGetRequest(encoded)

    check decoded.seq == 4444
    check decoded.keys.len == 0

  test "Batch operations validate MaxBatchItems limit":
    var manyKeys: seq[string]
    for i in 0..<MaxBatchItems + 1:
      manyKeys.add("key" & $i)

    let req = BatchGetRequest(seq: 5555, keys: manyKeys)
    expect ProtocolError:
      discard encodeBatchGetRequest(req)

  test "BatchSet request validates individual key/value sizes":
    let longKey = "x".repeat(MaxKeySize + 1)
    let req = BatchSetRequest(
      seq: 6666,
      pairs: @[(longKey, "value")]
    )
    expect ProtocolError:
      discard encodeBatchSetRequest(req)

  test "BatchGet response with all not-found results":
    let resp = BatchGetResponse(
      seq: 7777,
      results: @[(uint8(ord(statusNotFound)), ""),
                 (uint8(ord(statusNotFound)), "")]
    )
    let encoded = encodeBatchGetResponse(resp)
    let decoded = decodeBatchGetResponse(encoded)

    check decoded.results.len == 2
    check decoded.results[0].status == uint8(ord(statusNotFound))
    check decoded.results[1].status == uint8(ord(statusNotFound))
