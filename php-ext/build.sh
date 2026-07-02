#!/usr/bin/env bash
# Build a Nim source file into a C-ABI shared library PHP FFI can load.
#
#   ./build.sh src/demo.nim demo      -> build/libdemo.{dylib,so}
#   ./build.sh                        -> defaults to the demo above
#
# Reuse for nlftp later:  ./build.sh src/nlftp_ffi.nim nlftp
set -euo pipefail

cd "$(dirname "$0")"
SRC="${1:-src/demo.nim}"
NAME="${2:-demo}"

# macOS dynamic libs are .dylib; Linux/BSD use .so. PHP FFI loads whichever
# the host produces, so we just match the platform.
case "$(uname -s)" in
  Darwin) EXT="dylib" ;;
  *)      EXT="so" ;;
esac

OUT="build/lib${NAME}.${EXT}"
mkdir -p build

# --app:lib        : emit a shared library (and a callable NimMain)
# --mm:orc         : ORC memory management (single-threaded, deterministic)
# -d:release       : optimized, no debug checks
# --noMain:on      : we drive init via NimMain ourselves, no C main()
# --tlsEmulation:off: real thread-local storage (avoids macOS dylib TLS issues)
nim c \
  --app:lib \
  --mm:orc \
  -d:release \
  --noMain:on \
  --tlsEmulation:off \
  --out:"${OUT}" \
  "${SRC}"

echo "built ${OUT}"
