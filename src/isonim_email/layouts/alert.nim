## isonim_email/layouts/alert.nim — `alertLayout`
## (layout-patterns.md §4.8; the alert / incident row of §4.6): the
## header, then a content card: the heading, the severity band (a
## `mailCallout` in the severity's tone, its word as the label, the
## status as its title), the key facts (`mailKeyValue`), the evidence
## (`mailCodeBlock`), the caller's content, the actions
## (`mailButtonGroup`); then the footer.
##
## Pure tree building: identical on the C and JS targets.

import ../renderer
import ../target
import ./frame

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  AlertSeverity* = enum
    ## An alert's severity: its callout's tone and word.
    asCritical = "critical"   ## `danger`, "Critical"
    asWarning = "warning"     ## `warning`, "Warning"
    asInfo = "info"           ## `info`, "Info"
    asResolved = "resolved"   ## `success`, "Resolved"

  AlertLayoutProps* = object
    ## `alertLayout`'s props.
    frame*: LayoutFrame
    severity*: AlertSeverity = asCritical
    severityLabel*: string        ## the callout's word; "" = the severity's own
    heading*: string              ## the `h1` (required)
    status*: string               ## the callout's title (required)
    summary*: string              ## the callout's body
    factsCaption*: string = "Details"
    facts*: seq[LayoutRow]        ## what, where, since when
    codeTitle*: string            ## a line above the evidence
    code*: string                 ## the evidence (a log excerpt, a command)
    actions*: seq[LayoutLink]     ## 1–3 buttons
    content*: LayoutSlot          ## the caller's content, before the actions

proc severityTone*(s: AlertSeverity): tuple[tone, word: string] =
  ## The callout tone and word of a severity.
  case s
  of asCritical: ("danger", "Critical")
  of asWarning: ("warning", "Warning")
  of asInfo: ("info", "Info")
  of asResolved: ("success", "Resolved")

proc alertLayout*(r: EmailRenderer; p: AlertLayoutProps): EmailNode =
  ## Header, severity band, key facts, evidence, actions, footer.
  result = r.layoutDocument(p.frame)
  let stack = r.contentCard(result)
  r.heading(stack, p.heading, "")
  let (tone, word) = severityTone(p.severity)
  let c = r.node(stack, "mailCallout", [("tone", tone), ("title", p.status),
    ("label", if p.severityLabel.len > 0: p.severityLabel else: word)])
  if p.summary.len > 0:
    discard r.node(c, "p", text = p.summary)
  r.keyValue(stack, p.factsCaption, p.facts)
  if p.code.len > 0:
    if p.codeTitle.len > 0:
      let t = r.node(stack, "h2", text = p.codeTitle)
      r.setStyle(t, "margin", "0")
    let cb = r.node(stack, "mailCodeBlock")
    r.appendChild(cb, r.createTextNode(p.code))
  r.slotInto(stack, p.content)
  r.buttonGroup(stack, p.actions)
  r.layoutFooter(result, p.frame)
