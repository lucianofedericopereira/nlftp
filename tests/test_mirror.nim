## Phase 4 mirror tests (local->local, deterministic): full copy, skip-unchanged,
## recursion into subdirs, and the post-transfer --delete phase.

import std/[os, strutils]
import unittest2
import chronos
import ../nlftp/fs/[fileaccess, localaccess]
import ../nlftp/core/retry
import ../nlftp/jobs/mirror

suite "mirror":
  test "full copy, skip-unchanged, recurse, delete":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_mirror_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "src" / "sub")
      writeFile(base / "src" / "a.txt", "alpha")
      writeFile(base / "src" / "b.txt", "bravo")
      writeFile(base / "src" / "sub" / "c.txt", "charlie")
      createDir(base / "dst")
      defer: removeDir(base)

      let srcFa: FileAccess = newLocalAccess(base / "src")
      let dstFa: FileAccess = newLocalAccess(base / "dst")

      # 1. full copy
      var st = await runMirror(srcFa, dstFa, ".", ".", MirrorOpts())
      check st.filesTransferred == 3
      check st.dirsMade == 1
      check readFile(base / "dst" / "a.txt") == "alpha"
      check readFile(base / "dst" / "sub" / "c.txt") == "charlie"

      # 2. second run skips all (same size)
      st = await runMirror(srcFa, dstFa, ".", ".", MirrorOpts())
      check st.filesTransferred == 0
      check st.filesSkipped == 3

      # 3. changed size -> retransferred
      writeFile(base / "src" / "a.txt", "alpha-extended")
      st = await runMirror(srcFa, dstFa, ".", ".", MirrorOpts())
      check st.filesTransferred == 1
      check readFile(base / "dst" / "a.txt") == "alpha-extended"

      # 4. --delete removes dest-only files
      writeFile(base / "dst" / "stale.txt", "remove me")
      st = await runMirror(srcFa, dstFa, ".", ".",
                           MirrorOpts(deleteExtra: true))
      check st.removed == 1
      check not fileExists(base / "dst" / "stale.txt")
      check fileExists(base / "dst" / "a.txt")        # real files survive

    waitFor run()

  test "exclude / include glob filters":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_mfilt_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "src"); createDir(base / "dst1"); createDir(base / "dst2")
      defer: removeDir(base)
      writeFile(base / "src" / "a.txt", "a")
      writeFile(base / "src" / "b.tmp", "b")
      writeFile(base / "src" / "c.txt", "c")

      let s: FileAccess = newLocalAccess(base / "src")
      # exclude *.tmp
      var st = await runMirror(s, newLocalAccess(base / "dst1"), ".", ".",
                               MirrorOpts(exclude: "*.tmp"))
      check st.filesTransferred == 2
      check not fileExists(base / "dst1" / "b.tmp")
      check fileExists(base / "dst1" / "a.txt")
      # include only *.txt
      st = await runMirror(s, newLocalAccess(base / "dst2"), ".", ".",
                           MirrorOpts(includePat: "*.txt"))
      check st.filesTransferred == 2
      check not fileExists(base / "dst2" / "b.tmp")

    waitFor run()

  test "transfer retry: honors net:max-retries then gives up":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_mretry_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "src"); createDir(base / "dst")
      writeFile(base / "src" / "a.txt", "data")
      # make the source file unreadable so every openRead (hence copyFile) fails
      setFilePermissions(base / "src" / "a.txt", {})
      defer:
        setFilePermissions(base / "src" / "a.txt", {fpUserRead, fpUserWrite})
        removeDir(base)

      let s: FileAccess = newLocalAccess(base / "src")
      let d: FileAccess = newLocalAccess(base / "dst")

      # with retry on: retried exactly maxRetries times, then 1 recorded error
      var retries = 0
      let withRetry = MirrorOpts(
        retry: RetryConfig(maxRetries: 2, baseSec: 0.0),  # baseSec 0 = no backoff sleep
        logErr: proc(m: string) {.gcsafe, raises: [].} =
          if "retry" in m: inc retries)
      var st = await runMirror(s, d, ".", ".", withRetry)
      check st.errors == 1
      check retries == 2

      # with retry off (default): fails immediately, no retries
      retries = 0
      let noRetry = MirrorOpts(
        logErr: proc(m: string) {.gcsafe, raises: [].} =
          if "retry" in m: inc retries)
      st = await runMirror(s, d, ".", ".", noRetry)
      check st.errors == 1
      check retries == 0

    waitFor run()

  test "parallel transfers copy every file correctly":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_pmirror_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "src" / "d1"); createDir(base / "src" / "d2")
      createDir(base / "dst")
      defer: removeDir(base)
      # 20 files across subdirs, distinct contents
      for i in 0 ..< 20:
        let sub = (if i mod 2 == 0: "d1" else: "d2")
        writeFile(base / "src" / sub / ("f" & $i & ".txt"), "content-" & $i)

      let srcFa: FileAccess = newLocalAccess(base / "src")
      let dstFa: FileAccess = newLocalAccess(base / "dst")
      let st = await runMirror(srcFa, dstFa, ".", ".",
                               MirrorOpts(parallel: 4))
      check st.filesTransferred == 20
      check st.errors == 0
      # verify every file landed with correct content (no cross-talk/races)
      for i in 0 ..< 20:
        let sub = (if i mod 2 == 0: "d1" else: "d2")
        check readFile(base / "dst" / sub / ("f" & $i & ".txt")) ==
              "content-" & $i

    waitFor run()
