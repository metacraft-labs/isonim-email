## Plumbing proof: the umbrella module imports and the package version
## is visible. Backend-independent by construction (stdlib `unittest` only),
## so `just test` runs it on both the C and the JS backends.
import std/unittest
import isonim_email

suite "plumbing":
  test "umbrella module exposes the package version":
    check isonimEmailVersion == "0.1.0"
