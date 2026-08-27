## Pure-Nim Netpbm (PGM/PPM/PBM) and uncompressed-BMP codecs.
##
## These have no external dependencies, so the library always has *some* way to
## read and write pixels: the test suite, the debug dumps produced by
## `--dump-stage`, and the PNM handoff to external converters all work in a
## build with no vendored C at all. Everything else (PNG, JPEG, ...) goes
## through stb_image; see `stbimage.nim`.

import std/[strutils, parseutils]

import ../core/[types, errors]

# ---------------------------------------------------------------------------
# Netpbm
# ---------------------------------------------------------------------------

type PnmHeader = object
  magic: int      ## 1..6
  width, height: int
  maxVal: int
  dataOffset: int

proc skipWhitespaceAndComments(data: openArray[byte]; pos: var int) =
  while pos < data.len:
    let c = char(data[pos])
    if c == '#':
      while pos < data.len and char(data[pos]) notin {'\n', '\r'}:
        inc pos
    elif c in {' ', '\t', '\n', '\r', '\v', '\f'}:
      inc pos
    else:
      break

proc readIntToken(data: openArray[byte]; pos: var int; what: string): int =
  skipWhitespaceAndComments(data, pos)
  let start = pos
  while pos < data.len and char(data[pos]) in Digits:
    inc pos
  if pos == start:
    raiseUnsupported("malformed PNM header: expected " & what)
  var s = newString(pos - start)
  for i in 0 ..< pos - start:
    s[i] = char(data[start + i])
  if parseInt(s, result) != s.len:
    raiseUnsupported("malformed PNM header: bad " & what)

proc parsePnmHeader(data: openArray[byte]): PnmHeader =
  if data.len < 2 or char(data[0]) != 'P':
    raiseUnsupported("not a PNM stream")
  let m = int(data[1]) - int('0')
  if m < 1 or m > 6:
    raiseUnsupported("unsupported PNM variant P" & $m &
      " (P7/PAM is not implemented)")
  result.magic = m
  var pos = 2
  result.width = readIntToken(data, pos, "width")
  result.height = readIntToken(data, pos, "height")
  if m == 1 or m == 4:
    result.maxVal = 1
  else:
    result.maxVal = readIntToken(data, pos, "maxval")
    if result.maxVal < 1 or result.maxVal > 65535:
      raiseUnsupported("PNM maxval out of range: " & $result.maxVal)
  # Exactly one whitespace byte separates a binary header from its raster.
  if m >= 4:
    if pos < data.len and char(data[pos]) in {' ', '\t', '\n', '\r'}:
      inc pos
  result.dataOffset = pos

proc decodePnm*(data: openArray[byte]): Image =
  ## Decodes P1..P6. 16-bit samples are downshifted to 8 bits.
  let h = parsePnmHeader(data)
  let channels = if h.magic in {3, 6}: 3 else: 1
  result = newImage(h.width, h.height,
                    if channels == 3: pkRgb else: pkGray)
  let npix = h.width * h.height
  let scale16 = h.maxVal > 255

  case h.magic
  of 4: # Binary bitmap: 1 bit per pixel, rows padded to whole bytes, 1 = black.
    let rowBytes = (h.width + 7) div 8
    if data.len - h.dataOffset < rowBytes * h.height:
      raiseUnsupported("truncated P4 raster")
    for y in 0 ..< h.height:
      let rowStart = h.dataOffset + y * rowBytes
      for x in 0 ..< h.width:
        let bit = (int(data[rowStart + (x shr 3)]) shr (7 - (x and 7))) and 1
        result.data[y * h.width + x] = if bit == 1: 0'u8 else: 255'u8
  of 5, 6: # Binary gray / RGB.
    let sampleBytes = if scale16: 2 else: 1
    let need = npix * channels * sampleBytes
    if data.len - h.dataOffset < need:
      raiseUnsupported("truncated P" & $h.magic & " raster: need " & $need &
        " bytes, have " & $(data.len - h.dataOffset))
    if scale16:
      for i in 0 ..< npix * channels:
        let o = h.dataOffset + i * 2
        let v = (int(data[o]) shl 8) or int(data[o + 1])
        result.data[i] = byte(v * 255 div h.maxVal)
    elif h.maxVal == 255:
      for i in 0 ..< npix * channels:
        result.data[i] = data[h.dataOffset + i]
    else:
      for i in 0 ..< npix * channels:
        result.data[i] = byte(int(data[h.dataOffset + i]) * 255 div h.maxVal)
  of 1, 2, 3: # ASCII variants.
    var pos = h.dataOffset
    let total = npix * channels
    for i in 0 ..< total:
      let v = readIntToken(data, pos, "sample")
      result.data[i] =
        if h.magic == 1: (if v == 1: 0'u8 else: 255'u8)
        else: byte(clamp(v * 255 div h.maxVal, 0, 255))
  else:
    raiseUnsupported("unsupported PNM variant")

proc encodePnm*(img: Image): string =
  ## Writes P5 (gray) or P6 (RGB). Alpha is dropped: PNM has no alpha, and
  ## silently compositing onto an assumed background would corrupt the pixels
  ## a caller is trying to inspect.
  if img.isEmpty:
    raiseImage("cannot encode an empty image")
  let rgb = img.channels >= 3
  let magic = if rgb: "P6" else: "P5"
  result = magic & "\n" & $img.width & " " & $img.height & "\n255\n"
  let outCh = if rgb: 3 else: 1
  let base = result.len
  result.setLen(base + img.width * img.height * outCh)
  if img.channels == outCh:
    for i in 0 ..< img.data.len:
      result[base + i] = char(img.data[i])
  else:
    var o = base
    for i in 0 ..< img.width * img.height:
      let p = i * img.channels
      for c in 0 ..< outCh:
        result[o] = char(img.data[p + c])
        inc o

# ---------------------------------------------------------------------------
# BMP (uncompressed 8/24/32-bit)
# ---------------------------------------------------------------------------

func rd16(d: openArray[byte]; o: int): int =
  int(d[o]) or (int(d[o + 1]) shl 8)

func rd32(d: openArray[byte]; o: int): int =
  int(d[o]) or (int(d[o + 1]) shl 8) or (int(d[o + 2]) shl 16) or
    (int(d[o + 3]) shl 24)

proc decodeBmp*(data: openArray[byte]): Image =
  ## Handles the BI_RGB subset: 8-bit palettised, 24-bit BGR and 32-bit BGRA.
  ## Compressed variants raise `UnsupportedFormatError`.
  if data.len < 54 or char(data[0]) != 'B' or char(data[1]) != 'M':
    raiseUnsupported("not a BMP stream")
  let
    pixelOffset = rd32(data, 10)
    dibSize = rd32(data, 14)
    width = rd32(data, 18)
    rawHeight = rd32(data, 22)
    bpp = rd16(data, 28)
    compression = rd32(data, 30)
  if dibSize < 40:
    raiseUnsupported("BMP core headers (dibSize=" & $dibSize & ") not supported")
  if compression != 0:
    raiseUnsupported("compressed BMP (compression=" & $compression &
      ") not supported")
  if bpp notin {8, 24, 32}:
    raiseUnsupported("BMP bit depth " & $bpp & " not supported")

  # A negative height means the raster is stored top-down.
  let topDown = rawHeight < 0
  let height = abs(rawHeight)
  if width <= 0 or height <= 0:
    raiseUnsupported("invalid BMP dimensions")

  let srcCh = bpp div 8
  let rowSize = ((width * bpp + 31) div 32) * 4 # rows are 4-byte aligned
  if pixelOffset < 0 or pixelOffset + rowSize * height > data.len:
    raiseUnsupported("truncated BMP raster")

  var palette: seq[array[3, byte]]
  if bpp == 8:
    let paletteOffset = 14 + dibSize
    var colours = rd32(data, 46)
    if colours <= 0 or colours > 256: colours = 256
    if paletteOffset + colours * 4 > data.len:
      raiseUnsupported("truncated BMP palette")
    palette.setLen(colours)
    for i in 0 ..< colours:
      let o = paletteOffset + i * 4
      palette[i] = [data[o + 2], data[o + 1], data[o]] # stored BGRA
    result = newImage(width, height, pkRgb)
  else:
    result = newImage(width, height, if bpp == 32: pkRgba else: pkRgb)

  let dstCh = result.channels
  for y in 0 ..< height:
    let srcY = if topDown: y else: height - 1 - y
    let rowStart = pixelOffset + srcY * rowSize
    var dst = y * width * dstCh
    for x in 0 ..< width:
      let o = rowStart + x * srcCh
      if bpp == 8:
        let pi = int(data[o])
        let c = if pi < palette.len: palette[pi] else: [0'u8, 0, 0]
        result.data[dst] = c[0]
        result.data[dst + 1] = c[1]
        result.data[dst + 2] = c[2]
      else:
        result.data[dst] = data[o + 2] # B G R -> R G B
        result.data[dst + 1] = data[o + 1]
        result.data[dst + 2] = data[o]
        if dstCh == 4:
          result.data[dst + 3] = data[o + 3]
      dst += dstCh

proc encodeBmp*(img: Image): string =
  ## Writes a 24-bit BI_RGB bottom-up BMP. Useful because every OS previewer
  ## opens it without a codec.
  if img.isEmpty:
    raiseImage("cannot encode an empty image")
  let
    rowSize = ((img.width * 24 + 31) div 32) * 4
    pixelBytes = rowSize * img.height
    fileSize = 54 + pixelBytes
  # Built in a local rather than directly in `result`: Nim forbids closures
  # over `result`, and the little-endian header writers below are closures.
  var buf = newString(fileSize)

  proc put32(o, v: int) =
    buf[o] = char(v and 0xFF)
    buf[o + 1] = char((v shr 8) and 0xFF)
    buf[o + 2] = char((v shr 16) and 0xFF)
    buf[o + 3] = char((v shr 24) and 0xFF)

  proc put16(o, v: int) =
    buf[o] = char(v and 0xFF)
    buf[o + 1] = char((v shr 8) and 0xFF)

  buf[0] = 'B'
  buf[1] = 'M'
  put32(2, fileSize)
  put32(10, 54)
  put32(14, 40)
  put32(18, img.width)
  put32(22, img.height)
  put16(26, 1)
  put16(28, 24)
  put32(34, pixelBytes)
  put32(38, 2835) # 72 DPI in pixels/metre
  put32(42, 2835)

  for y in 0 ..< img.height:
    let srcY = img.height - 1 - y
    var o = 54 + y * rowSize
    for x in 0 ..< img.width:
      let p = img.idx(x, srcY)
      var r, g, b: byte
      if img.channels >= 3:
        r = img.data[p]
        g = img.data[p + 1]
        b = img.data[p + 2]
      else:
        r = img.data[p]
        g = r
        b = r
      buf[o] = char(b)
      buf[o + 1] = char(g)
      buf[o + 2] = char(r)
      o += 3
  move(buf)
