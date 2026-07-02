## Phase 0 core tests: errors, settings, buffer, and a chronos smoke test.

import std/[unittest, options]
import ../nlftp/core/errors
import ../nlftp/core/settings
import ../nlftp/core/defaults
import ../nlftp/core/buffer
import chronos   # proves the async dependency compiles & links

suite "errors":
  test "construction and formatting":
    let e = initError("boom", 42)
    check e.text == "boom"
    check e.code == 42
    check not e.isFatal
    check $e == "boom (42)"
    check $initError("plain") == "plain"

  test "fatal":
    check fatalError("dead").isFatal

  test "exception form carries payload":
    expect NlftpError:
      raiseError("nope", 7, true)
    try:
      raiseError("nope", 7, true)
    except NlftpError as ex:
      check ex.code == 7
      check ex.fatal

suite "settings":
  setup:
    let rm = newResMgr()
    rm.registerDefaults()

  test "default query":
    check rm.query("ftp:passive-mode") == "yes"
    check rm.queryBool("ftp:passive-mode")

  test "set and query override":
    rm.set("ftp:passive-mode", "no")
    check not rm.queryBool("ftp:passive-mode")

  test "closure-scoped override":
    rm.set("ftp:passive-mode/ftp.example.com", "no")
    check rm.queryBool("ftp:passive-mode")                       # global default
    check not rm.queryBool("ftp:passive-mode", "ftp.example.com") # host override

  test "closure suffix match":
    rm.set("ftp:passive-mode/example.com", "no")
    check not rm.queryBool("ftp:passive-mode", "ftp.example.com")

  test "abbreviation resolves unambiguously":
    check rm.query("mirror:parallel-transfer") == "1"

  test "ambiguous abbreviation raises":
    expect SettingsError:
      discard rm.query("ftp:ssl")   # several ftp:ssl-* settings

  test "unknown setting raises":
    expect SettingsError:
      discard rm.query("does:not-exist")

  test "validation rejects bad value":
    expect SettingsError:
      rm.set("ftp:passive-mode", "maybe")

  test "empty value reverts to default":
    rm.set("ftp:passive-mode", "no")
    rm.set("ftp:passive-mode", "")
    check rm.queryBool("ftp:passive-mode")

  test "numeric query":
    rm.set("sftp:max-packets-in-flight", "32")
    check rm.queryInt("sftp:max-packets-in-flight") == 32

suite "validators":
  test "bool":
    check validateBool("yes").isNone
    check validateBool("xyz").isSome
  test "time interval":
    check validateTimeInterval("1m30s").isNone
    check validateTimeInterval("2h").isNone
    check validateTimeInterval("infinity").isNone
    check validateTimeInterval("nonsense").isSome
  test "unumber":
    check validateUNumber("5").isNone
    check validateUNumber("-1").isSome

suite "buffer":
  test "put/peek/get round-trip":
    var b: Buffer
    b.put("hello")
    check b.len == 5
    check b.peekString() == "hello"
    check b.getString(5) == "hello"
    check b.isEmpty

  test "consume-without-shift tracks position":
    var b: Buffer
    b.put("abcdef")
    discard b.get(3)
    check b.position == 3
    check b.getString(3) == "def"
    check b.position == 6

  test "line framing":
    var b: Buffer
    b.put("220 Welcome\r\n230 Logg")
    check b.getLine() == "220 Welcome"
    check b.getLine() == ""          # incomplete second line
    b.put("ed in\r\n")
    check b.getLine() == "230 Logged in"

  test "partial get clamps":
    var b: Buffer
    b.put("hi")
    check b.getString(100) == "hi"

  test "eof and error flags":
    var b: Buffer
    b.setEof()
    b.setError("reset by peer")
    check b.eof
    check b.hasError

suite "chronos smoke":
  test "async runtime runs":
    proc compute() {.async.} =
      await sleepAsync(1.milliseconds)
    var ran = false
    proc top() {.async.} =
      await compute()
      ran = true
    waitFor top()
    check ran
