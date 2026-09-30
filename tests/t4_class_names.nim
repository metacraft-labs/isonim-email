# rule: R-CSS-08
## Class names are `e-` plus the shortest unique base36-hash prefix
## (≥ 3 characters) of the variant and the declaration set —
## deterministic across runs and templates, matching `[a-z][a-z0-9-]*`.
##
## Backend-independent (pure string work), so `just test` also runs it
## on JS.
import std/[strutils, unittest]
import isonim_email

proc decl(prop, value: string; important = false): Declaration =
  Declaration(prop: prop, value: value, important: important)

suite "class names deterministic":
  test "test_class_names_deterministic":
    # rule: R-CSS-08
    let decls = [decl("color", "#ffffff"),
      decl("background-color", "#1f6feb")]
    # The same declaration set yields the same name across runs and
    # templates: fresh registries agree, and declaration order never
    # matters. The pinned name also pins the FNV-1a/base36 digest.
    var first = initClassGen()
    let a = first.classFor(decls)
    check a == "e-b4r"
    var second = initClassGen()
    check second.classFor(decls) == a
    check second.classFor(
      [decl("background-color", "#1f6feb"), decl("color", "#ffffff")]) == a
    # Re-claiming in the same render returns the same name.
    check first.classFor(decls) == a
    # A different set — including an importance difference — yields a
    # different name.
    check first.classFor([decl("color", "#ffffff")]) != a
    check first.classFor([decl("color", "#ffffff"),
      decl("background-color", "#1f6feb", true)]) != a
    # Every full name matches [a-z][a-z0-9-]* with a ≥3-character
    # prefix (the prefix itself may start with a digit — base36).
    for name in [a, first.classFor([decl("margin", "0")]),
        first.classFor([decl("width", "100%")])]:
      check isSafeClassName(name)
      check name.startsWith("e-")
      check name.len >= 5
      # … and passes the head-CSS selector check (R-CSS-09's side).
      check validSelector("." & name)
    # Unsafe shapes never match.
    for bad in ["", "E-abc", "9lives", "e-ok!", "a:b", "a b", "a/b",
        "A", "-a"]:
      check not isSafeClassName(bad)
    # An empty declaration set has no name.
    expect StyleError:
      discard first.classFor(@[])

  test "test_class_names_hash_the_variant":
    # rule: R-CSS-08
    # The variant is part of the hash input: the same declarations
    # under sm:, dark: and hover: get three names, none equal to the
    # variant-free name, so one variant's rule never matches another
    # variant's element. Each is stable across registries.
    let decls = [decl("color", "#ffffff"),
      decl("background-color", "#1f6feb")]
    var gen = initClassGen()
    let plain = gen.classFor(decls)
    let sm = gen.classFor(decls, "sm")
    let dark = gen.classFor(decls, "dark")
    let hover = gen.classFor(decls, "hover")
    check plain == "e-b4r" # The variant-free name is unchanged.
    check sm != plain
    check dark != plain
    check hover != plain
    check sm != dark
    check sm != hover
    check dark != hover
    # Different digests, not just a prefix extension after a collision:
    # a fresh registry per variant yields the same names.
    var solo = initClassGen()
    check solo.classFor(decls, "dark") == dark
    var solo2 = initClassGen()
    check solo2.classFor(decls, "sm") == sm
    # Re-claiming under the same variant returns the same name.
    check gen.classFor(decls, "dark") == dark
    for name in [sm, dark, hover]:
      check isSafeClassName(name)
      check validSelector("." & name)
