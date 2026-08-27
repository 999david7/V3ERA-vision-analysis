## Preprocessing profiles.
##
## Different inputs want opposite treatment, and applying the wrong profile is
## the single biggest source of bad OCR:
##
##   * A **scan** benefits from deskew, upscaling toward 300 DPI and adaptive
##     binarisation.
##   * A **screenshot** must NOT be binarised. Its text is anti-aliased at a
##     small point size, and thresholding turns those grey edge pixels into
##     ragged bilevel noise. Integer upscaling helps instead.
##   * A **photo** of a page needs denoising before anything else, then the
##     scan treatment.
##   * A **diagram** should keep its colour for the VLM; only the label pass
##     gets a binarised copy.
##
## `PreprocessConfig` exposes each knob, and `profileFor` picks sane defaults
## from the classifier's verdict.

import std/[math, strutils]

import ../core/[types, log]
import ./ops, ./deskew

export ops, deskew

type
  BinarizeMode* = enum
    bmNone = "none"        ## Leave grayscale -- correct for anti-aliased text.
    bmOtsu = "otsu"        ## Global; fast, good on clean high-contrast scans.
    bmSauvola = "sauvola"   ## Adaptive; the default for anything photographed.

  PreprocessConfig* = object
    grayscale*: bool
    denoise*: bool           ## 3x3 median before anything else.
    autocontrast*: bool
    autoOrient*: bool        ## Quadrant detection + deskew.
    maxSkewDegrees*: float
    binarize*: BinarizeMode
    sauvolaWindow*: int
    sauvolaK*: float
    sharpen*: bool
    sharpenAmount*: float
    targetDpi*: int          ## Upscale toward this; 0 disables.
    maxDimension*: int       ## Hard cap on the longest side; 0 disables.
    minDimension*: int       ## Upscale small inputs to at least this.
    maxUpscale*: float
      ## Ceiling on the enlargement factor, whatever `targetDpi` and
      ## `minDimension` ask for. Interpolation invents no detail, so past a
      ## point enlarging only multiplies memory and OCR time; 4x is already
      ## generous for a legible source.
    padMargin*: int

  PreprocessReport* = object
    ## What actually happened, for logging and for the result's timing record.
    applied*: seq[string]
    deskewAngle*: float
    quadrantTurns*: int
    inputWidth*, inputHeight*: int
    outputWidth*, outputHeight*: int
    quality*: ImageQuality

func defaultConfig*(): PreprocessConfig =
  PreprocessConfig(
    grayscale: true, denoise: false, autocontrast: true, autoOrient: true,
    maxSkewDegrees: 10.0, binarize: bmSauvola, sauvolaWindow: 25,
    sauvolaK: 0.34, sharpen: false, sharpenAmount: 0.8, targetDpi: 300,
    maxDimension: 4000, minDimension: 0, maxUpscale: 4.0, padMargin: 12)

func documentProfile*(): PreprocessConfig =
  ## Clean scans and rendered PDF pages.
  result = defaultConfig()

func photoProfile*(): PreprocessConfig =
  ## A camera picture of a page: sensor noise, uneven lighting, real skew.
  result = defaultConfig()
  result.denoise = true
  result.sharpen = true
  result.sauvolaWindow = 31
  result.maxSkewDegrees = 15.0

func screenshotProfile*(): PreprocessConfig =
  ## UI captures. No binarisation, no deskew (they are never skewed), and a 2x
  ## upscale so small anti-aliased glyphs clear Tesseract's minimum x-height.
  result = defaultConfig()
  result.autoOrient = false
  result.binarize = bmNone
  result.autocontrast = false
  result.targetDpi = 0
  result.minDimension = 1600
  result.padMargin = 8

func diagramProfile*(): PreprocessConfig =
  ## Charts and line art: keep the strokes crisp, do not threshold away the
  ## thin ones, and leave orientation alone.
  result = defaultConfig()
  result.autoOrient = false
  result.binarize = bmNone
  result.targetDpi = 0
  result.minDimension = 1400
  result.padMargin = 8

func passthroughProfile*(): PreprocessConfig =
  PreprocessConfig(grayscale: false, maxDimension: 8000, maxUpscale: 1.0)

func vlmProfile*(maxSide = 1568): PreprocessConfig =
  ## What a vision-language model wants: original colour, no binarisation, and
  ## a cap on the longest side. Beyond roughly 1568 px the model downsamples
  ## anyway, so sending more only costs tokens and latency.
  PreprocessConfig(grayscale: false, autocontrast: false, autoOrient: false,
                   binarize: bmNone, maxDimension: maxSide, maxUpscale: 1.0)

func profileFor*(kind: InputKind): PreprocessConfig =
  case kind
  of ikScreenshot: screenshotProfile()
  of ikPhoto: photoProfile()
  of ikDiagram: diagramProfile()
  of ikScannedDocument, ikPdf: documentProfile()
  of ikUnknown: defaultConfig()

proc measureQuality*(img: Image): ImageQuality =
  ## Cheap signals used to gate later stages. Always computed on a grayscale
  ## copy so the numbers are comparable across input types.
  if img.isEmpty: return ImageQuality(isBlank: true)
  let gray = img.toGray()
  result.sharpness = gray.laplacianVariance()
  result.meanLuma = gray.meanLuma()
  result.contrast = gray.contrastSpread()
  result.estimatedDpi = img.dpi

  let bin = gray.binarizeGlobal()
  result.inkCoverage = bin.inkCoverage()
  # "Blank" means both almost no ink and almost no tonal range, so a very light
  # but genuinely printed page is not thrown away.
  result.isBlank = result.inkCoverage < 0.0008 and result.contrast < 0.08

proc targetScaleForDpi(img: Image; cfg: PreprocessConfig): float =
  ## How much to upscale so text reaches a size Tesseract handles well.
  ##
  ## When the DPI is known we scale toward `targetDpi` directly. When it is not
  ## -- the usual case for a bare PNG -- we fall back on measured text height:
  ## Tesseract wants an x-height around 20-30 px, and below about 12 px its
  ## accuracy falls off a cliff.
  if cfg.targetDpi <= 0: return 1.0
  if img.dpi > 0:
    if img.dpi >= cfg.targetDpi: return 1.0
    return min(4.0, cfg.targetDpi.float / img.dpi.float)

  let gray = img.toGray()
  let probe =
    if max(gray.width, gray.height) > 1600: gray.fitLongestSide(1600)
    else: gray
  let textHeight = probe.binarizeGlobal().estimateTextHeight()
  if textHeight <= 0: return 1.0
  # Undo the probe downscale so the measurement refers to the full-size image.
  let probeScale = probe.width.float / gray.width.float
  let actual = textHeight.float / max(probeScale, 1e-6)
  if actual >= 18.0: return 1.0
  clamp(22.0 / max(actual, 4.0), 1.0, 4.0)

proc preprocess*(img: Image; cfg: PreprocessConfig):
    tuple[image: Image; report: PreprocessReport] =
  ## Runs the configured stages in the order that matters:
  ## denoise -> grayscale -> contrast -> orient -> scale -> sharpen ->
  ## binarise -> pad.
  ##
  ## Orientation before scaling keeps the rotation cheap; binarisation last so
  ## every earlier stage still has grey levels to work with.
  var work = img
  var rep = PreprocessReport(
    inputWidth: img.width, inputHeight: img.height)

  if img.isEmpty:
    rep.quality = ImageQuality(isBlank: true)
    return (img, rep)

  template note(s: string) = rep.applied.add s

  if cfg.denoise:
    work = work.median3()
    note "denoise"

  if cfg.grayscale and work.channels > 1:
    work = work.toGray()
    note "grayscale"

  if cfg.autocontrast:
    work = work.autocontrast()
    note "autocontrast"

  if cfg.autoOrient:
    let turns = work.detectQuadrant()
    if turns != 0:
      work = work.rotateQuadrant(turns)
      rep.quadrantTurns = turns
      note "rotate:" & $(turns * 90)
    let (deskewed, angle) = work.deskew(maxAngle = cfg.maxSkewDegrees)
    if angle != 0.0:
      work = deskewed
      rep.deskewAngle = angle
      note "deskew:" & formatFloat(angle, ffDecimal, 2)

  # Quality is measured after geometric correction but before binarisation, so
  # the sharpness number reflects the pixels OCR will actually see.
  rep.quality = measureQuality(work)

  block scaling:
    var scale = targetScaleForDpi(work, cfg)
    if cfg.minDimension > 0:
      let longest = max(work.width, work.height)
      if longest > 0 and longest < cfg.minDimension:
        scale = max(scale, cfg.minDimension.float / longest.float)
    scale = min(scale, max(1.0, cfg.maxUpscale))
    if scale > 1.02:
      work = work.scaleBy(scale)
      note "upscale:" & formatFloat(scale, ffDecimal, 2)

  if cfg.maxDimension > 0 and max(work.width, work.height) > cfg.maxDimension:
    work = work.fitLongestSide(cfg.maxDimension)
    note "downscale:" & $cfg.maxDimension

  if cfg.sharpen:
    work = work.unsharp(radius = 2, amount = cfg.sharpenAmount)
    note "sharpen"

  case cfg.binarize
  of bmNone: discard
  of bmOtsu:
    work = work.toGray().binarizeGlobal()
    note "binarize:otsu"
  of bmSauvola:
    work = work.toGray().binarizeSauvola(window = cfg.sauvolaWindow,
                                         k = cfg.sauvolaK)
    note "binarize:sauvola"

  if cfg.padMargin > 0:
    let fill = if work.channels == 1: 255'u8 else: 255'u8
    work = work.pad(cfg.padMargin, fill)
    note "pad:" & $cfg.padMargin

  rep.outputWidth = work.width
  rep.outputHeight = work.height

  log.debug("preprocess complete", {
    "in": $rep.inputWidth & "x" & $rep.inputHeight,
    "out": $rep.outputWidth & "x" & $rep.outputHeight,
    "stages": rep.applied.join(",")})

  (work, rep)

proc preprocessFor*(img: Image; kind: InputKind):
    tuple[image: Image; report: PreprocessReport] =
  preprocess(img, profileFor(kind))

proc prepareForVlm*(img: Image; maxSide = 1568): Image =
  ## Downscales an image to the point past which a vision model gains nothing.
  ## Purely a cost control; no tonal changes are made.
  if img.isEmpty: return img
  img.fitLongestSide(maxSide)
