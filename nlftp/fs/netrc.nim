## ~/.netrc parser — port of lftp's `netrc.cc`.
##
## Looks up stored credentials for a host so `open ftp://host` can authenticate
## without `-u`. Standard token grammar: `machine <host> login <user> password
## <pass>` entries, plus a trailing `default` entry. Tokens are whitespace-
## separated; `#` begins a comment.

import std/[strutils, os]

type
  NetrcEntry* = object
    machine*: string      ## "" for the `default` entry
    login*: string
    password*: string
    account*: string

proc parseNetrc*(text: string): seq[NetrcEntry] =
  ## Parse netrc content into entries.
  var toks: seq[string]
  for rawLine in text.splitLines():
    let line = rawLine.split('#', 1)[0]      # strip comments
    for t in line.splitWhitespace():
      toks.add t
  var i = 0
  var cur: NetrcEntry
  var inEntry = false
  while i < toks.len:
    case toks[i].toLowerAscii
    of "machine":
      if inEntry: result.add cur
      cur = NetrcEntry(); inEntry = true
      if i+1 < toks.len: cur.machine = toks[i+1]
      inc i, 2
    of "default":
      if inEntry: result.add cur
      cur = NetrcEntry(); inEntry = true   # machine stays ""
      inc i
    of "login", "user":
      if i+1 < toks.len: cur.login = toks[i+1]
      inc i, 2
    of "password":
      if i+1 < toks.len: cur.password = toks[i+1]
      inc i, 2
    of "account":
      if i+1 < toks.len: cur.account = toks[i+1]
      inc i, 2
    of "macdef":
      # skip a macro definition up to a blank line — we don't run macros
      inc i, 2
    else:
      inc i
  if inEntry: result.add cur

proc lookupNetrc*(entries: seq[NetrcEntry]; host: string):
    tuple[login, password: string] =
  ## Exact host match wins; else the `default` entry; else empty.
  for e in entries:
    if e.machine == host:
      return (e.login, e.password)
  for e in entries:
    if e.machine == "":
      return (e.login, e.password)
  ("", "")

proc netrcLookup*(host: string): tuple[login, password: string] =
  ## Convenience: read ~/.netrc and look up `host`. Empty if no file/match.
  let path = getHomeDir() / ".netrc"
  if not fileExists(path): return ("", "")
  try:
    lookupNetrc(parseNetrc(readFile(path)), host)
  except CatchableError:
    ("", "")
