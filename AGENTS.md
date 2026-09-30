# isonim-email — agent guide

`isonim-email` is an IsoNim add-on library for authoring HTML email: the
same IsoNim DSL used for web and native UI, lowered to client-safe
messages (table/VML/conditional-comment structures, inlined styles, MIME
packaging with a plain-text part).

- The design specification and the milestone plan are maintained outside
  this repository. In a Metacraft workspace, the workspace's project
  index names them; read both before starting work — the milestone plan
  says which milestone is current.
- The framework source is the sibling checkout `../isonim`. The closest
  precedent for an add-on library's layout, build and tests is
  `../isonim-docs`.
- This repository is **public**. Commit messages and files must be
  user-facing: never describe private roadmap, internal spec mechanics,
  or cite private repositories.
- Branch model: product repository — mainline `dev`, agent landing
  branch `agents`.

## Commands

Enter the dev shell first (`direnv allow`, or prefix with
`nix develop -c`). There is no global nim.

```sh
just build           # compile the library and every test (no run)
just test            # full suite on C, backend-independent passes on JS
just email-shots     # backend-A captures (backend A only)
just lint            # nim check + capture-CLI syntax gate + nixfmt --check + markdownlint
just format          # nimpretty + nixfmt (alias: just fmt)
just bench           # benchmarks (none yet; they land later)
just t               # alias for test
```

Sibling repos (`../isonim`, `../nim-everywhere`, `../nim-faststreams`,
`../nim-stew`) must be checked out next to this repo; `config.nims`
and the Justfile resolve them. In CI they are cloned at the SHAs in
`.github/sibling-repos`.

## Project structure

```text
src/
  isonim_email.nim                 # public umbrella - re-exports land here
  isonim_email/                    # library modules (renderer,
                                   # vocabulary, style compiler, MIME, …)
tests/
  t1_*.nim, t2_*, t3_*             # unit/golden/invariant tests
  goldens/                         # re-recorded with EMAIL_GOLDEN_RECORD=1
  compile_fail/                    # `# expect:` fixtures + runner
tools/capture/                     # capture service, backends, review
```

## Layer rules

- `src/isonim_email.nim` is the stable public entry point; new public
  API is re-exported through it.
- Passes under `src/isonim_email/passes/` transform the tree in
  pipeline order; MSO/VML constructors stay restricted to
  `src/isonim_email/mso/` and `passes/head.nim`.
- Tests are `std/unittest`, one file per concern, each rule test
  carrying `# rule: R-…` comments. No mocks of our own components:
  external boundaries use real services (Mailpit for SMTP).
- Every `nim c` names `--out:` and `--nimcache:` (never beside the
  source); keep the Justfile and `repro.nim` edges in step.

## Visual iteration recipe (capture loop)

Every visual change iterates: edit → capture → background review →
read text summaries → fix. Reviewer sub-agents view the screenshots;
the main context only ever sees their under-200-word text summaries.

```sh
edit src/isonim_email/lower/button.nim   # e.g. tighten VML padding
just email-shots --affected              # changed stories; families
                                         # and schemes from the diff
# reviewers start in the background as captures land:
#   per-capture reviewer — one sub-agent per capture group (one
#     story in one family, all viewports). Prompt: brief path +
#     screenshot path + view/viewport + expected-elements pointer.
#     Under 200 words, rating 1-10, anything missing → ≤ 4.
#   consistency reviewer — one sub-agent per story: contact sheet
#     plus the story expected block and degradations lists.
read reviewer summaries; update build/email-shots/findings.jsonl
edit again …
just email-shots --affected --schemes light,dark  # full set
                                                  # before done
just email-shots --full --backends d --async      # Mailgun
                                                  # spread behind
```

Briefs (`brief-<family>-<viewport>-<scheme>.md`) and contact sheets
(`contact-<viewport>-<scheme>.png`) land in each story's run dir next
to its captures. The loop stops when the full capture set for the
work in hand has no open P1/P2 findings; a
rating summarises the list, it is never the gate itself.

The capture CLI serves backend A only (`--backends a`, the default).
Backend B/C coverage joins the done-line later; `--backends d` and
`--async` land with backend D (today they fail naming it).
