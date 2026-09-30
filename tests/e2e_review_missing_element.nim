## E2e review: the review loop catches a missing element.
##
## The mechanical form of methodology checklist item 7 ("verify the
## first review surfaces 'missing element' findings when you
## deliberately break a view"): a fixture story WITH a hero mailImage
## (alt 'Hero banner') has its expected block approved as a baseline
## (written to tmp, read back); a broken variant renders without the
## hero; `diffExpectedBlocks` (the brief-diff check) reports the hero
## as missing; and `rateFinding` (tools/review/findings.ts, the real
## module via node) caps the rating at ≤ 4 per the brief's report
## format. The falsifying direction pins that the current (broken)
## tree's own brief omits the hero.
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
  ## Review fixture: an `h1`, an optional 600 px hero image, and a
  ## footer section with an Unsubscribe link.
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
  let foot = r.createElement("mailSection")
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
  description: "Review fixture: h1, hero image, footer.",
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

suite "e2e review catches a missing element":
  test "test_e2e_review_catches_missing_element":
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
