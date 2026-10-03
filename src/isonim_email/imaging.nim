## isonim_email/imaging.nim — reading a PNG's pixels.
##
## The dark-safety heuristic for logos (catalogue R-DRK-06) looks at
## where an image is transparent and what colour its edges are, so it
## needs the decoded pixels, not just the header `assets.probeImage`
## reads. This module decodes a PNG into 8-bit RGBA: the zlib stream
## (RFC 1950/1951 inflate: stored, fixed and dynamic Huffman blocks,
## after zlib's own `puff.c` reference decoder), the five scanline
## filters, every colour type (grey, RGB, palette, grey + alpha, RGBA)
## at bit depths 1–16, with `tRNS` transparency.
##
## What is verified, each failure giving `ok = false`: the PNG
## signature; every chunk's CRC-32 (over its type and data, up to and
## including `IEND`) and length within the file; `IHDR` first, with a
## known colour type and bit depth pair and no interlacing (interlaced
## images are not read); the zlib header of the concatenated `IDAT`
## data (compression method 8, a window of at most 32 KiB, no preset
## dictionary, FCHECK making the header a multiple of 31); each stored
## block's NLEN (the one's complement of LEN); every Huffman code and
## back-reference distance; the decompressed size (no more than the
## scanlines need, so a stream cannot expand without bound, and no
## less); each row's filter type; palette indices; and the zlib stream's
## Adler-32 over the decompressed data. An image larger than
## `maxDecodePixels` is not decompressed at all (`tooLarge = true`). A
## failed decode is never an error of the render: the caller skips its
## check.
##
## The other way, `encodePng` writes RGBA pixels as an 8-bit RGBA PNG:
## each row under the filter whose bytes sum smallest (libpng's
## heuristic), one zlib stream of one fixed-Huffman DEFLATE block
## (RFC 1951 §3.2.6) over greedy LZ77 matches (a 32 KiB window, hash
## chains of at most 64 candidates), its Adler-32, and the chunks'
## CRC-32s. The bytes depend only on the pixels, so a crop made from the
## same source is the same file every time (catalogue R-IMG-13).
## `cropPixels`, `centredCrop` and `circleMask` make the crops.
##
## Pure arithmetic over strings: identical on the C and JS targets.

import std/math
import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  Pixels* = object
    ## A decoded image: `width` × `height` RGBA pixels, row-major, 4
    ## bytes each.
    ok*: bool
    tooLarge*: bool ## Over `maxDecodePixels`: not decompressed
    width*, height*: int
    rgba*: seq[uint8]

  InflateError = object of CatchableError

  BitReader = object
    data: string
    pos: int    ## the next byte
    bitBuf: int ## bits not consumed yet, LSB first
    bitCnt: int

  Huffman = object
    counts: array[16, int]
    symbols: seq[int]

const
  maxDecodePixels* = 4096 * 4096
    ## The most pixels `decodePng` decompresses (16 Mpx, 64 MiB of
    ## RGBA): a robustness bound, since the image is the author's own.
  lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3,
    3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289,
    16385, 24577]
  distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13,
    2, 14, 1, 15]

proc fail(why: string) {.noreturn.} =
  raise newException(InflateError, why)

proc bits(br: var BitReader; n: int): int =
  ## The next `n` bits, least significant first (RFC 1951 §3.1.1).
  while br.bitCnt < n:
    if br.pos >= br.data.len:
      fail("truncated stream")
    br.bitBuf = br.bitBuf or (ord(br.data[br.pos]) shl br.bitCnt)
    inc br.pos
    br.bitCnt += 8
  result = br.bitBuf and ((1 shl n) - 1)
  br.bitBuf = br.bitBuf shr n
  br.bitCnt -= n

proc buildHuffman(lengths: openArray[int]): Huffman =
  ## A canonical Huffman code from its code lengths (`puff.c`'s
  ## `construct`).
  for l in lengths:
    inc result.counts[l]
  var offs: array[16, int]
  for i in 1 .. 14:
    offs[i + 1] = offs[i] + result.counts[i]
  result.symbols = newSeq[int](lengths.len)
  for sym, l in lengths:
    if l != 0:
      result.symbols[offs[l]] = sym
      inc offs[l]

proc decodeSymbol(br: var BitReader; h: Huffman): int =
  ## One symbol (`puff.c`'s `decode`).
  var code, first, index = 0
  for len in 1 .. 15:
    code = code or br.bits(1)
    let count = h.counts[len]
    if code - count < first:
      return h.symbols[index + (code - first)]
    index += count
    first += count
    first = first shl 1
    code = code shl 1
  fail("bad Huffman code")

proc inflateCodes(br: var BitReader; output: var string;
                  lit, dist: Huffman; maxLen: int) =
  while true:
    if output.len > maxLen:
      fail("decompresses past its bound")
    let sym = decodeSymbol(br, lit)
    if sym < 256:
      output.add(chr(sym))
    elif sym == 256:
      return
    else:
      let li = sym - 257
      if li >= lengthBase.len:
        fail("bad length symbol")
      let length = lengthBase[li] + br.bits(lengthExtra[li])
      let di = decodeSymbol(br, dist)
      if di >= distBase.len:
        fail("bad distance symbol")
      let distance = distBase[di] + br.bits(distExtra[di])
      if distance > output.len:
        fail("distance too far back")
      for _ in 0 ..< length:
        # One byte at a time: a copy may overlap what it writes.
        let c = output[output.len - distance]
        output.add(c)

proc fixedTables(): (Huffman, Huffman) =
  var lengths = newSeq[int](288)
  for i in 0 .. 143: lengths[i] = 8
  for i in 144 .. 255: lengths[i] = 9
  for i in 256 .. 279: lengths[i] = 7
  for i in 280 .. 287: lengths[i] = 8
  var d = newSeq[int](30)
  for i in 0 ..< 30: d[i] = 5
  (buildHuffman(lengths), buildHuffman(d))

proc dynamicTables(br: var BitReader): (Huffman, Huffman) =
  let nlen = br.bits(5) + 257
  let ndist = br.bits(5) + 1
  let ncode = br.bits(4) + 4
  if nlen > 286 or ndist > 30:
    fail("bad table sizes")
  var cl = newSeq[int](19)
  for i in 0 ..< ncode:
    cl[codeLengthOrder[i]] = br.bits(3)
  let clh = buildHuffman(cl)
  var lengths = newSeq[int](nlen + ndist)
  var i = 0
  while i < nlen + ndist:
    let sym = decodeSymbol(br, clh)
    if sym < 16:
      lengths[i] = sym
      inc i
    else:
      var value = 0
      var rep = 0
      case sym
      of 16:
        if i == 0:
          fail("repeat with no previous length")
        value = lengths[i - 1]
        rep = 3 + br.bits(2)
      of 17:
        rep = 3 + br.bits(3)
      else:
        rep = 11 + br.bits(7)
      if i + rep > nlen + ndist:
        fail("too many lengths")
      for _ in 0 ..< rep:
        lengths[i] = value
        inc i
  (buildHuffman(lengths[0 ..< nlen]), buildHuffman(lengths[nlen .. ^1]))

proc crc32*(data: string): uint32 =
  ## CRC-32 (ISO 3309, as PNG and zlib's `crc32` compute it).
  var c = 0xFFFFFFFF'u32
  for ch in data:
    c = c xor uint32(ord(ch))
    for _ in 0 ..< 8:
      c = if (c and 1'u32) != 0'u32: (c shr 1) xor 0xEDB88320'u32
        else: c shr 1
  c xor 0xFFFFFFFF'u32

proc adler32*(data: string): uint32 =
  ## Adler-32 (RFC 1950).
  var a = 1'u32
  var b = 0'u32
  for ch in data:
    a = (a + uint32(ord(ch))) mod 65521'u32
    b = (b + a) mod 65521'u32
  (b shl 16) or a

proc inflateAt(data: string; start: int; maxLen: int;
               endPos: var int): string =
  ## The raw DEFLATE stream at `data[start ..]` decompressed, failing
  ## past `maxLen` bytes; `endPos` is the first byte after the stream.
  var br = BitReader(data: data, pos: start)
  var output = ""
  var last = 0
  while last == 0:
    last = br.bits(1)
    # Read once, before the `case`: the JS backend evaluates a `case`
    # selector more than once, and this one consumes bits.
    let blockType = br.bits(2)
    case blockType
    of 0:
      br.bitBuf = 0
      br.bitCnt = 0
      if br.pos + 4 > data.len:
        fail("truncated stored block")
      let n = ord(data[br.pos]) or (ord(data[br.pos + 1]) shl 8)
      let nlen = ord(data[br.pos + 2]) or (ord(data[br.pos + 3]) shl 8)
      if nlen != ((not n) and 0xFFFF):
        fail("stored block NLEN is not the complement of LEN")
      br.pos += 4
      if br.pos + n > data.len:
        fail("truncated stored block")
      output.add(data[br.pos ..< br.pos + n])
      br.pos += n
    of 1:
      let (l, d) = fixedTables()
      inflateCodes(br, output, l, d, maxLen)
    of 2:
      let (l, d) = dynamicTables(br)
      inflateCodes(br, output, l, d, maxLen)
    else:
      fail("bad block type")
    if output.len > maxLen:
      fail("decompresses past its bound")
  endPos = br.pos
  output

proc inflate*(data: string; start = 0; maxLen = high(int)): string =
  ## The raw DEFLATE stream at `data[start ..]` decompressed. Raises
  ## `CatchableError` on a corrupt stream, or one that decompresses past
  ## `maxLen` bytes.
  var endPos = 0
  inflateAt(data, start, maxLen, endPos)

proc zlibDecompress*(data: string; maxLen = high(int)): string =
  ## A zlib stream (RFC 1950) decompressed, its header and Adler-32
  ## checked. Raises `CatchableError` when either is wrong or the
  ## stream is corrupt.
  if data.len < 6:
    fail("truncated zlib stream")
  let cmf = ord(data[0])
  let flg = ord(data[1])
  if (cmf and 0x0F) != 8 or (cmf shr 4) > 7:
    fail("not deflate with a window of at most 32 KiB")
  if (cmf * 256 + flg) mod 31 != 0:
    fail("zlib header check (FCHECK) fails")
  if (flg and 0x20) != 0:
    fail("a preset dictionary")
  var endPos = 0
  result = inflateAt(data, 2, maxLen, endPos)
  if endPos + 4 > data.len:
    fail("truncated Adler-32")
  let want = (uint32(ord(data[endPos])) shl 24) or
    (uint32(ord(data[endPos + 1])) shl 16) or
    (uint32(ord(data[endPos + 2])) shl 8) or uint32(ord(data[endPos + 3]))
  if adler32(result) != want:
    fail("Adler-32 mismatch")

proc be32(s: string; at: int): int =
  (ord(s[at]) shl 24) or (ord(s[at + 1]) shl 16) or (ord(s[at + 2]) shl 8) or
    ord(s[at + 3])

proc paeth(a, b, c: int): int =
  let p = a + b - c
  let pa = abs(p - a)
  let pb = abs(p - b)
  let pc = abs(p - c)
  if pa <= pb and pa <= pc: a
  elif pb <= pc: b
  else: c

proc decodePng*(bytes: string): Pixels =
  ## `bytes` as RGBA pixels; `ok = false` for anything that is not a
  ## non-interlaced PNG this decoder reads.
  const sig = "\x89PNG\r\n\x1A\n"
  if bytes.len < 33 or bytes[0 ..< 8] != sig:
    return
  var width, height, depth, colorType, interlace = 0
  var palette: seq[array[4, uint8]] = @[]
  var trns = ""
  var idat = ""
  var p = 8
  var sawEnd = false
  while p + 12 <= bytes.len:
    let n = be32(bytes, p)
    if n < 0 or p + 12 + n > bytes.len:
      return
    let typ = bytes[p + 4 ..< p + 8]
    let body = bytes[p + 8 ..< p + 8 + n]
    let at = p + 8 + n
    let crc = (uint32(ord(bytes[at])) shl 24) or
      (uint32(ord(bytes[at + 1])) shl 16) or
      (uint32(ord(bytes[at + 2])) shl 8) or uint32(ord(bytes[at + 3]))
    if crc32(typ & body) != crc:
      return
    if p == 8 and typ != "IHDR":
      return
    case typ
    of "IHDR":
      if n < 13:
        return
      width = be32(body, 0)
      height = be32(body, 4)
      depth = ord(body[8])
      colorType = ord(body[9])
      interlace = ord(body[12])
    of "PLTE":
      var i = 0
      while i + 2 < body.len:
        palette.add([uint8(ord(body[i])), uint8(ord(body[i + 1])),
          uint8(ord(body[i + 2])), 255'u8])
        i += 3
    of "tRNS":
      trns = body
    of "IDAT":
      idat.add(body)
    of "IEND":
      sawEnd = true
      break
    else:
      discard
    p += 12 + n
  if not sawEnd or width <= 0 or height <= 0 or interlace != 0 or
      idat.len < 2:
    return
  if width > 65535 or height > 65535 or width * height > maxDecodePixels:
    result.tooLarge = true
    result.width = width
    result.height = height
    return
  let channels = case colorType
    of 0: 1
    of 2: 3
    of 3: 1
    of 4: 2
    of 6: 4
    else: 0
  if channels == 0 or depth notin [1, 2, 4, 8, 16] or
      (depth > 8 and colorType == 3) or (depth < 8 and colorType in {2, 4, 6}):
    return
  if colorType == 3:
    for i in 0 ..< min(trns.len, palette.len):
      palette[i][3] = uint8(ord(trns[i]))
  let bitsPerPixel = channels * depth
  let stride = (width * bitsPerPixel + 7) div 8
  let bpp = max(1, bitsPerPixel div 8)
  var raw: string
  try:
    raw = zlibDecompress(idat, maxLen = height * (stride + 1))
  except CatchableError:
    return
  if raw.len != height * (stride + 1):
    return
  var prev = newSeq[int](stride)
  var cur = newSeq[int](stride)
  result.rgba = newSeq[uint8](width * height * 4)
  let maxSample = (1 shl depth) - 1
  # A grey or RGB `tRNS` names one transparent colour, at the bit depth.
  var trnsKey: seq[int] = @[]
  if colorType in {0, 2} and trns.len >= 2 * channels:
    for c in 0 ..< channels:
      trnsKey.add((ord(trns[2 * c]) shl 8) or ord(trns[2 * c + 1]))
  for y in 0 ..< height:
    let base = y * (stride + 1)
    let filter = ord(raw[base])
    if filter > 4:
      return
    for x in 0 ..< stride:
      let v = ord(raw[base + 1 + x])
      let a = if x >= bpp: cur[x - bpp] else: 0
      let b = prev[x]
      let c = if x >= bpp: prev[x - bpp] else: 0
      cur[x] = case filter
        of 0: v
        of 1: (v + a) and 0xFF
        of 2: (v + b) and 0xFF
        of 3: (v + (a + b) div 2) and 0xFF
        else: (v + paeth(a, b, c)) and 0xFF
    proc sample(x, ch: int): int =
      ## Channel `ch` of pixel `x` on this row, at the image's depth.
      if depth == 16:
        let at = (x * channels + ch) * 2
        (cur[at] shl 8) or cur[at + 1]
      elif depth == 8:
        cur[x * channels + ch]
      else:
        let bit = (x * channels + ch) * depth
        (cur[bit div 8] shr (8 - depth - bit mod 8)) and maxSample
    proc to8(v: int): uint8 =
      ## A sample at 8 bits: a 16-bit one's high byte, a narrower one
      ## scaled up.
      if depth == 16: uint8(v shr 8) else: uint8(v * 255 div maxSample)
    for x in 0 ..< width:
      let o = (y * width + x) * 4
      var px: array[4, uint8]
      case colorType
      of 0:
        let g = sample(x, 0)
        px = [to8(g), to8(g), to8(g), 255'u8]
        if trnsKey.len == 1 and g == trnsKey[0]:
          px[3] = 0
      of 2:
        let (r, g, b) = (sample(x, 0), sample(x, 1), sample(x, 2))
        px = [to8(r), to8(g), to8(b), 255'u8]
        if trnsKey.len == 3 and r == trnsKey[0] and g == trnsKey[1] and
            b == trnsKey[2]:
          px[3] = 0
      of 3:
        let i = sample(x, 0)
        if i >= palette.len:
          return
        px = palette[i]
      of 4:
        let g = to8(sample(x, 0))
        px = [g, g, g, to8(sample(x, 1))]
      else:
        px = [to8(sample(x, 0)), to8(sample(x, 1)), to8(sample(x, 2)),
          to8(sample(x, 3))]
      for k in 0 .. 3:
        result.rgba[o + k] = px[k]
    swap(prev, cur)
  result.width = width
  result.height = height
  result.ok = true


# --- Encoding -----------------------------------------------------------------

type BitWriter = object
  data: string
  bitBuf: int ## bits not written yet, LSB first
  bitCnt: int

proc put(bw: var BitWriter; value, n: int) =
  ## `n` bits of `value`, least significant first (RFC 1951 §3.1.1).
  bw.bitBuf = bw.bitBuf or (value shl bw.bitCnt)
  bw.bitCnt += n
  while bw.bitCnt >= 8:
    bw.data.add(chr(bw.bitBuf and 0xFF))
    bw.bitBuf = bw.bitBuf shr 8
    bw.bitCnt -= 8

proc putCode(bw: var BitWriter; code, len: int) =
  ## A Huffman code, packed starting with its most significant bit.
  var rev = 0
  for i in 0 ..< len:
    rev = (rev shl 1) or ((code shr i) and 1)
  bw.put(rev, len)

proc putSymbol(bw: var BitWriter; sym: int) =
  ## A literal/length symbol in the fixed code (RFC 1951 §3.2.6).
  if sym <= 143: bw.putCode(0x30 + sym, 8)
  elif sym <= 255: bw.putCode(0x190 + sym - 144, 9)
  elif sym <= 279: bw.putCode(sym - 256, 7)
  else: bw.putCode(0xC0 + sym - 280, 8)

proc putMatch(bw: var BitWriter; length, distance: int) =
  var i = lengthBase.high
  while lengthBase[i] > length:
    dec i
  bw.putSymbol(257 + i)
  if lengthExtra[i] > 0:
    bw.put(length - lengthBase[i], lengthExtra[i])
  var d = distBase.high
  while distBase[d] > distance:
    dec d
  bw.putCode(d, 5)
  if distExtra[d] > 0:
    bw.put(distance - distBase[d], distExtra[d])

proc deflateFixed*(data: string): string =
  ## `data` as one raw DEFLATE block with the fixed Huffman codes over
  ## greedy LZ77 matches (deterministic: no clock, no randomness).
  const hashBits = 15
  const window = 32768
  const maxChain = 64
  var bw = BitWriter()
  bw.put(1, 1) # BFINAL
  bw.put(1, 2) # BTYPE 01: fixed codes
  var head = newSeq[int](1 shl hashBits)
  for k in 0 ..< head.len:
    head[k] = -1
  var link = newSeq[int](data.len)
  proc hashAt(i: int): int =
    ((ord(data[i]) shl 10) xor (ord(data[i + 1]) shl 5) xor
      ord(data[i + 2])) and ((1 shl hashBits) - 1)
  proc insert(i: int) =
    if i + 2 < data.len:
      let h = hashAt(i)
      link[i] = head[h]
      head[h] = i
  var i = 0
  while i < data.len:
    var bestLen = 0
    var bestDist = 0
    if i + 2 < data.len:
      let maxLen = min(258, data.len - i)
      var cand = head[hashAt(i)]
      var chain = 0
      while cand >= 0 and i - cand <= window and chain < maxChain:
        var l = 0
        while l < maxLen and data[cand + l] == data[i + l]:
          inc l
        if l > bestLen:
          bestLen = l
          bestDist = i - cand
          if l == maxLen:
            break
        cand = link[cand]
        inc chain
    if bestLen >= 3:
      bw.putMatch(bestLen, bestDist)
      for k in i ..< i + bestLen:
        insert(k)
      i += bestLen
    else:
      bw.putSymbol(ord(data[i]))
      insert(i)
      inc i
  bw.putSymbol(256)
  if bw.bitCnt > 0:
    bw.data.add(chr(bw.bitBuf and 0xFF))
  bw.data

proc beBytes(v: uint32): string =
  result = newString(4)
  result[0] = chr(int((v shr 24) and 0xFF'u32))
  result[1] = chr(int((v shr 16) and 0xFF'u32))
  result[2] = chr(int((v shr 8) and 0xFF'u32))
  result[3] = chr(int(v and 0xFF'u32))

proc zlibCompress*(data: string): string =
  ## `data` as a zlib stream (RFC 1950): a 32 KiB window header, one
  ## fixed-code DEFLATE block, the Adler-32.
  "\x78\x01" & deflateFixed(data) & beBytes(adler32(data))

proc pngChunk(typ, body: string): string =
  beBytes(uint32(body.len)) & typ & body & beBytes(crc32(typ & body))

proc encodePng*(p: Pixels): string =
  ## `p` as an 8-bit RGBA PNG (see the module comment). `p` must hold
  ## `width × height` RGBA pixels.
  doAssert p.width > 0 and p.height > 0 and
    p.rgba.len == p.width * p.height * 4
  let stride = p.width * 4
  var raw = newStringOfCap(p.height * (stride + 1))
  var prev = newSeq[int](stride)
  var cur = newSeq[int](stride)
  var best = newSeq[int](stride)
  var trial = newSeq[int](stride)
  for y in 0 ..< p.height:
    for x in 0 ..< stride:
      cur[x] = int(p.rgba[y * stride + x])
    var bestFilter = 0
    var bestCost = high(int)
    for f in 0 .. 4:
      var cost = 0
      for x in 0 ..< stride:
        let a = if x >= 4: cur[x - 4] else: 0
        let b = prev[x]
        let c = if x >= 4: prev[x - 4] else: 0
        let pred = case f
          of 0: 0
          of 1: a
          of 2: b
          of 3: (a + b) div 2
          else: paeth(a, b, c)
        let v = (cur[x] - pred) and 0xFF
        trial[x] = v
        cost += (if v < 128: v else: 256 - v)
      if cost < bestCost:
        bestCost = cost
        bestFilter = f
        for x in 0 ..< stride:
          best[x] = trial[x]
    raw.add(chr(bestFilter))
    for x in 0 ..< stride:
      raw.add(chr(best[x]))
    swap(prev, cur)
  var ihdr = beBytes(uint32(p.width)) & beBytes(uint32(p.height))
  ihdr.add("\x08\x06\x00\x00\x00") # 8 bits, RGBA, deflate, adaptive, not interlaced
  "\x89PNG\r\n\x1A\n" & pngChunk("IHDR", ihdr) &
    pngChunk("IDAT", zlibCompress(raw)) & pngChunk("IEND", "")

# --- Crops --------------------------------------------------------------------

proc centredCrop*(width, height, rw, rh: int): tuple[x, y, w, h: int] =
  ## The largest rectangle of ratio `rw:rh` centred in `width × height`
  ## (whole pixels; the spare pixel of an odd margin goes after it).
  var w = width
  var h = height
  if width * rh > height * rw:
    w = max(1, (height * rw + rh div 2) div rh)
  else:
    h = max(1, (width * rh + rw div 2) div rw)
  ((width - w) div 2, (height - h) div 2, w, h)

proc cropPixels*(p: Pixels; x, y, w, h: int): Pixels =
  ## The `w × h` rectangle of `p` at (`x`, `y`).
  doAssert x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= p.width and
    y + h <= p.height
  result = Pixels(ok: true, width: w, height: h,
    rgba: newSeq[uint8](w * h * 4))
  for row in 0 ..< h:
    let src = ((y + row) * p.width + x) * 4
    let dst = row * w * 4
    for k in 0 ..< w * 4:
      result.rgba[dst + k] = p.rgba[src + k]

proc circleMask*(p: var Pixels) =
  ## Makes every pixel outside the circle inscribed in `p` transparent,
  ## and scales the alpha of the pixels its edge crosses by how far
  ## inside it their centre is (a one-pixel anti-aliased edge).
  let r = min(p.width, p.height) / 2
  let cx = p.width / 2
  let cy = p.height / 2
  for y in 0 ..< p.height:
    for x in 0 ..< p.width:
      let dx = float(x) + 0.5 - cx
      let dy = float(y) + 0.5 - cy
      let cover = clamp(r - sqrt(dx * dx + dy * dy) + 0.5, 0.0, 1.0)
      let o = (y * p.width + x) * 4 + 3
      p.rgba[o] = uint8(int(float(p.rgba[o]) * cover + 0.5))
