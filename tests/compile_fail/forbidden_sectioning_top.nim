# expect: E-A11Y-SECTIONING
# expect-line: 9
## Compile-failure fixture: a sectioning element at the top of a block
## (parent unknown) still fails: the code does not depend on nesting.
import isonim_email

proc badTemplate*(r: EmailRenderer): EmailNode =
  ui(r):
    footer:
      p: text "fine print"
