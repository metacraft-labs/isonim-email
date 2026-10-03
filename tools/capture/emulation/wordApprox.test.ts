// tools/capture/emulation/wordApprox.test.ts — fixtures for the
// wordApprox emulation: one fixture per numbered step. The transform is a
// lint-grade approximation (no Word text-layout imitation): it reveals
// mso conditionals, strips the CSS Word ignores, drops media queries,
// stands VML shapes in as flat labelled rectangles, and flattens
// rgba. Run with:
//   node --test tools/capture/emulation/

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { imagesOff } from "./imagesOff.ts";
import { wordApprox } from "./wordApprox.ts";

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

  it("lays a cell out with its mso-padding-alt, as Word does", () => {
    // A table button: the padding is on the link (ignored), Word's on
    // the cell as mso-padding-alt.
    const out = wordApprox(
      doc(
        ``,
        `<table><tr><td style="border:none;mso-padding-alt:12px 24px;background-color:#1f6feb;">` +
          `<a style="display:inline-block;padding:12px 24px;mso-padding-alt:0px;">Go</a></td>` +
          `<td style="padding:4px;mso-padding-alt:8px">x</td><td style="padding:6px">y</td></tr></table>`,
      ),
    );
    assert.ok(
      out.includes(
        `<td style="border:none;mso-padding-alt:12px 24px;background-color:#1f6feb;padding:12px 24px;">`,
      ),
      `cell padding missing:\n${out}`,
    );
    assert.ok(
      out.includes(`<a style="mso-padding-alt:0px;">Go</a>`),
      `link kept its padding:\n${out}`,
    );
    // mso-padding-alt wins over the cell's own padding; a cell without
    // one keeps its padding.
    assert.ok(
      out.includes(`<td style="mso-padding-alt:8px;padding:8px;">x</td>`),
      `mso-padding-alt did not win:\n${out}`,
    );
    assert.ok(
      out.includes(`<td style="padding:6px">y</td>`),
      `padding lost:\n${out}`,
    );
  });

  it("strips box-shadow, which Word does not draw, and keeps the box's border", () => {
    const out = wordApprox(
      doc(
        `<style>.s{box-shadow:0 1px 3px #000;color:red}</style>`,
        `<table><tr><td style="padding:24px;border:1px solid #dedede;box-shadow:0 1px 3px rgba(0,0,0,0.12);">x</td></tr></table>`,
      ),
    );
    assert.ok(out.includes(`.s{color:red}`), `unexpected output:\n${out}`);
    assert.ok(
      out.includes(`<td style="padding:24px;border:1px solid #dedede;">x</td>`),
      `unexpected output:\n${out}`,
    );
  });

  it("strips calc() declarations, which Word does not support, and keeps the rest", () => {
    const out = wordApprox(
      doc(
        `<style>.f{width:calc(480px - 100%);color:red}</style>`,
        `<div style="display:inline-block;width:calc((480px - 100%) * 480);min-width:50%;font-size:16px">x</div>` +
          // The Fab Four's fallback pair: the max() form wraps calc(),
          // so it goes too (Word has neither function).
          `<div style="width:calc((480px - 100%) * 480);width:max(50%, calc((480px - 100%) * 480));min-width:50%">y</div>`,
      ),
    );
    assert.ok(out.includes(`.f{color:red}`), `unexpected output:\n${out}`);
    assert.ok(
      out.includes(`<div style="min-width:50%;font-size:16px">x</div>`),
      `unexpected output:\n${out}`,
    );
    assert.ok(
      out.includes(`<div style="min-width:50%">y</div>`),
      `unexpected output:\n${out}`,
    );
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

describe("wordApprox step 4: a shape filled with an image shows it", () => {
  it("stands a background v:rect in with its image, fill colour and size", () => {
    const out = wordApprox(
      `<!--[if gte mso 9]><v:rect xmlns:v="urn:schemas-microsoft-com:vml" fill="true" stroke="false" style="width:600px;height:300px;">` +
        `<v:fill type="frame" origin="0, -0.5" position="0, -0.5" src="https://x.test/bg.png" color="#223344" size="1,1" aspect="atleast" />` +
        `<v:textbox inset="0,0,0,0"><![endif]-->` +
        `<p>hero</p>` +
        `<!--[if gte mso 9]></v:textbox></v:rect><![endif]-->`,
    );
    assert.equal(
      out,
      `<div style="width:600px;height:300px;background-color:#223344;` +
        `background-image:url('https://x.test/bg.png');background-size:cover;` +
        `background-position:50% 0%;background-repeat:no-repeat;` +
        `position:relative;outline:2px dashed #000">` +
        `<span style="position:absolute;top:0;left:0;font:10px/12px monospace;` +
        `background:#000;color:#fff">VML</span><p>hero</p></div>`,
    );
  });

  it("tiles a type=tile fill and leaves the image to imagesOff", () => {
    const out = wordApprox(
      `<v:rect style="width:600px;"><v:fill type="tile" origin="0.5, 0" position="0.5, 0" src="https://x.test/t.png" color="#eeeeee" /><v:textbox><p>x</p></v:textbox></v:rect>`,
    );
    assert.ok(out.includes("background-repeat:repeat;"), out);
    assert.ok(out.includes("background-position:50% 0%;"), out);
    assert.ok(out.includes("background-size:auto;"), out);
    assert.ok(!/<v:/i.test(out), `v: tag survived:\n${out}`);
    const off = imagesOff(out);
    assert.ok(!/background-image/i.test(off), off);
    assert.ok(off.includes("background-color:#eeeeee"), off);
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
