{
  description = "isonim-email — HTML email for IsoNim (client-safe components, email renderer, style compilation, MIME packaging, visual verification)";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{ flake-parts, nixos-modules, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        nixos-modules.modules.flake.git-hooks
      ];

      # The Apache-2.0 boilerplate's fixed indentation is not ours to
      # reformat; keep editorconfig-checker off it (declared through the
      # option like any other consumer's exclusion). The vendored
      # caniemail payload joins it: its bytes are upstream's, pinned by
      # sha256 (tools/support-snapshot/snapshot.pin.json), so no
      # whitespace linter may touch them either — as do the three
      # vendored design-system payloads (tools/theme-snapshot/
      # brand|alias|mapped.json, sha-pinned by theme.pin.json). The
      # Golden skeletons join them: byte-exact serialiser output
      # pinned by tests/t5_document_golden.nim, so no rewriting or
      # whitespace hook may touch tests/golden/ either.
      mcl.gitHooks.editorconfigExcludes = [
        "^LICENSE$"
        "^tools/support-snapshot/caniemail-data.json$"
        "^tools/theme-snapshot/(brand|alias|mapped).json$"
        # Golden skeletons: byte-exact serialiser output (no trailing
        # newline by construction), pinned by tests/t5_document_golden.nim.
        "^tests/golden/"
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          # The mcl-standard-hooks set (large-file ban, .ct ban, hygiene)
          # is installed by the imported git-hooks module, adopted BY NAME
          # per the repo requirements. The two entries below are the
          # per-repo hooks, which are per-repo by nature and therefore not
          # in the shared set: `just lint` and the license check.
          pre-commit.settings.hooks = {
            # The vendored caniemail payload's bytes are upstream's,
            # pinned by sha256 (see snapshot.pin.json): the rewriting
            # hooks must never touch it. (editorconfig-checker takes
            # the same path through mcl.gitHooks.editorconfigExcludes
            # above; the shared set offers no option for these two, so
            # the native per-hook field carries them.) The theme
            # payloads join it for the same reason (vendored verbatim,
            # sha-pinned by theme.pin.json), plus mapping.json: the
            # snapshot test does exact-string surgery on its bytes, so
            # a reflow would silently break the malformed-input cases.
            end-of-file-fixer.excludes = [
              "^tools/support-snapshot/caniemail-data.json$"
              "^tools/theme-snapshot/(brand|alias|mapped|mapping).json$"
              "^tests/golden/"
            ];
            # prettier additionally skips:
            # * docs/rendering-rules.md: the rules catalogue. Its
            #   document-skeleton block is the byte-exact reference the
            #   library reproduces (mso/document.nim), and the rule
            #   tables are parsed by the traceability test; a reflow
            #   (table padding, HTML-block rewrapping) would change
            #   bytes the catalogue guarantees.
            # * the two agent-instruction symlinks to AGENTS.md: prettier
            #   refuses explicitly named symlinks with an error, which
            #   fails the hook; AGENTS.md itself is still formatted.
            prettier.excludes = [
              "^tools/support-snapshot/caniemail-data.json$"
              "^tools/theme-snapshot/(brand|alias|mapped|mapping).json$"
              "^tests/golden/"
              "^docs/rendering-rules\\.md$"
              "^\\.agents/AGENTS\\.md$"
              "^\\.github/copilot-instructions\\.md$"
            ];
            lint = {
              enable = true;
              name = "just lint";
              entry = "just lint";
              language = "system";
              pass_filenames = false;
            };
            check-license = {
              enable = true;
              name = "Check License File";
              entry = "bash -c 'if [ ! -f LICENSE ] && [ ! -f LICENSE-APACHE ] && [ ! -f LICENSE-MIT ]; then echo \"Error: No license file (LICENSE, LICENSE-APACHE, LICENSE-MIT) found in repository root!\"; exit 1; fi'";
              files = "^$";
              pass_filenames = false;
              # `files = \"^$\"` matches nothing, so without this prek
              # reports "(no files to check) Skipped" and the check never
              # runs. `always_run` makes it run once per invocation.
              always_run = true;
            };
          };

          devShells.default = pkgs.mkShell {
            inputsFrom = [ config.pre-commit.devShell ];
            packages = with pkgs; [
              nim
              nimble
              just
              git
              nixfmt
              # Dev-shell tooling: Nim, Node,
              # Playwright browsers, Mailpit. (Dovecot, mjml, axe-core
              # and fonttools arrive with the work that uses them;
              # the pinned fonts are pinned below.)
              nodejs_22
              # The Tailwind v4 CLI for `just build-tailwind`: the
              # standalone build, which bundles the `tailwindcss`
              # stylesheet itself, so the extraction needs no
              # node_modules here or in the isonim checkout.
              tailwindcss_4
              playwright-driver
              mailpit
              # fc-list for inspecting the pinned font set below
              # (also used by tests/e2e_local_capture_deterministic.nim).
              fontconfig
              # Markdown linting (`just lint-markdown`).
              markdownlint-cli2
            ];

            # Playwright must use the Nix-provided browsers, never download.
            PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
            PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
            # Capture CLI: the playwright-core node module matching
            # those browsers (same package, so the revisions agree).
            PLAYWRIGHT_CORE_PATH = "${pkgs.playwright-driver}";
            # Pinned fonts: fontconfig
            # sees ONLY these store paths, so captures render identical
            # text on every host. impureFontDirectories/includes are
            # emptied to exclude host /usr/share/fonts and
            # /etc/fonts/conf.d; makeFontsConf still appends
            # dejavu_fonts.minimal, which is nixpkgs-pinned and therefore
            # deterministic too (recorded, not fought).
            FONTCONFIG_FILE = "${pkgs.makeFontsConf {
              fontDirectories = with pkgs; [
                liberation_ttf
                carlito
                roboto
                noto-fonts
              ];
              impureFontDirectories = [ ];
              includes = [ ];
            }}";

            shellHook = ''
              echo "isonim-email dev shell — nim $(nim --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'), node $(node --version)"
            ''
            + config.mcl.gitHooks.installationScript;
          };

          packages.default = pkgs.stdenvNoCC.mkDerivation {
            pname = "isonim-email";
            version = "0.1.0";
            src = ./.;
            installPhase = ''
              mkdir -p $out
              cp -R src isonim_email.nimble README.md LICENSE $out/
            '';
          };
        };
    };
}
