// tools/capture/emulation/imagesOff.test.ts — fixtures for the imagesOff
// emulation: every img[src] gets src="" with alt and styling kept,
// CSS background-image goes from style blocks and inline style=, and
// nothing else changes. Run with:
//   node --test tools/capture/emulation/

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { imagesOff } from "./imagesOff.ts";

function doc(head: string, body: string): string {
  return `<!DOCTYPE html><html><head>${head}</head><body>${body}</body></html>`;
}

describe("imagesOff: img sources emptied, everything else kept", () => {
  it("empties src but keeps alt, dimensions, styling and other attributes", () => {
    const out = imagesOff(
      doc(
        ``,
        `<img src="https://x/y.png" alt="desert" width="600" height="400" style="display:block;border:0" class="hero">`,
      ),
    );
    assert.ok(
      out.includes(
        `<img src="" alt="desert" width="600" height="400" style="display:block;border:0" class="hero">`,
      ),
      `unexpected output:\n${out}`,
    );
  });

  it("handles unquoted and uppercase src, and imgs without src", () => {
    const out = imagesOff(
      doc(``, `<IMG SRC=https://x/y.png ALT=x><img alt="no src here">`),
    );
    assert.ok(out.includes(`<IMG SRC="" ALT=x>`), `unquoted src kept:\n${out}`);
    assert.ok(
      out.includes(`<img alt="no src here">`),
      `src-less img changed:\n${out}`,
    );
  });

  it("empties srcset too, but never data-src", () => {
    const out = imagesOff(
      doc(
        ``,
        `<img src="a.png" srcset="a.png 1x, b.png 2x" alt="s"><img data-src="lazy.png" src="real.png" alt="d">`,
      ),
    );
    assert.ok(
      out.includes(`<img src="" srcset="" alt="s">`),
      `srcset survived:\n${out}`,
    );
    assert.ok(
      out.includes(`<img data-src="lazy.png" src="" alt="d">`),
      `data-src touched:\n${out}`,
    );
  });

  it("leaves non-img src attributes alone", () => {
    const input = doc(``, `<script src="https://x/app.js"></script>`);
    assert.equal(imagesOff(input), input);
  });
});

describe("imagesOff: background-image removed, other CSS untouched", () => {
  it("strips background-image from style blocks", () => {
    const out = imagesOff(
      doc(
        `<style>.a{background-image:url(https://x/bg.png);color:red}.b{color:blue;background-image:url("quoted.png")}</style>`,
        `<p>hi</p>`,
      ),
    );
    assert.ok(
      !/background-image/i.test(out),
      `background-image survived:\n${out}`,
    );
    assert.ok(
      out.includes(`.a{color:red}`),
      `sibling declaration lost:\n${out}`,
    );
    assert.ok(
      out.includes(`.b{color:blue`),
      `sibling declaration lost:\n${out}`,
    );
  });

  it("eats data: background-images whole, not up to the inner semicolon", () => {
    const out = imagesOff(
      doc(
        `<style>.b{background-image:url(data:image/png;base64,iVBORw0=)}</style>`,
        ``,
      ),
    );
    assert.ok(
      !/background-image/i.test(out),
      `background-image survived:\n${out}`,
    );
    assert.ok(!/base64/.test(out), `data: tail survived:\n${out}`);
  });

  it("strips background-image from inline style= attributes", () => {
    const out = imagesOff(
      doc(
        ``,
        `<p style="background-image:url(https://x/bg.png);margin:0">hi</p>`,
      ),
    );
    assert.ok(
      out.includes(`<p style="margin:0">hi</p>`),
      `unexpected output:\n${out}`,
    );
  });

  it("keeps the background shorthand and all other declarations", () => {
    const input = doc(
      `<style>.c{background:#fff url(u.png);color:blue}</style>`,
      `<p style="color:red;background:green">hi</p>`,
    );
    assert.equal(imagesOff(input), input);
  });
});

describe("imagesOff: idempotent", () => {
  it("running the transform twice changes nothing the second time", () => {
    const input = doc(
      `<style>.a{background-image:url(x.png);color:red}</style>`,
      `<img src="a.png" srcset="a.png 1x" alt="s"><p style="background-image:url(y.png);margin:0">hi</p>`,
    );
    const once = imagesOff(input);
    assert.equal(imagesOff(once), once);
  });
});
