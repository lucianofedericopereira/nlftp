<?php

declare(strict_types=1);

/**
 * Session API demo: configure the engine with plain PHP method calls — no
 * script string for settings — then run a (local-only) script that shares them.
 *
 * Run:  php php/nlftp_session.php
 */

require __DIR__ . '/Nlftp.php';

$nlftp = new Nlftp();

// 1. Set options programmatically. These persist for every run() below.
$nlftp->set('net:connect-timeout', 5)
      ->set('net:max-retries', 3)
      ->connectTimeout(7);          // fluent helper overrides the above

// 2. Read them back through the same handle (proves persistence).
echo "settings on the live session:\n";
foreach (['net:connect-timeout', 'net:max-retries', 'net:timeout'] as $k) {
    printf("  %-22s = %s\n", $k, $nlftp->get($k));
}

// 3. Run a script that observes those settings (set query echoes the value we
//    set above — not a fresh-engine default).
echo "\nengine output:\n";
$script = <<<'NLFTP'
echo === session-configured engine ===
version
set net:connect-timeout
set net:max-retries
NLFTP;

$status = $nlftp->run($script, fn(string $line) => print("  | $line\n"));

echo "\nexit status = $status\n";
echo ($status === 0 && $nlftp->get('net:connect-timeout') === '7')
    ? "SESSION API WORKS ✓\n"
    : "unexpected result\n";
