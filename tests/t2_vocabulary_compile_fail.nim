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
## Every fixture this file names is checked once, all at once, before the
## first test (tests/compile_fail_checks.nim); each test then asserts on
## its fixtures' recorded output.
import std/[os, strutils, tables, unittest]
import compile_fail_checks

const testsDir = parentDir(currentSourcePath())

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

proc firstErrorLine*(output: string): string =
  ## The first compiler line containing `Error:` ("" when there is none).
  for line in output.splitLines():
    if "Error:" in line:
      return line
  ""

const fixtures = ["unknown_mail_tag.nim", "forbidden_script.nim",
  "forbidden_iframe.nim", "forbidden_form.nim", "forbidden_video.nim",
  "forbidden_svg.nim", "proc_as_element.nim", "forbidden_sectioning.nim",
  "forbidden_sectioning_top.nim", "bare_table.nim",
  "column_outside_row.nim", "pattern_unknown_attr.nim"]
  ## Every fixture a test below reads (a test naming one missing here
  ## fails on the table lookup).

var checked: Table[string, NimCheckResult]
block:
  var paths: seq[string]
  for f in fixtures:
    paths.add testsDir / "compile_fail" / f
  checked = nimCheckAll(paths)

proc checkFixture(path: string): tuple[output: string, exitCode: int,
    want: string, cited: string] =
  ## The fixture's `nim check` result and everything the test asserts
  ## on. Returns data instead of checking: `check` inside a helper proc
  ## prints but does not fail the test, so every `check` below sits in a
  ## test body.
  let exp = readExpect(path)
  let (output, exitCode) = checked[path]
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

  test "test_column_outside_a_row_is_compile_error":
    # rule: R-LAY-16
    # A column belongs to a row (a section, a group or a mailColumns):
    # anywhere else it is a compile-time nesting error at its own line.
    let (output, exitCode, want, cited) = checkFixture(
      testsDir / "compile_fail" / "column_outside_row.nim")
    check exitCode != 0
    check want in output
    check "mailColumn" in output
    check cited in output
    let first = firstErrorLine(output)
    check first.startsWith(testsDir / "compile_fail" / cited)
    check ("Error: " & want) in first

  test "test_defined_pattern_attributes_are_checked":
    # A pattern defined with defineMailPattern joins the static
    # vocabulary: its props are its attributes, and any other is an
    # error at the element, with the nearest prop suggested.
    let (output, exitCode, want, cited) = checkFixture(
      testsDir / "compile_fail" / "pattern_unknown_attr.nim")
    check exitCode != 0
    check want in output
    check "'mailPill' has no attribute 'colour'" in output
    check "Did you mean 'label'?" in output
    check cited in output
    let first = firstErrorLine(output)
    check first.startsWith(testsDir / "compile_fail" / cited)
    check ("Error: " & want) in first
