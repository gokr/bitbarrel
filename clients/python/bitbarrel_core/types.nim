## Python-compatible type definitions for BitBarrel client
##
## These types are designed to be exported to Python via nimpy

import nimpy

type
  TraverseOptions* {.exportpy.} = object
    includeFullData*: bool = false
    extractArrays*: bool = false
    firstOnly*: bool = false

  TraverseResult* {.exportpy.} = tuple
    path: string
    key: string
    value: string
    extractedData: string

  RangeResult* {.exportpy.} = tuple
    items: seq[(string, string)]
    nextCursor: string
    hasMore: bool
