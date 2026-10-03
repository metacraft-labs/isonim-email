## `mailButton` (`lower/button.nim`, `lower/button_style.nim`): the
## table button and its defaults, the placement of a start- or
## end-aligned button, widths and heights, the VML roundrect and its
## fit check, the Word-spacers option, the tap target, the destination
## rules, and the buttons' story set.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS. No test doubles.
# rule: R-BTN-01
# rule: R-BTN-02
# rule: R-BTN-03
# rule: R-BTN-04
# rule: R-BTN-05
# rule: R-BTN-06
# rule: R-BTN-07
# rule: R-OL-05
# rule: R-OL-12
import std/[strutils, unittest]
import isonim_email
import stories/seed_buttons

proc child(r: EmailRenderer; parent: EmailNode; tag: string;
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

proc newDoc(r: EmailRenderer; rtl = false): (EmailNode, EmailNode) =
  let doc = r.child(nil, "mailDocument", attrs = [("lang",
    if rtl: "ar" else: "en"), ("dir", if rtl: "rtl" else: "ltr"),
    ("title", "Buttons")])
  discard r.child(doc, "h1", text = "Buttons")
  (doc, r.child(doc, "mailSection"))

proc button(r: EmailRenderer; parent: EmailNode; label: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []): EmailNode =
  var a = @[("href", "https://app.example.com/")]
  for x in attrs:
    a.add(x)
  r.child(parent, "mailButton", styles, a, label)

proc body(html: string): string =
  html[html.find("<body") .. ^1]

proc codes(res: RenderedEmail): seq[string] =
  for d in res.diagnostics:
    result.add(d.code)

proc problems(res: RenderedEmail): seq[string] =
  ## The codes of the render's warnings and errors: what "renders
  ## cleanly" means (information, such as the inversion simulation's
  ## findings under an uncalibrated model, is not a problem).
  for d in res.diagnostics:
    if d.severity >= sevWarning:
      result.add(d.code)

proc render(build: proc(r: EmailRenderer; s: EmailNode);
    target = defaultTarget(); rtl = false): RenderedEmail =
  let r = EmailRenderer()
  let (doc, s) = newDoc(r, rtl)
  build(r, s)
  renderTree(doc, target = target)

const defaultLink = "<a href=\"https://app.example.com/\" target=\"_blank\" " &
  "style=\"display:inline-block;background-color:#1f6feb;color:#ffffff;" &
  "font-family:Helvetica, Arial, sans-serif;font-size:16px;" &
  "font-weight:600;line-height:20px;mso-line-height-rule:exactly;" &
  "margin:0;text-decoration:none;text-transform:none;padding:12px 24px;" &
  "mso-padding-alt:0px;border-radius:6px;\">Open dashboard</a>"
  ## The default button's link: the theme's accent, button padding and
  ## type, and a radius.md corner.

const defaultCell = "<td align=\"center\" bgcolor=\"#1f6feb\" " &
  "role=\"presentation\" valign=\"middle\" style=\"border:none;" &
  "border-radius:6px;cursor:auto;mso-padding-alt:12px 24px;" &
  "background-color:#1f6feb;\">"

suite "the table button":
  test "test_table_button_carries_colour_on_cell_and_link":
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Open dashboard"))
    check problems(res).len == 0
    let html = body(res.html)
    check "<mailbutton" notin html.toLowerAscii()
    # R-BTN-01: colour on the cell (bgcolor + CSS) and the link; the
    # padding on the link, Word's on the cell (R-OL-05), none on the
    # link for Word.
    check defaultCell & defaultLink & "</td></tr></table>" in html
    check "<table role=\"presentation\" border=\"0\" cellpadding=\"0\" " &
      "cellspacing=\"0\" align=\"left\" style=\"border-collapse:separate " &
      "!important;line-height:100%;\"><tr>" & defaultCell in html

  test "test_start_aligned_button_sits_in_a_cell_that_contains_its_float":
    # The reset centres every table, so a left button floats (align);
    # a cell contains the float: the text after it starts below.
    let left = body(render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Open dashboard")).html)
    check "<table role=\"presentation\" width=\"100%\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\"><tr><td align=\"left\" " &
      "style=\"text-align:left;\"><table role=\"presentation\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" align=\"left\"" in left
    # Right to left, the start is the right.
    let rtl = body(render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "افتح"), rtl = true).html)
    check "<td align=\"right\" style=\"text-align:right;\"><table " &
      "role=\"presentation\" border=\"0\" cellpadding=\"0\" " &
      "cellspacing=\"0\" align=\"right\"" in rtl
    # A centred table does not float: no outer cell.
    let centred = body(render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Go", attrs = [("align", "center")])).html)
    check "align=\"center\" style=\"border-collapse:separate" in centred
    check "width=\"100%\"" notin centred.split("<h1")[1].split("</table>")[0]
    # A cluster's item: no align, no outer cell; the cluster places it.
    let cluster = body(render(proc(r: EmailRenderer; s: EmailNode) =
      let c = r.child(s, "mailCluster")
      discard r.button(c, "One")
      discard r.button(c, "Two")).html)
    check cluster.count("<table role=\"presentation\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:" &
      "separate !important;line-height:100%;\">") == 2
    check "align=\"left\" style=\"border-collapse" notin cluster

  test "test_tones_and_variants_resolve_from_the_theme":
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Danger", attrs = [("tone", "danger")])
      discard r.button(s, "Outline", attrs = [("variant", "outline")])
      discard r.button(s, "Link", attrs = [("variant", "link")]))
    check problems(res).len == 0
    let html = body(res.html)
    check "bgcolor=\"#cf222e\"" in html
    # Outline: no fill, the link colour, a 2px border taken out of the
    # padding (as large as a solid button).
    check "style=\"border:2px solid #0969da;border-radius:6px;cursor:auto;" &
      "mso-padding-alt:10px 22px;\"><a" in html
    check "color:#0969da;" & "font-family" in html
    check "padding:10px 22px;" in html
    # Link: no fill, no border, underlined, square.
    check "style=\"border:none;cursor:auto;mso-padding-alt:12px 24px;\">" &
      "<a href=\"https://app.example.com/\" target=\"_blank\" " &
      "style=\"display:inline-block;color:#0969da;" in html
    check "text-decoration:underline;text-transform:none;" in html
    # The author's own values win over the tone.
    let own = body(render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Own", [("background-color", "#111111"),
        ("color", "#eeeeee"), ("padding", "14px 28px")])).html)
    check "bgcolor=\"#111111\"" in own
    check "color:#eeeeee;" in own
    check "padding:14px 28px;" in own

  test "test_dark_pairs_under_designed":
    var t = defaultTarget()
    t.darkMode = dmDesigned
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Open dashboard"), target = t)
    let html = res.html
    # The default colours' dark pairs, as a class on the cell and the
    # link (R-DRK-02).
    check "#4c8dff" in html
    check "#0b1220" in html
    let cls = html.split("<td align=\"center\" bgcolor=\"#1f6feb\" " &
      "role=\"presentation\" valign=\"middle\" class=\"")[1].split("\"")[0]
    check cls.startsWith("e-")
    check ("<a href=\"https://app.example.com/\" target=\"_blank\" class=\"" &
      cls & "\"") in html

  test "test_width_goes_on_the_table_and_the_link_fills_it":
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Pay now", [("width", "100%")])
      discard r.button(s, "A label long enough to wrap onto lines",
        [("width", "240px")], [("vml", "never")]))
    check problems(res).len == 0
    let html = body(res.html)
    # R-BTN-03: full width needs no placement; the link is a block.
    check "<table role=\"presentation\" width=\"100%\" border=\"0\" " &
      "cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:" &
      "separate !important;line-height:100%;width:100%;\">" in html
    check "style=\"display:block;background-color:#1f6feb;color:#ffffff;" &
      "text-align:center;" in html
    check "width=\"240\" border=\"0\" cellpadding=\"0\" cellspacing=\"0\" " &
      "align=\"left\" style=\"border-collapse:separate !important;" &
      "line-height:100%;width:240px;\"" in html
    # The label may wrap: nothing stops it.
    check "nowrap" notin html

  test "test_height_sets_the_vertical_padding":
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Tall", [("height", "56px")], [("vml", "never")]))
    let html = body(res.html)
    # (56 - 20) / 2 = 18 a side.
    check "mso-padding-alt:18px 24px;" in html
    check "padding:18px 24px;" in html

suite "the VML button":
  test "test_button_vml_fit_check":
    # A label that fits: a balanced roundrect inside MsoIf, the table
    # button inside NotMso.
    let fits = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Start free trial", [("width", "220px")]))
    check problems(fits).len == 0
    let html = body(fits.html)
    check "<!--[if mso]><div align=\"left\"><v:roundrect " &
      "xmlns:v=\"urn:schemas-microsoft-com:vml\" " &
      "xmlns:w=\"urn:schemas-microsoft-com:office:word\" " &
      "href=\"https://app.example.com/\" style=\"height:44px;" &
      "v-text-anchor:middle;width:220px;\" arcsize=\"14%\" " &
      "strokecolor=\"#1f6feb\" fillcolor=\"#1f6feb\"><w:anchorlock />" &
      "<center style=\"color:#ffffff;font-family:Helvetica, Arial, " &
      "sans-serif;font-size:16px;font-weight:600;\">Start free trial" &
      "</center></v:roundrect></div><![endif]--><!--[if !mso]><!-->" in html
    check html.count("<v:roundrect") == html.count("</v:roundrect>")
    check html.count("<v:roundrect") == 1
    check "Start free trial</a></td></tr></table></td></tr></table>" &
      "<!--<![endif]-->" in html
    # A label that does not fit at the metrics' worst case is an error
    # naming the numbers.
    let tight = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Start your free trial today", [("width",
        "180px")]))
    check codeLayoutLabelOverflow in codes(tight)
    check hasErrors(tight.diagnostics)
    for d in tight.diagnostics:
      if d.code == codeLayoutLabelOverflow:
        check "Start your free trial today" in d.message
        check "leaves it 132px" in d.message
    # The boundary: "Start free trial" in Liberation Sans Bold (the
    # Helvetica/Arial face) at 16px is 109.24px with the 5% margin, so
    # it fits a 158px button (110px inside 2 x 24px of padding) and not
    # a 157px one.
    for (w, over) in [(158, false), (157, true)]:
      let edge = render(proc(r: EmailRenderer; s: EmailNode) =
        discard r.button(s, "Start free trial", [("width", $w & "px")]))
      checkpoint($w)
      check (codeLayoutLabelOverflow in codes(edge)) == over
    # The label is measured as drawn. Uppercase, "START FREE TRIAL" is
    # 159.59px with the margin: it fits a 208px button (160px inside
    # the padding), not a 207px one, where the source text would fit.
    for (w, over) in [(208, false), (207, true)]:
      let upper = render(proc(r: EmailRenderer; s: EmailNode) =
        discard r.button(s, "Start free trial", [("width", $w & "px"),
          ("text-transform", "uppercase")]))
      checkpoint("uppercase " & $w)
      check (codeLayoutLabelOverflow in codes(upper)) == over
    # A 2px letter-spacing adds 16 x 2px to the 109.24px label: it fits
    # a 190px button (142px inside), not a 189px one. A negative
    # spacing counts as none (the 158px boundary above holds).
    for (w, spacing, over) in [(190, "2px", false), (189, "2px", true),
        (158, "-2px", false)]:
      let spaced = render(proc(r: EmailRenderer; s: EmailNode) =
        discard r.button(s, "Start free trial", [("width", $w & "px"),
          ("letter-spacing", spacing)]))
      checkpoint("letter-spacing " & spacing & " " & $w)
      check (codeLayoutLabelOverflow in codes(spaced)) == over
    # Word's label carries both, so the label Word draws is the one
    # measured.
    let both = body(render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Start free trial", [("width", "260px"),
        ("letter-spacing", "2px"), ("text-transform", "uppercase")])).html)
    check "font-weight:600;letter-spacing:2px;text-transform:uppercase;\">" &
      "Start free trial</center>" in both
    # The same label fits as a table button (no VML): no error.
    let never = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Start your free trial today", [("width",
        "180px")], [("vml", "never")]))
    check not hasErrors(never.diagnostics)
    check "v:roundrect" notin never.html
    # Without Word in the target there is no VML and nothing to fit.
    var noWord = defaultTarget()
    noWord.outlookWord = false
    let web = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Start your free trial today", [("width",
        "180px")]), target = noWord)
    check not hasErrors(web.diagnostics)
    check "v:roundrect" notin web.html

  test "test_vml_needs_a_px_width":
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Go", attrs = [("vml", "always")]))
    check codeLayoutVmlSize in codes(res)
    # `auto` with a % width keeps the fluid table button.
    let fluid = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Go", [("width", "100%")]))
    check problems(fluid).len == 0
    check "v:roundrect" notin fluid.html
    # `always` with 100% takes the box it sits in: 600 - 2 x 24.
    let full = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Go", [("width", "100%")], [("vml", "always")]))
    check problems(full).len == 0
    check "width:552px;\" arcsize" in full.html

  test "test_outline_vml_is_unfilled_with_a_stroke":
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Changelog", [("width", "260px"),
        ("height", "48px")], [("variant", "outline")]))
    check problems(res).len == 0
    check "style=\"height:48px;v-text-anchor:middle;width:260px;\" " &
      "arcsize=\"13%\" strokecolor=\"#0969da\" strokeweight=\"2px\" " &
      "filled=\"f\">" in res.html

  test "test_labels_outside_the_metrics_are_approximate":
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "ابدأ التجربة", [("width", "220px")]), rtl = true)
    check codeLayoutMetricsApprox in codes(res)
    check problems(res).len == 0
    check not hasErrors(res.diagnostics)
    # Negative control: a Latin label is measured, not estimated.
    let latin = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Start", [("width", "220px")]))
    check codeLayoutMetricsApprox notin codes(latin)

suite "Word spacers":
  test "test_word_spacers_option":
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Open dashboard", attrs = [("word_padding",
        "spacers")]))
    let html = body(res.html)
    # No table: a block holding the padded link, Word's padding from
    # the spacers: 24/16 = 150% wide, (12+12)/16 = 150% and 12/16 = 75%
    # raised.
    check "<div align=\"left\" style=\"text-align:left;\"><a " &
      "href=\"https://app.example.com/\" target=\"_blank\" " &
      "style=\"display:inline-block;background-color:#1f6feb;" in html
    check "padding:12px 24px;mso-padding-alt:0;" &
      "text-underline-color:#1f6feb;border-radius:6px;\">" &
      "<!--[if mso]><i style=\"mso-font-width:150%;mso-text-raise:150%\" " &
      "hidden>&emsp;</i><span style=\"mso-text-raise:75%;\"><![endif]-->" &
      "Open dashboard<!--[if mso]></span><i style=\"mso-font-width:150%;\" " &
      "hidden>&emsp;&#8203;</i><![endif]--></a></div>" in html
    check "<table role=\"presentation\" border=\"0\"" notin
      html.split("Buttons</h1>")[1]
    # Its mso-* properties are not on the closed list yet (R-OL-15).
    check codeCssMsoUnlisted in codes(res)
    # Right to left, the zero-width space goes on both sides; a side
    # wider than 5 em spaces is split over several.
    let rtl = body(render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "تواصل", [("padding", "12px 96px")],
        [("word_padding", "spacers")]), rtl = true).html)
    check "<i style=\"mso-font-width:300%;mso-text-raise:150%\" hidden>" &
      "&emsp;&emsp;&#8203;</i>" in rtl
    check "<i style=\"mso-font-width:300%;\" hidden>&emsp;&emsp;&#8203;" &
      "</i>" in rtl

  test "test_spacers_and_vml_always_conflict":
    let res = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Go", [("width", "200px")],
        [("word_padding", "spacers"), ("vml", "always")]))
    check codeVocabBadValue in codes(res)

suite "tap target and destination":
  test "test_button_shorter_than_44px_warns":
    let small = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Small", [("padding", "8px 16px")]))
    check problems(small) == @[codeA11yTapTarget]
    check "36px" in small.diagnostics[0].message
    # The defaults meet it: 20 + 2 x 12 = 44.
    let ok = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Default"))
    check codeA11yTapTarget notin codes(ok)
    # A smaller size keeps the theme's line-height ratio: 14 x 20 / 16
    # = 18, and 18 + 2 x 13 = 44.
    let small14 = render(proc(r: EmailRenderer; s: EmailNode) =
      discard r.button(s, "Small", [("font-size", "14px"),
        ("padding", "13px 16px")]))
    check problems(small14).len == 0
    check "line-height:18px;" in small14.html

  test "test_button_destination_rules":
    for (href, code) in [("", codeUrlEmpty), ("#", codeUrlEmpty),
        ("#top", codeUrlEmpty), ("http://app.example.com/", codeUrlScheme),
        ("javascript:alert(1)", codeUrlScheme), ("/relative", codeUrlScheme),
        ("https://", codeUrlScheme)]:
      let res = render(proc(r: EmailRenderer; s: EmailNode) =
        discard r.child(s, "mailButton", attrs = [("href", href)],
          text = "Go"))
      checkpoint(href)
      check code in codes(res)
    for href in ["https://app.example.com/", "mailto:help@example.com",
        "tel:+15550100"]:
      let res = render(proc(r: EmailRenderer; s: EmailNode) =
        discard r.child(s, "mailButton", attrs = [("href", href)],
          text = "Go"))
      checkpoint(href)
      check problems(res).len == 0

suite "the brief and the declared degradations":
  test "test_word_degradations_are_declared":
    # R-BTN-02 / R-OL-12: square corners and a label-only link in Word
    # are declared, so the lint reports them as degradations.
    var found = false
    for d in declaredDegradations():
      if d.name == "border-radius" and cfOutlookWord in d.families:
        found = true
    check found

suite "the buttons' story set":
  test "test_button_stories_render_cleanly":
    for s in buttonStories:
      checkpoint(s.name)
      let html = renderButtonStory(s.name).html
      check "<mailbutton" notin html.toLowerAscii()
      check html.count("<v:roundrect") == html.count("</v:roundrect>")
