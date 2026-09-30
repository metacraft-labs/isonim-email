## P6 assembles prioritised head blocks and enforces the budget by
## dropping whole blocks lowest-priority-first with a diagnostic each,
## then warning with `W-CSS-OVER-BUDGET` when the never-dropped blocks
## alone still exceed it (raised under `strict`).
## No rule claim here: R-CSS-07 is claimed by
## tests/t5_document_golden.nim (separate-<style> emission); this file
## covers the dropping and over-budget half.
##
## Also pinned here: `sm:` rules sit under the mobile query
## (`max-width:{breakpoint-1}px`); every variant rule, `:hover`
## included, carries `!important` (R-CSS-03, R-INT-02); class names
## hash the variant, so equal declarations under two variants never
## share a class; the dark block's Outlook copies split by property
## (R-DRK-03: `[data-ogsc]` carries `color` only, `[data-ogsb]`
## `background-color` only); and `darkMode = dmNone` emits no dark
## rules at all.
##
## Backend-independent (tree building + pure pass), so `just test` also
## runs it on JS.
import std/[algorithm, strutils, tables, unittest]
import isonim_email

proc cleanTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Budget"):
      mailSection:
        mailColumn:
          h1: text "Budget"
          p: text "static"

proc hd(node: EmailNode; variant, prop, value: string): HeadDecl =
  HeadDecl(variant: variant, prop: prop, value: value, node: node,
    origin: SourceSpan())

proc priorities(blocks: seq[EmailNode]): seq[int] =
  for b in blocks:
    result.add(b.priority)

proc codes(diags: seq[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc freshDecls(): tuple[decls: seq[HeadDecl]; sm, dark, hover: EmailNode] =
  ## Fresh nodes per stage: class attachment mutates, so stages must not
  ## share elements (a dropped block attaches nothing — only fresh nodes
  ## prove that).
  let r = EmailRenderer()
  let sm = r.createElement("div")
  let dark = r.createElement("p")
  let hover = r.createElement("a")
  (decls: @[
    hd(sm, "sm", "width", "100%"),
    hd(dark, "dark", "color", "#e5e7eb"),
    hd(dark, "dark", "background-color", "#111827"),
    hd(hover, "hover", "text-decoration", "underline"),
  ], sm: sm, dark: dark, hover: hover)

proc webfonts(): seq[seq[Declaration]] =
  @[@[Declaration(prop: "font-family", value: "Custom"),
    Declaration(prop: "src", value: "url(a.woff2)")]]

proc msoRules(): seq[Rule] =
  @[Rule(kind: rkStyle, selector: "table",
    decls: @[Declaration(prop: "border-collapse", value: "collapse")])]

suite "head budget drops lowest priority first":
  test "test_head_budget_drops_lowest_priority_first":
    # Full assembly: everything survives, in priority order, silent.
    var target = defaultTarget()
    target.headStyleBudget = 1_000_000
    let f = freshDecls()
    let full = assembleHead(f.decls, target, webfonts(), msoRules())
    check full.diagnostics.len == 0
    check full.blocks.len == 6
    check priorities(full.blocks) == @[1, 2, 3, 4, 5, 0]
    # Reset carries the catalogue §2 exact 13 lines in order (the
    # document assembly replaced the scaffolding; `u+.body` is gone —
    # no rule admits it). Pin the first line whole plus the group
    # selectors, the
    # uppercase literals and the unowned `a` line.
    check "html,body{margin:0 auto !important;padding:0 !important;" &
      "height:100% !important;width:100% !important;}" in
      full.blocks[0].text
    check "u+.body" notin full.blocks[0].text
    check ".aBn" in full.blocks[0].text
    check ".a6S" in full.blocks[0].text
    check "#MessageViewBody,#MessageWebViewDiv{width:100% !important;}" in
      full.blocks[0].text
    check "a{text-decoration:none;}" in full.blocks[0].text
    # Responsive: the mobile query (sm: is below the breakpoint) plus
    # the Thunderbird copy (default on); no OWA copy (default off).
    # Every variant rule carries !important — responsive, dark and
    # decorative :hover alike (R-CSS-03, R-INT-02).
    check full.blocks[1].text.startsWith(
      "@media only screen and (max-width: 479px){")
    check "min-width" notin full.blocks[1].text
    check ".moz-text-html" in full.blocks[1].text
    check "[owa]" notin full.blocks[1].text
    check "!important" in full.blocks[1].text
    check "!IMPORTANT" notin full.blocks[1].text
    check full.blocks[4].text.endsWith(
      ":hover{text-decoration:underline !important}")
    # Dark: the media query AND both client copies, all !important.
    check "(prefers-color-scheme: dark)" in full.blocks[2].text
    check "[data-ogsc]" in full.blocks[2].text
    check "[data-ogsb]" in full.blocks[2].text
    check "!important" in full.blocks[2].text
    check "!IMPORTANT" notin full.blocks[2].text
    # Fonts top-level, never in @media; decorative as :hover rules.
    check "@font-face" in full.blocks[3].text
    check "@media" notin full.blocks[3].text
    check ":hover" in full.blocks[4].text
    check "border-collapse:collapse" in full.blocks[5].text
    # Surviving blocks pair every rule with a class on the element.
    check "e-" in f.sm.attrs["class"]
    check "e-" in f.dark.attrs["class"]
    check "e-" in f.hover.attrs["class"]
    # The OWA copy and the breakpoint follow their flags.
    var owaTarget = defaultTarget()
    owaTarget.headStyleBudget = 1_000_000
    owaTarget.owaDesktop = true
    owaTarget.breakpoint = 600
    owaTarget.thunderbirdMq = false
    let o = freshDecls()
    let owa = assembleHead(o.decls, owaTarget)
    check owa.blocks[1].text.startsWith(
      "@media only screen and (max-width: 599px){")
    check "[owa]" in owa.blocks[1].text
    check ".moz-text-html" notin owa.blocks[1].text

    # Staged budgets from the measured sizes: each stage drops exactly
    # one more block (mso is never budgeted, so it is excluded).
    var sizes: seq[int] = @[]
    for b in full.blocks[0 .. 4]:
      sizes.add(b.text.len)
    let total = sizes[0] + sizes[1] + sizes[2] + sizes[3] + sizes[4]

    target.headStyleBudget = total - 1
    let f1 = freshDecls()
    let s1 = assembleHead(f1.decls, target, webfonts(), msoRules())
    check s1.diagnostics.len == 1
    check codes(s1.diagnostics) == @[codeCssBlockDropped]
    check s1.diagnostics[0].severity == sevWarning
    check s1.diagnostics[0].rules == @["R-CSS-07"]
    check "decorative" in s1.diagnostics[0].message
    check priorities(s1.blocks) == @[1, 2, 3, 4, 0]
    check "class" notin f1.hover.attrs
    check "e-" in f1.sm.attrs["class"]

    target.headStyleBudget = total - sizes[4] - 1
    let f2 = freshDecls()
    let s2 = assembleHead(f2.decls, target, webfonts(), msoRules())
    check s2.diagnostics.len == 2
    check codes(s2.diagnostics) ==
      @[codeCssBlockDropped, codeCssBlockDropped]
    check "decorative" in s2.diagnostics[0].message
    check "fonts" in s2.diagnostics[1].message
    check priorities(s2.blocks) == @[1, 2, 3, 0]

    target.headStyleBudget = total - sizes[4] - sizes[3] - 1
    let f3 = freshDecls()
    let s3 = assembleHead(f3.decls, target, webfonts(), msoRules())
    check s3.diagnostics.len == 3
    check "dark" in s3.diagnostics[2].message
    check priorities(s3.blocks) == @[1, 2, 0]
    check "class" notin f3.dark.attrs

    # Down to reset + responsive nothing more is reported: those two
    # fit exactly, so no over-budget warning.
    for d in s3.diagnostics:
      check d.code != codeCssOverBudget

    # At zero budget reset, responsive and mso still survive: the pass
    # never drops them. It reports the three droppable blocks, then
    # warns that the survivors alone are over budget.
    target.headStyleBudget = 0
    let f4 = freshDecls()
    let s4 = assembleHead(f4.decls, target, webfonts(), msoRules())
    check s4.diagnostics.len == 4
    check codes(s4.diagnostics) == @[codeCssBlockDropped,
      codeCssBlockDropped, codeCssBlockDropped, codeCssOverBudget]
    check priorities(s4.blocks) == @[1, 2, 0]
    check "html,body{margin:0 auto !important;" in s4.blocks[0].text
    check "e-" in f4.sm.attrs["class"]

proc blockWith(blocks: seq[EmailNode]; priority: int): string =
  for b in blocks:
    if b.priority == priority:
      return b.text
  ""

suite "over-budget warning when protected blocks exceed the budget":
  test "test_head_over_budget_warns":
    var target = defaultTarget()
    target.headStyleBudget = 1_000_000
    let probe = assembleHead(freshDecls().decls, target)
    let protectedBytes = blockWith(probe.blocks, 1).len +
      blockWith(probe.blocks, 2).len
    check protectedBytes > 0
    # Exactly at the budget: dark and decorative drop, nothing more.
    target.headStyleBudget = protectedBytes
    let fits = assembleHead(freshDecls().decls, target)
    check codes(fits.diagnostics) ==
      @[codeCssBlockDropped, codeCssBlockDropped]
    # One byte less: the survivors are over budget and say so, once,
    # as a Gmail-truncation warning citing R-CSS-07.
    target.headStyleBudget = protectedBytes - 1
    let over = assembleHead(freshDecls().decls, target)
    check codes(over.diagnostics) ==
      @[codeCssBlockDropped, codeCssBlockDropped, codeCssOverBudget]
    let w = over.diagnostics[^1]
    check w.code == "W-CSS-OVER-BUDGET"
    check w.severity == sevWarning
    check w.rules == @["R-CSS-07"]
    check $protectedBytes in w.message
    check cfGmailWeb in w.families
    check priorities(over.blocks) == @[1, 2]
    # Through the render: a warning normally, an error under strict.
    var tiny = defaultTarget()
    tiny.headStyleBudget = 100
    let loose = renderEmail(cleanTpl, 0, target = tiny)
    check codes(loose.diagnostics) == @[codeCssOverBudget]
    check not hasErrors(loose.diagnostics)
    var msg = ""
    try:
      discard renderEmail(cleanTpl, 0, target = tiny, strict = true)
    except EmailRenderError as e:
      msg = e.msg
    check msg.startsWith(codeCssOverBudget & ":")
    # Within budget, strict renders the same template cleanly.
    check renderEmail(cleanTpl, 0, strict = true).diagnostics.len == 0

suite "variant rules":
  test "test_sm_rules_target_mobile":
    # `sm:` is the mobile variant: its rules apply below the breakpoint,
    # so an inline 16px padding stays on desktop and an sm: 8px padding
    # applies only on phones.
    let r = EmailRenderer()
    let cell = r.createElement("td")
    var target = defaultTarget()
    target.thunderbirdMq = false
    let res = assembleHead(@[hd(cell, "sm", "padding", "8px")], target)
    let cls = cell.attrs["class"]
    check blockWith(res.blocks, 2) ==
      "@media only screen and (max-width: 479px){." & cls &
      "{padding:8px !important}}"
    target.breakpoint = 600
    let cell2 = r.createElement("td")
    let res2 = assembleHead(@[hd(cell2, "sm", "padding", "8px")], target)
    check blockWith(res2.blocks, 2).startsWith(
      "@media only screen and (max-width: 599px){")

  test "test_variant_classes_do_not_leak":
    # The same declaration under sm:, dark: and hover: on three
    # elements: three classes, each element carries only its own, and
    # no block names another variant's class.
    let r = EmailRenderer()
    let a = r.createElement("td")
    let b = r.createElement("td")
    let c = r.createElement("td")
    var target = defaultTarget()
    target.headStyleBudget = 1_000_000
    target.darkMode = dmDesigned
    let res = assembleHead(@[
      hd(a, "sm", "background-color", "#ffffff"),
      hd(b, "dark", "background-color", "#ffffff"),
      hd(c, "hover", "background-color", "#ffffff")], target)
    let (ca, cb, cc) = (a.attrs["class"], b.attrs["class"],
      c.attrs["class"])
    check ca.startsWith("e-")
    check cb.startsWith("e-")
    check cc.startsWith("e-")
    check ca != cb
    check ca != cc
    check cb != cc
    let resp = blockWith(res.blocks, 2)
    let dark = blockWith(res.blocks, 3)
    let hover = blockWith(res.blocks, 5)
    check ("." & ca & "{") in resp
    check ("." & cb) notin resp
    check ("." & cc) notin resp
    check ("." & cb & "{") in dark
    check ("." & ca) notin dark
    check ("." & cc) notin dark
    check ("." & cc & ":hover{") in hover
    check ("." & ca) notin hover
    check ("." & cb) notin hover

  test "test_hover_rules_are_important":
    # R-INT-02 (not claimed here): hover rules must beat inline values.
    let r = EmailRenderer()
    let link = r.createElement("a")
    let res = assembleHead(@[hd(link, "hover", "color", "#0000ff"),
      hd(link, "hover", "text-decoration", "underline")], defaultTarget())
    check blockWith(res.blocks, 5) == "." & link.attrs["class"] &
      ":hover{color:#0000ff !important;text-decoration:underline !important}"

  test "test_dark_copies_split_by_property":
    # R-DRK-03: [data-ogsc] recolours text, [data-ogsb] backgrounds;
    # each copy carries only its own property. The media query carries
    # every dark declaration.
    let r = EmailRenderer()
    let both = r.createElement("td")
    let border = r.createElement("td")
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    let res = assembleHead(@[
      hd(both, "dark", "color", "#e5e7eb"),
      hd(both, "dark", "background-color", "#111827"),
      hd(both, "dark", "border-color", "#374151"),
      hd(border, "dark", "border-color", "#374151")], designed)
    let cls = both.attrs["class"]
    let other = border.attrs["class"]
    # The media query's inner rules sort by selector (R-CSS-16).
    var inner = @["." & cls & "{background-color:#111827 !important;" &
      "border-color:#374151 !important;color:#e5e7eb !important}",
      "." & other & "{border-color:#374151 !important}"]
    inner.sort()
    check blockWith(res.blocks, 3) ==
      "[data-ogsb] ." & cls & "{background-color:#111827 !important}" &
      "[data-ogsc] ." & cls & "{color:#e5e7eb !important}" &
      "@media (prefers-color-scheme: dark){" & inner.join("") & "}"
    # A group with neither colour property gets no Outlook copy.
    check ("[data-ogsc] ." & other) notin blockWith(res.blocks, 3)
    check ("[data-ogsb] ." & other) notin blockWith(res.blocks, 3)

  test "test_dark_none_emits_no_dark_rules":
    var target = defaultTarget()
    target.darkMode = dmNone
    target.headStyleBudget = 1_000_000
    let f = freshDecls()
    let res = assembleHead(f.decls, target, webfonts(), msoRules())
    check res.diagnostics.len == 0
    check priorities(res.blocks) == @[1, 2, 4, 5, 0]
    for b in res.blocks:
      check "prefers-color-scheme" notin b.text
      check "data-ogs" notin b.text
    check "class" notin f.dark.attrs
    check "e-" in f.sm.attrs["class"]
    # The same declarations under the designed strategy do emit them.
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    designed.headStyleBudget = 1_000_000
    let g = freshDecls()
    let res2 = assembleHead(g.decls, designed, webfonts(), msoRules())
    check priorities(res2.blocks) == @[1, 2, 3, 4, 5, 0]
    check "e-" in g.dark.attrs["class"]
