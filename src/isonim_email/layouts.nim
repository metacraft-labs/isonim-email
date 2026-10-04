## isonim_email/layouts.nim — the layouts (layout-patterns.md §4.8):
## templates for the common email types, each returning a whole
## `mailDocument` built only from patterns and primitives.
##
## - `transactionalLayout`: header, content slot, footer;
## - `receiptLayout`: summary, line items, totals, actions;
## - `securityCodeLayout`: a one-time code or magic link, and the
##   "didn't request this?" warning;
## - `alertLayout`: severity band, key facts, evidence, actions;
## - `digestLayout`: a hero, then repeated cards.

import ./target
import ./layouts/[frame, transactional, receipt, security_code, alert,
  digest]
export frame, transactional, receipt, security_code, alert, digest

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies
