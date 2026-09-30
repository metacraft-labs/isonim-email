## isonim_email/style/classes.nim — deterministic safe class names
## (R-CSS-08).
##
## Names are `e-` plus base36 of the FNV-1a hash over the variant and
## the declaration set's canonical serialisation (`css.serializeDecls`,
## so declaration order never matters), at the shortest prefix — at
## least 3 characters — unique within the render. The variant (`sm`,
## `dark`, `hover`) is part of the hash input: the same declarations
## under two variants get two names, so a rule written for one variant's
## element never matches another variant's element. The empty variant
## hashes the declarations alone. The same declarations yield
## the same name across runs and templates; on a hash-prefix collision
## the later claim extends its prefix, deterministically per render.
## Names match `[a-z][a-z0-9-]*`: no escapes, no Tailwind-style
## characters, Gmail-safe.
##
## FNV-1a is implemented here rather than using `std/hashes` so the
## names are stable across compiler versions, not just runs.
##
## Pure `std` string work: identical on the C and JS targets.

import std/tables
import ./css
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies - {cfGanga}

export css

type ClassGen* = object
  ## A render's class registry: claimed names and the canonical
  ## declaration key each was claimed for.
  used*: Table[string, string]

proc initClassGen*(): ClassGen =
  ClassGen(used: initTable[string, string]())

proc fnv1a64*(s: string): uint64 =
  ## FNV-1a over bytes (offset 14695981039346656037, prime
  ## 1099511628211).
  result = 14695981039346656037'u64
  for c in s:
    result = result xor c.uint64
    result = result * 1099511628211'u64

const base36Digits = "0123456789abcdefghijklmnopqrstuvwxyz"

proc base36*(n: uint64): string =
  ## Lowercase base36, most significant digit first.
  if n == 0:
    return "0"
  var v = n
  result = ""
  while v > 0:
    result = base36Digits[(v mod 36).int] & result
    v = v div 36

proc isSafeClassName*(name: string): bool =
  ## `[a-z][a-z0-9-]*` (R-CSS-08). One predicate serves both rules:
  ## `css.validClassName` is the same check, used for selector
  ## validation (R-CSS-09), so a generated name always passes it.
  validClassName(name)

proc classFor*(g: var ClassGen; decls: openArray[Declaration];
    variant = ""): string =
  ## The class name for a declaration set under `variant`: `e-` plus the
  ## shortest base36-hash prefix (≥ 3 characters) unique in this render.
  ## Re-claiming the same declarations under the same variant returns
  ## the same name; another variant yields another name.
  if decls.len == 0:
    raise invalidCss("empty declaration set has no class name " &
      "(R-CSS-05: no empty declarations)")
  let canon =
    if variant == "": serializeDecls(decls)
    else: "@" & variant & ":" & serializeDecls(decls)
  let digest = base36(fnv1a64(canon))
  for length in 3 .. digest.len:
    let candidate = "e-" & digest[0 ..< length]
    if candidate notin g.used:
      g.used[candidate] = canon
      return candidate
    if g.used[candidate] == canon:
      return candidate
  raise invalidCss("declaration set '" & canon &
    "' collides on every hash prefix (R-CSS-08: extend the digest)")
