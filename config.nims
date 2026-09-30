## Root nim config.nims — applies to every nim invocation in this repo
## (the compiler walks up from the compiled module looking for config.nims).
##
## Sibling-repo path switching, mirroring ../isonim-docs/config.nims.
## Toolchain and these repos are expected to come from this repo's own
## dev shell (`nix develop -c <cmd>`) — do not assume a global nim.
##
## NOTE on `$config`: it resolves to the directory holding THIS file (the
## repo root), unlike `$projectDir` (the compiled main file's directory),
## so these paths are stable across entry points at any depth.

# Local sources (so `import isonim_email/...` resolves from src/, tests/, …).
switch("path", "$config/src")

# Sibling isonim — the framework this library targets.
switch("path", "$config/../isonim/src")

# Sibling nim-everywhere — the cross-target platform seam isonim's
# reactive core pulls in transitively.
switch("path", "$config/../nim-everywhere/src")

# Transitive deps that isonim re-exports (see ../isonim/tests/config.nims
# for the same pattern).
switch("path", "$config/../nim-faststreams")
switch("path", "$config/../nim-stew")

# Sibling isonim-docs: isonim-email depends on
# the DTCG resolver (`core/tokens`) instead of moving it into isonim.
# The move is a three-repo change (isonim gains the module, isonim-docs
# re-points, this repo consumes) owned by the IsoNim maintainers; a
# partial move here would fork the resolver. Only `core/tokens` is
# imported (std-only, C- and JS-safe); the email mode/theme layer on top
# of it is `src/isonim_email/style/tokens.nim`.
switch("path", "$config/../isonim-docs/src")

# isonim's vendored chronicles/serialization (see ../isonim-docs/config.nims):
# `nimble install chronicles` is unreliable in this workspace, so isonim
# vendors them and consumers resolve them from the sibling checkout.
switch("path", "$config/../isonim/vendor/chronicles")
switch("path", "$config/../isonim/vendor/serialization")
switch("path", "$config/../isonim/vendor/json_serialization")

# Variant-preserving Tailwind: this repo's compiles expand classes in the
# opt-in variant-preserving mode. The style-map path itself is passed on
# the nim command line from the Justfile (`tailwind-flags`), not here: a
# strdefine value keeps `$config` literally in both config.nims and
# nim.cfg, and a relative path resolves inconsistently between
# `fileExists` and `staticRead` (verified 2026-09-27), so only an
# absolute command-line path loads the map reliably.
switch("define", "isonimTailwindVariants")
