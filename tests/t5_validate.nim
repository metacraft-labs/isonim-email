## P1 validates the authoring tree — exactly one
## `mailDocument` with `lang` and `title`, at least one `h1`
## (R-A11Y-03), `alt` on every image (R-A11Y-04), valid UTF-8 text,
## raw nodes only inside `mailRaw`, no sectioning elements (R-A11Y-10)
## and no reactive residue. Pure collection: the tree is
## never mutated.
##
## Backend-independent (tree walk + pure checks), so `just test`
## also runs it on JS.
import std/[sequtils, strutils, unittest]
import isonim_email

proc validDoc(r: EmailRenderer): EmailNode =
  let doc = r.createElement("mailDocument")
  r.setAttribute(doc, "lang", "en")
  r.setAttribute(doc, "title", "Hello")
  doc.origin = SourceSpan(file: "valid.nim", line: 1, col: 1)
  let h1 = r.createElement("h1")
  r.setTextContent(h1, "Héllo")
  r.appendChild(doc, h1)
  doc

proc codesOf(diags: seq[EmailDiagnostic]): seq[string] =
  diags.mapIt(it.code)

suite "P1 validate":
  test "test_validate_clean_tree":
    let r = EmailRenderer()
    let doc = validDoc(r)
    let img = r.createElement("mailImage")
    img.origin = SourceSpan(file: "valid.nim", line: 5, col: 3)
    r.setAttribute(img, "src", "https://x.test/a.png")
    r.setAttribute(img, "alt", "A photo")
    r.appendChild(doc, img)
    check validate(doc).len == 0

  test "test_validate_two_documents":
    let r = EmailRenderer()
    let doc = validDoc(r)
    let other = r.createElement("mailDocument")
    r.setAttribute(other, "lang", "en")
    r.setAttribute(other, "title", "Other")
    r.appendChild(doc, other)
    let diags = validate(doc)
    check codesOf(diags) == @[codeStructNoDocument]
    check diags[0].severity == sevError

  test "test_validate_zero_documents":
    let r = EmailRenderer()
    let h1 = r.createElement("h1")
    r.setTextContent(h1, "No document")
    let diags = validate(h1)
    check codeStructNoDocument in codesOf(diags)

  test "test_validate_lang_missing":
    let r = EmailRenderer()
    let doc = validDoc(r)
    r.removeAttribute(doc, "lang")
    let diags = validate(doc)
    check codesOf(diags) == @[codeA11yLangMissing]
    check diags[0].severity == sevError
    check diags[0].origin.file == "valid.nim"

  test "test_validate_title_missing":
    let r = EmailRenderer()
    let doc = validDoc(r)
    r.removeAttribute(doc, "title")
    let diags = validate(doc)
    check codesOf(diags) == @[codeA11yTitleMissing]
    check diags[0].severity == sevError

  test "test_validate_h1_missing":
    # rule: R-A11Y-03
    let r = EmailRenderer()
    let doc = r.createElement("mailDocument")
    r.setAttribute(doc, "lang", "en")
    r.setAttribute(doc, "title", "No heading")
    let p = r.createElement("p")
    r.setTextContent(p, "Body without a heading.")
    r.appendChild(doc, p)
    let diags = validate(doc)
    check codesOf(diags) == @[codeA11yNoH1]
    check diags[0].severity == sevError

  test "test_validate_alt_missing":
    # rule: R-A11Y-04
    let r = EmailRenderer()
    let doc = validDoc(r)
    let img = r.createElement("mailImage")
    img.origin = SourceSpan(file: "alt.nim", line: 9, col: 5)
    r.setAttribute(img, "src", "https://x.test/a.png")
    r.appendChild(doc, img)
    let plain = r.createElement("img")
    plain.origin = SourceSpan(file: "alt.nim", line: 12, col: 5)
    r.setAttribute(plain, "src", "https://x.test/b.png")
    r.appendChild(doc, plain)
    let diags = validate(doc)
    check codesOf(diags) == @[codeA11yAltMissing, codeA11yAltMissing]
    check diags[0].origin == SourceSpan(file: "alt.nim", line: 9, col: 5)
    check diags[1].origin == SourceSpan(file: "alt.nim", line: 12, col: 5)

  test "test_validate_alt_variants":
    # rule: R-A11Y-04
    # R-IMG-04: alt is required; alt="" only with decorative = true.
    let r = EmailRenderer()
    let doc = validDoc(r)
    let deco = r.createElement("mailImage")
    r.setAttribute(deco, "src", "https://x.test/spacer.png")
    r.setAttribute(deco, "alt", "")
    r.setAttribute(deco, "decorative", "true")
    r.appendChild(doc, deco)
    check validate(doc).len == 0
    let bare = r.createElement("img")
    r.setAttribute(bare, "src", "https://x.test/c.png")
    r.setAttribute(bare, "alt", "")
    r.appendChild(doc, bare)
    let diags = validate(doc)
    check codesOf(diags) == @[codeA11yAltMissing]
    # Decorative without any alt still errors: alt is required.
    r.removeChild(doc, bare)
    let nodecor = r.createElement("mailImage")
    r.setAttribute(nodecor, "src", "https://x.test/d.png")
    r.setAttribute(nodecor, "decorative", "true")
    r.appendChild(doc, nodecor)
    check codesOf(validate(doc)) == @[codeA11yAltMissing]

  test "test_validate_bad_utf8":
    let r = EmailRenderer()
    let doc = validDoc(r)
    let p = r.createElement("p")
    p.origin = SourceSpan(file: "utf8.nim", line: 4, col: 1)
    r.setTextContent(p, "broken \xFF byte")
    r.appendChild(doc, p)
    let diags = validate(doc)
    check codesOf(diags) == @[codeStructInvalidUtf8]
    check diags[0].severity == sevError
    check diags[0].origin.file == "utf8.nim"

  test "test_validate_reactive_residue":
    let r = EmailRenderer()
    let doc = validDoc(r)
    let blk = r.createElement("div")
    r.setAttribute(blk, "data-hk", "0.1")
    r.appendChild(doc, blk)
    let script = r.createElement("script")
    r.appendChild(doc, script)
    let diags = validate(doc)
    # The residue walk aborts at the first offender, so one finding.
    check codesOf(diags) == @[codeStructReactiveResidue]
    check diags[0].severity == sevError

  test "test_validate_raw_outside_mailraw":
    # A raw node is legal only below `mailRaw`; anywhere else it is an
    # error located at the closest ancestor that carries an origin
    # (raw nodes built by hand have none of their own).
    let r = EmailRenderer()
    let doc = validDoc(r)
    let p = r.createElement("p")
    p.origin = SourceSpan(file: "raw.nim", line: 7, col: 5)
    r.appendChild(p, raw("<b>loose</b>"))
    r.appendChild(doc, p)
    let diags = validate(doc)
    check codesOf(diags) == @[codeStructRawOutside]
    check diags[0].severity == sevError
    check diags[0].origin.file == "raw.nim"
    check diags[0].origin.line == 7
    check "inside <p>" in diags[0].message
    check "mailRaw" in diags[0].message

  test "test_validate_raw_inside_mailraw_passes":
    # Directly under `mailRaw`, and below a transparent wrapper inside it.
    let r = EmailRenderer()
    let doc = validDoc(r)
    let rawBlock = r.createElement("mailRaw")
    r.appendChild(rawBlock, raw("<!-- audited -->"))
    let cond = r.createElement("mailIf")
    r.appendChild(cond, raw("<!-- nested -->"))
    r.appendChild(rawBlock, cond)
    r.appendChild(doc, rawBlock)
    check validate(doc).len == 0
    # A raw node as the whole tree has no mailRaw ancestor either.
    check codeStructRawOutside in codesOf(validate(raw("<p>x</p>")))

  test "test_validate_sectioning_element":
    # rule: R-A11Y-10
    # Templates cannot contain sectioning elements (the static vocabulary
    # rejects them); a tree built by hand is caught here.
    let r = EmailRenderer()
    let doc = validDoc(r)
    let nav = r.createElement("nav")
    nav.origin = SourceSpan(file: "nav.nim", line: 3, col: 2)
    r.appendChild(doc, nav)
    let diags = validate(doc)
    check codesOf(diags) == @[codeA11ySectioning]
    check diags[0].severity == sevError
    check diags[0].origin.file == "nav.nim"
    check diags[0].rules == @["R-A11Y-10"]
    check "layout primitives" in diags[0].message
