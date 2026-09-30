# expect: E-VOCAB-PROC-AS-ELEMENT
# expect-line: 14
## Compile-failure fixture: a data-only proc called with named arguments
## must fail naming both fixes.
import isonim_email

proc standardFooter(r: EmailRenderer; label: string): EmailNode =
  let node = r.createElement("p")
  r.setTextContent(node, label)
  node

proc badTemplate*(r: EmailRenderer): EmailNode =
  ui(r):
    standardFooter(label = "x")
