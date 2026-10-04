# Capture baselines (Tier-1 + Tier-2)

One directory per story of the regression matrix: the canary and the
fourteen reference emails (`examples/reference_set.nim`; the Justfile's
`capture-ci-stories`). Each holds the approved PNGs for the pinned
CI matrix (families `apple,thunderbird,chromium-baseline` × viewports
`mobile,desktop` × scheme `light` × images `on` — 6 variants per
story, but for the excluded variants below), named exactly as the capture files
(`a-<family>-<engine>-<viewport>-<scheme>-<images>.png`). The Tier-1
stories' directories (`canary`, `receiptTypical`, `alertArabic`,
`securityCodeJapanese`: `TIER1_STORIES` in
`tools/capture/email-capture-ci.ts`) additionally hold one
`<variant>.sha256` per PNG (`sha256sum` format) for the Tier-1
exact-hash check; every story's PNGs feed the Tier-2 perceptual diff
(fail over a 0.001 diff ratio).

Baselines change ONLY via `just email-capture-ci --update-baselines`,
which recaptures the matrix fresh (`--no-cache`) and regenerates this
tree from that run — at end-of-session approval, never by hand.
The flag adds and overwrites; it never prunes variants that left
the matrix (delete those deliberately, in the same approval).

## Excluded variants

A few variants are captured on every run but have no committed baseline,
because the PNG is over the repository's 1 MB file limit (the shared
large-file pre-commit check): `TIER2_EXCLUDED` in
`tools/capture/email-capture-ci.ts` lists each with its reason. Tier-2
does not compare them; every run prints one "Tier-2 excludes" line per
excluded variant it holds, with the reason, and counts them in its
verdict. `--update-baselines` does not write them, and a baseline
committed for one anyway fails the run. A Tier-1 story cannot be
excluded.

- `digestNearBudget`'s three mobile variants
  (`a-thunderbird-firefox-mobile-light-on`,
  `a-apple-webkit-mobile-light-on`,
  `a-chromium-baseline-chromium-mobile-light-on`): a message near the
  90 KB budget is a very long page on a phone, 1.5-2.2 MB as a
  full-page PNG. Its desktop variants are compared; its mobile captures
  are still made and reviewed in-session, and its size and invariants
  are checked by `tests/t7_reference_set.nim`.

## Awaiting re-approval

A story whose baselines are known to be out of date, but whose new
captures have not been reviewed yet, carries a `PENDING-REVIEW` file in
its directory stating why. The Tier-2 check does not compare such a
story; every run prints one "awaiting re-approval" line per pending
story and counts them in its verdict, and `--require-approved` turns
any pending story into a failure. `--update-baselines` leaves pending
stories alone; after a real visual review of the captures,
`just email-capture-ci --update-baselines --approve <story>` writes
their baselines and removes the marker. The canary can never be
pending: Tier-1 hashes it on every run.

## Provenance

- `canary`: recorded at the matrix's start; unchanged since.
- The fourteen reference emails (Tier-1: `receiptTypical`,
  `alertArabic`, `securityCodeJapanese`; Tier-2: the rest), recorded
  2026-10-04 from run `build/email-capture-ci/20261004T101049Z`, whose
  captures were first compared with the ones the visual review approved
  (runs `ref-r3`, and `ref-r4` for `newsletterColumns` and
  `markdownMaximal`, read by read-only reviewers to no open P1/P2 in an
  audience client): 82 of 84 byte-identical; the other two, the
  countdown GIF of `eventInvitation` in WebKit, differ by the frame the
  engine showed (diff ratios 0.00036 and 0.00065, both frames seen in
  the reviewed runs). The capture has since served an animated GIF as
  its first frame (`firstFrameGif` in `tools/capture/fixture_host.ts`),
  so the frame no longer depends on how long a capture takes; five
  fresh captures of `eventInvitation` in every family of the matrix were
  byte-identical to the recorded baselines, which therefore show the
  first frame and were kept as recorded. The seed `receipt` and
  `alert` left the matrix at the same time (they stay registered as the
  capture tooling's fixtures); their baselines were deleted. Of the
  90 PNGs recorded, `digestNearBudget`'s three mobile ones were then
  dropped as over the file limit (see "Excluded variants"), leaving 87.
