## bench/prelower.nim — the static pre-lowering prototype, kept out of
## the library.
##
## The idea: most of a template is static, and only its text varies
## from one recipient to the next. Run the passes once over a skeleton
## whose text is replaced by markers, cut the serialised HTML at the
## markers into fragments, and at render time write the recipient's
## text between the fragments instead of running the passes again.
##
## How the prototype does it, for a template `tpl` and data of type `T`:
##
## - **Slots.** Every string in the data is visited (objects, tuples,
##   sequences, arrays, refs and distinct strings, recursively; a proc
##   is opaque). A string is a candidate slot when it is *inert*: ASCII
##   letters, digits, single inner spaces and `. , : ; ! ? $ % + - ( ) *
##   _`, at least four non-space characters. Its HTML is then itself in
##   text and in attributes alike, so the fragments need no escaping.
## - **Markers.** A slot's marker keeps the value's shape: the same
##   length and the spaces in the same places, its first characters a
##   code naming the slot (`QJ` and the slot number in letters), the
##   rest `x`. A pass that reads word lengths (long-word breaking, the
##   preheader's padding) sees the same lengths it sees for the value.
## - **Classification** (once per data shape: the numbers, booleans,
##   enumerations and sequence lengths). Each candidate is rendered
##   alone as its marker, as its marker in the widest (`W`) and the
##   narrowest (`i`) letters, and with its last word three characters
##   longer. It is a *slot* when writing the value back where the marker
##   appears gives the plain render's bytes exactly and the width of the
##   letters changes nothing else; it is *length-sensitive* when the
##   longer marker changes anything else. A candidate the template reads
##   as a value (a network name, a number it parses, a status it
##   branches on for that value) or measures (an image's alt text,
##   whether it fits the image) is *fixed*.
## - **Skeleton** (once per key: the shape, every fixed string's value
##   and every length-sensitive slot's word lengths). All the slots are
##   rendered as their markers at once, the HTML is cut into fragments,
##   and the skeleton is used only when writing the datum it was built
##   from back into it gives that datum's plain HTML exactly.
## - **Render.** A datum whose key has a usable skeleton gets its HTML
##   from the fragments. Its plain-text part still comes from the text
##   pass, which wraps by length, over the template's tree after pattern
##   expansion; the MIME layer then packages both as for any render.
##   Anything else (a new key, a slot whose value is not inert) renders
##   on the plain path.
##
## What it cannot know is recorded here because it is why the prototype
## is not part of the library: a branch the template takes on a slot's
## value that the datum the skeleton was built from did not exercise; a
## measurement that changes only at a length the probes did not try; a
## proc in the data (its captured values are invisible); a diagnostic
## that depends on the text (a label that no longer fits its button, a
## link's words), which the skeleton path never computes; and a URL,
## never inert, so a per-recipient unsubscribe link makes every message
## a new key. The benchmark measures it against the plain path, and the
## test of the same name checks it byte for byte over every reference
## email.

import std/[strutils, tables, typetraits]
import isonim_email

type
  PrelowerPath* = enum
    ppSkeleton  ## the HTML written into a skeleton's fragments
    ppBuilt     ## a skeleton built from this datum (plain render)
    ppPlain     ## the plain path: no usable skeleton for this datum

  Classification = object
    ok: bool
    slot: seq[bool]        ## per string, in visiting order
    sensitive: seq[bool]   ## per slot: its word lengths are in the key

  Skeleton = object
    usable: bool
    fragments: seq[string]
    slotAt: seq[int]       ## the slot written after fragments[i]
    rendered: RenderedEmail ## the build datum's render (sizes, assets)

  PrelowerStats* = object
    renders*: array[PrelowerPath, int]
    classifyRenders*: int  ## plain renders spent classifying
    buildRenders*: int     ## plain renders spent building skeletons

  PrelowerCache*[T] = ref object
    ## The skeletons of one template, theme, target and profile.
    tpl: EmailTemplate[T]
    theme: EmailTheme
    target: EmailTarget
    profile: AudienceProfile
    assets: AssetStore
    classes: Table[string, Classification]
    skeletons: Table[string, Skeleton]
    stats*: PrelowerStats

proc newPrelowerCache*[T](tpl: EmailTemplate[T]; theme = defaultTheme();
    target = defaultTarget(); profile = consumer;
    assets: AssetStore = nil): PrelowerCache[T] =
  PrelowerCache[T](tpl: tpl, theme: theme, target: target,
    profile: profile, assets: assets)

# --- Visiting the data ----------------------------------------------------------

proc collect[T](x: T; strs: var seq[string]; shape: var string) =
  ## Every string of `x` in visiting order, and its shape.
  when T is string:
    strs.add(x)
  elif T is (SomeNumber or bool or enum or char):
    shape.add($x & ";")
  elif T is distinct:
    collect(distinctBase(T)(x), strs, shape)
  elif T is seq:
    shape.add("#" & $x.len & ";")
    for v in x:
      collect(v, strs, shape)
  elif T is array:
    for v in x:
      collect(v, strs, shape)
  elif T is ref:
    shape.add(if x == nil: "nil;" else: "ref;")
    if x != nil:
      collect(x[], strs, shape)
  elif T is (object or tuple):
    for _, v in fieldPairs(x):
      collect(v, strs, shape)
  elif (T is proc):
    discard # opaque: see the module comment
  else:
    {.error: "prelower: no visit for " & $T.}

proc assign[T](x: var T; strs: seq[string]; at: var int) =
  ## Writes `strs` back over `x`'s strings, in visiting order.
  when T is string:
    x = strs[at]
    inc at
  elif T is distinct:
    var base = distinctBase(T)(x)
    assign(base, strs, at)
    x = T(base)
  elif T is (seq or array):
    for v in x.mitems:
      assign(v, strs, at)
  elif T is ref:
    if x != nil:
      assign(x[], strs, at)
  elif T is (object or tuple):
    for _, v in fieldPairs(x):
      assign(v, strs, at)
  else:
    discard

proc withStrings[T](data: T; strs: seq[string]): T =
  result = data
  var at = 0
  assign(result, strs, at)

# --- Slots and markers -------------------------------------------------------------

const
  inertPunctuation = {'.', ',', ':', ';', '!', '?', '$', '%', '+', '-',
    '(', ')', '*', '_'}
  codeLetters = "bcdfghkmnpqrstvwyz" ## slot numbers, in base 18

proc isInert*(v: string): bool =
  ## A string the prototype can write between fragments as it is.
  if v.len == 0 or v[0] == ' ' or v[^1] == ' ' or "  " in v:
    return false
  var nonSpace = 0
  for c in v:
    if c == ' ':
      continue
    if not (c.isAlphaNumeric or c in inertPunctuation):
      return false
    inc nonSpace
  nonSpace >= 4

proc slotCode(i: int): string =
  ## `QJ` and `i` in letters: the marker's first characters.
  result = "QJ"
  var n = i
  var digits = ""
  while true:
    digits.add(codeLetters[n mod codeLetters.len])
    n = n div codeLetters.len
    if n == 0:
      break
  result.add(digits)

proc markerFor(i: int; v: string; longer = 0; fill = 'x'): string =
  ## `v`'s shape with slot `i`'s code at its start (see the module
  ## comment), the rest `fill`; "" when `v` is too short to carry the
  ## code.
  let code = slotCode(i)
  var k = 0
  for c in v:
    if c == ' ':
      result.add(' ')
    elif k < code.len:
      result.add(code[k])
      inc k
    else:
      result.add(fill)
  if k < code.len:
    return ""
  for _ in 0 ..< longer:
    result.add(fill)

proc wordShape(v: string): string =
  ## The word lengths of `v` (what a length-sensitive slot keys on).
  for w in v.split(' '):
    result.add($w.len & ".")

proc substitute(html: string; markers, values: openArray[string]): string =
  ## `html` with every marker replaced by its value.
  result = html
  for i, m in markers:
    if m.len > 0:
      result = result.replace(m, values[i])

# --- Rendering -----------------------------------------------------------------------

proc plain[T](c: PrelowerCache[T]; data: T): RenderedEmail =
  renderEmail(c.tpl, data, c.theme, c.target, c.profile, assets = c.assets)

proc tryHtml[T](c: PrelowerCache[T]; data: T): tuple[ok: bool; html: string] =
  ## The plain HTML of `data`, or not ok when the template refuses it (a
  ## marker where it parses a number, say).
  try:
    (true, plain(c, data).html)
  except CatchableError:
    (false, "")

proc shapeOf[T](data: T): tuple[strs: seq[string]; shape: string] =
  collect(data, result.strs, result.shape)

proc classify[T](c: PrelowerCache[T]; data: T;
    base: RenderedEmail): Classification =
  ## Which strings of `data` are slots, and which slots are
  ## length-sensitive (see the module comment).
  let (strs, _) = shapeOf(data)
  result.ok = true
  result.slot = newSeq[bool](strs.len)
  result.sensitive = newSeq[bool](strs.len)
  for i, v in strs:
    if not isInert(v):
      continue
    let m = markerFor(i, v)
    if m.len == 0:
      continue
    var probe = strs
    probe[i] = m
    let marked = tryHtml(c, withStrings(data, probe))
    inc c.stats.classifyRenders
    if not marked.ok or marked.html.replace(m, v) != base.html:
      continue
    # Width: the same shape in the widest and the narrowest letters. A
    # pass that measures the text (whether an image's alt text fits it,
    # a label its button) answers differently for text of another
    # width, so such a string is fixed.
    var widthSensitive = false
    for fill in ['W', 'i']:
      let mw = markerFor(i, v, fill = fill)
      probe[i] = mw
      let w = tryHtml(c, withStrings(data, probe))
      inc c.stats.classifyRenders
      if not w.ok or w.html.replace(mw, m) != marked.html:
        widthSensitive = true
    if widthSensitive:
      continue
    result.slot[i] = true
    let m2 = markerFor(i, v, longer = 3)
    probe[i] = m2
    let longer = tryHtml(c, withStrings(data, probe))
    inc c.stats.classifyRenders
    result.sensitive[i] = not longer.ok or
      longer.html.replace(m2, m) != marked.html

proc keyOf(cls: Classification; strs: seq[string]): tuple[ok: bool;
    key: string] =
  ## The skeleton key of a datum's strings, or not ok when a slot's
  ## value is not inert (its HTML would need escaping, or its marker
  ## could not carry the code).
  result.ok = true
  for i, v in strs:
    if cls.slot[i]:
      if not isInert(v) or markerFor(i, v).len == 0:
        return (false, "")
      result.key.add(if cls.sensitive[i]: "S" & wordShape(v) else: "S")
    else:
      result.key.add("F" & $v.len & ":" & v)
    result.key.add('\x1f')

proc build[T](c: PrelowerCache[T]; data: T; cls: Classification;
    strs: seq[string]; base: RenderedEmail): Skeleton =
  ## The skeleton of `data`: every slot as its marker, cut into fragments.
  var markers = newSeq[string](strs.len)
  var probe = strs
  for i, v in strs:
    if cls.slot[i]:
      markers[i] = markerFor(i, v)
      probe[i] = markers[i]
  let marked = tryHtml(c, withStrings(data, probe))
  inc c.stats.buildRenders
  if not marked.ok or substitute(marked.html, markers, strs) != base.html:
    return Skeleton(usable: false)
  # Cut at every marker, left to right.
  var at = 0
  var fragment = ""
  result = Skeleton(usable: true, rendered: base)
  let html = marked.html
  while at < html.len:
    var hit = -1
    if html[at] == 'Q':
      for i, m in markers:
        if m.len > 0 and html.continuesWith(m, at):
          hit = i
          break
    if hit < 0:
      fragment.add(html[at])
      inc at
    else:
      result.fragments.add(fragment)
      result.slotAt.add(hit)
      fragment = ""
      at += markers[hit].len
  result.fragments.add(fragment)

proc fill(sk: Skeleton; strs: seq[string]): string =
  ## The fragments with the datum's slot values between them.
  var size = 0
  for f in sk.fragments:
    size += f.len
  result = newStringOfCap(size + 64 * sk.slotAt.len)
  for i, f in sk.fragments:
    result.add(f)
    if i < sk.slotAt.len:
      result.add(strs[sk.slotAt[i]])

proc renderPrelowered*[T](c: PrelowerCache[T]; data: T): tuple[
    rendered: RenderedEmail; path: PrelowerPath] =
  ## `data` rendered through the skeleton cache (see the module comment).
  let (strs, shape) = shapeOf(data)
  if shape notin c.classes:
    let base = plain(c, data)
    c.classes[shape] = classify(c, data, base)
    let (ok, key) = keyOf(c.classes[shape], strs)
    if ok:
      c.skeletons[key] = build(c, data, c.classes[shape], strs, base)
    inc c.stats.renders[ppBuilt]
    return (base, ppBuilt)
  let cls = c.classes[shape]
  let (ok, key) = keyOf(cls, strs)
  if not ok:
    inc c.stats.renders[ppPlain]
    return (plain(c, data), ppPlain)
  if key notin c.skeletons:
    let base = plain(c, data)
    c.skeletons[key] = build(c, data, cls, strs, base)
    inc c.stats.renders[ppBuilt]
    return (base, ppBuilt)
  let sk = c.skeletons[key]
  if not sk.usable:
    inc c.stats.renders[ppPlain]
    return (plain(c, data), ppPlain)
  # The text part: the text pass over the template's tree after pattern
  # expansion; it wraps by length, so it is never a skeleton.
  let tree = renderAuthoringTree(c.tpl, data)
  var diags = expandPatterns(tree, c.theme, c.target)
  let text = renderText(tree)
  diags.add(text.diagnostics)
  var r = sk.rendered
  r.html = fill(sk, strs)
  r.htmlBytes = r.html.len
  r.text = text.text
  r.textFlowed = text.text.len > 0
  r.diagnostics = diags
  r.semantic = tree
  inc c.stats.renders[ppSkeleton]
  (r, ppSkeleton)

proc slotCount*[T](c: PrelowerCache[T]; data: T): tuple[strings, slots,
    sensitive: int] =
  ## How many of `data`'s strings are slots (after a first render).
  let (strs, shape) = shapeOf(data)
  result.strings = strs.len
  if shape in c.classes:
    for i in 0 ..< strs.len:
      if c.classes[shape].slot[i]:
        inc result.slots
        if c.classes[shape].sensitive[i]:
          inc result.sensitive

proc shifted(v: string; n: int): string =
  ## `v` with its letters and digits moved `n` places (case and length
  ## kept): another recipient's text of the same shape.
  result = v
  for i, ch in result.mpairs:
    if ch in 'a'..'z': ch = chr(ord('a') + (ord(ch) - ord('a') + n) mod 26)
    elif ch in 'A'..'Z':
      # Never spell the marker code.
      ch = chr(ord('A') + (ord(ch) - ord('A') + n) mod 26)
      if ch in {'Q', 'J'}: ch = 'K'
    elif ch in '0'..'9': ch = chr(ord('0') + (ord(ch) - ord('0') + n) mod 10)

proc personalised*[T](c: PrelowerCache[T]; data: T; n: int;
    longer = false; urls = false): T =
  ## `data` as recipient `n` gets it: every slot's letters and digits
  ## moved `n` places, and with `longer` a word added to it, so its
  ## length differs. Fixed strings stay as they are (they are the
  ## template's), except, with `urls`, a per-recipient link: an https
  ## URL with a `?u=` token gets `n` added to the token, as a sender's
  ## unsubscribe and preferences links do. Needs a first render of
  ## `data`.
  let (strs, shape) = shapeOf(data)
  doAssert shape in c.classes, "render the datum once first"
  var next = strs
  for i, v in strs:
    if n == 0:
      continue
    if c.classes[shape].slot[i]:
      next[i] = shifted(v, n)
      if longer:
        next[i].add(" " & "abc"[0 ..< 1 + n mod 3])
    elif urls and v.startsWith("https://") and "?u=" in v:
      next[i] = v & $n
  withStrings(data, next)
