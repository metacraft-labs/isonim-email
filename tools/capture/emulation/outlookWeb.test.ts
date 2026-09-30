// tools/capture/emulation/outlookWeb.test.ts — fixtures for the
// outlookWeb emulation: x_ prefixing in markup and CSS, attribute selectors
// kept, the rps_xxxx wrap, and dark-only data-ogsc/data-ogsb. Run with:
//   node --test tools/capture/emulation/

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { invertLightness, outlookWeb } from "./outlookWeb.ts";

function doc(head: string, body: string): string {
  return `<!DOCTYPE html><html><head>${head}</head><body>${body}</body></html>`;
}

describe("outlookWeb: class and id prefix in markup and CSS", () => {
  it("prefixes classes and ids, including inside media queries", () => {
    const input = doc(
      `<style>.a{color:red}#main{margin:0}` +
        `@media (max-width:600px){.b{width:1px}#side{display:none}}</style>`,
      `<p class="a b" id="main">x</p><span id='side'>y</span>`,
    );
    assert.equal(
      outlookWeb(input, "light"),
      doc(
        `<style>.x_a{color:red}#x_main{margin:0}` +
          `@media (max-width:600px){.x_b{width:1px}#x_side{display:none}}</style>`,
        `<div class="rps_xxxx"><p class="x_a x_b" id="x_main">x</p><span id='x_side'>y</span></div>`,
      ),
    );
  });

  it("leaves declarations, hex colours and data-* attributes alone; no double prefix", () => {
    const input = doc(
      `<style>.a{color:#aabbcc;background:url(foo.png)}</style>`,
      `<p class="x_a" id="x_p" data-id="p">x</p>`,
    );
    assert.equal(
      outlookWeb(input, "light"),
      doc(
        `<style>.x_a{color:#aabbcc;background:url(foo.png)}</style>`,
        `<div class="rps_xxxx"><p class="x_a" id="x_p" data-id="p">x</p></div>`,
      ),
    );
  });
});

describe("outlookWeb: attribute selectors are kept", () => {
  it("keeps attribute-selector rules, quoted values untouched", () => {
    const input = doc(
      `<style>input[type=text]{color:red}a[href="#sec"]{color:blue}.a[x=".b"]{margin:0}</style>`,
      `<p>hi</p>`,
    );
    assert.equal(
      outlookWeb(input, "light"),
      doc(
        `<style>input[type=text]{color:red}a[href="#sec"]{color:blue}.x_a[x=".b"]{margin:0}</style>`,
        `<div class="rps_xxxx"><p>hi</p></div>`,
      ),
    );
  });
});

describe("outlookWeb dark: recolours (partial inversion) and marks with data-ogsc/data-ogsb", () => {
  it("inverts dark text and light backgrounds, marking each with data-ogsc / data-ogsb", () => {
    const input = doc(
      ``,
      `<p style="color:#111111">dark text</p>` +
        `<p style="background-color:#ffffff">light plate</p>` +
        `<p style="color:#111111;background-color:#ffffff">both</p>`,
    );
    assert.equal(
      outlookWeb(input, "dark"),
      doc(
        ``,
        `<div class="rps_xxxx">` +
          `<p data-ogsc style="color:#c5c5c5">dark text</p>` +
          `<p data-ogsb style="background-color:#000000">light plate</p>` +
          `<p data-ogsc data-ogsb style="color:#c5c5c5;background-color:#000000">both</p>` +
          `</div>`,
      ),
    );
  });

  it("treats the same mid grey asymmetrically: text inverts, background does not", () => {
    // #777777 has relative luminance ~0.18: below the 0.5 text
    // threshold, so as a text colour it inverts (OKLCH L 0.569 →
    // 0.431, #505050, data-ogsc); as a background it is outside the
    // > 0.5 set, so it keeps its colour and gets no data-ogsb.
    const input = doc(
      ``,
      `<p style="color:#777777">grey text</p>` +
        `<p style="background-color:#777777">grey plate</p>`,
    );
    assert.equal(
      outlookWeb(input, "dark"),
      doc(
        ``,
        `<div class="rps_xxxx">` +
          `<p data-ogsc style="color:#505050">grey text</p>` +
          `<p style="background-color:#777777">grey plate</p>` +
          `</div>`,
      ),
    );
  });

  it("ignores light text, dark backgrounds and non-hex colours", () => {
    const input = doc(
      ``,
      `<p style="color:#ffffff">light text</p>` +
        `<p style="background-color:#000000">dark plate</p>` +
        `<p style="color:red">named</p>` +
        `<p style="background-color:rgb(255,255,255)">rgb</p>` +
        `<p>unstyled</p>`,
    );
    const out = outlookWeb(input, "dark");
    assert.ok(!out.includes("data-ogsc"), `unexpected ogsc:\n${out}`);
    assert.ok(!out.includes("data-ogsb"), `unexpected ogsb:\n${out}`);
  });

  it("inverts OKLCH lightness only: black and white swap, a blue stays blue", () => {
    const input = doc(
      ``,
      `<p style="color:#000000">black</p>` +
        `<table bgcolor="#ffffff"><tr><td style="background-color:#1a73e8">blue plate</td></tr></table>`,
    );
    const out = outlookWeb(input, "dark");
    assert.ok(
      out.includes(`<p data-ogsc style="color:#ffffff">black</p>`),
      out,
    );
    // bgcolor recolours like background-color.
    assert.ok(out.includes(`<table data-ogsb bgcolor="#000000">`), out);
    // #1a73e8 (luminance ~0.2) is a dark background: not recoloured.
    assert.ok(out.includes(`<td style="background-color:#1a73e8">`), out);
    assert.equal(invertLightness("#1a73e8"), "#0044b6");
  });

  it("keeps !important and re-escapes the quotes of the rewritten style", () => {
    const input = doc(
      ``,
      `<td style="font-family:&quot;Open Sans&quot;,Arial;color:#111111 !important;padding:4px">x</td>`,
    );
    const out = outlookWeb(input, "dark");
    assert.ok(
      out.includes(
        `<td data-ogsc style="font-family:&quot;Open Sans&quot;,Arial;color:#c5c5c5 !important;padding:4px">x</td>`,
      ),
      out,
    );
  });

  it("keeps the message's own [data-ogsc] rules and marks what it recolours", () => {
    // R-DRK-03: the library's dark classes are keyed on the markers,
    // so the recolour must add them where it recolours. (Whether
    // Outlook also marks ancestors is for real-client captures.)
    const input = doc(
      `<style>[data-ogsc] .dk{color:#eeeeee !important}</style>`,
      `<p class="dk" style="color:#111111">x</p>`,
    );
    const out = outlookWeb(input, "dark");
    assert.ok(out.includes(`[data-ogsc] .x_dk{color:#eeeeee !important}`), out);
    assert.ok(
      out.includes(`<p data-ogsc class="x_dk" style="color:#c5c5c5">`),
      out,
    );
  });

  it("adds no attributes twice: the dark pass does not duplicate", () => {
    const input = doc(``, `<p style="color:#111111">x</p>`);
    const twice = outlookWeb(outlookWeb(input, "dark"), "dark");
    assert.equal(twice.match(/data-ogsc/g)?.length ?? 0, 1);
  });
});

describe("outlookWeb light and forced-dark: no data-ogsc/data-ogsb", () => {
  it("adds no dark attributes outside scheme=dark", () => {
    const input = doc(
      ``,
      `<p style="color:#111111;background-color:#ffffff">both</p>`,
    );
    for (const scheme of ["light", "forced-dark"]) {
      const out = outlookWeb(input, scheme);
      assert.ok(!out.includes("data-ogsc"), `${scheme} added ogsc:\n${out}`);
      assert.ok(!out.includes("data-ogsb"), `${scheme} added ogsb:\n${out}`);
      assert.ok(
        out.includes(`<div class="rps_xxxx">`),
        `${scheme} lost the wrap:\n${out}`,
      );
    }
  });
});
