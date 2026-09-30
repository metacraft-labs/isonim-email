# rule: R-CSS-03
# rule: R-CSS-04
# rule: R-CSS-05
# rule: R-CSS-09
# rule: R-CSS-16
## Head CSS through the validating serialiser is Gmail-safe —
## lower-case, no nested at-rules, known properties only, class/element/ID
## selectors apart from the fixed client-targeting set, deterministically
## sorted. A block that fails validation is `E-CSS-INVALID`.
##
## Falsifying mutation (performed 2026-09-27, reverted afterwards):
## replacing the at-rule-nesting rejection in `serializeMediaRule` with
## a style-only filter makes `test_head_css_rejects_nested_at_rules`
## fail on the `@font-face`-inside-`@media` case, as
## required; the other four tests stay green.
##
## Backend-independent (pure string work), so `just test` also runs it
## on JS.
import std/[strutils, unittest]
import isonim_email

proc decl(prop, value: string; important = false): Declaration =
  Declaration(prop: prop, value: value, important: important)

suite "head CSS is Gmail-safe":
  test "test_head_css_is_gmail_safe":
    # rule: R-CSS-03
    # rule: R-CSS-04
    # rule: R-CSS-05
    # rule: R-CSS-09
    # rule: R-CSS-16
    var gen = initClassGen()
    let cls = gen.classFor(
      [decl("color", "#ffffff"), decl("background-color", "#1f6feb")])
    let blockText = serializeBlock([
      Rule(kind: rkMedia, query: "only screen and (max-width:480px)",
        rules: @[
          Rule(kind: rkStyle, selector: ".z-last",
            decls: @[decl("display", "block", true)]),
          Rule(kind: rkStyle, selector: "." & cls,
            decls: @[decl("width", "100%", true)]),
      ]),
      Rule(kind: rkStyle, selector: "p",
        decls: @[decl("margin", "0"), decl("color", "#111827")]),
      Rule(kind: rkStyle, selector: "#preheader",
        decls: @[decl("display", "none")]),
      Rule(kind: rkFontFace, faceDecls: @[
        decl("font-family", "Custom"), decl("src", "url(a.woff2)")]),
    ])
    # Rules sort by selector, declarations by property (R-CSS-16);
    # style rules come before @media, @font-face last.
    check blockText ==
      "#preheader{display:none}" &
      "p{color:#111827;margin:0}" &
      "@media only screen and (max-width:480px){" &
      "." & cls & "{width:100% !important}" &
      ".z-last{display:block !important}}" &
      "@font-face{font-family:Custom;src:url(a.woff2)}"
    # `!important` lower-case (R-CSS-03); uppercase never appears.
    check " !important" in blockText
    check "!IMPORTANT" notin blockText
    # Balanced braces, no empty declarations (R-CSS-05).
    check blockText.count('{') == blockText.count('}')
    check "{}" notin blockText
    check "{;" notin blockText
    check ";;" notin blockText
    check ":;" notin blockText
    check ":}" notin blockText

  test "test_head_css_rejects_nested_at_rules":
    # rule: R-CSS-04
    let fontInMedia = Rule(kind: rkMedia, query: "screen",
      rules: @[Rule(kind: rkFontFace,
        faceDecls: @[decl("font-family", "x")])])
    try:
      discard serializeBlock([fontInMedia])
      fail()
    except StyleError as e:
      check "E-CSS-INVALID" in e.msg
      check "R-CSS-04" in e.msg
    let mediaInMedia = Rule(kind: rkMedia, query: "screen",
      rules: @[Rule(kind: rkMedia, query: "screen",
        rules: @[Rule(kind: rkStyle, selector: "p",
          decls: @[decl("margin", "0")])])])
    expect StyleError:
      discard serializeBlock([mediaInMedia])
    # Top-level @font-face is the valid shape.
    check serializeBlock([Rule(kind: rkFontFace,
      faceDecls: @[decl("font-family", "x")])]) ==
      "@font-face{font-family:x}"

  test "test_head_css_rejects_invalid_rules":
    # rule: R-CSS-05
    # Unknown properties fail, naming the table.
    try:
      discard serializeDecls([decl("colr", "#fff")])
      fail()
    except StyleError as e:
      check "E-CSS-INVALID" in e.msg
      check "known-property table" in e.msg
    # Empty declarations fail.
    expect StyleError:
      discard serializeDecls([decl("color", "  ")])
    expect StyleError:
      discard serializeStyleRule("p", @[])
    expect StyleError:
      discard serializeFontFaceRule(@[])
    expect StyleError:
      discard serializeMediaRule("screen", @[])
    # Brace/semicolon-bearing values would break the block.
    for bad in ["a{b", "a}b", "a;b"]:
      expect StyleError:
        discard serializeDecls([decl("color", bad)])
    # A raw `!` marker fails: importance comes only from the flag,
    # which is what keeps `!important` lower-case (R-CSS-03).
    try:
      discard serializeDecls([decl("color", "#fff !IMPORTANT")])
      fail()
    except StyleError as e:
      check "R-CSS-03" in e.msg
    expect StyleError:
      discard serializeDecls([decl("color", "#fff!important")])
    # The flag itself always renders lower-case.
    check serializeDecls([decl("color", "#fff", true)]) ==
      "color:#fff !important"
    # Empty and brace-bearing queries fail (R-CSS-05 shape); the
    # R-CSS-10 vocabulary (screen-only, width/dark features) is
    # enforced on the same path — see tests/t5_media_queries.nim.
    expect StyleError:
      discard serializeMediaRule("  ", @[Rule(kind: rkStyle,
        selector: "p", decls: @[decl("margin", "0")])])
    expect StyleError:
      discard serializeMediaRule("screen{", @[Rule(kind: rkStyle,
        selector: "p", decls: @[decl("margin", "0")])])
    # Property names canonicalise to lowercase.
    check serializeDecls([decl("Margin", "0")]) == "margin:0"

  test "test_head_css_selectors_restricted":
    # rule: R-CSS-09
    for good in [".e-3kq", ".im", "p", "table", "h1", "#preheader",
        "p,td", ".a,.b", "*",
        "div[style*=\"margin: 16px 0\"]", "#outlook a",
        "a[x-apple-data-detectors]", ".unstyle-auto-detected-links a",
        ".aBn", ".a6S",
        "a[x-apple-data-detectors],.unstyle-auto-detected-links a,.aBn",
        "img.g-img+div", "[data-ogsc] .e-dk-abc",
        "[data-ogsb] .e-dk-abc", ".moz-text-html .e-x1",
        ".moz-text-html p"]:
      check validSelector(good)
      check validSelector("  " & good & "  ")
    for bad in ["", "div p", "div>p", "div+p", "div~p", ".a:hover",
        ".a:b", "[foo]", "a[x]", ".A", ".9lives", "#9", "9lives",
        ".e-ok, div p", "[data-ogsc] div", ".moz-text-html [x]",
        "u + .body"]:
      check not validSelector(bad)
      expect StyleError:
        discard serializeStyleRule(bad, @[decl("margin", "0")])
    # `u + .body` stays rejected, finally: the u-hack targets Gmail,
    # not Yahoo, catalogue §2 carries no such line, and no rule admits
    # the spelling (the gap issue was closed as dropped and the stale
    # mentions removed).
    # (Exactly `.aBn` and `.a6S` are admitted above under R-RST-09/11;
    # the `.A` pin in the bad list proves the extension is those two
    # literals, not uppercase classes in general.)
    try:
      discard serializeStyleRule("div p", @[decl("margin", "0")])
      fail()
    except StyleError as e:
      check "R-CSS-09" in e.msg

  test "test_declaration_sort_is_stable":
    # rule: R-CSS-16
    # R-CSS-14's blend-then-rgba pairs share one property name;
    # P5 passes them blend-first and the sort keeps that order.
    let pair = emitColorDecls("color", "rgba(0,0,0,.5)", "#ffffff")
    check serializeDecls(
      [decl(pair[0].prop, pair[0].value), decl("margin", "0"),
        decl(pair[1].prop, pair[1].value)]) ==
      "color:#7f7f7f;color:rgba(0,0,0,.5);margin:0"

  test "test_head_css_rejects_breakout_text":
    # rule: R-CSS-05
    # Nothing may close the <style> element early, open or close a
    # comment, escape, or leave a quote or parenthesis unbalanced — in a
    # value, a selector or a query. Each rejection names the breakout
    # check (not a later selector or vocabulary check), so the reason is
    # pinned, not just the failure.
    proc rejectsBreakout(body: proc ()) =
      try:
        body()
        fail()
      except StyleError as e:
        check "E-CSS-INVALID" in e.msg
        check "R-CSS-05: nothing may break out of the block" in e.msg
    let badValues = [
      "red</style><script>x</script>", # element break-out
      "<b", "#fff/*", "#fff*/", "/* x */ #fff", # comments
      "\\66 oo", "Arial\\", # escapes
      "'Courier New", "\"Courier New", "'a\"", # unbalanced quotes
      "url(a.woff2", "url(a.woff2))", "a)", # unbalanced parens
    ]
    for v in badValues:
      rejectsBreakout(proc () = discard serializeDecls([decl("font-family", v)]))
      rejectsBreakout(proc () = checkDeclaration(decl("font-family", v)))
    # The same text in a @font-face body fails the same way.
    rejectsBreakout(proc () =
      discard serializeFontFaceRule([decl("src", "url(a.woff2")]))
    # Selectors: checked before the class/element/ID vocabulary.
    for sel in [".a</style>", "p/*", "p*/", ".a\\:b",
        "div[style*=\"margin: 16px 0]", "div[style*='x]"]:
      rejectsBreakout(proc () =
        discard serializeStyleRule(sel, @[decl("margin", "0")]))
    # Queries: a feature value cannot smuggle text out either.
    for q in ["only screen and (max-width: 479px</style>)",
        "only screen and (max-width: 479px/**/)",
        "only screen and (max-width: \\34 79px)"]:
      rejectsBreakout(proc () = checkQuery(q))
      rejectsBreakout(proc () = discard serializeMediaRule(q,
        @[Rule(kind: rkStyle, selector: "p",
          decls: @[decl("margin", "0")])]))
    # Balanced quotes and parentheses pass, including parentheses
    # inside a quoted string.
    check serializeDecls([decl("font-family",
      "Menlo, Consolas, 'Courier New', monospace")]) ==
      "font-family:Menlo, Consolas, 'Courier New', monospace"
    check serializeDecls([decl("src", "url(\"a(1).woff2\")")]) ==
      "src:url(\"a(1).woff2\")"
    check serializeDecls([decl("font-family", "\"a)b\"")]) ==
      "font-family:\"a)b\""
    check serializeStyleRule("div[style*=\"margin: 16px 0\"]",
      @[decl("margin", "0")]) == "div[style*=\"margin: 16px 0\"]{margin:0}"

  test "test_shorthand_sorts_before_longhands":
    # rule: R-CSS-16
    # A shorthand always precedes its own longhands, so a longhand that
    # refines the shorthand keeps winning after the sort. Plain name
    # order would put `border-bottom-color` before `border-color` and
    # let the shorthand repaint the bottom edge.
    check serializeDecls([decl("border-bottom-color", "#ff0000"),
      decl("border-color", "#0000ff")]) ==
      "border-color:#0000ff;border-bottom-color:#ff0000"
    check serializeDecls([decl("border-top-left-radius", "0"),
      decl("border-radius", "4px")]) ==
      "border-radius:4px;border-top-left-radius:0"
    # Input order never matters: a longhand given first still follows.
    check serializeDecls([decl("margin-top", "8px"), decl("margin", "0")]) ==
      "margin:0;margin-top:8px"
    check serializeDecls([decl("padding-left", "4px"),
      decl("padding", "8px")]) == "padding:8px;padding-left:4px"
    check serializeDecls([decl("list-style-type", "disc"),
      decl("list-style", "none")]) == "list-style:none;list-style-type:disc"
    # A whole border family: depth first (border, the side and aspect
    # shorthands, then the per-side longhands), then name.
    check serializeDecls([decl("border-top-color", "#111111"),
      decl("border-width", "1px"), decl("border-top", "2px solid #222222"),
      decl("border", "0"), decl("border-color", "#333333")]) ==
      "border:0;border-color:#333333;border-top:2px solid #222222;" &
      "border-width:1px;border-top-color:#111111"
    # Properties outside a shorthand family still sort by name, and the
    # families interleave with them by name.
    check serializeDecls([decl("width", "1px"), decl("color", "#000000"),
      decl("border-color", "#ffffff"), decl("display", "block")]) ==
      "border-color:#ffffff;color:#000000;display:block;width:1px"
    check declSortKey("border").level == 0
    check declSortKey("border-top").level == 1
    check declSortKey("border-top-color").level == 2
    check declSortKey("color").family == "color"
    check declSortKey("color").level == 0
