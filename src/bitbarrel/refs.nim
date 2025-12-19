## Reference Model Utilities
##
## Provides functions for extracting and traversing references stored
## in JSON values using the _refs field pattern.

import std/[json, strutils, tables, sets, strformat]

export json, tables, sets

type
  RefError* = object of ValueError
    ## Raised when reference parsing or traversal fails

  PathStep* = object
    ## Represents a single step in a traversal path
    relType*: string          ## Relationship type ("friends", "*", etc.)
    arraySlice*: Slice[int]   ## Array slice [0], [0:5], [-1]
    isArraySlice*: bool       ## True if this step includes array indexing

  TraverseOptions* = object
    ## Options controlling traversal behavior
    includeFullData*: bool    ## Return full values or just paths
    extractArrays*: bool      ## Extract array elements individually
    firstOnly*: bool          ## Stop after first result

  RefsTraverseResult* = object
    ## Result of a traversal operation
    path*: string            ## Full traversal path
    key*: string             ## Key of the result
    fullValue*: string       ## Complete value (if includeFullData=true)
    extractedData*: string   ## Extracted array elements (if extractArrays=true)
    depth*: int              ## Depth from starting key

const
  REFS_FIELD* = "_refs"  ## Special field name for storing references

## Extract references from a JSON value
proc extractRefs*(value: string): Table[string, seq[string]] =
  ## Parses a JSON string and extracts the _refs field if present
  ## Returns a table mapping relationship types to arrays of referenced keys
  result = initTable[string, seq[string]]()

  try:
    let jsonNode = parseJson(value)
    if jsonNode.kind != JObject:
      return result

    if REFS_FIELD in jsonNode:
      let refsNode = jsonNode[REFS_FIELD]
      if refsNode.kind == JObject:
        for relType, refArray in refsNode:
          if refArray.kind == JArray:
            result[relType] = @[]
            for refItem in refArray:
              if refItem.kind == JString:
                result[relType].add(refItem.getStr())
  except JsonParsingError:
    # If JSON parsing fails, return empty refs
    discard

## Check if a value contains references
proc hasRefs*(value: string): bool =
  ## Returns true if the value contains a _refs field with references
  let refs = extractRefs(value)
  result = refs.len > 0

## Parse a path specification string into PathStep objects
proc parsePathSpec*(pathSpec: string): seq[PathStep] =
  ## Parses path specifications like "friends->team->matches[0:10]"
  ## Supports wildcards, array indexing, and ranges
  result = @[]

  if pathSpec.len == 0:
    return result

  let parts = pathSpec.split("->")
  for part in parts:
    var step = PathStep(
      relType: "",
      arraySlice: 0..0,
      isArraySlice: false
    )

    # Check for array indexing: friends[0], posts[-1], matches[0:10]
    let bracketOpen = part.find('[')
    if bracketOpen >= 0:
      let bracketClose = part.find(']', bracketOpen)
      if bracketClose > bracketOpen:
        step.relType = part[0..<bracketOpen]
        let sliceStr = part[bracketOpen+1..<bracketClose]

        # Parse slice: [n], [start:end], [-1]
        if sliceStr.find(':') >= 0:
          # Range slice [start:end] or [start:] or [:end]
          let colonPos = sliceStr.find(':')
          var startStr = ""
          var endStr = ""

          if colonPos > 0:
            startStr = sliceStr[0..<colonPos]
          if colonPos < sliceStr.len - 1:
            endStr = sliceStr[colonPos+1..^1]

          var start = 0
          var ending = int.high

          if startStr.len > 0:
            start = parseInt(startStr)
          if endStr.len > 0:
            ending = parseInt(endStr)

          step.arraySlice = start..ending
        else:
          # Single index [n] or [-1]
          let idx = parseInt(sliceStr)
          step.arraySlice = idx..idx

        step.isArraySlice = true
      else:
        # Malformed brackets, treat as regular relType
        step.relType = part
    else:
      # No array indexing
      step.relType = part

    result.add(step)

## Apply array slicing to a sequence of keys
proc applySlice*(keys: seq[string], slice: Slice[int]): seq[string] =
  ## Applies array slicing to a sequence, supporting negative indices
  if keys.len == 0:
    return @[]

  var start = slice.a
  var ending = slice.b

  # Handle negative indices
  if start < 0:
    start = keys.len + start
  if ending < 0:
    ending = keys.len + ending
  elif ending == int.high:
    ending = keys.len - 1

  # Clamp to valid range
  start = max(0, min(start, keys.len - 1))
  ending = max(0, min(ending, keys.len - 1))

  # Check if completely out of bounds
  if start >= keys.len or ending < 0 or start > ending:
    return @[]

  result = keys[start..ending]

## Convert a table of references to JSON string
proc refsToJson*(refs: Table[string, seq[string]]): string =
  ## Converts a reference table back to JSON format for storage
  var jsonObj = newJObject()

  for relType, keys in refs:
    var keyArray = newJArray()
    for key in keys:
      keyArray.add(newJString(key))
    jsonObj[relType] = keyArray

  result = $jsonObj

## Validate reference keys
proc validateRefs*(refs: Table[string, seq[string]]): seq[string] =
  ## Validates reference keys and returns a list of errors
  ## (e.g., empty keys, invalid formats)
  result = @[]

  for relType, keys in refs:
    for key in keys:
      if key.len == 0:
        result.add(fmt("Empty key in relationship '{relType}'"))
      # Add more validation rules as needed

## Check for circular references in a traversal
proc detectCycle*(path: seq[string], nextKey: string): bool =
  ## Returns true if nextKey would create a cycle in the path
  result = nextKey in path

## Get all referenced keys across all relationship types
proc getAllRefs*(refs: Table[string, seq[string]]): seq[string] =
  ## Returns a flat list of all referenced keys
  var allKeys: seq[string] = @[]
  for keys in refs.values:
    allKeys.add(keys)

  # Remove duplicates by converting to set and back
  var keySet = initHashSet[string]()
  for key in allKeys:
    keySet.incl(key)

  result = @[]
  for key in keySet:
    result.add(key)

## Count total references
proc countRefs*(refs: Table[string, seq[string]]): int =
  ## Returns the total number of references
  result = 0
  for keys in refs.values:
    result += keys.len
