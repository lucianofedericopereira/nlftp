## Tests for the pragmatic batch: netrc parsing, bookmarks, source, get -c resume.

import std/[os, tables]
import unittest2
import chronos
import ../nlftp/fs/[fileaccess, localaccess, netrc]
import ../nlftp/core/settings
import ../nlftp/shell/cmdexec

suite "netrc":
  test "machine entries and default":
    let entries = parseNetrc("""
      # a comment
      machine ftp.example.com login alice password s3cret
      machine other.host login bob password pw2
      default login anon password anon@
    """)
    check entries.len == 3
    check lookupNetrc(entries, "ftp.example.com") == ("alice", "s3cret")
    check lookupNetrc(entries, "other.host") == ("bob", "pw2")
    check lookupNetrc(entries, "unknown.host") == ("anon", "anon@")  # default

  test "no default, unknown host -> empty":
    let entries = parseNetrc("machine h login u password p")
    check lookupNetrc(entries, "nope") == ("", "")

suite "bookmarks + source + resume":
  test "bookmark add stores url; open resolves name":
    proc run() {.async.} =
      let x = newCmdExec()
      x.bookmarks.clear()
      await x.execLine("bookmark add gnu ftp://ftp.gnu.org/pub")
      check x.bookmarks["gnu"] == "ftp://ftp.gnu.org/pub"
    waitFor run()

  test "source runs a sub-script inline":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_src_" & $getCurrentProcessId()
      createDir(base)
      defer: removeDir(base)
      writeFile(base / "s.nlftp", "set ftp:passive-mode no\n")
      let x = newCmdExec()
      check x.settings.query("ftp:passive-mode") == "yes"
      await x.execLine("source " & base / "s.nlftp")
      check x.settings.query("ftp:passive-mode") == "no"   # sourced effect applied
    waitFor run()

  test "xfer:clobber off prevents overwrite":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_clob_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "src"); createDir(base / "dst")
      defer: removeDir(base)
      writeFile(base / "src" / "f.txt", "original")
      let x = newCmdExec()
      await x.execLine("cd " & base / "src")
      await x.execLine("lcd " & base / "dst")
      await x.execLine("get f.txt")
      check readFile(base / "dst" / "f.txt") == "original"
      # change source, turn clobber off, re-get -> dst must NOT change
      writeFile(base / "src" / "f.txt", "CHANGED")
      await x.execLine("set xfer:clobber no")
      await x.execLine("get f.txt")                 # refused (prints to stderr)
      check readFile(base / "dst" / "f.txt") == "original"
    waitFor run()

  test "get -c resumes a truncated local file byte-exactly":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_resume_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "remote"); createDir(base / "local")
      defer: removeDir(base)
      let full = "0123456789ABCDEFGHIJ" & "abcdefghij"   # 30 bytes
      writeFile(base / "remote" / "f.bin", full)
      writeFile(base / "local" / "f.bin", full[0 ..< 12])  # truncated

      let x = newCmdExec()
      await x.execLine("cd " & base / "remote")
      await x.execLine("lcd " & base / "local")
      await x.execLine("get -c f.bin")
      check readFile(base / "local" / "f.bin") == full
    waitFor run()
