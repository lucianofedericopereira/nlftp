## Network stream — connect a chronos `StreamTransport` and wrap it in async
## reader/writer, with optional TLS upgrade. This is the foundation every
## network protocol (FTP/HTTP/SFTP control + data channels) builds on, and it
## replaces lftp's `IOBuffer` / `buffer_ssl` pumps with the chronos stream stack
## (DECISIONS §P1: IOBuffer = library).

import std/strutils
import chronos
import chronos/streams/[asyncstream, tlsstream]
import errors, config

export asyncstream.readLine, asyncstream.readExactly, asyncstream.readOnce,
       asyncstream.read, asyncstream.write, asyncstream.atEof

type
  NetStream* = ref object
    ## A bidirectional async byte stream over a TCP connection.
    transp*: StreamTransport
    reader*: AsyncStreamReader
    writer*: AsyncStreamWriter
    host*: string
    port*: int
    tls*: bool

proc dial*(host: string; port: int;
           timeout = chronos.seconds(ConnectTimeoutSec)): Future[NetStream]
    {.async.} =
  ## Resolve `host`, open a TCP connection (with a per-address connect timeout),
  ## and wrap it. Raises on failure. `timeout` defaults to ConnectTimeoutSec so a
  ## dead host fails in ~that many seconds rather than the ~75s OS default.
  let addrs =
    try:
      resolveTAddress(host, Port(port))
    except TransportError as e:
      raiseError("cannot resolve " & host & ": " & e.msg, fatal = true)
  if addrs.len == 0:
    raiseError("no addresses for " & host, fatal = true)
  var transp: StreamTransport
  var lastErr = ""
  for a in addrs:
    try:
      transp = await connect(a).wait(timeout)
      break
    except AsyncTimeoutError:
      lastErr = "connection timed out after " & $timeout
    except TransportError as e:
      lastErr = e.msg
  if transp.isNil:
    raiseError("cannot connect to " & host & ": " & lastErr, fatal = true)
  result = NetStream(
    transp: transp, host: host, port: port, tls: false,
    reader: newAsyncStreamReader(transp),
    writer: newAsyncStreamWriter(transp))

proc startTls*(ns: NetStream; serverName = ""; verify = true) {.async.} =
  ## Upgrade the connection to TLS in place (FTPS AUTH TLS / HTTPS / data chan).
  ## `serverName` drives SNI + hostname verification; empty disables the name
  ## check. `verify = false` skips certificate validation (ssl:verify-certificate
  ## no). Trust anchors default to the bundled Mozilla CA set.
  ##
  ## NOTE: this chronos/bearssl build negotiates up to TLS 1.2 only.
  var flags: set[TLSFlags]
  if not verify:
    # skip BOTH the certificate chain AND the hostname/SNI check — otherwise
    # bearssl still rejects with X509BadServerName (e.g. connecting by IP).
    flags.incl TLSFlags.NoVerifyHost
    flags.incl TLSFlags.NoVerifyServerName
  if serverName.len == 0: flags.incl TLSFlags.NoVerifyServerName
  let tls = newTLSClientAsyncStream(ns.reader, ns.writer, serverName,
                                    flags = flags)
  ns.reader = tls.reader
  ns.writer = tls.writer
  ns.tls = true

proc tlsErrorHint*(err: string): string =
  ## Turn a raw bearssl TLS error into an actionable, plain-language reason.
  ## Returns "" if the error doesn't look TLS/certificate-related.
  let e = err.toLowerAscii
  if "x509expired" in e or ("expired" in e and "certificate" in e) or
     "not yet valid" in e:
    "the server's TLS certificate (or an intermediate in its chain) is expired " &
    "or not yet valid. nlftp's TLS (bearssl) enforces certificate dates even " &
    "with `set ssl:verify-certificate no`, unlike OpenSSL. Fix the server cert " &
    "chain, or use an OpenSSL-backed build (see docs) which can skip this like lftp."
  elif "badservername" in e or "server name was not found" in e:
    "the certificate does not match the host you connected to (common when " &
    "connecting by IP). Use `set ssl:verify-certificate no`, or connect by the " &
    "name on the certificate."
  elif "nottrusted" in e or "not trusted" in e or "unknownca" in e:
    "the certificate is self-signed or from a private CA not in the trust store. " &
    "Use `set ssl:verify-certificate no` to skip verification."
  else:
    ""

proc sendLine*(ns: NetStream; line: string; sep = "\r\n") {.async.} =
  ## Write a protocol command line terminated by `sep`.
  await ns.writer.write(line & sep)

proc recvLine*(ns: NetStream; limit = 8192): Future[string] {.async.} =
  ## Read one CRLF-terminated line (separator stripped). Returns "" at EOF.
  return await ns.reader.readLine(limit, sep = "\r\n")

proc close*(ns: NetStream) {.async.} =
  ## Close the stream and underlying transport.
  if not ns.writer.isNil:
    try: await ns.writer.closeWait()
    except CatchableError: discard
  if not ns.reader.isNil:
    try: await ns.reader.closeWait()
    except CatchableError: discard
  if not ns.transp.isNil and not ns.transp.closed:
    try: await ns.transp.closeWait()
    except CatchableError: discard
