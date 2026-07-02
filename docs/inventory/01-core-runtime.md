# Inventory 01 — Core runtime & infrastructure

lftp 4.9.3 → Nim (chronos) port planning. Source: `/Users/studiox/Downloads/lftp/src/src/` (flat directory).

This subsystem is the cooperative scheduler, timing/IO-readiness plumbing, and the
hand-rolled container/string library that the rest of lftp is built on. It is the
foundation everything else depends on, so its design dictates how the whole port is
structured.

---

## SMTask (cooperative scheduler — the heart of lftp)

- **Files & LOC**: `SMTask.cc` (334), `SMTask.h` (187). `SMTaskRef` lives *inside*
  `SMTask.h` (there is no separate `SMTaskRef.h`). Total ~521.
- **Purpose**: lftp's single-threaded cooperative ("state machine") scheduler. Every
  active object derives from `SMTask` and implements `int Do()`; the scheduler runs each
  task's `Do()` repeatedly until the whole program is idle, then blocks on `select()`.
- **Key classes/types**:
  - `SMTask` — abstract base; pure virtual `Do()`. Tasks register themselves on four
    intrusive `xlist` lists: `all_tasks`, `ready_tasks`, `new_tasks`, `deleted_tasks`.
    Lifecycle flags: `suspended`, `suspended_slave`, `running` (re-entrancy depth),
    `ref_count`, `deleting`.
  - `SMTaskRef<T>` — intrusive smart pointer keyed on `ref_count`. Assignment goes
    through `_SetRef`. Non-cloning, non-assignable from another ref (only from raw `T*`).
    `borrow()` releases ownership without deleting.
  - `TaskRefArray<T>` — `_RefArray` specialized with `SMTaskRef`.
  - `SMTaskInit` — sentinel root task pinned on the `Enter`/`Leave` stack.
- **How the scheduler actually works** (critical for the port):
  - `Do()` returns `STALL` (0) or `MOVED` (1). `MOVED` means "I made progress, call me
    again"; `STALL` means "I'm blocked, nothing to do."
  - `Schedule()` is one tick: empty the `block` PollVec, `UpdateNow()`, set the timeout
    from `Timer::GetTimeoutTV()`, run all new + ready tasks' `Do()` once each
    (`ScheduleThis`), `CollectGarbage()`, and if anything `MOVED`, call `block.NoWait()`
    so the next `select()` returns immediately.
  - Tasks declare interest in fds/timeouts *from inside `Do()`* via the static
    `Block(fd,mask)` / `Timeout*(ms)` calls, which push into the shared `PollVec block`.
    Readiness is read back via `Ready(fd,mask)`.
  - `Block()` calls `block.Block()` → `select()`. The main loop (in `lftp.cc`/`Job`,
    outside this subsystem) alternates `Schedule()` and `Block()`.
  - `Enter`/`Leave` maintain `current` and a 64-deep task stack so a task can recurse
    into `Roll()`-ing another task. `Roll()` drives one task to a stall in isolation.
  - **Deletion is deferred**: `Delete()` → `DeleteLater()` flips `deleting`, parks the
    task on `deleted_tasks`; `CollectGarbage()` frees it only when `running==0 &&
    ref_count==0`. This is how lftp safely deletes a task from inside its own `Do()`.
  - `Suspend`/`Resume` plus `SuspendSlave`/`ResumeSlave` (a 2-bit suspension: a task is
    runnable only if neither the owner nor a slave-suspend is set). `SuspendInternal`/
    `ResumeInternal` propagate to child tasks.
- **External C-library deps**: libc only (`errno`, `strerror`, `time`).
- **Internal deps**: `PollVec`, `TimeDate`, `Timer`, `Ref`, `xarray`, `xlist` (out of
  subsystem), `misc`, `Error`, `ResMgr` (for `xfer:disk-full-fatal`).
- **Nim mapping**: This is the single most important design decision of the port.
  - The natural target is **chronos async/await**. Each `SMTask` subclass becomes an
    `async proc` (a long-lived loop), and the `Do()`-returns-`MOVED`-until-`STALL`
    pattern collapses into ordinary `await` on the event the task is waiting for
    (`await stream.read()`, `await sleepAsync(...)`, `await fd.wait(Read)`). The
    hand-written `Schedule()`/`Block()`/`PollVec`/`select` loop is **entirely replaced**
    by chronos's `runForever()` / poll loop — it disappears.
  - `SMTaskRef`/`ref_count` deferred deletion mostly disappears under Nim's GC: shared
    ownership becomes a `ref object`, cyclic references handled by ORC. The deferred-
    delete-from-inside-Do trick exists *because* C++ can't free `this` mid-method; with
    async + GC that hazard is gone.
  - Suspend/Resume map to pausing/resuming a future, or to an `AsyncEvent`/condition the
    task awaits. Slave suspension (parent suspends children) maps to cancelling/awaiting
    child futures.
- **Port complexity**: **High** — not because the code is large, but because it is the
  paradigm of the entire codebase. Every other module is written against the `Do()`
  state-machine contract; converting them to async/await is the bulk of the whole port.
- **Gotchas**:
  - Re-entrancy: `Roll()` and `running` counter allow a task to be `Do()`-ed while
    already on the stack. async/await handles this differently; watch for places that
    assume synchronous completion of a nested `Roll()`.
  - `Ready(fd,mask)` semantics: an fd that was never polled is reported *ready* (see
    `PollVec::FDReady`) so first-time reads are attempted optimistically. Preserve this
    "try first, poll on EAGAIN" behavior.
  - Deferred deletion ordering and the `IncRefCount`/`DecRefCount` "protect next from
    deleting" dance inside the list loops must not be naively dropped.

## Ref.h (non-intrusive owning pointers)

- **Files & LOC**: `Ref.h` (72, header-only).
- **Purpose**: `unique_ptr`-style owning smart pointer for non-`SMTask` heap objects.
- **Key types**: `Ref<T>` (single object, `delete`), `RefToArray<T>` (`delete[]`),
  plus a static `null`. Non-cloning, non-assignable from another `Ref`.
- **External deps**: none. **Internal deps**: `misc` (`replace_value`).
- **Nim mapping**: **Vanishes** — replaced by Nim `ref object` + GC, or `owned`/`move`
  semantics. `RefToArray` → `seq[T]`.
- **Port complexity**: **Low**. **Gotchas**: code relies on `Ref` auto-deleting on
  reassignment; with GC that's automatic but destruction *timing* differs (no RAII).

## Timer

- **Files & LOC**: `Timer.cc` (179), `Timer.h` (80).
- **Purpose**: one-shot/relative timers integrated with the scheduler; the global set of
  running timers determines the `select()` timeout each tick.
- **Key classes/types**: `Timer` — holds `start`/`stop` `Time`, a `TimeInterval`
  setting, optional randomization, and optional resource binding (auto-reconfig from
  `ResMgr`). Registered on an intrusive `xlist all_timers` and an `xheap running_timers`
  (min-heap by time-left). Static `GetTimeoutTV()` returns next expiry for `SMTask`.
- **External deps**: libc (`gettimeofday`). **Internal deps**: `SMTask::now`, `TimeDate`,
  `xlist`, `xheap`, `ResMgr`, `xstring`.
- **Nim mapping**: Largely **vanishes** → `chronos.sleepAsync` / `addTimer` / deadlines.
  The global min-heap is chronos's internal timer wheel. Resource-bound auto-reconfig
  (rebind on config change) is the only bit needing hand-written glue.
- **Port complexity**: **Low–Medium**. **Gotchas**: `AddRandom()` jitter and
  `ResetDelayed`/`StopDelayed` semantics; `Stopped()` is false for infinite timers.

## PollVec

- **Files & LOC**: `PollVec.cc` (79), `PollVec.h` (79).
- **Purpose**: thin wrapper over `select()` accumulating the set of fds/timeouts all
  tasks want this tick, plus the readiness result.
- **Key classes/types**: `PollVec` — six `fd_set`s (want/polled/ready × in/out),
  `nfds`, `tv_timeout`. `Block()` calls `select()`; `FDReady` reports readiness with the
  "never-polled ⇒ ready" optimism noted above. Despite including `<poll.h>` for the
  `POLLIN/POLLOUT` enum values, the implementation uses `select()`.
- **External deps**: libc `select`/`fd_set`. **Internal deps**: none.
- **Nim mapping**: **Vanishes entirely** — chronos owns the event loop / fd registration
  (epoll/kqueue). No equivalent object is needed.
- **Port complexity**: **Low** (by deletion). **Gotchas**: the deadlock-detection guard
  and the `select()`-vs-`poll()` naming mismatch; `FD_SETSIZE` limit is gone for free.

## SignalHook

- **Files & LOC**: `SignalHook.cc` (99), `SignalHook.h` (52).
- **Purpose**: install/restore POSIX signal handlers and count signal deliveries
  (SIGINT/SIGHUP/SIGCHLD/etc.) for the scheduler to poll.
- **Key classes/types**: `SignalHook` — all-static; `counts[]`, saved `old_handlers`,
  a counting handler `cnt_handler`, plus `Handle/Ignore/Default/Block/Unblock/Restore`.
- **External deps**: libc `sigaction`/`sigprocmask`. **Internal deps**: none.
- **Nim mapping**: chronos provides `addSignal`/`SignalHandle` (async signal handling);
  the count-and-poll pattern becomes an async signal callback. Some hand-written glue for
  save/restore of original dispositions.
- **Port complexity**: **Low**. **Gotchas**: async-signal-safety of the handler; signal
  masking around critical sections.

## ProcWait

- **Files & LOC**: `ProcWait.cc` (141), `ProcWait.h` (67).
- **Purpose**: an `SMTask` that reaps child processes (`waitpid`) and tracks their exit
  status; driven by SIGCHLD counts from `SignalHook`.
- **Key classes/types**: `ProcWait : SMTask` — `pid`, `status` (RUNNING/TERMINATED/
  ERROR), `term_info`; static `xmap<ProcWait*> all_proc` keyed by pid string. `Do()`
  polls `waitpid(WNOHANG)`. `Kill()`, `Auto()` (self-delete on exit).
- **External deps**: libc `waitpid`, `kill`, signals. **Internal deps**: `SMTask`,
  `xmap`, `SignalHook` (in `.cc`).
- **Nim mapping**: chronos `AsyncProcess` / `osproc` + an async waitpid; or a small
  hand-written async wrapper. The `xmap`-by-pid registry → `Table[Pid, ...]`.
- **Port complexity**: **Low–Medium**. **Gotchas**: SIGCHLD races; `WNOHANG` polling
  vs. chronos's process-exit primitive; auto-die ordering with deferred deletion.

## buffer / buffer_std (the I/O buffering layer)

- **Files & LOC**: `buffer.cc` (904), `buffer.h` (310), `buffer_std.cc` (45),
  `buffer_std.h` (35). Total ~1294 — the largest module in the subsystem.
- **Purpose**: the universal byte-stream buffer used by every transfer/protocol path.
  Provides growable in-memory buffering, formatted append, big-endian pack/unpack,
  optional iconv recoding, rate metering, and the async `IOBuffer` family that pumps
  bytes to/from fds and `FileAccess` sessions.
- **Key classes/types**:
  - `Buffer` — core ring-ish buffer over an `xstring` with `buffer_ptr` consume offset;
    `Get/Skip/Put/Append/Prepend/Format`, error state, `pos`, save-for-cache, optional
    `Speedometer`, and `Pack/Unpack{INT,UINT}{8,16,32,64}BE`.
  - `DataTranslator` / `DataRecoder` (iconv) / `DirectedBuffer` (GET vs PUT + optional
    translator).
  - `IOBuffer : DirectedBuffer, SMTask` — async engine; virtual `Get_LL/Put_LL/PutEOF_LL`,
    `Do()`, `Done()`, max-buffer throttle, event-time for timeout detection.
  - Concrete: `IOBufferStacked` (chain buffers), `IOBufferFDStream` (fd-backed),
    `IOBufferFileAccess` (protocol-session-backed), `IOBuffer_STDOUT` (`buffer_std`,
    writes to a `Job`'s stdout).
- **External deps**: **iconv** (optional, `HAVE_ICONV`) for charset recoding. Otherwise
  libc only.
- **Internal deps**: `SMTask`, `xstring`, `Speedometer`, `Timer`, `Filter`/`FDStream`/
  `fg`, `FileAccess`, `Ref`/`SMTaskRef`, `log`.
- **Nim mapping**: Split it:
  - The pure `Buffer` byte-store → a hand-written buffer type over `seq[byte]`/`string`
    (Nim's `streams`/`StringStream` is too weak; chronos `AsyncBuffer` partially helps).
    Pack/unpack BE → `std/endians`. Formatted append → `strformat`/`&`.
  - `IOBuffer*` (the async pumps) → chronos `AsyncStream`/transport read/write loops.
    `Get_LL/Put_LL` become `await transport.read/write`. Backpressure (`IsFull`,
    `max_buf`) maps to bounded chronos `AsyncStream` queues.
  - `DataRecoder` → bind to `iconv` (or `std/unicode`/encodings) — keep as C dep.
- **Port complexity**: **High** — large, central, mixes pure data structure with async
  IO and the `SMTask` contract; touched by nearly every protocol module.
- **Gotchas**: `buffer_ptr` consume-without-shift semantics (and `UnSkip`); the
  cache-save (`Save`/`SaveRollback`) path; iconv partial-multibyte state at EOF;
  `MoveDataHere` zero-copy transfers between buffers; `GetSpace`/`SpaceAdd` exposing raw
  storage for in-place fills.

## xstring (dynamic string)

- **Files & LOC**: `xstring.cc` (627), `xstring.h` (294).
- **Purpose**: lftp's small/fast dynamic string + an `xstrdup/xfree` replacement; the
  string type used everywhere (keys, paths, formatted output).
- **Key classes/types**: `xstring0` (base, owns `char* buf`), `xstring_c` (compact,
  NUL-terminated, `strdup`-style), `xstring` (full: tracks `size`+`len`, growable, binary-
  safe, `append/prepend/setf/vappendf/url_decode/hex/quote/cat/join`, plus a per-thread
  `get_tmp()` scratch pool). `xstring_clonable` enables explicit copy via `.copy()`.
- **External deps**: libc; `trio`/`snprintf`. **Internal deps**: `xmalloc`.
- **Nim mapping**: Mostly **vanishes** → Nim's native `string` (length-prefixed, binary-
  safe, GC-managed). `xstring_c` → `string` or `cstring` at FFI edges. Formatting →
  `strformat`/`&`. URL/hex helpers → small hand-written procs (or `std/uri`).
- **Port complexity**: **Low–Medium**. **Gotchas**:
  - `get_tmp()` returns a **shared static temporary** — callers must consume it before
    the next `get_tmp()` call. This is used pervasively (`xstring::get_tmp(key)` in
    `xmap::lookup(const char*)`); the Nim port should just return fresh `string`s and
    drop the aliasing, but audit any code that relied on the shared buffer's lifetime.
  - Binary-safe (`len` separate from NUL) vs. C-string callers — Nim `string` handles
    this natively but FFI boundaries need care.
  - `borrow()` / `set_allocated()` ownership transfers disappear under GC.

## xarray (dynamic array)

- **Files & LOC**: `xarray.cc` (109), `xarray.h` (274).
- **Purpose**: hand-rolled `std::vector` equivalent + several ownership variants and a
  queue, used for all of lftp's growable collections.
- **Key classes/types**: `xarray0` (untyped base, `element_size`, grow/shrink, qsort,
  bsearch, insert-ordered), `xarray<T>` (POD values), `_RefArray`/`RefArray<T>`
  (arrays of `Ref<T>`), `xarray_s` (array of string-refs), `xarray_p<T>` (array of
  `new`'d pointers, auto-`delete`), `xarray_m<T>` (array of `malloc`'d pointers,
  `xfree`), `_xqueue`/`xqueue`/`xqueue_p`/`xqueue_m`/`RefQueue` (FIFO over an array with
  a read pointer).
- **External deps**: libc (`qsort`, `realloc`). **Internal deps**: `xmalloc`, `Ref`.
- **Nim mapping**: **Vanishes** → `seq[T]`. Sorting → `std/algorithm` `sort`/`binarySearch`.
  The pointer-owning variants (`xarray_p/_m/RefArray`) collapse into `seq[ref T]` under
  GC. Queues → `std/deque`.
- **Port complexity**: **Low**. **Gotchas**: `keep_extra` (NUL-terminated pointer arrays,
  used by `StringSet`/`StringPool`); manual `borrow()`/`move_here()` ownership transfers;
  `_xqueue` compacts lazily (read pointer + occasional shift) — `Deque` does this for free.

## xmap (hash map)

- **Files & LOC**: `xmap.cc` (175), `xmap.h` (161).
- **Purpose**: string-keyed hash map; backing store for registries (e.g. `ProcWait`,
  rate limits, caches).
- **Key classes/types**: `_xmap` (untyped: chained-bucket hashtable of `entry{next,
  xstring key}` + inline payload, rehashing, iteration cursor), `xmap<T>` (value
  payload, `lookup`/`operator[]`/`add`/`remove`/`each_*`), `xmap_p<T>` (owns `new`'d
  pointer payloads).
- **External deps**: none. **Internal deps**: `xarray`, `xstring`.
- **Nim mapping**: **Vanishes** → `std/tables` `Table[string, T]` / `TableRef`. The
  `each_begin/each_next` cursor → `for k, v in t.pairs`.
- **Port complexity**: **Low**. **Gotchas**: payload is stored *inline after the entry*
  (`*(T*)(e+1)`) — a C trick that's irrelevant in Nim; the iteration cursor is stateful
  (single shared `each_entry`) so concurrent iteration is unsafe — Nim iterators remove
  this hazard.

## xmalloc

- **Files & LOC**: `xmalloc.cc` (167), `xmalloc.h` (51).
- **Purpose**: checked allocation wrappers (`xmalloc`/`xrealloc`/`xfree`/`xstrdup`/
  `xstrset`) that abort on OOM, plus `alloca`-based stack-dup macros.
- **External deps**: libc `malloc` family; optional `dbmalloc`. **Internal deps**: none.
- **Nim mapping**: **Vanishes** → Nim GC allocator. `alloca_strdup` stack tricks have no
  Nim equivalent and are simply dropped (use locals/`string`).
- **Port complexity**: **Low**. **Gotchas**: abort-on-OOM behavior; `xstrdup(s,spare)`'s
  extra-capacity argument; only relevant at FFI boundaries (`alloc0`/`dealloc`).

## StringPool

- **Files & LOC**: `StringPool.cc` (52), `StringPool.h` (34).
- **Purpose**: global interning pool — `Get(s)` returns a single canonical, never-freed
  copy of a string so identical strings share storage and can be pointer-compared.
- **Key classes/types**: `StringPool` (all-static; `xarray_m<char> strings` kept sorted,
  binary-searched).
- **External deps**: none. **Internal deps**: `xarray`.
- **Nim mapping**: Hand-write a tiny intern table (`Table[string, string]` or a
  `HashSet[string]`) — small. Pointer-identity comparison must become value comparison.
- **Port complexity**: **Low**. **Gotchas**: interned strings are immortal (intentional
  leak); any code doing `ptr==ptr` identity checks must switch to `==`.

## StringSet

- **Files & LOC**: `StringSet.cc` (96), `StringSet.h` (65).
- **Purpose**: an owned, NULL-terminated `char**` vector — the natural form for argv-style
  lists passed to subprocesses and protocol commands.
- **Key classes/types**: `StringSet` over `xarray_m<char>`; append/insert/replace/pop,
  format-append, sort, `borrow()` to a raw `char**`.
- **External deps**: libc. **Internal deps**: `xarray`, `xstring`.
- **Nim mapping**: → `seq[string]`. Conversion to `cstringArray` only at `exec`/FFI
  boundaries (`std/os` `allocCStringArray`).
- **Port complexity**: **Low**. **Gotchas**: the trailing-NULL terminator (`keep_extra=1`)
  matters only at the C-exec boundary.

## keyvalue

- **Files & LOC**: `keyvalue.cc` (210), `keyvalue.h` (133).
- **Purpose**: simple ordered key/value store with file load/save and fcntl locking —
  used for on-disk databases (bookmarks, cache index, known-hosts-style files).
- **Key classes/types**: `KeyValueDB` (singly-linked `Pair{key,value,next}` chain, with
  `Add/Remove/Lookup/Sort/Write(fd)/Read(fd)/Format`, a rewind/Next iterator cursor, and
  `Lock(fd,type)`); `StringMangler` (pluggable key transform). `Pair`/`NewPair` are
  virtual for subclassing.
- **External deps**: libc `fcntl` (file locking), read/write. **Internal deps**: `xstring`.
- **Nim mapping**: `OrderedTable[string,string]` + hand-written serialization; locking →
  `std/posix` `fcntl` or a lockfile. The virtual `Pair`/`NewPair` subclass-extension
  point needs `method`/inheritance if subclasses rely on it.
- **Port complexity**: **Low–Medium**. **Gotchas**: file-format compatibility (must round-
  trip existing lftp db files byte-for-byte); fcntl lock semantics; the iteration cursor.

## Error

- **Files & LOC**: `Error.cc` (37), `Error.h` (43).
- **Purpose**: a value-type error object (text + numeric code + fatal flag).
- **Key classes/types**: `Error{xstring text; int code; bool fatal}` + static
  `Error::Fatal(...)`.
- **External deps**: none. **Internal deps**: `xstring`.
- **Nim mapping**: → a small `object`/`ref object`, or fold into chronos/Nim exception
  types. Trivial.
- **Port complexity**: **Low**. **Gotchas**: lftp distinguishes fatal vs. retryable
  (network) errors — preserve that flag; `SMTask::SysError`/`NonFatalError` produce these.

## TimeDate

- **Files & LOC**: `TimeDate.cc` (227), `TimeDate.h` (159).
- **Purpose**: time/duration value types used throughout (scheduler clock, timers,
  speedometer, timeouts).
- **Key classes/types**: `time_tuple` (sec+usec base, normalize/add/sub/compare),
  `Time` (absolute, `SetToCurrentTime`, `UnixTime`/`Milli`/`Micro`), `TimeDate` (adds
  cached `struct tm` local-time fields + `IsoDateTime()`), `TimeDiff` (signed duration,
  `toTimeval`), `TimeInterval` (`TimeDiff` + `infty` flag, `toString`).
- **External deps**: libc `gettimeofday`/`localtime`/`strftime`. **Internal deps**: none.
- **Nim mapping**: → `std/times` (`Time`, `Duration`, `DateTime`) and chronos `Moment`/
  `Duration` for deadlines. The `infty` interval flag and `toString` formatting are small
  hand-written additions.
- **Port complexity**: **Low**. **Gotchas**: microsecond precision and `normalize()` of
  the borrow/carry in `time_tuple`; the `infty` sentinel used by `TimeInterval`/`Timer`.

## RateLimit

- **Files & LOC**: `RateLimit.cc` (198), `RateLimit.h` (80).
- **Purpose**: token-bucket bandwidth limiter, layered per-connection / per-host / total,
  separately for GET and PUT directions.
- **Key classes/types**: `RateLimit` (level enum, parent pointer, `BytesPool pool[2]`),
  inner `BytesPool` (token bucket: `pool`, `rate`, `pool_max`, time-based refill via
  `AdjustTime`). Global `xmap_p<RateLimit> *total` for per-host/total aggregation.
  `BytesAllowed`/`BytesUsed`, `LimitBufferSize`, `SetBufferSize` throttle `IOBuffer`s.
- **External deps**: none. **Internal deps**: `TimeDate`, `buffer`/`IOBuffer`, `xmap`,
  `ResMgr` (rate config).
- **Nim mapping**: Hand-write the token bucket (small, pure arithmetic over `Moment`).
  Integrates with chronos `AsyncStream` backpressure rather than `IOBuffer` sizing. The
  `xmap_p` host registry → `Table`.
- **Port complexity**: **Medium**. **Gotchas**: the multi-level parent chaining and the
  GET/PUT split; correct token refill across time gaps; coupling to buffer sizing logic.

## Speedometer

- **Files & LOC**: `Speedometer.cc` (169), `Speedometer.h` (57).
- **Purpose**: exponential-decay transfer-rate meter + ETA string formatting; attached to
  `Buffer`s and shown in the UI.
- **Key classes/types**: `Speedometer : ResClient` — `period`, decaying `rate`,
  timestamps; `Add(bytes)`, `Get()`, `GetStr`/`GetStrS` (human "x.y KiB/s"), `GetETAStr*`.
  Reconfigurable period via `ResMgr`.
- **External deps**: none. **Internal deps**: `SMTask` (`now`), `ResMgr`/`ResClient`,
  `xstring`, `TimeDate`.
- **Nim mapping**: Hand-write — small pure-math class over `std/times`; formatting via
  `strformat`. Decouple from `ResClient` (config subsystem) once that subsystem is ported.
- **Port complexity**: **Low**. **Gotchas**: the EMA decay formula and period semantics
  must match for stable UI numbers; ETA edge cases (zero/negative rate).

---

## Subsystem summary

- **Total LOC**: ~6,081 across 35 files (the 34 listed files; `SMTaskRef` is inlined in
  `SMTask.h`). Largest: `buffer` (~1,294), `xstring` (~921), `SMTask` (~521).
- **Overall complexity**: **Medium-High**. Individually most modules are Low (they are
  reimplementations of things Nim's stdlib/GC give for free). The complexity is
  concentrated in two places: the **SMTask scheduler paradigm** and the **buffer/IOBuffer
  async-IO layer**, and in the fact that the *entire rest of lftp* is written against
  these two contracts.
- **Single hardest porting challenge**: **Re-expressing the `SMTask` cooperative
  state-machine model as chronos async/await.** The mechanical translation of `SMTask`
  itself is small, but every `Do()`-returning-`MOVED/STALL` method in every protocol/job
  module must be rewritten as an `async proc` with `await` points. This is a paradigm
  shift, not a line-by-line port, and it ripples through the whole codebase. The
  buffer/IOBuffer layer is the second hardest because it straddles pure data and async IO.
- **Modules that essentially vanish** (replaced by Nim stdlib / chronos):
  - `PollVec` → chronos event loop (gone entirely)
  - `Timer` → chronos `sleepAsync`/timers (mostly gone)
  - `xmalloc` → Nim GC allocator
  - `xstring` → Nim `string`
  - `xarray` → `seq` / `std/deque`
  - `xmap` → `std/tables`
  - `Ref` → `ref object` + GC/ORC
  - `TimeDate` → `std/times` + chronos `Moment`
  - much of `SignalHook` → chronos `addSignal`
  - The `SMTask` scheduler *loop* (Schedule/Block/CollectGarbage) → chronos `runForever`;
    only the per-task lifecycle modeling survives as async procs.
- **Stays hand-written**: `Buffer` core byte-store, `RateLimit` token bucket,
  `Speedometer`, `StringPool` interning, `keyvalue` DB (file-format + locking), `Error`,
  and the `IOBuffer` async pumps (as chronos stream loops).
