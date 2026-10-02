## Element lowering (P4). Two halves:
##
## - The invariant: a vocabulary element with no lowering is an error
##   (`E-LOWER-MISSING`), never emitted as a raw custom tag. Mail
##   clients strip unknown tags, so a raw `<mailHero>` or
##   `<mailButton>` would silently lose its box or its link. The
##   element's content survives (it is replaced by its children), the
##   error blocks sending, `strict` raises it, and the story pipeline
##   refuses the story.
## - `mailImage`: the fixed-size image of the catalogue, with the px
##   `width` attribute, the canonical inline stack, alt-text styling on
##   the `img` itself, an optional `height` attribute, the linked-image
##   wrap, and the width from the asset's intrinsic size (halved for
##   `@2x` assets). An image whose width cannot be known is an error,
##   and so is every prop whose lowering does not exist yet (dark
##   source, fluid on mobile, explicit alignment, percentage widths).
##
## The seed stories are pinned here too: both reach the output with
## their images as real `img` elements.
##
## Backend-independent (tree building + pure passes + the in-memory
## asset store), so `just test` also runs it on JS.
import std/[algorithm, strutils, unittest]
import isonim_email
import stories/email_stories
import stories/fixture_images

proc docWith(build: proc(r: EmailRenderer; doc: EmailNode)): EmailNode =
  ## A P1-clean `mailDocument` with an `h1`, plus whatever `build` adds.
  let r = EmailRenderer()
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "dir", "ltr")
  r.setAttribute(doc, "title", "Lowering")
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Lowering")
  r.appendChild(doc, h1)
  build(r, doc)
  doc

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc image(r: EmailRenderer; src, alt: string;
    attrs: openArray[(string, string)] = [];
    styles: openArray[(string, string)] = []): EmailNode =
  result = r.createElement("mailImage")
  r.setAttribute(result, "src", src)
  r.setAttribute(result, "alt", alt)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  for (k, v) in styles:
    r.setStyle(result, k, v)

proc renderOne(img: EmailNode; assets: AssetStore = nil): RenderedEmail =
  renderTree(docWith(proc(r: EmailRenderer; doc: EmailNode) =
    r.appendChild(doc, img)), assets = assets)

const altStyle = "font-family:Helvetica, Arial, sans-serif;" &
  "font-size:14px;line-height:20px;color:#4b5563;"
  ## Alt-text styling from the default theme: body font, small type,
  ## secondary text colour.

suite "elements without a lowering are errors, never raw tags":
  test "test_unlowered_elements_error_and_keep_their_content":
    # `mailHero` and `mailButton` have no lowering yet (the section that
    # stood here has one now: tests/t5_scaffolding.nim).
    let doc = docWith(proc(r: EmailRenderer; doc: EmailNode) =
      let hero = r.createElement("mailHero")
      let p = r.createElement("p")
      r.setTextContent(p, "Inside the section")
      r.appendChild(hero, p)
      let button = r.createElement("mailButton")
      r.setAttribute(button, "href", "https://app.example.com/")
      r.setTextContent(button, "Open dashboard")
      r.appendChild(hero, button)
      r.appendChild(doc, hero))
    let res = renderTree(doc)
    check codesOf(res.diagnostics) == @[codeLowerMissing, codeLowerMissing]
    check hasErrors(res.diagnostics)
    check "<mailHero>" in res.diagnostics[0].message
    check "<mailButton>" in res.diagnostics[1].message
    # Never a raw custom tag, in any spelling.
    check "<mailhero" notin res.html.toLowerAscii()
    check "<mailbutton" notin res.html.toLowerAscii()
    # The content survives, so the output stays inspectable.
    check "Inside the section" in res.html
    check "Open dashboard" in res.html
    # The semantic tree is the authoring tree, untouched by lowering.
    check res.semantic.children[1].tag == "mailHero"

  test "test_every_vocabulary_element_without_a_lowering_errors":
    # Every non-leaf vocabulary element other than the ones with a
    # lowering, plus a pattern-shaped tag the vocabulary does not know.
    let lowered = @loweredHere & @loweredElsewhere
    check lowered.sorted() == @["mailDocument", "mailImage", "mailSection",
      "mailStack", "mailWrapper"]
    var nonLeaf = 0
    var tags: seq[string] = @[]
    for t in buildEmailVocabulary().tags:
      if not t.allowAnyStyle:
        inc nonLeaf
        if t.name notin lowered:
          tags.add(t.name)
    tags.add("mailCard")
    check nonLeaf >= 27
    check tags.len == nonLeaf - lowered.len + 1
    for tag in tags:
      let res = renderTree(docWith(proc(r: EmailRenderer; doc: EmailNode) =
        let el = r.createElement(tag)
        if tag == "mailTable":
          # P7 requires a caption; give it one so only P4 speaks.
          r.setAttribute(el, "caption", "Items")
        r.setTextContent(el, "payload")
        r.appendChild(doc, el)))
      check codesOf(res.diagnostics) == @[codeLowerMissing]
      check ("<" & tag.toLowerAscii()) notin res.html.toLowerAscii()
      check "payload" in res.html

  test "test_html_leaves_and_lowered_elements_are_clean":
    # Negative control: the same pipeline over leaves and a lowered
    # image reports nothing.
    let res = renderTree(docWith(proc(r: EmailRenderer; doc: EmailNode) =
      let p = r.createElement("p")
      let a = r.createElement("a")
      r.setAttribute(a, "href", "https://app.example.com/")
      r.setTextContent(a, "Open")
      r.appendChild(p, a)
      r.appendChild(doc, p)
      r.appendChild(doc, image(r, "https://x.test/logo.png", "Logo",
        styles = [("width", "120px")]))))
    check res.diagnostics.len == 0

  test "test_strict_raises_and_stories_refuse_unlowered_elements":
    let doc = docWith(proc(r: EmailRenderer; doc: EmailNode) =
      r.appendChild(doc, r.createElement("mailSpacer")))
    var msg = ""
    try:
      discard renderTree(doc, strict = true)
    except EmailRenderError as e:
      msg = e.msg
    check msg.startsWith(codeLowerMissing & ":")
    let again = docWith(proc(r: EmailRenderer; doc: EmailNode) =
      r.appendChild(doc, r.createElement("mailSpacer")))
    var storyMsg = ""
    try:
      discard renderPipeline(again, defaultTarget())
    except StoryError as e:
      storyMsg = e.msg
    check codeLowerMissing in storyMsg

suite "mailImage lowers to the fixed-size image":
  test "test_mail_image_emits_the_fixed_size_stack":
    # rule: R-IMG-01
    let res = renderOne(image(EmailRenderer(), "https://x.test/logo.png",
      "Acme logo", styles = [("width", "120px")]))
    check res.diagnostics.len == 0
    # The px width capped by max-width:100% (never width:100% capped by
    # a px max-width, which Thunderbird's shrinktofit stylesheet
    # overrides), centred by margin under the skeleton's centred cell.
    check ("<img src=\"https://x.test/logo.png\" alt=\"Acme logo\" " &
      "width=\"120\" style=\"display:block;margin:0 auto;border:0;" &
      "outline:none;text-decoration:none;height:auto;width:120px;" &
      "max-width:100%;-ms-interpolation-mode:bicubic;" & altStyle &
      "\">") in res.html
    check ";width:100%" notin res.html.split("<img ")[1].split(">")[0]
    check "<mailimage" notin res.html.toLowerAscii()
    # No height attribute unless the author gave one.
    check "height=\"" notin res.html.split("<img ")[1].split(">")[0]

  test "test_mail_image_height_attribute_only_when_given":
    # rule: R-IMG-01
    let res = renderOne(image(EmailRenderer(), "https://x.test/logo.png",
      "Acme logo", styles = [("width", "120px"), ("height", "40px")]))
    check res.diagnostics.len == 0
    check ("alt=\"Acme logo\" width=\"120\" height=\"40\" style=\"" &
      "display:block;") in res.html
    # The inline height stays auto, so the aspect follows the width.
    check "height:auto;width:120px;max-width:100%;" in res.html

  test "test_linked_image_wraps_without_whitespace":
    # rule: R-IMG-10
    let res = renderOne(image(EmailRenderer(), "https://x.test/logo.png",
      "Acme logo", attrs = [("href", "https://acme.example/")],
      styles = [("width", "120px")]))
    check res.diagnostics.len == 0
    check ("<a href=\"https://acme.example/\" target=\"_blank\" " &
      "style=\"display:block;\"><img src=\"https://x.test/logo.png\"") in
      res.html
    check "width:120px;max-width:100%;-ms-interpolation-mode:bicubic;" &
      altStyle & "\"></a>" in res.html

  test "test_intrinsic_width_halves_for_2x_assets":
    # rule: R-IMG-05
    const pngBytes = staticRead("fixtures/t6_rgb.png")
    let info = probeImage(pngBytes, "t6_rgb.png")
    check info.width > 1
    let store = memoryAssetStore("https://assets.example.com")
    store.put("hero@2x.png", pngBytes)
    store.put("plain.png", pngBytes)
    let retina = renderOne(image(EmailRenderer(), "hero@2x.png", "Hero"),
      store)
    check retina.diagnostics.len == 0
    check ("width=\"" & $(info.width div 2) & "\" style=") in retina.html
    check (";width:" & $(info.width div 2) & "px;max-width:100%;") in
      retina.html
    let plain = renderOne(image(EmailRenderer(), "plain.png", "Plain"),
      store)
    check plain.diagnostics.len == 0
    check ("width=\"" & $info.width & "\" style=") in plain.html
    # An explicit width wins over the intrinsic size.
    let given = renderOne(image(EmailRenderer(), "plain.png", "Plain",
      styles = [("width", "7px")]), store)
    check ("width=\"7\" style=") in given.html

  test "test_mail_image_margin_follows_the_inherited_alignment":
    # rule: R-IMG-01
    # The image sits in a cell whose own alignment (attribute or
    # text-align) decides the margin; with none, the skeleton's centred
    # content cell centres it.
    proc inCell(cellAttrs, cellStyles: seq[(string, string)]):
        string =
      let html = renderTree(docWith(proc(r: EmailRenderer;
          doc: EmailNode) =
        let table = r.createElement("table")
        let tr = r.createElement("tr")
        let td = r.createElement("td")
        for (k, v) in cellAttrs:
          r.setAttribute(td, k, v)
        for (k, v) in cellStyles:
          r.setStyle(td, k, v)
        r.appendChild(td, image(r, "https://x.test/logo.png", "Acme logo",
          styles = [("width", "120px")]))
        r.appendChild(tr, td)
        r.appendChild(table, tr)
        r.appendChild(doc, table))).html
      html.split("<img ")[1].split(">")[0]
    check "style=\"display:block;margin:0 auto;border:0;" in inCell(@[], @[])
    check "style=\"display:block;margin:0 auto;border:0;" in
      inCell(@[("align", "center")], @[])
    check "style=\"display:block;margin:0 0 0 auto;border:0;" in
      inCell(@[("align", "right")], @[])
    check "style=\"display:block;margin:0 0 0 auto;border:0;" in
      inCell(@[], @[("text-align", "right")])
    let left = inCell(@[("align", "left")], @[])
    check "style=\"display:block;border:0;" in left
    check "margin" notin left
    # A table's own align places the table, not its content: it does
    # not stop the walk, so the skeleton's centre still applies.
    let tableAligned = renderTree(docWith(proc(r: EmailRenderer;
        doc: EmailNode) =
      let table = r.createElement("table")
      r.setAttribute(table, "align", "left")
      let tr = r.createElement("tr")
      let td = r.createElement("td")
      r.appendChild(td, image(r, "https://x.test/logo.png", "Acme logo",
        styles = [("width", "120px")]))
      r.appendChild(tr, td)
      r.appendChild(table, tr)
      r.appendChild(doc, table))).html
    check "style=\"display:block;margin:0 auto;border:0;" in tableAligned

  test "test_unknown_width_is_an_error":
    let res = renderOne(image(EmailRenderer(), "https://x.test/logo.png",
      "Acme logo"))
    check codesOf(res.diagnostics) == @[codeLayoutImageWidth]
    check res.diagnostics[0].rules == @["R-IMG-01"]

  test "test_props_without_a_lowering_are_reported":
    for (attrs, styles, rule) in [
        (@[("dark_src", "https://x.test/logo-dark.png")],
          @[("width", "120px")], "R-IMG-06"),
        (@[("fluid_on_mobile", "true")], @[("width", "120px")],
          "R-IMG-09"),
        (@[("align", "left")], @[("width", "120px")], "R-IMG-01"),
        (newSeq[(string, string)](), @[("width", "100%")], "R-IMG-11")]:
      let res = renderOne(image(EmailRenderer(), "https://x.test/logo.png",
        "Acme logo", attrs = attrs, styles = styles))
      check codesOf(res.diagnostics) == @[codeLowerMissing]
      check res.diagnostics[0].rules == @[rule]
      # The image itself still lowers.
      check "<img src=\"https://x.test/logo.png\"" in res.html

suite "seed stories reach the output with their images":
  test "test_seed_stories_render_images_as_img":
    let receipt = renderReceipt().html
    check "<img src=\"" & fixtureImageUrl("logo.png") &
      "\" alt=\"Acme logo\" width=\"120\" style=\"display:block;" in
      receipt
    let alert = renderAlert().html
    check "<img src=\"" & fixtureImageUrl("shield.png") &
      "\" alt=\"رمز الدرع\" width=\"48\" style=\"display:block;" in
      alert
    for html in [receipt, alert]:
      check "<mailimage" notin html.toLowerAscii()
    # The URLs are the content-hashed hosted form the capture fixture
    # host serves.
    check fixtureImageUrl("logo.png").len ==
      "https://x.test/".len + 16 + "/logo.png".len
