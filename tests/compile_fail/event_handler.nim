# expect: E-VOCAB-EVENT-HANDLER
# expect-line: 13
## Compile-failure fixture: an `onclick` handler in an email template must
## fail to compile with E-VOCAB-EVENT-HANDLER.
## Uses `mailButton` (`button` is forbidden by the vocabulary) to isolate the handler error.
##
## Not part of `just build` / `just lint`: `tests/t1_compile_fail.nim` runs
## `nim check` on this file and asserts the failure.
import isonim_email

proc badTemplate*(r: EmailRenderer; label: string): EmailNode =
  ui(r):
    mailButton(onclick = proc() = discard):
      text label
