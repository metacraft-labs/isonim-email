## isonim_email/content.nim — the content patterns (layout-patterns.md
## §4), each defined with `defineMailPattern` in a module of its own
## group: the structure patterns (`content/structure.nim`) and the hero
## and media patterns (`content/media.nim`). Importing this module
## registers them all (`render.nim`, `stories.nim` and
## `review/brief.nim` import it for that, hence `{.used.}`).

{.used.}

import ./target
import ./content/[kit, structure, media]
export kit, structure, media

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = allFamilies
