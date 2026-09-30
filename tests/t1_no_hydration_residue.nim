## `renderEmail` runs the template once inside a root and asserts the
## residue invariants — no `data-hk`, no `data-isonim-*`, no `<script>` —
## before disposing the root. Pending async resources are rejected by
## `assertNoPendingAsync` (an email cannot show a spinner): caller-supplied
## states via the list overload, and resources a template tracks via
## `trackAsync` against the render's own registry — the async halves are
## pinned directly below.
##
## Backend-independent (reactive core + tree walk), so `just test` also runs
## it on JS.
import std/[strutils, tables, unittest]
import isonim/core/computation
import isonim_email

# Vocabulary-valid (a top-level `div` with `id` fails the vocabulary check); the
# dynamic `title` still proves attributes resolve through the one-shot root.
proc sigTpl(r: EmailRenderer; name: string): EmailNode =
  let greeting = createSignal("Hello, " & name)
  let shouted = createMemo(proc(): string = greeting.val & "!")
  ui(r):
    mailDocument(lang = "en", title = shouted.val):
      mailSection:
        mailColumn:
          h1: text shouted.val
          p: text "static"

proc pendTpl(r: EmailRenderer; x: int): EmailNode =
  let user = r.trackAsync()
  ui(r):
    mailDocument(lang = "en", title = "Pending"):
      mailSection:
        h1: text "Pending"

proc doneTpl(r: EmailRenderer; x: int): EmailNode =
  let user = r.trackAsync()
  user.state = asReady
  let other = r.trackAsync()
  other.state = asError
  ui(r):
    mailDocument(lang = "en", title = "Done"):
      mailSection:
        h1: text "Done"

suite "no hydration residue":
  test "signals and memos resolve; output carries no residue":
    let tree = renderEmail(sigTpl, "Ada").semantic
    check tree.tag == "mailDocument"
    check tree.attrs["title"] == "Hello, Ada!"
    let h1 = tree.children[0].children[0].children[0]
    check h1.tag == "h1"
    check h1.children[0].text == "Hello, Ada!"
    let html = serialize(tree)
    check "Hello, Ada!" in html
    check "data-hk" notin html
    check "data-isonim-" notin html
    check "<script" notin html
    check "script" notin html

  test "data-hk attribute is rejected with its origin":
    let r = EmailRenderer()
    let bad = r.createElement("div")
    bad.origin = SourceSpan(file: "welcome.nim", line: 42, col: 7)
    r.setAttribute(bad, "data-hk", "3")
    var msg = ""
    try:
      assertNoReactiveResidue(bad)
    except EmailRenderError as e:
      msg = e.msg
    check "E-STRUCT-REACTIVE-RESIDUE" in msg
    check "data-hk" in msg
    check "welcome.nim:42:7" in msg

  test "data-isonim-* attributes and script tags are rejected":
    let r = EmailRenderer()
    let srcd = r.createElement("p")
    r.setAttribute(srcd, "data-isonim-src", "x")
    expect EmailRenderError:
      assertNoReactiveResidue(srcd)
    let tagged = r.createElement("div")
    r.setAttribute(tagged, "data-isonim-tag", "div")
    expect EmailRenderError:
      assertNoReactiveResidue(tagged)
    let scripted = r.createElement("div")
    r.appendChild(scripted, r.createElement("script"))
    expect EmailRenderError:
      assertNoReactiveResidue(scripted)
    # renderEmail enforces the same check on template output. The
    # vocabulary check rejects `script` in templates at compile time (see
    # the t2 forbidden fixtures), so the evil tree is hand-built; the
    # runtime guard still covers trees that bypass the macro.
    proc evilTpl(r: EmailRenderer; x: int): EmailNode =
      let root = r.createElement("div")
      r.appendChild(root, r.createElement("script"))
      root
    expect EmailRenderError:
      discard renderEmail(evilTpl, 0)

  test "pending async resources are rejected; resolved ones pass":
    expect EmailRenderError:
      assertNoPendingAsync([asLoading])
    # Idle (nothing started), ready and error are all resolved states.
    assertNoPendingAsync([asIdle])
    assertNoPendingAsync([asReady, asError])
    assertNoPendingAsync([])
    check renderEmail(sigTpl, "Ada").semantic.tag == "mailDocument"

  test "a template that leaves async pending fails with its call site":
    var msg = ""
    try:
      discard renderEmail(pendTpl, 0)
    except EmailRenderError as e:
      msg = e.msg
    check "E-STRUCT-REACTIVE-RESIDUE" in msg
    check "asLoading" in msg
    check "t1_no_hydration_residue.nim:28" in msg
    check "unknown location" notin msg

  test "a template that resolves its async renders; registries do not leak":
    check renderEmail(doneTpl, 0).semantic.tag == "mailDocument"
    # A failed render leaves nothing behind for the next one: each render
    # owns a fresh registry.
    try:
      discard renderEmail(pendTpl, 0)
    except EmailRenderError:
      discard
    check renderEmail(doneTpl, 0).semantic.tag == "mailDocument"
    check renderEmail(sigTpl, "Ada").semantic.tag == "mailDocument"

  test "tracking outside a render is loud; a bare renderer has none pending":
    expect ValueError:
      discard trackAsync(EmailRenderer())
    assertNoPendingAsync(EmailRenderer())
    var r = newEmailRenderer()
    let res = r.trackAsync()
    expect EmailRenderError:
      assertNoPendingAsync(r)
    res.state = asReady
    assertNoPendingAsync(r)
