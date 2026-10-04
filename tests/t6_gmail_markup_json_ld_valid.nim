# rule: R-SND-07
# rule: R-SND-08
## The emitted Gmail markup is valid JSON-LD for the schema.org types it
## names (`test_gmail_markup_json_ld_valid`): every block the reference
## stories write, and a block of every type and action with every
## property set, parses, and is checked structurally against the pinned
## schema.org vocabulary (release 30.1, `$ISONIM_EMAIL_SCHEMAORG`, a
## hash-pinned fetch in `flake.nix`; nothing is fetched here):
##
## - every `@type` is a schema.org class;
## - every property is a schema.org property whose domain includes the
##   node's type or one of its superclasses;
## - every nested object's `@type` is in the property's range (or a
##   subclass of it), and every string value fits a data type or an
##   enumeration in the range: a `URL` is an absolute URL, a `DateTime`
##   and a `Date` have ISO 8601's forms, an enumeration's value names one
##   of its members.
##
## Gmail's one-click actions use `SaveAction`, `handler` and
## `HttpActionHandler`, which Gmail's markup reference defines and
## schema.org does not; they are the only additions to the vocabulary,
## written below from that reference (SaveAction: an Action;
## HttpActionHandler: `url`, a URL; `handler`: on Action).
##
## It also checks that the reference stories carrying markup render as
## their reference emails do, but for the head's script elements, with
## the same plain-text part.
##
## C backend only: reads the vocabulary file.
import std/[json, os, sets, strutils, tables, unittest]
import isonim_email
import stories/story_kit
import reference_set
import gmail_markup_email
import stories/seed_markup
import stories/seed_reference

type Vocabulary = object
  classes: Table[string, seq[string]]   ## class -> direct superclasses
  domains: Table[string, seq[string]]   ## property -> domainIncludes
  ranges: Table[string, seq[string]]    ## property -> rangeIncludes
  members: Table[string, string]        ## enumeration member -> its type
  superseded: HashSet[string]           ## properties with supersededBy

proc ids(n: JsonNode): seq[string] =
  ## The `schema:` names an `{"@id": …}` value or array names.
  if n == nil:
    return
  let items = if n.kind == JArray: n.getElems() else: @[n]
  for it in items:
    let id = it{"@id"}.getStr
    if id.startsWith("schema:"):
      result.add(id["schema:".len .. ^1])

proc loadVocabulary(path: string): Vocabulary =
  let root = parseFile(path)
  for node in root["@graph"]:
    let id = node{"@id"}.getStr
    if not id.startsWith("schema:"):
      continue
    let name = id["schema:".len .. ^1]
    var types: seq[string] = @[]
    let t = node{"@type"}
    if t != nil:
      if t.kind == JArray:
        for x in t: types.add(x.getStr)
      else:
        types.add(t.getStr)
    if "rdfs:Class" in types:
      result.classes[name] = ids(node{"rdfs:subClassOf"})
    if "rdf:Property" in types:
      result.domains[name] = ids(node{"schema:domainIncludes"})
      result.ranges[name] = ids(node{"schema:rangeIncludes"})
      if node{"schema:supersededBy"} != nil:
        result.superseded.incl(name)
    for x in types:
      if x.startsWith("schema:"):
        # An instance of a schema.org class: an enumeration member.
        result.members[name] = x["schema:".len .. ^1]
  # Gmail's additions (Gmail markup reference, one-click actions):
  # SaveAction (extends Action, no properties of its own),
  # HttpActionHandler (its `url`; modelled under Thing, which holds
  # schema.org's `url`) and Action's `handler`.
  result.classes["SaveAction"] = @["Action"]
  result.classes["HttpActionHandler"] = @["Thing"]
  result.domains["handler"] = @["Action"]
  result.ranges["handler"] = @["HttpActionHandler"]

proc ancestors(v: Vocabulary; cls: string): HashSet[string] =
  ## `cls` and every class above it.
  result = initHashSet[string]()
  var todo = @[cls]
  while todo.len > 0:
    let c = todo.pop()
    if c in result:
      continue
    result.incl(c)
    for s in v.classes.getOrDefault(c, @[]):
      todo.add(s)

proc shaped(s, pattern: string; at = 0): bool =
  ## `s[at ..]` starts with `pattern`, where `d` is any digit and every
  ## other character itself.
  if at + pattern.len > s.len:
    return false
  for i, c in pattern:
    if c == 'd':
      if s[at + i] notin Digits: return false
    elif s[at + i] != c:
      return false
  true

proc xsdDate(s: string): bool =
  ## schema.org `Date`, ISO 8601's calendar date (independent of the
  ## library's own check).
  s.len == 10 and shaped(s, "dddd-dd-dd")

proc xsdDateTime(s: string): bool =
  ## schema.org `DateTime`: `[-]CCYY-MM-DDThh:mm[:ss[.f+]](Z|±hh:mm)` as
  ## its definition writes it, the zone required (Gmail's examples
  ## always give one).
  if not shaped(s, "dddd-dd-ddTdd:dd"):
    return false
  var i = 16
  if shaped(s, ":dd", i):
    i += 3
    if i < s.len and s[i] == '.':
      inc i
      let start = i
      while i < s.len and s[i] in Digits: inc i
      if i == start: return false
  (i == s.len - 1 and s[i] == 'Z') or
    (s.len == i + 6 and s[i] in {'+', '-'} and shaped(s, "dd:dd", i + 1))

proc isAbsoluteUrl(s: string): bool =
  let c = s.find("://")
  c > 0 and s.len > c + 3 and ' ' notin s

proc checkValue(v: Vocabulary; path: string; ranges: seq[string];
    value: JsonNode; problems: var seq[string])

proc checkNode(v: Vocabulary; path: string; node: JsonNode;
    problems: var seq[string]) =
  ## One typed object: its type a class, each property in its domain,
  ## each value in the property's range.
  let t = node{"@type"}.getStr
  if t notin v.classes:
    problems.add(path & ": @type '" & t & "' is not a schema.org class")
    return
  let above = ancestors(v, t)
  for key, value in node.pairs:
    if key in ["@type", "@context"]:
      continue
    let p = path & "." & key
    if key notin v.domains:
      problems.add(p & ": not a schema.org property")
      continue
    var inDomain = false
    for d in v.domains[key]:
      if d in above:
        inDomain = true
    if not inDomain:
      problems.add(p & ": not a property of " & t & " (its domain: " &
        v.domains[key].join(", ") & ")")
    checkValue(v, p, v.ranges[key], value, problems)

proc checkValue(v: Vocabulary; path: string; ranges: seq[string];
    value: JsonNode; problems: var seq[string]) =
  case value.kind
  of JArray:
    for i, x in value.getElems():
      checkValue(v, path & "[" & $i & "]", ranges, x, problems)
  of JObject:
    let t = value{"@type"}.getStr
    var fits = false
    for r in ranges:
      if r in ancestors(v, t):
        fits = true
    if not fits:
      problems.add(path & ": a " & t & " is not in the range (" &
        ranges.join(", ") & ")")
    checkNode(v, path, value, problems)
  of JString:
    let s = value.getStr
    var fits = false
    # Where the range has an enumeration (paymentStatus: PaymentStatusType
    # or Text), the library writes a member, so the value must name one:
    # stricter than schema.org's Text, which would accept anything.
    var enumerated = false
    for r in ranges:
      if "Enumeration" in ancestors(v, r):
        enumerated = true
    for r in ranges:
      if enumerated and "Enumeration" notin ancestors(v, r):
        continue
      case r
      of "Text":
        fits = true
      of "URL":
        if isAbsoluteUrl(s): fits = true
      of "DateTime":
        if xsdDateTime(s): fits = true
      of "Date":
        if xsdDate(s): fits = true
      of "Number":
        try:
          discard parseFloat(s)
          fits = true
        except ValueError:
          discard
      else:
        # An enumeration: the value names a member of the range, by name
        # or by its schema.org IRI. An object type (an Organization)
        # given as a string does not fit.
        let name = if s.startsWith("http://schema.org/"):
            s["http://schema.org/".len .. ^1] else: s
        if v.members.getOrDefault(name, "") in ancestors(v, r) and
            v.members.getOrDefault(name, "").len > 0:
          fits = true
    if not fits:
      problems.add(path & ": '" & s & "' fits none of " & ranges.join(", "))
  else:
    problems.add(path & ": a " & $value.kind & " where schema.org has " &
      ranges.join(", "))

proc validate(v: Vocabulary; jsonLd: string): seq[string] =
  ## Parses one block and checks it; the problems found, none when valid.
  let node = parseJson(jsonLd)
  if node{"@context"}.getStr != "http://schema.org":
    result.add("@context is '" & node{"@context"}.getStr & "'")
  checkNode(v, node{"@type"}.getStr, node, result)

const openTag = "<script type=\"application/ld+json\">"

proc scripts(html: string): seq[string] =
  var at = 0
  while true:
    let a = html.find(openTag, at)
    if a < 0:
      break
    let b = html.toLowerAscii().find("</script", a + openTag.len)
    result.add(html[a + openTag.len ..< b])
    at = b

proc fullBlocks(): seq[GmailMarkup] =
  ## A block of every type and action, every property set.
  @[gmailMarkup(EmailMessageMarkup(
      action: MarkupAction(kind: maView, name: "View order",
        url: "https://example.com/orders/1"),
      description: "Order 1",
      publisher: MarkupOrganization(name: "Acme",
        url: "https://example.com/"))),
    gmailMarkup(EmailMessageMarkup(action: MarkupAction(kind: maConfirm,
      name: "Approve", handlerUrl: "https://example.com/approve?t=1"))),
    gmailMarkup(EmailMessageMarkup(action: MarkupAction(kind: maSave,
      name: "Save coupon", handlerUrl: "https://example.com/save?t=1"))),
    gmailMarkup(InvoiceMarkup(
      provider: MarkupParty(name: "Acme"),
      totalPaymentDue: MarkupPrice(price: "70.00", priceCurrency: "USD"),
      minimumPaymentDue: MarkupPrice(price: "$20.00", priceCurrency: "USD"),
      paymentDue: "2026-11-01T08:00:00+00:00",
      scheduledPaymentDate: "2026-10-30", paymentStatus: psPastDue,
      accountId: "1", confirmationNumber: "2", paymentMethodId: "4242",
      customer: MarkupParty(name: "Ada"), orderNumber: "7")),
    gmailMarkup(ParcelDeliveryMarkup(
      deliveryAddress: MarkupAddress(name: "Home",
        streetAddress: "1 Example St", addressLocality: "Springfield",
        addressRegion: "IL", addressCountry: "US", postalCode: "62701"),
      originAddress: MarkupAddress(name: "Warehouse",
        streetAddress: "2 Example St", addressLocality: "Shelbyville",
        addressRegion: "IL", addressCountry: "US", postalCode: "62565"),
      expectedArrivalFrom: "2026-10-06T09:00:00-05:00",
      expectedArrivalUntil: "2026-10-07T18:00:00-05:00",
      carrier: MarkupOrganization(name: "Acme Express",
        url: "https://express.example.com/"),
      itemShipped: @[MarkupProduct(name: "Print", url: "https://example.com/p",
        image: "https://example.com/p.png", sku: "P-1", description: "A3"),
        MarkupProduct(name: "Frame")],
      trackingNumber: "AE1", trackingUrl: "https://example.com/track/1",
      orderNumber: "1", merchant: MarkupParty(name: "Acme"),
      orderStatus: osDelivered))]

let vocabPath = getEnv("ISONIM_EMAIL_SCHEMAORG")

suite "Gmail markup against schema.org":
  test "test_gmail_markup_json_ld_valid":
    # rule: R-SND-07
    # The pinned vocabulary is required: no skip path.
    check vocabPath.len > 0
    check fileExists(vocabPath)
    let v = loadVocabulary(vocabPath)
    check v.classes.len > 500 # the whole vocabulary, not a stub
    # The validator's controls: it refuses an unknown type, a property
    # outside its type's domain, an object outside the range, a string
    # outside a data type and an unknown enumeration member.
    let good = """{"@context":"http://schema.org","@type":"Invoice",""" &
      """"provider":{"@type":"Organization","name":"A"}}"""
    check validate(v, good).len == 0
    for bad in [
        """{"@context":"http://schema.org","@type":"Bill"}""",
        """{"@context":"http://schema.org","@type":"Invoice","orderNumber":"7"}""",
        """{"@context":"http://schema.org","@type":"Invoice","provider":{"@type":"PostalAddress"}}""",
        """{"@context":"http://schema.org","@type":"Invoice","paymentDue":"soon"}""",
        """{"@context":"http://schema.org","@type":"Invoice","paymentStatus":"PaymentSoon"}""",
        """{"@context":"http://schema.org","@type":"ParcelDelivery","trackingUrl":"track/1"}""",
        """{"@context":"https://example.com","@type":"Invoice"}"""]:
      checkpoint(bad)
      check validate(v, bad).len > 0
    # Every type and action, every property set.
    for m in fullBlocks():
      check checkGmailMarkup(m).len == 0
      let problems = validate(v, toJsonLd(m))
      checkpoint(toJsonLd(m) & "\n" & problems.join("\n"))
      check problems.len == 0
    # The superseded properties Gmail documents are still schema.org's.
    check "carrier" in v.superseded
    check "paymentDue" in v.superseded

  test "the stories' blocks are valid and their messages unchanged":
    # rule: R-SND-07
    # rule: R-SND-08
    check fileExists(vocabPath)
    let v = loadVocabulary(vocabPath)
    proc reference(name: string): RenderedEmail =
      for e in referenceEmails():
        if e.name == name:
          return renderReference(e)
      raise newException(KeyError, "no reference email " & name)
    for (marked, plain, blocks) in [
        (renderReceiptMarkup(), reference("receiptTypical"),
          receiptMarkup()),
        (renderShippingMarkup(), reference("shippingChinese"),
          shippingMarkup())]:
      check not hasErrors(marked.diagnostics)
      let found = scripts(marked.html)
      check found.len == blocks.len
      for i, s in found:
        check s == toJsonLd(blocks[i])
        check '<' notin s
        let problems = validate(v, s)
        checkpoint(s & "\n" & problems.join("\n"))
        check problems.len == 0
      # Invisible: the HTML without its blocks is the reference email's,
      # and so is the text part.
      var stripped = marked.html
      for s in found:
        stripped = stripped.replace(openTag & s & "</script>", "")
      check stripped == plain.html
      check marked.text == plain.text
