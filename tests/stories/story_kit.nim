## Story kit: the builders the data-table, navigation and raw-markup
## story sets share (`seed_table.nim`, `seed_navigation.nim`,
## `seed_raw.nim`): element and text helpers, a light document with a
## footer, a dark document whose every colour is a theme token with its
## dark pair, and the render that publishes the stories' images (the
## built-in social icons included) to the capture fixture host.
##
## Backend-independent (tree building only), like the seed builders.
import std/strutils
import isonim_email
import fixture_images

type
  KitStory* = tuple[name, description: string;
    build: proc(): EmailNode {.nimcall.}; dark: bool]
    ## One story of a set: its name, description, tree builder and
    ## whether it renders under `darkMode = designed`.

const longWord* = "Supercalifragilisticexpialidociousnessless"
  ## A long unbroken word (the maximal stories' wrapping check).

proc el*(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  if parent != nil:
    r.appendChild(parent, result)

proc txt*(r: EmailRenderer; parent: EmailNode; s: string) =
  r.appendChild(parent, r.createTextNode(s))

proc link*(r: EmailRenderer; parent: EmailNode; href, s: string;
    styles: openArray[(string, string)] = []): EmailNode =
  r.el(parent, "a", styles, [("href", href)], s)

proc storyDoc*(r: EmailRenderer; title, preheader: string;
    rtl = false): EmailNode =
  result = r.el(nil, "mailDocument", [("background-color", "#f4f5f7")],
    [("lang", if rtl: "ar" else: "en"), ("dir", if rtl: "rtl" else: "ltr"),
      ("title", title), ("preheader", preheader)])

proc band*(r: EmailRenderer; doc: EmailNode; bg = "#ffffff";
    padding = "24px 0"): EmailNode =
  r.el(doc, "mailSection", [("background-color", bg), ("padding", padding)])

proc footer*(r: EmailRenderer; doc: EmailNode; rtl = false) =
  let f = r.el(doc, "mailSection", [("background-color", "#1f2937"),
    ("text-align", "center")], [("full_width", "true")])
  let p = r.el(f, "p", [("color", "#f9fafb")])
  r.txt(p, if rtl: "شركة أكمي، ١ شارع المثال، الرياض · " else:
    "Acme Inc., 1 Example Street, Springfield · ")
  discard r.link(p, "https://example.com/unsubscribe",
    if rtl: "إلغاء الاشتراك" else: "Unsubscribe")

proc paint*(r: EmailRenderer; n: EmailNode; prop: string; t: TokenRef) =
  r.setStyle(n, prop, t)
  r.setStyle(n, "@dark:" & prop, t)

proc dkBand*(r: EmailRenderer; doc: EmailNode; surface: TokenRef;
    padding = "24px 0"): EmailNode =
  result = r.el(doc, "mailSection", [("padding", padding)])
  r.paint(result, "background-color", surface)

proc dkText*(r: EmailRenderer; parent: EmailNode; tag, body: string;
    styles: openArray[(string, string)] = [];
    colour = tok"color.text.primary"): EmailNode =
  result = r.el(parent, tag, styles, text = body)
  r.paint(result, "color", colour)

proc dkDoc*(r: EmailRenderer; title, preheader: string): EmailNode =
  ## A dark-designed document: canvas and card tokens, a heading band.
  result = r.el(nil, "mailDocument", attrs = [("lang", "en"),
    ("dir", "ltr"), ("title", title), ("preheader", preheader)])
  r.paint(result, "background-color", tok"color.surface.canvas")

proc dkFooter*(r: EmailRenderer; doc: EmailNode) =
  let f = r.dkBand(doc, tok"color.surface.subtle")
  r.setStyle(f, "text-align", "center")
  discard r.dkText(f, "p", "Acme Inc., 1 Example Street, Springfield",
    [("margin", "0")], tok"color.text.secondary")

proc textOf*(n: EmailNode): string =
  ## The visible text of a tree, one block per line: the stories' plain
  ## text alternative (the plain-text generator will produce these).
  if n.kind == enText:
    return n.text
  if n.kind != enElement:
    return ""
  var inner = ""
  for c in n.children:
    inner.add(textOf(c))
  if n.tag in ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "tr",
      "mailNavLink"]:
    return inner.strip() & "\n"
  inner

proc kitRender*(doc: EmailNode; dark = false): StoryHtml =
  ## Renders a story, publishing its images to the capture fixture host
  ## (the built-in social icons are served from there by the capture
  ## harness, like the story fixtures).
  var t = defaultTarget()
  if dark:
    t.darkMode = dmDesigned
  let text = textOf(doc)
  (renderPipeline(doc, t, memoryAssetStore(fixtureHost)), text)

proc renderOf*(build: proc(): EmailNode {.nimcall.};
    dark: bool): StoryRenderProc =
  ## One story's render closure, in a proc of its own so each closure
  ## captures its own story.
  result = proc(): StoryHtml = kitRender(build(), dark)

proc renderFrom*(stories: openArray[KitStory]; name, what: string): StoryHtml =
  ## The story `name` of a set, rendered.
  for s in stories:
    if s.name == name:
      return kitRender(s.build(), s.dark)
  raise newException(StoryError, "no " & what & " story '" & name & "'")

proc registerKit*(stories: openArray[KitStory];
    groupOf: proc(name: string): string {.nimcall.}) =
  ## Registers a set's stories (env-gated by the drivers) and the trees
  ## their briefs render from.
  for s in stories:
    registerStory(Story(name: s.name, group: groupOf(s.name),
      description: s.description, render: renderOf(s.build, s.dark)))

proc registerKitTrees*(stories: openArray[KitStory]) =
  for s in stories:
    registerStoryTree(s.name, s.build)
