## isonim_email/mso/vml.nim — VML shapes.
##
## The button's `v:roundrect` (catalogue R-BTN-04, the Campaign Monitor
## pattern): a rounded rectangle that is itself the link, with
## `w:anchorlock` and the label in a `center`. VML is only valid inside
## an Outlook conditional; the caller wraps the shape (`mso/cond`), and
## the serialiser's IR check refuses a shape anywhere else.
##
## Allowed IR site: `tests/t1_ir_restriction.nim` admits constructor
## calls from `mso/`.
##
## Pure tree building: identical on the C and JS targets.

import ../ir
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = {cfOutlookWord}

export ir

proc roundrectButton*(href: string; width, height, arcPercent: int;
    stroke: string; strokeWeight: int; fill: string;
    label: EmailNode): EmailNode =
  ## `<v:roundrect xmlns:v=… xmlns:w=… href="{href}"
  ## style="height:{h}px;v-text-anchor:middle;width:{w}px;"
  ## arcsize="{a}%" strokecolor="{stroke}" [strokeweight="{sw}px"]
  ## fillcolor="{fill}" | filled="f"><w:anchorlock />{label}</v:roundrect>`.
  ## A shape with no fill (an outline button) is `filled="f"`.
  var attrs = @[("xmlns:v", "urn:schemas-microsoft-com:vml"),
    ("xmlns:w", "urn:schemas-microsoft-com:office:word"),
    ("href", href),
    ("style", "height:" & $height & "px;v-text-anchor:middle;width:" &
      $width & "px;"),
    ("arcsize", $arcPercent & "%"),
    ("strokecolor", stroke)]
  if strokeWeight > 0:
    attrs.add(("strokeweight", $strokeWeight & "px"))
  if fill.len > 0:
    attrs.add(("fillcolor", fill))
  else:
    attrs.add(("filled", "f"))
  newVml("v:roundrect", attrs, @[newVml("w:anchorlock"), label])
