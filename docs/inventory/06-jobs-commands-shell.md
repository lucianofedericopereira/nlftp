# Subsystem 07 — Command Interpreter, Jobs & Interactive Shell

Inventory of lftp 4.9.3 for a Nim port. Source: `/Users/studiox/Downloads/lftp/src/src/` (flat).

This subsystem is the heart of lftp's user-facing behaviour: it parses the command
line, looks commands up in a table, builds `Job` objects, and runs them on a
cooperative (non-threaded) scheduler. It also owns the readline integration, tab
completion, command aliases, bookmarks, the background-job queue, and every
concrete job type — including the crown jewel, **MirrorJob**.

> **Cross-cutting dependency (read first):** Everything here is built on the
> `SMTask` cooperative scheduler (file `SMTask.cc/.h`, *outside* this subsystem).
> A `Job` *is a* `SMTask`. The scheduler repeatedly calls each task's `Do()`
> method, which must do a small chunk of work and return `MOVED` (made progress),
> `STALL` (no progress), or `WANTDIE`. **There are no threads** — all "parallelism"
> (parallel transfers, background jobs) is single-threaded event multiplexing over
> non-blocking fds with `poll()`. This model dictates the entire Nim port strategy
> and is noted repeatedly below.

---

## (A) Command / Shell Infrastructure

### A1. CmdExec — the command interpreter & job container

- **Files & LOC:** `CmdExec.cc` (1334), `CmdExec.h` (277). Total ~1611.
- **Purpose:** Central engine. It is *both* a `Job` (a `SessionJob`, so it owns a
  `FileAccess` session = "current connection") *and* the shell. It buffers fed
  command text, parses one command at a time, expands aliases, performs glob
  expansion, dispatches to a command creator, attaches the resulting child `Job`,
  manages backgrounding, redirection (`>`, `>>`, `|`), conditional chaining
  (`&&`, `||`, `;`), the prompt, builtins (`cd`, `open`, `lcd`, `exit`, `lftp`,
  `queue`, `glob`, `local`), command modules, and the background queue.
- **Key classes/types:**
  - `class CmdExec : public SessionJob, public ResClient`
  - `struct cmd_rec { name; cmd_creator_t creator; short_desc; long_desc; }` — one
    row of the command table.
  - `typedef Job *(*cmd_creator_t)(CmdExec *parent)` — every command is a factory
    function returning a `Job` (or `this`/NULL for builtins).
  - `class CmdFeeder` — abstract source of command text (interactive readline feeder,
    file feeder, queue feeder, alias feeder). Chained via `prev`.
  - `enum builtins { BUILTIN_NONE, BUILTIN_OPEN, BUILTIN_CD, BUILTIN_EXEC_RESTART,
    BUILTIN_GLOB }` — builtins that need to run *inside* CmdExec's own `Do()` state
    machine rather than as a separate job.
- **Dispatch mechanism (`find_cmd` + `exec_parsed_command`, CmdExec.cc:131-255):**
  1. `parse_one_cmd()` splits the buffer into an `ArgV`.
  2. `find_cmd(name, &rec)` does a **linear, case-insensitive scan** of the command
    table (`strcasecmp`), *also* accepting unambiguous prefix abbreviations
    (`strncasecmp`); returns count of partial matches (0 = unknown, >1 = ambiguous,
    1 = found).
  3. `args->setarg(0, c->name)` canonicalizes an abbreviated name.
  4. If `creator==0` → it's a dynamically-loadable module: `default_cmd()` calls
    `load_cmd_module()` (`dlopen`) and re-dispatches via `BUILTIN_EXEC_RESTART`.
  5. Otherwise `new_job = c->creator(this)`. If the creator returns `this` or sets a
    `builtin`, the work continues in CmdExec's `Do()`; else `AddNewJob(new_job)`
    attaches it as a child and (unless backgrounded) waits on it.
  - Table is `static_cmd_table[]`; `RegisterCommand()` lazily copies it into a
    sorted `dyn_cmd_table` (`xarray`, `bsearch`) so modules can add/override commands.
- **External C-library deps:** none directly (string libc, `dlopen` for modules via
  `lt_dlopen`/libltdl indirectly).
- **Internal deps:** `Job`, `ArgV`, `alias`, `History`, `bookmark`, `FileGlob`/`GlobURL`,
  `QueueFeeder`, `FileAccess`, `ResMgr` (settings), `SignalHook`, `StatusLine`, `SMTask`.
- **Nim mapping:** `CmdExec` → a `ref object` that is both a scheduler task and holds
  the parse buffer. Command table → a `seq[CmdRec]` or `Table[string, CmdCreator]`
  where `CmdCreator = proc(parent: CmdExec): Job`. The builtin state machine maps to a
  Nim `case` enum inside the task's `do()` proc. `CmdFeeder` → a small abstract
  `ref object` / closure iterator yielding command strings.
- **Port complexity:** **High.** It is a large hand-written state machine with many
  intertwined concerns (parsing, globbing, redirection, queue, builtins, prompt).
- **Gotchas:** Prefix-abbreviation matching is user-visible behaviour and must be
  preserved. `BUILTIN_EXEC_RESTART` `goto restart` re-entrancy. The CWD is *global*
  and "owned" by one CmdExec at a time (`cwd_owner`, `SaveCWD`/`RestoreCWD`) — a
  subtle invariant when multiple CmdExecs (subshells, queues) exist. `cmd:fail-exit`,
  `cmd:trace`, conditional operators all affect control flow.

### A2. commands.cc — the command table + all command creators

- **Files & LOC:** `commands.cc` (3677). Largest file in the subsystem.
- **Purpose:** Defines `static_cmd_table[]` and the `cmd_*` creator functions for
  every built-in command. Each creator parses that command's options (via `getopt`),
  constructs the appropriate `Job` subclass, and returns it.
- **Command count:** **84 entries** in `static_cmd_table[]`. Roughly ~63 have distinct
  creator functions (`CMD(...)` macros); the remainder are `ALIAS_FOR(...)` synonyms
  (e.g. `?`→help, `bye`/`quit`→exit, `rels`/`recls`/`renlist` re-variants) or
  module-loaded (`HELP_IN_MODULE` / `creator==0`, e.g. `at`).
  Full list: `! ( ? alias anon at bookmark bye cache cat cd chmod close cls connect
  command debug du echo edit eval exit fg find get get1 glob help jobs kill lcd lftp
  ln lpwd local login ls mget mirror mkdir module more mput mrm mv mmv nlist open
  pget put pwd queue quit quote recls reget rels renlist repeat reput rm rmdir scache
  set shell site sleep slot source suspend torrent user version wait zcat zmore bzcat
  bzmore .tasks .empty .notempty .true .false .mplist`.
- **External C-library deps:** `getopt`/`getopt_long` (option parsing). No readline.
- **Internal deps:** every Job subclass header, `ArgV`, `ResMgr`, `FileGlob`, `mirror`
  flag parsing, `PatternSet`.
- **Nim mapping:** one Nim `proc cmd_X(parent: CmdExec): Job` per command, registered
  into a table at init. Replace `getopt` with `std/parseopt` or a small custom parser
  (lftp relies on GNU getopt permutation + `optarg`; be careful to match semantics).
- **Port complexity:** **High** by sheer volume, but mechanical and parallelizable —
  each creator is independent. `cmd_mirror` is the most complex creator (huge option
  table feeding MirrorJob flags).
- **Gotchas:** Help text is GNU-gettext `N_()` marked; many creators mutate global
  `ResMgr` settings (e.g. `set` command). `getopt`'s global `optind`/`optreset`
  reset between commands must be emulated carefully.

### A3. parsecmd.cc — the tokenizer

- **Files & LOC:** `parsecmd.cc` (368), `parsecmd.h` (none separate; declared in
  CmdExec.h). ~368.
- **Purpose:** `parse_one_cmd()` — the lexer. Handles single/double quotes,
  backslash escaping, `!`-history quoting, whitespace splitting into `ArgV`, output
  redirection (`>`, `>>`, `|` → builds an `FDStream`/filter), background `&`, and
  command separators (`;`, `&&`, `||`) producing `condition` (`COND_ANY/AND/OR`).
  Also `quotable()`/`needs_quotation()` used by completion to re-quote output.
- **Key types:** `parse_result { PARSE_OK, PARSE_ERR, PARSE_AGAIN }` (PARSE_AGAIN =
  need more input, e.g. unterminated quote / continuation).
- **External deps:** none. **Internal:** `ArgV`, `Filter`/`FDStream` (redirection).
- **Nim mapping:** a pure procedural tokenizer over a string buffer returning a
  `seq[string]` plus redirection/condition metadata. Straightforward.
- **Port complexity:** **Medium.** Pure string logic, easy to unit-test, but the
  quoting/escaping rules and PARSE_AGAIN continuation must match exactly.
- **Gotchas:** Quoting rules are shared with completion (A5) and must stay consistent.

### A4. ArgV — argument vector + getopt wrapper

- **Files & LOC:** `ArgV.cc` (119), `ArgV.h` (88). ~207.
- **Purpose:** A growable `char**`-like argv (subclass of `StringSet`). Wraps
  `getopt_long`, provides `getopt()/getopt_long()`, `getindex()`, `CombineQuoted()`
  (re-serialize with quoting), `Append(int)` etc. Used everywhere a command needs
  to parse its own options.
- **External deps:** `getopt`/`getopt_long`. **Internal:** `xstring`/`StringSet`.
- **Nim mapping:** `seq[string]` + a thin options-parser helper. Drop the C `getopt`
  global state in favour of `std/parseopt` or a reusable custom struct.
- **Port complexity:** **Low–Medium** (getopt semantics the only wrinkle).

### A5. complete.cc — tab completion (readline-driven)

- **Files & LOC:** `complete.cc` (1340), `complete.h` (31). ~1371.
- **Purpose:** All tab-completion logic. Determines *what kind* of completion the
  cursor position implies (`cmd_completion_type` → COMMAND / LOCAL / REMOTE /
  BOOKMARK / VARIABLE / STRING_ARRAY / NO_COMPLETION, plus per-command option
  awareness e.g. `-O`, `-N`, `--newer-than`), then drives generators
  (`command_generator`, `remote_generator`, `bookmark_generator`, `vars_generator`,
  `array_generator`). Performs remote directory listing *cooperatively* (it pumps
  `SMTask::Schedule()` while readline is blocked) so the UI stays responsive.
  Handles bash-style filename quoting/dequoting and the `Meta-Tab` "complete-remote"
  and `Meta-N` slot-change key bindings.
- **Readline dependency:** **Deep and pervasive.** `#include <readline/readline.h>`.
  Uses `rl_line_buffer`, `rl_point/rl_end`, `rl_completion_append_character`,
  `rl_attempted_completion_function`, `rl_filename_quoting_function`,
  `rl_completer_quote_characters`, `rl_save_prompt`/`rl_message` (for the on-the-fly
  remote-listing progress prompt), `rl_complete`, custom defuns/bindings, and a
  **custom `rl_getc` (`lftp_rl_getc`)** that bridges readline's blocking input into
  the SMTask scheduler via `CharReader`. Wrapped through a thin `lftp_rl_*` shim
  (`lib/lftp_rl`, *outside* this subsystem) but the call sites here assume GNU
  readline's data model.
- **External deps:** **GNU readline** (and its `BANG_HISTORY` history-expansion
  symbols). Indirectly ncurses/termcap is pulled in *by* readline for terminal
  handling — this subsystem does not call ncurses directly.
- **Internal deps:** `CmdExec`, `FileAccess`/`GlobURL` (remote listing),
  `bookmark`, `ResMgr`, `FileSet`/`ColumnOutput`, `CharReader`, `SMTask`.
- **Nim mapping & readline replacement:** This is the **single hardest porting
  decision** (see strategy in the summary). Options:
  1. **FFI to GNU readline** — keep `complete.cc`'s logic almost verbatim, bind
    `librl` from Nim. Lowest behavioural risk, but readline is GPL and an external
    C dependency that fights the "pure Nim" goal and the cooperative scheduler.
  2. **linenoise / linenoise-ng** — tiny BSD-licensed line editor; has a completion
    callback but **no history-expansion, no `Meta-`/custom keymaps, no incremental
    `rl_message` prompt**. Would require re-implementing the completion driver and
    dropping/relocating advanced features.
  3. **Pure-Nim line editor** (e.g. `noise`/`linecross` style, or hand-rolled over
    the existing `CharReader` non-blocking input). Best fit for the SMTask model
    since input already flows through `CharReader`, and lets the editor *be* an
    SMTask. Most work, but cleanest long-term and license-clean.
  Recommended: option 3 for the editor with a **completion-engine that is a direct
  Nim translation of `cmd_completion_type` + the generators** (that logic is
  readline-independent once you abstract "the line buffer" and "the word to
  complete" behind a small interface).
- **Port complexity:** **Very High** (the readline coupling + cooperative remote
  listing). The *completion classification* logic is medium; the *editor binding* is
  the risk.
- **Gotchas:** The cooperative `lftp_rl_getc` is the lynchpin that keeps background
  jobs running while the user types — any line-editor replacement MUST preserve
  "pump the scheduler while waiting for a keystroke." Quoting must match parsecmd.

### A6. alias.cc — command aliases

- **Files & LOC:** `alias.cc` (111), `alias.h` (71). ~182.
- **Purpose:** Named text-substitution aliases (`alias` command). Linked list of
  `{name,value}`; `Expand()` returns substitution; loop detection via `TouchedAlias`
  TTL in CmdExec. **Internal:** `xstring`. **External:** none.
- **Nim mapping:** `Table[string,string]` + an `Alias` list type; expansion + cycle
  guard. **Port complexity: Low.**

### A7. bookmark.cc — bookmarks

- **Files & LOC:** `bookmark.cc` (202), `bookmark.h` (63). ~265.
- **Purpose:** Persistent `name → URL` bookmarks loaded from/saved to
  `~/.local/share/lftp/bookmarks` (a `KeyValueDB`). Used by `open` and completion.
- **External deps:** none. **Internal:** `KeyValueDB`, `xstring`.
- **Nim mapping:** `Table[string,string]` with a flat-file load/save. **Low.**

### A8. History.cc — CWD/connection history (NOT readline history)

- **Files & LOC:** `History.cc` (202), `History.h` (57). ~259.
- **Purpose:** Records the last directory visited per site (`~/.local/share/lftp/
  cwd_history`) so `open site; cd -` works across restarts. **This is lftp's own
  URL history — readline's command-line history lives in the readline lib, not here.**
- **External deps:** none. **Internal:** `KeyValueDB`/file IO, `FileAccess`.
- **Nim mapping:** keyed flat-file store. **Low.**

### A9. Feeders — QueueFeeder, FileFeeder

- **Files & LOC:** `QueueFeeder.cc` (376), `QueueFeeder.h` (89), `FileFeeder.cc`
  (66), `FileFeeder.h` (38). ~569.
- **Purpose:** `CmdFeeder` implementations.
  - **FileFeeder:** feeds commands from a file/fd (the `source` command, `-f`,
    rc files). Reads via a `Buffer`, returns lines.
  - **QueueFeeder:** the **background command queue** (`queue` command). Holds a
    linked list of `QueueJob {cmd, pwd, lpwd, jobno}`; supports add at position,
    delete by index/wildcard, move/reorder, and feeds queued commands one at a
    time to CmdExec when it goes idle. Tracks per-job pwd/lpwd so a queued command
    runs in the directory it was queued from.
- **External deps:** none. **Internal:** `CmdExec`/`CmdFeeder`, `Buffer`, `xstring`.
- **Nim mapping:** FileFeeder → a line iterator over a stream. QueueFeeder → a
  `seq`/`Deque[QueueJob]` with index/wildcard ops. **Port complexity: Medium**
  (QueueFeeder's reorder/wildcard editing is fiddly but self-contained).

### A10. CharReader — non-blocking single-char input

- **Files & LOC:** `CharReader.cc` (67), `CharReader.h` (45). ~112.
- **Purpose:** An `SMTask` that reads **one byte at a time** from an fd in
  non-blocking mode, returning `NOCHAR`/`EOFCHAR` and `Block()`ing on `POLLIN`.
  This is what lets `lftp_rl_getc` deliver keystrokes to readline without blocking
  the scheduler.
- **External deps:** `fcntl`/`read`/`poll` (POSIX). **Internal:** `SMTask`.
- **Nim mapping:** a small task using non-blocking `read` + the Nim scheduler's
  poll loop. **Port complexity: Low**, but **central** to the line-editor strategy.

---

## (B) Job base class + scheduling

### B1. Job.cc / Job.h — the cooperative job base

- **Files & LOC:** `Job.cc` (593), `Job.h` (173). ~766.
- **Purpose:** Base class for everything runnable. A `Job` *is a* `SMTask` (the
  scheduler calls `Do()`). Provides:
  - **Job tree & registry:** a global intrusive list `all_jobs` (via `xlist`), plus
    per-job `children_jobs`; `SetParent`, `AllocJobno` (assigns a job number),
    `FindJob(n)`, `NumberOfJobs`.
  - **Waiting / dependency graph:** `waiting` (an `xarray<Job*>`); `AddWaiting`,
    `RemoveWaiting`, `WaitsFor`, `FindDoneAwaitedJob`, `WaitForAllChildren`,
    `CheckForWaitLoop` (cycle detection), `FindWhoWaitsFor`. This is how a parent
    job (e.g. MirrorJob, CmdExec) blocks on children and reaps them when `Done()`.
  - **Foreground/background:** `fg`, `FgData` (terminal control), `Fg()`/`Bg()`,
    `lftpMovesToBackground`.
  - **Lifecycle:** `PrepareToDie()` reparents-or-kills children, removes from lists;
    `Kill`, `KillAll`, `Cleanup`, `BuryDoneJobs`/`ListDoneJobs`.
  - **Reporting:** `FormatStatus`, `FormatJobs`, `ShowRunStatus`, and printf-family
    (`eprintf`/`printf`) that route through `top_vfprintf` so a CmdExec parent can
    trap and redirect all of its children's output.
  - **Metrics:** `GetBytesCount`, `GetTimeSpent`, `GetTransferRate`.
  - `SessionJob` subclass: a `Job` that owns a `FileAccessRef session` (a
    connection) and can `Clone()` it.
- **Scheduling model:** **Cooperative, single-threaded.** No `Do()` may block; each
  returns `MOVED`/`STALL`/`WANTDIE`. "Background jobs" simply remain in `all_jobs`
  and keep getting `Do()`-called while the prompt is up; "waiting" is just a parent
  not finishing until `FindDoneAwaitedJob()` returns its child. **Parallelism =
  multiple jobs in the list, all pumped by the one scheduler loop** (see MirrorJob's
  `parallel` for the canonical pattern).
- **External deps:** none (libc/POSIX via SMTask). **Internal:** `SMTask`,
  `StatusLine`, `fg`/`FgData`, `FileAccess`, `xlist`/`xarray`, `trio` (printf).
- **Nim mapping:** `Job = ref object of SMTask`. The intrusive `xlist`/`xarray`
  become a Nim `seq[Job]` registry + per-job `children`/`waiting: seq[Job]`. `Do()`
  → a method returning an enum. **The whole port must adopt this cooperative
  `Do()`-returns-state model** — do NOT try to convert jobs to threads or async
  unless you re-architect (see summary). Nim's `ref`/GC handles the `Ref<>`/
  `SMTaskRef<>` reference counting that lftp does by hand.
- **Port complexity:** **High** — it's the architectural keystone; the intrusive
  lists, manual refcounting (`SMTaskRef`/`Ref`/`JobRef`), the waiting-graph cycle
  detection, and fg/bg terminal handoff all need careful Nim equivalents.
- **Gotchas:** `SMTaskRef`/`Ref` is hand-rolled refcounting with `DeleteLater()`
  deferred destruction (you can't delete a task from inside its own `Do()`); the
  Nim port should map this to GC refs but preserve "defer deletion until the
  scheduler tick ends." `PrepareToDie` reparenting logic must survive. `jobno`
  allocation and the global registry are user-visible (`jobs`, `kill`, `wait`).

---

## (C) Concrete Job types (one line each)

| File (LOC .cc/.h) | Class | Purpose |
|---|---|---|
| CopyJob.cc/.h (347/160) | `CopyJob` / `CopyJobEnv` / `CopyJobCreator` | Core single-file transfer driver wrapping a `FileCopy`; base for get/put/cat. Reports rate/ETA. |
| GetJob.cc/.h (137/55) | `GetJob : CopyJobEnv` | `get`/`put`/`reget`/`reput` — sets up source/target `FileCopyPeer`s and one or more `CopyJob`s. |
| pgetJob.cc/.h (558/99) | `pgetJob : CopyJob` | Parallel/segmented single-file download (`pget -n`): splits a file into chunks fetched concurrently, then stitches. |
| mgetJob.cc/.h (101/46) | `mgetJob : GetJob` | `mget`/`mput` — glob-expands patterns then enqueues many GetJob transfers. |
| mvJob.cc/.h (94/53) | `mvJob : SessionJob` | `mv` / rename (and used by mirror for symlink creation); optional remove-target-first. |
| mmvJob.cc/.h (144/62) | `mmvJob : SessionJob` | `mmv` — move multiple glob-matched files into a target directory. |
| mkdirJob.cc/.h (148/56) | `mkdirJob : SessionJob` | `mkdir` (with `-p`/`-f`) over possibly many dirs. |
| rmJob.cc/.h (76/42) | `rmJob : TreatFileJob` | `rm`/`rmdir`/`mrm` — recursive/glob remove via the FinderJob walk. |
| ChmodJob.cc/.h (135/59) | `ChmodJob : TreatFileJob` | `chmod` (symbolic/octal, recursive) applied over a file walk. |
| FindJob.cc/.h (410/133) | `FinderJob` (+`FinderJob_List`) | Recursive remote directory walker; base for find/du/rm/chmod. Drives `ls`-style traversal. |
| FindJobDu.cc/.h (199/83) | `FinderJob_Du` | `du` — disk-usage accumulation over the FinderJob walk. |
| SleepJob.cc/.h (318/62) | `SleepJob : SessionJob, Timer` | `sleep`/`repeat`/`at` — timed/repeating command execution; also the `repeat` loop engine. |
| SysCmdJob.cc/.h (103/41) | `SysCmdJob : Job` | `!cmd` / `shell` — fork+exec a local shell command, multiplexed into the scheduler. |
| CatJob.cc/.h (115/50) | `CatJob : CopyJobEnv` | `cat`/`more`/`zcat`/`zmore` — stream remote files to stdout / a pager. |
| echoJob.cc/.h (84/46) | `echoJob : Job` | `echo` builtin as a job (writes to its output stream). |
| EditJob.cc/.h (111/50) | `EditJob : SessionJob` | `edit` — download to temp, launch `$EDITOR`, re-upload if changed. |
| TreatFileJob.cc/.h (104/54) | `TreatFileJob : FinderJob` | Abstract base that applies a per-file action during a FinderJob walk (parent of rm/chmod). |
| attach.cc/.h (24/301) | `AcceptTermFD` / `SendTermFD` | Detach/`attach` support: pass the controlling-terminal fd over a unix socket to re-attach a backgrounded lftp. (Most logic is in the header.) |
| fg.cc/.h (78/90) | `FgData` | Foreground/background **terminal control** helper (process-group / tcsetpgrp handoff) used by `Job::Fg/Bg`. |

All of these are concrete `SMTask`/`Job` state machines; each is a **Low–Medium**
port individually, mechanical once the `Job` base + `FileCopy`/`FileAccess`
subsystems exist. `pgetJob`, `FindJob`, and `SleepJob`(+repeat/at) are the more
involved ones.

> Note: `fg.cc`/`attach.*` touch real TTY/process-group control (`tcsetpgrp`,
> `setpgid`, terminal fd passing over `AF_UNIX` with `SCM_RIGHTS`). These are the
> most OS-coupled, least "pure-Nim" pieces here and need careful POSIX FFI.

---

## (D) MirrorJob — in depth (the crown-jewel engine)

- **Files & LOC:** `MirrorJob.cc` (2365), `MirrorJob.h` (290). ~2655. Second-largest
  file in the subsystem after commands.cc.
- **Purpose:** Recursively synchronize a directory tree between any two
  `FileAccess` sessions (remote↔local, remote↔remote, local↔local, and `--reverse`
  for upload). Powers the `mirror` command — lftp's signature feature.
- **Key classes/types:**
  - `class MirrorJob : public Job`.
  - State machine `enum state_t` (INITIAL_STATE → MAKE_TARGET_DIR →
    CHANGING_DIR_{SOURCE,TARGET} → GETTING_LIST_INFO → WAITING_FOR_TRANSFER →
    TARGET_REMOVE_OLD[_FIRST] → TARGET_CHMOD → TARGET_MKDIR → SOURCE_REMOVING_SAME →
    FINISHING → LAST_EXEC → DONE).
  - **27 behaviour flags** (`ALLOW_SUID, DELETE, NO_RECURSION, ONLY_NEWER, NO_PERMS,
    CONTINUE, RETR_SYMLINKS, IGNORE_TIME, REMOVE_FIRST, IGNORE_SIZE, NO_SYMLINKS,
    LOOP, ONLY_EXISTING, NO_EMPTY_DIRS, DEPTH_FIRST, ASCII, SCAN_ALL_FIRST,
    OVERWRITE, UPLOAD_OLDER, TRANSFER_ALL, TARGET_FLAT, DELETE_EXCLUDED, REVERSE,
    …`).
  - `recursion_mode_t { ALWAYS, NEVER, MISSING, NEWER }`.
  - A family of `Ref<FileSet>` working sets: `source_set`, `target_set`,
    `to_transfer`, `to_mkdir`, `same`, `to_rm`, `to_rm_mismatched`,
    `old_files_set`, `new_files_set`, `to_rm_src`.
  - `struct Statistics` (counts of new/modified/deleted files/dirs/symlinks, bytes,
    time, errors) — aggregated up the sub-mirror tree.
  - `PatternSet exclude` (include/exclude globs & regexes), `Range size_range`,
    `newer_than`/`older_than` time filters.
- **The mirror algorithm:**
  1. **Chdir + List (GETTING_LIST_INFO):** `cd` into source and target dirs
    (`HandleChdir`), then create a `ListInfo` for each side and run them
    concurrently (cooperatively) to obtain a `FileSet` for source and target —
    full file metadata (name, type, size, date, symlink, mode).
  2. **Set computation (`InitSets`, MirrorJob.cc:581):** purely set-algebra over
    FileSets:
     - `to_rm = target_set − source_set` (files present at target but not source →
       deletion candidates; only acted on if `DELETE`); `DELETE_EXCLUDED` merges
       excluded target files in.
     - `to_transfer = source_set`, then **`SubtractSame(target_set, ignore)`**
       removes files already identical. *Sameness* compares **size and
       modification time** (with precision tolerance), modulated by flags:
       `ONLY_NEWER`, `IGNORE_TIME`, `IGNORE_SIZE`, `UPLOAD_OLDER`, and a special
       rule that for non-`file://` targets date-if-older is ignored. `same` keeps
       the skipped set. `TRANSFER_ALL` bypasses sameness entirely.
     - Apply `newer_than`/`older_than`/`size_range` filters.
     - Recursion handling: depending on `recursion_mode`, subtract directories
       (NEVER), only-missing dirs (MISSING), or only-newer dirs (NEWER).
     - Compute `new_files_set` (truly new), `old_files_set` (target files to be
       overwritten), and `to_rm_mismatched` (target entries whose *type* differs —
       e.g. file-vs-dir — which must be removed before transfer).
     - Sort `to_transfer` per `mirror:sort-by` (name/date/size, asc/desc) and
       `mirror:order` pattern list.
  3. **Make target dir (MAKE_TARGET_DIR / TARGET_MKDIR):** create the destination
    directory; with `SCAN_ALL_FIRST` pre-create the whole dir skeleton.
  4. **Transfer loop (WAITING_FOR_TRANSFER, MirrorJob.cc:1096):** the **parallel**
    core. While `transfer_count < parallel` and items remain, call
    `HandleFile(file)` on the next item. `transfer_count` is a **single global
    counter on the root mirror** (`root_transfer_count`) shared across the whole
    sub-mirror tree, so the `mirror:parallel-transfer-count` limit is enforced
    *globally*, not per-directory. Completed children are reaped each tick via
    `FindDoneAwaitedJob()` → `TransferFinished`.
     - **`HandleFile` (MirrorJob.cc:265)** dispatches by file type:
       - **Regular file:** decide new vs. modified vs. continue-partial (`CONTINUE`
         resumes a temp file if source grew); optionally remove/overwrite an
         existing target; choose plain `get` or **segmented `pget`** when
         `pget-n>1`, target is local, and the file is large enough; safety checks
         that the local target hasn't changed since the scan; then spawn a
         `CopyJob`/`GetJob` (or write a line to the `--script` file instead of
         transferring, in script mode). `RemoveSourceLater` queues source removal
         if `--Remove-source-files`.
       - **Directory:** unless recursion is off, **spawn a child `MirrorJob`**
         (`new MirrorJob(this, source->Clone(), target->Clone(), …)`) and
         `AddWaiting(mj)` — this is the recursion. Each child shares the root's
         transfer counter and aggregates stats upward. `DEPTH_FIRST` and
         `NO_EMPTY_DIRS` change traversal/pruning order.
       - **Symlink:** create the link (remote: `mvJob` with `FA::SYMLINK`; local:
         shell `ln -sf`) unless `NO_SYMLINKS`; `RETR_SYMLINKS` instead follows it.
  5. **Delete old (TARGET_REMOVE_OLD / _FIRST):** if `DELETE`, remove `to_rm` and
    `to_rm_mismatched` (mismatched removed *first*, before their replacements;
    `REMOVE_FIRST` moves all deletion before transfer). Also runs the parallel
    counter. `REPORT_NOT_DELETED` logs but skips when DELETE is off.
  6. **Permissions (TARGET_CHMOD):** apply source modes to transferred files/dirs
    (respecting `NO_PERMS`, `NO_UMASK`, `ALLOW_SUID`, `ALLOW_CHOWN`) and set
    directory mtimes (`LocalUtime`) so timestamps match.
  7. **Finish:** `SOURCE_REMOVING_SAME`/`to_rm_src` for `--Remove-source-files`,
    aggregate `Statistics` into the parent, run `LAST_EXEC`/`on_change` hook, then
    `DONE`. `LOOP` restarts the whole mirror until no changes; `max_error_count`
    aborts early.
- **Parallelism summary:** all "parallel" transfers and sub-directory mirrors are
  just **multiple Jobs in the one cooperative scheduler**, gated by a single shared
  integer counter (`root_transfer_count` vs `mirror:parallel-transfer-count`) and
  `mirror:parallel-directories`. No threads, no locks.
- **External deps:** `lstat`/`stat`/`chmod`/`access`/`remove`/`alloca` (POSIX),
  `getopt` (in the `cmd_mirror` creator). No readline/ncurses.
- **Internal deps:** `FileSet`/`FileInfo` (the set-algebra engine — *itself a large
  external dependency for this subsystem*, in `FileSet.cc`), `PatternSet`,
  `CopyJob`/`GetJob`/`pgetJob`/`mvJob`/`mkdirJob`/`ChmodJob`, `ListInfo`,
  `FileAccess`, `ResMgr`, `Range`, `xstring`.
- **Nim mapping:** `MirrorJob = ref object of Job` with the same explicit `state`
  enum driven by `do()`. The set algebra lives in the FileSet port (subtract/merge/
  sort/sameness) — porting MirrorJob is largely *re-expressing* those FileSet
  operations and the state transitions; keep the global transfer-counter semantics.
- **Port complexity:** **Very High.** Largest, most flag-laden, most edge-cased job;
  its correctness depends entirely on the FileSet "sameness" comparison and the
  recursion/counter bookkeeping. Behaviour is heavily user-observed — needs a broad
  test matrix (each flag, each recursion mode, partial-resume, type mismatches,
  symlinks, reverse/upload).
- **Gotchas:** "Sameness" rules (size+time with precision tolerance and the
  file:// special-case) are subtle and the heart of correctness. The shared
  root transfer counter (`#define transfer_count root_mirror->root_transfer_count`)
  is easy to get wrong. Local-target safety re-checks (file changed since scan)
  must be kept. Script mode (`--script`) emits an equivalent command list instead
  of transferring — a whole parallel code path. `TARGET_FLAT`, `DEPTH_FIRST`,
  `NO_EMPTY_DIRS`, and `LOOP` each rewire the traversal.

---

## Subsystem summary

- **Total LOC:** ~16,870 across this subsystem
  (Infra group A ≈ 9,387; Job base B ≈ 766; concrete jobs C ≈ 4,062 incl. their
  headers; MirrorJob D ≈ 2,655 — MirrorJob's LOC is counted within the file totals;
  the headline `wc` totals were 9,387 (infra+base) + 7,483 (all job files) = **16,870**).
- **Command count:** **84 commands** in `static_cmd_table[]` (~63 distinct creator
  functions plus aliases and module-loaded entries).
- **Dispatch:** linear, case-insensitive, prefix-abbreviation-aware table lookup
  (`find_cmd`) → a `cmd_creator_t` factory that returns a `Job`; builtins run inside
  CmdExec's own cooperative `Do()` state machine; modules loaded via `dlopen`.
- **Overall complexity:** **High.** Three hard cores: (1) the `SMTask`/`Job`
  cooperative scheduler + manual refcounting that *everything* depends on, (2) the
  readline-coupled completion/line editor, (3) MirrorJob + the FileSet set-algebra.
  The bulk of `commands.cc` and the concrete job types are mechanical but voluminous.
- **The non-negotiable architectural constraint:** lftp is **single-threaded and
  cooperative**. The Nim port should keep that model — implement `SMTask` as a Nim
  scheduler loop calling `do()` procs that return MOVED/STALL/WANTDIE and `poll()`
  over fds — rather than reaching for threads or `async/await` (an async rewrite is
  possible but would touch every job and is a separate, larger project). Map
  `Ref`/`SMTaskRef` to Nim GC refs while preserving deferred (`DeleteLater`)
  destruction.

### Readline / line-editing porting strategy

Readline is the **only heavyweight external C dependency** in this subsystem
(ncurses/termcap come transitively *through* readline; this code never calls them
directly). It appears in `complete.cc` (deeply) and is bridged into the cooperative
scheduler by `lftp_rl_getc` → `CharReader` (so background jobs keep running while
the user types). Recommended strategy:

1. **Decouple completion from the editor.** The completion *classifier*
   (`cmd_completion_type`) and the *generators* (command/remote/bookmark/variable/
   array) are readline-independent once "the current line buffer + word boundaries"
   is abstracted behind a tiny interface. Port these to pure Nim first — they carry
   lftp's real intelligence (remote globbing pumped cooperatively via the scheduler).
2. **Replace the editor with a pure-Nim, SMTask-native line editor** built on the
   existing `CharReader` non-blocking input. This is the cleanest fit: the editor
   *becomes* a scheduler task, so "pump background jobs while waiting for a
   keystroke" falls out naturally (today's `lftp_rl_getc` exists only to fake that
   inside blocking readline). It is also GPL/license-clean and dependency-free.
   - *Pragmatic interim:* FFI directly to GNU readline (or use linenoise) to get a
     working port fast, keeping `complete.cc` nearly verbatim — accept the C
     dependency and revisit. linenoise is lighter but lacks history-expansion,
     `Meta-`/custom keymaps, and the incremental `rl_message` remote-listing prompt,
     so feature parity needs extra work.
3. **Whichever editor you pick, preserve:** (a) cooperative keystroke input that
   keeps the scheduler running, (b) bash-compatible quoting/dequoting consistent
   with `parsecmd.cc`, (c) the `Meta-Tab` "complete-remote" and `Meta-N` slot keys,
   and (d) command-line history persistence (note: that history is readline's, *not*
   lftp's `History.cc`, which is unrelated CWD history).
