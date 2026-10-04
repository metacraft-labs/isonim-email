# isonim-email — task entry points.
#
# Every recipe assumes this repo's dev shell is active (Nim, nimble, just,
# node all come from there -- there is no global nim). From a clean checkout:
#   nix develop -c just test
# or enter the shell via direnv (`direnv allow`) and run `just test`.
#
# Sibling repos (isonim, nim-everywhere, nim-faststreams, nim-stew) are
# expected as checkouts next to this repo (`../isonim`, …), resolved via
# `config.nims` and the `src-paths` variable below. In CI they are cloned
# by the shared clone-repo action at the SHAs pinned in
# `.github/sibling-repos`.
#
# Every `nim c` names both `--out:` and `--nimcache:` (never beside the
# source), so each build's intermediates stay inside this checkout.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

# Path lookups - mirrors what `config.nims` exports (kept here so a
# developer running `just <recipe>` outside direnv still resolves
# sibling-repo sources).
src-paths := "--path:src --path:tests --path:../isonim/src --path:../nim-everywhere/src --path:../nim-faststreams --path:../nim-stew --path:../isonim-docs/src"

# Style checks - applied to every nim invocation in this file.
nim-flags := "--styleCheck:usages --styleCheck:error"

# Variant-preserving Tailwind expansion: every nim compile resolves
# isonim's Tailwind map to this
# repo's own generated file (absolute path; see config.nims for why the
# Justfile, not config.nims, carries it).
tailwind-flags := "-d:tailwindStylesPathOverride=" + justfile_directory() + "/build/tailwind-styles.json"

# The ordered list of test files. Adding a new test file here gates it
# on CI. Files follow the `tests/t1_*`, `t2_*`, `t3_*`, `t4_*` naming
# convention used by the verification pointers.
tests := "tests/t1_plumbing.nim tests/t1_renderer_conformance.nim tests/t1_serializer_determinism.nim tests/t1_conditional_comments.nim tests/t1_no_hydration_residue.nim tests/t1_render_email.nim tests/t1_source_spans.nim tests/t1_rule_traceability.nim tests/t1_compile_fail.nim tests/t1_ir_restriction.nim tests/t2_vocabulary.nim tests/t2_vocabulary_compile_fail.nim tests/t2_tailwind_map.nim tests/t3_snapshot_reproducible.nim tests/t3_metrics_reproducible.nim tests/t3_icons_reproducible.nim tests/t3_lint_flex.nim tests/t3_lint_degradation.nim tests/t4_tokens.nim tests/t4_text_metrics.nim tests/t4_theme_snapshot.nim tests/t4_normalisation.nim tests/t4_head_css.nim tests/t4_class_names.nim tests/t4_styles.nim tests/t4_head_budget.nim tests/t5_document_golden.nim tests/t5_preheader.nim tests/t5_validate.nim tests/t5_a11y.nim tests/t5_lint_a11y.nim tests/t5_emc_top_five.nim tests/t5_pass_order.nim tests/t5_ganga_strip.nim tests/t5_media_queries.nim tests/t5_lower_elements.nim tests/t5_layout.nim tests/t5_scaffolding.nim tests/t5_columns.nim tests/t5_primitives.nim tests/t5_text.nim tests/t5_images.nim tests/t5_leaves.nim tests/t5_button.nim tests/t5_background.nim tests/t5_table.nim tests/t5_navigation.nim tests/t5_raw.nim tests/t5_text_checks.nim tests/t5_welcome_golden.nim tests/t5_dark.nim tests/t5_text_part.nim tests/t5_long_words.nim tests/t6_qp.nim tests/t6_unsubscribe.nim tests/t6_assets.nim tests/t6_crop.nim tests/t6_size.nim tests/t6_message_api.nim tests/t6_headers.nim tests/t6_header_fuzz.nim tests/t6_dot_stuff.nim tests/t6_mailgun.nim tests/t6_roundtrip.nim tests/t7_stories.nim tests/t7_brief.nim tests/t7_patterns.nim tests/t7_content_patterns.nim tests/t7_container_data_patterns.nim tests/t7_action_patterns.nim tests/t7_pattern_story_sets.nim tests/t7_text_part_goldens.nim tests/e2e_local_shots_latency.nim tests/e2e_local_capture_deterministic.nim tests/e2e_brief_diff_missing_element.nim tests/e2e_dom_assertions.nim tests/e2e_local_columns.nim tests/e2e_local_primitives.nim tests/e2e_local_images_off.nim tests/e2e_local_text_edges.nim tests/e2e_local_dark_modes_legible.nim tests/e2e_local_line_items.nim tests/e2e_local_overflow_320.nim"

# Backend-independent passes, also run on the JS target.
# A file listed here must not touch backend-specific modules (no `std/os`
# process/file APIs); `nim js -r` executes it under the dev shell's node.
# (t1_rule_traceability, t1_compile_fail, t1_ir_restriction,
# t2_vocabulary_compile_fail and t2_tailwind_map read files or shell
# out, so they are C-only,
# as is t3_snapshot_reproducible: the generator reads JSON object insertion
# order, which the JS backend does not preserve; t3_metrics_reproducible
# reads font files and runs fc-match and the metrics generator. t3_icons_reproducible
# runs the social-icon generator and reads its files. t6_roundtrip is C-only
# too: it spawns a real Mailpit plus a fixture HTTP server and reads
# fixtures and docs/ off disk; t6_header_fuzz runs the dev shell's
# python3 as its decoding oracle, and so does t6_crop (the PNG
# encoder's output read by Python's zlib); t6_dot_stuff exercises the SMTP
# transport, socket code the JS build leaves out, and t6_mailgun
# drives the Mailgun transport against a local capture server.
# t7_text_part_goldens reads (and, on request, writes) the text-part
# goldens. e2e_local_shots_latency likewise: it
# shells out to node + just and reads the run dir off disk, as does
# e2e_local_capture_deterministic (two full-matrix CLI runs plus
# fc-list font checks), and e2e_brief_diff_missing_element (shells out
# to node for the findings.ts rating and writes its baseline to
# tmp), and e2e_dom_assertions (two gated CLI runs plus run-dir
# reads).)
tests-js := "tests/t1_plumbing.nim tests/t1_renderer_conformance.nim tests/t1_serializer_determinism.nim tests/t1_conditional_comments.nim tests/t1_no_hydration_residue.nim tests/t1_render_email.nim tests/t1_source_spans.nim tests/t2_vocabulary.nim tests/t3_lint_flex.nim tests/t3_lint_degradation.nim tests/t4_tokens.nim tests/t4_text_metrics.nim tests/t4_theme_snapshot.nim tests/t4_normalisation.nim tests/t4_head_css.nim tests/t4_class_names.nim tests/t4_styles.nim tests/t4_head_budget.nim tests/t5_document_golden.nim tests/t5_preheader.nim tests/t5_validate.nim tests/t5_a11y.nim tests/t5_lint_a11y.nim tests/t5_emc_top_five.nim tests/t5_pass_order.nim tests/t5_ganga_strip.nim tests/t5_media_queries.nim tests/t5_lower_elements.nim tests/t5_layout.nim tests/t5_scaffolding.nim tests/t5_columns.nim tests/t5_primitives.nim tests/t5_text.nim tests/t5_images.nim tests/t5_leaves.nim tests/t5_button.nim tests/t5_background.nim tests/t5_table.nim tests/t5_navigation.nim tests/t5_raw.nim tests/t5_text_checks.nim tests/t5_welcome_golden.nim tests/t5_dark.nim tests/t5_text_part.nim tests/t5_long_words.nim tests/t6_qp.nim tests/t6_unsubscribe.nim tests/t6_assets.nim tests/t6_size.nim tests/t6_message_api.nim tests/t6_headers.nim tests/t7_stories.nim tests/t7_brief.nim tests/t7_patterns.nim tests/t7_content_patterns.nim tests/t7_container_data_patterns.nim tests/t7_action_patterns.nim"

# --- Default targets ---

# Build: compile the library umbrella and every test file (no run).
build:
    @mkdir -p build/test-bin test-logs
    nim c {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/isonim_email --nimcache:build/nimcache-lib src/isonim_email.nim 2>&1 | tee test-logs/build.log
    @for t in {{tests}}; do \
      echo "Building $t"; \
      nim c {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/test-bin/$(basename $t .nim) --nimcache:build/nimcache-$(basename $t .nim) $t 2>&1 | tee -a test-logs/build.log; \
    done

# Generate build/tailwind.css + build/tailwind-styles.json from THIS
# repo's content only (src/, examples/, tests/; Tailwind's automatic
# source detection is off), with sm/dark/hover variant records and
# units. `md` is listed only so the variant-preserving expansion tags
# (rather than flattens) md: classes and the style pass can reject
# them per the one-breakpoint rule (only sm: ships). The Tailwind CLI
# comes from the dev shell; isonim's extractor is run read-only, and
# every output stays under build/ (see tools/tailwind/build-tailwind.mjs).
# With ISONIM_EMAIL_PREBUILT_DRIVERS set (prebuilt story drivers, below)
# nothing is compiled, so the map is not needed and not built.
build-tailwind:
    @if [ -n "${ISONIM_EMAIL_PREBUILT_DRIVERS:-}" ]; then \
      echo "build-tailwind: skipped (prebuilt drivers from $ISONIM_EMAIL_PREBUILT_DRIVERS)"; \
    else \
      node tools/tailwind/build-tailwind.mjs; \
    fi

# Regenerate src/isonim_email/support/caniemail_data.nim from the pinned
# caniemail snapshot. Verifies the vendored
# payload against the pin's sha256 first; the generator cross-checks the
# pin's apiVersion/dataDate against the payload. Re-running on the pinned
# inputs is a byte-identical no-op (tests/t3_snapshot_reproducible.nim);
# re-pinning (new data.json + pin) is a deliberate PR whose diff shows
# which support values changed.
support-snapshot:
    @mkdir -p build test-logs
    @expected=$(grep -o '"sha256": "[0-9a-f]*"' tools/support-snapshot/snapshot.pin.json | cut -d'"' -f4) && \
      actual=$(sha256sum tools/support-snapshot/caniemail-data.json | cut -d' ' -f1) && \
      [ "$expected" = "$actual" ] || \
      (echo "caniemail-data.json sha256 $actual != pin $expected" && exit 1)
    nim c {{nim-flags}} --out:build/snapshot --nimcache:build/nimcache-snapshot -r tools/support-snapshot/snapshot.nim tools/support-snapshot/caniemail-data.json tools/support-snapshot/snapshot.pin.json src/isonim_email/support/caniemail_data.nim 2>&1 | tee test-logs/support-snapshot.log

# Regenerate src/isonim_email/style/metacraft_theme.nim from the pinned
# design-system snapshot. Verifies each vendored payload
# against the pin's sha256 first; re-running on the pinned inputs is a
# byte-identical no-op (tests/t4_theme_snapshot.nim); re-pinning (new
# payloads + pin + mapping review) is a deliberate PR whose diff shows
# which theme values changed.
theme-snapshot:
    @mkdir -p build test-logs
    @for f in brand alias mapped; do \
      expected=$(grep -o "\"${f}Sha256\": \"[0-9a-f]*\"" tools/theme-snapshot/theme.pin.json | cut -d'"' -f4) && \
      actual=$(sha256sum tools/theme-snapshot/${f}.json | cut -d' ' -f1) && \
      [ "$expected" = "$actual" ] || \
      (echo "${f}.json sha256 $actual != pin $expected" && exit 1); \
    done
    nim c {{nim-flags}} {{src-paths}} --out:build/theme-snapshot --nimcache:build/nimcache-theme-snapshot -r tools/theme-snapshot/snapshot.nim tools/theme-snapshot/brand.json tools/theme-snapshot/alias.json tools/theme-snapshot/mapped.json tools/theme-snapshot/mapping.json tools/theme-snapshot/theme.pin.json src/isonim_email/style/metacraft_theme.nim 2>&1 | tee test-logs/theme-snapshot.log

# Regenerate src/isonim_email/metrics_data.nim, the text-metrics table
# (advance widths of the pinned capture fonts, read with fonttools; the
# font files' sha256 are recorded in its header). Re-running on the same
# fonts is a byte-identical no-op (tests/t3_metrics_reproducible.nim); a font
# update shows up as a hash and advance diff.
text-metrics:
    "$ISONIM_EMAIL_FONTTOOLS_PYTHON" tools/text-metrics/generate.py src/isonim_email/metrics_data.nim

# Regenerate the built-in social icons (src/isonim_email/assets/social/,
# monogram plates drawn from the pinned Roboto Bold with fonttools).
# Re-running on the same font is a byte-identical no-op
# (tests/t3_icons_reproducible.nim).
social-icons:
    "$ISONIM_EMAIL_FONTTOOLS_PYTHON" tools/social-icons/generate.py src/isonim_email/assets/social

# Test: the full suite on the C backend, plus the backend-independent
# passes on the JS backend, plus the capture emulation-transform tests,
# plus the self-hosted webmail end-to-end tests, plus the desktop-client
# end-to-end tests for Thunderbird and Claws Mail (Linux only;
# `just test-desktop-all` runs every desktop client), plus the capture
# regression checks (Tier-1 + Tier-2).
#
# The shared prerequisites (the Tailwind map, the story and brief
# drivers) are built first; then the six test recipes run at the same
# time (tools/test/run-recipes.sh), each logging to
# test-logs/<recipe>.log, and the C and JS recipes run their files
# concurrently too (tools/test/run-nim-tests.sh). Every test keeps its
# services, browsers, sessions, ports and scratch state to itself, so the
# recipes do not see each other. A line per recipe says PASS or FAIL as
# it finishes; a failed recipe's log follows at the end, naming the
# failing file and test; the exit status is non-zero if any failed.
# `test-serial` runs the same recipes one after another, as before.
test: build-tailwind email-shots-build
    tools/test/run-recipes.sh test-c test-js test-ts test-webmail test-desktop test-capture-ci

# The same recipes, one at a time, each streaming its output (slower;
# for comparing timings or reading one recipe's output live).
test-serial: build-tailwind test-c test-js test-ts test-webmail test-desktop test-capture-ci

# The capture regression checks as part of the full suite. The
# baselines (Tier-1 exact hashes above all) are pinned to the
# x86_64-linux capture environment, so other hosts say so loudly and
# do not run them; run `just email-capture-ci` directly to see the
# numbers anyway.
test-capture-ci:
    @if [ "$(uname -sm)" = "Linux x86_64" ]; then       just email-capture-ci;     else       echo "test-capture-ci: NOT RUN on $(uname -sm): the capture baselines are pinned to x86_64-linux";     fi

# Test on the C backend (the default target). Each file is its own
# `nim c -r` with its own binary and nimcache, as `test-file` builds it;
# several files compile and run at once (ISONIM_EMAIL_TEST_JOBS sets how
# many; tools/test/run-nim-tests.sh), each logging to
# test-logs/<file>-c.log. Depends on the story driver because the
# end-to-end files run it, and building it here keeps them from building
# it concurrently.
test-c: build-tailwind email-shots-build
    tools/test/run-nim-tests.sh c "{{nim-flags}} {{src-paths}} {{tailwind-flags}}" {{tests}}

# Run one test file on the C backend (verification pointers
# use this form: `just test-file tests/<file>.nim`).
test-file file:
    @mkdir -p build/test-bin test-logs
    nim c {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/test-bin/$(basename {{file}} .nim) --nimcache:build/nimcache-$(basename {{file}} .nim) -r {{file}} 2>&1 | tee test-logs/$(basename {{file}} .nim)-c.log

# Test the backend-independent passes on the JS backend (node).
#
# isonim's tailwind.nim staticReads its style map at compile time, and on
# the JS target a missing file is a hard error (the try/except around it
# cannot catch it) — hence the build-tailwind dependency. The map path
# comes from tailwind-flags above, the variant-preserving opt-in switch
# from config.nims.
test-js: build-tailwind
    tools/test/run-nim-tests.sh js "{{nim-flags}} {{src-paths}} {{tailwind-flags}}" {{tests-js}}

# node:test as every TypeScript recipe runs it: the spec reporter (a
# failure's file:line and assertion at the end), and a per-test timeout
# that fails a test still running after 25 min. It applies to each
# describe() suite as a whole too, so it sits well above the longest
# suite: the desktop clients' (`test-desktop-all`: about 6 min on a quiet
# host, 9-10 min at load ~100-120). It does not catch a handle left open
# after the tests finish (a server nobody closed keeps `node --test`
# waiting); tools/test/run-recipes.sh's per-recipe timeout does.
node-test := "node --test --test-reporter=spec --test-timeout=1500000"

# Test the capture and review suites (emulation transforms,
# cache/affected/wiring suites, provider routing and requirement
# suites, contact-sheet and findings suites, and the test runners'
# own suite):
# node:test with no runner to install.
# Quoted so node expands the globs (bare-directory discovery skips .ts).
# The self-hosted webmail and desktop-client end-to-end files are left
# to `test-webmail` and `test-desktop`.
test-ts:
    {{node-test}} "tools/capture/*.test.ts" "tools/capture/emulation/*.test.ts" $(ls tools/capture/providers/*.test.ts | grep -v -e '/selfhosted_webmail\.test\.ts$' -e '/linux_desktop\.test\.ts$') "tools/review/*.test.ts" "tools/test/*.test.ts"

# The self-hosted webmail provider end to end: real Roundcube and
# SnappyMail on php-fpm and caddy, Dovecot and Chromium (~3 min on a
# loaded host; a recipe of its own so it can be run alone, and the
# longest of `just test`'s concurrent recipes together with
# test-desktop). Needs the story driver (`just email-shots-build`).
test-webmail: email-shots-build
    {{node-test}} tools/capture/providers/selfhosted_webmail.test.ts

# The linux-desktop provider end to end: real clients in a headless
# sway (wlroots' software renderer), Dovecot, the assets service, grim,
# wtype, the accessibility bus and OCR, a recipe of its own so it can be
# run alone. Linux only (the provider is): elsewhere it says
# so and does not run. Needs the story driver (`just email-shots-build`).
# `test-desktop` runs the multi-client tests on Thunderbird (the
# thunderbird family's client) and Claws Mail (the quickest verification
# client), ~3 min on a loaded host; `test-desktop-all` runs them on all
# five clients (Evolution, Geary and KMail with Akonadi add ~3 min), and
# is the one to run after a change to the desktop provider or a driver.
test-desktop: email-shots-build
    @if [ "$(uname -s)" = "Linux" ]; then       ISONIM_EMAIL_DESKTOP_CLIENTS=thunderbird,claws-mail {{node-test}} tools/capture/providers/linux_desktop.test.ts;     else       echo "test-desktop: NOT RUN on $(uname -s): the desktop clients run in a Linux compositor";     fi

test-desktop-all: email-shots-build
    @if [ "$(uname -s)" = "Linux" ]; then       {{node-test}} tools/capture/providers/linux_desktop.test.ts;     else       echo "test-desktop-all: NOT RUN on $(uname -s): the desktop clients run in a Linux compositor";     fi

# Check the crop calibration of the desktop clients now (a capture run
# does it by itself when a client's build changed since its last
# calibration); records each pass under build/email-shots/.calibration/.
email-calibrate *args:
    node tools/capture/email-calibrate.ts {{args}}

# What the credentials directory holds for each provider that reads it
# ($ISONIM_EMAIL_CREDENTIALS_DIR, defaulting to
# ${XDG_CONFIG_HOME:-$HOME/.config}/metacraft/dev-credentials/isonim-email):
# per provider, whether its files are present, private (directory 0700,
# no group- or world-readable file) and complete, and the files no
# provider declares. Never prints a secret. `--strict` exits 1 when any
# provider's credentials are unavailable; an unsafe directory always does.
email-credentials-check *args:
    node tools/capture/email-credentials.ts check {{args}}

# Write placeholder credential files (0600, in 0700 directories) for the
# named providers, or all of them, to fill in with your own accounts.
# Never replaces an existing file.
email-credentials-template *providers:
    node tools/capture/email-credentials.ts template {{providers}}

# Build the story→MIME driver (pipeline step 1) and the
# review-brief driver (step 1b). Each rebuilds only
# when a Nim source or a story fixture image (compiled in) is newer
# than its binary, so plain iterations
# stay fast; `just email-shots` and the e2e tests depend on this.
#
# ISONIM_EMAIL_PREBUILT_DRIVERS names a directory holding both drivers
# already built (`build-stories`, `brief-driver`; the hermetic capture
# check builds them with Nix, see `test-vm`): they are copied into place
# and nothing is compiled.
email-shots-build: build-tailwind
    @mkdir -p build/capture build/review test-logs
    @if [ -n "${ISONIM_EMAIL_PREBUILT_DRIVERS:-}" ]; then \
      install -m755 "$ISONIM_EMAIL_PREBUILT_DRIVERS/build-stories" build/capture/build-stories; \
      install -m755 "$ISONIM_EMAIL_PREBUILT_DRIVERS/brief-driver" build/review/brief-driver; \
      echo "build/capture/build-stories, build/review/brief-driver: prebuilt, from $ISONIM_EMAIL_PREBUILT_DRIVERS"; \
    fi
    @if [ -n "${ISONIM_EMAIL_PREBUILT_DRIVERS:-}" ]; then :; \
    elif [ -x build/capture/build-stories ] && [ -z "$(find src tools/capture tests/stories \( -name '*.nim' -o -name '*.png' \) -newer build/capture/build-stories 2>/dev/null)" ]; then \
      echo "build/capture/build-stories up to date"; \
    else \
      nim c {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/capture/build-stories --nimcache:build/nimcache-build-stories tools/capture/build_stories.nim 2>&1 | tee test-logs/email-shots-build.log; \
    fi
    @if [ -n "${ISONIM_EMAIL_PREBUILT_DRIVERS:-}" ]; then :; \
    elif [ -x build/review/brief-driver ] && [ -z "$(find src tools/review tests/stories \( -name '*.nim' -o -name '*.png' \) -newer build/review/brief-driver 2>/dev/null)" ]; then \
      echo "build/review/brief-driver up to date"; \
    else \
      nim c {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/review/brief-driver --nimcache:build/nimcache-brief-driver tools/review/brief_driver.nim 2>&1 | tee test-logs/brief-driver-build.log; \
    fi

# Backend-A email captures (backend A only, emulation transforms
# included). A bare run captures what changed (changed-only --affected default);
# --full captures the whole matrix.
email-shots *args: email-shots-build
    node tools/capture/email-shots.ts {{args}}

# The review loop's own check (visual design methodology, checklist
# item 7): does a reviewer notice a missing element? Captures the
# intact receipt and `receiptB` (the receipt with its logo
# dropped from the output; its brief still expects the logo), then
# prints what each read-only reviewer sub-agent must be given and where
# its report is to be saved. The reviewers are agents, so the result is
# a recorded session: `email-review-broken-check RUN` then checks the
# saved reports and the session findings list (the broken story
# reported missing its logo and rated 4 or lower, the intact one
# passing, the P1 recorded).
email-review-broken *args: email-shots-build
    node tools/review/broken_story.ts prepare {{args}}

email-review-broken-check run:
    node tools/review/broken_story.ts check {{run}}

# Capture regression checks (Tier-1 + Tier-2, Tier-3 record/gate),
# run locally as part of `just test` (test-capture-ci) or on their own.
# Captures the full story set on the pinned CI matrix (backend a only:
# the real clients other providers serve under the same families are not
# part of these baselines; core families ×
# mobile,desktop × light, --full so MIME-diff selection cannot empty
# it, --no-cache so every PNG is a real capture) into
# build/email-capture-ci/<utc-date>, then checks it: Tier-1 exact
# sha256 of each canary PNG vs
# tests/baselines/canary/<variant>.sha256, Tier-2 diffPng of every
# capture vs tests/baselines/<story>/<variant>.png (fail over a
# 0.001 diff ratio). Tier-3 DOM assertions (overflow, touch,
# bodyfont, contrast, unsubscribe, clipped) are recorded in every
# provenance + per-story assertions.json either way; `just
# email-capture-ci --assert` additionally gates the captures on them
# (passed through to email-shots below) and runs the checker's Tier-3
# over the assertions.json files. Gating is opt-in because the seed
# stories (canary/receipt/alert) carry no visible unsubscribe link, so
# a gated matrix fails Tier-3 until the reference template set lands
# with real footers. axe-core, the seventh Tier-3 item, is not pinned in
# the dev shell or isonim's node_modules, so it is recorded as
# pass:null, never faked — owner action: pin axe-core (a flake.nix
# package or isonim/node_modules via yarn) and inject + axe.run it
# in-page in email-shots.ts captureOne. Any mismatch exits 1 naming
# the variants.
# `just email-capture-ci --update-baselines` regenerates the
# baselines from the fresh run — the ONLY way baselines change, at
# end-of-session approval (see tests/baselines/README.md). Stories
# whose baselines await re-approval (a PENDING-REVIEW marker) are
# reported on every run but not compared; `--approve <story>` (with
# --update-baselines) re-approves one after a real review, and
# `--require-approved` fails while any story is pending.
email-capture-ci *args: email-shots-build
    out="build/email-capture-ci/$(date -u +%Y%m%dT%H%M%SZ)"; gate=""; echo " {{args}} " | grep -q " --assert " && gate="--assert" || true; node tools/capture/email-shots.ts --backends a --families apple,thunderbird,chromium-baseline --viewports mobile,desktop --schemes light --images on --full --no-cache $gate --out "$out" && node tools/capture/email-capture-ci.ts "$out" {{args}}

# The hermetic capture check: the capture providers in a NixOS VM
# (nix/capture-vm.nix). The story drivers are built in the Nix sandbox
# against the sibling repositories pinned as flake inputs (the SHAs of
# .github/sibling-repos); inside a VM with no network, the same tools and
# variables as this dev shell run `just email-capture-ci` (backend a's
# matrix against the committed baselines: the canary's exact hashes, every
# story's perceptual threshold) and capture the canary in Thunderbird,
# Claws Mail, Roundcube and SnappyMail through the local mail stack (every
# capture must succeed). The run directories are the build output (its
# store path is printed last). Needs KVM and an x86_64-linux builder (on
# another host, a remote builder of that system). Not part of `just
# test`: about 5 min on a loaded host, nearly all of it the VM. The full
# log, VM console included, goes to test-logs/test-vm.log; the console
# lines are left out of what is printed here.
#
# Run the hermetic capture check (a NixOS VM, about 5 min).
test-vm:
    @mkdir -p test-logs
    @grep -E '^[A-Za-z0-9_.-]+=[0-9a-f]{40}' .github/sibling-repos | while IFS== read -r repo rest; do \
      pin="${rest%%[[:space:]]*}"; \
      head=$(git -C "../$repo" rev-parse HEAD 2>/dev/null || echo none); \
      [ "$head" = "$pin" ] || echo "test-vm: note: ../$repo is at $head, the check builds against the pinned $pin"; \
    done
    nix build --no-link --print-out-paths -L .#checks.x86_64-linux.capture-linux-desktop 2>&1 | tee test-logs/test-vm.log | grep -v ' # \['

# The MJML conformance check: this library's Outlook geometry (ghost
# tables, cell px widths and padding as Word lays them out, responsive
# class widths) and its layout pass's widths against MJML 5's, for the
# fixtures in tests/conformance/fixtures.nim. MJML is the dev shell's
# pinned build (`$ISONIM_EMAIL_MJML`, nix/mjml/); nothing is fetched.
# Not part of `just test`. Outputs and report.txt go to
# build/conformance/. `just test-conformance --record` rewrites
# tests/conformance/mjml_widths.json (what the width-solver unit test
# reads) from MJML's output: a deliberate change, like a golden.
test-conformance *args:
    @mkdir -p build/conformance-bin test-logs
    nim c {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/conformance-bin/mjml-conformance --nimcache:build/nimcache-mjml-conformance tools/conformance/mjml_conformance.nim 2>&1 | tee test-logs/conformance-build.log
    build/conformance-bin/mjml-conformance {{args}} 2>&1 | tee test-logs/conformance.log

# Lint everything.
lint: lint-nim lint-ts lint-nix lint-markdown

# `nim check` over the library and every test. Check-only: never links,
# so no `--out:`/`--nimcache:` pair is needed here.
lint-nim:
    @mkdir -p test-logs
    nim check {{nim-flags}} {{src-paths}} {{tailwind-flags}} src/isonim_email.nim 2>&1 | tee test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} {{tailwind-flags}} tools/capture/build_stories.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} {{tailwind-flags}} tools/review/brief_driver.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} {{tailwind-flags}} tools/conformance/mjml_conformance.nim 2>&1 | tee -a test-logs/lint-nim.log
    @for t in {{tests}}; do \
      echo "Checking $t"; \
      nim check {{nim-flags}} {{src-paths}} {{tailwind-flags}} $t 2>&1 | tee -a test-logs/lint-nim.log; \
    done

# Type-check every tools/**/*.ts (tests included) with tsc under the
# strict tsconfig.json at the repo root, then the runtime gate: --help
# parses the whole capture CLI under Node's type stripping, and
# importing each emulation module plus the contact-sheet,
# dom-assertions, perceptual, capture-ci, latency, launch, fixture-host,
# client-brief, capture-provider, findings and broken-story
# modules parses those too (cache/affected ride along transitively).
# The declarations tsc reads (@types/node, playwright-core's own) come
# from the dev shell's ISONIM_EMAIL_TS_TYPES, a Nix-pinned tree linked
# into build/ts-types (see flake.nix); nothing is installed from npm.
lint-ts:
    @if [ -z "${ISONIM_EMAIL_TS_TYPES:-}" ]; then echo "lint-ts: ISONIM_EMAIL_TS_TYPES is unset (run inside nix develop)" >&2; exit 1; fi
    @mkdir -p build && ln -sfn "$ISONIM_EMAIL_TS_TYPES" build/ts-types
    tsc -p tsconfig.json
    node tools/capture/email-shots.ts --help >/dev/null
    node tools/capture/email-calibrate.ts --help >/dev/null
    node tools/capture/email-credentials.ts --help >/dev/null
    for m in tools/capture/emulation/*.ts; do case "$m" in *.test.ts) continue;; esac; node --input-type=module -e "await import('./$m')"; done
    node --input-type=module -e "await import('./tools/capture/contact_sheet.ts')"
    node --input-type=module -e "await import('./tools/capture/dom_assertions.ts')"
    node --input-type=module -e "await import('./tools/capture/perceptual.ts')"
    node --input-type=module -e "await import('./tools/capture/email-capture-ci.ts')"
    node --input-type=module -e "await import('./tools/capture/latency.ts')"
    node --input-type=module -e "await import('./tools/capture/launch.ts')"
    node --input-type=module -e "await import('./tools/capture/fixture_host.ts')"
    node --input-type=module -e "await import('./tools/capture/briefs.ts')"
    for m in tools/capture/providers/*.ts; do case "$m" in *.test.ts) continue;; esac; node --input-type=module -e "await import('./$m')"; done
    node --input-type=module -e "await import('./tools/review/findings.ts')"
    node --input-type=module -e "await import('./tools/review/broken_story.ts')"

lint-nix:
    nixfmt --check flake.nix nix/*.nix

lint-markdown:
    @if command -v markdownlint-cli2 >/dev/null 2>&1; then \
      markdownlint-cli2 "**/*.md" "#node_modules" "#test-logs" "#build" || true; \
    else \
      echo "markdownlint-cli2 not available; skipping (run in nix develop)"; \
    fi

# Format everything.
format: format-nim format-nix

# The generated caniemail_data.nim and metacraft_theme.nim are excluded:
# their bytes are pinned by the snapshot tests, so no formatter may
# touch them.
format-nim:
    @if command -v nimpretty >/dev/null 2>&1; then \
      files=$(echo src/isonim_email.nim src/isonim_email/*.nim src/isonim_email/*/*.nim tools/support-snapshot/*.nim tools/theme-snapshot/*.nim tests/*.nim tests/compile_fail/*.nim | tr ' ' '\n' | grep -v 'support/caniemail_data.nim' | grep -v 'style/metacraft_theme.nim'); \
      nimpretty $files; \
    else \
      echo "nimpretty not available; skipping Nim formatting"; \
    fi

format-nix:
    nixfmt flake.nix nix/*.nix

# Benchmarks placeholder: no benchmarks exist until the
# rendering pipeline they measure lands (after the components).
bench:
    @echo "isonim-email: no benchmarks yet (they land with the components)"

# Single-source-of-truth version bump: the nimble file owns the
# version; the umbrella const follows it.
bump-version version:
    sed -i 's/^version[[:space:]]*=.*/version       = "{{version}}"/' isonim_email.nimble
    sed -i 's/^const isonimEmailVersion\* = ".*"/const isonimEmailVersion* = "{{version}}"/' src/isonim_email.nim
