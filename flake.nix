{
  description = "isonim-email — HTML email for IsoNim (client-safe components, email renderer, style compilation, MIME packaging, visual verification)";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";

    # The sibling repositories the Nim code compiles against (the
    # Justfile's and config.nims' `../<repo>` paths), as plain sources
    # for the hermetic capture check (nix/capture-vm.nix), which builds
    # the story drivers in the sandbox. Each is pinned at the SHA its
    # .github/sibling-repos entry pins for CI, and the check refuses to
    # evaluate when the two disagree: a pin changes in both places.
    isonim = {
      url = "github:metacraft-labs/isonim/acf1bd345d6c4a25d82e1de3dccd924fff6fd21e";
      flake = false;
    };
    nim-everywhere = {
      url = "github:metacraft-labs/nim-everywhere/fee7a232a337ded10932366626962b9b869a228e";
      flake = false;
    };
    nim-faststreams = {
      url = "github:metacraft-labs/nim-faststreams/82c8c3edb5fa7a4fdfcdb5d8ab53bbe1830d4503";
      flake = false;
    };
    nim-stew = {
      url = "github:metacraft-labs/nim-stew/cc405401637dc7a32bea708374e26e33f6deca44";
      flake = false;
    };
    isonim-docs = {
      url = "github:metacraft-labs/isonim-docs/4719b9820004fda250bc272877bd579e419b4783";
      flake = false;
    };
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
        {
          pkgs,
          config,
          system,
          ...
        }:
        let
          # Type definitions for `just lint-ts` (tsc over tools/**/*.ts),
          # assembled as a node_modules tree without any npm install:
          # the Node API declarations are fixed-output fetches of the
          # registry tarballs, pinned by the registry's own sha512
          # integrity, and Playwright's declarations are the ones
          # shipped inside the very playwright-driver the captures run
          # (so the checked API is the driven API). The Justfile links
          # build/ts-types to this path; tsconfig.json resolves from
          # there. @types/node tracks the dev shell's Node 22 line.
          nodeTypes = pkgs.fetchurl {
            url = "https://registry.npmjs.org/@types/node/-/node-22.20.4.tgz";
            hash = "sha512-zJRE40jpHtKqE/C4fgHrAKQLJuSpzEnP9ff9Y7YtoR3Wd2pwqzlekDeEuUQXjRd+QCYnVnNwuJYmhdk9XV8gvA==";
          };
          # @types/node's one dependency (the fetch/undici declarations).
          undiciTypes = pkgs.fetchurl {
            url = "https://registry.npmjs.org/undici-types/-/undici-types-6.21.0.tgz";
            hash = "sha512-iwDZqg0QAGrg9Rav5H4n0M64c3mkR59cJ6wQp+7C4nI0gsmExaedaYLNO44eT4AtBBwjbTiGPMlt2Md0T9H9JQ==";
          };
          tsTypes = pkgs.runCommand "isonim-email-ts-types" { } ''
            mkdir -p $out/node_modules/@types/node $out/node_modules/undici-types
            tar -xzf ${nodeTypes} -C $out/node_modules/@types/node --strip-components=1
            tar -xzf ${undiciTypes} -C $out/node_modules/undici-types --strip-components=1
            ln -s ${pkgs.playwright-driver} $out/node_modules/playwright-core
          '';
          # MJML, pinned (nix/mjml/), for `just test-conformance`:
          # the Outlook geometry this library emits is checked against
          # MJML's. Built from the lockfile's registry tarballs in a
          # fixed-output derivation; the check never fetches anything.
          mjml = pkgs.callPackage ./nix/mjml { };
          # The linux-desktop provider's accessibility client: Python
          # with PyGObject and the AT-SPI typelib, run outside the
          # capture session against the session's own accessibility bus
          # (tools/capture/providers/atspi_helper.py). One command, so the
          # typelib search path cannot be lost on the way.
          atspiPython = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
          atspiHelper = pkgs.writeShellScriptBin "isonim-email-atspi" ''
            export GI_TYPELIB_PATH=${
              pkgs.lib.makeSearchPath "lib/girepository-1.0" [
                pkgs.at-spi2-core
                pkgs.glib.out
                pkgs.gobject-introspection
              ]
            }
            exec ${atspiPython}/bin/python3 "$@"
          '';
          # The desktop clients' helper daemons, by name on PATH: the
          # accessibility bus launcher (at-spi2-core), Evolution's source
          # registry (evolution-data-server) and the keyring daemon whose
          # Secret Service Geary and KMail's IMAP resource require. Only
          # these binaries are linked, so nothing else of those packages
          # shadows the host's tools.
          desktopDaemons = pkgs.runCommand "isonim-email-desktop-daemons" { } ''
            mkdir -p $out/bin
            ln -s ${pkgs.at-spi2-core}/libexec/at-spi-bus-launcher $out/bin/at-spi-bus-launcher
            ln -s ${pkgs.evolution-data-server}/libexec/evolution-source-registry $out/bin/evolution-source-registry
            ln -s ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon $out/bin/gnome-keyring-daemon
          '';
          # KMail and Akonadi are not wrapped in nixpkgs (a Plasma session
          # provides the Qt plugin, QML and data paths); this wrapper
          # provides them from the closure of KMail, Akonadi, the PIM
          # runtime (the IMAP and maildir resources), the Wayland platform
          # plugin, Breeze (the colour schemes) and the KDE platform theme
          # (which reports a dark colour scheme to Qt, and so to
          # QtWebEngine's prefers-color-scheme): `isonim-email-kde CMD
          # ARGS…` runs CMD with them. Akonadi's agents inherit it.
          kdeMail = with pkgs.kdePackages; [
            kmail
            akonadi
            kdepim-runtime
            qtwayland
            breeze
            plasma-integration
          ];
          kdeMailClosure = pkgs.closureInfo { rootPaths = kdeMail; };
          kdeMailEnv = pkgs.runCommand "isonim-email-kde" { } ''
            qp=""; qml=""; xdg=""
            for p in $(cat ${kdeMailClosure}/store-paths); do
              if [ -d "$p/lib/qt-6/plugins" ]; then qp="$qp''${qp:+:}$p/lib/qt-6/plugins"; fi
              if [ -d "$p/lib/qt-6/qml" ]; then qml="$qml''${qml:+:}$p/lib/qt-6/qml"; fi
              if [ -d "$p/share" ]; then xdg="$xdg''${xdg:+:}$p/share"; fi
            done
            mkdir -p $out/bin
            {
              echo '#!${pkgs.runtimeShell}'
              echo "export QT_PLUGIN_PATH='$qp'"
              echo "export QML2_IMPORT_PATH='$qml'"
              echo "export XDG_DATA_DIRS='$xdg'\''${XDG_DATA_DIRS:+:\$XDG_DATA_DIRS}"
              echo "export PATH='${pkgs.lib.makeBinPath kdeMail}'\''${PATH:+:\$PATH}"
              echo 'exec "$@"'
            } > $out/bin/isonim-email-kde
            chmod +x $out/bin/isonim-email-kde
          '';

          # What a capture run needs at run time: the tools the providers
          # find on PATH and the variables that locate the pinned browsers,
          # fonts, webmail trees and locales. The dev shell and the
          # hermetic VM check (nix/capture-vm.nix) both use these two, so
          # the VM runs the providers with the very store paths the host's
          # captures use.
          captureTools =
            with pkgs;
            [
              # Node, the Playwright browsers and Mailpit.
              nodejs_22
              playwright-driver
              mailpit
              # The capture harness's `imap` service: Dovecot run as
              # the current user on loopback (dovecot -F, doveadm save),
              # holding the one-message mailboxes real clients open.
              dovecot
              # The selfhosted-webmail capture provider: Roundcube and
              # SnappyMail (located through the variables in captureEnv)
              # on php-fpm behind caddy, run as the current user on
              # loopback. nixpkgs' default php carries every extension
              # both need (pdo_sqlite, mbstring, intl, dom, curl,
              # sodium, zip).
              php
              caddy
              # fc-list for inspecting the pinned font set below
              # (also used by tests/e2e_local_capture_deterministic.nim).
              fontconfig
              # The independent RFC 2047 / MIME oracle for the header
              # fuzz test (Python's `email` package, stdlib only).
              python3
            ]
            # `setpriv --pdeathsig` (util-linux) starts the imap
            # service's Dovecot and the webmail's caddy so that they die
            # with the capture run even when the run is killed with
            # SIGKILL; `unshare --pid --kill-child` gives php-fpm a PID
            # namespace of its own, so its forked workers die with it
            # too. iproute2's `ip` brings loopback up in the network
            # namespace a desktop-client session runs in (loopback
            # only), and util-linux's `mount` sets up the session's own
            # name resolution in its mount namespace. `setsid` gives each
            # of `just test`'s concurrent recipes a session and process
            # group of its own (tools/test/run-recipes.sh), so a
            # timed-out recipe is killed whole. Only these five
            # binaries are put on PATH, so util-linux's and iproute2's
            # other tools do not shadow the host's.
            ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              (pkgs.runCommand "setpriv-unshare" { } ''
                mkdir -p $out/bin
                ln -s ${pkgs.util-linux}/bin/setpriv $out/bin/setpriv
                ln -s ${pkgs.util-linux}/bin/unshare $out/bin/unshare
                ln -s ${pkgs.iproute2}/bin/ip $out/bin/ip
                ln -s ${pkgs.util-linux}/bin/mount $out/bin/mount
                ln -s ${pkgs.util-linux}/bin/setsid $out/bin/setsid
              '')
              # The linux-desktop capture provider: real mail clients in
              # a headless sway (wlroots' headless backend and its
              # software renderer, no GPU), each instance with a private
              # D-Bus session bus (dbus-run-session); grim captures the
              # output, wtype types into it, swaymsg drives it.
              pkgs.sway
              pkgs.grim
              pkgs.wtype
              pkgs.dbus
              pkgs.thunderbird
              # The other desktop clients (verification clients):
              # Evolution and Geary (WebKitGTK), KMail with Akonadi on
              # SQLite (QtWebEngine; through the isonim-email-kde
              # wrapper above) and Claws Mail (its litehtml viewer),
              # with the helper daemons and the accessibility client
              # their drivers use. getent checks the sessions' name
              # resolution in the tests.
              pkgs.evolution
              pkgs.geary
              pkgs.claws-mail
              desktopDaemons
              kdeMailEnv
              atspiHelper
              pkgs.getent
              # OCR for the desktop end-to-end tests: the capture of a
              # story must show the story's own heading. English only
              # (the full language set is about ten times larger).
              (pkgs.tesseract.override { enableLanguages = [ "eng" ]; })
            ];

          captureEnv = {
            # The webmail trees the selfhosted-webmail provider serves
            # (read-only store paths; configs and data are generated per
            # run under build/).
            ISONIM_EMAIL_ROUNDCUBE = "${pkgs.roundcube}";
            ISONIM_EMAIL_SNAPPYMAIL = "${pkgs.snappymail}";

            # Breeze's colour schemes, which the KMail driver writes into
            # the session's kdeglobals (as applying a scheme does).
            ISONIM_EMAIL_KDE_COLOR_SCHEMES =
              if pkgs.stdenv.hostPlatform.isLinux then "${pkgs.kdePackages.breeze}/share/color-schemes" else "";

            # The locale archive the desktop clients run with (a fixed
            # en_US.UTF-8, whatever the host's locale): the provider
            # passes <dir>/locale-archive as LOCALE_ARCHIVE to the client
            # only. glibc locales exist on Linux alone, as does the
            # provider; elsewhere this names nothing and the provider is
            # unavailable.
            ISONIM_EMAIL_LOCALES =
              if pkgs.stdenv.hostPlatform.isLinux then "${pkgs.glibcLocales}/lib/locale" else "";

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
          };

          # The sibling pins CI clones (.github/sibling-repos:
          # `<repo>=<40-hex sha>  # comment` lines).
          siblingPins = builtins.listToAttrs (
            map
              (
                line:
                let
                  m = builtins.match "([A-Za-z0-9_.-]+)=([0-9a-f]{40}).*" line;
                in
                {
                  name = builtins.elemAt m 0;
                  value = builtins.elemAt m 1;
                }
              )
              (
                builtins.filter (line: builtins.match "[A-Za-z0-9_.-]+=[0-9a-f]{40}.*" line != null) (
                  pkgs.lib.splitString "\n" (builtins.readFile ./.github/sibling-repos)
                )
              )
          );
          captureVm = import ./nix/capture-vm.nix {
            inherit
              pkgs
              captureTools
              captureEnv
              siblingPins
              ;
            inherit (pkgs) lib;
            src = ./.;
            siblings = {
              inherit (inputs)
                isonim
                nim-everywhere
                nim-faststreams
                nim-stew
                isonim-docs
                ;
            };
          };
        in
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

          devShells.default = pkgs.mkShell (
            captureEnv
            // {
              inputsFrom = [ config.pre-commit.devShell ];
              packages =
                with pkgs;
                [
                  nim
                  nimble
                  just
                  git
                  nixfmt
                  # The Tailwind v4 CLI for `just build-tailwind`: the
                  # standalone build, which bundles the `tailwindcss`
                  # stylesheet itself, so the extraction needs no
                  # node_modules here or in the isonim checkout.
                  tailwindcss_4
                  # Markdown linting (`just lint-markdown`).
                  markdownlint-cli2
                  # The type checker for tools/**/*.ts (`just lint-ts`);
                  # its declarations come from tsTypes above.
                  typescript
                ]
                # Node, the Playwright browsers, the local mail stack and
                # the desktop clients (see captureTools above).
                ++ captureTools;

              # tsc's declaration tree (see tsTypes); `just lint-ts`
              # links build/ts-types to it.
              ISONIM_EMAIL_TS_TYPES = "${tsTypes}";

              # The pinned MJML CLI `just test-conformance` compiles the
              # conformance fixtures with (see mjml above).
              ISONIM_EMAIL_MJML = "${mjml}/bin/mjml";

              shellHook = ''
                echo "isonim-email dev shell — nim $(nim --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'), node $(node --version)"
              ''
              + config.mcl.gitHooks.installationScript;
            }
          );

          # The hermetic capture check (nix/capture-vm.nix): the capture
          # providers in a NixOS VM, checked against the committed
          # baselines. x86_64-linux only, the system those baselines are
          # pinned to (a macOS developer builds it on a Linux builder).
          checks = pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            capture-linux-desktop = captureVm.check;
          };
          packages = {
            default = pkgs.stdenvNoCC.mkDerivation {
              pname = "isonim-email";
              version = "0.1.0";
              src = ./.;
              installPhase = ''
                mkdir -p $out
                cp -R src isonim_email.nimble README.md LICENSE $out/
              '';
            };
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            # The story and brief drivers as the capture check builds them.
            capture-drivers = captureVm.drivers;
          };
        };
    };
}
