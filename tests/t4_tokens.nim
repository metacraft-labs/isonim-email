## DTCG tokens resolve to literals with light/dark mode pairs, and
## `EmailTheme` carries every required key in both modes.
##
## No `# rule:` claims here: R-CSS-11 ("`var()` never emitted") is owned by
## P5, whose test carries the rule comment. This file pins the resolution
## the passes consume —
## including that no resolved value ever contains `var(` — without claiming
## the pipeline-wide rule.
##
## Backend-independent (inline DTCG strings + pure resolution), so `just
## test` also runs it on JS.
import std/[strutils, tables, unittest]
import isonim_email

const modeDoc = """{
  "color": {
    "surface": {
      "canvas": {"$type": "color", "$value": "{color.base.light}",
        "$extensions": {"modes": {"light": "{color.base.light}",
          "dark": "{color.base.dark}"}}},
      "card": {"$type": "color", "$value": "{color.base.dark}",
        "$extensions": {"modes": {"Light": "#ffffff", "Dark": "#1a1d23"}}},
      "subtle": {"$type": "color", "$value": "#f8f9fb"}
    },
    "text": {
      "primary": {"$type": "color", "$value": "#111827",
        "$extensions": {"modes": {"light": "#111827"}}},
      "secondary": {"$type": "color", "$value": "#4b5563",
        "$extensions": {"modes": {"dark": "#c3c8d0"}}},
      "inverse": {"$type": "color", "$value": "{color.base.light}",
        "$extensions": {"modes": {}}}
    },
    "border": {"subtle": {"$type": "color", "$value": "#e5e7eb"}},
    "accent": {
      "primary": {"$type": "color", "$value": "#1f6feb",
        "$extensions": {"modes": {"LIGHT": "#1f6feb", "DARK": "#4c8dff"}}},
      "primaryText": {"$type": "color", "$value": "#ffffff"}
    },
    "link": {"$type": "color", "$value": "{color.accent.primary}"},
    "status": {
      "info": {"$type": "color", "$value": "#1f6feb"},
      "info.bg": {"$type": "color", "$value": "#ddf4ff"},
      "success": {"$type": "color", "$value": "#1a7f37"},
      "success.bg": {"$type": "color", "$value": "#dafbe1"},
      "warning": {"$type": "color", "$value": "#9a6700"},
      "warning.bg": {"$type": "color", "$value": "#fff8c5"},
      "danger": {"$type": "color", "$value": "#cf222e"},
      "danger.bg": {"$type": "color", "$value": "#ffebe9"}
    },
    "base": {
      "light": {"$type": "color", "$value": "#f4f5f7"},
      "dark": {"$type": "color", "$value": "#0f1115"}
    }
  },
  "font": {
    "body": {"$value": "Helvetica, Arial, sans-serif"},
    "heading": {"$value": "Helvetica, Arial, sans-serif"},
    "mono": {"$value": "Menlo, Consolas, 'Courier New', monospace"}
  },
  "type": {
    "body": {"$value": "16px/24px"},
    "small": {"$value": "14px/20px"},
    "h1": {"$value": "28px/36px/700"},
    "h2": {"$value": "22px/30px/700"},
    "h3": {"$value": "18px/26px/700"}
  },
  "space": {
    "1": {"$value": "4px"}, "2": {"$value": "8px"}, "3": {"$value": "12px"},
    "4": {"$value": "16px"}, "5": {"$value": "24px"}, "6": {"$value": "32px"},
    "7": {"$value": "48px"}, "8": {"$value": "64px"},
    "section": {"$value": "24px 0"}, "gutter": {"$value": "0 24px"}
  },
  "radius": {
    "sm": {"$value": "4px"}, "md": {"$value": "6px"}, "lg": {"$value": "12px"}
  },
  "button": {
    "padding": {"$value": "12px 24px"}, "font": {"$value": "16px/20px/600"}
  },
  "layout": {"containerWidth": {"$value": "600"}, "breakpoint": {"$value": "480"}}
}"""

proc modeSet(): tuple[ts: TokenSet, modes: ModeTable] =
  (loadTokensFromStrings([modeDoc]), loadModesFromStrings([modeDoc]))

suite "tokens resolve to literals with dark pairs":
  test "test_tokens_resolve_to_literals_with_dark_pairs":
    let (ts, modes) = modeSet()
    let theme = themeFromDtcg(ts, modes, "fixture")
    # Every required key resolves; the light literal is what P5 inlines
    # (R-CSS-01) and the dark literal is what P6 emits in the dark head
    # block (R-CSS-02). The mapping is pinned first; the end of this
    # test proves the passes consume both sides of it.
    check theme.lightFor("color.surface.canvas") == "#f4f5f7"
    check theme.darkFor("color.surface.canvas") == "#0f1115"
    # Capitalised mode names (`Light`/`Dark`, as the design system ships)
    # resolve like lowercase ones, for literals as well as aliases.
    check theme.lightFor("color.surface.card") == "#ffffff"
    check theme.darkFor("color.surface.card") == "#1a1d23"
    # A token without modes yields the same literal in both modes …
    check theme.lightFor("color.surface.subtle") == "#f8f9fb"
    check theme.darkFor("color.surface.subtle") == "#f8f9fb"
    check not theme.hasDarkVariant("color.surface.subtle")
    # … as does an empty modes object, and a missing side falls back to
    # the token's own $value.
    check theme.lightFor("color.text.inverse") == "#f4f5f7"
    check theme.darkFor("color.text.inverse") == "#f4f5f7"
    check theme.lightFor("color.text.primary") == "#111827"
    check theme.darkFor("color.text.primary") == "#111827"
    check theme.lightFor("color.text.secondary") == "#4b5563"
    check theme.darkFor("color.text.secondary") == "#c3c8d0"
    # Mode names match case-insensitively.
    check theme.lightFor("color.accent.primary") == "#1f6feb"
    check theme.darkFor("color.accent.primary") == "#4c8dff"
    check theme.hasDarkVariant("color.surface.canvas")
    check theme.hasDarkVariant("color.surface.card")
    check theme.hasDarkVariant("color.accent.primary")
    # Plain aliases (no modes involved) resolve through the set.
    check theme.lightFor("color.link") == "#1f6feb"
    # Non-color keys pass through as literals in both modes.
    check theme.lightFor("font.mono") == "Menlo, Consolas, 'Courier New', monospace"
    check theme.darkFor("type.h1") == "28px/36px/700"
    check theme.lightFor("space.4") == "16px"
    check theme.darkFor("layout.containerWidth") == "600"
    # The token layer never emits a reference: no `var(` in any value.
    for key, pair in theme:
      check "var(" notin pair.light
      check "var(" notin pair.dark
      check "{" notin pair.light
      check "{" notin pair.dark
    # The passes consume both sides of the pair: through P5, a token
    # inline resolves to its light literal and the same token under
    # @dark: to its dark literal; through P6, the dark head block
    # carries the dark literals and none of the light ones.
    let r = EmailRenderer()
    let card = r.createElement("td")
    r.setStyle(card, "background-color", tok"color.surface.card")
    r.setStyle(card, "color", tok"color.accent.primary")
    r.setStyle(card, "@dark:background-color", tok"color.surface.card")
    r.setStyle(card, "@dark:color", tok"color.accent.primary")
    let (head, diags) = applyStyles(card, theme, defaultTarget())
    check diags.len == 0
    check card.styles["background-color"] == "#ffffff"
    check card.styles["color"] == "#1f6feb"
    check head.len == 2
    for h in head:
      check h.variant == "dark"
      if h.prop == "background-color":
        check h.value == "#1a1d23"
      else:
        check h.prop == "color"
        check h.value == "#4c8dff"
    var designed = defaultTarget()
    designed.darkMode = dmDesigned
    var darkText = ""
    for b in assembleHead(head, designed).blocks:
      if "@media (prefers-color-scheme: dark)" in b.text:
        darkText = b.text
    let query = darkText[darkText.find("@media") ..< darkText.find("}}") + 2]
    check "background-color:#1a1d23 !important" in query
    check "color:#4c8dff !important" in query
    check "#ffffff" notin query
    check "#1f6feb" notin query
    # Thunderbird's copy carries both values (R-DRK-08).
    check "background-color:light-dark(#ffffff,#1a1d23) !important" in
      darkText
    check "color:light-dark(#1f6feb,#4c8dff) !important" in darkText

  test "tok references resolve against the theme":
    let (ts, modes) = modeSet()
    let theme = themeFromDtcg(ts, modes, "fixture")
    let card = tok"color.surface.card"
    check card.key == "color.surface.card"
    check theme.lightFor(card) == "#ffffff"
    check theme.darkFor(card) == "#1a1d23"
    check theme.lightFor(tok"space.section") == "24px 0"

  test "defaultTheme carries the required key table":
    let theme = defaultTheme()
    check requiredThemeKeys.len == 43
    var seen = 0
    for key, pair in theme:
      check key == requiredThemeKeys[seen]
      check pair.light.len > 0
      check pair.dark.len > 0
      check "var(" notin pair.light
      check "var(" notin pair.dark
      inc seen
    check seen == 43
    # Spot values from the key table (light, dark).
    check theme.lightFor("color.surface.canvas") == "#f4f5f7"
    check theme.darkFor("color.surface.canvas") == "#0f1115"
    check theme.lightFor("color.status.danger.bg") == "#ffebe9"
    check theme.darkFor("color.status.danger.bg") == "#4c0f14"
    check theme.lightFor("font.body") == "Helvetica, Arial, sans-serif"
    check theme.lightFor("type.body") == "16px/24px"
    check theme.lightFor("space.8") == "64px"
    check theme.lightFor("radius.lg") == "12px"
    check theme.lightFor("button.padding") == "12px 24px"
    check theme.lightFor("layout.breakpoint") == "480"
    # Colors carry dark variants; metrics do not.
    check theme.hasDarkVariant("color.text.primary")
    check not theme.hasDarkVariant("space.1")
    check not theme.hasDarkVariant("type.h1")

  test "a theme missing a key fails with E-THEME-MISSING-TOKEN":
    let (ts, modes) = modeSet()
    var bindings: seq[(string, string)] = @[]
    for key in requiredThemeKeys:
      if key != "color.surface.card" and key != "space.8":
        bindings.add((key, key))
    expect ThemeError:
      discard themeFromBindings(ts, modes, bindings, "gappy")
    try:
      discard themeFromBindings(ts, modes, bindings, "gappy")
    except ThemeError as e:
      check codeThemeMissingToken in e.msg
      check "color.surface.card" in e.msg
      check "space.8" in e.msg
      # The `CODE: message` shape converts to a diagnostic.
      let d = toDiagnostic(e.msg)
      check d.code == codeThemeMissingToken
      check d.severity == sevError
    # A hand-built theme lacking the key fails the same way at lookup.
    var theme = defaultTheme()
    theme.values.del("color.link")
    expect ThemeError:
      discard theme.lightFor("color.link")

  test "a duplicated theme key is a programmer error":
    var pairs: seq[(string, ThemePair)] = @[]
    for key in requiredThemeKeys:
      pairs.add((key, ThemePair(light: "x", dark: "x")))
    pairs.add(("space.1", ThemePair(light: "y", dark: "y")))
    expect ThemeError:
      discard buildTheme(pairs)

  test "dangling and cyclic references raise TokenError":
    let dangling = loadTokensFromStrings([
      """{"a": {"$value": "{missing.key}"}}"""])
    let danglingModes = loadModesFromStrings([
      """{"a": {"$value": "{missing.key}"}}"""])
    expect TokenError:
      discard dangling.resolvePair(danglingModes, "a")
    let cyclic = loadTokensFromStrings([
      """{"a": {"$value": "{b}"}, "b": {"$value": "{a}"}}"""])
    let cyclicModes = loadModesFromStrings([
      """{"a": {"$value": "{b}"}, "b": {"$value": "{a}"}}"""])
    expect TokenError:
      discard cyclic.resolvePair(cyclicModes, "a")
    # A mode entry pointing nowhere fails the same way.
    let badMode = loadTokensFromStrings([
      """{"a": {"$value": "#111111", "$extensions":
        {"modes": {"dark": "{missing.key}"}}}}"""])
    let badModeModes = loadModesFromStrings([
      """{"a": {"$value": "#111111", "$extensions":
        {"modes": {"dark": "{missing.key}"}}}}"""])
    expect TokenError:
      discard badMode.resolvePair(badModeModes, "a")

suite "the default palette's link colour":
  test "test_link_colour_passes_on_every_surface":
    # The default theme paints links on its own surfaces (the text
    # leaves' link default, outline and link buttons), so the link
    # colour passes 4.5:1 on every surface token, not just white: the
    # light value on the light surfaces, and the dark pair (painted
    # under darkMode = designed) on the dark ones.
    let theme = defaultTheme()
    let link = parseColor(theme.lightFor("color.link"))
    let darkLink = parseColor(theme.darkFor("color.link"))
    for key in ["color.surface.canvas", "color.surface.card",
        "color.surface.subtle"]:
      let ratio = contrastRatio(link, parseColor(theme.lightFor(key)))
      checkpoint(key & ": " & $ratio)
      check ratio >= 4.5
      let darkRatio = contrastRatio(darkLink,
        parseColor(theme.darkFor(key)))
      checkpoint(key & " (dark): " & $darkRatio)
      check darkRatio >= 4.5

  test "test_default_palette_light_and_dark_pairs_pass":
    # The default palette's pairs pass R-DRK-04's light and dark schemes
    # (4.5:1) on their own, as the library paints them: body and
    # secondary text on every surface, a filled button's label on its
    # fill (the accent, and each status tone with the inverse text) and
    # an outline button's tone on a card. Under darkMode = designed each
    # side takes its dark value. (The inversion models are a separate
    # check: tests/t5_dark.nim pins what they say of this palette.)
    let t = defaultTheme()
    proc both(fg, bg: string) =
      for dark in [false, true]:
        let f = parseColor(if dark: t.darkFor(fg) else: t.lightFor(fg))
        let b = parseColor(if dark: t.darkFor(bg) else: t.lightFor(bg))
        let ratio = contrastRatio(f, b)
        checkpoint(fg & " on " & bg & (if dark: " (dark): " else: ": ") &
          $ratio)
        check ratio >= 4.5
    for text in ["color.text.primary", "color.text.secondary"]:
      for surface in ["color.surface.canvas", "color.surface.card",
          "color.surface.subtle"]:
        both(text, surface)
    both("color.accent.primaryText", "color.accent.primary")
    for tone in ["info", "success", "warning", "danger"]:
      both("color.text.inverse", "color.status." & tone)
      both("color.status." & tone, "color.surface.card")
