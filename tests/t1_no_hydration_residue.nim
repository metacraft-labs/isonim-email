## `renderEmail` runs the template once inside a root and asserts the
## residue invariants — no `data-hk`, no `data-isonim-*`, no `<script>` —
## before disposing the root. Pending async resources are rejected by
## `assertNoPendingAsync` (an email cannot show a spinner): caller-supplied
## states via the list overload, and resources a template tracks via
## `trackAsync` against the render's own registry — the async halves are
## pinned directly below. Pending state held by isonim's own primitives
## (an `AsyncState` signal left `asLoading`, an async `createResource`
## whose future never completes) fails the render when the template reads
## it, with no opt-in call; a resource created under the render's root
## fails it even when only its `data` is read (or nothing at all), found
## through the resources the root registers. Resolved resources are the
## negative control.
##
## No mocks: the templates use the real reactive core and real
## cross-target futures.
##
## Backend-independent (reactive core + tree walk), so `just test` also runs
## it on JS.
import std/[strutils, tables, unittest]
import isonim/core/computation
import isonim/core/resource
import nim_everywhere/async_compat
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

template lineHere(): int = instantiationInfo().line

# The line of `pendTpl`'s `trackAsync` call, which its diagnostic cites.
const pendTrackLine = lineHere() + 2
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

# Pending state held by isonim's own primitives, created inside the
# template and read by it: the output would carry a loading placeholder.
proc loadingSignalTpl(r: EmailRenderer; x: int): EmailNode =
  let status = createSignal(asLoading)
  ui(r):
    mailDocument(lang = "en", title = "Loading"):
      mailSection:
        h1: text "Your order"
        if status.val == asLoading:
          p: text "Loading…"
        else:
          p: text "Ready"

proc neverFuture(): PlatformFuture[string] =
  ## A future nothing ever completes.
  when defined(js):
    newPromise(proc(resolve: proc(v: string)) = discard)
  else:
    newFuture[string]("never completes")

proc pendingResourceTpl(r: EmailRenderer; x: int): EmailNode =
  let user = createResource(proc(info: ResourceFetcherInfo[string]):
      PlatformFuture[string] = neverFuture())
  ui(r):
    mailDocument(lang = "en", title = "Resource"):
      mailSection:
        h1: text "Account"
        if user.loading:
          p: text "Spinner"
        else:
          p: text user.val

proc dataOnlyResourceTpl(r: EmailRenderer; x: int): EmailNode =
  # Only `data` is read: its initial value would reach the email as-is.
  let user = createResource(proc(info: ResourceFetcherInfo[string]):
      PlatformFuture[string] = neverFuture(), initialValue = "Loading…")
  ui(r):
    mailDocument(lang = "en", title = "Data only"):
      mailSection:
        h1: text "Account"
        p: text user.data.val

proc unreadNestedResourceTpl(r: EmailRenderer; x: int): EmailNode =
  # Created inside a template-owned memo, and never read at all.
  let label = createMemo(proc(): string =
    discard createResource(proc(info: ResourceFetcherInfo[string]):
        PlatformFuture[string] = neverFuture())
    "Account")
  ui(r):
    mailDocument(lang = "en", title = "Nested"):
      mailSection:
        h1: text label.val

proc settledResourcesTpl(r: EmailRenderer; x: int): EmailNode =
  # Created under the render's root and settled before it returns.
  let sync = createResource(proc(): string = "Ada")
  let deferred = createDeferredResource[string]("…")
  deferred.resolve("Lovelace")
  let failed = createDeferredResource[string]()
  failed.reject("offline")
  ui(r):
    mailDocument(lang = "en", title = "Settled"):
      mailSection:
        h1: text sync.data.val & " " & deferred.resource.data.val

proc memoOverLoadingTpl(r: EmailRenderer; x: int): EmailNode =
  # The read happens inside a memo the template owns, not in the body.
  let status = createSignal(asLoading)
  let label = createMemo(proc(): string =
    if status.val == asLoading: "Loading…" else: "Ready")
  ui(r):
    mailDocument(lang = "en", title = "Memo"):
      mailSection:
        h1: text "Status"
        p: text label.val

var readyUser: Resource[string]
  ## Resolved before the render, as the contract requires.

proc resolvedTpl(r: EmailRenderer; x: int): EmailNode =
  let status = createSignal(asLoading)
  status.val = asReady # resolved before the template returns
  ui(r):
    mailDocument(lang = "en", title = "Resolved"):
      mailSection:
        h1: text "Account"
        if readyUser.loading or status.val == asLoading:
          p: text "Spinner"
        else:
          p: text readyUser.val

proc renderError(fn: proc()): string =
  try:
    fn()
  except EmailRenderError as e:
    return e.msg
  ""

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
    # A full path, like element spans: the basename alone is ambiguous.
    check ("/tests/t1_no_hydration_residue.nim:" & $pendTrackLine & ":") in
      msg
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

  test "an AsyncState signal left asLoading fails the render":
    let msg = renderError(proc() = discard renderEmail(loadingSignalTpl, 0))
    check "E-STRUCT-REACTIVE-RESIDUE" in msg
    check "asLoading" in msg
    check "t1_no_hydration_residue.nim" in msg

  test "an async createResource that never completes fails the render":
    let msg = renderError(proc() = discard renderEmail(pendingResourceTpl, 0))
    check "E-STRUCT-REACTIVE-RESIDUE" in msg
    check "rsPending" in msg

  test "a pending resource whose state is never read fails the render":
    let msg = renderError(proc() = discard renderEmail(dataOnlyResourceTpl, 0))
    check "E-STRUCT-REACTIVE-RESIDUE" in msg
    check "a resource the template created is still pending" in msg
    check "rsPending" in msg
    check "t1_no_hydration_residue.nim" in msg

  test "a pending resource created in a template-owned memo fails the render":
    let msg = renderError(proc() =
      discard renderEmail(unreadNestedResourceTpl, 0))
    check "E-STRUCT-REACTIVE-RESIDUE" in msg
    check "a resource the template created is still pending" in msg
    check "rsPending" in msg

  test "resources the template settles before returning pass":
    let res = renderEmail(settledResourcesTpl, 0)
    check "Ada Lovelace" in res.html

  test "pending state read through a template-owned memo fails the render":
    let msg = renderError(proc() = discard renderEmail(memoOverLoadingTpl, 0))
    check "E-STRUCT-REACTIVE-RESIDUE" in msg
    check "asLoading" in msg

  test "resources resolved before the render pass; no probe outlives it":
    var root: proc()
    createRoot(proc(dispose: proc()) =
      root = dispose
      readyUser = createResource(proc(info: ResourceFetcherInfo[string]):
          PlatformFuture[string] = newCompletedFuture("Ada")))
    drainPlatformCallbacks()
    check readyUser.state.value == rsReady
    let res = renderEmail(resolvedTpl, 0)
    check "Ada" in res.html
    check "Spinner" notin res.html
    # The render's probe listener was unlinked from the signal it read.
    check readyUser.state.observers.len == 0
    root()
