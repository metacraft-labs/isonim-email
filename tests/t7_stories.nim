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

suite "story registry":
  test "test_story_registry_lists_the_m7a1_set":
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
    check first.text == canaryText
    check first.text.len > 0

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
    check "<title>Security alert</title>" in alertHtml
    check "New sign-in detected." in alertHtml
    check "Security alert" in alertText
