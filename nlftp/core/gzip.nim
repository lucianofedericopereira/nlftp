## gzip/zlib/deflate codec façade — replaces lftp's `buffer_zlib` (DataInflator).
##
## Pragmatic one-shot codec over **zippy** (pure Nim), per DECISIONS §P1: in a
## transfer client, wire-compression is almost always small (HTML/WebDAV
## listings, text), where one-shot is ideal. This façade is the *swappable
## interface* — if large `Content-Encoding: gzip` downloads ever need true
## streaming, swap the body for a nim-lang/zip `ZlibStream` backend without
## touching callers.

import std/strutils
import zippy

type
  CompFormat* = enum
    cfGzip      ## RFC 1952 gzip
    cfZlib      ## RFC 1950 zlib
    cfDeflate   ## RFC 1951 raw deflate

  GzipError* = object of CatchableError

func toZippy(fmt: CompFormat): CompressedDataFormat =
  case fmt
  of cfGzip: dfGzip
  of cfZlib: dfZlib
  of cfDeflate: dfDeflate

proc decompress*(data: string; fmt = cfGzip): string =
  ## Inflate a complete compressed body.
  try:
    uncompress(data, fmt.toZippy)
  except ZippyError as e:
    raise newException(GzipError, "decompress failed: " & e.msg)

proc compress*(data: string; fmt = cfGzip; level = DefaultCompression): string =
  ## Deflate a complete body.
  try:
    zippy.compress(data, level, fmt.toZippy)
  except ZippyError as e:
    raise newException(GzipError, "compress failed: " & e.msg)

proc decodeContentEncoding*(body: string; encoding: string): string =
  ## Decode an HTTP body per its `Content-Encoding` / `Transfer-Encoding` token.
  ## Unknown/empty encodings pass through unchanged.
  case encoding.toLowerAscii
  of "gzip", "x-gzip": decompress(body, cfGzip)
  of "deflate":        decompress(body, cfZlib)   # HTTP "deflate" = zlib-wrapped
  of "", "identity":   body
  else:
    raise newException(GzipError, "unsupported content-encoding: " & encoding)
