## Byte buffer — port of lftp's `Buffer` (src/buffer.h / buffer.cc).
##
## A growable FIFO byte store. lftp's key trick is *consume-without-shift*:
## reading data advances a start offset rather than memmoving the remainder,
## and the backing store is only compacted lazily. We keep that property so the
## hot path (append at tail, drain from head) stays allocation-light.
##
## The async I/O pumps (`IOBuffer`, which read/write this store over a chronos
## transport) are built on top of this in a later phase.

import std/strutils
import config

type
  Buffer* = object
    data: seq[byte]      ## backing store
    start: int           ## offset of first unread byte
    eof*: bool           ## producer signalled end-of-stream
    bptr: int            ## logical stream position of `start` (bytes consumed)
    err*: string         ## sticky error text ("" = none)

func len*(b: Buffer): int {.inline.} =
  ## Number of unread (buffered) bytes.
  b.data.len - b.start

func isEmpty*(b: Buffer): bool {.inline.} = b.len == 0

func position*(b: Buffer): int {.inline.} =
  ## Total bytes consumed so far (lftp's buffer position counter).
  b.bptr

proc compact(b: var Buffer) =
  ## Drop already-consumed bytes from the front when it's worthwhile.
  if b.start == 0: return
  if b.start == b.data.len:
    b.data.setLen(0)
    b.start = 0
  elif b.start >= BufferCompactThreshold or b.start * 2 >= b.data.len:
    b.data = b.data[b.start ..< b.data.len]
    b.start = 0

proc put*(b: var Buffer; src: openArray[byte]) =
  ## Append bytes at the tail.
  if src.len == 0: return
  compact(b)
  let off = b.data.len
  b.data.setLen(off + src.len)
  for i in 0 ..< src.len:
    b.data[off + i] = src[i]

proc put*(b: var Buffer; s: string) =
  ## Append a string's bytes.
  if s.len == 0: return
  compact(b)
  let off = b.data.len
  b.data.setLen(off + s.len)
  for i in 0 ..< s.len:
    b.data[off + i] = byte(s[i])

proc putLine*(b: var Buffer; s: string) =
  ## Append a string followed by CRLF (protocol command convenience).
  b.put(s)
  b.put("\r\n")

func peek*(b: Buffer): seq[byte] =
  ## View the buffered bytes (copy). Does not consume.
  b.data[b.start .. ^1]

func peekString*(b: Buffer): string =
  ## Buffered bytes as a string. Does not consume.
  result = newString(b.len)
  for i in 0 ..< b.len:
    result[i] = char(b.data[b.start + i])

proc skip*(b: var Buffer; n: int) =
  ## Consume `n` bytes from the head (advance, don't shift).
  let take = min(n, b.len)
  b.start += take
  b.bptr += take
  compact(b)

proc get*(b: var Buffer; n: int): seq[byte] =
  ## Read and consume up to `n` bytes.
  let take = min(n, b.len)
  result = b.data[b.start ..< b.start + take]
  b.skip(take)

proc getString*(b: var Buffer; n: int): string =
  ## Read and consume up to `n` bytes as a string.
  let take = min(n, b.len)
  result = newString(take)
  for i in 0 ..< take:
    result[i] = char(b.data[b.start + i])
  b.skip(take)

proc getLine*(b: var Buffer): string =
  ## Consume and return one line (up to and including LF) if a complete line
  ## is buffered; otherwise return "" and consume nothing. Trailing CR is
  ## stripped. Use `eof` to decide how to treat a final unterminated line.
  let s = b.start
  var i = s
  while i < b.data.len:
    if b.data[i] == byte('\n'):
      var endp = i
      if endp > s and b.data[endp-1] == byte('\r'):
        dec endp
      result = newString(endp - s)
      for j in 0 ..< result.len:
        result[j] = char(b.data[s + j])
      b.skip(i - s + 1)
      return
    inc i
  return ""   # no complete line yet

proc setEof*(b: var Buffer) {.inline.} = b.eof = true

proc setError*(b: var Buffer; msg: string) {.inline.} = b.err = msg

func hasError*(b: Buffer): bool {.inline.} = b.err.len > 0

func `$`*(b: Buffer): string =
  ## Debug rendering.
  "Buffer(len=" & $b.len & ", pos=" & $b.bptr & ", eof=" & $b.eof &
    (if b.err.len > 0: ", err=" & escape(b.err) else: "") & ")"
