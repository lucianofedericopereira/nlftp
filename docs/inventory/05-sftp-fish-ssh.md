# Inventory 05 — SSH-based protocols (SFTP, FISH) and SSH plumbing

lftp 4.9.3 → Nim (chronos) port planning. Source: `/Users/studiox/Downloads/lftp/src/src/` (flat).

This subsystem implements two file-transfer protocols that run **over an `ssh` subprocess** rather than a direct socket:

- **SFtp** — the binary SFTP wire protocol (the same one `sftp(1)` speaks), driven over `ssh -s ... sftp` (the ssh2 `sftp` subsystem) or a remote `sftp-server`.
- **Fish** — the "FIles transferred over SHell" protocol: ASCII shell commands and shell-script snippets piped to a remote shell, parsing `### NNN` status markers from stdout.

Both share **SSH_Access** (subprocess + PTY plumbing, password/host-key prompt handling) which itself sits on **PtyShell** (fork + pseudo-tty allocation). **GetPass** reads a password from the controlling tty with echo disabled.

All four classes implement the `FileAccess` / `NetAccess` virtual interface (see inventory of the FileAccess core): `Do()` is the state-machine pump called by the global `SMTask` scheduler, plus `Read/Write/StoreStatus/Close/MakeListInfo/MakeDirList/MakeGlob/SameSiteAs/Clone` etc.

---

## Module: SSH_Access (shared base)

### Files & LOC
- `SSH_Access.h` (63) + `SSH_Access.cc` (221) = **284 LOC**

### Purpose
Common base for `SFtp` and `Fish`. Owns the four I/O buffers wrapping the ssh subprocess, drives password/host-key-confirm prompt detection off the pty, logs ssh stderr, and implements connection-stealing move semantics.

### Key classes/types
- `class SSH_Access : public NetAccess`
- Four `SMTaskRef<IOBuffer>`:
  - `send_buf` / `recv_buf` — the **data channel**, wrapping the ssh subprocess's stdin/stdout **pipes** (`getfd_pipe_out` / `getfd_pipe_in`). Binary SFTP framing / FISH commands flow here.
  - `pty_send_buf` / `pty_recv_buf` — the **control channel**, wrapping the **pseudo-tty master fd** (`getfd()`). ssh writes password prompts, host-key confirmations and diagnostics here; lftp writes the password here.
- `Ref<PtyShell> ssh` — the subprocess+pty handle.
- State: `password_sent`, `greeting` (`"FISH:"` for fish, server greeting for sftp), `received_greeting`, `hostname_valid`, `last_ssh_message`/`_time`.

### Key methods
- `MakePtyBuffers()` — after `getfd()` succeeds: `Kill(SIGCONT)` to resume the stopped child (PtyShell SIGSTOPs the child so the parent can wire buffers first), then builds the 4 IOBuffers over pipes + pty.
- `HandleSSHMessage()` — reads a line from `pty_recv_buf`; classifies it via `IsPasswordPrompt` (ends with `'s password`, or ends `:` containing "password"/"passphrase") and `IsConfirmPrompt` (ends `?` containing "yes/no"). On password prompt: errors if no `pass` or if already sent once ("Login incorrect"), else echoes `XXXX` to the local pty buffer (to mask the prompt in logs) and writes `pass\n` to `pty_send_buf`. On confirm prompt: answers from `QueryBool("auto-confirm")`. Detects `"Host key verification failed"`, DNS-failure strings → fatal/lookup errors.
- `LogSSHMessage()` — drains ssh diagnostic lines, strips `ssh: ` prefix, marks greeting received, detects peer-closed/error.
- `DisconnectLL()` / `MoveConnectionHere()` — tear down / steal all 4 buffers + ssh handle + greeting/password state.

### External deps
- None directly C-library; relies on PtyShell for the pty. Uses `std::search` / `<algorithm>` for case-insensitive substring match.

### Internal deps
- `NetAccess` (base), `PtyShell`, `IOBuffer`/`IOBufferFDStream`, `FDStream`, `xstring`, `ResMgr` (`QueryBool`), logging.

---

## Module: PtyShell + lftp_pty

### Files & LOC
- `PtyShell.h` (59) + `PtyShell.cc` (259) = **318 LOC**
- helper: `lftp_pty.c` / `lftp_pty.h` (the portable `open_pty()`), not strictly in the named set but a hard dependency.

### Purpose
Spawn a child process attached to a freshly allocated pseudo-tty (so ssh believes it has a real terminal and will issue interactive prompts), optionally also wiring separate stdin/stdout **pipes** for the data channel.

### Key classes/types
- `class PtyShell : public FDStream` — `fd` is the pty master. Holds `Ref<ArgV> a` (argv form) or a shell command string `name` (filter form), `SMTaskRef<ProcWait> w` (child reaper), `pid_t pg` (process group), `use_pipes`, `pipe_in`/`pipe_out`.

### Mechanism (`getfd()`, lazy on first call)
1. If `use_pipes`: `pipe(pipe0)`, `pipe(pipe1)`.
2. `open_pty(&ptyfd,&ttyfd)` (lftp_pty.c) — portable pty allocation.
3. Set raw termios on the slave (`c_lflag=c_oflag=c_iflag=0`, `VMIN=1`).
4. `fork()`. Child: dup pipes onto fd 0/1 (or tty onto 0/1 if no pipes), tty onto fd 2 always; `setsid()`; `ioctl(TIOCSCTTY)` to make pty the controlling tty; `SignalHook::RestoreAll()`; **`kill(getpid(),SIGSTOP)`** (parent wires buffers, then SIGCONTs); force `LC_ALL/LANG/LANGUAGE=C`; `execvp(argv)` or `execl("/bin/sh","sh","-c",name)`.
5. Parent: set pty master `FD_CLOEXEC`+`O_NONBLOCK`, keep pipe ends, `waitpid(...,WUNTRACED)` for the SIGSTOP, create `ProcWait`.

### External C-library deps
- **pty allocation** via `lftp_pty.c::open_pty`, which is a config-driven fan-out:
  - `openpty()` (from **`<util.h>`/`<pty.h>`** → links **`-lutil`** on BSD/glibc), or
  - `_getpty()` (Irix), or
  - `posix_openpt`/`grantpt`/`unlockpt`/`ptsname` on `/dev/ptmx` (SysV/Linux), or
  - `/dev/ptc`+`/dev/pts` (AIX), or legacy `/dev/pty??` scan.
  - STREAMS `ioctl(I_PUSH,"ptem"/"ldterm")` on SysV.
- `<termios.h>` (`tcgetattr/tcsetattr`), `<sys/ioctl.h>` (`TIOCSCTTY`), `fork/execvp/execl/dup2/setsid/waitpid` (`<unistd.h>`,`<sys/wait.h>`), `fcntl`.

### Internal deps
- `FDStream`/`Filter.h`, `ProcWait`, `SignalHook`, `ArgV`, `xstring`.

### External PROGRAM dep
- **`ssh` binary** (`ssh -a -x` by default; overridable via `connect-program`). lftp never speaks the SSH transport itself — it shells out.

---

## Module: GetPass

### Files & LOC
- `GetPass.h` (28) + `GetPass.cc` (92) = **120 LOC**

### Purpose
Prompt for and read a password from the controlling terminal with echo disabled (used when the site has no stored password and ssh is about to prompt). `readline_from_file` is a generic SIGINT-aware line reader over an fd.

### Mechanism
- `GetPass`: open fd 0 or `/dev/tty`; write prompt; clear `ECHO` in termios; `readline_from_file`; restore termios; echo `\r\n`.
- `readline_from_file`: cooperatively reads char-by-char through `CharReader`, yielding via `SMTask::Schedule()/Block()` and bailing on `SIGINT`.

### External / internal deps
- `<termios.h>`, `isatty`, `open`. Internal: `CharReader`, `SignalHook`, `SMTask`, `xstring`.

---

## Module: Fish

### Files & LOC
- `Fish.h` (169) + `Fish.cc` (1205) = **1374 LOC**

### Purpose
File transfer by piping shell snippets to a remote shell over ssh and parsing the textual replies. Each command is wrapped so the server emits `### NNN` status lines (e.g. `### 200` success, `### 000` continue).

### Key classes/types
- `class Fish : public SSH_Access`. States: `DISCONNECTED, CONNECTING, CONNECTING_1, CONNECTED, FILE_RECV, FILE_SEND, WAITING, DONE`.
- `enum expect_t` (12 tags): `EXPECT_FISH, EXPECT_VER, EXPECT_PWD, EXPECT_CWD, EXPECT_DIR, EXPECT_RETR_INFO, EXPECT_RETR, EXPECT_INFO, EXPECT_DEFAULT, EXPECT_STOR_PRELIMINARY, EXPECT_STOR, EXPECT_QUOTE, EXPECT_IGNORE`.
- Reply correlation is a strict **FIFO**: `xqueue<expect_t> RespQueue` (commands complete in order — there is no out-of-order concern, unlike SFTP). `StringSet path_queue` tracks pending directory/path context.
- Helpers: `FishDirList`, `FishListInfo : GenericParseListInfo`, `ParseLongList` (parses `ls -l`-style output into a `FileSet`).

### Protocol / command set
- Greeting: `echo FISH:;<shell>`; handshake sends `#FISH ... start_fish_server; echo '### 200'` then `#VER 0.0.2`.
- Commands (all `Send(...)` printf-style, each followed by `echo '### NNN'`): `#PWD`, `#CWD`, `#LIST`, `#INFO`, `#RETR`/`#RETRP` (with offset), `#STOR <size> <name>`, `#DELE`, `#RMD`, `#MKD`, `#RENAME`, `#CHMOD`, `#LINK`, `#SYMLINK`, `#EXEC`. Data transfer is length-prefixed (`body_size`/`bytes_received` track the byte count of a `#RETR` body).

### Deps
- External program: `ssh` (same launch path as SFtp). No extra C libs beyond the shared SSH_Access/PtyShell.
- Internal: `SSH_Access`, `StringSet`, `GenericParseListInfo`, `ArgV`, `IOBuffer`, charset translation (`fish:charset`).

---

## Module: SFtp

### Files & LOC
- `SFtp.h` (832) + `SFtp.cc` (2336) = **3168 LOC** (largest in the subsystem; ~half the header is the packet-class hierarchy)

### Purpose
Full SFTP wire-protocol client (protocol versions 3–6, negotiated), framed over the ssh data pipes. Supports pipelined reads/writes with many packets in flight and out-of-order reply reassembly.

### Key classes/types
- `class SFtp : public SSH_Access`. States: `DISCONNECTED, CONNECTING, CONNECTING_1, CONNECTING_2, CONNECTED, FILE_RECV, FILE_SEND, WAITING, DONE`. `protocol_version`, `unsigned ssh_id` (monotonic request id), `xstring handle` (open file/dir handle).
- **Packet class hierarchy** (all nested): base `Packet` → `PacketUINT32`, `PacketSTRING`, `PacketSTRING_ATTRS`; concrete `Request_*` (INIT, OPEN, CLOSE, READ, WRITE, OPENDIR, READDIR, REALPATH, STAT/FSTAT, SETSTAT/FSETSTAT, MKDIR, RMDIR, REMOVE, RENAME, READLINK, SYMLINK, LINK) and `Reply_*` (VERSION, HANDLE, DATA, NAME, ATTRS, STATUS). Each knows how to `Pack(Buffer*)`, `ComputeLength()`, and `Unpack(const Buffer*)` returning `unpack_status_t {UNPACK_SUCCESS, UNPACK_WRONG_FORMAT, UNPACK_PREMATURE_EOF, UNPACK_NO_DATA_YET}`.
- `struct FileAttrs` (+ nested `ExtFileAttr`, `FileACE`) and `struct NameAttrs` — version-aware attribute (un)packing covering the full v3–v6 flag/type/ACL matrix.
- Helpers: `SFtpDirList`, `SFtpListInfo`.

### The SFTP protocol state machine / packet handling

**Wire framing:** every packet is `uint32 length` then `uint8 type` then (for most) `uint32 id` then a type-specific body. `Packet::Unpack` is two-phase: a stack `Packet probe` first peeks length+type+id from `recv_buf` returning `UNPACK_NO_DATA_YET` if fewer than 4/`length` bytes have arrived; `UnpackPacket()` then allocates the concrete `Reply_*` by type and unpacks the body. Strings are `uint32 len` + bytes.

**Packet types** (`enum packet_type`, `SFtp.h:37-69`):
- Requests `1–23`: `SSH_FXP_INIT`(1), `OPEN`(3), `CLOSE`(4), `READ`(5), `WRITE`(6), `LSTAT`(7), `FSTAT`(8), `SETSTAT`(9), `FSETSTAT`(10), `OPENDIR`(11), `READDIR`(12), `REMOVE`(13), `MKDIR`(14), `RMDIR`(15), `REALPATH`(16), `STAT`(17), `RENAME`(18, v≥2), `READLINK`(19, v≥3), `SYMLINK`(20, v≤5), `LINK`(21, v≥6), `BLOCK`(22)/`UNBLOCK`(23, v≥6).
- Replies: `SSH_FXP_VERSION`(2), `STATUS`(101), `HANDLE`(102), `DATA`(103), `NAME`(104), `ATTRS`(105), `EXTENDED`(200)/`EXTENDED_REPLY`(201). Valid replies = VERSION, 101–105, EXTENDED_REPLY.
- `enum sftp_status_t` (SSH_FX_OK=0 … SSH_FX_GROUP_INVALID=30); `sftp_file_type`; large set of `SSH_FILEXFER_ATTR_*` flags and per-version masks (`MASK_V3..V6`); open modes/flags (`SSH_FXF_*`), ACE4 ACL masks, RENAME flags.

**Handshake:** `Request_INIT(version)` → expect `Reply_VERSION`; then `Request_REALPATH(".")` to learn home. Version drives which attr fields and open-flag encoding are used.

**Request/reply correlation (the core mechanism):**
- Every request gets `id = ssh_id++` and is registered via `PushExpect`, which inserts an `Expect{request, tag, i}` into **`xmap_p<Expect> expect_queue`** keyed by the 4-byte id (`Expect::GetKey()`).
- A reply is matched in `FindExpectExclusive(reply)`: `expect_queue.borrow(reply->GetKey())` — an O(1) hash lookup by id, NOT a FIFO. This is what makes pipelined, out-of-order completion possible.
- `Expect::tag` (`HOME_PATH, FXP_VERSION, CWD, HANDLE, HANDLE_STALE, DATA, INFO, INFO_READLINK, DEFAULT, WRITE_STATUS, IGNORE`) selects how `HandleExpect()` interprets the matched reply.

**Pipelining & flow control:** `Read()` keeps up to `max_packets_in_flight` (slow-start ramped `max_packets_in_flight_slow_start`) `Request_READ`s outstanding, bounded also by `max_out_of_order - ooo_chain.count()`. `request_pos` tracks the next byte offset to request; `RequestMoreData()` issues the next READ/READDIR.

**Out-of-order handling (the 4.9.3 fix area):**
- A `Reply_DATA` is only consumed in place if `r->pos == pos + file_buf->Size()` (it is the next contiguous chunk). Otherwise the whole `Expect` is parked on **`xarray_p<Expect> ooo_chain`** (capped at `max_out_of_order=64`; overflow → "Too many out-of-order packets" → Disconnect).
- `HandleReplies()` (`SFtp.cc:1046`), each pump, first scans `ooo_chain` for an entry whose `has_data_at_pos(need_pos)` matches the now-current contiguous position and replays it via `HandleExpect`, draining the chain as the gap fills.
- **EOF correctness** is the subtle part the NEWS "sftp out-of-order fix" addresses: `file_buf->PutEOF()` is only emitted when `ooo_chain.count()==0` **and** `!HasExpectBefore(reply->GetID(), Expect::DATA)` — i.e. no earlier-id DATA request is still outstanding. `HasExpectBefore` uses `IsBefore()` with **wrap-around-safe** id comparison (`id2-id1 < id1-id2`). Emitting EOF while an earlier read is still in flight or buffered out-of-order would truncate the file — that is the bug class fixed in 4.9.3.

**Charset:** v<4 servers are bytes; lftp does optional `lc_to_utf8`/`utf8_to_lc` translation (`send_translate`/`recv_translate` DirectedBuffers, `sftp:charset`). v≥4 is UTF-8 on the wire.

### External deps
- External program: **`ssh`** launched as `ssh -a -x ... -s host sftp` (the `-s` runs the ssh2 sftp subsystem) or a path-style `server-program` (then prefixed `echo SFTP: >&2;`). No SFTP C library — framing is hand-rolled over `Buffer`.
- C libs: only via PtyShell (pty/util) and standard `<sys/stat.h>` types.

### Internal deps
- `SSH_Access`, `FileSet`/`FileInfo`, `Buffer`/`IOBuffer` (`PackUINT32BE`/`UnpackUINT32BE` etc.), `xmap_p`/`xarray_p`/`xstring`/`Ref`, `DirList`/`ListInfo`/`GenericGlob`, `ResMgr`, `Timer`.

---

## Nim mapping

### Subprocess management — chronos `asyncproc`
- chronos provides `asyncproc` (`startProcess`, `AsyncProcessRef`, async pipe streams). For Fish/SFtp the natural shape is: spawn `ssh`, get async byte streams for stdin/stdout (the data channel) and stderr (the diagnostic/prompt channel).
- The hard part is **not the subprocess but the PTY**: ssh only emits interactive password/host-key prompts when it sees a controlling terminal. `asyncproc` does not allocate a pty. lftp's split — data over pipes, prompts over the pty master (fd 2 of the child is always the tty) — must be reproduced.

### PTY allocation in Nim
- There is **no pure-Nim pty** abstraction in std/chronos. You must wrap POSIX: `posix_openpt(O_RDWR or O_NOCTTY)`, `grantpt`, `unlockpt`, `ptsname` (Linux/macOS path), or `openpty()` from `-lutil`. Nim's `std/posix` exposes the primitives but not `openpty`/`grantpt`/`ptsname` directly — declare them via `importc` from `<stdlib.h>`/`<util.h>`/`<pty.h>` (and add `--passL:-lutil` on Linux/BSD). This is essentially a direct transliteration of `lftp_pty.c`.
- The fork+exec+`setsid`+`TIOCSCTTY`+`SIGSTOP`/`SIGCONT` dance in `PtyShell::getfd()` must be ported almost verbatim with `std/posix` (`fork`, `execvp`, `dup2`, `setsid`, `ioctl`). Make the master fd non-blocking and register it with chronos via `AsyncFD`/`addReader`. **No pure approach exists** — this is the single most platform-bound piece in the whole subsystem. (Windows has no equivalent; SFTP/FISH would be POSIX-only, as in lftp.)

### SFTP packet framing with chronos streams
- Replace the `Buffer`/`IOBuffer` pack/unpack with a `seq[byte]`/`AsyncBuffer` reader. The two-phase peek (length, then full-body availability) maps cleanly onto chronos `AsyncStreamReader.readExactly`/`readMessage`, or a manual ring buffer feeding a `tryUnpack(): Option[Packet]`.
- The packet class hierarchy → Nim `object variant`s (a `case type: PacketType` discriminated record) with `pack(s: var seq[byte])` / `unpack` procs, or a typeclass + methods. Version-conditional fields stay as runtime branches on `protocolVersion`.
- Request/reply correlation → a `Table[uint32, Expect]` keyed by id (direct map of `xmap_p<Expect> expect_queue`); the out-of-order buffer → a `seq[Expect]` (`ooo_chain`). The pipelining loop (issue READs up to in-flight limit, reassemble by contiguous `pos`, wrap-around-safe `isBefore`) ports 1:1 — keep the **`ooo_chain.count()==0 and not hasExpectBefore(id, Data)` EOF guard** intact, it is load-bearing.
- chronos lets you replace lftp's hand-rolled `Do()` re-entrant pump with `async`/`await` coroutines: one task draining the data stream and dispatching by id, futures completing per-request. This is a genuine simplification over the SMTask cooperative model, but you must preserve the flow-control/back-pressure semantics (`max_packets_in_flight`, slow-start, rate limiting).

### Pure-Nim ssh client vs spawning system ssh — recommendation
- **lftp spawns the system `ssh` binary** and relies on the user's ssh config, agent, known_hosts, key auth, ProxyJump, etc. There is **no production-grade pure-Nim SSH transport** library; the realistic alternative is binding **libssh2** or **libssh** (C libs) for a true SFTP channel.
- **Recommendation: keep spawning system `ssh` for the initial port.** It is a behavioral 1:1 with lftp (same auth surface, same config), avoids reimplementing SSH crypto/auth, and keeps FISH (which fundamentally needs a remote *shell*, not an SFTP channel) on the same code path. The cost is the PTY-prompt machinery. A later optional backend could use libssh2 for SFTP to drop the pty entirely — but that splits SFtp and Fish and loses ssh-config fidelity, so it is a v2 concern, not the port baseline.

---

## Port complexity

| Module | LOC | Complexity | Justification |
|---|---|---|---|
| GetPass | 120 | **Low** | Small; termios echo-off + line read. Direct POSIX wrap. |
| PtyShell + lftp_pty | 318 (+pty.c) | **High** | Pure-platform pty allocation + fork/exec/setsid/TIOCSCTTY/SIGSTOP choreography; no Nim/chronos abstraction; multi-OS `#ifdef` fan-out; the riskiest piece. |
| SSH_Access | 284 | **Medium** | Logic is straightforward but the *interaction* (prompt detection on pty vs data on pipes, masking, greeting sync) is fiddly and timing-sensitive. |
| Fish | 1374 | **Medium** | Lots of code but conceptually simple: format shell command, await `### NNN`, strict FIFO queue, parse `ls -l`. No binary framing, no OOO. |
| SFtp | 3168 | **High** | Large versioned binary protocol (v3–v6 attr matrix, ~25 packet types), id-keyed correlation, pipelining + slow-start, **out-of-order reassembly with the wrap-around-safe EOF guard**. Correctness-critical and the most code. |

---

## Gotchas

1. **PTY allocation is the keystone and is non-portable.** Everything depends on `open_pty` succeeding. Get `posix_openpt/grantpt/unlockpt/ptsname` (or `openpty` + `-lutil`) right per-OS; macOS and Linux differ. No pure-Nim path; Windows is out.
2. **SIGSTOP/SIGCONT handshake.** The child `kill(getpid(),SIGSTOP)`s itself right after `setsid()`/`TIOCSCTTY`; the parent `waitpid(...,WUNTRACED)`, wires the 4 buffers, then `Kill(SIGCONT)` (in `MakePtyBuffers`). Skip this ordering and you race the child's first prompt. Port it exactly.
3. **Two channels, two roles.** Data is on stdin/stdout **pipes**; password prompts, host-key `yes/no`, and ssh diagnostics are on the **pty master** (child fd 2). Don't collapse them. Prompt classification is heuristic string matching (`'s password`, trailing `:` + "password"/"passphrase", trailing `?` + "yes/no") — fragile across ssh/locale versions, which is why the child forces `LC_ALL=C`.
4. **Password sent at most once.** A second password prompt ⇒ "Login incorrect" (not a retry loop). The local-echo `XXXX` masks the password from logs.
5. **SFTP out-of-order EOF (the 4.9.3 fix).** Only `PutEOF()` when `ooo_chain` is empty **and** no earlier-id `DATA` request is outstanding (`HasExpectBefore` with wrap-around-safe `IsBefore`). Emitting EOF early truncates downloads. Also enforce the `max_out_of_order=64` cap → disconnect on overflow.
6. **Wrap-around request ids.** `ssh_id` is a free-running `unsigned`; ordering comparisons must use modular distance, not `<`.
7. **Protocol-version conditioning everywhere.** Attr packing, open-flag encoding, RENAME/LINK availability, and charset behavior (v<4 = bytes + optional `lc_to_utf8`; v≥4 = UTF-8) all branch on the negotiated version. Replicate the v3–v6 masks faithfully.
8. **Two-phase unpack / partial reads.** Packets can straddle stream reads; `UNPACK_NO_DATA_YET` must leave `recv_buf` untouched until the full `length` is buffered. Mirror with chronos `readExactly` or a peeking ring buffer.
9. **FISH relies on a cooperating remote shell** (`start_fish_server`, `### NNN` markers, `ls -l` format). It is a remote *shell*, not an SFTP channel — a libssh2 SFTP backend cannot serve FISH; it must keep the exec-a-shell model.

---

## Subsystem summary

- **Total LOC:** ~5264 across the named files (SFtp 3168, Fish 1374, SSH_Access 284, PtyShell 318, GetPass 120), plus the `lftp_pty.c/.h` pty helper they all depend on.
- **Overall complexity: High**, concentrated in two places: the **SFTP binary protocol engine** (versioned packets + id-keyed pipelining + out-of-order reassembly with the correctness-critical EOF guard) and the **PTY allocation/subprocess choreography** (non-portable POSIX, no Nim abstraction).
- **Subprocess + PTY porting strategy:** Keep lftp's architecture — **spawn the system `ssh` binary** (no pure-Nim or libssh2 SSH transport in the baseline) so auth/config/known_hosts fidelity is preserved and FISH's remote-shell model still works. Build a Nim `PtyShell` equivalent by `importc`-wrapping POSIX pty primitives (`posix_openpt/grantpt/unlockpt/ptsname`, or `openpty` + `--passL:-lutil`) and transliterating the fork/exec/`setsid`/`TIOCSCTTY`/`SIGSTOP`→`SIGCONT` sequence. Drive **two channels** through chronos `asyncproc`/`AsyncFD`: binary/command data over the stdin/stdout pipes, and password/host-key prompts over the pty master, replicating the heuristic prompt detection. Replace the SMTask `Do()` pump with chronos coroutines, but preserve flow control (`max_packets_in_flight`, slow-start), the id `Table` correlation, the `ooo_chain` reassembly, and the wrap-around-safe early-EOF guard verbatim. Treat a libssh2-based pure-SFTP backend (which would eliminate the pty) as an optional v2, not the initial port.
