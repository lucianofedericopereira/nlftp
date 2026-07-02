## LocalAccess — the local-filesystem backend (port of lftp's `LocalAccess`,
## src/LocalAccess.cc). The smallest complete `FileAccess`, used both directly
## (`file:` / bare paths) and as the prototype validating the contract.
##
## Local disk I/O is done with ordinary blocking file ops wrapped in resolved
## futures: like lftp, local access isn't truly async (POSIX files are always
## "ready"), and a chunked read keeps the event loop responsive enough.

import std/[os, times, options]
import chronos
import ../core/errors
import fileaccess, fileinfo

type
  LocalAccess* = ref object of FileAccess

  LocalReader = ref object of DataReader
    f: File
    done: bool

  LocalWriter = ref object of DataWriter
    f: File
    path: string
    tmpPath: string

# std/os FilePermission is ordered x,w,r per class — map to standard unix bits.
const permBit: array[FilePermission, int] = [
  fpUserExec:   0o100, fpUserWrite:   0o200, fpUserRead:   0o400,
  fpGroupExec:  0o010, fpGroupWrite:  0o020, fpGroupRead:  0o040,
  fpOthersExec: 0o001, fpOthersWrite: 0o002, fpOthersRead: 0o004]

proc resolve(fa: LocalAccess; path: string): string =
  if path.len == 0: fa.cwd
  elif isAbsolute(path): path
  else: absolutePath(path, fa.cwd)

proc newLocalAccess*(cwd = getCurrentDir()): LocalAccess =
  LocalAccess(proto: "file", cwd: cwd, connected: true)

# --- reader ----------------------------------------------------------------

method readSome(r: LocalReader; maxBytes = 65536): Future[seq[byte]]
    {.async: (raises: [CatchableError]).} =
  var buf = newSeq[byte](maxBytes)
  let n = r.f.readBuffer(addr buf[0], maxBytes)
  buf.setLen(n)
  if n == 0: r.done = true
  return buf

method atEnd(r: LocalReader): bool {.raises: [], gcsafe.} = r.done

method closeReader(r: LocalReader): Future[void] {.async: (raises: []).} =
  try: close(r.f)
  except Exception: discard

# --- writer ----------------------------------------------------------------

method writeSome(w: LocalWriter; data: seq[byte]): Future[void]
    {.async: (raises: [CatchableError]).} =
  if data.len > 0:
    let n = w.f.writeBuffer(unsafeAddr data[0], data.len)
    if n != data.len:
      raiseError("short write to " & w.path, fatal = true)

method finishWriter(w: LocalWriter): Future[void]
    {.async: (raises: [CatchableError]).} =
  close(w.f)
  if w.tmpPath.len > 0 and w.tmpPath != w.path:
    try: moveFile(w.tmpPath, w.path)
    except Exception as e: raiseError("rename failed: " & e.msg, fatal = true)

method abortWriter(w: LocalWriter): Future[void] {.async: (raises: []).} =
  try:
    close(w.f)
    if w.tmpPath.len > 0 and fileExists(w.tmpPath): removeFile(w.tmpPath)
  except Exception: discard

# --- backend ---------------------------------------------------------------

method chdir(fa: LocalAccess; dir: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  let target = fa.resolve(dir)
  if not dirExists(target):
    raiseError("cd: " & dir & ": no such directory")
  fa.cwd = target

method listInfo(fa: LocalAccess; path = ""): Future[seq[fileinfo.FileInfo]]
    {.async: (raises: [CatchableError]).} =
  let dir = fa.resolve(path)
  if not dirExists(dir):
    raiseError("ls: " & path & ": no such directory")
  var res: seq[fileinfo.FileInfo]
  for kind, p in walkDir(dir, relative = false):
    let name = extractFilename(p)
    var fi: fileinfo.FileInfo
    fi.name = name
    case kind
    of pcFile:         fi.kind = ftFile
    of pcDir:          fi.kind = ftDir
    of pcLinkToFile, pcLinkToDir: fi.kind = ftSymlink
    try:
      let info = getFileInfo(p, followSymlink = false)
      fi.size = some(info.size.int64)
      fi.mtime = some(info.lastWriteTime)
      var bits = 0
      for perm in info.permissions:
        bits = bits or permBit[perm]
      fi.mode = some(bits)
    except Exception: discard
    res.add fi
  return res

method size(fa: LocalAccess; path: string): Future[int64]
    {.async: (raises: [CatchableError]).} =
  let p = fa.resolve(path)
  return if fileExists(p): getFileSize(p) else: -1

method openRead(fa: LocalAccess; path: string; offset: int64 = 0): Future[DataReader]
    {.async: (raises: [CatchableError]).} =
  let p = fa.resolve(path)
  var f: File
  if not open(f, p, fmRead):
    raiseError("cannot open " & path & " for reading", fatal = true)
  if offset > 0: f.setFilePos(offset)
  return LocalReader(f: f)

method openWrite(fa: LocalAccess; path: string; offset: int64 = 0;
                 size: int64 = -1): Future[DataWriter]
    {.async: (raises: [CatchableError]).} =
  let p = fa.resolve(path)
  var f: File
  if offset > 0:
    # resume: open existing in-place
    if not open(f, p, fmReadWriteExisting):
      raiseError("cannot open " & path & " for resume", fatal = true)
    f.setFilePos(offset)
    return LocalWriter(f: f, path: p, tmpPath: "")
  else:
    let tmp = p & ".nlftp-tmp"
    if not open(f, tmp, fmWrite):
      raiseError("cannot open " & path & " for writing", fatal = true)
    return LocalWriter(f: f, path: p, tmpPath: tmp)

method mkdir(fa: LocalAccess; path: string; parents = false): Future[void]
    {.async: (raises: [CatchableError]).} =
  let p = fa.resolve(path)
  try:
    if parents: createDir(p)
    else: createDir(p)   # std createDir already makes parents; ok either way
  except Exception as e:
    raiseError("mkdir: " & e.msg)

method remove(fa: LocalAccess; path: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  let p = fa.resolve(path)
  try: removeFile(p)
  except Exception as e: raiseError("rm: " & e.msg)

method removeDir(fa: LocalAccess; path: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  let p = fa.resolve(path)
  try: removeDir(p)
  except Exception as e: raiseError("rmdir: " & e.msg)

method rename(fa: LocalAccess; src, dst: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  try: moveFile(fa.resolve(src), fa.resolve(dst))
  except Exception as e: raiseError("mv: " & e.msg)

method chmodPath(fa: LocalAccess; path: string; mode: int): Future[void]
    {.async: (raises: [CatchableError]).} =
  let p = fa.resolve(path)
  var perms: set[FilePermission]
  for perm in FilePermission:
    if (mode and permBit[perm]) != 0:
      perms.incl perm
  try: setFilePermissions(p, perms)
  except Exception as e: raiseError("chmod: " & e.msg)
