<?php

declare(strict_types=1);

/**
 * Smoke test: drive the REAL nlftp engine in-process and stream its output
 * back to PHP. Uses local-only commands so it needs no network.
 *
 * Run:  php php/nlftp_smoke.php
 */

$ext = PHP_OS_FAMILY === 'Darwin' ? 'dylib' : 'so';
$lib = __DIR__ . "/../build/libnlftp.$ext";

if (!is_file($lib)) {
    fwrite(STDERR, "missing $lib — run ./build.sh src/nlftp_ffi.nim nlftp\n");
    exit(1);
}

$ffi = FFI::cdef(<<<'CDEF'
    void nlftp_init(void);
    typedef void (*nlftp_log_cb)(const char *line, void *ctx);
    int  nlftp_run_script(const char *script, nlftp_log_cb cb, void *ctx);
CDEF, $lib);

$ffi->nlftp_init();

// A real nlftp script — every output line streams through the callback.
$script = <<<'NLFTP'
echo === nlftp running in-process ===
version
lpwd
set net:timeout
NLFTP;

$lines = [];
$cb = function (string $line, $ctx) use (&$lines): void {
    $lines[] = $line;
};

$status = $ffi->nlftp_run_script($script, $cb, null);

echo "engine output (streamed via callback):\n";
foreach ($lines as $l) {
    echo "  | $l\n";
}
echo "\nexit status = $status\n";
echo $status === 0 ? "IN-PROCESS ENGINE WORKS ✓\n" : "engine returned non-zero\n";
