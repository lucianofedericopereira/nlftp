## Phase 5 SFTP codec tests — the bug-prone protocol core (packet
## encode/decode), verified deterministically without a live server.

import std/options
import unittest2
import ../nlftp/proto/sftp

suite "sftp codec":
  test "u8/u32/u64 big-endian round-trip":
    var b: SftpBuf
    b.putU8(0xAB)
    b.putU32(0x01020304'u32)
    b.putU64(0x0102030405060708'u64)
    var r = initReader(b.data)
    check r.getU8() == 0xAB
    check r.getU32() == 0x01020304'u32
    check r.getU64() == 0x0102030405060708'u64
    check r.remaining == 0

  test "u32 byte order is network (big-endian)":
    var b: SftpBuf
    b.putU32(258)            # 0x00000102
    check b.data == @[0'u8, 0, 1, 2]

  test "string length-prefix round-trip":
    var b: SftpBuf
    b.putStr("hello.txt")
    b.putStr("")
    var r = initReader(b.data)
    check r.getStr() == "hello.txt"
    check r.getStr() == ""

  test "attrs: size + permissions + mtime":
    # build an ATTRS payload by hand: flags then fields in protocol order
    var b: SftpBuf
    b.putU32(0x01 or 0x04 or 0x08)     # SIZE | PERMISSIONS | ACMODTIME
    b.putU64(123456'u64)               # size
    b.putU32(0o100644'u32)             # permissions (regular file)
    b.putU32(1000)                     # atime
    b.putU32(1700000000'u32)           # mtime
    var r = initReader(b.data)
    let a = r.getAttrs()
    check a.size == some(123456'i64)
    check a.perms == some(0o100644'u32)
    check a.mtime == some(1700000000'i64)

  test "attrs: uid/gid present but ignored":
    var b: SftpBuf
    b.putU32(0x02 or 0x01)             # UIDGID | SIZE
    b.putU64(42'u64)                   # size  (NOTE: UIDGID parsed before/after per flag order)
    # protocol order: SIZE(0x01) then UIDGID(0x02); our reader checks SIZE first
    var r = initReader(b.data)
    # rebuild correctly: flags=SIZE|UIDGID, size, uid, gid
    var b2: SftpBuf
    b2.putU32(0x01 or 0x02)
    b2.putU64(42'u64)
    b2.putU32(1000); b2.putU32(1000)
    var r2 = initReader(b2.data)
    let a = r2.getAttrs()
    check a.size == some(42'i64)
    check a.perms.isNone
