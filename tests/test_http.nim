## Phase 3 HTTP tests against an in-process mock server: content-length and
## chunked bodies, redirect following, and HTML-autoindex listing.

import std/strutils
import unittest2
import chronos

proc chunkHex(n: int): string =
  ## hex chunk-length with leading zeros stripped (never the trailing ones)
  toHex(n, 8).strip(leading = true, trailing = false, chars = {'0'})
import ../nlftp/core/[settings, defaults]
import ../nlftp/core/gzip as gz
import ../nlftp/fs/fileaccess
import ../nlftp/proto/http

const Body = "hello http world"
const PutBody = "uploaded content via chunked PUT \x00\x01\x02 binary"

proc readChunked(r: AsyncStreamReader): Future[string] {.async.} =
  var body = ""
  while true:
    let szLine = await r.readLine(64, sep = "\r\n")
    let sz = try: parseHexInt(szLine.split(';')[0].strip()) except ValueError: 0
    if sz == 0:
      discard await r.readLine(64, sep = "\r\n")   # trailing CRLF
      break
    var buf = newSeq[byte](sz)
    await r.readExactly(addr buf[0], sz)
    body.add cast[string](buf)
    discard await r.readLine(64, sep = "\r\n")      # CRLF after chunk
  return body
const IndexHtml = """<html><body>
<a href="?C=N">Name</a>
<a href="../">Parent</a>
<a href="file1.txt">file1.txt</a>
<a href="sub/">sub/</a>
<a href="http://other/x">ext</a>
</body></html>"""

proc handle(server: StreamServer; t: StreamTransport) {.async: (raises: []).} =
  try:
    let r = newAsyncStreamReader(t)
    let w = newAsyncStreamWriter(t)
    let reqLine = await r.readLine(4096, sep = "\r\n")
    while true:                                   # drain headers
      let h = await r.readLine(4096, sep = "\r\n")
      if h.len == 0: break
    let path = reqLine.split(' ')[1]
    let meth = reqLine.split(' ')[0]
    proc send(s: string) {.async.} = await w.write(s)
    if meth == "PUT":   # validate the streamed chunked body matches exactly
      let got = await readChunked(r)
      let code = if got == PutBody: "201 Created" else: "400 Bad Request"
      await send("HTTP/1.1 " & code & "\r\nContent-Length: 0\r\n" &
                 "Connection: close\r\n\r\n")
      await w.closeWait(); await r.closeWait(); await t.closeWait()
      return
    if meth in ["MKCOL", "DELETE"]:   # WebDAV dir ops
      let code = if meth == "MKCOL": "201 Created" else: "204 No Content"
      await send("HTTP/1.1 " & code & "\r\nContent-Length: 0\r\n" &
                 "Connection: close\r\n\r\n")
      await w.closeWait(); await r.closeWait(); await t.closeWait()
      return
    case path
    of "/file":
      if meth == "HEAD":
        await send("HTTP/1.1 200 OK\r\nContent-Length: " & $Body.len &
                   "\r\nConnection: close\r\n\r\n")
      else:
        await send("HTTP/1.1 200 OK\r\nContent-Length: " & $Body.len &
                   "\r\nConnection: close\r\n\r\n" & Body)
    of "/chunked":
      var resp = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n" &
                 "Connection: close\r\n\r\n"
      # two chunks: "hello " + "http world"
      resp.add chunkHex(6) & "\r\nhello \r\n"
      resp.add chunkHex(10) & "\r\nhttp world\r\n"
      resp.add "0\r\n\r\n"
      await send(resp)
    of "/redir":
      await send("HTTP/1.1 302 Found\r\nLocation: /file\r\n" &
                 "Connection: close\r\n\r\n")
    of "/smuggle":   # both Content-Length and chunked -> client must reject
      await send("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n" &
                 "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" &
                 "0\r\n\r\n")
    of "/dupcl":     # duplicate Content-Length -> reject
      await send("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n" &
                 "Content-Length: 4\r\nConnection: close\r\n\r\nabc")
    of "/stall":     # send partial body then stall -> client must time out
      await send("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n" &
                 "Connection: close\r\n\r\npartial")
      await sleepAsync(3.seconds)
    of "/gzipbody":  # gzip-encoded (buffered path; cap applies)
      let gzBody = gz.compress(Body, cfGzip)
      await send("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n" &
                 "Content-Length: " & $gzBody.len &
                 "\r\nConnection: close\r\n\r\n" & gzBody)
    of "/tetoken":   # "gzip, chunked" must still be detected as chunked
      await send("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n" &
                 "Connection: close\r\n\r\n" &
                 chunkHex(Body.len) & "\r\n" & Body &
                 "\r\n0\r\n\r\n")
    of "/", "/dir/":
      await send("HTTP/1.1 200 OK\r\nContent-Length: " & $IndexHtml.len &
                 "\r\nConnection: close\r\n\r\n" & IndexHtml)
    else:
      await send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" &
                 "Connection: close\r\n\r\n")
    await w.closeWait()
    await r.closeWait()
    await t.closeWait()
  except CatchableError:
    discard

template withServer(body: untyped) =
  let server {.inject.} = createStreamServer(initTAddress("127.0.0.1:0"),
                                             handle, {ReuseAddr})
  let port {.inject.} = int(server.localAddress().port)
  server.start()
  let rm {.inject.} = newResMgr(); rm.registerDefaults()
  body
  server.stop()

proc fetch(fa: HttpAccess; path: string): Future[string] {.async.} =
  let rd = await fa.openRead(path)
  var got: seq[byte]
  while not rd.atEnd:
    let c = await rd.readSome()
    if c.len == 0: break
    got.add c
  await rd.closeReader()
  return cast[string](got)

suite "http client (mock server)":
  test "content-length GET":
    proc run(): Future[string] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        result = await fetch(fa, "/file")
    check waitFor(run()) == Body

  test "chunked GET":
    proc run(): Future[string] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        result = await fetch(fa, "/chunked")
    check waitFor(run()) == Body

  test "redirect is followed":
    proc run(): Future[string] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        result = await fetch(fa, "/redir")
    check waitFor(run()) == Body

  test "rejects Content-Length + chunked (smuggling defense)":
    proc run(): Future[bool] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        try:
          discard await fetch(fa, "/smuggle")
          result = false
        except CatchableError:
          result = true
    check waitFor(run())

  test "rejects duplicate Content-Length":
    proc run(): Future[bool] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        try:
          discard await fetch(fa, "/dupcl"); result = false
        except CatchableError: result = true
    check waitFor(run())

  test "token-aware: 'gzip, chunked' detected as chunked":
    proc run(): Future[string] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        result = await fetch(fa, "/tetoken")
    check waitFor(run()) == Body

  test "identity body streams (constant memory, no cap)":
    proc run(): Future[string] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        fa.maxBody = 5            # identity now streams -> cap irrelevant
        result = await fetch(fa, "/file")
    check waitFor(run()) == Body

  test "gzip body over the cap is rejected (no OOM)":
    proc run(): Future[bool] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        fa.maxBody = 5            # gzipped body is buffered; >5 -> reject
        try:
          discard await fetch(fa, "/gzipbody"); result = false
        except CatchableError: result = true
    check waitFor(run())

  test "cap is RAM-derived and sane (64MB..4GB)":
    let fa = newHttpAccess("h", 80, "", "", newResMgr())
    check fa.maxBody >= 64'i64 * 1024 * 1024
    check fa.maxBody <= 4'i64 * 1024 * 1024 * 1024

  test "setConcurrency divides the buffer cap":
    let fa = newHttpAccess("h", 80, "", "", newResMgr())
    let full = fa.maxBody
    fa.setConcurrency(4)
    check fa.maxBody == full div 4

  test "stalled stream times out (net:timeout)":
    proc run(): Future[bool] {.async.} =
      withServer:
        rm.set("net:timeout", "1")         # 1s per-read timeout
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        try:
          discard await fetch(fa, "/stall"); result = false
        except CatchableError:
          result = true
    check waitFor(run())

  test "chunked PUT upload streams the body exactly":
    proc run(): Future[bool] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        let wr = await fa.openWrite("/dav/file.bin")
        # write in two batches to exercise multi-chunk streaming
        await wr.writeSome(cast[seq[byte]](PutBody[0 ..< 10]))
        await wr.writeSome(cast[seq[byte]](PutBody[10 .. ^1]))
        await wr.finishWriter()        # raises if server got wrong bytes (400)
        result = true
    check waitFor(run())

  test "WebDAV MKCOL / DELETE succeed":
    proc run(): Future[bool] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        await fa.mkdir("/coll")        # MKCOL 201
        await fa.remove("/coll/f")     # DELETE 204
        await fa.removeDir("/coll")    # DELETE 204
        result = true
    check waitFor(run())

  test "PUT rejects offset/resume":
    proc run(): Future[bool] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        try:
          discard await fa.openWrite("/x", offset = 5); result = false
        except CatchableError: result = true
    check waitFor(run())

  test "autoindex listing":
    proc run(): Future[int] {.async.} =
      withServer:
        let fa = newHttpAccess("127.0.0.1", port, "", "", rm)
        let entries = await fa.listInfo("")
        # expect file1.txt (file) and sub (dir); skip sort/parent/ext links
        doAssert entries.len == 2, $entries.len
        doAssert entries[0].name == "file1.txt"
        doAssert entries[1].name == "sub"
        doAssert entries[1].isDir
        result = entries.len
    check waitFor(run()) == 2
