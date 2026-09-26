# isonim-email

HTML email for [IsoNim](https://github.com/metacraft-labs/isonim), the
isomorphic reactive UI framework for Nim.

Email is not the web. A message is read in dozens of clients whose HTML
engines range from current WebKit (Apple Mail) to Microsoft Word (classic
Outlook for Windows), through webmail sanitisers that rewrite or delete CSS
(Gmail, Outlook.com, Yahoo). It is also *packaged* differently: one
self-contained document, styles inlined, no scripts, wrapped in a MIME
`multipart/alternative` with a plain-text part and optionally embedded images.

`isonim-email` lets you write that message with the same IsoNim DSL you use
for web and native UI, and takes responsibility for the parts that are easy
to get wrong:

- **Client-safe components** — sections, columns, buttons, images, hero
  blocks, spacers, dividers — that render as the table/VML/conditional-comment
  structures each client family needs.
- **An email target for the IsoNim renderer** that forbids what email cannot
  carry (scripts, event handlers, unsupported CSS) at compile time rather than
  in production.
- **Style compilation** — design tokens and utility classes resolved and
  inlined, with the small residue that must stay in `<head>` (media queries,
  dark mode) kept there and within client limits.
- **Packaging** — the plain-text alternative, preheader, MIME assembly,
  embedded images, and header helpers such as one-click unsubscribe.
- **Visual verification** — rendering a message in real clients and webmail
  and feeding the screenshots into a review loop.

## Status

Design stage. Nothing here is usable yet; the first milestone establishes the
build and the test harness.

## License

Apache-2.0. See [LICENSE](LICENSE).
