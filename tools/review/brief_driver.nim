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
import std/[os, sequtils, strutils]
import isonim_email
import stories/email_stories
import stories/seed_receipt
import stories/seed_alert
import stories/seed_overflow
import stories/seed_sanitiser_probe

proc splitMatrix(s: string): seq[string] =
  for part in s.split(','):
    let item = part.strip()
    if item.len > 0:
      result.add(item)

proc defaultViewports(): seq[string] =
  for (name, _) in briefViewports:
    result.add(name)

proc main(): int =
  let args = commandLineParams()
  if args.len < 2 or args.len > 5:
    stderr.writeLine(
      "usage: brief_driver <story> <outDir> [families] [viewports] " &
      "[schemes]")
    return 2
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
