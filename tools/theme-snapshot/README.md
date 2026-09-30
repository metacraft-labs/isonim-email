# theme-snapshot

Pins the `codetracer-design-system` DTCG tokens and generates
`src/isonim_email/style/metacraft_theme.nim` from them.

- `brand.json`, `alias.json`, `mapped.json` — the pinned payloads,
  vendored verbatim from the design-system repo at the pinned commit.
- `theme.pin.json` — the pin: source URL, repo commit and date, fetch
  date, per-file sha256, licence note.
- `mapping.json` — the theme key → design-system binding (see below).
- `snapshot.nim` — the generator: pure `generateThemeModule` plus a CLI.

Regenerate (verifies the sha256s, then rewrites the theme):

```sh
just theme-snapshot
```

Re-running on the pinned inputs is a byte-identical no-op, asserted by
`tests/t4_theme_snapshot.nim`. Re-pinning is a deliberate PR:

1. Copy fresh `brand.json` / `alias.json` / `mapped.json` from the
   design-system repo and note its HEAD (`git ls-remote` on the repo URL
   in `theme.pin.json`).
2. Replace the payloads, update the pin (commit, dates, sha256s).
3. Check the mapping still resolves (`just theme-snapshot` fails on a
   dangling token path); review renamed roles in the design-system diff.
4. Run `just theme-snapshot` and review the diff: it shows which theme
   values changed. Update the spot values in
   `tests/t4_theme_snapshot.nim` when the change is intended.

## Binding rationale

Colours resolve from design-system roles with real `Dark`/`Light` mode
pairs; metrics and font stacks are the email constants. The split
is deliberate: the fixed numbers (type scale, spacing, radii, 600px
container) are email requirements the components assume, while the
colours are the brand. Email-specific literals are first-class here, the
same call `isonim-docs` makes for docs-specific literals.

- Surface/text roles bind within their own family (`base.canvas`,
  `text.primary.body`, `text.primary.body-subtle`, `divider.subtle`).
  Measured contrast on the pinned snapshot: body on card 10.56 (light) /
  13.64 (dark), secondary on card 8.61 / 7.30.
- `color.accent.primary` binds `surface.action.primary` (role-correct)
  and `primaryText` binds `text.on-action.primary`. Known gap on the
  pinned snapshot: that pairing is 1.80:1 in light mode
  (`#f3f3f3` on `#a5b4fc`) — the design-system light action ramp, not an
  email choice. It is pinned as-is so a re-pin shows the fix; revisit on
  re-pin and in contrast verification.
- `color.link` and `color.status.info` share
  `text.information.primary` (link blue in both modes), mirroring the
  default theme where
  the default link and info lights are also identical. `text.primary.active`
  was rejected: its light value (`#c7d2fe`) is unreadable as body-link text.
- `color.status.*.bg` have no design-system role (the `surface.alert.*`
  tokens are saturated solids in both modes, not callout tints), so each
  mode binds an alias primitive directly: light `*.100` tints, dark `*.900`
  deeps (e.g. info `information.100` / `information.900`).
- Fonts are websafe stacks (R-TXT-05): the design-system font tokens name
  webfonts, which email can only use as progressive enhancement.
