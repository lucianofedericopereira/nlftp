## demo.nim — a minimal Nim shared library callable from PHP via FFI.
##
## It exists to prove out, in isolation, the four marshaling patterns that ANY
## Nim -> PHP bridge needs. Once these work, wrapping the real nlftp engine is
## just "swap the bodies":
##
##   1. runtime init        — NimMain() boots the Nim GC + module globals
##   2. scalar in / out     — demo_add
##   3. string in / out     — demo_echo  (+ demo_free to release the result)
##   4. callback Nim -> PHP — demo_run streams lines back through a fn pointer
##
## Build:  see ../build.sh         Test:  see ../php/demo.php

import std/strutils

# Nim emits NimMain() when compiled with --app:lib. We forward-declare it and
# expose an explicit init so the *host* (PHP) decides when the Nim runtime
# starts. Call demo_init() exactly once, right after loading the library.
proc NimMain() {.importc, cdecl.}

{.push exportc, cdecl, dynlib.}   # every proc below is C-ABI + exported

proc demo_init() =
  NimMain()

proc demo_add(a, b: cint): cint =
  a + b

proc demo_echo(input: cstring): cstring =
  ## Returns a NUL-terminated heap copy. Ownership transfers to the caller,
  ## who MUST release it with demo_free — never let PHP's GC free C memory.
  let s = "nim says: " & $input
  result = cast[cstring](alloc0(s.len + 1))
  copyMem(result, s.cstring, s.len)

proc demo_free(p: cstring) =
  if p != nil: dealloc(p)

# A C function pointer PHP fills in with a closure. Nim calls it once per line —
# this is exactly how you'd stream nlftp's transfer progress back to PHP.
type LogCb = proc (line: cstring, ctx: pointer) {.cdecl.}

proc demo_run(script: cstring, cb: LogCb, ctx: pointer): cint =
  ## Stand-in for nlftp's `for line in script: execLine(line)` loop.
  ## Splits on ';', streams each non-empty token to cb, returns the count.
  var n: cint = 0
  for raw in ($script).split(';'):
    let line = raw.strip()
    if line.len == 0: continue
    if cb != nil:
      let msg = "ran: " & line          # keep alive across the call
      cb(msg.cstring, ctx)
    inc n
  n

{.pop.}
