## stb_image / stb_image_write bindings.
##
## Compiled in only when the build defines `v3eraStb`; `io.nim` queries
## `stbAvailable` at compile time and falls back to the native codecs plus the
## external-converter escape hatch otherwise. Run `scripts/fetch_vendor.sh`
## (or `nimble vendor`) to place the headers before enabling it.
##
## Everything goes through the wrappers in `csrc/v3era_stb.c` so no callback or
## thread-local handling leaks into Nim.

import ../core/[types, errors]

const stbAvailable* = defined(v3eraStb)

when stbAvailable:
  {.compile: "../../../csrc/v3era_stb.c".}

  proc v3eStbDecode(buf: ptr byte; len: cint; w, h, ch: ptr cint;
                    desired: cint; err: ptr cstring): ptr UncheckedArray[byte]
    {.importc: "v3e_stb_decode", cdecl.}
  proc v3eStbFree(p: pointer) {.importc: "v3e_stb_free", cdecl.}
  proc v3eStbInfo(buf: ptr byte; len: cint; w, h, ch: ptr cint): cint
    {.importc: "v3e_stb_info", cdecl.}
  proc v3eStbEncodePng(px: ptr byte; w, h, ch: cint;
                       outBuf: ptr ptr UncheckedArray[byte];
                       outLen: ptr cint): cint
    {.importc: "v3e_stb_encode_png", cdecl.}
  proc v3eStbEncodeJpg(px: ptr byte; w, h, ch, quality: cint;
                       outBuf: ptr ptr UncheckedArray[byte];
                       outLen: ptr cint): cint
    {.importc: "v3e_stb_encode_jpg", cdecl.}
  proc v3eStbEncodeFree(p: pointer) {.importc: "v3e_stb_encode_free", cdecl.}

  ## Refuse anything that would allocate more than this once decoded. A 40 MP
  ## RGBA image is 160 MB; a malicious header claiming 60000x60000 is a trivial
  ## OOM otherwise, and `stbi_info` lets us reject it before the allocation.
  const maxPixels = 40_000_000

  proc stbProbe*(data: openArray[byte]): tuple[width, height, channels: int] =
    ## Reads dimensions without decoding the raster.
    if data.len == 0:
      raiseUnsupported("empty image buffer")
    var w, h, ch: cint
    let ok = v3eStbInfo(cast[ptr byte](unsafeAddr data[0]), cint(data.len),
                        addr w, addr h, addr ch)
    if ok == 0:
      raiseUnsupported("stb_image cannot identify this container")
    (int(w), int(h), int(ch))

  proc stbDecode*(data: openArray[byte]; desiredChannels = 0): Image =
    ## Decodes PNG, JPEG, BMP, GIF, TGA or PNM into an `Image`.
    if data.len == 0:
      raiseUnsupported("empty image buffer")

    let (pw, ph, _) = stbProbe(data)
    if pw.int64 * ph.int64 > maxPixels:
      raiseImage("image exceeds the " & $(maxPixels div 1_000_000) &
        " MP decode limit: " & $pw & "x" & $ph)

    var w, h, ch: cint
    var err: cstring = nil
    let px = v3eStbDecode(cast[ptr byte](unsafeAddr data[0]), cint(data.len),
                          addr w, addr h, addr ch, cint(desiredChannels),
                          addr err)
    if px == nil:
      raiseUnsupported("stb_image decode failed: " &
        (if err == nil: "unknown reason" else: $err))
    defer: v3eStbFree(px)

    if w <= 0 or h <= 0 or ch < 1 or ch > 4:
      raiseImage("stb_image returned invalid geometry")
    let n = int(w) * int(h) * int(ch)
    var buf = newSeq[byte](n)
    copyMem(addr buf[0], px, n)
    result = initImage(int(w), int(h), int(ch), move(buf))

  proc stbEncodePng*(img: Image): string =
    if img.isEmpty:
      raiseImage("cannot encode an empty image")
    var outBuf: ptr UncheckedArray[byte]
    var outLen: cint
    let ok = v3eStbEncodePng(cast[ptr byte](unsafeAddr img.data[0]),
                             cint(img.width), cint(img.height),
                             cint(img.channels), addr outBuf, addr outLen)
    if ok == 0:
      raiseImage("stb_image_write failed to encode PNG")
    defer: v3eStbEncodeFree(outBuf)
    result = newString(int(outLen))
    if outLen > 0:
      copyMem(addr result[0], outBuf, int(outLen))

  proc stbEncodeJpeg*(img: Image; quality = 88): string =
    if img.isEmpty:
      raiseImage("cannot encode an empty image")
    # stb's JPEG writer handles 1 and 3 channels; 2 and 4 must be reduced first.
    if img.channels notin {1, 3}:
      raiseImage("JPEG encoding requires 1 or 3 channels, got " & $img.channels)
    var outBuf: ptr UncheckedArray[byte]
    var outLen: cint
    let ok = v3eStbEncodeJpg(cast[ptr byte](unsafeAddr img.data[0]),
                             cint(img.width), cint(img.height),
                             cint(img.channels), cint(quality),
                             addr outBuf, addr outLen)
    if ok == 0:
      raiseImage("stb_image_write failed to encode JPEG")
    defer: v3eStbEncodeFree(outBuf)
    result = newString(int(outLen))
    if outLen > 0:
      copyMem(addr result[0], outBuf, int(outLen))

else:
  # Stubs so callers compile either way; `io.nim` never reaches these because
  # it branches on `stbAvailable` at compile time.
  proc stbProbe*(data: openArray[byte]): tuple[width, height, channels: int] =
    raise newCapabilityError("stb_image",
      "built without stb_image; rebuild with -d:v3eraStb after running " &
      "scripts/fetch_vendor.sh")

  proc stbDecode*(data: openArray[byte]; desiredChannels = 0): Image =
    raise newCapabilityError("stb_image",
      "built without stb_image; rebuild with -d:v3eraStb after running " &
      "scripts/fetch_vendor.sh")

  proc stbEncodePng*(img: Image): string =
    raise newCapabilityError("stb_image", "built without stb_image_write")

  proc stbEncodeJpeg*(img: Image; quality = 88): string =
    raise newCapabilityError("stb_image", "built without stb_image_write")
