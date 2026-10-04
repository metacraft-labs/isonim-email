## The reference set (`examples/reference_set.nim`): the invariants every
## reference email keeps, rendered with Outlook's Word output on and off:
##
## - no error diagnostic (it lints clean), and no error under `strict`;
## - the decoded HTML within the size budget (R-SIZE-01) and the head
##   CSS within its own (R-CSS-07);
## - every table carries a `role`; every image an `alt`, a `width` and
##   `display:block`;
## - the head CSS is well formed: balanced braces, lower-case outside
##   quoted strings and URLs, no at-rule inside an at-rule (R-CSS-03,
##   R-CSS-04);
## - Outlook's conditional comments are balanced;
## - `lang` and `dir` on `<html>` and on the message's wrapper;
## - a plain-text part, holding the unsubscribe URL;
## - a footer whose unsubscribe link is in the HTML;
## - as a message: every body line within 76 characters (quoted-printable
##   and base64 alike, RFC 2045).
##
## Vacuity guard: the set covers every `mail*` element of the vocabulary
## (patterns, primitives and items included) and every layout, and each
## of the edge cases it is there for: right to left in Hebrew and
## Arabic, Japanese and Chinese, long unbroken words, a missing (404)
## image, text over a hero image, sections of one to four columns, a
## message near the 90 KB budget, and, in the designed dark palette,
## every colour token of the theme.
##
## C backend only: the reference set reads its images at compile time,
## as the capture drivers do, and the message is assembled with the MIME
## writer. No test doubles.
import std/[sets, strutils, tables, unittest]
import isonim_email
import stories/seed_reference
import reference_set

const tagParents = staticTagParents()
  ## Every element of the static vocabulary, patterns and items included.

proc vocabularyElements(): seq[string] =
  ## The `mail*` elements and `codeInline`.
  for (name, _) in tagParents:
    if name.startsWith("mail") or name == "codeInline":
      result.add(name)

proc collect(n: EmailNode; acc: var HashSet[string]) =
  if n.kind == enElement:
    acc.incl(n.tag)
  for c in n.children:
    collect(c, acc)

proc countOf(n: EmailNode; tag: string): int =
  if n.kind == enElement and n.tag == tag:
    inc result
  for c in n.children:
    result += countOf(c, tag)

proc tagsOf(html, tag: string): seq[string] =
  ## Every opening `<tag …>` of `html`, as written.
  var i = 0
  let open = "<" & tag
  while true:
    i = html.find(open, i)
    if i < 0:
      break
    let after = i + open.len
    if after < html.len and html[after] in {' ', '>', '/'}:
      let e = html.find('>', i)
      result.add(html[i .. e])
    i = after

proc styleBlocks(html: string): seq[string] =
  var i = 0
  while true:
    let s = html.find("<style>", i)
    if s < 0:
      break
    let e = html.find("</style>", s)
    result.add(html[s + "<style>".len ..< e])
    i = e

proc unquoted(css: string): string =
  ## `css` without its quoted strings and `url(…)` arguments.
  var i = 0
  while i < css.len:
    if css[i] in {'"', '\''}:
      let q = css[i]
      inc i
      while i < css.len and css[i] != q:
        inc i
      inc i
    elif css.continuesWith("url(", i):
      let e = css.find(')', i)
      i = (if e < 0: css.len else: e + 1)
    else:
      result.add(css[i])
      inc i

proc declarationBlocks(css: string): seq[string] =
  ## The contents of every innermost `{…}` block: the declarations.
  var start = -1
  for i, ch in css:
    if ch == '{':
      start = i
    elif ch == '}' and start >= 0:
      result.add(css[start + 1 ..< i])
      start = -1

proc atRulesNest(css: string): bool =
  ## True when an at-rule's block holds another at-rule.
  var depth = 0
  var atDepths: seq[int] = @[]
  var pendingAt = false
  for ch in css:
    case ch
    of '@':
      if atDepths.len > 0:
        return true
      pendingAt = true
    of '{':
      inc depth
      if pendingAt:
        atDepths.add(depth)
        pendingAt = false
    of '}':
      if atDepths.len > 0 and atDepths[^1] == depth:
        discard atDepths.pop()
      dec depth
    else:
      discard
  false

proc conditionalsBalance(html: string): bool =
  ## Every Outlook conditional comment that opens closes.
  html.count("<!--[if ") == html.count("<![endif]-->")

proc targetWith(word: bool): EmailTarget =
  result = defaultTarget()
  result.outlookWord = word

let emails = referenceEmails()

suite "the reference set keeps the invariants":
  test "test_reference_set_invariants":
    # Vacuity guard, part one: the set is not empty, every email renders.
    check emails.len >= 14
    var names = initHashSet[string]()
    for e in emails:
      check e.name notin names
      names.incl(e.name)
      let lower = e.name.toLowerAscii()
      for word in [true, false]:
        let t = targetWith(word)
        let res = renderReference(e, t)
        let where = e.name & " (outlookWord = " & $word & ")"
        # Lints clean: no error.
        for d in res.diagnostics:
          if d.severity == sevError:
            checkpoint(where & ": " & d.code & " " & d.message)
        check not hasErrors(res.diagnostics)
        # The size budgets.
        check res.htmlBytes <= t.sizeBudget
        check res.headCssBytes <= t.headStyleBudget
        for d in res.diagnostics:
          check d.code != codeSizeNearClip
        # Tables, images.
        let tables = tagsOf(res.html, "table")
        check tables.len > 0
        for tb in tables:
          if "role=" notin tb:
            checkpoint(where & ": " & tb)
          check "role=" in tb
        for img in tagsOf(res.html, "img"):
          # `display:block`, or the catalogue's inline form (R-IMG-03: an
          # image in a line of text, `vertical-align:middle` and no
          # `display` at all), or the dark image of a light/dark pair,
          # hidden until the dark block shows it (R-IMG-06).
          let blockOrInline = "display:block" in img or
            ("vertical-align:middle" in img and "display:" notin img) or
            ("style=\"display:none;" in img and "dk-show" in img)
          if not ("alt=" in img and "width=" in img and blockOrInline):
            checkpoint(where & ": " & img)
          check "alt=" in img
          check "width=" in img
          check blockOrInline
        # Head CSS.
        for css in styleBlocks(res.html):
          check css.count('{') == css.count('}')
          # Declarations are lower-case; selectors are as the catalogue
          # writes them (its client-targeting IDs and classes, such as
          # `#MessageViewBody` and `.aBn`, are case-sensitive).
          for decls in declarationBlocks(unquoted(css)):
            if decls != decls.toLowerAscii():
              checkpoint(where & ": upper case in {" & decls & "}")
            check decls == decls.toLowerAscii()
          check not atRulesNest(css)
        # Outlook's conditionals.
        check conditionalsBalance(res.html)
        # lang and dir on <html> and on the wrapper.
        let html = tagsOf(res.html, "html")[0]
        let doc = res.semantic
        let lang = doc.attrs["lang"]
        let dir = doc.attrs["dir"]
        check ("lang=\"" & lang & "\"") in html
        check ("dir=\"" & dir & "\"") in html
        var wrapper = ""
        for d in tagsOf(res.html, "div"):
          if "role=\"article\"" in d:
            wrapper = d
        check ("lang=\"" & lang & "\"") in wrapper
        check ("dir=\"" & dir & "\"") in wrapper
        # The text part, with the unsubscribe link; the footer's link.
        check res.text.strip().len > 0
        check "https://example.com/unsubscribe?u=4f2a" in res.text
        check "href=\"https://example.com/unsubscribe?u=4f2a\"" in res.html
        check doc.countOf("mailFooter") == 1
        # As a message: no body line over 76 characters.
        let msg = toMessage(res, MessageHeaders(
          fromAddr: mailbox("Acme", "hello@example.com"),
          to: @[mailbox("", "qa@example.test")], subject: e.name))
        let wire = toRfc5322(msg, lower)
        let body = wire[wire.find("\r\n\r\n") + 4 .. ^1]
        for line in body.split("\r\n"):
          if line.len > 76:
            checkpoint(where & ": " & line)
          check line.len <= 76
        # And under `strict`: nothing it would raise (an error, head CSS
        # over its budget, a cell row too narrow at 320px).
        for d in res.diagnostics:
          check d.code notin [codeCssOverBudget, codeLayoutMinColumn]

  test "test_reference_set_covers_every_element_and_layout":
    # Vacuity guard, part two: what the set is for.
    var seen = initHashSet[string]()
    var layouts = initHashSet[string]()
    var langs = initHashSet[string]()
    var hero, missing, longWords, nearBudget = false
    var columnCounts = initHashSet[int]()
    for e in emails:
      let res = renderReference(e)
      # The authoring tree (the items a pattern consumes are only there)
      # and the expanded one.
      collect(e.tree(), seen)
      collect(res.semantic, seen)
      if e.layout.len > 0:
        layouts.incl(e.layout)
      let doc = res.semantic
      langs.incl(doc.attrs["lang"] & "/" & doc.attrs["dir"])
      proc walk(n: EmailNode) =
        if n.kind == enElement:
          if n.tag == "mailHero" and n.styles.getOrDefault(
              "background-image", "").len > 0:
            for c in n.children:
              if c.kind == enElement and c.tag in ["h1", "h2", "p"]:
                hero = true
          if n.tag == "mailSection":
            var cols = 0
            for c in n.children:
              if c.kind == enElement and c.tag == "mailColumn":
                inc cols
            if cols > 0:
              columnCounts.incl(cols)
        for c in n.children:
          walk(c)
      walk(doc)
      if missingImage in res.html:
        missing = true
      if "Supercalifragilisticexpialidociousnessless" in res.html:
        longWords = true
      if res.htmlBytes > 80_000:
        nearBudget = true
    for name in vocabularyElements():
      if name notin seen:
        checkpoint("no reference email holds " & name)
      check name in seen
    check layouts == toHashSet(["transactionalLayout", "receiptLayout",
      "securityCodeLayout", "alertLayout", "digestLayout"])
    for l in ["he/rtl", "ar/rtl", "ja/ltr", "zh-Hans/ltr", "en/ltr"]:
      check l in langs
    check hero
    check missing
    check longWords
    check nearBudget
    # Sections of one to four columns (a band of four expands to a
    # section holding them).
    for n in 1 .. 4:
      if n notin columnCounts:
        checkpoint("no section of " & $n & " columns")
      check n in columnCounts

  test "test_reference_set_dark_palette_uses_every_colour_token":
    var dark: ReferenceEmail
    for e in emails:
      if e.dark:
        dark = e
    require dark.name == "darkPalette"
    let res = renderReference(dark)
    check not hasErrors(res.diagnostics)
    # The designed dark block: every colour token's dark value in it.
    var block3 = ""
    for css in styleBlocks(res.html):
      if "prefers-color-scheme: dark" in css and "@media" in css:
        block3 = css
    check block3.len > 0
    let theme = defaultTheme()
    for key in requiredThemeKeys:
      if not key.startsWith("color."):
        continue
      let value = theme.darkFor(TokenRef(key: key)).toLowerAscii()
      if value notin block3:
        checkpoint("dark palette lacks " & key & " (" & value & ")")
      check value in block3
