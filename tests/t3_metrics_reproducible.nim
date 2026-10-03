## The text-metrics table is the pinned fonts: every face's recorded
## sha256 is the file the capture environment's fontconfig resolves
## (`fc-match` under the dev shell's `FONTCONFIG_FILE`), and running
## the generator (`just text-metrics`, fonttools) again yields the
## committed `src/isonim_email/metrics_data.nim` byte for byte.
##
## C backend only: reads font files and runs fc-match and the
## generator. A missing tool fails loudly, never skips (no test
## doubles).
import std/[os, osproc, strutils, unittest]
import isonim_email
import isonim_email/metrics_data

const repoRoot = parentDir(parentDir(currentSourcePath()))

proc fcMatch(pattern: string): string =
  let (output, code) = execCmdEx("fc-match -f '%{file}' " &
    quoteShell(pattern))
  doAssert code == 0, "fc-match failed: " & output
  output.strip()

suite "text metrics reproducible":
  test "test_metrics_hashes_are_the_pinned_fonts":
    for (face, pattern) in [(liberationSansFace, "Liberation Sans:style=Regular"),
        (liberationSansBoldFace, "Liberation Sans:style=Bold"),
        (liberationSerifFace, "Liberation Serif:style=Regular"),
        (liberationSerifBoldFace, "Liberation Serif:style=Bold"),
        (liberationMonoFace, "Liberation Mono:style=Regular"),
        (liberationMonoBoldFace, "Liberation Mono:style=Bold"),
        (carlitoFace, "Carlito:style=Regular"),
        (carlitoBoldFace, "Carlito:style=Bold"),
        (robotoFace, "Roboto:style=Regular"),
        (robotoBoldFace, "Roboto:style=Bold"),
        (notoSansFace, "Noto Sans:style=Regular"),
        (notoSansBoldFace, "Noto Sans:style=Bold")]:
      let path = fcMatch(pattern)
      checkpoint(pattern & " -> " & path)
      check extractFilename(path) == face.file
      check sha256Hex(readFile(path)) == face.sha256

  test "test_metrics_generation_reproducible":
    let python = getEnv("ISONIM_EMAIL_FONTTOOLS_PYTHON")
    doAssert python.len > 0 and fileExists(python),
      "ISONIM_EMAIL_FONTTOOLS_PYTHON is not set: run in the dev shell"
    let outPath = repoRoot / "build" / "metrics-regen-" &
      $getCurrentProcessId() & ".nim"
    defer: removeFile(outPath)
    let (output, code) = execCmdEx(quoteShell(python) & " " &
      quoteShell(repoRoot / "tools/text-metrics/generate.py") & " " &
      quoteShell(outPath))
    checkpoint(output)
    check code == 0
    check readFile(outPath) ==
      readFile(repoRoot / "src/isonim_email/metrics_data.nim")
