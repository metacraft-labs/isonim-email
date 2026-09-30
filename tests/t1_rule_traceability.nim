## Rule traceability: every rule ID in `docs/rendering-rules.md` is named
## by at least one test's `# rule: R-…` comment, or is listed in
## `tests/rules_pending.txt` (which may only shrink).
##
## The catalogue ships in this repo, so this test reads it directly and
## fails loudly when it is absent — there are no skip paths.
##
## C backend only: reads the docs and tests directories off disk.
import std/[algorithm, os, sequtils, sets, strutils, unittest]

const testsDir = parentDir(currentSourcePath())
const cataloguePath = parentDir(testsDir) / "docs" / "rendering-rules.md"

proc isRuleId(s: string): bool =
  ## `R-<GROUP>-<NN>`, where GROUP may contain digits (`R-A11Y-01`).
  if not s.startsWith("R-"):
    return false
  let rest = s[2 .. ^1]
  let dash = rest.rfind('-')
  if dash <= 0 or dash == rest.len - 1:
    return false
  for c in rest[0 ..< dash]:
    if c notin {'A' .. 'Z', '0' .. '9'}:
      return false
  for c in rest[dash + 1 .. ^1]:
    if c notin {'0' .. '9'}:
      return false
  true

proc catalogueRuleIds(path: string): HashSet[string] =
  ## Rule IDs are the first cells of the catalogue's rule-table rows
  ## (`| R-XX-NN | …`). Withdrawn rows (❌) are excluded.
  result = initHashSet[string]()
  for line in lines(path):
    let stripped = line.strip()
    if not stripped.startsWith("| R-"):
      continue
    let cells = stripped.split('|')
    if cells.len < 2:
      continue
    let id = cells[1].strip()
    if not isRuleId(id):
      continue
    if "withdrawn" in line:
      continue
    result.incl(id)

proc testedRuleIds(dir: string): HashSet[string] =
  ## Rule IDs named in full-line `# rule:` comments under `tests/`
  ## (comma- or space-separated lists allowed). Only lines whose stripped
  ## form *starts* with the marker count, so prose or code mentioning the
  ## marker mid-line is never mistaken for a rule claim.
  result = initHashSet[string]()
  for path in walkDirRec(dir):
    if not path.endsWith(".nim"):
      continue
    var lineNo = 0
    for line in lines(path):
      inc lineNo
      let stripped = line.strip()
      if not stripped.startsWith("# rule:"):
        continue
      for tok in stripped[len("# rule:") .. ^1].split({' ', '\t', ','}):
        let id = tok.strip()
        if id.len == 0:
          continue
        doAssert isRuleId(id),
          path & "(" & $lineNo & "): malformed rule ID '" & id & "'"
        result.incl(id)

proc ruleIdsFromFile(path: string): HashSet[string] =
  result = initHashSet[string]()
  var lineNo = 0
  for line in lines(path):
    inc lineNo
    let id = line.strip()
    if id.len == 0 or id.startsWith("#"):
      continue
    doAssert isRuleId(id),
      path & "(" & $lineNo & "): malformed rule ID '" & id & "'"
    result.incl(id)

suite "rule traceability":
  test "every catalogue rule is tested or pending":
    # The catalogue ships in this repo: a missing file is a packaging
    # bug and fails loudly here — it is never skipped.
    doAssert fileExists(cataloguePath),
      "rendering-rules catalogue missing at " & cataloguePath
    let catalogue = catalogueRuleIds(cataloguePath)
    check catalogue.len > 0
    let tested = testedRuleIds(testsDir)
    let pending = ruleIdsFromFile(testsDir / "rules_pending.txt")
    echo "catalogue: ", catalogue.len, " tested: ", tested.len,
      " pending: ", pending.len
    # No stale exemptions: everything pending must be a real catalogue ID.
    let stalePending = sorted(toSeq(pending - catalogue))
    check stalePending.len == 0
    # No stale rule claims either: everything tested must be real.
    let bogusTested = sorted(toSeq(tested - catalogue))
    check bogusTested.len == 0
    # A tested rule must leave the pending list (the list only shrinks).
    let overlap = sorted(toSeq(tested * pending))
    check overlap.len == 0
    # And everything untested must be listed.
    let missing = sorted(toSeq(catalogue - tested - pending))
    check missing.len == 0
