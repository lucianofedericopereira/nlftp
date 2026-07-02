## Background-job / queue tests (local, deterministic): queue runs jobs, wait
## blocks until all finish, jobs land their output.

import std/os
import unittest2
import chronos
import ../nlftp/fs/[fileaccess, localaccess]
import ../nlftp/shell/cmdexec

suite "queue / wait":
  test "queued jobs run and wait blocks until done":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_jobs_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "src"); createDir(base / "dst")
      defer: removeDir(base)
      writeFile(base / "src" / "a.txt", "alpha")
      writeFile(base / "src" / "b.txt", "bravo")
      writeFile(base / "src" / "c.txt", "charlie")

      let x = newCmdExec()
      await x.execLine("cd " & base / "src")
      await x.execLine("lcd " & base / "dst")
      await x.execLine("set cmd:queue-parallel 3")
      await x.execLine("queue get a.txt")
      await x.execLine("queue get b.txt")
      await x.execLine("queue get c.txt")
      await x.execLine("wait")

      check readFile(base / "dst" / "a.txt") == "alpha"
      check readFile(base / "dst" / "b.txt") == "bravo"
      check readFile(base / "dst" / "c.txt") == "charlie"

    waitFor run()

  test "waitAllJobs finishes jobs without an explicit wait":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_jobs2_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "src"); createDir(base / "dst")
      defer: removeDir(base)
      writeFile(base / "src" / "x.txt", "xray")

      let x = newCmdExec()
      await x.execLine("cd " & base / "src")
      await x.execLine("lcd " & base / "dst")
      await x.execLine("queue get x.txt")
      await waitAllJobs(x)             # the implicit end-of-script wait
      check readFile(base / "dst" / "x.txt") == "xray"

    waitFor run()
