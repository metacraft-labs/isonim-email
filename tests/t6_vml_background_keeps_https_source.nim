# rule: R-VML-04
## A band's VML background keeps its https source when a message embeds
## its images.
##
## Word paints a band's background image from the `src` of a `v:fill`,
## and that `src` is always an absolute https URL: embedded (`cid:`)
## images are never used for VML backgrounds (R-VML-04). The image
## strategy is `toMessage`'s parameter and the render never sees it, so
## the rule has to hold on the message as well as on the render. In a
## message built with `images = isEmbedded`, the `v:fill` still carries
## the URL the asset store published, wherever a caller reads the HTML:
## the message's stored HTML, `toParts`, and the `text/html` part of the
## bytes `toRfc5322` writes.
##
## - A fixed-height `mailHero` has its rectangle on the default target.
## - A `mailSection` has one under the target's `vmlFitToText`.
## - An image and a band may name the same asset. The image is then
##   embedded (R-MIME-11), which shows the strategy is in force, and the
##   band's `v:fill` still is not.
##
## Every test first checks the render it starts from (`publishedSource`):
## no error, the band's asset listed once with its bytes and its
## published https URL, and one `v:fill` carrying that URL. A render that
## is not so raises there, naming the setup, and the property is not
## read from it.
##
## No test double: the tree goes through `renderTree`, `toMessage`,
## `toParts` and `toRfc5322` as a caller runs them. The asset store is
## the library's in-memory `AssetStore` holding a real PNG; its default
## upload hook records the URL and sends nothing, the uploader being
## the sender's own.
##
## Backend-independent (tree building, pure passes and string code).
import std/[strutils, times, unittest]
import isonim_email

const pngBytes = staticRead("fixtures/t6_rgb.png")
  ## A real image: the embedded strategy sends an asset's bytes.

proc child(r: EmailRenderer; parent: EmailNode; tag: string;
    styles: openArray[(string, string)] = [];
    attrs: openArray[(string, string)] = []; text = ""): EmailNode =
  result = r.createElement(tag)
  for (k, v) in styles:
    r.setStyle(result, k, v)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)
  r.appendChild(parent, result)

proc newDoc(r: EmailRenderer): EmailNode =
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", "en")
  r.setAttribute(result, "dir", "ltr")
  r.setAttribute(result, "title", "Backgrounds")

proc addHero(r: EmailRenderer; doc: EmailNode) =
  ## A fixed-height hero whose background names the store's image: Word
  ## gets its rectangle on any target with Outlook output.
  let h = r.child(doc, "mailHero", [("background-color", "#223344"),
    ("background-image", "hero.png"), ("height", "300px")])
  discard r.child(h, "h1", [("color", "#ffffff")], text = "Spring sale")

proc heroDoc(): EmailNode =
  let r = EmailRenderer()
  result = r.newDoc()
  r.addHero(result)

proc sectionDoc(): EmailNode =
  ## A section whose background names the store's image: Word gets its
  ## rectangle only with `vmlFitToText` (R-VML-03).
  let r = EmailRenderer()
  result = r.newDoc()
  let s = r.child(result, "mailSection", [("background-color", "#334455"),
    ("background-image", "hero.png")])
  discard r.child(s, "h1", [("color", "#ffffff")], text = "Spring sale")

proc heroAndImageDoc(): EmailNode =
  ## The hero, then a section with a `mailImage` of the same asset.
  let r = EmailRenderer()
  result = r.newDoc()
  r.addHero(result)
  let s = r.child(result, "mailSection")
  discard r.child(s, "mailImage", attrs = [("src", "hero.png"),
    ("alt", "Spring sale")])

proc fitTarget(): EmailTarget =
  result = defaultTarget()
  result.vmlFitToText = true

proc imageStore(): AssetStore =
  let store = memoryAssetStore("https://cdn.example.com")
  store.put("hero.png", pngBytes)
  store

proc headers(): MessageHeaders =
  MessageHeaders(fromAddr: mailbox("", "a@example.com"),
    to: @[mailbox("", "b@example.com")], subject: "Spring sale",
    date: fromUnix(1767268800))

proc errorsOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    if d.severity == sevError:
      result.add(d.code & ": " & d.message)

proc sourceOf(html, tag: string): string =
  ## The `src` of the first `<tag …>` in `html`; "" when `html` has no
  ## such element, or the element has no `src`.
  let open = html.find("<" & tag & " ")
  if open < 0:
    return ""
  let close = html.find('>', open)
  if close < 0:
    return ""
  let element = html[open ..< close]
  const key = " src=\""
  let at = element.find(key)
  if at < 0:
    return ""
  let stop = element.find('"', at + key.len)
  if stop < 0:
    return ""
  element[at + key.len ..< stop]

proc fillSource(html: string): string =
  ## The source Word reads the band's background image from.
  sourceOf(html, "v:fill")

proc publishedSource(res: RenderedEmail): string =
  ## The URL the store published the band's image at, once the render is
  ## known to be the one each test starts from. Anything else is a
  ## failure of the setup: it raises here, before a message is built.
  let errors = errorsOf(res.diagnostics)
  doAssert errors.len == 0, "setup: the render reports " & $errors
  doAssert res.assets.len == 1, "setup: the render lists " &
    $res.assets.len & " assets, not the band's one"
  let asset = res.assets[0]
  doAssert asset.bytes == pngBytes,
    "setup: the listed asset does not carry the image's bytes"
  doAssert asset.url.startsWith("https://cdn.example.com/"),
    "setup: the asset was published at '" & asset.url & "'"
  doAssert res.html.count("<v:fill ") == 1, "setup: the render holds " &
    $res.html.count("<v:fill ") & " v:fill elements, not one"
  doAssert fillSource(res.html) == asset.url, "setup: the render's " &
    "v:fill reads '" & fillSource(res.html) & "', not the published URL"
  asset.url

proc qpDecode(s: string): string =
  ## The test's own quoted-printable reader (RFC 2045 §6.7): `=XX` is a
  ## byte, and `=` before a line break joins two lines.
  var i = 0
  while i < s.len:
    if s[i] == '=' and s.continuesWith("\r\n", i + 1):
      i += 3
    elif s[i] == '=' and i + 2 < s.len and s[i + 1] in HexDigits and
        s[i + 2] in HexDigits:
      result.add(chr(parseHexInt(s[i + 1 .. i + 2])))
      i += 3
    else:
      result.add(s[i])
      inc i

proc htmlPart(bytes: string): string =
  ## The decoded body of a serialised message's `text/html` part: from
  ## the blank line after the part's headers to the next delimiter of
  ## any boundary the message declares.
  let head = bytes.find("\r\nContent-Type: text/html;")
  doAssert head >= 0, "the message bytes hold no text/html part"
  let blank = bytes.find("\r\n\r\n", head + 2)
  doAssert blank >= 0, "the text/html part has no body"
  doAssert "\r\nContent-Transfer-Encoding: quoted-printable" in
    bytes[head ..< blank], "the text/html part is not quoted-printable"
  var stop = bytes.len
  const param = "boundary=\""
  var i = bytes.find(param)
  while i >= 0:
    let first = i + param.len
    let boundary = bytes[first ..< bytes.find('"', first)]
    let delimiter = bytes.find("\r\n--" & boundary, blank)
    if delimiter >= 0 and delimiter < stop:
      stop = delimiter
    i = bytes.find(param, first)
  qpDecode(bytes[blank + 4 ..< stop])

suite "a band's VML background in an embedded message (R-VML-04)":
  test "test_hero_fill_keeps_its_https_source_when_images_are_embedded":
    let res = renderTree(heroDoc(), assets = imageStore())
    let url = publishedSource(res)
    let msg = toMessage(res, headers(), images = isEmbedded)
    check fillSource(msg.rendered.html) == url
    check fillSource(toParts(msg).html) == url
    check fillSource(htmlPart(toRfc5322(msg, "t"))) == url

  test "test_section_fill_keeps_its_https_source_when_images_are_embedded":
    let res = renderTree(sectionDoc(), target = fitTarget(),
      assets = imageStore())
    let url = publishedSource(res)
    let msg = toMessage(res, headers(), images = isEmbedded)
    check fillSource(msg.rendered.html) == url
    check fillSource(toParts(msg).html) == url
    check fillSource(htmlPart(toRfc5322(msg, "t"))) == url

  test "test_fill_keeps_its_https_source_when_an_image_embeds_its_asset":
    # One asset, referenced by an image and by a band: the image's
    # source becomes `cid:`, the band's `v:fill` keeps the URL.
    let res = renderTree(heroAndImageDoc(), assets = imageStore())
    let url = publishedSource(res)
    doAssert sourceOf(res.html, "img") == url, "setup: the render's " &
      "img reads '" & sourceOf(res.html, "img") & "', not the published URL"
    let msg = toMessage(res, headers(), images = isEmbedded)
    # The strategy is in force: the image is embedded.
    check sourceOf(msg.rendered.html, "img") ==
      "cid:" & contentIdFor(res.assets[0])
    check fillSource(msg.rendered.html) == url
    check fillSource(toParts(msg).html) == url
    check fillSource(htmlPart(toRfc5322(msg, "t"))) == url
