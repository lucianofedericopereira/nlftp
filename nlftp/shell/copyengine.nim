## Copy engine — the minimal seed of lftp's `FileCopy`/`CopyJob`.
##
## Pumps bytes from a source backend's `DataReader` into a destination
## backend's `DataWriter`, with atomic commit/abort, and applies rate limiting
## (per-transfer `net:limit-rate` + a shared global `net:limit-total-rate`).

import chronos
import ../core/errors
import ../core/ratelimit
import ../core/progress
import ../fs/fileaccess

export progress.ProgressMeter, progress.newProgressMeter

type
  CopyResult* = object
    bytes*: int64

var gTotalRate {.threadvar.}: TokenBucket   ## net:limit-total-rate (shared)

proc setTotalRateLimit*(bytesPerSec: float) =
  ## Configure the global rate cap shared across all concurrent transfers.
  gTotalRate = initTokenBucket(bytesPerSec)

proc accountAndDelay(bucket: var TokenBucket; bytes: int): float =
  ## Charge `bytes` to a token bucket and return seconds to wait (0 if
  ## unlimited / within budget). Synchronous — no await crosses the var param.
  if bucket.rate <= 0: return 0.0
  bucket.update()
  bucket.take(bytes)
  bucket.delayFor(0)

proc copyFile*(src: FileAccess; srcPath: string;
               dst: FileAccess; dstPath: string;
               offset: int64 = 0; rateLimit: float = 0.0;
               progress: ProgressMeter = nil): Future[CopyResult] {.async.} =
  ## Transfer `srcPath` (on `src`) to `dstPath` (on `dst`). `rateLimit` (B/s,
  ## 0 = unlimited) throttles this transfer; the global cap also applies.
  ## `progress` (if given) shows a live status line.
  var local = initTokenBucket(rateLimit)
  let r = await src.openRead(srcPath, offset)
  var w: DataWriter
  try:
    w = await dst.openWrite(dstPath, offset)
  except CatchableError:
    await r.closeReader()
    raise
  var total = offset
  try:
    while not r.atEnd:
      let chunk = await r.readSome()
      if chunk.len == 0: break
      await w.writeSome(chunk)
      total += chunk.len
      if not progress.isNil: progress.update(total)
      let d = max(accountAndDelay(local, chunk.len),
                  accountAndDelay(gTotalRate, chunk.len))
      if d > 0: await sleepAsync(milliseconds(max(1, int(d * 1000))))
    await w.finishWriter()
  except CatchableError as e:
    if not progress.isNil: progress.finish()
    await w.abortWriter()
    await r.closeReader()
    raiseError("transfer failed: " & e.msg, fatal = true)
  if not progress.isNil: progress.finish()
  await r.closeReader()
  return CopyResult(bytes: total)
