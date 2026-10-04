## The reference emails (`examples/reference_set.nim`) as stories: each
## rendered with its images published to the capture fixture host (the
## render's own asset store), and refused when it reports an error, as
## every story is.
##
## Env-gated like the element sets: the drivers register them only under
## `ISONIM_CAPTURE_LAYOUT=1`, outside the regression matrix.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import story_kit
import reference_set

proc renderReference*(e: ReferenceEmail;
    target = defaultTarget()): RenderedEmail =
  ## `e` rendered with `target` (its dark mode set by the entry), its
  ## images published to the fixture host.
  e.render(target, fixtureStore())

proc storyOf(e: ReferenceEmail): StoryRenderProc =
  ## The story's render closure: the HTML and text, or a `StoryError`
  ## naming the first error; its diagnostics are noted for the readers
  ## of a story's diagnostics (the preview server, the editor).
  result = proc(): StoryHtml =
    let res = renderReference(e)
    noteStoryDiagnostics(res.diagnostics)
    for d in res.diagnostics:
      if d.severity == sevError:
        raise newException(StoryError, "reference email '" & e.name &
          "': " & d.code & ": " & d.message)
    (res.html, res.text)

proc registerReferenceStories*() =
  ## Registers every reference email as a story (env-gated, see above).
  for e in referenceEmails():
    registerStory(Story(name: e.name, group: "reference",
      description: e.description, render: storyOf(e)))

proc registerReferenceStoryTrees*() =
  ## The trees the briefs of those stories render from.
  for e in referenceEmails():
    registerStoryTree(e.name, e.tree,
      if e.dark: dmDesigned else: dmAccommodate)
