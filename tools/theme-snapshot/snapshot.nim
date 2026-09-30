## tools/theme-snapshot/snapshot.nim — pinned design-system tokens → theme.
##
## Reads the pinned `brand.json` / `alias.json` / `mapped.json` snapshots
## plus `mapping.json` (theme key → design-system token(s) or literal)
## and `theme.pin.json`, and generates
## `src/isonim_email/style/metacraft_theme.nim`: the Metacraft product
## theme with every value resolved to its light/dark literals.
##
## Binding forms (see mapping.json and README.md):
## - `{"token": path}`: both modes from that token's `$extensions.modes`
##   (`$value` fallback per side);
## - `{"light": side, "dark": side}`: each mode separately, where a side
##   is `{"token": path}` (the exact value — that token's own modes are
##   NOT consulted) or `{"literal": value}`;
## - `{"literal": value}`: an email constant in both modes.
##
## Output order follows `requiredThemeKeys` (key-table order), never JSON
## iteration order, so generation is a pure function of the five inputs —
## `tests/t4_theme_snapshot.nim` asserts the committed file is
## byte-identical to a fresh run.
##
## The payload sha256s are verified by `just theme-snapshot` before this
## runs (shell `sha256sum`, so the generator stays dependency-free); the
## pin's commit/shas are embedded in the generated header and exposed as
## constants the snapshot test pins.

import std/[json, sequtils, strutils]
import isonim_email/style/tokens

type ThemePin* = object
  source*, repo*, commit*, commitDate*, fetchDate*: string
  brand*, brandSha256*, alias*, aliasSha256*: string
  mapped*, mappedSha256*, license*: string

proc parseThemePin*(pinJson: string): ThemePin =
  ## Parses `theme.pin.json`. Raises `ValueError` naming the missing key.
  let j = parseJson(pinJson)
  for key in ["source", "repo", "commit", "commitDate", "fetchDate",
      "brand", "brandSha256", "alias", "aliasSha256",
      "mapped", "mappedSha256", "license"]:
    if not j.hasKey(key) or j[key].kind != JString:
      raise newException(ValueError,
        "theme.pin.json: missing or non-string key '" & key & "'")
  ThemePin(
    source: j["source"].str, repo: j["repo"].str,
    commit: j["commit"].str, commitDate: j["commitDate"].str,
    fetchDate: j["fetchDate"].str, brand: j["brand"].str,
    brandSha256: j["brandSha256"].str, alias: j["alias"].str,
    aliasSha256: j["aliasSha256"].str, mapped: j["mapped"].str,
    mappedSha256: j["mappedSha256"].str, license: j["license"].str,
  )

proc nimStrLit(s: string): string =
  ## `"..."` literal for resolved values and provenance text.
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    else: result.add c
  result.add "\""

proc resolveSide(ts: TokenSet; side: JsonNode; what: string): string =
  ## Resolves one `{"token": …} | {"literal": …}` per-mode side to its
  ## exact value. Raises `ValueError` on a malformed side.
  if side.kind != JObject:
    raise newException(ValueError,
      "mapping.json: " & what & " must be an object")
  let hasToken = side.hasKey("token")
  let hasLiteral = side.hasKey("literal")
  if hasToken == hasLiteral:
    raise newException(ValueError,
      "mapping.json: " & what & " must have exactly one of " &
      "'token' / 'literal'")
  if hasToken:
    if side["token"].kind != JString:
      raise newException(ValueError,
        "mapping.json: " & what & " 'token' must be a string")
    ts.resolve(side["token"].str)
  else:
    if side["literal"].kind != JString:
      raise newException(ValueError,
        "mapping.json: " & what & " 'literal' must be a string")
    side["literal"].str

proc sideSource(side: JsonNode): string =
  ## Short provenance note for a per-mode side (`token <path>` or the
  ## literal itself).
  if side.hasKey("token"):
    "token " & side["token"].str
  else:
    "literal " & nimStrLit(side["literal"].str)

proc applyBinding(ts: TokenSet; modes: ModeTable; key: string;
                  binding: JsonNode): tuple[pair: ThemePair; note: string] =
  ## Resolves one mapping entry to its theme pair plus a one-line
  ## provenance note for the generated file. Raises `ValueError` on a
  ## malformed binding; a dangling token path raises `TokenError`.
  if binding.kind != JObject:
    raise newException(ValueError,
      "mapping.json: binding for '" & key & "' must be an object")
  let hasToken = binding.hasKey("token")
  let hasLiteral = binding.hasKey("literal")
  let hasModes = binding.hasKey("light") or binding.hasKey("dark")
  if [hasToken, hasLiteral, hasModes].count(true) != 1:
    raise newException(ValueError,
      "mapping.json: binding for '" & key & "' must have exactly one of " &
      "'token' / 'literal' / 'light'+'dark'")
  if hasToken:
    if binding["token"].kind != JString:
      raise newException(ValueError,
        "mapping.json: binding for '" & key & "' has a non-string 'token'")
    let path = binding["token"].str
    (ts.resolvePair(modes, path), path)
  elif hasLiteral:
    if binding["literal"].kind != JString:
      raise newException(ValueError,
        "mapping.json: binding for '" & key & "' has a non-string 'literal'")
    let v = binding["literal"].str
    (ThemePair(light: v, dark: v), "literal")
  else:
    if not binding.hasKey("light") or not binding.hasKey("dark"):
      raise newException(ValueError,
        "mapping.json: binding for '" & key &
        "' needs both 'light' and 'dark'")
    let light = ts.resolveSide(binding["light"], "'" & key & "' light")
    let dark = ts.resolveSide(binding["dark"], "'" & key & "' dark")
    (ThemePair(light: light, dark: dark),
      "light " & sideSource(binding["light"]) &
      " / dark " & sideSource(binding["dark"]))

proc generateThemeModule*(brandJson, aliasJson, mappedJson, mappingJson,
                          pinJson: string): string =
  ## Returns the full bytes of `metacraft_theme.nim` for the pinned inputs.
  let pin = parseThemePin(pinJson)
  let ts = loadTokensFromStrings([brandJson, aliasJson, mappedJson])
  let modes = loadModesFromStrings([brandJson, aliasJson, mappedJson])
  let mapping = parseJson(mappingJson)
  if mapping.kind != JObject:
    raise newException(ValueError, "mapping.json: expected a JSON object")
  # Coverage first, so a mapping typo names the mapping (not a dangling
  # token or a theme gap downstream).
  var missing: seq[string] = @[]
  for key in requiredThemeKeys:
    if not mapping.hasKey(key):
      missing.add(key)
  if missing.len > 0:
    raise newException(ValueError,
      "mapping.json: missing binding(s) for " & missing.join(", "))
  var unknown: seq[string] = @[]
  for key in mapping.keys:
    if key.startsWith("_") or key.startsWith("$"):
      continue
    if key notin requiredThemeKeys:
      unknown.add(key)
  if unknown.len > 0:
    raise newException(ValueError,
      "mapping.json: unknown theme key(s) " & unknown.join(", "))

  var res = ""
  res.add "## isonim_email/style/metacraft_theme.nim — GENERATED, do not edit.\n"
  res.add "##\n"
  res.add "## The Metacraft product theme: required theme keys resolved to\n"
  res.add "## light/dark literals from the pinned design-system snapshot.\n"
  res.add "##   source:      " & pin.source & "\n"
  res.add "##   repo:        " & pin.repo & "\n"
  res.add "##   commit:      " & pin.commit & "\n"
  res.add "##   commit date: " & pin.commitDate & "\n"
  res.add "##   fetch date:  " & pin.fetchDate & "\n"
  res.add "##   brand:       " & pin.brand & " " & pin.brandSha256 & "\n"
  res.add "##   alias:       " & pin.alias & " " & pin.aliasSha256 & "\n"
  res.add "##   mapped:      " & pin.mapped & " " & pin.mappedSha256 & "\n"
  res.add "##   licence:     " & pin.license & "\n"
  res.add "##\n"
  res.add "## Generated by `just theme-snapshot`\n"
  res.add "## (tools/theme-snapshot/snapshot.nim) from `mapping.json` over the\n"
  res.add "## pinned payloads: colours resolve from design-system roles (light\n"
  res.add "## inlines, dark feeds the head block); metrics and font stacks are\n"
  res.add "## email constants. Each entry cites its binding.\n"
  res.add "##\n"
  res.add "## Re-pinning is a deliberate PR: the diff shows which theme values\n"
  res.add "## changed. `tests/t4_theme_snapshot.nim` asserts this file is\n"
  res.add "## byte-identical to what the pinned inputs produce.\n"
  res.add "\n"
  res.add "import isonim_email/style/tokens\n"
  res.add "\n"
  res.add "const metacraftThemeSource* = " & nimStrLit(pin.source) & "\n"
  res.add "const metacraftThemeCommit* = " & nimStrLit(pin.commit) & "\n"
  res.add "const metacraftThemeCommitDate* = " &
    nimStrLit(pin.commitDate) & "\n"
  res.add "const metacraftThemeFetchDate* = " &
    nimStrLit(pin.fetchDate) & "\n"
  res.add "const metacraftThemeBrandSha256* = " &
    nimStrLit(pin.brandSha256) & "\n"
  res.add "const metacraftThemeAliasSha256* = " &
    nimStrLit(pin.aliasSha256) & "\n"
  res.add "const metacraftThemeMappedSha256* = " &
    nimStrLit(pin.mappedSha256) & "\n"
  res.add "\n"
  res.add "proc metacraftTheme*(): EmailTheme =\n"
  res.add "  ## The Metacraft product theme: brand colours from\n"
  res.add "  ## `codetracer-design-system`, plus email constants.\n"
  res.add "  buildTheme([\n"
  for key in requiredThemeKeys:
    let (pair, note) = applyBinding(ts, modes, key, mapping[key])
    res.add "    (" & nimStrLit(key) & ",\n"
    res.add "      ThemePair(light: " & nimStrLit(pair.light) &
      ", dark: " & nimStrLit(pair.dark) & ")), # " & note & "\n"
  res.add "  ], \"metacraftTheme\")\n"
  res

when isMainModule:
  import std/os
  if paramCount() != 6:
    quit "usage: snapshot <brand.json> <alias.json> <mapped.json> " &
      "<mapping.json> <theme.pin.json> <out.nim>", 1
  writeFile(paramStr(6), generateThemeModule(
    readFile(paramStr(1)), readFile(paramStr(2)), readFile(paramStr(3)),
    readFile(paramStr(4)), readFile(paramStr(5))))
