## Safe Nim surface over the C kernels in `csrc/v3era_imgops.c`.
##
## Each wrapper validates geometry, allocates the destination and takes the
## address of element 0 only after establishing the buffer is non-empty --
## `unsafeAddr data[0]` on an empty seq is undefined behaviour, and every one of
## these entry points can be reached from network input.

import std/[math, algorithm]

import ../core/[types, errors]

{.compile: "../../../csrc/v3era_imgops.c".}
{.passL: "-lm".}

# ---------------------------------------------------------------------------
# Raw imports
# ---------------------------------------------------------------------------

proc c_toGray(src: ptr byte; w, h, ch: cint; dst: ptr byte)
  {.importc: "v3e_to_gray", cdecl.}
proc c_grayToChannels(src: ptr byte; w, h, ch: cint; dst: ptr byte)
  {.importc: "v3e_gray_to_channels", cdecl.}
proc c_autocontrast(buf: ptr byte; w, h, ch: cint; loPct, hiPct: cdouble)
  {.importc: "v3e_autocontrast", cdecl.}
proc c_integral(gray: ptr byte; w, h: cint; sum, sqsum: ptr uint64)
  {.importc: "v3e_integral", cdecl.}
proc c_otsu(gray: ptr byte; w, h: cint): cint
  {.importc: "v3e_otsu_threshold", cdecl.}
proc c_thresholdApply(gray: ptr byte; w, h, thr, invert: cint; dst: ptr byte)
  {.importc: "v3e_threshold_apply", cdecl.}
proc c_sauvola(gray: ptr byte; w, h, window: cint; k, r: cdouble;
               dst: ptr byte): cint
  {.importc: "v3e_sauvola", cdecl.}
proc c_boxBlur(src: ptr byte; w, h, ch, radius: cint; scratch, dst: ptr byte)
  {.importc: "v3e_box_blur", cdecl.}
proc c_median3(src: ptr byte; w, h, ch: cint; dst: ptr byte)
  {.importc: "v3e_median3", cdecl.}
proc c_unsharp(src: ptr byte; w, h, ch, radius: cint; amount: cdouble;
               dst: ptr byte): cint
  {.importc: "v3e_unsharp", cdecl.}
proc c_resizeBilinear(src: ptr byte; sw, sh, ch: cint; dst: ptr byte;
                      dw, dh: cint)
  {.importc: "v3e_resize_bilinear", cdecl.}
proc c_resizeArea(src: ptr byte; sw, sh, ch: cint; dst: ptr byte; dw, dh: cint)
  {.importc: "v3e_resize_area", cdecl.}
proc c_rotateQuadrant(src: ptr byte; w, h, ch, turns: cint; dst: ptr byte)
  {.importc: "v3e_rotate_quadrant", cdecl.}
proc c_rotateBilinear(src: ptr byte; w, h, ch: cint; angle: cdouble;
                      dst: ptr byte; dw, dh: cint; fill: uint8)
  {.importc: "v3e_rotate_bilinear", cdecl.}
proc c_laplacianVariance(gray: ptr byte; w, h: cint): cdouble
  {.importc: "v3e_laplacian_variance", cdecl.}
proc c_meanLuma(gray: ptr byte; w, h: cint): cdouble
  {.importc: "v3e_mean_luma", cdecl.}
proc c_inkCoverage(gray: ptr byte; w, h: cint): cdouble
  {.importc: "v3e_ink_coverage", cdecl.}
proc c_rowProjection(bin: ptr byte; w, h: cint; outp: ptr int32)
  {.importc: "v3e_row_projection", cdecl.}
proc c_projectionVariance(bin: ptr byte; w, h: cint; angle: cdouble): cdouble
  {.importc: "v3e_projection_variance", cdecl.}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

template p0(s: untyped): ptr byte =
  ## Address of the first byte of a non-empty seq[byte].
  cast[ptr byte](unsafeAddr s[0])

template requireNonEmpty(img: Image; what: string) =
  if img.isEmpty:
    raiseImage(what & ": image is empty")

template requireGray(img: Image; what: string) =
  if img.channels != 1:
    raiseImage(what & " requires a single-channel image, got " &
      $img.channels & " channels")

# ---------------------------------------------------------------------------
# Colour
# ---------------------------------------------------------------------------

proc toGray*(img: Image): Image =
  ## Rec.601 luma. Returns `img` unchanged when it is already single-channel.
  requireNonEmpty(img, "toGray")
  if img.channels == 1: return img
  result = newImage(img.width, img.height, pkGray, img.dpi)
  c_toGray(p0(img.data), cint(img.width), cint(img.height), cint(img.channels),
           p0(result.data))

proc toChannels*(img: Image; kind: PixelKind): Image =
  ## Expands a gray image to more channels. Only widening is supported; use
  ## `toGray` for the other direction.
  requireNonEmpty(img, "toChannels")
  if img.channels == ord(kind): return img
  if img.channels != 1:
    raiseImage("toChannels expands from gray only; call toGray first")
  result = newImage(img.width, img.height, kind, img.dpi)
  c_grayToChannels(p0(img.data), cint(img.width), cint(img.height),
                   cint(ord(kind)), p0(result.data))

proc autocontrast*(img: Image; lowPct = 0.5; highPct = 0.5): Image =
  ## Percentile histogram stretch. The default clip of 0.5% at each end removes
  ## scanner black point and paper hot spots without crushing real detail.
  requireNonEmpty(img, "autocontrast")
  result = img
  c_autocontrast(p0(result.data), cint(img.width), cint(img.height),
                 cint(img.channels), cdouble(lowPct), cdouble(highPct))

# ---------------------------------------------------------------------------
# Thresholding
# ---------------------------------------------------------------------------

proc otsuThreshold*(gray: Image): int =
  ## Global threshold from Otsu's method. Returns -1 for an empty image.
  requireNonEmpty(gray, "otsuThreshold")
  requireGray(gray, "otsuThreshold")
  int(c_otsu(p0(gray.data), cint(gray.width), cint(gray.height)))

proc binarizeGlobal*(gray: Image; threshold = -1; invert = false): Image =
  ## Applies a global threshold; pass -1 to compute one with Otsu.
  requireNonEmpty(gray, "binarizeGlobal")
  requireGray(gray, "binarizeGlobal")
  let thr = if threshold >= 0: threshold else: otsuThreshold(gray)
  result = newImage(gray.width, gray.height, pkGray, gray.dpi)
  c_thresholdApply(p0(gray.data), cint(gray.width), cint(gray.height),
                   cint(thr), cint(ord(invert)), p0(result.data))

proc binarizeSauvola*(gray: Image; window = 25; k = 0.34; r = 128.0): Image =
  ## Adaptive threshold. This is the right default for photographed or unevenly
  ## lit pages, where a single global cut either drops faint text or floods
  ## shadowed corners with ink.
  requireNonEmpty(gray, "binarizeSauvola")
  requireGray(gray, "binarizeSauvola")
  result = newImage(gray.width, gray.height, pkGray, gray.dpi)
  let rc = c_sauvola(p0(gray.data), cint(gray.width), cint(gray.height),
                     cint(window), cdouble(k), cdouble(r), p0(result.data))
  if rc != 0:
    raiseImage("Sauvola binarisation failed to allocate its integral images")

proc integralImage*(gray: Image): tuple[sum, sqsum: seq[uint64]] =
  ## Summed-area tables with a `(width + 1)` stride, exposed because layout
  ## analysis reuses them for region statistics.
  requireNonEmpty(gray, "integralImage")
  requireGray(gray, "integralImage")
  let n = (gray.width + 1) * (gray.height + 1)
  result.sum = newSeq[uint64](n)
  result.sqsum = newSeq[uint64](n)
  c_integral(p0(gray.data), cint(gray.width), cint(gray.height),
             addr result.sum[0], addr result.sqsum[0])

# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

proc boxBlur*(img: Image; radius: int): Image =
  requireNonEmpty(img, "boxBlur")
  if radius <= 0: return img
  result = newImage(img.width, img.height, img.pixelKind, img.dpi)
  var scratch = newSeq[byte](img.byteLen)
  c_boxBlur(p0(img.data), cint(img.width), cint(img.height),
            cint(img.channels), cint(radius), p0(scratch), p0(result.data))

proc median3*(img: Image): Image =
  ## 3x3 median. Removes scanner speckle without the stroke thinning a blur
  ## causes.
  requireNonEmpty(img, "median3")
  result = newImage(img.width, img.height, img.pixelKind, img.dpi)
  c_median3(p0(img.data), cint(img.width), cint(img.height),
            cint(img.channels), p0(result.data))

proc unsharp*(img: Image; radius = 2; amount = 0.8): Image =
  requireNonEmpty(img, "unsharp")
  result = newImage(img.width, img.height, img.pixelKind, img.dpi)
  let rc = c_unsharp(p0(img.data), cint(img.width), cint(img.height),
                     cint(img.channels), cint(radius), cdouble(amount),
                     p0(result.data))
  if rc != 0:
    raiseImage("unsharp mask failed to allocate its scratch buffers")

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

proc resize*(img: Image; width, height: int): Image =
  ## Resamples to an exact size, picking area-averaging for downscales (which
  ## is alias-free) and bilinear for upscales.
  requireNonEmpty(img, "resize")
  if width <= 0 or height <= 0:
    raiseImage("resize target must be positive, got " & $width & "x" & $height)
  if width == img.width and height == img.height: return img

  let scaledDpi =
    if img.dpi > 0: int(round(img.dpi.float * width.float / img.width.float))
    else: 0
  result = newImage(width, height, img.pixelKind, scaledDpi)
  if width <= img.width and height <= img.height:
    c_resizeArea(p0(img.data), cint(img.width), cint(img.height),
                 cint(img.channels), p0(result.data), cint(width), cint(height))
  else:
    c_resizeBilinear(p0(img.data), cint(img.width), cint(img.height),
                     cint(img.channels), p0(result.data), cint(width),
                     cint(height))

proc scaleBy*(img: Image; factor: float): Image =
  if factor <= 0.0:
    raiseImage("scale factor must be positive, got " & $factor)
  resize(img, max(1, int(round(img.width.float * factor))),
              max(1, int(round(img.height.float * factor))))

proc fitWithin*(img: Image; maxWidth, maxHeight: int): Image =
  ## Downscales to fit a bounding box, preserving aspect ratio. Never upscales
  ## -- enlarging costs tokens and adds no information.
  requireNonEmpty(img, "fitWithin")
  if img.width <= maxWidth and img.height <= maxHeight: return img
  let s = min(maxWidth.float / img.width.float,
              maxHeight.float / img.height.float)
  resize(img, max(1, int(round(img.width.float * s))),
              max(1, int(round(img.height.float * s))))

proc fitLongestSide*(img: Image; maxSide: int): Image =
  requireNonEmpty(img, "fitLongestSide")
  if max(img.width, img.height) <= maxSide: return img
  fitWithin(img, maxSide, maxSide)

proc rotateQuadrant*(img: Image; turns: int): Image =
  ## Lossless rotation by a multiple of 90 degrees clockwise.
  requireNonEmpty(img, "rotateQuadrant")
  let t = ((turns mod 4) + 4) mod 4
  if t == 0: return img
  let (w, h) = if t == 2: (img.width, img.height) else: (img.height, img.width)
  result = newImage(w, h, img.pixelKind, img.dpi)
  c_rotateQuadrant(p0(img.data), cint(img.width), cint(img.height),
                   cint(img.channels), cint(t), p0(result.data))

proc rotate*(img: Image; degrees: float; expand = true; fill = 255'u8): Image =
  ## Rotates counter-clockwise about the centre. With `expand`, the canvas grows
  ## so no content is clipped -- which is what deskew wants, since a page corner
  ## pushed outside the frame takes its text with it.
  requireNonEmpty(img, "rotate")
  if abs(degrees) < 1e-9: return img
  let rad = degrees * PI / 180.0
  var dw = img.width
  var dh = img.height
  if expand:
    let c = abs(cos(rad))
    let s = abs(sin(rad))
    dw = max(1, int(ceil(img.width.float * c + img.height.float * s)))
    dh = max(1, int(ceil(img.width.float * s + img.height.float * c)))
  result = newImage(dw, dh, img.pixelKind, img.dpi)
  c_rotateBilinear(p0(img.data), cint(img.width), cint(img.height),
                   cint(img.channels), cdouble(rad), p0(result.data),
                   cint(dw), cint(dh), fill)

proc crop*(img: Image; box: BBox): Image =
  ## Crops to `box`, clipped to the image bounds.
  requireNonEmpty(img, "crop")
  let b = box.clampTo(img.width, img.height)
  if b.isEmpty:
    raiseImage("crop rectangle does not intersect the image")
  result = newImage(b.w, b.h, img.pixelKind, img.dpi)
  let rowBytes = b.w * img.channels
  for y in 0 ..< b.h:
    let src = ((b.y + y) * img.width + b.x) * img.channels
    let dst = y * rowBytes
    copyMem(addr result.data[dst], unsafeAddr img.data[src], rowBytes)

proc pad*(img: Image; margin: int; fill = 255'u8): Image =
  ## Adds a uniform border. Tesseract's layout analysis is measurably better
  ## with a quiet margin around the text, and tightly cropped inputs are common.
  requireNonEmpty(img, "pad")
  if margin <= 0: return img
  result = newImage(img.width + 2 * margin, img.height + 2 * margin,
                    img.pixelKind, img.dpi)
  for i in 0 ..< result.data.len:
    result.data[i] = fill
  let rowBytes = img.width * img.channels
  for y in 0 ..< img.height:
    let src = y * rowBytes
    let dst = ((y + margin) * result.width + margin) * img.channels
    copyMem(addr result.data[dst], unsafeAddr img.data[src], rowBytes)

# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

proc laplacianVariance*(gray: Image): float =
  requireNonEmpty(gray, "laplacianVariance")
  requireGray(gray, "laplacianVariance")
  float(c_laplacianVariance(p0(gray.data), cint(gray.width), cint(gray.height)))

proc meanLuma*(gray: Image): float =
  requireNonEmpty(gray, "meanLuma")
  requireGray(gray, "meanLuma")
  float(c_meanLuma(p0(gray.data), cint(gray.width), cint(gray.height)))

proc inkCoverage*(gray: Image): float =
  requireNonEmpty(gray, "inkCoverage")
  requireGray(gray, "inkCoverage")
  float(c_inkCoverage(p0(gray.data), cint(gray.width), cint(gray.height)))

proc rowProjection*(bin: Image): seq[int32] =
  requireNonEmpty(bin, "rowProjection")
  requireGray(bin, "rowProjection")
  result = newSeq[int32](bin.height)
  c_rowProjection(p0(bin.data), cint(bin.width), cint(bin.height),
                  addr result[0])

proc projectionVariance*(bin: Image; degrees: float): float =
  ## Variance of the horizontal ink profile after a virtual rotation. Text lines
  ## are horizontal when this peaks, which is the whole basis of the deskew
  ## search in `deskew.nim`.
  requireNonEmpty(bin, "projectionVariance")
  requireGray(bin, "projectionVariance")
  float(c_projectionVariance(p0(bin.data), cint(bin.width), cint(bin.height),
                             cdouble(degrees * PI / 180.0)))

proc contrastSpread*(gray: Image): float =
  ## Separation between the ink and paper tones, normalised to 0..1.
  ##
  ## Computed as the distance between the two class means either side of the
  ## Otsu threshold -- i.e. exactly the quantity binarisation depends on.
  ##
  ## A percentile spread was the obvious first choice and is wrong here: a
  ## printed page is ~99% paper, so its 5th *and* 95th percentiles are both
  ## white and a crisp scan scores 0.0. Even a 5% tail average is dominated by
  ## paper when ink covers 0.6% of the page. Splitting at the Otsu threshold
  ## sidesteps the problem entirely, because the split adapts to however much
  ## ink there happens to be.
  ##
  ## A clean scan scores above 0.8; a washed-out or underexposed one falls
  ## toward 0.3, which is the warning that binarisation is about to struggle.
  ## A featureless image scores 0.
  requireNonEmpty(gray, "contrastSpread")
  requireGray(gray, "contrastSpread")
  let thr = otsuThreshold(gray)
  if thr < 0: return 0.0

  var hist: array[256, int]
  for v in gray.data: inc hist[int(v)]

  var darkSum = 0
  var darkCount = 0
  var lightSum = 0
  var lightCount = 0
  for v in 0 .. 255:
    if v <= thr:
      darkSum += v * hist[v]
      darkCount += hist[v]
    else:
      lightSum += v * hist[v]
      lightCount += hist[v]

  # One empty class means the image has no tonal structure at all.
  if darkCount == 0 or lightCount == 0: return 0.0
  let darkMean = darkSum.float / darkCount.float
  let lightMean = lightSum.float / lightCount.float
  max(0.0, (lightMean - darkMean) / 255.0)

proc estimateTextHeight*(bin: Image): int =
  ## Median height of the ink runs in the row projection -- a decent proxy for
  ## x-height, and therefore for whether the page is scanned high enough for
  ## OCR. Returns 0 when no lines are found.
  let proj = rowProjection(bin)
  if proj.len == 0: return 0
  var threshold = 0'i32
  for v in proj: threshold += v
  threshold = int32(max(1, threshold.int div max(1, proj.len) div 4))

  var runs: seq[int]
  var run = 0
  for v in proj:
    if v >= threshold:
      inc run
    elif run > 0:
      runs.add run
      run = 0
  if run > 0: runs.add run
  if runs.len == 0: return 0
  runs.sort()
  runs[runs.len div 2]
