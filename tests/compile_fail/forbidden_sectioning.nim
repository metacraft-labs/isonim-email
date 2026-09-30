# expect: E-A11Y-SECTIONING
# expect-line: 12
## Compile-failure fixture: a sectioning element (`nav`) in an email
## template must fail with the accessibility code, not the generic
## forbidden-tag one, and name the alternative.
import isonim_email

proc badTemplate*(r: EmailRenderer): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Nav"):
      mailSection:
        nav:
          p: text "links"
