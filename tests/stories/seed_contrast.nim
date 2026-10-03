## Tier-3 fixtures for the contrast assertion in each scheme: three
## messages that each fail it in exactly one of light, dark and forced
## dark, and pass it in the other two, so a run that captures them shows
## the check is live in every scheme
## (`tests/e2e_local_dark_modes_legible.nim`).
##
## - `contrastLightBroken` (`darkMode = designed`): faint grey text
##   (#bbbbbb on white, 1.9:1) whose dark colour is legible: fails light
##   only (forced dark keeps a light text colour and darkens the page).
## - `contrastDarkBroken` (`darkMode = designed`): legible text whose own
##   dark colour (#2a2d33) is nearly the card's dark background: fails
##   dark only (forced dark darkens the light design instead).
## - `contrastForcedBroken` (`darkMode = accommodate`): dark text over a
##   light background image: legible in light and in dark (which keeps
##   the light design); forced dark lightens the text and leaves the
##   image, so it fails forced dark only.
##
## Env-gated like the other fixtures: the drivers register these only
## under `ISONIM_CAPTURE_FIXTURES=1`, so bare runs, the capture matrices
## and the story-set pins never see them.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import fixture_images
import story_kit

proc contrastLightBrokenDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Light broken", "Faint in light only.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Light broken")
  discard r.el(s, "p", [("color", "#bbbbbb"), ("@dark:color", "#f3f4f6")],
    text = "Faint grey text on white, legible in dark.")

proc contrastDarkBrokenDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Dark broken", "Faint in dark only.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Dark broken")
  discard r.el(s, "p", [("color", "#111827"), ("@dark:color", "#2a2d33")],
    text = "Legible in light, nearly the card's colour in dark.")

proc contrastForcedBrokenDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Forced broken", "Faint under forced dark only.")
  discard r.el(r.band(result), "h1", [("color", "#111827")],
    text = "Forced broken")
  let band = r.el(result, "mailSection", [("background-color", "#fde9d0"),
    ("background-image", fixtureImageUrl("band.png")),
    ("padding", "40px 0")])
  discard r.el(band, "p", [("color", "#3f3a33")],
    text = "Dark text over a light background image.")

const contrastFixtures*: array[3, KitStory] = [
  ("contrastLightBroken", "Tier-3 fixture: fails contrast in light only.",
    contrastLightBrokenDoc, true),
  ("contrastDarkBroken", "Tier-3 fixture: fails contrast in dark only.",
    contrastDarkBrokenDoc, true),
  ("contrastForcedBroken", "Tier-3 fixture: fails contrast under forced " &
    "dark only.", contrastForcedBrokenDoc, false),
]

proc contrastGroup(name: string): string = "contrast"

proc registerContrastFixtures*() =
  ## Registers the three fixtures (env-gated, see above).
  registerKit(contrastFixtures, contrastGroup)
