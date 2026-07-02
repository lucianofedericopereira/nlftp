## Segmented pget test — deterministic local source (exercises size +
## openReadRange + concurrent offset writes + reassembly).

import std/os
import unittest2
import chronos
import ../nlftp/fs/[fileaccess, localaccess]
import ../nlftp/jobs/pget

suite "pget":
  test "segmented download reassembles byte-exact":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_pget_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "src")
      defer: removeDir(base)
      # 5 MB with position-dependent bytes, so any mis-placed segment is caught
      var original = newString(5_000_000)
      for i in 0 ..< original.len: original[i] = char(i mod 256)
      writeFile(base / "src" / "big.bin", original)

      let src: FileAccess = newLocalAccess(base / "src")
      check (await src.size("big.bin")) == 5_000_000

      let res = await pget(src, "big.bin", base / "out.bin", 4)
      check res.segments == 4                  # 5MB/4 = 1.25MB/seg > 1MB min
      check res.bytes == 5_000_000
      check readFile(base / "out.bin") == original   # byte-exact, in order

    waitFor run()

  test "small file falls back to a single segment":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_pget1_" & $getCurrentProcessId()
      removeDir(base); createDir(base / "src")
      defer: removeDir(base)
      writeFile(base / "src" / "small.txt", "tiny")
      let src: FileAccess = newLocalAccess(base / "src")
      let res = await pget(src, "small.txt", base / "out.txt", 4)
      check res.segments == 1                  # below the split threshold
      check readFile(base / "out.txt") == "tiny"
    waitFor run()
