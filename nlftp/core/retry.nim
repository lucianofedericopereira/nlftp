## Retry policy — exponential backoff for connections/transfers.
##
## Honors net:max-retries (0 = no retry, the safe default for scripts) with
## backoff net:reconnect-interval-base * multiplier^(n-1), capped at
## reconnect-interval-max. These policy functions are pure (tested); the retry
## loops themselves are inlined at the call sites (open / get), because they
## also reconnect and resume — too much side effect for a generic runner (and
## chronos closure typing makes a generic runner awkward).

import std/math

type
  RetryConfig* = object
    maxRetries*: int      ## 0 = no retry
    baseSec*: float
    multiplier*: float
    maxSec*: float

proc shouldRetry*(cfg: RetryConfig; attempt: int): bool =
  ## `attempt` is the 1-based retry number (1 = first retry).
  cfg.maxRetries > 0 and attempt <= cfg.maxRetries

proc backoffDelay*(cfg: RetryConfig; attempt: int): float =
  ## Seconds to wait before retry `attempt`.
  if cfg.baseSec <= 0: return 0.0
  let m = if cfg.multiplier > 0: cfg.multiplier else: 1.0
  min((if cfg.maxSec > 0: cfg.maxSec else: Inf),
      cfg.baseSec * pow(m, (attempt - 1).float))
