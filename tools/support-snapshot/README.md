# support-snapshot

Pins the caniemail client-support data and generates
`src/isonim_email/support/caniemail_data.nim` from it.

- `caniemail-data.json` — the pinned payload, fetched from
  `https://www.caniemail.com/api/data.json`. Also available as the
  `hteumeuleu/caniemail` repository at the pinned commit (the payload is
  built from its `_features/*.md` front matter).
- `snapshot.pin.json` — the pin: source URL, repo commit and date, fetch
  date, payload date and apiVersion, sha256, licence.
- `LICENSE-caniemail` — the payload's MIT licence text.
- `snapshot.nim` — the generator: pure `generateSupportModule` plus a
  CLI. Reduction: latest test result per (feature, family/platform) key.

Regenerate (verifies the sha256, then rewrites the table):

```sh
just support-snapshot
```

Re-running on the pinned inputs is a byte-identical no-op, asserted by
`tests/t3_snapshot_reproducible.nim`. Re-pinning is a deliberate PR:

1. Fetch a fresh payload and note the repo HEAD
   (`git ls-remote https://github.com/hteumeuleu/caniemail.git HEAD`).
2. Replace `caniemail-data.json`, update the pin (commit, dates,
   apiVersion, sha256).
3. Run `just support-snapshot` and review the diff: it shows which
   support values changed. Lint behaviour and test expectations may need
   updating alongside.

The payload's bytes are upstream's and sha256-pinned, so it is
excluded from the whitespace/formatting hooks in `flake.nix`
(editorconfig-checker, end-of-file-fixer, prettier): never reformat
it, re-pin it.
