// tools/capture/emulation/wordApprox.test.ts — fixtures for the
// wordApprox emulation: one fixture per numbered step. The transform is a
// lint-grade approximation (no Word text-layout imitation): it reveals
// mso conditionals, strips the CSS Word ignores, drops media queries,
// stands VML shapes in as flat labelled rectangles, and flattens
// rgba. Run with:
//   node --test tools/capture/emulation/

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { wordApprox } from "./wordApprox.ts";

// The style attribute of the first <TAG …> in `html`, read the way an
// HTML parser reads a double-quoted value: up to the next raw `"`.
function styleOf(html: string, tag: string): string {
  const m = new RegExp(`<${tag}\\b[^>]*?\\sstyle="([^"]*)"`).exec(html);
  assert.ok(m !== null, `no <${tag} style="…"> in:\n${html}`);
  return m[1];
}

function doc(head: string, body: string): string {
  return `<!DOCTYPE html><html><head>${head}</head><body>${body}</body></html>`;
}

describe("wordApprox step 1: mso conditionals revealed, !mso deleted", () => {
  it("unwraps [if mso] and [if gte mso 9], keeping the inner markup", () => {
    const out = wordApprox(
      `<!--[if mso]><table><tr><td>ghost</td></tr></table><![endif]-->` +
        `<!--[if gte mso 9]><p>niner</p><![endif]-->`,
    );
    assert.equal(out, `<table><tr><td>ghost</td></tr></table><p>niner</p>`);
  });

  it("deletes downlevel-revealed [if !mso] blocks whole", () => {
    const out = wordApprox(
      `a<!--[if !mso]><!--><p>capable clients only</p><!--<![endif]-->b`,
    );
    assert.equal(out, `ab`);
  });

  it("leaves other conditions (e.g. lte mso 11) untouched", () => {
    const input = `<!--[if lte mso 11]><style>.x{width:100%}</style><![endif]-->`;
    assert.equal(wordApprox(input), input);
  });
});

describe("wordApprox step 2: CSS Word ignores is stripped", () => {
  it("strips max-width, bad display values, radius and margin:auto from blocks", () => {
    const out = wordApprox(
      doc(
        `<style>.s{margin:0 auto;max-width:600px;display:inline-block;border-radius:8px;color:red}.t{display:block;min-width:1px}</style>`,
        ``,
      ),
    );
    assert.ok(out.includes(`.s{color:red}`), `unexpected output:\n${out}`);
    assert.ok(
      out.includes(`.t{display:block;min-width:1px}`),
      `good declarations lost:\n${out}`,
    );
  });

  it("strips flex/grid display and background-image, keeps the background shorthand", () => {
    const out = wordApprox(
      doc(
        ``,
        `<div style="display:flex;background-image:url(x.png);background:green">x</div>` +
          `<div style="display:grid">y</div>`,
      ),
    );
    assert.ok(
      out.includes(`<div style="background:green">x</div>`),
      `unexpected output:\n${out}`,
    );
    assert.ok(out.includes(`<div style="">y</div>`), `grid kept:\n${out}`);
  });

  it("keeps padding on td/th only, in blocks and inline", () => {
    const out = wordApprox(
      doc(
        `<style>td{padding:10px}p{padding:5px}.td{padding:1px}</style>`,
        `<td style="padding:4px;max-width:9px">y</td><div style="padding:2px">x</div>`,
      ),
    );
    assert.ok(out.includes(`td{padding:10px}`), `td padding lost:\n${out}`);
    assert.ok(!/p\{[^}]*padding/.test(out), `p padding kept:\n${out}`);
    assert.ok(!/\.td\{[^}]*padding/.test(out), `.td padding kept:\n${out}`);
    assert.ok(
      out.includes(`<td style="padding:4px;">y</td>`),
      `inline td padding lost:\n${out}`,
    );
    assert.ok(
      out.includes(`<div style="">x</div>`),
      `inline div padding kept:\n${out}`,
    );
  });
});

describe("wordApprox step 3: media queries stripped", () => {
  it("removes every @media rule and keeps plain rules", () => {
    const out = wordApprox(
      doc(
        `<style>.a{color:red}@media only screen and (min-width:480px){.a{width:50%}}@media screen{.b{x:y}}</style>`,
        ``,
      ),
    );
    assert.ok(!/@media/i.test(out), `media survived:\n${out}`);
    assert.ok(out.includes(`.a{color:red}`), `plain rule lost:\n${out}`);
  });
});

describe("wordApprox step 4: VML shapes become flat labelled rectangles", () => {
  it("replaces a self-closing shape with a closed div at its px size", () => {
    const out = wordApprox(
      `<!--[if gte mso 9]><v:rect fillcolor="#ff0000" style="width:600px;height:200px;"/><![endif]-->`,
    );
    assert.equal(
      out,
      `<div style="width:600px;height:200px;background-color:#ff0000;outline:2px dashed #000">VML</div>`,
    );
  });

  it("keeps live content between split open/close tags; converts pt", () => {
    const out = wordApprox(
      `<!--[if gte mso 9]><v:rect fillcolor="#00ff00" style="width:450pt;height:150pt;"><v:fill color="#00ff00"/><v:textbox><![endif]-->` +
        `<p>hero</p>` +
        `<!--[if gte mso 9]></v:textbox></v:rect><![endif]-->`,
    );
    assert.equal(
      out,
      `<div style="width:600px;height:200px;background-color:#00ff00;outline:2px dashed #000">VML<p>hero</p></div>`,
    );
  });

  it("falls back to color, then grey, when fillcolor is missing", () => {
    const withColor = wordApprox(`<v:shape color="blue" style="width:10px"/>`);
    assert.ok(
      withColor.includes(`background-color:blue`),
      `color fallback missed:\n${withColor}`,
    );
    const bare = wordApprox(`<v:image src="https://x/i.png"/>`);
    assert.ok(
      bare.includes(`background-color:#cccccc`),
      `grey fallback missed:\n${bare}`,
    );
    assert.ok(!/<v:/i.test(bare), `v: tag survived:\n${bare}`);
  });
});

describe("wordApprox step 5: rgba alpha dropped", () => {
  it("flattens rgba() to rgb() in blocks and inline", () => {
    const out = wordApprox(
      doc(
        `<style>.a{color:#7f7f7f;color:rgba(0,0,0,.5)}</style>`,
        `<p style="color:rgba(1, 2, 3, 0.5)">t</p>`,
      ),
    );
    assert.ok(!/rgba\(/i.test(out), `rgba survived:\n${out}`);
    assert.ok(
      out.includes(`.a{color:#7f7f7f;color:rgb(0,0,0)}`),
      `unexpected block output:\n${out}`,
    );
    assert.ok(
      out.includes(`<p style="color:rgb(1,2,3)">t</p>`),
      `unexpected inline output:\n${out}`,
    );
  });
});

describe("wordApprox: idempotent", () => {
  it("running the transform twice changes nothing the second time", () => {
    const input = doc(
      `<style>.s{margin:0 auto;max-width:9px}@media screen{.a{x:y}}.a{color:rgba(0,0,0,.5)}</style>`,
      `<!--[if mso]><table><tr><td>ghost</td></tr></table><![endif]-->` +
        `<!--[if gte mso 9]><v:rect fillcolor="#123456" style="width:9px;height:9px;"/><![endif]-->` +
        `<div style="display:flex;padding:1px">x</div>`,
    );
    const once = wordApprox(input);
    assert.equal(wordApprox(once), once);
  });
});

describe("wordApprox: rewritten inline styles stay inside their attribute", () => {
  it("re-escapes a decoded &quot; in both inline passes (step 2 and step 5)", () => {
    const out = wordApprox(
      `<div style="font-family:&quot;A B&quot;;max-width:600px;color:rgba(0,0,0,0.5);font-size:16px">x</div>` +
        `<td style="font-family:&quot;C D&quot;;padding:8px;border-radius:4px;color:#111111">y</td>`,
    );
    assert.equal(
      styleOf(out, "div"),
      `font-family:&quot;A B&quot;;color:rgb(0,0,0);font-size:16px`,
    );
    assert.equal(
      styleOf(out, "td"),
      `font-family:&quot;C D&quot;;padding:8px;color:#111111`,
    );
  });
});
