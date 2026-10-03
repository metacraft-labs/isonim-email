## isonim_email/mso/vml.nim — VML shapes.
##
## A band's background image (catalogue R-VML-01): a `v:rect` filled
## with the image (`v:fill`), whose `v:textbox` holds the band's
## content, opened and closed in two `gte mso 9` conditionals around
## it (`vmlBackgroundOpen`, `vmlBackgroundClose`). Their payloads are
## unbalanced, so they ride as raw nodes inside typed conditionals, as
## the ghost tables do.
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
import ../serialize
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

proc vmlBackgroundOpen*(width, height: int; src, color, kind, origin,
    position, size, aspect: string; fit: bool): EmailNode =
  ## `<!--[if gte mso 9]><v:rect xmlns:v="urn:schemas-microsoft-com:vml"
  ## fill="true" stroke="false" style="width:{W}px;height:{H}px;"><v:fill
  ## type="{frame|tile}" origin="{x, y}" position="{x, y}" src="{src}"
  ## color="{bg}" [size="{s}"] [aspect="{a}"] /><v:textbox
  ## inset="0,0,0,0"[ style="mso-fit-shape-to-text:true"]><![endif]-->`.
  ## A `height` of 0 writes none: the rectangle of a band that grows
  ## with its content (R-VML-03, only with `fit`). Every value is
  ## escaped as an attribute value.
  var style = "width:" & $width & "px;"
  if height > 0:
    style.add("height:" & $height & "px;")
  var text = "<v:rect xmlns:v=\"urn:schemas-microsoft-com:vml\" " &
    "fill=\"true\" stroke=\"false\" style=\"" & style & "\">"
  text.add("<v:fill type=\"" & escapeEmailAttr(kind) & "\" origin=\"" &
    escapeEmailAttr(origin) & "\" position=\"" & escapeEmailAttr(position) &
    "\" src=\"" & escapeEmailAttr(src) & "\" color=\"" &
    escapeEmailAttr(color) & "\"")
  if size.len > 0:
    text.add(" size=\"" & escapeEmailAttr(size) & "\"")
  if aspect.len > 0:
    text.add(" aspect=\"" & escapeEmailAttr(aspect) & "\"")
  text.add(" />")
  text.add("<v:textbox inset=\"0,0,0,0\"")
  if fit:
    text.add(" style=\"mso-fit-shape-to-text:true\"")
  text.add(">")
  newMsoIf("gte mso 9", @[raw(text)])

proc vmlBackgroundClose*(): EmailNode =
  ## `<!--[if gte mso 9]></v:textbox></v:rect><![endif]-->`.
  newMsoIf("gte mso 9", @[raw("</v:textbox></v:rect>")])
