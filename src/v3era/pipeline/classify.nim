## Input classification.
##
## The router decides which preprocessing profile, which OCR page-segmentation
## mode and which prompt an image gets. Getting it wrong is expensive -- a
## screenshot pushed through the scan profile comes back as ragged bilevel
## noise -- so the classifier reports its evidence alongside its verdict, and
## abstains (`ikUnknown`) rather than guessing when the signals disagree.
##
## All signals are computed on a downscaled copy, so cost is bounded regardless
## of input size.

import std/[math, strutils, algorithm]

import ../core/[types, log]
import ../preprocess/ops

type
  ClassifySignals* = object
    ## Every number the verdict is based on, so a misclassification can be
    ## diagnosed from a log line instead of a debugger.
    flatRunRatio*: float
      ## Fraction of horizontally adjacent pixel pairs that are exactly equal.
      ## Rendered UI is full of flat fills and hits 0.7+; a photograph, with
      ## sensor noise on every pixel, sits near zero even on a blank wall.
    uniqueColorRatio*: float
      ## Distinct colours over sampled pixels. Line art and UI quantise hard.
    colorfulness*: float
      ## Mean per-pixel spread between the max and min channel, 0..1.
    backgroundRatio*: float
      ## Fraction of pixels within 12 levels of the modal (paper) luma.
    borderBackgroundRatio*: float
      ## Same measure restricted to the outer 4% frame of the image. A printed
      ## page has margins, so this is near 1.0; a screenshot has window chrome,
      ## sidebars and scrollbars running to the edge, so it is much lower. This
      ## is what separates a rendered document page from a screenshot when both
      ## are grey, flat and full of text.
    inkCoverage*: float
    textLineScore*: float
      ## Normalised row-projection variance: high whenever ink clusters into
      ## rows. On its own it does NOT identify text -- a diagram's horizontal
      ## rules spike just as hard -- so the three band measures below carry the
      ## actual discrimination.
    textBandCount*: int
      ## Number of contiguous ink bands in the row projection. A page of prose
      ## has many; a diagram has a handful of rules.
    medianBandHeight*: int
      ## Median band thickness in probe pixels. Text bands are several pixels
      ## tall even downscaled; a drawn rule is one to three.
    bandRegularity*: float
      ## 0..1, how evenly the bands are spaced. Leading is near-constant in
      ## typeset text and arbitrary in artwork. This is the single strongest
      ## cue that a region is prose.
    sharpness*: float
    aspect*: float

  Classification* = object
    kind*: InputKind
    confidence*: float ## 0..1.
    signals*: ClassifySignals
    rationale*: string

const probeSide = 900
  ## Signals are scale-free; a smaller probe is faster and averages out grain.

proc computeSignals*(img: Image): ClassifySignals =
  if img.isEmpty: return

  let probe =
    if max(img.width, img.height) > probeSide: img.fitLongestSide(probeSide)
    else: img
  let gray = probe.toGray()
  result.aspect = probe.width.float / max(1.0, probe.height.float)
  result.sharpness = gray.laplacianVariance()

  # --- flat runs and colour statistics, in one pass over the probe ---
  var equalPairs = 0
  var totalPairs = 0
  var saturationSum = 0.0
  let ch = probe.channels
  for y in 0 ..< probe.height:
    for x in 0 ..< probe.width - 1:
      let a = (y * probe.width + x) * ch
      let b = a + ch
      var same = true
      for c in 0 ..< min(ch, 3):
        if probe.data[a + c] != probe.data[b + c]:
          same = false
          break
      if same: inc equalPairs
      inc totalPairs
    if ch >= 3:
      for x in 0 ..< probe.width:
        let p = (y * probe.width + x) * ch
        let r = probe.data[p].int
        let g = probe.data[p + 1].int
        let bl = probe.data[p + 2].int
        saturationSum += (max(r, max(g, bl)) - min(r, min(g, bl))).float / 255.0
  if totalPairs > 0:
    result.flatRunRatio = equalPairs.float / totalPairs.float
  if ch >= 3 and probe.width * probe.height > 0:
    result.colorfulness = saturationSum / (probe.width * probe.height).float

  # --- distinct colours, quantised to 5 bits per channel ---
  # Exact colours would count JPEG ringing as variety; 32 levels per channel is
  # coarse enough to ignore that and fine enough to separate UI from photo.
  var seen: seq[bool] = newSeq[bool](32 * 32 * 32)
  var distinct1 = 0
  var sampled = 0
  let step = max(1, (probe.width * probe.height) div 20_000)
  var i = 0
  while i < probe.width * probe.height:
    let p = i * ch
    let key =
      if ch >= 3:
        (probe.data[p].int shr 3) * 1024 + (probe.data[p + 1].int shr 3) * 32 +
          (probe.data[p + 2].int shr 3)
      else:
        let v = probe.data[p].int shr 3
        v * 1024 + v * 32 + v
    if not seen[key]:
      seen[key] = true
      inc distinct1
    inc sampled
    i += step
  if sampled > 0:
    result.uniqueColorRatio = distinct1.float / sampled.float

  # --- background (paper) detection from the luma histogram mode ---
  var hist: array[256, int]
  for v in gray.data: inc hist[int(v)]
  var modal = 0
  for v in 1 .. 255:
    if hist[v] > hist[modal]: modal = v
  var near = 0
  for v in max(0, modal - 12) .. min(255, modal + 12):
    near += hist[v]
  result.backgroundRatio = near.float / max(1, gray.data.len).float

  let lo = max(0, modal - 12)
  let hi = min(255, modal + 12)
  let bandX = max(1, gray.width * 4 div 100)
  let bandY = max(1, gray.height * 4 div 100)
  var borderTotal = 0
  var borderBg = 0
  for y in 0 ..< gray.height:
    let edgeRow = y < bandY or y >= gray.height - bandY
    for x in 0 ..< gray.width:
      if not (edgeRow or x < bandX or x >= gray.width - bandX): continue
      inc borderTotal
      let v = gray.data[y * gray.width + x].int
      if v >= lo and v <= hi: inc borderBg
  if borderTotal > 0:
    result.borderBackgroundRatio = borderBg.float / borderTotal.float

  # --- ink and text-band structure ---
  let bin = gray.binarizeGlobal()
  result.inkCoverage = bin.inkCoverage()
  let flat = bin.projectionVariance(0.0)
  # Normalise by the variance a uniform smear of the same ink would produce, so
  # the score reflects banding rather than sheer quantity of ink.
  let ink = result.inkCoverage * (bin.width * bin.height).float
  let uniform = if bin.height > 0: (ink / bin.height.float) else: 0.0
  result.textLineScore =
    if uniform <= 0.0: 0.0
    else: min(4.0, sqrt(flat) / uniform)

  # Bands: contiguous runs of rows carrying a significant share of the busiest
  # row's ink. Thresholding against the maximum rather than the mean keeps a
  # page's wide margins from dragging the cut below the noise floor.
  let proj = bin.rowProjection()
  var peak = 0
  for v in proj: peak = max(peak, v.int)
  if peak > 0:
    let cut = max(1, peak div 6)
    var heights: seq[int]
    var starts: seq[int]
    var i = 0
    while i < proj.len:
      if proj[i].int >= cut:
        let runStart = i
        while i < proj.len and proj[i].int >= cut: inc i
        heights.add i - runStart
        starts.add runStart
      else:
        inc i
    result.textBandCount = heights.len
    if heights.len > 0:
      var sortedHeights = heights
      sortedHeights.sort()
      result.medianBandHeight = sortedHeights[sortedHeights.len div 2]
    if starts.len >= 3:
      var gaps: seq[float]
      for k in 1 ..< starts.len:
        gaps.add (starts[k] - starts[k - 1]).float
      gaps.sort()
      let medianGap = gaps[gaps.len div 2]
      if medianGap > 0.0:
        # Median absolute deviation, not standard deviation. Real pages throw
        # off stray bands -- a descender that clears the threshold, a rule
        # under a heading, a page number -- and each one produces a single
        # anomalous gap. With only three or four gaps on a short document, one
        # outlier moves the mean and inflates the variance enough to sink an
        # obviously well-typeset page. The median ignores it.
        var deviations: seq[float]
        for g in gaps:
          deviations.add abs(g - medianGap)
        deviations.sort()
        let mad = deviations[deviations.len div 2]
        result.bandRegularity = clamp(1.0 - mad / medianGap, 0.0, 1.0)

proc classify*(img: Image; hintedFormat = sfUnknown): Classification =
  ## Decides what kind of input this is.
  ##
  ## Ordered rules rather than a learned model: with six or so signals and four
  ## classes, explicit thresholds are auditable, adjustable per deployment, and
  ## need no training data or model artefact in the container.
  if img.isEmpty:
    return Classification(kind: ikUnknown, rationale: "empty image")

  result.signals = computeSignals(img)
  let s = result.signals

  # A PDF that reached here has already been rasterised; keep its identity so
  # the document profile is used and page structure is preserved.
  if hintedFormat == sfPdf:
    return Classification(kind: ikPdf, confidence: 1.0, signals: s,
                          rationale: "source container is PDF")

  # A page with essentially nothing on it has no evidence to classify. Saying
  # so beats letting it fall through to the sparse-marks rule and be called a
  # diagram, which is what an empty scan would otherwise be labelled.
  if s.inkCoverage < 0.0008 and s.textBandCount == 0:
    return Classification(kind: ikUnknown, confidence: 0.0, signals: s,
                          rationale: "no discernible content")

  # Synthetic pixels: long runs of identical colour and a small palette are
  # things a camera essentially never produces.
  let synthetic = s.flatRunRatio > 0.55 and s.uniqueColorRatio < 0.25

  # ...but "synthetic" alone does not mean "screenshot": a rendered PDF page and
  # a line drawing are just as flat and just as monochrome. What separates them
  # is the frame. A page or a drawing sits on a margin, so its border is bare
  # background; a screenshot has chrome -- title bar, sidebar, scrollbar --
  # reaching the edge.
  #
  # Both halves are required. Edge content alone would catch a scan with the
  # scanner lid's black border, and colour alone would catch a colourful chart.
  # A *coloured* edge is what UI has and neither of those does.
  #
  # Known limit: a fully greyscale screenshot -- a terminal, a monochrome
  # e-reader capture -- reads as a document here. That misroute is cheap: the
  # document profile still OCRs it, just with binarisation it did not need.
  let hasChrome = s.borderBackgroundRatio < 0.85 and s.colorfulness > 0.03

  # A page of text: dominant paper background, a modest amount of ink, and --
  # the part that actually separates prose from artwork -- many bands, each
  # thick enough to be a line of type, spaced evenly enough to be leading.
  # Signals are measured on a probe capped at 900 px, so 5 px is a meaningful
  # absolute floor for band thickness at any input resolution.
  #
  # Three bands is the floor. Short documents are common -- a receipt, a
  # memo, a cover sheet -- and demanding more sends them down the diagram
  # path. Below three there are no two gaps to compare, so `bandRegularity`
  # carries no information and the rule would rest on thickness alone; a
  # one- or two-line image is treated as a label rather than a page, which is
  # usually what it is.
  const
    minTextBands = 3
    minBandHeight = 5
    minRegularity = 0.45
  let pageLike = s.backgroundRatio > 0.55 and s.inkCoverage > 0.005 and
                 s.inkCoverage < 0.45 and
                 s.textBandCount >= minTextBands and
                 s.medianBandHeight >= minBandHeight and
                 s.bandRegularity >= minRegularity

  if synthetic and hasChrome:
    result.kind = ikScreenshot
    result.confidence = min(1.0, (s.flatRunRatio - 0.55) / 0.35 + 0.55)
    result.rationale = "flat colour runs, small palette, coloured chrome at the edges"

  elif pageLike:
    # Flat runs separate a clean scan from a camera photo of the same page:
    # scanning quantises, photographing does not.
    if s.flatRunRatio > 0.30 or s.colorfulness < 0.06:
      result.kind = ikScannedDocument
      result.confidence = if synthetic: 0.85 else: 0.8
      result.rationale = "paper background with regular text bands and margins"
    else:
      result.kind = ikPhoto
      result.confidence = 0.65
      result.rationale = "text bands over a noisy, coloured background"

  # Diagram: mostly background, little ink, few colours, and -- having already
  # failed `pageLike` -- no run of evenly spaced lines of type.
  elif s.backgroundRatio > 0.5 and s.inkCoverage < 0.25 and
       s.uniqueColorRatio < 0.3:
    result.kind = ikDiagram
    result.confidence = 0.7
    result.rationale = "sparse marks on a uniform background, not lines of type"

  # Photo: continuous tone. Near-zero flat runs is the decisive cue -- sensor
  # noise means adjacent pixels are essentially never bit-identical, which no
  # rendered image can say.
  elif s.flatRunRatio < 0.15:
    result.kind = ikPhoto
    result.confidence = 0.7
    result.rationale = "continuous tone with no flat colour runs"

  else:
    result.kind = ikUnknown
    result.confidence = 0.3
    result.rationale = "signals did not match any profile confidently"

  log.debug("input classified", {
    "kind": $result.kind,
    "confidence": formatFloat(result.confidence, ffDecimal, 2),
    "flat_runs": formatFloat(s.flatRunRatio, ffDecimal, 3),
    "unique_colors": formatFloat(s.uniqueColorRatio, ffDecimal, 3),
    "background": formatFloat(s.backgroundRatio, ffDecimal, 3),
    "border_background": formatFloat(s.borderBackgroundRatio, ffDecimal, 3),
    "ink": formatFloat(s.inkCoverage, ffDecimal, 4),
    "text_bands": formatFloat(s.textLineScore, ffDecimal, 2),
    "band_count": $s.textBandCount,
    "band_height": $s.medianBandHeight,
    "band_regularity": formatFloat(s.bandRegularity, ffDecimal, 2),
    "colorfulness": formatFloat(s.colorfulness, ffDecimal, 3)})

func toJson*(s: ClassifySignals): auto =
  ## Included in the analysis result under `--explain`.
  (flat_run_ratio: s.flatRunRatio, unique_color_ratio: s.uniqueColorRatio,
   colorfulness: s.colorfulness, background_ratio: s.backgroundRatio,
   border_background_ratio: s.borderBackgroundRatio,
   ink_coverage: s.inkCoverage, text_line_score: s.textLineScore,
   text_band_count: s.textBandCount,
   median_band_height: s.medianBandHeight,
   band_regularity: s.bandRegularity,
   sharpness: s.sharpness, aspect: s.aspect)
