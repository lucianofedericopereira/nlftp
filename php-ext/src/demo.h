/*
 * demo.h — C ABI for the demo Nim library.
 *
 * Two ways PHP can consume this:
 *
 *   1. Inline (what php/demo.php does):  FFI::cdef("<these decls>", "libdemo.so")
 *      Simple, cross-platform, but re-parses the decls on every request.
 *
 *   2. Preloaded (production):           FFI::load(__DIR__."/demo.h")  then
 *      FFI::scope("DEMO") in each request. Parsed once at PHP startup via
 *      opcache.preload — the fast path for Laravel/FPM. Requires the two
 *      #define lines below.
 *
 * FFI_LIB is platform-specific (.so on Linux, .dylib on macOS). Commit the
 * one matching your *deploy* target (Linux .so), or template it per-host.
 */

#define FFI_SCOPE "DEMO"
#define FFI_LIB   "./build/libdemo.so"

void  demo_init(void);
int   demo_add(int a, int b);
char *demo_echo(const char *input);
void  demo_free(char *p);

typedef void (*demo_log_cb)(const char *line, void *ctx);
int   demo_run(const char *script, demo_log_cb cb, void *ctx);
