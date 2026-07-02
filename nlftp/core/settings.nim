## Settings registry — port of lftp's `ResMgr` / `ResType` / `Resource`
## (src/ResMgr.h, ResMgr.cc, resource.cc).
##
## lftp models every tunable as a *resource*: a typed, validated name with a
## default, plus zero or more *closure*-scoped overrides. A "closure" is a
## context key — typically a hostname or `proto/host` — so a user can write
##
##     set ftp:passive-mode/ftp.example.com no
##
## and have it apply only to that host. `query(name, closure)` returns the most
## specific matching value, falling back to the default.
##
## Names may be queried by unambiguous abbreviation (e.g. `pget:def` →
## `pget:default-n`), mirroring lftp's prefix/substring matching.

import std/[tables, strutils, options, sequtils]

type
  ValidateProc* = proc(value: string): Option[string] {.nimcall, raises: [], gcsafe.}
    ## Returns `some(msg)` if `value` is invalid (msg = reason), else `none`.

  ResType* = object
    ## Definition of one setting.
    name*: string            ## canonical "section:key" name
    defValue*: string        ## default value (as text)
    valValidate*: ValidateProc   ## validates the value (may be nil)
    closureValidate*: ValidateProc ## validates a closure key (may be nil)

  Resource = object
    ## A concrete set value for some closure.
    closure: string          ## "" = global (applies to all contexts)
    value: string

  SettingsError* = object of CatchableError

  ResMgr* = ref object
    ## The registry: definitions + current values.
    types: OrderedTable[string, ResType]
    values: Table[string, seq[Resource]]   ## name -> overrides (closure-keyed)

# ---------------------------------------------------------------------------
# Validators (port of ResMgr::*Validate)
# ---------------------------------------------------------------------------

proc validateBool*(value: string): Option[string] {.nimcall.} =
  ## yes/no/true/false/on/off/1/0.
  const ok = ["yes","no","true","false","on","off","1","0","y","n"]
  if value.toLowerAscii in ok: none(string)
  else: some("expected a boolean (yes/no)")

proc validateTriBool*(value: string): Option[string] {.nimcall.} =
  const ok = ["yes","no","true","false","on","off","1","0","y","n","auto",""]
  if value.toLowerAscii in ok: none(string)
  else: some("expected yes/no/auto")

proc validateNumber*(value: string): Option[string] {.nimcall.} =
  try:
    discard parseInt(value); none(string)
  except ValueError:
    some("expected an integer")

proc validateUNumber*(value: string): Option[string] {.nimcall.} =
  try:
    if parseInt(value) < 0: some("expected a non-negative integer")
    else: none(string)
  except ValueError:
    some("expected a non-negative integer")

proc validateFloat*(value: string): Option[string] {.nimcall.} =
  try:
    discard parseFloat(value); none(string)
  except ValueError:
    some("expected a number")

proc parseBool*(value: string): bool =
  ## Interpret a validated boolean setting value.
  value.toLowerAscii in ["yes","true","on","1","y"]

# ---------------------------------------------------------------------------
# Time-interval validator (e.g. "30", "1m30s", "2h", "infinity")
# ---------------------------------------------------------------------------

proc validateTimeInterval*(value: string): Option[string] {.nimcall.} =
  let v = value.toLowerAscii
  if v in ["inf","infinity","forever","never"]: return none(string)
  var i = 0
  var sawDigit = false
  while i < v.len:
    if v[i] in {'0'..'9','.'}:
      sawDigit = true
      inc i
    elif v[i] in {'d','h','m','s'}:
      inc i
    else:
      return some("expected a time interval (e.g. 30, 1m30s, 2h)")
  if sawDigit: none(string) else: some("expected a time interval")

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

proc newResMgr*(): ResMgr =
  ResMgr(types: initOrderedTable[string, ResType](),
         values: initTable[string, seq[Resource]]())

proc register*(rm: ResMgr; name, defValue: string;
               valValidate: ValidateProc = nil;
               closureValidate: ValidateProc = nil) =
  ## Define a setting. Called at startup to seed the table (resource.cc).
  rm.types[name] = ResType(name: name, defValue: defValue,
                           valValidate: valValidate,
                           closureValidate: closureValidate)

# --- name abbreviation matching (port of ResType::VarNameCmp/FindVar) -------

proc splitName(name: string): tuple[base, closure: string] =
  ## "ftp:passive-mode/host" -> ("ftp:passive-mode", "host").
  let slash = name.find('/')
  if slash < 0: (name, "")
  else: (name[0 ..< slash], name[slash+1 .. ^1])

proc resolveName*(rm: ResMgr; name: string): string =
  ## Resolve an exact or unambiguously-abbreviated setting name to its
  ## canonical form. Raises SettingsError on unknown/ambiguous names.
  if name in rm.types: return name
  # Abbreviation: match on prefix of the whole name, or prefix of the key
  # after the section colon.
  var matches: seq[string]
  for k in rm.types.keys:
    if k.startsWith(name):
      matches.add(k)
  if matches.len == 0:
    # try substring on the key part (after ':')
    for k in rm.types.keys:
      let colon = k.find(':')
      let keyPart = if colon >= 0: k[colon+1 .. ^1] else: k
      if keyPart.startsWith(name) or name in k:
        matches.add(k)
  case matches.len
  of 0: raise newException(SettingsError, "unknown setting: " & name)
  of 1: matches[0]
  else:
    raise newException(SettingsError,
      "ambiguous setting '" & name & "', matches: " & matches.join(", "))

# --- set / query ------------------------------------------------------------

proc set*(rm: ResMgr; name, value: string) =
  ## Set a setting, honoring an optional `/closure` suffix and abbreviation.
  ## Setting an empty value removes the override (reverts to default), like lftp.
  let (rawBase, closure) = splitName(name)
  let base = rm.resolveName(rawBase)
  let rt = rm.types[base]
  if rt.valValidate != nil and value.len > 0:
    let err = rt.valValidate(value)
    if err.isSome:
      raise newException(SettingsError,
        "invalid value for " & base & ": " & err.get)
  if rt.closureValidate != nil and closure.len > 0:
    let err = rt.closureValidate(closure)
    if err.isSome:
      raise newException(SettingsError,
        "invalid closure for " & base & ": " & err.get)

  var lst = rm.values.getOrDefault(base)
  # remove any existing entry for this closure
  lst.keepItIf(it.closure != closure)
  if value.len > 0:
    lst.add(Resource(closure: closure, value: value))
  rm.values[base] = lst

proc query*(rm: ResMgr; name: string; closure = ""): string =
  ## Return the effective value of `name` for `closure`: the most specific
  ## matching override, else the global override, else the default.
  let base = rm.resolveName(name)
  let lst = rm.values.getOrDefault(base)
  # exact closure match wins
  if closure.len > 0:
    for r in lst:
      if r.closure == closure:
        return r.value
    # suffix match (closure "ftp.example.com" matches override "example.com")
    for r in lst:
      if r.closure.len > 0 and closure.endsWith(r.closure):
        return r.value
  # global override
  for r in lst:
    if r.closure.len == 0:
      return r.value
  # default
  rm.types[base].defValue

proc queryBool*(rm: ResMgr; name: string; closure = ""): bool =
  parseBool(rm.query(name, closure))

proc queryInt*(rm: ResMgr; name: string; closure = ""): int =
  parseInt(rm.query(name, closure).strip())

proc isRegistered*(rm: ResMgr; name: string): bool =
  name in rm.types

iterator allNames*(rm: ResMgr): string =
  for k in rm.types.keys: yield k
