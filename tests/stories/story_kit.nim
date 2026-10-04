## Story kit: the builders the data-table, navigation and raw-markup
## story sets share (`seed_table.nim`, `seed_navigation.nim`,
## `seed_raw.nim`): element and text helpers, a light document with a
## footer, a dark document whose every colour is a theme token with its
## dark pair, and the render that publishes the stories' images (the
## built-in social icons included) to the capture fixture host.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import fixture_images
when not defined(js):
  import std/os

type
  KitStory* = tuple[name, description: string;
    build: proc(): EmailNode {.nimcall.}; dark: bool]
    ## One story of a set: its name, description, tree builder and
    ## whether it renders under `darkMode = designed`.

const longWord* = "Supercalifragilisticexpialidociousnessless"
  ## A long unbroken word (the maximal stories' wrapping check).

proc elAt*(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)]; attrs: openArray[(string, string)];
    text: string; at: SourceSpan): EmailNode =
  result = r.createElement(tag)
  result.origin = at
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  if parent != nil:
    r.appendChild(parent, result)

template el*(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  ## An element appended to `parent` (when given), its source span the
  ## line calling `el`: a diagnostic about it names the story's line.
  elAt(r, parent, tag, styles, attrs, text,
    callerSpan(instantiationInfo(-1, fullPaths = true)))

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

proc fixtureStore*(): AssetStore =
  ## The capture fixture host as an asset store. The images a render
  ## derives (the crops the asset pass makes, catalogue R-IMG-13) are
  ## written, under their published names, to the directory the capture
  ## CLI names in `ISONIM_EMAIL_DERIVED_ASSETS`, which the fixture host
  ## serves; without it (the tests) nothing is written.
  var hook: UploadHook = nil
  when not defined(js):
    let dir = getEnv("ISONIM_EMAIL_DERIVED_ASSETS")
    if dir.len > 0:
      hook = proc (a: AssetRef): string =
        let path = dir / assetBaseName(a.name)
        if a.bytes.len > 0 and (not fileExists(path) or
            readFile(path) != a.bytes):
          createDir(dir)
          writeFile(path, a.bytes)
        hostedUrl(fixtureHost, a)
  memoryAssetStore(fixtureHost, hook)

proc kitRender*(doc: EmailNode; dark = false): StoryHtml =
  ## Renders a story, publishing its images to the capture fixture host
  ## (the built-in social icons are served from there by the capture
  ## harness, like the story fixtures, and so are its crops).
  var t = defaultTarget()
  if dark:
    t.darkMode = dmDesigned
  renderStoryPipeline(doc, t, fixtureStore())

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
    registerStoryTree(s.name, s.build,
      if s.dark: dmDesigned else: dmAccommodate)
