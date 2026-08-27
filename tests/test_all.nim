## Runs the whole suite in one binary.
##
##   nimble test              # native codecs only
##   nimble testStb           # additionally exercises the stb_image backend
##
## Cases needing an optional dependency (libtesseract, poppler, stb) skip
## themselves and say so, so the suite is green on a bare machine and still
## proves the integration wherever those are installed.

import ./test_preprocess
import ./test_imageio
import ./test_layout
import ./test_vlm
import ./test_pdf
import ./test_pipeline
