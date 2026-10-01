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
  CLI. Reduction: the worst test result over the versions each
  (feature, family/platform) key spans, with the note ids of the results
  carrying that value. `spanRules` in the generator names every key's
  span with a one-line rationale: the latest result for a webmail or
  store app (it auto-updates), every result labelled with a version
  still in use for an OS-bundled or installed client (Apple Mail on iOS
  and macOS, Outlook for Windows and Mac, Thunderbird), falling back to
  the latest result when none is. A key with no rule fails generation.

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
3. Review `spanRules` (in-use floors move as versions leave use; its
   `spanRulesAsOf` date says when they were last judged) and give any
   new client key a rule.
4. Run `just support-snapshot` and review the diff: it shows which
   support values changed. Lint behaviour and test expectations may need
   updating alongside.

The payload's bytes are upstream's and sha256-pinned, so it is
excluded from the whitespace/formatting hooks in `flake.nix`
(editorconfig-checker, end-of-file-fixer, prettier): never reformat
it, re-pin it.
