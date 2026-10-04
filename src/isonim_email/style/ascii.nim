## isonim_email/style/ascii.nim — ASCII case-insensitive comparisons
## that read their argument in place.
##
## The passes compare tags, properties and keywords without regard to
## case (`node.tag.toLowerAscii() in [...]`). Lower-casing builds a new
## string for every comparison, once per node or declaration of every
## render. These give the same answer as the `toLowerAscii` form (ASCII
## letters folded, every other byte compared as it is) without building
## one: `eqLowerAscii(s, x)` is `s.toLowerAscii() == x`, and
## `inLowerAscii(s, xs)` is `s.toLowerAscii() in xs`, for any `s` and
## any `x`/`xs`.
##
## Backend-independent: plain string code, runs on C and JS.

import std/strutils
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run. The
## passes' case-insensitive matches go through it.
const affects*: set[ClientFamily] = allFamilies

proc hasUpperAscii*(s: string): bool =
  ## True when `s` holds an ASCII capital letter (`toLowerAscii` would
  ## change it).
  for c in s:
    if c in {'A' .. 'Z'}:
      return true
  false

proc eqLowerAscii*(s, x: string): bool =
  ## `s.toLowerAscii() == x`, without the lower-cased copy.
  if s.len != x.len:
    return false
  for i in 0 ..< s.len:
    if toLowerAscii(s[i]) != x[i]:
      return false
  true

proc inLowerAscii*(s: string; xs: openArray[string]): bool =
  ## `s.toLowerAscii() in xs`, without the lower-cased copy.
  for x in xs:
    if eqLowerAscii(s, x):
      return true
  false
