# The hermetic capture check: the capture providers run inside a NixOS VM
# (`nix build .#checks.x86_64-linux.capture-linux-desktop`, or
# `just test-vm`).
#
# What it builds:
#
# * `drivers`: the story driver (build/capture/build-stories) and the
#   review-brief driver (build/review/brief-driver), compiled in the Nix
#   sandbox by the Justfile's own `email-shots-build` recipe, against the
#   sibling repositories pinned as flake inputs (the same SHAs
#   .github/sibling-repos pins for CI; see `siblings` below). The
#   checkout layout the Justfile and config.nims expect (`../isonim`, …)
#   is rebuilt in the build directory from those inputs.
# * `check`: a NixOS VM (pkgs.testers.runNixOSTest) with no network,
#   holding the same capture tools and variables as the dev shell
#   (`captureTools`, `captureEnv` in flake.nix: the very store paths the
#   host's captures use). As an unprivileged user it copies this
#   repository into a writable directory, installs the prebuilt drivers
#   (ISONIM_EMAIL_PREBUILT_DRIVERS), and runs:
#     1. `just email-capture-ci`: backend a's regression matrix over every
#        story, checked against the committed baselines (the canary's
#        exact hashes and every story's perceptual threshold);
#     2. `just email-shots` on the canary story in the real clients: the
#        linux-desktop provider and the selfhosted-webmail provider,
#        through the local mail stack (Dovecot and the assets service),
#        gated on every capture succeeding.
#   The run directories (PNGs, provenance, logs) are copied out as the
#   check's output, and the check fails if either step failed.
{
  pkgs,
  lib,
  src,
  siblings,
  siblingPins,
  captureTools,
  captureEnv,
}:
let
  # A sibling input whose locked revision differs from the pin CI clones
  # would compile the drivers against different sources than CI and the
  # host checkout layout do; refuse to evaluate rather than build that.
  checkedSiblings = lib.mapAttrs (
    name: input:
    let
      pinned = siblingPins.${name} or null;
    in
    if pinned == null then
      throw "capture-vm: .github/sibling-repos does not pin ${name}"
    else if input.rev != pinned then
      throw "capture-vm: flake.lock locks ${name} at ${input.rev}, but .github/sibling-repos pins ${pinned}; pin the `${name}` input in flake.nix at the same SHA (flake.lock follows the URL), or fix the pin"
    else
      input
  ) siblings;

  # Only what the two drivers are compiled from (and the Tailwind map's
  # content globs read): editing a TypeScript tool, a baseline or a
  # document does not rebuild them.
  driverSrc = lib.fileset.toSource {
    root = src;
    fileset = lib.fileset.unions [
      (src + "/src")
      # The Tailwind map's content globs read tests/**/*.nim; the stories
      # compile their fixture images in. Not the baselines or goldens.
      (lib.fileset.fileFilter (file: file.hasExt "nim") (src + "/tests"))
      (src + "/tests/stories")
      (src + "/tools/capture/build_stories.nim")
      (src + "/tools/review/brief_driver.nim")
      (src + "/tools/tailwind")
      (src + "/config.nims")
      (src + "/Justfile")
      (src + "/isonim_email.nimble")
    ];
  };

  drivers = pkgs.stdenv.mkDerivation {
    pname = "isonim-email-capture-drivers";
    version = "0.1.0";
    src = driverSrc;
    nativeBuildInputs = with pkgs; [
      nim
      just
      nodejs_22
      tailwindcss_4
      findutils
    ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      export HOME="$NIX_BUILD_TOP/home"
      ws="$NIX_BUILD_TOP/ws"
      mkdir -p "$HOME" "$ws"
      cp -r . "$ws/isonim-email"
      chmod -R u+w "$ws/isonim-email"
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: input: ''ln -s ${input} "$ws/${name}"'') checkedSiblings
      )}
      cd "$ws/isonim-email"
      just email-shots-build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 build/capture/build-stories "$out/bin/build-stories"
      install -Dm755 build/review/brief-driver "$out/bin/brief-driver"
      runHook postInstall
    '';
  };

  # Runs inside the VM, as the unprivileged user: copies the repository,
  # runs the two steps, records each one's exit status and output under
  # OUT. Never stops early, so every step's output is copied out even
  # when an earlier one failed.
  runner = pkgs.writeShellApplication {
    name = "isonim-email-capture-vm";
    runtimeInputs = captureTools ++ [
      pkgs.just
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.bash
    ];
    # Each step's status is recorded, not acted on.
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text = ''
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") captureEnv
      )}
      export ISONIM_EMAIL_PREBUILT_DRIVERS=${drivers}/bin
      out="$1"
      work="$HOME/isonim-email"
      mkdir -p "$out"
      cp -rT ${src} "$work"
      chmod -R u+w "$work"
      cd "$work" || exit 1

      step() {
        local name="$1"
        shift
        local t0
        t0=$(date +%s)
        echo "capture-vm: $name: $*"
        "$@" >"$out/$name.log" 2>&1
        local status=$?
        echo "$status" >"$out/$name.status"
        echo "capture-vm: $name: exit $status in $(($(date +%s) - t0)) s"
        tail -n 40 "$out/$name.log"
      }

      # 1. backend a's regression matrix and its Tier-1/Tier-2 checks.
      step capture-ci just email-capture-ci
      # 2. the canary in the real clients of the two local providers.
      step real-clients just email-shots \
        --backends linux-desktop,selfhosted-webmail \
        --clients thunderbird,claws-mail,roundcube,snappymail \
        --schemes light --full --no-cache \
        --out "$work/build/email-shots/vm-real-clients" canary

      # The run directories, PNGs and provenance included.
      cp -r build/email-capture-ci "$out/email-capture-ci" || true
      cp -r build/email-shots/vm-real-clients "$out/real-clients" || true
      find "$out" -name '*.png' -path '*canary*' -exec sha256sum {} + | sed "s|$out/||" | sort -k2
    '';
  };

  check = pkgs.testers.runNixOSTest {
    name = "capture-linux-desktop";
    nodes.machine = {
      virtualisation = {
        memorySize = 8192;
        cores = 8;
        diskSize = 4096;
      };
      users.users.capture = {
        isNormalUser = true;
        uid = 1000;
      };
      environment.systemPackages = [ runner ];
    };
    testScript = ''
      import json

      machine.wait_for_unit("multi-user.target")
      out = "/tmp/capture-vm"
      machine.succeed(f"install -d -o capture {out}")
      status, output = machine.execute(
          f"runuser -u capture -- isonim-email-capture-vm {out} 2>&1",
          timeout=3600,
      )
      print(output)
      machine.copy_from_machine(out, "")
      statuses = {}
      for step in ["capture-ci", "real-clients"]:
          statuses[step] = machine.succeed(f"cat {out}/{step}.status").strip()
      failed = [s for s, v in statuses.items() if v != "0"]
      assert status == 0, f"the capture runner itself exited {status}"
      assert not failed, (
          "capture steps failed (each step's output is printed above): "
          + ", ".join(f"{s} (exit {statuses[s]})" for s in failed)
      )
      # The real clients' captures, each of which must be done: a client
      # that drops out of the matrix (its provider unavailable, so its
      # requests are never routed) fails here, not only a failed capture.
      expected = {
          ("linux-desktop", "thunderbird", "desktop"),
          ("linux-desktop", "claws-mail", "desktop"),
          ("selfhosted-webmail", "roundcube", "desktop"),
          ("selfhosted-webmail", "roundcube", "mobile"),
          ("selfhosted-webmail", "snappymail", "desktop"),
          ("selfhosted-webmail", "snappymail", "mobile"),
      }
      index = json.loads(machine.succeed(f"cat {out}/real-clients/index.json"))
      done = {
          (e["backend"], e["client"], e["viewport"])
          for e in index
          if e["story"] == "canary" and e["status"] == "done"
      }
      missing = sorted(expected - done)
      assert not missing, f"real-client captures not done: {missing}"
    '';
  };
in
{
  inherit drivers check runner;
}
