## Recursive directory walks over any FileAccess backend — the engine behind
## `find`, `du`, and `rm -r` (ports of lftp's FindJob / FindJobDu / rm -r).
##
## All three are async recursions over `listInfo`; accumulators that must cross
## `await` are passed as `ref` (a plain `var` param can't be captured).

import std/[options, strutils]
import chronos
import ../core/errors
import ../fs/[fileaccess, fileinfo]

proc j*(a, b: string): string =
  ## Join a directory path with a child name.
  if a.len == 0 or a == ".": b
  elif a.endsWith("/"): a & b
  else: a & "/" & b

# --- find ------------------------------------------------------------------

proc findInto(fa: FileAccess; dir, prefix: string;
              acc: ref seq[string]) {.async.} =
  for e in await fa.listInfo(dir):
    let shown = j(prefix, e.name)
    acc[].add (if e.kind == ftDir: shown & "/" else: shown)
    if e.kind == ftDir:
      await findInto(fa, j(dir, e.name), shown, acc)

proc findFiles*(fa: FileAccess; dir = ""): Future[seq[string]] {.async.} =
  ## Recursively list every entry under `dir`, paths relative to it.
  let acc = new(seq[string])
  acc[] = @[]
  await findInto(fa, dir, (if dir.len == 0: "." else: dir), acc)
  return acc[]

# --- du --------------------------------------------------------------------

proc duSize*(fa: FileAccess; dir = ""): Future[int64] {.async.} =
  ## Total size (bytes) of all files under `dir`, recursively.
  var total = 0'i64
  for e in await fa.listInfo(dir):
    case e.kind
    of ftDir: total += await duSize(fa, j(dir, e.name))
    of ftFile:
      if e.size.isSome: total += e.size.get
    else: discard
  return total

proc humanSize*(n: int64): string =
  ## "1.2M"-style rendering.
  const units = ["B", "K", "M", "G", "T"]
  var f = n.float
  var u = 0
  while f >= 1024.0 and u < units.high:
    f /= 1024.0
    inc u
  if u == 0: $n & "B"
  else: formatFloat(f, ffDecimal, 1) & units[u]

# --- rm -r -----------------------------------------------------------------

proc removeTree*(fa: FileAccess; path: string) {.async.} =
  ## Recursively delete `path` (a directory): remove children depth-first, then
  ## the now-empty directory itself.
  var entries: seq[fileinfo.FileInfo]
  try:
    entries = await fa.listInfo(path)
  except CatchableError:
    # not a directory (or unreadable) — try a plain file delete
    await fa.remove(path)
    return
  for e in entries:
    let child = j(path, e.name)
    if e.kind == ftDir:
      await removeTree(fa, child)
    else:
      await fa.remove(child)
  await fa.removeDir(path)
