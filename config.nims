# Project-wide compiler configuration.
#
# Applies to every `nim c` invocation rooted at this directory, including the
# ones nimble makes. Keep build-mode-specific flags here rather than in the
# nimble file so that ad-hoc `nim c src/...` builds behave identically to
# `nimble build`.

--mm:orc
--threads:on
--define:ssl
--styleCheck:hint

# The C fast-path translation unit lives outside src/ so it is shared by every
# module that needs it. `preprocess/ops.nim` pulls it in with {.compile.}.
switch("path", "$projectDir")

when defined(release) or defined(danger):
  --opt:speed
  --passC:"-ffast-math"
  --panics:on

when defined(v3eraStb):
  # scripts/fetch_vendor.sh drops the stb headers here.
  switch("passC", "-I" & thisDir() & "/vendor/stb")
