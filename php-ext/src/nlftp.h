/*
 * nlftp.h — C ABI for the real nlftp Nim library.
 *
 * Two ways PHP can consume this:
 *
 *   1. Inline (what php/Nlftp.php + the test scripts do):
 *      FFI::cdef("<these decls>", "libnlftp.so")
 *      Simple, cross-platform, but re-parses the decls on every request.
 *
 *   2. Preloaded (production):  FFI::load(__DIR__."/nlftp.h") at startup, then
 *      FFI::scope("NLFTP") per request. Parsed once via opcache.preload — the
 *      fast path for Laravel/FPM. Requires the two #define lines below.
 *
 * FFI_LIB is platform-specific (.so on Linux, .dylib on macOS). Commit the one
 * matching your *deploy* target (Linux .so), or template it per-host.
 */

#define FFI_SCOPE "NLFTP"
#define FFI_LIB   "./build/libnlftp.so"

/* runtime init — call once per process before anything else */
void  nlftp_init(void);

/* stateless one-shot: run a full nlftp script on a throwaway engine */
typedef void (*nlftp_log_cb)(const char *line, void *ctx);
int   nlftp_run_script(const char *script, nlftp_log_cb cb, void *ctx);

/* persistent session: one handle holds settings/bookmarks/cwd across calls */
void *nlftp_open(void);
int   nlftp_set(void *h, const char *name, const char *value);  /* 0 = ok */
char *nlftp_get(void *h, const char *name);                     /* free via nlftp_free */
void  nlftp_free(char *p);
int   nlftp_run(void *h, const char *script, nlftp_log_cb cb, void *ctx);
void  nlftp_close(void *h);
