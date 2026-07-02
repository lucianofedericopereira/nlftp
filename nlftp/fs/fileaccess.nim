## FileAccess — the universal backend contract (port of lftp's `FileAccess`,
## src/FileAccess.h). Every protocol (local, ftp, http, sftp) subclasses this.
##
## lftp's poll-driven `Open(file, mode)` + `Read`/`Write` + `Done()` state
## machine is re-expressed as **async methods** over chronos (DECISIONS §2): a
## transfer is `openRead`/`openWrite` returning an async `DataReader`/`DataWriter`
## that the copy engine pumps between. Errors raise `NlftpError` instead of the
## C++ status enum (the enum's fatal/non-fatal distinction survives as
## `NlftpError.fatal`).

import std/options
import chronos
import ../core/errors
import fileinfo
export fileinfo, options

# --- abstract byte source / sink -------------------------------------------

type
  DataReader* = ref object of RootObj
    ## An async source of bytes (a local file, an FTP data connection, …).
  DataWriter* = ref object of RootObj
    ## An async sink of bytes, with explicit commit (`finish`) / `abort`.

method readSome*(r: DataReader; maxBytes = 65536): Future[seq[byte]]
    {.base, async: (raises: [CatchableError]).} =
  raiseError("readSome not implemented")

method atEnd*(r: DataReader): bool {.base, raises: [], gcsafe.} = true

method closeReader*(r: DataReader): Future[void]
    {.base, async: (raises: []).} = discard

type
  LengthLimitReader* = ref object of DataReader
    ## Wraps another reader, yielding at most `remaining` bytes — the generic
    ## way to turn an "offset-to-EOF" read into a bounded byte range (used by
    ## segmented pget when a backend lacks a native end-bounded read).
    inner: DataReader
    remaining: int64

proc newLengthLimitReader*(inner: DataReader; length: int64): DataReader =
  LengthLimitReader(inner: inner, remaining: length)

method readSome*(r: LengthLimitReader; maxBytes = 65536): Future[seq[byte]]
    {.async: (raises: [CatchableError]).} =
  if r.remaining <= 0: return @[]
  let want = min(maxBytes.int64, r.remaining).int
  let data = await r.inner.readSome(want)
  r.remaining -= data.len
  return data

method atEnd*(r: LengthLimitReader): bool {.raises: [], gcsafe.} =
  r.remaining <= 0 or r.inner.atEnd

method closeReader*(r: LengthLimitReader): Future[void] {.async: (raises: []).} =
  await r.inner.closeReader()

method writeSome*(w: DataWriter; data: seq[byte]): Future[void]
    {.base, async: (raises: [CatchableError]).} =
  raiseError("writeSome not implemented")

method finishWriter*(w: DataWriter): Future[void]
    {.base, async: (raises: [CatchableError]).} = discard

method abortWriter*(w: DataWriter): Future[void]
    {.base, async: (raises: []).} = discard

# --- the backend ------------------------------------------------------------

type
  FileAccess* = ref object of RootObj
    proto*: string
    host*: string
    port*: int
    user*: string
    password*: string
    cwd*: string
    connected*: bool

method getProto*(fa: FileAccess): string {.base, raises: [], gcsafe.} = fa.proto

method clone*(fa: FileAccess): Future[FileAccess]
    {.base, async: (raises: [CatchableError]).} =
  ## Return a backend usable concurrently with `fa`. Default returns `fa` itself
  ## — safe for backends whose operations are already independent (local; http,
  ## which dials a fresh connection per request). Connection-oriented backends
  ## (ftp, sftp) override this to open a SEPARATE connection, since one
  ## control/data channel cannot multiplex concurrent transfers.
  return fa

method connect*(fa: FileAccess): Future[void]
    {.base, async: (raises: [CatchableError]).} = discard

method close*(fa: FileAccess): Future[void]
    {.base, async: (raises: []).} = discard

method getCwd*(fa: FileAccess): string {.base, raises: [], gcsafe.} = fa.cwd

method setConcurrency*(fa: FileAccess; n: int) {.base, gcsafe, raises: [].} =
  ## Hint that up to `n` transfers may run concurrently on sibling connections.
  ## Backends that buffer in memory (http's gzip path) use this to shrink their
  ## per-connection buffer cap so the aggregate stays bounded. Default: no-op.
  discard

method chdir*(fa: FileAccess; dir: string): Future[void]
    {.base, async: (raises: [CatchableError]).} =
  raiseError(fa.proto & ": chdir not supported")

method listInfo*(fa: FileAccess; path = ""): Future[seq[FileInfo]]
    {.base, async: (raises: [CatchableError]).} =
  raiseError(fa.proto & ": listInfo not supported")

method openRead*(fa: FileAccess; path: string; offset: int64 = 0): Future[DataReader]
    {.base, async: (raises: [CatchableError]).} =
  raiseError(fa.proto & ": openRead not supported")

method size*(fa: FileAccess; path: string): Future[int64]
    {.base, async: (raises: [CatchableError]).} =
  ## File size in bytes, or -1 if unknown/unsupported (pget falls back to a
  ## single sequential download). Backends override with HEAD / SIZE / STAT.
  return -1

method openReadRange*(fa: FileAccess; path: string; offset, length: int64):
    Future[DataReader] {.base, async: (raises: [CatchableError]).} =
  ## Read exactly `length` bytes starting at `offset`. Default: an offset read
  ## bounded by a LengthLimitReader (works for any backend supporting offsets);
  ## HTTP overrides this with a precise `Range: start-end` request.
  let inner = await fa.openRead(path, offset)
  return newLengthLimitReader(inner, length)

method openWrite*(fa: FileAccess; path: string; offset: int64 = 0;
                  size: int64 = -1): Future[DataWriter]
    {.base, async: (raises: [CatchableError]).} =
  raiseError(fa.proto & ": openWrite not supported")

method mkdir*(fa: FileAccess; path: string; parents = false): Future[void]
    {.base, async: (raises: [CatchableError]).} =
  raiseError(fa.proto & ": mkdir not supported")

method remove*(fa: FileAccess; path: string): Future[void]
    {.base, async: (raises: [CatchableError]).} =
  raiseError(fa.proto & ": remove not supported")

method removeDir*(fa: FileAccess; path: string): Future[void]
    {.base, async: (raises: [CatchableError]).} =
  raiseError(fa.proto & ": removeDir not supported")

method rename*(fa: FileAccess; src, dst: string): Future[void]
    {.base, async: (raises: [CatchableError]).} =
  raiseError(fa.proto & ": rename not supported")

method chmodPath*(fa: FileAccess; path: string; mode: int): Future[void]
    {.base, async: (raises: [CatchableError]).} =
  raiseError(fa.proto & ": chmod not supported")
