## isonim_email/mso/document.nim — document-level MSO conditionals.
##
## The two fixed `<!--[if mso]>` fragments the catalogue §1 skeleton
## carries: `OfficeDocumentSettings` (R-DOC-08) and the `lte mso 11`
## group fix (the class hook R-LAY-10 uses; the group lowering lands
## later). Both are byte-exact literals: the `<o:AllowPNG/>`
## self-closer has no typed form (the serialiser emits `<tag></tag>`
## for empty elements and ` />` for VML), so the settings payload
## rides as one raw node inside a typed `MsoIf`.
##
## Allowed IR site: `tests/t1_ir_restriction.nim` admits constructor
## calls from `mso/`.
##
## Pure tree building: identical on the C and JS targets.

import ../ir

export ir

const officeSettingsPayload* =
  "<noscript><xml><o:OfficeDocumentSettings><o:AllowPNG/>" &
  "<o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings>" &
  "</xml></noscript>"
  ## The R-DOC-08 payload: `AllowPNG` + `PixelsPerInch 96` inside
  ## `<noscript><xml>`, so the XML never leaks into non-Outlook
  ## clients. Catalogue §1, byte-exact.

const msoGroupFixCss* = ".e-mso-group-fix{width:100% !important;}"
  ## The `lte mso 11` group-fix rule (catalogue §1): Outlook ≤ 11
  ## needs the group width re-asserted. Exact literal.

proc officeDocumentSettings*(): EmailNode =
  ## `<!--[if mso]><noscript><xml>…</xml></noscript><![endif]-->`
  ## (R-DOC-08). Emitted only when `EmailTarget.outlookWord` (the
  ## ⟪mso⟫ marker in catalogue §1); the caller gates.
  newMsoIf("mso", @[raw(officeSettingsPayload)])

proc msoGroupFix*(): EmailNode =
  ## `<!--[if lte mso 11]><style>…group-fix…</style><![endif]-->`.
  ## Emitted only when `EmailTarget.outlookWord`; the caller gates.
  newMsoIf("lte mso 11", @[newHeadStyle(msoGroupFixCss, 0)])
