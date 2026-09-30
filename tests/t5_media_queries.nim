# rule: R-CSS-10
## R-CSS-10 pins the `@media` vocabulary — only the `screen`
## type (or `only screen`) and the features `min-width` /
## `max-width` / `prefers-color-scheme`. Height, orientation and
## resolution features (and any other media type) are
## `E-CSS-INVALID`, through `checkQuery` and through the
## `@media` serialiser path that calls it.
##
## Backend-independent (pure string checks), so `just test` also
## runs it on JS.
import std/[strutils, unittest]
import isonim_email

suite "media query vocabulary":
  test "test_media_queries_screen_and_width_only":
    let good = ["screen", "only screen",
      "only screen and (min-width: 600px)",
      "only screen and (max-width:480px)",
      "(prefers-color-scheme: dark)",
      "ONLY SCREEN AND (MIN-WIDTH: 1px)"]
    check good.len >= 1
    for q in good:
      checkQuery(q)
    let bad = ["(orientation: landscape)",
      "(orientation: portrait)",
      "(min-resolution: 2dppx)",
      "(max-resolution: 300dpi)",
      "(height: 600px)",
      "(min-height: 100px)",
      "(max-height: 100px)",
      "(min-width: 1px) and (orientation: landscape)",
      "print and (min-width: 1px)",
      "all and (max-width: 1px)",
      "(min-device-width: 1px)",
      "not screen and (min-width: 1px)"]
    check bad.len >= 1
    var rejected = 0
    for q in bad:
      try:
        checkQuery(q)
        fail()
      except StyleError as e:
        check "R-CSS-10" in e.msg
        inc rejected
    check rejected == bad.len
    # The serialiser path enforces it too.
    try:
      discard serializeMediaRule("(orientation: landscape)",
        @[Rule(kind: rkStyle, selector: "p",
          decls: @[Declaration(prop: "margin", value: "0")])])
      fail()
    except StyleError as e:
      check "R-CSS-10" in e.msg
