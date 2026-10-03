## The built-in social icons are the generator's output: running
## `tools/social-icons/generate.py` (`just social-icons`, fonttools, the
## pinned Roboto Bold) again yields every committed PNG in
## `src/isonim_email/assets/social/` byte for byte, and no other file.
##
## C backend only: runs the generator and reads its files. A missing
## tool fails loudly, never skips (no test doubles).
import std/[algorithm, os, osproc, strutils, unittest]

const repoRoot = parentDir(parentDir(currentSourcePath()))
const iconDir = repoRoot / "src" / "isonim_email" / "assets" / "social"

proc pngs(dir: string): seq[string] =
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".png"):
      result.add(extractFilename(path))
  result.sort()

suite "social icons reproducible":
  test "test_social_icons_regenerate_byte_identically":
    # rule: R-IMG-12
    let python = getEnv("ISONIM_EMAIL_FONTTOOLS_PYTHON")
    doAssert python.len > 0 and fileExists(python),
      "ISONIM_EMAIL_FONTTOOLS_PYTHON is not set: run in the dev shell"
    let outDir = repoRoot / "build" / "icons-regen-" & $getCurrentProcessId()
    defer: removeDir(outDir)
    let (output, code) = execCmdEx(quoteShell(python) & " " &
      quoteShell(repoRoot / "tools/social-icons/generate.py") & " " &
      quoteShell(outDir))
    checkpoint(output)
    check code == 0
    let committed = pngs(iconDir)
    check committed.len == 20
    check pngs(outDir) == committed
    for name in committed:
      checkpoint(name)
      check readFile(outDir / name) == readFile(iconDir / name)
