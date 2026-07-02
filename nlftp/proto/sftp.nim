## SFTP backend — port of lftp's `SFtp` (src/SFtp.cc).
##
## lftp speaks the SFTP wire protocol over an `ssh -s sftp` subprocess; we do the
## same via chronos asyncproc (DECISIONS: SSH = spawn system ssh, no pure-Nim SSH).
## This implements SFTP **v3** (the universally supported version): the
## length-prefixed packet framing, the INIT/VERSION handshake, and the core
## requests (OPENDIR/READDIR, OPEN/READ/WRITE/CLOSE, MKDIR/RMDIR/REMOVE/RENAME,
## REALPATH/STAT).
##
## Auth: key-based (BatchMode) when no password; PASSWORD auth without a PTY via
## SSH_ASKPASS — ssh asks our own binary for the password, forced with
## SSH_ASKPASS_REQUIRE=force (OpenSSH >= 8.4). No PtyShell needed.
##
## VERIFICATION STATUS: codec unit-tested; the live path is VERIFIED end-to-end
## against test.rebex.net (sftp://demo:password@…): password login, OPENDIR/
## READDIR listing, and OPEN/READ download all work.

import std/[strutils, options, times, strtabs, os]
import chronos, chronos/asyncproc
import chronos/streams/asyncstream
import ../core/errors
import ../fs/[fileaccess, fileinfo]

# --- protocol constants ----------------------------------------------------

const
  FXP_INIT = 1'u8
  FXP_VERSION = 2'u8
  FXP_OPEN = 3'u8
  FXP_CLOSE = 4'u8
  FXP_READ = 5'u8
  FXP_WRITE = 6'u8
  FXP_OPENDIR = 11'u8
  FXP_READDIR = 12'u8
  FXP_REMOVE = 13'u8
  FXP_MKDIR = 14'u8
  FXP_RMDIR = 15'u8
  FXP_REALPATH = 16'u8
  FXP_STAT = 17'u8
  FXP_RENAME = 18'u8
  FXP_STATUS = 101'u8
  FXP_HANDLE = 102'u8
  FXP_DATA = 103'u8
  FXP_NAME = 104'u8
  FXP_ATTRS = 105'u8

  FXF_READ = 0x01'u32
  FXF_WRITE = 0x02'u32
  FXF_CREAT = 0x08'u32
  FXF_TRUNC = 0x10'u32

  ATTR_SIZE = 0x01'u32
  ATTR_PERMISSIONS = 0x04'u32
  ATTR_ACMODTIME = 0x08'u32

  FX_OK = 0'u32
  FX_EOF = 1'u32

  SftpVersion = 3'u32

# --- codec -----------------------------------------------------------------

type
  SftpBuf* = object
    data*: seq[byte]

  SftpReader* = object
    data: seq[byte]
    pos: int

  SftpAttrs* = object
    size*: Option[int64]
    perms*: Option[uint32]
    mtime*: Option[int64]

proc putU8*(b: var SftpBuf; v: uint8) = b.data.add v

proc putU32*(b: var SftpBuf; v: uint32) =
  b.data.add byte((v shr 24) and 0xff)
  b.data.add byte((v shr 16) and 0xff)
  b.data.add byte((v shr 8) and 0xff)
  b.data.add byte(v and 0xff)

proc putU64*(b: var SftpBuf; v: uint64) =
  for i in countdown(7, 0):
    b.data.add byte((v shr (i*8)) and 0xff)

proc putStr*(b: var SftpBuf; s: string) =
  b.putU32(uint32(s.len))
  for c in s: b.data.add byte(c)

proc initReader*(data: seq[byte]): SftpReader = SftpReader(data: data, pos: 0)

proc remaining*(r: SftpReader): int = r.data.len - r.pos

proc getU8*(r: var SftpReader): uint8 =
  result = r.data[r.pos]; inc r.pos

proc getU32*(r: var SftpReader): uint32 =
  result = (uint32(r.data[r.pos]) shl 24) or (uint32(r.data[r.pos+1]) shl 16) or
           (uint32(r.data[r.pos+2]) shl 8) or uint32(r.data[r.pos+3])
  r.pos += 4

proc getU64*(r: var SftpReader): uint64 =
  result = 0
  for i in 0 ..< 8:
    result = (result shl 8) or uint64(r.data[r.pos + i])
  r.pos += 8

proc getStr*(r: var SftpReader): string =
  let n = int(r.getU32())
  result = newString(n)
  for i in 0 ..< n: result[i] = char(r.data[r.pos + i])
  r.pos += n

proc getAttrs*(r: var SftpReader): SftpAttrs =
  let flags = r.getU32()
  if (flags and ATTR_SIZE) != 0: result.size = some(int64(r.getU64()))
  if (flags and 0x02'u32) != 0: (discard r.getU32(); discard r.getU32()) # uid/gid
  if (flags and ATTR_PERMISSIONS) != 0: result.perms = some(r.getU32())
  if (flags and ATTR_ACMODTIME) != 0:
    discard r.getU32()                     # atime
    result.mtime = some(int64(r.getU32())) # mtime

# --- backend ---------------------------------------------------------------

type
  SftpAccess* = ref object of FileAccess
    process: AsyncProcessRef
    si: AsyncStreamWriter
    so: AsyncStreamReader
    reqId: uint32

  SftpReaderObj = ref object of DataReader
    fa: SftpAccess
    handle: string
    offset: uint64
    done: bool

  SftpWriterObj = ref object of DataWriter
    fa: SftpAccess
    handle: string
    offset: uint64

proc newSftpAccess*(host: string; port: int; user, password: string): SftpAccess =
  SftpAccess(proto: "sftp", host: host, port: (if port != 0: port else: 22),
             user: user, password: password, cwd: ".")

proc nextId(fa: SftpAccess): uint32 =
  inc fa.reqId
  fa.reqId

proc sendPacket(fa: SftpAccess; ptype: uint8; payload: seq[byte]) {.async.} =
  var frame: SftpBuf
  frame.putU32(uint32(1 + payload.len))   # length covers type + payload
  frame.putU8(ptype)
  frame.data.add payload
  await fa.si.write(frame.data)

proc recvPacket(fa: SftpAccess): Future[(uint8, seq[byte])] {.async.} =
  var lenBuf = newSeq[byte](4)
  await fa.so.readExactly(addr lenBuf[0], 4)
  var lr = initReader(lenBuf)
  let length = int(lr.getU32())
  if length < 1: raiseError("sftp: zero-length packet", fatal = true)
  var body = newSeq[byte](length)
  await fa.so.readExactly(addr body[0], length)
  return (body[0], body[1 .. ^1])

proc expectStatusOk(fa: SftpAccess; what: string) {.async.} =
  let (ptype, payload) = await fa.recvPacket()
  if ptype != FXP_STATUS:
    raiseError("sftp: " & what & ": unexpected packet " & $ptype)
  var r = initReader(payload)
  discard r.getU32()                 # request id
  let code = r.getU32()
  if code != FX_OK:
    let msg = r.getStr()
    raiseError("sftp: " & what & ": " & msg & " (code " & $code & ")")

method connect(fa: SftpAccess): Future[void] {.async: (raises: [CatchableError]).} =
  var args: seq[string]
  var env: StringTableRef = nil
  if fa.password.len > 0:
    # password auth without a PTY: ssh asks our own binary (as SSH_ASKPASS) for
    # the password, forced via SSH_ASKPASS_REQUIRE (OpenSSH >= 8.4).
    args.add ["-oBatchMode=no", "-oNumberOfPasswordPrompts=1"]
    env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    env["SSH_ASKPASS"] = getAppFilename()
    env["SSH_ASKPASS_REQUIRE"] = "force"
    env["NLFTP_ASKPASS"] = "1"
    env["NLFTP_SFTP_PW"] = fa.password
  else:
    args.add "-oBatchMode=yes"            # key-only
  args.add "-oStrictHostKeyChecking=accept-new"
  if fa.port != 22: args.add ["-p", $fa.port]
  if fa.user.len > 0: args.add ["-l", fa.user]
  args.add [fa.host, "-s", "sftp"]
  fa.process = await startProcess("/usr/bin/ssh", arguments = args,
                                  environment = env,
                                  stdinHandle = AsyncProcess.Pipe,
                                  stdoutHandle = AsyncProcess.Pipe)
  fa.si = fa.process.stdinStream()
  fa.so = fa.process.stdoutStream()

  # INIT -> VERSION
  var initp: SftpBuf
  initp.putU32(SftpVersion)
  await fa.sendPacket(FXP_INIT, initp.data)
  let (ptype, payload) = await fa.recvPacket()
  if ptype != FXP_VERSION:
    raiseError("sftp: expected VERSION, got " & $ptype, fatal = true)
  var r = initReader(payload)
  let v = r.getU32()
  if v < SftpVersion:
    raiseError("sftp: server version " & $v & " < 3", fatal = true)
  # resolve home dir
  try:
    var rp: SftpBuf
    let id = fa.nextId()
    rp.putU32(id); rp.putStr(".")
    await fa.sendPacket(FXP_REALPATH, rp.data)
    let (rt, rpay) = await fa.recvPacket()
    if rt == FXP_NAME:
      var rr = initReader(rpay)
      discard rr.getU32()      # id
      discard rr.getU32()      # count
      fa.cwd = rr.getStr()
  except CatchableError: discard
  fa.connected = true

method clone(fa: SftpAccess): Future[FileAccess]
    {.async: (raises: [CatchableError]).} =
  ## A fresh ssh -s sftp session at the same cwd (for parallel transfers).
  let c = newSftpAccess(fa.host, fa.port, fa.user, fa.password)
  await c.connect()
  if fa.cwd.len > 0 and fa.cwd != ".":
    await c.chdir(fa.cwd)
  return c

method close(fa: SftpAccess): Future[void] {.async: (raises: []).} =
  try:
    if not fa.si.isNil: await fa.si.closeWait()
  except CatchableError: discard
  if not fa.process.isNil:
    discard fa.process.terminate()
    await fa.process.closeWait()

proc absPath(fa: SftpAccess; path: string): string =
  if path.len == 0: fa.cwd
  elif path.startsWith("/"): path
  elif fa.cwd.endsWith("/"): fa.cwd & path
  else: fa.cwd & "/" & path

# --- listing ---------------------------------------------------------------

method listInfo(fa: SftpAccess; path = ""): Future[seq[fileinfo.FileInfo]]
    {.async: (raises: [CatchableError]).} =
  let dir = fa.absPath(path)
  var op: SftpBuf
  op.putU32(fa.nextId()); op.putStr(dir)
  await fa.sendPacket(FXP_OPENDIR, op.data)
  let (ht, hpay) = await fa.recvPacket()
  if ht != FXP_HANDLE:
    var r = initReader(hpay); discard r.getU32()
    raiseError("sftp: opendir " & dir & ": " & (if r.remaining > 0: r.getStr() else: "failed"))
  var hr = initReader(hpay); discard hr.getU32()
  let handle = hr.getStr()

  var res: seq[fileinfo.FileInfo]
  block readLoop:
    while true:
      var rd: SftpBuf
      rd.putU32(fa.nextId()); rd.putStr(handle)
      await fa.sendPacket(FXP_READDIR, rd.data)
      let (pt, pay) = await fa.recvPacket()
      if pt == FXP_STATUS: break readLoop      # EOF
      if pt != FXP_NAME: break readLoop
      var r = initReader(pay)
      discard r.getU32()                        # id
      let count = r.getU32()
      for _ in 0 ..< count:
        let fname = r.getStr()
        discard r.getStr()                      # longname
        let attrs = r.getAttrs()
        if fname in [".", ".."]: continue
        var fi: fileinfo.FileInfo
        fi.name = fname
        if attrs.perms.isSome:
          let m = attrs.perms.get
          fi.kind = if (m and 0o170000) == 0o040000: ftDir
                    elif (m and 0o170000) == 0o120000: ftSymlink
                    else: ftFile
          fi.mode = some(int(m and 0o777))
        else:
          fi.kind = ftFile
        if attrs.size.isSome: fi.size = attrs.size
        if attrs.mtime.isSome:
          fi.mtime = some(fromUnix(attrs.mtime.get))
        res.add fi

  var cp: SftpBuf
  cp.putU32(fa.nextId()); cp.putStr(handle)
  await fa.sendPacket(FXP_CLOSE, cp.data)
  try: await fa.expectStatusOk("close") except CatchableError: discard
  return res

# --- read ------------------------------------------------------------------

method readSome(r: SftpReaderObj; maxBytes = 65536): Future[seq[byte]]
    {.async: (raises: [CatchableError]).} =
  if r.done: return @[]
  var rq: SftpBuf
  rq.putU32(r.fa.nextId()); rq.putStr(r.handle)
  rq.putU64(r.offset); rq.putU32(uint32(maxBytes))
  await r.fa.sendPacket(FXP_READ, rq.data)
  let (pt, pay) = await r.fa.recvPacket()
  if pt == FXP_STATUS:
    r.done = true                # EOF (or error treated as end)
    return @[]
  if pt != FXP_DATA:
    raiseError("sftp: read: unexpected packet " & $pt)
  var rr = initReader(pay)
  discard rr.getU32()            # id
  let data = rr.getStr()
  r.offset += uint64(data.len)
  if data.len == 0: r.done = true
  return cast[seq[byte]](data)

method atEnd(r: SftpReaderObj): bool {.raises: [], gcsafe.} = r.done

method closeReader(r: SftpReaderObj): Future[void] {.async: (raises: []).} =
  try:
    var cp: SftpBuf
    cp.putU32(r.fa.nextId()); cp.putStr(r.handle)
    await r.fa.sendPacket(FXP_CLOSE, cp.data)
    await r.fa.expectStatusOk("close")
  except CatchableError: discard

method size(fa: SftpAccess; path: string): Future[int64]
    {.async: (raises: [CatchableError]).} =
  var p: SftpBuf
  p.putU32(fa.nextId()); p.putStr(fa.absPath(path))
  await fa.sendPacket(FXP_STAT, p.data)
  let (pt, pay) = await fa.recvPacket()
  if pt != FXP_ATTRS: return -1
  var r = initReader(pay)
  discard r.getU32()                 # request id
  let a = r.getAttrs()
  return if a.size.isSome: a.size.get else: -1

method openRead(fa: SftpAccess; path: string; offset: int64 = 0): Future[DataReader]
    {.async: (raises: [CatchableError]).} =
  var op: SftpBuf
  op.putU32(fa.nextId()); op.putStr(fa.absPath(path))
  op.putU32(FXF_READ); op.putU32(0)            # no attrs
  await fa.sendPacket(FXP_OPEN, op.data)
  let (ht, hpay) = await fa.recvPacket()
  if ht != FXP_HANDLE:
    raiseError("sftp: open " & path & " for read failed")
  var hr = initReader(hpay); discard hr.getU32()
  return SftpReaderObj(fa: fa, handle: hr.getStr(), offset: uint64(offset))

# --- write -----------------------------------------------------------------

method writeSome(w: SftpWriterObj; data: seq[byte]): Future[void]
    {.async: (raises: [CatchableError]).} =
  if data.len == 0: return
  var wq: SftpBuf
  wq.putU32(w.fa.nextId()); wq.putStr(w.handle)
  wq.putU64(w.offset)
  wq.putU32(uint32(data.len))
  for b in data: wq.data.add b
  await w.fa.sendPacket(FXP_WRITE, wq.data)
  await w.fa.expectStatusOk("write")
  w.offset += uint64(data.len)

method finishWriter(w: SftpWriterObj): Future[void]
    {.async: (raises: [CatchableError]).} =
  var cp: SftpBuf
  cp.putU32(w.fa.nextId()); cp.putStr(w.handle)
  await w.fa.sendPacket(FXP_CLOSE, cp.data)
  await w.fa.expectStatusOk("close")

method abortWriter(w: SftpWriterObj): Future[void] {.async: (raises: []).} =
  try:
    var cp: SftpBuf
    cp.putU32(w.fa.nextId()); cp.putStr(w.handle)
    await w.fa.sendPacket(FXP_CLOSE, cp.data)
    await w.fa.expectStatusOk("close")
  except CatchableError: discard

method openWrite(fa: SftpAccess; path: string; offset: int64 = 0;
                 size: int64 = -1): Future[DataWriter]
    {.async: (raises: [CatchableError]).} =
  var op: SftpBuf
  op.putU32(fa.nextId()); op.putStr(fa.absPath(path))
  op.putU32(FXF_WRITE or FXF_CREAT or FXF_TRUNC); op.putU32(0)
  await fa.sendPacket(FXP_OPEN, op.data)
  let (ht, hpay) = await fa.recvPacket()
  if ht != FXP_HANDLE:
    raiseError("sftp: open " & path & " for write failed")
  var hr = initReader(hpay); discard hr.getU32()
  return SftpWriterObj(fa: fa, handle: hr.getStr(), offset: uint64(offset))

# --- directory ops ---------------------------------------------------------

proc simpleReq(fa: SftpAccess; ptype: uint8; what: string;
               args: seq[string]) {.async.} =
  var p: SftpBuf
  p.putU32(fa.nextId())
  for a in args: p.putStr(a)
  await fa.sendPacket(ptype, p.data)
  await fa.expectStatusOk(what)

method chdir(fa: SftpAccess; dir: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  # resolve via REALPATH so cwd stays canonical
  var rp: SftpBuf
  rp.putU32(fa.nextId()); rp.putStr(fa.absPath(dir))
  await fa.sendPacket(FXP_REALPATH, rp.data)
  let (rt, rpay) = await fa.recvPacket()
  if rt != FXP_NAME:
    raiseError("sftp: cd " & dir & ": not found")
  var rr = initReader(rpay); discard rr.getU32(); discard rr.getU32()
  fa.cwd = rr.getStr()

method mkdir(fa: SftpAccess; path: string; parents = false): Future[void]
    {.async: (raises: [CatchableError]).} =
  var p: SftpBuf
  p.putU32(fa.nextId()); p.putStr(fa.absPath(path)); p.putU32(0)   # empty attrs
  await fa.sendPacket(FXP_MKDIR, p.data)
  await fa.expectStatusOk("mkdir")

method remove(fa: SftpAccess; path: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  await fa.simpleReq(FXP_REMOVE, "rm", @[fa.absPath(path)])

method removeDir(fa: SftpAccess; path: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  await fa.simpleReq(FXP_RMDIR, "rmdir", @[fa.absPath(path)])

method rename(fa: SftpAccess; src, dst: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  await fa.simpleReq(FXP_RENAME, "rename", @[fa.absPath(src), fa.absPath(dst)])
