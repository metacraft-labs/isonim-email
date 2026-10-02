## isonim_email/diagnostics.nim — stable codes and the EmailDiagnostic pipe.
##
## Codes are stable: a new code is added below, with a
## negative-control test, before it is emitted. The prefix is the severity
## (`E` error, `W` warning, `I` info) and the middle segment the area.
##
## Reconciliation with the tree builder: `EmailRenderer` raises
## `EmailRenderError` (renderer.nim) whose message carries a stable
## diagnostic code up front
## (e.g. `E-STRUCT-REACTIVE-RESIDUE: …`). That stays — fatal render aborts
## keep raising, and the existing tests pin that. What this module adds is
## the conversion both ways: `toDiagnostic` parses a raised message into
## an `EmailDiagnostic` (severity from the code prefix), and
## `raiseDiagnostic` raises one through `EmailRenderError`, so later passes
## can collect diagnostics and still abort through the same type.

import std/strutils
import ./renderer
import ./target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

export renderer
export target

type Severity* = enum
  sevInfo, sevWarning, sevError

const
  codeCssHarmful* = "E-CSS-HARMFUL"
    ## Harmful in a weighted family, e.g. layout `display:flex` (R-OL-10)
  codeSupportUnsupported* = "W-SUPPORT-UNSUPPORTED"
    ## Unsupported in ≥ 5% of profile weight, with no declared fallback
  codeSupportDegradation* = "I-SUPPORT-DEGRADATION"
    ## Unsupported, with a declared fallback
  codeThemeMissingToken* = "E-THEME-MISSING-TOKEN"
    ## A required theme key is missing at theme load. Raised from
    ## `style/tokens.nim` as `ThemeError` (that module stays framework-free
    ## so the theme generator and the JS target avoid the renderer import);
    ## the `CODE: message` shape converts via `toDiagnostic`.
  codeVocabBadValue* = "E-VOCAB-BAD-VALUE"
    ## A value fails its declared type. Raised from `style/units.nim`,
    ## `style/colors.nim` and `style/shorthand.nim` as `StyleError`
    ## (framework-free, same seam as `ThemeError`).
  codeCssInvalid* = "E-CSS-INVALID"
    ## The CSS serialiser rejected a rule (R-CSS-05). Raised from
    ## `style/css.nim` and `style/classes.nim` as `StyleError`.
  codeLayoutMarginConverted* = "W-LAYOUT-MARGIN-CONVERTED"
    ## P5 moved a margin to cell padding (R-OL-04). Collected from
    ## `passes/styles.nim` (framework-touching, so a diagnostic, not a
    ## `StyleError`).
  codeDarkRawColor* = "W-DARK-RAW-COLOR"
    ## A raw (non-token) colour under `darkMode = designed`.
    ## Collected from `passes/styles.nim`, like the margin conversion.
  codeCssBlockDropped* = "W-CSS-BLOCK-DROPPED"
    ## P6 dropped a head block for budget (R-CSS-07). Collected from
    ## `passes/head.nim` (the registered budget code).
  codeCssOverBudget* = "W-CSS-OVER-BUDGET"
    ## The head blocks P6 never drops (reset, responsive) alone exceed
    ## `headStyleBudget`, so Gmail will truncate them (R-CSS-07).
    ## Collected from `passes/head.nim`; `strict` raises it.
  codeStructNoDocument* = "E-STRUCT-NO-DOCUMENT"
    ## P1 found zero or more than one `mailDocument`.
    ## Collected from `passes/validate.nim`.
  codeStructInvalidUtf8* = "E-STRUCT-INVALID-UTF8"
    ## P1 found a text node that is not valid UTF-8.
    ## Collected from `passes/validate.nim`.
  codeStructRawOutside* = "E-STRUCT-RAW-OUTSIDE"
    ## P1 found a raw node that is not inside `mailRaw`, the only
    ## element whose content may be verbatim HTML.
    ## Collected from `passes/validate.nim`.
  codeStructReactiveResidue* = "E-STRUCT-REACTIVE-RESIDUE"
    ## P1 collected `assertNoReactiveResidue` instead of raising it.
    ## Collected from `passes/validate.nim`.
  codeA11yLangMissing* = "E-A11Y-LANG-MISSING"
    ## `mailDocument` without `lang` (R-DOC-02). Collected from
    ## `passes/validate.nim`.
  codeA11yTitleMissing* = "E-A11Y-TITLE-MISSING"
    ## `mailDocument` without `title` (R-DOC-10). Collected from
    ## `passes/validate.nim`.
  codeA11yNoH1* = "E-A11Y-NO-H1"
    ## No `h1` anywhere in the tree (R-A11Y-03). Collected from
    ## `passes/validate.nim`.
  codeA11yAltMissing* = "E-A11Y-ALT-MISSING"
    ## Image without `alt` and not decorative (R-A11Y-04, R-IMG-04).
    ## Collected from `passes/validate.nim`.
  codeA11ySectioning* = "E-A11Y-SECTIONING"
    ## A sectioning element (`nav`, `main`, `article`, `section`,
    ## `header`, `footer`, `aside`, `details`, `summary`) in a template
    ## (R-A11Y-10: clients rewrite or strip them). Reported at compile
    ## time by the static vocabulary (`vocabulary.nim`) and, for trees
    ## built by hand, collected from `passes/validate.nim`.
  codeA11yTableCaption* = "E-A11Y-TABLE-CAPTION"
    ## `mailTable` without a `caption` child (R-A11Y-02). Collected
    ## from `passes/a11y.nim`.
  codeA11yHeadingSkip* = "W-A11Y-HEADING-SKIP"
    ## Heading level skipped, e.g. h1 → h3 (R-TXT-10). Collected
    ## from `passes/a11y.nim`.
  codeA11yLinkText* = "W-A11Y-LINK-TEXT"
    ## "Click here" style link text (R-A11Y-06). Collected from
    ## `passes/lint.nim`.
  codeA11yContrast* = "W-A11Y-CONTRAST"
    ## Text/background pair below threshold in the light scheme
    ## (R-A11Y-07). Collected from `passes/lint.nim`.
  codeA11yContrastDark* = "E-A11Y-CONTRAST"
    ## Text/background pair below threshold in the designed dark scheme
    ## (R-DRK-04). Collected from `passes/lint.lintDarkContrast`.
  codeImgAltFit* = "W-IMG-ALT-FIT"
    ## With images off, WebKit shows no alt text for an image whose alt
    ## does not fit its width on one line (R-IMG-03). Collected from
    ## `lower/image.nim`.
  codeAssetFormat* = "E-ASSET-FORMAT"
    ## WebP or SVG image under a profile that gives Word-engine Outlook
    ## or Gmail weight (R-IMG-08, R-OL-13). Collected from
    ## `passes/lint.nim`.
  codeA11yAltLong* = "W-A11Y-ALT-LONG"
    ## Alt longer than 60 characters (R-IMG-04, text-in-image
    ## heuristic). Collected from `passes/lint.nim`.
  codeSizeNearClip* = "W-SIZE-NEAR-CLIP"
    ## Decoded HTML exceeds `EmailTarget.sizeBudget` (R-SIZE-01).
    ## Emitted by `passes/lint.checkSize` (P10).
  codeSizeClip* = "E-SIZE-CLIP"
    ## Decoded HTML exceeds 100,000 bytes: Gmail will clip it
    ## (R-SIZE-01). Emitted by `passes/lint.checkSize` (P10).
  codeMimeHeader* = "E-MIME-HEADER"
    ## An invalid header value, e.g. an unsubscribe URI that is not
    ## https (R-SND-01), an attachment filename with CR or LF, or a
    ## deterministic seed that cannot derive a valid Message-ID.
    ## Emitted by `mime/headers.ownedHeaders`; raised by
    ## `mime/message.toMessage` and `toRfc5322`.
  codeMimeUnsubToken* = "W-MIME-UNSUB-TOKEN"
    ## An unsubscribe URI without an opaque token of at least 16
    ## characters (R-SND-02). Emitted by `mime/headers.ownedHeaders`
    ## and returned to the caller on `EmailMessage.diagnostics` by
    ## `mime/message.toMessage`.
  codeTextOmitted* = "I-TEXT-OMITTED"
    ## The rendered email carries no plain-text part yet, so the
    ## message is sent as HTML only — never with an empty `text/plain`
    ## part. Emitted by `mime/message.toMessage` on
    ## `EmailMessage.diagnostics`.
  codeUrlScheme* = "E-URL-SCHEME"
    ## A forbidden URL scheme, e.g. a `data:` URI (R-IMG-08). Raised
    ## from `assets.nim` as `AssetError` (framework-free, same seam as
    ## `StyleError`); the `CODE: message` shape converts via
    ## `toDiagnostic`.
  codeAssetUnknown* = "E-ASSET-UNKNOWN"
    ## An asset the store cannot resolve. Raised from `assets.nim` as
    ## `AssetError`, like `codeUrlScheme`.
  codeAssetUnpublished* = "E-ASSET-UNPUBLISHED"
    ## A hosted message references an asset that was never published
    ## (its `url` is empty), so the upload did not complete before the
    ## message was built (R-IMG-07). Raised by `mime/message.toMessage`
    ## and `toRfc5322`.

  codeLowerMissing* = "E-LOWER-MISSING"
    ## A vocabulary element, or a prop of a lowered element, with no
    ## lowering yet. Never passed through as a raw custom tag, never
    ## dropped silently. Collected from `lower/elements.nim` and
    ## `lower/image.nim`.
  codeLayoutImageWidth* = "E-LAYOUT-IMAGE-WIDTH"
    ## A `mailImage` with no px width and no known intrinsic size, so
    ## the required `width` attribute cannot be emitted (R-IMG-01).
    ## Collected from `lower/image.nim`.
  codeStructNesting* = "E-STRUCT-NESTING"
    ## An illegal parent/child pairing the static check cannot see in a
    ## hand-built tree or a composed one: a section that mixes columns
    ## with other content, anything but columns in a group (R-LAY-16).
    ## Collected from `passes/layout.nim`.

  codeTblUnexpected* = "W-TBL-UNEXPECTED"
    ## A layout `table` outside the constructs allowed to emit one
    ## (R-TBL-01): in the authoring tree, any `table` that is not inside
    ## a `mailTable`. Collected from `passes/lint.nim`.
  codeTblDeep* = "W-TBL-DEEP"
    ## More than three levels of layout tables outside Outlook
    ## conditionals in the lowered document (R-TBL-15). Collected from
    ## `passes/lint.nim`.
  codeTblSpan* = "W-TBL-SPAN"
    ## `rowspan` anywhere, or `colspan` outside a data table's header
    ## row (R-TBL-06). Collected from `passes/lint.nim`.
  codeCssMsoUnlisted* = "W-CSS-MSO-UNLISTED"
    ## An `mso-*` property outside the closed list (R-OL-15): its effect
    ## in Word is unverified. Collected from `passes/lint.nim`.
  codeLayoutMinColumn* = "W-LAYOUT-MIN-COLUMN"
    ## A column of a cell row (`cells`, `cellsStacking`) whose content
    ## box at a 320px document is narrower than its declared minimum
    ## (R-TBL-11); an error under `strict`. Collected from
    ## `passes/layout.nim`.
  codeLayoutReverseText* = "E-LAYOUT-REVERSE-TEXT"
    ## `reverse_on_mobile` on a row where more than one column holds
    ## text, or in a right-to-left row (R-LAY-11). Collected from
    ## `passes/validate.nim`.
  codeTblRagged* = "I-TBL-RAGGED"
    ## A bordered or background-carrying item in a row whose items do
    ## not share a height: a `hybrid` or `fabFour` row's column, a
    ## section's own column, a `mailGrid` item (R-TBL-10). Information:
    ## the ragged bottoms are a declared degradation, and the code makes
    ## the choice a visible one. Collected from `passes/lint.nim`.
  codePatternGridOrphan* = "E-PATTERN-GRID-ORPHAN"
    ## `mailGrid(columns = 3, mobile_columns = 2)`: two per row on a
    ## phone leaves an orphan item in every second row. Collected from
    ## `passes/validate.nim`.
  codeA11yTapTarget* = "W-A11Y-TAP-TARGET"
    ## A tap target too small or too close: interactive items of a
    ## `mailCluster` closer than 8px (R-TBL-12). Collected from
    ## `passes/lint.nim`.

type EmailDiagnostic* = object
  severity*: Severity
  code*: string
  message*: string
  origin*: SourceSpan
  families*: set[ClientFamily]
  weight*: float
  rules*: seq[string] ## Catalogue rule IDs (empty when none apply)

proc severityOfCode*(code: string): Severity =
  ## Derives severity from the code prefix. Raises `ValueError` on an
  ## unknown prefix — codes are a closed registry, never ad-hoc strings.
  if code.startsWith("E-"):
    sevError
  elif code.startsWith("W-"):
    sevWarning
  elif code.startsWith("I-"):
    sevInfo
  else:
    raise newException(ValueError,
      "diagnostic code '" & code &
      "' has no E-/W-/I- prefix (register it in diagnostics.nim first)")

proc hasErrors*(d: openArray[EmailDiagnostic]): bool =
  ## True when any diagnostic is an error.
  for diag in d:
    if diag.severity == sevError:
      return true
  false

proc `$`*(severity: Severity): string =
  case severity
  of sevInfo: "info"
  of sevWarning: "warning"
  of sevError: "error"

proc `$`*(d: EmailDiagnostic): string =
  ## `file:line:col: severity CODE: message [R-…]`. The
  ## rule list is omitted when empty.
  result = $d.origin & ": " & $d.severity & " " & d.code & ": " & d.message
  if d.rules.len > 0:
    result.add(" [" & d.rules.join(", ") & "]")

proc toDiagnostic*(msg: string;
                   origin = SourceSpan();
                   families: set[ClientFamily] = {};
                   weight = 0.0;
                   rules: seq[string] = @[]): EmailDiagnostic =
  ## Parses an `EmailRenderError`-style `CODE: message` string into an
  ## `EmailDiagnostic`, deriving severity from the code prefix. Raises
  ## `ValueError` when the message carries no `CODE: ` head — every raise
  ## site must name its stable code.
  let sep = msg.find(": ")
  if sep <= 0:
    raise newException(ValueError,
      "cannot convert to EmailDiagnostic (no 'CODE: ' head): '" & msg & "'")
  let code = msg[0 ..< sep]
  EmailDiagnostic(
    severity: severityOfCode(code),
    code: code,
    message: msg[sep + 2 .. ^1],
    origin: origin,
    families: families,
    weight: weight,
    rules: rules,
  )

proc raiseDiagnostic*(d: EmailDiagnostic) {.noreturn.} =
  ## Raises a diagnostic through `EmailRenderError`, keeping one abort
  ## type for the whole pipeline.
  raise newException(EmailRenderError, d.code & ": " & d.message)
