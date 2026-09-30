## isonim_email/style/tokens.nim — DTCG resolution to literals, light/dark
## mode pairs, and `EmailTheme`.
##
## This module DEPENDS on the DTCG resolver from
## `isonim-docs` (`core/tokens`: `loadTokens`, `resolve`, `resolveToken`)
## instead of moving it into `isonim`. Rationale:
##
## - Single implementation. The core is ~180 lines, `std`-only, already
##   correct on the C and JS targets; reusing it keeps one alias-walker
##   instead of two.
## - The move is a three-repo change — `isonim` gains the module,
##   `isonim-docs` re-points its import, this repo consumes the new home —
##   owned by the IsoNim maintainers and not landable atomically inside
##   this repo's scope. A partial move here (a copy under
##   `isonim/theming/` without the `isonim-docs` re-point) would fork the
##   resolver, which is worse than depending on it.
## - Email needs `$extensions.modes` handling that the shared core lacks,
##   and that layer is email-shaped either way (light inlines, dark feeds
##   the head block). Depending keeps the delta visible in this one file.
## - All three repositories are public, so the CI sibling clone works;
##   the pin lives in `.github/sibling-repos`.
##
## Follow-up: when the IsoNim
## maintainers schedule the move, only this module's `import core/tokens`
## (re-exported below, so consumers keep compiling) changes, plus the
## alias-or-scalar helper which a shared home could export instead of the
## copy kept here.
##
## Email exception: the web direction is "emit the reference,
## not the value" (`var(--…)`). Email cannot do that — CSS custom
## properties are unsupported in Gmail, Outlook and Yahoo — so this layer
## resolves every token to a literal at render time. `var()` is never
## emitted (R-CSS-11, enforced at the token layer here and at P5).
##
## Modes: a token whose `$extensions.modes` carries `light`/`dark` values
## yields both — the light literal is inlined (R-CSS-01) and the dark
## literal feeds the dark head block (R-CSS-02). Mode names match
## case-insensitively, since producers capitalise them differently (the
## design system ships `Light`/`Dark`). A side without a mode entry falls
## back to the token's own `$value`, so single-valued tokens (fonts,
## spacing, type) yield identical pairs.
##
## Value encodings:
## sizes carry `px` (`space.4` is `"16px"`), unitless where the key is
## unitless (`layout.containerWidth` is `"600"`), and `type.*`/`button.font`
## pack size/line-height/weight as `"16px/24px"` / `"28px/36px/700"`.
## This module stops at resolved pairs: no CSS serialisation here — that is
## `style/css.nim`, `passes/styles.nim` and `passes/head.nim`.
##
## Pure `std` + `core/tokens` string work: identical on the C and JS
## targets. (`loadTokens`/`loadModes` file variants are C-only, like the
## core's; tests and the JS target use the `*FromStrings` variants.)

import std/[json, strutils, tables]
import core/tokens

## Re-export the DTCG core (`TokenSet`, `loadTokens`, `resolve`, …) so
## consumers import one module and the isonim-docs seam stays in this file.
export tokens

type
  ThemeError* = object of ValueError
    ## Fatal theme-load failure. The message carries the stable code head
    ## (`E-THEME-MISSING-TOKEN: …`) so `toDiagnostic` converts it. Kept as
    ## this module's own type (rather than `EmailRenderError`) so the style
    ## layer stays framework-free: the theme generator and the JS target
    ## never import the renderer.

  TokenRef* = object
    ## A `tok"…"` reference: a required theme key, resolved against the
    ## render's theme at render time (P5).
    key*: string

  ThemePair* = object
    ## One theme key's resolved literals: `light` is inlined, `dark` feeds
    ## the dark head block; identical when the token has no dark mode.
    light*: string
    dark*: string

  EmailTheme* = object
    ## A resolved token set: every required key maps to its
    ## light/dark literal pair. Plain data — no live DTCG graph — so P5
    ## lookups are total and backend-independent.
    values*: Table[string, ThemePair]

  ModeTable* = Table[string, JsonNode]
    ## Raw `$extensions.modes` objects per dotted token path, walked from
    ## the same DTCG documents as the `TokenSet` (the core drops
    ## `$extensions`, so email walks them itself).

const requiredThemeKeys* = [
  "color.surface.canvas", "color.surface.card", "color.surface.subtle",
  "color.text.primary", "color.text.secondary", "color.text.inverse",
  "color.border.subtle", "color.accent.primary", "color.accent.primaryText",
  "color.link", "color.status.info", "color.status.info.bg",
  "color.status.success", "color.status.success.bg", "color.status.warning",
  "color.status.warning.bg", "color.status.danger", "color.status.danger.bg",
  "font.body", "font.heading", "font.mono", "type.body", "type.small",
  "type.h1", "type.h2", "type.h3", "space.1", "space.2", "space.3", "space.4",
  "space.5", "space.6", "space.7", "space.8", "space.section", "space.gutter",
  "radius.sm", "radius.md", "radius.lg", "button.padding", "button.font",
  "layout.containerWidth", "layout.breakpoint",
]
  ## Every key required in every theme, in table order. `tok"…"`
  ## checks against this at compile time; `buildTheme` checks at load.

proc toTokenRef(key: string): TokenRef {.inline.} =
  ## Hygienic constructor: `tok` cannot build `TokenRef(key: key)` itself
  ## because template substitution would also rewrite the field name.
  TokenRef(key: key)

template tok*(key: static string): TokenRef =
  ## A theme reference, resolved against the render's theme at render
  ## time (P5). An unknown key is a compile error.
  when key notin requiredThemeKeys:
    {.error: "unknown email theme key: '" & key &
      "': every tok\"…\" key must be a required theme key".}
  toTokenRef(key)

proc collectModes(node: JsonNode; prefix: string; modes: var ModeTable) =
  ## Walks one DTCG document exactly like the core's `addLayer` (a node
  ## with `$value` is a leaf, any other object a group, `$`-keys skipped)
  ## and records each leaf's `$extensions.modes` object, when present.
  if node.kind != JObject:
    return
  if node.hasKey("$value"):
    if node.hasKey("$extensions") and
        node["$extensions"].kind == JObject and
        node["$extensions"].hasKey("modes") and
        node["$extensions"]["modes"].kind == JObject:
      modes[prefix] = node["$extensions"]["modes"]
    return
  for key, child in node:
    if key.startsWith("$"):
      continue
    collectModes(child, if prefix.len == 0: key else: prefix & "." & key,
      modes)

proc loadModesFromStrings*(jsons: openArray[string]): ModeTable =
  ## Collects `$extensions.modes` from in-memory DTCG documents — the modes
  ## companion to `loadTokensFromStrings`, over the same inputs.
  result = initTable[string, JsonNode]()
  for s in jsons:
    collectModes(parseJson(s), "", result)

proc loadModes*(paths: varargs[string]): ModeTable =
  ## Collects `$extensions.modes` from DTCG files — the modes companion to
  ## `loadTokens`. C-only, like the core's file loader.
  result = initTable[string, JsonNode]()
  when defined(js):
    raise newException(TokenError,
      "loadModes requires a filesystem and is unavailable on the JS target; " &
      "embed the token JSON at compile time (staticRead) and use loadModesFromStrings")
  else:
    for p in paths:
      collectModes(parseFile(p), "", result)

proc resolveNode(ts: TokenSet; v: JsonNode): string =
  ## Resolves one raw DTCG value node: a whole-string `{alias}` follows the
  ## core's chain, anything else renders as the scalar the core would emit.
  ## (Mirrors the core's private `isAlias`/`scalarToString`, which the
  ## shared module does not export — see the follow-up note above.)
  if v.kind == JString and v.getStr.startsWith("{") and
      v.getStr.endsWith("}"):
    let target = v.getStr[1 ..< v.getStr.len - 1]
    return ts.resolve(target)
  case v.kind
  of JString: v.getStr
  of JInt: $v.getInt
  of JFloat:
    let f = v.getFloat
    if f == f.int.float: $f.int else: $f
  of JBool: $v.getBool
  of JNull: ""
  else: $v

proc modeSide(modes: JsonNode; side: string): JsonNode =
  ## The `light`/`dark` entry of a modes object, matched
  ## case-insensitively (`Light`/`Dark` in the design system); `nil` when
  ## the side is absent.
  for key, val in modes:
    if key.cmpIgnoreCase(side) == 0:
      return val
  nil

proc resolvePair*(ts: TokenSet; modes: ModeTable; key: string): ThemePair =
  ## Resolves `key` to its (light, dark) literals. Each side uses the
  ## `$extensions.modes` entry when present, else the token's own `$value`
  ## (so modeless tokens yield identical pairs). A dangling key or mode
  ## entry raises the core's `TokenError`.
  let lightNode =
    if key in modes: modeSide(modes[key], "light") else: nil
  let darkNode =
    if key in modes: modeSide(modes[key], "dark") else: nil
  ThemePair(
    light: (if lightNode != nil: ts.resolveNode(lightNode) else: ts.resolve(key)),
    dark: (if darkNode != nil: ts.resolveNode(darkNode) else: ts.resolve(key)),
  )

proc buildTheme*(pairs: openArray[(string, ThemePair)];
                 name = "theme"): EmailTheme =
  ## Builds and validates a theme: every required key must be present, or
  ## loading fails with `E-THEME-MISSING-TOKEN` naming each gap. Extra keys
  ## are kept (reserved for product extension; `tok"…"` still only accepts
  ## required keys). A duplicated key is a `ThemeError` without a code head — a
  ## programmer error, like a malformed pin, not a diagnosable render fault.
  result.values = initTable[string, ThemePair]()
  for (key, pair) in pairs:
    if key in result.values:
      raise newException(ThemeError, "duplicate theme key: '" & key & "'")
    result.values[key] = pair
  var missing: seq[string] = @[]
  for key in requiredThemeKeys:
    if key notin result.values:
      missing.add(key)
  if missing.len > 0:
    raise newException(ThemeError,
      "E-THEME-MISSING-TOKEN: " & name & " is missing " & $missing.len &
      " required theme key(s): " & missing.join(", "))

proc themeFromDtcg*(ts: TokenSet; modes: ModeTable;
                    name = "theme"): EmailTheme =
  ## Builds a theme reading each required key straight from the DTCG set
  ## (identity mapping) — the degenerate case where token paths ARE theme
  ## keys. Gaps fail with `E-THEME-MISSING-TOKEN`.
  var pairs: seq[(string, ThemePair)] = @[]
  for key in requiredThemeKeys:
    pairs.add((key, ts.resolvePair(modes, key)))
  buildTheme(pairs, name)

proc themeFromBindings*(ts: TokenSet; modes: ModeTable;
                        bindings: openArray[(string, string)];
                        name = "theme"): EmailTheme =
  ## Builds a theme from (theme key → DTCG path) bindings — the mapping a
  ## product theme carries (the Metacraft one lives in
  ## `tools/theme-snapshot/mapping.json`). Gaps fail with
  ## `E-THEME-MISSING-TOKEN`.
  var pairs: seq[(string, ThemePair)] = @[]
  for (key, path) in bindings:
    pairs.add((key, ts.resolvePair(modes, path)))
  buildTheme(pairs, name)

proc pairFor*(t: EmailTheme; key: string): ThemePair =
  ## The theme pair for `key`. A hand-built theme lacking the key fails
  ## with `E-THEME-MISSING-TOKEN`, the same code as load time.
  if key notin t.values:
    raise newException(ThemeError,
      "E-THEME-MISSING-TOKEN: theme has no key '" & key & "'")
  t.values[key]

proc lightFor*(t: EmailTheme; key: string): string =
  ## The inline literal for `key` (R-CSS-01): what P5 emits in `style=""`.
  t.pairFor(key).light

proc darkFor*(t: EmailTheme; key: string): string =
  ## The dark literal for `key` (R-CSS-02): what P6 emits in the dark head
  ## block. Equal to the light value when the token has no dark mode.
  t.pairFor(key).dark

proc lightFor*(t: EmailTheme; r: TokenRef): string =
  ## Resolves a `tok"…"` reference to its inline literal.
  t.lightFor(r.key)

proc darkFor*(t: EmailTheme; r: TokenRef): string =
  ## Resolves a `tok"…"` reference to its dark literal.
  t.darkFor(r.key)

proc hasDarkVariant*(t: EmailTheme; key: string): bool =
  ## Whether `key` carries a distinct dark value (i.e. P6 must emit a dark
  ## rule for it).
  let p = t.pairFor(key)
  p.dark != p.light

iterator pairs*(t: EmailTheme): tuple[key: string; pair: ThemePair] =
  ## Every required pair in key-table order (deterministic — the
  ## underlying table is unordered).
  for key in requiredThemeKeys:
    yield (key, t.values[key])

proc defaultTheme*(): EmailTheme =
  ## The neutral theme: white card on a light-grey canvas, one accent,
  ## 16/24 body. Its light/dark pairs must pass R-DRK-04 on their own
  ## (the theme test fails if they stop doing so).
  buildTheme([
    ("color.surface.canvas", ThemePair(light: "#f4f5f7", dark: "#0f1115")),
    ("color.surface.card", ThemePair(light: "#ffffff", dark: "#1a1d23")),
    ("color.surface.subtle", ThemePair(light: "#f8f9fb", dark: "#22262e")),
    ("color.text.primary", ThemePair(light: "#111827", dark: "#f3f4f6")),
    ("color.text.secondary", ThemePair(light: "#4b5563", dark: "#c3c8d0")),
    ("color.text.inverse", ThemePair(light: "#ffffff", dark: "#111827")),
    ("color.border.subtle", ThemePair(light: "#e5e7eb", dark: "#2f343d")),
    ("color.accent.primary", ThemePair(light: "#1f6feb", dark: "#4c8dff")),
    ("color.accent.primaryText", ThemePair(light: "#ffffff", dark: "#0b1220")),
    ("color.link", ThemePair(light: "#1f6feb", dark: "#7aa7ff")),
    ("color.status.info", ThemePair(light: "#1f6feb", dark: "#4c8dff")),
    ("color.status.info.bg", ThemePair(light: "#ddf4ff", dark: "#0c2d6b")),
    ("color.status.success", ThemePair(light: "#1a7f37", dark: "#3fb950")),
    ("color.status.success.bg", ThemePair(light: "#dafbe1", dark: "#0f3d1f")),
    ("color.status.warning", ThemePair(light: "#9a6700", dark: "#d29922")),
    ("color.status.warning.bg", ThemePair(light: "#fff8c5", dark: "#3d2e00")),
    ("color.status.danger", ThemePair(light: "#cf222e", dark: "#f85149")),
    ("color.status.danger.bg", ThemePair(light: "#ffebe9", dark: "#4c0f14")),
    ("font.body", ThemePair(light: "Helvetica, Arial, sans-serif",
      dark: "Helvetica, Arial, sans-serif")),
    ("font.heading", ThemePair(light: "Helvetica, Arial, sans-serif",
      dark: "Helvetica, Arial, sans-serif")),
    ("font.mono", ThemePair(light: "Menlo, Consolas, 'Courier New', monospace",
      dark: "Menlo, Consolas, 'Courier New', monospace")),
    ("type.body", ThemePair(light: "16px/24px", dark: "16px/24px")),
    ("type.small", ThemePair(light: "14px/20px", dark: "14px/20px")),
    ("type.h1", ThemePair(light: "28px/36px/700", dark: "28px/36px/700")),
    ("type.h2", ThemePair(light: "22px/30px/700", dark: "22px/30px/700")),
    ("type.h3", ThemePair(light: "18px/26px/700", dark: "18px/26px/700")),
    ("space.1", ThemePair(light: "4px", dark: "4px")),
    ("space.2", ThemePair(light: "8px", dark: "8px")),
    ("space.3", ThemePair(light: "12px", dark: "12px")),
    ("space.4", ThemePair(light: "16px", dark: "16px")),
    ("space.5", ThemePair(light: "24px", dark: "24px")),
    ("space.6", ThemePair(light: "32px", dark: "32px")),
    ("space.7", ThemePair(light: "48px", dark: "48px")),
    ("space.8", ThemePair(light: "64px", dark: "64px")),
    ("space.section", ThemePair(light: "24px 0", dark: "24px 0")),
    ("space.gutter", ThemePair(light: "0 24px", dark: "0 24px")),
    ("radius.sm", ThemePair(light: "4px", dark: "4px")),
    ("radius.md", ThemePair(light: "6px", dark: "6px")),
    ("radius.lg", ThemePair(light: "12px", dark: "12px")),
    ("button.padding", ThemePair(light: "12px 24px", dark: "12px 24px")),
    ("button.font", ThemePair(light: "16px/20px/600", dark: "16px/20px/600")),
    ("layout.containerWidth", ThemePair(light: "600", dark: "600")),
    ("layout.breakpoint", ThemePair(light: "480", dark: "480")),
  ], "defaultTheme")
