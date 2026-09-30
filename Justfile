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
tests := "tests/t1_plumbing.nim tests/t1_renderer_conformance.nim tests/t1_serializer_determinism.nim tests/t1_conditional_comments.nim tests/t1_no_hydration_residue.nim tests/t1_render_email.nim tests/t1_source_spans.nim tests/t1_rule_traceability.nim tests/t1_compile_fail.nim tests/t1_ir_restriction.nim tests/t2_vocabulary.nim tests/t2_vocabulary_compile_fail.nim tests/t2_tailwind_map.nim tests/t3_snapshot_reproducible.nim tests/t3_lint_flex.nim tests/t3_lint_degradation.nim tests/t4_tokens.nim tests/t4_theme_snapshot.nim tests/t4_normalisation.nim tests/t4_head_css.nim tests/t4_class_names.nim tests/t4_styles.nim tests/t4_head_budget.nim tests/t5_document_golden.nim tests/t5_preheader.nim tests/t5_validate.nim tests/t5_a11y.nim tests/t5_lint_a11y.nim tests/t5_emc_top_five.nim tests/t5_pass_order.nim tests/t5_ganga_strip.nim tests/t5_media_queries.nim tests/t6_qp.nim tests/t6_unsubscribe.nim tests/t6_assets.nim tests/t6_size.nim tests/t6_message_api.nim tests/t6_headers.nim tests/t6_header_fuzz.nim tests/t6_dot_stuff.nim tests/t6_roundtrip.nim tests/t7_stories.nim tests/t7_brief.nim tests/e2e_local_shots_latency.nim tests/e2e_local_capture_deterministic.nim tests/e2e_review_missing_element.nim tests/e2e_dom_assertions.nim"

# Backend-independent passes, also run on the JS target.
# A file listed here must not touch backend-specific modules (no `std/os`
# process/file APIs); `nim js -r` executes it under the dev shell's node.
# (t1_rule_traceability, t1_compile_fail, t1_ir_restriction,
# t2_vocabulary_compile_fail and t2_tailwind_map read files or shell
# out, so they are C-only,
# as is t3_snapshot_reproducible: the generator reads JSON object insertion
# order, which the JS backend does not preserve. t6_roundtrip is C-only
# too: it spawns a real Mailpit plus a fixture HTTP server and reads
# fixtures and docs/ off disk; t6_header_fuzz runs the dev shell's
# python3 as its decoding oracle; t6_dot_stuff exercises the SMTP
# transport, socket code the JS build leaves out. e2e_local_shots_latency likewise: it
# shells out to node + just and reads the run dir off disk, as does
# e2e_local_capture_deterministic (two full-matrix CLI runs plus
# fc-list font checks), and e2e_review_missing_element (shells out
# to node for the findings.ts rating and writes its baseline to
# tmp), and e2e_dom_assertions (two gated CLI runs plus run-dir
# reads).)
tests-js := "tests/t1_plumbing.nim tests/t1_renderer_conformance.nim tests/t1_serializer_determinism.nim tests/t1_conditional_comments.nim tests/t1_no_hydration_residue.nim tests/t1_render_email.nim tests/t1_source_spans.nim tests/t2_vocabulary.nim tests/t3_lint_flex.nim tests/t3_lint_degradation.nim tests/t4_tokens.nim tests/t4_theme_snapshot.nim tests/t4_normalisation.nim tests/t4_head_css.nim tests/t4_class_names.nim tests/t4_styles.nim tests/t4_head_budget.nim tests/t5_document_golden.nim tests/t5_preheader.nim tests/t5_validate.nim tests/t5_a11y.nim tests/t5_lint_a11y.nim tests/t5_emc_top_five.nim tests/t5_pass_order.nim tests/t5_ganga_strip.nim tests/t5_media_queries.nim tests/t6_qp.nim tests/t6_unsubscribe.nim tests/t6_assets.nim tests/t6_size.nim tests/t6_message_api.nim tests/t6_headers.nim tests/t7_stories.nim tests/t7_brief.nim"

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
build-tailwind:
    node tools/tailwind/build-tailwind.mjs

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

# Test: the full suite on the C backend, plus the backend-independent
# passes on the JS backend, plus the capture emulation-transform tests.
test: build-tailwind test-c test-js test-ts

# Test on the C backend (the default target).
test-c:
    @mkdir -p build/test-bin test-logs
    @for t in {{tests}}; do \
      echo "=== $t (c)"; \
      nim c {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/test-bin/$(basename $t .nim) --nimcache:build/nimcache-$(basename $t .nim) -r $t 2>&1 | tee test-logs/$(basename $t .nim)-c.log; \
    done

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
    @mkdir -p build/test-bin-js test-logs
    @for t in {{tests-js}}; do \
      echo "=== $t (js)"; \
      nim js {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/test-bin-js/$(basename $t .nim).js -r $t 2>&1 | tee test-logs/$(basename $t .nim)-js.log; \
    done

# Test the capture and review suites (emulation transforms,
# cache/affected/wiring suites, contact-sheet and findings suites):
# node:test with no runner to install.
# Quoted so node expands the globs (bare-directory discovery skips .ts).
test-ts:
    node --test "tools/capture/*.test.ts" "tools/capture/emulation/*.test.ts" "tools/review/*.test.ts"

# Build the story→MIME driver (pipeline step 1) and the
# review-brief driver (step 1b). Each rebuilds only
# when a Nim source is newer than its binary, so plain iterations
# stay fast; `just email-shots` and the e2e tests depend on this.
email-shots-build: build-tailwind
    @mkdir -p build/capture build/review test-logs
    @if [ -x build/capture/build-stories ] && [ -z "$(find src tools/capture tests/stories -name '*.nim' -newer build/capture/build-stories 2>/dev/null)" ]; then \
      echo "build/capture/build-stories up to date"; \
    else \
      nim c {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/capture/build-stories --nimcache:build/nimcache-build-stories tools/capture/build_stories.nim 2>&1 | tee test-logs/email-shots-build.log; \
    fi
    @if [ -x build/review/brief-driver ] && [ -z "$(find src tools/review tests/stories -name '*.nim' -newer build/review/brief-driver 2>/dev/null)" ]; then \
      echo "build/review/brief-driver up to date"; \
    else \
      nim c {{nim-flags}} {{src-paths}} {{tailwind-flags}} --out:build/review/brief-driver --nimcache:build/nimcache-brief-driver tools/review/brief_driver.nim 2>&1 | tee test-logs/brief-driver-build.log; \
    fi

# Backend-A email captures (backend A only, emulation transforms
# included). A bare run captures what changed (changed-only --affected default);
# --full captures the whole matrix.
email-shots *args: email-shots-build
    node tools/capture/email-shots.ts {{args}}

# CI regression checks (Tier-1 + Tier-2, Tier-3 record/gate).
# Captures the full story set on the pinned CI matrix (core families ×
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
# end-of-session approval (see tests/baselines/README.md).
email-capture-ci *args: email-shots-build
    out="build/email-capture-ci/$(date -u +%Y%m%dT%H%M%SZ)"; gate=""; echo " {{args}} " | grep -q " --assert " && gate="--assert" || true; node tools/capture/email-shots.ts --families apple,thunderbird,chromium-baseline --viewports mobile,desktop --schemes light --images on --full --no-cache $gate --out "$out" && node tools/capture/email-capture-ci.ts "$out" {{args}}

# Lint everything.
lint: lint-nim lint-ts lint-nix lint-markdown

# `nim check` over the library and every test. Check-only: never links,
# so no `--out:`/`--nimcache:` pair is needed here.
lint-nim:
    @mkdir -p test-logs
    nim check {{nim-flags}} {{src-paths}} {{tailwind-flags}} src/isonim_email.nim 2>&1 | tee test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} {{tailwind-flags}} tools/capture/build_stories.nim 2>&1 | tee -a test-logs/lint-nim.log
    nim check {{nim-flags}} {{src-paths}} {{tailwind-flags}} tools/review/brief_driver.nim 2>&1 | tee -a test-logs/lint-nim.log
    @for t in {{tests}}; do \
      echo "Checking $t"; \
      nim check {{nim-flags}} {{src-paths}} {{tailwind-flags}} $t 2>&1 | tee -a test-logs/lint-nim.log; \
    done

# Syntax gate for the capture CLI: --help parses the whole file
# (`node --check` cannot parse .ts type syntax on this Node), and
# importing each emulation module plus the contact-sheet,
# dom-assertions, perceptual, capture-ci, latency, launch and findings
# modules parses those too (cache/affected ride along transitively).
lint-ts:
    node tools/capture/email-shots.ts --help >/dev/null
    for m in tools/capture/emulation/*.ts; do case "$m" in *.test.ts) continue;; esac; node --input-type=module -e "await import('./$m')"; done
    node --input-type=module -e "await import('./tools/capture/contact_sheet.ts')"
    node --input-type=module -e "await import('./tools/capture/dom_assertions.ts')"
    node --input-type=module -e "await import('./tools/capture/perceptual.ts')"
    node --input-type=module -e "await import('./tools/capture/email-capture-ci.ts')"
    node --input-type=module -e "await import('./tools/capture/latency.ts')"
    node --input-type=module -e "await import('./tools/capture/launch.ts')"
    node --input-type=module -e "await import('./tools/review/findings.ts')"

lint-nix:
    nixfmt --check flake.nix

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
    nixfmt flake.nix

# Benchmarks placeholder: no benchmarks exist until the
# rendering pipeline they measure lands (after the components).
bench:
    @echo "isonim-email: no benchmarks yet (they land with the components)"

# Single-source-of-truth version bump: the nimble file owns the
# version; the umbrella const follows it.
bump-version version:
    sed -i 's/^version[[:space:]]*=.*/version       = "{{version}}"/' isonim_email.nimble
    sed -i 's/^const isonimEmailVersion\* = ".*"/const isonimEmailVersion* = "{{version}}"/' src/isonim_email.nim
