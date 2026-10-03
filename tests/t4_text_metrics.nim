## The text metrics (`style/metrics.nim` over the generated
## `metrics_data.nim`): advances read from the pinned fonts, font stacks
## measured at their worst case, bold measured with bold faces, and
## characters outside the table's ranges flagged as approximate.
##
## Backend-independent (pure arithmetic), so `just test` also runs it
## on JS. No test doubles. The table's regeneration and its font hashes
## are checked by tests/t3_metrics_reproducible.nim (C only).
import std/[math, unittest]
import isonim_email/style/metrics
import isonim_email/metrics_data

suite "text metrics":
  test "test_advances_come_from_the_fonts":
    # Liberation Sans is Arial's metric twin: "a" is 1139 of 2048 units.
    check liberationSansFace.unitsPerEm == 2048
    check liberationSansFace.advances[int('a') - 0x20] == 1139
    check abs(textWidth("a", 2048.0, margin = false) - 1139.0) < 1e-9
    # The safety margin is 5%.
    check abs(textWidth("a", 2048.0) - 1139.0 * 1.05) < 1e-9
    # Latin-1 and Latin Extended-A are measured, not estimated.
    let latin = measureFace("Ærøskøbing Łódź", mfLiberationSans, false,
      16.0)
    check not latin.approx
    # Whitespace runs collapse to one space.
    check textWidth("a  b", 16.0) == textWidth("a b", 16.0)

  test "test_a_stack_is_measured_at_its_worst_case":
    let arial = measureText("Open dashboard", "Arial, sans-serif", 16.0)
    let mixed = measureText("Open dashboard",
      "Arial, 'Segoe UI', sans-serif", 16.0)
    let noto = measureFace("Open dashboard", mfNotoSans, false, 16.0)
    # Segoe UI has no metric twin: Noto Sans stands in, and it is wider.
    check mixed.width > arial.width
    check abs(mixed.width - noto.width) < 1e-9
    # A generic family counts only in a stack that names no family.
    check stackFamilies("Helvetica, Arial, sans-serif") == @[mfLiberationSans]
    check stackFamilies("sans-serif") == @[mfNotoSans]
    check stackFamilies("Georgia, serif") == @[mfNotoSans]
    check stackFamilies("Calibri, Roboto") == @[mfCarlito, mfRoboto]
    check stackFamilies("") == @[mfLiberationSans]
    # Bold faces are wider.
    check measureText("Open dashboard", "Arial", 16.0, bold = true).width >
      arial.width
    check isBoldWeight("600") and isBoldWeight("bold")
    check not isBoldWeight("500") and not isBoldWeight("normal")

  test "test_characters_outside_the_table_are_approximate":
    let arabic = measureText("ابدأ التجربة", "Arial", 16.0)
    check arabic.approx
    # Noto Sans' average advance for each of the 11 letters, plus a
    # space from the table.
    let avg = float(notoSansFace.averageAdvance) /
      float(notoSansFace.unitsPerEm)
    let space = float(liberationSansFace.advances[0]) / 2048.0
    check abs(arabic.width - (11.0 * avg + space) * 16.0 * 1.05) < 1e-6
    # The wide CJK range counts a full em.
    check abs(measureFace("漢字", mfLiberationSans, false, 10.0,
      margin = false).width - 20.0) < 1e-9
