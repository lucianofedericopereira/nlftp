<?php

declare(strict_types=1);

/**
 * Reusable base for any Nim-backed FFI library.
 *
 * Subclass it, point it at your .so/.dylib + C declarations, and you get:
 *   - cross-platform library discovery (.dylib on macOS, .so elsewhere)
 *   - a single FFI handle
 *   - guaranteed one-time Nim runtime init (NimMain)
 *
 * Example:
 *
 *   final class Demo extends NimLib {
 *       protected function cdef(): string { return file_get_contents(__DIR__.'/../src/demo.h'); }
 *       protected function libBasename(): string { return 'libdemo'; }
 *       protected function initFn(): string { return 'demo_init'; }
 *       public function add(int $a, int $b): int { return $this->ffi->demo_add($a, $b); }
 *   }
 */
abstract class NimLib
{
    protected \FFI $ffi;

    private static array $instances = [];

    final protected function __construct()
    {
        $ext = PHP_OS_FAMILY === 'Darwin' ? 'dylib' : 'so';
        $lib = $this->libDir() . '/' . $this->libBasename() . '.' . $ext;

        if (!is_file($lib)) {
            throw new \RuntimeException("Nim library not built: {$lib} — run build.sh");
        }

        // Strip preload-only directives (#define FFI_SCOPE/FFI_LIB) that cdef()
        // rejects but FFI::load() requires, so one header serves both paths.
        $decls = preg_replace('/^\s*#define\s+FFI_\w+.*$/m', '', $this->cdef());

        $this->ffi = \FFI::cdef($decls, $lib);

        // Boot the Nim GC + module globals exactly once per process.
        ($this->ffi->{$this->initFn()})();
    }

    /** One shared instance per subclass per process (FPM worker). */
    final public static function instance(): static
    {
        return self::$instances[static::class] ??= new static();
    }

    /** C declarations (typically the contents of your .h file). */
    abstract protected function cdef(): string;

    /** Library filename without extension, e.g. "libnlftp". */
    abstract protected function libBasename(): string;

    /** Name of the exported init function that calls NimMain, e.g. "nlftp_init". */
    abstract protected function initFn(): string;

    /** Directory holding the built library. Override if yours lives elsewhere. */
    protected function libDir(): string
    {
        return dirname(__DIR__) . '/build';
    }
}
