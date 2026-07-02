## Mirror engine — port of lftp's `MirrorJob` (src/MirrorJob.cc), simplified.
##
## Recursively synchronizes a directory tree from a *source* backend to a
## *destination* backend (both `FileAccess`, so it works for ftp->local,
## local->ftp, http->local, …). Three phases:
##   1. plan   — sequential walk: list both sides, mkdir missing dirs, count
##               skips, collect the set of file transfers + deletions
##   2. transfer — N concurrent workers (chronos async; honors
##               `mirror:parallel-transfer-count`) drain the transfer list
##   3. delete — (if --delete) remove dest entries the source lacks
##
## Deletions run AFTER transfers (issue triage #645/#665) so a failed transfer
## can't cause data loss. Stats are mutated by the concurrent workers without
## locks — chronos is single-threaded cooperative, so field updates between
## awaits never race.

import std/[tables, options, strutils]
import chronos
import ../core/errors
import ../core/retry
import ../fs/[fileaccess, fileinfo]
import ../shell/copyengine

type
  MirrorLog* = proc(s: string) {.gcsafe, raises: [].}
    ## Output callback for progress/errors; non-raising + gcsafe so worker
    ## async procs aren't forced to widen their effect set.

  MirrorOpts* = object
    reverse*: bool        ## local -> session (upload)
    deleteExtra*: bool    ## remove dest entries missing from source
    verbose*: bool
    onlyNewer*: bool      ## skip if dest size matches (cheap "same" test)
    parallel*: int        ## concurrent transfers (<=0 means 1)
    exclude*: string      ## glob: skip entries matching this
    includePat*: string      ## glob: keep only entries matching this
    rateLimit*: float     ## per-transfer B/s (0 = unlimited)
    retry*: RetryConfig   ## per-file transfer retry (net:max-retries); maxRetries 0 = off
    log*: MirrorLog       ## progress sink; nil = echo to stdout (CLI default)
    logErr*: MirrorLog    ## error sink; nil = stderr (CLI default)

  MirrorStats* = object
    filesTransferred*: int
    filesSkipped*: int
    dirsMade*: int
    removed*: int
    bytes*: int64
    errors*: int

  TransferJob = object
    src, dst: string

  DelJob = object
    path: string
    isDir: bool

# Progress/error output goes through the opts sinks when set (library host),
# else falls back to the terminal (CLI), matching the old behavior exactly.
template emitLog(opts: MirrorOpts; msg: string) =
  if opts.log != nil: opts.log(msg) else: echo msg
template emitErrLog(opts: MirrorOpts; msg: string) =
  if opts.logErr != nil: opts.logErr(msg) else: stderr.writeLine(msg)

proc j(a, b: string): string =
  if a.len == 0 or a == ".": b
  elif a.endsWith("/"): a & b
  else: a & "/" & b

proc sizeOf(fi: FileInfo): int64 =
  if fi.size.isSome: fi.size.get else: -1

proc globMatch(name, pat: string): bool =
  ## Shell glob (`*`, `?`) — used for mirror --exclude/--include filters.
  proc go(n, p: int): bool =
    if p == pat.len: return n == name.len
    case pat[p]
    of '*': (go(n, p+1) or (n < name.len and go(n+1, p)))
    of '?': n < name.len and go(n+1, p+1)
    else:   n < name.len and name[n] == pat[p] and go(n+1, p+1)
  go(0, 0)

proc filtered(name: string; opts: MirrorOpts): bool =
  ## True if `name` should be skipped per --exclude/--include.
  if opts.exclude.len > 0 and globMatch(name, opts.exclude): return true
  if opts.includePat.len > 0 and not globMatch(name, opts.includePat): return true
  false

# --- phase 1: plan (sequential) --------------------------------------------

proc planMirror(src, dst: FileAccess; srcPath, dstPath: string;
                opts: MirrorOpts; stats: ref MirrorStats;
                jobs: ref seq[TransferJob]; dels: ref seq[DelJob]) {.async.} =
  let srcEntries = await src.listInfo(srcPath)

  var dstByName = initTable[string, FileInfo]()
  try:
    for e in await dst.listInfo(dstPath):
      dstByName[e.name] = e
  except CatchableError:
    try:
      await dst.mkdir(dstPath, parents = true)
      inc stats.dirsMade
    except CatchableError:
      discard

  var seen: seq[string]
  for e in srcEntries:
    if filtered(e.name, opts): continue       # --exclude / --include
    seen.add e.name
    let s = j(srcPath, e.name)
    let d = j(dstPath, e.name)
    case e.kind
    of ftDir:
      await planMirror(src, dst, s, d, opts, stats, jobs, dels)
    of ftFile:
      let ex = dstByName.getOrDefault(e.name)
      if ex.name.len > 0 and ex.kind == ftFile and
         sizeOf(ex) >= 0 and sizeOf(ex) == sizeOf(e):
        inc stats.filesSkipped
      else:
        jobs[].add TransferJob(src: s, dst: d)
    else:
      discard   # symlinks/unknown skipped for now

  if opts.deleteExtra:
    for name, fi in dstByName:
      if name notin seen:
        dels[].add DelJob(path: j(dstPath, name), isDir: fi.kind == ftDir)

# --- phase 2: transfer worker (concurrent) ---------------------------------

proc mirrorWorker(src, dst: FileAccess; jobs: seq[TransferJob]; idx: ref int;
                  opts: MirrorOpts; stats: ref MirrorStats) {.async.} =
  ## Pull jobs by a shared index until exhausted. N of these run concurrently;
  ## the shared `idx` is safe to bump without a lock (cooperative scheduling).
  while true:
    let i = idx[]
    if i >= jobs.len: break
    idx[] = i + 1
    let job = jobs[i]
    # Transfer with retry: flaky transfers (timeouts, dropped data channels)
    # are retried on the SAME connection per net:max-retries — copyFile opens a
    # fresh data connection each attempt, so transient failures recover without
    # a full reconnect (unlike `get`, which also resumes). maxRetries 0 = off.
    var attempt = 0
    while true:
      try:
        let res = await copyFile(src, job.src, dst, job.dst, 0, opts.rateLimit)
        stats.bytes += res.bytes
        inc stats.filesTransferred
        if opts.verbose: emitLog(opts, "  transfer " & job.dst & " (" & $res.bytes & " bytes)")
        break
      except CatchableError as e:
        inc attempt
        if not opts.retry.shouldRetry(attempt):
          inc stats.errors
          emitErrLog(opts, "  failed " & job.dst & ": " & e.msg)
          break
        emitErrLog(opts, "  retry " & $attempt & "/" & $opts.retry.maxRetries &
                   " " & job.dst & ": " & e.msg)
        let d = opts.retry.backoffDelay(attempt)
        if d > 0: await sleepAsync(chronos.milliseconds(int(d * 1000)))

# --- driver ----------------------------------------------------------------

proc runMirror*(session, localFa: FileAccess; srcDir, dstDir: string;
                opts: MirrorOpts): Future[MirrorStats] {.async.} =
  ## session->local by default; local->session with `reverse`.
  let stats = new(MirrorStats)
  let jobs = new(seq[TransferJob]); jobs[] = @[]
  let dels = new(seq[DelJob]); dels[] = @[]
  let (src, dst) =
    if opts.reverse: (localFa, session)
    else: (session, localFa)

  await planMirror(src, dst, srcDir, dstDir, opts, stats, jobs, dels)

  # transfer phase — up to N concurrent workers, each with its OWN connection
  # pair (one FTP/SFTP channel can't multiplex; clone() opens a fresh one,
  # while local/http clone to themselves and share safely).
  let n = max(1, opts.parallel)
  let workerCount = min(n, max(1, jobs[].len))
  var srcConns, dstConns: seq[FileAccess]
  for w in 0 ..< workerCount:
    if w == 0:
      srcConns.add src; dstConns.add dst          # worker 0 uses the originals
    else:
      srcConns.add (await src.clone())
      dstConns.add (await dst.clone())
  # tell each connection how many siblings share RAM (shrinks in-memory caps)
  for c in srcConns: c.setConcurrency(workerCount)
  for c in dstConns: c.setConcurrency(workerCount)
  let idx = new(int); idx[] = 0
  var workers: seq[Future[void]]
  for w in 0 ..< workerCount:
    workers.add mirrorWorker(srcConns[w], dstConns[w], jobs[], idx, opts, stats)
  if workers.len > 0:
    await allFutures(workers)
  # close the extra connections (not the originals)
  for w in 1 ..< workerCount:
    if srcConns[w] != src: await srcConns[w].close()
    if dstConns[w] != dst: await dstConns[w].close()

  # delete phase — after transfers (data-loss safety)
  for del in dels[]:
    try:
      if del.isDir: await dst.removeDir(del.path)
      else: await dst.remove(del.path)
      inc stats.removed
      if opts.verbose: emitLog(opts, "  delete " & del.path)
    except CatchableError:
      inc stats.errors

  return stats[]
