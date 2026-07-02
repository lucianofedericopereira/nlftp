## nlftp — a modern, pure-Nim, POSIX-only port of lftp.
##
## Script-only entry point (DECISIONS: no interactive mode). nlftp runs:
##   nlftp script.nlftp        — run a script file
##   nlftp -f script.nlftp     — same, explicit
##   nlftp -c "cmd; cmd; ..."  — inline commands
##   cmd | nlftp               — commands from stdin
## A `#!/usr/bin/env nlftp` shebang works (lines starting with `#` are comments),
## so `.nlftp` files can be made executable.

import std/[os, strutils, terminal]
import chronos
import core/version
import shell/cmdexec

proc usage() =
  echo """nlftp """ & NlftpVersion & """ — pure-Nim lftp port (script-only)

Usage:
  nlftp <script.nlftp>     run commands from a script file
  nlftp -f <script>        run a script file (explicit)
  nlftp -c "<commands>"    run inline ';'-separated commands
  some-cmd | nlftp         run commands from stdin
  nlftp -v | --version
  nlftp -h | --help

Scripts are command lines (one per line; '#' comments; ';' separates commands).
Example script:
    open ftp://ftp.gnu.org
    cd /gnu/hello
    lcd ./downloads
    mirror . hello
    exit

Auto-loads ~/.nlftprc (aliases/settings/bookmarks) before running.
Credentials fall back to ~/.netrc when `-u` is not given.

Commands: ls cd pwd lcd lls lpwd get [-c] pget [-n N] put mget mput mirror cat
          mkdir rm rmdir mv chmod open close set alias bookmark source
          echo !cmd exit"""

proc runLines(x: CmdExec; lines: seq[string]) =
  for line in lines:
    if x.quitFlag: break
    let t = line.strip()
    if t.len == 0: continue
    waitFor x.execLine(line)

proc main() =
  # When invoked by ssh as SSH_ASKPASS (for sftp password auth), just print the
  # password from the env and exit — no PTY needed (OpenSSH >= 8.4).
  if existsEnv("NLFTP_ASKPASS"):
    echo getEnv("NLFTP_SFTP_PW")
    quit(0)

  var
    runCmds = ""
    scriptFile = ""
    argv = commandLineParams()
    i = 0
  while i < argv.len:
    let a = argv[i]
    case a
    of "-v", "--version": echo nlftpVersionString(); return
    of "-h", "--help": usage(); return
    of "-c": runCmds = argv[i+1 .. ^1].join("\n"); break
    of "-f":
      if i+1 < argv.len: scriptFile = argv[i+1]; inc i
    else:
      if a.startsWith("-"):
        stderr.writeLine("unknown option: " & a); quit(2)
      if scriptFile.len == 0: scriptFile = a   # first bare arg = script file
    inc i

  let x = newCmdExec()

  # auto-load ~/.nlftprc (aliases, settings, bookmarks) before anything else
  let rc = getHomeDir() / ".nlftprc"
  if fileExists(rc):
    runLines(x, readFile(rc).splitLines())

  if runCmds.len > 0:
    runLines(x, runCmds.splitLines())
  elif scriptFile.len > 0:
    if not fileExists(scriptFile):
      stderr.writeLine("nlftp: script not found: " & scriptFile); quit(1)
    runLines(x, readFile(scriptFile).splitLines())
  elif not stdin.isatty():
    runLines(x, stdin.readAll().splitLines())
  else:
    usage()
    quit(1)

  waitFor waitAllJobs(x)   # let background `queue`d jobs finish before exit
  quit(x.exitCode)         # non-zero if cmd:fail-exit aborted on an error

when isMainModule:
  main()
