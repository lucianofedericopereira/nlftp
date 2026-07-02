## Transfer-rate meter — port of lftp's `Speedometer` (src/Speedometer.cc).
##
## Exponential moving average of transfer rate over a smoothing window. Feed it
## byte counts as they transfer; read `rate` (bytes/sec) for the status line /
## ETA. Like lftp, the window weights recent samples more heavily.

import std/[monotimes, times, math]

type
  Speedometer* = object
    rate*: float        ## smoothed bytes/sec
    period*: float      ## smoothing window (seconds)
    last: MonoTime
    started: bool

proc initSpeedometer*(period = 8.0): Speedometer =
  Speedometer(period: period)

proc add*(s: var Speedometer; bytes: int; elapsed: float) =
  ## Fold a sample (`bytes` transferred over `elapsed` seconds) into the EMA.
  if elapsed <= 0: return
  let inst = bytes.float / elapsed
  # weight grows with elapsed/period, saturating at 1 (a long gap fully replaces
  # the old estimate rather than blending stale data).
  let w = clamp(elapsed / s.period, 0.0, 1.0)
  s.rate = s.rate * (1.0 - w) + inst * w

proc sample*(s: var Speedometer; bytes: int) =
  ## Convenience: fold a sample using wall-clock time since the last call.
  let now = getMonoTime()
  if not s.started:
    s.started = true
    s.last = now
    return
  let elapsed = (now - s.last).inNanoseconds.float / 1e9
  s.last = now
  s.add(bytes, elapsed)

proc reset*(s: var Speedometer) =
  s.rate = 0.0
  s.started = false

func eta*(s: Speedometer; remaining: int): float =
  ## Estimated seconds to transfer `remaining` bytes at the current rate
  ## (`Inf` if the rate is zero).
  if s.rate <= 0: Inf else: remaining.float / s.rate
