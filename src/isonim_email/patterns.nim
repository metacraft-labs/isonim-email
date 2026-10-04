## isonim_email/patterns.nim — vocabulary elements defined by expansion,
## and the review declarations every primitive and pattern carries.
##
## A pattern is a vocabulary element (`mailCard`, `mailCallout`, an
## application's own) whose lowering is an **expansion**: a proc that
## turns the element, its typed props and its content into a tree built
## only from vocabulary elements and HTML leaves. `defineMailPattern`
## registers one, with two declarations the review brief generator
## reads (`review/brief.nim`):
##
## - `expectedElements`: what a screenshot of the pattern must show,
##   one brief line each, for the client the brief is written for;
## - `degradations`: what that client is expected to get wrong, as
##   declared (the brief lists them so a reviewer does not report them,
##   and does report anything else).
##
## Both are mandatory: a pattern nobody can review is not shipped. The
## layout primitives (`mailBox`, `mailGrid`, `mailCluster`,
## `mailSidebar`, registered by `primitives.nim`) carry the same two
## declarations; their own lowerings live in `lower/`, so their
## expansion returns nil ("lowered by its own lowering"), except where a
## primitive is itself a composition (`mailGrid(mobile_columns = 2)`).
##
## When expansion runs: first, before validation (`expandPatterns`, run
## by the render entries), so the expanded tree goes through the whole
## pipeline (P1 validation, P3 widths, P5 styles, P6 head rules) like
## any authored tree. The pattern element stays in the tree with its
## props, holding its expansion as its only child (`expanded` is set);
## lowering replaces it by that child. Briefs read the unexpanded tree:
## a pattern's lines come from its own declarations, and the content it
## was given is walked as usual.
##
## Props are the fields of a plain object type (`string`, `bool`, `int`,
## `float`, or an enum), read from the element's attributes and styles
## under the field's name (`background_color` or `background-color`);
## a field the element does not set keeps its declared default. A value
## that does not parse, or an expansion that raises `PatternError`, is
## `E-VOCAB-BAD-VALUE` at the element.
##
## Pure tree building: identical on the C and JS targets.

import std/[strutils, tables]
import isonim/dsl/vocabulary
import ./renderer
import ./target
import ./diagnostics
import ./style/tokens
import ./passes/layout
import ./vocabulary as emailVocabulary

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies

type
  ExpandCtx* = object
    ## What an expansion may read: the render's theme and target, and a
    ## builder for the nodes it creates.
    theme*: EmailTheme
    target*: EmailTarget
    r*: EmailRenderer
    diagnostics*: ref seq[EmailDiagnostic]
      ## What an expansion reports beside the tree it returns (a warning
      ## about the content it was given, an error for content it left
      ## out); collected with the expansion's own `E-VOCAB-BAD-VALUE`.
      ## Nil outside `expandPatterns`: `report` then drops nothing, it
      ## raises.

  BriefView* = object
    ## The client a review brief is written for, as a pattern's
    ## declarations see it.
    client*: string       ## Backend A's family (`apple`, `ganga`, `wordApprox`, …) or a real client's id (`roundcube`, …)
    audience*: bool       ## The client is an audience family (`family` is set)
    family*: ClientFamily ## Its audience family, when `audience`
    headCss*: bool        ## The message's `<style>` blocks reach the render
    mediaQueries*: bool   ## …and their media queries apply
    word*: bool           ## Word's ghost tables lay the message out (classic Outlook or its approximation)
    width*: int           ## The viewport's layout width (px)
    real*: bool           ## A real client (`client` is its id), not backend A's family
    breakpoint*: int      ## The target's mobile/desktop breakpoint (px)

  ExpandProc* = proc(n: EmailNode; ctx: ExpandCtx): EmailNode {.closure.}
    ## The untyped expansion: nil means "no expansion, the element has a
    ## lowering of its own".
  BriefProc* = proc(n: EmailNode; view: BriefView): seq[string] {.closure.}
    ## An untyped declaration: brief lines for one client.

  PatternDef* = object
    ## One registered pattern or primitive.
    name*: string
    expand*: ExpandProc
    expectedElements*: BriefProc
    degradations*: BriefProc
    itemOf*: string
      ## For an item element (a `mailStep`, a `mailSocialItem`), the
      ## pattern that places it; "" for a pattern that stands on its
      ## own. An item never appears outside its parent, so its parent's
      ## stories are its stories (layout-patterns.md §5).

  PatternError* = object of ValueError
    ## A prop value that does not parse, or an expansion that refuses its
    ## input; reported as `E-VOCAB-BAD-VALUE` at the element.

proc report*(ctx: ExpandCtx; d: EmailDiagnostic) =
  ## Records `d` for the render, beside the expansion's tree. Without a
  ## collector (an expansion run outside `expandPatterns`) an error is a
  ## `PatternError`, so it is never lost; anything less is dropped.
  if ctx.diagnostics != nil:
    ctx.diagnostics[].add(d)
  elif d.severity == sevError:
    raise newException(PatternError, d.code & ": " & d.message)

proc narrow*(view: BriefView): bool =
  ## True when the viewport is below the breakpoint (a phone).
  view.width < view.breakpoint

proc stacksHere*(view: BriefView): bool =
  ## True when a mobile-first row (inline-block items that take their
  ## desktop arrangement from a `min-width` rule, or stack by a
  ## `max-width` rule) is in its stacked state in this client: on a
  ## phone with head CSS, never in Word.
  not view.word and view.headCss and view.mediaQueries and view.narrow

var patternRegistry = initOrderedTable[string, PatternDef]()

proc registerPattern*(def: PatternDef) =
  ## Registers one pattern. Both declarations are mandatory; a name
  ## registered twice raises (two definitions must never shadow each
  ## other silently).
  if def.name.len == 0:
    raise newException(PatternError, "a pattern needs a name")
  if def.expectedElements == nil or def.degradations == nil:
    raise newException(PatternError, "pattern '" & def.name &
      "' must declare expectedElements and degradations: the review " &
      "brief generator reads both")
  if def.name in patternRegistry:
    raise newException(PatternError, "pattern '" & def.name &
      "' is already defined")
  patternRegistry[def.name] = def

proc isPattern*(tag: string): bool =
  ## True when `tag` is a registered pattern or primitive.
  tag in patternRegistry

proc patternOf*(tag: string): PatternDef =
  ## The registered definition of `tag`; raises `PatternError` when none.
  if tag notin patternRegistry:
    raise newException(PatternError, "no pattern '" & tag & "'")
  patternRegistry[tag]

proc patternNames*(): seq[string] =
  ## Registered names, in registration order.
  for k in patternRegistry.keys:
    result.add(k)

proc declareItemOf*(name, parent: string) =
  ## Marks the registered pattern `name` as an item element that only
  ## `parent` places (its `itemOf`); raises `PatternError` when either is
  ## not registered.
  if name notin patternRegistry or parent notin patternRegistry:
    raise newException(PatternError, "declareItemOf: '" & name & "' and '" &
      parent & "' must both be registered")
  patternRegistry[name].itemOf = parent

# --- Typed props ------------------------------------------------------------

proc propText*(n: EmailNode; name: string): string =
  ## The raw value of prop `name` on `n` (attribute or style, either
  ## spelling), "" when unset.
  rawValue(n, name)

proc resolveProp*(ctx: ExpandCtx; value: string): string =
  ## A prop value with a `tok"…"` sentinel resolved to the theme's light
  ## literal.
  if value.startsWith("tok:"): ctx.theme.lightFor(value[4 .. ^1]) else: value

proc readProps*[P](n: EmailNode): P =
  ## The element's props as a `P`: each field read under its own name,
  ## defaults kept where unset. Raises `PatternError` on a value that
  ## does not parse as the field's type.
  result = default(P)
  for name, field in result.fieldPairs:
    let raw = rawValue(n, name)
    if raw.len > 0:
      try:
        when field is string:
          field = raw
        elif field is bool:
          case raw.toLowerAscii()
          of "true", "1", "yes": field = true
          of "false", "0", "no": field = false
          else: raise newException(ValueError, "not a bool")
        elif field is SomeInteger:
          var t = raw.toLowerAscii()
          if t.endsWith("px"):
            t = t[0 ..< ^2].strip()
          field = typeof(field)(parseInt(t))
        elif field is SomeFloat:
          field = parseFloat(raw)
        elif field is enum:
          field = parseEnum[typeof(field)](raw)
        else:
          {.error: "pattern props are string, bool, int, float or enum".}
      except ValueError:
        raise newException(PatternError, n.tag & " " & name & " = '" &
          raw & "' is not a valid " & $typeof(field))

proc patternTagDef*(name: string; P: typedesc): TagDef {.compileTime.} =
  ## The static-vocabulary entry of a pattern: one attribute per field
  ## of `P` (the static check covers names; values are read at render).
  result = TagDef(name: name)
  var p = default(P)
  for field, value in p.fieldPairs:
    result.attrs.add(AttrDef(name: field, kind: akAttr,
      typ: $typeof(value)))

proc typedPattern*[P](name: string;
    expand: proc(n: EmailNode; p: P; ctx: ExpandCtx): EmailNode;
    expectedElements: proc(n: EmailNode; p: P; view: BriefView): seq[string];
    degradations: proc(n: EmailNode; p: P; view: BriefView): seq[string]):
    PatternDef =
  ## A `PatternDef` whose procs receive the element's props as a `P`.
  PatternDef(name: name,
    expand: proc(n: EmailNode; ctx: ExpandCtx): EmailNode =
      expand(n, readProps[P](n), ctx),
    expectedElements: proc(n: EmailNode; view: BriefView): seq[string] =
      expectedElements(n, readProps[P](n), view),
    degradations: proc(n: EmailNode; view: BriefView): seq[string] =
      degradations(n, readProps[P](n), view))

template defineMailPattern*(name: untyped; props: typedesc;
    expand, expectedElements, degradations: typed) =
  ## Registers the vocabulary element `name` (an identifier, e.g.
  ## `mailCallout`), whose typed attributes are the fields of `props`:
  ##
  ## - `expand: proc(n: EmailNode; p: props; ctx: ExpandCtx): EmailNode`
  ##   returns the tree the element stands for, built only from
  ##   vocabulary elements and HTML leaves; `n.children` is the content
  ##   the author put in the element (the slot), to be moved into that
  ##   tree; anything left there follows it;
  ## - `expectedElements: proc(n: EmailNode; p: props; view: BriefView):
  ##   seq[string]` — the brief's lines for what a screenshot must show;
  ## - `degradations: proc(n: EmailNode; p: props; view: BriefView):
  ##   seq[string]` — what `view`'s client is expected to get wrong.
  ##
  ## At compile time the element joins the static vocabulary, so a
  ## `ui(EmailRenderer)` template after this definition may use it (and
  ## its attributes are checked); at run time the definition joins the
  ## registry the render and the brief generator read.
  static:
    registerPatternTag(patternTagDef(astToStr(name), props))
  registerPattern(typedPattern[props](astToStr(name), expand,
    expectedElements, degradations))

# --- Expansion --------------------------------------------------------------

const maxExpansionDepth = 16
  ## Patterns expanding into patterns: deeper than this is a cycle.

proc expandNode(n: EmailNode; ctx: ExpandCtx; depth: int;
    diags: var seq[EmailDiagnostic]) =
  if n == nil or n.kind != enElement:
    return
  if n.tag in patternRegistry and not n.expanded:
    let def = patternRegistry[n.tag]
    if def.expand != nil:
      if depth >= maxExpansionDepth:
        diags.add(EmailDiagnostic(severity: sevError,
          code: codeVocabBadValue, message: n.tag & " expands into " &
            "itself (more than " & $maxExpansionDepth & " nested pattern " &
            "expansions)", origin: n.origin))
        return
      var tree: EmailNode
      try:
        tree = def.expand(n, ctx)
      except PatternError as e:
        diags.add(EmailDiagnostic(severity: sevError,
          code: codeVocabBadValue, message: e.msg, origin: n.origin))
        return
      if tree != nil:
        let rest = n.children # What the expansion did not place follows it.
        for c in rest:
          c.parent = nil
        n.children = @[]
        ctx.r.appendChild(n, tree)
        for c in rest:
          if c != tree:
            ctx.r.appendChild(n, c)
        n.expanded = true
        if tree.origin.file.len == 0:
          tree.origin = n.origin
        for c in n.children:
          expandNode(c, ctx, depth + 1, diags)
        return
  let kids = n.children
  for c in kids:
    expandNode(c, ctx, depth, diags)

const bandTags* = ["mailSection", "mailWrapper", "mailHero", "mailIf",
  "textOnly", "htmlOnly", "mailRaw", "mailColumn", "mailGroup"]
  ## A document's children that are bands (or wrap bands, or are the
  ## author's own raw markup) and so are never wrapped; a column or a
  ## group outside a row stays where it is, for P4's nesting error.

proc isBand*(n: EmailNode): bool =
  ## True for a band (`bandTags`), and for an expanded pattern whose
  ## expansion is one: a pattern is classified by the root of what it
  ## became, never by its own name.
  if n == nil or n.kind != enElement:
    return false
  if n.tag in ["textOnly", "htmlOnly"]:
    # A text-only or HTML-only wrapper is what it holds: loose content
    # in one still belongs in a section.
    for c in n.children:
      if c.kind == enElement:
        return isBand(c)
    return false
  if n.tag in bandTags:
    return true
  if n.expanded and n.tag in patternRegistry:
    for c in n.children:
      if c.kind == enElement:
        return isBand(c)
  false

proc wrapLooseContent*(doc: EmailNode) =
  ## Content placed directly in a `mailDocument` (outside any band) is an
  ## implicit `mailSection` with the section's defaults (catalogue
  ## R-LAY-08): each run of consecutive loose children moves into a
  ## section of its own. Without it the content sits flush against the
  ## message's edges, where a heading whose glyphs reach above its line
  ## box is clipped at the top of the reading pane. Runs after pattern
  ## expansion, so a pattern that expands to a band stays a top-level
  ## band. Idempotent.
  if doc == nil or doc.kind != enElement or doc.tag != "mailDocument":
    return
  let r = EmailRenderer()
  var kids: seq[EmailNode] = @[]
  var run: EmailNode = nil
  for c in doc.children:
    let loose = (c.kind == enElement and not isBand(c)) or
      (c.kind == enText and c.text.strip().len > 0)
    if not loose:
      if c.kind == enElement or c.kind != enText:
        run = nil
      kids.add(c)
      continue
    if run == nil:
      run = r.createElement("mailSection")
      run.origin = c.origin
      run.parent = doc
      kids.add(run)
    c.parent = run
    run.children.add(c)
  doc.children = kids

proc expandPatterns*(root: EmailNode; theme: EmailTheme;
    target: EmailTarget): seq[EmailDiagnostic] =
  ## Expands every pattern element of `root` in place, depth first, the
  ## expansions' own patterns included, then wraps a document's loose
  ## content in sections (`wrapLooseContent`). Idempotent: an expanded
  ## element is not expanded again.
  var reported: ref seq[EmailDiagnostic]
  new(reported)
  let ctx = ExpandCtx(theme: theme, target: target, r: EmailRenderer(),
    diagnostics: reported)
  expandNode(root, ctx, 0, result)
  result.add(reported[])
  wrapLooseContent(root)
