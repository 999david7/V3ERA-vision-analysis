## Error hierarchy for the whole system.
##
## Every failure that crosses a subsystem boundary is one of these, so callers
## can decide policy (retry, degrade, abort) without string-matching messages.
## `CapabilityError` is the important one: it means an optional native
## dependency is missing at runtime, and the pipeline is expected to degrade
## rather than crash.

type
  V3eraError* = object of CatchableError ## Root of every error this library raises.

  ImageError* = object of V3eraError
    ## Decoding, encoding or geometry failure on raster data.

  UnsupportedFormatError* = object of ImageError
    ## The byte stream is not a container this build can decode.

  CapabilityError* = object of V3eraError
    ## An optional capability (Tesseract, poppler, a VLM key) is unavailable.
    ## Recoverable by definition: the caller should skip the stage, not abort.
    capability*: string

  OcrError* = object of V3eraError
    ## The OCR engine was present but failed on this input.

  DocumentError* = object of V3eraError
    ## Document container (PDF) could not be read or rendered.

  VlmError* = object of V3eraError
    ## Vision-language model call failed.
    status*: int      ## HTTP status, or 0 for transport-level failures.
    retryable*: bool  ## Whether a retry with backoff could plausibly succeed.

  ConfigError* = object of V3eraError
    ## Invalid or missing configuration.

proc newCapabilityError*(capability, msg: string): ref CapabilityError =
  ## Raised when an optional native dependency is not installed.
  result = newException(CapabilityError, msg)
  result.capability = capability

proc newVlmError*(msg: string; status = 0; retryable = false): ref VlmError =
  result = newException(VlmError, msg)
  result.status = status
  result.retryable = retryable

template raiseImage*(msg: string) =
  raise newException(ImageError, msg)

template raiseUnsupported*(msg: string) =
  raise newException(UnsupportedFormatError, msg)

template raiseDocument*(msg: string) =
  raise newException(DocumentError, msg)

template raiseConfig*(msg: string) =
  raise newException(ConfigError, msg)
