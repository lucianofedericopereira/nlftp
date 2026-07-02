# Subsystem Inventory 03 — FTP / FTPS protocol

Source: `lftp 4.9.3`, files under `/Users/studiox/Downloads/lftp/src/src/` (flat).
Target port: **Nim** with the **`chronos`** async library.

This subsystem implements the FTP and FTPS (explicit/implicit TLS) client. It is the
single largest protocol driver in lftp and is the canonical reference for how a
`FileAccess` backend is structured. The whole thing is a hand-written, single-threaded,
cooperatively-scheduled (`SMTask`) **non-blocking state machine** — there is no thread,
no callback soup, just one giant `Do()` that is re-entered by the scheduler whenever a
socket becomes ready or a timer fires. This shape is exactly what `chronos` `async`/`await`
exists to replace.

---

## Module: ftpclass (`ftpclass.cc` / `ftpclass.h`)

### Files & LOC
| File | LOC |
|------|-----|
| `ftpclass.cc` | 5183 |
| `ftpclass.h` | 580 |
| **total** | **5763** |

### Purpose
The FTP/FTPS protocol engine. Manages the **control connection** (command/reply dialog)
and the **data connection** (file transfers and directory listings), full login flow
(USER/PASS/ACCT, proxy auth, S/Key, .netrc), FEAT-based capability negotiation, passive
(PASV/EPSV/CEPR/CPSV) and active (PORT/EPRT) data channels, TLS (AUTH TLS, PBSZ, PROT,
CCC, SSCN), resume (REST), MODE Z compression, MLSD/LIST/STAT listing, and FXP
(server-to-server) copies. Implements the abstract `FileAccess`/`NetAccess` interface so
the rest of lftp can drive it generically.

### Key classes/types & responsibilities
- **`Ftp : public NetAccess`** — the protocol driver. Holds the state machine (`Do()`),
  the active `Connection`, the `ExpectQueue`, settings cache, copy-mode (FXP) state, and
  the `FileAccess` virtual method implementations.
- **`FtpS : public Ftp`** — trivial subclass; sets `ftps=true` so the connection opens
  with implicit TLS (port 990) and `PROT P` by default. `GetProto()` returns `"ftps"`.
- **`Ftp::Connection`** (nested) — owns one physical control connection and its current
  data connection: `control_sock`, `control_recv`/`control_send` (`IOBuffer`s), the unsent
  `send_cmd_buffer` (a `DirectedBuffer`), `data_sock`/`data_iobuf`, `peer_sa`/`data_sa`
  socket addresses, the optional telnet-IAC layer, and the full bag of **per-server
  capability flags** discovered via FEAT (`mlst_supported`, `epsv_supported`,
  `rest_supported`, `mode_z_supported`, `auth_supported`, `utf8_activated`, `prot`, …).
  Also holds the `control_ssl` (`lftp_ssl`) handle and several timers
  (`waiting_150_timer`, `abor_close_timer`, `stat_timer`, `waiting_ssl_timer`).
- **`Ftp::Expect`** + **`Ftp::ExpectQueue`** — the heart of the asynchronous command
  pipeline. Every command sent pushes an `Expect` record onto the queue tagged with a
  `check_case` (e.g. `USER`, `PASS`, `PASV`, `EPSV`, `PORT`, `REST`, `TRANSFER`, `CWD`,
  `FEAT`, `AUTH_TLS`, `PROT`, `CCC`, `SIZE_OPT`, `MDTM_OPT`, `QUOTED`, …). When a reply
  line completes, `CheckResp(code)` pops the matching `Expect` and runs case-specific
  validation. This decouples *send* from *reply handling* and is what makes pipelined
  (non-sync) mode possible. ~45 `expect_t` cases.
- **`TelnetEncode`/`TelnetDecode`/`IOBufferTelnet`** — RFC 854 telnet IAC escaping on the
  control channel (`use-telnet-iac`), stacked as an `IOBuffer` translator.
- **`pasv_state_t`** — sub-state machine for the passive-mode data-socket connect:
  `PASV_NO_ADDRESS_YET → PASV_HAVE_ADDRESS → PASV_DATASOCKET_CONNECTING → PASV_HTTP_PROXY_CONNECTED`.
- **`ConnectLevel`** — coarse external view of connection progress
  (`CL_NOT_CONNECTED … CL_LOGGED_IN … CL_JUST_BEFORE_DISCONNECT`), used by connection
  reuse / pooling logic (`GetBetterConnection`, `MoveConnectionHere`).

### The FTP connection state machine
`enum automate_state` (declared in `ftpclass.h:51`), driven by the single big `switch(state)`
inside `int Ftp::Do()` (`ftpclass.cc`, switch begins ~line 1438). The cases **fall through**
deliberately — each state, once its work is done, sets `state=NEXT` and lets control drop
into the next case in the same `Do()` pass. Re-entry happens via the `SMTask` scheduler
when a socket/timer is ready.

States (13):

| State | Meaning | Exits to |
|-------|---------|----------|
| `INITIAL_STATE` | all sockets closed; allocate `Connection`+`ExpectQueue`, create control socket, `SocketConnect()`, → | `CONNECTING_STATE` |
| `CONNECTING_STATE` | `Poll(control_sock,POLLOUT)`; on connect build IOBuffers (SSL buffers if ftps/ftps-proxy); send CONNECT to http-proxy if any | `HTTP_PROXY_CONNECTED` or `CONNECTED_STATE` |
| `HTTP_PROXY_CONNECTED` | wait for http-proxy CONNECT reply | `CONNECTED_STATE` |
| `CONNECTED_STATE` | got greeting (`Expect::READY`); optionally `FEAT`; `AUTH TLS` if SSL allowed; build USER (incl. all proxy-auth variants); send `USER` | `USER_RESP_WAITING_STATE` |
| `USER_RESP_WAITING_STATE` | got USER reply; send `PASS`/`ACCT`/S-Key/netkey, post-login `FEAT`/`OPTS MLST`, `SITE` cmds, `PWD`, and TLS `PBSZ`/`PROT`/`CCC` | `EOF_STATE` |
| `EOF_STATE` | **idle / logged-in dispatch hub.** Control open, no transfer. Resolves home/`CWD`, picks the operation for `mode`, builds the command (RETR/STOR/LIST/MLSD/NLST/MKD/DELE/RNFR/SITE…/QUOTE/STAT), sends `TYPE`/`MODE Z`/`SIZE`/`MDTM`/`PROT`/`SSCN`, then either issues PASV/EPSV/CPSV or PORT/EPRT and `REST`+transfer command | `CWD_CWD_WAITING_STATE` then `DATASOCKET_CONNECTING_STATE` / `ACCEPTING_STATE` / `WAITING_STATE` |
| `CWD_CWD_WAITING_STATE` | wait for all in-flight `CWD` (and critical `PROT`/`SSCN`) to finish; allocate+bind data socket, `listen()` if active | data-channel setup (see `EOF_STATE` row) |
| `DATASOCKET_CONNECTING_STATE` | **passive** path; runs the `pasv_state_t` sub-machine: wait for PASV/EPSV address, validate it, connect new data socket, (or hand FXP address to peer), http-proxy data CONNECT | `WAITING_150_STATE` (via `pre_waiting_150`) |
| `ACCEPTING_STATE` | **active** path; `Poll(data_sock,POLLIN)` then `SocketAccept()`, verify peer address | `WAITING_150_STATE` |
| `WAITING_150_STATE` | wait for the `1xx` "150 Opening data connection" (or `received_150`); then wrap data socket in SSL (`PROT P`), MODE-Z inflate/deflate translator, charset translator, rate limiter | `DATA_OPEN_STATE` |
| `DATA_OPEN_STATE` | data connection live, pumping bytes; rate-limit/back-pressure via suspend/resume; NOOP keep-alive on idle; on data EOF → | `WAITING_STATE` (or `EOF_STATE` on error) |
| `WAITING_STATE` | data done / FXP / non-data command; drain `ExpectQueue`, wait for final `2xx` (e.g. 226), STAT polling for FXP progress, set `eof` | `EOF_STATE` |
| `WAITING_CCC_SHUTDOWN` | after `CCC` accepted: wait for server to SSL-shutdown the control channel, then rebuild plaintext buffers | `EOF_STATE` (`pre_EOF_STATE`) |

Cross-cutting transitions:
- **`Disconnect()` / `DisconnectNow()` / `ControlClose()`** reset to `INITIAL_STATE` from
  any state (error, 421, peer close, timeout) and trigger retry via `retry_timer`/`NextTry`.
- `DataAbort()` sends `ABOR` (urgent, telnet IP/DM) and parks the half-closed data socket
  in `aborted_data_sock` with `abor_close_timer`.
- The `mode` field (`open_mode`: RETRIEVE/STORE/LIST/LONG_LIST/MP_LIST/CHANGE_DIR/MAKE_DIR/
  REMOVE/RENAME/CHANGE_MODE/QUOTE_CMD/ARRAY_INFO/CONNECT_VERIFY…) selects which branch
  `EOF_STATE` takes — it is the *operation*, orthogonal to the connection *state*.

Reply parsing: `ReceiveResp()` → `ReceiveOneLine()` handles multiline replies
(`NNN-…`/`NNN …`), `<CR><NUL>`→`<CR>` per RFC 2640, telnet decode, and the `sync_wait`
counter (commands in flight). `CheckResp(code)` pops the `Expect` and dispatches the
~45-case validation switch. Outbound side: commands are queued into
`Connection::send_cmd_buffer` by `SendCmd*`, then `FlushSendQueueOneCmd()` writes **one
command per `sync_wait` slot** when in sync mode (or all of them when pipelining).

### External C-library deps
- **OpenSSL/GnuTLS via `lftp_ssl`** (`#if USE_SSL`) — all TLS is funneled through the
  project's `lftp_ssl` wrapper and `IOBufferSSL`; ftpclass never touches OpenSSL directly.
  Used for AUTH TLS control channel (`MakeSSLBuffers`), per-data-connection SSL
  (`WAITING_150_STATE`, with optional `copy_sid` session-ID sharing between control and
  data), `PBSZ`/`PROT`/`CCC`/`SSCN`.
- **libc sockets** — `socket`/`connect`/`bind`/`listen`/`accept`/`getsockname` via lftp's
  `Socket*` helpers; `sockaddr_u` union for IPv4/IPv6; `inet_pton`, `htons`.
- **`trio`** (printf), **`sscanf`** (PASV/EPSV/SIZE/MDTM parsing), `zlib` indirectly via
  `DataDeflator`/`DataInflator` for MODE Z.

### Internal deps
- **`FileAccess` / `NetAccess`** (base classes) — virtual interface: `Read`, `Write`,
  `Buffered`, `Close`, `SendEOT`, `StoreStatus`, `Do`, `Done`, `CurrentStatus`,
  `MakeListInfo`, `MakeGlob`, `MakeDirList`, `Clone`, `New`, `SameLocationAs`. `NetAccess`
  supplies `peer[]`/`Resolver` integration, proxy config, retry/timeout timers,
  `RateLimit`, `idle_timer`.
- **`IOBuffer` family** — `IOBufferFDStream`, `IOBufferSSL`, `IOBufferStacked`,
  `DirectedBuffer`, `DataTranslator` (telnet, charset, deflate/inflate). All I/O goes
  through these.
- **`Resolver`** (via `NetAccess::peer`) — hostname → `sockaddr_u` list, with
  `NextPeer()` failover.
- **`lftp_ssl`** — TLS.
- **`ResMgr` / `Query*`** — the enormous settings surface (`ftp:passive-mode`,
  `ftp:ssl-allow`, `ftp:use-feat`, `ftp:prefer-epsv`, `ftp:fix-pasv-address`,
  `ftp:use-mode-z`, `ftp:nop-interval`, `ftp:port-range`, etc.).
- **`netrc.cc`**, **`FtpListInfo`**, **`FtpDirList`**, **`FileCopyFtp`** (this subsystem).
- **`SMTask`** scheduler — `Do()`/`Done()`/`MOVED`/`STALL`, `Timer`, `SuspendInternal`/
  `ResumeInternal`.

---

## Module: FtpListInfo (`FtpListInfo.cc` / `FtpListInfo.h`)

### Files & LOC
| File | LOC |
|------|-----|
| `FtpListInfo.cc` | 849 |
| `FtpListInfo.h` | 33 |

### Purpose
Parses the **raw bytes returned by LIST/MLSD** into a structured `FileSet`. Subclass of
`GenericParseListInfo`. Because FTP `LIST` output is server-OS-dependent and unstandardized,
this module runs **7 candidate parsers in parallel** over the listing and picks the one with
the fewest errors (auto-detection).

### Key classes/types
- **`FtpListInfo : GenericParseListInfo`** — `Parse()` chooses MLSD/LONG-LIST vs short
  NLST; `ParseShortList()` for bare-name NLST output.
- **`Ftp::ParseLongList()`** (lives in `FtpListInfo.cc`, lines 61+) — the parallel-parser
  driver: for each line, feeds a copy to all 7 parsers, tracks per-parser error counts,
  locks onto the best parser once confident.
- **`Ftp::line_parsers[7]`** — the parser table:
  `ParseFtpLongList_UNIX`, `_NT`, `_EPLF`, `_MLSD`, `_AS400`, `_OS2`, `_MacWebStar`.
  UNIX delegates to `FileInfo::parse_ls_line`; MLSD parses `facts;name`
  (`type=`, `size=`, `modify=`, `UNIX.mode/owner/group/uid/gid=`, `perm=`); EPLF parses
  `+`-prefixed facts. `parse_perms()` converts `drwxr-xr-x` strings to `mode_t`.

### Internal deps
`FileSet`, `FileInfo`, `Ftp` (for `ParseLongList`/`line_parsers`/`Query("timezone")`),
`misc`, `ascii_ctype`.

---

## Module: FtpDirList (`FtpDirList.cc` / `FtpDirList.h`)

### Files & LOC
| File | LOC |
|------|-----|
| `FtpDirList.cc` | 269 |
| `FtpDirList.h` | 44 |

### Purpose
The human-facing `ls`/`cls` directory listing for FTP. Unlike `FtpListInfo` (which builds a
machine `FileSet`), `FtpDirList` streams the listing to the user's terminal, optionally
**reformatting** EPLF/MLSD/colorized lines into readable text.

### Key classes/types
- **`FtpDirList : DirList`** — own `SMTask` `Do()` loop that reads from a data-channel
  `IOBuffer ubuf` line-by-line and writes formatted output. `TryEPLF()`, `TryMLSD()`,
  `TryColor()` recognize and reformat machine listing formats; `FormatGeneric()` produces
  the long-format line. `Status()` reports progress.

### Internal deps
`DirList`, `IOBuffer`, `FileInfo`, `Ftp`/`FtpListInfo` formats, `ArgV`.

---

## Module: FileCopyFtp (`FileCopyFtp.cc` / `FileCopyFtp.h`)

### Files & LOC
| File | LOC |
|------|-----|
| `FileCopyFtp.cc` | 264 |
| `FileCopyFtp.h` | 53 |

### Purpose
**FXP** — direct FTP-server-to-FTP-server transfer with no data routed through the client.
Coordinates two `Ftp` sessions: one passive, one active. One side's PASV/EPSV address is
captured (`copy_addr`) and fed to the other side's PORT/EPRT, then both are told to
STOR/RETR. Handles fallback negotiation when servers refuse FXP (flip
`fxp-passive-source`, `fxp-passive-sscn`, `ssl-protect-fxp`, or disable FXP entirely).

### Key classes/types
- **`FileCopyFtp : FileCopy`** — `Do()` orchestrates the two peers via
  `Ftp::SetCopyMode(COPY_SOURCE/COPY_DEST,…)`, `SetCopyAddress()`, `CopyIsReadyForStore()`,
  `CopyAllowStore()`. Tracks per-side retries and the SSL/passive/protect toggles for
  fallback. `Ftp` exposes the FXP hooks (`copy_mode`, `copy_addr`, `copy_passive`,
  `copy_protect`, `CopyFailed()` …) in `ftpclass.h`.

### Internal deps
`FileCopy`, `Ftp` (FXP API surface), `FileCopyPeer`.

---

## Module: netrc (`netrc.cc` / `netrc.h`)

### Files & LOC
| File | LOC |
|------|-----|
| `netrc.cc` | 155 |
| `netrc.h` | 43 |

### Purpose
Parses `~/.netrc` for stored credentials. `NetRC::LookupHost(host,user)` opens the file
(`fopen`), tokenizes `machine`/`login`/`password`/`account`/`default` entries, and returns a
matching `NetRC::Entry{host,user,pass,acct}`. Used by the FTP login flow to auto-fill
USER/PASS/ACCT.

### Key classes/types
- **`NetRC::Entry`** — `{host,user,pass,acct}` xstrings.
- **`NetRC::LookupHost`** — static parser/lookup (should also check file permissions for
  security; classic `.netrc` 0600 expectation).

### Internal deps
`xstring` only (plus libc `fopen`/`getenv`). The cleanest, most self-contained module of
the five — a good first thing to port.

---

## Nim mapping (chronos)

**The big win: the `Do()` mega-switch collapses into linear `async` procs.** The C++ code
is an explicit continuation-passing state machine *precisely because* C++ has no `await`.
In Nim/chronos most of those states vanish into straight-line code:

- `INITIAL_STATE`→`CONNECTING_STATE`→`HTTP_PROXY_CONNECTED`→`CONNECTED_STATE`→
  `USER_RESP_WAITING_STATE` becomes one `proc connectAndLogin(): Future[void] {.async.}`:
  ```nim
  let transp = await connect(peerAddr)        # was CONNECTING_STATE + Poll(POLLOUT)
  var ctrl = newAsyncStreamReader/Writer(transp)
  if ftps: ctrl = await wrapTls(ctrl, host)   # AUTH TLS / implicit
  await expectReply(ctrl, 220)                # READY
  if useFeat: await feat(ctrl)
  await cmd(ctrl, "USER " & user); await expectReply(...)
  await cmd(ctrl, "PASS " & pass); await expectReply(...)
  ```
- **Control connection** = a chronos `StreamTransport` wrapped in `AsyncStreamReader`/
  `AsyncStreamWriter`. `ReceiveOneLine()` → `await reader.readLine()` (chronos has a
  bounded line reader; keep the multiline `NNN-`/`NNN ` and `<CR><NUL>` handling). Telnet
  IAC and charset translation become small stream-transformer layers (chronos
  `AsyncStream` layering mirrors `IOBufferStacked`).
- **Data connection** = a second `StreamTransport`. Passive: `await connect(pasvAddr)`.
  Active: an `StreamServer` that you `await accept()` on. `WAITING_150_STATE` becomes
  `await expectReply(150)` *interleaved* with the transfer — note FTP allows the 150 and
  the data to race, so use `let (one, two) = await all/oneOf(...)` style or just start the
  data future and await the control reply concurrently.
- **TLS data channel**: after PASV/PORT + `PROT P`, wrap the data transport with the same
  TLS layer; preserve `ssl-copy-sid` (session resumption between control and data) — this
  is required by many servers and is a real chronos/`bearssl`/`openssl`-binding concern.
- **The `ExpectQueue`** mostly disappears: in `await`-style code each command's reply is
  awaited right where it's sent, so the send/reply decoupling is unnecessary for the
  synchronous path. **But** keep a lightweight reply-router for: (a) pipelined/non-sync
  mode (multiple commands in flight — model as a `Future`-per-command queue or an
  `AsyncQueue[Reply]`), and (b) unsolicited `421`/`STAT` progress lines. A practical Nim
  design: one background `proc readReplies()` that pushes parsed replies into per-command
  `Future[Reply]`s.
- **Back-pressure** (`DATA_OPEN_STATE` suspend/resume, rate limiting): chronos streams have
  natural flow control via `await write`/`await read`; the manual `Suspend/Resume/max_buf`
  logic becomes bounded reads plus an `AsyncRateLimiter`. NOOP keep-alive → an
  `asyncSpawn`'d timer loop or `withTimeout`.
- **List parsing** (`FtpListInfo`, `FtpDirList`) is pure CPU, no async — port the 7
  parsers and the parallel best-of-7 selector almost verbatim into pure procs operating on
  a buffer. Easiest part.
- **FXP** (`FileCopyFtp`): two `Ftp` async objects; capture one's PASV `Future[Address]`,
  feed the other's `PORT`. Maps cleanly to two concurrent coroutines coordinated by a
  shared address.
- **`.netrc`**: trivial sync parser — port directly.
- **Timers** (`abor_close_timer`, `waiting_150_timer`, retry/idle) → `chronos`
  `sleepAsync` / `withTimeout` / `addTimer`.

---

## Port complexity

| Module | Complexity | Justification |
|--------|-----------|---------------|
| `ftpclass` | **Very High** | 5.7k LOC, 13-state machine + PASV sub-machine + ~45 Expect cases, FEAT capability matrix, TLS (AUTH/PBSZ/PROT/CCC/SSCN, data-channel SSL, sid sharing), telnet IAC, MODE Z, proxy (http CONNECT + 4 FTP proxy-auth styles), active+passive+EPSV/CEPR/CPSV, REST/resume, ABOR, NOOP keep-alive, connection reuse/pooling, S/Key. The async rewrite *simplifies* control flow but the protocol breadth and the long tail of server-bug workarounds are the real cost. |
| `FtpListInfo` | **Medium** | 7 server-format parsers + parallel best-of-N selector; pure logic, but fiddly date/perm/quirk handling per OS. |
| `FtpDirList` | **Low–Medium** | One stream loop + 3 format detectors + formatter. |
| `FileCopyFtp` | **Medium** | Small, but the two-session FXP coordination + fallback toggles are subtle. Depends on the `ftpclass` FXP API existing first. |
| `netrc` | **Low** | ~150 LOC self-contained parser. Port first as a warm-up. |

Recommended order: `netrc` → list parsers (`FtpListInfo`/`FtpDirList`) → `ftpclass`
control+login → data transfer → TLS → proxy/FXP/quirks last.

---

## Gotchas

- **FTPS data channel must be TLS-wrapped *after* PASV/PORT and `PROT P`**, and many
  servers require **TLS session resumption** (the data connection reuses the control
  connection's session — `ssl-copy-sid`); some refuse the data connection otherwise. This
  is the #1 FTPS interop pitfall.
- **`CCC` (Clear Command Channel)** drops the control channel back to plaintext *mid-session*
  (for NAT/firewall ALG traversal) — `WAITING_CCC_SHUTDOWN` waits for the server's TLS
  close-notify, then rebuilds plaintext buffers. Easy to get the shutdown ordering wrong.
- **PASV NAT breakage** (`fix-pasv-address`, `ignore-pasv-address`): servers behind NAT
  return their *private* IP in the PASV reply. lftp detects private/loopback/multicast/
  reserved mismatches vs the control peer and substitutes the control peer's address
  (`fixed_pasv`). Must replicate, or transfers hang.
- **EPSV vs PASV fallback** and the variants: `EPSV` (RFC 2428, IPv6-capable),
  `CEPR`/custom EPSV (`Handle_EPSV_CEPR`, `(|proto|addr|port|)`), `CPSV` (PASV that makes
  the *server* do `SSL_connect` for FXP). `prefer-epsv`, `auto-passive-mode` can flip
  active/passive after a failed connect (`PASV_DATASOCKET_CONNECTING` error path).
- **The 150/226 race & "transfer complete before EOF"**: the final `226` can arrive before
  *or* after the data-channel EOF; `WAITING_150_STATE`/`WAITING_STATE` coordinate both.
  Also the proftpd "resets data connection when no files found" workaround (LIST + empty +
  no 150 → treat as empty success).
- **Multiline replies & `421`**: `NNN-`…`NNN ` framing, `strict-multiline`, and unsolicited
  `421` (server going away) can interrupt any state — needs an out-of-band reply path even
  in the `await` design.
- **`sync-mode` auto-detection**: some servers can't pipeline; lftp watches for `331`
  ordering anomalies / `auto-sync-mode` regex and *reconnects* with sync mode on. Port
  must support both pipelined and one-command-at-a-time control flow.
- **Telnet IAC escaping** on the control channel (`0xFF` doubling, IP/DM for ABOR urgent
  data) and **RFC 2640 `<CR><NUL>`→`<CR>`** plus UTF-8 / charset translation of paths.
- **Active mode `PORT` with `port-range`/`bind-data-socket`/`port-ipv4`** — binding a data
  socket in a configured port range with retries, faking the advertised IP for NAT, and
  EPRT for IPv6. Firewall-hostile; rarely the default but must work.
- **MODE Z** (zlib deflate/inflate `DataTranslator`) is negotiated per-transfer and stacks
  under the SSL layer.
- **REST quirks**: `rest-stor`, `rest-list` off for buggy servers; servers that don't reset
  REST after a transfer (`last_rest` tracking); `NOREST_MODE`.
- **`.netrc` is security-sensitive** — should enforce 0600-ish permissions and never log
  the password (mirror `may_show_password`/`PASS XXXX` redaction in the control log).

---

## Subsystem summary

**Total LOC:** ~7,473 across 10 files (`ftpclass` 5,763; `FtpListInfo` 882; `FtpDirList`
313; `FileCopyFtp` 317; `netrc` 198).

**Complexity:** Very High overall, concentrated in `ftpclass`. It is the most feature-dense
protocol in lftp: full FTP + FTPS (explicit & implicit TLS, AUTH/PBSZ/PROT/CCC/SSCN with
data-channel session resumption), active + passive (PASV/EPSV/CEPR/CPSV/PORT/EPRT) with NAT
fixups and EPSV↔PASV fallback, REST/resume, MODE Z compression, telnet-IAC + charset
translation, http-CONNECT and four FTP-proxy auth styles, FXP server-to-server copy, S/Key,
`.netrc`, capability negotiation via FEAT, and a long tail of per-server bug workarounds.
The list parsing (7 auto-detected formats) is independently nontrivial but pure-CPU.

**State machine (concise):** A single non-blocking `Ftp::Do()` walks
`INITIAL → CONNECTING → [HTTP_PROXY_CONNECTED] → CONNECTED → USER_RESP_WAITING → EOF`
(the logged-in idle/dispatch hub). For each transfer it goes
`EOF → CWD_CWD_WAITING → {DATASOCKET_CONNECTING (passive, with its own
PASV_NO_ADDRESS_YET→HAVE_ADDRESS→CONNECTING→HTTP_PROXY sub-machine) | ACCEPTING (active)} →
WAITING_150 → DATA_OPEN → WAITING → EOF`. `WAITING_CCC_SHUTDOWN` is a side excursion for
clearing the TLS command channel. Outbound commands queue into `send_cmd_buffer` and are
flushed one-per-`sync_wait`; each reply is matched against the `ExpectQueue` by
`CheckResp()`. In the Nim/chronos port the connection/login/transfer chains collapse into
linear `async`/`await` procs over chronos `StreamTransport`s (control + data), with a small
reply-router retained only for pipelined mode and unsolicited `421`/`STAT` lines.
