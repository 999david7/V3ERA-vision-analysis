## The single entry point for turning bytes into an `Image` and back.
##
## Decode order:
##   1. PNM and uncompressed BMP go to the native Nim codecs -- always present.
##   2. Everything else goes to stb_image when the build has it (`-d:v3eraStb`).
##   3. Failing that, an external converter named by `V3ERA_IMAGE_CONVERT` is
##      invoked to transcode to PNM on stdout. This is the production escape
##      hatch for TIFF, WebP and CMYK JPEG, which stb does not handle.
##
## Step 3 keeps the common deployment (`vips`/ImageMagick already installed)
## working without adding a link-time dependency, and it is opt-in, so nothing
## is executed unless an operator configured it.

import std/[os, osproc, streams, strutils, times]

import ../core/[types, errors, log]
import ./sniff, ./netpbm, ./stbimage

export sniff

const
  convertEnvVar* = "V3ERA_IMAGE_CONVERT"
    ## Command template for the fallback converter. `{in}` is replaced with a
    ## temporary input path; the command must write PNM to stdout. Example:
    ##   export V3ERA_IMAGE_CONVERT='magick {in} pnm:-'
    ##   export V3ERA_IMAGE_CONVERT='vips pnmsave {in} .pnm'
  maxDecodeBytes* = 256 * 1024 * 1024
    ## Refuse to even look at inputs larger than this.

func nativeFormats*(): set[SourceFormat] = {sfPnm, sfBmp}

func decodableFormats*(): set[SourceFormat] =
  ## Formats this *build* can decode without an external helper.
  result = nativeFormats()
  when stbAvailable:
    result = result + {sfPng, sfJpeg, sfGif}

proc runConverter(data: openArray[byte]; format: SourceFormat): Image =
  let tmpl = getEnv(convertEnvVar, "")
  if tmpl.len == 0:
    raise newCapabilityError("image-decoder",
      "no decoder for " & $format & " in this build. Either rebuild with " &
      "-d:v3eraStb (after scripts/fetch_vendor.sh), or set " & convertEnvVar &
      " to a command that writes PNM to stdout, e.g. " &
      "'magick {in} pnm:-'")

  let tmp = getTempDir() / "v3era-" & $getCurrentProcessId() & "-" &
    $epochTime().int64 & "." & $format
  writeFile(tmp, cast[string](@data))
  defer: discard tryRemoveFile(tmp)

  let cmd = tmpl.replace("{in}", quoteShell(tmp))
  log.debug("invoking external image converter", {"cmd": cmd})
  let p = startProcess(cmd, options = {poEvalCommand, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    raise newCapabilityError("image-decoder",
      convertEnvVar & " exited with status " & $code & ": " &
      output[0 ..< min(output.len, 400)])
  if output.len == 0:
    raise newCapabilityError("image-decoder",
      convertEnvVar & " produced no output")
  decodePnm(toOpenArrayByte(output, 0, output.high))

proc decodeImage*(data: openArray[byte]; format = sfUnknown): Image =
  ## Decodes an in-memory image. `format` may be supplied when it is already
  ## known; otherwise it is sniffed from the magic bytes.
  if data.len == 0:
    raiseUnsupported("empty image buffer")
  if data.len > maxDecodeBytes:
    raiseImage("input of " & $data.len & " bytes exceeds the " &
      $(maxDecodeBytes div (1024 * 1024)) & " MiB decode limit")

  let fmt = if format != sfUnknown: format else: detectFormat(data)
  case fmt
  of sfPnm: return decodePnm(data)
  of sfBmp: return decodeBmp(data)
  of sfPdf:
    raiseUnsupported("PDF is a document container; use docparse/pdf.nim")
  of sfUnknown:
    raiseUnsupported("unrecognised image container (first bytes: " &
      toHex(cast[string](@data)[0 ..< min(8, data.len)]) & ")")
  else:
    when stbAvailable:
      if fmt in {sfPng, sfJpeg, sfGif}:
        return stbDecode(data)
    return runConverter(data, fmt)

proc decodeImage*(data: string; format = sfUnknown): Image =
  decodeImage(toOpenArrayByte(data, 0, data.high), format)

proc loadImage*(path: string): Image =
  ## Reads and decodes a file, routing on content rather than extension.
  if not fileExists(path):
    raiseImage("no such file: " & path)
  let size = getFileSize(path)
  if size > maxDecodeBytes:
    raiseImage("file " & path & " is " & $size & " bytes, over the decode limit")
  let raw = readFile(path)
  try:
    result = decodeImage(raw)
  except UnsupportedFormatError as e:
    # Add the path; the sniffer only ever sees an anonymous buffer.
    raiseUnsupported(path & ": " & e.msg)

proc encodeImage*(img: Image; format: SourceFormat; quality = 88): string =
  ## Serialises an image. PNM and BMP always work; PNG and JPEG need stb.
  case format
  of sfPnm: encodePnm(img)
  of sfBmp: encodeBmp(img)
  of sfPng:
    when stbAvailable: stbEncodePng(img)
    else:
      raise newCapabilityError("stb_image",
        "PNG encoding requires -d:v3eraStb; write PNM or BMP instead")
  of sfJpeg:
    when stbAvailable:
      # Reduce channel counts stb's JPEG writer rejects.
      if img.channels in {1, 3}: stbEncodeJpeg(img, quality)
      else:
        var reduced = newImage(img.width, img.height,
                               if img.channels == 2: pkGray else: pkRgb)
        let outCh = reduced.channels
        for i in 0 ..< img.width * img.height:
          for c in 0 ..< outCh:
            reduced.data[i * outCh + c] = img.data[i * img.channels + c]
        stbEncodeJpeg(reduced, quality)
    else:
      raise newCapabilityError("stb_image",
        "JPEG encoding requires -d:v3eraStb; write PNM or BMP instead")
  else:
    raiseUnsupported("cannot encode to " & $format)

proc saveImage*(img: Image; path: string; quality = 88) =
  ## Writes an image, choosing the codec from the path's extension.
  var fmt = formatFromExtension(path)
  if fmt == sfUnknown: fmt = sfPnm
  writeFile(path, encodeImage(img, fmt, quality))

proc bestEncodableFormat*(img: Image): SourceFormat =
  ## The most widely accepted format this build can actually produce. Used when
  ## handing an image to a VLM, which accepts PNG/JPEG but not PNM.
  when stbAvailable:
    # Photos compress far better as JPEG; keep line art and text lossless.
    if img.channels >= 3 and img.megapixels > 1.0: sfJpeg else: sfPng
  else:
    sfPnm
