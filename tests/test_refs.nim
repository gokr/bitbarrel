## Test Reference Model Utilities

import std/unittest
import std/json
import std/tables
import ../src/bitbarrel/refs

suite "Reference Model Tests":
  test "extractRefs - empty refs":
    let value = "{\"data\": {\"name\": \"test\"}}"
    let refs = extractRefs(value)
    check refs.len == 0

  test "extractRefs - with refs field":
    let value = """{
      "data": {"name": "test"},
      "_refs": {
        "friends": ["user:1", "user:2"],
        "posts": ["post:1"]
      }
    }"""
    let refs = extractRefs(value)
    check refs.len == 2
    check refs["friends"].len == 2
    check refs["posts"].len == 1
    check refs["friends"][0] == "user:1"
    check refs["friends"][1] == "user:2"
    check refs["posts"][0] == "post:1"

  test "extractRefs - invalid JSON":
    let value = "not json"
    let refs = extractRefs(value)
    check refs.len == 0

  test "extractRefs - _refs not an object":
    let value = "{\"_refs\": \"not an object\"}"
    let refs = extractRefs(value)
    check refs.len == 0

  test "hasRefs - detects refs":
    let noRefs = "{\"data\": {}}"
    let withRefs = """{"_refs": {"friends": []}}"""

    check not hasRefs(noRefs)
    check hasRefs(withRefs)

  test "parsePathSpec - simple relationship":
    let steps = parsePathSpec("friends")
    check steps.len == 1
    check steps[0].relType == "friends"
    check not steps[0].isArraySlice

  test "parsePathSpec - multiple steps":
    let steps = parsePathSpec("friends->team->matches")
    check steps.len == 3
    check steps[0].relType == "friends"
    check steps[1].relType == "team"
    check steps[2].relType == "matches"

  test "parsePathSpec - with array index":
    let steps = parsePathSpec("friends[0]")
    check steps.len == 1
    check steps[0].relType == "friends"
    check steps[0].isArraySlice
    check steps[0].arraySlice.a == 0
    check steps[0].arraySlice.b == 0

  test "parsePathSpec - with array range":
    let steps = parsePathSpec("friends[0:5]")
    check steps.len == 1
    check steps[0].relType == "friends"
    check steps[0].isArraySlice
    check steps[0].arraySlice.a == 0
    check steps[0].arraySlice.b == 5

  test "parsePathSpec - with negative index":
    let steps = parsePathSpec("friends[-1]")
    check steps.len == 1
    check steps[0].relType == "friends"
    check steps[0].isArraySlice
    check steps[0].arraySlice.a == -1
    check steps[0].arraySlice.b == -1

  test "parsePathSpec - wildcard":
    let steps = parsePathSpec("*")
    check steps.len == 1
    check steps[0].relType == "*"

  test "parsePathSpec - complex path":
    let steps = parsePathSpec("friends[0:5]->team->matches[-1]")
    check steps.len == 3
    check steps[0].relType == "friends"
    check steps[0].isArraySlice
    check steps[0].arraySlice.a == 0
    check steps[0].arraySlice.b == 5
    check steps[1].relType == "team"
    check not steps[1].isArraySlice
    check steps[2].relType == "matches"
    check steps[2].isArraySlice
    check steps[2].arraySlice.a == -1

  test "applySlice - basic range":
    let keys = @["a", "b", "c", "d", "e"]
    let sliced = applySlice(keys, Slice[int](a: 1, b: 3))
    check sliced.len == 3
    check sliced[0] == "b"
    check sliced[1] == "c"
    check sliced[2] == "d"

  test "applySlice - negative indices":
    let keys = @["a", "b", "c", "d", "e"]
    let sliced = applySlice(keys, Slice[int](a: -2, b: -1))
    check sliced.len == 2
    check sliced[0] == "d"
    check sliced[1] == "e"

  test "applySlice - single index":
    let keys = @["a", "b", "c"]
    let sliced = applySlice(keys, Slice[int](a: 1, b: 1))
    check sliced.len == 1
    check sliced[0] == "b"

  test "applySlice - out of bounds returns last element":
    let keys = @["a", "b", "c"]
    let sliced = applySlice(keys, Slice[int](a: 10, b: 20))
    # When range is beyond bounds, should clamp to end
    check sliced.len == 1
    check sliced[0] == "c"

  test "applySlice - empty keys":
    let keys: seq[string] = @[]
    let sliced = applySlice(keys, Slice[int](a: 0, b: 5))
    check sliced.len == 0

  test "refsToJson - converts table to JSON":
    var refs = initTable[string, seq[string]]()
    refs["friends"] = @["user:1", "user:2"]
    refs["posts"] = @["post:1"]

    let jsonStr = refsToJson(refs)
    let jsonNode = parseJson(jsonStr)

    check jsonNode.kind == JObject
    check jsonNode["friends"].kind == JArray
    check jsonNode["friends"].len == 2
    check jsonNode["posts"].len == 1

  test "validateRefs - empty key detection":
    var refs = initTable[string, seq[string]]()
    refs["friends"] = @["user:1", "", "user:2"]

    let errors = validateRefs(refs)
    check errors.len > 0
    # Just check that we got an error
    check errors.len == 1

  test "detectCycle - detects existing key in path":
    let path = @["user:1", "user:2", "user:3"]
    check detectCycle(path, "user:2")
    check not detectCycle(path, "user:4")

  test "getAllRefs - flattens all refs":
    var refs = initTable[string, seq[string]]()
    refs["friends"] = @["user:1", "user:2"]
    refs["posts"] = @["post:1"]

    let allRefs = getAllRefs(refs)
    check allRefs.len == 3
    check "user:1" in allRefs
    check "user:2" in allRefs
    check "post:1" in allRefs

  test "countRefs - counts total references":
    var refs = initTable[string, seq[string]]()
    refs["friends"] = @["user:1", "user:2"]
    refs["posts"] = @["post:1", "post:2", "post:3"]

    let count = countRefs(refs)
    check count == 5
