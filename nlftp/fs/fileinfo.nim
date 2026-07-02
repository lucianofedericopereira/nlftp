## Directory-entry model + Unix `ls -l` parser — port of lftp's `FileInfo`
## (src/FileSet.h) and the `parse_ls_line` family used by FTP/Fish/HTTP list
## parsing (src/FileSet.cc, FtpListInfo.cc).

import std/[strutils, times, options]

type
  FileType* = enum
    ftUnknown, ftFile, ftDir, ftSymlink

  FileInfo* = object
    name*: string
    kind*: FileType
    size*: Option[int64]
    mtime*: Option[Time]
    mode*: Option[int]          ## unix permission bits
    user*: string
    group*: string
    symlink*: string            ## target, when kind == ftSymlink

func newFile*(name: string; size = -1'i64): FileInfo =
  result = FileInfo(name: name, kind: ftFile)
  if size >= 0: result.size = some(size)

func newDir*(name: string): FileInfo =
  FileInfo(name: name, kind: ftDir)

func isDir*(fi: FileInfo): bool = fi.kind == ftDir

# --- permission string -> bits ---------------------------------------------

proc parseModeString(s: string): Option[int] =
  ## "rwxr-xr-x" (9 chars) -> octal bits.
  if s.len < 9: return none(int)
  var bits = 0
  const map = "rwxrwxrwx"
  for i in 0 ..< 9:
    bits = bits shl 1
    if s[i] == map[i]: bits = bits or 1
  some(bits)

# --- Unix `ls -l` line parser ----------------------------------------------

const monthNames = ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct",
                    "nov","dec"]

proc parseLsTime(mon, day, yearOrTime: string): Option[Time] =
  let mi = monthNames.find(mon.toLowerAscii)
  if mi < 0: return none(Time)
  var dt: DateTime
  let d = try: parseInt(day) except ValueError: return none(Time)
  if ':' in yearOrTime:
    # "HH:MM" — year is implied (current); approximate with this year.
    let parts = yearOrTime.split(':')
    let nowYear = now().year
    dt = dateTime(nowYear, Month(mi + 1), d,
                  parseInt(parts[0]), parseInt(parts[1]), 0, zone = utc())
  else:
    let y = try: parseInt(yearOrTime) except ValueError: return none(Time)
    dt = dateTime(y, Month(mi + 1), d, 0, 0, 0, zone = utc())
  some(dt.toTime)

proc parseLsLine*(line: string): Option[FileInfo] =
  ## Parse one `ls -l`-style line (the de-facto FTP LIST format). Returns none
  ## for blank lines, "total N" headers, and unrecognizable input.
  let s = line.strip()
  if s.len == 0 or s.startsWith("total "): return none(FileInfo)

  # Need at least: perms links owner group size mon day year/time name
  let f = s.splitWhitespace()
  if f.len < 9: return none(FileInfo)

  let perms = f[0]
  if perms.len < 10: return none(FileInfo)

  var fi: FileInfo
  case perms[0]
  of 'd': fi.kind = ftDir
  of 'l': fi.kind = ftSymlink
  of '-': fi.kind = ftFile
  else:   fi.kind = ftUnknown

  fi.mode = parseModeString(perms[1 ..< 10])
  fi.user = f[2]
  fi.group = f[3]
  let sz = try: some(parseBiggestInt(f[4]).int64) except ValueError: none(int64)
  fi.size = sz
  fi.mtime = parseLsTime(f[5], f[6], f[7])

  # name is everything from field 8 on; handle "name -> target" for symlinks.
  let nameStart = s.find(f[8], 0)
  var name = s[nameStart .. ^1]
  if fi.kind == ftSymlink:
    let arrow = name.find(" -> ")
    if arrow >= 0:
      fi.symlink = name[arrow + 4 .. ^1]
      name = name[0 ..< arrow]
  fi.name = name
  if fi.name in [".", ".."]: return none(FileInfo)
  some(fi)
