## Progress formatting tests (the bug-prone pure bits). The live status line is
## verified by demo; here we lock the human-size / ETA rendering.

import std/[math, strutils]
import unittest2
import ../nlftp/core/progress

suite "progress formatting":
  test "human size":
    check hsize(0) == "0B"
    check hsize(512) == "512B"
    check hsize(1023) == "1023B"
    check hsize(1024) == "1.0K"
    check hsize(1536) == "1.5K"
    check hsize(1048576) == "1.0M"
    check hsize(1610612736) == "1.5G"
    check hsize(-1) == "?"

  test "ETA":
    check heta(0) == "00:00"
    check heta(5) == "00:05"
    check heta(65) == "01:05"
    check heta(599) == "09:59"
    check heta(3661) == "01:01:01"
    check heta(Inf) == "--:--"
    check heta(-1) == "--:--"
    check heta(NaN) == "--:--"

  test "render line shows name + size when no total":
    let p = newProgressMeter("file.bin", -1, force = true)
    check p.renderLine().startsWith("file.bin")
