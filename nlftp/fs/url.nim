## URL parsing — port of lftp's `ParsedURL` (src/url.cc).
##
## lftp accepts `proto://[user[:pass]@]host[:port][/path]` plus shortcuts and
## per-component percent-encoding that std/uri doesn't handle the lftp way
## (e.g. preserving empty vs absent password, `~` home paths, bare hostnames).
## We hand-roll it (rung 5) but lean on std/uri's encode/decode helpers.

import std/[strutils, uri]

type
  ParsedURL* = object
    proto*: string       ## "ftp", "http", "sftp", "file", … ("" = bare path)
    user*: string
    password*: string
    hasPassword*: bool   ## distinguishes ":@" (empty) from absent
    host*: string
    port*: int           ## 0 = default for proto
    path*: string

const KnownProtos* = ["ftp", "ftps", "http", "https", "sftp", "file"]
  ## hftp and fish are dropped (see DECISIONS) — not accepted schemes.

func defaultPort*(proto: string): int =
  case proto
  of "ftp", "ftps": 21
  of "http": 80
  of "https": 443
  of "sftp": 22
  else: 0

func isIPv6Literal*(host: string): bool =
  ## A bare IPv6 address (contains ':' and no brackets) — needs bracketing when
  ## rendered into a URL or HTTP Host header.
  ':' in host

proc decode(s: string): string = decodeUrl(s, decodePlus = false)

proc parseUrl*(s: string): ParsedURL =
  ## Parse an lftp-style URL or a bare local path.
  var rest = s
  let schemeSep = rest.find("://")
  if schemeSep >= 0:
    result.proto = rest[0 ..< schemeSep].toLowerAscii
    rest = rest[schemeSep + 3 .. ^1]
  else:
    # No scheme: a bare path (possibly with leading host for "host:path"? lftp
    # treats a bare token as a local path here; site connection is handled by
    # the caller).
    result.path = s
    return

  # Split authority from path at the first '/'.
  var authority = rest
  var path = ""
  let slash = rest.find('/')
  if slash >= 0:
    authority = rest[0 ..< slash]
    path = rest[slash .. ^1]
  result.path = decode(path)

  # userinfo@host
  let at = authority.rfind('@')
  var hostPort = authority
  if at >= 0:
    let userinfo = authority[0 ..< at]
    hostPort = authority[at + 1 .. ^1]
    let colon = userinfo.find(':')
    if colon >= 0:
      result.user = decode(userinfo[0 ..< colon])
      result.password = decode(userinfo[colon + 1 .. ^1])
      result.hasPassword = true
    else:
      result.user = decode(userinfo)

  # host[:port], with bracketed IPv6 literals: [::1] or [2001:db8::1]:8080.
  # The stored host has no brackets (for dialing); they're re-added when needed.
  if hostPort.startsWith("["):
    let rb = hostPort.find(']')
    if rb >= 0:
      result.host = hostPort[1 ..< rb]
      let after = hostPort[rb + 1 .. ^1]
      if after.startsWith(":"):
        result.port = try: parseInt(after[1 .. ^1]) except ValueError: 0
    else:
      result.host = hostPort                       # malformed; leave as-is
  else:
    let pcolon = hostPort.rfind(':')
    if pcolon >= 0:
      result.host = hostPort[0 ..< pcolon]
      result.port = try: parseInt(hostPort[pcolon + 1 .. ^1]) except ValueError: 0
    else:
      result.host = hostPort

proc effectivePort*(u: ParsedURL): int =
  if u.port != 0: u.port else: defaultPort(u.proto)

func isRemote*(u: ParsedURL): bool =
  u.proto.len > 0 and u.proto != "file"

proc `$`*(u: ParsedURL): string =
  ## Render back to a URL (password elided).
  if u.proto.len == 0: return u.path
  result = u.proto & "://"
  if u.user.len > 0:
    result.add encodeUrl(u.user, usePlus = false)
    if u.hasPassword: result.add ":***"
    result.add "@"
  result.add (if isIPv6Literal(u.host): "[" & u.host & "]" else: u.host)
  if u.port != 0 and u.port != defaultPort(u.proto):
    result.add ":" & $u.port
  result.add u.path
