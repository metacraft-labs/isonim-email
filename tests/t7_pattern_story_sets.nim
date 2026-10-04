## Every registered primitive and pattern ships its story set
## (layout-patterns.md §5): `<name>Minimal`, `Maximal`, `Rtl`,
## `ImagesOff`, `Dark` and `InContext`, the name being the element's
## without its `mail` prefix, first letter lower-cased (`mailCard` →
## `cardMinimal`, `codeInline` → `codeInlineRtl`).
##
## The rule's two exceptions, and only these:
##
## - an item element (a registered pattern with `itemOf` set:
##   `mailStep`, `mailSocialItem`, `mailNavLink`) is covered by its
##   parent's stories, the parent being registered and not an item
##   itself;
## - a pattern that refuses right to left has no `Rtl` story:
##   `mailZigZag` (R-LAY-11).
##
## A pattern registered later without its six stories fails here.
##
## C backend only: registers every capture story set, as the text-part
## goldens test does.
import std/[algorithm, sequtils, strutils, unittest]
import isonim_email
import stories/seed_layout
import stories/seed_primitives
import stories/seed_leaves
import stories/seed_buttons
import stories/seed_table
import stories/seed_navigation
import stories/seed_raw
import stories/seed_backgrounds
import stories/seed_dark
import stories/seed_structure
import stories/seed_media
import stories/seed_containers
import stories/seed_data
import stories/seed_actions

registerLayoutStories()
registerPrimitiveStories()
registerLeafStories()
registerButtonStories()
registerTableStories()
registerNavigationStories()
registerRawStories()
registerBackgroundStories()
registerDarkStories()
registerStructureStories()
registerMediaStories()
registerContainerStories()
registerDataStories()
registerActionStories()

const
  storyKinds = ["Minimal", "Maximal", "Rtl", "ImagesOff", "Dark",
    "InContext"]
  rtlRefused = ["mailZigZag"]
    ## Patterns that refuse right to left (R-LAY-11): no `Rtl` story.

proc storyPrefix(name: string): string =
  ## `mailCard` → `card`; a name without the prefix (`codeInline`) as is.
  let bare = if name.startsWith("mail"): name[4 .. ^1] else: name
  bare[0 .. 0].toLowerAscii() & bare[1 .. ^1]

suite "every pattern ships its story set":
  test "test_pattern_story_set_complete":
    let names = patternNames()
    # Vacuity guard: the registry holds the primitives and every part of
    # the content patterns, and exactly the three item elements.
    check names.len >= 38
    let items = names.filterIt(patternOf(it).itemOf.len > 0)
    check items.sorted() == @["mailNavLink", "mailSocialItem", "mailStep"]
    var checked = 0
    for name in names:
      let parent = patternOf(name).itemOf
      if parent.len > 0:
        # Covered by its parent's stories, which are checked below.
        check isPattern(parent)
        check patternOf(parent).itemOf.len == 0
        continue
      inc checked
      let prefix = storyPrefix(name)
      for kind in storyKinds:
        if kind == "Rtl" and name in rtlRefused:
          check not hasStory(prefix & kind)
          continue
        if not hasStory(prefix & kind):
          checkpoint(name & " has no story " & prefix & kind)
        check hasStory(prefix & kind)
    check checked == names.len - 3
    # The exceptions are what they say: a refused pattern is registered.
    for name in rtlRefused:
      check isPattern(name)
