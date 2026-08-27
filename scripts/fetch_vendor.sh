#!/bin/sh
# Download the vendored public-domain single-header C libraries.
#
# We pin exact commits rather than tracking master so a build is reproducible,
# and verify SHA-256 digests so a compromised mirror cannot inject code into a
# translation unit we compile with the rest of the project.
#
# Usage:  sh scripts/fetch_vendor.sh
# Then:   nim c -d:v3eraStb src/v3era_cli.nim

set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VENDOR="$DIR/vendor/stb"
BASE="https://raw.githubusercontent.com/nothings/stb"
COMMIT="f0569113c93ad095470c54bf34a17b36646bbbb5"

# Digests of the two headers at the pinned commit (stb_image v2.30,
# stb_image_write v1.16). Bumping COMMIT means recomputing both.
STB_IMAGE_SHA="594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3"
STB_IMAGE_WRITE_SHA="cbd5f0ad7a9cf4468affb36354a1d2338034f2c12473cf1a8e32053cb6914a05"

mkdir -p "$VENDOR"

fetch() {
  name="$1"
  url="$BASE/$COMMIT/$name"
  out="$VENDOR/$name"
  if [ -f "$out" ]; then
    echo "  have  $name"
    return 0
  fi
  echo "  fetch $name"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out.tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out.tmp" "$url"
  else
    echo "error: neither curl nor wget is available" >&2
    exit 1
  fi
  mv "$out.tmp" "$out"
}

verify() {
  name="$1"
  want="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$VENDOR/$name" | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "$VENDOR/$name" | cut -d' ' -f1)
  else
    echo "  warn  no sha256 tool; skipping digest check for $name" >&2
    return 0
  fi
  if [ "$got" != "$want" ]; then
    echo "error: digest mismatch for $name" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    echo "  Delete vendor/stb and retry, or update the pin in this script if" >&2
    echo "  you intentionally moved to a different upstream commit." >&2
    exit 1
  fi
  echo "  ok    $name"
}

echo "Vendoring stb into $VENDOR (pinned to ${COMMIT})"
fetch stb_image.h
fetch stb_image_write.h

if [ "${V3ERA_SKIP_DIGEST:-0}" = "1" ]; then
  echo "  skip  digest verification (V3ERA_SKIP_DIGEST=1)"
else
  verify stb_image.h "$STB_IMAGE_SHA"
  verify stb_image_write.h "$STB_IMAGE_WRITE_SHA"
fi

echo "Done. Build the stb backend with:  nim c -d:v3eraStb src/v3era_cli.nim"
