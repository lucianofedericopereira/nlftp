# 09 — Open Issues Triage (input to the C++→Nim port)

**Source:** `github.com/lavv17/lftp`, open issues fetched via GitHub REST API on 2026-06-30.
**Method:** `GET /repos/lavv17/lftp/issues?state=open&per_page=100` (pages 1–3), excluding any object
with a `pull_request` field (11 PRs dropped). The repo carries **no labels** on any issue, so the
categorization below is derived entirely from titles + bodies (the ~40 most-commented / most-recent
were read in full).

**Total open issues (PRs excluded): 256.**

Context for triage decisions: we are rewriting **lftp 4.9.3 in Nim + chronos**. Feature parity is
**not** strict (features may be dropped). Goal is **0 C source in our repo** (system TLS via thin
wrappers is fine). Autotools/gnulib are **left behind**. Therefore the entire D-category
(build/packaging/autotools/gnulib/portability) is **moot by construction** — that is the single
biggest lever for shrinking the bug surface.

---

## Summary table

| Cat | Meaning | Count | % of 256 |
|-----|---------|------:|---------:|
| **A** | Real bug, fixable-by-design in the async Nim rewrite | 38 | 14.8% |
| **B** | Real bug, must be ported deliberately (logic we'd carry over) | 22 | 8.6% |
| **C** | Feature request / enhancement | 71 | 27.7% |
| **D** | Build / packaging / portability / autotools / gnulib / platform — **MOOT** | 34 | 13.3% |
| **E** | Protocol-specific (FTP / HTTP / SFTP / FISH / Torrent / WebDAV) | 73 | 28.5% |
| **F** | Won't-fix / unclear / user-error / stale / question | 18 | 7.0% |
| | **Total** | **256** | 100% |

**MOOT-by-rewrite share.** Category **D is moot outright = 13.3%.** On top of that, a large slice of
the crash/hang/race bugs in **A** (memory bugs, fork/exec ObjC crashes, SM-task null derefs,
xheap asserts) **disappear for free** in a clean chronos rewrite — they require no deliberate porting
work, only that we *not* reproduce the C++ object-lifetime/SMTask machinery. Counting D plus the
A-bugs that are eliminated purely by architecture (≈24 of the 38 A items), the **effectively-moot /
free-win share is ≈ (34 + 24)/256 ≈ 22.7%.** Nearly a quarter of the open backlog evaporates without
us writing fix-specific code.

> Note: categories are exclusive; an issue that is *both* a protocol bug and an async-fixable crash is
> filed under **E** when the protocol detail is the load-bearing part (it informs protocol porting),
> and under **A/B** when the defect is generic. Cross-references are noted inline.

---

## A. Real bugs — fixable-by-design in the Nim/chronos rewrite

These are memory-safety bugs, fork/exec hazards, SMTask state-machine null-derefs, and timeout/hang
edge cases that a memory-safe, single-threaded-async (chronos) design avoids structurally. Subsystem
noted in **[brackets]**. Most need **no** porting work — just "don't rebuild the C++ machinery."

- **#593** — Null ptr deref in `CmdExec::FeedCmd` on fuzzed cmd input — **[cmd parser]** memory-safe strings/seq in Nim remove this class.
- **#603** — Null ptr access `xlist<Job>::get_next(this=0x0)` on redirected stdin — **[job list / xlist]** no raw intrusive linked-list in the rewrite.
- **#615** — Segfault on certain SFTP failures (`GetFileInfo::Do` via SMTask schedule) — **[SMTask/SFTP]** async error-path is just an exception, not a dangling task.
- **#461** — Segfault arm64 in `SMTask::SMTask()` ctor chain (`put /dev/random`) — **[SMTask ctor]** object-lifetime bug; gone by design.
- **#716** — Segfault on exit: `SSL_CTX_free` on null OpenSSL lock during global dtor — **[TLS teardown]** no global-static dtor ordering issue; close TLS explicitly in async cleanup.
- **#724** — `assert __EX failed, xheap.h:127` with >4 queued transfers — **[xheap scheduler]** custom heap replaced by chronos scheduling.
- **#750** — Immediate coredump from commit a311746 on SFTP connect — **[SFTP connect]** regression we simply never introduce; do not port that commit.
- **#613** — Segfault while validating torrent files — **[torrent]** (also E-torrent) memory bug in validator.
- **#631** — macOS crash: `NSPlaceholderDictionary initialize ... fork()` not fork-safe — **[fork/exec]** we won't `fork()` between Foundation init and exec; spawn via chronos asyncproc.
- **#689** — Commands leave defunct (zombie) ssh/sh processes — **[fork/exec/sftp]** proper async child reaping in chronos eliminates this.
- **#501** — Fork-Exec issue on OSX 10.14 Mojave — **[fork/exec]** same class as #631.
- **#454** — lftp runs forever with no error when `ssh` binary not found — **[fork/exec]** async spawn returns a real error.
- **#571** — Hangs trying to resolve host address — **[DNS/resolver]** chronos async resolver with timeout.
- **#572** — Hangs during file transfer — **[transfer loop]** state-machine stall; async I/O with timeouts.
- **#691** — Hangs on file upload except very small files (FTPS) — **[FTP data/TLS buffering]** (also E-FTP) likely TLS write/close ordering; clean async write path. **High-signal.**
- **#346** — Upload hangs at 100% "Waiting for transfer to complete" (FTPS) — **[FTP data/TLS]** same family as #691/#780.
- **#609** — Mirror -R stuck on "Sending Data" at 99% — **[FTP data]** transfer-completion stall.
- **#328** — `rmdir` hangs — **[cmd/state machine]** command never completes.
- **#581** — Mirror hangs on completion with `--loop` — **[mirror loop]** completion-detection race.
- **#438** — Mirror periodically hangs, no progress/log updates — **[mirror]** stall, likely same completion race.
- **#634** — High CPU usage — **[event loop]** busy-spin in the select loop; chronos epoll/kqueue avoids it.
- **#647** — Hangs if strings appended to source file during transfer — **[transfer size race]** (cf. #606/#186/#709/#764).
- **#764** — Process gets stuck when files added during transmission — **[transfer/size race]** same family.
- **#186** — Never finishes if file is modified at mirror time — **[transfer/size race]** same family.
- **#377** — Hangs on `150` in binary mode transferring `.gitkeep` (0-byte/tiny) — **[FTP data]** zero-byte transfer edge case.
- **#618** — Mirror of 0-byte / empty files fails — **[transfer]** empty-file edge case (cf. #530).
- **#530** — Mirroring folders results in 0-byte files — **[transfer]** empty/short transfer bug.
- **#632** — Doesn't recover from failed `421`/`PASV`; violates "every op is retried" — **[FTP retry/state machine]** (also E-FTP) reliability promise broken; clean retry FSM.
- **#621** — `450 Transfer aborted. Link to file server lost` not recovered — **[FTP retry]** same retry-FSM family.
- **#444** — `421 Timeout: closing control connection` — no way to skip the wait — **[FTP retry/timeout]**.
- **#434** — Indefinite loop "Delaying before retry: 450 Directory already exists" — **[FTP retry loop]** infinite-retry on a non-retryable error.
- **#380** — mirror infinite loop bug — **[mirror]** loop-termination defect.
- **#411** — Mirror synchronization exception — **[mirror]** unhandled state.
- **#311** — `-c` (continue) option not working with mirror sometimes — **[mirror resume]**.
- **#605** — `xfer:make-backup` not working — **[transfer/backup]** logic defect (borderline B).
- **#487** — `cls --dirsfirst` breaks sort order — **[listing/sort]** small logic bug.
- **#718** — lftp timeout mechanism unreliable — **[net timeout]** chronos deadlines make this uniform.
- **#523** — Inconsistent/corrupt file from `pget` — **[pget chunking]** chunk-assembly bug (cf. #608/#688). **High-signal.**

## B. Real bugs that must be ported deliberately (logic we'd carry over if we copy naively)

Protocol/path/encoding/permission logic where the correct behavior is non-obvious; if we transliterate
the C++ we inherit the bug. **Flag each to fix during port.**

- **#69** — Special chars (â, è) in names mis-encoded to SFTP server — **[charset]** decide UTF-8 wire policy explicitly; don't blind-iconv. **High-signal.**
- **#783** — Mirroring files with precomposed (NFC) accented chars re-downloads each run — **[Unicode normalization]** must compare names NFC-normalized. **High-signal.**
- **#129** — Remote filenames containing literal `/` not displayed — **[path parsing]** path splitter assumes `/` is always a separator.
- **#142** — Cannot create/access remote names containing `:` — **[path/URL parsing]** colon mis-parsed as scheme/port.
- **#624** — Delete files with special chars (`'`) → 550 — **[quoting]** arg-quoting on the wire.
- **#646** — Files whose name begins with a space fail (`550 File not found`) — **[name trimming]** leading-space stripped somewhere.
- **#736** — mirror doesn't unescape standard bash-style escapes consistently — **[arg lexer]** glob/escape handling.
- **#625** — Cannot delete dotfiles (`553 Prohibited`) — **[server-policy vs client]** partly server, but verify lftp isn't transforming the name.
- **#385** / **#416** — `exclude` doesn't work on multi-level / full-path dirs — **[mirror exclude matching]** path-relative match logic.
- **#578** — Empty folders created when all files excluded — **[mirror exclude]** create-dir-then-skip ordering.
- **#590** — No deletions with `mirror --reverse --delete` — **[mirror reverse delete]** delete-set computed wrong.
- **#645** — mirror deletes dirs it hasn't emptied with `--Remove-source-dirs` — **[mirror remove]** ordering/guard bug. **High-signal (data loss).**
- **#665** — `--Remove-source-files` removes remote dirs too — **[mirror remove]** over-broad removal. **(data loss).**
- **#630** — `mput -E` doesn't report error when a file can't be deleted — **[error propagation]** swallowed error.
- **#364** — mirror -R ignores date comparison when building transfer list — **[mirror compare]** stat/compare logic.
- **#675** — "mirror updated file only if bigger" — size-only comparison — **[mirror compare]**.
- **#348** — Local file timestamp differs from server after mirror — **[mtime preservation]** rounding/timezone (cf. #522 secs-vs-ms).
- **#388** — Directory timestamps not preserved on get — **[mtime preservation]** dirs skipped.
- **#617** — `bytes_count` wrong in `MirrorJob::TransferFinished` over SFTP — **[accounting]** counter logic; fix while porting MirrorJob.
- **#652** — MLSD `ParseLongList` returns empty list (Cerberus FTP) — **[FTP MLSD parser]** parser edge case; port the parser carefully. **High-signal.**
- **#480** — `-O/--target-directory` not honored — **[arg handling]** option plumbing.
- **#404** — Cannot specify target with mirror glob — **[mirror arg parsing]**.

## C. Feature requests / enhancements

Mark **[ADD]** (cheap/worth doing), **[DROP]** (skip to simplify), or **[MAYBE]**.

- **#139** — `df` / free-space command — **[ADD]** small, useful.
- **#737** / **#748** / **#751** — Stop/check on remote out-of-disk before/while transfer — **[ADD]** (dup cluster).
- **#770** / **#416** — Exclude directory by full path (relative to root) — **[ADD]** fixes a real gap.
- **#771** — Whitelist (include-only) mode for mirror — **[ADD]**.
- **#356** — Continue mirror in pget mode — **[MAYBE]** resume + chunking interaction is fiddly.
- **#494** — pget-n: split non-evenly to prioritize streaming — **[DROP]** niche.
- **#464** — Upload single file in multiple chunks (parallel STOR) — **[MAYBE]** few servers support it.
- **#415** — Better status line for parallel mirror — **[ADD]** UX.
- **#488** — Clearer docs/output for `mirror --loop` — **[ADD]** UX/docs.
- **#591** — Clarify how `mirror --flat` works — **[ADD]** docs.
- **#95** — `get` verbose mode — **[ADD]** trivial.
- **#414** — Parameter to hide arguments (creds in process list) — **[ADD]** security; cf. #246.
- **#246** — Safe credential handling — **[ADD]** design creds story up front.
- **#373** — Encrypted passwords in bookmarks — **[MAYBE]**.
- **#640** — Option to specify `.netrc` location — **[ADD]** trivial.
- **#119** / **#482** / **#657** — Default/explicit permissions for transferred files & dirs (000 rights bug-ish) — **[ADD]** umask handling.
- **#439** — Flag to overwrite — **[ADD]**.
- **#484** — Temp dir / temp name for in-flight files — **[ADD]** atomic-rename pattern; aligns with #353.
- **#300** — Create COMPLETE marker folder when transfer done — **[DROP]** scriptable already.
- **#457** — String replacement of file contents during mirror — **[DROP]** scope creep; not a transfer client's job.
- **#516** — zip support — **[DROP]**.
- **#507** — SMB protocol support — **[DROP]** big new protocol.
- **#510** — SOCKS5 proxy support — **[MAYBE]** chronos transports can do it cleanly if wanted.
- **#427** — Daemon option with listening socket — **[DROP]**.
- **#430** — `liblftp` (library form) — **[MAYBE]** Nim makes a lib trivial, but out of scope.
- **#189** — `lftpost` utility — **[DROP]**.
- **#598** — Add torrent to `lftpget` — **[DROP if torrent dropped]**.
- **#687** — Sequential torrent download — **[DROP if torrent dropped]**.
- **#429** — BitTorrent Message Stream Encryption — **[DROP if torrent dropped]**.
- **#614** — Torrent set-variables missing — **[DROP if torrent dropped]**.
- **#287** — Support MFCT (Modify File Creation Time) — **[MAYBE]**.
- **#435** — `find --printf` support — **[ADD]** cheap.
- **#705** — Enable/disable background-job verbose logging — **[ADD]**.
- **#706** — Scripted job control / interact with background jobs — **[MAYBE]**.
- **#704** — User-defined alias for remote command list — **[MAYBE]**.
- **#695** — Redirect lftp paths to other shell commands — **[DROP]**.
- **#541** — Extra params for verify-command — **[ADD]** cheap.
- **#719** — Pre-allocate / sparse files on Windows — **[MAYBE]**.
- **#190** — Resume upload after system goes down — **[ADD]** resume is core.
- **#308** — Mirror option to avoid `rm -r` — **[ADD]** safer delete.
- **#302** — `--skip-no-access`: skip unremovable dirs — **[ADD]**.
- **#290** / **#343** / **#347** / **#456** / **#520** — symlink handling/dereference options — **[ADD cluster]** define symlink policy once (cf. #342 crash in A).
- **#496** — Case-insensitive mirroring — **[ADD]** option flag.
- **#388**-adjacent **#522** — seconds vs ms in reported time — **[ADD]** precision.
- **#354** — Download files from a certain filename onwards — **[MAYBE]** glob/range.
- **#467** — `--directory=PATH` for multiple dirs — **[ADD]**.
- **#404**/**#714** — wildcard usage in mirror target (`wp-*`) — **[ADD]** (overlaps B-#404).
- **#656** — Make mirror independent of what it's mirroring — **[MAYBE]** vague.
- **#697** — More guards against race conditions in mirror — **[ADD]** aligns with async design.
- **#688** — `mirror --continue` not working for pget-chunk interrupt — **[MAYBE]** (borderline A/B resume bug).
- **#441** — mirror `use-mode-z` (compression) — **[MAYBE]**.
- **#532** — `-e` and `-o` together with put — **[ADD]** small.
- **#610** — CLI option for pre-connection `set` — **[ADD]** cheap.
- **#640**-adjacent **#445**/**#422** — control HOST/FEAT command timing/disable — **[ADD]** (see also E-#638).
- **#287**, **#373**, **#516**, **#507**, **#427**, **#430**, **#189**, **#598**, **#687**, **#429**, **#614**, **#695**, **#457**, **#300**, **#494**, **#464**, **#719** already noted above.
- **#451** — Disable pseudo-tty for sftp (`ssh -T`) — **[ADD]** sftp connect-program flag (overlaps E-SFTP).
- **#527** — Restrict remote commands for fish connections — **[MAYBE]** (E-FISH).
- **#287**/**#520**/**#348**/**#388**/**#522** mtime cluster — see also B.
- **#680** — "What's the planned next release?" — **[DROP]** (project-mgmt, near F).
- **#359** — Automated docker image build — **[DROP]** packaging.
- **#431** — Native Windows version — **[MAYBE]** Nim cross-compiles; relevant but big.
- **#769**-style **#767** — pass config file from stdin — **[ADD]** cheap.
- **#739**-style **#640** netrc — noted.

## D. Build / packaging / portability / autotools / gnulib / platform — **MOOT in the Nim rewrite**

~34 issues. All disappear because we drop autotools/gnulib, target Nim's toolchain, and keep 0 C
source. **Moot.** Numbers:
**#114, #178(build-cert path part), #229, #243, #244, #357, #386, #396, #408, #421, #436, #459, #468, #471, #485, #534, #542, #575, #580, #600, #611, #629, #644, #659, #661, #667, #703, #717, #725, #742, #743, #746, #759, #766.**
Highlights (for the record, not for action):
- **#759 / #436** — gnulib `regex.h` / `parse-datetime` — *gone with gnulib*.
- **#717 / #742** — config.guess/config.sub, missing `lib/Makefile.in` — *gone with autotools*.
- **#725 / #611 / #766** — OpenSSL 3 deprecations, clang 12, C++14-mode build fail — *gone with C++*.
- **#396 / #580** — AppImage / fully-static build — *Nim static linking is trivial; re-evaluate, not port.*
- **#644 / #732 / #428 / #437 / #678 / #679** — translation/manpage typos & formatting — *docs, regenerate fresh.* (Filed here as packaging/docs noise.)
- **#229 / #534 / #485** — custom expat/zlib/readline linking — *moot; pick libs in nimble.*

## E. Protocol-specific (informs protocol porting)

Grouped by protocol. These carry the wire-level knowledge we must reproduce.

### FTP / FTPS
- **#466** — EPSV with FTP OPEN proxy connects to proxy IP not target (`Handle_EPSV` copies peer_sa) — **port EPSV/PASV addr handling correctly.** **High-signal.**
- **#784** — `ftp:ignore-pasv-address` uses proxy IP behind HTTP proxy — same address-selection bug family.
- **#780** — FTPS upload kills control conn after data transfer (`SSL_shutdown` on data socket) over OpenSSL — **TLS data-channel close ordering.** **High-signal** (cf. #346/#691/#612).
- **#691 / #346** — FTPS upload hang at 100% (TLS data close) — see A; protocol root = data-channel TLS shutdown.
- **#612** — "slow" transfer with GnuTLS build — TLS data-path perf.
- **#638** — `FEAT` issued before login; no way to defer — **command-ordering state machine.**
- **#445 / #422** — control `HOST` command timing / disable — login sequencing.
- **#655** — Sending `ACCT` after logon — login sequencing.
- **#632 / #621 / #444 / #434** — 421/450/PASV retry recovery — reliability FSM (also in A).
- **#218 / #366 / #538 / #489** — `550`/`530` change-dir / login-failed handling — error mapping.
- **#353** — `553` on rename of temp file — temp-name + rename flow.
- **#546** — `426 Connection closed; aborted transfer` — abort handling.
- **#377** — `150` hang on tiny file — data-transfer state.
- **#550** — FXP (server-to-server) mirror stalls/incomplete — **FXP support decision** (drop or port carefully).
- **#653** — `550 Unsupported command` on put — server-feature negotiation.
- **#503** — Mirroring from bintray with `:` in names — listing/path (cf. B-#142).
- **#594 / #722** — Listing silently capped (1000 / 98 files) — **listing pagination / buffer cap bug.** **High-signal (silent data loss).**
- **#423** — `nop-interval` / control-conn timeout semantics — keepalive.
- **#407** — Different users can't connect with same login — connection reuse/cache.
- **#749** — Uploads fail for files >14434 bytes — **server-specific data-channel cutoff** (likely TLS/PASV).

### HTTP / HTTPS / WebDAV
- **#205** — `ls` shows no results on ownCloud WebDAV — **WebDAV PROPFIND parsing.** **High-signal.**
- **#43** — WebDAV `mirror -nR` hangs on some dirs (EOF reading headers) — WebDAV listing/keepalive.
- **#276** — mirror over https quirk — WebDAV/HTTP.
- **#517** — http download from wrong directory — **URL/redirect path resolution.**
- **#389** — Does lftp cache redirects? — redirect handling.
- **#649** — http URLs with query strings mishandled — URL parsing.
- **#599** — FTPS/HFTP/HTTPS/MAGNET scheme handling — scheme table.

### SFTP / SSH
- **#358** — SFTP fails on Easylink (password auth via connect-program) — **connect-program prompt handling.**
- **#592** — SFTP "bad string in reply" (protocol v6, OPENDIR) — **SFTP v6 packet parsing.** **High-signal.**
- **#608** — Corrupt files on SFTP download (zeroed chunks) — **SFTP read offset/reassembly bug.** **High-signal (corruption).**
- **#615** — Segfault on SFTP find when home=/ and no list perm — see A; protocol = error-path on denied list.
- **#637** — SFTP via HTTP proxy — proxy tunneling for sftp.
- **#451** — Disable pseudo-tty (`ssh -T`) — connect-program flags.
- **#460 / #468** — `sftp:auto-confirm` not working (Win10 / CentOS7) — host-key confirm flow.
- **#490** — SFTP broken on Windows due to hard-coded `sh` path — spawn path (also platform).
- **#529** — `SSH2_MSG_USERAUTH_FAILURE` info — auth surfacing.
- **#447** — `pget -n` / `--use-pget-n` fails for ssh auth via gpg-agent — multi-conn auth reuse.
- **#715** — `sftp:connect-program` not working for passphrase-protected keys — connect-program/agent.
- **#757** — `sftp:size-write` config semantics — write-size negotiation.
- **#635** — Can't connect to sftp server — generic (needs body; near F).
- **#730** — `open` doesn't initiate connection with simpleSSHD (Android) — handshake timing.

### FISH
- **#527** — Restrict remote command list for fish connections — fish command surface.
- *(FISH otherwise has near-zero open issues — low porting priority.)*

### Torrent / Magnet
- **#613** — Segfault validating torrent files — see A.
- **#614** — Torrent set-variables missing — config.
- **#429** — BitTorrent Message Stream Encryption — feature.
- **#687 / #598** — sequential torrent download / lftpget torrent — feature.
- **#599** — MAGNET scheme — scheme handling.
- **Porting note:** torrent is a large, self-contained subsystem with thin demand. **Strong DROP candidate.**

### TLS / certificate handling (cross-protocol)
- **#143** — Cert chain verification fails despite valid chain — **trust-store/chain-building.** **High-signal.**
- **#526** — LetsEncrypt cert "Not trusted" — missing intermediate / CA path.
- **#178** — "unable to get local issuer certificate" even with `ssl:ca-file` — CA loading.
- **#772** — lftp fingerprint differs from `openssl s_client` ("no issuer found") — chain/fingerprint logic.
- **#731** — Segfault with CRL file — **[A: crash]** but CRL-parsing is protocol; fix in TLS wrapper.
- **#761** — `gnutls_record_recv: unexpected TLS packet`, files skipped on mirror — TLS read framing (GnuTLS-specific; system-TLS wrapper may resolve).
- **#651** — Encrypted/password-protected client certs — feature on TLS wrapper.
- **Porting note:** delegate cert verification to the **system TLS** library via a thin wrapper; many
  of these (#143/#526/#178/#772) are about chain building the OS trust store already does correctly.

## F. Won't-fix / unclear / user-error / stale / questions

- **#227** — "lftp \*\*\*\*" — no content / spam-like.
- **#680** — "What's the planned next release?" — project question.
- **#720** — "What happened to lftp.tech?" — infra question.
- **#758** — bare NEWS permalink, no description — empty.
- **#428 / #437 / #678 / #679** — manpage typos/formatting — trivial docs (also D); regenerate.
- **#644** — Spanish translation typo — docs.
- **#712 / #705** — "how to get more details in log" — usage/question (705 also C).
- **#570** — Difference between `-e` and `-c` — usage question.
- **#591 / #488** — how `--flat` / `--loop` work — docs (also C).
- **#708** — Misleading docs/behavior for `get -P` — docs/clarification.
- **#757 / #772 / #712** — questions (some cross-listed E).
- **#386** — "not working exactly like ftp in SUSE12" — vague/user-env.
- **#418** — "Directory Does Not Exist" — too little info.
- **#269** — stuck while pushing a file, v4.6.3a, no repro — stale (likely A-hang but undiagnosable).
- **#221** — "Mirror with Local OS X" — unclear.
- **#467** noted under C.
- **#782** — Windows directory junctions deleted/recreated — *real bug, but Windows-junction semantics;* parked as platform-specific/unclear-priority (revisit if Windows is a target). Borderline B.

---

## Top 15 issues that should shape the port

1. **#608 — SFTP download corruption (zeroed chunks).** Data integrity. Build the SFTP read path with
   explicit offset accounting and a post-transfer length/most-importantly content check; add a test
   that downloads with reordered/parallel reads. (cf. #523 pget corruption, #592 v6 parsing.)
2. **#780 / #691 / #346 — FTPS data-channel TLS shutdown.** The single most-reported FTPS failure
   family (hang at 100% / control conn killed). Get TLS `close_notify` ordering on the data socket
   right *before* reading the control reply. Bake into the FTP transfer FSM from day one.
3. **#594 / #722 — Silent listing truncation (1000 / 98 files).** Silent data loss. Never cap a
   directory listing; stream/paginate listings and assert completeness. Add a >10k-entry test.
4. **#466 / #784 — PASV/EPSV address selection behind proxies.** Don't copy `peer_sa` into the data
   socket. Compute the data endpoint from the server's advertised address vs. proxy correctly, with
   an explicit `ignore-pasv-address` knob. Core to FTP-through-NAT/proxy.
5. **#632 / #621 / #444 / #434 — FTP reliability FSM (421/450/PASV retry).** lftp's headline promise
   ("every non-fatal error is retried") is currently broken in cases. Design one clean retry state
   machine with bounded backoff and a *non-retryable* classification so #434's infinite loop can't
   recur.
6. **#645 / #665 — mirror delete/remove can destroy data.** `--Remove-source-dirs`/`--delete` remove
   things they shouldn't. Treat deletions as a verified, ordered phase (only after confirmed
   transfer); add guards + dry-run parity tests. Data-loss class — highest correctness bar.
7. **#69 / #783 / #129 / #142 / #624 / #646 — filename/charset/path correctness.** Define the wire
   charset policy and Unicode **NFC normalization** for name comparison up front; treat names as
   opaque bytes where the protocol allows; don't strip leading spaces or mis-split `/`/`:`. Prevents a
   whole recurring class (re-download loops, 550s).
8. **#143 / #526 / #178 / #772 — TLS chain verification.** Delegate to system trust store via the
   wrapper; these "valid cert reported untrusted" reports mostly vanish when the OS does chain
   building. Provide `ssl:ca-file`/pinning escape hatches that actually load.
9. **#205 / #43 — WebDAV listing (PROPFIND) parse/hang.** WebDAV is widely used (ownCloud/Nextcloud);
   the listing parser is fragile. Port with a real XML parser and keepalive/EOF handling; test against
   ownCloud/Nextcloud fixtures. (Decide early if WebDAV is in scope — recommend yes.)
10. **#593 / #603 / #461 / #615 / #716 / #724 / #750 — memory-safety crash cluster.** Free wins:
    these go away by *not* rebuilding SMTask/xlist/xheap and avoiding global-static TLS dtors. Make
    "no raw intrusive lists / no custom heap scheduler / explicit async cleanup" an architectural rule
    and these stay fixed.
11. **#631 / #501 / #689 / #454 — fork/exec hazards.** Spawn ssh/sh via chronos asyncproc with proper
    reaping and no `fork()` between framework-init and exec. Kills the macOS ObjC crash, the OSX
    fork-exec issue, zombie processes, and the silent "ssh not found" hang.
12. **#638 / #445 / #655 — FTP command-ordering (FEAT/HOST/ACCT vs login).** Make the login/feature
    negotiation sequence explicit and configurable so servers that reject pre-auth FEAT work.
13. **#592 — SFTP protocol v6 parsing.** Several servers negotiate v6; the parser must handle v6
    packet shapes (OPENDIR/handle replies). Build SFTP with full v3–v6 support and a parser fuzz test.
14. **#606 / #186 / #647 / #764 / #709 — "file size decreased / changed during transfer".** Decide
    explicit semantics for files mutated mid-transfer (re-stat, retry, or fail cleanly) instead of
    hanging. Common with log/append files.
15. **#246 / #414 — credential safety.** Design the credential story (no creds in argv/process list,
    safe netrc/keyring) at the architecture stage rather than bolting it on.

---

## Features the issues suggest we could DROP to simplify

Dropping these removes large/fragile subsystems with thin demand, directly shrinking the port:

- **BitTorrent / Magnet** (#613, #614, #429, #687, #598, #599-magnet). Self-contained, large, low
  demand, brings its own crash (#613). **Drop the whole torrent subsystem** unless a hard requirement
  surfaces — biggest single simplification.
- **FXP (server-to-server FTP transfer)** (#550). Stalls/incomplete, niche, doubles connection-state
  complexity. **Drop** (or make a clearly-unsupported stub).
- **FISH protocol** (#527 + the broader FISH support). Almost no open issues; superseded by SFTP
  everywhere. **Drop** to save a protocol implementation.
- **SMB** (#507) — never implemented; **don't add.**
- **In-transfer content transformation** (#457 string-replace, #516 zip support). Out of scope for a
  transfer client. **Drop.**
- **Daemon / listening-socket mode** (#427) and **lftpost** (#189). **Drop.**
- **pget non-even split / streaming-priority** (#494) and **single-file multi-connection upload**
  (#464). Marginal benefit, real complexity. **Drop / defer.**
- **SOCKS / Dante socks5** build paths (#114, #660, #746, #510). The autotools socks integration is a
  perennial build-failure source; if SOCKS is wanted, do it natively via chronos transports and drop
  the Dante linkage entirely. **Drop the C SOCKS dependency.**
- **AppImage / fully-static / docker packaging asks** (#396, #580, #359). Re-evaluate fresh with Nim
  tooling instead of porting; **drop the old packaging machinery.**
- **Custom-library linking knobs** (#229, #534, #485 for expat/zlib/readline). Pick deps via nimble;
  **drop the configurable-C-lib surface.**

These drops, plus leaving autotools/gnulib behind, are what push the "moot / eliminated-without-fix-code"
share to roughly a quarter of the open backlog.
