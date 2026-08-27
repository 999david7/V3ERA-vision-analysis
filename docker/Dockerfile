# Multi-stage build: a fat builder with the Nim toolchain, a slim runtime with
# only the shared libraries and CLI tools the binaries actually dlopen or exec.

# ---------------------------------------------------------------------------
# Builder
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS builder

ARG NIM_VERSION=2.2.10
ARG TARGETARCH=amd64

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      xz-utils \
      libtesseract-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Nim from the official binary release rather than choosenim: it is one
# download, needs no network at build time beyond this layer, and pins exactly.
RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" \
      -o /tmp/nim.tar.xz \
 && mkdir -p /opt/nim \
 && tar -xJf /tmp/nim.tar.xz -C /opt/nim --strip-components=1 \
 && rm /tmp/nim.tar.xz
ENV PATH="/opt/nim/bin:${PATH}"

WORKDIR /src

# Fetch the vendored headers first so this layer caches independently of the
# source tree.
COPY scripts/fetch_vendor.sh scripts/
RUN sh scripts/fetch_vendor.sh

COPY . .

# -d:v3eraStb enables PNG/JPEG/GIF decoding and PNG/JPEG encoding.
RUN nim c -d:release --opt:speed -d:v3eraStb --hints:off \
      -o:/out/v3era src/v3era_cli.nim \
 && nim c -d:release --opt:speed -d:v3eraStb --hints:off \
      -o:/out/v3erad src/v3era_server.nim \
 && strip /out/v3era /out/v3erad

# Prove the image can actually do the work before it ships.
RUN nim c -r -d:release -d:v3eraStb --hints:off --warnings:off tests/test_all.nim

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

# libtesseract5  -- dlopen'd at first OCR call
# tesseract-ocr-eng -- the language data; add more with tesseract-ocr-<lang>
# poppler-utils  -- pdftoppm/pdftotext/pdfinfo, exec'd for PDF work
RUN apt-get update && apt-get install -y --no-install-recommends \
      libtesseract5 \
      tesseract-ocr-eng \
      poppler-utils \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Run unprivileged. The service needs no write access outside /tmp, which it
# uses to stage uploads for the PDF tools.
RUN useradd --system --uid 10001 --create-home --home-dir /home/v3era v3era

COPY --from=builder /out/v3era  /usr/local/bin/v3era
COPY --from=builder /out/v3erad /usr/local/bin/v3erad

USER v3era
WORKDIR /home/v3era

ENV V3ERA_LOG_FORMAT=json \
    V3ERA_LOG_LEVEL=info \
    PORT=8080

EXPOSE 8080

# /readyz reports 503 until the process can decode images, which is what an
# orchestrator should gate traffic on.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD ["/usr/local/bin/v3era", "capabilities"]

ENTRYPOINT ["/usr/local/bin/v3erad"]
CMD ["--port", "8080", "--workers", "4"]
