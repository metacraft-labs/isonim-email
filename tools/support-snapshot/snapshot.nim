## tools/support-snapshot/snapshot.nim — pinned caniemail fetch → Nim table.
##
## Reads the pinned `caniemail-data.json` snapshot plus `snapshot.pin.json`
## and generates `src/isonim_email/support/caniemail_data.nim`:
## a compile-time table of features × clients with support values `y`/`n`/
## `a` (partial) / `u` (unknown) plus note ids.
##
## Reduction rule: the latest test result per (feature, family/platform)
## key wins. `latest` means the LAST entry in the JSON object: caniemail
## appends new results (`_features/*.md` front matter shows the same
## order). Keys absent from a feature read as `u`. Both orders the output
## otherwise depends on (feature slugs, client keys) are sorted, so
## generation is a pure function of the two inputs —
## `tests/t3_snapshot_reproducible.nim` asserts the committed file is
## byte-identical to a fresh run.
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

  # Latest-per-key reduction: the last version entry wins (JSON objects
  # preserve insertion order, and caniemail appends new results).
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
        # `pairs` on a JObject yields insertion order; the last one wins.
        var last = ""
        for _, v in vers.pairs:
          last = v.str
        let (val, notes) = parseSupportCell(last)
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
  res.add "## (tools/support-snapshot/snapshot.nim). Reduction: the latest\n"
  res.add "## test result per (feature, family/platform) key; values y = yes,\n"
  res.add "## n = no, a = partial, u = unknown/absent, with caniemail note ids\n"
  res.add "## where the entry cites one.\n"
  res.add "##\n"
  res.add "## Re-generation is a deliberate PR: the diff shows which support\n"
  res.add "## values changed. `tests/t3_snapshot_reproducible.nim` asserts this\n"
  res.add "## file is byte-identical to what the pinned inputs produce.\n"
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
