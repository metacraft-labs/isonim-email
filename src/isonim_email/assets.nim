## isonim_email/assets.nim — images and assets.
##
## `asset"…"` resolves at compile time (caller-anchored `staticRead`)
## with content hash, intrinsic size and alpha computed before the
## binary runs. Hosted URLs are content-hashed (`/{sha256[0:16]}/{name}`,
## R-IMG-07) through an `AssetStore` whose upload hook is injected —
## `nil` records without network (tests), a file sink or a real CDN
## uploader plugs in. `cid:` embedding is deterministic from the same
## hash; `data:` URIs are rejected naming R-IMG-08.
##
## Framework-free (no renderer import) like the style layer, so compile
## time, the C backend and the JS backend all run it; only
## `FileAssetStore.get` and the file sink need the filesystem (`when
## not defined(js)`).

import std/[strutils, tables]
import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

when not defined(js):
  import std/os

type
  AssetError* = object of ValueError
    ## A forbidden URL scheme or an unresolvable asset. The message
    ## carries the stable `CODE: …` head, so P8 converts it with
    ## `toDiagnostic`.

  Url* = distinct string
    ## An email-safe URL. `asset"…"` yields the content-hashed path;
    ## a render given a store publishes the asset and rewrites the
    ## path to the published URL.

  ImageStrategy* = enum
    ## Hosted (default) or `cid:`-embedded. `data:` URIs are
    ## not offered (R-IMG-08).
    isHosted, isEmbedded

  ImageInfo* = object
    ## Metadata sniffing: magic bytes plus PNG/GIF/JPEG dimension and
    ## alpha parsing. Unknown input keeps its extension-guessed mime
    ## with zero dimensions — never an error.
    mime*: string
    width*, height*: int
    hasAlpha*: bool

  AssetRef* = object
    ## One asset with its content hash and metadata.
    name*: string
    sha256*: string
    mime*: string
    width*, height*: int
    hasAlpha*: bool
    bytes*: string ## Empty when not embedded.
    url*: string
      ## The URL the rendered HTML references: set when the render
      ## publishes the asset through its store; "" otherwise.

proc `$`*(u: Url): string =
  string(u)

proc `==`*(a, b: Url): bool =
  string(a) == string(b)

proc isDataUri*(s: string): bool =
  ## Leading-whitespace-tolerant, case-insensitive `data:` check.
  var i = 0
  while i < s.len and s[i] in {' ', '\t', '\r', '\n'}:
    inc i
  const prefix = "data:"
  if s.len - i < prefix.len:
    return false
  for k in 0 ..< prefix.len:
    if s[i + k].toLowerAscii() != prefix[k]:
      return false
  true

# ---------------------------------------------------------------- sha256

const sha256K: array[64, uint32] = [
  0x428A2F98'u32, 0x71374491'u32, 0xB5C0FBCF'u32, 0xE9B5DBA5'u32,
  0x3956C25B'u32, 0x59F111F1'u32, 0x923F82A4'u32, 0xAB1C5ED5'u32,
  0xD807AA98'u32, 0x12835B01'u32, 0x243185BE'u32, 0x550C7DC3'u32,
  0x72BE5D74'u32, 0x80DEB1FE'u32, 0x9BDC06A7'u32, 0xC19BF174'u32,
  0xE49B69C1'u32, 0xEFBE4786'u32, 0x0FC19DC6'u32, 0x240CA1CC'u32,
  0x2DE92C6F'u32, 0x4A7484AA'u32, 0x5CB0A9DC'u32, 0x76F988DA'u32,
  0x983E5152'u32, 0xA831C66D'u32, 0xB00327C8'u32, 0xBF597FC7'u32,
  0xC6E00BF3'u32, 0xD5A79147'u32, 0x06CA6351'u32, 0x14292967'u32,
  0x27B70A85'u32, 0x2E1B2138'u32, 0x4D2C6DFC'u32, 0x53380D13'u32,
  0x650A7354'u32, 0x766A0ABB'u32, 0x81C2C92E'u32, 0x92722C85'u32,
  0xA2BFE8A1'u32, 0xA81A664B'u32, 0xC24B8B70'u32, 0xC76C51A3'u32,
  0xD192E819'u32, 0xD6990624'u32, 0xF40E3585'u32, 0x106AA070'u32,
  0x19A4C116'u32, 0x1E376C08'u32, 0x2748774C'u32, 0x34B0BCB5'u32,
  0x391C0CB3'u32, 0x4ED8AA4A'u32, 0x5B9CCA4F'u32, 0x682E6FF3'u32,
  0x748F82EE'u32, 0x78A5636F'u32, 0x84C87814'u32, 0x8CC70208'u32,
  0x90BEFFFA'u32, 0xA4506CEB'u32, 0xBEF9A3F7'u32, 0xC67178F2'u32,
]

proc rotr(x: uint32; n: int): uint32 {.inline.} =
  (x shr n) or (x shl (32 - n))

proc sha256Hex*(data: string): string =
  ## FIPS 180-4 SHA-256, hex-encoded. Pure Nim (the stdlib has no
  ## SHA-256), so the `asset` template runs it at compile time. The
  ## `t6_assets` suite pins the FIPS `"abc"` vector through `hostedPath`.
  ## Public: the capture driver (`tools/capture/build_stories.nim`)
  ## records `mime_sha256` with it.
  var h = [0x6A09E667'u32, 0xBB67AE85'u32, 0x3C6EF372'u32,
    0xA54FF53A'u32, 0x510E527F'u32, 0x9B05688C'u32, 0x1F83D9AB'u32,
    0x5BE0CD19'u32]
  let bitLen = uint64(data.len) * 8
  var msg = data
  msg.add('\x80')
  while msg.len mod 64 != 56:
    msg.add('\x00')
  for i in countdown(7, 0):
    msg.add(char((bitLen shr (i * 8)) and 0xFF))
  var w: array[64, uint32]
  var p = 0
  while p < msg.len:
    for i in 0 ..< 16:
      w[i] = (uint32(msg[p + i * 4].ord) shl 24) or
        (uint32(msg[p + i * 4 + 1].ord) shl 16) or
        (uint32(msg[p + i * 4 + 2].ord) shl 8) or
        uint32(msg[p + i * 4 + 3].ord)
    for i in 16 ..< 64:
      let s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor
        (w[i - 15] shr 3)
      let s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor
        (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4],
      h[5], h[6], h[7])
    for i in 0 ..< 64:
      let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + s1 + ch + sha256K[i] + w[i]
      let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = s0 + maj
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b
      b = a
      a = t1 + t2
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    h[5] += f
    h[6] += g
    h[7] += hh
    p += 64
  const digits = "0123456789abcdef"
  result = newStringOfCap(64)
  for v in h:
    for i in countdown(7, 0):
      result.add(digits[(v shr (i * 4)) and 0xF])

# ------------------------------------------------------- metadata probes

proc be16(b: string; at: int): int {.inline.} =
  (b[at].ord shl 8) or b[at + 1].ord

proc be32(b: string; at: int): int {.inline.} =
  (b[at].ord shl 24) or (b[at + 1].ord shl 16) or
    (b[at + 2].ord shl 8) or b[at + 3].ord

proc le16(b: string; at: int): int {.inline.} =
  b[at].ord or (b[at + 1].ord shl 8)

proc pngInfo(bytes: string): tuple[ok: bool; w, h: int; alpha: bool] =
  ## IHDR dimensions plus alpha: colour types 4/6 carry it, and a
  ## `tRNS` chunk grants it to types 0/2/3. Chunk-walk stops at `IDAT`.
  const sig = "\x89PNG\r\n\x1A\n"
  if bytes.len < 29 or bytes[0 ..< 8] != sig or
      bytes[12 ..< 16] != "IHDR":
    return (false, 0, 0, false)
  let colorType = bytes[25].ord
  result = (true, be32(bytes, 16), be32(bytes, 20),
    colorType in {4, 6})
  if result.alpha or colorType notin {0, 2, 3}:
    return
  var p = 8
  while p + 12 <= bytes.len:
    let len = be32(bytes, p)
    if len < 0 or p + 12 + len > bytes.len:
      return
    let typ = bytes[p + 4 ..< p + 8]
    if typ == "tRNS":
      result.alpha = true
      return
    if typ == "IDAT" or typ == "IEND":
      return
    p += 12 + len

proc skipGifBlocks(bytes: string; p: int): int =
  ## Past a run of sub-blocks; -1 when truncated.
  var q = p
  while true:
    if q >= bytes.len:
      return -1
    let n = bytes[q].ord
    inc q
    if n == 0:
      return q
    q += n
    if q > bytes.len:
      return -1

proc gifInfo(bytes: string): tuple[ok: bool; w, h: int; alpha: bool] =
  ## Logical-screen dimensions plus a real extension walk: alpha only
  ## when a Graphic Control Extension sets the transparent-colour flag.
  if bytes.len < 13 or (bytes[0 ..< 6] != "GIF87a" and
      bytes[0 ..< 6] != "GIF89a"):
    return (false, 0, 0, false)
  result = (true, le16(bytes, 6), le16(bytes, 8), false)
  var p = 13
  let packed = bytes[10].ord
  if (packed and 0x80) != 0:
    p += 3 * (1 shl (1 + (packed and 7)))
  while p < bytes.len:
    let sep = bytes[p].ord
    if sep == 0x3B:
      return
    elif sep == 0x21:
      if p + 1 >= bytes.len:
        return
      if bytes[p + 1].ord == 0xF9:
        if p + 5 >= bytes.len:
          return
        if bytes[p + 2].ord == 4 and (bytes[p + 3].ord and 1) != 0:
          result.alpha = true
          return
      p = skipGifBlocks(bytes, p + 2)
      if p < 0:
        return
    elif sep == 0x2C:
      if p + 9 >= bytes.len:
        return
      let ipacked = bytes[p + 9].ord
      p += 10
      if (ipacked and 0x80) != 0:
        p += 3 * (1 shl (1 + (ipacked and 7)))
      if p >= bytes.len:
        return
      p = skipGifBlocks(bytes, p + 1)
      if p < 0:
        return
    else:
      return

proc jpegInfo(bytes: string): tuple[ok: bool; w, h: int] =
  ## First SOF frame dimensions via a marker scan; stops at SOS (past
  ## it lies entropy data). JPEG has no alpha.
  if bytes.len < 4 or bytes[0].ord != 0xFF or bytes[1].ord != 0xD8:
    return (false, 0, 0)
  var p = 2
  while p + 1 < bytes.len:
    if bytes[p].ord != 0xFF:
      return (false, 0, 0)
    while p < bytes.len and bytes[p].ord == 0xFF:
      inc p
    if p >= bytes.len:
      return (false, 0, 0)
    let m = bytes[p].ord
    inc p
    if m == 0xD8 or m == 0x01 or (0xD0 <= m and m <= 0xD7):
      continue
    if m == 0xD9:
      return (false, 0, 0)
    if p + 1 >= bytes.len:
      return (false, 0, 0)
    let segLen = be16(bytes, p)
    if segLen < 2:
      return (false, 0, 0)
    if m in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA,
        0xCB, 0xCD, 0xCE, 0xCF}:
      if p + 7 >= bytes.len:
        return (false, 0, 0)
      return (true, be16(bytes, p + 5), be16(bytes, p + 3))
    if m == 0xDA:
      return (false, 0, 0)
    p += segLen
  (false, 0, 0)

proc mimeFromName(name: string): string =
  let dot = name.rfind('.')
  if dot < 0:
    return "application/octet-stream"
  case name[dot + 1 .. ^1].toLowerAscii()
  of "png": "image/png"
  of "gif": "image/gif"
  of "jpg", "jpeg": "image/jpeg"
  of "webp": "image/webp"
  of "svg": "image/svg+xml"
  else: "application/octet-stream"

proc probeImage*(bytes: string; name: string): ImageInfo =
  ## Sniffs magic bytes, then PNG/GIF/JPEG metadata. Anything
  ## unrecognised keeps the extension-guessed mime with zero size.
  let png = pngInfo(bytes)
  if png.ok:
    return ImageInfo(mime: "image/png", width: png.w, height: png.h,
      hasAlpha: png.alpha)
  let gif = gifInfo(bytes)
  if gif.ok:
    return ImageInfo(mime: "image/gif", width: gif.w, height: gif.h,
      hasAlpha: gif.alpha)
  let jpeg = jpegInfo(bytes)
  if jpeg.ok:
    return ImageInfo(mime: "image/jpeg", width: jpeg.w, height: jpeg.h,
      hasAlpha: false)
  ImageInfo(mime: mimeFromName(name), width: 0, height: 0,
    hasAlpha: false)

proc loadAsset*(name, bytes: string): AssetRef =
  ## Hashes and probes raw bytes into an `AssetRef`. A `data:` name is
  ## rejected naming R-IMG-08.
  if isDataUri(name):
    raise newException(AssetError,
      "E-URL-SCHEME: data: URIs are forbidden (R-IMG-08): '" & name & "'")
  let info = probeImage(bytes, name)
  AssetRef(name: name, sha256: sha256Hex(bytes), mime: info.mime,
    width: info.width, height: info.height, hasAlpha: info.hasAlpha,
    bytes: bytes)

# ---------------------------------------------------- hosted URLs, cid

proc assetBaseName*(name: string): string =
  ## After the last `/` or `\`; the hosted path carries the base name
  ## (`asset"brand/logo.png"` → `…/logo.png`).
  var cut = 0
  for i in 0 ..< name.len:
    if name[i] in {'/', '\\'}:
      cut = i + 1
  name[cut .. ^1]

proc hostedPath*(a: AssetRef): string =
  ## `/{sha256[0:16]}/{base}` (R-IMG-07): changing the bytes changes
  ## the URL, so proxies never serve a stale image.
  "/" & a.sha256[0 ..< 16] & "/" & assetBaseName(a.name)

proc hostedUrl*(baseUrl: string; a: AssetRef): string =
  ## The base plus the hosted path, tolerating a trailing slash.
  var base = baseUrl
  while base.endsWith('/'):
    base.setLen(base.len - 1)
  base & hostedPath(a)

proc safeIdBit(s: string): string =
  result = newStringOfCap(s.len)
  for c in s:
    if c.isAlphaNumeric() or c in {'.', '-', '_'}:
      result.add(c)
    else:
      result.add('-')

proc contentIdFor*(a: AssetRef): string =
  ## Deterministic `Content-ID` for `cid:` embedding (the MIME layer's
  ## `imagePart` wraps it in `<>`): hash plus base name, stable across renders.
  a.sha256[0 ..< 16] & "-" & safeIdBit(assetBaseName(a.name)) &
    "@isonim"

proc cidUrl*(contentId: string): string =
  ## The `src` side of an embedded image.
  "cid:" & contentId

proc contentIdFromCid*(url: string): string =
  ## Back from `cid:` to the bare id; `""` when not a `cid:` URL.
  if url.len > 4 and url[0 ..< 4].toLowerAscii() == "cid:":
    url[4 .. ^1]
  else:
    ""

# ---------------------------------------------------------------- stores

type
  UploadHook* = proc (a: AssetRef): string {.closure.}
    ## Publishes one asset, returning its https URL. The real CDN
    ## uploader is a consumer seam; `nil` records without network.

  PublishedAsset* = object
    asset*: AssetRef
    url*: string

  AssetStore* = ref object of RootObj
    ## Resolves names and publishes hashed URLs. `publish`
    ## is idempotent: a republished asset returns its stored URL.
    baseUrl*: string
    upload*: UploadHook
    published*: seq[PublishedAsset]

  MemoryAssetStore* = ref object of AssetStore
    ## In-memory `name → bytes`; the backend-independent test store.
    files*: Table[string, string]

  FileAssetStore* = ref object of AssetStore
    ## `root`-anchored files (C backend only for reads).
    root*: string

method get*(s: AssetStore; name: string): AssetRef {.base.} =
  ## Resolves one asset by name. The base raises; stores override.
  raise newException(AssetError,
    "E-ASSET-UNKNOWN: asset '" & name & "' not found")

proc recordUploadHook*(baseUrl: string): UploadHook =
  ## The default hook: records, no network (upload completes before
  ## send by construction — R-IMG-07's ordering is the caller's).
  result = proc (a: AssetRef): string {.closure.} =
    hostedUrl(baseUrl, a)

proc ensureUpload(s: AssetStore) =
  if s.upload == nil:
    s.upload = recordUploadHook(s.baseUrl)

method publish*(s: AssetStore; a: AssetRef): string {.base.} =
  ## Publishes one asset, returning its https URL. Idempotent: the
  ## same name plus bytes republishes to the stored URL without
  ## calling the hook again.
  s.ensureUpload()
  for p in s.published:
    if p.asset.sha256 == a.sha256 and p.asset.name == a.name:
      return p.url
  let url = s.upload(a)
  s.published.add(PublishedAsset(asset: a, url: url))
  url

proc publishBytes*(s: AssetStore; name, bytes: string): string =
  ## `loadAsset` plus `publish` in one call.
  s.publish(loadAsset(name, bytes))

proc memoryAssetStore*(baseUrl: string;
                       upload: UploadHook = nil): MemoryAssetStore =
  ## An empty in-memory store; `upload = nil` records without network.
  result = MemoryAssetStore(baseUrl: baseUrl, upload: upload,
    published: @[], files: initTable[string, string]())
  result.ensureUpload()

proc put*(s: MemoryAssetStore; name, bytes: string) =
  ## Stores raw bytes under `name` for `get` to resolve.
  s.files[name] = bytes

method get*(s: MemoryAssetStore; name: string): AssetRef =
  if name notin s.files:
    raise newException(AssetError,
      "E-ASSET-UNKNOWN: asset '" & name & "' not found")
  loadAsset(name, s.files[name])

proc fileAssetStore*(root: string; baseUrl: string;
                     upload: UploadHook = nil): AssetStore =
  ## A `root`-anchored store; `upload = nil` records
  ## without network.
  result = FileAssetStore(baseUrl: baseUrl, upload: upload,
    published: @[], root: root)
  result.ensureUpload()

when not defined(js):
  proc fileSinkHook*(root, baseUrl: string): UploadHook =
    ## A test/loop hook: writes bytes under `root/<hosted path>` and
    ## returns the URL. The real uploader is a consumer seam.
    result = proc (a: AssetRef): string {.closure.} =
      let dest = root / hostedPath(a)
      createDir(parentDir(dest))
      writeFile(dest, a.bytes)
      hostedUrl(baseUrl, a)

method get*(s: FileAssetStore; name: string): AssetRef =
  if ".." in name:
    raise newException(AssetError,
      "E-ASSET-UNKNOWN: asset '" & name & "' escapes the root")
  when defined(js):
    raise newException(AssetError,
      "E-ASSET-UNKNOWN: file stores cannot read on the JS backend: '" &
        name & "'")
  else:
    let path = s.root / name
    if not fileExists(path):
      raise newException(AssetError,
        "E-ASSET-UNKNOWN: asset '" & name & "' not found")
    loadAsset(name, readFile(path))

# ------------------------------------------------- compile-time assets

var compiledAssets: seq[AssetRef]
  ## Every `asset"…"` the program embeds, registered
  ## once at program start, so the render can publish a compile-time
  ## asset from the content-hashed path the template wrote into `src`.

proc registerCompiledAsset*(a: AssetRef): bool =
  ## Records one compile-time asset (idempotent on name plus hash).
  ## Returns true so the templates can bind it to a start-up global.
  for known in compiledAssets:
    if known.sha256 == a.sha256 and known.name == a.name:
      return true
  compiledAssets.add(a)
  true

proc compiledAssetAt*(path: string): tuple[found: bool; asset: AssetRef] =
  ## The compile-time asset whose content-hashed path is `path`
  ## (`/{sha256[0:16]}/{base}`), if the program embeds one.
  for known in compiledAssets:
    if hostedPath(known) == path:
      return (true, known)
  (false, AssetRef())

proc callerDirOf(path: string): string =
  var cut = 0
  for i in 0 ..< path.len:
    if path[i] in {'/', '\\'}:
      cut = i + 1
  path[0 ..< cut]

proc callerJoin(dir, name: string): string =
  if name.startsWith('/') or
      (name.len > 2 and name[1] == ':' and name[2] == '\\'):
    name
  else:
    dir & name

template asset*(name: static string): Url =
  ## Resolves `name` (caller-file-relative, like `include`)
  ## at compile time and yields the content-hashed path. Hash,
  ## dimensions and alpha are computed before the binary runs; a
  ## `data:` name fails the build. The asset is registered at program
  ## start, so a render given a store publishes it and rewrites the
  ## path to the published URL. Render-time resolution through an
  ## `AssetStore` (missing files, dynamic names) is the render
  ## pipeline's half — `MemoryAssetStore`/`FileAssetStore.get` above.
  when isDataUri(name):
    {.error: "E-URL-SCHEME: data: URIs are forbidden (R-IMG-08)".}
  else:
    const caller {.gensym.} = instantiationInfo(fullPaths = true)
    const srcPath {.gensym.} =
      callerJoin(callerDirOf(caller.filename), name)
    const srcBytes {.gensym.} = staticRead(srcPath)
    const loaded {.gensym.} = loadAsset(name, srcBytes)
    let registered {.global, gensym, used.} = registerCompiledAsset(loaded)
    Url(hostedPath(loaded))

template templateAsset*(name: static string): AssetRef =
  ## The same compile-time resolution as `asset`, yielding the full
  ## `AssetRef` (bytes included) for the image checks and `publish`.
  when isDataUri(name):
    {.error: "E-URL-SCHEME: data: URIs are forbidden (R-IMG-08)".}
  else:
    const caller {.gensym.} = instantiationInfo(fullPaths = true)
    const srcPath {.gensym.} =
      callerJoin(callerDirOf(caller.filename), name)
    const srcBytes {.gensym.} = staticRead(srcPath)
    const loaded {.gensym.} = loadAsset(name, srcBytes)
    loaded
