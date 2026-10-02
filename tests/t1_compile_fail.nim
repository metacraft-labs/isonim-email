## Compile-failure fixtures. Each `tests/compile_fail/*.nim`
## starts with `# expect: <substring>` and `# expect-line: <line>`; the
## runner asserts `nim check` exits non-zero with the substring in its
## output and the fixture's violation line cited.
##
## C backend only: shells out to `nim check` (dev shell / CI provide it),
## every fixture at once (tests/compile_fail_checks.nim).
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

suite "compile failures":
  test "event handler fixture fails with the documented message":
    var count = 0
    var paths: seq[string]
    for path in walkFiles(testsDir / "compile_fail" / "*.nim"):
      paths.add path
    let checked = nimCheckAll(paths)
    for path in paths:
      let exp = readExpect(path)
      let (output, exitCode) = checked[path]
      check exitCode != 0
      check exp.want in output
      # The violation line is cited as `basename(line, col)` in the
      # instantiation trace ("on the expected line").
      let cited = extractFilename(path) & "(" & $exp.wantLine & ","
      check cited in output
      inc count
    # Vacuity guard: the fixtures this suite names must exist.
    check count > 0
