// tools/capture/emulation/gmailWeb.test.ts — fixtures for the gmailWeb
// emulation steps 1–6. Each case feeds input HTML through gmailWeb()
// and pins the full-pipeline output. Run with:
//   node --test tools/capture/emulation/

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { gmailHash, gmailWeb } from "./gmailWeb.ts";

function doc(head: string, body: string): string {
  return `<!DOCTYPE html><html><head>${head}</head><body>${body}</body></html>`;
}

// The style attribute of the first <TAG …> in `html`, read the way an
// HTML parser reads a double-quoted value: up to the next raw `"`.
function styleOf(html: string, tag: string): string {
  const style = new RegExp(`<${tag}\\b[^>]*?\\sstyle="([^"]*)"`).exec(
    html,
  )?.[1];
  assert.ok(style !== undefined, `no <${tag} style="…"> in:\n${html}`);
  return style;
}

// Step 5 rewrites classes with the input's hash; the expectation
// builds only that prefix and pins everything else literally.
function pref(input: string): string {
  return `m_${gmailHash(input)}`;
}

describe("gmailWeb step 1: styles outside head", () => {
  it("drops body styles and keeps head styles", () => {
    const input = doc(
      `<style>.a{color:red}</style>`,
      `<style>.b{color:blue}</style><p>hi</p>`,
    );
    const p = pref(input);
    assert.equal(
      gmailWeb(input),
      doc(
        `<style>.${p}a{color:red}</style>`,
        `<div class="a3s"><p>hi</p></div>`,
      ),
    );
  });
});

describe("gmailWeb step 2: poison and budget", () => {
  it("drops !IMPORTANT, nested at-rule and parse-error blocks; poison spends no budget", () => {
    const huge = `/*${"p".repeat(20000)}*/`;
    const input = doc(
      `<style>.x{color:red !IMPORTANT}${huge}</style>` +
        `<style>.ok{color:green}</style>` +
        `<style>@media screen{.n{color:red} @media print{.m{color:blue}}}</style>` +
        `<style>.broken{color:red</style>`,
      `<p>hi</p>`,
    );
    const p = pref(input);
    assert.equal(
      gmailWeb(input),
      doc(
        `<style>.${p}ok{color:green}</style>`,
        `<div class="a3s"><p>hi</p></div>`,
      ),
    );
  });

  it("keeps blocks while the total is within 16384 bytes, then drops the rest", () => {
    // Block 1 lands exactly on the budget and is kept; block 2
    // crosses it and block 3 follows, so both are dropped (R-CSS-07).
    const pad = 16384 - ".a{color:red}".length - "/*".length - "*/".length;
    const css1 = `.a{color:red}/*${"p".repeat(pad)}*/`;
    assert.equal(Buffer.byteLength(css1, "utf8"), 16384);
    const input = doc(
      `<style>${css1}</style><style>.b{color:blue}</style><style>.c{color:cyan}</style>`,
      `<p>hi</p>`,
    );
    const p = pref(input);
    const kept = `.${p}a{color:red}/*${"p".repeat(pad)}*/`;
    assert.equal(
      gmailWeb(input),
      doc(`<style>${kept}</style>`, `<div class="a3s"><p>hi</p></div>`),
    );
  });
});

describe("gmailWeb step 3: rule filtering in kept blocks", () => {
  it("drops attribute selectors, non-width media, font-face and import", () => {
    const input = doc(
      `<style>` +
        `input[type=text]{color:red}` +
        `@media (orientation: portrait){.o{color:red}}` +
        `@media (max-width:600px){.a{color:red}input[x]{color:blue}}` +
        `@font-face{font-family:f;src:url(f.woff)}` +
        `@import url(more.css);` +
        `.b{color:green}` +
        `</style>`,
      `<p>hi</p>`,
    );
    const p = pref(input);
    assert.equal(
      gmailWeb(input),
      doc(
        `<style>@media (max-width:600px){.${p}a{color:red}}.${p}b{color:green}</style>`,
        `<div class="a3s"><p>hi</p></div>`,
      ),
    );
  });
});

describe("gmailWeb step 4: var, data images, links", () => {
  it("strips var() declarations, data: images and link elements", () => {
    const input = doc(
      `<link rel="stylesheet" href="https://x/site.css"><style>.a{color:var(--x);width:10px}</style>`,
      `<p style="color:var(--y);margin:0">hi</p>` +
        `<img src="data:image/png;base64,iVBORw0=" alt="inline">` +
        `<img src="https://x/y.png" alt="remote">`,
    );
    const p = pref(input);
    assert.equal(
      gmailWeb(input),
      doc(
        `<style>.${p}a{width:10px}</style>`,
        `<div class="a3s"><p style="margin:0">hi</p><img src="https://x/y.png" alt="remote"></div>`,
      ),
    );
  });
});

describe("gmailWeb step 5: class prefix and a3s wrap", () => {
  it("prefixes markup and selector classes, leaves declarations alone", () => {
    const input = doc(
      `<style>.a{color:red;background:url(foo.png)}.b,.c{margin:0}` +
        `@media (max-width:600px){.d{width:1px}}</style>`,
      `<p class="a b">x</p><span class='c'>y</span>`,
    );
    const p = pref(input);
    assert.equal(
      gmailWeb(input),
      doc(
        `<style>.${p}a{color:red;background:url(foo.png)}.${p}b,.${p}c{margin:0}` +
          `@media (max-width:600px){.${p}d{width:1px}}</style>`,
        `<div class="a3s"><p class="${p}a ${p}b">x</p><span class='${p}c'>y</span></div>`,
      ),
    );
  });
});

describe("gmailWeb step 6: clip", () => {
  it("leaves short documents unclipped", () => {
    const input = doc(`<style>.a{color:red}</style>`, `<p>hi</p>`);
    assert.ok(!gmailWeb(input).includes("[Message clipped]"));
  });

  it("truncates tag-aware past 102400 bytes and appends the marker", () => {
    const filler = "<p>0123456789abcdef</p>".repeat(5000);
    const input = doc(`<style>.a{color:red}</style>`, `<p>top</p>${filler}`);
    assert.ok(Buffer.byteLength(input, "utf8") > 102400);
    const out = gmailWeb(input);
    const marker = "\n<div>[Message clipped]  View entire message</div>";
    assert.ok(out.endsWith(marker));
    const cut = out.slice(0, out.length - marker.length);
    assert.ok(Buffer.byteLength(cut, "utf8") <= 102400);
    // Tag-aware: the cut never ends inside a tag (it may end in text).
    assert.ok(!/<[^>]*$/.test(cut), cut.slice(-40));
  });
});

describe("gmailWeb: rewritten inline styles stay inside their attribute", () => {
  it("re-escapes a decoded &quot; so the declarations after it survive", () => {
    const input = doc(
      ``,
      `<p style="font-family:&quot;Open Sans&quot;,Arial;--x:1px;margin:var(--x);color:#123456">x</p>` +
        `<p style='font-family:&#39;Open Sans&#39;,Arial;color:#654321'>y</p>`,
    );
    const out = gmailWeb(input);
    const style = styleOf(out, "p");
    assert.equal(
      style,
      `font-family:&quot;Open Sans&quot;,Arial;--x:1px;color:#123456`,
    );
    assert.ok(
      out.includes(
        `style='font-family:&#39;Open Sans&#39;,Arial;color:#654321'`,
      ),
      out,
    );
  });
});

describe("gmailWeb step 6: the clip keeps text inside long elements", () => {
  const marker = "\n<div>[Message clipped]  View entire message</div>";

  it("clips one long paragraph mid-text, keeping everything up to the limit", () => {
    const input = doc(``, `<p>${"x".repeat(200000)}</p>`);
    const out = gmailWeb(input);
    assert.ok(out.endsWith(marker));
    const cut = out.slice(0, out.length - marker.length);
    // Exactly the limit: the cut falls in text, so nothing backs up.
    assert.equal(Buffer.byteLength(cut, "utf8"), 102400);
    assert.ok(cut.endsWith("xxxx"), cut.slice(-40));
  });

  it("never cuts inside a tag, a character reference or a character", () => {
    // The tail starts `into` bytes before the limit, so the limit falls
    // inside its first construct; the cut must move back to where that
    // construct starts (for "é", 2 bytes each, the second one). The
    // last case lands just past a ">" inside a quoted attribute value.
    const a3s = `<div class="a3s">`;
    for (const [tail, into, kept] of [
      [`<a href="https://example.test/a>b">link</a>`, 3, ``],
      [`&amp;&amp;&amp;&amp;`, 3, ``],
      [`ééééé`, 3, `é`],
      [`<a href="https://example.test/a>b">link</a>`, 34, ``],
    ] as const) {
      const lead = doc(``, `<p>`).replace(`</body></html>`, "");
      const pad = 102400 - into - Buffer.byteLength(lead, "utf8") - a3s.length;
      const input = doc(
        ``,
        `<p>${"y".repeat(pad)}${tail}${"z".repeat(5000)}</p>`,
      );
      const out = gmailWeb(input);
      assert.ok(out.endsWith(marker), tail);
      const cut = out.slice(0, out.length - marker.length);
      const expected = `${lead.replace("<body>", `<body>${a3s}`)}${"y".repeat(pad)}${kept}`;
      assert.equal(
        Buffer.byteLength(expected, "utf8"),
        102400 - into + Buffer.byteLength(kept, "utf8"),
      );
      assert.equal(cut, expected, `${tail}: ${cut.slice(-30)}`);
    }
  });
});
