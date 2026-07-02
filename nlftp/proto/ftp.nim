## FTP/FTPS backend — port of lftp's `Ftp` (src/ftpclass.cc).
##
## lftp's 13-state `Do()` machine collapses into linear async procs over two
## chronos streams (control + data), per DECISIONS §2. This implements the core
## of the protocol: login, FEAT, TYPE, PASV/EPSV, LIST/MLSD, RETR/STOR, and the
## directory ops — enough for `open ftp://… ; ls ; get ; put ; mirror`.
##
## FTPS (AUTH TLS) upgrades the control stream via netstream.startTls and, when
## `ftp:ssl-protect-data`, the data stream too.

import std/[strutils, options]
import chronos
import chronos/streams/asyncstream
import ../core/[errors, netstream, settings, config]
import ../fs/[fileaccess, fileinfo]

type
  FtpAccess* = ref object of FileAccess
    ctrl: NetStream
    settings: ResMgr
    loggedIn: bool
    binary: bool
    useEpsv: bool
    useTls: bool

  FtpReply = object
    code: int
    text: string

  FtpReader = ref object of DataReader
    data: NetStream
    fa: FtpAccess
    done: bool

  FtpWriter = ref object of DataWriter
    data: NetStream
    fa: FtpAccess

proc newFtpAccess*(host: string; port: int; user, password: string;
                   settings: ResMgr; tls = false): FtpAccess =
  FtpAccess(proto: (if tls: "ftps" else: "ftp"), host: host,
            port: (if port != 0: port else: 21),
            user: (if user.len > 0: user else: "anonymous"),
            password: (if password.len > 0: password else: "anonymous@"),
            cwd: "/", settings: settings, useTls: tls)

proc connTimeout(fa: FtpAccess): Duration =
  ## Connect timeout = min(net:timeout, net:connect-timeout). The cap keeps a
  ## fast fail-fast default (30s) while still honoring a lower net:timeout; both
  ## are runtime-configurable (defaults in core/config).
  let netT = try: fa.settings.queryInt("net:timeout") except CatchableError: 0
  let conT = try: fa.settings.queryInt("net:connect-timeout") except CatchableError: 0
  let cap = if conT > 0: conT else: ConnectTimeoutSec
  chronos.seconds(if netT > 0: min(netT, cap) else: cap)

# --- control protocol ------------------------------------------------------

proc readReply(fa: FtpAccess): Future[FtpReply] {.async.} =
  ## Read one (possibly multi-line) FTP reply. Multi-line replies open with
  ## "NNN-" and close with "NNN " (same code, space).
  let first = await fa.ctrl.recvLine()
  if first.len < 4:
    raiseError("ftp: short reply: " & first, fatal = true)
  let code = try: parseInt(first[0 ..< 3]) except ValueError:
    raiseError("ftp: bad reply code: " & first, fatal = true)
  var text = first[4 .. ^1]
  if first.len >= 4 and first[3] == '-':
    # multi-line: read until a line begins with "NNN "
    let tag = first[0 ..< 3] & " "
    while true:
      let line = await fa.ctrl.recvLine()
      text.add "\n" & line
      if line.startsWith(tag): break
  return FtpReply(code: code, text: text)

proc cmd(fa: FtpAccess; line: string): Future[FtpReply] {.async.} =
  ## Send a command and read its reply.
  await fa.ctrl.sendLine(line)
  return await fa.readReply()

proc expect(r: FtpReply; want: int; what = "") =
  if r.code div 100 != want div 100 and r.code != want:
    raiseError("ftp: " & (if what.len > 0: what & ": " else: "") &
               $r.code & " " & r.text.strip())

proc expectOk(r: FtpReply; what = "") =
  ## Accept any 2xx (and 1xx as in-progress for transfer starts handled apart).
  if r.code >= 400:
    raiseError("ftp: " & (if what.len > 0: what & ": " else: "") &
               $r.code & " " & r.text.strip())

# --- connect / login -------------------------------------------------------

method connect(fa: FtpAccess): Future[void] {.async: (raises: [CatchableError]).} =
  fa.ctrl = await dial(fa.host, fa.port, fa.connTimeout())
  expectOk(await fa.readReply(), "greeting")

  if fa.useTls:
    let r = await fa.cmd("AUTH TLS")
    expectOk(r, "AUTH TLS")
    await fa.ctrl.startTls(fa.host, verify = fa.settings.queryBool(
      "ssl:verify-certificate", fa.host))
    try:
      discard await fa.cmd("PBSZ 0")        # first I/O on TLS -> handshake here
    except CatchableError as e:
      let hint = tlsErrorHint(e.msg)
      if hint.len > 0:
        raiseError("ftps: TLS handshake failed — " & hint, fatal = true)
      raiseError("ftps: TLS handshake failed: " & e.msg, fatal = true)
    if fa.settings.queryBool("ftp:ssl-protect-data", fa.host):
      discard await fa.cmd("PROT P")
    else:
      discard await fa.cmd("PROT C")

  expectOk(await fa.cmd("USER " & fa.user), "USER")
  let pr = await fa.cmd("PASS " & fa.password)
  if pr.code >= 400:
    raiseError("ftp: login failed: " & $pr.code & " " & pr.text.strip(),
               fatal = true)
  fa.loggedIn = true
  discard await fa.cmd("TYPE I")   # binary by default
  fa.binary = true
  # best-effort PWD to learn the start directory
  let pwd = await fa.cmd("PWD")
  if pwd.code == 257:
    let q1 = pwd.text.find('"')
    let q2 = pwd.text.rfind('"')
    if q1 >= 0 and q2 > q1: fa.cwd = pwd.text[q1+1 ..< q2]
  fa.connected = true

method clone(fa: FtpAccess): Future[FileAccess]
    {.async: (raises: [CatchableError]).} =
  ## A fresh, independent FTP connection at the same cwd (for parallel transfers).
  let c = newFtpAccess(fa.host, fa.port, fa.user, fa.password, fa.settings,
                       fa.useTls)
  await c.connect()
  if fa.cwd.len > 0 and fa.cwd != "/":
    await c.chdir(fa.cwd)
  return c

method close(fa: FtpAccess): Future[void] {.async: (raises: []).} =
  if not fa.ctrl.isNil:
    try:
      await fa.ctrl.sendLine("QUIT")
      await fa.ctrl.close()
    except CatchableError: discard

# --- data connection (passive) ---------------------------------------------

proc openData(fa: FtpAccess): Future[NetStream] {.async.} =
  ## Open a passive-mode data connection (EPSV then PASV fallback).
  # Try EPSV first (works for IPv4/IPv6, proxy/NAT-friendly).
  block epsv:
    let r = await fa.cmd("EPSV")
    if r.code == 229:
      # "229 ... (|||port|)"
      let lp = r.text.find('(')
      let rp = r.text.find(')')
      if lp >= 0 and rp > lp:
        let inside = r.text[lp+1 ..< rp]
        let parts = inside.split(inside[0])   # delimiter is the 1st char
        if parts.len >= 4:
          let port = try: parseInt(parts[3]) except ValueError: 0
          if port > 0:
            return await dial(fa.host, port, fa.connTimeout())
    # else fall through to PASV
  let r = await fa.cmd("PASV")
  if r.code != 227:
    raiseError("ftp: PASV failed: " & $r.code & " " & r.text.strip())
  let lp = r.text.find('(')
  let rp = r.text.find(')')
  if lp < 0 or rp < lp:
    raiseError("ftp: malformed PASV reply: " & r.text)
  let nums = r.text[lp+1 ..< rp].split(',')
  if nums.len != 6:
    raiseError("ftp: malformed PASV tuple: " & r.text)
  # NOTE (#466/#784 fix): use the *control* host, not the address the server
  # advertises, which is wrong behind NAT/proxy.
  let port = (parseInt(nums[4].strip()) shl 8) or parseInt(nums[5].strip())
  return await dial(fa.host, port, fa.connTimeout())

proc maybeProtectData(fa: FtpAccess; ns: NetStream) {.async.} =
  if fa.useTls and fa.settings.queryBool("ftp:ssl-protect-data", fa.host):
    await ns.startTls(fa.host, verify = fa.settings.queryBool(
      "ssl:verify-certificate", fa.host))

# --- listing ---------------------------------------------------------------

method listInfo(fa: FtpAccess; path = ""): Future[seq[fileinfo.FileInfo]]
    {.async: (raises: [CatchableError]).} =
  let data = await fa.openData()
  await fa.maybeProtectData(data)
  let target = if path.len > 0: " " & path else: ""
  let r = await fa.cmd("LIST" & target)
  if r.code >= 400:
    await data.close()
    raiseError("ftp: LIST failed: " & $r.code & " " & r.text.strip())
  var raw = ""
  while true:
    let chunk = await data.reader.read(65536)
    if chunk.len == 0: break
    raw.add cast[string](chunk)
  await data.close()
  expectOk(await fa.readReply(), "LIST end")   # 226
  var res: seq[fileinfo.FileInfo]
  for line in raw.splitLines():
    let fi = parseLsLine(line)
    if fi.isSome: res.add fi.get
  return res

# --- retrieve / store ------------------------------------------------------

method readSome(r: FtpReader; maxBytes = 65536): Future[seq[byte]]
    {.async: (raises: [CatchableError]).} =
  var buf = newSeq[byte](maxBytes)
  let n = await r.data.reader.readOnce(addr buf[0], maxBytes)
  buf.setLen(n)
  if n == 0: r.done = true
  return buf

method atEnd(r: FtpReader): bool {.raises: [], gcsafe.} = r.done

method closeReader(r: FtpReader): Future[void] {.async: (raises: []).} =
  try:
    await r.data.close()
    expectOk(await r.fa.readReply(), "RETR end")  # 226
  except CatchableError: discard

method size(fa: FtpAccess; path: string): Future[int64]
    {.async: (raises: [CatchableError]).} =
  let r = await fa.cmd("SIZE " & path)
  if r.code == 213:
    return try: parseBiggestInt(r.text.strip()).int64 except ValueError: -1
  return -1

method openRead(fa: FtpAccess; path: string; offset: int64 = 0): Future[DataReader]
    {.async: (raises: [CatchableError]).} =
  let data = await fa.openData()
  await fa.maybeProtectData(data)
  if offset > 0:
    expectOk(await fa.cmd("REST " & $offset), "REST")
  let r = await fa.cmd("RETR " & path)
  if r.code >= 400:
    await data.close()
    raiseError("ftp: RETR " & path & ": " & $r.code & " " & r.text.strip())
  return FtpReader(data: data, fa: fa)

method writeSome(w: FtpWriter; data: seq[byte]): Future[void]
    {.async: (raises: [CatchableError]).} =
  if data.len > 0:
    await w.data.writer.write(data)

method finishWriter(w: FtpWriter): Future[void]
    {.async: (raises: [CatchableError]).} =
  await w.data.close()
  expectOk(await w.fa.readReply(), "STOR end")    # 226

method abortWriter(w: FtpWriter): Future[void] {.async: (raises: []).} =
  try: await w.data.close()
  except CatchableError: discard

method openWrite(fa: FtpAccess; path: string; offset: int64 = 0;
                 size: int64 = -1): Future[DataWriter]
    {.async: (raises: [CatchableError]).} =
  let data = await fa.openData()
  await fa.maybeProtectData(data)
  if offset > 0:
    expectOk(await fa.cmd("REST " & $offset), "REST")
  let verb = if offset > 0: "APPE " else: "STOR "
  let r = await fa.cmd(verb & path)
  if r.code >= 400:
    await data.close()
    raiseError("ftp: STOR " & path & ": " & $r.code & " " & r.text.strip())
  return FtpWriter(data: data, fa: fa)

# --- directory ops ---------------------------------------------------------

method chdir(fa: FtpAccess; dir: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  let r = await fa.cmd("CWD " & dir)
  if r.code >= 400:
    raiseError("ftp: cd " & dir & ": " & $r.code & " " & r.text.strip())
  let pwd = await fa.cmd("PWD")
  if pwd.code == 257:
    let q1 = pwd.text.find('"'); let q2 = pwd.text.rfind('"')
    if q1 >= 0 and q2 > q1: fa.cwd = pwd.text[q1+1 ..< q2]

method mkdir(fa: FtpAccess; path: string; parents = false): Future[void]
    {.async: (raises: [CatchableError]).} =
  expectOk(await fa.cmd("MKD " & path), "mkdir")

method remove(fa: FtpAccess; path: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  expectOk(await fa.cmd("DELE " & path), "rm")

method removeDir(fa: FtpAccess; path: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  expectOk(await fa.cmd("RMD " & path), "rmdir")

method rename(fa: FtpAccess; src, dst: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  expect(await fa.cmd("RNFR " & src), 300, "rename")
  expectOk(await fa.cmd("RNTO " & dst), "rename")

method chmodPath(fa: FtpAccess; path: string; mode: int): Future[void]
    {.async: (raises: [CatchableError]).} =
  expectOk(await fa.cmd("SITE CHMOD " & mode.toOct(3) & " " & path), "chmod")
