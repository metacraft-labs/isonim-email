# expect: E-STRUCT-NESTING
# expect-line: 13
## Compile-failure fixture: a bare `table` outside `mailTable` fails the
## nesting rule and names both alternatives.
import isonim_email

proc badTemplate*(r: EmailRenderer): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Table"):
      mailSection:
        mailColumn:
          p: text "layout by table"
          table:
            tr:
              td: text "cell"
