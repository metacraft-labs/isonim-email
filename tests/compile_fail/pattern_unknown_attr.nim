# expect: E-VOCAB-UNKNOWN-ATTR
# expect-line: 31
## Compile-failure fixture: a pattern defined with `defineMailPattern`
## joins the static vocabulary with its props as attributes, so an
## attribute it does not declare is a compile error at the element.
## (Named `mailPill`: the library defines its own `mailBadge`.)
import isonim_email

type BadgeProps = object
  label: string

proc badgeExpand(n: EmailNode; p: BadgeProps; ctx: ExpandCtx): EmailNode =
  result = ctx.r.createElement("span")
  ctx.r.setTextContent(result, p.label)

proc badgeExpected(n: EmailNode; p: BadgeProps; v: BriefView): seq[string] =
  @["Badge \"" & p.label & "\"."]

proc badgeDegradations(n: EmailNode; p: BadgeProps;
    v: BriefView): seq[string] =
  @[]

defineMailPattern(mailPill, BadgeProps, badgeExpand, badgeExpected,
  badgeDegradations)

proc badTemplate*(r: EmailRenderer): EmailNode =
  ui(r):
    mailDocument(lang = "en", title = "Badge"):
      h1: text "Badge"
      mailSection:
        mailPill(label = "New", colour = "red")
