## Reprobuild project file for isonim-email.
##
## **An IsoNim add-on-library CONSUMER (SC-11 develop-mode from-source
## sibling consumption).** ``isonim-email`` is the HTML-email library for
## IsoNim. Its ``src/isonim_email`` module tree consumes TWO landed
## workspace Nim-library producers from source at build time:
##
##   * ``isonim`` — the isomorphic reactive UI framework. The email
##     renderer satisfies its ``RendererBackend`` concept and the DSL
##     macros build the email tree. Producer: ``isonim/repro.nim`` →
##     ``library isonim`` (exported path ``src``).
##   * ``nim-everywhere`` — the cross-target platform seam isonim's
##     reactive core pulls in transitively. Producer:
##     ``nim-everywhere/repro.nim`` → ``library nim_everywhere``.
##
## The repo's ``config.nims`` / ``Justfile`` resolve these with hardcoded
## ``--path:../isonim/src --path:../nim-everywhere/src`` literals. This
## recipe expresses each the reprobuild-native way instead: ``uses:
## "<sibling>"`` names each PRODUCER project by its workspace directory
## name; reprobuild builds each from source (its ``library`` edge) and
## threads its ``src/`` root onto this repo's ``nim c --path:`` via the
## SC-11 ``nimPathDirs`` aux channel — replacing the hardcoded path
## literals. Editing a sibling's ``src/`` invalidates + rebuilds this
## repo's affected test compiles. Mirrors the landed consumer recipes
## ``isonim-tui/repro.nim`` + ``isonim-gpui/repro.nim``.
##
## Both siblings are in the AVAILABLE set (each ships a landed
## ``repro.nim`` with a ``library`` export), so this is proper SC-11
## develop-mode consumption — NOT a SKIP and NOT a hardcoded path.
##
## **Third-party deps (NOT ``uses:``).** isonim's reactive core
## transitively pulls in two status-im workspace source trees —
## ``../nim-faststreams`` and ``../nim-stew`` — exactly as isonim's own
## build resolves them. These are THIRD-PARTY upstreams (no ``repro.nim``
## ``library`` export), so they are NOT ``uses:`` sibling-from-source
## edges: they are threaded via each edge's ``paths:`` slot the way the
## repo's own ``config.nims`` treats them.
##
## A hybrid of reprobuild's layout-as-manifest convention (the ``src/``
## tree is the library) and a small hand-curated ``repro.nim``, modelled
## on the canonical Nim-consumer recipes ``isonim-tui/repro.nim`` +
## ``isonim-gpui/repro.nim`` and the leaf ``nim-pty/repro.nim`` two-edge
## test template:
##
## * Declares the toolchain floor via ``uses:`` (``nim`` + ``gcc``).
##   Mirrors the nimble file's ``requires "nim >= 2.0.0"``.
## * Declares ``library isonim_email`` — the importable ``src/`` tree, so
##   a downstream repo can consume this library via
##   ``uses: "isonim-email"``. The exported path is ``src`` (convention
##   default). The importable umbrella is ``src/isonim_email.nim``.
## * Emits, per test file in the ``Justfile`` ``tests`` list, a BUILD
##   edge (``buildNimUnittest.build``) that compiles
##   ``build/test-bin/<stem>`` and an EXECUTE edge
##   (``edge.testBinary.run``) that runs it — the two-edge test template
##   from the reprobuild package model.
##   BUILD halves collect into ``test-builds``; EXECUTE halves into
##   ``test`` so ``repro build test`` / ``repro test`` materialise the
##   runnable closure (each execute edge transitively depends on its
##   build edge).
##
## **Compile profile.** Each edge reproduces ``just test``: a plain
## ``nim c`` with this repo's default flags (no ``mm:`` pin — the corpus
## is backend-independent unit tests) plus the two Tailwind defines
## ``just test`` passes (the variant-preserving switch and the class-map
## override), fed by one ``node`` edge that builds that map.
## ``paths = @["src", "tests", "../nim-faststreams", "../nim-stew"]``
## supplies this repo's own two roots plus the two THIRD-PARTY status-im
## trees; the TWO sibling ``src`` roots (isonim / nim-everywhere) are
## threaded off the ``uses:`` ``nimPathDirs`` channel, not spelled here.
## The ``--styleCheck`` switches from ``nim-flags`` are style flags that
## don't affect the produced binary and aren't part of the typed
## ``nim c`` surface, so they're omitted — the engine compile is already
## hermetic and the corpus compiles + runs identically without them.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on the
## environment, so the weak-local PATH resolver is the right default. It
## is also required for the ``uses:`` declarations to resolve at all
## ("typed tool provisioning is required for uses declarations").

import std/os
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge and the ``edge.testBinary.run(...)``
# UFCS dispatch for the EXECUTE edges. Like the other consumer sibling recipes
# this file does NOT import ``ct_test_runner_install`` (engine-coupled,
# reprobuild-internal): the execute edges route through the engine's default
# direct-binary runner (run the binary, key on exit status), which is exactly
# the exit-0 verification this corpus needs — Nim ``unittest`` prints per-suite
# results and exits non-zero on failure.
import ct_test_nim_unittest

# Test stems — the ``Justfile`` ``tests`` list without the ``tests/`` prefix
# and ``.nim`` suffix. Every entry compiles + runs to exit 0 under ``nim c``.
const emailTestSpecs = @[
  "t1_plumbing",
  "t1_renderer_conformance",
  "t1_serializer_determinism",
  "t1_conditional_comments",
  "t1_no_hydration_residue",
  "t1_render_email",
  "t1_source_spans",
  "t1_rule_traceability",
  "t1_compile_fail",
  "t1_ir_restriction",
  "t2_vocabulary",
  "t2_vocabulary_compile_fail",
  "t2_tailwind_map",
  "t3_snapshot_reproducible",
  "t3_metrics_reproducible",
  "t3_icons_reproducible",
  "t3_lint_flex",
  "t3_lint_degradation",
  "t4_tokens",
  "t4_text_metrics",
  "t4_theme_snapshot",
  "t4_normalisation",
  "t4_head_css",
  "t4_class_names",
  "t4_styles",
  "t4_head_budget",
  "t5_document_golden",
  "t5_preheader",
  "t5_validate",
  "t5_a11y",
  "t5_lint_a11y",
  "t5_emc_top_five",
  "t5_pass_order",
  "t5_ganga_strip",
  "t5_media_queries",
  "t5_lower_elements",
  "t5_layout",
  "t5_scaffolding",
  "t5_columns",
  "t5_primitives",
  "t5_text",
  "t5_images",
  "t5_leaves",
  "t5_button",
  "t5_background",
  "t5_table",
  "t5_navigation",
  "t5_raw",
  "t5_text_checks",
  "t5_welcome_golden",
  "t5_dark",
  "t5_text_part",
  "t6_qp",
  "t6_unsubscribe",
  "t6_assets",
  "t6_crop",
  "t6_size",
  "t6_message_api",
  "t6_headers",
  "t6_header_fuzz",
  "t6_dot_stuff",
  "t6_mailgun",
  "t6_roundtrip",
  "t7_stories",
  "t7_brief",
  "t7_patterns",
  "t7_content_patterns",
  "t7_text_part_goldens",
  # WAIVER (2026-09-28): `repro test` is 76/80 — the 4 e2e EXECUTE actions
  # below fail ONLY under engine-monitored execution (`node: pthread_create:
  # Invalid argument` + browser launch failure; the io-monitor interposer
  # propagated to spawned node children is the proven single variable — the
  # same binaries pass direct, under `just test`, `repro exec`, parallel
  # shells, and with `--daemon=off` still failing identically). Proven
  # environmental engine defect, not a product failure: `just test` runs all
  # four green and CI gates (`just test`/`just lint`) never invoke
  # `repro test`, so CI is unaffected. No per-action recipe remedy exists
  # (no hosting/env knob in the action surface; depfile dodge rejected as
  # tracking-weakening). The defect is tracked upstream in reprobuild as
  # "repro daemon environment breaks node worker threads".
  "e2e_local_shots_latency",
  "e2e_local_capture_deterministic",
  "e2e_brief_diff_missing_element",
  "e2e_dom_assertions",
  # Added 2026-10-02: spawns node and the pinned Chromium like the four
  # above, so it is expected to meet the same engine defect; `repro test`
  # was not re-run for it.
  "e2e_local_columns",
  # Added with the layout primitives: spawns node and the pinned
  # Chromium like the e2e actions above (same expected engine defect;
  # `repro test` was not re-run for it).
  "e2e_local_primitives",
  # Added with the content leaves: spawns node and the pinned browsers
  # like the e2e actions above (same expected engine defect; `repro
  # test` was not re-run for it).
  "e2e_local_images_off",
  "e2e_local_text_edges",
  # Added with the dark-mode legibility check: spawns node and the
  # pinned Chromium like the e2e actions above (same expected engine
  # defect; `repro test` was not re-run for it).
  "e2e_local_dark_modes_legible",
]

package isonim_email:
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs. ``nim``
    # compiles every test binary (the ``buildNimUnittest.build`` edges below,
    # matching the nimble file's ``requires "nim >= 2.0.0"``); ``gcc`` is the
    # C back-end ``nim c`` shells out to and links through. Sufficient for
    # the path-mode resolver under ``nix develop``.
    "nim >=2.0"
    "gcc >=12"
    # ``node`` runs the Tailwind class-map extraction (the
    # ``isonim-email.tailwind_extract`` edge below); the Tailwind CLI it
    # drives is the dev shell's standalone ``tailwindcss`` on PATH.
    "node >=20"

    # The two landed sibling Nim-library producers this repo consumes from
    # source (SC-11 develop-mode). Naming each workspace project here makes
    # reprobuild build the sibling from source (its ``library`` edge) and
    # thread its ``src/`` root onto this repo's ``nim c --path:`` via the
    # ``nimPathDirs`` aux channel — replacing the ``config.nims`` /
    # ``Justfile`` hardcoded ``--path:../<repo>/src`` literals.
    "isonim"          # library isonim (reactive core + DSL + renderers)
    "nim-everywhere"  # library nim_everywhere (isonim's platform seam)

  # Library declaration — the ``src/`` tree is importable when this package
  # is consumed via ``uses: "isonim-email"``. The umbrella is
  # ``src/isonim_email.nim``; consumers may also import submodules under
  # ``src/isonim_email/`` directly. The exported path is ``src`` (default).
  library isonim_email

  build:
    # Two-edge test template: one
    # compile BUILD edge + one EXECUTE edge per test file. BUILD halves
    # collect into ``test-builds`` (compile verification); EXECUTE halves
    # into ``test`` so ``repro test`` / ``repro build test`` materialise the
    # runnable closure (each execute edge transitively depends on its build
    # edge).
    #
    # ``basePaths`` supplies this repo's own ``src`` + ``tests`` roots and
    # the two THIRD-PARTY status-im trees (``../nim-faststreams`` +
    # ``../nim-stew``). The TWO sibling ``src`` roots (isonim /
    # nim-everywhere) are threaded off the ``uses:`` ``nimPathDirs``
    # channel, NOT listed here.
    const basePaths = @["src", "tests", "../nim-faststreams", "../nim-stew"]

    # The Tailwind class map (``build/tailwind-styles.json``) that isonim's
    # ``dsl/tailwind.nim`` reads at compile time: the SAME map ``just test``
    # uses, produced by the same command (``just build-tailwind`` runs
    # ``node tools/tailwind/build-tailwind.mjs``) from this repo's content
    # only. Every test compile depends on it via ``after`` and names it as
    # an input, and gets the same two defines the Justfile / config.nims
    # give ``nim c``: the variant-preserving expansion switch and the map
    # override. The override must be absolute (``staticRead`` resolves a
    # relative path against isonim's own module directory), hence
    # ``currentSourcePath``.
    let tailwindMap = currentSourcePath().parentDir() / "build" /
      "tailwind-styles.json"
    let tailwindDefines = @["isonimTailwindVariants",
      "tailwindStylesPathOverride=" & tailwindMap]
    let tailwindEdge = node(
      args = @["tools/tailwind/build-tailwind.mjs"],
      actionId = "isonim-email.tailwind_extract",
      extraInputs = @["tools/tailwind/build-tailwind.mjs", "src", "tests",
        "../isonim/tools/tailwind-extract.mjs"],
      extraOutputs = @["build/tailwind-styles.json", "build/tailwind.css"])

    var testBuildActions: seq[BuildActionDef] = @[tailwindEdge]
    var testExecuteActions: seq[BuildActionDef] = @[]

    for stem in emailTestSpecs:
      let source = "tests/" & stem & ".nim"
      let binary = "build/test-bin/" & stem

      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        paths = basePaths,
        defines = tailwindDefines,
        actionId = "isonim-email.test_build." & stem,
        after = @[tailwindEdge],
        # ``src`` + the nimble file are declared inputs so the monitor tracks
        # the transitively imported ``src/isonim_email`` module tree; the
        # class map is read at compile time.
        extraInputs = @["src", "isonim_email.nimble",
          "build/tailwind-styles.json"])
      testBuildActions.add(edge.action)

      # ``registerImplicitName = false``: the BUILD edge already owns the
      # binary basename as the implicit target name; the explicit ``actionId``
      # is the execute edge's selector (two-edge shape).
      let executeEdge = edge.testBinary.run(
        actionId = "isonim-email.test_execute." & stem,
        registerImplicitName = false)
      testExecuteActions.add(executeEdge)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
