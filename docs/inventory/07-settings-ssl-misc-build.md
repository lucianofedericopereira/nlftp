# Inventory 08 — Settings, TLS, Output, Logging, Misc, Entry Point & Build/Portability

Scope: the configuration subsystem (`ResMgr`/`resource`), the TLS abstraction
(`lftp_ssl` + `buffer_ssl`), zlib transfer compression (`buffer_zlib`), dynamic
module loading (`module`), logging (`log`/`ProtoLog`), the misc utility grab-bag
(`misc`), the program entry point (`lftp.cc`), terminfo (`lftp_tinfo`), the
status line / output job / filter / pattern-set helpers (`StatusLine`,
`OutputJob`, `Filter`, `PatternSet`), and the whole **build & portability story**
(`configure.ac`, `src/Makefile.am`, `lib/` gnulib, `trio/`).

lftp source is C++ (no exceptions, no RTTI — see `-fno-exceptions -fno-rtti` in
`configure.ac`). The target port is **Nim using `chronos`** for async I/O. A
recurring theme below: most of this subsystem is *portability shimming* (gnulib,
trio, terminfo probing, autoconf feature tests) that **disappears entirely** in
a Nim rewrite, because Nim's stdlib + chronos + a handful of thin C wrappers
cover the same ground natively.

---

## ResMgr + resource — the settings subsystem

- **Files & LOC**: `ResMgr.cc` (984), `ResMgr.h` (250), `resource.cc` (501),
  plus the table fragments registered from other modules. Total ~1735 LOC.
- **Purpose**: lftp's entire runtime configuration store. Every tunable
  (`net:timeout`, `ftp:passive-mode`, `ssl:verify-certificate`, `mirror:...`,
  `color:dir-colors`, …) is a *resource* identified by a `"prefix:name"` string
  and queried with an optional **closure** (a per-host / per-context qualifier,
  e.g. `ssl:verify-certificate` keyed on hostname or cert fingerprint).
- **Key classes/types**:
  - `struct ResType` — one row of the settings *schema*: `name`, `defvalue`,
    `val_valid` (a `ResValValid` validator fn-ptr), `closure_valid`
    (`ResClValid`). Holds the global `xmap<ResType*> types_by_name` registry and
    the lookup/format/generator machinery (`FindVar`, `VarNameCmp` does
    prefix/substring abbreviation matching, `Format`, `Generator`).
  - `class Resource` — one *set value*: a (`type`, `closure`, `value`, `def`)
    tuple. Lives on two intrusive `xlist`s (`all_list`, and a per-type list).
  - `class ResMgr : public ResType` — static façade: `Query`, `QueryBool`,
    `QueryTriBool`, `QueryNext`, plus the whole library of **validators**
    (`BoolValidate`, `NumberValidate`, `FloatValidate`, `TimeIntervalValidate`,
    `RangeValidate`, `ERegExpValidate`, `IPv4AddrValidate`, `IPv6AddrValidate`,
    `CharsetValidate`, `FileReadable`/`DirReadable`/`FileExecutable`/
    `FileCreatable`, `AliasValidate`, `NoClosure`/`HasClosure`).
  - `class ResDecl : public ResType` / `class ResDecls` — registration helpers.
    A `static ResType foo[]` array + a `static ResDecls foo_register(foo)` at
    file scope registers a batch of settings at static-init time. Individual
    `ResDecl x("cmd:save-cwd-history","yes",…)` objects register single
    settings (e.g. in `lftp.cc`).
  - `class ResValue` — a typed view over the stored string (`to_bool`,
    `to_number`, `operator int/long/double`, `ToNumberPair`).
  - `class ResClient` — base class for objects that want `Reconfig(name)`
    callbacks when a setting changes; `ResClient::ReconfigAll` fans out.
    `Log`, `ProtoLog::Tags`, the SSL instances, etc. derive from it.
  - Value parsers: `TimeIntervalR` (extends `TimeInterval`), `NumberPair`,
    `Range`.
- **How settings are defined/stored/validated**:
  - **Defined** declaratively as table rows
    `{"prefix:name","default",ValidatorFn,ClosureValidatorFn}`. The bulk live in
    `resource.cc` in one array `lftp_vars[]`; protocol/job modules add their own
    arrays (see counts below).
  - **Stored** as `Resource` objects in intrusive linked lists, indexed via
    `xmap`. There is no DB — it's an in-memory list keyed by (type, closure).
  - **Validated** at *set* time by calling the validator fn-ptr, which may
    canonicalize the value (rewrite in place via `xstring_c*`) or return an
    error string. `ClassInit` also re-validates every default at startup and
    warns if a default is non-canonical.
  - **Environment seeding**: `ResType::ClassInit` imports `http_proxy`,
    `ftp_proxy`, `no_proxy`, `LFTP_MODULE_PATH`, `LS_COLORS`, `TIME_STYLE`,
    locale charset into the corresponding settings.
- **How many settings exist**: the main `resource.cc` table `lftp_vars[]` has
  **199 rows**. Additional settings are registered from other modules:
  `CmdExec.cc` (29), `Torrent.cc` (18), `log.cc` (11), plus ~26 standalone
  `ResDecl` declarations scattered across the tree (e.g. `lftp.cc`). **Roughly
  ~280 settings total**, ~199 of which belong to this inventory's `resource.cc`.
- **External C-library deps**: none directly (validators lean on `regex` from
  gnulib and `localcharset`/iconv for `CharsetValidate`).
- **Internal deps**: `xstring`/`xstring_c`, `xmap`, `xlist`, `xarray`,
  `TimeDate`, `url` (for proxy validators), `GetPass`, `misc`.
- **Nim mapping**:
  - Define settings as a compile-time `seq`/`array` of a `ResType` object/tuple
    `(name, default, validator, closureValidator)` — direct translation of the
    table. Validators become `proc(value: var string): string` (returns error or
    "").
  - Storage: a `Table[string, seq[Resource]]` (closure-keyed) instead of the
    intrusive `xlist`/`xmap`. Nim's `tables` + `seq` replace all the custom
    container code.
  - `ResValue` → either a `distinct string` with conversion procs, or just parse
    on demand. `ResClient.Reconfig` → an observer/callback list (a `seq[proc]`)
    or chronos `AsyncEvent`.
  - The abbreviation matcher `VarNameCmp` can be ported verbatim (pure string
    logic).
- **Port complexity**: **Medium.** The data model is simple but there is a lot
  of surface area (every validator, the abbreviation matcher, closure matching,
  alias resolution, formatting/generation for the `set` command and tab
  completion). The 199-row table is mechanical but tedious to transcribe.
- **Gotchas**:
  - Closure semantics (per-host overrides, fingerprint-keyed cert trust) are
    load-bearing and easy to under-port. `set_cert_error` in `lftp_ssl.cc`
    queries `ssl:verify-certificate` keyed on hostname *and then* on the cert's
    hex fingerprint — that pattern must survive.
  - Static-initialization registration order: in C++ these register via global
    ctors. In Nim, register explicitly at module init.
  - `AliasValidate` settings (e.g. `xfer:log` → `log:enabled/xfer`) are
    indirections, not values — alias resolution happens in `FindVar`.
  - Abbreviated/ambiguous variable names produce specific user-facing errors
    ("ambiguous variable name") that the `set` UX depends on.

---

## lftp_ssl + buffer_ssl — the TLS abstraction (CRITICAL)

- **Files & LOC**: `lftp_ssl.cc` (1547), `lftp_ssl.h` (155), `buffer_ssl.cc`
  (125), `buffer_ssl.h` (49). Total ~1876 LOC.
- **Purpose**: lftp's TLS layer for FTPS/HTTPS/FISH-over-TLS. Provides a uniform
  non-blocking `lftp_ssl` object that wraps **either GnuTLS or OpenSSL**, chosen
  at compile time. `buffer_ssl` bolts that object onto lftp's async `IOBuffer`
  state machine.

### How the OpenSSL-vs-GnuTLS abstraction works
The abstraction is **compile-time polymorphism via a typedef**, not a vtable:
- A backend-neutral base `lftp_ssl_base` holds the shared state: `fd`,
  `hostname`, `handshake_mode` (CLIENT/SERVER), `error`/`fatal`/`cert_error`
  flags, `handshake_done`/`goodbye_done`, and the `enum code { RETRY=-2,
  ERROR=-1, DONE=0 }` used to drive the non-blocking loop. It also owns the
  policy methods `set_error` and `set_cert_error` (the latter encapsulates the
  `ssl:verify-certificate` closure logic and SHA-1 fingerprint formatting).
- Two concrete subclasses implement the *same method surface*:
  `read`, `write`, `want_in`, `want_out`, `do_handshake`, `shutdown`,
  `copy_sid` (session resumption), `load_keys`, `check_fatal`, `get_fp`
  (fingerprint), plus `static global_init`/`global_deinit`.
  - `lftp_ssl_gnutls` (+ `lftp_ssl_gnutls_instance`)
  - `lftp_ssl_openssl` (+ `lftp_ssl_openssl_instance`)
- The header ends with `typedef lftp_ssl_gnutls lftp_ssl;` **or**
  `typedef lftp_ssl_openssl lftp_ssl;` under `#if USE_GNUTLS / #elif
  USE_OPENSSL`. The rest of lftp only ever names `lftp_ssl`. So there is **no
  runtime backend selection** — you build one or the other. (`configure.ac`
  defaults to GnuTLS; OpenSSL is opt-in and forces GnuTLS off.)
- A per-process **instance/context** object (`*_instance`) holds the expensive
  global state: the loaded CA list / CRL list (GnuTLS) or the `SSL_CTX` +
  CRL `X509_STORE` (OpenSSL). It is a `ResClient`, so changing `ssl:ca-file` /
  `ssl:crl-file` triggers `Reconfig` → reload. Held in a `static Ref<>` and
  lazily created on first use.

### Certificate verification
- **GnuTLS path** (`verify_certificate_chain`): import leaf cert →
  `gnutls_certificate_verify_peers2` → if status != 0, render the reason via
  `gnutls_certificate_verification_status_print` → then `ssl:check-hostname`
  gate calls `gnutls_x509_crt_check_hostname`. CA/CRL lists are loaded once into
  the instance (`LoadCA`/`LoadCRL` via `mmap_file`) and attached per-session in
  `load_keys`.
- **OpenSSL path**: verification is split between a `verify_callback` registered
  on the `SSL_CTX` (logs the chain, runs `verify_crl` for explicit CRL checking
  — code adapted from Ralf Engelschall / mod_ssl), and `check_certificate()`
  run after a successful `SSL_connect`. Hostname checking is a **vendored copy
  of curl's `hostmatch`/`cert_hostcheck`** (RFC 6125 wildcard matching over
  subjectAltName dNSName/iPAddress, falling back to CN), plus a UTF-8
  round-trip sanity check (`convert_from_utf8`). CA discovery falls back through
  a hard-coded list of distro `ca-bundle.crt` paths (`lftp_ssl_find_ca_file`,
  GnuTLS side) or `SSL_CTX_set_default_verify_paths` (OpenSSL).
- Both backends derive a **SHA-1 fingerprint** (`get_fp`) used to key
  per-cert trust overrides through `ssl:verify-certificate`.
- Verification is advisory unless `ssl:verify-certificate` is true: on failure
  it logs `WARNING` and continues, or logs `ERROR` + sets `fatal`/`cert_error`.

### Session handling & non-blocking integration
- `do_handshake` is re-entrant and returns `RETRY` on `WANT_READ/WANT_WRITE`
  (GnuTLS `E_AGAIN`/`E_INTERRUPTED`, OpenSSL `BIO_sock_should_retry` /
  `SSL_want_x509_lookup`). `want_in`/`want_out` expose the desired poll
  direction. `read`/`write` first pump the handshake, then do record I/O,
  mapping truncation/`PREMATURE_TERMINATION` to EOF.
- `copy_sid` copies session data for **session resumption** across reconnects
  (`gnutls_session_get_data`/`set_data`; `SSL_copy_session_id`).
- `shutdown` does a graceful close-notify (`gnutls_bye` / `SSL_shutdown`) with a
  Windows-tolerant early-exit.
- **`buffer_ssl` (`IOBufferSSL`)** is the glue to lftp's reactor: it holds a
  `Ref<lftp_ssl>`, computes a poll `want_mask()` from `ssl->want_in/out`, and in
  `Do()` drives `Get_LL`/`Put_LL`/`PutEOF_LL` against the ssl object's
  `read`/`write`/`shutdown`, translating `RETRY`/`ERROR`/`DONE`.
- Lots of `#if OPENSSL_VERSION_NUMBER < …` / LibreSSL shims for API churn
  (X509_OBJECT accessors, `SSLeay_add_ssl_algorithms`, ticket flags, etc.).

- **External C-library deps**: **GnuTLS** (`gnutls`, `gnutls/x509`) *or*
  **OpenSSL** (`libssl` + `libcrypto`: `ssl.h`, `err.h`, `rand.h`, `x509v3.h`,
  `x509_vfy.h`). Also `sha1.h` (gnulib crypto/sha1), `mmap`, and lftp's iconv
  buffer for the UTF-8 check.
- **Internal deps**: `ResMgr` (heavily — all policy is settings-driven), `Log`,
  `misc` (`temporary_network_error`), `network` (`sockaddr_u`), `buffer`
  (`DirectedBuffer` for charset), `Ref`, `xstring`.
- **Nim mapping & TLS recommendation** — see the dedicated discussion in
  **External dependencies** below. Short version: **target chronos's
  bearssl-backed TLS for the common path** and keep a thin OpenSSL wrapper
  available for CRL / legacy-server scenarios.
- **Port complexity**: **High** — this is the single most complex file in the
  subsystem. The non-blocking handshake state machine and cert-verification
  policy must be reproduced exactly; the curl-derived hostname matcher and the
  CRL logic are subtle.
- **Gotchas**:
  - The two backends are **not feature-equivalent**: only the GnuTLS instance
    actively manages a CRL *list*, while OpenSSL has the full
    `verify_crl`/`X509_STORE` path. Hostname checking is native in GnuTLS but
    hand-rolled (curl code) in OpenSSL. A Nim port should pick *one* semantics
    and implement it once.
  - SNI is gated on `ssl:use-sni`; priority strings (`ssl:priority`) are
    GnuTLS-native and *emulated* for OpenSSL by translating `-VERS-TLS1.x`
    tokens into `SSL_OP_NO_*` flags — don't lose that translation if you keep an
    OpenSSL path.
  - Session resumption (`copy_sid`) is relied on for FTP data connections that
    reuse the control connection's TLS session — a correctness/interop issue,
    not just an optimization.
  - `set_cert_error`'s double query of `ssl:verify-certificate` (hostname then
    fingerprint) is the user-facing "trust this cert" mechanism.

---

## buffer_zlib — transfer compression

- **Files & LOC**: `buffer_zlib.cc` (178), `buffer_zlib.h` (51).
- **Purpose**: streaming inflate/deflate `DataTranslator`s plugged into lftp's
  `Buffer` chain — used for FTP `MODE Z` (`ftp:mode-z-level`) and HTTP gzip
  content.
- **Key classes/types**: `DataInflator` and `DataDeflator`, each wrapping a
  `z_stream`; `PutTranslated(dst,buf,size)` runs `inflate`/`deflate` in a loop,
  growing the output buffer, handling `Z_STREAM_END` (treat trailing bytes as
  uncompressed) and `Z_NEED_DICT`/error reporting via `Buffer::SetError`.
- **External C-library deps**: **zlib** (`<zlib.h>`, system, `-lz`).
- **Internal deps**: `Buffer`/`DataTranslator`, `xstring`.
- **Nim mapping**: wrap system zlib via Nim (`std/zippy` is a pure-Nim
  alternative, or use the `zlib` C wrapper from nimble / `std/` bindings).
  Recommend **`zippy`** (pure Nim, no C dependency) to honor the
  "no C source in our repo" constraint, with the streaming inflate/deflate
  re-expressed as a translator over chronos byte streams. zlib's `z_stream`
  incremental API maps cleanly onto zippy's streaming or onto a small state
  object.
- **Port complexity**: **Low–Medium.** Self-contained; the only subtlety is the
  "data after the compressed stream is plaintext" heuristic and incremental
  buffer growth.
- **Gotchas**: must remain *streaming* (don't buffer the whole transfer);
  preserve the `Z_STREAM_END`-then-passthrough behavior for FTP MODE Z.

---

## module — dynamic module loading

- **Files & LOC**: `module.cc` (231), `module.h` (27).
- **Purpose**: optional `--with-modules` build where protocols/jobs are `.so`s
  loaded with `dlopen`. Resolves a module name (via `module:path` setting and a
  hard-coded alias table, e.g. `proto-https → proto-http`, `proto-ftps →
  proto-ftp`), `dlopen`s it, runs its init symbol.
- **Key types**: `lftp_module_info` (linked list of loaded handles),
  `module_load`, `module_error_message`, `module_init_preloaded`.
- **External C-library deps**: `libdl` (`dlopen`/`dlsym`, `HAVE_DLOPEN`).
- **Internal deps**: `ResMgr` (`module:path`), `configmake` (PKGLIBDIR),
  `xstring`.
- **Nim mapping**: lftp ships a non-modular static build by default
  (`--with-modules=no`), and a Nim port should be **statically linked / single
  binary** — so this module is best **dropped entirely**. If runtime plugins are
  ever wanted, Nim has `std/dynlib` (`loadLib`/`symAddr`). The alias table is
  just data.
- **Port complexity**: **Low** (or **N/A** if dropped — recommended).
- **Gotchas**: the alias table encodes protocol equivalences (https≈http,
  ftps≈ftp) that also matter at the dispatch layer; even if `dlopen` goes away,
  keep those aliases in the protocol registry.

---

## log + ProtoLog — logging

- **Files & LOC**: `log.cc` (187), `log.h` (86), `ProtoLog.cc` (105),
  `ProtoLog.h` (58). Total ~436 LOC.
- **Purpose**: `Log` is the global leveled logger (`Log::global`), a
  `ResClient` reconfigured by `log:*` settings (`log:enabled`, `log:file`,
  `log:level`, `log:show-time`/`-pid`/`-context`, `log:max-size`). Writes to an
  fd (tty or file), with line-start tracking and tty callback hooks.
  `ProtoLog` is the protocol-conversation logger (recv/send/note/error) whose
  prefixes are settings (`log:prefix-recv` etc.); used by FTP/HTTP/etc.
- **Key types**: `class Log : public ResClient` (`Write`, `Format`/`vFormat`,
  `WillOutput`, the `debug(...)` macro); `class ProtoLog` (static `LogRecv`,
  `LogSend`, `LogError`, `LogNote`, …) with an inner `Tags : ResClient`.
- **External C-library deps**: none (stdio/`write`, varargs).
- **Internal deps**: `ResMgr`/`ResClient`, `xstring`, `Ref`, `SMTask`
  indirectly.
- **Nim mapping**: a small logging object holding an
  `AsyncFile`/`chronos`-friendly fd, level checks, and a reconfig hook on the
  settings store. Nim's `std/logging` is a possible base but the level/closure
  semantics and the `log:` settings integration are custom enough that a
  hand-written ~150-line module is cleaner. Varargs `Format` → Nim `varargs` +
  `strformat`.
- **Port complexity**: **Low.**
- **Gotchas**: `log:max-size` rotation, tty-vs-file behavior, and the
  `ProtoLog` prefix settings drive user-visible output and the transfer log
  format — keep them.

---

## misc — utility grab-bag

- **Files & LOC**: `misc.cc` (1112), `misc.h` (151).
- **Purpose**: a kitchen-sink of free functions: path manipulation
  (`expand_home_relative`, `basename_ptr`, `dir_file`, `url_file`,
  `dirname`/`squeeze_file_name`), directory tree ops (`create_directories`,
  `truncate_file_tree`), terminal width (`fd_width`), foreground-pgrp check,
  `xgetcwd`, date/time parsing & formatting (`parse_month`, `mktime_from_utc`,
  `xstrftime`, `parse_year_or_time`), perms parsing/formatting, regex match
  helper (`re_match`), base64, `temporary_network_error`, XDG dir resolution
  (`get_lftp_config_dir`/`_data_dir`/`_cache_dir`), shell-escaping
  (`shell_encode`), **IDN** (`xidna_to_ascii`, `xtld_name_ok` via libidn2),
  IP-address classification, `lftp_fallocate`, randomness.
- **External C-library deps**: **libidn2** (optional, `idn2.h`,
  `idn2_to_ascii_lz`/`idn2_lookup_ul`), gnulib `regex`, iconv/`localcharset`
  (indirect), `getpwuid`, `posix_fallocate`/`fallocate`.
- **Internal deps**: `xstring`, `trio` (printf), `TimeDate`.
- **Nim mapping**: most of this is **stdlib in Nim** — `std/os` (paths, cwd,
  dirs, `removeDir`), `std/times` (parse/format, replacing
  `mktime_from_utc`/`xstrftime`), `std/strutils`, `std/base64`, `std/re` or
  `std/nre` (replacing the gnulib regex helper), `std/terminal` (`terminalWidth`
  replaces `fd_width`). XDG dirs → `std/paths`/`getConfigDir`/`getCacheDir` or a
  tiny helper. IDN → a small libidn2 wrapper *or* a pure-Nim IDNA lib; this is
  the only nontrivial external dep here and is **optional** (guard it).
  `temporary_network_error` → map chronos/`OSErrorCode` equivalents.
- **Port complexity**: **Medium**, but mostly by *volume* of small functions;
  each maps to a stdlib call. Real work is the date parsing (`parse_year_or_time`,
  `guess_year`) and `mktime_from_utc`, which have lftp-specific semantics for
  listing parsers.
- **Gotchas**: `mktime_from_utc`/`guess_year` feed FTP/HTTP listing date parsing
  — get the timezone and year-guessing rules right or timestamps drift.
  `shell_encode` is used for command generation; IDN handling affects which
  hostnames resolve.

---

## lftp.cc — program entry point

- **Files & LOC**: `lftp.cc` (620). (`lftp.h` does not exist.)
- **Purpose**: `main()` and interactive setup: locale init, readline
  integration (`ReadlineFeeder : CmdFeeder, ResClient`), signal hooks, history
  load/save, top-level `CmdExec` creation, the REPL loop and the
  SMTask/PollVec run loop. Registers a few `cmd:*` settings via `ResDecl`.
- **Key types**: `ReadlineFeeder`, the `main` driver, `hook_signals`.
- **External C-library deps**: **readline** (`lftp_rl.*` wrapper around GNU
  readline/history), `glob`, `locale`/`setlocale`.
- **Internal deps**: nearly everything — `CmdExec`, `SignalHook`, `GetPass`,
  `History`, `Log`, `ResMgr`, `ConnectionSlot`, `complete`, `alias`, the whole
  runtime.
- **Nim mapping**: a Nim `main` driving a chronos event loop (`waitFor
  mainLoop()`). Interactive line editing → `linenoise`/`noise`/`linecross`
  bindings or a small readline wrapper; non-interactive mode needs none. Locale
  via `std/`/`setlocale`. Signal handling via chronos `addSignal` /
  `std/posix`.
- **Port complexity**: **Medium** — the logic is thin, but it's the integration
  point for the async loop, readline, and signals; getting the chronos main loop
  + readline cohabitation right is the tricky part.
- **Gotchas**: readline and an async reactor must share the tty without
  blocking; lftp solves this with `CmdFeeder`. The `cmd:save-rl-history` /
  `cmd:save-cwd-history` settings and history files must be preserved for UX
  parity.

---

## lftp_tinfo — terminfo

- **Files & LOC**: `lftp_tinfo.cc` (82), `lftp_tinfo.h` (25).
- **Purpose**: `get_string_term_cap()` — look up a terminfo/termcap string
  capability (used by `StatusLine` for title/status escape sequences).
- **External C-library deps**: **ncurses/terminfo** (`tigetstr`/termcap),
  probed by `m4/terminfo.m4`.
- **Internal deps**: minimal.
- **Nim mapping**: `std/terminal` covers most needs; for raw capability lookup
  either a tiny ncurses `tigetstr` wrapper or hard-code the handful of
  sequences `StatusLine` actually uses (title set, cursor moves). Recommend
  **dropping the terminfo dependency** and using ANSI sequences + `std/terminal`.
- **Port complexity**: **Low.**
- **Gotchas**: title-setting escape sequences vary by terminal; lftp degrades
  gracefully when caps are absent — preserve that.

---

## StatusLine — interactive status/title line

- **Files & LOC**: `StatusLine.cc` (286), `StatusLine.h` (69).
- **Purpose**: an `SMTask` that renders the bottom status line and terminal
  title, throttled by a `Timer`, tracking width/height, with delayed updates.
- **Key types**: `class StatusLine : public SMTask`.
- **External C-library deps**: terminfo strings (via `lftp_tinfo`), `ioctl`
  TIOCGWINSZ for size.
- **Internal deps**: `SMTask`, `Timer`, `StringSet`, `lftp_tinfo`.
- **Nim mapping**: a chronos periodic task writing to stdout; `std/terminal`
  for size (`terminalWidth`/`terminalHeight`) and clearing. Throttle with a
  chronos timer.
- **Port complexity**: **Low–Medium.**
- **Gotchas**: SIGWINCH handling and the update-throttling cadence affect
  flicker; title-only updates are an optimization to keep.

---

## OutputJob — buffered/filtered output sink

- **Files & LOC**: `OutputJob.cc` (539), `OutputJob.h` (124).
- **Purpose**: a `Job` that funnels command output to a destination (stdout, a
  file, a remote FA path, or through a shell filter / pager), via internal
  `CopyJob`s. Handles tty detection, width, status-line interaction, optional
  pre-filters, and broken-pipe policy.
- **Key types**: `class OutputJob : public Job`.
- **External C-library deps**: none directly.
- **Internal deps**: `Job`, `CopyJob`, `FileCopy`, `Filter` (OutputFilter),
  `Buffer`, `FileAccess`, `Timer`, `StatusLine`.
- **Nim mapping**: a chronos async writer with an optional sub-process filter
  stage (chronos `AsyncProcess`) and a tee to status line. Built atop the
  port's FileCopy/CopyJob equivalents (covered in other inventories).
- **Port complexity**: **Medium** — depends on the FileCopy/Job framework being
  ported first.
- **Gotchas**: the "buffer until initialized" path (`tmp_buf`) and
  pager/filter spawning; `DontFailIfBroken` semantics for `| head`-style pipes.

---

## Filter — FDStream / pipe / file streams

- **Files & LOC**: `Filter.cc` (488), `Filter.h` (166).
- **Purpose**: `FDStream` and subclasses model a file descriptor source/sink:
  `OutputFilter`/`InputFilter` spawn a child process connected by a pipe (the
  shell-filter mechanism), `FileStream` opens/locks/backs-up files. Used by
  `OutputJob`, editing, viewing, local transfers.
- **Key types**: `FDStream`, `OutputFilter`, `InputFilter`, `FileStream`.
- **External C-library deps**: POSIX `pipe`/`fork`/`exec`/`fcntl`/`flock`
  (no third-party lib).
- **Internal deps**: `ProcWait`, `ArgV`, `xstring`, `FileTimestamp`.
- **Nim mapping**: `FileStream` → `std/os`/`AsyncFile`; the filter classes →
  chronos `AsyncProcess` with async pipes. Backup/lock logic → `std/os` +
  `posix` `flock`.
- **Port complexity**: **Medium** — process spawning + async pipe plumbing is
  the meat; chronos `AsyncProcess` handles most of it.
- **Gotchas**: process-group management (`SetProcGroup`/`Kill`) for job control;
  atomic file backup/restore semantics.

---

## PatternSet — include/exclude pattern matching

- **Files & LOC**: `PatternSet.cc` (123), `PatternSet.h` (98).
- **Purpose**: ordered list of include/exclude rules (regex or glob) used by
  `mirror`/`find` filtering.
- **Key types**: `class PatternSet` with nested `Pattern` base, `Regex`
  (wrapping `regex_t`), `Glob`.
- **External C-library deps**: POSIX `regex` (gnulib's `regex` on systems
  lacking it), `fnmatch`/glob semantics.
- **Internal deps**: `xstring`.
- **Nim mapping**: `std/re`/`std/nre` for regex, `std/strutils`'
  `matchPattern`/glob or a tiny glob matcher; the include/exclude chain is plain
  data structures (`seq`).
- **Port complexity**: **Low.**
- **Gotchas**: rule *ordering* and first-match-wins semantics matter for mirror
  correctness; the `slash_count` glob nuance.

---

## External dependencies

Derived from `configure.ac` and `src/Makefile.am`
(`liblftp_network_la_LIBADD`, `liblftp_tasks_la_LIBADD`, `lftp_LDADD`, the
`AC_SEARCH_LIBS`/`PKG_CHECK_MODULES`/`AX_*` macros).

### Required / commonly linked
| lftp C dependency | Used for | Where (configure.ac / Makefile.am) | Nim equivalent |
|---|---|---|---|
| **GnuTLS** (`gnutls`) *(default TLS)* | FTPS/HTTPS TLS, X.509, CRL | `PKG_CHECK_MODULES([LIBGNUTLS])`; `liblftp-network` | **chronos TLS (bearssl)** for the common path; optional `gnutls` wrapper only if CRL/GnuTLS-specific behavior is required |
| **OpenSSL** (`libssl`+`libcrypto`) *(opt-in alt TLS)* | alternative TLS backend, CRL store, RAND | `LFTP_OPENSSL_CHECK`, `--with-openssl`; `liblftp-network` | Nim `openssl` wrapper (stdlib `std/openssl`) **only if** an OpenSSL-parity path is needed; otherwise unused |
| **zlib** (`-lz`) | FTP MODE Z, HTTP gzip | `AX_CHECK_ZLIB`; `buffer_zlib` | **`zippy`** (pure Nim) — preferred under "no C in repo"; or a system-zlib wrapper |
| **GNU readline + history** | interactive line editing/history | `lftp_LIB_READLINE`; `lftp_CPPFLAGS`/`lftp_LDADD` | `linenoise`/`noise`/`linecross` Nim binding, or thin readline wrapper; none for batch mode |
| **ncurses / terminfo** | terminal capability strings | `lftp_TERMINFO`; `StatusLine`/`lftp_tinfo` | `std/terminal` + ANSI; drop terminfo dep |
| **iconv** (libiconv or libc) | charset conversion | `AM_ICONV`; `$(LTLIBICONV)` | `std/encodings` (wraps iconv) or a Nim iconv binding |
| **gettext / libintl** (`-lintl`) | i18n (`_()`/`N_()`) | `AM_GNU_GETTEXT`; `$(LTLIBINTL)` | `std/`/custom catalog, or skip i18n initially; gettext `.po` files re-used via a small loader |
| **expat** | HTTP/WebDAV (PROPFIND) & DAV XML | `AX_LIB_EXPAT`, `HAVE_LIBEXPAT`; `proto-http` | `std/parsexml` (pure Nim) |
| **libdl** (`dlopen`) | `--with-modules` plugin loading | `AC_SEARCH_LIBS([dlopen])`; `module.cc` | `std/dynlib` — or drop (static binary) |
| **libresolv / libbind** | `res_search`/`dn_expand` (SRV, DNSSEC) | `AC_SEARCH_LIBS([res_search])`, `hstrerror` | `std/net`/chronos resolver + optional libresolv wrapper for SRV |

### Optional (off by default or `--with-*`)
| lftp C dependency | Used for | Where | Nim equivalent |
|---|---|---|---|
| **libidn2** | IDN (punycode) hostnames | `LFTP_LIBIDN2_CHECK`; `misc.cc` (`xidna_to_ascii`) | thin `idn2` wrapper or pure-Nim IDNA; optional |
| **libval / libsres** (dnssec-tools) | local DNSSEC validation | `--with-dnssec-local-validation` | optional; chronos/system resolver or a DNSSEC lib; likely dropped |
| **SOCKS** (`libsocks`/`-socks5`/dante) | SOCKS proxy | `--with-socks*`; function-remapping macros in `config.h` | chronos has no built-in SOCKS; small client lib or drop |
| **libsocket / libnsl** | sockets on legacy SVR4 | `AC_SEARCH_LIBS([socket],[gethostbyname])` | none — Nim/chronos provides sockets natively |
| **libm** | math (commented out) | `dnl LFTP_CHECK_LIBM` | `std/math` |

### TLS recommendation (given "no C source in OUR repo")
- **chronos ships TLS backed by bearssl, which is vendored *inside chronos*, not
  in lftp's repo.** That satisfies the constraint ("no C source in our repo")
  the same way it satisfies it for every other chronos user — bearssl lives in
  the dependency, not in this project.
- **Primary recommendation: use chronos's bearssl-based TLS
  (`chronos/streams/tlsstream`)** for FTPS/HTTPS. It gives a non-blocking
  `AsyncStream` that maps directly onto lftp's `IOBufferSSL` model (handshake
  pumping, want_read/want_write, graceful close), and onto `lftp_ssl`'s
  `read`/`write`/`shutdown`/`want_in`/`want_out` surface. Implement
  `set_cert_error` policy (hostname check + `ssl:verify-certificate` closure +
  SHA-1 fingerprint trust) in Nim on top of bearssl's verification callbacks.
- **Caveat / fallback**: bearssl does **not** provide lftp's full CRL story or
  the GnuTLS-specific priority strings. For the (rare) deployments that need
  explicit CRL files (`ssl:crl-file`/`ssl:crl-path`) or OpenSSL-parity
  behavior, keep an **optional OpenSSL path** via Nim's stdlib `std/openssl`
  wrapper (still no C source in-repo — it links the system library). This
  mirrors lftp's own GnuTLS-default / OpenSSL-opt-in design.
- **Net**: default to **chronos+bearssl** (single dependency, no in-repo C,
  async-native); offer **std/openssl** as a compile-time alternative for CRL /
  legacy interop — exactly the two-backend shape lftp already has, but with the
  C now living in the dependencies rather than in the project tree.

---

## gnulib & trio

These two directories are **pure portability shims and vanish in the Nim port.**

- **`lib/` (gnulib)** — a vendored slice of GNU gnulib pulled in by `bootstrap`
  (see `bootstrap.conf gnulib_modules`): `alloca-opt`, `arpa_inet`,
  `configmake`, `crypto/md5`, `crypto/sha1`, `fnmatch`/`fnmatch-gnu`,
  `getopt-gnu`, `gettext`, `gettimeofday`, `glob`, `human`, `iconv_open`,
  `inet_pton`, `lstat`, `mbswidth`, `memmem`, `mktime`, `nstrftime`,
  `parse-datetime`, `passfd`, `poll`, `readlink`, `regex`, `sockets`,
  `socklen`, `strdup-posix`, `strptime`, `strstr`, `strtok_r`, `unsetenv`,
  `vsnprintf`(-posix), plus the checked-in `hstrerror.c` and `unistr`/`uniwidth`
  (Unicode string-width) helpers. **Every one of these is a polyfill for a libc
  function that is either standard on modern systems or provided directly by
  Nim's stdlib** (`std/os`, `std/times`, `std/strutils`, `std/net`,
  `std/unicode`, `std/widestrs`) **or chronos** (`poll`, sockets). The crypto
  helpers (md5/sha1) used for cert fingerprints map to Nim `std/sha1`/bearssl.
  → **Delete entirely.**

- **`trio/`** — a portable, self-contained `printf`/`scanf` implementation
  (`trio.c`, `triostr.c`, `trionan.c`) used when the platform's stdio
  `*printf`/`*scanf` are deemed inadequate (gated by `LFTP_NEED_TRIO` /
  `TRIO_REPLACE_STDIO` in `configure.ac`). Almost every lftp header `#include
  "trio.h"` purely to get these. **Nim has native string formatting**
  (`std/strformat`, `&`, `std/strutils`) and parsing; there is no `printf`
  portability problem to solve. → **Delete entirely.**

Also disappearing with them: the entire **autotools layer** (`configure.ac`,
`Makefile.am`, the `m4/` feature-test macros, `bootstrap`/`autogen.sh`,
`config.h`), replaced by a `*.nimble` file + `nim` compiler. All the
`AC_CHECK_*` / `#ifdef HAVE_*` portability branching collapses because Nim's
stdlib gives one consistent cross-platform surface.

---

## Subsystem summary

- **Total LOC (this subsystem's primary files): ~8,417** (see per-file table at
  top). Dominated by `lftp_ssl.cc` (1547), `misc.cc` (1112), `ResMgr.cc` (984),
  `lftp.cc` (620), `OutputJob.cc` (539), `resource.cc` (501), `Filter.cc` (488).
  Plus the `lib/` (gnulib) and `trio/` trees, which are **out-of-scope to port
  (deleted)**.
- **Settings count**: `resource.cc` defines **199** settings in `lftp_vars[]`;
  with other modules' tables (CmdExec 29, Torrent 18, log 11) and ~26 standalone
  `ResDecl`s, **~280 total** across the program.
- **Overall complexity**: **Medium**, with one **High** island
  (`lftp_ssl.cc` — non-blocking dual-backend TLS + cert verification). The
  settings system is medium-by-surface-area; logging, zlib, patternset,
  terminfo are low; most of `misc` collapses into Nim stdlib calls; `module` is
  best dropped.
- **TLS recommendation**: **Default to chronos's bearssl-backed TLS**
  (`tlsstream`) — async-native, single dependency, no C source in lftp's own
  repo (bearssl is vendored inside chronos). Re-implement lftp's
  settings-driven cert policy (`ssl:check-hostname`, `ssl:verify-certificate`
  keyed on hostname *and* SHA-1 fingerprint, SNI via `ssl:use-sni`) in Nim atop
  bearssl callbacks. Keep an **optional `std/openssl` path** for the CRL
  (`ssl:crl-file/-path`) and legacy-interop cases bearssl can't cover —
  mirroring lftp's existing GnuTLS-default / OpenSSL-opt-in two-backend design,
  but with all C now in dependencies rather than in-tree.

### External-dependency → Nim mapping (master table)
| C dependency | Status | Nim replacement |
|---|---|---|
| GnuTLS (default) / OpenSSL (opt-in) | required (one of) | **chronos TLS / bearssl** (default); `std/openssl` optional for CRL/legacy |
| zlib | required | **`zippy`** (pure Nim) or system-zlib wrapper |
| GNU readline + history | required (interactive) | `linenoise`/`noise` binding; none for batch |
| ncurses / terminfo | required (tty) | `std/terminal` + ANSI; drop terminfo |
| iconv | required | `std/encodings` |
| gettext / libintl | required | custom `.po` loader or defer i18n |
| expat | required (HTTP/DAV) | `std/parsexml` (pure Nim) |
| libdl (dlopen) | modules only | `std/dynlib`, or **drop** (static binary) |
| libresolv / libbind | required-ish (SRV/DNSSEC) | chronos resolver + optional libresolv wrapper |
| libidn2 | optional | `idn2` wrapper or pure-Nim IDNA; optional |
| libval/libsres (DNSSEC) | optional | drop / dedicated lib |
| SOCKS (libsocks/dante) | optional | small SOCKS client or drop |
| libsocket / libnsl | legacy | **none** (chronos sockets) |
| libm | (commented) | `std/math` |
| **gnulib (`lib/`)** | portability shim | **deleted** — Nim stdlib + chronos |
| **trio (`trio/`)** | printf/scanf shim | **deleted** — `std/strformat`/`strutils` |
| **autotools (`configure.ac`, `m4/`, `Makefile.am`)** | build system | **deleted** — `*.nimble` + `nim` |
