## Container detection from magic bytes.
##
## File extensions lie, and an HTTP upload often has no name at all, so every
## entry point routes on content. Only the first few dozen bytes are needed.

import std/strutils

import ../core/types

func startsWithBytes(data: openArray[byte]; sig: openArray[byte]): bool =
  if data.len < sig.len: return false
  for i in 0 ..< sig.len:
    if data[i] != sig[i]: return false
  true

func hasAt(data: openArray[byte]; offset: int; s: string): bool =
  if data.len < offset + s.len: return false
  for i in 0 ..< s.len:
    if data[offset + i] != byte(s[i]): return false
  true

func detectFormat*(data: openArray[byte]): SourceFormat =
  ## Identifies the container. Returns `sfUnknown` rather than guessing.
  if data.len < 4: return sfUnknown

  if startsWithBytes(data, [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
    return sfPng
  if startsWithBytes(data, [0xFF'u8, 0xD8, 0xFF]):
    return sfJpeg
  if startsWithBytes(data, [0x25'u8, 0x50, 0x44, 0x46]): # "%PDF"
    return sfPdf
  if startsWithBytes(data, [0x42'u8, 0x4D]): # "BM"
    return sfBmp
  if startsWithBytes(data, [0x47'u8, 0x49, 0x46, 0x38]): # "GIF8"
    return sfGif
  # RIFF....WEBP
  if startsWithBytes(data, [0x52'u8, 0x49, 0x46, 0x46]) and hasAt(data, 8, "WEBP"):
    return sfWebp
  # TIFF, either byte order.
  if startsWithBytes(data, [0x49'u8, 0x49, 0x2A, 0x00]) or
     startsWithBytes(data, [0x4D'u8, 0x4D, 0x00, 0x2A]):
    return sfTiff
  # Netpbm: 'P' followed by 1..7.
  if data[0] == byte('P') and data[1] >= byte('1') and data[1] <= byte('7'):
    return sfPnm
  sfUnknown

func detectFormat*(data: string): SourceFormat =
  detectFormat(toOpenArrayByte(data, 0, data.high))

func isRaster*(f: SourceFormat): bool =
  f notin {sfUnknown, sfPdf}

func formatFromExtension*(path: string): SourceFormat =
  ## Fallback only, for naming output files. Never used to route decoding.
  let ext = path.rsplit('.', maxsplit = 1)
  if ext.len < 2: return sfUnknown
  case ext[1].toLowerAscii()
  of "png": sfPng
  of "jpg", "jpeg", "jpe": sfJpeg
  of "webp": sfWebp
  of "gif": sfGif
  of "bmp", "dib": sfBmp
  of "tif", "tiff": sfTiff
  of "pnm", "pgm", "ppm", "pbm", "pam": sfPnm
  of "pdf": sfPdf
  else: sfUnknown
