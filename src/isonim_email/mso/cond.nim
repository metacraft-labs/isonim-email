## isonim_email/mso/cond.nim — MSO conditional wrappers.
##
## The generic in-`src/` call sites of the IR conditional constructors
## (`mso/document.nim` adds the fixed document-level fragments; the
## ghost-table lowering lands later). `tests/t1_ir_restriction.nim`
## enforces that no module outside `mso/` and `passes/head.nim` calls
## `newMsoIf` / `newNotMso` / `newVml` / `newHeadStyle`.

import ../ir

export ir

proc msoWrap*(children: varargs[EmailNode]): EmailNode =
  ## Wraps `children` in an Outlook-only conditional (`<!--[if mso]>`).
  newMsoIf("mso", @children)

proc notMsoWrap*(children: varargs[EmailNode]): EmailNode =
  ## Wraps `children` in an everyone-but-Outlook conditional.
  newNotMso(@children)
