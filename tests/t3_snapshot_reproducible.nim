## Re-running the generator on the pinned snapshot yields a
## byte-identical Nim table, and the table reads back as the source data.
##
## C backend only: the generator reads JSON object insertion order, which
## the JS backend does not preserve (integer-like keys iterate numerically
## there), so byte-identity only holds for C generation.
import std/[strutils, unittest]
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
    # Latest-per-key reduction: last test result wins.
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
