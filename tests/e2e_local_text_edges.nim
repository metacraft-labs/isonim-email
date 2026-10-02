## E2e: no text is cut off at the top of the reading pane.
##
## `e2e_local_text_not_clipped_at_the_top` renders the seed stories
## (canary, receipt, alert), the content leaves' stories and the layout
## primitives' stories, and loads each in the pinned Chromium, WebKit
## and Firefox at a phone (375 px at 3×) and a desktop width
## (`tools/capture/edge_ink.ts`): the first two device-pixel rows of
## every page hold no ink, only the background of whatever band starts
## the message. The canary, whose heading sits directly in the document,
## is the case that regressed: with no band around it, WebKit drew the
## heading's glyphs above the top edge.
##
## No test doubles: the real library, the real pinned browsers
## (allowed_mocks: None). C-only: writes files and spawns node. A
## missing node or browser tree fails loudly instead of skipping.
import std/[json, os, osproc, unittest]
import isonim_email
import stories/email_stories
import stories/seed_primitives
import stories/seed_leaves

const repoRoot = parentDir(parentDir(currentSourcePath()))

proc requireTools() =
  if findExe("node").len == 0:
    raise newException(OSError, "node not found on PATH — refusing to " &
      "skip (allowed_mocks: None). Run under the dev shell.")
  let dir = getEnv("PLAYWRIGHT_BROWSERS_PATH")
  if dir.len == 0 or not dirExists(dir):
    raise newException(OSError, "PLAYWRIGHT_BROWSERS_PATH is not set to " &
      "a readable directory — refusing to skip (allowed_mocks: None).")

suite "text at the edges":
  test "e2e_local_text_not_clipped_at_the_top":
    # rule: R-LAY-08
    requireTools()
    let work = repoRoot / "build" / "e2e-text-edges-" & $getCurrentProcessId()
    createDir(work)
    defer: removeDir(work)
    writeFile(work / "canary.html", renderCanary().html)
    writeFile(work / "receipt.html", renderReceipt().html)
    writeFile(work / "alert.html", renderAlert().html)
    for s in leafStories:
      writeFile(work / s.name & ".html", renderLeafStory(s.name).html)
    for s in primitiveStories:
      writeFile(work / s.name & ".html", renderPrimitiveStory(s.name).html)
    let outFile = work / "edges.json"
    let (output, code) = execCmdEx("node " & quoteShell(repoRoot /
      "tools/capture/edge_ink.ts") & " " & quoteShell(work) & " " &
      quoteShell(outFile) & " --viewports 375@3,800", workingDir = repoRoot)
    checkpoint(output)
    check code == 0
    let pages = parseJson(readFile(outFile))
    check pages.len == (3 + leafStories.len + primitiveStories.len) * 3 * 2
    for page in pages:
      checkpoint($page)
      check page["inkTop"].getInt == 0
