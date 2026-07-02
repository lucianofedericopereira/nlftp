## Retry policy tests (pure; the inlined retry loops use these).

import std/math
import unittest2
import ../nlftp/core/retry

suite "retry policy":
  test "shouldRetry honors max-retries (0 = off)":
    check not RetryConfig(maxRetries: 0).shouldRetry(1)
    check RetryConfig(maxRetries: 3).shouldRetry(1)
    check RetryConfig(maxRetries: 3).shouldRetry(3)
    check not RetryConfig(maxRetries: 3).shouldRetry(4)

  test "backoff is exponential, capped":
    let c = RetryConfig(baseSec: 2, multiplier: 2, maxSec: 10)
    check c.backoffDelay(1) == 2.0
    check c.backoffDelay(2) == 4.0
    check c.backoffDelay(3) == 8.0
    check c.backoffDelay(4) == 10.0     # capped at maxSec
    check RetryConfig(baseSec: 0).backoffDelay(1) == 0.0
    check RetryConfig(baseSec: 5, multiplier: 1).backoffDelay(3) == 5.0  # flat
