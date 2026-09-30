## `border-radius` on a button with the Word fallback declared yields
## info; with no declared fallback it yields a warning under business.
## Plus the lint engine's mapping tables (each pinned to a slug present in
## the snapshot), selector/at-rule scanning, head-CSS checks, diagnostics
## and the client model.
##
## Backend-independent (tree building + pure lint), so `just test` also
## runs it on JS.
import std/[sequtils, strutils, unittest]
import isonim_email

proc buttonTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Button"):
      mailSection:
        mailColumn:
          mailButton(href = "https://app.example.com/",
              border_radius = "6px"):
            text "Open dashboard"

proc handBuilt(tag: string; styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []): EmailNode =
  let r = EmailRenderer()
  let node = r.createElement(tag)
  node.origin = SourceSpan(file: "degrade.nim", line: 11, col: 5)
  for (k, v) in styles:
    r.setStyle(node, k, v)
  for (k, v) in attrs:
    r.setAttribute(node, k, v)
  node

suite "lint expected degradation is info":
  test "test_lint_expected_degradation_is_info":
    let tree = renderAuthoringTree(buttonTpl, 0)
    # Declared: info, not warning.
    let infos = lintTree(tree, business, [
      expectDegradation(lkProperty, "border-radius", {cfOutlookWord},
        "square corners in Word"),
    ])
    check infos.len == 1
    check infos[0].severity == sevInfo
    check infos[0].code == "I-SUPPORT-DEGRADATION"
    check infos[0].code == codeSupportDegradation
    check infos[0].families == {cfOutlookWord}
    check infos[0].weight == 0.25
    check infos[0].rules.len == 0
    check "border-radius" in infos[0].message
    check "as declared" in infos[0].message
    check "square corners in Word" in infos[0].message
    check not hasErrors(infos)
    # The declaration matches case-insensitively.
    let infos2 = lintTree(tree, business,
      [expectDegradation(lkProperty, "Border-Radius", {cfOutlookWord})])
    check infos2.len == 1
    check infos2[0].severity == sevInfo

  test "undeclared border-radius warns under business (negative control)":
    let tree = renderAuthoringTree(buttonTpl, 0)
    let diags = lintTree(tree, business)
    check diags.len == 1
    check diags[0].severity == sevWarning
    check diags[0].code == "W-SUPPORT-UNSUPPORTED"
    check diags[0].code == codeSupportUnsupported
    # Only Word fully lacks it (Yahoo's partial is exotic syntax only).
    check diags[0].families == {cfOutlookWord}
    check diags[0].weight == 0.25
    check "border-radius" in diags[0].message
    check "outlookWord" in diags[0].message
    check "25%" in diags[0].message
    check "business" in diags[0].message
    check "declare the fallback" in diags[0].message
    check not hasErrors(diags)

  test "severity follows profile weights":
    let tree = renderAuthoringTree(buttonTpl, 0)
    # consumer: outlookWord 0.02 < 5% — accepted loss, silent.
    check lintTree(tree, consumer).len == 0
    # developer: outlookWord 0.05 — exactly at threshold, warns.
    let devDiags = lintTree(tree, developer)
    check devDiags.len == 1
    check devDiags[0].severity == sevWarning
    check devDiags[0].weight == 0.05
    check "5%" in devDiags[0].message

  test "a declaration for the wrong scope does not downgrade":
    let tree = renderAuthoringTree(buttonTpl, 0)
    # Wrong families: Word uncovered, still warns on Word.
    let wrongFam = lintTree(tree, business,
      [expectDegradation(lkProperty, "border-radius", {cfYahoo})])
    check wrongFam.len == 1
    check wrongFam[0].severity == sevWarning
    check wrongFam[0].families == {cfOutlookWord}
    # Wrong name or kind: no match, still warns.
    let wrongName = lintTree(tree, business,
      [expectDegradation(lkProperty, "border", {cfOutlookWord})])
    check wrongName.len == 1
    check wrongName[0].severity == sevWarning
    let wrongKind = lintTree(tree, business,
      [expectDegradation(lkValue, "border-radius", {cfOutlookWord})])
    check wrongKind.len == 1
    check wrongKind[0].severity == sevWarning

  test "position warns broadly; clean properties stay silent":
    let pos = handBuilt("tdiv", [("position", "relative")])
    let diags = lintTree(pos, consumer)
    check diags.len == 1
    check diags[0].severity == sevWarning
    check diags[0].families ==
      {cfGmailWeb, cfGmailApp, cfGanga, cfOutlookWord, cfOutlookApp}
    check abs(diags[0].weight - 0.304) < 1e-9
    check "position" in diags[0].message
    for prop in ["margin", "padding", "background-color", "width",
        "text-align", "font-size"]:
      check lintTree(handBuilt("tdiv", [(prop, "1px")]), consumer).len == 0
      check lintTree(handBuilt("tdiv", [(prop, "1px")]), business).len == 0

  test "elements and attributes check through the tree":
    let video = lintTree(handBuilt("video"), consumer)
    check video.len == 1
    check video[0].severity == sevWarning
    check video[0].code == "W-SUPPORT-UNSUPPORTED"
    check video[0].families ==
      {cfGmailWeb, cfGmailApp, cfGanga, cfOutlookWord, cfOutlookWeb,
        cfOutlookApp, cfYahoo, cfProton, cfFastmail, cfHey}
    check "<video>" in video[0].message
    # Best-practice attributes read clean and stay silent.
    let cell = handBuilt("td", [], [("align", "center"),
      ("valign", "top"), ("cellspacing", "0"), ("cellpadding", "0")])
    check lintTree(cell, business).len == 0
    check lintTree(handBuilt("p"), consumer).len == 0
    check lintTree(nil, consumer).len == 0

  test "variant declarations data-check under their base name":
    let diags = lintStyles("p", [("@dark:border-radius", "6px")],
      business, [], SourceSpan())
    check diags.len == 1
    check diags[0].severity == sevWarning
    check "@dark" in diags[0].message
    let infos = lintStyles("p", [("@dark:border-radius", "6px")],
      business, [expectDegradation(lkProperty, "border-radius",
        {cfOutlookWord})], SourceSpan())
    check infos.len == 1
    check infos[0].severity == sevInfo

suite "lint mappings":
  test "every seed resolves to a slug present in the snapshot":
    const propPins = [
      ("border-radius", "css-border-radius"),
      ("margin", "css-margin"), ("margin-top", "css-margin"),
      ("margin-right", "css-margin"), ("margin-bottom", "css-margin"),
      ("margin-left", "css-margin"),
      ("padding", "css-padding"), ("padding-top", "css-padding"),
      ("padding-right", "css-padding"), ("padding-bottom", "css-padding"),
      ("padding-left", "css-padding"),
      ("width", "css-width"), ("height", "css-height"),
      ("max-width", "css-max-width"), ("min-width", "css-min-width"),
      ("display", "css-display"), ("position", "css-position"),
      ("float", "css-float"), ("clear", "css-clear"),
      ("box-sizing", "css-box-sizing"),
      ("gap", "css-gap"), ("justify-content", "css-justify-content"),
      ("align-items", "css-align-items"),
      ("flex-direction", "css-flex-direction"),
      ("flex-wrap", "css-flex-wrap"),
      ("border", "css-border"),
      ("border-collapse", "css-border-collapse"),
      ("border-spacing", "css-border-spacing"),
      ("background", "css-background"),
      ("background-color", "css-background-color"),
      ("background-image", "css-background-image"),
      ("background-size", "css-background-size"),
      ("background-position", "css-background-position"),
      ("background-repeat", "css-background-repeat"),
      ("box-shadow", "css-box-shadow"),
      ("table-layout", "css-table-layout"),
      ("text-align", "css-text-align"),
      ("vertical-align", "css-vertical-align"),
      ("line-height", "css-line-height"),
      ("direction", "css-direction"),
      ("font", "css-font"), ("font-size", "css-font-size"),
      ("font-weight", "css-font-weight"),
      ("letter-spacing", "css-letter-spacing"),
      ("text-transform", "css-text-transform"),
      ("text-indent", "css-text-indent"),
      ("word-wrap", "css-word-wrap"),
      ("white-space", "css-white-space"),
      ("list-style", "css-list-style"),
      ("list-style-type", "css-list-style-type"),
      ("list-style-position", "css-list-style-position"),
    ]
    for (prop, slug) in propPins:
      check propertySlug(prop) == slug
      check featureIndex(slug) >= 0
    check propertySlug("MARGIN") == "css-margin"
    for prop in ["color", "opacity", "cursor", "z-index", "visibility",
        "overflow", "text-decoration", "font-style", "word-spacing",
        "bogus-prop"]:
      check propertySlug(prop) == ""

    check valueSlug("display", "flex") == "css-display-flex"
    check valueSlug("DISPLAY", "Flex") == "css-display-flex"
    check valueSlug("display", "inline-flex") == "css-display-flex"
    check valueSlug("display", "grid") == "css-display-grid"
    check valueSlug("display", "inline-grid") == "css-display-grid"
    check featureIndex("css-display-flex") >= 0
    check featureIndex("css-display-grid") >= 0
    for (prop, value) in [("display", "none"), ("display", "block"),
        ("color", "red"), ("display", "flexbox")]:
      check valueSlug(prop, value) == ""

    check selectorSlug(skAttribute) == "css-selector-attribute"
    check featureIndex("css-selector-attribute") >= 0
    for kind in [skClass, skId, skType, skUniversal, skDescendant, skChild,
        skAdjacentSibling, skGeneralSibling, skGrouping, skChaining]:
      check selectorSlug(kind) == ""

    for (name, slug) in [("font-face", "css-at-font-face"),
        ("import", "css-at-import"), ("supports", "css-at-supports"),
        ("keyframes", "css-at-keyframes")]:
      check atRuleSlug(name) == slug
      check featureIndex(slug) >= 0
    check atRuleSlug("MEDIA") == ""
    check atRuleSlug("charset") == ""

    for (tag, slug) in [("video", "html-video"), ("audio", "html-audio"),
        ("picture", "html-picture"), ("svg", "html-svg"),
        ("form", "html-form"), ("style", "html-style"),
        ("link", "html-link"), ("input", "html-input-text"),
        ("button", "html-button-submit"), ("img", "html-img")]:
      check elementSlug(tag) == slug
      check featureIndex(slug) >= 0
    check elementSlug("VIDEO") == "html-video"
    for tag in ["p", "div", "table", "h1", "span"]:
      check elementSlug(tag) == ""

    for (attr, slug) in [("align", "html-align"),
        ("valign", "html-valign"), ("cellspacing", "html-cellspacing"),
        ("cellpadding", "html-cellpadding")]:
      check attributeSlug(attr) == slug
      check featureIndex(slug) >= 0
    for attr in ["lang", "dir", "target", "width", "height", "background",
        "href", "alt"]:
      check attributeSlug(attr) == ""

  test "variant keys split":
    check splitVariantKey("@dark:border-radius") ==
      (variant: "dark", base: "border-radius")
    check splitVariantKey("border-radius") ==
      (variant: "", base: "border-radius")
    check splitVariantKey("@") == (variant: "", base: "@")

suite "head CSS checks":
  test "selectors classify by kind":
    check classifySelector(".e-c") == {skClass}
    check classifySelector("#i") == {skId}
    check classifySelector("div") == {skType}
    check classifySelector("*") == {skUniversal}
    check classifySelector("[type]") == {skAttribute}
    check classifySelector("a[href]") ==
      {skType, skAttribute, skChaining}
    check classifySelector(".a.b") == {skClass, skChaining}
    check classifySelector("div.a") == {skType, skClass, skChaining}
    check classifySelector("ul li") == {skType, skDescendant}
    check classifySelector("ul>li") == {skType, skChild}
    check classifySelector("h1 + p") == {skType, skAdjacentSibling}
    check classifySelector("h1~p") == {skType, skGeneralSibling}
    check classifySelector("u + .body") ==
      {skType, skClass, skAdjacentSibling}
    check classifySelector("#MessageViewBody .x") ==
      {skId, skClass, skDescendant}
    check classifySelector("a[href='x,y']") ==
      {skType, skAttribute, skChaining}
    check classifySelector(".a:hover") == {skClass}
    check classifySelector("") == {}
    check splitSelectorList("a[href='x,y'], .b") ==
      @["a[href='x,y']", ".b"]

  test "at-rules and selectors scan in source order":
    check atRulesIn("@media x{.a{}}") == @["media"]
    check atRulesIn("@FONT-FACE{f{}}") == @["font-face"]
    check atRulesIn("@media a{} @media b{}") == @["media"]
    check atRulesIn(".a{content:\"@x\"}") == newSeq[string]()
    check atRulesIn("/* @media */.a{}") == newSeq[string]()
    check atRulesIn("@-moz-document url(){.a{}}") == @["-moz-document"]
    check selectorsIn(".a{color:red}") == @[".a"]
    check selectorsIn(".a,.b{}") == @[".a", ".b", ","]
    check selectorsIn("@media x{.a{}}") == @[".a"]
    check selectorsIn("/* .x */.a{}") == @[".a"]
    check selectorsIn("a[href='x,y']{}") == @["a[href='x,y']"]
    check stripCssComments("a/*x*/b") == "ab"
    check stripCssComments("a/*x") == "a"

  test "font-face warns undeclared and infos declared":
    let diags = lintHeadCss("@font-face{font-family:x;src:url(y)}",
      consumer)
    check diags.len == 1
    check diags[0].severity == sevWarning
    check diags[0].code == "W-SUPPORT-UNSUPPORTED"
    check diags[0].families ==
      {cfGmailWeb, cfGmailApp, cfGanga, cfOutlookWeb, cfOutlookApp,
        cfYahoo, cfProton, cfFastmail}
    check "@font-face" in diags[0].message
    let affected = unsupportedFamilies("css-at-font-face")
    let infos = lintHeadCss("@font-face{font-family:x}",
      consumer, [expectDegradation(lkAtRule, "font-face", affected,
        "system font stack")])
    check infos.len == 1
    check infos[0].severity == sevInfo
    check "as declared" in infos[0].message

  test "attribute selectors warn; required targeting stays silent":
    let diags = lintHeadCss("a[href]{color:red}", consumer)
    check diags.len == 1
    check diags[0].severity == sevWarning
    check diags[0].families == {cfGmailWeb, cfOutlookWord, cfProton}
    check "attribute" in diags[0].message
    # The Gmail `u + .body` hack, resets and media queries are unmapped.
    check lintHeadCss("u + .body .e-x{width:100%}", consumer).len == 0
    check lintHeadCss("div,p{margin:0}", business).len == 0
    check lintHeadCss(
      "@media only screen and (max-width:480px){.e-c{width:100%}}",
      consumer).len == 0
    # Comments never contribute findings.
    check lintHeadCss("/* a[href]{} @font-face{} */.a{}",
      consumer).len == 0

  test "head style blocks lint through the tree":
    let r = EmailRenderer()
    let root = r.createElement("mailDocument")
    let css = newHeadStyle("a[href]{color:red}", 2)
    r.appendChild(root, css)
    let diags = lintTree(root, consumer)
    check diags.len == 1
    check diags[0].severity == sevWarning
    check "attribute" in diags[0].message

suite "diagnostics":
  test "rendering, errors and code prefixes":
    let d = EmailDiagnostic(severity: sevError,
      code: "E-A11Y-ALT-MISSING", message: "mailImage without alt",
      origin: SourceSpan(file: "a.nim", line: 1, col: 2),
      rules: @["R-IMG-04"])
    check $d ==
      "a.nim:1:2: error E-A11Y-ALT-MISSING: mailImage without alt [R-IMG-04]"
    let noRules = EmailDiagnostic(severity: sevWarning,
      code: "W-SUPPORT-UNSUPPORTED", message: "unsupported",
      origin: SourceSpan())
    check $noRules ==
      "unknown location: warning W-SUPPORT-UNSUPPORTED: unsupported"
    let info = EmailDiagnostic(severity: sevInfo,
      code: "I-SUPPORT-DEGRADATION", message: "degrades",
      origin: SourceSpan(file: "a.nim", line: 3, col: 4))
    check $info ==
      "a.nim:3:4: info I-SUPPORT-DEGRADATION: degrades"
    check hasErrors([d])
    check not hasErrors([noRules, info])
    check not hasErrors(newSeq[EmailDiagnostic]())
    check severityOfCode("E-A11Y-ALT-MISSING") == sevError
    check severityOfCode("W-SUPPORT-UNSUPPORTED") == sevWarning
    check severityOfCode("I-SUPPORT-DEGRADATION") == sevInfo
    expect ValueError:
      discard severityOfCode("X-BOGUS")

  test "raised errors convert into diagnostics and back":
    let parsed = toDiagnostic("E-VOCAB-UNKNOWN-TAG: unknown tag 'x'",
      SourceSpan(file: "t.nim", line: 9, col: 1))
    check parsed.severity == sevError
    check parsed.code == "E-VOCAB-UNKNOWN-TAG"
    check parsed.message == "unknown tag 'x'"
    check parsed.origin.line == 9
    expect ValueError:
      discard toDiagnostic("no code head here")
    # The renderer raise path feeds the same pipeline without changing it.
    let r = EmailRenderer()
    let bad = r.createElement("tdiv")
    r.setAttribute(bad, "data-hk", "3")
    var converted = false
    try:
      assertNoReactiveResidue(bad)
    except EmailRenderError as e:
      let diag = toDiagnostic(e.msg)
      check diag.severity == sevError
      check diag.code == "E-STRUCT-REACTIVE-RESIDUE"
      converted = true
    check converted
    # And diagnostics raise through the same error type.
    let diag = EmailDiagnostic(severity: sevError, code: "E-CSS-HARMFUL",
      message: "harmful", origin: SourceSpan())
    var raised = false
    try:
      raiseDiagnostic(diag)
    except EmailRenderError as e:
      check e.msg == "E-CSS-HARMFUL: harmful"
      raised = true
    check raised

suite "client model":
  test "profiles weight every family and sum to one":
    check consumer.name == "consumer"
    check business.name == "business"
    check developer.name == "developer"
    check consumer.weights[cfApple] == 0.60
    check business.weights[cfOutlookWord] == 0.25
    check developer.weights[cfGmailWeb] == 0.35
    for profile in [consumer, business, developer]:
      var total = 0.0
      for f in ClientFamily:
        check profile.weights[f] > 0.0
        total += profile.weights[f]
      check abs(total - 1.0) < 1e-9
    expect AssertionDefect:
      discard makeProfile("bad", [
        cfApple: 0.5, cfGmailWeb: 0.0, cfGmailApp: 0.0, cfGanga: 0.0,
        cfOutlookWord: 0.0, cfOutlookWeb: 0.0, cfOutlookApp: 0.0,
        cfYahoo: 0.0, cfSamsung: 0.0, cfThunderbird: 0.0, cfProton: 0.0,
        cfFastmail: 0.0, cfHey: 0.0,
      ])

  test "family ids and the default target":
    check familyId(cfApple) == "apple"
    check familyId(cfGmailWeb) == "gmailWeb"
    check familyId(cfGanga) == "ganga"
    check familyId(cfOutlookWord) == "outlookWord"
    check familyId(cfOutlookWeb) == "outlookWeb"
    check familyId(cfThunderbird) == "thunderbird"
    check familyId(cfHey) == "hey"
    var ids: seq[string] = @[]
    for f in ClientFamily:
      ids.add(familyId(f))
    check ids.len == 13
    for id in ids:
      check ids.count(id) == 1
    let t = defaultTarget()
    check t.outlookWord
    check t.thunderbirdMq
    check not t.owaDesktop
    check t.darkMode == dmAccommodate
    check t.breakpoint == 480
    check t.containerWidth == 600
    check t.sizeBudget == 90_000
    check t.headStyleBudget == 15_000
    check t.preheaderPad == "&#847;&zwnj;&nbsp;"

  test "weight helpers":
    check profileWeight(business, {cfOutlookWord}) == 0.25
    check profileWeight(consumer, {}) == 0.0
    check formatPercent(0.25) == "25"
    check formatPercent(0.002) == "0.2"
    check formatPercent(0.304) == "30.4"
    check formatFamilies({cfYahoo, cfOutlookWord}) == "outlookWord, yahoo"
    check formatFamilies({}) == ""
