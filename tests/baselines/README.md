# Capture baselines (Tier-1 + Tier-2)

One directory per story. Each holds the approved PNGs for the pinned
CI matrix (families `apple,thunderbird,chromium-baseline` × viewports
`mobile,desktop` × scheme `light` × images `on` — 6 variants per
story), named exactly as the capture files
(`a-<family>-<engine>-<viewport>-<scheme>-<images>.png`). The `canary/`
directory additionally holds one `<variant>.sha256` per PNG
(`sha256sum` format) for the Tier-1 exact-hash check; every story's
PNGs feed the Tier-2 perceptual diff (fail over a 0.001 diff ratio).

Baselines change ONLY via `just email-capture-ci --update-baselines`,
which recaptures the matrix fresh (`--no-cache`) and regenerates this
tree from that run — at end-of-session approval, never by hand.
The flag adds and overwrites; it never prunes variants that left
the matrix (delete those deliberately, in the same approval).
