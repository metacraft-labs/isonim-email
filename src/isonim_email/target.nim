## isonim_email/target.nim — client families, audience profiles, target flags.
##
## The library models families, never individual clients: rendering
## choices, lint rules and verification targets are all keyed by
## `ClientFamily`. An `AudienceProfile` weights families for lint
## severity only — weights never switch off a family's lowering.
## `EmailTarget` records what the output must accommodate; each flag
## prunes or enables one isolated pass.

type
  ClientFamily* = enum
    cfApple, cfGmailWeb, cfGmailApp, cfGanga, cfOutlookWord, cfOutlookWeb,
    cfOutlookApp, cfYahoo, cfSamsung, cfThunderbird, cfProton, cfFastmail,
    cfHey

  AudienceProfile* = object
    name*: string
    weights*: array[ClientFamily, float] ## Sums to 1.0 (checked at build)

  DarkModeStrategy* = enum
    dmNone, dmAccommodate, dmDesigned

  WebFont* = object
    ## One web font the message loads (catalogue R-TXT-07): an
    ## `@font-face` in the fonts block, hidden from Word, whose fallback
    ## Word gets instead (R-OL-07). Stacks name it by `family`.
    family*: string       ## The family name stacks use (`Inter`)
    url*: string          ## Absolute https URL of the font file
    format*: string       ## `woff2` (default when empty), `woff` or `truetype`
    weight*: string       ## `400` when empty
    style*: string        ## `normal` when empty

  EmailTarget* = object
    outlookWord*: bool    ## Emit MSO conditionals, ghost tables, VML
    thunderbirdMq*: bool  ## Emit `.moz-text-html`-prefixed MQs
    owaDesktop*: bool     ## Emit `[owa]` copies for desktop layout
    darkMode*: DarkModeStrategy
    breakpoint*: int      ## Mobile/desktop switch, px
    containerWidth*: int  ## Content width, px
    sizeBudget*: int      ## Decoded HTML bytes; warn above
    headStyleBudget*: int ## Bytes of head CSS across all blocks
    preheaderPad*: string ## R-PRE-02 unit sequence (the measured sequence lands later)
    webFonts*: seq[WebFont] ## Fonts loaded with `@font-face` (R-TXT-07, R-OL-07); none by default
    vmlFitToText*: bool   ## R-VML-03 flag (unverified): Word's background
      ## rectangles that grow with their content (`mso-fit-shape-to-text`):
      ## a section's or wrapper's, and a `min_height` hero's. Off by
      ## default: such a band shows Word its fallback colour instead

const allFamilies* = {low(ClientFamily) .. high(ClientFamily)}
  ## Every client family: the `affects` value of a module whose edits
  ## can change what any family renders.

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

proc familyId*(f: ClientFamily): string =
  ## The family id used in diagnostics and briefs.
  case f
  of cfApple: "apple"
  of cfGmailWeb: "gmailWeb"
  of cfGmailApp: "gmailApp"
  of cfGanga: "ganga"
  of cfOutlookWord: "outlookWord"
  of cfOutlookWeb: "outlookWeb"
  of cfOutlookApp: "outlookApp"
  of cfYahoo: "yahoo"
  of cfSamsung: "samsung"
  of cfThunderbird: "thunderbird"
  of cfProton: "proton"
  of cfFastmail: "fastmail"
  of cfHey: "hey"

proc makeProfile*(name: string;
                  weights: array[ClientFamily, float]): AudienceProfile =
  ## Builds a profile, asserting the weights sum to 1.0.
  var total = 0.0
  for w in weights:
    total += w
  doAssert abs(total - 1.0) < 1e-9,
    "audience profile '" & name & "' weights sum to " & $total &
    ", not 1.0"
  AudienceProfile(name: name, weights: weights)

# The "others" remainder is split across the families below; the
# weights are starting assumptions, not measurements — a consumer with real
# open data replaces them.

let consumer* = makeProfile("consumer", [
  cfApple: 0.60, cfGmailWeb: 0.14, cfGmailApp: 0.14, cfGanga: 0.002,
  cfOutlookWord: 0.02, cfOutlookWeb: 0.04, cfOutlookApp: 0.002,
  cfYahoo: 0.03, cfSamsung: 0.02, cfThunderbird: 0.002, cfProton: 0.002,
  cfFastmail: 0.001, cfHey: 0.001,
])
  ## Receipts and notifications to end users.

let business* = makeProfile("business", [
  cfApple: 0.25, cfGmailWeb: 0.20, cfGmailApp: 0.02, cfGanga: 0.005,
  cfOutlookWord: 0.25, cfOutlookWeb: 0.20, cfOutlookApp: 0.05,
  cfYahoo: 0.01, cfSamsung: 0.005, cfThunderbird: 0.005, cfProton: 0.002,
  cfFastmail: 0.002, cfHey: 0.001,
])
  ## Invoices and alerts to companies.

let developer* = makeProfile("developer", [
  cfApple: 0.30, cfGmailWeb: 0.35, cfGmailApp: 0.02, cfGanga: 0.005,
  cfOutlookWord: 0.05, cfOutlookWeb: 0.10, cfOutlookApp: 0.01,
  cfYahoo: 0.01, cfSamsung: 0.005, cfThunderbird: 0.05, cfProton: 0.04,
  cfFastmail: 0.04, cfHey: 0.02,
])
  ## CodeTracer / Reprobuild product mail.

proc defaultTarget*(): EmailTarget =
  ## The default target. `preheaderPad` is the R-PRE-02 flag value
  ## (the `&#847;&zwnj;&nbsp;` unit); the measured sequence lands later.
  EmailTarget(
    outlookWord: true,
    thunderbirdMq: true,
    owaDesktop: false,
    darkMode: dmAccommodate,
    breakpoint: 480,
    containerWidth: 600,
    sizeBudget: 90_000,
    headStyleBudget: 15_000,
    preheaderPad: "&#847;&zwnj;&nbsp;",
  )
