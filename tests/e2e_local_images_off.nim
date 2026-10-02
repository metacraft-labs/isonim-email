## E2e: images off, every story keeps its information.
##
## `e2e_local_images_off_readable` renders the images-off stories of
## the layout primitives and of the content leaves (icons, badges,
## avatars, thumbnails, a box picture, a cover) and measures them in the
## pinned Chromium, WebKit and Firefox with every image source emptied
## (`tools/capture/alt_geometry.ts`, backend A's imagesOff transform),
## at a phone and a desktop width:
##
## - Chromium and Firefox draw every image's alt, and each image's box
##   is at least as wide as the alt's longest word: no alt is clipped to
##   a narrow image (an icon's alt shows whole);
## - WebKit draws the alt of every image except those the render
##   reported with `W-IMG-ALT-FIT` (an alt wider than its image on one
##   line, which WebKit never draws): what the library cannot get shown
##   is declared, and everything else shows;
## - no page is wider than its viewport, and the bands keep their
##   background colours (the footer's dark band is there).
##
## No test doubles: the real library, the real transform, the real
## pinned browsers (allowed_mocks: None). C-only: writes files and spawns
## node. A missing node or browser tree fails loudly instead of
## skipping.
import std/[json, os, osproc, sets, strutils, unittest]
import isonim_email
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

const stories = ["boxImagesOff", "gridImagesOff", "clusterImagesOff",
  "sidebarImagesOff", "textImagesOff", "imageImagesOff", "imageInContext",
  "spacerImagesOff", "dividerImagesOff"]

proc buildOf(name: string): EmailNode =
  for s in primitiveStories:
    if s.name == name:
      return s.build()
  for s in leafStories:
    if s.name == name:
      return s.build()
  raise newException(ValueError, "no story " & name)

suite "images off":
  test "e2e_local_images_off_readable":
    # rule: R-IMG-03
    requireTools()
    let work = repoRoot / "build" / "e2e-images-off-" & $getCurrentProcessId()
    createDir(work)
    defer: removeDir(work)
    var declared = initHashSet[string]()
    for name in stories:
      let res = renderTree(buildOf(name))
      check not hasErrors(res.diagnostics)
      for d in res.diagnostics:
        if d.code == codeImgAltFit:
          # "… for this {w}px image: '{alt}' does not fit …" (an alt
          # may hold an apostrophe).
          declared.incl(d.message.split("image: '")[1].split(
            "' does not fit")[0])
      writeFile(work / name & ".html", res.html)
    let outFile = work / "alt.json"
    let (output, code) = execCmdEx("node " & quoteShell(repoRoot /
      "tools/capture/alt_geometry.ts") & " " & quoteShell(work) & " " &
      quoteShell(outFile) & " --viewports 375,800", workingDir = repoRoot)
    checkpoint(output)
    check code == 0
    let pages = parseJson(readFile(outFile))
    check pages.len == stories.len * 3 * 2
    # The ones WebKit cannot show are the narrow icons, badges and
    # avatars, and only those.
    check "Mastodon" in declared
    check "The hill at dawn" notin declared
    var measured = 0
    for page in pages:
      let where = page["file"].getStr & " " & page["engine"].getStr & " " &
        $page["viewport"].getInt
      checkpoint(where)
      check page["scrollWidth"].getInt <= page["viewport"].getInt
      var bgs: seq[string] = @[]
      for b in page["backgrounds"]:
        bgs.add(b.getStr)
      check "#1f2937" in bgs
      for im in page["images"]:
        let alt = im["alt"].getStr
        checkpoint(where & " '" & alt & "' " & $im)
        inc measured
        if page["engine"].getStr == "webkit":
          if alt notin declared:
            check im["drawn"].getBool
        else:
          check im["drawn"].getBool
          check im["width"].getFloat + 0.5 >= im["wordWidth"].getFloat
    check measured > 60
