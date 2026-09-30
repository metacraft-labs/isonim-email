# rule: R-CSS-06
# rule: R-CSS-12
# rule: R-CSS-13
## Lengths normalise to px, colours to 6-digit hex, shorthands
## expand, and the packed `type.*`/`button.font` theme encodings parse.
## Margins parse with R-OL-04's shape but carry no
## rule claim: P5 owns the conversion and the warning.
##
## Backend-independent (pure string work), so `just test` also runs it
## on JS.
import std/[strutils, unittest]
import isonim_email

suite "lengths normalise to px":
  test "test_lengths_normalise_to_px":
    # rule: R-CSS-13
    check normaliseLength("padding", "16") == "16px"
    check normaliseLength("padding", "16px") == "16px"
    check normaliseLength("padding", "16PX") == "16px"
    check normaliseLength("padding", "  8px  ") == "8px"
    check normaliseLength("font-size", "1rem") == "16px"
    check normaliseLength("font-size", "1.5em") == "24px"
    check normaliseLength("font-size", "1.5em", fontSizePx = 20.0) == "30px"
    check normaliseLength("padding", "0") == "0"
    check normaliseLength("padding", "0px") == "0"
    check normaliseLength("padding", "12.50px") == "12.5px"
    # Unitless numbers from the Tailwind extractor get px restored
    # from the Tailwind extractor's unit record, threaded through `unit`.
    check toPx("2", unit = "rem") == 32.0
    check toPx("2") == 2.0
    # % survives on widths only.
    check normaliseLength("width", "50%") == "50%"
    check normaliseLength("max-width", "12.50%") == "12.5%"
    expect StyleError:
      discard normaliseLength("padding", "50%")
    expect StyleError:
      discard normaliseLength("padding", "1vw")
    expect StyleError:
      discard normaliseLength("padding", "wide")
    try:
      discard normaliseLength("padding", "50%")
    except StyleError as e:
      check "E-VOCAB-BAD-VALUE" in e.msg
      check "R-CSS-13" in e.msg
    # Unitless line-height becomes px against the font size; px and
    # `normal` pass through canonically.
    check normaliseLineHeight("1.5", 16.0) == "24px"
    check normaliseLineHeight("24px", 16.0) == "24px"
    check normaliseLineHeight("150%", 16.0) == "24px"
    check normaliseLineHeight("normal", 16.0) == "normal"
    check normaliseLineHeight("0", 16.0) == "0"

suite "colours normalise to six-digit hex":
  test "test_colours_normalise_to_six_digit_hex":
    # rule: R-CSS-12
    check normaliseColor("#fff") == "#ffffff"
    check normaliseColor("#FFF") == "#ffffff"
    check normaliseColor("#1f6feb") == "#1f6feb"
    check normaliseColor("red") == "#ff0000"
    check normaliseColor("Red") == "#ff0000"
    check normaliseColor("rebeccapurple") == "#663399"
    check normaliseColor("rgb(255,0,0)") == "#ff0000"
    check normaliseColor("rgb(255, 0, 0)") == "#ff0000"
    check normaliseColor("rgb(100%,0%,0%)") == "#ff0000"
    check normaliseColor("rgba(255,0,0,1)") == "#ff0000"
    check normaliseColor("hsl(0,100%,50%)") == "#ff0000"
    check normaliseColor("hsl(120,100%,25%)") == "#008000"
    check normaliseColor("oklch(0 0 0)") == "#000000"
    check normaliseColor("oklch(1 0 0)") == "#ffffff"
    check normaliseColor("oklch(100% 0 0)") == "#ffffff"
    # oklch(62.796% 0.25768 29.23) is sRGB red; allow ±3 per channel
    # for float noise across backends.
    let red = parseColor("oklch(0.62796 0.25768 29.23)")
    check abs(red.r - 255) <= 3
    check red.g <= 3
    check red.b <= 3
    expect StyleError:
      discard normaliseColor("not-a-colour")
    expect StyleError:
      discard normaliseColor("#ff")
    expect StyleError:
      discard normaliseColor("var(--x)")

  test "test_whitespace_colour_syntax_rejected":
    # rule: R-CSS-06
    for bad in ["rgb(0 0 0)", "rgb(0 0 0 / 50%)", "rgba(0 0 0 / 50%)",
        "hsl(0 100% 50%)"]:
      try:
        discard parseColor(bad)
        fail()
      except StyleError as e:
        check "E-VOCAB-BAD-VALUE" in e.msg
        check "R-CSS-06" in e.msg
    # The comma form — the rule's named alternative — parses (its
    # alpha makes normaliseColor point at R-CSS-14 instead).
    check parseColor("rgba(0,0,0,.5)").toRgba() == "rgba(0,0,0,.5)"

  test "test_named_colour_table_well_formed":
    # rule: R-CSS-12
    var seen: seq[string] = @[]
    for (name, hex) in cssNamedColors:
      check name == name.toLowerAscii()
      check hex.len == 7
      check hex[0] == '#'
      for c in hex[1 .. ^1]:
        check c in {'0' .. '9', 'a' .. 'f'}
      check name notin seen
      seen.add(name)
    # Spot values, including the grey/gray aliases.
    check normaliseColor("white") == "#ffffff"
    check normaliseColor("black") == "#000000"
    check normaliseColor("gray") == normaliseColor("grey")
    check normaliseColor("darkslategray") == normaliseColor("darkslategrey")

suite "translucent colours emit blend then rgba":
  test "test_translucent_colours_emit_blend_then_rgba":
    # No rule claim: R-CSS-14 is pending on the content leaves (see rules_pending.txt).
    # The pair computation is tested here; emission is unowned — P5
    # inline carries the blend alone (one declaration per property).
    # The catalogue's exact example: rgba(0,0,0,.5) over white blends
    # to #7f7f7f (truncated, not rounded).
    check emitColorDecls("color", "rgba(0,0,0,.5)", "#ffffff") ==
      @[("color", "#7f7f7f"), ("color", "rgba(0,0,0,.5)")]
    # Opaque colours emit one hex declaration; the background is
    # parsed but unused.
    check emitColorDecls("color", "red", "#ffffff") ==
      @[("color", "#ff0000")]
    # 8-digit hex and `transparent` carry alpha too.
    check emitColorDecls("background-color", "#00000080", "#ffffff") ==
      @[("background-color", "#7f7f7f"),
        ("background-color", "rgba(0,0,0,.5)")]
    check emitColorDecls("color", "transparent", "#1f6feb") ==
      @[("color", "#1f6feb"), ("color", "rgba(0,0,0,0)")]
    # Blending over a translucent background has no meaning.
    expect StyleError:
      discard emitColorDecls("color", "rgba(0,0,0,.5)", "rgba(0,0,0,.5)")
    # normaliseColor refuses translucency loudly, pointing at R-CSS-14.
    try:
      discard normaliseColor("rgba(0,0,0,.5)")
      fail()
    except StyleError as e:
      check "R-CSS-14" in e.msg

suite "shorthands expand":
  test "test_box_expands_to_four_px_sides":
    check expandBox("16px") == ["16px", "16px", "16px", "16px"]
    check expandBox("24px 0") == ["24px", "0", "24px", "0"]
    check expandBox("1px 2px 3px") == ["1px", "2px", "3px", "2px"]
    check expandBox("1px 2px 3px 4px") == ["1px", "2px", "3px", "4px"]
    check expandBox("1rem 2") == ["16px", "2px", "16px", "2px"]
    expect StyleError:
      discard expandBox("1px 2px 3px 4px 5px")
    expect StyleError:
      discard expandBox("10%")
    expect StyleError:
      discard expandBox("")

  test "test_border_parses_and_expands":
    let b = parseBorder("1px solid #e5e7eb")
    check b.widthPx == 1.0
    check b.style == "solid"
    check b.color.toHex() == "#e5e7eb"
    check expandBorder(b) == [("border-width", "1px"),
      ("border-style", "solid"), ("border-color", "#e5e7eb")]
    # Tokens in any order, style case-insensitive.
    let b2 = parseBorder("red DASHED 2px")
    check (b2.widthPx, b2.style, b2.color.toHex()) ==
      (2.0, "dashed", "#ff0000")
    for bad in ["1px groove red", "solid red", "1px solid",
        "1px 2px solid red", "1px solid red blue", "1px solid 2px",
        "-1px solid red", "1px solid var(--x)"]:
      expect StyleError:
        discard parseBorder(bad)

  test "test_background_splits_colour_from_image_path":
    check splitBackground("#fff") == ("#ffffff", "")
    check splitBackground("red") == ("#ff0000", "")
    check splitBackground("url(a.png) no-repeat center") ==
      ("", "url(a.png) no-repeat center")
    check splitBackground("#fff url(a.png) center/cover") ==
      ("#ffffff", "url(a.png) center/cover")

  test "test_margin_parses_with_word_shape":
    check parseMargin("16px 0") == ["16px", "0", "16px", "0"]
    check isBlockTextElement("p")
    check isBlockTextElement("h1")
    check isBlockTextElement("h6")
    check isBlockTextElement("ul")
    check isBlockTextElement("ol")
    check not isBlockTextElement("span")
    check not isBlockTextElement("body")
    check not isBlockTextElement("td")
    check not isBlockTextElement("div")
    for bad in ["-1px", "0 -2px", "auto", "0 auto"]:
      try:
        discard parseMargin(bad)
        fail()
      except StyleError as e:
        check "R-OL-04" in e.msg

suite "normalisation consumes token literals":
  test "test_default_theme_literals_parse":
    # Every defaultTheme literal parses through the normalisation
    # layer that owns its kind — the seam P5 renders through.
    let theme = defaultTheme()
    for key, pair in theme.pairs():
      if key.startsWith("color."):
        check normaliseColor(pair.light).startsWith("#")
        check normaliseColor(pair.dark).startsWith("#")
      elif key.startsWith("type.") or key == "button.font":
        check expandTypeSpec(pair.light).len >= 2
      elif key in ["space.section", "space.gutter", "button.padding"]:
        check expandBox(pair.light).len == 4
      elif key.startsWith("space.") or key.startsWith("radius."):
        check toPx(pair.light) > 0.0
      elif key.startsWith("layout."):
        check parseInt(pair.light) > 0
      elif key.startsWith("font."):
        # Stacks carry no rule here (R-TXT-05 is tokens').
        check "," in pair.light
      else:
        fail()
    # The Metacraft theme's literals parse the same way.
    for key, pair in metacraftTheme().pairs():
      if key.startsWith("color."):
        check normaliseColor(pair.light).startsWith("#")
        check normaliseColor(pair.dark).startsWith("#")

suite "packed type specs parse":
  test "test_type_spec_parses":
    check parseTypeSpec("16px/24px") ==
      TypeSpec(fontSize: "16px", lineHeight: "24px", weight: "")
    check parseTypeSpec("28px/36px/700") ==
      TypeSpec(fontSize: "28px", lineHeight: "36px", weight: "700")
    check parseTypeSpec("16px/20px/600") ==
      TypeSpec(fontSize: "16px", lineHeight: "20px", weight: "600")
    # Unitless size means px; a unitless line is a multiplier of the
    # size (CSS semantics), so "16/24" is 24 * 16px.
    check parseTypeSpec("16/24") ==
      TypeSpec(fontSize: "16px", lineHeight: "384px", weight: "")
    check parseTypeSpec("16/1.5") ==
      TypeSpec(fontSize: "16px", lineHeight: "24px", weight: "")
    check parseTypeSpec("16px/1.5") ==
      TypeSpec(fontSize: "16px", lineHeight: "24px", weight: "")
    check parseTypeSpec("18px/26px/bold") ==
      TypeSpec(fontSize: "18px", lineHeight: "26px", weight: "bold")
    check expandTypeSpec("28px/36px/700") == @[
      ("font-size", "28px"), ("line-height", "36px"),
      ("font-weight", "700")]
    check expandTypeSpec("16px/24px") == @[
      ("font-size", "16px"), ("line-height", "24px")]
    check parseTypeSpec("16px/150%") ==
      TypeSpec(fontSize: "16px", lineHeight: "24px", weight: "")
    for bad in ["16px", "16px/24px/700/x", "big/24px", "16px/tall",
        "16px/24px/heavy", "16px/24px/50", "16px/24px/1000"]:
      expect StyleError:
        discard parseTypeSpec(bad)
