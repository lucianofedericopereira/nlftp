## Phase 2 FTP tests against an in-process minimal FTP server.
##
## The mock implements just enough of RFC 959 to exercise the client:
## greeting, USER/PASS, PWD, TYPE, EPSV (refused -> tests PASV fallback), PASV,
## LIST, RETR, STOR, QUIT. Deterministic, no external network.

import std/[strutils, os]
import unittest2
import chronos
import ../nlftp/core/[settings, defaults]
import ../nlftp/fs/fileaccess
import ../nlftp/proto/ftp

const Listing = "-rw-r--r-- 1 u g 11 Jan 15 12:30 hello.txt\r\n" &
                "drwxr-xr-x 2 u g 4096 Feb 3 2023 docs\r\n"
const FileBody = "hello world"

proc handle(server: StreamServer; ctrl: StreamTransport) {.async: (raises: []).} =
  try:
    let r = newAsyncStreamReader(ctrl)
    let w = newAsyncStreamWriter(ctrl)
    var dataServer: StreamServer
    var pendingData: Future[StreamTransport]
    proc reply(s: string) {.async.} = await w.write(s & "\r\n")

    proc openPasv(): Port =
      proc onData(s: StreamServer; t: StreamTransport) {.async: (raises: []).} =
        pendingData.complete(t)
        try: s.stop()
        except CatchableError: discard
      dataServer = createStreamServer(initTAddress("127.0.0.1:0"), onData,
                                      {ReuseAddr})
      pendingData = newFuture[StreamTransport]("data")
      dataServer.start()
      dataServer.localAddress().port

    await reply("220 mock ftp ready")
    var stored = ""
    while true:
      let line = await r.readLine(4096, sep = "\r\n")
      if line.len == 0: break
      let parts = line.split(' ', 1)
      let cmd = parts[0].toUpperAscii
      let arg = if parts.len > 1: parts[1] else: ""
      case cmd
      of "USER": await reply("331 need password")
      of "PASS": await reply("230 logged in")
      of "PWD":  await reply("257 \"/\" is cwd")
      of "TYPE": await reply("200 type set")
      of "EPSV": await reply("502 not implemented")     # force PASV fallback
      of "PASV":
        let p = openPasv()
        let hi = int(p) shr 8
        let lo = int(p) and 0xff
        await reply("227 Entering Passive Mode (127,0,0,1," & $hi & "," & $lo & ")")
      of "CWD":  await reply("250 ok")
      of "LIST":
        await reply("150 here comes the listing")
        let dt = await pendingData
        let dw = newAsyncStreamWriter(dt)
        await dw.write(Listing)
        await dw.closeWait()
        await dt.closeWait()
        await reply("226 listing done")
      of "RETR":
        await reply("150 sending file")
        let dt = await pendingData
        let dw = newAsyncStreamWriter(dt)
        await dw.write(FileBody)
        await dw.closeWait()
        await dt.closeWait()
        await reply("226 transfer complete")
      of "STOR":
        await reply("150 ready for data")
        let dt = await pendingData
        let dr = newAsyncStreamReader(dt)
        stored = ""
        while not dr.atEof():
          let chunk = await dr.read(4096)
          if chunk.len == 0: break
          stored.add cast[string](chunk)
        await dr.closeWait()
        await dt.closeWait()
        await reply("226 stored " & $stored.len & " bytes")
      of "QUIT":
        await reply("221 bye"); break
      else:
        await reply("500 unknown")
    await w.closeWait()
    await r.closeWait()
    await ctrl.closeWait()
  except CatchableError:
    discard

suite "ftp client (mock server)":
  test "connect, login, list, retrieve via PASV fallback":
    proc run(): Future[string] {.async.} =
      let server = createStreamServer(initTAddress("127.0.0.1:0"), handle,
                                      {ReuseAddr})
      let port = int(server.localAddress().port)
      server.start()
      let rm = newResMgr(); rm.registerDefaults()
      let fa = newFtpAccess("127.0.0.1", port, "anonymous", "x@y", rm)
      await fa.connect()

      let entries = await fa.listInfo()
      doAssert entries.len == 2
      doAssert entries[0].name == "hello.txt"
      doAssert entries[1].name == "docs"

      let rd = await fa.openRead("hello.txt")
      var got: seq[byte]
      while not rd.atEnd:
        let c = await rd.readSome()
        if c.len == 0: break
        got.add c
      await rd.closeReader()
      await fa.close()
      server.stop()
      return cast[string](got)

    let fut = run()
    check waitFor(fut.withTimeout(10.seconds))
    check fut.read() == FileBody
