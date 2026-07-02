## Live transfer progress — surfaces the Speedometer as an in-place updating
## status line (name, %, done/total, speed, ETA).
##
## Writes to **stderr** so it never pollutes stdout (command output / piped
## data), and only when stderr is a TTY — so scripts, pipes, and CI stay clean.
## `renderLine` is pure (testable); `force` enables output without a real TTY.

import std/[monotimes, times, terminal, strutils, math]
import speedometer

type
  ProgressMeter* = ref object
    name: string
    total: int64           ## -1 = unknown size
    done: int64
    speedo: Speedometer
    last: MonoTime
    enabled*: bool
    active: bool

proc newProgressMeter*(name: string; total: int64; force = false): ProgressMeter =
  ProgressMeter(name: name, total: total, speedo: initSpeedometer(),
                enabled: force or stderr.isatty())

proc hsize*(n: int64): string =
  ## "1.2M"-style human size.
  if n < 0: return "?"
  const u = ["B", "K", "M", "G", "T"]
  var f = n.float
  var i = 0
  while f >= 1024.0 and i < u.high:
    f /= 1024.0
    inc i
  if i == 0: $n & "B" else: formatFloat(f, ffDecimal, 1) & u[i]

proc heta*(sec: float): string =
  ## seconds -> MM:SS (or HH:MM:SS); "--:--" if unknown/infinite.
  if sec < 0 or sec == Inf or sec != sec: return "--:--"
  let s = int(sec)
  if s >= 3600:
    align($(s div 3600), 2, '0') & ":" & align($((s mod 3600) div 60), 2, '0') &
      ":" & align($(s mod 60), 2, '0')
  else:
    align($(s div 60), 2, '0') & ":" & align($(s mod 60), 2, '0')

proc renderLine*(p: ProgressMeter): string =
  result = p.name
  if p.total > 0:
    result.add "  " & $int(p.done * 100 div p.total) & "%"
    result.add "  " & hsize(p.done) & "/" & hsize(p.total)
  else:
    result.add "  " & hsize(p.done)
  result.add "  " & hsize(int64(p.speedo.rate)) & "/s"
  if p.total > 0 and p.speedo.rate > 0:
    result.add "  ETA " & heta(p.speedo.eta(int(p.total - p.done)))

proc update*(p: ProgressMeter; done: int64) {.raises: [].} =
  ## Account `done` total bytes; redraw the line (throttled to ~150ms).
  if not p.enabled: return
  let delta = done - p.done
  p.done = done
  if delta > 0: p.speedo.sample(int(delta))
  let now = getMonoTime()
  if p.active and (now - p.last).inMilliseconds < 150: return
  p.last = now
  p.active = true
  # the status line is cosmetic — never let an stderr hiccup break a transfer
  try:
    stderr.write("\r" & renderLine(p) & "   ")
    stderr.flushFile()
  except Exception: discard

proc finish*(p: ProgressMeter) =
  ## Clear the status line at end of transfer.
  if p.enabled and p.active:
    try:
      stderr.write("\r" & spaces(72) & "\r")
      stderr.flushFile()
    except Exception: discard
