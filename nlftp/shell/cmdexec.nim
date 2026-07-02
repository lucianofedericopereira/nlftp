## Command executor — port of lftp's `CmdExec`/`commands.cc` (the dispatch +
## a starter command set). Holds the session state (current backend + always-
## local backend + settings) and runs parsed command lines.
##
## Backends are `FileAccess`, so every command is protocol-agnostic: when Phase
## 2 adds FTP, `open ftp://…` swaps `session` to an FtpAccess and `ls`/`get`/…
## work unchanged.

import std/[strutils, os, options, algorithm, times, tables, sequtils, terminal]
import chronos
import ../core/[errors, settings, defaults, retry]
import ../core/version
import ../fs/[fileaccess, localaccess, fileinfo, url, netrc]
import ../proto/ftp
import ../proto/http
import ../proto/sftp
import ../jobs/mirror
import ../jobs/walk
import ../jobs/pget
import parsecmd, copyengine

type
  OutSink* = proc(s: string) {.gcsafe, raises: [].}
    ## A captured-output callback. Non-raising + gcsafe so it can be invoked
    ## from async procs without widening their effect set.

  JobState = enum jsRunning, jsDone, jsFailed
  Job = ref object
    id: int
    cmd: string
    state: JobState
    err: string
    fut: Future[void]
  JobManager = ref object
    sem: AsyncSemaphore         ## bounded concurrency (cmd:queue-parallel)
    jobs: seq[Job]
    nextId: int

  CmdExec* = ref object
    settings*: ResMgr
    session*: FileAccess        ## current backend (local until `open`)
    localFa*: LocalAccess       ## always-local backend (lcd/lls/lpwd)
    aliases*: Table[string, string]
    bookmarks*: Table[string, string]
    pending*: seq[string]       ## lines queued by `source`, drained by execLine
    jobMgr*: JobManager         ## background `queue`d jobs
    quitFlag*: bool
    exitCode*: int              ## process exit status (set by cmd:fail-exit)
    # Output sinks. nil = write to the terminal (CLI default); a library host
    # (e.g. the PHP/FFI bridge) sets these to capture output instead. See emit*.
    outSink*: OutSink   ## one message line (newline added by the sink)
    rawSink*: OutSink   ## raw bytes, no newline (cat / file dumps)
    errSink*: OutSink   ## diagnostics (failures, job errors)

const BookmarksFile = ".nlftp/bookmarks"

proc loadBookmarks(x: CmdExec) =
  let path = getHomeDir() / BookmarksFile
  if not fileExists(path): return
  for line in readFile(path).splitLines():
    let parts = line.strip().split(' ', 1)
    if parts.len == 2 and parts[0].len > 0:
      x.bookmarks[parts[0]] = parts[1].strip()

proc saveBookmarks(x: CmdExec) =
  let path = getHomeDir() / BookmarksFile
  createDir(getHomeDir() / ".nlftp")
  var s = ""
  for k, v in x.bookmarks: s.add k & " " & v & "\n"
  writeFile(path, s)

proc matchGlob*(name, pat: string): bool =
  ## Minimal shell glob: `*` (any run) and `?` (one char). Used by mget/mput.
  proc go(n, p: int): bool =
    if p == pat.len: return n == name.len
    case pat[p]
    of '*':
      # match zero+ chars
      if go(n, p + 1): return true
      if n < name.len: return go(n + 1, p)
      return false
    of '?':
      return n < name.len and go(n + 1, p + 1)
    else:
      return n < name.len and name[n] == pat[p] and go(n + 1, p + 1)
  go(0, 0)

func hasGlob(s: string): bool =
  '*' in s or '?' in s

proc newCmdExec*(): CmdExec =
  let rm = newResMgr()
  rm.registerDefaults()
  # Distinct backends: `session` (what cd/ls/get act on, local until `open`) and
  # the always-local `localFa` (lcd/lls/lpwd) must track separate cwds.
  result = CmdExec(settings: rm, session: newLocalAccess(),
                   localFa: newLocalAccess(),
                   aliases: initTable[string, string](),
                   bookmarks: initTable[string, string](),
                   jobMgr: JobManager(jobs: @[], nextId: 0), quitFlag: false)
  result.loadBookmarks()

# forward decl: queued jobs run via execLine (mutual recursion with the queue)
proc execLine*(x: CmdExec; line: string): Future[void] {.async.}

# --- output sinks ----------------------------------------------------------
# All console output goes through these so a host can capture it. `emit` is a
# drop-in for `echo` (command syntax: `x.emit a, b, c`); the sink owns the
# trailing newline. Default behavior is identical to the old direct stdout/err.

proc emit*(x: CmdExec; parts: varargs[string, `$`]) {.gcsafe, raises: [].} =
  var s = ""
  for p in parts: s.add p
  if x.outSink != nil: x.outSink(s)
  else:
    try: stdout.writeLine(s) except CatchableError: discard

proc emitRaw*(x: CmdExec; s: string) {.gcsafe, raises: [].} =
  if x.rawSink != nil: x.rawSink(s)
  else:
    try: stdout.write(s) except CatchableError: discard

proc emitErr*(x: CmdExec; s: string) {.gcsafe, raises: [].} =
  if x.errSink != nil: x.errSink(s)
  else:
    try: stderr.writeLine(s) except CatchableError: discard

# --- output helpers --------------------------------------------------------

proc fmtMode(fi: fileinfo.FileInfo): string =
  result = case fi.kind
    of ftDir: "d"
    of ftSymlink: "l"
    else: "-"
  if fi.mode.isSome:
    const ch = "rwxrwxrwx"
    let m = fi.mode.get
    for i in 0 ..< 9:
      result.add (if (m and (1 shl (8 - i))) != 0: ch[i] else: '-')
  else:
    result.add "?????????"

proc fmtEntry(fi: fileinfo.FileInfo): string =
  let sz = if fi.size.isSome: $fi.size.get else: "-"
  let t = if fi.mtime.isSome: fi.mtime.get.format("MMM dd HH:mm") else: ""
  var name = fi.name
  if fi.kind == ftSymlink and fi.symlink.len > 0:
    name = name & " -> " & fi.symlink
  fmtMode(fi) & " " & align(sz, 12) & " " & t & " " & name

proc printLong(x: CmdExec; entries: seq[fileinfo.FileInfo]) =
  var sorted = entries
  sorted.sort(proc(a, b: fileinfo.FileInfo): int = cmpIgnoreCase(a.name, b.name))
  for fi in sorted:
    x.emit fmtEntry(fi)

# --- argument helpers ------------------------------------------------------

proc takeOutOpt(args: var seq[string]): string =
  ## Extract a `-o <path>` option, returning the path ("" if absent).
  let i = args.find("-o")
  if i >= 0 and i + 1 < args.len:
    result = args[i + 1]
    args.delete(i)      # remove -o
    args.delete(i)      # remove value

# --- commands --------------------------------------------------------------

proc cmdHelp(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  x.emit """Commands:
  ls [path]              list session directory      lls [path]   list local
  cd <dir> / pwd         session dir                 lcd / lpwd   local dir
  get <file> [-o out]    download (session->local)   put <file>   upload
  pget -n N <file>       segmented parallel download
  cat <file>             print a file
  mkdir <dir>  rm [-r] <f>  rmdir <d>  mv <a> <b>  chmod <mode> <f>
  find [dir]   du [-h] [dir]   (recursive)
  open <url|bookmark>    connect (ftp/ftps/http/https/sftp)
  bookmark add <name>    save current site           open <name>  use a bookmark
  source <file>          run another script          set [name [value]]
  get -c <file>          resume a partial download    !<cmd>       run shell cmd
  echo  version  help    exit/quit"""

proc cmdSet(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  if args.len == 0:
    for name in x.settings.allNames:
      x.emit name, " = ", x.settings.query(name)
  elif args.len == 1:
    x.emit args[0], " = ", x.settings.query(args[0])
  else:
    x.settings.set(args[0], args[1 .. ^1].join(" "))

proc cmdLs(x: CmdExec; fa: FileAccess; args: seq[string]): Future[void] {.async.} =
  let path = if args.len > 0: args[0] else: ""
  printLong(x, await fa.listInfo(path))

proc cmdCat(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  if args.len == 0: raiseError("cat: missing file")
  let r = await x.session.openRead(args[0])
  while not r.atEnd:
    let chunk = await r.readSome()
    if chunk.len == 0: break
    x.emitRaw(cast[string](chunk))
  await r.closeReader()

proc rateOf(x: CmdExec): float =
  ## Per-transfer limit; also (re)applies the global cap. From net:limit-rate /
  ## net:limit-total-rate (bytes/sec; 0 = unlimited).
  setTotalRateLimit(x.settings.queryInt("net:limit-total-rate").float)
  x.settings.queryInt("net:limit-rate").float

proc wantProgress(): bool =
  stderr.isatty() or existsEnv("NLFTP_FORCE_PROGRESS")

proc makeMeter(x: CmdExec; fa: FileAccess; remotePath, label: string):
    Future[ProgressMeter] {.async.} =
  ## Build a progress meter for a transfer (fetches the size for %/ETA). Only
  ## call when progress is actually wanted — `size` costs a round-trip.
  let total = try: await fa.size(remotePath) except CatchableError: -1
  return newProgressMeter(label, total, force = existsEnv("NLFTP_FORCE_PROGRESS"))

proc retryConfig(x: CmdExec): RetryConfig =
  RetryConfig(
    maxRetries: x.settings.queryInt("net:max-retries"),   # 0 = off (default)
    baseSec: x.settings.queryInt("net:reconnect-interval-base").float,
    multiplier: (try: parseFloat(x.settings.query(
                   "net:reconnect-interval-multiplier")) except ValueError: 1.0),
    maxSec: x.settings.queryInt("net:reconnect-interval-max").float)

proc backoff(x: CmdExec; cfg: RetryConfig; attempt: int) {.async.} =
  let d = cfg.backoffDelay(attempt)
  # qualify: cmdexec imports std/times, whose `milliseconds` -> TimeInterval
  # would shadow chronos's `milliseconds` -> Duration.
  if d > 0: await sleepAsync(chronos.milliseconds(int(d * 1000)))

proc connectWithRetry(x: CmdExec; fa: FileAccess) {.async.} =
  ## connect(), retrying per net:max-retries with backoff.
  let cfg = x.retryConfig()
  var attempt = 0
  while true:
    try:
      await fa.connect()
      return
    except CatchableError as e:
      inc attempt
      if not cfg.shouldRetry(attempt): raise
      x.emitErr("open: attempt " & $attempt & " failed (" & e.msg &
                "); retrying…")
      await x.backoff(cfg, attempt)

proc cmdGet(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  var a = args
  var cont = false
  let ci = a.find("-c")
  if ci >= 0: cont = true; a.delete(ci)     # -c = continue/resume
  let outName = takeOutOpt(a)
  if a.len == 0: raiseError("get: missing file")
  let remote = a[0]
  let local = if outName.len > 0: outName else: extractFilename(remote)
  var offset = 0'i64
  if cont:
    let lp = x.localFa.getCwd / local
    if fileExists(lp): offset = getFileSize(lp)
  if not cont and not x.settings.queryBool("xfer:clobber") and
     fileExists(x.localFa.getCwd / local):
    raiseError("get: " & local & ": file exists (xfer:clobber is off)")
  let meter = if wantProgress(): await x.makeMeter(x.session, remote, local)
              else: nil
  # transfer with retry: on failure reconnect (fresh connection) and resume from
  # whatever bytes already landed locally (resumes for `-c`; restarts a fresh get
  # whose atomic temp file was discarded on abort).
  let cfg = x.retryConfig()
  var attempt = 0
  while true:
    try:
      let res = await copyFile(x.session, remote, x.localFa, local, offset,
                               x.rateOf(), meter)
      let verb = if offset > 0: "get -c (resumed @" & $offset & ")" else: "get"
      x.emit verb, ": ", remote, " -> ", local, " (", res.bytes, " bytes)"
      return
    except CatchableError as e:
      inc attempt
      if not cfg.shouldRetry(attempt): raise
      x.emitErr("get: attempt " & $attempt & " failed (" & e.msg &
                "); reconnecting…")
      if x.session.getProto != "file":
        try: await x.session.close() except CatchableError: discard
        x.session = await x.session.clone()
      let lp = x.localFa.getCwd / local
      offset = if fileExists(lp): getFileSize(lp) else: 0
      await x.backoff(cfg, attempt)

proc sessionUrl(x: CmdExec): string =
  let s = x.session
  if s.getProto == "file": return ""
  result = s.getProto & "://"
  if s.user.len > 0: result.add s.user & "@"
  result.add s.host
  if s.port != 0: result.add ":" & $s.port
  result.add s.getCwd

proc cmdBookmark(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  if args.len == 0 or args[0] == "list":
    for k, v in x.bookmarks: x.emit k, " -> ", v
  elif args[0] == "add" and args.len >= 2:
    let url = if args.len >= 3: args[2] else: x.sessionUrl()
    if url.len == 0: raiseError("bookmark add: no url and no open session")
    x.bookmarks[args[1]] = url
    x.saveBookmarks()
    x.emit "bookmark ", args[1], " -> ", url
  elif args[0] in ["del", "delete", "rm"] and args.len >= 2:
    x.bookmarks.del(args[1])
    x.saveBookmarks()
  else:
    raiseError("usage: bookmark [list | add <name> [url] | del <name>]")

proc cmdFind(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  let dir = if args.len > 0: args[0] else: ""
  for p in await findFiles(x.session, dir):
    x.emit p

proc cmdDu(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  let human = "-h" in args
  let pos = args.filterIt(not it.startsWith("-"))
  let dir = if pos.len > 0: pos[0] else: ""
  let total = await duSize(x.session, dir)
  x.emit (if human: humanSize(total) else: $total), "\t",
       (if dir.len > 0: dir else: ".")

proc cmdRm(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  var recursive = false
  var targets: seq[string]
  for a in args:
    if a in ["-r", "-R", "-rf", "-fr"]: recursive = true
    elif a == "-f": discard
    elif a.startsWith("-"): raiseError("rm: unknown option " & a)
    else: targets.add a
  if targets.len == 0: raiseError("rm: missing operand")
  for t in targets:
    if recursive: await removeTree(x.session, t)
    else: await x.session.remove(t)

proc cmdSource(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  if args.len == 0: raiseError("source: missing file")
  if not fileExists(args[0]): raiseError("source: not found: " & args[0])
  # queue lines; execLine drains them after the current line (no async recursion)
  x.pending.add readFile(args[0]).splitLines()

# --- background jobs / queue (chronos AsyncSemaphore-bounded) ---------------

proc runJob(x: CmdExec; job: Job) {.async.} =
  await x.jobMgr.sem.acquire()
  # Each job runs on its OWN cloned connection (isolated from the foreground and
  # from sibling jobs) — one ftp/sftp channel can't multiplex; clone() opens a
  # fresh one, while local/http clone to themselves.
  var sess: FileAccess
  try:
    sess = await x.session.clone()
    let jx = CmdExec(settings: x.settings, session: sess,
                     localFa: newLocalAccess(x.localFa.getCwd),
                     aliases: x.aliases, bookmarks: x.bookmarks,
                     jobMgr: x.jobMgr)
    await jx.execLine(job.cmd)        # errors are reported inside execLine
    job.state = jsDone
  except CatchableError as e:
    job.state = jsFailed; job.err = e.msg
  finally:
    if not sess.isNil and sess != x.session:
      await sess.close()
    x.jobMgr.sem.release()

proc cmdJobs(x: CmdExec): Future[void] {.async.} =
  if x.jobMgr.jobs.len == 0: x.emit "no jobs"; return
  for j in x.jobMgr.jobs:
    let st =
      if not j.fut.isNil and not j.fut.finished: "running"
      elif j.state == jsFailed: "failed"
      else: "done"
    x.emit "[", j.id, "] ", st, "\t", j.cmd

proc cmdQueue(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  if args.len == 0:
    await cmdJobs(x); return
  if x.jobMgr.sem.isNil:                       # size from the current setting
    x.jobMgr.sem = newAsyncSemaphore(
      max(1, x.settings.queryInt("cmd:queue-parallel")))
  inc x.jobMgr.nextId
  let job = Job(id: x.jobMgr.nextId, cmd: args.join(" "), state: jsRunning)
  job.fut = runJob(x, job)                     # spawn (don't await): background
  x.jobMgr.jobs.add job
  x.emit "queued [", job.id, "] ", job.cmd

proc pendingJobs(x: CmdExec): seq[Future[void]] =
  for j in x.jobMgr.jobs:
    if not j.fut.isNil and not j.fut.finished: result.add j.fut

proc cmdWait(x: CmdExec): Future[void] {.async.} =
  let pend = x.pendingJobs()
  if pend.len > 0: await allFutures(pend)
  for j in x.jobMgr.jobs:
    if j.state == jsFailed:
      x.emitErr("job [" & $j.id & "] failed: " & j.err)

proc waitAllJobs*(x: CmdExec): Future[void] {.async.} =
  ## Implicit wait at script end so nlftp doesn't exit before queued jobs finish.
  let pend = x.pendingJobs()
  if pend.len > 0: await allFutures(pend)

proc cmdPget(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  ## pget [-n N] <file> [-o out] — segmented parallel download (session->local).
  var a = args
  var nseg = 1
  let ni = a.find("-n")
  if ni >= 0 and ni + 1 < a.len:
    nseg = try: parseInt(a[ni+1]) except ValueError: 1
    a.delete(ni); a.delete(ni)
  let outName = takeOutOpt(a)
  if a.len == 0: raiseError("pget: missing file")
  let remote = a[0]
  let local = x.localFa.getCwd / (if outName.len > 0: outName
                                  else: extractFilename(remote))
  let res = await pget(x.session, remote, local, nseg)
  x.emit "pget: ", remote, " -> ", local, " (", res.bytes, " bytes, ",
       res.segments, " segment", (if res.segments == 1: "" else: "s"), ")"

proc cmdPut(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  var a = args
  let outName = takeOutOpt(a)
  if a.len == 0: raiseError("put: missing file")
  let local = a[0]
  let remote = if outName.len > 0: outName else: extractFilename(local)
  let res = await copyFile(x.localFa, local, x.session, remote, 0, x.rateOf())
  x.emit "put: ", local, " -> ", remote, " (", res.bytes, " bytes)"

proc cmdOpen(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  if args.len == 0: raiseError("open: missing url/host")
  # Accept "host", "ftp://host/path", optional -u user[,pass].
  var a = args
  var user, pass: string
  let ui = a.find("-u")
  if ui >= 0 and ui + 1 < a.len:
    let creds = a[ui+1].split(',', 1)
    user = creds[0]
    if creds.len > 1: pass = creds[1]
    a.delete(ui); a.delete(ui)
  if a.len == 0: raiseError("open: missing host")
  # a bookmark name resolves to its stored URL
  var target = a[0]
  if target in x.bookmarks: target = x.bookmarks[target]
  var u = parseUrl(target)
  if u.proto.len == 0:
    # bare host -> default ftp
    u = parseUrl("ftp://" & target)
  if user.len > 0: u.user = user
  if pass.len > 0: (u.password = pass; u.hasPassword = true)
  # fill missing credentials from ~/.netrc
  if u.user.len == 0:
    let (nl, np) = netrcLookup(u.host)
    if nl.len > 0: u.user = nl
    if np.len > 0: (u.password = np; u.hasPassword = true)

  case u.proto
  of "ftp", "ftps":
    let fa = newFtpAccess(u.host, u.port, u.user, u.password, x.settings,
                          tls = (u.proto == "ftps"))
    await x.connectWithRetry(fa)
    x.session = fa
    if u.path.len > 0: await x.session.chdir(u.path)
    x.emit "Connected to ", u.host, " as ", fa.user, " (cwd ", x.session.getCwd, ")"
  of "http", "https":
    let fa = newHttpAccess(u.host, u.port, u.user, u.password, x.settings,
                           tls = (u.proto == "https"))
    await x.connectWithRetry(fa)
    x.session = fa
    if u.path.len > 0: await x.session.chdir(u.path)
    x.emit "Connected to ", u.host, " (", u.proto, ", cwd ", x.session.getCwd, ")"
  of "sftp":
    let fa = newSftpAccess(u.host, u.port, u.user, u.password)
    await x.connectWithRetry(fa)
    x.session = fa
    if u.path.len > 0: await x.session.chdir(u.path)
    x.emit "Connected to ", u.host, " (sftp, cwd ", x.session.getCwd, ")"
  else:
    raiseError("open: unsupported protocol: " & u.proto)

proc cmdClose(x: CmdExec): Future[void] {.async.} =
  if x.session of LocalAccess:
    return
  await x.session.close()
  x.session = newLocalAccess(x.localFa.getCwd)

proc cmdShell(cmd: string): Future[void] {.async.} =
  discard execShellCmd(cmd)

proc cmdAlias(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  if args.len == 0:
    for k, v in x.aliases: x.emit "alias ", k, " = ", v
  elif args.len == 1:
    x.aliases.del(args[0])              # `alias name` with no value unsets
  else:
    x.aliases[args[0]] = args[1 .. ^1].join(" ")

proc cmdMget(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  ## mget <patterns...>: download every session-dir entry matching a glob.
  if args.len == 0: raiseError("mget: missing pattern")
  let entries = await x.session.listInfo("")
  var n = 0
  for pat in args:
    for fi in entries:
      if fi.kind == ftFile and matchGlob(fi.name, pat):
        let res = await copyFile(x.session, fi.name, x.localFa, fi.name, 0, x.rateOf())
        x.emit "mget: ", fi.name, " (", res.bytes, " bytes)"
        inc n
  if n == 0: x.emit "mget: no matching files"

proc cmdMput(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  ## mput <patterns...>: upload every local-dir entry matching a glob.
  if args.len == 0: raiseError("mput: missing pattern")
  let entries = await x.localFa.listInfo("")
  var n = 0
  for pat in args:
    for fi in entries:
      if fi.kind == ftFile and matchGlob(fi.name, pat):
        let res = await copyFile(x.localFa, fi.name, x.session, fi.name, 0, x.rateOf())
        x.emit "mput: ", fi.name, " (", res.bytes, " bytes)"
        inc n
  if n == 0: x.emit "mput: no matching files"

proc cmdMirror(x: CmdExec; args: seq[string]): Future[void] {.async.} =
  var opts: MirrorOpts
  opts.parallel = x.settings.queryInt("mirror:parallel-transfer-count")
  opts.rateLimit = x.rateOf()             # net:limit-rate (+ sets global cap)
  opts.retry = x.retryConfig()            # net:max-retries (0 = off) auto-retry flaky files
  var pos: seq[string]
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "-R", "--reverse": opts.reverse = true
    of "-v", "--verbose": opts.verbose = true
    of "--delete": opts.deleteExtra = true
    of "-P", "--parallel":
      if i+1 < args.len:
        opts.parallel = try: parseInt(args[i+1]) except ValueError: 1
        inc i
    of "-x", "--exclude":
      if i+1 < args.len: opts.exclude = args[i+1]; inc i
    of "-i", "--include":
      if i+1 < args.len: opts.includePat = args[i+1]; inc i
    else:
      if a.startsWith("-"): raiseError("mirror: unknown option " & a)
      pos.add a
    inc i
  # mirror [src] [dst]; defaults: source dir ".", dest dir "."
  let srcDir = if pos.len > 0: pos[0] else: "."
  let dstDir = if pos.len > 1: pos[1] else: "."
  let dir = if opts.reverse: "(upload) local -> " & x.session.getProto
            else: "(download) " & x.session.getProto & " -> local"
  x.emit "mirror ", dir, ": ", srcDir, " -> ", dstDir,
       " (parallel=", max(1, opts.parallel), ")"
  # route the worker progress/error lines through this exec's sinks
  opts.log = proc(s: string) = x.emit s
  opts.logErr = proc(s: string) = x.emitErr(s)
  let s = await runMirror(x.session, x.localFa, srcDir, dstDir, opts)
  x.emit "mirror done: ", s.filesTransferred, " transferred, ",
       s.filesSkipped, " skipped, ", s.dirsMade, " dirs, ",
       s.removed, " removed, ", s.errors, " errors (", s.bytes, " bytes)"

# --- dispatch --------------------------------------------------------------

proc execWords(x: CmdExec; words: seq[string]): Future[void] {.async.} =
  if words.len == 0: return

  # alias expansion (bounded, non-recursive): rewrite the head command until
  # it's no longer an alias.
  var w = words
  var depth = 0
  while depth < 16 and w.len > 0 and w[0] in x.aliases:
    let expanded = parseCommands(x.aliases[w[0]] & " " & w[1 .. ^1].join(" "))
    if expanded.len == 0: return
    w = expanded[0].words
    inc depth
  if w.len == 0: return

  let cmd = w[0]
  let args = w[1 .. ^1]

  # `!cmd ...` shell escape
  if cmd.startsWith("!"):
    let rest = (cmd[1 .. ^1] & " " & args.join(" ")).strip()
    await cmdShell(rest)
    return

  case cmd.toLowerAscii
  of "help", "?":        await cmdHelp(x, args)
  of "exit", "quit", "bye": x.quitFlag = true
  of "version":          x.emit nlftpVersionString()
  of "echo":             x.emit args.join(" ")
  of "set":              await cmdSet(x, args)
  of "pwd":              x.emit x.session.getCwd
  of "lpwd":             x.emit x.localFa.getCwd
  of "cd":               await x.session.chdir(if args.len>0: args[0] else: ".")
  of "lcd":              await x.localFa.chdir(if args.len>0: args[0] else: ".")
  of "ls", "dir":        await cmdLs(x, x.session, args)
  of "lls":              await cmdLs(x, x.localFa, args)
  of "cat", "more":      await cmdCat(x, args)
  of "get":              await cmdGet(x, args)
  of "pget":             await cmdPget(x, args)
  of "put":              await cmdPut(x, args)
  of "mget":             await cmdMget(x, args)
  of "mput":             await cmdMput(x, args)
  of "alias":            await cmdAlias(x, args)
  of "open", "connect":  await cmdOpen(x, args)
  of "close", "disconnect": await cmdClose(x)
  of "mirror":           await cmdMirror(x, args)
  of "bookmark", "bm":   await cmdBookmark(x, args)
  of "source", ".":      await cmdSource(x, args)
  of "queue":            await cmdQueue(x, args)
  of "wait":             await cmdWait(x)
  of "jobs":             await cmdJobs(x)
  of "mkdir":            await x.session.mkdir(if args.len>0: args[0] else: "")
  of "rm", "delete":     await cmdRm(x, args)
  of "rmdir":            await x.session.removeDir(if args.len>0: args[0] else: "")
  of "find":             await cmdFind(x, args)
  of "du":               await cmdDu(x, args)
  of "mv", "rename":
    if args.len < 2: raiseError("mv: need source and dest")
    await x.session.rename(args[0], args[1])
  of "chmod":
    if args.len < 2: raiseError("chmod: need mode and file")
    let mode = try: parseOctInt(args[0]) except ValueError: raiseError("chmod: bad mode"); 0
    await x.session.chmodPath(args[1], mode)
  else:
    raiseError("unknown command: " & cmd & " (try 'help')")

proc onError(x: CmdExec; msg: string) =
  x.emitErr(msg)
  # cmd:fail-exit (yes) aborts the script with a non-zero status — important for
  # automation/CI where a silent failure would be worse.
  if x.settings.queryBool("cmd:fail-exit"):
    x.quitFlag = true
    x.exitCode = 1

proc runCmd(x: CmdExec; words: seq[string]) {.async.} =
  try:
    await execWords(x, words)
  except NlftpError as e:
    x.onError(e.msg)
  except CatchableError as e:
    x.onError("error: " & e.msg)

proc execLine*(x: CmdExec; line: string): Future[void] {.async.} =
  ## Parse and run a command line (`;`-separated commands). After each command,
  ## drain any lines queued by `source` so `source X; Y` runs X before Y
  ## (bounded; non-recursive).
  var guard = 0
  for pc in parseCommands(line):
    if x.quitFlag: break
    await runCmd(x, pc.words)
    while x.pending.len > 0 and not x.quitFlag and guard < 100_000:
      let l = x.pending[0]
      x.pending.delete(0)
      inc guard
      if l.strip().len == 0: continue
      for spc in parseCommands(l):
        if x.quitFlag: break
        await runCmd(x, spc.words)
