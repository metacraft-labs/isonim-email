// tools/capture/emulation/ganga.ts — backend-A ganga emulation.
//
// Ganga: remove every <style> and <link>, then apply
// gmailWeb steps 4–5. Steps 4–5 are gmailWeb's own helpers, imported
// — never reimplemented — so the two transforms cannot drift apart.

import {
  gmailHash,
  prefixClassesWithHash,
  stripDataImages,
  stripLinks,
  stripVarDecls,
  wrapA3s,
} from "./gmailWeb.ts";

export const GANGA_TRANSFORM_VERSION = 1;

// Every <style> element, closed or unclosed, anywhere in the document.
// (Links go through gmailWeb's stripLinks, called as part of step 4.)
const STYLE_BLOCK_RE = /<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi;
const STYLE_OPEN_RE = /<style\b[^>]*>/gi;

function stripStyles(html: string): string {
  return html.replace(STYLE_BLOCK_RE, "").replace(STYLE_OPEN_RE, "");
}

// Ganga: strip, then gmailWeb steps 4–5. Pure: the
// output depends only on the input HTML. The hash is taken over the
// transform input, exactly as gmailWeb takes it over its own.
export function ganga(html: string): string {
  const hash = gmailHash(html);
  const step4 = stripLinks(stripDataImages(stripVarDecls(stripStyles(html))));
  return wrapA3s(prefixClassesWithHash(step4, hash));
}
