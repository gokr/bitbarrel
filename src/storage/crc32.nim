## CRC32 Implementation Wrapper
##
## This module provides a unified interface for CRC32 calculation
## with compile-time selection between crunchy (optimized) and
## original lookup table implementation.

when defined(useCrunchy):
  ## Use crunchy library for optimized CRC32 calculation
  import crunchy

  proc crc32*(data: string): uint32 =
    ## Calculate CRC32 checksum using crunchy library
    result = crunchy.crc32(data)

else:
  ## Use original lookup table implementation (default)
  ## CRC32 lookup table for fast computation (IEEE 802.3 polynomial)
  const CRC32_TABLE: array[256, uint32] = block:
    var table: array[256, uint32]
    for i in 0'u32 ..< 256'u32:
      var crc = i
      for j in 0 ..< 8:
        if (crc and 1) != 0:
          crc = (crc shr 1) xor 0xEDB88320'u32
        else:
          crc = crc shr 1
      table[i] = crc
    table

  proc crc32*(data: string): uint32 =
    ## Calculate CRC32 checksum using lookup table (10-100x faster than bit-by-bit)
    result = 0xFFFFFFFF'u32
    for b in data:
      let index = (result xor b.uint32) and 0xFF
      result = (result shr 8) xor CRC32_TABLE[index]
    result = result xor 0xFFFFFFFF'u32
