# Nim → PHP extensions, via FFI

A small, **working, reusable** template for calling Nim code from PHP — built to
become `nlftp.so` (drive the nlftp engine in-process instead of shelling out to
the `lftp` binary), but generic enough for any future Nim → PHP bridge.

The demo here is verified end-to-end on this machine:

```
$ ./build.sh && php php/demo.php
demo_add(40, 2)      = 42
demo_echo(...)       = "nim says: hello from php"
demo_run(...)        = 3 commands
  callback: ran: open ftp://x
  callback: ran: cd /pub
  callback: ran: mirror . site

ALL PATTERNS WORK ✓
```

---

## Why FFI, not a Zend (`phpize`) extension

| | **FFI** (this template) | Zend extension |
|---|---|---|
| C glue to write | **none** | a `.c` per function + `config.m4` |
| Rebuild per PHP version | no (stable ABI) | yes (Zend ABI changes) |
| Distribution | ship one `.so` + a `.h` | compile against each PHP-dev |
| Speed | C-call overhead, negligible here | marginally faster |
| Best for | bulk ops (mirror, transfer) | hot per-call paths |

For a deploy tool that calls `mirror` a handful of times per run, FFI's
zero-glue, version-stable story wins outright. Keep Zend in your back pocket
only if you later need a polished, PECL-distributable package.

The pipeline both share:

```
   your .nim  ──nim c --app:lib──►  libfoo.so   ──C ABI──►  PHP FFI  ──►  Laravel
  (Nim engine)                    (shared lib)            (this README)
```

---

## How the FFI layer works

**FFI** (Foreign Function Interface) lets PHP call functions in a precompiled
shared library *directly*, by declaring their C signatures — no C extension to
write, no recompile per PHP version. PHP's `ext-ffi` does the `dlopen`, looks up
each symbol, and converts arguments to/from C types at the call site.

The thing to internalize: **this is not a subprocess.** Today's
`new Process(['lftp', …])` forks a *separate program* and talks to it over pipes —
every value is serialized to bytes, written, read, and re-parsed. FFI instead
loads the Nim engine **into the PHP process** and calls it like any C function:
a jump to machine code in the **same address space, same thread**. No fork, no
pipe, no serialization. That single fact is *why* a callback can hand PHP a ready
string, *why* settings can live on a handle between calls, and *why* you must be
careful about who owns memory — there's only one address space now, shared.

```
  PHP process
  ┌─────────────────────────────────────────────────────────────────┐
  │  PHP code ──$ffi->nlftp_set($h,"net:timeout","5")               │
  │      │  (ext-ffi marshals args to C types, jumps to the symbol) │
  │      ▼                                                          │
  │  libnlftp.so  ── nlftp_set(pointer, cstring, cstring): cint     │
  │      │  (plain C call — same stack, same heap, Nim's GC)        │
  │      ▼                                                          │
  │  the real CmdExec engine  ──►  returns cint  ──►  back to PHP   │
  └─────────────────────────────────────────────────────────────────┘
   one OS process · one thread · no IPC · no serialization
```

### The contract is the C ABI — both sides must match exactly

The two sides never see each other's source; they agree only on each function's
**name, argument types, and return type** — its C **A**pplication **B**inary
**I**nterface. A mismatch isn't a compile error, it's undefined behavior at call
time (a wrong arg width silently corrupts the stack). So the signatures are the
single source of truth, copied verbatim on both sides:

| Nim side (`src/nlftp_ffi.nim`) | PHP side (`FFI::cdef` / `nlftp.h`) |
|---|---|
| `proc nlftp_set(h: pointer; name, value: cstring): cint` | `int nlftp_set(void *h, const char *name, const char *value);` |
| `{.exportc.}` — emit the **C name**, no Nim mangling | the literal symbol PHP looks up |
| `{.cdecl.}` — the **C calling convention** | how PHP pushes the args |
| `{.dynlib.}` — **export** the symbol from the `.so` | what `dlopen` can find |

That's the whole reason for the `{.exportc, cdecl, dynlib.}` stamp on every
exported proc: it makes a Nim proc look, link, and call exactly like a C one.

### Only C types cross — everything else needs a pattern

The boundary speaks **C, and nothing else**. A C function can't receive a PHP
array or return a Nim `ref object`. So each kind of data needs a known technique
for getting across — and *that* is what the rest of this document is: a catalog
of the handful of techniques you'll ever need.

| What you want to pass | What actually crosses | Technique |
|---|---|---|
| a number / bool | the value itself | pattern **2** (free) |
| text | `const char *` (a pointer) | pattern **3** (+ who frees) |
| "call me back" | a C function pointer | pattern **4** (callbacks) |
| a whole stateful object | an **opaque pointer** (handle) | pattern **5** (sessions) |

### Two runtimes, one address space

The Nim library carries its **own garbage collector**. `NimMain()` boots it once
(pattern 1); after that, Nim objects live in the shared address space but are
owned by **Nim's** GC — PHP's GC must never touch them, and vice versa. This is
the root of two rules you'll see repeated: a string returned to PHP is a heap
copy *PHP hands back* to be freed (pattern 3), and a Nim object kept alive across
calls must be **pinned** so the GC won't reclaim it while PHP holds the pointer
(`GC_ref`, pattern 5). Cross the memory-ownership line in either direction and
you get a use-after-free or a leak — no exception, just corruption.

With that model in hand, the patterns below are short.

---

## The marshaling patterns (everything else is a variation)

Any bridge reduces to these five. The first four are stateless one-shots that
`src/demo.nim` implements in ~5 lines each; the fifth (handles) is what makes a
*stateful* engine like nlftp embeddable. The real engine just swaps the bodies.

### 1. Runtime init — boot Nim's GC exactly once

Nim needs `NimMain()` called before any other proc (it initializes the GC and
module-level globals). `--app:lib` emits it; we forward-declare it and wrap it
in an explicit init the host calls once:

```nim
proc NimMain() {.importc, cdecl.}
proc demo_init() {.exportc, cdecl, dynlib.} = NimMain()
```

```php
$ffi->demo_init();   // once per process, before anything else
```

> **Pitfall:** don't self-guard with a Nim `bool` global — `NimMain` *re-runs*
> module init and would reset it. Make the host call init once instead. The
> `NimLib` base class does this for you (one instance per FPM worker).

### 2. Scalars — free, no marshaling

```nim
proc demo_add(a, b: cint): cint {.exportc, cdecl, dynlib.} = a + b
```
`cint`/`cfloat`/`cdouble`/`bool` pass straight through. Use the `c*` types so
widths match C.

### 3. Strings — who allocates, who frees

Returning a Nim `string`'s `.cstring` is a use-after-free waiting to happen (the
GC owns it). Return a **heap copy the caller frees**, and export the matching
free:

```nim
proc demo_echo(input: cstring): cstring {.exportc, cdecl, dynlib.} =
  let s = "nim says: " & $input
  result = cast[cstring](alloc0(s.len + 1))
  copyMem(result, s.cstring, s.len)

proc demo_free(p: cstring) {.exportc, cdecl, dynlib.} =
  if p != nil: dealloc(p)
```

```php
$ptr = $ffi->demo_echo("hello");
$str = FFI::string($ptr);   // copy into a PHP string
$ffi->demo_free($ptr);      // hand the pointer back — NEVER let PHP GC it
```

**Rule:** memory crosses the boundary as a borrow. Whoever `alloc`s, `free`s.
Inbound `const char *` is fine to read directly (`$input` above) — PHP owns it.

### 4. Callbacks — Nim streams progress back into PHP

A C function pointer PHP fills with a closure. This is how transfer progress
gets out without parsing stdout:

```nim
type LogCb = proc (line: cstring, ctx: pointer) {.cdecl.}
proc demo_run(script: cstring, cb: LogCb, ctx: pointer): cint {.exportc,cdecl,dynlib.} =
  ...
  cb(msg.cstring, ctx)   # fires once per line
```

```php
$cb = function (string $line, $ctx): void {   // <- already a PHP string!
    echo "progress: $line\n";
};
$ffi->demo_run($script, $cb, null);
```

> **Two gotchas we hit and fixed (so you don't):**
> - FFI **auto-marshals** the `const char *` callback arg to a PHP `string`.
>   Do **not** call `FFI::string()` on it — it's already a string.
> - **Never throw** out of an FFI callback (`Throwing from FFI callbacks is not
>   allowed` → fatal). Catch inside the closure; signal errors via return value
>   or `$ctx`.

### 5. Handles — a stateful object that outlives one call

The four patterns above are stateless: each call stands alone. But a real engine
has *state* — settings, an open connection, a current directory — that the host
wants to configure once and reuse across calls. You can't return a Nim `ref`
to C (the GC would move/collect it), so you return it as an **opaque handle**
(`void*`) and pin it so the GC leaves it alone until you say so:

```nim
proc nlftp_open(): pointer {.exportc, cdecl, dynlib.} =
  let x = newCmdExec()      # the stateful engine object (a Nim ref)
  GC_ref(x)                 # pin it: ORC won't collect while PHP holds the ptr
  cast[pointer](x)

proc nlftp_set(h: pointer; name, value: cstring): cint {.exportc,cdecl,dynlib.} =
  if h == nil: return 1
  let x = cast[CmdExec](h)  # recover the ref from the handle
  try: (x.settings.set($name, $value); 0) except CatchableError: 1

proc nlftp_close(h: pointer) {.exportc, cdecl, dynlib.} =
  if h != nil: GC_unref(cast[CmdExec](h))   # release the pin → GC can reclaim
```

PHP holds that `void*` inside a wrapper object and threads it through every call:

```php
$this->h = $ffi->nlftp_open();
$ffi->nlftp_set($this->h, 'net:connect-timeout', '5');   // mutates THIS session
// ... later, same handle ...
$ffi->nlftp_run($this->h, $script, $cb, null);           // sees that setting
$ffi->nlftp_close($this->h);                             // in __destruct()
```

> **Pitfalls:**
> - **`GC_ref`/`GC_unref` must balance** — miss the `unref` and the engine leaks
>   for the process's life; `unref` twice and you free live memory. One `open`,
>   one `close`; drive `close` from PHP's `__destruct`.
> - **Don't hand out a raw `addr` of a local** — only a `GC_ref`'d ref survives
>   the return. The handle is a borrow the *Nim* side owns until `close`.
> - **`cast[CmdExec](h)` trusts the caller.** A wrong/freed pointer is undefined
>   behavior; the `nil` guard is the cheap half of the defense — keep the handle
>   private inside the wrapper so PHP can't fabricate one.

This is what turns "run a script" into a **programmatic API**: because settings
live on the handle, the host sets them with plain method calls instead of
splicing `set …` lines into a script string (see the next section).

---

## Programmatic settings — no script string required

With the handle API, `php/Nlftp.php` exposes the engine's settings as ordinary
PHP calls. Settings persist on the session, so they apply to every later `run()`:

```php
$nlftp = new Nlftp();
$nlftp->set('net:connect-timeout', 5)      // any setting by name…
      ->set('net:max-retries', 3)
      ->connectTimeout(7);                  // …or a typed fluent helper
echo $nlftp->get('net:connect-timeout');    // "7" — read back from the live session
$nlftp->run("open ftps://host/\nmirror -R ./local /remote",
            fn(string $line) => print("$line\n"));
```

Why a `set('net:connect-timeout', 5)` string-key API and not a fluent
`$nlftp->net->connectTimeout = 5`? lftp's setting names mix **two** separators —
`:` for namespace, `-` for words (`net:connect-timeout`, `ftp:ssl-protect-data`,
`mirror:parallel-transfer-count`) — so a `->net->connect->timeout` chain can't
tell which separator goes where without a lookup table. The string key is exact
and forwards 1:1 to the engine's `set` command; the typed helpers
(`connectTimeout()`, `maxRetries()`, `sslVerify()`, …) cover the common knobs
with autocompletion. Both end up calling the same `nlftp_set`.

`get()` returns a heap copy from Nim (pattern 3) and frees it for you. Invalid
names/values make `nlftp_set` return non-zero → `set()` throws, so a typo fails
loudly instead of silently doing nothing.

**Two ways to drive the engine, pick per call site:**

| | `nlftp_run_script($script)` (stateless) | `Nlftp` session (handle) |
|---|---|---|
| State across calls | none (fresh engine each call) | settings/bookmarks/cwd persist |
| Set options | `set …` lines inside the script | `->set()` / typed helpers |
| Best for | "run this `lftp -f` script as-is" | configure once, run repeatedly |
| Lifecycle | none | `new Nlftp()` … `__destruct` closes |

---

## The cardinal rule: a library must not own stdout

This is the one change that separates "a CLI you shell out to" from "a library you
embed", and it's the part people miss. **An embeddable library may never write to
`stdout`/`stderr` directly.** The moment your Nim code calls `echo`, that text goes
to the host *process's* terminal — not to your PHP caller, who has no pipe to read.
The patterns above move data across the boundary; this rule is about making
sure your code *produces* its output as data in the first place.

The demo was born right (it returns strings / fires callbacks). A real program
like nlftp was **not** — it was a CLI, so it printed everywhere. Converting it
meant replacing every direct write with an **injectable sink**: a nil-able
callback the host can point wherever it wants. Default `nil` = behave exactly
like the old CLI (write to the terminal); set it = capture.

**Before** (CLI-only — output is unreachable from a library host):

```nim
echo "mirror done: ", n, " files"        # straight to the process terminal
stderr.writeLine("failed: " & path)      # ditto
```

**After** (embeddable — output is whatever the host wants):

```nim
type OutSink* = proc(s: string) {.gcsafe, raises: [].}   # the injection point

type CmdExec = ref object
  outSink*, errSink*: OutSink            # nil by default

proc emit*(x: CmdExec; s: string) {.gcsafe, raises: [].} =
  if x.outSink != nil: x.outSink(s)
  else: (try: stdout.writeLine(s) except CatchableError: discard)

# call sites change mechanically: `echo X`  ->  `x.emit X`
x.emit "mirror done: " & $n & " files"
x.emitErr("failed: " & path)
```

The FFI wrapper then points the sink at the PHP callback — and per-line streaming
falls out for free, no stdout redirection, no buffering:

```nim
x.outSink = proc(s: string) = cb(s.cstring, ctx)   # -> PHP closure
```

**Three things that bite you on a real codebase:**

- **The effect contract.** Type the sink `{.gcsafe, raises: [].}`. A bare
  `proc(s: string)` defaults to `raises: [Exception]`; calling that inside an
  `async`/threaded proc makes the compiler reject it (`Exception can raise an
  unlisted exception`). Non-raising + gcsafe means invoking the sink adds *no*
  effects to its callers — so you can drop it into hot async paths untouched.
- **Output must never crash the work.** Make `emit` swallow I/O errors (the
  `try/except … discard` above). A broken pipe on a status line should not abort
  a 10 GB transfer. That's also what lets the helper *be* `raises: []`.
- **Procs without the context object.** Free procs (`printLong`) and worker procs
  in other modules (`mirror.nim`) can't see `x`. Give them the sink another way:
  thread `x` in as a parameter, or add a sink field to the options object they
  already receive (nlftp's `MirrorOpts.log`). Don't reach back to a global.

Mechanically it's a find-and-replace (`echo ` → `x.emit `), but do it through the
compiler, not blind: the value of `x` in scope at each call site is exactly what a
paper spec gets wrong. In nlftp this was ~35 call sites across two files; the test
suite (`nimble test`) stayed green throughout because the `nil`-default keeps CLI
behavior byte-for-byte identical.

---

## Build & run

```bash
./build.sh                 # builds build/libdemo.{dylib,so}
php -d ffi.enable=1 php/demo.php
```

`build.sh` flags that matter:

- `--app:lib` — emit a shared library (+ callable `NimMain`)
- `--mm:orc` — deterministic single-threaded memory management (matches nlftp's
  single-threaded chronos model)
- `--noMain:on` — we drive init via `NimMain`, no C `main()`
- `--tlsEmulation:off` — real TLS; avoids macOS dylib thread-local quirks

---

## Production wiring (Laravel / PHP-FPM)

1. **Enable FFI.** `ffi.enable=1` in `php.ini` (or `preload` mode — see below).
   Shared hosting often disables it; check `php -m | grep FFI`.

2. **Preload the binding** for speed. Instead of re-parsing decls every request
   (`FFI::cdef`), put `#define FFI_SCOPE`/`FFI_LIB` in a `.h` (see `src/demo.h`),
   preload it once, and fetch by scope per request:

   ```ini
   ; php.ini
   ffi.preload=/path/to/php-ext/src/demo.h
   opcache.preload=/path/to/preload.php   ; calls FFI::load() on the header
   ```
   ```php
   $ffi = FFI::scope("DEMO");   // no re-parse, no re-dlopen
   ```

3. **One instance per worker.** Init the Nim runtime once; reuse the handle.
   `php/NimLib.php` is a ready base that handles discovery + one-time init —
   subclass it (see its docblock).

4. **Ship the right binary.** The lib is platform-specific: build `.so` on your
   Linux deploy target in CI, not the `.dylib` from your Mac. The `.h`'s
   `FFI_LIB` line is likewise per-platform.

---

## From demo to `nlftp.so`

`src/nlftp_ffi.nim` is the skeleton — same patterns, bodies now call the
real `shell/cmdexec` engine (`newCmdExec` / `execLine` / `waitAllJobs`). It
feeds nlftp **the exact script your PHP already builds for `lftp -f`**, so the
deploy command barely changes:

```php
// today:        new Process(['lftp', '-f', $scriptPath])->run();
// drop-in:      (new Nlftp())->run($script, $onProgress);          // same script
// or, native:   (new Nlftp())->connectTimeout(5)->maxRetries(3)    // no script
//                            ->run("open ftps://…\nmirror -R …", $onProgress);
```

**Output capture — done (Option B, the clean one).** The engine no longer
writes to stdout directly: `CmdExec` now carries nil-able `OutSink` fields
(`outSink`/`rawSink`/`errSink`) and every `echo` was replaced with `x.emit` /
`x.emitRaw` / `x.emitErr`. `jobs/mirror.nim` got matching `MirrorLog` sinks for
per-file progress. The sinks are typed `{.gcsafe, raises: [].}` so they can be
called from async workers without widening effects, and they're nil by default
— the CLI's terminal output is byte-for-byte unchanged.

That means `nlftp_run_script` gets **true per-line streaming** for free: it just
points the sinks at the PHP callback (see `src/nlftp_ffi.nim`). No stdout
redirection, no whole-run buffering.

**Built and verified.** `src/nlftp_ffi.nim` compiles against the engine and runs
end-to-end from PHP:

```bash
./build.sh src/nlftp_ffi.nim nlftp   # -> build/libnlftp.{so,dylib}
php php/nlftp_smoke.php               # drives the real engine in-process
```
```
engine output (streamed via callback):
  | === nlftp running in-process ===     (echo)
  | nlftp 0.0.1 (port of lftp 4.9.3)     (version)
  | /Users/.../php-ext                   (lpwd)
  | net:timeout = 300                    (set query)
exit status = 0  ->  IN-PROCESS ENGINE WORKS ✓
```

Two wrapper-specific notes baked into `src/nlftp_ffi.nim`:
- Annotate each exported proc with `{.exportc, cdecl, dynlib.}` **individually** —
  a `{.push.}` block leaks `dynlib` onto the inner sink closures, which fails
  with `.dynlib requires .exportc` (closures can't be dynlib-exported).
- The `LogCb` type and the sink closures are `{.gcsafe, raises: [].}` so they
  satisfy the engine's `OutSink` contract and never widen async effects.

### ⚠️ License — read before linking into your app

nlftp is **GPLv3** (derivative of lftp). Running it as a *separate binary*
(today's `Process` call) is arm's-length aggregation — your Laravel app stays
unaffected. **Linking it in-process via FFI makes a combined work**, which pulls
your deploy tooling under the GPL. For a commercial shop that's a deliberate
licensing choice, not a detail. If that's unwanted, the lowest-risk win is to
keep the process boundary but swap the `lftp` binary for an `nlftp` binary you
build from this repo — no GPL entanglement, no FFI, ~1 day of work.

---

## Reuse checklist (any future Nim → PHP lib)

1. **If you're wrapping an existing CLI, do the sink pass first** (see "The
   cardinal rule" above): every `echo`/`stdout`/`stderr` becomes a nil-able
   `{.gcsafe, raises: [].}` sink, defaulting to terminal so the CLI is unchanged.
   A library that prints can't be embedded.
2. Write `src/yourlib.nim`: an `*_init` that calls `NimMain`, your exported procs
   using the patterns above. Annotate each `{.exportc, cdecl, dynlib.}`
   **individually** — a `{.push.}` block leaks `dynlib` onto inner closures.
3. Write `src/yourlib.h` mirroring the signatures (+ `FFI_SCOPE`/`FFI_LIB`).
4. `./build.sh src/yourlib.nim yourlib`
5. Subclass `NimLib` in `php/`, expose typed methods.
6. Remember: caller frees returned strings; never throw from callbacks; init once.

## Files

| File | Role |
|---|---|
| `src/demo.nim` | the four patterns, minimal & working |
| `src/demo.h` | C ABI (doubles as the `FFI::load` production header) |
| `src/nlftp_ffi.nim` | the real `nlftp.so` wrapper — stateless `run_script` + the `open/set/get/run/close` session API, streams via sinks |
| `src/nlftp.h` | C ABI (doubles as the `FFI::load` production header) |
| `build.sh` | `nim c --app:lib` → `build/lib*.{so,dylib}` |
| `php/demo.php` | end-to-end test of the four patterns (run this first) |
| `php/nlftp_smoke.php` | end-to-end test of the stateless engine in-process |
| `php/Nlftp.php` | typed wrapper over the session API (`set()`/`get()`/`run()` + fluent helpers) |
| `php/nlftp_session.php` | end-to-end test of the session API (programmatic settings) |
| `php/NimLib.php` | reusable FFI loader base (discovery + one-time init) |
