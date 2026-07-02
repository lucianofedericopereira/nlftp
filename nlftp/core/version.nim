## Version metadata for nlftp.

const
  NlftpVersion* = "0.0.1"
    ## nlftp's own version.
  LftpBaseVersion* = "4.9.3"
    ## The upstream lftp release this port tracks.

proc nlftpVersionString*(): string =
  "nlftp " & NlftpVersion & " (port of lftp " & LftpBaseVersion & ")"
