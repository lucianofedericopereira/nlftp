## Phase 1 tests: url parsing, ls-line parsing, and the LocalAccess backend
## exercised through the FileAccess contract.

import std/[os, options]
import unittest2
import chronos
import ../nlftp/fs/url
import ../nlftp/fs/fileinfo
import ../nlftp/fs/fileaccess
import ../nlftp/fs/localaccess

suite "url":
  test "full ftp url":
    let u = parseUrl("ftp://bob:secret@ftp.example.com:2121/pub/file.txt")
    check u.proto == "ftp"
    check u.user == "bob"
    check u.password == "secret"
    check u.hasPassword
    check u.host == "ftp.example.com"
    check u.port == 2121
    check u.path == "/pub/file.txt"
    check u.effectivePort == 2121
    check u.isRemote

  test "default port and no userinfo":
    let u = parseUrl("https://example.com/")
    check u.effectivePort == 443
    check u.user == ""
    check not u.hasPassword

  test "bare path is local":
    let u = parseUrl("/home/me/file")
    check u.proto == ""
    check u.path == "/home/me/file"
    check not u.isRemote

  test "percent decoding":
    let u = parseUrl("ftp://host/a%20b/c")
    check u.path == "/a b/c"

  test "IPv6 literal with port":
    let u = parseUrl("http://[2001:db8::1]:8080/path")
    check u.host == "2001:db8::1"        # brackets stripped for dialing
    check u.port == 8080
    check u.path == "/path"
    check $u == "http://[2001:db8::1]:8080/path"   # re-bracketed on render

  test "IPv6 literal default port":
    let u = parseUrl("ftp://[::1]/pub")
    check u.host == "::1"
    check u.effectivePort == 21
    check u.path == "/pub"

  test "IPv6 with userinfo":
    let u = parseUrl("sftp://bob@[fe80::1]:2222/")
    check u.user == "bob"
    check u.host == "fe80::1"
    check u.port == 2222

  test "hftp and fish are no longer known schemes":
    check "hftp" notin KnownProtos
    check "fish" notin KnownProtos

suite "ls-line parse":
  test "file":
    let fi = parseLsLine("-rw-r--r--  1 user group  1234 Jan 15 12:30 hello.txt")
    check fi.isSome
    check fi.get.name == "hello.txt"
    check fi.get.kind == ftFile
    check fi.get.size == some(1234'i64)

  test "directory":
    let fi = parseLsLine("drwxr-xr-x  2 user group  4096 Feb  3  2023 docs")
    check fi.get.kind == ftDir
    check fi.get.name == "docs"

  test "symlink with target":
    let fi = parseLsLine("lrwxrwxrwx 1 u g 7 Jan 1 00:00 link -> /target")
    check fi.get.kind == ftSymlink
    check fi.get.name == "link"
    check fi.get.symlink == "/target"

  test "total header and dotdirs skipped":
    check parseLsLine("total 48").isNone
    check parseLsLine("drwxr-xr-x 2 u g 4096 Jan 1 00:00 .").isNone

suite "LocalAccess (FileAccess contract)":
  test "list, read, write, mkdir, rename, remove round-trip":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_test_" & $getCurrentProcessId()
      createDir(base)
      defer: removeDir(base)
      writeFile(base / "a.txt", "hello world")

      let fa: FileAccess = newLocalAccess(base)

      # list
      let entries = await fa.listInfo()
      check entries.len == 1
      check entries[0].name == "a.txt"

      # read via contract
      let r = await fa.openRead("a.txt")
      var got: seq[byte]
      while not r.atEnd:
        let chunk = await r.readSome(4)
        if chunk.len == 0: break
        got.add chunk
      await r.closeReader()
      check cast[string](got) == "hello world"

      # write via contract (atomic temp + commit)
      let w = await fa.openWrite("b.txt")
      await w.writeSome(cast[seq[byte]]("copied data"))
      await w.finishWriter()
      check readFile(base / "b.txt") == "copied data"

      # mkdir / rename / remove
      await fa.mkdir("sub")
      check dirExists(base / "sub")
      await fa.rename("b.txt", "c.txt")
      check fileExists(base / "c.txt")
      await fa.remove("c.txt")
      check not fileExists(base / "c.txt")

      # chdir
      await fa.chdir("sub")
      check fa.getCwd == base / "sub"

    waitFor run()
