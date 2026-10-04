## isonim_email/editor_stories.nim — the registered stories through the
## IsoNim editor's story contract.
##
## The editor lists a project's stories as `StoryGroup`s of `StoryItem`s
## and asks the project for each selected story's preview through a
## `ProjectPreviewHook` (`isonim/editor/types`). This module builds both
## from the story registry (`stories.nim`), so the editor lists every
## registered email and shows the one selected as the message's HTML:
##
## ```nim
## import isonim/editor
## import isonim_email/editor_stories
## registerMyStories()            # the project's own registrations
## let ws = newEditorWorkspace("Email", emailStoryGroups(),
##   previewHook = emailPreviewHook(),
##   allowedPlatforms = emailEditorPlatforms)
## ```
##
## Each registry group (`Story.group`) is one `StoryGroup`, in the order
## its first story was registered, holding its stories in registration
## order. Every story is a whole message, so every item is a page
## (`skPage`). The hook renders the selected story on the Web platform
## (the editor shows a page's `documentHtml` in an iframe there): the
## preview's `documentHtml` is the message's HTML, its `bodyText` the
## plain-text part. A story whose render refused it previews as a page
## naming the error and the diagnostics found before it. Other platforms
## stream frames from a renderer of their own, which an email does not
## have: the hook answers `ppsUnsupportedStory` for them.
##
## Only the editor's data types are imported (no view models, no
## browser code), so this module builds on the C and JS targets like
## the rest of the library. It is not part of the umbrella module:
## import it where an editor workspace is assembled.

import std/[strutils, tables]
import isonim/editor/types except SourceSpan
import ./diagnostics
import ./stories

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run. None:
## it only hands rendered stories to the editor.
const affects*: set[ClientFamily] = {}

const
  emailStoryKind* = skPage
    ## The kind of every email story: each one is a whole message.
  emailRenderKind* = "email"
    ## `StoryRenderMetadata.renderKind` of an email story's preview.
  emailEditorPlatforms*: set[PreviewBackend] = {pbWeb}
    ## The platforms an email story previews on, for the workspace's
    ## `allowedPlatforms`.

proc emailStoryGroups*(): seq[StoryGroup] =
  ## The registered stories as the editor's sidebar groups (see the
  ## module comment).
  var at = initTable[string, int]()
  for s in stories():
    if s.group notin at:
      at[s.group] = result.len
      result.add(StoryGroup(name: s.group, kind: emailStoryKind))
    result[at[s.group]].items.add(StoryItem(name: s.name,
      description: s.description, kind: emailStoryKind, group: s.group))

proc findStory(story: StoryRef; found: var Story; index: var int): bool =
  ## The registered story `story` names (group, name and kind all
  ## match, as the editor's own lookup requires), and its position in
  ## its group.
  if story.kind != emailStoryKind:
    return false
  var i = 0
  for s in stories():
    if s.group != story.group:
      continue
    if s.name == story.name:
      found = s
      index = i
      return true
    inc i

proc escapeHtml(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
    ("\"", "&quot;"))

proc refusedDocument(name: string; res: StoryRender): string =
  ## The page a refused story previews as: the error, then every
  ## diagnostic found before it, each with its source span when it has
  ## one.
  result = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" &
    "<title>" & escapeHtml(name) & ": refused</title></head><body>" &
    "<h1>" & escapeHtml(name) & " was refused</h1><p>" &
    escapeHtml(res.error) & "</p><ul>"
  for d in res.diagnostics:
    result.add("<li><code>" & escapeHtml(d.code) & "</code> " &
      escapeHtml(d.message))
    if d.origin.file.len > 0:
      result.add(" <small>(" & escapeHtml(d.origin.file) & ":" &
        $d.origin.line & ")</small>")
    result.add("</li>")
  result.add("</ul></body></html>")

proc emailPreview*(story: StoryRef; platform: Platform): ProjectPreview =
  ## The editor's preview of `story` (see the module comment).
  var found: Story
  var index = -1
  if not findStory(story, found, index):
    return ProjectPreview(status: ppsUnsupportedStory, story: story)
  let canonical = StoryRef(group: found.group, name: found.name,
    kind: emailStoryKind, index: index)
  let metadata = StoryRenderMetadata(story: canonical,
    title: found.group & " / " & found.name, fixtureName: found.name,
    renderKind: emailRenderKind)
  if platform notin emailEditorPlatforms:
    return ProjectPreview(status: ppsUnsupportedStory, story: canonical,
      title: metadata.title, metadata: metadata)
  let res = renderStoryDiagnosed(found)
  ProjectPreview(status: ppsRendered, story: canonical,
    title: metadata.title,
    bodyText: (if res.error.len > 0: res.error else: res.text),
    documentHtml: (if res.error.len > 0: refusedDocument(found.name, res)
      else: res.html),
    metadata: metadata)

proc emailPreviewHook*(): ProjectPreviewHook =
  ## `emailPreview` as the workspace's preview hook.
  result = proc(story: StoryRef; platform: Platform): ProjectPreview =
    emailPreview(story, platform)
