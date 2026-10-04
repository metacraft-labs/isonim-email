## The registered stories through the IsoNim editor's story contract
## (`isonim_email/editor_stories`): the sidebar groups list every
## registered story once, in registration order, grouped as the
## registry groups them, with the item fields the editor's own lookup
## matches on (group, name, kind); the preview hook renders the story a
## sidebar item names into the message's HTML and text part, exactly as
## the story renders; a refused story previews as a page naming its
## error and diagnostics; anything else, and the platforms an email has
## no renderer for, is `ppsUnsupportedStory`.
##
## Also the registry's diagnosed render behind it
## (`renderStoryDiagnosed`), which the preview server reads too: every
## diagnostic a story's render collected, with the source span of the
## line that built the element (the story kit's `el`, the layouts'
## `node`, a `ui(r)` template), and a refusal returned, not raised.
##
## Backend-independent (registry, pure pipeline, the editor's data
## types), so `just test` also runs it on JS.
import std/[sets, strutils, unittest]
import isonim/editor/types except SourceSpan
import isonim_email
import isonim_email/editor_stories
import stories/email_stories
import stories/seed_layout
import stories/seed_primitives
import stories/seed_reference
import reference_set

proc linkedTpl(r: EmailRenderer; name: string): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Linked"):
      mailSection:
        h1: text "Hello, " & name
        p:
          a(href = "/account"): text "Your account"

registerSeedStories()
registerLayoutStories()
registerPrimitiveStories()
registerReferenceStories()
registerStory(Story(name: "linked/relative", group: "linked",
  description: "A template whose link has no page to resolve against.",
  render: proc(): StoryHtml =
    renderStoryPipeline(renderAuthoringTree(linkedTpl, "Ada"),
      defaultTarget())))

proc refOf(item: StoryItem; index: int): StoryRef =
  ## The reference the editor builds from a sidebar item.
  StoryRef(group: item.group, name: item.name, kind: item.kind,
    index: index)

suite "the IsoNim editor's story contract":
  test "test_editor_groups_list_every_registered_story":
    let groups = emailStoryGroups()
    var names: seq[string] = @[]
    var groupNames: seq[string] = @[]
    for g in groups:
      check g.name notin groupNames
      groupNames.add(g.name)
      check g.kind == skPage
      check g.items.len > 0
      for item in g.items:
        check item.group == g.name
        check item.kind == skPage
        check getStory(item.name).group == g.name
        check item.description == getStory(item.name).description
        names.add(item.name)
    # Every registered story, once, and nothing else.
    check names.len == listStories().len
    check names.toHashSet == listStories().toHashSet
    check names.len == names.toHashSet.len
    # Registration order within a group.
    for g in groups:
      var order: seq[string] = @[]
      for n in listStories():
        if getStory(n).group == g.name:
          order.add(n)
      var shown: seq[string] = @[]
      for item in g.items:
        shown.add(item.name)
      check shown == order
    # The groups the sets register under, the reference emails whole.
    check "canary" in groupNames
    check "reference" in groupNames
    check "linked" in groupNames
    for g in groups:
      if g.name == "reference":
        check g.items.len == referenceEmails().len
        check g.items[0].name == "receiptTypical"

  test "test_editor_preview_renders_the_selected_story":
    let groups = emailStoryGroups()
    var rendered = 0
    for g in groups:
      for i, item in g.items:
        if g.name == "linked":
          continue
        let ref0 = refOf(item, i)
        let p = emailPreview(ref0, pbWeb)
        checkpoint(item.name)
        check p.status == ppsRendered
        check p.story.group == item.group
        check p.story.name == item.name
        check p.story.index == i
        check p.title == item.group & " / " & item.name
        check p.metadata.fixtureName == item.name
        check p.metadata.renderKind == emailRenderKind
        let (html, text) = getStory(item.name).render()
        check p.documentHtml == html
        check p.bodyText == text
        inc rendered
    check rendered == listStories().len - 1
    # The hook is the same preview, as the workspace calls it.
    let hook = emailPreviewHook()
    let one = StoryRef(group: "reference", name: "receiptTypical",
      kind: skPage)
    check hook(one, pbWeb).documentHtml ==
      getStory("receiptTypical").render().html
    check hook(one, pbWeb).story.index == 0

  test "test_editor_preview_refuses_what_it_cannot_show":
    # Not registered, in another group, of another kind, or no story.
    for s in [StoryRef(group: "reference", name: "noSuchEmail", kind: skPage),
        StoryRef(group: "canary", name: "receiptTypical", kind: skPage),
        StoryRef(group: "reference", name: "receiptTypical",
          kind: skComponent),
        StoryRef()]:
      checkpoint(s.group & "/" & s.name)
      let p = emailPreview(s, pbWeb)
      check p.status == ppsUnsupportedStory
      check p.documentHtml.len == 0
    # An email has no renderer on the streaming platforms.
    let tui = emailPreview(StoryRef(group: "canary", name: "canary",
      kind: skPage), pbTui)
    check tui.status == ppsUnsupportedStory
    check tui.title == "canary / canary"
    check tui.documentHtml.len == 0
    check emailEditorPlatforms == {pbWeb}

  test "test_editor_preview_of_a_refused_story_names_the_error":
    let p = emailPreview(StoryRef(group: "linked", name: "linked/relative",
      kind: skPage), pbWeb)
    check p.status == ppsRendered
    check "linked/relative was refused" in p.documentHtml
    check "E-URL-SCHEME" in p.documentHtml
    check "/account" in p.documentHtml
    check "t7_editor_stories.nim:" in p.documentHtml
    # The text the editor shows beside it is the refusal itself.
    check "failed validation" in p.bodyText
    check "/account" in p.bodyText

suite "a story's diagnosed render":
  test "test_story_render_diagnosed_collects_diagnostics_and_spans":
    # The seed alert: one warning (its icon's alt does not fit), from
    # a hand-built tree, so no span.
    let alert = renderStoryDiagnosed(getStory("alert"))
    check alert.error.len == 0
    check alert.html == getStory("alert").render().html
    var codes: seq[string] = @[]
    for d in alert.diagnostics:
      codes.add(d.code)
    check codeImgAltFit in codes
    # A reference email: its layout's elements carry the line of the
    # layout or of the reference set that built them.
    var located = 0
    for name in listStories():
      let res = renderStoryDiagnosed(getStory(name))
      check res.error.len == 0 or name == "linked/relative"
      for d in res.diagnostics:
        if d.origin.file.len > 0:
          check d.origin.line > 0
          check d.origin.file.endsWith(".nim")
          inc located
    check located > 0
    # The layouts' `node` names the line that built the element: in the
    # layout itself, or in the reference email's own template.
    let ref1 = renderStoryDiagnosed(getStory("alertCritical"))
    var inLayout, inEmail = 0
    for d in ref1.diagnostics:
      if d.origin.file.endsWith("frame.nim"):
        inc inLayout
      if d.origin.file.endsWith("reference_set.nim"):
        inc inEmail
    check inLayout > 0
    check inEmail > 0
    # Each render starts from nothing, and a story rendered the plain
    # way (as the capture driver and the goldens do) leaves nothing
    # behind for the next: the same diagnostics twice.
    for name in ["alert", "alertCritical", "receiptTypical"]:
      discard getStory(name).render()
    check renderStoryDiagnosed(getStory("alert")).diagnostics.len ==
      alert.diagnostics.len

  test "test_story_render_diagnosed_returns_the_refusal":
    let res = renderStoryDiagnosed(getStory("linked/relative"))
    check res.html.len == 0
    check "failed validation" in res.error
    check "/account" in res.error
    var found = false
    for d in res.diagnostics:
      if d.code == codeUrlScheme:
        found = true
        check d.origin.file.endsWith("t7_editor_stories.nim")
        check d.origin.line > 0
        check d.rules == @["R-TXT-13"]
    check found
    # The registry's own render still raises for it.
    var raised = false
    try:
      discard getStory("linked/relative").render()
    except StoryError:
      raised = true
    check raised
