## Task prompts and response schemas.
##
## Kept in one module so they can be reviewed and versioned as a unit -- prompt
## changes alter output as surely as code changes do, and burying them at their
## call sites makes that invisible.
##
## The system prompt is deliberately identical across tasks so it stays a
## cacheable prefix; the per-task instruction goes in the user turn.

import std/[json, strutils]

import ../core/types

const systemPrompt* = """
You are a vision analysis engine. You are given an image or document page,
sometimes alongside OCR text extracted from it.

Rules:
- Report only what is visibly present. Never infer values that are not shown.
- When OCR text is provided, treat it as a hint, not as ground truth: it
  contains recognition errors. Prefer what you can read in the image, and use
  the OCR text to disambiguate characters that are visually similar.
- If a region is illegible, say so explicitly rather than guessing.
- Preserve the source's own wording, spelling and numbers exactly.
- When asked for JSON, return only JSON, with no surrounding commentary.
""".strip()

type
  VisionTask* = enum
    vtDescribe = "describe"
      ## General description; the default for an unclassified image.
    vtTranscribe = "transcribe"
      ## Full text transcription preserving layout.
    vtExtractFields = "extract_fields"
      ## Structured key/value extraction from a form, receipt or invoice.
    vtDescribeDiagram = "describe_diagram"
      ## Chart, schematic or whiteboard: read the structure, not just labels.
    vtSummarize = "summarize"
    vtScreenshotAnalysis = "screenshot"
      ## UI state: what application, what screen, what is actionable.
    vtCustom = "custom"

func taskInstruction*(task: VisionTask): string =
  case task
  of vtDescribe:
    "Describe this image. Cover: what it depicts, any text that appears in " &
    "it (quoted exactly), and anything notable about its condition or " &
    "quality. Be concrete and specific."
  of vtTranscribe:
    "Transcribe all text in this image as Markdown. Preserve the reading " &
    "order, heading hierarchy, lists and tables. Render tables as GitHub " &
    "pipe tables. Do not summarise, translate or correct the source; " &
    "reproduce it. Mark anything unreadable as [illegible]."
  of vtExtractFields:
    "Extract the labelled fields from this document as JSON. Use the " &
    "document's own field labels as keys, lower-cased with underscores. " &
    "Copy values exactly as printed, including currency symbols and " &
    "formatting. Omit any field you cannot read rather than guessing it."
  of vtDescribeDiagram:
    "Describe this diagram. Identify its type, then enumerate its " &
    "components and the relationships between them (arrows, containment, " &
    "ordering). Quote every label exactly. If it is a chart, report the " &
    "axes, units and the trend or values shown."
  of vtSummarize:
    "Summarise the content of this page in a few sentences. Lead with what " &
    "the document is, then its key facts and figures."
  of vtScreenshotAnalysis:
    "Analyse this screenshot. Identify the application or website, the " &
    "screen or state shown, the visible interactive elements, and any error " &
    "or status messages. Quote on-screen text exactly."
  of vtCustom:
    ""

func defaultTaskFor*(kind: InputKind): VisionTask =
  case kind
  of ikScreenshot: vtScreenshotAnalysis
  of ikDiagram: vtDescribeDiagram
  of ikScannedDocument, ikPdf: vtTranscribe
  of ikPhoto: vtDescribe
  of ikUnknown: vtDescribe

proc withOcrContext*(instruction, ocrText: string;
                     maxChars = 12_000): string =
  ## Appends OCR output as a hint. Truncated with a visible marker rather than
  ## silently, so a downstream reader can tell the context was incomplete.
  if ocrText.strip().len == 0:
    return instruction
  var text = ocrText.strip()
  var truncated = false
  if text.len > maxChars:
    text = text[0 ..< maxChars]
    truncated = true
  result = instruction & "\n\nOCR text extracted from this image (may " &
    "contain recognition errors):\n<ocr>\n" & text
  if truncated:
    result.add "\n[... OCR text truncated ...]"
  result.add "\n</ocr>"

# ---------------------------------------------------------------------------
# Response schemas
# ---------------------------------------------------------------------------

proc fieldExtractionSchema*(): JsonNode =
  ## Schema for `vtExtractFields`. `confidence` and `notes` give the model a
  ## place to express uncertainty instead of encoding it as a wrong value.
  %*{
    "type": "object",
    "additionalProperties": false,
    "required": ["document_type", "fields"],
    "properties": {
      "document_type": {
        "type": "string",
        "description": "e.g. invoice, receipt, form, letter, id_card"},
      "fields": {
        "type": "array",
        "items": {
          "type": "object",
          "additionalProperties": false,
          "required": ["key", "value"],
          "properties": {
            "key": {"type": "string"},
            "value": {"type": "string"},
            "confidence": {
              "type": "string",
              "enum": ["high", "medium", "low"]}}}},
      "notes": {"type": "string"}}}

proc diagramSchema*(): JsonNode =
  %*{
    "type": "object",
    "additionalProperties": false,
    "required": ["diagram_type", "summary", "nodes"],
    "properties": {
      "diagram_type": {"type": "string"},
      "summary": {"type": "string"},
      "nodes": {
        "type": "array",
        "items": {
          "type": "object",
          "additionalProperties": false,
          "required": ["label"],
          "properties": {
            "label": {"type": "string"},
            "role": {"type": "string"}}}},
      "edges": {
        "type": "array",
        "items": {
          "type": "object",
          "additionalProperties": false,
          "required": ["from", "to"],
          "properties": {
            "from": {"type": "string"},
            "to": {"type": "string"},
            "label": {"type": "string"}}}}}}

proc schemaFor*(task: VisionTask): JsonNode =
  ## The schema to constrain a task's output with, or `nil` for free prose.
  case task
  of vtExtractFields: fieldExtractionSchema()
  of vtDescribeDiagram: diagramSchema()
  else: nil
