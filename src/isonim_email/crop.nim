## isonim_email/crop.nim — images cropped before sending (P8).
##
## `mailImage(crop = "W:H")` and `crop = circle` (catalogue R-IMG-13):
## mail clients have no `object-fit` or `aspect-ratio` outside Apple
## Mail, so a gallery's tiles, a thumbnail's ratio and an avatar's
## circle are made in the image itself, before the message exists.
##
## - A PNG the render holds the bytes of (a store asset or a
##   compile-time `asset"…"`) is decoded (`imaging.decodePng`), cut to
##   the largest centred W:H rectangle (for `circle`, the largest
##   centred square, its corners made transparent by `circleMask`) and
##   re-encoded (`imaging.encodePng`: the bytes depend only on the source
##   and the crop). The result is an asset of its own, named
##   `{stem}-{W}x{H}.png` or `{stem}-circle.png` beside the source's
##   name, content-hashed and published like any other (R-IMG-07). A
##   PNG that already has the ratio is used as it is.
## - A JPEG or GIF is not decoded: its size must already have the ratio,
##   within a pixel. A circle needs a PNG (transparency).
##
## Everything else is `E-ASSET-CROP` (`cropAsset` returns why), and the
## caller leaves the source as written: a crop asked for is never
## dropped silently.
##
## Pure arithmetic over strings: identical on the C and JS targets.

import std/[strutils, tables]
import ./assets
import ./imaging
import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  CropSpec* = object
    ## A parsed `crop` value.
    ok*: bool
    circle*: bool
    rw*, rh*: int ## the ratio (1:1 for a circle)

  CropResult* = object
    ok*: bool
    asset*: AssetRef ## the cropped asset (the source when it had the ratio)
    error*: string   ## why the crop cannot be made, when not `ok`

proc parseCrop*(value: string): CropSpec =
  ## `circle`, or `W:H` with W and H positive whole numbers (spaces
  ## allowed around the colon); `ok = false` for anything else.
  let v = value.strip().toLowerAscii()
  if v == "circle":
    return CropSpec(ok: true, circle: true, rw: 1, rh: 1)
  let parts = v.split(':')
  if parts.len != 2:
    return
  try:
    let w = parseInt(parts[0].strip())
    let h = parseInt(parts[1].strip())
    if w > 0 and h > 0 and w <= 10_000 and h <= 10_000:
      return CropSpec(ok: true, rw: w, rh: h)
  except ValueError:
    discard

proc cropSuffix*(c: CropSpec): string =
  if c.circle: "circle" else: $c.rw & "x" & $c.rh

proc croppedName*(name: string; c: CropSpec): string =
  ## `dir/photo.jpg` → `dir/photo-4x3.png`.
  var dir = ""
  var base = name
  let slash = max(name.rfind('/'), name.rfind('\\'))
  if slash >= 0:
    dir = name[0 .. slash]
    base = name[slash + 1 .. ^1]
  let dot = base.rfind('.')
  let stem = if dot > 0: base[0 ..< dot] else: base
  dir & stem & "-" & cropSuffix(c) & ".png"

proc hasRatio*(width, height, rw, rh: int): bool =
  ## True when `width × height` is `rw:rh` within a pixel either way.
  abs(width * rh - height * rw) <= max(rw, rh)

const pngCropMemoCap = 64
  ## How many PNG crops `cropAsset` keeps per thread before it starts
  ## over (a sender with endless distinct images stays bounded).

var pngCropMemo {.threadvar.}: Table[string, tuple[source: bool;
  made: CropResult]]
  ## The PNG crops made on this thread, keyed by everything a crop's
  ## result depends on: the source's name, its bytes and the crop.
  ## `source` marks a PNG that already had the ratio: the caller's own
  ## asset is the answer then, not the one first asked about.

proc cropPng(a: AssetRef; c: CropSpec): CropResult

proc cropAsset*(a: AssetRef; c: CropSpec): CropResult =
  ## The asset `c` turns `a` into (see the module comment). A PNG crop
  ## is made once per source and crop on a thread and reused: its bytes
  ## depend only on those, and decoding and re-encoding the image is
  ## most of a render that crops (a digest re-sent to every reader).
  if not c.ok:
    return CropResult(error: "not a crop")
  if a.mime == "image/png":
    let key = a.name & "\x00" & cropSuffix(c) & "\x00" & a.bytes
    pngCropMemo.withValue(key, known):
      if known.source:
        return CropResult(ok: true, asset: a)
      return known.made
    result = cropPng(a, c)
    if pngCropMemo.len >= pngCropMemoCap:
      pngCropMemo.clear()
    let source = result.ok and result.asset == a
    pngCropMemo[key] = (source, if source: CropResult() else: result)
    return
  if c.circle:
    return CropResult(error: "a circle needs a PNG (its corners are " &
      "made transparent), and this is " & (if a.mime.len > 0: a.mime
        else: "not an image the render knows"))
  if a.width <= 0 or a.height <= 0:
    return CropResult(error: "its size is unknown")
  if hasRatio(a.width, a.height, c.rw, c.rh):
    return CropResult(ok: true, asset: a)
  let article = if a.mime.len > 0 and a.mime[0] in {'a', 'e', 'i', 'o', 'u'}:
      "an " else: "a "
  CropResult(error: article & a.mime & " is not re-encoded, so it must " &
    "already be " & $c.rw & ":" & $c.rh & ", and it is " & $a.width &
    "×" & $a.height & ": crop it before sending")

proc cropPng(a: AssetRef; c: CropSpec): CropResult =
  ## `cropAsset` for a PNG, made every time.
  if a.bytes.len == 0:
    return CropResult(error: "its bytes are not held by the render")
  let px = decodePng(a.bytes)
  if px.tooLarge:
    return CropResult(error: "it is larger than " & $maxDecodePixels &
      " pixels, which the crop does not decode")
  if not px.ok:
    return CropResult(error: "it is not a PNG the crop can read " &
      "(an interlaced or damaged PNG)")
  let (x, y, w, h) = centredCrop(px.width, px.height, c.rw, c.rh)
  if not c.circle and w == px.width and h == px.height:
    return CropResult(ok: true, asset: a)
  var cut = cropPixels(px, x, y, w, h)
  if c.circle:
    circleMask(cut)
  CropResult(ok: true,
    asset: loadAsset(croppedName(a.name, c), encodePng(cut)))
