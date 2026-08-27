import std/[unittest, math, sequtils, strutils]

import ../src/v3era/core/[types, errors]
import ../src/v3era/preprocess/[ops, deskew, pipeline]
import ./helpers

suite "colour and analysis kernels":
  test "toGray uses Rec.601 weights":
    var img = newImage(2, 1, pkRgb)
    img.data = @[255'u8, 0, 0, 0, 255, 0]
    let g = img.toGray()
    check g.channels == 1
    # 0.299 * 255 = 76.2 -> 76, 0.587 * 255 = 149.7 -> 149
    check g.data[0] == 76
    check g.data[1] == 149

  test "toGray is a no-op on single-channel input":
    let g = solid(8, 8, 120)
    check g.toGray().data == g.data

  test "toChannels widens gray to RGBA with opaque alpha":
    let rgba = solid(4, 4, 90).toChannels(pkRgba)
    check rgba.channels == 4
    check rgba.data[0] == 90
    check rgba.data[3] == 255

  test "meanLuma and inkCoverage agree with hand-computed values":
    check solid(10, 10, 200).meanLuma().int == 200
    check solid(10, 10, 0).inkCoverage() == 1.0
    check solid(10, 10, 255).inkCoverage() == 0.0

  test "laplacianVariance separates flat from textured":
    let flat = solid(64, 64, 128).laplacianVariance()
    let sharp = checkerboard(64, 64, 4).laplacianVariance()
    check flat < 1.0
    check sharp > flat * 100.0

  test "contrastSpread measures ink-against-paper separation":
    # A featureless field has no two tones to separate.
    check solid(64, 64, 128).contrastSpread() < 0.05
    # A full ramp splits into two halves whose means are ~64 and ~191.
    check gradient(256, 32, pkGray).contrastSpread() > 0.4

  test "contrastSpread stays high on a sparse page and drops when washed out":
    # The case a percentile spread gets wrong: ~1% ink on white paper.
    let crisp = syntheticPage(600, 400)
    check crisp.contrastSpread() > 0.8
    # Same page, ink lifted toward the paper tone.
    var washed = crisp
    for i in 0 ..< washed.data.len:
      if washed.data[i] < 128: washed.data[i] = 170
    check washed.contrastSpread() < 0.4
    check washed.contrastSpread() < crisp.contrastSpread()

suite "thresholding":
  test "Otsu lands in the valley of a bimodal histogram":
    var img = newImage(100, 10, pkGray)
    for i in 0 ..< img.data.len:
      img.data[i] = if i mod 2 == 0: 40'u8 else: 210'u8
    # Every threshold in [40, 209] separates these two modes equally well, so
    # the implementation returns the midpoint of that plateau rather than
    # hugging either peak.
    let t = img.otsuThreshold()
    check t > 100
    check t < 150

  test "global binarisation is strictly bilevel":
    let bin = syntheticPage().binarizeGlobal()
    for v in bin.data:
      check v == 0 or v == 255

  test "invert swaps polarity":
    let g = solid(8, 8, 10)
    check g.binarizeGlobal(threshold = 128).data[0] == 0
    check g.binarizeGlobal(threshold = 128, invert = true).data[0] == 255

  test "Sauvola recovers text under a strong lighting gradient":
    # A page whose left side is lit and right side is in shadow: the ink on the
    # right is darker than the *paper* on the left, so no global threshold can
    # separate them. This is the case Sauvola exists for.
    var page = newImage(400, 200, pkGray)
    for y in 0 ..< 200:
      for x in 0 ..< 400:
        let lighting = 255 - (x * 170) div 399   # 255 down to 85
        page.data[y * 400 + x] = byte(lighting)
    for y in 40 ..< 60:
      for x in 20 ..< 380:
        let lighting = 255 - (x * 170) div 399
        page.data[y * 400 + x] = byte(lighting * 35 div 100) # ink at 35% of local paper

    let otsu = page.binarizeGlobal()
    let sauvola = page.binarizeSauvola(window = 31)

    proc inkInBand(img: Image; x0, x1: int): int =
      for y in 40 ..< 60:
        for x in x0 ..< x1:
          if img.data[y * 400 + x] < 128: inc result

    # Sauvola must find the text across the whole width.
    check sauvola.inkInBand(20, 200) > 2000
    check sauvola.inkInBand(200, 380) > 2000
    # Otsu drowns: it either loses the lit-side text or floods the shadow.
    let otsuBalanced = otsu.inkInBand(20, 200) > 2000 and
                       otsu.inkInBand(200, 380) > 2000 and
                       otsu.inkCoverage() < 0.3
    check not otsuBalanced

  test "Sauvola rejects multi-channel input":
    expect ImageError:
      discard gradient(16, 16, pkRgb).binarizeSauvola()

suite "geometry":
  test "resize to identical dimensions returns the same pixels":
    let src = syntheticPage(120, 90)
    check src.resize(120, 90).data == src.data

  test "area downscale of a flat field stays flat":
    let small = solid(200, 200, 77).resize(50, 50)
    check small.width == 50
    for v in small.data:
      check v == 77

  test "bilinear upscale preserves endpoints of a ramp":
    let up = gradient(64, 8, pkGray).resize(256, 8)
    check up.width == 256
    check up.data[0] < 6
    check up.data[255] > 249

  test "resize scales the DPI tag":
    var img = newImage(100, 100, pkGray, dpi = 150)
    check img.resize(200, 200).dpi == 300

  test "four quarter turns are an identity":
    let src = syntheticPage(80, 60)
    var r = src
    for _ in 0 ..< 4:
      r = r.rotateQuadrant(1)
    check r.width == src.width
    check r.height == src.height
    check r.data == src.data

  test "a single quarter turn swaps the axes and moves the corner":
    var img = newImage(3, 2, pkGray)
    img.data = @[1'u8, 2, 3,
                 4, 5, 6]
    let r = img.rotateQuadrant(1)
    check (r.width, r.height) == (2, 3)
    # 90 CW: the bottom-left of the source becomes the top-left.
    check r.data == @[4'u8, 1,
                      5, 2,
                      6, 3]

  test "rotation by zero degrees is a no-op":
    let src = syntheticPage(64, 64)
    check src.rotate(0.0).data == src.data

  test "expanding rotation grows the canvas and keeps the ink":
    let src = syntheticPage(200, 150)
    let rot = src.rotate(30.0, expand = true)
    check rot.width > src.width
    check rot.height > src.height
    # Ink is conserved to within resampling softness at the stroke edges.
    let before = src.countInk()
    let after = rot.countInk()
    check after.float > before.float * 0.85
    check after.float < before.float * 1.25

  test "round-tripping a rotation returns close to the original":
    let src = syntheticPage(200, 150)
    let there = src.rotate(7.0, expand = false)
    let back = there.rotate(-7.0, expand = false)
    check meanAbsDiff(src, back) < 40.0

  test "crop extracts the requested window":
    let src = gradient(100, 20, pkGray)
    let c = src.crop(bbox(10, 5, 30, 10))
    check (c.width, c.height) == (30, 10)
    check c.data[0] == src.at(10, 5, 0)

  test "crop clips to the image and rejects a disjoint rectangle":
    let src = solid(50, 50, 10)
    check src.crop(bbox(40, 40, 100, 100)).width == 10
    expect ImageError:
      discard src.crop(bbox(200, 200, 10, 10))

  test "pad adds a uniform border without moving the content":
    let src = syntheticPage(100, 80)
    let p = src.pad(10, 255)
    check (p.width, p.height) == (120, 100)
    check p.at(0, 0, 0) == 255
    check p.at(15, 15, 0) == src.at(5, 5, 0)

  test "fitWithin never upscales":
    let src = solid(100, 50, 0)
    check src.fitWithin(400, 400).width == 100

  test "fitLongestSide preserves the aspect ratio":
    let r = solid(800, 400, 0).fitLongestSide(200)
    check r.width == 200
    check r.height == 100

suite "filters":
  test "box blur of a flat field is that flat field":
    let b = solid(40, 40, 90).boxBlur(3)
    for v in b.data:
      check v == 90

  test "box blur reduces high-frequency energy":
    let sharp = checkerboard(64, 64, 2)
    check sharp.boxBlur(2).laplacianVariance() < sharp.laplacianVariance()

  test "median3 removes isolated speckle but keeps edges":
    var img = solid(32, 32, 255)
    img.data[10 * 32 + 10] = 0 # single black pixel
    let m = img.median3()
    check m.at(10, 10, 0) == 255

    let edge = checkerboard(32, 32, 8)
    check meanAbsDiff(edge, edge.median3()) < 20.0

  test "unsharp increases local contrast":
    let soft = checkerboard(64, 64, 6).boxBlur(2)
    check soft.unsharp(radius = 2, amount = 1.2).laplacianVariance() >
          soft.laplacianVariance()

  test "autocontrast stretches a compressed range":
    var img = newImage(64, 64, pkGray)
    for i in 0 ..< img.data.len:
      img.data[i] = byte(100 + (i mod 40))
    let a = img.autocontrast(0.0, 0.0)
    var lo = 255
    var hi = 0
    for v in a.data:
      lo = min(lo, v.int)
      hi = max(hi, v.int)
    check lo < 10
    check hi > 245

suite "skew estimation":
  test "an upright page reports no skew":
    let est = syntheticPage(600, 450).estimateSkew()
    check abs(est.angle) < 0.3

  test "a known rotation is recovered to within a quarter degree":
    for truth in [-6.0, -2.5, 1.5, 4.0]:
      let page = syntheticPage(700, 520).rotate(truth, expand = true)
      let est = page.estimateSkew()
      check abs(est.angle - truth) < 0.25

  test "deskew leaves a near-level page alone":
    let page = syntheticPage(400, 300)
    let (_, angle) = page.deskew()
    check angle == 0.0

  test "deskew corrects a tilted page":
    let page = syntheticPage(700, 520).rotate(5.0, expand = true)
    let (fixed, angle) = page.deskew()
    check abs(angle - 5.0) < 0.3
    check abs(fixed.estimateSkew().angle) < 0.5

  test "a blank page produces no skew estimate and no rotation":
    let blank = solid(200, 200, 255)
    check blank.estimateSkew().angle == 0.0
    check blank.deskew().angle == 0.0

  test "quadrant detection recovers every 90-degree orientation":
    # Descenders give the page a genuine up/down asymmetry; without one, no
    # algorithm can tell upright from upside-down.
    let page = syntheticPage(600, 450, descenders = true)
    for applied in 0 .. 3:
      let rotated = page.rotateQuadrant(applied)
      # Undoing `applied` clockwise turns takes (4 - applied) mod 4 more.
      check rotated.detectQuadrant() == (4 - applied) mod 4

  test "quadrant detection abstains on a symmetric page":
    # Solid bars carry no up/down cue. Reporting 'upright' is the safe answer;
    # inventing a 180-degree flip would be unrecoverable.
    let page = syntheticPage(600, 450)
    check page.detectQuadrant() == 0

  test "autoOrient restores a rotated and skewed page":
    let page = syntheticPage(600, 460, descenders = true)
    let mangled = page.rotateQuadrant(1).rotate(3.0, expand = true)
    let (fixed, turns, angle) = mangled.autoOrient()
    check turns == 3
    check abs(angle - 3.0) < 0.6
    check fixed.width > fixed.height # landscape again

suite "pipeline profiles":
  test "the document profile binarises and pads":
    let (out1, rep) = syntheticPage(800, 600).preprocess(documentProfile())
    check "binarize:sauvola" in rep.applied
    check out1.channels == 1
    check out1.width >= 800
    for v in out1.data:
      check v == 0 or v == 255

  test "the screenshot profile never binarises":
    let src = gradient(400, 300, pkRgb)
    let (out1, rep) = src.preprocess(screenshotProfile())
    check rep.applied.allIt(not it.startsWith("binarize"))
    var distinct1: set[uint8]
    for v in out1.data:
      distinct1.incl v
    check distinct1.card > 2 # grey levels survived

  test "the screenshot profile upscales small captures up to the cap":
    # minDimension asks for 1600 from a 300px source, which is 5.3x; maxUpscale
    # caps that at 4x, so the longest side lands at 1200 plus the padding.
    let cfg = screenshotProfile()
    let (out1, _) = solid(300, 200, 128).preprocess(cfg)
    check max(out1.width, out1.height) == int(300.0 * cfg.maxUpscale) +
                                          2 * cfg.padMargin

  test "minDimension is reached when it fits under maxUpscale":
    let (out1, _) = solid(500, 400, 128).preprocess(screenshotProfile())
    check max(out1.width, out1.height) >= 1600

  test "the VLM profile caps the longest side and keeps colour":
    let (out1, _) = gradient(4000, 2000, pkRgb).preprocess(vlmProfile(1568))
    check out1.width == 1568
    check out1.channels == 3

  test "maxDimension is enforced":
    let (out1, _) = solid(9000, 100, 0).preprocess(defaultConfig())
    check out1.width <= 4000 + 2 * defaultConfig().padMargin

  test "an empty image passes through without raising":
    let (out1, rep) = Image().preprocess(defaultConfig())
    check out1.isEmpty
    check rep.quality.isBlank

  test "profileFor maps every input kind":
    for k in InputKind:
      discard profileFor(k)

  test "quality flags a blank page and clears a printed one":
    check solid(300, 300, 255).measureQuality().isBlank
    check not syntheticPage(400, 300).measureQuality().isBlank

  test "the preprocess report records the geometry it changed":
    let src = syntheticPage(500, 400).rotate(4.0, expand = true)
    let (_, rep) = src.preprocess(documentProfile())
    check rep.inputWidth == src.width
    check rep.outputWidth > 0
    check abs(rep.deskewAngle - 4.0) < 0.5
