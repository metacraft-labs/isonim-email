## The answers the render keeps per thread instead of computing them for
## every message: the families a caniemail feature is unsupported in,
## the dark-mode verdict of a logo's bytes, and a PNG's crop. Each is a
## function of what it is keyed on, so a kept answer must be the answer
## computed afresh, and two inputs that differ in anything the answer
## depends on must not share one.
##
## Backend-independent (pure computation over strings and the snapshot),
## so `just test` also runs it on JS.
import std/[os, unittest]
import isonim_email

const assetsDir = parentDir(currentSourcePath()) / "stories" / "assets"
const outlinedPng = staticRead(assetsDir / "mark-outlined.png")
const barePng = staticRead(assetsDir / "mark-bare.png")

proc fromSnapshot(slug: string): set[ClientFamily] =
  ## The families `slug` reads `svNo` in, straight from the snapshot.
  for f in ClientFamily:
    if familySupport(slug, f).value == svNo:
      result.incl(f)

proc gradientPng(w, h: int): string =
  var p = Pixels(ok: true, width: w, height: h, rgba: newSeq[uint8](w * h * 4))
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = (y * w + x) * 4
      p.rgba[i] = uint8(x * 5 mod 256)
      p.rgba[i + 1] = uint8(y * 9 mod 256)
      p.rgba[i + 2] = 128
      p.rgba[i + 3] = 255
  encodePng(p)

proc logoTree(url: string): EmailNode =
  let r = EmailRenderer()
  result = r.createElement("mailImage")
  r.setAttribute(result, "src", url)
  r.setAttribute(result, "dark_src", "https://x.test/mark-dark.png")
  r.setAttribute(result, "alt", "Acme")

suite "answers kept per thread":
  test "test_unsupported_families_kept_match_the_snapshot":
    var some = 0
    for round in 0 .. 1:
      # The second round reads every answer back from what was kept.
      for slug in caniemailFeatures:
        check unsupportedFamilies(slug) == fromSnapshot(slug)
        if round == 0 and unsupportedFamilies(slug) != {}:
          inc some
    check unsupportedFamilies("no-such-feature") == {}
    check unsupportedFamilies("no-such-feature") == {}
    # Not vacuous: the snapshot has features some families lack.
    check some > 20

  test "test_logo_verdict_follows_the_bytes_not_the_url":
    let url = "https://x.test/mark.png"
    proc warnings(bytes: string): int =
      let found = lintDarkLogos(logoTree(url), [AssetRef(name: "mark.png",
        url: url, bytes: bytes)])
      for d in found:
        if d.code == codeDarkLogoUnsafe:
          inc result
    check warnings(barePng) == 1
    # The same URL and name with other bytes: their own verdict.
    check warnings(outlinedPng) == 0
    check warnings(barePng) == 1
    check warnings(outlinedPng) == 0

  test "test_png_crop_kept_per_name_bytes_and_crop":
    let bytes = gradientPng(40, 20)
    let a = loadAsset("photos/a.png", bytes)
    let square = parseCrop("1:1")
    let first = cropAsset(a, square)
    check first.ok
    check first.asset.name == "photos/a-1x1.png"
    check first.asset.width == 20 and first.asset.height == 20
    check cropAsset(a, square) == first
    # Another name with the same bytes: its own name.
    let b = loadAsset("photos/b.png", bytes)
    check cropAsset(b, square).asset.name == "photos/b-1x1.png"
    check cropAsset(b, square).asset.bytes == first.asset.bytes
    # Another crop of the same image.
    let circle = cropAsset(a, parseCrop("circle"))
    check circle.asset.name == "photos/a-circle.png"
    check circle.asset.bytes != first.asset.bytes
    # Other bytes under the same name: their own crop.
    let c = loadAsset("photos/a.png", gradientPng(30, 20))
    let third = cropAsset(c, square)
    check third.asset.width == 20
    check third.asset.bytes != first.asset.bytes

  test "test_png_with_the_ratio_is_the_callers_own_asset":
    # A PNG that already has the ratio is used as it is: the asset the
    # caller passed, with its own fields, even when an earlier caller's
    # asset of the same name and bytes was answered first.
    let bytes = gradientPng(40, 20)
    var a = loadAsset("photos/wide.png", bytes)
    a.url = "https://first.test/wide.png"
    let first = cropAsset(a, parseCrop("2:1"))
    check first.ok
    check first.asset == a
    var b = loadAsset("photos/wide.png", bytes)
    b.url = "https://second.test/wide.png"
    let second = cropAsset(b, parseCrop("2:1"))
    check second.ok
    check second.asset == b
    check second.asset.url == "https://second.test/wide.png"
