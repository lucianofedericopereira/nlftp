## Seed settings — a starter subset of lftp's ~199 `resource.cc` entries.
##
## We register settings incrementally as each subsystem is ported. This module
## holds the cross-cutting / net / ftp basics needed by early phases. The full
## table is filled in as Phases 2+ land.

import settings
import config

proc registerDefaults*(rm: ResMgr) =
  # --- net: ---
  rm.register("net:timeout", $DefaultTimeoutSec, validateTimeInterval)
  rm.register("net:connect-timeout", $ConnectTimeoutSec, validateTimeInterval)
  rm.register("net:connection-limit", "0", validateUNumber)
  rm.register("net:connection-takeover", "yes", validateBool)
  rm.register("net:max-retries", "0", validateUNumber)
  rm.register("net:reconnect-interval-base", "30", validateTimeInterval)
  rm.register("net:reconnect-interval-multiplier", "1.5", validateFloat)
  rm.register("net:socket-buffer", "0", validateUNumber)
  rm.register("net:limit-rate", "0", validateUNumber)         # per-transfer B/s
  rm.register("net:limit-total-rate", "0", validateUNumber)   # global B/s
  rm.register("net:idle", "0", validateTimeInterval)
  rm.register("net:persist-retries", "0", validateUNumber)
  rm.register("net:reconnect-interval-max", "600", validateTimeInterval)

  # --- ftp: ---
  rm.register("ftp:passive-mode", "yes", validateBool)
  rm.register("ftp:use-mlsd", "yes", validateBool)
  rm.register("ftp:use-feat", "yes", validateBool)
  rm.register("ftp:ssl-allow", "yes", validateBool)
  rm.register("ftp:ssl-protect-data", "no", validateBool)
  rm.register("ftp:ssl-protect-list", "yes", validateBool)
  rm.register("ftp:ssl-force", "no", validateBool)
  rm.register("ftp:sync-mode", "auto", validateTriBool)
  rm.register("ftp:port-range", "full", nil)
  rm.register("ftp:prefer-epsv", "yes", validateBool)
  rm.register("ftp:list-options", "", nil)
  rm.register("ftp:proxy", "", nil)
  rm.register("ftp:home", "", nil)
  rm.register("ftp:use-stat", "yes", validateBool)

  # --- http: ---
  rm.register("http:use-propfind", "no", validateBool)
  rm.register("http:cache", "yes", validateBool)
  rm.register("http:proxy", "", nil)
  rm.register("http:user-agent", UserAgent, nil)
  rm.register("http:cookie", "", nil)
  rm.register("http:put-method", "PUT", nil)

  # --- sftp: ---
  rm.register("sftp:max-packets-in-flight", $SftpMaxPacketsInFlight, validateUNumber)
  rm.register("sftp:size-read", "0x8000", nil)
  rm.register("sftp:size-write", "0x8000", nil)
  rm.register("sftp:connect-program", "ssh -a -x", nil)
  rm.register("sftp:protocol-version", "3", validateUNumber)
  rm.register("sftp:charset", "", nil)

  # --- dns: ---
  rm.register("dns:order", "inet inet6", nil)
  rm.register("dns:cache-enable", "yes", validateBool)
  rm.register("dns:SRV-query", "no", validateBool)
  rm.register("dns:fatal-timeout", "0", validateTimeInterval)

  # --- mirror: ---
  rm.register("mirror:parallel-transfer-count", "1", validateUNumber)
  rm.register("mirror:use-pget-n", "1", validateUNumber)
  rm.register("mirror:set-permissions", "yes", validateBool)
  rm.register("mirror:exclude-regex", "", nil)
  rm.register("mirror:include-regex", "", nil)
  rm.register("mirror:no-empty-dirs", "no", validateBool)
  rm.register("mirror:dereference", "no", validateBool)

  # --- xfer: ---
  rm.register("xfer:clobber", "yes", validateBool)
  rm.register("xfer:make-backup", "yes", validateBool)
  rm.register("xfer:disk-full-fatal", "no", validateBool)
  rm.register("xfer:auto-rename", "no", validateBool)
  rm.register("xfer:use-temp-file", "no", validateBool)
  rm.register("xfer:verify", "no", validateBool)

  # --- ssl: ---
  rm.register("ssl:verify-certificate", "yes", validateBool)
  rm.register("ssl:ca-file", "", nil)
  rm.register("ssl:ca-path", "", nil)
  rm.register("ssl:check-hostname", "yes", validateBool)
  rm.register("ssl:cert-file", "", nil)
  rm.register("ssl:key-file", "", nil)
  rm.register("ssl:crl-file", "", nil)

  # --- cmd: (script-relevant only; interactive/readline settings are out of
  #           scope since nlftp has no interactive mode) ---
  rm.register("cmd:fail-exit", "no", validateBool)      # stop script on error
  rm.register("cmd:verbose", "no", validateBool)
  rm.register("cmd:default-protocol", "ftp", nil)       # proto for bare hosts
  rm.register("cmd:queue-parallel", "1", validateUNumber) # concurrent queued jobs
