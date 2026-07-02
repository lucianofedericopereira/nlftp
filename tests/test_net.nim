## Phase 0 adapter tests: ratelimit, speedometer, gzip, and a live loopback
## netstream round-trip.

import std/[unittest, math, strutils, times]
import chronos
import ../nlftp/core/ratelimit
import ../nlftp/core/speedometer
import ../nlftp/core/gzip
import ../nlftp/core/netstream

suite "ratelimit":
  test "unlimited":
    var b = initTokenBucket(0)
    check b.allowed == high(int)
    check b.delayFor(1_000_000) == 0.0

  test "bucket drains and refills":
    var b = initTokenBucket(1000.0, burst = 1000.0)   # 1000 B/s, cap 1000
    check b.allowed == 1000
    b.take(1000)
    b.advance(0.0)
    check b.allowed == 0
    check abs(b.delayFor(500) - 0.5) < 1e-6            # 500 B at 1000 B/s = 0.5s
    b.advance(0.5)                                     # refill half a second
    check b.allowed == 500

  test "refill capped at burst":
    var b = initTokenBucket(1000.0, burst = 1000.0)
    b.advance(100.0)                                   # would overfill
    check b.allowed == 1000

suite "speedometer":
  test "steady rate converges":
    var s = initSpeedometer(period = 4.0)
    for _ in 0 ..< 50:
      s.add(1000, 1.0)                                 # 1000 B/s steadily
    check abs(s.rate - 1000.0) < 1.0

  test "eta":
    var s = initSpeedometer(period = 4.0)
    for _ in 0 ..< 50:
      s.add(1000, 1.0)                # converge to ~1000 B/s
    check abs(s.eta(2000) - 2.0) < 0.2
    s.reset()
    check s.eta(2000) == Inf

suite "gzip":
  test "gzip round-trip":
    let original = "the quick brown fox " & repeat("lftp ", 200)
    let packed = compress(original, cfGzip)
    check packed.len < original.len
    check decompress(packed, cfGzip) == original

  test "zlib and deflate round-trip":
    let original = repeat("abc123", 100)
    check decompress(compress(original, cfZlib), cfZlib) == original
    check decompress(compress(original, cfDeflate), cfDeflate) == original

  test "content-encoding dispatch":
    let body = repeat("x", 500)
    check decodeContentEncoding(compress(body, cfGzip), "gzip") == body
    check decodeContentEncoding(body, "identity") == body
    check decodeContentEncoding(body, "") == body

  test "bad content-encoding raises":
    expect GzipError:
      discard decodeContentEncoding("x", "br")

suite "netstream loopback":
  test "connect, line round-trip, close":
    proc serve(server: StreamServer; transp: StreamTransport) {.async: (raises: []).} =
      try:
        let r = newAsyncStreamReader(transp)
        let w = newAsyncStreamWriter(transp)
        let line = await r.readLine(8192, sep = "\r\n")
        await w.write("ECHO " & line & "\r\n")
        await w.closeWait()
        await r.closeWait()
        await transp.closeWait()
        server.stop()
      except CatchableError:
        discard

    proc run(): Future[string] {.async.} =
      let server = createStreamServer(initTAddress("127.0.0.1:0"), serve,
                                      {ReuseAddr})
      let port = server.localAddress().port
      server.start()
      let ns = await dial("127.0.0.1", int(port))
      await ns.sendLine("HELLO")
      let reply = await ns.recvLine()
      await ns.close()
      await server.closeWait()
      return reply

    check waitFor(run()) == "ECHO HELLO"

  test "connect timeout fails fast on a dead host":
    # 192.0.2.1 is TEST-NET-1 (RFC 5737) — typically blackholes. With a short
    # timeout, dial must raise quickly, not hang the ~75s OS default.
    proc run(): Future[float] {.async.} =
      let t0 = epochTime()
      try:
        discard await dial("192.0.2.1", 80, timeout = chronos.seconds(2))
      except CatchableError:
        discard
      return epochTime() - t0
    check waitFor(run()) < 15.0      # ~2s (or instant if unreachable), never ~75s
