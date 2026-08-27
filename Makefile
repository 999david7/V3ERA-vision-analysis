# V3ERA build targets. `nimble` does the same work; this exists so the usual
# `make && make test` reflex works and so CI has one obvious entry point.

NIM      ?= nim
NIMFLAGS ?= --hints:off
BIN      ?= bin

# Set STB=1 to compile the stb_image backend in (PNG/JPEG/GIF support).
ifeq ($(STB),1)
  NIMFLAGS += -d:v3eraStb
  VENDOR_DEP = vendor
else
  VENDOR_DEP =
endif

.PHONY: all build release test test-stb vendor clean fmt docs docker install \
        check help

all: build

help:
	@echo "make build      Debug build of both binaries into $(BIN)/"
	@echo "make release    Optimised build into $(BIN)/"
	@echo "make test       Run the test suite"
	@echo "make test-stb   Run the test suite with the stb_image backend"
	@echo "make vendor     Download the pinned stb single-header libraries"
	@echo "make check      Typecheck every module without producing binaries"
	@echo "make docs       Generate API documentation into docs/api"
	@echo "make docker     Build the container image"
	@echo "make clean      Remove build output"
	@echo ""
	@echo "Add STB=1 to any target to enable PNG/JPEG support:"
	@echo "  make release STB=1"

vendor:
	sh scripts/fetch_vendor.sh

build: $(VENDOR_DEP)
	@mkdir -p $(BIN)
	$(NIM) c $(NIMFLAGS) -o:$(BIN)/v3era src/v3era_cli.nim
	$(NIM) c $(NIMFLAGS) -o:$(BIN)/v3erad src/v3era_server.nim

release: $(VENDOR_DEP)
	@mkdir -p $(BIN)
	$(NIM) c -d:release --opt:speed $(NIMFLAGS) -o:$(BIN)/v3era src/v3era_cli.nim
	$(NIM) c -d:release --opt:speed $(NIMFLAGS) -o:$(BIN)/v3erad src/v3era_server.nim
	@echo "Built $(BIN)/v3era and $(BIN)/v3erad"

test:
	$(NIM) c -r $(NIMFLAGS) tests/test_all.nim

test-stb: vendor
	$(NIM) c -r $(NIMFLAGS) -d:v3eraStb tests/test_all.nim

check:
	$(NIM) check $(NIMFLAGS) src/v3era.nim
	$(NIM) check $(NIMFLAGS) src/v3era_cli.nim
	$(NIM) check $(NIMFLAGS) src/v3era_server.nim

docs:
	$(NIM) doc --project --index:on --outdir:docs/api $(NIMFLAGS) src/v3era.nim

docker:
	docker build -t v3era:latest -f docker/Dockerfile .

install: release
	install -d $(DESTDIR)/usr/local/bin
	install -m 0755 $(BIN)/v3era $(DESTDIR)/usr/local/bin/v3era
	install -m 0755 $(BIN)/v3erad $(DESTDIR)/usr/local/bin/v3erad

clean:
	rm -rf $(BIN) nimcache docs/api
	rm -f tests/test_all tests/test_preprocess tests/test_imageio \
	      tests/test_layout tests/test_vlm tests/test_pdf tests/test_pipeline
	find examples -type f ! -name '*.nim' ! -name '*.md' -delete 2>/dev/null || true
