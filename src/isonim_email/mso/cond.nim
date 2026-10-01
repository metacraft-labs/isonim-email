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
