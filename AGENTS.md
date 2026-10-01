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
just test            # full suite: C, JS, the TS tooling tests, capture checks
just email-shots     # screenshot captures through the capture providers
just email-capture-ci # capture regression checks (part of just test)
just lint            # nim check, tsc, capture-CLI gate, nixfmt, markdownlint
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
  golden/                          # byte-exact goldens; changed only on
                                   # purpose, the reason recorded in the
                                   # owning test's header
  compile_fail/                    # `# expect:` fixtures + runner
  baselines/                       # capture regression baselines
tools/capture/                     # email-shots CLI, emulation transforms,
                                   # cache, contact sheets, regression checks
  providers/                       # capture provider interface, routing,
                                   # requirement checks, providers
tools/review/                      # review briefs and the findings list
```

## Layer rules

- `src/isonim_email.nim` is the stable public entry point; new public
  API is re-exported through it.
- Passes under `src/isonim_email/passes/` transform the tree in
  pipeline order; MSO/VML constructors stay restricted to
  `src/isonim_email/mso/` and `passes/head.nim`.
- Nim tests are `std/unittest`, one file per concern, each rule test
  carrying `# rule: R-…` comments; the capture and review tooling is
  TypeScript, tested with `node:test` and type-checked by `tsc`
  (`just lint-ts`). Tests use real services and boundaries (Mailpit for
  SMTP, the pinned browsers, real files and processes). A test double is
  used only where no real counterpart exists yet, and the test file's
  header says why.
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
# later: real-client providers join the same command; a slow
# device-farm spread will run in the background (--async, refused today)
```

Briefs (`brief-<family>-<viewport>-<scheme>.md`) and contact sheets
(`contact-<viewport>-<scheme>.png`) land in each story's run dir next
to its captures. The loop stops when the full capture set for the
work in hand has no open P1/P2 findings; a
rating summarises the list, it is never the gate itself.

### Capture providers

Every way of producing a screenshot is a capture provider
(`tools/capture/providers/`). A provider declares the clients it can
render (client id, family, engine, schemes, viewports), its
requirements (binaries, Nix, a credentials directory, the host OS) and
its health. `just email-shots` routes each requested family (and, with
`--clients`, client) to every available provider that serves it, runs
the providers concurrently in-process, and streams each capture as it
lands. The harness owns the result cache (keyed on the message, the
provider and its version, the client build, the viewport, scheme and
images, and the emulation's transform version), the provenance JSON
next to each PNG, `index.json` and the run summary.

An unavailable provider is never skipped silently: the run summary and
`run.json` name it with its reason, and a request no available provider
serves fails with that reason.

Local services several providers share (an IMAP server, a loopback
asset server) belong to the harness (`providers/services.ts`): a
provider declares one as a `service` requirement, the harness starts it
once per run before any provider is prepared, hands its endpoint to the
providers that declared it, and stops it after the last provider is
disposed; a service that fails to start makes those providers
unavailable with the reason. Providers keep clients warm only within one
run; `--cold` asks for a fresh client per capture.

Today one provider is registered: `browser-emulation` (backend `a`), the
dev shell's pinned Chromium, WebKit and Firefox, raw or through the
client emulations (gmailWeb, ganga, outlookWeb, imagesOff, wordApprox).
Later: real desktop clients in a headless compositor, self-hosted and
hosted webmail, clients in VM guests, and a device-farm service, each as
one more provider. `--backends b|c|d` and `--async` are refused today,
naming what lands later. Providers that need accounts read their
credentials from one directory on the machine running the captures
(`$ISONIM_EMAIL_CREDENTIALS_DIR`); the directory must be mode 0700 and
no file in it group- or world-readable.
