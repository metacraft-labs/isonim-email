## Re-running the theme generator on the pinned design-system
## snapshot yields a byte-identical theme module, and the module reads
## back as the pinned values.
##
## Backend-independent (in-memory generation over staticRead payloads;
## output order follows `requiredThemeKeys`, never JSON iteration order),
## so `just test` also runs it on JS.
import std/[strutils, unittest]
import isonim_email
import "../tools/theme-snapshot/snapshot"

const brandJson = staticRead("../tools/theme-snapshot/brand.json")
const aliasJson = staticRead("../tools/theme-snapshot/alias.json")
const mappedJson = staticRead("../tools/theme-snapshot/mapped.json")
const mappingJson = staticRead("../tools/theme-snapshot/mapping.json")
const pinJson = staticRead("../tools/theme-snapshot/theme.pin.json")
const committed =
  staticRead("../src/isonim_email/style/metacraft_theme.nim")

proc freshModule(): string =
  generateThemeModule(brandJson, aliasJson, mappedJson, mappingJson, pinJson)

suite "theme snapshot reproducible":
  test "test_theme_generation_reproducible":
    check freshModule() == committed

  test "pin carries the theme provenance":
    let pin = parseThemePin(pinJson)
    check pin.repo ==
      "https://github.com/metacraft-labs/codetracer-design-system"
    check pin.commit == "8fb101f29a2269d87b246e87f6c39eff454f0a3a"
    check pin.commitDate == "2026-09-23"
    check pin.fetchDate == "2026-09-27"
    check pin.brand == "brand.json"
    check pin.brandSha256 ==
      "d65d49db892c638b8ba221570bd76e3babc91668708bca8520fb5a7608be4b70"
    check pin.alias == "alias.json"
    check pin.aliasSha256 ==
      "f84e6d9a3296501d188e2f9ebf7ad11d61317749919a83b60f0b740eb84f3ce2"
    check pin.mapped == "mapped.json"
    check pin.mappedSha256 ==
      "deb29aad71b80a17eda81ae2c0b76f0ba268bb5e381dda7e2c436cf7757fad76"
    # The generated header records the same provenance.
    check pin.commit in committed
    check pin.brandSha256 in committed
    check pin.aliasSha256 in committed
    check pin.mappedSha256 in committed
    check pin.fetchDate in committed
    # And the module exposes it as constants.
    check metacraftThemeCommit == pin.commit
    check metacraftThemeCommitDate == pin.commitDate
    check metacraftThemeFetchDate == pin.fetchDate
    check metacraftThemeBrandSha256 == pin.brandSha256
    check metacraftThemeAliasSha256 == pin.aliasSha256
    check metacraftThemeMappedSha256 == pin.mappedSha256

  test "a broken mapping or pin fails generation":
    # A removed binding names the missing key …
    let dropped = mappingJson.replace(
      "\"color.link\": {\"token\": \"colors.ui.text.information.primary\"},",
      "")
    expect ValueError:
      discard generateThemeModule(brandJson, aliasJson, mappedJson, dropped,
        pinJson)
    try:
      discard generateThemeModule(brandJson, aliasJson, mappedJson, dropped,
        pinJson)
    except ValueError as e:
      check "color.link" in e.msg
    # … an unknown key is rejected (typo guard) …
    let extended = mappingJson.replace(
      "\"space.8\": {\"literal\": \"64px\"},",
      "\"space.8\": {\"literal\": \"64px\"}, \"space.9\": {\"literal\": \"1px\"},")
    expect ValueError:
      discard generateThemeModule(brandJson, aliasJson, mappedJson, extended,
        pinJson)
    # … a malformed binding is rejected …
    let mistyped = mappingJson.replace(
      "\"color.surface.canvas\": {\"token\": " &
        "\"colors.ui.surface.base.canvas\"}",
      "\"color.surface.canvas\": {\"token\": 42}")
    expect ValueError:
      discard generateThemeModule(brandJson, aliasJson, mappedJson, mistyped,
        pinJson)
    # … a token path pointing nowhere raises TokenError …
    let dangling = mappingJson.replace(
      "colors.ui.surface.base.canvas", "colors.nope")
    expect TokenError:
      discard generateThemeModule(brandJson, aliasJson, mappedJson, dangling,
        pinJson)
    # … and a pin missing a key names it.
    let badPin = pinJson.replace("\"commitDate\": \"2026-09-23\",", "")
    expect ValueError:
      discard generateThemeModule(brandJson, aliasJson, mappedJson,
        mappingJson, badPin)

  test "the metacraft theme reads back as the pinned values":
    let theme = metacraftTheme()
    var seen = 0
    for key, pair in theme:
      check key == requiredThemeKeys[seen]
      check "var(" notin pair.light
      check "var(" notin pair.dark
      inc seen
    check seen == 43
    # Spot values, cross-checked against an independent resolution of the
    # pinned payloads (light, dark).
    check theme.lightFor("color.surface.canvas") == "#d2ccc1"
    check theme.darkFor("color.surface.canvas") == "#1b1b1b"
    check theme.lightFor("color.text.primary") == "#272522"
    check theme.darkFor("color.text.primary") == "#f3f3f3"
    check theme.lightFor("color.accent.primary") == "#a5b4fc"
    check theme.darkFor("color.accent.primary") == "#4f46e5"
    check theme.lightFor("color.link") == "#2563eb"
    check theme.darkFor("color.status.danger.bg") == "#7f1d1d"
    check theme.lightFor("color.status.success.bg") == "#dcfce7"
    check theme.lightFor("font.mono") ==
      "Menlo, Consolas, 'Courier New', monospace"
    check theme.lightFor("layout.containerWidth") == "600"
    # Colour values are 6-digit lowercase hex in both modes.
    for key in requiredThemeKeys:
      if not key.startsWith("color."):
        continue
      for v in [theme.lightFor(key), theme.darkFor(key)]:
        check v.len == 7
        check v[0] == '#'
        for c in v[1 .. ^1]:
          check c in {'0' .. '9', 'a' .. 'f'}
    # Dark variants exactly where the mapping binds them: the 12 role
    # colours whose modes differ plus the 4 per-mode callout tint pairs.
    # (`color.text.inverse` / `color.accent.primaryText` resolve
    # identically in both modes, like their design-system role.)
    var darkKeys: seq[string] = @[]
    for key in requiredThemeKeys:
      if theme.hasDarkVariant(key):
        darkKeys.add(key)
    check darkKeys.len == 16
    check "color.surface.canvas" in darkKeys
    check "color.status.danger.bg" in darkKeys
    check "color.text.inverse" notin darkKeys
    check "space.1" notin darkKeys

  test "theme values resolve from the pinned payloads":
    # Independent provenance check: resolving the mapped design-system
    # paths straight from the payloads yields the generated pairs, so the
    # theme cannot drift into hand-written literals unnoticed.
    let ts = loadTokensFromStrings([brandJson, aliasJson, mappedJson])
    let modes = loadModesFromStrings([brandJson, aliasJson, mappedJson])
    let theme = metacraftTheme()
    for (key, path) in [
        ("color.surface.card", "colors.ui.surface.base.card"),
        ("color.text.secondary", "colors.ui.text.primary.body-subtle"),
        ("color.border.subtle", "colors.ui.divider.subtle"),
        ("color.status.warning", "colors.ui.text.warning.primary"),
      ]:
      let direct = ts.resolvePair(modes, path)
      check theme.lightFor(key) == direct.light
      check theme.darkFor(key) == direct.dark
    check theme.lightFor("color.status.info.bg") ==
      ts.resolve("colors.information.100")
    check theme.darkFor("color.status.info.bg") ==
      ts.resolve("colors.information.900")
