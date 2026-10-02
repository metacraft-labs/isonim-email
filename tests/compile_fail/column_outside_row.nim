# expect: E-STRUCT-NESTING
# expect-line: 10
## Compile-failure fixture: a `mailColumn` outside a row (a section, a
## group or a `mailColumns`) fails the nesting rule.
import isonim_email

proc badTemplate*(r: EmailRenderer): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Column"):
      mailColumn:
        h1: text "A column with no row"
