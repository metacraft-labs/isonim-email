## The billing page's script: the domain view `renderInvoiceSummary`
## (`invoice_summary.nim`) rendered by IsoNim's web renderer into the
## page's `<main id="invoice">` (`invoice_summary_page.html`). The
## invoice email renders the same view from the same source
## (`invoice_summary_email.nim`).
##
## Built with `nim js` (`just example-page-build`); the page's images
## sit beside it.
when not defined(js):
  {.error: "the billing page runs in the browser: build it with nim js".}

import isonim/web/dom_api
import isonim/web/web_renderer
import invoice_summary

let view = renderInvoiceSummary[WebRenderer, Element](WebRenderer(),
  sampleInvoice("mark-outlined.png", "mark-dark.png"))
discard appendChild(Node(document.getElementById("invoice")), Node(view))
