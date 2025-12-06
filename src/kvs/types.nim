## Common types and constants for the KVS implementation

const
  MAGIC_NUMBER* = "BCKS"
  VERSION* = 1'u32
  HEADER_SIZE* = 32
  MAX_KEY_SIZE* = 64 * 1024  # 64KB
  MAX_VALUE_SIZE* = 1 * 1024 * 1024  # 1MB

type
  FileHeader* = object
    magic*: array[4, char]
    version*: uint32
    created*: int64
    fileSize*: uint64
    reserved*: array[8, byte]

  KeyDirEntry* = object
    fileId*: uint32      # Which data file contains the record
    valuePos*: uint64    # Position of value within file
    valueSize*: uint32   # Size of value
    timestamp*: int64    # For conflict resolution and TTL
    recordSize*: uint32  # Total record size for merge decisions

  Command* = enum
    cmdGet = 0x01
    cmdSet = 0x02
    cmdDelete = 0x03
    cmdExists = 0x04
    cmdScan = 0x05
    cmdStats = 0x06

  Status* = enum
    statusOK = 0x00
    statusError = 0x01
    statusNotFound = 0x02
    statusServerError = 0x03