## Phase 1 shell tests: command tokenizer + scripted execution.

import std/[os, strutils]
import unittest2
import chronos
import ../nlftp/fs/fileaccess
import ../nlftp/core/settings
import ../nlftp/shell/parsecmd
import ../nlftp/shell/cmdexec

suite "tokenizer":
  test "plain words":
    check tokenize("get file.txt -o out") == @["get", "file.txt", "-o", "out"]

  test "single and double quotes":
    check tokenize("""echo 'a b' "c d" """) == @["echo", "a b", "c d"]

  test "backslash escape":
    check tokenize("""cd my\ dir""") == @["cd", "my dir"]

  test "double-quote keeps backslash escapes":
    check tokenize(""""a\"b"""") == @["""a"b"""]

  test "comment stripped":
    check tokenize("ls # this is a comment") == @["ls"]

  test "semicolon separates commands":
    let cmds = parseCommands("cd src; ls; get x")
    check cmds.len == 3
    check cmds[0].words == @["cd", "src"]
    check cmds[2].words == @["get", "x"]

  test "empty line yields nothing":
    check parseCommands("   ").len == 0
    check parseCommands("# just a comment").len == 0

suite "scripted execution":
  test "cd/ls/get/put round-trip via the shell":
    proc run() {.async.} =
      let base = getTempDir() / "nlftp_shell_" & $getCurrentProcessId()
      removeDir(base)
      createDir(base / "remote")
      createDir(base / "local")
      writeFile(base / "remote" / "data.txt", "payload")
      defer: removeDir(base)

      let x = newCmdExec()
      await x.execLine("cd " & base / "remote")
      await x.execLine("lcd " & base / "local")
      check x.session.getCwd == base / "remote"
      check x.localFa.getCwd == base / "local"
      await x.execLine("get data.txt")
      check fileExists(base / "local" / "data.txt")
      check readFile(base / "local" / "data.txt") == "payload"
      await x.execLine("put data.txt -o echoed.txt")  # local->session
      check fileExists(base / "remote" / "echoed.txt")

    waitFor run()

  test "settings via shell":
    proc run() {.async.} =
      let x = newCmdExec()
      check x.settings.query("ftp:passive-mode") == "yes"
      await x.execLine("set ftp:passive-mode no")
      check x.settings.query("ftp:passive-mode") == "no"
    waitFor run()

  test "unknown command does not crash":
    proc run() {.async.} =
      let x = newCmdExec()
      await x.execLine("boguscmd arg")   # prints to stderr, no raise
    waitFor run()

  test "quit flag":
    proc run() {.async.} =
      let x = newCmdExec()
      await x.execLine("exit")
      check x.quitFlag
    waitFor run()

  test "cmd:fail-exit aborts with exit code 1":
    proc run() {.async.} =
      let x = newCmdExec()
      await x.execLine("boguscmd")           # default: continues
      check not x.quitFlag
      await x.execLine("set cmd:fail-exit yes")
      await x.execLine("boguscmd")           # now aborts
      check x.quitFlag
      check x.exitCode == 1
    waitFor run()

  test "alias expansion":
    proc run() {.async.} =
      let x = newCmdExec()
      await x.execLine("alias q exit")
      await x.execLine("q")          # alias -> exit
      check x.quitFlag
    waitFor run()

suite "glob":
  test "wildcard matching":
    check matchGlob("hello.txt", "*.txt")
    check matchGlob("hello.txt", "h*.txt")
    check matchGlob("hello.txt", "?ello.txt")
    check matchGlob("hello.txt", "hello.txt")
    check not matchGlob("hello.txt", "*.sig")
    check not matchGlob("hello.txt", "world*")
    check matchGlob("a", "*")
    check matchGlob("", "*")
