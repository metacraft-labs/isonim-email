## isonim_email — HTML email for IsoNim.
##
## Public umbrella: importing this module is sufficient to author and render
## email templates. It re-exports the library surface (renderer, email IR,
## serialiser, static vocabulary, MSO wrappers) plus the framework pieces
## templates are written against: the renderer-mode `ui` macro, the
## reactive core (`createRoot`, `createSignal`, `createMemo`,
## `createRenderEffect`, …) and `AsyncState`.

import isonim_email/[renderer, ir, serialize, vocabulary, target, diagnostics,
  render]
import isonim_email/mso/cond
import isonim_email/mso/ghost
import isonim_email/lower/document
import isonim_email/lower/elements
import isonim_email/lower/image
import isonim_email/lower/section
import isonim_email/lower/wrapper
import isonim_email/lower/stack
import isonim_email/lower/box
import isonim_email/lower/grid
import isonim_email/lower/cluster
import isonim_email/lower/sidebar
import isonim_email/patterns
import isonim_email/primitives
import isonim_email/passes/layout
import isonim_email/support/[caniemail_data, families]
import isonim_email/passes/lint
import isonim_email/passes/styles
import isonim_email/passes/head
import isonim_email/passes/validate
import isonim_email/passes/a11y
import isonim_email/style/tokens
import isonim_email/style/metacraft_theme
import isonim_email/mime/model
import isonim_email/mime/headers
import isonim_email/mime/message
import isonim_email/mime/one_click
import isonim_email/assets
when not defined(js):
  import isonim_email/transport/smtp
  import isonim_email/transport/mailpit
  import isonim_email/transport/mailgun
import isonim_email/style/units
import isonim_email/style/colors
import isonim_email/style/shorthand
import isonim_email/style/css
import isonim_email/style/classes
import isonim_email/stories
import isonim_email/review/brief
import isonim/dsl/ui
import isonim/rxcore
import isonim/viewmodel

export renderer
export ir
export serialize
export vocabulary
export target
export diagnostics
export render
export cond
export ghost
export document
export elements
export image
export section
export wrapper
export stack
export box
export grid
export cluster
export sidebar
export patterns
export primitives
export layout
export caniemail_data
export families
export lint
export styles
export head
export validate
export a11y
export model
export headers
export message
export one_click
export assets
when not defined(js):
  export smtp
  export mailpit
  export mailgun
export tokens
export metacraft_theme
export units
export colors
export shorthand
export css
export classes
export stories
export brief
export ui
export rxcore
export viewmodel

const isonimEmailVersion* = "0.1.0"
  ## Library version. Single source of truth is `isonim_email.nimble`;
  ## `just bump-version` keeps the two in step.
