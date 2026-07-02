## Error type — port of lftp's `Error` (src/Error.h / Error.cc).
##
## lftp's Error is a small value: text + code + fatal flag. In Nim we expose
## both a plain value type (for stored/returned errors) and an exception type
## (for the places the port prefers raising over status codes).

type
  Error* = object
    ## A protocol/operation error: human-readable text, an optional numeric
    ## code (-1 = none), and whether it is fatal (unrecoverable).
    text*: string
    code*: int
    fatal*: bool

  NlftpError* = object of CatchableError
    ## Exception form, carrying the same payload.
    code*: int
    fatal*: bool

func initError*(text: string; code = -1; fatal = false): Error =
  Error(text: text, code: code, fatal: fatal)

func fatalError*(text: string; code = -1): Error =
  ## Mirrors lftp's `Error::Fatal`.
  Error(text: text, code: code, fatal: true)

func `$`*(e: Error): string =
  result = e.text
  if e.code != -1:
    result.add(" (" & $e.code & ")")

func isFatal*(e: Error): bool {.inline.} = e.fatal

proc raiseError*(text: string; code = -1; fatal = false) {.noreturn.} =
  ## Raise the exception form.
  var e = newException(NlftpError, text)
  e.code = code
  e.fatal = fatal
  raise e
