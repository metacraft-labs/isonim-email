## isonim_email/lower/hero.nim — `mailHero` lowering.
##
## A hero is a band (like a section: `W` px wide, centred, its content
## an implicit single column with the default column padding) whose
## content sits in one table cell, so it can have a height and a
## vertical alignment in every client, Word included (a `div` has
## neither without `display:flex`, which R-OL-10 forbids). With a
## background image (catalogue R-VML-01, R-VML-06):
##
## ```html
## <!--[if mso]><table role="presentation" align="center" border="0" cellpadding="0" cellspacing="0" width="{W}" style="width:{W}px;"><tr><td bgcolor="{bg}" style="background-color:{bg};"><![endif]-->
## <!--[if gte mso 9]><v:rect … style="width:{W}px;height:{H}px;"><v:fill … /><v:textbox inset="0,0,0,0"><![endif]-->
## <div style="margin:0 auto;max-width:{W}px;">
##   <!--[if !mso]><!--><div style="background-color:{bg};background-image:url('{src}');background-position:{p};background-size:{s};background-repeat:{r};"><!--<![endif]-->
##   <table role="presentation" width="100%" border="0" cellpadding="0" cellspacing="0" style="width:100%;"><tr>
##     <td height="{H − padding}" valign="{v}" align="{align}" style="padding:{pad};height:{H − padding}px;box-sizing:content-box;vertical-align:{v};font-size:16px;text-align:{align};direction:{dir};">{content}</td>
##   </tr></table>
##   <!--[if !mso]><!--></div><!--<![endif]-->
## </div>
## <!--[if gte mso 9]></v:textbox></v:rect><![endif]-->
## <!--[if mso]></td></tr></table><![endif]-->
## ```
##
## The background box (colour, image, the hero's classes) is hidden
## from Word, which would paint its colour over the image; Word paints
## the fallback colour on the ghost cell and the image with VML. The
## cell's `height` is a minimum everywhere, so a `height` and a
## `min_height` hero look the same outside Word. Word needs the
## rectangle's px height (R-VML-02): a hero with a background image
## and neither is `E-LAYOUT-VML-SIZE` when `outlookWord` is on. A
## `height` hero's rectangle has that height; a `min_height` hero's
## grows with its content only through `mso-fit-shape-to-text`, which
## is unverified (R-VML-03), so it gets the rectangle only with the
## target's `vmlFitToText`, and otherwise shows Word its fallback
## colour, at least `min_height` tall. A hero without an image is the
## same band without the VML.
##
## A `height` hero's rectangle never grows, so its content must fit
## (R-VML-08): `contentHeight` estimates it at the text metrics' worst
## case, and more than the cell holds is `E-LAYOUT-HERO-OVERFLOW`.
##
## Ghost tables and VML come from `mso/` only. Pure tree building:
## identical on the C and JS targets.

import std/[math, strutils, tables]
import ../renderer
import ../diagnostics
import ../target
import ../style/units
import ../style/shorthand
import ../style/metrics
import ../passes/layout
import ../mso/ghost
import ../mso/vml
import ./section
import ./button

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const heroConsumed = ["background-color", "background_color", "padding",
  "padding-top", "padding-right", "padding-bottom", "padding-left",
  "height", "min-height", "min_height", "vertical-align", "vertical_align",
  "text-align", "text_align", "direction", "font-size"]

proc lengthPx(node: EmailNode; prop: string;
    diags: var seq[EmailDiagnostic]): int =
  ## A px length prop as whole px; 0 when absent. A length that is not
  ## px is `E-LAYOUT-VML-SIZE` (R-VML-02).
  let v = rawValue(node, prop)
  if v.len == 0:
    return 0
  try:
    if v.strip().endsWith("%"):
      raise newException(StyleError, "a percentage")
    result = int(toPx(normaliseLength("height", v)))
    if result <= 0:
      raise newException(StyleError, "not positive")
  except StyleError, ValueError:
    diags.add(EmailDiagnostic(severity: sevError, code: codeLayoutVmlSize,
      message: "mailHero " & prop.replace("-", "_") & " '" & v &
        "' is not a positive px length (R-VML-02)", origin: node.origin,
      rules: @["R-VML-02"]))
    result = 0

proc pxOr(value: string; fallback: float): float =
  try:
    toPx(value.strip())
  except StyleError, ValueError:
    fallback

proc verticalMargins(node: EmailNode): float =
  ## Top plus bottom margin, px (P5 has normalised them).
  var sides = [0.0, 0.0, 0.0, 0.0]
  let m = node.styles.getOrDefault("margin", "")
  if m.len > 0:
    try:
      let s = expandBox(m)
      for i in 0 .. 3:
        sides[i] = pxOr(s[i], 0)
    except StyleError:
      discard
  for (i, k) in [(0, "margin-top"), (2, "margin-bottom")]:
    if k in node.styles:
      sides[i] = pxOr(node.styles[k], 0)
  max(0.0, sides[0]) + max(0.0, sides[2])

proc textRuns(node: EmailNode; runs: var seq[string]) =
  ## The block's text, split at `br` (a forced line break).
  for c in node.children:
    if c.kind == enText:
      runs[^1].add(c.text)
    elif c.kind == enElement and c.tag == "br":
      runs.add("")
    elif c.kind == enElement:
      textRuns(c, runs)

proc wrappedLines(text, stack: string; size: float; bold: bool;
    width: float; approx: var bool): int =
  ## Lines of `text` wrapped greedily at `width`, worst-case face.
  var line = ""
  for word in text.splitWhitespace():
    let w = measureText(word, stack, size, bold)
    approx = approx or w.approx
    if w.width > width:
      # A word wider than the line breaks over as many lines as it needs.
      if line.len > 0:
        inc result
        line = ""
      result += int(ceil(w.width / max(1.0, width))) - 1
      line = word
      continue
    let cand = if line.len == 0: word else: line & " " & word
    if line.len > 0 and measureText(cand, stack, size, bold).width > width:
      inc result
      line = word
    else:
      line = cand
  if line.len > 0:
    inc result

proc contentHeight*(node: EmailNode; width: float;
    approx: var bool): float =
  ## The estimated height of a hero's content at `width` (R-VML-08):
  ## text blocks wrapped at the metrics' worst case, buttons, spacers
  ## and dividers at their own heights, margins summed; anything else is
  ## not measured.
  for c in node.children:
    if c.kind != enElement:
      continue
    case c.tag
    of "h1", "h2", "h3", "h4", "h5", "h6", "p", "mailText":
      let size = pxOr(c.styles.getOrDefault("font-size", "16px"), 16)
      var lh = pxOr(c.styles.getOrDefault("line-height", ""), -1)
      if lh <= 0:
        lh = minLineHeight(size)
      let stack = c.styles.getOrDefault("font-family", "sans-serif")
      let bold = isBoldWeight(c.styles.getOrDefault("font-weight",
        if c.tag.startsWith("h"): "700" else: "400"))
      var runs = @[""]
      textRuns(c, runs)
      var lines = 0
      for run in runs:
        lines += max(1, wrappedLines(run, stack, size, bold, width, approx))
      result += float(lines) * lh + verticalMargins(c)
    of "mailButton":
      var ignored: seq[EmailDiagnostic] = @[]
      result += float(geometry(c, ignored).height) + verticalMargins(c)
    of "mailSpacer":
      result += pxOr(c.styles.getOrDefault("height", "16px"), 16)
    of "mailDivider":
      var pad = [16.0, 0.0, 16.0, 0.0]
      let p = c.styles.getOrDefault("padding", "")
      if p.len > 0:
        try:
          let s = expandBox(p)
          for i in 0 .. 3:
            pad[i] = pxOr(s[i], 0)
        except StyleError:
          discard
      var line = 1.0
      for part in c.styles.getOrDefault("border", "").splitWhitespace():
        if part.len > 0 and part[0] in {'0' .. '9'}:
          line = pxOr(part, 1)
      result += pad[0] + pad[2] + line
    else:
      discard

proc lowerHero*(node: EmailNode; ctx: LowerCtx):
    tuple[nodes: seq[EmailNode]; inner: EmailNode;
      diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one laid-out `mailHero`; its content is moved into `inner`
  ## (the cell) for the caller to lower next.
  let r = EmailRenderer()
  var diags: seq[EmailDiagnostic] = @[]
  let image = readBackground(node, diags)
  let w = node.layout.outer
  var padding = node.layout.padding
  let colPad = defaultColumnPadding(ctx.theme)
  for i in 0 .. 3:
    padding[i] += colPad[i]
  let height = lengthPx(node, "height", diags)
  let minHeight = lengthPx(node, "min-height", diags)
  if height > 0 and minHeight > 0:
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailHero has both height and min_height: give one " &
        "(R-VML-02)", origin: node.origin, rules: @["R-VML-02"]))
  let boxHeight = if height > 0: height else: minHeight
  if image.src.len > 0 and ctx.target.outlookWord and boxHeight == 0 and
      rawValue(node, "height").len == 0 and
      rawValue(node, "min-height").len == 0:
    diags.add(EmailDiagnostic(severity: sevError, code: codeLayoutVmlSize,
      message: "a mailHero with a background image needs height or " &
        "min_height when Outlook output is on: Word draws the image " &
        "as a VML rectangle, which needs a px height (R-VML-02)",
      origin: node.origin, rules: @["R-VML-02"]))
  var cellHeight = 0
  if boxHeight > 0:
    cellHeight = boxHeight - padding[0] - padding[2]
    if cellHeight <= 0:
      diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
        message: "mailHero height " & $boxHeight & "px leaves no room " &
          "inside its vertical padding (" & $(padding[0] + padding[2]) &
          "px) (R-VML-02)", origin: node.origin, rules: @["R-VML-02"]))
      cellHeight = 0
  if image.src.len > 0 and ctx.target.outlookWord and height > 0 and
      cellHeight > 0:
    # R-VML-08: Word's rectangle is exactly `height` tall.
    let width = float(w - padding[1] - padding[3])
    var approx = false
    let need = contentHeight(node, width, approx)
    if approx:
      diags.add(EmailDiagnostic(severity: sevInfo,
        code: codeLayoutMetricsApprox,
        message: "the mailHero's text has characters outside the text " &
          "metrics; its height is estimated from average advances",
        origin: node.origin, rules: @["R-VML-08"]))
    if need > float(cellHeight):
      diags.add(EmailDiagnostic(severity: sevError,
        code: codeLayoutHeroOverflow,
        message: "the mailHero's content needs up to " &
          formatPx(ceil(need)) & " at the text metrics' worst case but " &
          "its height leaves it " & $cellHeight & "px (" & $height &
          "px less " & $(padding[0] + padding[2]) & "px of padding); " &
          "Word's background rectangle does not grow: make the hero " &
          "taller, shorten the content, or use min_height (R-VML-08)",
        origin: node.origin, rules: @["R-VML-08"]))
  var valign = rawValue(node, "vertical-align").toLowerAscii()
  if valign.len == 0:
    valign = "top"
  if valign notin ["top", "middle", "bottom"]:
    diags.add(EmailDiagnostic(severity: sevError, code: codeVocabBadValue,
      message: "mailHero vertical_align '" & valign & "' is not top, " &
        "middle or bottom", origin: node.origin, rules: @["R-VML-06"]))
    valign = "top"
  let dir = directionOf(node, ctx)
  let align = alignOf(node, dir)
  let background = if image.src.len > 0: image.color
    else: colourOf(node, "background-color")

  # The cell.
  let td = r.createElement("td")
  td.origin = node.origin
  if cellHeight > 0:
    r.setAttribute(td, "height", $cellHeight)
  r.setAttribute(td, "valign", valign)
  r.setAttribute(td, "align", align)
  r.setStyle(td, "padding", boxText(padding))
  if cellHeight > 0:
    r.setStyle(td, "height", $cellHeight & "px")
    # The cell's height excludes its padding whatever the client's own
    # stylesheet says (Roundcube's sets `border-box` on every element,
    # which took the padding out of the hero's height).
    r.setStyle(td, "box-sizing", "content-box")
  r.setStyle(td, "vertical-align", valign)
  r.setStyle(td, "font-size", innerFontSize)
  r.setStyle(td, "text-align", align)
  if dir.len > 0:
    r.setStyle(td, "direction", dir)
  for k, v in node.styles.pairs:
    if k notin heroConsumed and k notin backgroundProps:
      r.setStyle(td, k, v)
  let tr = r.createElement("tr")
  r.appendChild(tr, td)
  let table = r.createElement("table")
  table.origin = node.origin
  for (k, v) in [("role", "presentation"), ("width", "100%"),
      ("border", "0"), ("cellpadding", "0"), ("cellspacing", "0")]:
    r.setAttribute(table, k, v)
  r.setStyle(table, "width", "100%")
  r.appendChild(table, tr)

  # The background box: the colour, the image and the hero's classes.
  let box = r.createElement("div")
  box.origin = node.origin
  if image.src.len > 0:
    for (k, v) in cssDeclarations(image):
      r.setStyle(box, k, v)
  elif background.len > 0:
    r.setStyle(box, "background-color", background)
  if "class" in node.attrs:
    r.setAttribute(box, "class", node.attrs["class"])
  r.appendChild(box, table)

  let outer = r.createElement("div")
  outer.origin = node.origin
  r.setStyle(outer, "margin", "0 auto")
  r.setStyle(outer, "max-width", $w & "px")
  if ctx.target.outlookWord:
    for n in hiddenFromWord(box):
      r.appendChild(outer, n)
  else:
    r.appendChild(outer, box)

  let kids = node.children # Copy: appendChild detaches as it moves.
  for c in kids:
    r.appendChild(td, c)

  if not ctx.target.outlookWord:
    return (@[outer], td, diags)
  var nodes = @[ghostTableOpen(w, GhostCell(background: background))]
  let fit = height == 0 and minHeight > 0
  let vml = image.src.len > 0 and boxHeight > 0 and
    (not fit or ctx.target.vmlFitToText)
  if vml:
    let f = image.fill
    nodes.add(vmlBackgroundOpen(w, boxHeight, image.src, image.color,
      f.kind, f.origin, f.position, f.size, f.aspect, fit))
  nodes.add(outer)
  if vml:
    nodes.add(vmlBackgroundClose())
  nodes.add(ghostTableClose())
  (nodes, td, diags)
