## The EMC top-five-impossible over the seed story set
## (`test_emc_top_five_impossible`): every
## story carries `lang`/`dir` on `html` and the article wrapper,
## `role="presentation"` on every layout table, an `h1`, and `alt` on
## every image — checked on the lowered `img`, never on a raw
## `mailImage`. The reference template set will subsume the seeds (see
## `tests/stories/`); these checks run unchanged over it.
##
## No rule claim here: this is an end-to-end check, not a
## catalogue rule — R-A11Y-08 (the order invariant) is claimed
## separately by `tests/t5_pass_order.nim`.
##
## Backend-independent (tree building + pure passes), so `just test`
## also runs it on JS.
import std/[tables, unittest]
import isonim_email
import stories/seed_receipt
import stories/seed_alert

proc lowered(story: EmailNode): EmailNode =
  ## The story through the current pipeline: P4 lowers its elements
  ## (the seed images become `img`), the shell wraps the result, and
  ## P7 backfills roles on the lowered tree.
  let target = defaultTarget()
  let diags = validate(story)
  doAssert diags.len == 0, "seed story must be P1-clean"
  let styled = applyStyles(story, defaultTheme(), target)
  let headed = assembleHead(styled.head, target)
  doAssert not hasErrors(lowerElements(story, defaultTheme())),
    "seed story must use only elements with a lowering"
  let html = lowerDocument(story, story, headed.blocks, target)
  discard applyA11y(html)
  html

suite "EMC top five over seed stories":
  test "test_emc_top_five_impossible":
    let stories = @[seedReceipt(), seedAlert()]
    check stories.len >= 1
    var htmlChecked = 0
    var wrapperChecked = 0
    var tablesVisited = 0
    var h1Visited = 0
    var imgsVisited = 0
    var mailImagesVisited = 0
    for story in stories:
      let wantLang = story.attrs["lang"]
      let wantDir = story.attrs["dir"]
      var stack = @[lowered(story)]
      while stack.len > 0:
        let node = stack.pop()
        if node == nil:
          continue
        if node.kind == enElement:
          if node.tag == "html":
            check node.attrs.getOrDefault("lang", "") == wantLang
            check node.attrs.getOrDefault("dir", "") == wantDir
            inc htmlChecked
          if node.tag == "div" and
              node.attrs.getOrDefault("role", "") == "article":
            check node.attrs.getOrDefault("lang", "") == wantLang
            check node.attrs.getOrDefault("dir", "") == wantDir
            inc wrapperChecked
          if node.tag == "table":
            check node.attrs.getOrDefault("role", "") == "presentation"
            inc tablesVisited
          if node.tag == "h1":
            inc h1Visited
          if node.tag == "img":
            check "alt" in node.attrs
            check node.attrs["alt"].len > 0
            inc imgsVisited
          if node.tag == "mailImage":
            # A raw vocabulary tag in the lowered tree is the defect
            # P4 exists to prevent.
            inc mailImagesVisited
        for i in countdown(node.children.high, 0):
          stack.add(node.children[i])
    check htmlChecked >= 1
    check wrapperChecked >= 1
    check tablesVisited >= 1
    check h1Visited >= 1
    # Both seeds carry one image, and both reach the output as `img`.
    check imgsVisited == 2
    check mailImagesVisited == 0
