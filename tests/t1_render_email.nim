# rule: R-DOC-02
## `renderEmail` returns the `RenderedEmail` record — HTML, text,
## diagnostics, sizes, assets and the resolved semantic tree — with
## every parameter threaded: the theme resolves tokens, the target
## switches the lowering, the profile weights the lint, strict turns
## collected errors into a raise, and the asset store resolves the
## images the tree references. Same inputs render byte-identically.
##
## The templates use only elements that have a lowering (headings,
## paragraphs, links, `mailImage`): an element without one is an
## error of its own (`E-LOWER-MISSING`, pinned in
## t5_lower_elements.nim), which would drown the diagnostics these
## tests count.
##
## Backend-independent (tree building + pure passes + the in-memory
## asset store), so `just test` also runs it on JS.
import std/[strutils, tables, unittest]
import isonim_email

proc sigTpl(r: EmailRenderer; name: string): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Hello"):
      h1: text "Hello, " & name
      p: text "static"

proc tokenTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Tok"):
      h1: text "Tok"
      p(color = tok"color.accent.primary"): text "hi"

proc buttonTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Button"):
      h1: text "Button"
      a(href = "https://app.example.com/", border_radius = "6px"):
        text "Open dashboard"

proc noLangTpl(r: EmailRenderer; x: int): EmailNode =
  ui(r):
    mailDocument(title = "No lang"):
      h1: text "No lang"

proc imgTpl(r: EmailRenderer; src: string): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Img"):
      h1: text "Img"
      mailImage(src = src, alt = "logo", width = "120px")

proc codesOf(diags: openArray[EmailDiagnostic]): seq[string] =
  for d in diags:
    result.add(d.code)

proc problemsOf(diags: openArray[EmailDiagnostic]): seq[string] =
  ## The codes of the warnings and errors: what "renders cleanly" means
  ## (information, such as the inversion simulation's findings under an
  ## uncalibrated model, is not a problem).
  for d in diags:
    if d.severity >= sevWarning:
      result.add(d.code)

type DisposeProbe = ref object
  cleaned: bool

proc cleanupTpl(r: EmailRenderer; p: DisposeProbe): EmailNode =
  onCleanup(proc() = p.cleaned = true)
  ui(r):
    mailDocument(lang = "en", title = "Cleanup"):
      h1: text "Cleanup"

proc cleanupEvilTpl(r: EmailRenderer; p: DisposeProbe): EmailNode =
  onCleanup(proc() = p.cleaned = true)
  let root = r.createElement("div")
  r.appendChild(root, r.createElement("script"))
  root

proc cleanupRaiseTpl(r: EmailRenderer; p: DisposeProbe): EmailNode =
  onCleanup(proc() = p.cleaned = true)
  raise newException(ValueError, "mid-render boom")

suite "renderEmail returns the rendered record":
  test "record shape, sizes and the intact semantic tree":
    let res = renderEmail(sigTpl, "Ada")
    check res.html.startsWith("<!doctype html>")
    check "Hello, Ada!" notin res.html # no shout here; signals resolve below
    check res.text == "" # the plain-text pass fills this later
    check res.diagnostics.len == 0
    check res.htmlBytes == res.html.len
    check res.headCssBytes >= 0
    check res.headCssBytes <= res.htmlBytes
    var breakdownTotal = 0
    for (_, bytes) in res.sizeBreakdown:
      breakdownTotal += bytes
    check breakdownTotal == res.htmlBytes
    check res.assets.len == 0
    # The semantic tree keeps its children and resolved values.
    check res.semantic.tag == "mailDocument"
    check res.semantic.attrs["title"] == "Hello"
    # The template's heading sits directly in the document, so it is in
    # the implicit section that holds the document's loose content.
    check res.semantic.children[0].tag == "mailSection"
    let h1 = res.semantic.children[0].children[0]
    check h1.tag == "h1"
    check h1.children[0].text == "Hello, Ada"
    check "data-hk" notin res.html
    check "data-isonim-" notin res.html
    check "<script" notin res.html

  test "signals resolve through the full render":
    proc shoutTpl(r: EmailRenderer; name: string): EmailNode =
      let greeting = createSignal("Hello, " & name)
      ui(r):
        mailDocument(lang = "en", title = greeting.val):
          h1: text greeting.val
    let res = renderEmail(shoutTpl, "Ada")
    check res.semantic.attrs["title"] == "Hello, Ada"
    check "Hello, Ada" in res.html

  test "the theme resolves tokens in the output":
    let base = renderEmail(tokenTpl, 0)
    check problemsOf(base.diagnostics).len == 0
    check "color:#1f6feb" in base.html
    var theme = defaultTheme()
    # A distinctive dark violet: passes the contrast lint on white,
    # so the render stays clean and only the colour changes.
    theme.values["color.accent.primary"] =
      ThemePair(light: "#7c3aed", dark: "#7c3aed")
    let custom = renderEmail(tokenTpl, 0, theme = theme)
    check problemsOf(custom.diagnostics).len == 0
    check "color:#7c3aed" in custom.html
    check "#1f6feb" notin custom.html

  test "the target switches the lowering":
    let word = renderEmail(sigTpl, "Ada")
    check "[if mso]" in word.html
    var plain = defaultTarget()
    plain.outlookWord = false
    let noWord = renderEmail(sigTpl, "Ada", target = plain)
    check "[if mso]" notin noWord.html
    check "Hello, Ada" in noWord.html

  test "the profile weights the lint diagnostics":
    # border-radius lacks Word: silent under consumer (2% < 5%),
    # a warning under business (25%).
    let calm = renderEmail(buttonTpl, 0, profile = consumer)
    check problemsOf(calm.diagnostics).len == 0
    let loud = renderEmail(buttonTpl, 0, profile = business)
    check problemsOf(loud.diagnostics) == @[codeSupportUnsupported]
    check loud.diagnostics[0].severity == sevWarning
    check "border-radius" in loud.diagnostics[0].message
    check not hasErrors(loud.diagnostics)

  test "strict collects nothing: it raises the first error":
    let loose = renderEmail(noLangTpl, 0)
    check codeA11yLangMissing in codesOf(loose.diagnostics)
    check hasErrors(loose.diagnostics)
    check loose.html.startsWith("<!doctype html>")
    var msg = ""
    try:
      discard renderEmail(noLangTpl, 0, strict = true)
    except EmailRenderError as e:
      msg = e.msg
    check msg.startsWith(codeA11yLangMissing & ":")
    # A clean template renders under strict too.
    check renderEmail(sigTpl, "Ada", strict = true).diagnostics.len == 0

  test "residue raises even when strict is off":
    proc evilTpl(r: EmailRenderer; x: int): EmailNode =
      let root = r.createElement("div")
      r.appendChild(root, r.createElement("script"))
      root
    var msg = ""
    try:
      discard renderEmail(evilTpl, 0)
    except EmailRenderError as e:
      msg = e.msg
    check "E-STRUCT-REACTIVE-RESIDUE" in msg

  test "the asset store resolves referenced images":
    let store = memoryAssetStore("https://assets.example.com")
    store.put("logo.png", "fake-png-bytes")
    let res = renderEmail(imgTpl, "logo.png", assets = store)
    check res.diagnostics.len == 0
    check res.assets.len == 1
    check res.assets[0].name == "logo.png"
    check res.assets[0].sha256 == sha256Hex("fake-png-bytes")
    check res.assets[0].mime == "image/png"
    check res.assets[0].bytes == "fake-png-bytes"
    # Without a store nothing resolves, and nothing is claimed.
    let bare = renderEmail(imgTpl, "logo.png")
    check bare.assets.len == 0
    check bare.diagnostics.len == 0

  test "unknown and forbidden image sources are collected":
    # No rule claim: R-IMG-08 also covers WebP/SVG under Word/Gmail
    # profiles — this pins the data: half at the render layer only,
    # so the rule stays pending.
    let store = memoryAssetStore("https://assets.example.com")
    let missing = renderEmail(imgTpl, "nope.png", assets = store)
    check codesOf(missing.diagnostics) == @[codeAssetUnknown]
    check hasErrors(missing.diagnostics)
    let dataUri = renderEmail(imgTpl, "data:image/png;base64,xx",
      assets = store)
    check codesOf(dataUri.diagnostics) == @[codeUrlScheme]
    check "R-IMG-08" in dataUri.diagnostics[0].message
    # Absolute URLs and cid references are already resolved: the
    # store is never consulted for them.
    for src in ["https://cdn.example.com/logo.png", "cid:abc@isonim"]:
      let res = renderEmail(imgTpl, src, assets = store)
      check res.assets.len == 0
      check res.diagnostics.len == 0

  test "a failed render still disposes its root":
    # Disposal is observable: the template registers an onCleanup hook,
    # which runs only when the render's root is disposed. Both failure
    # modes — a guard raising after the template built, and the template
    # itself raising mid-render — must still dispose.
    let evil = DisposeProbe(cleaned: false)
    expect EmailRenderError:
      discard renderEmail(cleanupEvilTpl, evil)
    check evil.cleaned
    let raised = DisposeProbe(cleaned: false)
    var msg = ""
    try:
      discard renderEmail(cleanupRaiseTpl, raised)
    except ValueError as e:
      msg = e.msg
    check msg == "mid-render boom"
    check raised.cleaned
    # Control: a clean render disposes too.
    let clean = DisposeProbe(cleaned: false)
    check renderEmail(cleanupTpl, clean).diagnostics.len == 0
    check clean.cleaned

  test "the same inputs render byte-identically":
    let a = renderEmail(buttonTpl, 0, profile = business)
    let b = renderEmail(buttonTpl, 0, profile = business)
    check a.html == b.html
    check a.text == b.text
    check $a.diagnostics == $b.diagnostics
    check a.htmlBytes == b.htmlBytes
    check a.headCssBytes == b.headCssBytes
    check a.sizeBreakdown == b.sizeBreakdown
    check serialize(a.semantic) == serialize(b.semantic)
    # ... and across a fresh store with the same bytes.
    let mkStore = proc(): MemoryAssetStore =
      let s = memoryAssetStore("https://assets.example.com")
      s.put("logo.png", "fake-png-bytes")
      s
    let c = renderEmail(imgTpl, "logo.png", assets = mkStore())
    let d = renderEmail(imgTpl, "logo.png", assets = mkStore())
    check c.html == d.html
    check c.assets == d.assets
