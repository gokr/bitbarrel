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

proc newRecordInfo*(recordPos: uint64, valueSize, recordSize: uint32, keyLen: uint16): RecordInfo =
  ## Helper to create RecordInfo
  result = RecordInfo(
    recordPos: recordPos,
    valueSize: valueSize,
    recordSize: recordSize,
    keyLen: keyLen
  )

proc newKeyDirEntry*(recordPos: uint64, fileId: uint32, valueSize, recordSize: uint32, keyLen: uint16): KeyDirEntry =
  ## Helper to create KeyDirEntry
  result = KeyDirEntry(
    recordPos: recordPos,
    fileId: fileId,
    valueSize: valueSize,
    recordSize: recordSize,
    keyLen: keyLen
  )

# Constants for easier access
const
  DEFAULT_RECORD_HEADER_SIZE* = 29  # From datafile module
  DEFAULT_CRC_SEED* = 0x0           # From crc32 module