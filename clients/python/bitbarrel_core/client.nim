## BitBarrel Python client using Nimpy
##
## This module wraps the Nim network client to provide Python bindings

import nimpy
import std/[strformat, strutils]
import ../../../src/network/client
import ../../../src/network/protocol
import ./types

type
  ClientConfig* {.exportpy.} = object
    host*: string = "localhost"
    port*: int32 = 9876
    connectTimeout*: int32 = 5000

  BitBarrelClient* {.exportpy.} = object
    config*: ClientConfig
    client*: BitBarrelClientObj

proc newBitBarrelClient*(config: ClientConfig): BitBarrelClient {.exportpy.} =
  ## Create a new BitBarrel client
  result.config = config
  result.client = newClient(ClientConfig(
    host: config.host,
    port: Port(config.port),
    connectTimeout: int(config.connectTimeout)
  ))

proc newBitBarrelClient*(): BitBarrelClient {.exportpy.} =
  ## Create a new BitBarrel client with default configuration
  newBitBarrelClient(ClientConfig())

proc connect*(client: var BitBarrelClient) {.exportpy.} =
  ## Connect to the BitBarrel server
  client.client.connect()

proc close*(client: var BitBarrelClient) {.exportpy.} =
  ## Close the connection to the server
  client.client.close()

proc currentBarrel*(client: BitBarrelClient): string {.exportpy.} =
  ## Get the current barrel name
  client.client.currentBarrel

# Barrel management operations

proc createBarrel*(client: var BitBarrelClient, name: string, config: string = ""): bool {.exportpy.} =
  ## Create a new barrel on the server
  client.client.createBarrel(name, config)

proc openBarrel*(client: var BitBarrelClient, name: string): bool {.exportpy.} =
  ## Open an existing barrel on the server
  client.client.openBarrel(name)

proc useBarrel*(client: var BitBarrelClient, name: string): bool {.exportpy.} =
  ## Set the current barrel for this session
  client.client.useBarrel(name)

proc listBarrels*(client: var BitBarrelClient): seq[string] {.exportpy.} =
  ## List all available barrels on the server
  client.client.listBarrels()

proc closeBarrel*(client: var BitBarrelClient, name: string = ""): bool {.exportpy.} =
  ## Close a barrel
  if name.len == 0:
    return client.client.closeBarrel(client.client.currentBarrel)
  return client.client.closeBarrel(name)

proc dropBarrel*(client: var BitBarrelClient, name: string): bool {.exportpy.} =
  ## Delete a barrel and all its data
  client.client.deleteBarrel(name)

# Basic key-value operations

proc get*(client: var BitBarrelClient, key: string): string {.exportpy.} =
  ## Get value by key
  client.client.get(key)

proc set*(client: var BitBarrelClient, key: string, value: string): bool {.exportpy.} =
  ## Set key-value pair
  client.client.set(key, value)

proc delete*(client: var BitBarrelClient, key: string): bool {.exportpy.} =
  ## Delete a key
  client.client.delete(key)

proc exists*(client: var BitBarrelClient, key: string): bool {.exportpy.} =
  ## Check if key exists
  client.client.exists(key)

proc count*(client: var BitBarrelClient): int {.exportpy.} =
  ## Count all keys in current barrel
  client.client.listKeys().len

proc listKeys*(client: var BitBarrelClient): seq[string] {.exportpy.} =
  ## List all keys in current barrel
  client.client.listKeys()

proc ping*(client: var BitBarrelClient): bool {.exportpy.} =
  ## Ping the server
  client.client.ping()

# Range query operations

proc rangeQuery*(client: var BitBarrelClient, startKey: string, endKey: string,
                 limit: int = 1000, cursor: string = ""): RangeResult {.exportpy.} =
  ## Query key-value pairs in range [startKey, endKey) with cursor pagination
  ## Requires barrel opened in bmCritBit mode
  let (items, nextCursor, hasMore) = client.client.rangeQuery(
    startKey, endKey, limit, cursor)
  result = RangeResult(
    items: items,
    nextCursor: nextCursor,
    hasMore: hasMore
  )

proc prefixQuery*(client: var BitBarrelClient, prefix: string,
                  limit: int = 1000, cursor: string = ""): RangeResult {.exportpy.} =
  ## Query key-value pairs with prefix and cursor pagination
  ## Requires barrel opened in bmCritBit mode
  let (items, nextCursor, hasMore) = client.client.prefixQuery(
    prefix, limit, cursor)
  result = RangeResult(
    items: items,
    nextCursor: nextCursor,
    hasMore: hasMore
  )

proc rangeCount*(client: var BitBarrelClient, startKey: string, endKey: string): int {.exportpy.} =
  ## Count keys in range [startKey, endKey)
  client.client.rangeCount(startKey, endKey)

# Reference traversal

proc traverse*(client: var BitBarrelClient, key: string, pathSpec: string,
               includeFullData: bool = false, extractArrays: bool = false,
               firstOnly: bool = false): seq[TraverseResult] {.exportpy.} =
  ## Traverse references from a key using path specification
  let options = TraverseOptions(
    includeFullData: includeFullData,
    extractArrays: extractArrays,
    firstOnly: firstOnly
  )
  let nimResults = client.client.traverse(key, pathSpec, options)
  result = newSeq[TraverseResult](nimResults.len)
  for i, r in nimResults:
    result[i] = (
      path: r.path,
      key: r.key,
      value: r.value,
      extractedData: r.extractedData
    )

proc traversePath*(client: var BitBarrelClient, key: string, pathSpec: string): seq[TraverseResult] {.exportpy.} =
  ## Traverse with default options (include full data, no extraction)
  client.traverse(key, pathSpec, includeFullData = true)
