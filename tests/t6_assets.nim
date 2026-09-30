# rule: R-IMG-07
## Images and assets. Hosted URLs are content-hashed
## (`/{sha256[0:16]}/{name}`): mutating the bytes changes the URL,
## identical bytes keep it. `cid:` embedding round-trips through
## `multipart/related` parts, `data:` URIs are rejected, and
## `asset"…"` resolves the same hash at compile time with intrinsic
## size and alpha.
##
## Backend-independent (pure hashing, probing and strings; the file
## store guards its reads), so `just test` also runs it on JS.
import std/[strutils, times, unittest]
import isonim_email

when not defined(js):
  import std/os

const
  rgbaBytes = staticRead("fixtures/t6_rgba.png")
  rgbBytes = staticRead("fixtures/t6_rgb.png")
  trnsBytes = staticRead("fixtures/t6_trns.png")
  gifBytes = staticRead("fixtures/t6_sample.gif")
  jpgBytes = staticRead("fixtures/t6_sample.jpg")
  abcSha256 =
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

var hookCalls = 0

proc countingHook(a: AssetRef): string =
  ## Module-level on purpose: a closure capturing a test-local crashes
  ## the JS backend (`jsgen env is missing`), a global does not.
  inc hookCalls
  "https://cdn.example.com" & hostedPath(a)

proc imgTpl(r: EmailRenderer; src: string): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Img"):
      mailSection:
        h1: text "Img"
        mailImage(src = src, alt = "logo")

var cdnCalls: seq[string]

proc cdnHook(a: AssetRef): string =
  ## A stand-in CDN uploader whose URLs differ from the store base, so
  ## the tests can tell the published URL from any derived one.
  cdnCalls.add(a.name)
  "https://cdn.example.net/u" & hostedPath(a)

var badUrl = ""

proc badUrlHook(a: AssetRef): string =
  ## An uploader that "succeeds" without returning where the image
  ## lives: an empty or non-https URL.
  badUrl

proc failingHook(a: AssetRef): string =
  ## An uploader whose upload fails.
  raise newException(IOError, "upload of " & a.name & " failed")

proc renderErr(store: AssetStore; strict: bool): string =
  try:
    discard renderEmail(imgTpl, "brand/logo.png", strict = strict,
      assets = store)
  except CatchableError as e:
    return e.msg
  ""

proc testHeaders(): MessageHeaders =
  MessageHeaders(fromAddr: mailbox("", "a@example.com"),
    to: @[mailbox("", "b@example.com")], date: fromUnix(1767268800))

suite "assets":
  test "sha256 matches the FIPS vector through the public path":
    # The vendored hash proves itself through `hostedPath`: no stdlib
    # SHA-256 exists to cross-check against, so the "abc" vector is
    # the oracle.
    let a = loadAsset("abc.txt", "abc")
    check a.sha256 == abcSha256
    check hostedPath(a) == "/ba7816bf8f01cfea/abc.txt"
    check hostedUrl("https://assets.example.com/", a) ==
      "https://assets.example.com/ba7816bf8f01cfea/abc.txt"

  test "test_asset_urls_change_with_content":
    # rule: R-IMG-07

    let store = memoryAssetStore("https://assets.example.com")
    let first = store.publishBytes("logo.png", rgbaBytes)
    check first.startsWith("https://assets.example.com/")
    # `/{sha16}/{base}` shape, and the base name wins over directories.
    let nested = store.publishBytes("brand/logo.png", rgbaBytes)
    check nested[^9 .. ^1] == "/logo.png"
    check nested.len ==
      "https://assets.example.com".len + 1 + 16 + 1 + 8

    # Same bytes, same name: the same URL, recorded once.
    let again = store.publishBytes("logo.png", rgbaBytes)
    check again == first
    check store.published.len == 2 # logo.png + brand/logo.png

    # Mutating one byte changes the URL.
    var mutated = rgbaBytes
    mutated[mutated.len - 1] =
      char((mutated[mutated.len - 1].ord + 1) mod 256)
    let changed = store.publishBytes("logo.png", mutated)
    check changed != first
    check changed.startsWith("https://assets.example.com/")
    check changed[^9 .. ^1] == "/logo.png"

    # An injected hook sees each publish once: republishing the same
    # asset returns the stored URL without calling it again.
    hookCalls = 0
    let hooked =
      memoryAssetStore("https://cdn.example.com", upload = countingHook)
    check hooked.publishBytes("a.png", rgbBytes) ==
      hooked.publishBytes("a.png", rgbBytes)
    check hookCalls == 1

  test "cid embedding round-trips through the related part":
    # No rule claim: the MIME framing is the roundtrip's; this pins
    # only that the asset side is deterministic and reversible.
    let a = loadAsset("logo.png", rgbaBytes)
    let id = contentIdFor(a)
    check contentIdFromCid(cidUrl(id)) == id
    check contentIdFromCid("https://example.com/x") == ""
    # Deterministic across loads.
    check contentIdFor(loadAsset("logo.png", rgbaBytes)) == id

    let part = imagePart(InlineImage(contentId: id,
      contentType: "image/png", filename: "logo.png", data: rgbaBytes))
    let serialised = serializePart(part)
    check ("<" & id & ">") in serialised
    check "Content-ID: <" & id & ">" in serialised.replace("\r\n ", "")

  test "data uris are rejected naming the rule":
    # No rule claim: R-IMG-08 also covers WebP/SVG under Word/Gmail
    # profiles (P10, the content leaves) — this pins the data:
    # half only, so the rule stays pending.
    for uri in ["data:image/png;base64,iVBOR", "  DATA:text/plain,x",
        "Data:,hello"]:
      check isDataUri(uri)
      var message = ""
      try:
        discard loadAsset(uri, "junk")
      except AssetError as e:
        message = e.msg
      check "E-URL-SCHEME" in message
      check "R-IMG-08" in message
    check not isDataUri("https://example.com/data:x")
    check not isDataUri("database.png")

    let store = memoryAssetStore("https://assets.example.com")
    expect AssetError:
      discard store.publishBytes("data:image/gif;base64,R0lG", "junk")

  test "compile-time asset agrees with the runtime load":
    # rule: R-IMG-07

    # `asset"…"` resolves caller-relative at compile time and hashes
    # identically to the runtime path.
    let compileUrl = asset"fixtures/t6_rgba.png"
    let runtime = loadAsset("fixtures/t6_rgba.png", rgbaBytes)
    check $compileUrl == hostedPath(runtime)

    # Intrinsic size and alpha come from the same compile-time load.
    const resolved = templateAsset("fixtures/t6_rgba.png")
    check resolved.width == 2
    check resolved.height == 2
    check resolved.hasAlpha
    check resolved.mime == "image/png"
    check resolved.bytes == rgbaBytes

    const opaque = templateAsset("fixtures/t6_rgb.png")
    check (opaque.width, opaque.height) == (2, 2)
    check not opaque.hasAlpha

    # A tRNS chunk grants alpha to an RGB image.
    const trns = templateAsset("fixtures/t6_trns.png")
    check trns.hasAlpha

    const gif = templateAsset("fixtures/t6_sample.gif")
    check gif.mime == "image/gif"
    check (gif.width, gif.height) == (2, 2)

    const jpg = templateAsset("fixtures/t6_sample.jpg")
    check jpg.mime == "image/jpeg"
    check (jpg.width, jpg.height) == (2, 2)
    check not jpg.hasAlpha

    # Unknown bytes keep an extension-guessed mime with zero size,
    # never an error.
    let unknown = loadAsset("notes.txt", "hello")
    check unknown.mime == "application/octet-stream"
    check (unknown.width, unknown.height) == (0, 0)

  test "stores resolve, miss and sink":
    let mem = memoryAssetStore("https://assets.example.com")
    mem.put("logo.png", rgbBytes)
    let got = mem.get("logo.png")
    check (got.width, got.height) == (2, 2)
    check mem.publish(got).startsWith("https://assets.example.com/")
    var miss = ""
    try:
      discard mem.get("missing.png")
    except AssetError as e:
      miss = e.msg
    check "E-ASSET-UNKNOWN" in miss

    when not defined(js):
      # The file store reads caller-anchored fixtures and refuses
      # escapes; the sink writes bytes under the hosted path.
      let testsDir = parentDir(currentSourcePath())
      let files = fileAssetStore(testsDir, "https://assets.example.com")
      let fromDisk = files.get("fixtures/t6_rgb.png")
      check (fromDisk.width, fromDisk.height) == (2, 2)
      expect AssetError:
        discard files.get("fixtures/nope.png")
      expect AssetError:
        discard files.get("../isonim_email.nimble")
      let sinkDir = testsDir / "tmp-t6-sink"
      let sunk = fileAssetStore(testsDir, "https://assets.example.com",
        upload = fileSinkHook(sinkDir, "https://assets.example.com"))
      let url = sunk.publish(fromDisk)
      check url == hostedUrl("https://assets.example.com", fromDisk)
      check readFile(sinkDir / hostedPath(fromDisk)) == rgbBytes
      removeDir(sinkDir)

  test "the render publishes every referenced asset and rewrites src":
    # rule: R-IMG-07
    cdnCalls = @[]
    let store = memoryAssetStore("https://assets.example.com",
      upload = cdnHook)
    store.put("brand/logo.png", rgbBytes)
    let res = renderEmail(imgTpl, "brand/logo.png", assets = store)
    check res.diagnostics.len == 0
    # Published through the store's hook before the HTML was final,
    # and the HTML carries exactly the URL the hook returned.
    check cdnCalls == @["brand/logo.png"]
    check res.assets.len == 1
    let url = "https://cdn.example.net/u" & hostedPath(res.assets[0])
    check res.assets[0].url == url
    check "src=\"" & url & "\"" in res.html
    check "src=\"brand/logo.png\"" notin res.html
    check store.published.len == 1
    # A second render republishes idempotently: same URL, no upload.
    let again = renderEmail(imgTpl, "brand/logo.png", assets = store)
    check again.html == res.html
    check cdnCalls.len == 1
    # Hosted messages keep the published URL and embed nothing.
    let hosted = toMessage(res, testHeaders())
    check "src=\"" & url & "\"" in hosted.rendered.html
    check toParts(hosted).inline.len == 0

  test "compile-time assets are published from their hashed path":
    # rule: R-IMG-07
    let path = $asset"fixtures/t6_rgba.png"
    let store = memoryAssetStore("https://assets.example.com")
    let res = renderEmail(imgTpl, path, assets = store)
    check res.diagnostics.len == 0
    check res.assets.len == 1
    check res.assets[0].bytes == rgbaBytes
    check res.assets[0].url == "https://assets.example.com" & path
    check "src=\"https://assets.example.com" & path & "\"" in res.html
    check store.published.len == 1
    # Without a store the path stays as written and nothing publishes.
    let bare = renderEmail(imgTpl, path)
    check bare.assets.len == 0
    check "src=\"" & path & "\"" in bare.html

  test "embedded messages reference cid: parts matching the Content-IDs":
    # rule: R-MIME-11
    let store = memoryAssetStore("https://assets.example.com")
    store.put("logo.png", rgbBytes)
    let res = renderEmail(imgTpl, "logo.png", assets = store)
    let msg = toMessage(res, testHeaders(), images = isEmbedded)
    let id = contentIdFor(res.assets[0])
    check "src=\"cid:" & id & "\"" in msg.rendered.html
    check res.assets[0].url notin msg.rendered.html
    let parts = toParts(msg)
    check parts.inline.len == 1
    check contentIdFor(parts.inline[0]) == id
    let bytes = toRfc5322(msg, "t")
    check "Content-ID: <" & id & ">" in bytes.replace("\r\n ", " ")
    check "multipart/related" in bytes

  test "the html only ever references what the upload returned":
    # rule: R-IMG-07
    # An upload that fails fails the render: no HTML exists that could
    # reference the image before it is published.
    let failing = memoryAssetStore("https://assets.example.com",
      upload = failingHook)
    failing.put("brand/logo.png", rgbBytes)
    check "upload of brand/logo.png failed" in renderErr(failing, false)
    # An upload that returns no absolute https URL did not publish:
    # E-URL-SCHEME naming R-IMG-07, the src is not rewritten to it and
    # the asset is not listed as published.
    for bad in ["", "http://cdn.example.net/x.png", "/relative/x.png",
        "https://", "https:///x.png", "https://cdn.example.net/a b.png"]:
      badUrl = bad
      let store = memoryAssetStore("https://assets.example.com",
        upload = badUrlHook)
      store.put("brand/logo.png", rgbBytes)
      let res = renderEmail(imgTpl, "brand/logo.png", assets = store)
      check res.assets.len == 0
      var found = false
      for d in res.diagnostics:
        if d.code == codeUrlScheme and "R-IMG-07" in d.rules:
          found = true
          check d.severity == sevError
      check found
      if bad.len > 0:
        check ("src=\"" & escapeEmailAttr(bad) & "\"") notin res.html
      # Strict raises it.
      check renderErr(store, true).startsWith("E-URL-SCHEME")
    # Negative control: a good URL publishes and is referenced.
    badUrl = "https://cdn.example.net/ok/logo.png"
    let good = memoryAssetStore("https://assets.example.com",
      upload = badUrlHook)
    good.put("brand/logo.png", rgbBytes)
    let res = renderEmail(imgTpl, "brand/logo.png", assets = good)
    check res.diagnostics.len == 0
    check res.assets.len == 1
    check "src=\"https://cdn.example.net/ok/logo.png\"" in res.html
