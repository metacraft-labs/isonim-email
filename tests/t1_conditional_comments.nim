# rule: R-OL-01
## MSO conditionals use the exact R-OL-01 syntax, survive minification
## verbatim, and unbalanced IR is rejected. Negative control: a tree with no
## MSO nodes produces no conditional comments.
##
## Backend-independent (pure string building), so `just test` also runs it on JS.
import std/[strutils, unittest]
import isonim_email

proc buildMsoTree(r: EmailRenderer): EmailNode =
  result = r.createElement("div")
  let ghost = r.createElement("table")
  r.setAttribute(ghost, "width", "600")
  let rect = newVml("v:rect", [("fill", "true"), ("stroke", "false")])
  let fill = newVml("v:fill",
    [("type", "frame"), ("src", "https://x.example/i.png"),
     ("color", "#ffffff")])
  r.appendChild(rect, fill)
  let cond = newMsoIf("gte mso 9", @[rect])
  let alt = r.createElement("span")
  r.appendChild(alt, r.createTextNode("not outlook"))
  let notCond = notMsoWrap(alt)
  r.appendChild(result, ghost)
  r.appendChild(result, cond)
  r.appendChild(result, notCond)

const msoExact =
  "<!--[if gte mso 9]>" &
  "<v:rect fill=\"true\" stroke=\"false\">" &
  "<v:fill type=\"frame\" src=\"https://x.example/i.png\" " &
  "color=\"#ffffff\" />" &
  "</v:rect><![endif]-->"
const notMsoExact =
  "<!--[if !mso]><!--><span>not outlook</span><!--<![endif]-->"

suite "conditional comments":
  test "MsoIf and NotMso use the exact R-OL-01 syntax":
    let r = EmailRenderer()
    let html = serialize(buildMsoTree(r))
    check msoExact in html
    check notMsoExact in html

  test "conditionals and VML survive minification verbatim":
    let r = EmailRenderer()
    let tree = buildMsoTree(r)
    # Inter-element whitespace around the conditionals must not disturb them.
    r.insertBefore(tree, r.createTextNode("  \n  "), tree.children[1])
    let html = serialize(tree, minify = true)
    check msoExact in html
    check notMsoExact in html
    # …while the whitespace itself is collapsed.
    check "  \n  " notin html
    check serialize(tree, minify = false) != html

  test "minify keeps whitespace inside pre":
    let r = EmailRenderer()
    let pre = r.createElement("pre")
    r.appendChild(pre, r.createTextNode("  spaced  "))
    check serialize(pre, minify = true) == "<pre>  spaced  </pre>"

  test "minify keeps whitespace inside conditionals":
    # Conditional content is verbatim: Outlook reads it raw, so even
    # whitespace-only text survives minification — including inside a
    # VML textbox, where the padding is the content.
    let r = EmailRenderer()
    let cond = newMsoIf("mso")
    r.appendChild(cond, r.createTextNode("  \n  "))
    let box = newVml("v:textbox")
    r.appendChild(box, r.createTextNode("  padded  "))
    r.appendChild(cond, box)
    let html = serialize(cond, minify = true)
    check "  \n  " in html
    check "  padded  " in html
    let notCond = newNotMso()
    r.appendChild(notCond, r.createTextNode("  kept  "))
    check "  kept  " in serialize(notCond, minify = true)

  test "unbalanced IR is rejected":
    let r = EmailRenderer()
    let bad = r.createElement("div")
    # A stray closer smuggled in through a raw node.
    r.appendChild(bad, raw("<![endif]-->"))
    expect EmailRenderError:
      discard serialize(bad)
    # VML outside any MsoIf.
    let stray = r.createElement("div")
    r.appendChild(stray, newVml("v:rect"))
    expect EmailRenderError:
      discard serialize(stray)
    # A real Outlook version condition outside the closed emitted set.
    expect EmailRenderError:
      discard newMsoIf("mso 12")

  test "void elements with children are rejected with their span":
    let r = EmailRenderer()
    let img = r.createElement("img")
    img.origin = SourceSpan(file: "gallery.nim", line: 9, col: 3)
    r.setAttribute(img, "src", "https://x.example/i.png")
    r.appendChild(img, r.createTextNode("fallback"))
    var msg = ""
    try:
      discard serialize(img)
    except EmailRenderError as e:
      msg = e.msg
    check "img" in msg
    check "gallery.nim:9:3" in msg
    # A childless void still serialises open, HTML5 style.
    let br = r.createElement("br")
    check serialize(br) == "<br>"

  test "negative control: no MSO nodes, no conditional comments":
    let r = EmailRenderer()
    let plain = r.createElement("div")
    let p = r.createElement("p")
    r.appendChild(p, r.createTextNode("hello"))
    r.appendChild(plain, p)
    let html = serialize(plain, minify = true)
    check "<!--[if" notin html
    check "<![endif]" notin html
