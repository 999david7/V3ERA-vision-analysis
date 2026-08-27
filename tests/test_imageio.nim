import std/[unittest, os, strutils]

import ../src/v3era/core/[types, errors]
import ../src/v3era/imageio/[sniff, netpbm, io, stbimage]
import ./helpers

suite "format sniffing":
  test "recognises the containers we care about":
    check detectFormat("\x89PNG\r\n\x1a\n....") == sfPng
    check detectFormat("\xFF\xD8\xFF\xE0....") == sfJpeg
    check detectFormat("%PDF-1.7\n") == sfPdf
    check detectFormat("BM\x36\x00\x00\x00...") == sfBmp
    check detectFormat("GIF89a...") == sfGif
    check detectFormat("RIFF\x00\x00\x00\x00WEBPVP8 ") == sfWebp
    check detectFormat("II\x2A\x00rest") == sfTiff
    check detectFormat("MM\x00\x2Arest") == sfTiff
    check detectFormat("P5\n2 2\n255\n") == sfPnm

  test "refuses to guess on unrecognised or truncated input":
    check detectFormat("not an image at all") == sfUnknown
    check detectFormat("ab") == sfUnknown
    check detectFormat("") == sfUnknown

  test "extension mapping is only a fallback":
    check formatFromExtension("a/b/c.PNG") == sfPng
    check formatFromExtension("scan.tiff") == sfTiff
    check formatFromExtension("noextension") == sfUnknown

  test "media types match what the API expects":
    check sfPng.mediaType == "image/png"
    check sfJpeg.mediaType == "image/jpeg"
    check sfPdf.mediaType == "application/pdf"

suite "netpbm codec":
  test "P5 round-trips a grayscale image exactly":
    let src = syntheticPage(64, 48)
    let decoded = decodePnm(toOpenArrayByte(src.encodePnm(), 0,
                                            src.encodePnm().high))
    check decoded.width == src.width
    check decoded.height == src.height
    check decoded.channels == 1
    check decoded.data == src.data

  test "P6 round-trips an RGB image exactly":
    let src = gradient(32, 16, pkRgb)
    let encoded = src.encodePnm()
    check encoded.startsWith("P6")
    let decoded = decodePnm(toOpenArrayByte(encoded, 0, encoded.high))
    check decoded.channels == 3
    check decoded.data == src.data

  test "encoding drops alpha rather than compositing it":
    let src = solid(4, 4, 200, pkRgba)
    let decoded = decodePnm(toOpenArrayByte(src.encodePnm(), 0,
                                            src.encodePnm().high))
    check decoded.channels == 3
    check decoded.data[0] == 200

  test "reads ASCII P2 with comments in the header":
    let text = "P2\n# a comment\n3 2\n255\n0 128 255\n255 128 0\n"
    let img = decodePnm(toOpenArrayByte(text, 0, text.high))
    check (img.width, img.height) == (3, 2)
    check img.data == @[0'u8, 128, 255, 255, 128, 0]

  test "reads P1 bitmaps with 1 meaning black":
    let text = "P1\n2 2\n1 0\n0 1\n"
    let img = decodePnm(toOpenArrayByte(text, 0, text.high))
    check img.data == @[0'u8, 255, 255, 0]

  test "rescales a non-255 maxval":
    let text = "P2\n2 1\n15\n0 15\n"
    let img = decodePnm(toOpenArrayByte(text, 0, text.high))
    check img.data == @[0'u8, 255]

  test "rejects a truncated raster instead of reading past the end":
    let short = "P5\n10 10\n255\nonly-a-few-bytes"
    expect UnsupportedFormatError:
      discard decodePnm(toOpenArrayByte(short, 0, short.high))

  test "rejects P7/PAM, which is not implemented":
    let pam = "P7\nWIDTH 1\n"
    expect UnsupportedFormatError:
      discard decodePnm(toOpenArrayByte(pam, 0, pam.high))

suite "bmp codec":
  test "24-bit round-trip preserves RGB":
    let src = gradient(31, 7, pkRgb) # odd width exercises row padding
    let encoded = src.encodeBmp()
    let decoded = decodeBmp(toOpenArrayByte(encoded, 0, encoded.high))
    check (decoded.width, decoded.height) == (src.width, src.height)
    check decoded.channels == 3
    check decoded.data == src.data

  test "grayscale is widened to RGB on encode":
    let src = syntheticPage(40, 30)
    let encoded = src.encodeBmp()
    let decoded = decodeBmp(toOpenArrayByte(encoded, 0, encoded.high))
    check decoded.channels == 3
    for i in 0 ..< src.data.len:
      check decoded.data[i * 3] == src.data[i]

  test "rejects a non-BMP stream":
    expect UnsupportedFormatError:
      discard decodeBmp(toOpenArrayByte("not a bmp at all, really truly not!!",
                                        0, 35))

  test "rejects a compressed BMP rather than producing garbage":
    var encoded = gradient(8, 8, pkRgb).encodeBmp()
    encoded[30] = char(1) # BI_RLE8
    expect UnsupportedFormatError:
      discard decodeBmp(toOpenArrayByte(encoded, 0, encoded.high))

suite "io facade":
  test "decodeImage routes by content, not by any supplied name":
    let pnm = syntheticPage(20, 20).encodePnm()
    check decodeImage(pnm).width == 20
    let bmp = syntheticPage(20, 20).encodeBmp()
    check decodeImage(bmp).width == 20

  test "an empty buffer is rejected":
    expect UnsupportedFormatError:
      discard decodeImage("")

  test "a PDF is refused by the image decoder with a pointed message":
    expect UnsupportedFormatError:
      discard decodeImage("%PDF-1.4\nrest")

  test "unrecognised bytes name what they were":
    try:
      discard decodeImage("this is definitely not an image file")
      check false
    except UnsupportedFormatError as e:
      check "unrecognised" in e.msg

  test "load and save round-trip through the filesystem":
    let dir = getTempDir() / "v3era-test-io"
    createDir(dir)
    defer:
      try: removeDir(dir) except OSError: discard
    let path = dir / "page.pnm"
    let src = syntheticPage(48, 32)
    src.saveImage(path)
    check fileExists(path)
    let loaded = loadImage(path)
    check loaded.data == src.data

  test "loading a missing file gives a clear error":
    expect ImageError:
      discard loadImage("/nonexistent/definitely-not-here.png")

  test "the build reports which formats it can decode":
    let formats = decodableFormats()
    check sfPnm in formats
    check sfBmp in formats
    when stbAvailable:
      check sfPng in formats
      check sfJpeg in formats
    else:
      check sfPng notin formats

  test "PNG encoding either works or explains how to enable it":
    let src = syntheticPage(32, 24)
    when stbAvailable:
      let png = encodeImage(src, sfPng)
      check png.len > 0
      check detectFormat(png) == sfPng
      let back = decodeImage(png)
      check (back.width, back.height) == (src.width, src.height)
      check back.data == src.data # PNG is lossless
    else:
      expect CapabilityError:
        discard encodeImage(src, sfPng)

  test "bestEncodableFormat picks something this build can produce":
    let fmt = gradient(2000, 1500, pkRgb).bestEncodableFormat()
    when stbAvailable:
      check fmt == sfJpeg # large colour image -> lossy is the right call
      check syntheticPage(100, 100).bestEncodableFormat() == sfPng
    else:
      check fmt == sfPnm

when stbAvailable:
  suite "stb backend":
    test "JPEG round-trips approximately":
      let src = gradient(64, 64, pkRgb)
      let jpg = encodeImage(src, sfJpeg, quality = 95)
      check detectFormat(jpg) == sfJpeg
      let back = decodeImage(jpg)
      check (back.width, back.height) == (64, 64)
      check meanAbsDiff(src, back) < 8.0

    test "probing reads dimensions without decoding the raster":
      let png = encodeImage(syntheticPage(70, 50), sfPng)
      let (w, h, _) = stbProbe(toOpenArrayByte(png, 0, png.high))
      check (w, h) == (70, 50)

    test "a corrupt stream is reported, not crashed on":
      var png = encodeImage(syntheticPage(32, 32), sfPng)
      # Corrupt the compressed data, leaving the signature intact.
      for i in 40 ..< min(png.len, 200):
        png[i] = char(0xFF)
      expect UnsupportedFormatError:
        discard decodeImage(png)
