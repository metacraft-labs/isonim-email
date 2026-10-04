## isonim_email/layouts/security_code.nim — `securityCodeLayout`
## (layout-patterns.md §4.8; the password-reset / magic-link / OTP row
## of §4.6): the header, a content card (the heading, the code in a
## `mailSecurityCode` with its expiry and an optional magic-link button,
## a warning `mailCallout` for whoever did not ask for it) and the
## footer.
##
## Pure tree building: identical on the C and JS targets.

import ../renderer
import ../target
import ./frame

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  SecurityCodeLayoutProps* = object
    ## `securityCodeLayout`'s props.
    frame*: LayoutFrame
    heading*: string                 ## the `h1` (required)
    intro*: string
    code*: string                    ## the one-time code (required)
    expires*: string                 ## its expiry in absolute time (required)
    codeLabel*: string = "Your code"
    expiresLabel*: string = "Expires at"
    magicLink*: string               ## Url of the magic link; "" for none
    cta*: string = "Sign in"         ## the magic link's button
    warningLabel*: string = "Warning" ## the callout's tone word
    warningTitle*: string = "Didn't request this?"
    warning*: string                 ## the callout's body (required)
    content*: LayoutSlot             ## the caller's content, after the callout

proc securityCodeLayout*(r: EmailRenderer; p: SecurityCodeLayoutProps):
    EmailNode =
  ## Header, the code, the "didn't request this?" warning, footer.
  result = r.layoutDocument(p.frame)
  let stack = r.contentCard(result)
  r.heading(stack, p.heading, p.intro)
  discard r.node(stack, "mailSecurityCode", [("code", p.code),
    ("expires", p.expires), ("label", p.codeLabel),
    ("expires_label", p.expiresLabel), ("href", p.magicLink),
    ("cta", if p.magicLink.len > 0: p.cta else: "")])
  let c = r.node(stack, "mailCallout", [("tone", "warning"),
    ("label", p.warningLabel), ("title", p.warningTitle)])
  discard r.node(c, "p", text = p.warning)
  r.slotInto(stack, p.content)
  r.layoutFooter(result, p.frame)
