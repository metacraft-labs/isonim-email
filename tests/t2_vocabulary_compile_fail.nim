## Vocabulary compile-failure fixtures. Each fixture in
## `tests/compile_fail/` starts with `# expect: <substring>` and
## `# expect-line: <line>`; these tests assert `nim check` exits non-zero
## with the substring in its output and the violation line cited. The
## unknown-tag test additionally pins the `mailSection` suggestion, and the
## forbidden test pins each element's alternative verbatim.
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

  test "test_proc_as_element_is_compile_error":
    let (output, exitCode, want, cited) = checkFixture(
      testsDir / "compile_fail" / "proc_as_element.nim")
    check exitCode != 0
    check want in output
    check "call it positionally" in output
    check "defineMailPattern" in output
    check cited in output
