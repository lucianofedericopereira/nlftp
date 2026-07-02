# Subsystem Inventory: HTTP / HTTPS Protocol

Port target: **Nim + chronos**. Source: `lftp 4.9.3`, flat dir `src/src/`.

This subsystem implements the `http://`, `https://`, and `hftp://` (FTP-over-HTTP-proxy)
schemes as concrete `FileAccess` / `NetAccess` backends, plus WebDAV and directory-listing
parsing.

---

## Module: Http (core protocol engine)

### Files & LOC
- `Http.cc` — 2842 lines
- `Http.h` — 278 lines

### Purpose
The HTTP client engine. Drives the connection lifecycle, builds requests for every
`FileAccess` operation (RETRIEVE / STORE / LIST / CHANGE_DIR / array-info / MKCOL / REMOVE /
RENAME / arbitrary QUOTE_CMD methods), parses status line + headers, decodes the body
(plain, chunked, gzip-inflate), handles redirects, ranges/resume, keep-alive, cookies,
authentication wiring, WebDAV PROPFIND/PROPPATCH/MOVE/COPY, and CONNECT tunneling for HTTPS
through a proxy. `HFtp` and `Https` are thin subclasses.

### Key classes / types
- `class Http : public NetAccess` — the engine. Implements the `FileAccess` virtual
  interface: `Do()`, `Read()`, `Write()`, `SendEOT()`, `StoreStatus()`, `Buffered()`,
  `Done()`, `Close()`, `Clone()`/`New()`, `MakeDirList()`, `MakeGlob()`, `MakeListInfo()`,
  `SameSiteAs()`, `SameLocationAs()`, `ParseLongList()`, `Reconfig()`, `CurrentStatus()`.
- `Http::Connection` (nested) — owns the socket `int sock`, a send `IOBuffer`, a recv
  `IOBuffer`, and (under `USE_SSL`) a `Ref<lftp_ssl> ssl`. `MakeBuffers()` vs
  `MakeSSLBuffers()` choose plaintext vs TLS buffers.
- `class HFtp : public Http` — FTP over HTTP proxy (`hftp`), requires a proxy, has its own
  `Login()`.
- `class Https : public Http` — sets `https=true`.
- Enums: `state_t`, `tunnel_state_t`, and an anonymous `special` enum
  (`HTTP_NONE/POST/MOVE/COPY/PROPFIND`).
- Numerous `H_*` status-code constants and classifier macros (`H_2XX`, `H_5XX`,
  `H_REDIRECTED`, `H_AUTH_REQ`, `H_TRANSIENT`, `H_CONTINUE`, `H_EMPTY`, `H_UNSUPPORTED`,
  `H_REQUESTED_RANGE_NOT_SATISFIABLE`, …) defined at the top of `Http.cc`.

### The HTTP request/response state machine
Primary `state_t` (member `state`), driven by `Http::Do()`:

1. `DISCONNECTED` — idle. Resolves host (`Resolve`), creates TCP socket, decides
   mode-supported, scans for a reusable idle session (`GetBetterConnection`, 3 levels),
   issues `SocketConnect`. Special-cases `hftp` (needs proxy), `ARRAY_INFO` pre-flight,
   `QUOTE_CMD` (POST/COPY/MOVE/PROPFIND/Set-Cookie). → `CONNECTING`.
2. `CONNECTING` — polls `POLLOUT`; on connect builds plaintext or SSL buffers. If
   `proxy && https`, sends `CONNECT host:port` and enters tunnel: `tunnel_state =
   TUNNEL_WAITING`, jumps to `RECEIVING_HEADER`. → `CONNECTED`.
3. `CONNECTED` — `SendRequest()` (or `SendArrayInfoRequest()`); sets up `rate_limit` for
   STORE. → `RECEIVING_HEADER`.
4. `RECEIVING_HEADER` — line-oriented parse via `find_eol`. First non-empty line = status
   line (`HTTP/x.y code`), sets `proto_version`, default keep-alive for ≥1.1. Subsequent
   lines → `HandleHeaderLine`. Empty line ends headers and branches: tunnel established →
   back to `CONNECTED`; chunked trailer → `DONE`/propfind; `100 Continue` → reset and loop;
   ARRAY_INFO/PROPFIND handling; STORE success → `DONE`; else `pre_RECEIVING_BODY`.
5. `pre_RECEIVING_BODY` (label, not an enum value) — post-header decisions: 204 empty body;
   416 range-not-satisfiable → `DONE`; 401/407 with a known scheme → disconnect+retry with
   auth; non-2xx → redirect handling or `SetError`; PROPFIND → allocate `propfind` XML
   buffer; set up gzip `inflate`; derive `entity_size` from `body_size`. → `RECEIVING_BODY`.
6. `RECEIVING_BODY` — rate-limit / `max_buf` flow control, suspend/resume recv buffer,
   timeout detection (also detects squid-emulated ranges → `no_ranges`). Actual byte
   delivery happens in `Read()`/`_Read()`, not here.
7. `DONE` — terminal; `Read()` returns EOF (0).

Secondary `tunnel_state_t`: `NO_TUNNEL` → `TUNNEL_WAITING` (CONNECT sent) → `TUNNEL_ESTABLISHED`.

A separate `propfind` `IOBufferFileAccess` sub-state is polled at the top of `Do()` to feed
WebDAV XML to `HttpListInfo::ParseProps` once EOF is hit, independent of `state`.

### Chunked transfer encoding
Implemented by hand in `_Read()` (Http.cc ~2117-2169):
- `chunked`, `chunked_trailer`, `chunk_size` (`CHUNK_SIZE_UNKNOWN` sentinel), `chunk_pos`.
- Reads hex chunk-size line (`sscanf("%lx")`), validates with `is_ascii_xdigit`; `Fatal`
  on malformed input. Chunk size 0 → sets `chunked_trailer`, switches back to
  `RECEIVING_HEADER` to consume optional trailer headers. Consumes the `\r\n` between
  chunks. `Transfer-Encoding: identity` is ignored; only `chunked` is supported.

### Keep-alive
`keep_alive`, `keep_alive_max`. Default true for HTTP/1.1. Parsed from `Connection`,
`Proxy-Connection`, and `Keep-Alive: max=` headers. `Close()` keeps the connection in an
idle pool when `keep_alive` and not chunked; `GetBetterConnection`/`MoveConnectionHere`
take over idle sessions. Note: chunked replies are explicitly **not** kept alive.

### Redirects
`HandleRedirection()` + `Location` header parsing in `HandleHeaderLine`. Tracks
`location`, `location_permanent` (301/308), `location_mode` (303 → RETRIEVE),
`location_file`. Relative vs absolute URL resolution; reuses username on same-host
redirects; special POST-relative resolution. Actual following is done by the upper
`FileAccess` layer re-opening the new location.

### Range / resume
`Range: bytes=` request lines emitted in `SendRequest` (start-only or start-limit, and a
`bytes=p-l/size` form for STORE). `Content-Range` response parsing sets `real_pos`,
`body_size`, `entity_size`. `no_ranges`, `seen_ranges_bytes` detect servers/proxies that
silently ignore ranges (e.g. squid) so `pget` resume logic can react. 416 → treat file as
fully received.

### WebDAV
`special` method dispatch + `SendPropfind`/`SendPropfindBody`/`SendProppatch`/
`SendMethod("PROPFIND"/"MOVE"/"COPY"/"MKCOL"…)`. PROPFIND used for `CHANGE_DIR` and
`ARRAY_INFO` (size/date) when `http:use-propfind` is on; falls back and disables itself on
405/501. `FormatLastModified` for PROPPATCH date. Response XML routed to `HttpDirXML`.

### HTTPS / TLS integration
Conditional `#if USE_SSL`. TLS is delegated to `lftp_ssl` (project wrapper over OpenSSL/
GnuTLS) via `Connection::MakeSSLBuffers()`. Two paths: direct `https://`, and `http`-proxy
+ `CONNECT` tunnel then upgrade to SSL buffers after a 2xx tunnel response.

### Auth
Wiring only here (algorithms in `HttpAuth`): `auth_sent[2]`, `auth_scheme[2]` for
`[WWW]`/`[PROXY]`. `NewAuth` parses `WWW-Authenticate`/`Proxy-Authenticate`, `SendAuth`
emits cached headers, plus inline Basic via `SendBasicAuth`. 401/407 trigger a
disconnect+retry once a scheme is learned.

### External C-library deps
- **OpenSSL/GnuTLS** — indirectly, via `lftp_ssl.h` (only under `USE_SSL`).
- **zlib** — gzip/deflate via `DataInflator` translator on a `DirectedBuffer` (project
  wrapper), triggered by `Content-Encoding`. `IsCompressed`, `CompressedContentEncoding`,
  `CompressedContentType`.
- libc: `sscanf`/`strtok`/`strcasecmp`/`memchr`/`alloca` throughout.
- No external HTTP library — the protocol is hand-rolled on raw sockets + `IOBuffer`.

### Internal deps
`NetAccess` (base: resolver, peer list, reconnect/retry, rate limiting, proxy config),
`IOBuffer`/`Buffer`/`DirectedBuffer`, `lftp_ssl`, `HttpHeader`, `HttpAuth`, `url`/`ParsedURL`,
`ResMgr`/`Query*` (settings), `xstring`/`xmap`/`xarray`, `FileSet`/`FileInfo`, `Log`,
`SMTask`, `IOBufferFileAccess`, `cache` (directory cache), `md5` (indirectly through HttpAuth).

### Nim mapping
- **Do not reuse `std/httpclient`.** It is a blocking/threaded, request/response convenience
  client with no incremental state machine, no session take-over/idle-pool, no STORE-with-
  resume, no PROPFIND, no proxy CONNECT control, and no integration point for lftp's
  buffer/rate-limit/`SMTask` cooperative model.
- **`chronos/apps/http/httpclient`** is a much better base: async, supports chunked,
  keep-alive connection pooling, redirects, TLS via chronos' bearssl integration, and
  request/response streaming. Recommended: build the lftp HTTP backend **on chronos'
  low-level HTTP client + raw `AsyncStream`s**, re-implementing the lftp-specific behaviors
  (resume/Range STORE, PROPFIND/PROPPATCH/MOVE/COPY, proxy-CONNECT tunnel, cookie jar,
  squid-range detection, idle-session reuse) as a layer on top. The byte-level chunked and
  keep-alive parsing in `_Read` can largely be replaced by chronos primitives.
- **WebDAV** is not in chronos; port `SendPropfind`/`SendProppatch` request building and the
  XML response handling explicitly.
- The cooperative `Do()` poll loop maps to an `async` proc with `await`; the explicit
  `state_t` machine can collapse into straight-line async code, but the STORE path (Write/
  SendEOT/StoreStatus driven by the upper layer) must keep an explicit resumable structure.

### Port complexity
**Very high.** ~2840 lines of dense, branch-heavy logic with many real-world server quirks
(broken Content-Length, squid range emulation, 0.9 responses, gzip-vs-content-type
heuristics, tunnel upgrade, propfind fallback). Even building on chronos, faithfully
reproducing resume + STORE + idle-session reuse + WebDAV is the single largest item in the
HTTP subsystem.

### Gotchas
- **proxy support**: three distinct modes — plain HTTP proxy (absolute-URI requests),
  `hftp` (FTP semantics over an HTTP proxy, no direct mode), and HTTPS-via-CONNECT tunnel.
  Each has its own auth target and URL formatting (`AppendHostEncoded`, `last_url`).
- **Chunked + keep-alive interaction**: chunked replies disable connection reuse here.
- **Squid/broken servers**: silent range-ignore detection, negative Content-Length
  workaround, EOF-while-fetching-headers redirect workaround, HTTP/0.9 fallback.
- **gzip**: many servers send `Content-Encoding: x-gzip` with a gzip content-type; lftp
  deliberately does **not** inflate those — replicate the `CompressedContentType` check.
- **STORE state machine** is subtle: PROPPATCH for mtime is sent as a *separate* request
  after a successful PUT (`sending_proppatch`, re-enters DISCONNECTED).

---

## Module: HttpAuth (authentication schemes)

### Files & LOC
- `HttpAuth.cc` — 245 lines
- `HttpAuth.h` — 107 lines

### Purpose
Parses `WWW-Authenticate`/`Proxy-Authenticate` challenges and computes `Authorization`/
`Proxy-Authorization` headers for **Basic** and **Digest**. Maintains a process-wide cache
of credentials keyed by target/uri-prefix/user.

### Key classes / types
- `HttpAuth` (base) — `target_t {WWW, PROXY}`, `scheme_t {NONE, BASIC, DIGEST}`, nested
  `Challenge` (parses `scheme param=value, …`, stores params in `xmap_p<xstring>`), static
  `cache` (`xarray_p<HttpAuth>`), `New`/`Get`/`CleanCache`/`Matches`/`ApplicableForURI`.
  Produces a `HttpHeader`.
- `HttpAuthBasic` — base64 of `user:pass`.
- `HttpAuthDigest` — RFC 2617 Digest: MD5 HA1 (with `MD5-sess` variant), per-request
  `Update()` computing HA2, response, `qop=auth`/`auth-int`, client `cnonce`, nonce-count
  `nc`. **No NTLM** — despite the task hint, lftp 4.9.3 implements only Basic and Digest.

### External C-library deps
- **MD5** via project `md5.h` (`md5_init_ctx`/`md5_process_bytes`/`md5_finish_ctx`) — a
  bundled implementation, not OpenSSL.
- base64 via project `base64_encode` (utils), `random()` for cnonce.

### Internal deps
`HttpHeader`, `xmap`/`xarray`/`xstring`, `md5`.

### Nim mapping
- Basic is trivial (`std/base64`).
- Digest: port directly using `std/md5` (or nimcrypto). Logic is self-contained and
  algorithmic — a clean, mechanical port. The credential cache → a Nim `seq`/`Table`.
- chronos' http client has no built-in Digest, so this must be ported regardless of the
  transport choice.

### Port complexity
**Low–medium.** Pure algorithm, well-isolated; the only care points are exact byte-for-byte
Digest string construction (quoting, `qop`, `nc` formatting) and `MD5-sess`.

### Gotchas
- **Digest** quoting/ordering must match servers exactly; `auth-int` requires an entity
  body hash that the caller must supply (`Update(..., entity_hash)`).
- cnonce uses `random()` — replace with a CSPRNG in the port.

---

## Module: HttpHeader (header value helpers)

### Files & LOC
- `HttpHeader.cc` — 58 lines
- `HttpHeader.h` — 39 lines

### Purpose
Tiny helper: a name/value header pair plus static `extract_quoted_value` (RFC 2616
quoted-string / token parsing) and `append_quoted_value` (escaping). Used by HttpAuth and
Http header parsing.

### Key classes / types
- `class HttpHeader { xstring name, value; ... }` with `SetValue`/`GetName`/`GetValue`.

### External C-library deps
None (libc `strcspn` only).

### Internal deps
`xmap`/`buffer`/`xstring`.

### Nim mapping
A few small string procs in Nim. Trivial.

### Port complexity
**Trivial.**

### Gotchas
- `extract_quoted_value` uses the RFC token separator set `()<>@,;:\"/[]?={} \t`; preserve
  it for compatibility with the challenge parser.

---

## Module: HttpDir (directory-listing parsers — HTML + dispatch)

### Files & LOC
- `HttpDir.cc` — 1444 lines
- `HttpDir.h` — 71 lines

### Purpose
Converts HTTP responses into `FileSet` directory listings. Two strategies: (1) heuristic
parsing of human-readable HTML index pages from many server/proxy products, and (2) WebDAV
property listings (delegated to `HttpDirXML`). Also the `DirList`/`ListInfo` glue.

### Key classes / types
- `HttpListInfo : GenericParseListInfo` — `Parse()` HTML→FileSet; static `ParseProps()`
  (defined in HttpDirXML.cc) for WebDAV.
- `HttpDirList : DirList` — streaming directory output; holds an `XML_Parser xml_p` +
  `xml_context` when `USE_EXPAT`, else falls back to `parse_as_html`. `ParsePropsFormat`
  drives incremental XML.
- `struct file_info` + ~26 `try_*` heuristic line parsers: `try_apache_listing`,
  `try_apache_listing_iso`, `try_apache_listing_unusual`, `try_apache_unixlike`,
  `try_netscape_proxy`, `try_squid_eplf`, `try_squid_ftp`, `try_mini_proxy`,
  `try_wwwoffle_ftp`, `try_csm_proxy`, `try_roxen`, `try_lighttpd_listing`, … plus an HTML
  tokenizer that extracts `href`/`src` from `<a>`, `<img>`, `<area>`, `<link>`, `<base>`.
- `Http::ParseLongList` (in HttpDir.cc, ~1416) is the entry the engine calls.

### External C-library deps
- **expat** (`<expat.h>`) — but only referenced here via the header include for
  `XML_Parser`; the actual expat calls live in HttpDirXML.cc. Guarded by `USE_EXPAT`.

### Internal deps
`Http`, `FileSet`/`FileInfo`, `url`/`ParsedURL`, `LsOptions`, `Log`, `misc`,
`GenericParseListInfo`/`DirList`.

### Nim mapping
- The HTML index parsing is bespoke, regex/`sscanf`-style heuristic matching against output
  of specific server versions. There is **no equivalent in std or chronos** — it must be
  ported essentially line-for-line (the value is precisely in matching these quirky
  formats). Use Nim `scanf`/`parseutils`/`re` (or `std/strscans`) per `try_*` parser.
- The HTML link extractor → a small Nim tag scanner (avoid pulling a full HTML5 parser; the
  original is intentionally lenient).

### Port complexity
**High.** Not algorithmically hard but voluminous and quirk-laden; ~1450 lines of
format-specific heuristics that only earn their keep when reproduced faithfully. Each
`try_*` needs its own test corpus.

### Gotchas
- Heuristic ordering matters (first parser that validates wins).
- `base href` handling rewrites relative links.
- Date parsing relies on `Http::atotm` (shared loose RFC-822/ISO date parser).

---

## Module: HttpDirXML (WebDAV PROPFIND XML parsing)

### Files & LOC
- `HttpDirXML.cc` — 249 lines (no separate header; declarations live in HttpDir.h)

### Purpose
Parses WebDAV `multistatus`/`response` XML (the body of a PROPFIND reply) into a `FileSet`,
both as a one-shot (`HttpListInfo::ParseProps`) and incrementally for streaming dir output
(`HttpDirList::ParsePropsFormat`).

### Key classes / types
- `struct xml_context` — a tag stack (`xarray_s<xstring_c>`), current `FileInfo`/`FileSet`,
  `base_dir`, char-data accumulator. Helpers `push`/`pop`/`process_chardata`, `in(tag)`
  namespace-qualified matching (`DAV:response`, `DAV:href`, `DAV:getcontentlength`,
  `DAV:getlastmodified`, `DAV:collection`, `DAV:creator-displayname`, and apache's
  `http://apache.org/dav/props/executable`).
- expat callbacks `start_handle`/`end_handle`/`chardata_handle`.

### External C-library deps
- **expat** (`XML_ParserCreateNS`, `XML_SetElementHandler`, `XML_SetCharacterDataHandler`,
  `XML_Parse`, `XML_GetErrorCode`, …), namespace-aware (`NS`) mode. Entire module is
  `#if USE_EXPAT`; otherwise `ParseProps`/`ParsePropsFormat` are stubs returning 0/no-op,
  and HttpDir falls back to HTML parsing.

### Internal deps
`HttpDir`/`Http` (uses `Http::atotm`), `FileSet`/`FileInfo`, `ParsedURL`, `Log`.

### Nim mapping
- Replace expat with **`std/xmlparser` + `std/xmltree`** (DOM) or, to preserve the
  streaming/namespace behavior, **`std/parsexml`** (a pull/StAX-style parser, closer to the
  expat callback model). `parsexml` is the better fit for the incremental `ParsePropsFormat`
  path and avoids buffering the whole multistatus.
- Namespace handling: expat is used in NS mode producing `DAV:` prefixed names; with
  `parsexml` you must do namespace resolution yourself (track `xmlns` attributes) or match
  on local-names — a real porting decision point.

### Port complexity
**Medium.** The state machine (tag stack, chardata dispatch) is small and clear; the work is
the XML-parser swap and reproducing namespace-qualified matching without expat's NS mode.

### Gotchas
- **WebDAV**: hrefs may be absolute URLs or percent-encoded paths; `process_chardata`
  re-parses href via `ParsedURL`, strips trailing `/` to detect collections, special-cases
  `/~`, and computes `.` for the base dir.
- Collections are detected from both `<DAV:collection>` and a trailing-slash href.
- Apache executable property sets the unix mode.
- The whole feature silently degrades to HTML parsing when expat is unavailable — the Nim
  port should decide whether WebDAV is mandatory (std/parsexml is always available, so it
  can be).

---

## Subsystem summary

**Total LOC:** ~5333 (Http 3120, HttpDir 1515, HttpDirXML 249, HttpAuth 352, HttpHeader 97).

**Overall complexity: HIGH**, concentrated almost entirely in `Http.cc` (the hand-rolled
request/response engine with resume/STORE/keep-alive/chunked/tunnel/WebDAV) and in the
voluminous `HttpDir.cc` HTML heuristics. HttpAuth, HttpHeader, and HttpDirXML are
individually small and mechanical.

**Reuse vs port:**
- **Transport:** build on **chronos** (`chronos/apps/http` low-level client + raw async
  streams + bearssl TLS), **not** `std/httpclient`. chronos gives async chunked, keep-alive
  pooling, redirects, and TLS for free, which removes the most error-prone byte-level code in
  `Http.cc`. **Do not** try to reuse `std/httpclient` — it lacks streaming, resume, pooling,
  proxy-CONNECT control, and WebDAV hooks.
- **Port lftp's own logic** for everything chronos doesn't cover: STORE-with-resume/Range,
  PROPFIND/PROPPATCH/MOVE/COPY (WebDAV), proxy-CONNECT tunneling, `hftp`, cookie jar,
  squid-range and broken-server workarounds, and idle-session reuse semantics.
- **Auth:** port HttpAuth verbatim (Basic + Digest; **no NTLM exists** in this codebase) on
  top of `std/md5`/`std/base64`; chronos has no Digest.
- **XML:** swap expat for **`std/parsexml`** (streaming, always available) — this also lets
  WebDAV be mandatory rather than a compile-time option.
- **HTML listing parsers:** no library substitute; port the `try_*` heuristics directly with
  a per-format test corpus.

Recommended porting order: HttpHeader → HttpAuth → HttpDirXML → Http (core, the big one) →
HttpDir (HTML heuristics, can be incremental/lazy).
