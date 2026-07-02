# Subsystem 02 — FileAccess abstraction, local access, file sets, name resolution, URLs

Port target: Nim + `chronos`. Source: lftp 4.9.3, `src/src/` (flat).

This subsystem is the heart of lftp's I/O model. `FileAccess` is the abstract base
class that **every** protocol backend (ftp/http/https/sftp/fish/file) subclasses. The
whole program talks to remote and local storage through this one interface, driven by
the cooperative `SMTask` scheduler (every object has an `int Do()` pumped each event
loop tick). Porting this contract correctly is the single most load-bearing decision
of the entire port, because all protocol modules depend on its exact shape.

---

## FileAccess (FileAccess.cc / FileAccess.h)

- **Files & LOC**: FileAccess.cc (1105), FileAccess.h (583) — 1688 total.
- **Purpose**: Abstract base class for all storage backends and the central state
  machine for a single "session" (one connection to one site, or local fs). Defines
  the open-mode command set, path handling, error model, URL formatting, the protocol
  registry/factory, and the session pool. Also declares the operation helper classes
  (`FileAccessOperation`, `ListInfo`, `DirList`, `Glob`).
- **Key classes/types**:
  - `FileAccess` — base session. Inherits `SMTask` (cooperative task with `Do()`),
    `ResClient` (config/resource client), `ProtoLog` (logging).
  - `FileAccess::Path` — rich path value type: `path`, `is_file`, `url`,
    `device_prefix_len`; `Optimize()` collapses `.`/`..`/`//`; tilde expansion;
    equality. (~100 lines of pure path logic to reproduce.)
  - `FileAccess::Protocol` — name→`SessionCreator` registry (`Register`, `NewSession`).
  - `SessionPool` (64-slot reuse cache), `FileAccessRef`/`FileAccessRefC`/`FileAccessRefS`
    (refcounted smart pointers that auto-return sessions to the pool).
  - `FileAccessOperation` base + `ListInfo`, `DirList`, `LsOptions`, `UploadState`.

### The virtual interface every protocol MUST implement

Pure virtual (abstract — subclass is required to provide):
```
const char *GetProto() const            // "ftp","http","file",...
FileAccess *Clone() const               // duplicate session config
int  Read(Buffer *buf,int size)         // pull data while open in RETRIEVE/LIST
int  Write(const void *buf,int size)    // push data while open in STORE
int  StoreStatus()                      // poll completion of a STORE
int  Do()                               // SMTask pump: advances the state machine
int  Done()                             // poll completion of current operation
```
Commonly overridden virtuals (base supplies a default/no-op):
```
void Open(const char*file,int mode,off_t pos)   // begin an operation (see open_mode)
void Close()                                     // end operation, keep connection
void Login(const char*u,const char*p)
void ResetLocationData()
int  IsConnected() const                         // 0 = not connected, higher = more
void DisconnectLL()                              // low-level disconnect
int  Buffered();  bool IOReady();                 // flow control
bool SameLocationAs(...); bool SameSiteAs(...)    // session matching/reuse
const char *CurrentStatus(); const char *StrError(int)
void Cleanup(); void CleanupThis()                // drop idle connections
ListInfo *MakeListInfo(path)                       // factory: directory listing op
Glob     *MakeGlob(pattern)                        // factory: wildcard expansion
DirList  *MakeDirList(ArgV*)                        // factory: human-readable `ls`
FileSet  *ParseLongList(buf,len,*err)               // parse server `ls -l` output
bool NeedSizeDateBeforehand(); void UseCache(bool)
```

### State machine (the `open_mode` command enum)

A session is either `CLOSED` or executing one command. `Open()` sets `mode` to one of:
`RETRIEVE, STORE, LONG_LIST, LIST, MP_LIST, CHANGE_DIR, MAKE_DIR, REMOVE_DIR, REMOVE,
QUOTE_CMD, RENAME, ARRAY_INFO, CONNECT_VERIFY, CHANGE_MODE, LINK, SYMLINK`.
Convenience wrappers (`Rename`, `Mkdir`, `Chdir`, `Remove`, `Chmod`, `Link`, `Symlink`,
`GetInfoArray`, `ConnectVerify`) all funnel into `Open`/`Open2`. The caller then pumps
`Do()` until `Done()` returns non-`IN_PROGRESS`, reading via `Read()`/writing via
`Write()` in between. Result/status codes are the `status` enum (`OK`, `IN_PROGRESS`,
`SEE_ERRNO`, `LOOKUP_ERROR`, `NO_FILE`, `NO_HOST`, `LOGIN_FAILED`, `FATAL`, `NOT_SUPP`,
`DO_AGAIN`, …). Restart position handled via `pos`/`real_pos`/`SeekReal()`.

- **External C-library deps**: `<sys/socket.h>`, `<netinet/in.h>` (only for type
  visibility), `errno`, `fcntl`. No direct syscalls of consequence in the base — it is
  state + string + registry logic.
- **Internal deps**: SMTask, ResMgr/ResClient, ProtoLog, FileSet, ArgV, xstring/xmap/
  xlist, Timer, Buffer, url, LsCache, ConnectionSlot, netrc, DummyProto, FileGlob.
- **Nim mapping**: Translate to a Nim abstract `ref object of RootObj` (or a
  `FileAccess` base with `method`s) plus the `chronos` event loop replacing the manual
  `Do()` pump — but note lftp's `Do()` model is *not* async/await; it is a hand-rolled
  cooperative scheduler. Two viable strategies: (a) keep a faithful `Do()`-style state
  machine and drive it from a chronos `Future`, or (b) rewrite each backend as
  `proc ... {.async.}` and make `FileAccess` a thin async interface. (b) is cleaner but
  touches every protocol module — decide early. The `open_mode` enum, `status` enum,
  `Path`, the protocol registry (a `Table[string, proc]`), and the session pool all
  port directly to plain Nim. Smart-ptr refs (`FileAccessRef`) become `ref` + a manual
  pool, since Nim GC won't auto-return to the pool.
- **Port complexity**: **High** — it is the central contract, the `Path::Optimize`
  logic is fiddly, and the sync-`Do()`-vs-async decision ripples through all of
  subsystem 03+ (the protocols).
- **Gotchas**: `Do()` must never block. `Read`/`Write` return byte counts or negative
  status codes, not exceptions — keep that convention or adapt every caller. Session
  reuse via `SessionPool` + the `~FileAccessRef` destructor is subtle; Nim has no
  deterministic destructor unless you use `=destroy`/`{.destructor.}` hooks.

---

## NetAccess (NetAccess.cc / NetAccess.h)

- **Files & LOC**: NetAccess.cc (700), NetAccess.h (193) — 893 total.
- **Purpose**: Intermediate abstract class between `FileAccess` and the *networked*
  protocols. Adds DNS resolution, peer-address rotation, connection limiting per site,
  reconnect/backoff timers, proxy config, rate limiting, and socket tuning.
- **Key classes/types**:
  - `NetAccess : public FileAccess, public Networker` — still abstract.
  - `NetAccess::SiteData` — per-site adaptive connection-limit governor (`xmap` keyed
    by connect-URL).
  - `GenericParseListInfo : ListInfo` — drives a listing by reading the data stream and
    feeding `ParseLongList`, with redirect following.
  - Holds `SMTaskRef<Resolver> resolver`, `xarray<sockaddr_u> peer` (+ `peer_curr`,
    `NextPeer()`), reconnect-interval backoff fields, `RateLimit`, proxy fields.
- **External C-library deps**: `poll()` (via `Poll`/`CheckHangup`), socket layer (via
  `Networker`). No DNS here directly — delegated to `Resolver`.
- **Internal deps**: FileAccess, Resolver, LsCache, RateLimit, Networker, Timer, ResMgr.
- **Nim mapping**: chronos provides connection management, timeouts, and transports
  natively — much of `NetAccess` (poll loop, peer rotation, reconnect backoff) becomes
  `chronos.connect` + `withTimeout` + a retry loop. `SiteData` connection limiting and
  `RateLimit` are bespoke and must be hand-written. `Resolver` maps to
  `chronos.resolveTAddress`. Proxy handling is custom.
- **Port complexity**: **Medium-High** — much is subsumed by chronos, but the adaptive
  connection-limit governor and reconnect/backoff policy are lftp-specific behavior to
  preserve.
- **Gotchas**: `peer` is a list of resolved addresses tried in order (IPv4/IPv6
  fallback) — chronos `resolveTAddress` returns a seq, so keep the rotation logic.
  `GetSiteData` lazily allocates and leaks into a static `xmap` — a global `Table` in
  Nim with care around lifetime.

---

## LocalAccess (LocalAccess.cc / LocalAccess.h)

- **Files & LOC**: LocalAccess.cc (745), LocalAccess.h (64) — 809 total.
- **Purpose**: The `"file"` protocol — concrete `FileAccess` over the local filesystem.
  The simplest fully-working backend and the best reference implementation of the
  `FileAccess` contract.
- **Key classes/types**: `LocalAccess : FileAccess`; uses `Ref<FDStream>` for open
  files; `LocalListInfo`, `LocalGlob`, `LocalDirList` operation subclasses.
- **External C-library deps**: POSIX `<dirent.h>` (`opendir`/`readdir`), `<sys/stat.h>`
  (`stat`/`lstat`/`fstat`), `open`/`read`/`write`, `unlink`/`rmdir`/`mkdir`/`rename`/
  `link`/`symlink`/`chmod`, `utime`, `<pwd.h>`, and `<glob.h>` (system glob) for
  `LocalGlob`.
- **Internal deps**: FileAccess, Filter/FDStream, LocalDir, FileGlob, FileSet, ArgV.
- **Nim mapping**: `std/os`, `std/posix`, `std/dirs`/`walkDir`, `std/stat` cover nearly
  everything. Read/write can use chronos `AsyncFD` or stay synchronous (local fs is
  fast; lftp itself does sync syscalls here in `Do()`). System `glob.h` → Nim
  `std/os.walkPattern` or `walkDirRec` + `fnmatch`-style matching.
- **Port complexity**: **Low-Medium** — straightforward syscall mapping; the
  `Do()`-driven state machine over the `open_mode` switch is the only mild complexity.
- **Gotchas**: It performs blocking syscalls inside `Do()` (acceptable because local).
  `fill_array_info` for `ARRAY_INFO` stats a whole FileSet. `dir_file(cwd,file)` path
  joining must match lftp semantics.

---

## LocalDir (LocalDir.cc / LocalDir.h)

- **Files & LOC**: LocalDir.cc (100), LocalDir.h (43) — 143 total.
- **Purpose**: Save/restore the process current working directory (by held fd when
  possible, else by remembered name), so the program can `chdir` around safely.
- **Key classes/types**: `LocalDirectory` — `GetName()`, `Chdir()`, `SetFromCWD()`,
  `Unset()`, `Clone()`.
- **External C-library deps**: `getcwd`, `chdir`, `fchdir`, `open(O_DIRECTORY)`.
- **Internal deps**: xstring.
- **Nim mapping**: `std/os.getCurrentDir`/`setCurrentDir`; fd-based `fchdir` via
  `std/posix` for the fast path.
- **Port complexity**: **Low**.
- **Gotchas**: Holds a dir fd open; remember to close on `Unset`.

---

## FileSet / FileInfo (FileSet.cc / FileSet.h)

- **Files & LOC**: FileSet.cc (1185), FileSet.h (246) — 1431 total.
- **Purpose**: The core data model for directory contents. `FileInfo` = one entry
  (name, mode, date, size, type, symlink target, user/group, nlinks, with a
  `defined`/`need` bitmask tracking which fields are known). `FileSet` = an ordered,
  sortable, filterable collection of `FileInfo` with rich set algebra.
- **Key classes/types**:
  - `FileInfo` — `defined_bits` mask (NAME/MODE/DATE/TYPE/SIZE/USER/GROUP/NLINKS…),
    `parse_ls_line()` (parses Unix `ls -l`!), `LocalFile()` (stat a local path),
    `Merge`/`MergeInfo`, time/size comparisons, `MakeLongName`.
  - `FileSet` — `sort_e` modes, dozens of `Subtract*` set operations (diff against
    another set by name/type/date/size — the engine behind `mirror`), `Exclude*`,
    pattern-list sort, `Local{Remove,Utime,Chmod,Chown}`, `PrependPath`.
- **External C-library deps**: `<sys/stat.h>` (for `LocalFile`/`LocalRemove` etc.),
  `utime`, `chmod`, `chown`. `parse_ls_line` does date/time parsing.
- **Internal deps**: xarray/RefArray, xstring, PatternSet, Range/TimeInterval,
  IdNameCache (user/group name lookup).
- **Nim mapping**: Hand-written `object` for `FileInfo` and a `seq[FileInfo]`-backed
  `FileSet`. No stdlib equivalent — this is domain logic. Sorting → `std/algorithm.sort`
  with custom comparators. `parse_ls_line` is a substantial standalone parser to port
  faithfully (many server `ls` dialects). Time parsing → `std/times`.
- **Port complexity**: **Medium-High** — large surface, the `defined`/`need` bitmask
  discipline must be preserved, and `parse_ls_line` is intricate and correctness-
  critical for FTP listings.
- **Gotchas**: `user`/`group` are interned `const char*` from a `StringPool`/IdNameCache
  — don't copy strings naively. The `Subtract*` family encodes mirror semantics; subtle
  bugs here corrupt syncs. `NO_SIZE`/`NO_SIZE_YET`/`NO_DATE`/`NO_DATE_YET` sentinel
  values are load-bearing.

---

## FileSetOutput (FileSetOutput.cc / FileSetOutput.h)

- **Files & LOC**: FileSetOutput.cc (431), FileSetOutput.h (118) — 549 total.
- **Purpose**: Formats a `FileSet` for display — implements the `cls`/`ls`-style output
  (column selection, classify suffixes, color, sorting, human-readable sizes, time
  format). `clsJob` is the job wrapper.
- **Key classes/types**: `FileSetOutput` (options + `print()`), `clsJob : SessionJob`.
- **External C-library deps**: none directly (uses internal human-size + time fmt).
- **Internal deps**: FileSet, ColumnOutput, DirColors, OutputJob/CopyJob/Job, ArgV,
  keyvalue, GetFileInfo, ResMgr.
- **Nim mapping**: Pure formatting logic — port by hand. `strformat`/`std/terminal` for
  width/color. Argument parsing → custom (mirrors lftp option set).
- **Port complexity**: **Medium** — lots of option flags and formatting rules, but
  mechanical.
- **Gotchas**: Tied to lftp's `OutputJob` pipeline and `cls` resource options; needs the
  job/output infrastructure (subsystem dependency) to be in place.

---

## FileGlob (FileGlob.cc / FileGlob.h)

- **Files & LOC**: FileGlob.cc (352), FileGlob.h (113) — 465 total.
- **Purpose**: Wildcard expansion abstraction. `Glob` is a `FileAccessOperation` that
  produces a `FileSet`; `GenericGlob` expands by listing directories and matching;
  `NoGlob` passes a literal; `GlobURL` handles URL-prefixed patterns.
- **Key classes/types**: `Glob`, `NoGlob`, `GenericGlob`, `GlobURL`; static
  `HasWildcards`, `UnquoteWildcards`.
- **External C-library deps**: `<fnmatch.h>` (`fnmatch` for pattern matching). (Note:
  *system* `glob()` is used by `LocalAccess`'s `LocalGlob`, not here.)
- **Internal deps**: FileAccess, FileSet, url, misc, ResMgr.
- **Nim mapping**: Pattern matching → Nim has no `fnmatch` in stdlib; either FFI to
  `fnmatch`, use `std/os.walkPattern` matching, or port a small glob matcher.
  `std/re`/`std/nre` is overkill and has different semantics — a dedicated glob matcher
  is safer. The directory-walking `GenericGlob` reuses `MakeListInfo`, so it ports with
  the FileAccess interface.
- **Port complexity**: **Medium** — the matcher itself is small; `GenericGlob`'s
  recursive directory expansion driven by async listings is the work.
- **Gotchas**: lftp distinguishes server-side vs generic globbing; `inhibit_tilde`,
  `match_period`, `casefold`, `cmd:nullglob` flags all affect results.

---

## GetFileInfo (GetFileInfo.cc / GetFileInfo.h)

- **Files & LOC**: GetFileInfo.cc (490), GetFileInfo.h (81) — 571 total.
- **Purpose**: A `ListInfo` operation that figures out whether a path is a file or a
  directory and returns its info, trying `cd`-as-dir, then `cd`-as-file, then
  `GetInfoArray` as a last resort, with cache shortcuts.
- **Key classes/types**: `GetFileInfo : ListInfo` — state machine
  (`INITIAL→CHANGE_DIR→CHANGING_DIR→GETTING_LIST→GETTING_INFO_ARRAY→DONE`), tracks
  `tried_dir`/`tried_file`/`tried_info`/`from_cache`/`was_directory`.
- **External C-library deps**: none.
- **Internal deps**: FileAccess, ListInfo, FileSet, LsCache.
- **Nim mapping**: Pure state-machine logic over the FileAccess interface — port by
  hand; no stdlib analog.
- **Port complexity**: **Medium** — state machine with fallbacks and cache interaction.
- **Gotchas**: Heavily depends on the exact semantics of `Chdir` success/failure and
  cache `IsDirectory` — port after FileAccess + LsCache are stable.

---

## Resolver (Resolver.cc / Resolver.h)  — DNS

- **Files & LOC**: Resolver.cc (1008), Resolver.h (139) — 1147 total.
- **Purpose**: Asynchronous hostname → `sockaddr_u[]` resolution, with optional
  `fork()`ed child (to avoid blocking the event loop in libc resolver), SRV-record
  lookup, address-family ordering, and a TTL cache.
- **Key classes/types**: `Resolver : SMTask` (`Do()` drives child-pipe or inline
  resolution); `ResolverCache`/`ResolverCacheEntry` (TTL cache keyed by host/port/
  service/proto); `SRV` struct + `SRV_compare` for RFC 2782 priority/weight ordering.
- **External C-library deps**: `<netdb.h>` — `getaddrinfo`/`gethostbyname`
  (`DoGethostbyname`), `<resolv.h>`/`<arpa/nameser.h>` — `res_search` for SRV
  (`T_SRV`), optional `val_res_search` (DNSSEC). `fork`/`pipe`/`fcntl` for the
  worker-process strategy (`dns:use-fork`).
- **Internal deps**: ProcWait, IOBuffer/buffer, Cache, network/Networker, ResMgr, log.
- **Nim mapping**: **Maps directly to `chronos.resolveTAddress`** for the common A/AAAA
  case — this eliminates the entire fork/pipe machinery (chronos resolves on a thread
  pool / async). The address-family ordering, TTL cache, and timeout become a thin
  wrapper. **SRV lookup has no chronos equivalent** — must be hand-written: either FFI
  to `res_search`/`getrrsetbyname`, a pure-Nim DNS client, or drop SRV initially.
- **Port complexity**: **Medium** — chronos removes most of it, but SRV + the cache +
  the address ordering policy are real work, and the fork worker simply disappears.
- **Gotchas**: The fork/pipe protocol (a custom wire format `'E'`/`'P'` error bytes
  prefixing packed `sockaddr_u`) is obsolete under chronos — don't port it. Keep the
  TTL-cache (`dns:cache-expire`) and the `dns:order` (inet/inet6) preference. SRV record
  parsing is byte-level and fiddly.

---

## network (network.cc / network.h)

- **Files & LOC**: network.cc (474), network.h (146) — 620 total.
- **Purpose**: Socket-layer helpers and the `sockaddr_u`/`sockaddr_compact` address
  union used everywhere. `Networker` mixin provides socket create/tune/connect/bind.
- **Key classes/types**: `sockaddr_u` (union over `sockaddr_in`/`sockaddr_in6` with
  address/port/family/classification helpers — `is_loopback`/`is_private`/
  `is_multicast`/`is_reserved`), `sockaddr_compact` (packed binary address as xstring),
  `Networker` (static socket helpers: `NonBlock`, `KeepAlive`, `MinimizeLatency`,
  `SetSocketBuffer`, `SocketConnect`, `SocketCreateTCP`, IPv6 handling).
- **External C-library deps**: full BSD sockets — `socket`/`setsockopt`/`getsockopt`/
  `bind`/`connect`/`accept`/`fcntl`/`ioctl`, `<netinet/tcp.h>`, `inet_*`.
- **Internal deps**: sockets.h compat, xstring, ResMgr, ProtoLog.
- **Nim mapping**: `chronos` transports replace nearly all of `Networker` (connect,
  non-blocking, buffers). `sockaddr_u` → chronos `TransportAddress` / `std/nativesockets`
  `Sockaddr_storage`. The address classification helpers (`is_private`, etc.) and socket
  tuning options (TOS, MAXSEG, custom bind address) are bespoke and may need
  `setSockOpt` FFI.
- **Port complexity**: **Medium** — mostly subsumed by chronos, but `sockaddr_u`
  classification and the per-socket tuning knobs (lftp resources like
  `net:socket-bind-ipv4`, TCP_MAXSEG) need hand work.
- **Gotchas**: `sockaddr_compact` packs addresses into a byte string by length
  (4/16/6/18) — a clever encoding used by the resolver cache; reproduce or replace.
  IPv6/IPV6_V6ONLY handling matters.

---

## url (url.cc / url.h)

- **Files & LOC**: url.cc (425), url.h (89) — 514 total.
- **Purpose**: URL parsing and construction with lftp-specific rules: protocol/user/
  password/host/port/path, RFC 1738 vs lftp conventions, percent encode/decode with
  per-component "unsafe" character sets, password hiding, connection-slot (`slot:`) and
  bookmark expansion.
- **Key classes/types**: `ParsedURL` (parse + `CombineTo`/`Combine`), `url` (mutable
  builder with static helpers: `encode`/`decode`, `is_url`, `path_index`,
  `dir_needs_trailing_slash`, `find_password_pos`, `remove_password`/`hide_password`).
- **External C-library deps**: none (ctype only).
- **Internal deps**: xstring, ConnectionSlot, bookmark, misc, network, log.
- **Nim mapping**: **`std/uri` is NOT sufficient.** It covers generic RFC 3986 parsing
  and `encodeUrl`/`decodeUrl`, but lftp needs: (1) per-component unsafe-char sets
  (`URL_PATH_UNSAFE`, `URL_HOST_UNSAFE`, etc. — different from `std/uri`'s fixed set),
  (2) the RFC-1738-vs-lftp toggle, (3) password hiding/locating, (4) `slot:`/bookmark
  expansion, (5) `dir_needs_trailing_slash` per-proto quirks. Use `std/uri` for the
  skeleton parse, then port the lftp-specific encode/decode and expansion logic by hand.
- **Port complexity**: **Medium** — parsing core is easy, but the encode/decode
  character-set rules and password/slot/bookmark handling are lftp-specific and
  security-relevant.
- **Gotchas**: Percent-encoding rules differ per field and from std/uri — getting these
  wrong breaks logins (e.g. `@`/`:`/`/` in usernames/passwords). `decode` is
  `warn_unused_result` — it returns fresh storage. Password-hiding logic is used in
  logs; preserve it to avoid leaking credentials.

---

## ConnectionSlot (ConnectionSlot.cc / ConnectionSlot.h)

- **Files & LOC**: ConnectionSlot.cc (89), ConnectionSlot.h (56) — 145 total.
- **Purpose**: Named saved sessions (the `slot:` mechanism) — a `KeyValueDB` mapping a
  user-chosen name to a `FileAccessRef` (live session) so `slot:work` reconnects to a
  remembered site/cwd.
- **Key classes/types**: `ConnectionSlot : KeyValueDB`, inner `SlotValue` holding a
  `FileAccessRef`. Static API: `Find`, `FindSession`, `Set`, `SetCwd`, `Remove`,
  `Format`.
- **External C-library deps**: none.
- **Internal deps**: FileAccess, keyvalue.
- **Nim mapping**: A global `Table[string, FileAccess]` + formatting. Trivial once
  FileAccess exists.
- **Port complexity**: **Low**.
- **Gotchas**: Holds live session refs — lifetime/refcount interaction with the session
  pool.

---

## Cache (Cache.cc / Cache.h)

- **Files & LOC**: Cache.cc (65), Cache.h (62) — 127 total.
- **Purpose**: Generic TTL cache base. `CacheEntry` extends `Timer` (so each entry
  expires itself); `Cache` manages a singly-linked chain with size-limit trimming and a
  resource-controlled enable flag. Base for `ResolverCache` and `LsCache`.
- **Key classes/types**: `CacheEntry : Timer`, `Cache` (`Trim`, `Flush`, `AddCacheEntry`,
  iterate helpers, `IsEnabled`/`SizeLimit` from resources).
- **External C-library deps**: none.
- **Internal deps**: Timer, ResMgr/ResType.
- **Nim mapping**: A small generic cache type — `seq`/linked structure + a monotonic
  timer (`std/times` or chronos `Moment`). Hand-written.
- **Port complexity**: **Low**.
- **Gotchas**: Entry expiry is driven by the `Timer` base + resource (`*-cache-expire`);
  size estimation via virtual `EstimateSize`.

---

## LsCache (LsCache.cc / LsCache.h)

- **Files & LOC**: LsCache.cc (292), LsCache.h (99) — 391 total.
- **Purpose**: Caches directory-listing results (raw bytes + parsed `FileSet`) per
  (session-location, arg, mode), plus a directory/file type cache. Avoids re-listing on
  the network. `FileAccess::cache` is the global instance.
- **Key classes/types**: `LsCacheEntryLoc` (key: session loc + arg + mode),
  `LsCacheEntryData` (err code + raw data + `Ref<FileSet>`), `LsCacheEntry`,
  `LsCache : Cache` (`Add`/`Find`/`FindFileSet`/`UpdateFileSet`, `IsDirectory`/
  `SetDirectory`, `Changed`/`FileChanged`/`DirectoryChanged`/`TreeChanged`).
- **External C-library deps**: none.
- **Internal deps**: Cache, FileAccess, FileSet, Buffer.
- **Nim mapping**: Hand-written on top of the ported `Cache`; key is a tuple/string.
- **Port complexity**: **Low-Medium**.
- **Gotchas**: Invalidation (`Changed` with FILE/DIR/TREE granularity) must be wired
  into every mutating operation across protocols, or stale listings appear. Stores a
  live `FileSet` ref shared with callers.

---

## IdNameCache (IdNameCache.cc / IdNameCache.h)

- **Files & LOC**: IdNameCache.cc (186), IdNameCache.h (110) — 296 total.
- **Purpose**: Bidirectional uid↔username and gid↔groupname caches (so listings show
  names not numbers) with periodic expiry. `PasswdCache`/`GroupCache` singletons.
- **Key classes/types**: `IdNameCache : SMTask` (dual hash tables id→name / name→id,
  virtual `get_record`), `PasswdCache`, `GroupCache`, `IdNamePair` (interned via
  `StringPool`).
- **External C-library deps**: `<pwd.h>`/`<grp.h>` — `getpwuid`/`getpwnam`/`getgrgid`/
  `getgrnam`.
- **Internal deps**: SMTask, Timer, StringPool.
- **Nim mapping**: `std/posix` exposes `getpwuid`/`getgrgid` etc. A `Table[int,string]`
  + `Table[string,int]` with expiry. Hand-written, small.
- **Port complexity**: **Low**.
- **Gotchas**: Names are interned (`StringPool`) and handed out as `const char*`;
  FileInfo holds those pointers — in Nim just use `string` and accept the copies, or
  intern.

---

## DirColors (DirColors.cc / DirColors.h)

- **Files & LOC**: DirColors.cc (400), DirColors.h (58) — 458 total.
- **Purpose**: Parses `LS_COLORS`/`dircolors`-style spec and returns ANSI color codes
  per file type/extension for colored listings (a `coreutils`-compatible `dircolors`).
- **Key classes/types**: `DirColors : ResClient, KeyValueDB` singleton — `Parse`,
  `GetColor(FileInfo*)`, `PutColored`, `PutReset`.
- **External C-library deps**: none (reads env/resource string).
- **Internal deps**: SMTask, keyvalue, buffer, FileInfo, ResMgr.
- **Nim mapping**: Port the `LS_COLORS` parser by hand; `std/terminal` for ANSI. Small
  self-contained parser.
- **Port complexity**: **Low-Medium**.
- **Gotchas**: Must match GNU `dircolors` syntax (`*.ext`, type keys `di`/`ln`/`ex`…) to
  honor users' existing `LS_COLORS`.

---

## ColumnOutput (ColumnOutput.cc / ColumnOutput.h)

- **Files & LOC**: ColumnOutput.cc (222), ColumnOutput.h (71) — 293 total.
- **Purpose**: Lays out a list of (name, color) cells into terminal columns
  (`ls`-style vertical multi-column layout), computing column widths to fit terminal
  width.
- **Key classes/types**: `datum` (one cell: parallel `StringSet` of name-segments and
  colors), `ColumnOutput` (`add`/`addf`/`append`, `SetWidth`, `print`,
  `get_print_info` column-fitting).
- **External C-library deps**: none.
- **Internal deps**: OutputJob, xarray/StringSet.
- **Nim mapping**: Pure layout math — port by hand; `std/terminal.terminalWidth` for
  width.
- **Port complexity**: **Low**.
- **Gotchas**: Width math must account for color escapes being zero-width and for
  multi-segment colored names.

---

## Subsystem summary

- **Total LOC**: ≈ 10,540 across 30 files (.cc + .h).
- **Overall complexity**: **High**, driven almost entirely by `FileAccess` itself (the
  universal contract) and the size/correctness-sensitivity of `FileSet`/`parse_ls_line`,
  `Resolver`, and `url`. The peripheral caches and output formatters are individually
  Low/Medium. chronos meaningfully reduces `NetAccess`, `Resolver` (A/AAAA), and
  `network` by replacing fork-based DNS, the poll loop, and manual socket management;
  but the cooperative `Do()` scheduler, lftp-specific URL encoding, SRV records, the
  FileSet set-algebra, and `ls -l` parsing are all hand-written work with no stdlib
  shortcut.

### The FileAccess virtual contract (the key port decision)

Every protocol backend in lftp is a subclass of `FileAccess` that implements this
contract. Get this interface right first; all of subsystem 03+ depends on it:

```
Abstract (must implement):
  GetProto() -> string                 // protocol id
  Clone() -> FileAccess                // copy session config
  Read(buf, size) -> int               // >=0 bytes, or negative status code
  Write(buf, size) -> int              // >=0 bytes accepted, or negative status
  StoreStatus() -> int                 // poll a STORE to completion
  Do() -> int                          // non-blocking pump; advance state machine
  Done() -> int                        // IN_PROGRESS / OK / negative error

Driven via:
  Open(file, mode, pos)                // mode ∈ open_mode enum (RETRIEVE, STORE,
                                       // LIST, LONG_LIST, CHANGE_DIR, MAKE_DIR,
                                       // REMOVE, RENAME, CHANGE_MODE, LINK, SYMLINK,
                                       // ARRAY_INFO, QUOTE_CMD, CONNECT_VERIFY, …)
  Close()                              // end op, keep connection
  status codes: OK / IN_PROGRESS / SEE_ERRNO / LOOKUP_ERROR / NO_FILE /
                NO_HOST / LOGIN_FAILED / FATAL / NOT_SUPP / DO_AGAIN / …

Lifecycle / config (mostly virtual with base defaults):
  Connect/Login/ResetLocationData, Chdir, IsConnected, DisconnectLL, Cleanup,
  SameLocationAs/SameSiteAs, NeedSizeDateBeforehand, UseCache

Factories each backend provides:
  MakeListInfo(path) -> ListInfo       // async directory listing operation
  MakeGlob(pattern)  -> Glob           // wildcard expansion
  MakeDirList(argv)  -> DirList        // human-readable ls
  ParseLongList(buf,len) -> FileSet    // parse server `ls -l` text
```

Usage pattern (caller side): `Open(...)`, then loop pumping `Do()` until `Done()`
leaves `IN_PROGRESS`, calling `Read`/`Write` to move bytes. Sessions are pooled and
matched by `SameSiteAs`/`SameLocationAs` for reuse. **Port decision to settle up
front:** keep this synchronous `Do()` state-machine model (faithful, low-risk, but
non-idiomatic under chronos) vs. rewrite each backend as chronos `{.async.}` procs
(idiomatic, but rewrites every protocol and changes the contract). Recommend
prototyping `LocalAccess` both ways before committing, since it is the smallest
complete implementation of the contract.
```
