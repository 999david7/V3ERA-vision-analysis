#!/bin/sh
# Install everything V3ERA needs, then build and test it.
#
#   sh scripts/setup.sh              # install deps, vendor stb, build, test
#   sh scripts/setup.sh --no-deps    # skip system package installation
#   sh scripts/setup.sh --minimal    # skip the optional OCR/PDF dependencies
#
# Nothing here is required to *build* V3ERA -- the library compiles and its
# tests pass against a bare Nim install. The system packages below enable the
# optional stages: OCR (libtesseract) and PDF (poppler).

set -eu

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$DIR"

INSTALL_DEPS=1
MINIMAL=0
for arg in "$@"; do
  case "$arg" in
    --no-deps) INSTALL_DEPS=0 ;;
    --minimal) MINIMAL=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Nim
# ---------------------------------------------------------------------------
say "Checking for Nim"
if command -v nim >/dev/null 2>&1; then
  echo "    $(nim --version | head -1)"
else
  echo "    Nim not found."
  echo "    Install it with choosenim (recommended):"
  echo "      curl https://nim-lang.org/choosenim/init.sh -sSf | sh"
  echo "      export PATH=\"\$HOME/.nimble/bin:\$PATH\""
  echo "    or from your package manager. V3ERA needs Nim 2.0 or newer;"
  echo "    Debian's 'nim' package is 1.6 and will not work."
  exit 1
fi

# ---------------------------------------------------------------------------
# Optional system dependencies
# ---------------------------------------------------------------------------
if [ "$INSTALL_DEPS" -eq 1 ] && [ "$MINIMAL" -eq 0 ]; then
  say "Installing optional system dependencies"
  if command -v apt-get >/dev/null 2>&1; then
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    $SUDO apt-get update
    $SUDO apt-get install -y \
      build-essential \
      libtesseract-dev tesseract-ocr tesseract-ocr-eng \
      poppler-utils
  elif command -v dnf >/dev/null 2>&1; then
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    $SUDO dnf install -y gcc make tesseract tesseract-devel poppler-utils
  elif command -v brew >/dev/null 2>&1; then
    brew install tesseract poppler
  elif command -v pacman >/dev/null 2>&1; then
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    $SUDO pacman -S --needed --noconfirm base-devel tesseract tesseract-data-eng poppler
  else
    echo "    No recognised package manager. Install these by hand:"
    echo "      libtesseract (runtime + headers), tesseract language data,"
    echo "      poppler-utils (pdftoppm, pdftotext, pdfinfo)"
  fi
else
  say "Skipping system dependency installation"
fi

# ---------------------------------------------------------------------------
# Vendored C headers
# ---------------------------------------------------------------------------
say "Vendoring stb (PNG/JPEG/GIF support)"
sh scripts/fetch_vendor.sh

# ---------------------------------------------------------------------------
# Build and test
# ---------------------------------------------------------------------------
say "Building"
mkdir -p bin
nim c -d:release --opt:speed -d:v3eraStb --hints:off -o:bin/v3era src/v3era_cli.nim
nim c -d:release --opt:speed -d:v3eraStb --hints:off -o:bin/v3erad src/v3era_server.nim

say "Running the test suite"
nim c -r -d:v3eraStb --hints:off --warnings:off tests/test_all.nim

say "Capabilities on this machine"
./bin/v3era --version

cat <<'EOF'

Ready. Try:

  ./bin/v3era analyze <file.pdf> --format markdown
  ./bin/v3era ocr <image.png>
  ./bin/v3era classify <image.png>
  ./bin/v3erad --port 8080

To enable the vision-language model stage:

  export ANTHROPIC_API_KEY=sk-ant-...
  ./bin/v3era analyze <image.png> --vlm --task describe --format json --pretty

EOF
