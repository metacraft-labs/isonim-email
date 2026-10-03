## tools/review/brief_driver.nim — brief-file emitter.
##
## Briefs made files: for one story, writes
## `brief-<family>-<viewport>-<scheme>.md` for every combination of
## the requested matrix into `<outDir>` (the story's run dir, created
## when missing). `email-shots.ts` step 1b invokes it once per story
## after the `.eml` write.
##
## Usage: brief_driver <story> <outDir> [families] [viewports] [schemes]
## (comma-separated; an absent matrix axis means the full backend-A
## default — the `briefFamilies`/`briefViewports`/`briefSchemes`
## mirror of the email-shots.ts matrix).
##
## A real client's captures get their own briefs:
## brief_driver --client <backend> <family> <client> <story> <outDir>
##   <viewports> <schemes>
## writes `brief-<backend>-<family>-<client>-<viewport>-<scheme>.md`
## for each combination; a client the generator does not know, or
## knows under another backend or family, fails (exit 1).
import std/[os, sequtils, strutils]
import isonim_email
import stories/email_stories
import stories/seed_broken
import stories/seed_receipt
import stories/seed_alert
import stories/seed_overflow
import stories/seed_sanitiser_probe
import stories/seed_layout
import stories/seed_primitives
import stories/seed_leaves
import stories/seed_buttons
import stories/seed_table
import stories/seed_backgrounds
import stories/seed_navigation
import stories/seed_raw

proc splitMatrix(s: string): seq[string] =
  for part in s.split(','):
    let item = part.strip()
    if item.len > 0:
      result.add(item)

proc defaultViewports(): seq[string] =
  for (name, _) in briefViewports:
    result.add(name)

proc registerAll() =
  registerSeedStories()
  registerStoryTree("canary", canaryDoc)
  registerStoryTree("receipt", proc(): EmailNode = seedReceipt())
  registerStoryTree("alert", proc(): EmailNode = seedAlert())
  if getEnv("ISONIM_CAPTURE_FIXTURES") == "1":
    # Tier-3 fixtures (see build_stories.nim): twins plus the
    # trees their briefs render from.
    registerOverflowStories()
    registerStoryTree("overflowFixed", overflowFixedDoc)
    registerStoryTree("overflowFluid", overflowFluidDoc)
    registerSanitiserProbeStory()
    registerStoryTree("sanitiserProbe", sanitiserProbeDoc)
    # The broken receipt's brief is the intact receipt's: the break is
    # in the output only.
    registerBrokenStories()
    registerStoryTree("receiptB",
      proc(): EmailNode = seedReceipt())
  if getEnv("ISONIM_CAPTURE_LAYOUT") == "1":
    # The layout reference stories (see build_stories.nim).
    registerLayoutStories()
    registerStoryTree("layoutOneColumn", layoutOneColumnDoc)
    registerStoryTree("layoutTwoColumns", layoutTwoColumnsDoc)
    registerStoryTree("layoutThreeColumns", layoutThreeColumnsDoc)
    registerStoryTree("layoutFourColumns", layoutFourColumnsDoc)
    registerPrimitiveStories()
    registerPrimitiveStoryTrees()
    registerLeafStories()
    registerLeafStoryTrees()
    registerButtonStories()
    registerButtonStoryTrees()
    registerTableStories()
    registerTableStoryTrees()
    registerNavigationStories()
    registerNavigationStoryTrees()
    registerRawStories()
    registerRawStoryTrees()
    registerBackgroundStories()
    registerBackgroundStoryTrees()

proc clientMain(args: seq[string]): int =
  ## `--client <backend> <family> <client> <story> <outDir> <viewports>
  ## <schemes>`.
  if args.len != 8:
    stderr.writeLine("usage: brief_driver --client <backend> <family> " &
      "<client> <story> <outDir> <viewports> <schemes>")
    return 2
  let (backend, family, client) = (args[1], args[2], args[3])
  registerAll()
  try:
    let mismatch = briefClientMismatch(backend, family, client)
    if mismatch.len > 0:
      stderr.writeLine("brief_driver: " & mismatch)
      return 1
    let story = getStory(args[4])
    createDir(args[5])
    for viewport in splitMatrix(args[6]):
      for scheme in splitMatrix(args[7]):
        writeFile(args[5] / clientBriefName(backend, family, client,
          viewport, scheme),
          clientExpectedBlock(story, client, viewport, scheme))
  except StoryError as e:
    stderr.writeLine("brief_driver: " & e.msg)
    return 1
  except BriefError as e:
    stderr.writeLine("brief_driver: " & e.msg)
    return 1
  0

proc main(): int =
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--client":
    return clientMain(args)
  if args.len < 2 or args.len > 5:
    stderr.writeLine(
      "usage: brief_driver <story> <outDir> [families] [viewports] " &
      "[schemes]")
    return 2
  registerAll()
  let families =
    if args.len > 2: splitMatrix(args[2])
    else: briefFamilies.toSeq()
  let viewports =
    if args.len > 3: splitMatrix(args[3])
    else: defaultViewports()
  let schemes =
    if args.len > 4: splitMatrix(args[4])
    else: briefSchemes.toSeq()
  try:
    let story = getStory(args[0])
    createDir(args[1])
    for family in families:
      for viewport in viewports:
        for scheme in schemes:
          let name = "brief-" & family & "-" & viewport & "-" &
            scheme & ".md"
          writeFile(args[1] / name,
            expectedBlock(story, family, viewport, scheme))
  except StoryError as e:
    stderr.writeLine("brief_driver: " & e.msg)
    return 1
  except BriefError as e:
    stderr.writeLine("brief_driver: " & e.msg)
    return 1
  0

when isMainModule:
  quit(main())
