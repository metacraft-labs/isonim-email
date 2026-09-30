## The Tailwind class map every compile reads is extracted from this
## repository's own content, and building it touches nothing outside this
## repository's build/ directory.
##
## * every class in build/tailwind-styles.json occurs as a whole token in
##   the scanned content (src/, examples/, tests/);
## * classes that only the sibling isonim checkout uses (its own tests and
##   components) are absent — Tailwind's automatic source detection would
##   pull them in;
## * re-running `tools/tailwind/build-tailwind.mjs` reproduces the same
##   map, leaves ../isonim unchanged (git status, including ignored files,
##   and no file modified under it), and writes nothing in this checkout
##   outside build/.
##
## The negative class names below are split across string literals on
## purpose: tests/ is scanned content, and a whole literal would put the
## class into the map this test says must not contain it.
##
## C backend only: reads the tree and runs node.
import std/[json, os, osproc, sequtils, strutils, times, unittest]

const testsDir = parentDir(currentSourcePath())
const repoRoot = parentDir(testsDir)
const mapPath = repoRoot / "build" / "tailwind-styles.json"
const isonimDir = parentDir(repoRoot) / "isonim"
const tailwindStylesPathOverride {.strdefine.} = ""
  ## The map path the compile was given (`just` passes it); "" otherwise.

const contentRoots = ["src", "examples", "tests"]

# Classes the isonim checkout's own content uses and this repository's
# does not: its Tailwind golden fixture, its variant tests, its components.
const isonimOnlyClasses = [
  "sm:p" & "-2",
  "dark:te" & "xt-white",
  "hover:under" & "line",
  "rounded-2" & "xl",
]

proc readTree(root: string; exts: openArray[string]): string =
  ## Every file under `root` with one of `exts`, concatenated.
  if not dirExists(root):
    return ""
  for path in walkDirRec(root):
    if path.splitFile.ext in exts:
      result.add(readFile(path))
      result.add('\n')

proc emailContent(): string =
  for r in contentRoots:
    result.add(readTree(repoRoot / r, [".nim"]))

const classChars = {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', ':'}

proc hasToken(content, token: string): bool =
  ## `token` occurs with no class character directly before or after it.
  var i = content.find(token)
  while i >= 0:
    let before = i == 0 or content[i - 1] notin classChars
    let afterIdx = i + token.len
    let after = afterIdx >= content.len or content[afterIdx] notin classChars
    if before and after:
      return true
    i = content.find(token, i + 1)
  false

proc loadMapKeys(): seq[string] =
  let j = parseFile(mapPath)
  for k, _ in j:
    result.add(k)

proc gitStatus(dir: string): string =
  let (output, code) = execCmdEx("git -C " & quoteShell(dir) &
    " status --porcelain --ignored --untracked-files=all")
  doAssert code == 0, "git status failed in " & dir & ":\n" & output
  output

proc modifiedSince(root: string; since: Time;
                   skip: openArray[string]): seq[string] =
  ## Files under `root` modified at or after `since`, skipping the
  ## top-level entries named in `skip`.
  for path in walkDirRec(root, relative = true):
    if path.split(DirSep)[0] in skip:
      continue
    try:
      if getLastModificationTime(root / path) >= since:
        result.add(path)
    except OSError:
      discard # vanished while walking

suite "tailwind class map":
  test "test_map_is_the_one_the_compile_reads":
    check fileExists(mapPath)
    when tailwindStylesPathOverride != "":
      check tailwindStylesPathOverride == mapPath

  test "test_map_classes_come_from_this_repository":
    let keys = loadMapKeys()
    let content = emailContent()
    # Non-vacuous: the map is not empty, and it carries the md: class the
    # style pass's one-breakpoint test compiles through it.
    check keys.len > 0
    check "md:p-6" in keys
    var foreign: seq[string] = @[]
    for k in keys:
      if not hasToken(content, k):
        foreign.add(k)
    check foreign.len == 0
    if foreign.len > 0:
      echo "classes not found in this repository's content: ", foreign

  test "test_map_has_no_isonim_only_classes":
    let keys = loadMapKeys()
    let content = emailContent()
    for cls in isonimOnlyClasses:
      check cls notin keys
      # Meaningful only while this repository does not use the class.
      check not hasToken(content, cls)
    if dirExists(isonimDir):
      # ...and while the sibling checkout does, so an automatic scan of
      # it would have put the class into the map.
      let isonimContent = readTree(isonimDir / "tests", [".nim", ".html"]) &
        readTree(isonimDir / "src", [".nim"])
      for cls in isonimOnlyClasses:
        check hasToken(isonimContent, cls)

  test "test_build_writes_only_under_build":
    let node = findExe("node")
    doAssert node.len > 0, "node not on PATH (run under nix develop)"
    doAssert dirExists(isonimDir), "the isonim sibling checkout is required"
    let before = readFile(mapPath)
    let isonimBefore = gitStatus(isonimDir)
    let start = getTime()
    let (output, code) = execCmdEx(
      quoteShell(node) & " tools/tailwind/build-tailwind.mjs",
      workingDir = repoRoot)
    check code == 0
    if code != 0:
      echo output
    # Deterministic: the same content yields the same map.
    check readFile(mapPath) == before
    # The sibling checkout is untouched, including its ignored files.
    check gitStatus(isonimDir) == isonimBefore
    let isonimWrites = modifiedSince(isonimDir, start, [".git"])
    check isonimWrites.len == 0
    if isonimWrites.len > 0:
      echo "written under ../isonim: ", isonimWrites
    # In this checkout, everything it wrote is under build/ (test-logs/
    # is where the running test's own log goes).
    let strayWrites = modifiedSince(repoRoot, start,
      [".git", "build", "test-logs"])
    check strayWrites.len == 0
    if strayWrites.len > 0:
      echo "written outside build/: ", strayWrites
    check "tailwind-styles.json" in output
    check toSeq(walkDir(repoRoot / "build" / "tailwind-extract")).len > 0
