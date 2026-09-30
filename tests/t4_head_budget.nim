## P6 assembles prioritised head blocks and enforces the budget by
## dropping whole blocks lowest-priority-first with a diagnostic each.
## No rule claim: R-CSS-07 stays pending — separate-<style>
## emission is the document assembly's half.
##
## Backend-independent (tree building + pure pass), so `just test` also
## runs it on JS.
import std/[strutils, tables, unittest]
import isonim_email

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
    # Responsive: the breakpoint query plus the Thunderbird copy
    # (default on); no OWA copy (default off). Responsive rules carry
    # !important (media-query and dark rules get !important);
    # decorative :hover rules do not.
    check "only screen and (min-width: 480px)" in full.blocks[1].text
    check ".moz-text-html" in full.blocks[1].text
    check "[owa]" notin full.blocks[1].text
    check "!important" in full.blocks[1].text
    check "!IMPORTANT" notin full.blocks[1].text
    check "!important" notin full.blocks[4].text
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
    check "min-width: 600px" in owa.blocks[1].text
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

    # At zero budget reset, responsive and mso still survive: the pass
    # never drops them, it just reports the three droppable blocks.
    target.headStyleBudget = 0
    let f4 = freshDecls()
    let s4 = assembleHead(f4.decls, target, webfonts(), msoRules())
    check s4.diagnostics.len == 3
    check priorities(s4.blocks) == @[1, 2, 0]
    check "html,body{margin:0 auto !important;" in s4.blocks[0].text
    check "e-" in f4.sm.attrs["class"]
