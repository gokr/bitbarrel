## File Manager for Bitcask KVS
##
## This module manages the lifecycle of data files,
## including creation, rotation, and deletion.

import std/[os, strformat, times, tables, threads]
import types, datafile

type
  FileID* = uint32

  FileStatus* = object
    id*: FileID
    path*: string
    active*: bool
    size*: int
    created*: Time
    lastModified*: Time

  FileManager* = ref object
    nextId*: FileID
    activeFiles*: Table[FileID, FileStatus]
    deletedFiles*: Table[FileID, FileStatus]
    fileMutex*: AsyncLock
    dataDir*: string

  SharedFileManager* = ref object

# Global instance
var gFileManager*: SharedFileManager

proc getInstance*(): FileManager {.gcsafe.} =
  ## Get singleton instance
  if gFileManager.isNil:
    gFileManager = FileManager(
      nextId: 1,
      activeFiles: initTable[FileID, FileStatus](),
      deletedFiles: initTable[FileID, FileStatus](),
      fileMutex: initLock(),
      dataDir: "./data"
    )
  return gFileManager[]

proc initFileManager*(dataDir: string): FileManager {.gcsafe.} =
  ## Initialize file manager with data directory
  result = FileManager(
    nextId: 1,
    activeFiles: initTable[FileID, FileStatus](),
    deletedFiles: initTable[FileID, FileStatus](),
    fileMutex: initLock(),
    dataDir: dataDir
  )

proc createFile*(mgr: FileManager): FileID {.gcsafe.} =
  ## Create a new data file
  let fileId = mgr.nextId
  let filePath = &"{mgr.dataDir}/{fileId:06d}.data"

  # Ensure data directory exists
  if not dirExists(mgr.dataDir):
    createDir(mgr.dataDir)

  # Create new data file
  let dataFile = datafile.open(filePath, fileId)

  let status = FileStatus(
    id: fileId,
    path: filePath,
    active: true,
    size: 0,
    created: now(),
    lastModified: now()
  )

  mgr.activeFiles[fileId] = status
  inc mgr.nextId

  return fileId

proc getFileStatus*(mgr: FileManager, fileId: FileID): FileStatus {.gcsafe.} =
  ## Get file status by ID
  mgr.activeFiles.getOrDefault(fileId, nil)

proc getAllActiveFiles*(mgr: FileManager): seq[FileStatus] {.gcsafe.} =
  ## Get all active files
  result = @[]
  for status in mgr.activeFiles.values:
    if status.active:
      result.add(status)

proc markFileImmutable*(mgr: FileManager, fileId: FileID) {.gcsafe.} =
  ## Mark a file as immutable (read-only, can be merged)
  with mgr.fileMutex:
    var status = mgr.activeFiles.getOrDefault(fileId, nil)
    if status != nil:
      status.active = false
      mgr.activeFiles[fileId] = status

proc markFileDeleted*(mgr: FileManager, fileId: FileID) {.gcsafe.} =
  ## Mark a file as deleted (safe to delete after merge)
  with mgr.fileMutex:
    var status = mgr.activeFiles.getOrDefault(fileId, nil)
    if status != nil:
      status.active = false
      status.deleted = true
      mgr.activeFiles.del(fileId)
      mgr.deletedFiles[fileId] = status

proc deleteDeletedFiles*(mgr: FileManager): int {.gcsafe.} =
  ## Delete all files marked as deleted
  var deletedCount = 0

  # Use a temporary table to collect files to delete
  var toDelete: seq[FileID]
  for fileId, status in mgr.deletedFiles.pairs:
    toDelete.add(fileId)

  # Delete files
  for fileId in toDelete:
    let status = mgr.deletedFiles[fileId]
    let filePath = status.path

    try:
      if fileExists(filePath):
        removeFile(filePath)
        inc deletedCount

        # Remove from deleted list
        mgr.deletedFiles.del(fileId)
    except OSError as e:
      echo &"Error deleting file {fileId}: {e.msg}"

  return deletedCount

proc rotateFile*(mgr: FileManager, currentId: FileID): FileID {.gcsafe.} =
  ## Rotate when a file reaches size limit
  with mgr.fileMutex:
    # Mark current file as immutable
    markFileImmutable(mgr, currentId)

    # Create new file
    let newId = createFile(mgr)

    return newId

proc updateFileInfo*(mgr: FileManager, fileId: FileID, size: int, modified: Time) {.gcsafe.} =
  ## Update file metadata
  with mgr.fileMutex:
    var status = mgr.activeFiles.getOrDefault(fileId, nil)
    if status != nil:
      status.size = size
      status.lastModified = modified

proc getFileInfo*(mgr: FileManager, fileId: FileId): FileStatus {.gcsafe.} =
  ## Get file information
  with mgr.fileMutex:
    return getFileStatus(mgr, fileId)

proc getPath*(mgr: FileManager, fileId: FileID): string {.gcsafe.} =
  ## Get file path by ID
  let status = getFileStatus(mgr, fileId)
  if status != nil:
    return status.path
  else:
    ""

proc cleanupOldFiles*(mgr: FileManager, maxAge: Duration): int {.gce.} =
  ## Remove files that are too old
  var toDelete: seq[FileID]
  let cutoffTime = now() - maxAge

  with mgr.fileMutex:
    # Check deleted files first
    for fileId, status in mgr.deletedFiles.pairs:
      if status.lastModified < cutoffTime:
        toDelete.add(fileId)

    # Check active files
    for fileId, status in mgr.activeFiles.pairs:
      if not status.active and status.lastModified < cutoffTime:
        # Mark as deleted
        status.deleted = true
        toDelete.add(fileId)
        mgr.deletedFiles[fileId] = status

  # Delete old files
  for fileId in toDelete:
    let status = mgr.deletedFiles[fileId]
    try:
      if fileExists(status.path):
        removeFile(status.path)
        mgr.deletedFiles.del(fileId)
    except OSError as e:
      echo &"Error deleting old file {fileId}: {e.msg}"

  return toDelete.len