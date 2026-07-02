## Tests for the recursive walks: find, du, rm -r (local, deterministic).

import std/[os, algorithm]
import unittest2
import chronos
import ../nlftp/fs/[fileaccess, localaccess]
import ../nlftp/jobs/walk

suite "recursive walks":
  setup:
    let base = getTempDir() / "nlftp_walk_" & $getCurrentProcessId()
    removeDir(base)
    createDir(base / "a" / "b")
    createDir(base / "c")
    writeFile(base / "f1.txt", "x")          # 1
    writeFile(base / "a" / "f2.txt", "yy")    # 2
    writeFile(base / "a" / "b" / "f3.txt", "zzz")  # 3
    writeFile(base / "c" / "f4.txt", "w")     # 1
    let fa: FileAccess = newLocalAccess(base)

  teardown:
    removeDir(base)

  test "find lists the whole tree":
    proc run(): Future[seq[string]] {.async.} =
      var got = await findFiles(fa, "")
      got.sort()
      return got
    let got = waitFor run()
    check got == @["a/", "a/b/", "a/b/f3.txt", "a/f2.txt", "c/", "c/f4.txt",
                   "f1.txt"]

  test "du sums all file bytes recursively":
    check waitFor(duSize(fa, "")) == 7'i64    # 1+2+3+1

  test "humanSize rendering":
    check humanSize(512) == "512B"
    check humanSize(1024) == "1.0K"
    check humanSize(1536) == "1.5K"
    check humanSize(1048576) == "1.0M"

  test "rm -r removes a subtree, leaves siblings":
    proc run() {.async.} =
      await removeTree(fa, "a")
    waitFor run()
    check not dirExists(base / "a")
    check fileExists(base / "f1.txt")
    check fileExists(base / "c" / "f4.txt")

  test "removeTree on a file deletes just the file":
    proc run() {.async.} =
      await removeTree(fa, "f1.txt")
    waitFor run()
    check not fileExists(base / "f1.txt")
    check dirExists(base / "a")
