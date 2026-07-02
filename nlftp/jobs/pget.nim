## Segmented parallel download — port of lftp's `pget` (pgetJob.cc).
##
## Downloads one remote file in N concurrent byte-range segments, each on its
## own connection (clone()), writing directly to the local file at the segment
## offset. Uses chronos async concurrency (no threads). Falls back to a single
## sequential transfer when the size is unknown or the file is small.
##
## The destination is always local, so the segments write through plain file
## handles (one per segment, disjoint regions) rather than the FileAccess writer
## abstraction — which is built around atomic temp-file commit, not concurrent
## offset writes.

import std/os
import chronos
import ../core/errors
import ../core/config
import ../fs/fileaccess

type
  PgetResult* = object
    bytes*: int64
    segments*: int

proc downloadSegment(conn: FileAccess; remotePath, localPath: string;
                     start, length: int64) {.async.} =
  let reader = await conn.openReadRange(remotePath, start, length)
  var f: File
  if not open(f, localPath, fmReadWriteExisting):
    await reader.closeReader()
    raiseError("pget: cannot open " & localPath & " for writing", fatal = true)
  f.setFilePos(start)
  try:
    while not reader.atEnd:
      let chunk = await reader.readSome()
      if chunk.len == 0: break
      if f.writeBuffer(unsafeAddr chunk[0], chunk.len) != chunk.len:
        raiseError("pget: short write", fatal = true)
  finally:
    close(f)
    await reader.closeReader()

proc pget*(remote: FileAccess; remotePath, localPath: string;
           n: int): Future[PgetResult] {.async.} =
  let total = await remote.size(remotePath)
  let nseg = max(1, n)

  # Fall back to a plain sequential download when splitting won't help.
  if total < 0 or nseg <= 1 or total < int64(MinSegmentBytes) * 2:
    let reader = await remote.openRead(remotePath)
    var f: File
    if not open(f, localPath, fmWrite):
      await reader.closeReader()
      raiseError("pget: cannot create " & localPath, fatal = true)
    var got = 0'i64
    try:
      while not reader.atEnd:
        let chunk = await reader.readSome()
        if chunk.len == 0: break
        discard f.writeBuffer(unsafeAddr chunk[0], chunk.len)
        got += chunk.len
    finally:
      close(f)
      await reader.closeReader()
    return PgetResult(bytes: got, segments: 1)

  # Preallocate the output file to `total` so segment handles can seek+write.
  block:
    var f = open(localPath, fmWrite)
    if total > 0:
      f.setFilePos(total - 1)
      var z: byte = 0
      discard f.writeBuffer(addr z, 1)
    close(f)

  # Build segments and a connection per segment (segment 0 reuses `remote`).
  let segSize = total div nseg
  var conns: seq[FileAccess]
  var tasks: seq[Future[void]]
  for i in 0 ..< nseg:
    let start = int64(i) * segSize
    let length = (if i == nseg - 1: total - start else: segSize)
    let conn = if i == 0: remote else: await remote.clone()
    conns.add conn
    tasks.add downloadSegment(conn, remotePath, localPath, start, length)
  await allFutures(tasks)

  # Close the cloned connections (not the original).
  for i in 1 ..< conns.len:
    if conns[i] != remote:
      await conns[i].close()

  return PgetResult(bytes: total, segments: nseg)
