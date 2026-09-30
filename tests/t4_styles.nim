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
    let p = styled("p", [("color", "#111827"), ("@sm:padding", "8"),
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
    let q = styled("p", [("@sm:display", "flex")])
    let (qHead, qDiags) = applyStyles(q, defaultTheme(), defaultTarget())
    check qDiags.len == 0
    check q.styles.len == 0
    check qHead.len == 1
    check (qHead[0].variant, qHead[0].prop, qHead[0].value) ==
      ("sm", "display", "flex")

suite "margins convert to cell padding":
  test "test_margins_convert_to_cell_padding":
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

suite "harmful display is removed with an error":
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
    # Grid, and non-containers too: P5 removes everywhere (lint only
    # warns off-container, but the removal itself always errors).
    let grid = renderAuthoringTree(gridParaTpl, 0)
    let (_, gridDiags) = applyStyles(grid, defaultTheme(), defaultTarget())
    check "display" notin findTag(grid, "p").styles
    check gridDiags.len == 1
    check gridDiags[0].severity == sevError
    check gridDiags[0].code == codeCssHarmful
    check "display:grid" in gridDiags[0].message

suite "custom properties never reach output":
  test "test_no_var_anywhere":
    # rule: R-CSS-11
    let p = styled("p", [("color", "var(--ink)"), ("--ink", "#111827"),
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
    let q = styled("p", [("@sm:color", "var(--x)")])
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

suite "translucent colours inline as the blend":
  test "test_translucent_colours_inline_as_blend":
    # The catalogue's example value: rgba(0,0,0,.5) over the default
    # white truncates to #7f7f7f (inline carries the blend alone — the
    # style table holds one declaration per property).
    let p = styled("p", [("color", "rgba(0,0,0,.5)")])
    let (_, diags) = applyStyles(p, defaultTheme(), defaultTarget())
    check diags.len == 0
    check p.styles["color"] == "#7f7f7f"
    # Against an ancestor background the blend follows it.
    let card = styled("div", [("background-color", "#1f6feb")],
      styled("p", [("color", "rgba(0,0,0,.5)")]))
    discard applyStyles(card, defaultTheme(), defaultTarget())
    check card.children[0].styles["color"] == "#0f3775"
