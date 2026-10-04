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
just test            # full suite: C, JS, the TS tooling tests, the webmail and
                     # desktop end-to-end tests, capture checks (concurrently)
just test-serial     # the same recipes one at a time, output streamed
just test-file tests/t4_styles.nim  # one Nim test file on the C backend
just email-shots     # screenshot captures through the capture providers
just email-capture-ci # capture regression checks (part of just test)
just test-conformance # Outlook geometry and widths against the pinned MJML
just lint            # nim check, tsc, capture-CLI gate, nixfmt, markdownlint
just format          # nimpretty + nixfmt (alias: just fmt)
just example-page    # the billing page example rendered by IsoNim's web
                     # renderer, saved as static HTML with screenshots
just email-preview   # every story on http://127.0.0.1:4610/: transforms,
                     # widths, schemes, diagnostics, reload on change
just bench           # benchmarks (none yet; they land later)
just t               # alias for test
```

`just test` builds the shared prerequisites, then runs its six recipes
(`test-c`, `test-js`, `test-ts`, `test-webmail`, `test-desktop`,
`test-capture-ci`) at the same time, and `test-c`/`test-js` compile and
run their files several at a time (`ISONIM_EMAIL_TEST_JOBS` sets how
many; by default it follows the host's cores and load). Output goes to
`test-logs/<recipe>.log` and `test-logs/<file>-<c|js>.log`; the terminal
gets a PASS/FAIL line per recipe (per file when `just test-c` or
`just test-js` runs alone), then each failure's log, naming the failing
file and test. A test must therefore keep its processes,
ports and scratch state to itself and scope any "nothing left behind"
check to what it started: other tests run beside it. Each recipe runs
in a process group of its own; one still running after
`ISONIM_EMAIL_RECIPE_TIMEOUT` seconds (default 1800) fails as timed out,
and one that exits leaving processes behind fails too; either way all
of its processes are killed.

Sibling repos (`../isonim`, `../nim-everywhere`, `../nim-faststreams`,
`../nim-stew`) must be checked out next to this repo; `config.nims`
and the Justfile resolve them. In CI they are cloned at the SHAs in
`.github/sibling-repos`.

`just test-conformance` (not part of `just test`) checks the Outlook
geometry this library emits (ghost tables, the boxes Word lays text
into, responsive class widths) and the layout pass's widths against
MJML 5's for the fixtures in `tests/conformance/`; MJML is pinned in
`nix/mjml/` and nothing is fetched. The layout reference stories
(`tests/stories/seed_layout.nim`) and the layout primitives' story set
(`tests/stories/seed_primitives.nim`: `boxMinimal` … `sidebarInContext`)
and the content patterns' story sets (`tests/stories/seed_structure.nim`,
`seed_media.nim`: `headerMinimal` … `countdownInContext`), the
Markdown bodies' (`seed_markdown.nim`) and the reference emails
(`examples/reference_set.nim`, registered by
`tests/stories/seed_reference.nim`: `receiptTypical` …
`newsletterColumns`) and the domain view's invoice email
(`tests/stories/seed_domain.nim`: `invoiceSummary`) and the Gmail
markup stories (`tests/stories/seed_markup.nim`: `receiptMarkup`,
`shippingMarkup`, two reference emails with JSON-LD in the head,
`docs/gmail-markup.md`) are captured with
`ISONIM_CAPTURE_LAYOUT=1 just email-shots layoutOneColumn …`; they are
outside the regression matrix, apart from the reference emails: the
matrix (`just email-capture-ci`,
gated with `--assert` in `just test`) is the canary and the fourteen
reference emails, Tier-1 the canary, `receiptTypical`, `alertArabic`
and `securityCodeJapanese` (`tests/baselines/README.md`). Images a
story's render derives (the crops of `mailImage(crop)`) are written to
`build/email-shots/.derived-assets/`, which the fixture host serves.
Every backend-a capture also runs the pinned axe-core
(`$ISONIM_EMAIL_AXE`, `tools/capture/axe.ts`) after its screenshot: the
seventh Tier-3 check, gated by `--assert` like the others.

`just test-vm` (not part of `just test`; needs KVM) runs the hermetic
capture check, `checks.x86_64-linux.capture-linux-desktop`
(`nix/capture-vm.nix`): the capture providers in a NixOS VM with no
network, against the committed baselines. It does not use the `../<repo>`
checkouts: the siblings are `flake = false` inputs in `flake.nix`, each
pinned at the same SHA as its `.github/sibling-repos` line, and
evaluation fails when `flake.lock` and that file disagree. To move a pin,
change both together:

1. edit the SHA in `.github/sibling-repos`;
2. edit the same SHA in that input's `url` in `flake.nix`;
3. `nix flake lock` (records the new revision in `flake.lock`);
4. `nix flake check --no-build`, then `just test-vm`.

A new sibling needs a line in `.github/sibling-repos`, an input in
`flake.nix`, and an entry in `siblings` where `flake.nix` imports
`nix/capture-vm.nix` (a pin with no input is not checked). `just test-vm`
prints a note for each `../<repo>` checkout that is not at its pin: the
host build then compiles against different sources than the VM.

## Project structure

```text
src/
  isonim_email.nim                 # public umbrella - re-exports land here
  isonim_email/                    # library modules (renderer,
                                   # vocabulary, style compiler, MIME, …)
examples/
  reference_set.nim                # the reference emails: the layouts and
                                   # every common email type, with their
                                   # fixed data (and assets/, their images)
  invoice_summary*.nim             # a domain view on the portable leaves
                                   # (docs/portable-views.md), rendered
                                   # into an email and a web page
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
tools/test/                        # the concurrent test runners behind
                                   # `just test`, `test-c` and `test-js`
tools/web/                         # renders an IsoNim web page in the
                                   # pinned Chromium, saved as static HTML
tools/preview/                     # the preview server (`just email-preview`)
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

## Preview server and the IsoNim editor

`just email-preview` serves every registered story (the reference
emails, the layout and element sets and the capture fixtures) on
`http://127.0.0.1:4610/` (`--port N`, loopback only). The page lists the
stories by group and shows the selected one in an iframe: as authored
or through one of the capture's emulation transforms (gmailWeb, ganga,
outlookWeb, imagesOff, wordApprox; images off on any of them), at 320px,
mobile (375px) or desktop (800px) width, in the light or dark scheme
(emulated in the HTML, so the viewer's own setting does not leak in;
forced dark is a shot of the pinned Chromium under Blink's automatic dark
mode), or as its plain-text part. Beside it are the render's
diagnostics, each with a link to the line that built the element it is
about (`/source?file=…&line=…`): the story kit's `el`, the layouts'
`node` and `ui(r)` templates record their call site. The selection is in
the URL's fragment, so a link to the page names a story and its view.

The server compiles the story driver (`tools/capture/build_stories.nim`,
its `--preview` mode) into `build/email-preview/`, apart from the
captures' binary, and watches `src/`, `examples/` and `tests/stories/`:
a change rebuilds it and the open page reloads the preview in place
(server-sent events); a change that does not compile shows the
compiler's output and keeps the last good build. `build-stories --list`
prints the registered stories as JSON.

The IsoNim editor lists and renders the same stories through its story
contract: `isonim_email/editor_stories` turns the registry into the
editor's `StoryGroup`s (one per story group, every story a page) and a
`ProjectPreviewHook` whose preview is the message's HTML and text part
on the Web platform (`emailStoryGroups()`, `emailPreviewHook()`,
`emailEditorPlatforms`, for `newEditorWorkspace`). It imports only the
editor's data types, so it builds on the C and JS targets.

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

Briefs (`brief-<family>-<viewport>-<scheme>.md` for backend `a`;
`brief-<backend>-<family>-<client>-<viewport>-<scheme>.md` for every
real-client capture, named like the capture without `-<images>.png`)
and contact sheets (`contact-<viewport>-<scheme>.png`, one cell per
client) land in each story's run dir next to its captures. A
real-client brief says which audience family the client is (the real
Thunderbird) or that it stands in for none (the webmails and the
other desktop clients), and what that client is expected to show:
its sanitiser, its dark behaviour and any of its own UI in the crop.
Reviewer sub-agents are read-only: their prompt says they may only
read files, never edit, build or commit, so they can run in parallel.

Keep the findings list with `tools/review/findings.ts`
(`appendFinding`, then `updateFindingStatus` to mark an entry `fixed`
in a run, `wontfix` with a reason, or to name the `owner` of a P3/P4
left open). The loop stops when the full capture set for the work in
hand has no open P1/P2 findings; a rating summarises the list, it is
never the gate itself.

The loop's own check (does a reviewer notice a missing element?):
`just email-review-broken` captures the receipt and `receiptB` (the
receipt with its logo dropped from the output, its brief unchanged)
and prints what each reviewer must be given; save each reviewer's
report verbatim where it says, record the broken story's P1, then
`just email-review-broken-check <run>` checks the session.

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

Three providers are registered: `browser-emulation` (backend `a`), the
dev shell's pinned Chromium, WebKit and Firefox, raw or through the
client emulations (gmailWeb, ganga, outlookWeb, imagesOff, wordApprox);
`selfhosted-webmail`, real Roundcube and SnappyMail on php-fpm and
caddy on loopback, against a harness-started Dovecot (family
`verification`: real sanitisers that stand in for no audience family;
select them with `--families verification`, `--clients
roundcube,snappymail` or `--backends selfhosted-webmail`); and
`linux-desktop` (Linux only), real desktop clients in a headless sway
(software rendering, a private D-Bus bus and home, a network namespace
with loopback only and name resolution of its own), captured with
grim: Thunderbird (family `thunderbird`), driven over its own remote
protocol, and Evolution, Geary, KMail (with Akonadi on SQLite) and
Claws Mail (family `verification`), driven through their own
command-line, D-Bus and socket interfaces and their accessibility
trees; desktop width only, and Claws Mail light only (`--clients
thunderbird,evolution`, `--families verification` or `--backends
linux-desktop`). A change alone selects backend `a` only; the real
clients run on a run with nothing to diff against, on `--full`, or
when named. Each desktop client's crop is calibrated against a fixture
with a square in each corner whenever its build changes (recorded under
`build/email-shots/.calibration/`); `just email-calibrate` runs the
check on demand. `just test-desktop` (part of `just test`) runs the
desktop end-to-end tests on Thunderbird and Claws Mail, and `just
test-desktop-all` on all five clients (run it after changing the
provider or a driver). Later: hosted webmail, clients in VM guests, and
a device-farm service, each as one more provider. `--backends b|c|d` and `--async`
are refused today, naming what lands later. Providers that need accounts read their
credentials from one directory on the machine running the captures
(`$ISONIM_EMAIL_CREDENTIALS_DIR`); the directory must be mode 0700 and
no file in it group- or world-readable.
