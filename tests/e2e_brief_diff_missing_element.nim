## E2e brief diff: a removed element is reported missing by the
## expected-elements diff.
##
## What this test is: a comparison of two generated text briefs. A
## fixture story WITH a hero mailImage (alt 'Hero banner') has its
## expected block approved as a baseline (written to tmp, read back);
## a broken variant renders without the hero; `diffExpectedBlocks`
## reports the hero as missing; and `rateFinding`
## (tools/review/findings.ts, the real module via node) turns one
## missing element into a rating of at most 4, the brief's report
## rule. The falsifying direction pins that the broken tree's own
## brief omits the hero.
##
## What this test is not: a review. No reviewer runs and no screenshot
## is looked at, so it does not show that a reviewer reading a real
## capture notices the missing hero. That check needs a real reviewer
## sub-agent on a real capture and stays unverified until one runs; the
## brief diff here only proves the brief side of it (the expected block
## names the element, and its absence is mechanically detectable).
##
## C-only: writes the baseline to tmp and shells out to node (the
## e2e_local_shots_latency precedent). A missing node fails loudly
## instead of skipping (allowed_mocks: None).
import std/[os, osproc, strutils, unittest]
import isonim_email

const repoRoot = parentDir(parentDir(currentSourcePath()))
  ## Resolved at compile time, so the test works whatever the
  ## runner's working directory is.

proc seedHero*(includeHero = true): EmailNode =
  ## Brief-diff fixture: an `h1`, an optional 600 px hero image, and
  ## a footer paragraph with an Unsubscribe link (only elements with a
  ## lowering, so the story renders).
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Hero story")
  r.setAttribute(doc, "preheader", "A hero above the fold.")
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Welcome back")
  r.appendChild(doc, h1)
  if includeHero:
    let hero = r.createElement("mailImage")
    r.setAttribute(hero, "src", "https://x.test/hero.png")
    r.setAttribute(hero, "alt", "Hero banner")
    r.setStyle(hero, "width", "600px")
    r.appendChild(doc, hero)
  let foot = r.createElement("p")
  let unsub = r.createElement("a")
  r.setAttribute(unsub, "href", "https://x.test/unsub")
  r.setTextContent(unsub, "Unsubscribe")
  r.appendChild(foot, unsub)
  r.appendChild(doc, foot)
  doc

const heroText = "Welcome back\n\nA hero above the fold.\n"
  ## Fixed plain-text alternative for the fixture (the plain-text
  ## generator will produce these).

registerStory(Story(name: "heroStory", group: "review",
  description: "Brief-diff fixture: h1, hero image, footer.",
  render: proc(): StoryHtml =
    (renderPipeline(seedHero(), defaultTarget()), heroText)))
registerStoryTree("heroStory", proc(): EmailNode = seedHero())
registerStory(Story(name: "heroStory-broken", group: "review",
  description: "Broken variant: the hero image removed.",
  render: proc(): StoryHtml =
    (renderPipeline(seedHero(false), defaultTarget()), heroText)))
registerStoryTree("heroStory-broken", proc(): EmailNode = seedHero(false))

proc rateViaFindings(missing: int): int =
  ## The brief's mechanical rating rule, computed by the real
  ## tools/review/findings.ts (node type-strips the .ts, the
  ## email-shots.ts precedent).
  if findExe("node").len == 0:
    raise newException(OSError,
      "node not found on PATH — refusing to skip (allowed_mocks: " &
      "None). Run under the dev shell (`nix develop` in isonim-email).")
  let (output, code) = execCmdEx(
    "node --input-type=module -e \"import('./tools/review/" &
    "findings.ts').then(m => console.log(m.rateFinding(" & $missing &
    ")))\"", workingDir = repoRoot)
  if code != 0:
    raise newException(OSError,
      "rateFinding via node failed:\n" & output)
  output.strip().parseInt()

suite "e2e brief diff reports a missing element":
  test "test_e2e_brief_diff_reports_missing_element":
    # Approve the baseline: the full tree's block, via a tmp file.
    let approved = expectedBlock(getStory("heroStory"), "gmailWeb",
      "mobile", "light")
    let baselinePath = getTempDir() / "isonim-e2e-review-baseline-" &
      $getCurrentProcessId() & ".md"
    writeFile(baselinePath, approved)
    let baseline = readFile(baselinePath)
    removeFile(baselinePath)

    # The broken variant's current-tree block.
    let current = expectedBlock(getStory("heroStory-broken"),
      "gmailWeb", "mobile", "light")

    # Pin 1: the baseline contains the hero.
    check "Hero banner" in baseline
    check "Hero image \"Hero banner\", ~600 px wide" in baseline
    # Pin 2 (falsifying direction): the current-tree brief omits it.
    check "Hero banner" notin current
    check "Hero image" notin current
    # The rest of the block survives the breakage.
    check "Heading \"Welcome back\" (largest text)." in current
    # Pin 3: the diff reports exactly the missing hero.
    let missing = diffExpectedBlocks(baseline, current)
    check missing.len == 1
    check "Hero banner" in missing[0]
    # Pin 4: the mechanical rating rule caps at 4.
    let rating = rateViaFindings(missing.len)
    echo "missing elements: " & $missing.len & " (" & missing[0] &
      "), rateFinding → " & $rating
    check rating <= 4
