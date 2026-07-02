# nlftp — a modern, pure-Nim, POSIX-only port of lftp 4.9.3
# (port of github.com/lavv17/lftp; derivative work — stays GPLv3)

version       = "0.0.1"
author        = "nlftp contributors"
description   = "A modern pure-Nim port of lftp (FTP/FTPS/HTTP/HTTPS/SFTP client)"
license       = "GPL-3.0-or-later"
srcDir        = "nlftp"
bin           = @["nlftp"]
binDir        = "bin"

# Dependencies
requires "nim >= 2.0.0"
requires "chronos >= 4.0.0"   # async runtime — successor to lftp's SMTask scheduler
requires "zippy >= 0.10.0"    # pure-Nim gzip/zlib (replaces C zlib)

# Pure-Nim-first: sha1, parsexml, encodings, terminal, uri all come from stdlib.

import std/os

task test, "run all test suites":
  for f in ["core", "net", "fs", "shell", "ftp", "http", "mirror", "sftp",
            "features", "walk", "pget", "jobs", "progress", "retry"]:
    echo "=== test_" & f & " ==="
    exec "nim c -r --hints:off -w:off -o:bin/test_" & f & " tests/test_" & f & ".nim"
