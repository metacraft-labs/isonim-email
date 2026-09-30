# expect: E-VOCAB-FORBIDDEN-TAG
# expect-line: 9
## Compile-failure fixture: `iframe` in an email template must fail
## naming the alternative.
import isonim_email

proc badTemplate*(r: EmailRenderer): EmailNode =
  ui(r):
    iframe(src = "https://example.com")
