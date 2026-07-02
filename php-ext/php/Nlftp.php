<?php

declare(strict_types=1);

/**
 * Nlftp — a thin, typed PHP wrapper over libnlftp's persistent-session API.
 *
 * One instance == one nlftp engine (settings + bookmarks + cwd) held alive in
 * the Nim runtime. You configure it with plain method calls — no script string
 * required for options:
 *
 *     $nlftp = new Nlftp();
 *     $nlftp->set('net:connect-timeout', 5)
 *           ->set('net:max-retries', 3);
 *     echo $nlftp->get('net:connect-timeout');        // "5"
 *     $nlftp->run("open ftps://host/\nmirror -R ./local /remote",
 *                 fn(string $line) => print("$line\n"));
 *
 * Settings set this way persist for every subsequent run() on the same instance,
 * because they all share the one underlying CmdExec (the session handle).
 *
 * Requires ext-ffi (`php -m | grep FFI`). For production (Laravel/FPM) prefer
 * FFI::scope preloading via a header — see README "Production wiring".
 */
final class Nlftp
{
    private \FFI $ffi;
    /** @var \FFI\CData session handle (void*) */
    private $h;
    private bool $closed = false;

    public function __construct(?string $lib = null)
    {
        $ext  = PHP_OS_FAMILY === 'Darwin' ? 'dylib' : 'so';
        $lib ??= __DIR__ . "/../build/libnlftp.$ext";

        if (!is_file($lib)) {
            throw new \RuntimeException(
                "missing $lib — run ./build.sh src/nlftp_ffi.nim nlftp");
        }

        $this->ffi = \FFI::cdef(<<<'CDEF'
            void  nlftp_init(void);
            void* nlftp_open(void);
            int   nlftp_set(void *h, const char *name, const char *value);
            char* nlftp_get(void *h, const char *name);
            void  nlftp_free(char *p);
            typedef void (*nlftp_log_cb)(const char *line, void *ctx);
            int   nlftp_run(void *h, const char *script, nlftp_log_cb cb, void *ctx);
            void  nlftp_close(void *h);
        CDEF, $lib);

        $this->ffi->nlftp_init();      // boots the Nim runtime once per process
        $this->h = $this->ffi->nlftp_open();
    }

    /**
     * Set one setting (same name space as the `set` command, e.g.
     * 'net:connect-timeout', 'ftp:ssl-protect-data'). Fluent.
     *
     * @param string|int|bool $value
     * @throws \RuntimeException if the engine rejects the value (bad name/format)
     */
    public function set(string $name, string|int|bool $value): self
    {
        $v  = is_bool($value) ? ($value ? 'yes' : 'no') : (string) $value;
        $rc = $this->ffi->nlftp_set($this->h, $name, $v);
        if ($rc !== 0) {
            throw new \RuntimeException("nlftp: rejected setting $name = $v");
        }
        return $this;
    }

    /** Read a setting's current value ('' if unknown). */
    public function get(string $name): string
    {
        $ptr = $this->ffi->nlftp_get($this->h, $name);
        if ($ptr === null) {
            return '';
        }
        $s = \FFI::string($ptr);
        $this->ffi->nlftp_free($ptr);   // we own the heap copy — hand it back
        return $s;
    }

    /**
     * Run a multi-line nlftp script on this session. Each engine output line is
     * delivered to $onLine as a ready PHP string. Returns the engine exit code
     * (0 = success).
     */
    public function run(string $script, ?callable $onLine = null): int
    {
        $cb = $onLine === null ? null
            : function (string $line, $ctx) use ($onLine): void {
                // NEVER throw out of an FFI callback — fatal. Swallow here.
                try { $onLine($line); } catch (\Throwable) { /* ignore */ }
            };
        return $this->ffi->nlftp_run($this->h, $script, $cb, null);
    }

    // --- fluent convenience helpers (mapped to real setting names) ----------
    // The setting names mix ':' (namespace) and '-' (words), which don't chain
    // cleanly; these give an unambiguous typed API for the common knobs.

    public function timeout(int $sec): self        { return $this->set('net:timeout', $sec); }
    public function connectTimeout(int $sec): self  { return $this->set('net:connect-timeout', $sec); }
    public function maxRetries(int $n): self        { return $this->set('net:max-retries', $n); }
    public function limitRate(int $bytesPerSec): self { return $this->set('net:limit-rate', $bytesPerSec); }
    public function sslVerify(bool $on): self       { return $this->set('ssl:verify-certificate', $on); }
    public function sslProtectData(bool $on): self  { return $this->set('ftp:ssl-protect-data', $on); }

    public function close(): void
    {
        if (!$this->closed) {
            $this->ffi->nlftp_close($this->h);
            $this->closed = true;
        }
    }

    public function __destruct()
    {
        $this->close();
    }
}
