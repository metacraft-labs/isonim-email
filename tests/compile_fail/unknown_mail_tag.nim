# expect: E-VOCAB-UNKNOWN-TAG
# expect-line: 9
## Compile-failure fixture: a typo'd mail tag must fail with
## E-VOCAB-UNKNOWN-TAG suggesting `mailSection`.
import isonim_email

proc badTemplate*(r: EmailRenderer): EmailNode =
  ui(r):
    mailSectoin(width = "50%"):
      text "x"
