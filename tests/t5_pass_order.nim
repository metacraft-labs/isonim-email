# rule: R-A11Y-08
## The order invariant (R-A11Y-08) — no pass
## reorders children. Each seed story is fingerprinted (tag
## sequences per node), run through validate + P5 + P6 + P7 in
## pipeline order, and fingerprinted again; the fingerprints must
## be identical.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS.
import std/[tables, unittest]
import isonim_email
import stories/seed_receipt
import stories/seed_alert

proc describe(node: EmailNode): string =
  case node.kind
  of enElement:
    "e:" & node.tag
  of enText:
    "t"
  of enRaw:
    "r"
  of enMsoIf:
    "mso"
  of enNotMso:
    "notmso"
  of enVml:
    "v:" & node.tag
  of enHeadStyle:
    "style"

proc fingerprint(node: EmailNode): seq[string] =
  ## Pre-order child-order fingerprint: each node's own descriptor,
  ## then its children's descriptor sequence, then recurse.
  result.add(describe(node))
  var kids = "["
  for i, c in node.children:
    if i > 0:
      kids.add(",")
    kids.add(describe(c))
  result.add(kids & "]")
  for c in node.children:
    for d in fingerprint(c):
      result.add(d)

proc presentationTables(root: EmailNode): int =
  ## Tables carrying `role="presentation"` (the P7 backfill anchor).
  if root == nil:
    return 0
  if root.kind == enElement and root.tag == "table" and
      root.attrs.getOrDefault("role", "") == "presentation":
    inc result
  for c in root.children:
    result += presentationTables(c)

suite "pass order invariant":
  test "test_pass_order_preserves_child_order":
    let stories = @[seedReceipt(), seedAlert()]
    check stories.len >= 1
    var storiesChecked = 0
    for story in stories:
      let before = fingerprint(story)
      check validate(story).len == 0
      let styled = applyStyles(story, defaultTheme(), defaultTarget())
      discard assembleHead(styled.head, defaultTarget())
      discard applyA11y(story)
      check fingerprint(story) == before
      # Non-vacuity: P7 really ran — the layout table gained its role.
      check presentationTables(story) >= 1
      inc storiesChecked
    check storiesChecked == stories.len
