## Compression Abstraction Layer for BitBarrel
##
## This module provides a unified interface for different compression algorithms
## selected at compile time. Currently supports:
## - LZ4 (with lz4wrapper)
## - Snappy (with supersnappy)
## - No compression (default)

{.experimental: "codeReordering".}

import ../bitbarrel/types

# Compression algorithm IDs
const
  ALG_NONE* = 0
  ALG_LZ4* = 1
  ALG_SNAPPY* = 2

type
  CompressionError* = object of ValueError
    ## Raised when compression/decompression fails

# Compile-time algorithm selection
when defined(lz4Compression):
  import lz4wrapper
  const
    compressionEnabled* = true
    algorithmId* = ALG_LZ4
    algorithmName* = "LZ4"

  proc compress*(src: openArray[byte]): seq[byte] {.raises: [CompressionError].} =
    ## Compress data using LZ4
    if src.len == 0:
      return @[]

    let maxCompressed = compressBound(src.len)
    result = newSeq[byte](maxCompressed)

    let compressedSize = compress(src, result)
    if isError(compressedSize):
      raise newException(CompressionError, "LZ4 compression failed: " & getErrorName(compressedSize))

    result.setLen(compressedSize)

  proc decompress*(src: openArray[byte], expectedSize: int): seq[byte] {.raises: [CompressionError].} =
    ## Decompress LZ4 data
    if src.len == 0:
      return @[]

    result = newSeq[byte](expectedSize)

    let decompressedSize = decompress(src, result)
    if isError(decompressedSize):
      raise newException(CompressionError, "LZ4 decompression failed: " & getErrorName(decompressedSize))

    if decompressedSize != expectedSize:
      raise newException(CompressionError, "LZ4 decompression size mismatch: expected " &
                         $expectedSize & ", got " & $decompressedSize)

elif defined(snappyCompression):
  import supersnappy
  const
    compressionEnabled* = true
    algorithmId* = ALG_SNAPPY
    algorithmName* = "Snappy"

  proc compress*(src: openArray[byte]): seq[byte] {.raises: [CompressionError].} =
    ## Compress data using Snappy
    try:
      if src.len == 0:
        return @[]
      let srcStr = cast[string](src)
      let compressed = supersnappy.compress(srcStr)
      result = cast[seq[byte]](compressed)
    except SnappyError as e:
      raise newException(CompressionError, "Snappy compression failed: " & e.msg)

  proc decompress*(src: openArray[byte], expectedSize: int): seq[byte] {.raises: [CompressionError].} =
    ## Decompress Snappy data
    if src.len == 0:
      return @[]

    try:
      let srcStr = cast[string](src)
      let decompressedStr = supersnappy.uncompress(srcStr)
      result = cast[seq[byte]](decompressedStr)

      if result.len != expectedSize:
        raise newException(CompressionError, "Snappy decompression size mismatch: expected " &
                           $expectedSize & ", got " & $result.len)
    except SnappyError as e:
      raise newException(CompressionError, "Snappy decompression failed: " & e.msg)

else:
  const
    compressionEnabled* = false
    algorithmId* = ALG_NONE
    algorithmName* = "None"

  proc compress*(src: openArray[byte]): seq[byte] {.raises: [].} =
    ## No compression - just copy data
    result = @src

  proc decompress*(src: openArray[byte], expectedSize: int): seq[byte] {.raises: [CompressionError].} =
    ## No decompression needed
    if src.len != expectedSize:
      raise newException(CompressionError, "Uncompressed data size mismatch: expected " &
                         $expectedSize & ", got " & $src.len)
    result = @src

# Utility procedures
proc shouldCompress*(value: openArray[byte], threshold: int): bool {.inline.} =
  ## Determine if data should be compressed based on size and algorithm availability
  result = compressionEnabled and value.len >= threshold

proc compressionRatio*(originalSize, compressedSize: int): float {.inline.} =
  ## Calculate compression ratio (original/compressed)
  if originalSize == 0:
    result = 1.0
  else:
    result = originalSize.float / compressedSize.float

proc isCompressionBeneficial*(originalSize, compressedSize: int, minRatio: float = 1.1): bool {.inline.} =
  ## Check if compression provides enough benefit
  result = compressionRatio(originalSize, compressedSize) >= minRatio