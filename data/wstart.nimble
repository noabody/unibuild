# wstart native Nim build
version       = "0.2.0"
author        = "wstart"
description   = "Wine Starter"
license       = "unlicense"
srcDir        = "."
bin           = @["wstart"]

requires "nim >= 2.0.0"
requires "https://github.com/RePRGM/PEFile"
