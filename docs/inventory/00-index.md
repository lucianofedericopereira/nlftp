# lftp Source Inventory — Index

Full module-by-module inventory of lftp 4.9.3, written to plan the Nim port.
See `../PLAN.md` for the synthesis and `../DECISIONS.md` for locked choices.

| Doc | Subsystem | Upstream LOC | Complexity |
|-----|-----------|-------------:|------------|
| [01-core-runtime.md](01-core-runtime.md) | SMTask scheduler, buffers, xstring/xarray/xmap, timers | ~6,080 | High (much vanishes) |
| [02-fileaccess-local.md](02-fileaccess-local.md) | FileAccess contract, LocalAccess, FileSet, Resolver, url | ~10,540 | High |
| [03-ftp.md](03-ftp.md) | FTP/FTPS engine (13-state machine), list parsers, FXP | ~7,470 | Very High |
| [04-http.md](04-http.md) | HTTP/HTTPS, chunked/keepalive, WebDAV, Basic/Digest auth | ~5,330 | High |
| [05-sftp-fish-ssh.md](05-sftp-fish-ssh.md) | SFTP packet protocol, FISH, ssh subprocess, PTY | ~5,260 | High |
| [06-jobs-commands-shell.md](07-jobs-commands-shell.md) | 84 commands, Job scheduler, MirrorJob, readline/completion | ~16,870 | High |
| [07-settings-ssl-misc-build.md](08-settings-ssl-misc-build.md) | 199 settings, TLS abstraction, build deps, gnulib/trio | ~8,420 | Mixed |
| [08-open-issues-triage.md](09-open-issues-triage.md) | 256 open GitHub issues categorized for the port | — | — |
