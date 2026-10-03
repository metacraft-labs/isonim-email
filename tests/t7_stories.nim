## The story registry.
##
## The seed set (canary + receipt + alert seeds) registers,
## duplicates and unknown names fail loudly, and rendering is
## deterministic: the canary renders byte-identical twice, and every
## story yields a full document plus a non-empty text part.
##
## Backend-independent (registry + pure pipeline), so `just test`
## also runs it on JS.
import std/[strutils, unittest]
import isonim_email
import stories/email_stories

registerSeedStories()

proc welcomeTpl(r: EmailRenderer; name: string): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Welcome"):
      mailSection:
        h1: text "Welcome, " & name
        p: text "Glad you are here."

suite "story registry":
  test "test_story_registry_lists_the_seed_set":
    check listStories() == @["canary", "receipt", "alert"]
    check hasStory("canary")
    check hasStory("receipt")
    check hasStory("alert")
    check not hasStory("invoiceReady/typical")

  test "test_story_registry_rejects_duplicates":
    var raised = false
    try:
      registerStory(canaryStory())
    except StoryError:
      raised = true
    check raised

  test "test_story_registry_rejects_empty_name_and_nil_render":
    var raisedEmpty = false
    try:
      registerStory(Story(name: "", group: "x", description: "x",
        render: renderCanary))
    except StoryError:
      raisedEmpty = true
    check raisedEmpty
    var raisedNil = false
    try:
      registerStory(Story(name: "nil-render", group: "x",
        description: "x", render: nil))
    except StoryError:
      raisedNil = true
    check raisedNil

  test "test_story_registry_unknown_name_fails_loudly":
    var raised = false
    try:
      discard getStory("no-such-story")
    except StoryError as e:
      raised = true
      check "no-such-story" in e.msg
      check "canary" in e.msg
    check raised

  test "test_canary_renders_deterministically":
    # The determinism anchor: two renders, identical bytes.
    let first = renderCanary()
    let second = renderCanary()
    check first.html == second.html
    check first.text == second.text
    check first.html.startsWith("<!doctype html><html")
    check "<title>Canary</title>" in first.html
    check "The canary sings at noon." in first.html
    # The text part is generated from the same tree (the plain-text
    # pass): the heading underlined, the preheader left out.
    check first.text == "Canary\n======\n\nThe canary sings at noon.\n"

  test "test_seed_stories_render_full_documents":
    for name in ["receipt", "alert"]:
      let story = getStory(name)
      let (html, text) = story.render()
      check html.startsWith("<!doctype html><html")
      check text.len > 0
    let (receiptHtml, receiptText) = getStory("receipt").render()
    check "<title>Receipt #1234</title>" in receiptHtml
    check "Thanks for your order." in receiptHtml
    check "Receipt #1234" in receiptText
    let (alertHtml, alertText) = getStory("alert").render()
    check "<title>تنبيه أمني</title>" in alertHtml
    check "تم رصد تسجيل دخول جديد." in alertHtml
    check "تنبيه أمني" in alertText

  test "story registers a template with its data; stories iterates":
    # Registered here, after the set pins above ran.
    story("welcome/typical", welcomeTpl, "Ada")
    story("welcome/wide", welcomeTpl, "Grace"):
      target.outlookWord = false
    var names: seq[string] = @[]
    for entry in stories():
      names.add(entry.name)
    check names == @["canary", "receipt", "alert", "welcome/typical",
      "welcome/wide"]
    let typical = getStory("welcome/typical")
    check typical.group == "welcome"
    let (html, _) = typical.render()
    check html.startsWith("<!doctype html><html")
    check "Welcome, Ada" in html
    # The body's override reaches the render; the default does not
    # carry it.
    let (wide, _) = getStory("welcome/wide").render()
    check "Welcome, Grace" in wide
    check "OfficeDocumentSettings" notin wide
    check "OfficeDocumentSettings" in html
    expect StoryError:
      story("welcome/typical", welcomeTpl, "Duplicate")
