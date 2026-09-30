# rule: R-LAY-05
## The serialiser is byte-deterministic — the same tree yields identical
## bytes across 100 runs — and emits no whitespace between inline-block
## siblings, including across the conditionals separating them (R-LAY-05).
##
## Backend-independent (pure string building), so `just test` also runs it on
## JS. The C and JS runs assert against the same embedded golden, which is
## what proves cross-backend byte-equality: any backend divergence fails one
## of the two runs.
import std/[strutils, unittest]
import isonim_email

proc buildDetTree(r: EmailRenderer): EmailNode =
  result = r.createElement("div")
  r.setAttribute(result, "id", "cols")
  r.setAttribute(result, "title", "a'b<c\"d&e")
  r.setStyle(result, "font-size", "0")
  let a = r.createElement("div")
  r.setAttribute(a, "class", "col-a")
  r.setStyle(a, "display", "inline-block")
  r.setStyle(a, "width", "100%")
  let pa = r.createElement("p")
  r.appendChild(pa, r.createTextNode("left <&> \"quoted\""))
  r.appendChild(pa, raw("<br>"))
  r.appendChild(a, pa)
  let ghost = r.createElement("table")
  r.setAttribute(ghost, "width", "300")
  r.setStyle(ghost, "width", "300px")
  let cond = msoWrap(ghost)
  let b = r.createElement("div")
  r.setAttribute(b, "class", "col-b")
  r.setStyle(b, "display", "inline-block")
  r.setStyle(b, "width", "100%")
  let pb = r.createElement("p")
  r.appendChild(pb, r.createTextNode("right — naïve ✓"))
  r.appendChild(b, pb)
  r.appendChild(result, a)
  r.appendChild(result, cond)
  r.appendChild(result, b)

const detGolden =
  "<div id=\"cols\" title=\"a&#x27;b&lt;c&quot;d&amp;e\" " &
  "style=\"font-size:0;\">" &
  "<div class=\"col-a\" style=\"display:inline-block;width:100%;\">" &
  "<p>left &lt;&amp;&gt; \"quoted\"<br></p></div>" &
  "<!--[if mso]><table width=\"300\" " &
  "style=\"width:300px;\"></table><![endif]-->" &
  "<div class=\"col-b\" style=\"display:inline-block;width:100%;\">" &
  "<p>right — naïve ✓</p></div></div>"

suite "serializer determinism":
  test "same tree serialises byte-identically across 100 runs":
    let r = EmailRenderer()
    let tree = buildDetTree(r)
    check serialize(tree) == detGolden
    for i in 0 ..< 100:
      check serialize(tree) == detGolden

  test "fresh builds of the same tree serialise identically":
    let r = EmailRenderer()
    check serialize(buildDetTree(r)) == serialize(buildDetTree(r))

  test "no whitespace between inline-block siblings (R-LAY-05)":
    let r = EmailRenderer()
    let html = serialize(buildDetTree(r))
    # The column divs and the conditional between them are contiguous:
    # `</div><!--[if mso]>…<![endif]--><div`, with nothing between.
    check "</div><!--[if mso]>" in html
    check "<![endif]--><div" in html
    check "</div> <div" notin html
    check "</div>\n<div" notin html

  test "email attribute escaping covers quote, ampersand, tick and angle":
    check escapeEmailAttr("\"&'<>") == "&quot;&amp;&#x27;&lt;>"
    check escapeEmailAttr("plain déjà") == "plain déjà"

  test "serializeDocument prefixes the exact HTML5 doctype":
    let r = EmailRenderer()
    let html = r.createElement("html")
    check serializeDocument(html) == "<!doctype html><html></html>"
