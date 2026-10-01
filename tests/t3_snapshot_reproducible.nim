## Re-running the generator on the pinned snapshot yields a
## byte-identical Nim table, the vendored payload hashes to the pinned
## sha256, and the table reads back as the source data — including the
## worst-over-versions reduction for a client whose versions disagree.
##
## C backend only: the generator reads JSON object insertion order, which
## the JS backend does not preserve (integer-like keys iterate numerically
## there), so byte-identity only holds for C generation.
import std/[json, strutils, unittest]
import isonim_email
import "../tools/support-snapshot/snapshot"

const dataJson = staticRead("../tools/support-snapshot/caniemail-data.json")
const pinJson = staticRead("../tools/support-snapshot/snapshot.pin.json")
const committed =
  staticRead("../src/isonim_email/support/caniemail_data.nim")

suite "snapshot generation reproducible":
  test "test_snapshot_generation_reproducible":
    let generated = generateSupportModule(dataJson, pinJson)
    check generated == committed

  test "the vendored payload hashes to the pinned sha256":
    # The generator never hashes its input (the regeneration recipe
    # does, in shell); this is the check that a payload edited in place
    # — one byte is enough — no longer matches its pin.
    let pin = parsePin(pinJson)
    check sha256Hex(dataJson) == pin.sha256
    check caniemailSha256 == sha256Hex(dataJson)

  test "pin carries the fetch provenance":
    let pin = parsePin(pinJson)
    check pin.source == "https://www.caniemail.com/api/data.json"
    check pin.repo == "https://github.com/hteumeuleu/caniemail"
    check pin.commit == "cb8109c3f8658e003aa064b47a71b232ddc28d39"
    check pin.commitDate == "2026-09-16"
    check pin.fetchDate == "2026-09-27"
    check pin.dataDate == "2026-09-16 13:05:00 +0000"
    check pin.apiVersion == "1.0.4"
    check pin.sha256 ==
      "7328f873fae3bb24455d10bf3005464b2af12cbbcc5b54da51683d4911235628"
    check "MIT" in pin.license
    # The generated header records the same provenance.
    check pin.commit in committed
    check pin.sha256 in committed
    check pin.fetchDate in committed
    # And the module exposes it as constants.
    check caniemailCommit == pin.commit
    check caniemailSha256 == pin.sha256
    check caniemailFetchDate == pin.fetchDate
    check caniemailDataDate == pin.dataDate
    check caniemailApiVersion == pin.apiVersion

  test "a mismatched pin fails generation":
    let badPin = pinJson.replace("1.0.4", "9.9.9")
    expect ValueError:
      discard generateSupportModule(dataJson, badPin)
    let badDate = pinJson.replace("13:05:00", "00:00:00")
    expect ValueError:
      discard generateSupportModule(dataJson, badDate)

  test "support cells parse, including multi-note cells":
    let plain = parseSupportCell("y")
    check plain.value == 'y'
    check plain.notes == newSeq[int]()
    let noted = parseSupportCell("n #1")
    check noted.value == 'n'
    check noted.notes == @[1]
    let multi = parseSupportCell("a #6 #7")
    check multi.value == 'a'
    check multi.notes == @[6, 7]
    expect ValueError:
      discard parseSupportCell("bogus")
    expect ValueError:
      discard parseSupportCell("y oops")

  test "the table reads back as the source data":
    check caniemailFeatureCount == 308
    check caniemailClientCount == 48
    # One result per key, or every result agreeing: the value as is.
    let wordRadius = supportFor("css-border-radius", "outlook/windows")
    check wordRadius.value == svNo
    check wordRadius.notes == @[1]
    check supportFor("css-border-radius", "gmail/ios").value == svYes
    let yahooRadius = supportFor("css-border-radius", "yahoo/ios")
    check yahooRadius.value == svPartial
    check yahooRadius.notes == @[2]
    let gmailFlex = supportFor("css-display-flex", "gmail/ios")
    check gmailFlex.value == svPartial
    check gmailFlex.notes == @[1]
    check supportFor("css-display-flex", "outlook/windows").value == svNo
    check supportFor("amp", "apple-mail/macos").value == svNo
    check supportFor("amp", "gmail/ios").value == svYes
    # Unknown slugs or keys abstain.
    check supportFor("no-such-feature", "gmail/ios").value == svUnknown
    check supportFor("amp", "no-such-client").value == svUnknown
    check featureIndex("amp") >= 0
    check featureIndex("no-such-feature") == -1
    check clientIndex("gmail/ios") >= 0
    check clientIndex("no-such-client") == -1

  test "every family maps to keys, and every mapped key exists":
    for f in ClientFamily:
      check familyClients(f).len > 0
      for key in familyClients(f):
        check clientIndex(key) >= 0
    # outlook-com stands in for new Outlook (no separate column).
    check familyClients(cfOutlookWeb) == @["outlook/outlook-com"]
    # Windows Mail is excluded (retired end of 2024).
    check not isMappedClient("outlook/windows-mail")
    # Untracked webmails have no family; profiles spread them as "others".
    check not isMappedClient("orange/desktop-webmail")
    check not isMappedClient("gmx/desktop-webmail")
    check isMappedClient("gmail/ios")
    check isMappedClient("thunderbird/windows")

  test "family support is the worst of its keys":
    check familySupport("css-border-radius", cfOutlookWord).value == svNo
    check familySupport("css-border-radius", cfYahoo).value == svPartial
    check familySupport("css-border-radius", cfApple).value == svYes
    check familySupport("no-such-feature", cfApple).value == svUnknown
    let outlook = familySupport("css-border-radius", cfOutlookWord)
    check outlook.witnesses == @["outlook/windows"]
    check outlook.notes == @[1]
    # Partial counts as supported for lint: only full gaps warn.
    check unsupportedFamilies("css-border-radius") == {cfOutlookWord}
    check unsupportedFamilies("css-display-flex") == {cfOutlookWord}
    check unsupportedFamilies("css-background-color") == {}
    check unsupportedFamilies("no-such-feature") == {}

  test "a client whose versions disagree reads as its worst spanned version":
    # Outlook for Windows 2016 lacks what 2019 has; the latest-only
    # reduction read all three as supported or partial.
    for slug in ["image-svg", "image-base64", "css-max-width"]:
      check supportFor(slug, "outlook/windows").value == svNo
      check familySupport(slug, cfOutlookWord).value == svNo
      check cfOutlookWord in unsupportedFamilies(slug)
    # The notes are those of the results carrying the worst value: 2019's
    # partial note no longer applies once 2016's `n` decides the value,
    # and a partial shared by 2016 and 2019 keeps both versions' notes.
    check supportFor("image-svg", "outlook/windows").notes == newSeq[int]()
    check supportFor("css-max-width", "outlook/windows").notes ==
      newSeq[int]()
    let fontFace = supportFor("css-at-font-face", "outlook/windows")
    check fontFace.value == svPartial
    check fontFace.notes == @[4, 5]
    # An auto-updating key keeps its latest result: Gmail's retests
    # disagree too, and the latest one decides.
    check supportFor("css-display-flex", "gmail/ios").value == svPartial

  test "the span reduction, on hand-written results":
    let word = parseJson("""{"2007": "n", "2013": "n #3", "2016": "a #2",
      "2019": "y", "2023-12": "a #4"}""")
    # Only 2016 and later count for outlook/windows.
    check spannedResults("outlook/windows", word) ==
      @["a #2", "y", "a #4"]
    let wordVal = reduceSpan(spannedResults("outlook/windows", word))
    check wordVal.value == 'a'
    check wordVal.notes == @[2, 4]
    # Any other key: the last result only, whatever came before.
    check spannedResults("gmail/ios", word) == @["a #4"]
    check reduceSpan(@["y", "n #1", "a #2"]) == ('n', @[1])
    check reduceSpan(@["y", "a #2", "y"]) == ('a', @[2])
    check reduceSpan(@["u", "y"]) == ('y', newSeq[int]())
    check reduceSpan(@["u"]) == ('u', newSeq[int]())
    # An in-use span with nothing in it falls back to the latest result,
    # the nearest evidence there is (never to `u`).
    check spannedResults("outlook/windows",
      parseJson("""{"2010": "n", "2013": "y"}""")) == @["y"]
    # A label the rule cannot place fails generation rather than guessing:
    # no date/year/version shape, a version where the rule has no version
    # floor, a product year where it has no year floor.
    expect ValueError:
      discard spannedResults("outlook/windows",
        parseJson("""{"2016": "y", "next": "y"}"""))
    expect ValueError:
      discard spannedResults("outlook/windows",
        parseJson("""{"2016": "y", "16.0": "y"}"""))
    expect ValueError:
      discard spannedResults("apple-mail/ios",
        parseJson("""{"2019": "y", "26": "y"}"""))

  test "versioned and OS-bundled keys span every version in use":
    # iOS 18.7's Mail lacks the command attribute 26.9 has; 18 is still
    # in use, so the key (and the Apple family) reads `n`.
    check supportFor("html-command-attribute", "apple-mail/ios").value ==
      svNo
    check familySupport("html-command-attribute", cfApple).value == svNo
    # macOS Mail 16-20 lack accent-color, which 21 has.
    check supportFor("css-accent-color", "apple-mail/macos").value == svNo
    # Outlook 2019 for Mac lacks HEIF images the current build shows.
    check supportFor("image-heif", "outlook/macos").value == svNo
    # Results below the floors drop out: iOS 17's `n` and a pre-18
    # retest do not count, 18.x, 26 and a retest after 18's release do.
    let ios = parseJson("""{"16": "n", "17.4": "n #1", "2024-03": "n",
      "18.3.2": "a #2", "2024-10": "y", "26.9": "y"}""")
    check spannedResults("apple-mail/ios", ios) == @["a #2", "y", "y"]
    check reduceSpan(spannedResults("apple-mail/ios", ios)) == ('a', @[2])
    # Thunderbird: a beta and the 128 ESR are out of use, 140+ counts.
    let tb = parseJson("""{"128.9.0": "n", "137.0b3": "n", "149": "a #1",
      "152": "y"}""")
    check spannedResults("thunderbird/macos", tb) == @["a #1", "y"]
    # Outlook for Mac: product year 2019 on, builds from 16.78 on.
    let olm = parseJson("""{"2016": "n", "2019": "a #3", "16.57": "n",
      "16.80": "y", "2023-01": "n", "2023-12": "y"}""")
    check spannedResults("outlook/macos", olm) == @["a #3", "y", "y"]
    # An auto-updating key still reads its latest result only.
    check spannedResults("samsung-email/android", ios) == @["y"]

  test "a label exactly at a floor is in use, one just below it is not":
    # Each label carries its own note, so the spanned list names exactly
    # which labels counted. The at-floor results are the worst ones: an
    # exclusive floor would drop them and lift the reduced value, and a
    # floor one step too low would admit the just-below results.
    # Version floor 18, dated floor 2024-09.
    let ios = parseJson("""{"17.9": "n #1", "18": "n #2", "2024-08": "n #3",
      "2024-09": "a #4", "26": "y"}""")
    check spannedResults("apple-mail/ios", ios) == @["n #2", "a #4", "y"]
    check reduceSpan(spannedResults("apple-mail/ios", ios)) == ('n', @[2])
    # Version floor 16, met by "16.0" as well as by "16".
    let mac = parseJson("""{"15.9": "n #1", "16.0": "n #2", "16": "a #3",
      "2024-08": "n #4", "2024-09": "a #5", "26": "y"}""")
    check spannedResults("apple-mail/macos", mac) ==
      @["n #2", "a #3", "a #5", "y"]
    check reduceSpan(spannedResults("apple-mail/macos", mac)) == ('n', @[2])
    # Version floor 140, dated floor 2025-07.
    let tb = parseJson("""{"139.0.1": "n #1", "140": "n #2", "2025-06": "n #3",
      "2025-07": "a #4", "153": "y"}""")
    check spannedResults("thunderbird/windows", tb) == @["n #2", "a #4", "y"]
    check reduceSpan(spannedResults("thunderbird/windows", tb)) ==
      ('n', @[2])
    # Build floor 16.78, year floor 2019, dated floor 2023-10.
    let olm = parseJson("""{"2018": "n #1", "2019": "n #2", "16.77": "n #3",
      "16.78": "n #4", "2023-09": "n #5", "2023-10": "a #6", "16.80": "y"}""")
    check spannedResults("outlook/macos", olm) ==
      @["n #2", "n #4", "a #6", "y"]
    check reduceSpan(spannedResults("outlook/macos", olm)) ==
      ('n', @[2, 4])
    # Year floor 2016, dated floor 2016-01.
    let word = parseJson("""{"2015": "n #1", "2016": "n #2", "2015-12": "n #3",
      "2016-01": "a #4", "2019": "y"}""")
    check spannedResults("outlook/windows", word) == @["n #2", "a #4", "y"]
    check reduceSpan(spannedResults("outlook/windows", word)) == ('n', @[2])
    # A dated label at the floor month is the only worst result.
    let dated = parseJson("""{"2024-08": "n #1", "2024-09": "n #2",
      "26": "y"}""")
    check reduceSpan(spannedResults("apple-mail/ios", dated)) == ('n', @[2])

  test "every client key has a span rule, and an unknown key fails":
    for key in caniemailClients:
      check spanRule(key).key == key
      check spanRule(key).why.len > 0
    check spanRules.len == caniemailClients.len
    check spanRulesAsOf == "2026-10-01"
    expect ValueError:
      discard spanRule("newclient/desktop-webmail")
    expect ValueError:
      discard spannedResults("newclient/desktop-webmail",
        parseJson("""{"2026-01": "y"}"""))
    # Generation fails as a whole when the payload grows a key the table
    # does not name — even one whose results are all empty.
    let grown = dataJson.replace("\"stats\":{", "\"stats\":{" &
      "\"newclient\":{\"desktop-webmail\":{\"2026-01\":\"y\"}},")
    check grown != dataJson
    expect ValueError:
      discard generateSupportModule(grown, pinJson)
    let grownEmpty = dataJson.replace("\"stats\":{", "\"stats\":{" &
      "\"newclient\":{\"desktop-webmail\":{}},")
    check grownEmpty != dataJson
    expect ValueError:
      discard generateSupportModule(grownEmpty, pinJson)
