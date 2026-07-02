## Command-line tokenizer — port of lftp's `parsecmd.cc` (the lexer half).
##
## Splits an interactive command line into words, honoring single quotes
## (literal), double quotes (allow backslash escapes), backslash escaping, `#`
## comments, and `;` / newline command separators. This is lftp-specific lexing
## (bash-compatible-ish), so it's hand-rolled (DECISIONS §P1 rung 5).

import std/strutils

type
  ParsedCommand* = object
    words*: seq[string]

proc tokenizeOne(s: string; i: var int): seq[string] =
  ## Tokenize up to the next unquoted `;` or newline; advances `i` past it.
  var words: seq[string]
  var cur = ""
  var haveWord = false
  while i < s.len:
    let c = s[i]
    case c
    of ' ', '\t':
      if haveWord:
        words.add cur
        cur = ""
        haveWord = false
      inc i
    of ';', '\n', '\r':
      inc i           # consume separator
      break
    of '#':
      if not haveWord and cur.len == 0:
        # comment to end of line
        while i < s.len and s[i] != '\n': inc i
      else:
        cur.add c; haveWord = true; inc i
    of '\'':
      haveWord = true; inc i
      while i < s.len and s[i] != '\'':
        cur.add s[i]; inc i
      if i < s.len: inc i   # closing quote
    of '"':
      haveWord = true; inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and i + 1 < s.len and s[i+1] in {'"', '\\', '$', '`'}:
          cur.add s[i+1]; inc i, 2
        else:
          cur.add s[i]; inc i
      if i < s.len: inc i
    of '\\':
      haveWord = true
      if i + 1 < s.len:
        cur.add s[i+1]; inc i, 2
      else:
        inc i
    else:
      cur.add c; haveWord = true; inc i
  if haveWord: words.add cur
  return words

proc parseCommands*(line: string): seq[ParsedCommand] =
  ## Split a line into one or more commands (separated by `;`).
  var i = 0
  while i < line.len:
    let words = tokenizeOne(line, i)
    if words.len > 0:
      result.add ParsedCommand(words: words)

proc tokenize*(line: string): seq[string] =
  ## Convenience: the words of the first command on the line.
  let cmds = parseCommands(line)
  if cmds.len > 0: cmds[0].words else: @[]
