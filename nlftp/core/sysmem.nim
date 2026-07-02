## System memory query — POSIX-only (macOS `sysctl hw.memsize`, Linux
## `/proc/meminfo`). Used to size the in-memory response-buffer cap from real
## RAM, so a huge or malicious body aborts cleanly instead of OOMing the
## process (rather than a hardcoded magic number).

import std/strutils
import config

when defined(macosx):
  proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t;
                    newp: pointer; newlen: csize_t): cint
    {.importc, header: "<sys/sysctl.h>".}

  proc totalMemory*(): int64 =
    var mem: uint64
    var ln = csize_t(sizeof(mem))
    if sysctlbyname("hw.memsize", addr mem, addr ln, nil, 0) == 0: int64(mem)
    else: 0

  proc availableMemory*(): int64 = totalMemory()
    ## macOS has no cheap portable "available" figure; total is the basis.

elif defined(linux):
  proc readMeminfo(key: string): int64 =
    try:
      for line in lines("/proc/meminfo"):
        if line.startsWith(key):
          return parseInt(line.splitWhitespace()[1]).int64 * 1024  # kB -> bytes
    except CatchableError: discard
    0
  proc totalMemory*(): int64 = readMeminfo("MemTotal:")
  proc availableMemory*(): int64 =
    let a = readMeminfo("MemAvailable:")
    if a > 0: a else: totalMemory()

else:
  proc totalMemory*(): int64 = 0
  proc availableMemory*(): int64 = 0

proc bufferBudget*(fraction = BufferBudgetFraction): int64 =
  ## A conservative cap for one in-memory buffer: availableMemory/fraction,
  ## clamped to [BufferBudgetMin, BufferBudgetMax]. Falls back when RAM unknown.
  ## (Tunables live in core/config.nim.)
  let avail = availableMemory()
  if avail <= 0: return BufferBudgetFallback
  max(BufferBudgetMin, min(BufferBudgetMax, avail div fraction))
