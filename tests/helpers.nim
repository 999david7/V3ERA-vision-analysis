## Shared fixtures: synthetic pages that exercise the geometry and OCR paths
## without shipping binary test assets.

import std/[math, random]

import ../src/v3era/core/types
import ../src/v3era/preprocess/ops

proc fillRect*(img: var Image; box: BBox; value: byte) =
  let b = box.clampTo(img.width, img.height)
  for y in b.y ..< b.bottom:
    for x in b.x ..< b.right:
      let p = img.idx(x, y)
      for c in 0 ..< img.channels:
        img.data[p + c] = value

proc syntheticPage*(width = 640; height = 480; lines = 12; lineHeight = 14;
                    leading = 24; margin = 60; descenders = false): Image =
  ## A page of horizontal "text" bars. The row projection has exactly `lines`
  ## sharp peaks, which is what the deskew search keys on.
  ##
  ## With `descenders`, each band is drawn as a full-width body plus a sparse
  ## tail below it, mimicking how Latin script puts far more ink above the
  ## baseline than below. Orientation detection needs that asymmetry: a page of
  ## perfectly symmetric bars carries no information about which way is up.
  result = newImage(width, height, pkGray)
  for i in 0 ..< result.data.len:
    result.data[i] = 255

  var y = margin
  var rng = initRand(0x5EED)
  for i in 0 ..< lines:
    if y + lineHeight >= height - margin: break
    # Ragged right edge, like real text.
    let w = max(20, width - 2 * margin - rng.rand(0 .. (width div 5)))
    if descenders:
      let bodyH = max(2, (lineHeight * 2) div 3)
      fillRect(result, bbox(margin, y, w, bodyH), 0'u8)
      # A few short descender stubs under the body, ~15% of the line's ink.
      let tailH = lineHeight - bodyH
      if tailH > 0:
        var x = margin + 8
        while x < margin + w - 8:
          fillRect(result, bbox(x, y + bodyH, 3, tailH), 0'u8)
          x += 40
    else:
      fillRect(result, bbox(margin, y, w, lineHeight), 0'u8)
    y += leading

proc checkerboard*(width, height, cell: int): Image =
  result = newImage(width, height, pkGray)
  for y in 0 ..< height:
    for x in 0 ..< width:
      result.data[y * width + x] =
        if ((x div cell) + (y div cell)) mod 2 == 0: 0'u8 else: 255'u8

proc gradient*(width, height: int; kind = pkRgb): Image =
  result = newImage(width, height, kind)
  let ch = ord(kind)
  for y in 0 ..< height:
    for x in 0 ..< width:
      let p = (y * width + x) * ch
      for c in 0 ..< ch:
        result.data[p + c] = byte((x * 255) div max(1, width - 1))

proc solid*(width, height: int; value: byte; kind = pkGray): Image =
  result = newImage(width, height, kind)
  for i in 0 ..< result.data.len:
    result.data[i] = value

proc meanAbsDiff*(a, b: Image): float =
  ## Mean absolute per-byte difference; the images must have equal geometry.
  doAssert a.width == b.width and a.height == b.height
  doAssert a.channels == b.channels
  if a.data.len == 0: return 0.0
  var acc = 0.0
  for i in 0 ..< a.data.len:
    acc += abs(a.data[i].float - b.data[i].float)
  acc / a.data.len.float

proc countInk*(img: Image): int =
  for v in img.data:
    if v < 128: inc result
