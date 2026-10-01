// tools/capture/emulation/ganga.test.ts — fixtures for the ganga
// emulation: strip every <style>/<link>, then gmailWeb steps 4–5. Steps
// 4–5 are pinned by direct comparison against gmailWeb on the same
// input (on style-free inputs the two pipelines coincide), never by
// duplicated expectations. Run with:
//   node --test tools/capture/emulation/

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { ganga } from "./ganga.ts";
import { gmailWeb } from "./gmailWeb.ts";

// The style attribute of the first <TAG …> in `html`, read the way an
// HTML parser reads a double-quoted value: up to the next raw `"`.
function styleOf(html: string, tag: string): string {
  const style = new RegExp(`<${tag}\\b[^>]*?\\sstyle="([^"]*)"`).exec(
    html,
  )?.[1];
  assert.ok(style !== undefined, `no <${tag} style="…"> in:\n${html}`);
  return style;
}

function doc(head: string, body: string): string {
  return `<!DOCTYPE html><html><head>${head}</head><body>${body}</body></html>`;
}

describe("ganga: no style or link survives", () => {
  it("removes head styles, body styles and links", () => {
    const input = doc(
      `<link rel="stylesheet" href="https://x/site.css"><style>.a{color:red}</style>`,
      `<style>.b{color:blue}</style><LINK HREF="https://x/other.css"><p class="a">hi</p>`,
    );
    const out = ganga(input);
    assert.ok(!/<style[\s>]/i.test(out), `style survived:\n${out}`);
    assert.ok(!/<link[\s>]/i.test(out), `link survived:\n${out}`);
    assert.ok(out.includes(`<p class="m_`), `class prefix missing:\n${out}`);
    assert.ok(out.includes(`<div class="a3s">`), `a3s wrap missing:\n${out}`);
  });

  it("removes unclosed style tags too", () => {
    const input = doc(`<style>.a{color:red}`, `<p>hi</p>`);
    const out = ganga(input);
    assert.ok(!/<style[\s>]/i.test(out), `style survived:\n${out}`);
  });
});

describe("ganga steps 4-5 match gmailWeb on the same input", () => {
  it("var() declarations, data: images, classes and a3s wrap", () => {
    const inputs = [
      doc(
        ``,
        `<p style="color:var(--y);margin:0">hi</p>` +
          `<img src="data:image/png;base64,iVBORw0=" alt="inline">` +
          `<img src="https://x/y.png" alt="remote">` +
          `<p class="a b">x</p><span class='c'>y</span>`,
      ),
      doc(``, `<p>plain</p>`),
    ];
    for (const input of inputs) assert.equal(ganga(input), gmailWeb(input));
  });
});

describe("ganga: rewritten inline styles stay inside their attribute", () => {
  it("re-escapes a decoded &quot; after dropping var() declarations", () => {
    const out = ganga(
      `<html><head></head><body><td style="font-family:&quot;A B&quot;;margin:var(--m);padding:8px">x</td></body></html>`,
    );
    assert.equal(styleOf(out, "td"), `font-family:&quot;A B&quot;;padding:8px`);
  });
});
