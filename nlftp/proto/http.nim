## HTTP/HTTPS backend — port of lftp's `Http` (src/Http.cc).
##
## Each operation is a request/response over a fresh chronos stream (no
## keep-alive yet; `Connection: close`). Handles status/headers, chunked and
## Content-Length framing, gzip `Content-Encoding` (via core/gzip), redirects,
## and Basic auth. Directory listing parses an HTML autoindex (the common case;
## WebDAV PROPFIND is a later addition).
##
## Identity bodies STREAM via `HttpStreamReader` (constant memory). Only gzip
## bodies are buffered (zippy is one-shot) and they are small in practice
## (listings/text), guarded by a RAM-derived cap. Per-read timeouts (net:timeout)
## keep a stalled server from hanging the stream.

import std/[strutils, base64, options]
import chronos
import ../core/[errors, netstream, settings, gzip, sysmem, config]
import ../fs/[fileaccess, fileinfo, url]

type
  HttpAccess* = ref object of FileAccess
    settings: ResMgr
    useTls: bool
    userAgent: string
    maxBody*: int64       ## cap on a buffered body (RAM-derived); 0 = unlimited

  HttpResponse = object
    status: int
    reason: string
    headers: seq[(string, string)]

  MemReader = ref object of DataReader
    data: seq[byte]
    pos: int



proc newHttpAccess*(host: string; port: int; user, password: string;
                    settings: ResMgr; tls = false): HttpAccess =
  HttpAccess(proto: (if tls: "https" else: "http"), host: host,
             port: (if port != 0: port else: (if tls: 443 else: 80)),
             user: user, password: password, cwd: "/",
             settings: settings, useTls: tls, userAgent: UserAgent,
             maxBody: bufferBudget())   # ~RAM/4 — abort, don't OOM

proc connTimeout(fa: HttpAccess): Duration =
  ## Connect timeout = min(net:timeout, net:connect-timeout). The cap keeps a
  ## fast fail-fast default (30s) while still honoring a lower net:timeout; both
  ## are runtime-configurable (defaults in core/config).
  let netT = try: fa.settings.queryInt("net:timeout") except CatchableError: 0
  let conT = try: fa.settings.queryInt("net:connect-timeout") except CatchableError: 0
  let cap = if conT > 0: conT else: ConnectTimeoutSec
  chronos.seconds(if netT > 0: min(netT, cap) else: cap)

# --- MemReader -------------------------------------------------------------

method readSome(r: MemReader; maxBytes = 65536): Future[seq[byte]]
    {.async: (raises: [CatchableError]).} =
  let n = min(maxBytes, r.data.len - r.pos)
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

method atEnd(r: MemReader): bool {.raises: [], gcsafe.} = r.pos >= r.data.len
method closeReader(r: MemReader): Future[void] {.async: (raises: []).} = discard

# --- header helpers --------------------------------------------------------

proc header(resp: HttpResponse; name: string): string =
  let want = name.toLowerAscii
  for (k, v) in resp.headers:
    if k.toLowerAscii == want: return v
  ""

# Token-aware, case-insensitive header-value match (handles "gzip, chunked").
# Adapted from guzba/mummy `headerContainsToken` (MIT) — see docs/THIRD-PARTY.md.
proc headerHasToken(resp: HttpResponse; name, token: string): bool =
  let wantK = name.toLowerAscii
  for (k, v) in resp.headers:
    if k.toLowerAscii != wantK: continue
    for part in v.split(','):
      if part.strip().toLowerAscii == token.toLowerAscii: return true
  false

proc headerCount(resp: HttpResponse; name: string): int =
  let want = name.toLowerAscii
  for (k, _) in resp.headers:
    if k.toLowerAscii == want: inc result

proc validateFraming(resp: HttpResponse) =
  ## Reject malformed framing that enables response smuggling (mummy's defense,
  ## applied client-side against hostile/buggy servers).
  let hasCL = resp.headerCount("Content-Length") > 0
  let chunked = resp.headerHasToken("Transfer-Encoding", "chunked")
  if resp.headerCount("Content-Length") > 1:
    raiseError("http: duplicate Content-Length", fatal = true)
  if resp.headerCount("Transfer-Encoding") > 1:
    raiseError("http: duplicate Transfer-Encoding", fatal = true)
  if hasCL and chunked:
    raiseError("http: both Content-Length and chunked", fatal = true)
  if hasCL:
    let cl = resp.header("Content-Length").strip()
    var n: int
    if cl.len == 0 or (try: (n = parseInt(cl); n < 0) except ValueError: true):
      raiseError("http: invalid Content-Length: " & cl, fatal = true)

proc joinPath(cwd, path: string): string =
  if path.len == 0: cwd
  elif path.startsWith("/"): path
  elif cwd.endsWith("/"): cwd & path
  else: cwd & "/" & path

# --- low-level request -----------------------------------------------------

proc readN(ns: NetStream; n: int): Future[string] {.async.} =
  ## Read up to `n` bytes, stopping cleanly at EOF (tolerant of servers that
  ## close before delivering a full Content-Length).
  if n <= 0: return ""
  var buf = newSeq[byte](n)
  var got = 0
  while got < n:
    let k = await ns.reader.readOnce(addr buf[got], n - got)
    if k == 0: break
    got += k
  buf.setLen(got)
  return cast[string](buf)

proc tooBig(have, cap: int64): bool {.inline.} = cap > 0 and have > cap

proc bodyCapError(cap: int64) =
  raiseError("http: gzip body exceeds the in-memory buffer cap (" &
    $(cap div (1024*1024)) & " MB); gzip can't stream (zippy is one-shot)",
    fatal = true)

proc readBody(ns: NetStream; resp: HttpResponse; maxBody: int64):
    Future[string] {.async.} =
  if resp.headerHasToken("Transfer-Encoding", "chunked"):
    var body = ""
    while true:
      let szLine = await ns.recvLine()
      let szTok = szLine.split(';')[0].strip()
      let sz = try: parseHexInt(szTok) except ValueError: 0
      if sz == 0:
        discard await ns.recvLine()      # trailing CRLF / trailers
        break
      if tooBig(body.len.int64 + sz, maxBody): bodyCapError(maxBody)
      body.add await readN(ns, sz)
      discard await ns.recvLine()        # CRLF after each chunk
    return body
  let cl = resp.header("content-length")
  if cl.len > 0:
    let n = try: parseInt(cl.strip()) except ValueError: 0
    if tooBig(n.int64, maxBody): bodyCapError(maxBody)
    return await readN(ns, n)
  # else: read until connection close. Tolerate an unclean TLS close (bearssl
  # raises when a server omits close_notify) — the body bytes are already
  # complete by then, so return whatever we accumulated rather than losing it.
  var rest = ""
  var buf = newSeq[byte](65536)
  while true:
    let k =
      try: await ns.reader.readOnce(addr buf[0], buf.len)
      except CatchableError: 0
    if k == 0: break
    rest.add cast[string](buf[0 ..< k])
    if tooBig(rest.len.int64, maxBody): bodyCapError(maxBody)
  return rest

proc sendRequest(fa: HttpAccess; meth, path: string; body = "";
                 extraHeaders: seq[(string, string)] = @[]):
    Future[(HttpResponse, NetStream)] {.async.} =
  ## Send a request and follow redirects, returning the final response with its
  ## connection positioned at the body start. The caller reads/streams the body
  ## and closes the connection.
  var curHost = fa.host
  var curPort = fa.port
  var curTls = fa.useTls
  var curPath = path
  var redirects = 0
  while true:
    let ns = await dial(curHost, curPort, fa.connTimeout())
    if curTls:
      await ns.startTls(curHost, verify = fa.settings.queryBool(
        "ssl:verify-certificate", curHost))
    var req = meth & " " & curPath & " HTTP/1.1\r\n"
    let hostHdr = (if isIPv6Literal(curHost): "[" & curHost & "]" else: curHost)
    req.add "Host: " & hostHdr & "\r\n"
    req.add "User-Agent: " & fa.userAgent & "\r\n"
    req.add "Accept: */*\r\n"
    # gzip is safe now: the close-delimited reader tolerates bearssl's unclean
    # TLS close, so a gzipped close-delimited body still decodes (core/gzip).
    req.add "Accept-Encoding: gzip\r\n"
    if fa.user.len > 0:
      req.add "Authorization: Basic " &
        encode(fa.user & ":" & fa.password) & "\r\n"
    for (k, v) in extraHeaders:
      req.add k & ": " & v & "\r\n"
    if body.len > 0:
      req.add "Content-Length: " & $body.len & "\r\n"
    req.add "Connection: close\r\n\r\n"
    # the write/first-read triggers the TLS handshake on https
    let statusLine =
      try:
        await ns.writer.write(req)
        if body.len > 0: await ns.writer.write(body)
        await ns.recvLine()
      except CatchableError as e:
        let hint = tlsErrorHint(e.msg)
        await ns.close()
        if curTls and hint.len > 0:
          raiseError("https: TLS handshake failed — " & hint, fatal = true)
        raise
    if statusLine.len < 12:
      await ns.close()
      raiseError("http: bad status line: " & statusLine, fatal = true)
    let sp = statusLine.find(' ')
    var resp: HttpResponse
    resp.status = try: parseInt(statusLine[sp+1 ..< sp+4]) except ValueError:
      await ns.close(); raiseError("http: bad status: " & statusLine, fatal = true)
    resp.reason = statusLine[sp+5 .. ^1]
    # headers
    while true:
      let h = await ns.recvLine()
      if h.len == 0: break
      let c = h.find(':')
      if c > 0: resp.headers.add (h[0 ..< c].strip(), h[c+1 .. ^1].strip())

    # reject smuggling-prone / malformed framing before reading a body
    if meth != "HEAD":
      try:
        validateFraming(resp)
      except CatchableError:
        await ns.close(); raise

    # redirects
    if resp.status in [301, 302, 303, 307, 308]:
      let loc = resp.header("location")
      await ns.close()
      if loc.len == 0 or redirects >= MaxRedirects:
        raiseError("http: redirect without usable Location")
      inc redirects
      if loc.startsWith("http://") or loc.startsWith("https://"):
        let u = loc
        curTls = u.startsWith("https://")
        var rest = u[(if curTls: 8 else: 7) .. ^1]
        let slash = rest.find('/')
        var hostPort = (if slash >= 0: rest[0 ..< slash] else: rest)
        curPath = (if slash >= 0: rest[slash .. ^1] else: "/")
        let pc = hostPort.find(':')
        if pc >= 0:
          curHost = hostPort[0 ..< pc]
          curPort = try: parseInt(hostPort[pc+1 .. ^1]) except ValueError:
            (if curTls: 443 else: 80)
        else:
          curHost = hostPort
          curPort = (if curTls: 443 else: 80)
      else:
        curPath = loc       # relative redirect, same host
      continue

    return (resp, ns)

proc doRequest(fa: HttpAccess; meth, path: string; body = "";
               extraHeaders: seq[(string, string)] = @[]):
    Future[(HttpResponse, string)] {.async.} =
  ## Buffered request: read the whole (gzip-decoded) body and close. Used for
  ## HEAD (connect) and directory listings — responses that are small by nature.
  let (resp, ns) = await fa.sendRequest(meth, path, body, extraHeaders)
  var raw = ""
  if meth != "HEAD" and resp.status notin [204, 304]:
    raw =
      try: await readBody(ns, resp, fa.maxBody).wait(BodyReadTimeoutSec.seconds)
      except AsyncTimeoutError:
        await ns.close()
        raiseError("http: timed out reading response body", fatal = true)
    let enc = resp.header("content-encoding")
    if enc.len > 0:
      raw = decodeContentEncoding(raw, enc)
  await ns.close()
  return (resp, raw)

# --- streaming body reader (constant memory; the fix for large downloads) ---

type
  HttpStreamReader = ref object of DataReader
    ns: NetStream
    chunked: bool
    remaining: int64        ## content-length bytes left; -1 = close-delimited
    chunkLeft: int          ## bytes left in the current chunk (chunked mode)
    pendingCrlf: bool       ## a chunk's trailing CRLF not yet consumed
    timeout: Duration       ## per-read timeout (a stalled server can't hang us)
    done: bool

proc newHttpStreamReader(ns: NetStream; resp: HttpResponse;
                         timeout: Duration): HttpStreamReader =
  result = HttpStreamReader(ns: ns, remaining: -1, timeout: timeout)
  if resp.headerHasToken("Transfer-Encoding", "chunked"):
    result.chunked = true
  else:
    let cl = resp.header("content-length")
    if cl.len > 0:
      result.remaining = try: parseInt(cl.strip()).int64 except ValueError: 0

method atEnd(r: HttpStreamReader): bool {.raises: [], gcsafe.} =
  r.done or r.remaining == 0

method closeReader(r: HttpStreamReader): Future[void] {.async: (raises: []).} =
  try: await r.ns.close()
  except CatchableError: discard

proc readSomeImpl(r: HttpStreamReader; maxBytes: int): Future[seq[byte]]
    {.async.} =
  if r.chunked:
    if r.chunkLeft == 0:
      if r.pendingCrlf:
        discard await r.ns.recvLine()        # CRLF after the previous chunk
        r.pendingCrlf = false
      let szLine = await r.ns.recvLine()
      let sz = try: parseHexInt(szLine.split(';')[0].strip())
               except ValueError: 0
      if sz == 0:
        discard await r.ns.recvLine()         # trailing CRLF / trailers
        r.done = true
        return @[]
      r.chunkLeft = sz
    let take = min(maxBytes, r.chunkLeft)
    let data = await readN(r.ns, take)
    r.chunkLeft -= data.len
    if r.chunkLeft == 0: r.pendingCrlf = true
    return cast[seq[byte]](data)
  elif r.remaining > 0:
    var buf = newSeq[byte](min(maxBytes.int64, r.remaining).int)
    let k = await r.ns.reader.readOnce(addr buf[0], buf.len)
    buf.setLen(k)
    r.remaining -= k
    if k == 0: r.done = true
    return buf
  else:   # close-delimited: read until EOF (tolerate unclean TLS close)
    var buf = newSeq[byte](maxBytes)
    let k =
      try: await r.ns.reader.readOnce(addr buf[0], maxBytes)
      except CatchableError: 0
    if k == 0: r.done = true
    buf.setLen(k)
    return buf

method readSome(r: HttpStreamReader; maxBytes = 65536): Future[seq[byte]]
    {.async: (raises: [CatchableError]).} =
  if r.atEnd: return @[]
  try:
    return await readSomeImpl(r, maxBytes).wait(r.timeout)
  except AsyncTimeoutError:
    r.done = true
    try: await r.ns.close()
    except CatchableError: discard
    raiseError("http: stream read timed out after " & $r.timeout, fatal = true)

# --- FileAccess methods ----------------------------------------------------

method setConcurrency(fa: HttpAccess; n: int) {.gcsafe, raises: [].} =
  ## Shrink the gzip-buffer cap so N concurrent http transfers don't, together,
  ## exceed the RAM budget. (Only gzip bodies buffer now — downloads stream.)
  fa.maxBody = bufferBudget() div max(1, n)

method connect(fa: HttpAccess): Future[void] {.async: (raises: [CatchableError]).} =
  # HTTP is connectionless per-request; a HEAD on the base path validates reach.
  let (resp, _) = await fa.doRequest("HEAD", fa.cwd)
  if resp.status >= 400 and resp.status != 405:   # 405 = HEAD not allowed, ok
    raiseError("http: " & $resp.status & " " & resp.reason, fatal = true)
  fa.connected = true

method openRead(fa: HttpAccess; path: string; offset: int64 = 0): Future[DataReader]
    {.async: (raises: [CatchableError]).} =
  var extra: seq[(string, string)]
  if offset > 0: extra.add ("Range", "bytes=" & $offset & "-")
  let (resp, ns) = await fa.sendRequest("GET", joinPath(fa.cwd, path), "", extra)
  if resp.status >= 400:
    await ns.close()
    raiseError("http: GET " & path & ": " & $resp.status & " " & resp.reason)
  let enc = resp.header("content-encoding")
  if enc.len > 0:
    # gzip can't stream (zippy is one-shot): buffer whole, decode, cap applies.
    # These bodies are small in practice (listings/text).
    let raw =
      try: await readBody(ns, resp, fa.maxBody).wait(BodyReadTimeoutSec.seconds)
      except AsyncTimeoutError:
        await ns.close(); raiseError("http: timed out reading body", fatal = true)
    await ns.close()
    return MemReader(data: cast[seq[byte]](decodeContentEncoding(raw, enc)))
  # identity: STREAM the body — constant memory regardless of size.
  let toSec = try: fa.settings.queryInt("net:timeout") except CatchableError: DefaultTimeoutSec
  return newHttpStreamReader(ns, resp, seconds(max(1, toSec)))

method size(fa: HttpAccess; path: string): Future[int64]
    {.async: (raises: [CatchableError]).} =
  let (resp, _) = await fa.doRequest("HEAD", joinPath(fa.cwd, path))
  if resp.status >= 400: return -1
  let cl = resp.header("content-length")
  return if cl.len > 0: (try: parseInt(cl.strip()).int64 except ValueError: -1)
         else: -1

method openReadRange(fa: HttpAccess; path: string; offset, length: int64):
    Future[DataReader] {.async: (raises: [CatchableError]).} =
  let last = offset + length - 1
  let extra = @[("Range", "bytes=" & $offset & "-" & $last)]
  let (resp, ns) = await fa.sendRequest("GET", joinPath(fa.cwd, path), "", extra)
  if resp.status >= 400:
    await ns.close()
    raiseError("http: range GET " & path & ": " & $resp.status)
  let toSec = try: fa.settings.queryInt("net:timeout") except CatchableError: DefaultTimeoutSec
  # 206 carries Content-Length = segment length; stream it (bound to be safe)
  return newLengthLimitReader(newHttpStreamReader(ns, resp, seconds(max(1, toSec))),
                              length)

# --- upload (WebDAV/HTTP PUT, streaming via chunked request encoding) -------

type
  HttpWriter = ref object of DataWriter
    ns: NetStream
    timeout: Duration

proc chunkHeader(n: int): string =
  ## hex length (no leading zeros; never strip trailing) + CRLF
  n.toHex.strip(leading = true, trailing = false, chars = {'0'}) & "\r\n"

method writeSome(w: HttpWriter; data: seq[byte]): Future[void]
    {.async: (raises: [CatchableError]).} =
  if data.len == 0: return
  try:
    await w.ns.writer.write(chunkHeader(data.len)).wait(w.timeout)
    await w.ns.writer.write(data).wait(w.timeout)
    await w.ns.writer.write("\r\n").wait(w.timeout)
  except AsyncTimeoutError:
    await w.ns.close(); raiseError("http: PUT write timed out", fatal = true)

method finishWriter(w: HttpWriter): Future[void]
    {.async: (raises: [CatchableError]).} =
  await w.ns.writer.write("0\r\n\r\n")          # terminating chunk
  let statusLine = await w.ns.recvLine()
  while true:                                    # drain response headers
    let h = await w.ns.recvLine()
    if h.len == 0: break
  await w.ns.close()
  let sp = statusLine.find(' ')
  let status = try: parseInt(statusLine[sp+1 ..< sp+4]) except ValueError: 0
  if status >= 400 or status == 0:
    raiseError("http: PUT failed: " & statusLine, fatal = true)

method abortWriter(w: HttpWriter): Future[void] {.async: (raises: []).} =
  try: await w.ns.close()
  except CatchableError: discard

method openWrite(fa: HttpAccess; path: string; offset: int64 = 0;
                 size: int64 = -1): Future[DataWriter]
    {.async: (raises: [CatchableError]).} =
  if offset > 0:
    raiseError("http: resume/append not supported for PUT")
  let ns = await dial(fa.host, fa.port, fa.connTimeout())
  if fa.useTls:
    await ns.startTls(fa.host, verify = fa.settings.queryBool(
      "ssl:verify-certificate", fa.host))
  let hostHdr = (if isIPv6Literal(fa.host): "[" & fa.host & "]" else: fa.host)
  var req = "PUT " & joinPath(fa.cwd, path) & " HTTP/1.1\r\n"
  req.add "Host: " & hostHdr & "\r\n"
  req.add "User-Agent: " & fa.userAgent & "\r\n"
  if fa.user.len > 0:
    req.add "Authorization: Basic " & encode(fa.user & ":" & fa.password) & "\r\n"
  req.add "Transfer-Encoding: chunked\r\n"        # stream: no size needed
  req.add "Connection: close\r\n\r\n"
  await ns.writer.write(req)
  let toSec = try: fa.settings.queryInt("net:timeout") except CatchableError: DefaultTimeoutSec
  return HttpWriter(ns: ns, timeout: seconds(max(1, toSec)))

method chdir(fa: HttpAccess; dir: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  fa.cwd = joinPath(fa.cwd, (if dir.endsWith("/"): dir else: dir & "/"))

# --- WebDAV directory ops (MKCOL / DELETE) ---------------------------------

proc davRequest(fa: HttpAccess; meth, target: string): Future[int] {.async.} =
  ## A bodiless WebDAV request; returns the HTTP status code.
  let ns = await dial(fa.host, fa.port, fa.connTimeout())
  if fa.useTls:
    await ns.startTls(fa.host, verify = fa.settings.queryBool(
      "ssl:verify-certificate", fa.host))
  let hostHdr = (if isIPv6Literal(fa.host): "[" & fa.host & "]" else: fa.host)
  var req = meth & " " & target & " HTTP/1.1\r\n"
  req.add "Host: " & hostHdr & "\r\n"
  req.add "User-Agent: " & fa.userAgent & "\r\n"
  if fa.user.len > 0:
    req.add "Authorization: Basic " & encode(fa.user & ":" & fa.password) & "\r\n"
  req.add "Content-Length: 0\r\nConnection: close\r\n\r\n"
  await ns.writer.write(req)
  let statusLine = await ns.recvLine()
  while true:
    let h = await ns.recvLine()
    if h.len == 0: break
  await ns.close()
  let sp = statusLine.find(' ')
  return try: parseInt(statusLine[sp+1 ..< sp+4]) except ValueError: 0

method mkdir(fa: HttpAccess; path: string; parents = false): Future[void]
    {.async: (raises: [CatchableError]).} =
  var p = joinPath(fa.cwd, path)
  if not p.endsWith("/"): p.add "/"
  let st = await fa.davRequest("MKCOL", p)
  # 201 created; tolerate 405/301 (collection already exists)
  if st >= 400 and st notin [405, 301]:
    raiseError("http: MKCOL " & path & ": " & $st)

method remove(fa: HttpAccess; path: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  let st = await fa.davRequest("DELETE", joinPath(fa.cwd, path))
  if st >= 400 and st != 404:        # tolerate already-gone
    raiseError("http: DELETE " & path & ": " & $st)

method removeDir(fa: HttpAccess; path: string): Future[void]
    {.async: (raises: [CatchableError]).} =
  var p = joinPath(fa.cwd, path)
  if not p.endsWith("/"): p.add "/"
  let st = await fa.davRequest("DELETE", p)
  if st >= 400 and st != 404:
    raiseError("http: DELETE " & path & ": " & $st)

# --- HTML autoindex listing ------------------------------------------------

proc parseHtmlIndex(html: string): seq[fileinfo.FileInfo] =
  ## Extract entries from an Apache/nginx-style autoindex (the <a href> links).
  var i = 0
  let lower = html.toLowerAscii
  while true:
    let a = lower.find("href=\"", i)
    if a < 0: break
    let start = a + 6
    let endq = html.find('"', start)
    if endq < 0: break
    i = endq + 1
    var href = html[start ..< endq]
    # skip sort links, parent, absolute/external, queries
    if href.len == 0 or href[0] in {'?', '/'} or "://" in href or
       href == "../" or href.startsWith(".."):
      continue
    let isDir = href.endsWith("/")
    let name = if isDir: href[0 ..< href.len-1] else: href
    if name.len == 0 or name in [".", ".."]: continue
    var fi = if isDir: newDir(name) else: newFile(name)
    result.add fi

method listInfo(fa: HttpAccess; path = ""): Future[seq[fileinfo.FileInfo]]
    {.async: (raises: [CatchableError]).} =
  let p = joinPath(fa.cwd, (if path.len == 0 or path.endsWith("/"): path
                            else: path & "/"))
  let (resp, body) = await fa.doRequest("GET", (if p.len == 0: "/" else: p))
  if resp.status >= 400:
    raiseError("http: list " & path & ": " & $resp.status & " " & resp.reason)
  return parseHtmlIndex(body)

method close(fa: HttpAccess): Future[void] {.async: (raises: []).} = discard
