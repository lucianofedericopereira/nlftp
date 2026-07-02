## Token-bucket rate limiter — port of lftp's `RateLimit` (src/RateLimit.cc).
##
## lftp throttles transfers per-direction and globally. We model it as a token
## bucket: `rate` bytes/sec refill a `pool` capped at `burst`; a transfer takes
## tokens, and when the pool runs dry the async I/O adapter waits `delayFor`
## seconds. `rate <= 0` means unlimited.

import std/[monotimes, times]

type
  TokenBucket* = object
    rate*: float        ## bytes/sec; <= 0 means unlimited
    burst*: float       ## bucket capacity (max pool)
    pool: float         ## currently available bytes
    last: MonoTime

proc initTokenBucket*(rate: float; burst = 0.0): TokenBucket =
  ## `burst` defaults to one second of rate (min 4 KiB) when unspecified.
  let cap = if burst > 0: burst else: max(rate, 4096.0)
  TokenBucket(rate: rate, burst: cap, pool: cap, last: getMonoTime())

proc setRate*(b: var TokenBucket; rate: float; burst = 0.0) =
  b.rate = rate
  b.burst = if burst > 0: burst else: max(rate, 4096.0)
  b.pool = min(b.pool, b.burst)

proc advance*(b: var TokenBucket; elapsed: float) =
  ## Refill the pool for `elapsed` seconds (explicit step; used by tests and the
  ## adapter after a wait).
  if b.rate <= 0: return
  b.pool = min(b.burst, b.pool + b.rate * elapsed)

proc update*(b: var TokenBucket) =
  ## Refill based on wall-clock time since the last update.
  let now = getMonoTime()
  let elapsed = (now - b.last).inNanoseconds.float / 1e9
  b.last = now
  b.advance(elapsed)

proc allowed*(b: TokenBucket): int =
  ## Bytes that may be transferred right now.
  if b.rate <= 0: return high(int)
  max(0, b.pool.int)

proc take*(b: var TokenBucket; n: int) =
  ## Consume `n` bytes' worth of tokens (may drive the pool negative slightly;
  ## the deficit is paid back by refill).
  if b.rate <= 0: return
  b.pool -= n.float

proc delayFor*(b: TokenBucket; n: int): float =
  ## Seconds to wait until `n` bytes become available (0 if ready/unlimited).
  if b.rate <= 0 or b.pool >= n.float: return 0.0
  (n.float - b.pool) / b.rate
