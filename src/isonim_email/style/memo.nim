## isonim_email/style/memo.nim — per-thread answers of the pure value
## parsers, kept by their input.
##
## A render parses the same few style values over and over: the theme's
## colours, its packed type specs, a handful of lengths and boxes, on
## every element of every message. Each parser here is a pure function
## of its string argument (no theme, no node, no target), so its answer
## for a given string never changes; `memoised` keeps the answer the
## first call computed in a per-thread table and hands back a copy of it
## on every later call. An input that raises is never kept: it raises
## again, the same way, every time.
##
## Each table is bounded by its `cap`: when full it is emptied, never
## evicted piecemeal, so a stale or partial answer cannot be served.
## Backend-independent: on JS, `{.threadvar.}` is a plain global and the
## runtime is single-threaded.

import std/tables
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run. The
## parsers' answers flow into every inline style.
const affects*: set[ClientFamily] = allFamilies

template memoised*[T](memo: var Table[string, T]; cap: int; key: string;
    compute: untyped): T =
  ## `compute`'s value for `key`: the kept one when `memo` has it, else
  ## `compute` evaluated and kept (unless it raised). `memo` is emptied
  ## when it already holds `cap` answers.
  ## At compile time (a `const` or `static` caller) nothing is kept.
  block:
    var memoAnswer: T
    when nimvm:
      memoAnswer = compute
    else:
      var memoFound = false
      memo.withValue(key, kept):
        memoAnswer = kept[]
        memoFound = true
      if not memoFound:
        memoAnswer = compute
        if memo.len >= cap:
          memo.clear()
        memo[key] = memoAnswer
    memoAnswer
