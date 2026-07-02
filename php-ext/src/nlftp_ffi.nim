## nlftp_ffi.nim — the real nlftp.so: drives the nlftp engine in-process and
## streams its output to PHP via the CmdExec output sinks.
##
## Build:
##   ./build.sh src/nlftp_ffi.nim nlftp     ->  build/libnlftp.{so,dylib}
##
## Two ways to drive it from the host:
##
##   A. Stateless one-shot     — nlftp_run_script(script): fresh engine per call,
##      settings must be `set` inside the script. Simplest; good for "run this
##      lftp script" parity.
##
##   B. Persistent session      — nlftp_open() returns a handle that holds one
##      CmdExec (settings + bookmarks + cwd) alive across calls, so the host can
##      set options programmatically (nlftp_set/nlftp_get) and run scripts that
##      share that state (nlftp_run). Close it with nlftp_close.
##
## Because cmdexec.nim routes ALL console output through x.outSink/errSink, both
## paths get true per-line streaming to the PHP callback — no stdout capture.

import std/strutils
import chronos
import ../../nlftp/shell/cmdexec     # the real engine (relative to this file)
import ../../nlftp/core/settings     # ResMgr.set / .query for the session API

proc NimMain() {.importc, cdecl.}

type LogCb = proc (line: cstring; ctx: pointer) {.cdecl, gcsafe, raises: [].}

# --- shared run body -------------------------------------------------------
# NOT exported: it captures the cb in sink closures, and a closure can't be
# dynlib-exported (".dynlib requires .exportc"). The exported procs below are
# annotated individually for the same reason — never wrap them in {.push.}.

proc runOn(x: CmdExec; script: cstring; cb: LogCb; ctx: pointer): cint =
  ## Run a multi-line nlftp script on an existing engine, streaming each output
  ## line to `cb`. Returns 0 on success, non-zero on the first failing line (or
  ## the engine's exitCode).
  if cb != nil:
    x.outSink = proc(s: string) = cb(s.cstring, ctx)
    x.rawSink = proc(s: string) = cb(s.cstring, ctx)
    x.errSink = proc(s: string) = cb(("[err] " & s).cstring, ctx)
  else:
    x.outSink = nil; x.rawSink = nil; x.errSink = nil

  var status: cint = 0
  for raw in ($script).splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith('#'): continue
    try:
      waitFor x.execLine(line)
      if x.quitFlag: break
    except CatchableError as e:
      if cb != nil: cb(("[err] " & line & ": " & e.msg).cstring, ctx)
      status = 1
      break

  waitFor waitAllJobs(x)              # let queued background jobs drain
  if status == 0 and x.exitCode != 0:
    status = cint(x.exitCode)
  status

# --- 1. runtime init -------------------------------------------------------

proc nlftp_init() {.exportc, cdecl, dynlib.} =
  NimMain()

# --- 2. stateless one-shot -------------------------------------------------

proc nlftp_run_script(script: cstring; cb: LogCb; ctx: pointer): cint
    {.exportc, cdecl, dynlib.} =
  ## Runs a full nlftp script on a throwaway engine (the same text PHP already
  ## builds for `lftp -f`). For repeated runs that share settings, use a session.
  runOn(newCmdExec(), script, cb, ctx)

# --- 3. persistent session (handle holds one CmdExec across calls) ----------

proc nlftp_open(): pointer {.exportc, cdecl, dynlib.} =
  ## Create a session and return an opaque handle. GC_ref pins the CmdExec so
  ## ORC won't collect it while PHP holds the pointer; nlftp_close releases it.
  let x = newCmdExec()
  GC_ref(x)
  cast[pointer](x)

proc nlftp_set(h: pointer; name, value: cstring): cint
    {.exportc, cdecl, dynlib.} =
  ## Set one setting on the session (same as the `set NAME VALUE` command).
  ## Returns 0 on success, 1 on a bad handle or a rejected/invalid value.
  if h == nil: return 1
  let x = cast[CmdExec](h)
  try:
    x.settings.set($name, $value)
    0
  except CatchableError:
    1

proc nlftp_get(h: pointer; name: cstring): cstring
    {.exportc, cdecl, dynlib.} =
  ## Read a setting's current value. Returns a heap copy the caller MUST release
  ## with nlftp_free (never let PHP's GC free it). nil on a bad handle.
  if h == nil: return nil
  let x = cast[CmdExec](h)
  let s = try: x.settings.query($name) except CatchableError: ""
  result = cast[cstring](alloc0(s.len + 1))
  copyMem(result, s.cstring, s.len)

proc nlftp_run(h: pointer; script: cstring; cb: LogCb; ctx: pointer): cint
    {.exportc, cdecl, dynlib.} =
  ## Run a script on the session, sharing its settings/bookmarks/cwd. Output
  ## streams to `cb`. Returns 0 / non-zero like nlftp_run_script.
  if h == nil: return 1
  runOn(cast[CmdExec](h), script, cb, ctx)

proc nlftp_free(p: cstring) {.exportc, cdecl, dynlib.} =
  ## Release a string returned by nlftp_get.
  if p != nil: dealloc(p)

proc nlftp_close(h: pointer) {.exportc, cdecl, dynlib.} =
  ## Destroy a session created by nlftp_open.
  if h != nil:
    GC_unref(cast[CmdExec](h))
