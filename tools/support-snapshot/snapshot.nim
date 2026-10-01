## tools/support-snapshot/snapshot.nim — pinned caniemail fetch → Nim table.
##
## Reads the pinned `caniemail-data.json` snapshot plus `snapshot.pin.json`
## and generates `src/isonim_email/support/caniemail_data.nim`:
## a compile-time table of features × clients with support values `y`/`n`/
## `a` (partial) / `u` (unknown) plus note ids.
##
## Reduction rule: a key's value is the WORST result over the versions
## the key spans (`n` < `a` < `y`; `u` only when nothing is known), and
## its note ids are the union over the spanned results carrying that
## value. `spanRules` gives every key a span, with a one-line rationale
## judged as of `spanRulesAsOf`: a webmail or store app auto-updates, so
## only its latest result describes a build anyone runs; an OS-bundled or
## separately installed client (Apple Mail, Outlook for Windows and Mac,
## Thunderbird) spans every result labelled with a version still in use.
## A key with no rule fails generation. Keys absent from a feature read
## as `u`. Both orders the output otherwise depends on (feature slugs,
## client keys) are sorted, so generation is a pure function of the two
## inputs — `tests/t3_snapshot_reproducible.nim` asserts the committed
## file is byte-identical to a fresh run.
##
## C backend only: the reduction reads JSON object insertion order, which
## `std/json` preserves on C (OrderedTable) but the JS backend does not
## (integer-like keys iterate numerically — verified 2026-09-27:
## `{"10.15": n, "11": y, "12": y}` reduces to `n` on JS, `y` on C).
## `just support-snapshot` and the reproducibility test both run on C.
##
## The pin cross-check (`apiVersion`, `dataDate` against the JSON payload)
## fails generation on a mismatched pair; the sha256 of the payload is
## verified by `just support-snapshot` before this runs (shell `sha256sum`,
## so the generator stays dependency-free and backend-independent).

import std/[algorithm, json, sequtils, strutils]

type SnapshotPin* = object
  source*, repo*, commit*, commitDate*, fetchDate*: string
  dataDate*, apiVersion*, sha256*, license*: string

proc parsePin*(pinJson: string): SnapshotPin =
  ## Parses `snapshot.pin.json`. Raises `ValueError` naming the missing key.
  let j = parseJson(pinJson)
  for key in ["source", "repo", "commit", "commitDate", "fetchDate",
      "dataDate", "apiVersion", "sha256", "license"]:
    if not j.hasKey(key) or j[key].kind != JString:
      raise newException(ValueError,
        "snapshot.pin.json: missing or non-string key '" & key & "'")
  SnapshotPin(
    source: j["source"].str, repo: j["repo"].str,
    commit: j["commit"].str, commitDate: j["commitDate"].str,
    fetchDate: j["fetchDate"].str, dataDate: j["dataDate"].str,
    apiVersion: j["apiVersion"].str, sha256: j["sha256"].str,
    license: j["license"].str,
  )

proc parseSupportCell*(raw: string): tuple[value: char, notes: seq[int]] =
  ## Splits a caniemail cell (`y`, `n`, `a #1`, `a #6 #7`) into its value
  ## and note ids (empty when the cell cites none). Raises `ValueError`
  ## on anything outside the `y`/`n`/`a`/`u` vocabulary.
  let parts = raw.strip().split(' ')
  if parts.len == 0 or parts[0].len != 1 or parts[0][0] notin "ynau":
    raise newException(ValueError,
      "caniemail-data.json: bad support value '" & raw & "'")
  var notes: seq[int] = @[]
  for refPart in parts[1 .. ^1]:
    if not refPart.startsWith("#"):
      raise newException(ValueError,
        "caniemail-data.json: bad note reference '" & raw & "'")
    try:
      notes.add(parseInt(refPart[1 .. ^1]))
    except ValueError:
      raise newException(ValueError,
        "caniemail-data.json: bad note reference '" & raw & "'")
  (parts[0][0], notes)

type
  SpanKind* = enum
    spanLatest  ## the last result only
    spanInUse   ## every result labelled within the in-use floors

  SpanRule* = object
    ## How many of a caniemail key's results its value is reduced over.
    key*: string
    kind*: SpanKind
    minVersion*: string
      ## `spanInUse`: dotted version labels (`18.7`, `16.80`, `137.0b3`)
      ## count from this version on; "" makes such a label an error.
    minDate*: string
      ## `spanInUse`: dated retests (`2024-10`) count from this month on —
      ## the month the oldest in-use version shipped (or, for Outlook for
      ## Mac, stopped updating).
    minYear*: int
      ## `spanInUse`: product-year labels (`2019`) count from this year
      ## on; 0 makes such a label an error.
    why*: string
      ## The one-line rationale, as of `spanRulesAsOf`.

const spanRulesAsOf* = "2026-10-01"
  ## The date the in-use floors below were judged against. Review the
  ## table whenever the snapshot is re-pinned: a floor moves when a
  ## version leaves use, and a new key needs a rule before generation
  ## succeeds.

proc latestRule(key, why: string): SpanRule =
  SpanRule(key: key, kind: spanLatest, why: why)

proc inUseRule(key, minVersion, minDate: string; minYear: int;
    why: string): SpanRule =
  SpanRule(key: key, kind: spanInUse, minVersion: minVersion,
    minDate: minDate, minYear: minYear, why: why)

const
  webmail = "webmail: one server-side build serves every user"
  storeApp = "store app: auto-updates, older results are builds nobody runs"

const spanRules*: array[48, SpanRule] = [
  latestRule("aol/android", storeApp),
  latestRule("aol/desktop-webmail", webmail),
  latestRule("aol/ios", storeApp),
  inUseRule("apple-mail/ios", "18", "2024-09", 0,
    "bundled with iOS: 27 is current (2026-09) and 26 previous, and 18 " &
    "stays on the devices 26 dropped (XS/XR), so 18 and later; dated " &
    "retests from 18's release (2024-09)"),
  inUseRule("apple-mail/macos", "16", "2024-09", 0,
    "bundled with macOS: Apple patches 27, 26 Tahoe and 15 Sequoia; the " &
    "payload labels Mail 13-15 for Catalina-Monterey, 16 for the Mail " &
    "of Ventura/Sonoma/Sequoia and 26 for Tahoe, so 16 and later; dated " &
    "retests from Sequoia's release (2024-09)"),
  latestRule("fastmail/desktop-webmail", webmail),
  latestRule("free-fr/desktop-webmail", webmail),
  latestRule("gmail/android", storeApp),
  latestRule("gmail/desktop-webmail", webmail),
  latestRule("gmail/ios", storeApp),
  latestRule("gmail/mobile-webmail", webmail),
  latestRule("gmx/android", storeApp),
  latestRule("gmx/desktop-webmail", webmail),
  latestRule("gmx/ios", storeApp),
  latestRule("hey/desktop-webmail", webmail),
  latestRule("ionos-1and1/android", storeApp),
  latestRule("ionos-1and1/desktop-webmail", webmail),
  latestRule("laposte/android", storeApp),
  latestRule("laposte/desktop-webmail", webmail),
  latestRule("laposte/ios", storeApp),
  latestRule("mail-ru/desktop-webmail", webmail),
  latestRule("orange/android", storeApp),
  latestRule("orange/desktop-webmail", webmail),
  latestRule("orange/ios", storeApp),
  latestRule("outlook/android", storeApp),
  latestRule("outlook/ios", storeApp),
  inUseRule("outlook/macos", "16.78", "2023-10", 2019,
    "installed product: perpetual Outlook 2019 for Mac and later is " &
    "still deployed; 16.78 (2023-10) is 2019's final update, so every " &
    "in-use install runs that build or later"),
  latestRule("outlook/outlook-com", webmail),
  inUseRule("outlook/windows", "", "2016-01", 2016,
    "installed product: Outlook 2016 is still deployed and lacks what " &
    "2019 has; 2016 and later, with their dated retests"),
  latestRule("outlook/windows-mail",
    "retired at the end of 2024: its final build is the only one left"),
  latestRule("protonmail/android", storeApp),
  latestRule("protonmail/desktop-webmail", webmail),
  latestRule("protonmail/ios", storeApp),
  latestRule("rainloop/desktop-webmail",
    "self-hosted webmail with a single result: nothing older to span"),
  latestRule("samsung-email/android",
    "store app: updated through Galaxy Store and Google Play " &
    "independently of the One UI release"),
  latestRule("sfr/android", storeApp),
  latestRule("sfr/desktop-webmail", webmail),
  latestRule("sfr/ios", storeApp),
  latestRule("t-online-de/desktop-webmail", webmail),
  inUseRule("thunderbird/macos", "140", "2025-07", 0,
    "installed product: 153 is the current ESR, 140 the previous ESR " &
    "still patched alongside it, plus the monthly release channel; so " &
    "140 and later, dated retests from 140's release (2025-07)"),
  inUseRule("thunderbird/windows", "140", "2025-07", 0,
    "same product and floors as thunderbird/macos"),
  latestRule("web-de/android", storeApp),
  latestRule("web-de/desktop-webmail", webmail),
  latestRule("web-de/ios", storeApp),
  latestRule("wp-pl/desktop-webmail", webmail),
  latestRule("yahoo/android", storeApp),
  latestRule("yahoo/desktop-webmail", webmail),
  latestRule("yahoo/ios", storeApp),
]
  ## Every caniemail key's span. A key without a rule fails generation.

proc spanRule*(key: string): SpanRule =
  ## The rule for `key`. Raises `ValueError` when it has none: a re-pin
  ## that adds a client must decide its span, not inherit a default.
  for r in spanRules:
    if r.key == key:
      return r
  raise newException(ValueError, "caniemail-data.json: client key '" & key &
    "' has no span rule in snapshot.nim's `spanRules`")

proc allDigits(s: string): bool =
  s.len > 0 and s.allIt(it in {'0' .. '9'})

proc versionParts(s: string): seq[int] =
  ## `16.80` → @[16, 80]; `137.0b3` → @[137, 0] (a beta of 137.0); empty
  ## when `s` is not a dotted version.
  var core = s
  for i, c in s:
    if c in {'a', 'b'}:
      if not allDigits(s[i + 1 .. ^1]):
        return @[]
      core = s[0 ..< i]
      break
  for part in core.split('.'):
    if not allDigits(part):
      return @[]
    result.add(parseInt(part))

proc atLeast(a, b: seq[int]): bool =
  ## `a >= b`, component-wise, missing components reading as 0.
  for i in 0 ..< max(a.len, b.len):
    let x = (if i < a.len: a[i] else: 0)
    let y = (if i < b.len: b[i] else: 0)
    if x != y:
      return x > y
  true

proc inUse(rule: SpanRule; label: string): bool =
  ## Whether a result labelled `label` falls within `rule`'s floors.
  ## Raises `ValueError` on a label of a kind the rule has no floor for.
  let bad = "caniemail-data.json: " & rule.key & " version '" & label & "' "
  if label.len == 7 and label[4] == '-' and allDigits(label[0 .. 3]) and
      allDigits(label[5 .. 6]):
    return label >= rule.minDate
  if label.len == 4 and allDigits(label):
    if rule.minYear == 0:
      raise newException(ValueError, bad & "is a year, and the rule has none")
    return parseInt(label) >= rule.minYear
  let parts = versionParts(label)
  if parts.len == 0:
    raise newException(ValueError, bad & "is neither a date, a year nor " &
      "a version")
  if rule.minVersion == "":
    raise newException(ValueError, bad & "is a version, and the rule has " &
      "no version floor")
  atLeast(parts, versionParts(rule.minVersion))

proc spannedResults*(key: string; vers: JsonNode): seq[string] =
  ## The raw cells of the results `key` spans, in payload order (see
  ## `spanRules`). For `spanInUse`, the results labelled within the
  ## floors — or, when none is, the latest result, the nearest evidence
  ## there is. For `spanLatest`, the last result: caniemail appends new
  ## results, and JSON objects keep insertion order on C. Raises
  ## `ValueError` for a key with no rule or a label the rule cannot place.
  let rule = spanRule(key)
  var last = ""
  for label, cell in vers.pairs:
    last = cell.str
    if rule.kind == spanInUse and inUse(rule, label):
      result.add(cell.str)
  if result.len == 0:
    result = @[last]

proc reduceSpan*(cells: openArray[string]): tuple[value: char, notes: seq[int]] =
  ## The worst value over `cells` (`n` < `a` < `y`; `u` abstains unless
  ## every cell is `u`) and the union of note ids, first-seen order,
  ## over the cells carrying it.
  proc rank(v: char): int =
    case v
    of 'n': 0
    of 'a': 1
    of 'y': 2
    else: 3
  result.value = 'u'
  for cell in cells:
    let (val, _) = parseSupportCell(cell)
    if rank(val) < rank(result.value):
      result.value = val
  for cell in cells:
    let (val, notes) = parseSupportCell(cell)
    if val == result.value:
      for n in notes:
        if n notin result.notes:
          result.notes.add(n)

proc nimSlugLit(s: string): string =
  ## `"..."` literal for slugs and client keys, which are `[a-z0-9-./]`;
  ## anything else fails loudly rather than emitting a bad literal.
  for c in s:
    if c notin {'a' .. 'z', '0' .. '9', '-', '.', '/'}:
      raise newException(ValueError,
        "caniemail-data.json: unexpected characters in '" & s & "'")
  "\"" & s & "\""

proc nimTextLit(s: string): string =
  ## `"..."` literal for free-text provenance (URLs, dates, hashes).
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    else: result.add c
  result.add "\""

proc generateSupportModule*(dataJson, pinJson: string): string =
  ## Returns the full bytes of `caniemail_data.nim` for the pinned inputs.
  let pin = parsePin(pinJson)
  let root = parseJson(dataJson)
  if root["api_version"].str != pin.apiVersion:
    raise newException(ValueError,
      "caniemail-data.json api_version '" & root["api_version"].str &
      "' does not match pin '" & pin.apiVersion & "'")
  if root["last_update_date"].str != pin.dataDate:
    raise newException(ValueError,
      "caniemail-data.json last_update_date '" &
      root["last_update_date"].str & "' does not match pin '" &
      pin.dataDate & "'")

  var slugs: seq[string] = @[]
  var keySet: seq[string] = @[]
  for feat in root["data"].items:
    slugs.add(feat["slug"].str)
    for fam, plats in feat["stats"].pairs:
      for plat in plats.keys:
        let key = fam & "/" & plat
        if key notin keySet:
          keySet.add(key)
  slugs.sort()
  keySet.sort()
  for key in keySet:
    discard spanRule(key) # a key with no rule fails, used or not

  # Worst over each key's span (see `spanRules` and `spannedResults`).
  var values = newSeq[seq[char]](slugs.len)
  var noteRefs: seq[array[3, int]] = @[]
  for fi, slug in slugs:
    values[fi] = newSeq[char](keySet.len)
    var feat: JsonNode = nil
    for f in root["data"].items:
      if f["slug"].str == slug:
        feat = f
        break
    for ci, key in keySet:
      let slash = key.find('/')
      let vers =
        try: feat["stats"][key[0 ..< slash]][key[slash + 1 .. ^1]]
        except KeyError: nil
      if vers == nil or vers.len == 0:
        values[fi][ci] = 'u'
      else:
        let (val, notes) = reduceSpan(spannedResults(key, vers))
        values[fi][ci] = val
        for note in notes:
          noteRefs.add([fi, ci, note])

  proc encode(v: char): string =
    case v
    of 'u': "0"
    of 'y': "1"
    of 'n': "2"
    of 'a': "3"
    else: raise newException(ValueError, "unreachable")

  var res = ""
  res.add "## isonim_email/support/caniemail_data.nim — GENERATED, do not edit.\n"
  res.add "##\n"
  res.add "## Pinned caniemail support snapshot:\n"
  res.add "##   source:      " & pin.source & "\n"
  res.add "##   repo:        " & pin.repo & "\n"
  res.add "##   commit:      " & pin.commit & "\n"
  res.add "##   commit date: " & pin.commitDate & "\n"
  res.add "##   fetch date:  " & pin.fetchDate & "\n"
  res.add "##   data date:   " & pin.dataDate & " (api " & pin.apiVersion & ")\n"
  res.add "##   sha256:      " & pin.sha256 & "\n"
  res.add "##   licence:     " & pin.license & "\n"
  res.add "##\n"
  res.add "## Generated by `just support-snapshot`\n"
  res.add "## (tools/support-snapshot/snapshot.nim). Reduction: the worst\n"
  res.add "## test result over the versions each (feature, family/platform) key\n"
  res.add "## spans: the latest result, except for these keys, which span\n"
  res.add "## every result labelled in use (as of " & spanRulesAsOf & "):\n"
  for r in spanRules:
    if r.kind == spanInUse:
      var floors: seq[string] = @[]
      if r.minVersion != "": floors.add("version " & r.minVersion)
      if r.minYear != 0: floors.add("year " & $r.minYear)
      floors.add("retests from " & r.minDate)
      res.add "##   " & r.key & ": " & floors.join(", ") & "\n"
  res.add "## Values y = yes, n = no, a = partial, u = unknown/absent, with the\n"
  res.add "## caniemail note ids of the spanned results carrying that value.\n"
  res.add "##\n"
  res.add "## Re-generation is a deliberate PR: the diff shows which support\n"
  res.add "## values changed. `tests/t3_snapshot_reproducible.nim` asserts this\n"
  res.add "## file is byte-identical to what the pinned inputs produce.\n"
  res.add "\n"
  res.add "import ../target\n"
  res.add "\n"
  res.add "## The client families an edit to this module can change: read by\n"
  res.add "## the capture CLI to pick the families of an `--affected` run.\n"
  res.add "const affects*: set[ClientFamily] = allFamilies\n"
  res.add "\n"
  res.add "type SupportValue* = enum\n"
  res.add "  svUnknown, svYes, svNo, svPartial\n"
  res.add "\n"
  res.add "const caniemailSource* = " & nimTextLit(pin.source) & "\n"
  res.add "const caniemailCommit* = " & nimTextLit(pin.commit) & "\n"
  res.add "const caniemailCommitDate* = " & nimTextLit(pin.commitDate) & "\n"
  res.add "const caniemailFetchDate* = " & nimTextLit(pin.fetchDate) & "\n"
  res.add "const caniemailDataDate* = " & nimTextLit(pin.dataDate) & "\n"
  res.add "const caniemailApiVersion* = " & nimTextLit(pin.apiVersion) & "\n"
  res.add "const caniemailSha256* = " & nimTextLit(pin.sha256) & "\n"
  res.add "\n"
  res.add "const caniemailFeatureCount* = " & $slugs.len & "\n"
  res.add "const caniemailClientCount* = " & $keySet.len & "\n"
  res.add "\n"
  res.add "const caniemailFeatures*: array[" & $slugs.len & ", string] = [\n"
  for i, slug in slugs:
    res.add "  " & nimSlugLit(slug)
    res.add(if i < slugs.len - 1: ",\n" else: "\n")
  res.add "]\n"
  res.add "\n"
  res.add "const caniemailClients*: array[" & $keySet.len & ", string] = [\n"
  for i, key in keySet:
    res.add "  " & nimSlugLit(key)
    res.add(if i < keySet.len - 1: ",\n" else: "\n")
  res.add "]\n"
  res.add "\n"
  res.add "## One row per feature (`0` = u, `1` = y, `2` = n, `3` = a).\n"
  res.add "const caniemailSupport*: array[" & $slugs.len & ", array[" &
    $keySet.len & ", int]] = [\n"
  for fi, slug in slugs:
    res.add "  [" & values[fi].mapIt(encode(it)).join(", ") & "], # " &
      slug & "\n"
  res.add "]\n"
  res.add "\n"
  res.add "## Note references as (feature, client, note) triples, sorted.\n"
  res.add "const caniemailNoteRefs*: array[" & $noteRefs.len &
    ", array[3, int]] = [\n"
  for i, r in noteRefs:
    res.add "  [" & $r[0] & ", " & $r[1] & ", " & $r[2] & "]"
    res.add(if i < noteRefs.len - 1: ",\n" else: "\n")
  res.add "]\n"
  res.add "\n"
  res.add "proc featureIndex*(slug: string): int =\n"
  res.add "  ## Index of `slug` in `caniemailFeatures`, or -1 when absent.\n"
  res.add "  for i, s in caniemailFeatures:\n"
  res.add "    if s == slug:\n"
  res.add "      return i\n"
  res.add "  -1\n"
  res.add "\n"
  res.add "proc clientIndex*(key: string): int =\n"
  res.add "  ## Index of `key` (`family/platform`) in `caniemailClients`, or -1.\n"
  res.add "  for i, k in caniemailClients:\n"
  res.add "    if k == key:\n"
  res.add "      return i\n"
  res.add "  -1\n"
  res.add "\n"
  res.add "proc supportAt*(fi, ci: int): SupportValue =\n"
  res.add "  ## Support value at a feature/client index pair.\n"
  res.add "  case caniemailSupport[fi][ci]\n"
  res.add "  of 1: svYes\n"
  res.add "  of 2: svNo\n"
  res.add "  of 3: svPartial\n"
  res.add "  else: svUnknown\n"
  res.add "\n"
  res.add "proc notesAt*(fi, ci: int): seq[int] =\n"
  res.add "  ## Note ids at a feature/client index pair (empty = none).\n"
  res.add "  for r in caniemailNoteRefs:\n"
  res.add "    if r[0] == fi and r[1] == ci:\n"
  res.add "      result.add(r[2])\n"
  res.add "\n"
  res.add "proc supportFor*(slug, key: string): tuple[value: SupportValue, notes: seq[int]] =\n"
  res.add "  ## Support value and note ids for a feature slug and client key.\n"
  res.add "  ## Unknown slugs or keys read as `(svUnknown, @[])`.\n"
  res.add "  let fi = featureIndex(slug)\n"
  res.add "  let ci = clientIndex(key)\n"
  res.add "  if fi < 0 or ci < 0:\n"
  res.add "    return (svUnknown, @[])\n"
  res.add "  (supportAt(fi, ci), notesAt(fi, ci))\n"
  res

when isMainModule:
  import std/os
  if paramCount() != 3:
    quit "usage: snapshot <caniemail-data.json> <snapshot.pin.json> <out.nim>", 1
  let dataJson = readFile(paramStr(1))
  let pinJson = readFile(paramStr(2))
  writeFile(paramStr(3), generateSupportModule(dataJson, pinJson))
