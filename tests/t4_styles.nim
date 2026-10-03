# rule: R-CSS-11
## P5 resolves tokens to light literals, splits variant keys out of
## inline for P6, normalises units/colours/shorthands, adds the closed MSO
## list under outlookWord, and mirrors width/height/bgcolor/align —
## without reordering children and without silently dropping anything but
## harmful `display` and `var()`.
##
## Variant keys are hand-set rather than compiled from `class="sm:…"`: the
## style map is content-derived (partly from `isonim/`'s own tree), so a
## test template would depend on incidental entries — a scratch template
## proved the Tailwind-variant→`@sm:`/`@md:` mapping separately instead. The `md:` half
## of that proof is now committed below
## (`test_md_class_through_real_map_errors`, C-only): it fails loudly if
## `md` leaves build-tailwind's `--variants` list.
##
## Backend-independent (tree building + pure pass), so `just test` also
## runs it on JS.
import std/[strutils, tables, unittest]
import isonim_email
import isonim/dsl/tailwind

proc styled(tag: string; decls: openArray[(string, string)];
            kids: varargs[EmailNode]): EmailNode =
  let r = EmailRenderer()
  result = r.createElement(tag)
  for (p, v) in decls:
    r.setStyle(result, p, v)
  for k in kids:
    r.appendChild(result, k)

proc tokenTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Tok"):
      mailSection:
        p(color = tok"color.text.primary"): text "hi"

proc flexDivTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Flex"):
      mailSection:
        mailColumn:
          tdiv(display = "flex"):
            p: text "laid out by flex"

proc gridParaTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Grid"):
      mailSection:
        mailColumn:
          p(display = "grid"): text "laid out by grid"

proc findTag(n: EmailNode; tag: string): EmailNode =
  if n.kind == enElement and n.tag == tag:
    return n
  for c in n.children:
    let hit = findTag(c, tag)
    if hit != nil:
      return hit
  nil

proc allStyleText(n: EmailNode): string =
  if n.kind == enElement:
    for k, v in n.styles.pairs:
      result.add(k & ":" & v & ";")
  for c in n.children:
    result.add(allStyleText(c))

suite "tokens resolve to light literals inline":
  test "test_tokens_resolve_to_light_literals":
    # Through the macro: a tok"…" style value arrives via the setStyle
    # overload and P5 inlines the light literal.
    let tree = renderAuthoringTree(tokenTpl, 0)
    let (head, diags) = applyStyles(tree, defaultTheme(), defaultTarget())
    check head.len == 0
    check diags.len == 0
    check findTag(tree, "p").styles["color"] == "#111827"
    # Direct: Box and packed-type tokens expand through the same seam
    # (P2 will settle which property carries a type token; P5 expands
    # whichever carrier it arrives under).
    let r = EmailRenderer()
    let box = r.createElement("div")
    r.setStyle(box, "padding", tok"space.section")
    let (boxHead, boxDiags) = applyStyles(box, defaultTheme(),
      defaultTarget())
    check boxHead.len == 0
    check boxDiags.len == 0
    check box.styles["padding"] == "24px 0"
    let tp = r.createElement("p")
    r.setStyle(tp, "font", tok"type.body")
    let (_, tpDiags) = applyStyles(tp, defaultTheme(), defaultTarget())
    check tpDiags.len == 0
    check tp.styles["font-size"] == "16px"
    check tp.styles["line-height"] == "24px"
    check "font" notin tp.styles
    # A token colour stays silent under darkMode=designed (tokens carry
    # their own dark pair — only raw colours warn).
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let tokP = r.createElement("p")
    r.setStyle(tokP, "color", tok"color.text.primary")
    let (_, tokDiags) = applyStyles(tokP, defaultTheme(), designed)
    check tokDiags.len == 0
    check tokP.styles["color"] == "#111827"

suite "variant keys split out of inline for P6":
  test "test_variant_keys_split_out":
    # A span: block text elements also get their type defaults inline
    # (lower/text.nim), which would crowd the count checked here.
    let p = styled("span", [("color", "#111827"), ("@sm:padding", "8"),
      ("@dark:color", "white"), ("@hover:text-decoration", "underline")])
    let (head, diags) = applyStyles(p, defaultTheme(), defaultTarget())
    check diags.len == 0
    check p.styles.len == 1
    check p.styles["color"] == "#111827"
    check head.len == 3
    check (head[0].variant, head[0].prop, head[0].value) ==
      ("sm", "padding", "8px")
    check (head[1].variant, head[1].prop, head[1].value) ==
      ("dark", "color", "#ffffff")
    check (head[2].variant, head[2].prop, head[2].value) ==
      ("hover", "text-decoration", "underline")
    for h in head:
      check h.node == p
    # A head-bound flex is kept, not removed: Word ignores head rules
    # entirely, so it cannot collapse anything (the lint precedent).
    # (A span: a text element or a div would also get its default
    # inline colour and type.)
    let q = styled("span", [("@sm:display", "flex")])
    let (qHead, qDiags) = applyStyles(q, defaultTheme(), defaultTarget())
    check qDiags.len == 0
    check q.styles.len == 0
    check qHead.len == 1
    check (qHead[0].variant, qHead[0].prop, qHead[0].value) ==
      ("sm", "display", "flex")

suite "dark variants resolve tokens to their dark literal":
  test "test_dark_variant_tokens_resolve_dark":
    # A tok"…" value under @dark: resolves through the theme's dark
    # literal — the value the dark rules exist to carry — while the same
    # token inline and under sm:/hover: resolves to the light literal.
    let theme = defaultTheme()
    let key = "color.text.primary"
    check theme.lightFor(key) != theme.darkFor(key)
    let r = EmailRenderer()
    let p = r.createElement("p")
    r.setStyle(p, "color", tok"color.text.primary")
    r.setStyle(p, "@dark:color", tok"color.text.primary")
    r.setStyle(p, "@dark:background-color", tok"color.surface.canvas")
    r.setStyle(p, "@hover:color", tok"color.text.primary")
    r.setStyle(p, "@sm:color", tok"color.text.primary")
    let (head, diags) = applyStyles(p, theme, defaultTarget())
    check diags.len == 0
    check p.styles["color"] == theme.lightFor(key)
    check head.len == 4
    for h in head:
      case h.variant
      of "dark":
        if h.prop == "color":
          check h.value == theme.darkFor(key)
        else:
          check h.prop == "background-color"
          check h.value == theme.darkFor("color.surface.canvas")
          check h.value != theme.lightFor("color.surface.canvas")
      else:
        check h.value == theme.lightFor(key)
    # End to end: the dark head block carries the dark literal, never
    # the light one.
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let blocks = assembleHead(head, designed).blocks
    var darkText = ""
    for b in blocks:
      if "prefers-color-scheme" in b.text:
        darkText = b.text
    check ("color:" & theme.darkFor(key) & " !important") in darkText
    check theme.lightFor(key) notin darkText

suite "margins convert to cell padding":
  test "test_margins_convert_to_cell_padding":
    # rule: R-OL-04
    let inner = styled("div", [("margin", "8px 0")])
    let cell = styled("td", [("padding", "10px")], inner)
    let (head, diags) = applyStyles(cell, defaultTheme(), defaultTarget())
    check head.len == 0
    check "margin" notin inner.styles
    check cell.styles["padding"] == "18px 10px"
    check diags.len == 1
    check diags[0].severity == sevWarning
    check diags[0].code == codeLayoutMarginConverted
    check diags[0].rules == @["R-OL-04"]
    # Longhands convert one side; block text keeps its margins.
    let div2 = styled("div", [("margin-top", "4px")])
    let cell2 = styled("td", [("padding", "10px")], div2)
    let (_, diags2) = applyStyles(cell2, defaultTheme(), defaultTarget())
    check "margin-top" notin div2.styles
    check cell2.styles["padding"] == "14px 10px 10px"
    check diags2.len == 1
    check diags2[0].code == codeLayoutMarginConverted
    let p = styled("p", [("margin", "16px 0")])
    let (_, pDiags) = applyStyles(p, defaultTheme(), defaultTarget())
    check p.styles["margin"] == "16px 0"
    check pDiags.len == 0

suite "MSO additions apply iff outlookWord":
  test "test_mso_additions_apply_iff_outlook_word":
    # rule: R-OL-06
    proc msoTree(): EmailNode =
      styled("table", [],
        styled("tr", [],
          styled("td", [("padding", "4px")],
            styled("p", [("line-height", "24px"), ("display", "none")])),
          styled("td", [("padding", "4px")],
            styled("p", [("line-height", "normal")]))))
    let on = msoTree()
    let (_, onDiags) = applyStyles(on, defaultTheme(), defaultTarget())
    check onDiags.len == 0
    check on.styles["mso-table-lspace"] == "0pt"
    check on.styles["mso-table-rspace"] == "0pt"
    let tds = on.children[0].children
    check tds[0].styles["mso-padding-alt"] == "4px"
    let hid = tds[0].children[0]
    check hid.styles["mso-line-height-rule"] == "exactly"
    check hid.styles["mso-hide"] == "all"
    # `normal` line-height needs no rule.
    check "mso-line-height-rule" notin tds[1].children[0].styles
    var offTarget = defaultTarget()
    offTarget.outlookWord = false
    let off = msoTree()
    let (_, offDiags) = applyStyles(off, defaultTheme(), offTarget)
    check offDiags.len == 0
    check "mso-table-lspace" notin off.styles
    check "mso-padding-alt" notin off.children[0].children[0].styles
    check "mso-hide" notin off.children[0].children[0].children[0].styles
    # Author-written mso-* stays for P9 to prune (only P9 removes by
    # target).
    let keep = styled("td", [("mso-hide", "all")])
    let (_, keepDiags) = applyStyles(keep, defaultTheme(), offTarget)
    check keepDiags.len == 0
    check keep.styles["mso-hide"] == "all"

suite "attributes mirror CSS both ways":
  test "test_attributes_mirror_css_both_ways":
    let r = EmailRenderer()
    # Attribute seeds CSS.
    let td = r.createElement("td")
    r.setAttribute(td, "width", "600")
    r.setAttribute(td, "bgcolor", "red")
    r.setAttribute(td, "align", "center")
    let (_, seedDiags) = applyStyles(td, defaultTheme(), defaultTarget())
    check seedDiags.len == 0
    check td.styles["width"] == "600px"
    check td.styles["background-color"] == "#ff0000"
    check td.attrs["bgcolor"] == "#ff0000"
    check td.styles["text-align"] == "center"
    # CSS drives the attribute (CSS wins conflicts).
    let img = styled("img", [("width", "300px")])
    let (_, imgDiags) = applyStyles(img, defaultTheme(), defaultTarget())
    check imgDiags.len == 0
    check img.attrs["width"] == "300"
    let clash = r.createElement("td")
    r.setAttribute(clash, "width", "500")
    r.setStyle(clash, "width", "600px")
    discard applyStyles(clash, defaultTheme(), defaultTarget())
    check clash.attrs["width"] == "600"
    let pct = styled("table", [("width", "50%")])
    discard applyStyles(pct, defaultTheme(), defaultTarget())
    check pct.attrs["width"] == "50%"
    # Non-carriers keep CSS-only (no invalid attribute is minted).
    let wrap = styled("div", [("width", "600px")])
    discard applyStyles(wrap, defaultTheme(), defaultTarget())
    check "width" notin wrap.attrs

suite "harmful display is removed with its R-OL-10 severity":
  test "test_harmful_display_removed_with_error":
    # rule: R-OL-10
    let tree = renderAuthoringTree(flexDivTpl, 0)
    let (head, diags) = applyStyles(tree, defaultTheme(), defaultTarget())
    check head.len == 0
    check "display" notin findTag(tree, "div").styles
    check diags.len == 1
    check diags[0].severity == sevError
    check diags[0].code == "E-CSS-HARMFUL"
    check diags[0].code == codeCssHarmful
    check diags[0].families == {cfOutlookWord}
    check diags[0].rules == @["R-OL-10"]
    check "display:flex" in diags[0].message
    check hasErrors(diags)
    # Non-containers too: P5 removes everywhere, but off a layout
    # container nothing collapses, so the removal is a warning (catalogue
    # R-OL-10, the same severity lint gives it).
    let grid = renderAuthoringTree(gridParaTpl, 0)
    let (_, gridDiags) = applyStyles(grid, defaultTheme(), defaultTarget())
    check "display" notin findTag(grid, "p").styles
    check gridDiags.len == 1
    check gridDiags[0].severity == sevWarning
    check gridDiags[0].code == codeSupportUnsupported
    check gridDiags[0].rules == @["R-OL-10"]
    check "display:grid" in gridDiags[0].message
    check "was removed" in gridDiags[0].message
    check not hasErrors(gridDiags)

suite "custom properties never reach output":
  test "test_no_var_anywhere":
    # rule: R-CSS-11
    # Spans: a text element or a div would also get its default inline
    # colour and type once the var() colour is removed.
    let p = styled("span", [("color", "var(--ink)"), ("--ink", "#111827"),
      ("width", "var (--w)")])
    let (head, diags) = applyStyles(p, defaultTheme(), defaultTarget())
    check p.styles.len == 0
    check head.len == 0
    check diags.len == 3
    for d in diags:
      check d.severity == sevError
      check d.code == codeVocabBadValue
      check d.rules == @["R-CSS-11"]
    check hasErrors(diags)
    check "var(" notin allStyleText(p)
    # Variant values are rejected the same way (P6's serialiser would
    # otherwise pass the parens through into a head block).
    let q = styled("span", [("@sm:color", "var(--x)")])
    let (qHead, qDiags) = applyStyles(q, defaultTheme(), defaultTarget())
    check qHead.len == 0
    check q.styles.len == 0
    check qDiags.len == 1
    check qDiags[0].rules == @["R-CSS-11"]
    check "var(" notin allStyleText(q)

suite "md: violates the one-breakpoint rule":
  test "test_md_breakpoint_errors":
    let p = styled("p", [("@md:padding", "24px"), ("color", "#111827")])
    let (head, diags) = applyStyles(p, defaultTheme(), defaultTarget())
    check head.len == 0
    check p.styles["color"] == "#111827"
    # The unsplittable key stays inline (never-drop); the error blocks
    # `toMessage`, so it never reaches output.
    check p.styles["@md:padding"] == "24px"
    check diags.len == 1
    check diags[0].severity == sevError
    check diags[0].code == codeVocabBadValue
    check "one breakpoint" in diags[0].message
    check "sm:" in diags[0].message
    check hasErrors(diags)
    let q = styled("p", [("@lg:padding", "8px")])
    let (_, qDiags) = applyStyles(q, defaultTheme(), defaultTarget())
    check qDiags.len == 1
    check "unknown variant" in qDiags[0].message

when not defined(js):
  proc mdFragilityTpl(r: EmailRenderer; x: int): EmailNode =
    ui(r):
      mailDocument(lang = "en", title = "Md"):
        mailSection:
          p(class = "md:p-6"): text "md must stay tagged"

  suite "md: tagging survives the real map":
    test "test_md_class_through_real_map_errors":
      # C backend only (the ui macro expands Tailwind classes at compile
      # time only on C), and only under drivers that pass the map
      # override (`just test`; other drivers skip): a scratch template
      # with an md: class through the REAL generated map must surface
      # the @md: key and P5's one-breakpoint error. If md: leaves
      # build-tailwind's --variants list, the expansion flattens the class to
      # plain padding and the @md: check below fails loudly. Requires
      # md:p-6 in the map (anchored by a literal mention in
      # passes/head.nim, which the extractor's src/ scan covers).
      # The body sits in the `else` branch deliberately: `skip()` alone
      # only marks the test (Nim 2.2 runs the rest anyway), so without
      # the branch a driver without the override would run the body
      # against isonim's fallback map and fail instead of skipping.
      when tailwindStylesPathOverride == "":
        skip()
      else:
        let tree = renderAuthoringTree(mdFragilityTpl, 0)
        let para = findTag(tree, "p")
        check "@md:padding" in para.styles
        check para.styles["@md:padding"] == "24px"
        let (_, diags) = applyStyles(tree, defaultTheme(), defaultTarget())
        var sawBreakpoint = false
        for d in diags:
          if d.code == codeVocabBadValue and "one breakpoint" in d.message:
            sawBreakpoint = true
        check sawBreakpoint

suite "children keep order and strangers keep values":
  test "test_children_keep_order_and_strangers_keep_values":
    let tree = styled("div", [("cursor", "pointer"), ("word-spacing", "2")],
      styled("p", []), styled("span", []))
    let (head, diags) = applyStyles(tree, defaultTheme(), defaultTarget())
    check head.len == 0
    check diags.len == 0
    check tree.children.len == 2
    check tree.children[0].tag == "p"
    check tree.children[1].tag == "span"
    # Unsupported properties pass through verbatim for P10 — not even
    # unit normalisation touches them.
    check tree.styles["cursor"] == "pointer"
    check tree.styles["word-spacing"] == "2"

suite "raw colours warn under darkMode=designed":
  test "test_raw_colours_warn_when_designed":
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let raw = styled("p", [("color", "#111827")])
    let (_, rawDiags) = applyStyles(raw, defaultTheme(), designed)
    check rawDiags.len == 1
    check rawDiags[0].severity == sevWarning
    check rawDiags[0].code == codeDarkRawColor
    check raw.styles["color"] == "#111827"
    # Accommodate mode stays silent about the same declaration.
    let calm = styled("p", [("color", "#111827")])
    let (_, calmDiags) = applyStyles(calm, defaultTheme(), defaultTarget())
    check calmDiags.len == 0

suite "translucent colours inline as the blend-then-rgba pair":
  # rule: R-CSS-14
  test "test_translucent_colours_inline_as_a_pair":
    # The catalogue's example value: rgba(0,0,0,.5) over the default
    # white truncates to #7f7f7f. With Word in the target the blend
    # comes first, as the declaration's fallback, then rgba() for the
    # other clients.
    let p = styled("p", [("color", "rgba(0,0,0,.5)")])
    let (_, diags) = applyStyles(p, defaultTheme(), defaultTarget())
    check diags.len == 0
    check p.styles["color"] == "rgba(0,0,0,.5)"
    check p.fallbacks["color"] == "#7f7f7f"
    check "color:#7f7f7f;color:rgba(0,0,0,.5);" in serialize(p)
    # Against an ancestor background the blend follows it, and a
    # background's pair mirrors its blend as the cell's bgcolor.
    let card = styled("div", [("background-color", "#1f6feb")],
      styled("p", [("color", "rgba(0,0,0,.5)")]))
    discard applyStyles(card, defaultTheme(), defaultTarget())
    check card.children[0].fallbacks["color"] == "#0f3775"
    let cell = styled("td", [("background-color", "rgba(0,0,0,.5)")])
    discard applyStyles(cell, defaultTheme(), defaultTarget())
    check cell.attrs["bgcolor"] == "#7f7f7f"
    check cell.styles["background-color"] == "rgba(0,0,0,.5)"
    # Without Word, rgba() alone.
    var noWord = defaultTarget()
    noWord.outlookWord = false
    let q = styled("p", [("color", "rgba(0,0,0,.5)")])
    discard applyStyles(q, defaultTheme(), noWord)
    check q.styles["color"] == "rgba(0,0,0,.5)"
    check "color" notin q.fallbacks
    # A vocabulary element keeps the opaque blend alone: its lowering
    # paints Word-safe hex.
    let band = styled("mailSection", [("background-color", "rgba(0,0,0,.5)")])
    discard applyStyles(band, defaultTheme(), defaultTarget())
    check band.styles["background-color"] == "#7f7f7f"
    check band.fallbacks.len == 0

suite "text elements never inherit their colour":
  test "test_text_elements_get_the_theme_text_colour":
    # Every heading, paragraph and list item without a colour of its own
    # gets the theme's primary text colour inline; a cell gets it only
    # when it holds text itself (a layout cell inherits nothing it
    # needs). An author colour is never replaced. Clients whose dark
    # scheme supplies a light default text colour (SnappyMail's dark
    # themes, WebKit under color-scheme: light dark) otherwise paint
    # inherited text light on the message's light background.
    let r = EmailRenderer()
    let h1 = styled("h1", [])
    r.setTextContent(h1, "Heading")
    let h3 = styled("h3", [])
    r.setTextContent(h3, "Sub")
    let p = styled("p", [])
    r.setTextContent(p, "Body")
    let li = styled("li", [])
    r.setTextContent(li, "Item")
    let own = styled("p", [("color", "#1f6feb")])
    r.setTextContent(own, "Mine")
    let textCell = styled("td", [])
    r.setTextContent(textCell, "Widget: $10.00")
    let layoutCell = styled("td", [], styled("p", []))
    let blankCell = styled("td", [])
    r.setTextContent(blankCell, "  ")
    let tree = styled("div", [], h1, h3, p, li, own,
      styled("table", [], styled("tr", [], textCell, layoutCell,
        blankCell)))
    let (head, diags) = applyStyles(tree, defaultTheme(), defaultTarget())
    check head.len == 0
    check diags.len == 0
    for n in [h1, h3, p, li, textCell]:
      check n.styles.getOrDefault("color", "") == "#111827"
    check own.styles["color"] == "#1f6feb"
    check "color" notin layoutCell.styles
    check layoutCell.children[0].styles["color"] == "#111827"
    check "color" notin blankCell.styles
    check "color" notin tree.styles
    # The colour is the theme's, not a constant.
    var pairs: seq[(string, ThemePair)] = @[]
    let base = defaultTheme()
    for key in requiredThemeKeys:
      pairs.add((key, ThemePair(light: base.lightFor(key),
        dark: base.darkFor(key))))
    for i, (key, _) in pairs:
      if key == "color.text.primary":
        pairs[i][1] = ThemePair(light: "#202122", dark: "#eeeeee")
    let custom = buildTheme(pairs, "custom")
    let q = styled("p", [])
    r.setTextContent(q, "Custom")
    discard applyStyles(q, custom, defaultTarget())
    check q.styles["color"] == "#202122"
    # Silent under darkMode=designed too: the default is a token value,
    # not a raw author colour.
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let d = styled("p", [])
    r.setTextContent(d, "Designed")
    let (_, dDiags) = applyStyles(d, defaultTheme(), designed)
    check dDiags.len == 0
    check d.styles["color"] == "#111827"

proc darkColorsOf(head: seq[HeadDecl]; node: EmailNode): seq[string] =
  ## The dark `color` values P5 split out for `node`.
  for h in head:
    if h.node == node and h.variant == "dark" and h.prop == "color":
      result.add(h.value)

suite "an uncoloured text element gets the colour it would inherit":
  test "test_uncoloured_text_copies_the_container_light_and_dark_colour":
    # The container sets its colour and background as tokens with
    # dark variants; the paragraph sets nothing. Under designed the
    # paragraph carries the container's light colour inline and the
    # container's dark colour as its own dark declaration, so in a dark
    # client it is light on the container's dark background, as it was
    # when it inherited.
    let r = EmailRenderer()
    let p = styled("p", [])
    r.setTextContent(p, "Inherits")
    let box = styled("div", [("color", "tok:color.text.secondary"),
      ("@dark:color", "tok:color.text.secondary"),
      ("background-color", "tok:color.surface.card"),
      ("@dark:background-color", "tok:color.surface.card")], p)
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let (head, diags) = applyStyles(box, defaultTheme(), designed)
    check diags.len == 0
    check box.styles["color"] == "#4b5563"
    check p.styles["color"] == "#4b5563"
    check darkColorsOf(head, box) == @["#c3c8d0"]
    check darkColorsOf(head, p) == @["#c3c8d0"]
    # P6 turns the paragraph's pairing into its own dark class and rule.
    let res = assembleHead(head, designed)
    let cls = p.attrs.getOrDefault("class", "")
    check cls.startsWith("e-")
    var css = ""
    for b in res.blocks:
      css.add(b.text)
    check ("." & cls & "{color:#c3c8d0 !important}") in css

  test "test_uncoloured_text_without_a_coloured_ancestor_is_dark_paired":
    let r = EmailRenderer()
    let p = styled("p", [])
    r.setTextContent(p, "Default")
    let tree = styled("div", [], p)
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let (head, diags) = applyStyles(tree, defaultTheme(), designed)
    check diags.len == 0
    check p.styles["color"] == "#111827"
    check darkColorsOf(head, p) == @["#f3f4f6"]
    let res = assembleHead(head, designed)
    let cls = p.attrs.getOrDefault("class", "")
    check cls.startsWith("e-")
    var css = ""
    for b in res.blocks:
      css.add(b.text)
    check ("." & cls & "{color:#f3f4f6 !important}") in css

  test "test_uncoloured_text_is_light_only_outside_designed":
    # accommodate and none write no dark CSS: the default and the
    # inherited colour are light values only, as before.
    for mode in [dmAccommodate, dmNone]:
      var target = defaultTarget()
      target.darkMode = mode
      let r = EmailRenderer()
      let bare = styled("p", [])
      r.setTextContent(bare, "Default")
      let inner = styled("p", [])
      r.setTextContent(inner, "Inherits")
      let box = styled("div", [("color", "#334155"),
        ("@dark:color", "#e2e8f0")], inner)
      let tree = styled("div", [], bare, box)
      let (head, diags) = applyStyles(tree, defaultTheme(), target)
      check diags.len == 0
      check bare.styles["color"] == "#111827"
      check inner.styles["color"] == "#334155"
      check darkColorsOf(head, bare).len == 0
      check darkColorsOf(head, inner).len == 0
      discard assembleHead(head, target)
      check "class" notin bare.attrs
      check "class" notin inner.attrs

  test "test_author_text_colour_always_wins":
    let r = EmailRenderer()
    let own = styled("p", [("color", "tok:color.link")])
    r.setTextContent(own, "Mine")
    let ownDark = styled("p", [("color", "tok:color.link"),
      ("@dark:color", "tok:color.link")])
    r.setTextContent(ownDark, "Mine, paired")
    let box = styled("div", [("color", "tok:color.text.secondary"),
      ("@dark:color", "tok:color.text.secondary")], own, ownDark)
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let (head, diags) = applyStyles(box, defaultTheme(), designed)
    check diags.len == 0
    check own.styles["color"] == "#0969da"
    # Its own token's dark value, not the box's (R-DRK-02, token-driven).
    check darkColorsOf(head, own) == @["#7aa7ff"]
    check ownDark.styles["color"] == "#0969da"
    check darkColorsOf(head, ownDark) == @["#7aa7ff"]

  test "test_nearest_coloured_ancestor_wins":
    # Grandparent sets A, parent sets B: the child gets B, light and
    # dark. A parent with no dark value of its own holds its light
    # colour in dark mode too, so the child gets no dark rule then.
    let r = EmailRenderer()
    let child = styled("p", [])
    r.setTextContent(child, "Nested")
    let parent = styled("div", [("color", "#1e3a8a"),
      ("@dark:color", "#bfdbfe")], child)
    let grand = styled("div", [("color", "#7f1d1d"),
      ("@dark:color", "#fecaca")], parent)
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let (head, _) = applyStyles(grand, defaultTheme(), designed)
    check child.styles["color"] == "#1e3a8a"
    check darkColorsOf(head, child) == @["#bfdbfe"]
    let child2 = styled("p", [])
    r.setTextContent(child2, "Nested, light-only parent")
    let parent2 = styled("div", [("color", "#1e3a8a")], child2)
    let grand2 = styled("div", [("color", "#7f1d1d"),
      ("@dark:color", "#fecaca")], parent2)
    let (head2, _) = applyStyles(grand2, defaultTheme(), designed)
    check child2.styles["color"] == "#1e3a8a"
    check darkColorsOf(head2, child2).len == 0
    # A parent with only a dark value: light from the grandparent,
    # dark from the parent.
    let child3 = styled("p", [])
    r.setTextContent(child3, "Nested, dark-only parent")
    let parent3 = styled("div", [("@dark:color", "#bfdbfe")], child3)
    let grand3 = styled("div", [("color", "#7f1d1d")], parent3)
    let (head3, _) = applyStyles(grand3, defaultTheme(), designed)
    check child3.styles["color"] == "#7f1d1d"
    check darkColorsOf(head3, child3) == @["#bfdbfe"]
