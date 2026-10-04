## Markdown body stories: the story set of `mailMarkdown`
## (layout-patterns.md §5): `Minimal` (a paragraph), `Maximal` (every
## construct it reads, long unbroken words and a long URL), `Rtl`
## (Arabic), `ImagesOff` (a body with an image, captured with images
## blocked), `Dark` (`darkMode = designed`) and `InContext` (between a
## callout and a button group).
##
## The image is the compile-time `photo-lake.png` placeholder.
##
## Env-gated like the other element sets: the drivers register them only
## under `ISONIM_CAPTURE_LAYOUT=1`.
##
## Backend-independent (tree building only), like the seed builders.
import isonim_email
import story_kit

let lake = $asset"assets/photo-lake.png"

proc intro(r: EmailRenderer; doc: EmailNode; title, body: string) =
  let s = r.band(doc, padding = "24px 0 8px")
  discard r.el(s, "h1", text = title)
  if body.len > 0:
    discard r.el(s, "p", [("margin", "0")], text = body)

proc markdown(r: EmailRenderer; parent: EmailNode; src: string;
    attrs: openArray[(string, string)] = []): EmailNode =
  r.el(parent, "mailMarkdown", attrs = @[("src", src), ("heading_offset",
    "1")] & @attrs)

const maximalBody = """
# Everything a body can hold

A paragraph with **strong**, *emphasis*, ***both***, ~~struck~~ text,
`inline code`, a [link](https://example.com/docs "The docs") and an
autolink: <https://example.com/a/very/long/path/that/keeps/going/and/going/without/a/single/space/in/it>.
A word that never breaks: """ & longWord & """.
Hard break here\
and the next line.

Second level
------------

- A bullet
- Another, with `code`

1. First
2. Second

```
for i in 0 ..< 3:
  echo "line ", i, " of a code block whose line is long enough to wrap"
```

> A quotation, read as Markdown again: *emphasis* inside.

***

| Plan | Seats | Price |
|---|---|---|
| Hobby | 1 | Free |
| Team | 5 | **$20** |

:::note
An admonition becomes a callout.
:::

:::button href="https://example.com/start"
Get started
:::
"""

proc markdownMinimalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Your report is ready", "A Markdown body of one " &
    "paragraph.")
  r.intro(result, "Your report is ready", "")
  let s = r.band(result)
  discard r.markdown(s, "Your **September** report is ready to download.")
  r.footer(result)

proc markdownMaximalDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Everything Markdown", "Every construct a " &
    "Markdown body reads.")
  r.intro(result, "Everything Markdown", "Headings, emphasis, code, " &
    "lists, a quote, a rule, a table, a callout and a button, from one " &
    "Markdown string.")
  let s = r.band(result)
  discard r.markdown(s, maximalBody)
  r.footer(result)

proc markdownRtlDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("تحديث الإصدار", "نص Markdown من اليمين إلى اليسار.",
    rtl = true)
  r.intro(result, "تحديث الإصدار", "")
  let s = r.band(result)
  discard r.markdown(s, "# ما الجديد\n\nالإصدار **2026.10** متاح الآن. " &
    "عمليات النشر *أسرع*.\n\n- البحث في السجلات\n- ملخص بعد " &
    "`acme deploy`\n\n> وفّر عملاؤنا ساعة يوم الثلاثاء.\n\n---\n\n" &
    "| الخطة | السعر |\n|---|---|\n| الفريق | 20 $ |\n\nشكرًا، " &
    "[فريق Acme](https://example.com/ar).")
  r.footer(result, rtl = true)

proc markdownImagesOffDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Trip notes", "A Markdown body with an image " &
    "(captured with images off).")
  r.intro(result, "Trip notes", "With images blocked, the photo shows " &
    "its alt text; the text around it is unchanged.")
  let s = r.band(result)
  discard r.markdown(s, "The lake was still at dawn.\n\n![A lake under " &
    "green hills at dawn](" & lake & ")\n\nWe walked the shore until " &
    "noon.", [("image_width", "552")])
  r.footer(result)

proc markdownDarkDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.dkDoc("Release notes, dark", "A Markdown body in its dark " &
    "colours.")
  let s = r.dkBand(result, tok"color.surface.card")
  discard r.dkText(s, "h1", "Release notes, dark")
  discard r.markdown(s, "## What changed\n\nDeploys are **faster** and " &
    "logs are easier to search ([details](https://example.com/c)).\n\n" &
    "- Run `acme self-update`\n- Deploy as usual\n\n```\n$ acme deploy\n" &
    "done in 41s\n```\n\n> Quoted feedback.\n\n---\n\n| A | B |\n|---|---|\n" &
    "| 1 | 2 |\n\n:::warning\nOne setting goes away in November.\n:::")
  r.dkFooter(result)

proc markdownInContextDoc*(): EmailNode =
  let r = EmailRenderer()
  result = r.storyDoc("Maintenance on Sunday", "A Markdown body between " &
    "a callout and a button group.")
  r.intro(result, "Maintenance on Sunday", "")
  let s = r.band(result)
  let c = r.el(s, "mailCallout", attrs = [("tone", "info"),
    ("title", "Sunday, 02:00–03:00 UTC")])
  discard r.el(c, "p", [("margin", "0")], text = "The dashboard will be " &
    "read-only for up to an hour.")
  discard r.el(s, "mailSpacer", [("height", "16px")])
  discard r.markdown(s, "During the window:\n\n- deploys are **queued**, " &
    "not lost;\n- the API answers reads as usual.\n\nNothing to do on " &
    "your side.")
  discard r.el(s, "mailSpacer", [("height", "16px")])
  let g = r.el(s, "mailButtonGroup")
  discard r.el(g, "mailButton", attrs = [("href",
    "https://status.example.com/")], text = "Status page")
  r.footer(result)

proc story(name, description: string;
    build: proc(): EmailNode {.nimcall.}; dark: bool): KitStory =
  (name, description, build, dark)

let markdownStories*: seq[KitStory] = @[
  story("markdownMinimal", "mailMarkdown: one paragraph.", markdownMinimalDoc,
    false),
  story("markdownMaximal", "mailMarkdown: every construct, long words and a " &
    "long URL.", markdownMaximalDoc, false),
  story("markdownRtl", "mailMarkdown in Arabic, right to left.", markdownRtlDoc,
    false),
  story("markdownImagesOff", "mailMarkdown with an image (capture with images " &
    "off).", markdownImagesOffDoc, false),
  story("markdownDark", "mailMarkdown in its dark colours.", markdownDarkDoc,
    true),
  story("markdownInContext", "mailMarkdown between a callout and a button " &
    "group.", markdownInContextDoc, false),
]

proc markdownGroup(name: string): string =
  discard name
  "markdown"

proc renderMarkdownStory*(name: string): StoryHtml =
  ## The story `name` of the set, rendered.
  renderFrom(markdownStories, name, "markdown")

proc registerMarkdownStories*() =
  ## Registers the Markdown story set (env-gated, see above).
  registerKit(markdownStories, markdownGroup)

proc registerMarkdownStoryTrees*() =
  ## The trees the briefs of those stories render from.
  registerKitTrees(markdownStories)
