## Seed builders → registry stories.
##
## Wraps the seed builders (`seed_receipt`, `seed_alert`) as `Story`
## entries sharing the seeds' growth rule: when the reference
## template set lands, these wrappers retire with the builders.
## Imported by the capture driver and the story tests alike, so both
## register exactly the same set.
import isonim_email
import seed_receipt
import seed_alert
import seed_overflow
import seed_sanitiser_probe

const receiptText = "Receipt #1234\n\nThanks for your order.\n\n" &
  "Widget: $10.00\n"
  ## Fixed plain-text alternative for the receipt seed (the plain-text
  ## generator will produce these; the content mirrors the seed's
  ## title, preheader and line item).

const alertText = "تنبيه أمني\n\nتم رصد تسجيل دخول جديد.\n\n" &
  "تسجيل دخول من جهاز جديد.\n"
  ## Fixed plain-text alternative for the alert seed.

proc renderReceipt*(): StoryHtml =
  ## The receipt seed through the current pipeline.
  (renderPipeline(seedReceipt(), defaultTarget()), receiptText)

proc renderAlert*(): StoryHtml =
  ## The alert seed through the current pipeline.
  (renderPipeline(seedAlert(), defaultTarget()), alertText)

proc receiptStory*(): Story =
  ## The receipt seed as a registry entry.
  Story(name: "receipt", group: "receipt",
    description: "Minimal receipt (LTR).", render: renderReceipt)

proc alertStory*(): Story =
  ## The alert seed as a registry entry.
  Story(name: "alert", group: "alert",
    description: "Minimal RTL alert.", render: renderAlert)

proc registerSeedStories*() =
  ## Registers the full seed set: canary + both seeds.
  registerStory(canaryStory())
  registerStory(receiptStory())
  registerStory(alertStory())

proc registerOverflowStories*() =
  ## Registers the Tier-3 fixture twins (env-gated, never in
  ## bare runs — see seed_overflow.nim).
  registerStory(Story(name: "overflowFixed", group: "overflow",
    description: "Tier-3 fixture: fixed 700px table.",
    render: renderOverflowFixed))
  registerStory(Story(name: "overflowFluid", group: "overflow",
    description: "Tier-3 fixture: fluid twin (passes).",
    render: renderOverflowFluid))

proc registerSanitiserProbeStory*() =
  ## Registers the webmail sanitiser probe (env-gated, never in bare
  ## runs — see seed_sanitiser_probe.nim).
  registerStory(Story(name: "sanitiserProbe", group: "sanitiserProbe",
    description: "Capture fixture: head CSS under a webmail sanitiser.",
    render: renderSanitiserProbe))
