## The static pre-lowering prototype (`bench/prelower.nim`), which is
## not part of the library: its HTML is written into fragments the
## passes produced once, and every message it makes must be the plain
## path's message byte for byte.
##
## - Over every reference email and the invoice email, for recipients
##   with text of the same shape (the skeleton path) and of other
##   lengths (a new skeleton, or the plain path), the MIME bytes, the
##   HTML and the text part are the plain path's.
## - What keeps it out of the library, shown rather than described: a
##   template that branches on a slot's value, for a value the skeleton
##   was not built from, gets the wrong HTML; and per-recipient link
##   tokens make every recipient a new skeleton.
##
## C backend only, like the reference-set tests (its images are read at
## compile time from examples/).
import std/[strutils, unittest]
import isonim_email
import reference_set
import ../bench/workload

type Notice = object
  status, body: string

proc noticeTpl(r: EmailRenderer; d: Notice): EmailNode =
  ## Branches on `status`'s value.
  let todo = if d.status == "Payment overdue": "Please pay today."
    else: "Nothing to do."
  ui(r):
    mailDocument(lang = "en", title = "Your account"):
      mailSection:
        h1: text "Your account"
        p: text todo
        p: text d.body

suite "static pre-lowering prototype":
  test "test_prelowered_output_identical":
    var onSkeleton, stories = 0
    for s in benchStories():
      inc stories
      for (n, longer) in [(0, false), (1, false), (2, false), (7, false),
          (1, true), (2, true), (3, true)]:
        let pre = s.prelowered(n, longer, false)
        let plain = s.personalised(n, longer, false)
        check pre.rendered.html == plain.html
        check pre.rendered.text == plain.text
        check packageMime(pre.rendered) == packageMime(plain)
        if pre.rendered.html != plain.html or pre.rendered.text != plain.text:
          checkpoint(s.name & " recipient " & $n & " longer=" & $longer &
            " via " & $pre.path)
        if n == 1 and not longer and pre.path == ppSkeleton:
          inc onSkeleton
      if s.name == referenceStory:
        # The reference story's recipients of the same shape take the
        # skeleton: the comparison above exercised the prototype.
        check s.prelowered(9, false, false).path == ppSkeleton
        check s.prelowerStats().renders[ppSkeleton] >= 4
        let sl = s.slots()
        check sl.slots >= 10
    check stories == referenceEmails().len + 1
    check onSkeleton * 2 >= stories

  test "test_prelowered_value_branch_diverges":
    # Built from "Paid in full", the skeleton holds the branch every
    # value but one takes. "Payment overdue" is that one: the plain path
    # writes its branch, the prototype the skeleton's. The value itself
    # is never written, so nothing in the skeleton's checks sees it.
    let cache = newPrelowerCache(noticeTpl)
    let paid = Notice(status: "Paid in full", body: "Thanks for paying.")
    let built = cache.renderPrelowered(paid)
    check built.path == ppBuilt
    let overdue = Notice(status: "Payment overdue", body: "See the invoice.")
    let pre = cache.renderPrelowered(overdue)
    let plain = renderEmail(noticeTpl, overdue)
    check pre.path == ppSkeleton
    check "Please pay today." in plain.html
    check "Please pay today." notin pre.rendered.html
    check pre.rendered.html != plain.html

  test "test_per_recipient_links_make_every_recipient_a_new_skeleton":
    var receipt: BenchStory
    for s in benchStories():
      if s.name == "receiptTypical":
        receipt = s
    for n in 1 .. 3:
      let pre = receipt.prelowered(n, false, true)
      check pre.path == ppBuilt
      check packageMime(pre.rendered) ==
        packageMime(receipt.personalised(n, false, true))
    check receipt.prelowerStats().renders[ppSkeleton] == 0
