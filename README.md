# V3ERA — Vision Analysis

A modular vision AI system in Nim. It takes screenshots, photos, diagrams,
scanned documents and PDFs, and returns structured text and analysis through
image preprocessing, OCR, document parsing and a multimodal vision-language
model.

```
$ v3era analyze invoice.pdf --format markdown
$ v3era ocr receipt.jpg --lang eng
$ v3era analyze whiteboard.png --vlm --task describe_diagram --pretty
$ v3erad --port 8080 --workers 4
```

Nim carries the pipeline, the type model and the service. C does the inner
loops and the bindings: a hand-written kernel unit for the image operations,
`stb_image` for codecs, and Tesseract's C API for recognition.

---

## Contents

- [Why this shape](#why-this-shape)
- [Architecture](#architecture)
- [Project structure](#project-structure)
- [Dependencies](#dependencies)
- [Setup](#setup)
- [Command-line use](#command-line-use)
- [HTTP service](#http-service)
- [Library use](#library-use)
- [Configuration](#configuration)
- [How the pipeline decides things](#how-the-pipeline-decides-things)
- [Performance](#performance)
- [Testing](#testing)
- [Deployment](#deployment)
- [Limitations](#limitations)

---

## Why this shape

Three decisions drive everything else.

**Optional dependencies are resolved at runtime, not at link time.**
`libtesseract` is opened with `dlopen` on first use; poppler is executed as a
subprocess; the model backend is an HTTP call. Nothing is linked. A build with
none of them installed still compiles, still runs, and still reads a digital
PDF — it just reports what it could not do. The alternative, linking
Tesseract, means every deployment carries a 40 MB dependency it may never call.

**Every optional stage degrades to a warning.** Missing engine, blank page,
unconfigured model, unreadable page — each adds a string to
`AnalysisResult.warnings` and the remaining stages still run. Only an input
that cannot be decoded at all raises. This is what lets a ten-thousand-page
batch survive page 4,000 being corrupt.

**The input kind selects the treatment, and getting it wrong is expensive.**
A scan wants deskewing, upscaling toward 300 DPI and adaptive binarisation. A
screenshot wants none of that — its text is anti-aliased at a small point
size, and thresholding turns those grey edge pixels into ragged noise. So an
explicit classifier runs first, reports the evidence behind its verdict, and
abstains rather than guessing.

---

## Architecture

```
  bytes ──► sniff ──► decode ──────────────────────────────┐
            (magic)   (netpbm/bmp native, stb for the rest) │
                                                            ▼
                                                    ┌───────────────┐
                                                    │   classify    │
                                                    │ screenshot?   │
                                                    │ photo?        │
                                                    │ diagram?      │
                                                    │ document?     │
                                                    └───────┬───────┘
                                                            │ picks a profile
                                                            ▼
  ┌──────────────────────── preprocess ─────────────────────────────┐
  │  denoise → grayscale → autocontrast → orient → scale →          │
  │  sharpen → binarise → pad          (all C kernels)              │
  │                                                                 │
  │  orient = quadrant detection (lossless) then skew correction    │
  │           by projection-profile variance                        │
  └────────────────────────────────┬────────────────────────────────┘
                                   ▼
                        ┌──────────────────────┐
                        │  OCR (Tesseract C)   │  words + boxes + confidence
                        └──────────┬───────────┘
                                   ▼
                        ┌──────────────────────┐
                        │  layout analysis     │  reading order, columns,
                        │                      │  headings, lists, tables
                        └──────────┬───────────┘
                                   ▼
                        ┌──────────────────────┐
                        │  VLM (optional)      │  image + OCR text as a hint
                        │  Anthropic or any    │  → prose or schema-constrained
                        │  OpenAI-compatible   │    JSON
                        └──────────┬───────────┘
                                   ▼
                            AnalysisResult
                     (text, structure, quality, timings, warnings)
```

PDFs take a shortcut. A PDF is two documents in one — a text layer and a set
of rasterisable pages — so the planner extracts the text layer first and sends
**only the pages without one** to render-and-OCR. A digital PDF is read in
milliseconds; a scanned annex inside the same file still gets OCRed. The
decision is per page, because mixed documents are the normal case.

### Module graph

```
core/          types, errors, structured logging     (no dependencies)
  ├── imageio/     sniff, netpbm, stbimage, io
  ├── preprocess/  ops (C kernels), deskew, pipeline
  ├── ocr/         tesseract (dlopen'd C API)
  ├── docparse/    pdf (poppler/mupdf subprocess), layout
  ├── vlm/         client, anthropic, openai, prompts
  ├── util/        exec (subprocess with timeout)
  └── pipeline/    classify, analyze  ← the only module that knows about all of them
```

Every layer depends only on `core/`. `pipeline/analyze` is the single place
that composes them, so any layer can be used alone or replaced.

---

## Project structure

```
v3era-vision-analysis/
├── README.md              LICENSE            Makefile
├── v3era.nimble           config.nims        .gitignore
│
├── csrc/                             C sources, compiled by Nim directly
│   ├── v3era_imgops.h  v3era_imgops.c        scalar image kernels
│   └── v3era_stb.c                           stb implementation unit
│
├── src/
│   ├── v3era.nim                     library facade + capability probe
│   ├── v3era_cli.nim                 the `v3era` binary
│   ├── v3era_server.nim              the `v3erad` binary
│   └── v3era/
│       ├── core/       types.nim  errors.nim  log.nim
│       ├── imageio/    sniff.nim  netpbm.nim  stbimage.nim  io.nim
│       ├── preprocess/ ops.nim  deskew.nim  pipeline.nim
│       ├── ocr/        tesseract.nim
│       ├── docparse/   pdf.nim  layout.nim
│       ├── vlm/        client.nim  anthropic.nim  openai.nim  prompts.nim
│       ├── pipeline/   classify.nim  analyze.nim
│       └── util/       exec.nim
│
├── tests/                            201 cases, no binary fixtures
│   ├── helpers.nim                   synthetic page/photo/UI generators
│   ├── pdfgen.nim                    builds valid PDFs in memory
│   └── test_{preprocess,imageio,layout,vlm,pdf,pipeline,all}.nim
│
├── examples/    extract_receipt.nim  batch_ocr.nim
├── scripts/     setup.sh  fetch_vendor.sh
├── docker/      Dockerfile
└── .github/workflows/ci.yml
```

The test suite ships **no binary fixtures**. Pages, screenshots, photographs
and line art are generated procedurally in `tests/helpers.nim`, and
`tests/pdfgen.nim` writes structurally valid PDFs — real cross-reference
tables, real base-14 font references — from source. Every byte of test input
is readable in the repository.

---

## Dependencies

### Required

| | |
|---|---|
| **Nim ≥ 2.0** | Uses ORC and Nim 2 stdlib. Debian's `nim` package is 1.6 and will not work — install via [choosenim](https://github.com/dom96/choosenim). |
| **A C compiler** | gcc or clang. Nim compiles through C, and the kernels in `csrc/` come with it. |

There are **no Nimble package dependencies.** Everything outside the standard
library is either vendored C or an optional native tool.

### Optional

Each one enables a stage. Absent, that stage reports a warning and the rest
still runs.

| Dependency | Enables | Install |
|---|---|---|
| `libtesseract` ≥ 4 + language data | OCR | `apt install libtesseract-dev tesseract-ocr-eng` · `brew install tesseract` |
| `poppler-utils` | PDF render + text layer | `apt install poppler-utils` · `brew install poppler` |
| `mupdf-tools` | PDF fallback backend | `apt install mupdf-tools` |
| `stb_image` headers | PNG, JPEG, GIF codecs | `make vendor` (pinned commit, SHA-256 verified) |

Without the stb headers the build still decodes **PNM and BMP** natively in
pure Nim, which is enough for the whole test suite and for the PDF path
(poppler renders to PGM). Add `-d:v3eraStb` for everything else.

`ANTHROPIC_API_KEY` (or any OpenAI-compatible endpoint) enables the VLM stage.

Check what a given machine actually has:

```
$ v3era --version
V3ERA 0.1.0
  image decode : png, jpeg, gif, bmp, pnm (stb_image enabled)
  ocr          : tesseract 5.3.4
  pdf          : pdftoppm, pdftotext, pdfinfo
  vlm          : anthropic / claude-opus-5
```

---

## Setup

### Quick

```sh
git clone <repo> && cd v3era-vision-analysis
sh scripts/setup.sh          # installs deps, vendors stb, builds, tests
```

### Manual

```sh
# 1. Nim 2.x
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
export PATH="$HOME/.nimble/bin:$PATH"

# 2. Optional native dependencies
sudo apt install -y libtesseract-dev tesseract-ocr-eng poppler-utils

# 3. Vendored C headers for PNG/JPEG (pinned + digest-verified)
make vendor

# 4. Build and test
make release STB=1
make test-stb
```

Binaries land in `bin/`: `v3era` (CLI) and `v3erad` (HTTP service).

### Docker

```sh
docker build -t v3era -f docker/Dockerfile .
docker run --rm -p 8080:8080 -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" v3era
```

The image builds with the full toolchain, runs the test suite as a build step,
and ships a slim runtime with only `libtesseract5`, the English language data
and `poppler-utils` — running unprivileged as uid 10001.

### Adding OCR languages

```sh
sudo apt install tesseract-ocr-deu tesseract-ocr-fra
v3era ocr page.png --lang deu
v3era ocr page.png --lang eng+fra        # several at once
```

---

## Command-line use

```
v3era <command> [options] <input>...

  analyze      full pipeline: classify, preprocess, OCR, optional VLM
  ocr          OCR only; prints recognised text
  text         extract text, preferring a PDF's own text layer
  classify     report the detected input kind and the evidence for it
  preprocess   write the preprocessed image (for tuning and debugging)
  info         container, geometry and quality metrics
  capabilities what this build and host can do
```

```sh
# A scanned PDF to Markdown, tables and headings preserved
v3era analyze scan.pdf --format markdown

# Just the text, using the PDF's text layer where it has one
v3era text report.pdf

# Structured JSON with per-word boxes and confidences
v3era analyze page.png --format json --boxes --pretty

# Why did it choose that profile?
v3era classify screenshot.png
#   screenshot.png: screenshot  (confidence 0.98 -- flat colour runs, small
#                                palette, coloured chrome at the edges)
#     flat_runs=0.812 unique_colors=0.041 background=0.694 border_bg=0.310
#     ink=0.1520 bands=11/h12/reg0.91

# See what OCR actually receives
v3era preprocess photo.jpg --out debug.pnm

# Force a profile when you know better than the classifier
v3era ocr terminal.png --kind screenshot

# Vision model, schema-constrained output
v3era analyze invoice.pdf --vlm --task extract_fields --format json --pretty

# Free-form question about an image
v3era analyze chart.png --prompt "What is the peak value and in which month?"
```

`--format json` on several inputs emits a JSON array; text output goes to
stdout and diagnostics to stderr, so pipes behave:

```sh
v3era analyze *.png --format json | jq -r '.[] | "\(.source): \(.kind)"'
```

---

## HTTP service

```sh
v3erad --port 8080 --workers 4
```

| Method | Path | |
|---|---|---|
| GET | `/healthz` | liveness |
| GET | `/readyz` | readiness — 503 until decoding works |
| GET | `/v1/capabilities` | what this build and host can do |
| GET | `/metrics` | Prometheus text exposition |
| POST | `/v1/analyze` | full pipeline |
| POST | `/v1/ocr` | OCR only |
| POST | `/v1/text` | text extraction |

Upload either as a raw body with the file's own content type, or as JSON with
base64 — whichever fits the caller.

```sh
# Raw body
curl -sS --data-binary @scan.pdf \
     -H 'Content-Type: application/pdf' \
     'http://localhost:8080/v1/analyze?format=markdown'

# JSON with options
curl -sS -H 'Content-Type: application/json' -d '{
  "data": "'"$(base64 -w0 receipt.jpg)"'",
  "name": "receipt.jpg",
  "options": {"vlm": true, "task": "extract_fields", "language": "eng"}
}' http://localhost:8080/v1/analyze | jq
```

Query parameters mirror the JSON options (`format`, `pretty`, `boxes`, `ocr`,
`layout`, `vlm`, `task`, `kind`, `language`, `dpi`, `render_dpi`, `first_page`,
`last_page`), so `curl --data-binary` stays usable without a JSON wrapper.

Every response carries `X-Request-Id`, matching the id in the access log.

### Scaling

The analysis stages are CPU-bound and synchronous, so one process handles one
analysis at a time. `--workers N` forks N processes that share the port via
`SO_REUSEPORT`, and the kernel balances between them. That is deliberately
simpler than a thread pool: no shared mutable state, and a crash takes down one
worker rather than the service. Size N to available cores.

Run with `--no-vlm` to reject model calls outright on a server that should
never make outbound requests.

---

## Library use

```nim
import v3era

let res = analyzeFile("invoice.pdf")

echo res.kind                    # ikPdf
echo res.document.text
echo res.markdown()              # headings, lists and tables preserved
echo res.toJson().pretty()

for w in res.warnings:
  echo "degraded: ", w
```

Any layer works on its own:

```nim
import v3era

# Preprocessing only
let (prepared, report) = loadImage("photo.jpg").preprocess(photoProfile())
echo report.applied              # @["denoise", "grayscale", ... "binarize:sauvola"]
echo report.deskewAngle          # -3.42

# OCR with word geometry
let page = recognizePage(prepared)
for blk in page.blocks:
  for line in blk.lines:
    for word in line.words:
      echo word.text, " @ ", word.box, " (", word.confidence, "%)"

# Just the geometry primitives
let angle = loadImage("scan.png").estimateSkew().angle
let deskewed = loadImage("scan.png").rotate(-angle)
```

The VLM client takes an injectable transport, so request construction and
response handling are testable without a network or a key:

```nim
var opts = defaultAnalyzeOptions()
opts.runVlm = true
opts.transport = proc (url: string; headers: HttpHeaders; body: string;
                       timeoutMs: int): HttpResponse {.gcsafe.} =
  HttpResponse(status: 200, body: recordedFixture)

let res = analyzeImage(img, "test", opts)
```

---

## Configuration

Everything is settable by environment variable, so a deployment changes
provider or model without a rebuild.

| Variable | Default | |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | API key for the default backend |
| `V3ERA_VLM_PROVIDER` | `anthropic` | or `openai` for any compatible server |
| `V3ERA_VLM_MODEL` | `claude-opus-5` | |
| `V3ERA_VLM_BASE_URL` | `https://api.anthropic.com` | |
| `V3ERA_VLM_MAX_TOKENS` | `16000` | |
| `V3ERA_VLM_TIMEOUT_MS` | `300000` | |
| `V3ERA_TESSERACT_LIB` | — | explicit path to `libtesseract` |
| `V3ERA_IMAGE_CONVERT` | — | fallback decoder, e.g. `magick {in} pnm:-` |
| `V3ERA_LOG_LEVEL` | `info` | `debug` · `info` · `warn` · `error` |
| `V3ERA_LOG_FORMAT` | `text` | `text` · `json` |
| `PORT` | `8080` | server only |

### Running against a local model

```sh
export V3ERA_VLM_PROVIDER=openai
export V3ERA_VLM_BASE_URL=http://localhost:8000
export V3ERA_VLM_MODEL=Qwen/Qwen2-VL-7B-Instruct
v3era analyze page.png --vlm
```

vLLM, Ollama, llama.cpp's server and LM Studio all speak this shape. PDFs are
rasterised first, since only the Anthropic backend accepts them natively.

### VLM request details

The Anthropic backend sends `thinking: {type: "adaptive"}`, puts `effort`
inside `output_config`, marks the system prompt with `cache_control` (it is the
stable prefix across a batch), and opts into server-side refusal fallbacks. A
safety decline arrives as HTTP 200 with `stop_reason: "refusal"`, which is
surfaced as `VlmAnswer.refused` rather than raised. Retries use exponential
backoff with full jitter, and an explicit `retry-after` always wins.

Tasks with a schema (`extract_fields`, `describe_diagram`) constrain the
response through structured outputs, so the result is parsed JSON rather than
prose that has to be scraped.

---

## How the pipeline decides things

The parts most likely to surprise you, and why they work that way.

**Classification** scores eight signals on a downscaled probe. Flat colour runs
and palette size separate synthetic pixels from photographic ones — sensor
noise means adjacent pixels are essentially never bit-identical. Among
synthetic images, a *coloured* border separates a screenshot from a rendered
page: a page has margins, a UI has chrome. Among page-like images, band
structure — how many ink bands, how thick, how evenly spaced — separates lines
of type from a diagram's horizontal rules. `v3era classify` prints all of it.

**Deskew** maximises the variance of the row projection. Text lines are
horizontal when the ink-per-row profile is spikiest. The C kernel accumulates
into rotated bins analytically, so no intermediate image is produced per
candidate angle; a coarse-to-fine sweep reaches 0.02° in about 50 evaluations.
Orientation is corrected quadrant-first (lossless) then by skew, because a
90°-rotated page would otherwise saturate the skew search at its bound.

**Binarisation** defaults to Sauvola, computed over summed-area tables. On a
photographed page the ink on the shadowed side is darker than the *paper* on
the lit side, so no global threshold can separate them; the adaptive one
tracks the local mean and variance. Otsu is available for clean scans, and
returns the midpoint of its argmax plateau rather than the first maximiser —
on a cleanly bimodal histogram every threshold in the gap scores identically,
and sitting against the ink peak is where noise flips pixels.

**Screenshots are never binarised.** Their text is anti-aliased at a small
point size; thresholding destroys exactly the grey edge pixels that make it
legible. They get a bounded upscale instead.

**Contrast** is measured as the separation between the Otsu class means, not as
a percentile spread. A printed page is ~99% paper, so its 5th and 95th
percentiles are both white and a percentile measure reports 0.0 for a
perfectly crisp scan.

**Layout** recovers reading order by detecting full-height gutters, promotes
headings from relative text size *and* textual cues (both required), and finds
tables by column alignment rather than ruling lines — many real tables have
none.

---

## Performance

Measured on one core of an Intel Xeon @ 2.80 GHz, `-d:release --opt:speed`,
against a US Letter page at 150 DPI (1275×1650 RGB) rendered from a PDF.
Reproduce with the numbers your own hardware gives — nothing here is tuned to
a benchmark.

| Stage | Time |
|---|---|
| PNG decode (stb) | 7 ms |
| Grayscale conversion | 2 ms |
| Classification (8 signals, 900 px probe) | 18 ms |
| Otsu binarisation | 5 ms |
| Sauvola binarisation, window 25 | 29 ms |
| Skew estimate (~50 candidate angles) | 50 ms |
| Quadrant detection | 53 ms |
| **Full preprocess, document profile** | **181 ms** |
| Tesseract OCR | 165 ms |
| **Analyse one page image, end to end** | **372 ms** |
| PDF metadata probe | 14 ms |
| PDF text-layer extraction | 14 ms |
| PDF page render at 200 DPI | 38 ms |
| **Analyse a digital PDF page** | **28 ms** |

The design consequence is the last two rows: **a digital PDF page costs 28 ms
and a scanned one costs roughly 410 ms** — fifteen times more. That ratio is
why the planner checks for a text layer before rendering anything, and why the
check is per page rather than per file.

Note that preprocessing costs more than OCR here. That is the expected shape:
orientation correction dominates it (skew estimate plus quadrant detection is
103 of the 181 ms), and it buys back far more than it costs on a page that is
actually skewed. `--kind screenshot` or a custom profile with
`autoOrient: false` skips it when you know the input is already square.

Where the time goes, and what was done about it:

- Image kernels are C compiled at `-O3 -ffast-math`, auto-vectorisable, and
  called through validated Nim wrappers. Sauvola over integral images is O(1)
  per pixel regardless of window size; box blur uses a running sum, so cost is
  independent of radius.
- Deskew runs on a probe capped at 1200 px and never materialises a rotated
  image — the C kernel accumulates into rotated bins analytically.
- Classification runs on a probe capped at 900 px, so cost is bounded
  regardless of input size.
- Images are downscaled to 1568 px before reaching a model — past that it
  downsamples anyway, so more is pure token cost.

---

## Testing

```sh
make test           # native codecs only
make test-stb       # additionally exercises stb_image
nim c -r -d:release tests/test_all.nim
```

201 cases across preprocessing, codecs, layout, the VLM client, PDF handling
and the full pipeline. The suite passes in debug and release, with and without
the stb backend, and — importantly — **with no OCR engine and no PDF toolchain
installed at all**, which is how the degradation path stays honest. CI runs
that "bare" configuration as its own matrix leg.

Cases needing an optional dependency skip themselves and say so.

Notable coverage:

- Sauvola is tested against a synthetic lighting gradient where the ink on one
  side is darker than the paper on the other — the case no global threshold
  can handle.
- Deskew recovers known rotations to within 0.25°, and all four 90° page
  orientations round-trip.
- Every VLM case runs against a stub transport: request shape, retry
  behaviour, `retry-after` handling, refusals, structured output, and the
  distinction between retryable and terminal statuses.
- The pipeline's degradation contract is tested directly: missing engine,
  blank page, unconfigured model and API failure must all produce a result
  with a warning rather than an exception.

---

## Deployment

- **Health**: gate traffic on `/readyz`, not `/healthz`.
- **Scaling**: `--workers N` sized to cores; scale horizontally beyond one box.
- **Limits**: `--max-body` (default 64 MiB) and a decode cap that rejects
  images over 40 MP before allocating for them.
- **Logging**: `V3ERA_LOG_FORMAT=json` for a log shipper. Logs go to stderr;
  command output goes to stdout.
- **Metrics**: `/metrics` exposes request, error, byte and cumulative-latency
  counters. Counters are **per process**, so with `--workers N` a scrape hits
  whichever worker the kernel hands the connection to and sees roughly `1/N`
  of the traffic. Either scrape with `--workers 1` behind an external load
  balancer, or treat the values as a sample and aggregate across scrapes.
- **Security**: external tools are invoked with an argument vector and never
  through a shell — document paths reach the code from HTTP uploads. The
  container runs unprivileged and needs no write access outside `/tmp`.
- **Cost**: `--no-vlm` disables outbound model calls entirely.

---

## Limitations

Stated plainly, because each one is a real edge you may hit.

- **A greyscale screenshot reads as a document.** A terminal capture or a
  monochrome e-reader screenshot has no coloured chrome, so it takes the
  document profile and gets binarised it did not need. OCR still works; pass
  `--kind screenshot` when it matters.
- **A one- or two-line image is treated as a label, not a page.** There are not
  enough bands to measure leading, so it takes the diagram profile.
- **Handwriting is not supported.** Tesseract is trained on print. The VLM
  stage handles handwriting far better — use `--vlm --task transcribe`.
- **TIFF and WebP need a helper.** stb_image does not decode them. Set
  `V3ERA_IMAGE_CONVERT='magick {in} pnm:-'` (or the `vips` equivalent) and
  they route through it.
- **Encrypted PDFs are rejected** rather than prompted for. Decrypt first.
- **Vertical scripts** (traditional Chinese, Japanese tategaki) will confuse
  the projection-profile deskew, which assumes horizontal text lines.
- **Table detection needs consistent column alignment.** Deeply nested or
  merged-cell tables come back as flat rows.
- **The OpenAI-compatible backend has no native PDF input**, so pages are
  rasterised first — lower fidelity and more tokens than the Anthropic path.

---

## License

MIT. See [LICENSE](LICENSE). `stb_image` is fetched, not vendored in-tree, and
is public domain / MIT.
