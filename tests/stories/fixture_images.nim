## Story fixture images: URLs on the capture fixture host.
##
## The seed stories reference their images as
## `https://x.test/{sha256[0:16]}/{name}` — the content-hashed hosted
## form of any published asset (R-IMG-07) on the reserved `.test`
## host. The bytes live in `tests/stories/assets/`, and the capture
## browsers answer fixture-host requests from that directory
## (`tools/capture/fixture_host.ts`), so the images render without a
## network. The hash is in the URL, so editing an image changes the
## story's MIME and with it the capture cache key.
##
## The images are hand-made placeholders: `logo.png` (240×80, shown at
## 120 px), `shield.png` (96×96, shown at 48 px) and `scene.png`
## (560×320, a flat landscape, shown at 280 px), all @2x.
##
## Backend-independent (compile-time read + pure hashing).
import isonim_email

const fixtureHost* = "https://x.test"
  ## The reserved `.test` host the capture harness serves locally.

proc fixtureImageUrl*(name: static string): string =
  ## The hosted URL of `tests/stories/assets/<name>`.
  const bytes = staticRead("assets/" & name)
  fixtureHost & hostedPath(loadAsset(name, bytes))
