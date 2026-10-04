## Images cropped before sending (`mailImage(crop)`, catalogue R-IMG-13)
## and the PNG encoder the crops are written with.
##
## - `encodePng` writes pixels `decodePng` reads back exactly, the same
##   bytes every time; and the dev shell's Python (its `zlib` and a PNG
##   reader written in the test, sharing no code with the library) reads
##   the same pixels out of them: the chunks' CRC-32s, the zlib stream
##   and every scanline filter are checked by an independent decoder.
## - The asset pass crops a PNG to the largest centred W:H rectangle, or
##   to a circle with transparent corners and an anti-aliased edge, and
##   publishes the crop as an asset of its own whose size the lowering
##   reads; a PNG that already has the ratio is published as it is.
## - A JPEG or GIF is checked, not re-encoded: it must already have the
##   ratio; a circle needs a PNG. A crop P8 cannot make (no store, an
##   absolute URL, a malformed value) is `E-ASSET-CROP`, never dropped.
##
## C backend only: the oracle runs the dev shell's `python3` and reads
## a file written to a temporary directory. No test doubles.
import std/[os, osproc, sequtils, strutils, unittest]
import isonim_email

const
  store = "https://cdn.example.com"
  gifBytes = staticRead("fixtures/t6_sample.gif")

proc pixels(w, h: int; f: proc(x, y: int): array[4, uint8]): Pixels =
  result = Pixels(ok: true, width: w, height: h,
    rgba: newSeq[uint8](w * h * 4))
  for y in 0 ..< h:
    for x in 0 ..< w:
      let px = f(x, y)
      for k in 0 .. 3:
        result.rgba[(y * w + x) * 4 + k] = px[k]

proc gradient(w, h: int): Pixels =
  ## Every pixel tells where it came from: red is x, green is y.
  pixels(w, h, proc(x, y: int): array[4, uint8] =
    [uint8(x mod 256), uint8(y mod 256), uint8((x * 7 + y * 3) mod 256),
      255'u8])

proc at(p: Pixels; x, y: int): array[4, uint8] =
  for k in 0 .. 3:
    result[k] = p.rgba[(y * p.width + x) * 4 + k]

proc imageDoc(src, crop: string; width = "200px"): EmailNode =
  let r = EmailRenderer()
  result = r.createElement("mailDocument")
  r.setAttribute(result, "lang", "en")
  r.setAttribute(result, "title", "Crop")
  let s = r.createElement("mailSection")
  let h = r.createElement("h1")
  r.setTextContent(h, "Crop")
  r.appendChild(s, h)
  let img = r.createElement("mailImage")
  r.setAttribute(img, "src", src)
  r.setAttribute(img, "alt", "A picture")
  if crop.len > 0:
    r.setAttribute(img, "crop", crop)
  r.setStyle(img, "width", width)
  r.appendChild(s, img)
  r.appendChild(result, s)

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc jpegOf(w, h: int): string =
  ## The header of a baseline JPEG of `w × h` (SOI, one SOF0, EOI): all
  ## the asset probe reads.
  result = "\xFF\xD8\xFF\xC0\x00\x11\x08"
  result.add(chr(h shr 8) & chr(h and 0xFF) & chr(w shr 8) & chr(w and 0xFF))
  result.add("\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01\xFF\xD9")

suite "the PNG encoder":
  test "test_encoded_png_decodes_to_the_same_pixels":
    for (w, h) in [(1, 1), (3, 2), (17, 9), (240, 80)]:
      let p = pixels(w, h, proc(x, y: int): array[4, uint8] =
        [uint8((x * 37 + y) mod 256), uint8((y * 11) mod 256),
          uint8((x xor y) mod 256), uint8((x * y * 5) mod 256)])
      let bytes = encodePng(p)
      check bytes == encodePng(p) # deterministic
      let back = decodePng(bytes)
      check back.ok
      check back.width == w and back.height == h
      check back.rgba == p.rgba
    # A planar image, which only the Paeth filter predicts exactly: its
    # rows are written with filter 4, and still read back.
    let planar = pixels(64, 32, proc(x, y: int): array[4, uint8] =
      [uint8((3 * x + 5 * y) mod 256), uint8((7 * x + 2 * y) mod 256),
        uint8((x + 9 * y) mod 256), 255'u8])
    let planarBytes = encodePng(planar)
    let raw = zlibDecompress(planarBytes[41 ..< planarBytes.len - 16])
    var paethRows = 0
    for y in 0 ..< 32:
      if raw[y * (64 * 4 + 1)] == '\x04':
        inc paethRows
    check paethRows >= 30
    check decodePng(planarBytes).rgba == planar.rgba
    # Long runs compress: a flat 200×200 image is far below its 160 KB
    # of pixels.
    let flat = pixels(200, 200, proc(x, y: int): array[4, uint8] =
      [12'u8, 34, 56, 255])
    let flatBytes = encodePng(flat)
    check flatBytes.len < 4000
    check decodePng(flatBytes).rgba == flat.rgba

  test "test_an_independent_decoder_reads_the_encoded_png":
    let python = findExe("python3")
    if python.len == 0:
      raise newException(OSError, "python3 not on PATH: run under the " &
        "dev shell (`nix develop`); the oracle is not skipped")
    let p = gradient(61, 23)
    let dir = getTempDir() / "isonim-email-t6-crop-" & $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    let path = dir / "out.png"
    writeFile(path, encodePng(p))
    # RFC 2083 read with Python's zlib: chunk CRCs, the stream, the five
    # filters; prints the unfiltered RGBA as hex.
    let script = """
import struct, sys, zlib
b = open(sys.argv[1], 'rb').read()
assert b[:8] == b'\x89PNG\r\n\x1a\n'
p, idat, w, h = 8, b'', 0, 0
while p < len(b):
    n, = struct.unpack('>I', b[p:p+4]); t = b[p+4:p+8]; d = b[p+8:p+8+n]
    crc, = struct.unpack('>I', b[p+8+n:p+12+n])
    assert zlib.crc32(t + d) & 0xffffffff == crc, t
    if t == b'IHDR':
        w, h, depth, ctype = struct.unpack('>IIBB', d[:10]); assert (depth, ctype) == (8, 6)
    if t == b'IDAT': idat += d
    p += 12 + n
raw = zlib.decompress(idat); s = w * 4; out = bytearray(); prev = bytearray(s)
for y in range(h):
    f = raw[y * (s + 1)]; row = bytearray(raw[y * (s + 1) + 1:(y + 1) * (s + 1)])
    for x in range(s):
        a = row[x - 4] if x >= 4 else 0; c = prev[x - 4] if x >= 4 else 0; up = prev[x]
        if f == 1: row[x] = (row[x] + a) & 255
        elif f == 2: row[x] = (row[x] + up) & 255
        elif f == 3: row[x] = (row[x] + (a + up) // 2) & 255
        elif f == 4:
            q = a + up - c; pa, pb, pc = abs(q - a), abs(q - up), abs(q - c)
            row[x] = (row[x] + (a if pa <= pb and pa <= pc else up if pb <= pc else c)) & 255
    out += row; prev = row
print(w, h, out.hex())
"""
    let (output, code) = execCmdEx(python & " -c " & quoteShell(script) &
      " " & quoteShell(path))
    check code == 0
    var hex = ""
    for b in p.rgba:
      hex.add(toHex(int(b), 2).toLowerAscii())
    check output.strip() == "61 23 " & hex

suite "crops made by the asset pass":
  # rule: R-IMG-13
  test "test_a_png_is_cropped_to_the_largest_centred_rectangle":
    let s = memoryAssetStore(store)
    s.put("photos/beach.png", encodePng(gradient(480, 360)))
    let res = renderTree(imageDoc("photos/beach.png", "1:1"), assets = s)
    check not hasErrors(res.diagnostics)
    check res.assets.len == 1
    let a = res.assets[0]
    check a.name == "photos/beach-1x1.png"
    check a.width == 360 and a.height == 360
    check a.url == store & hostedPath(a)
    check ("src=\"" & a.url & "\"") in res.html
    # The rendered height follows the crop: 200 wide, 200 tall.
    check "width=\"200\" height=\"200\"" in res.html
    # The window is centred: 60 columns cut from each side.
    let cut = decodePng(a.bytes)
    check cut.ok
    check cut.at(0, 0)[0] == 60'u8 and cut.at(0, 0)[1] == 0'u8
    check cut.at(359, 359)[0] == uint8(419 mod 256)
    check cut.at(359, 359)[1] == uint8(359 mod 256)
    # A wide ratio cuts rows instead.
    let s2 = memoryAssetStore(store)
    s2.put("beach.png", encodePng(gradient(480, 360)))
    let wide = renderTree(imageDoc("beach.png", "16:9"), assets = s2)
    check wide.assets[0].width == 480 and wide.assets[0].height == 270
    check decodePng(wide.assets[0].bytes).at(0, 0)[1] == 45'u8
    # The crop attribute is the asset pass's: never written to the HTML.
    check "crop=" notin res.html

  test "test_a_circle_crop_has_transparent_corners":
    let s = memoryAssetStore(store)
    s.put("face.png", encodePng(pixels(100, 80,
      proc(x, y: int): array[4, uint8] = [200'u8, 100, 50, 255])))
    let res = renderTree(imageDoc("face.png", "circle", "80px"), assets = s)
    check not hasErrors(res.diagnostics)
    let a = res.assets[0]
    check a.name == "face-circle.png"
    check a.width == 80 and a.height == 80 and a.hasAlpha
    let c = decodePng(a.bytes)
    for (x, y) in [(0, 0), (79, 0), (0, 79), (79, 79), (5, 5)]:
      check c.at(x, y)[3] == 0'u8
    check c.at(40, 40) == [200'u8, 100, 50, 255]
    check c.at(40, 1)[3] == 255'u8
    # The edge is anti-aliased: on the circle's rim a pixel is partly
    # covered.
    var partial = 0
    for x in 0 ..< 80:
      let alpha = c.at(x, 12)[3]
      if alpha > 0'u8 and alpha < 255'u8:
        inc partial
    check partial >= 2
    # Same source, same crop: the same bytes and URL every time.
    let again = renderTree(imageDoc("face.png", "circle", "80px"),
      assets = s)
    check again.assets[0].bytes == a.bytes
    check again.assets[0].url == a.url

  test "test_a_png_that_has_the_ratio_is_published_as_it_is":
    let s = memoryAssetStore(store)
    let bytes = encodePng(gradient(400, 300))
    s.put("plain.png", bytes)
    let res = renderTree(imageDoc("plain.png", "4:3"), assets = s)
    check not hasErrors(res.diagnostics)
    check res.assets[0].name == "plain.png"
    check res.assets[0].bytes == bytes

  test "test_a_jpeg_or_gif_must_already_have_the_ratio":
    let s = memoryAssetStore(store)
    s.put("shot.jpg", jpegOf(400, 300))
    let ok = renderTree(imageDoc("shot.jpg", "4:3"), assets = s)
    check not hasErrors(ok.diagnostics)
    check ok.assets[0].name == "shot.jpg"
    # 401×300 is within a pixel of 4:3.
    s.put("near.jpg", jpegOf(401, 300))
    check not hasErrors(renderTree(imageDoc("near.jpg", "4:3"),
      assets = s).diagnostics)
    let bad = renderTree(imageDoc("shot.jpg", "1:1"), assets = s)
    check codeAssetCrop in codesOf(bad.diagnostics)
    let badMessage = bad.diagnostics[codesOf(bad.diagnostics).find(
      codeAssetCrop)].message
    check "400×300" in badMessage
    check "an image/jpeg is not re-encoded" in badMessage
    check "https://" notin bad.html.split("<img")[1].split(">")[0]
    s.put("anim.gif", gifBytes)
    let gif = renderTree(imageDoc("anim.gif", "circle"), assets = s)
    check codeAssetCrop in codesOf(gif.diagnostics)

  test "test_a_crop_that_cannot_be_made_is_an_error":
    let s = memoryAssetStore(store)
    s.put("beach.png", encodePng(gradient(48, 36)))
    # No store: nothing is resolved, so nothing is cropped.
    let noStore = renderTree(imageDoc("beach.png", "1:1"))
    check codesOf(noStore.diagnostics).count(codeAssetCrop) == 1
    # An absolute URL: its bytes are not the render's.
    let url = renderTree(imageDoc("https://cdn.example.com/x/beach.png",
      "1:1"), assets = s)
    check codeAssetCrop in codesOf(url.diagnostics)
    # A malformed value.
    for v in ["4x3", "0:1", "wide", "1:"]:
      let res = renderTree(imageDoc("beach.png", v), assets = s)
      check codeAssetCrop in codesOf(res.diagnostics)
    # A malformed PNG.
    s.put("broken.png", "\x89PNG\r\n\x1A\nnot a png at all")
    check codeAssetCrop in codesOf(renderTree(imageDoc("broken.png",
      "1:1"), assets = s).diagnostics)
