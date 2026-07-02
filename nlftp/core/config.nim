## nlftp compile-time configuration — ALL tunable constants in one place.
##
## Philosophy (DECISIONS): keep the runtime `set` surface small (only the
## settings users actually touch). Everything else is a compile-time constant
## here: to change a default, edit this file and recompile. Advanced users build
## their own binary; ordinary users are not burdened with hundreds of knobs.
##
## Grouped by area. The runtime settings in `defaults.nim` source their defaults
## from these where they overlap, so there is a single source of truth.

# --- versioning (informational; real version lives in version.nim) ---------

const
  UserAgent* = "nlftp/0.0.1"        ## HTTP User-Agent / http:user-agent default

# --- I/O ---------------------------------------------------------------------

const
  IoChunkSize* = 65536             ## read/write granularity for transfers
  DefaultTimeoutSec* = 300         ## net:timeout default (per-op stream timeout)
  BodyReadTimeoutSec* = 60         ## cap on reading a *buffered* HTTP body
  ConnectTimeoutSec* = 30          ## per-address TCP connect timeout (fail fast
                                   ## instead of the ~75s OS default on dead hosts)

# --- HTTP --------------------------------------------------------------------

const
  MaxRedirects* = 10               ## redirect-follow limit before giving up

# --- segmented download (pget) ----------------------------------------------

const
  MinSegmentBytes* = 1 shl 20      ## don't split a file below ~2x this size

# --- in-memory buffer budget (sysmem) ---------------------------------------

const
  BufferBudgetFraction* = 4              ## cap one buffered body at RAM/this
  BufferBudgetMin* = 64'i64 * 1024 * 1024      ## floor: 64 MiB
  BufferBudgetMax* = 4'i64 * 1024 * 1024 * 1024 ## ceiling: 4 GiB
  BufferBudgetFallback* = 512'i64 * 1024 * 1024 ## when RAM can't be determined

# --- byte buffer -------------------------------------------------------------

const
  BufferCompactThreshold* = 4096   ## compact a Buffer once this many head bytes
                                   ## have been consumed

# --- SFTP --------------------------------------------------------------------

const
  SftpReadSize* = 0x8000           ## sftp:size-read default
  SftpWriteSize* = 0x8000          ## sftp:size-write default
  SftpMaxPacketsInFlight* = 16     ## sftp:max-packets-in-flight default
  SftpOooCap* = 64                 ## max out-of-order packets before disconnect
