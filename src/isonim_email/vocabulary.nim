## isonim_email/vocabulary.nim — the static email vocabulary.
##
## Declares `staticVocabulary(EmailRenderer)`, the static-vocabulary hook (`isonim/dsl/ui.nim`
## `emitVocabCheck`) that makes `ui(EmailRenderer)` templates compile-time
## checked: unknown tags (with nearest-entry suggestions), forbidden elements
## (with reasons and alternatives), unknown attributes, and structural
## nesting rules. Reuses `checkElement` from `isonim/dsl/vocabulary`; this
## module only supplies the data, including the per-entry diagnostic code
## (sectioning tags report E-A11Y-SECTIONING) and the alternative a
## nesting error names (a bare `table`).
##
## Element set: the `mail*` mechanics elements plus the layout primitives
## (whose props tables the content patterns define; content patterns
## arrive later, via `defineMailPattern`). HTML leaves and the forbidden
## list are transcribed strictly: names the list omits (`tfoot`,
## `colgroup`, …) stay unknown tags until a schema change adds them.
## Value types ride along as informational `typ` strings for P2; the static
## check covers names only, so E-VOCAB-BAD-VALUE and E-VOCAB-DUPLICATE-ATTR
## stay out (owner: the P2 cascade check, not built yet).
## Application-registered patterns need a registration seam on top of
## this fixed proc (owner: the first content patterns).
##
## `buildEmailVocabulary` is a plain proc so tests can call it at runtime;
## the hook caches one instance in a compile-time var (the schema is big
## and every element would otherwise rebuild it).

import isonim/dsl/vocabulary
import isonim_email/renderer
from isonim_email/diagnostics import codeA11ySectioning

proc attr(name: string; kind: AttrKind; typ = ""): AttrDef =
  ## One schema row. `kind` mirrors the macro's style/attr routing, so a
  ## style keyword never lands in the plain-attribute array it is checked
  ## against; `typ` is a value-type name, `bool`/`string`/`int`/`set`, or —
  ## for ad-hoc enums — the pipe-joined options.
  AttrDef(name: name, kind: kind, typ: typ)

const
  sectioningReason = "sectioning elements are rewritten or stripped by " &
    "email clients (R-A11Y-10)"
  sectioningAlternative = "layout primitives and content patterns; the " &
    "patterns add landmark roles themselves"
    ## Shared by the nine sectioning tags, which report
    ## E-A11Y-SECTIONING rather than the generic forbidden-tag code.

proc buildEmailVocabulary*(): VocabularyRef =
  ## The full email schema. Runtime-callable (tests, and later P1/P2);
  ## the static-vocabulary hook below serves a cached instance at compile time.
  let trio = @["mailIf", "textOnly", "htmlOnly"]
  ## Transparent wrappers: `mailIf`/`textOnly`/`htmlOnly` lower to
  ## conditionals around unchanged content, so they join every non-empty
  ## parent list rather than breaking nesting chains. `mailDocument`
  ## stays strictly top-level (`@[""]`), or document counting breaks.
  VocabularyRef(
    tags: @[
      # -- Mechanics elements --
      TagDef(name: "mailDocument", allowedParents: @[""], attrs: @[
        attr("lang", akAttr, "string"),
        attr("dir", akAttr, "ltr|rtl|auto"),
        attr("title", akAttr, "string"),
        attr("preheader", akAttr, "string"),
        attr("background_color", akStyle, "Color"),
        attr("font_family", akStyle, "FontStack"),
        attr("width", akStyle, "Len"),
      ]),
      TagDef(name: "mailWrapper",
        allowedParents: @["mailDocument"] & trio, attrs: @[
        attr("background_color", akStyle, "Color"),
        attr("background_image", akStyle, "Url"),
        attr("padding", akStyle, "Box"),
        attr("border", akStyle, "Border"),
        attr("border_radius", akStyle, "Len"),
      ]),
      TagDef(name: "mailSection",
        allowedParents: @["mailDocument", "mailWrapper"] & trio, attrs: @[
        attr("background_color", akStyle, "Color"),
        attr("background_image", akStyle, "Url"),
        attr("background_size", akStyle, "cover|contain|Len"),
        attr("background_position", akAttr, "string"),
        attr("padding", akStyle, "Box"),
        attr("border", akStyle, "Border"),
        attr("border_radius", akStyle, "Len"),
        attr("full_width", akAttr, "bool"),
        attr("text_align", akStyle, "Align"),
        attr("direction", akAttr, "ltr|rtl"),
        attr("reverse_on_mobile", akAttr, "bool"),
        attr("stack", akAttr, "mobile|never"),
      ]),
      # `mailColumns` joins R-LAY-16's letter (`mailSection`/`mailGroup`):
      # pattern rows hold `mailColumn` children by design.
      TagDef(name: "mailColumn",
        allowedParents: @["mailSection", "mailGroup", "mailColumns"] & trio,
        attrs: @[
        attr("width", akStyle, "Len"),
        attr("vertical_align", akAttr, "VAlign"),
        attr("padding", akStyle, "Box"),
        attr("inner_padding", akAttr, "Box"),
        attr("background_color", akStyle, "Color"),
        attr("border", akStyle, "Border"),
        attr("border_radius", akStyle, "Len"),
        attr("min_width", akStyle, "Len"),
      ]),
      TagDef(name: "mailGroup",
        allowedParents: @["mailSection"] & trio, attrs: @[
        attr("width", akStyle, "Len"),
        attr("vertical_align", akAttr, "VAlign"),
        attr("background_color", akStyle, "Color"),
      ]),
      TagDef(name: "mailButton", attrs: @[
        attr("href", akAttr, "Url"),
        attr("tone", akAttr, "Tone"),
        attr("variant", akAttr, "solid|outline|link"),
        attr("background_color", akStyle, "Color"),
        attr("color", akStyle, "Color"),
        attr("border", akStyle, "Border"),
        attr("border_radius", akStyle, "Len"),
        attr("padding", akStyle, "Box"),
        attr("width", akStyle, "Len"),
        attr("height", akStyle, "Len"),
        attr("align", akAttr, "Align"),
        attr("vml", akAttr, "auto|always|never"),
        attr("font_size", akStyle, "Len"),
        attr("font_weight", akStyle, "string"),
        attr("line_height", akStyle, "Len"),
      ]),
      TagDef(name: "mailImage", attrs: @[
        attr("src", akAttr, "Url"),
        attr("alt", akAttr, "string"),
        attr("decorative", akAttr, "bool"),
        attr("width", akStyle, "Len"),
        attr("height", akStyle, "Len"),
        attr("href", akAttr, "Url"),
        attr("align", akAttr, "Align"),
        attr("dark_src", akAttr, "Url"),
        attr("fluid_on_mobile", akAttr, "bool"),
        attr("border_radius", akStyle, "Len"),
      ]),
      TagDef(name: "mailSpacer", attrs: @[
        attr("height", akStyle, "Len"),
      ]),
      TagDef(name: "mailDivider", attrs: @[
        attr("border", akStyle, "Border"),
        attr("padding", akStyle, "Box"),
        attr("width", akStyle, "Len"),
      ]),
      TagDef(name: "mailTable", attrs: @[
        attr("caption", akAttr, "string"),
        attr("mobile", akAttr, "stack|scroll|keep"),
        attr("striped", akAttr, "bool"),
        attr("border", akStyle, "Border"),
      ]),
      # Font props mirror the button's five: color, family, size, weight, line height.
      TagDef(name: "mailText", attrs: @[
        attr("padding", akStyle, "Box"),
        attr("align", akAttr, "Align"),
        attr("color", akStyle, "Color"),
        attr("font_family", akStyle, "FontStack"),
        attr("font_size", akStyle, "Len"),
        attr("font_weight", akStyle, "string"),
        attr("line_height", akStyle, "Len"),
      ]),
      TagDef(name: "mailMarkdown", attrs: @[
        attr("src", akAttr, "string"),
      ]),
      # No `mode` prop: the hero's image/background mode is read from
      # the props given.
      TagDef(name: "mailHero", attrs: @[
        attr("background_image", akStyle, "Url"),
        attr("background_color", akStyle, "Color"),
        attr("height", akStyle, "Len"),
        attr("min_height", akStyle, "Len"),
        attr("padding", akStyle, "Box"),
        attr("vertical_align", akAttr, "VAlign"),
      ]),
      TagDef(name: "mailSocial", attrs: @[
        attr("align", akAttr, "Align"),
        attr("icon_size", akAttr, "Len"),
        attr("mode", akAttr, "light|dark|auto"),
      ]),
      TagDef(name: "mailSocialItem",
        allowedParents: @["mailSocial"] & trio, attrs: @[
        attr("network", akAttr, "string"),
        attr("href", akAttr, "Url"),
      ]),
      TagDef(name: "mailNavbar", attrs: @[
        attr("align", akAttr, "Align"),
        attr("separator", akAttr, "string"),
      ]),
      TagDef(name: "mailNavLink",
        allowedParents: @["mailNavbar"] & trio, attrs: @[
        attr("href", akAttr, "Url"),
      ]),
      TagDef(name: "mailRaw", attrs: @[]),
      TagDef(name: "mailIf", attrs: @[
        attr("mso", akAttr, "bool"),
        attr("family", akAttr, "set"),
      ]),
      TagDef(name: "textOnly", attrs: @[]),
      TagDef(name: "htmlOnly", attrs: @[]),
      # -- Layout primitives (props from the content patterns) --
      TagDef(name: "mailStack", attrs: @[
        attr("gap", akStyle, "Len"),
        attr("align", akAttr, "Align"),
      ]),
      TagDef(name: "mailBox", attrs: @[
        attr("padding", akStyle, "Box"),
        attr("background_color", akStyle, "Color"),
        attr("border", akStyle, "Border"),
        attr("border_radius", akStyle, "Len"),
        attr("shadow", akAttr, "none|sm|md"),
        attr("outlook_rounded", akAttr, "bool"),
      ]),
      # `strategy` lives on `mailColumns` only: the columns' choice is
      # one strategy for the pair, not per column.
      TagDef(name: "mailColumns", attrs: @[
        attr("strategy", akAttr, "hybrid|fabFour|cellsStacking|cells"),
        attr("gutter", akAttr, "Len"),
        attr("valign", akAttr, "VAlign"),
        attr("reverse_on_mobile", akAttr, "bool"),
        attr("min_column", akAttr, "Len"),
        attr("equal_height", akAttr, "bool"),
      ]),
      TagDef(name: "mailGrid", attrs: @[
        attr("columns", akAttr, "int"),
        attr("mobile_columns", akAttr, "1|2"),
        attr("gutter", akAttr, "Len"),
        attr("min_item", akAttr, "Len"),
        attr("align", akAttr, "Align"),
        attr("last_row", akAttr, "stretch|left|center"),
      ]),
      TagDef(name: "mailCluster", attrs: @[
        attr("gap", akStyle, "Len"),
        attr("row_gap", akStyle, "Len"),
        attr("align", akAttr, "Align"),
        attr("separator", akAttr, "string"),
      ]),
      TagDef(name: "mailSidebar", attrs: @[
        attr("side", akAttr, "left|right"),
        attr("fixed", akAttr, "Len"),
        attr("valign", akAttr, "VAlign"),
        attr("gap", akStyle, "Len"),
        attr("switch_below", akAttr, "Len"),
        attr("reverse_on_mobile", akAttr, "bool"),
      ]),
      # -- HTML leaves: listed attributes plus any style
      # keyword (`allowAnyStyle`); styles stay CSS for leaves.
      TagDef(name: "h1", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "h2", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "h3", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "h4", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "h5", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "h6", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "p", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "span", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "strong", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "em", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "b", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "i", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "u", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "s", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "small", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "sup", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "sub", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "br", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "blockquote", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "code", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "pre", allowAnyStyle: true, attrs: @[
        attr("lang", akAttr, "string"), attr("dir", akAttr, "string"),
        attr("title", akAttr, "string"),
      ]),
      TagDef(name: "a", allowAnyStyle: true, attrs: @[
        attr("href", akAttr, "Url"), attr("title", akAttr, "string"),
        attr("target", akAttr, "string"), attr("rel", akAttr, "string"),
      ]),
      TagDef(name: "ul", allowAnyStyle: true, attrs: @[]),
      TagDef(name: "ol", allowAnyStyle: true, attrs: @[
        attr("start", akAttr, "int"),
      ]),
      TagDef(name: "li", allowAnyStyle: true,
        allowedParents: @["ul", "ol"] & trio, attrs: @[]),
      # Strictly column-or-text: pattern slots do not exist yet, so
      # nothing else is listed until they do.
      TagDef(name: "div", allowAnyStyle: true,
        allowedParents: @["mailColumn", "mailText"] & trio, attrs: @[]),
      # A bare `table` elsewhere is a layout table in disguise: the
      # nesting error names both ways out.
      TagDef(name: "table", allowAnyStyle: true,
        allowedParents: @["mailTable"] & trio,
        nestingAlternative: "mailTable (data) or layout primitives",
        attrs: @[]),
      TagDef(name: "thead", allowAnyStyle: true,
        allowedParents: @["table"] & trio, attrs: @[]),
      TagDef(name: "tbody", allowAnyStyle: true,
        allowedParents: @["table"] & trio, attrs: @[]),
      TagDef(name: "caption", allowAnyStyle: true,
        allowedParents: @["table"] & trio, attrs: @[]),
      TagDef(name: "tr", allowAnyStyle: true,
        allowedParents: @["table", "thead", "tbody"] & trio, attrs: @[]),
      # `colspan` on both cell kinds in the static check; header-rows-only (R-TBL-06)
      # needs row position, which is P1's job.
      TagDef(name: "th", allowAnyStyle: true,
        allowedParents: @["tr"] & trio, attrs: @[
        attr("scope", akAttr, "string"), attr("colspan", akAttr, "int"),
      ]),
      TagDef(name: "td", allowAnyStyle: true,
        allowedParents: @["tr"] & trio, attrs: @[
        attr("colspan", akAttr, "int"),
      ]),
    ],
    forbidden: @[
      ForbiddenTag(tag: "img",
        reason: "bare images skip sizing, alt and dark-mode rules",
        alternative: "mailImage"),
      ForbiddenTag(tag: "hr",
        reason: "hr renders inconsistently in Outlook",
        alternative: "mailDivider"),
      ForbiddenTag(tag: "button",
        reason: "native buttons render inconsistently across clients",
        alternative: "mailButton"),
      ForbiddenTag(tag: "script",
        reason: "no email client runs scripts",
        alternative: "a mailButton linking to a hosted page"),
      ForbiddenTag(tag: "iframe",
        reason: "no email client renders iframes",
        alternative: "a mailButton linking to the hosted page"),
      ForbiddenTag(tag: "object",
        reason: "plugins run in no email client", alternative: ""),
      ForbiddenTag(tag: "embed",
        reason: "plugins run in no email client", alternative: ""),
      ForbiddenTag(tag: "form",
        reason: "forms cannot submit from an email",
        alternative: "a mailButton linking to a hosted form"),
      # Unconditional until the checkbox-hack components land: the
      # "outside the checkbox-hack components" carve-out has no referent yet.
      ForbiddenTag(tag: "input",
        reason: "form controls cannot submit from an email",
        alternative: "a mailButton linking to a hosted form"),
      ForbiddenTag(tag: "select",
        reason: "form controls cannot submit from an email",
        alternative: "a mailButton linking to a hosted form"),
      ForbiddenTag(tag: "textarea",
        reason: "form controls cannot submit from an email",
        alternative: "a mailButton linking to a hosted form"),
      ForbiddenTag(tag: "video",
        reason: "video plays in almost no email client",
        alternative: "a mailImage poster linking to the video page"),
      ForbiddenTag(tag: "audio",
        reason: "audio plays in almost no email client",
        alternative: "a mailButton linking to the audio"),
      ForbiddenTag(tag: "canvas",
        reason: "canvas needs scripts, which email cannot carry",
        alternative: "a PNG via mailImage"),
      ForbiddenTag(tag: "svg",
        reason: "SVG is unsupported in most email clients (R-IMG-08)",
        alternative: "a PNG @2x via mailImage"),
      ForbiddenTag(tag: "picture",
        reason: "picture/source selection is unsupported in email",
        alternative: "mailImage (with dark_src for dark mode)"),
      ForbiddenTag(tag: "link",
        reason: "the document head is generated by mailDocument",
        alternative: ""),
      ForbiddenTag(tag: "style",
        reason: "the document head is generated by mailDocument",
        alternative: ""),
      ForbiddenTag(tag: "meta",
        reason: "the document head is generated by mailDocument",
        alternative: ""),
      ForbiddenTag(tag: "nav", code: codeA11ySectioning,
        reason: sectioningReason, alternative: sectioningAlternative),
      ForbiddenTag(tag: "main", code: codeA11ySectioning,
        reason: sectioningReason, alternative: sectioningAlternative),
      ForbiddenTag(tag: "article", code: codeA11ySectioning,
        reason: sectioningReason, alternative: sectioningAlternative),
      ForbiddenTag(tag: "section", code: codeA11ySectioning,
        reason: sectioningReason, alternative: sectioningAlternative),
      ForbiddenTag(tag: "header", code: codeA11ySectioning,
        reason: sectioningReason, alternative: sectioningAlternative),
      ForbiddenTag(tag: "footer", code: codeA11ySectioning,
        reason: sectioningReason, alternative: sectioningAlternative),
      ForbiddenTag(tag: "aside", code: codeA11ySectioning,
        reason: sectioningReason, alternative: sectioningAlternative),
      ForbiddenTag(tag: "details", code: codeA11ySectioning,
        reason: sectioningReason, alternative: sectioningAlternative),
      ForbiddenTag(tag: "summary", code: codeA11ySectioning,
        reason: sectioningReason, alternative: sectioningAlternative),
    ])

var vocabCache {.compileTime.}: VocabularyRef

proc staticVocabulary*(T: typedesc[EmailRenderer]): VocabularyRef
    {.compileTime.} =
  ## The static-vocabulary hook: `ui(EmailRenderer)` checks every element against this.
  if vocabCache == nil:
    vocabCache = buildEmailVocabulary()
  vocabCache
