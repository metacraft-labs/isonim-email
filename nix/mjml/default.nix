# MJML, pinned for the Outlook-geometry conformance check
# (`just test-conformance`, tools/conformance/mjml_conformance.nim).
#
# nixpkgs does not package MJML, so it is built here from the npm
# registry tarballs named in package-lock.json: buildNpmPackage fetches
# every tarball the lock lists into a fixed-output derivation (the
# whole set pinned by npmDepsHash, each tarball by the lock's own
# sha512 integrity) and installs offline from that cache. Nothing is
# fetched when the check runs. To move the pin, change the version in
# package.json, regenerate package-lock.json (`npm install
# --package-lock-only --ignore-scripts`), and update npmDepsHash.
{ buildNpmPackage, nodejs_22 }:
buildNpmPackage {
  pname = "isonim-email-mjml";
  version = "5.4.1";
  src = ./.;
  nodejs = nodejs_22;
  npmDepsHash = "sha256-MI9fupmo9UMJzUr4AWG7Ji6b/+qru5+jPbh3NKNP/H4=";
  dontNpmBuild = true;
  npmFlags = [ "--ignore-scripts" ];
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/bin
    cp -r node_modules $out/lib/node_modules
    ln -s $out/lib/node_modules/mjml/bin/mjml $out/bin/mjml
    runHook postInstall
  '';
}
