## Skew estimation by projection-profile variance.
##
## When text lines are horizontal, the count of ink pixels per row is spiky:
## high inside a line, near zero in the leading. Rotate the page away from
## level and those peaks smear together, lowering the variance. So the skew
## angle is the one that maximises variance of the row projection.
##
## The search is coarse-to-fine over a downscaled binary image. The C kernel
## accumulates into rotated bins analytically, so no intermediate image is
## produced per candidate angle -- that is what keeps a sub-0.1-degree estimate
## affordable on a full page.

import std/[math, strutils]

import ../core/[types, log]
import ./ops

type
  DeskewResult* = object
    angle*: float
      ## The tilt the page currently *has*, in degrees, positive meaning text
      ## lines run down to the right. Correcting it means rotating by the
      ## negation of this value, which is what `deskew` does.
    confidence*: float ## 0..1, from the peak-to-baseline variance ratio.
    searched*: int     ## Number of candidate angles evaluated.

const
  workingSide = 1200
    ## Deskew is scale-invariant, and a downscaled page gives a *cleaner*
    ## projection because it averages away speckle.
  minInk = 0.0005
    ## Below this ink fraction there is nothing to align.

proc prepareForDeskew(img: Image): Image =
  var gray = img.toGray()
  if max(gray.width, gray.height) > workingSide:
    gray = gray.fitLongestSide(workingSide)
  # A global threshold is right here: we only need the ink mask's *geometry*,
  # and Otsu is far cheaper than Sauvola at this size.
  gray.binarizeGlobal()

proc bestAngle(bin: Image; center, halfRange, step: float):
    tuple[angle, score: float; evaluated: int] =
  result.angle = center
  result.score = -1.0
  var a = center - halfRange
  while a <= center + halfRange + 1e-9:
    let s = bin.projectionVariance(a)
    inc result.evaluated
    if s > result.score:
      result.score = s
      result.angle = a
    a += step

proc estimateSkew*(img: Image; maxAngle = 10.0): DeskewResult =
  ## Estimates the page skew in degrees. `maxAngle` bounds the search; pages
  ## rotated further than that are a quadrant problem, not a skew problem, and
  ## `detectQuadrant` handles those.
  if img.isEmpty: return DeskewResult()
  let bin = prepareForDeskew(img)
  if bin.inkCoverage() < minInk:
    log.debug("deskew skipped: page has almost no ink")
    return DeskewResult()

  # Coarse pass at 1 degree, then two refinement passes an order of magnitude
  # finer each. Three passes reach 0.05 degrees in ~50 evaluations instead of
  # the ~400 a flat sweep would need.
  let coarse = bestAngle(bin, 0.0, maxAngle, 1.0)
  let mid = bestAngle(bin, coarse.angle, 1.0, 0.1)
  let fine = bestAngle(bin, mid.angle, 0.1, 0.02)

  let baseline = bin.projectionVariance(0.0)
  result.angle = fine.angle
  result.searched = coarse.evaluated + mid.evaluated + fine.evaluated
  result.confidence =
    if fine.score <= 0.0: 0.0
    elif baseline <= 0.0: 1.0
    else: clamp(1.0 - baseline / fine.score, 0.0, 1.0)

  log.debug("skew estimated", {
    "angle": formatFloat(result.angle, ffDecimal, 3),
    "confidence": formatFloat(result.confidence, ffDecimal, 3),
    "evaluated": $result.searched})

proc deskew*(img: Image; maxAngle = 10.0; minAngle = 0.15;
             fill = 255'u8): tuple[image: Image; angle: float] =
  ## Estimates and corrects skew, returning the corrected image and the tilt
  ## that was removed. Tilts below `minAngle` are left alone: the resampling
  ## blur costs more OCR accuracy than the residual skew does.
  let est = estimateSkew(img, maxAngle)
  if abs(est.angle) < minAngle:
    return (img, 0.0)
  # `est.angle` is the tilt present in the page, so the correction is its
  # negation.
  (img.rotate(-est.angle, expand = true, fill = fill), est.angle)

proc detectQuadrant*(img: Image): int =
  ## Detects 90-degree page rotation, returning the number of clockwise turns
  ## (0..3) needed to set it upright.
  ##
  ## Two cues, in order: whether the projection variance is higher for rows or
  ## for columns tells us the axis; then, for the upright axis, Latin script
  ## puts more ink in the upper half of each text band (ascenders and capitals
  ## outnumber descenders), which disambiguates upright from upside-down.
  if img.isEmpty: return 0
  let bin = prepareForDeskew(img)
  if bin.inkCoverage() < minInk: return 0

  # Score each axis at its *best* angle rather than at exactly 0 degrees. A page
  # that is both rotated by a quadrant and skewed by a few degrees scores poorly
  # on both axes at 0, and the comparison then turns on noise.
  proc axisScore(b: Image): tuple[score, angle: float] =
    let coarse = bestAngle(b, 0.0, 8.0, 1.0)
    let fine = bestAngle(b, coarse.angle, 1.0, 0.2)
    (fine.score, fine.angle)

  let horizontal = axisScore(bin)
  let rotated = bin.rotateQuadrant(1)
  let vertical = axisScore(rotated)

  # Text lines run along whichever axis gives the spikier profile.
  let needsTurn = vertical.score > horizontal.score * 1.15
  let candidate = if needsTurn: rotated else: bin
  let tilt = if needsTurn: vertical.angle else: horizontal.angle

  # Level the candidate before reading the up/down cue: the asymmetry between
  # the halves of a text band only survives while the bands are horizontal.
  let upright =
    if abs(tilt) >= 0.2: candidate.rotate(-tilt, expand = true)
    else: candidate

  # Ink asymmetry within each detected line band.
  let proj = upright.rowProjection()
  if proj.len < 8: return (if needsTurn: 1 else: 0)
  var total = 0
  for v in proj: total += v.int
  if total == 0: return (if needsTurn: 1 else: 0)

  let threshold = int32(max(1, total div proj.len div 3))
  const asymmetryMargin = 1.08
    ## A band only votes when one half carries at least 8% more ink than the
    ## other. Without this, perfectly symmetric bands (rules, table borders,
    ## boxed forms) would all fall to whichever side the tie-break favours and
    ## manufacture a confident, wrong verdict.
  var topHeavy = 0
  var bottomHeavy = 0
  var i = 0
  while i < proj.len:
    if proj[i] >= threshold:
      var j = i
      while j < proj.len and proj[j] >= threshold: inc j
      let mid = (i + j) div 2
      var upper = 0
      var lower = 0
      for k in i ..< mid: upper += proj[k].int
      for k in mid ..< j: lower += proj[k].int
      if upper.float > lower.float * asymmetryMargin: inc topHeavy
      elif lower.float > upper.float * asymmetryMargin: inc bottomHeavy
      i = j
    else:
      inc i

  # Require both a clear majority and enough voting bands: a two-line page
  # gives no reliable read on which way is up, and guessing there costs a
  # 180-degree error that OCR cannot recover from.
  let flipped = bottomHeavy > topHeavy * 2 and bottomHeavy >= 3
  if needsTurn:
    # The page reads top-to-bottom along the original columns; one clockwise
    # turn set it upright, three turns is the other handedness.
    result = if flipped: 3 else: 1
  else:
    result = if flipped: 2 else: 0

  log.debug("quadrant detected", {
    "turns": $result,
    "v_horizontal": formatFloat(horizontal.score, ffDecimal, 1),
    "v_vertical": formatFloat(vertical.score, ffDecimal, 1),
    "top_heavy": $topHeavy, "bottom_heavy": $bottomHeavy})

proc autoOrient*(img: Image): tuple[image: Image; turns: int; angle: float] =
  ## Full orientation correction: quadrant first (cheap and lossless), then
  ## fine skew. Doing it in that order matters -- a 90-degree rotated page
  ## would otherwise saturate the skew search at its bound and return garbage.
  let turns = detectQuadrant(img)
  let upright = if turns == 0: img else: img.rotateQuadrant(turns)
  let (corrected, angle) = upright.deskew()
  (corrected, turns, angle)
