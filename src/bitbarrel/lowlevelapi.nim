## Low-Level BitBarrel API Wrapper
##
## Provides convenient access to the low-level storage primitives
## Re-exports storage modules with consistent naming and documentation

import ../storage/[datafile, record, keydir, writebuffer, crc32]
import types

# Re-export all types and constructors
export types, datafile, record, keydir, writebuffer, crc32

# convenience aliases for common operations
template withDataFile*(path: string, fileId: uint32, body: untyped) =
  ## Convenience template for working with data files in a block
  var df = datafile.open(path, fileId)
  try:
    body
  finally:
    df.close()

template withKeyDir*(body: untyped) =
  ## Convenience template for working with KeyDir in a block
  var kd = keydir.init()
  body
  # KeyDir doesn't need explicit cleanup in current implementation

proc newRecordInfo*(recordPos, valuePos: uint64, valueSize, recordSize: uint32): RecordInfo =
  ## Helper to create RecordInfo
  result = RecordInfo(
    recordPos: recordPos,
    valuePos: valuePos,
    valueSize: valueSize,
    recordSize: recordSize
  )

proc newKeyDirEntry*(fileId: uint32, recordPos, valuePos: uint64, valueSize, recordSize: uint32, timestamp: int64): KeyDirEntry =
  ## Helper to create KeyDirEntry
  result = KeyDirEntry(
    fileId: fileId,
    recordPos: recordPos,
    valuePos: valuePos,
    valueSize: valueSize,
    timestamp: timestamp,
    recordSize: recordSize
  )

# Constants for easier access
const
  DEFAULT_RECORD_HEADER_SIZE* = 29  # From datafile module
  DEFAULT_CRC_SEED* = 0x0           # From crc32 module