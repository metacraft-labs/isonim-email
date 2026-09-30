// tools/capture/emulation/style_attr.ts — rewrite inline style=
// attributes without breaking their quoting.
//
// The transforms edit inline CSS as text, so they decode the quote
// entities first (`font-family:&quot;Open Sans&quot;` is CSS with real
// quotes in it). The result must be escaped again for the attribute it
// goes back into: a raw `"` inside a double-quoted attribute ends the
// attribute early and silently drops every declaration after it.
// Every transform that rewrites style= goes through mapStyleAttributes
// (imported — never reimplemented — per the ganga precedent).

// Quote entities only: the CSS rewrites never touch `&` or `<`, so the
// other entities pass through byte-identical.
export function decodeQuoteEntities(value: string): string {
  return value
    .replace(/&quot;|&#0*34;|&#x0*22;/gi, '"')
    .replace(/&apos;|&#0*39;|&#x0*27;/gi, "'");
}

// Escapes the attribute's own quote character; the other quote is
// legal as-is inside it.
export function escapeForQuote(value: string, quote: string): string {
  return quote === '"'
    ? value.replace(/"/g, "&quot;")
    : value.replace(/'/g, "&#39;");
}

// A start tag, attribute values quoted or not, so a `>` inside a
// quoted value (alt="a > b") does not end the tag early.
export const START_TAG_RE =
  /<[a-zA-Z][a-zA-Z0-9:-]*(?:\s+(?:[^\s"'>\/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+))?|\/))*\s*\/?>/g;

// Applies `rewrite` to the decoded CSS of every quoted style= attribute
// (the lookbehind keeps data-style from matching) and writes the result
// back escaped for its quote. Unquoted style values cannot carry
// quotes or `;`-separated lists worth rewriting and are left alone.
export function mapStyleAttributes(
  html: string,
  rewrite: (css: string, tag: string) => string,
): string {
  return html.replace(START_TAG_RE, (tag: string): string =>
    tag.replace(
      /(?<![-\w])style\s*=\s*(?:"([^"]*)"|'([^']*)')/gi,
      (_m: string, dq: string | undefined, sq: string | undefined): string => {
        const quote = dq !== undefined ? '"' : "'";
        const css = rewrite(decodeQuoteEntities(dq ?? sq ?? ""), tag);
        return `style=${quote}${escapeForQuote(css, quote)}${quote}`;
      },
    ),
  );
}
