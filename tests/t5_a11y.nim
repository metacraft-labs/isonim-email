## P7 backfills accessibility attributes —
## `role="presentation"` on layout tables (R-A11Y-02), `aria-hidden`
## on the preheader padding (R-PRE-03), decorative VML and empty
## spacers (R-A11Y-05; its dark-swap part, settled as no attribute on
## either image, is tests/t5_dark.nim's), `mailDocument`
## `lang`/`dir` copied onto the
## article wrapper (R-A11Y-01) — and warns on skipped heading
## levels (R-TXT-10). Backfills only add missing attributes.
##
## Backend-independent (tree walk + attribute writes), so `just test`
## also runs it on JS.
# rule: R-A11Y-05
import std/[sequtils, tables, unittest]
import isonim_email

proc codesOf(diags: seq[EmailDiagnostic]): seq[string] =
  diags.mapIt(it.code)

suite "P7 a11y":
  test "test_a11y_role_backfill":
    # rule: R-A11Y-02
    let r = EmailRenderer()
    let root = r.createElement("div")
    let layout = r.createElement("table")
    r.appendChild(root, layout)
    let kept = r.createElement("table")
    r.setAttribute(kept, "role", "table")
    r.appendChild(root, kept)
    let data = r.createElement("mailTable")
    let cap = r.createElement("caption")
    r.setTextContent(cap, "Prices")
    r.appendChild(data, cap)
    r.appendChild(root, data)
    let attrCap = r.createElement("mailTable")
    r.setAttribute(attrCap, "caption", "Totals")
    r.appendChild(root, attrCap)
    let explicit = r.createElement("mailTable")
    r.setAttribute(explicit, "role", "grid")
    r.setAttribute(explicit, "caption", "Grid")
    r.appendChild(root, explicit)
    let diags = applyA11y(root)
    check diags.len == 0
    check layout.attrs["role"] == "presentation"
    check kept.attrs["role"] == "table"
    check data.attrs["role"] == "table"
    check attrCap.attrs["role"] == "table"
    check explicit.attrs["role"] == "grid"

  test "test_a11y_mailtable_caption_error":
    # rule: R-A11Y-02
    let r = EmailRenderer()
    let root = r.createElement("div")
    let data = r.createElement("mailTable")
    data.origin = SourceSpan(file: "a11y.nim", line: 3, col: 7)
    r.appendChild(root, data)
    let diags = applyA11y(root)
    check codesOf(diags) == @[codeA11yTableCaption]
    check diags[0].severity == sevError
    check diags[0].origin.file == "a11y.nim"
    # An empty caption attribute is no caption — but the role
    # backfill still lands (backfills never depend on validity).
    let root2 = r.createElement("div")
    let empty = r.createElement("mailTable")
    r.setAttribute(empty, "caption", "")
    r.appendChild(root2, empty)
    check codesOf(applyA11y(root2)) == @[codeA11yTableCaption]
    check empty.attrs["role"] == "table"

  test "test_a11y_aria_hidden_backfill":
    # R-A11Y-05's spacer and decorative-VML parts. Not a rule claim:
    # the rule's dark-swap duplicates do not exist yet (mailImage
    # dark_src has no lowering), so R-A11Y-05 stays pending.
    let r = EmailRenderer()
    let root = r.createElement("div")
    let spacer = r.createElement("div")
    r.appendChild(root, spacer)
    let full = r.createElement("div")
    r.setTextContent(full, "text")
    r.appendChild(root, full)
    let box = r.createElement("div")
    r.appendChild(box, r.createElement("p"))
    r.appendChild(root, box)
    let deco = newVml("v:rect", [("decorative", "true")])
    r.appendChild(root, deco)
    let shape = newVml("v:rect", [("alt", "hero")])
    r.appendChild(root, shape)
    check applyA11y(root).len == 0
    check spacer.attrs["aria-hidden"] == "true"
    check "aria-hidden" notin full.attrs
    check "aria-hidden" notin box.attrs
    check deco.attrs["aria-hidden"] == "true"
    check "aria-hidden" notin shape.attrs

  test "test_a11y_preheader_padding_hidden":
    # rule: R-PRE-03
    let r = EmailRenderer()
    let doc = r.createElement("mailDocument")
    r.setAttribute(doc, "preheader", "Hello")
    let html = lowerDocument(doc, nil, @[], defaultTarget())
    var body: EmailNode = nil
    for c in html.children:
      if c.kind == enElement and c.tag == "body":
        body = c
    check body != nil
    check body.children.len == 3
    let pad = body.children[1]
    r.removeAttribute(pad, "aria-hidden")
    let diags = applyA11y(html)
    check diags.len == 0
    check pad.attrs["aria-hidden"] == "true"
    check "aria-hidden" notin body.children[0].attrs

  test "test_a11y_wrapper_lang_dir":
    # rule: R-A11Y-01
    let r = EmailRenderer()
    let doc = r.createElement("mailDocument")
    r.setAttribute(doc, "lang", "fr")
    r.setAttribute(doc, "dir", "rtl")
    let wrap = r.createElement("div")
    r.setAttribute(wrap, "role", "article")
    r.appendChild(doc, wrap)
    let kept = r.createElement("div")
    r.setAttribute(kept, "role", "article")
    r.setAttribute(kept, "lang", "de")
    check applyA11y(doc).len == 0
    check wrap.attrs["lang"] == "fr"
    check wrap.attrs["dir"] == "rtl"
    # Present values are never overwritten (separate tree: only the
    # first article wrapper in a tree is backfilled).
    let doc2 = r.createElement("mailDocument")
    r.setAttribute(doc2, "lang", "fr")
    r.setAttribute(doc2, "dir", "rtl")
    r.appendChild(doc2, kept)
    check applyA11y(doc2).len == 0
    check kept.attrs["lang"] == "de"
    check kept.attrs["dir"] == "rtl"

  test "test_a11y_heading_skip":
    let r = EmailRenderer()
    let root = r.createElement("div")
    let h1 = r.createElement("h1")
    r.setTextContent(h1, "Top")
    r.appendChild(root, h1)
    let h3 = r.createElement("h3")
    h3.origin = SourceSpan(file: "a11y.nim", line: 11, col: 2)
    r.setTextContent(h3, "Skipped")
    r.appendChild(root, h3)
    let diags = applyA11y(root)
    check codesOf(diags) == @[codeA11yHeadingSkip]
    check diags[0].severity == sevWarning
    check diags[0].origin.line == 11
    # Steady descent never warns.
    let clean = r.createElement("div")
    for tag in ["h1", "h2", "h3", "h2", "h1"]:
      let h = r.createElement(tag)
      r.setTextContent(h, tag)
      r.appendChild(clean, h)
    check applyA11y(clean).len == 0
