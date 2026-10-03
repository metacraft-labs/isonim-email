## isonim_email/mso/cond.nim — MSO conditional wrappers.
##
## The generic in-`src/` call sites of the IR conditional constructors
## (`mso/document.nim` adds the fixed document-level fragments; the
## ghost-table lowering lands later). `tests/t1_ir_restriction.nim`
## enforces that no module outside `mso/` and `passes/head.nim` calls
## `newMsoIf` / `newNotMso` / `newVml` / `newHeadStyle`.

import ../ir
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
## Every family, not just Word: `msoWrap` content reaches only Word, but
## `notMsoWrap` content (`<!--[if !mso]>`) reaches every family EXCEPT
## Word — the document's non-mso head style blocks and meta tag go
## through it — so an edit here can change what any family renders.
const affects*: set[ClientFamily] = allFamilies

export ir

proc msoWrap*(children: varargs[EmailNode]): EmailNode =
  ## Wraps `children` in an Outlook-only conditional (`<!--[if mso]>`).
  newMsoIf("mso", @children)

proc notMsoWrap*(children: varargs[EmailNode]): EmailNode =
  ## Wraps `children` in an everyone-but-Outlook conditional.
  newNotMso(@children)

proc msoCond*(cond: string; children: varargs[EmailNode]): EmailNode =
  ## An Outlook-only conditional with any condition of the closed set
  ## (`mso`, `gte mso 9`, `lte mso 11`; R-OL-02): the tree a raw
  ## payload's conditional comment reads as (`raw.nim`). Raises
  ## `EmailRenderError` on any other condition, like `newMsoIf`.
  newMsoIf(cond, @children)
