<?php

declare(strict_types=1);

/**
 * End-to-end test of the Nim <-> PHP FFI bridge.
 *
 * Run:  php php/demo.php
 *
 * It exercises all four patterns the bridge needs: init, scalar, string
 * (with explicit free), and a Nim->PHP progress callback.
 */

// Locate the shared library the build script produced (.dylib on macOS, .so elsewhere).
$ext = PHP_OS_FAMILY === 'Darwin' ? 'dylib' : 'so';
$lib = __DIR__ . "/../build/libdemo.$ext";

if (!is_file($lib)) {
    fwrite(STDERR, "missing $lib — run ./build.sh first\n");
    exit(1);
}

// The C ABI, declared inline. (In production, point FFI::load() at a .h file
// with FFI_SCOPE/FFI_LIB headers so opcache can preload it — see the README.)
$ffi = FFI::cdef(<<<'CDEF'
    void  demo_init(void);
    int   demo_add(int a, int b);
    char *demo_echo(const char *input);
    void  demo_free(char *p);
    typedef void (*demo_log_cb)(const char *line, void *ctx);
    int   demo_run(const char *script, demo_log_cb cb, void *ctx);
CDEF, $lib);

// 1. Boot the Nim runtime exactly once.
$ffi->demo_init();

// 2. Scalar in / out.
$sum = $ffi->demo_add(40, 2);
echo "demo_add(40, 2)      = $sum\n";
assert($sum === 42);

// 3. String in / heap-string out — read it, then hand the pointer back to free.
$ptr = $ffi->demo_echo("hello from php");
$str = FFI::string($ptr);
$ffi->demo_free($ptr);
echo "demo_echo(...)       = \"$str\"\n";
assert($str === 'nim says: hello from php');

// 4. Callback: Nim calls back into PHP once per command line.
$lines = [];
// Note: FFI marshals the `const char *` argument to a PHP string for us, so
// $line is already a string here (no FFI::string() needed on callback args).
$cb = function (string $line, $ctx) use (&$lines): void {
    $lines[] = $line;
};
$count = $ffi->demo_run('open ftp://x ; cd /pub ; mirror . site', $cb, null);
echo "demo_run(...)        = $count commands\n";
foreach ($lines as $l) {
    echo "  callback: $l\n";
}
assert($count === 3);
assert($lines === ['ran: open ftp://x', 'ran: cd /pub', 'ran: mirror . site']);

echo "\nALL PATTERNS WORK ✓\n";
