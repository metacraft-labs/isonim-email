## isonim_email/lower/wrapper.nim — `mailWrapper` lowering.
##
## A wrapper gives several sections one shared background, padding and
## border (R-LAY-17). It is a band like a section (R-LAY-06, R-LAY-08):
## a ghost table `W` px wide whose cell carries the wrapper's padding,
## background and border for Word (R-TBL-02), and the same two `div`s
## for everyone else. Its sections are laid out in its box,
## `W − padding − borders`, so each inner section's own ghost table is
## that many px wide and sits inside the wrapper's ghost cell.
##
## The inner div holds sections, which reset their own font size,
## alignment and direction, so the wrapper sets none of those.
##
## Ghost tables come from `mso/ghost.nim` only. Pure tree building:
## identical on the C and JS targets.

import ../renderer
import ../diagnostics
import ../target
import ./section

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

const wrapperConsumed = ["background-color", "background_color",
  "padding", "padding-top", "padding-right", "padding-bottom",
  "padding-left", "border", "border-width", "border-style",
  "border-color", "border-radius", "border_radius"]

proc lowerWrapper*(node: EmailNode; ctx: LowerCtx):
    tuple[band: Band; diagnostics: seq[EmailDiagnostic]] =
  ## Lowers one laid-out `mailWrapper`; its children (sections) are
  ## moved into `band.inner` for the caller to lower next.
  let r = EmailRenderer()
  var diags: seq[EmailDiagnostic] = @[]
  missingProps(node, diags)
  let (border, uniform) = borderText(node)
  if not uniform:
    diags.add(lowerMissing(node, "per-side border", "R-TBL-02"))
  var band = bandNodes(node, ctx, node.layout.padding,
    colourOf(node, "background-color"), border, radiusOf(node), "",
    ghostAlign = false, [], wrapperConsumed, r)
  let kids = node.children # Copy: appendChild detaches as it moves.
  for c in kids:
    r.appendChild(band.inner, c)
  (band, diags)
