## Vocabulary compile-failure fixtures. Each fixture in
## `tests/compile_fail/` starts with `# expect: <substring>` and
## `# expect-line: <line>`; these tests assert `nim check` exits non-zero
## with the substring in its output and the violation line cited. The
## unknown-tag test additionally pins the `mailSection` suggestion, and the
## forbidden test pins each element's alternative verbatim. Every test also
## pins where the error is reported: the FIRST `Error:` line of the output
## is the fixture's own `file(line, col)` at the offending element, and
## carries the expected code (no stack trace, nothing attributed to the
## vocabulary module ahead of it).
##
## C backend only: shells out to `nim check` (dev shell / CI provide it).
import std/[os, osproc, strutils, unittest]

const testsDir = parentDir(currentSourcePath())
const repoRoot = parentDir(testsDir)

type FixtureExpect = object
  want: string
  wantLine: int

proc readExpect(path: string): FixtureExpect =
  for line in lines(path):
    if line.startsWith("# expect:"):
      result.want = line[len("# expect:") .. ^1].strip()
    elif line.startsWith("# expect-line:"):
      result.wantLine = parseInt(line[len("# expect-line:") .. ^1].strip())
  doAssert result.want.len > 0, path & ": missing '# expect:' header"
  doAssert result.wantLine > 0, path & ": missing '# expect-line:' header"

proc nimCheck(path: string): tuple[output: string, exitCode: int] =
  let nim = findExe("nim")
  doAssert nim.len > 0, "nim not on PATH (run under nix develop)"
  # `nim check` writes diagnostics to stderr; merge it to capture them.
  # `config.nims` is found by walking up from the fixture, so no --path
  # flags are needed; style checks are off so only semantic errors show.
  result = execCmdEx(
    nim & " check --hints:off " & quoteShell(path) & " 2>&1",
    workingDir = repoRoot)

proc firstErrorLine*(output: string): string =
  ## The first compiler line containing `Error:` ("" when there is none).
  for line in output.splitLines():
    if "Error:" in line:
      return line
  ""

proc checkFixture(path: string): tuple[output: string, exitCode: int,
    want: string, cited: string] =
  ## Runs `nim check` and returns everything the test asserts on. Returns
  ## data instead of checking: `check` inside a helper proc prints but does
  ## not fail the test, so every `check` below sits in a test body.
  let exp = readExpect(path)
  let (output, exitCode) = nimCheck(path)
  # The violation line is cited as `basename(line, col)` in the
  # instantiation trace ("on the expected line").
  (output, exitCode, exp.want, extractFilename(path) & "(" & $exp.wantLine & ",")

suite "vocabulary compile failures":
  test "test_unknown_mail_tag_is_compile_error":
    let (output, exitCode, want, cited) = checkFixture(
      testsDir / "compile_fail" / "unknown_mail_tag.nim")
    check exitCode != 0
    check want in output
    check "Did you mean 'mailSection'?" in output
    check cited in output
    let first = firstErrorLine(output)
    check first.startsWith(testsDir / "compile_fail" / cited)
    check ("Error: " & want) in first

  test "test_forbidden_elements_rejected":
    const alts = [
      ("forbidden_script.nim",
        "Use 'a mailButton linking to a hosted page' instead."),
      ("forbidden_iframe.nim",
        "Use 'a mailButton linking to the hosted page' instead."),
      ("forbidden_form.nim",
        "Use 'a mailButton linking to a hosted form' instead."),
      ("forbidden_video.nim",
        "Use 'a mailImage poster linking to the video page' instead."),
      ("forbidden_svg.nim", "Use 'a PNG @2x via mailImage' instead."),
    ]
    for (fixture, alt) in alts:
      let (output, exitCode, want, cited) = checkFixture(
        testsDir / "compile_fail" / fixture)
      check exitCode != 0
      check want in output
      check alt in output
      check cited in output
      let first = firstErrorLine(output)
      check first.startsWith(testsDir / "compile_fail" / cited)
      check ("Error: " & want) in first

  test "test_proc_as_element_is_compile_error":
    let (output, exitCode, want, cited) = checkFixture(
      testsDir / "compile_fail" / "proc_as_element.nim")
    check exitCode != 0
    check want in output
    check "call it positionally" in output
    check "defineMailPattern" in output
    check cited in output
    let first = firstErrorLine(output)
    check first.startsWith(testsDir / "compile_fail" / cited)
    check ("Error: " & want) in first

  test "test_sectioning_elements_report_a11y_code":
    # rule: R-A11Y-10
    # Nested (parent known) and at the top of a block (parent unknown):
    # the code comes from the forbidden entry, so both report it.
    for fixture in ["forbidden_sectioning.nim", "forbidden_sectioning_top.nim"]:
      let (output, exitCode, want, cited) = checkFixture(
        testsDir / "compile_fail" / fixture)
      check exitCode != 0
      check want == "E-A11Y-SECTIONING"
      check "E-VOCAB-FORBIDDEN-TAG" notin output
      check "rewritten or stripped by email clients (R-A11Y-10)" in output
      check ("Use 'layout primitives and content patterns; the patterns " &
        "add landmark roles themselves' instead.") in output
      check cited in output
      let first = firstErrorLine(output)
      check first.startsWith(testsDir / "compile_fail" / cited)
      check ("Error: " & want) in first

  test "test_bare_table_names_its_alternative":
    let (output, exitCode, want, cited) = checkFixture(
      testsDir / "compile_fail" / "bare_table.nim")
    check exitCode != 0
    check want == "E-STRUCT-NESTING"
    check "'table' must not be a child of 'mailColumn'" in output
    check "Use 'mailTable (data) or layout primitives' instead." in output
    check cited in output
    let first = firstErrorLine(output)
    check first.startsWith(testsDir / "compile_fail" / cited)
    check ("Error: " & want) in first
