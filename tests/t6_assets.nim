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
import std/[strutils, unittest]
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
