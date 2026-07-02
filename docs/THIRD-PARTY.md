# Third-Party Notices

nlftp is **GPL-3.0-or-later** (derivative of lftp). It uses and/or adapts code
from the projects below, all under licenses compatible with GPLv3. Their
attribution notices are retained here and in the relevant source files.

## Dependencies (linked, not copied)

| Project | License | Use |
|---------|---------|-----|
| [chronos](https://github.com/status-im/nim-chronos) | Apache-2.0 / MIT | async runtime, stream stack (TLS/chunked/bounded) |
| [zippy](https://github.com/guzba/zippy) | MIT | pure-Nim gzip/deflate codec |
| [bearssl](https://github.com/status-im/nim-bearssl) | MIT (BearSSL: MIT) | TLS backend (via chronos `tlsstream`) |
| Nim standard library | MIT | sha1, parsexml, encodings, terminal, uri, times, … |

### Available transitively (via chronos) — may be adopted later
| Project | License | Candidate use |
|---------|---------|---------------|
| [httputils](https://github.com/status-im/nim-http-utils) | Apache-2.0/MIT | HTTP message parsing (Phase 3) |
| [nimcrypto](https://github.com/cheatfate/nimcrypto) | Apache-2.0/MIT | MD5/SHA/HMAC (HTTP Digest auth, fingerprints) |
| [illwill](https://github.com/johnnovak/illwill) | WTFPL/MIT | TUI status line (Phase 4 — P1 eval) |

### Escalation option (not yet used)
| Project | License | Would be used for |
|---------|---------|-------------------|
| [nim-lang/zip](https://github.com/nim-lang/zip) | MIT (wraps C zlib, zlib license) | streaming inflate, only if zippy one-shot proves insufficient |

## Adapted code (patterns transcribed)

| Where in nlftp | Source | License | What was taken |
|----------------|--------|---------|----------------|
| `proto/http.nim` `headerHasToken` / `validateFraming` | [guzba/mummy](https://github.com/guzba/mummy) `headerContainsToken` + request-framing validation | MIT (© 2022 Ryan Oldenburg) | Pattern only (reimplemented): token-aware case-insensitive header matching; reject Content-Length+chunked, duplicate CL/TE, invalid CL (response-smuggling defenses applied client-side). |

## Reimplemented from lftp

The protocol logic, settings model, mirror algorithm, etc. are re-expressed in
Nim from lftp 4.9.3 (GPL-3.0). Same license; this whole project is the derivative.
