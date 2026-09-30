## The IR constructors (`newMsoIf`, `newNotMso`, `newVml`,
## `newHeadStyle`) may only be called from `src/isonim_email/mso/` and
## `passes/head.nim`. This test greps `src/` and fails on any
## other call site. Tests are exempt so they can build IR trees directly.
##
## C backend only: reads the source tree.
import std/[os, strutils, unittest]

const testsDir = parentDir(currentSourcePath())
const srcDir = parentDir(testsDir) / "src" / "isonim_email"

const constructors = ["newMsoIf", "newNotMso", "newVml", "newHeadStyle"]

proc stripComment(line: string): string =
  ## Cuts a `#` comment, ignoring `#` inside string literals.
  var inStr = false
  var i = 0
  while i < line.len:
    let c = line[i]
    if inStr:
      if c == '"':
        inStr = false
      i += 1
    elif c == '"':
      inStr = true
      i += 1
    elif c == '#':
      return line[0 ..< i]
    else:
      i += 1
  line

proc isWholeWord(line, word: string): bool =
  var i = line.find(word)
  while i >= 0:
    let beforeOk = i == 0 or line[i - 1] notin {'a' .. 'z', 'A' .. 'Z',
      '0' .. '9', '_'}
    let afterIdx = i + word.len
    let afterOk = afterIdx >= line.len or
      line[afterIdx] notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}
    if beforeOk and afterOk:
      return true
    i = line.find(word, i + 1)
  false

proc isAllowedSite(relPath, code: string; ctor: string): bool =
  ## Definitions live in `ir.nim`; calls are allowed under `mso/` and in
  ## `passes/head.nim`.
  if relPath == "ir.nim":
    return "proc " & ctor in code
  if relPath.startsWith("mso" / ""):
    return true
  relPath == "passes" / "head.nim"

suite "IR constructor restriction":
  test "no out-of-allowlist constructor call sites in src":
    var files = 0
    var defs = 0
    var allowedCalls = 0
    var violations: seq[string] = @[]
    for path in walkDirRec(srcDir):
      if not path.endsWith(".nim"):
        continue
      inc files
      let rel = relativePath(path, srcDir)
      var lineNo = 0
      for rawLine in lines(path):
        inc lineNo
        let code = stripComment(rawLine)
        for ctor in constructors:
          if not isWholeWord(code, ctor):
            continue
          if isAllowedSite(rel, code, ctor):
            if rel == "ir.nim":
              inc defs
            else:
              inc allowedCalls
          else:
            violations.add(rel & "(" & $lineNo & "): " & code.strip())
    echo "scanned: ", files, " defs: ", defs, " allowed calls: ", allowedCalls
    check files > 0
    # Vacuity guards: the four definitions and real in-allowlist call
    # sites (`mso/cond.nim`) must be found, or the grep is blind.
    check defs == 4
    check allowedCalls > 0
    check violations.len == 0
