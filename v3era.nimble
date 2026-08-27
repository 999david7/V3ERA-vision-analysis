# Package

version       = "0.1.0"
author        = "V3ERA"
description   = "Modular vision AI system: preprocessing, OCR, document parsing and VLM analysis"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["v3era_cli", "v3era_server"]
namedBin      = {"v3era_cli": "v3era", "v3era_server": "v3erad"}.toTable()

# Dependencies

requires "nim >= 2.0.0"

# Tasks

task test, "Run the unit test suite":
  exec "nim c -r --hints:off tests/test_all.nim"

task testStb, "Run the test suite with the stb_image backend enabled":
  exec "nim c -r --hints:off -d:v3eraStb tests/test_all.nim"

task release, "Build optimised binaries into bin/":
  mkDir "bin"
  exec "nim c -d:release --opt:speed -o:bin/v3era src/v3era_cli.nim"
  exec "nim c -d:release --opt:speed -o:bin/v3erad src/v3era_server.nim"

task vendor, "Download the vendored single-header C libraries":
  exec "sh scripts/fetch_vendor.sh"

task docs, "Generate API documentation into docs/api":
  exec "nim doc --project --index:on --outdir:docs/api src/v3era.nim"
