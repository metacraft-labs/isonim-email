// tools/capture/providers/mime_rewrite.test.ts — rewriting the story
// asset origin in the copy of a message injected into IMAP.
//
// The rewritten messages are decoded by Python's `email` package (the
// dev shell's python3), an implementation independent of the rewrite's
// own decoder, so a rewrite that changed anything but the resource
// URLs, or broke the transfer encoding, is caught. Expected outputs are
// written out literally here, not computed by the code under test. No
// mocks; the one seam used (RewriteSeam.beforeCheck) corrupts the
// rewrite's output to show the post-check is what refuses it. Run with:
//   node --test tools/capture/providers/mime_rewrite.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  checkRewrite,
  decodeAttrValue,
  decodeQuotedPrintable,
  leftoverResource,
  parseEntity,
  resourceOccurrences,
  rewriteAssetOrigin,
} from "./mime_rewrite.ts";

const FROM = "https://x.test/";
const TO = "http://127.0.0.1:43125/";

interface Leaf {
  type: string;
  body: string; // decoded octets, one char per byte
}

// Every leaf part, decoded by Python's email package.
function pythonLeaves(mime: Uint8Array): Leaf[] {
  const r = spawnSync(
    "python3",
    [
      "-c",
      [
        "import sys, json, email",
        "m = email.message_from_bytes(sys.stdin.buffer.read())",
        "out = []",
        "for p in m.walk():",
        "    if p.is_multipart(): continue",
        "    out.append({'type': p.get_content_type(), 'body': p.get_payload(decode=True).decode('latin1')})",
        "json.dump(out, sys.stdout)",
      ].join("\n"),
    ],
    { input: mime, encoding: "utf8" },
  );
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout) as Leaf[];
}

function bytes(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, "latin1"));
}

function text(b: Uint8Array): string {
  return Buffer.from(b).toString("latin1");
}

// Encodes with Python's quopri (an independent QP encoder).
function pythonQpEncode(s: string): string {
  const r = spawnSync(
    "python3",
    [
      "-c",
      "import sys, quopri; sys.stdout.buffer.write(quopri.encodestring(sys.stdin.buffer.read()))",
    ],
    { input: Buffer.from(s, "latin1") },
  );
  assert.equal(r.status, 0, String(r.stderr));
  return r.stdout.toString("latin1").replace(/\r?\n/g, "\r\n");
}

// Decodes with Python's quopri.
function pythonQpDecode(s: string): string {
  const r = spawnSync(
    "python3",
    [
      "-c",
      "import sys, quopri; sys.stdout.buffer.write(quopri.decodestring(sys.stdin.buffer.read()))",
    ],
    { input: Buffer.from(s, "latin1") },
  );
  assert.equal(r.status, 0, String(r.stderr));
  return r.stdout.toString("latin1");
}

function message(parts: string[], boundary = "=_b1"): string {
  return [
    "MIME-Version: 1.0",
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
    "",
    ...parts.flatMap((p) => [`--${boundary}`, p]),
    `--${boundary}--`,
    "",
  ].join("\r\n");
}

// A multipart/alternative message in quoted-printable. The HTML part
// loads three resources from the origin: an img src split by a soft
// line break, an img src with an =3A escape, and a CSS url() in a
// style attribute split by a soft break. It also has the origin in an
// href and in visible text (split by a soft break), and the text part
// has it too: none of those may change.
const QP_HTML_LINES = [
  '<table><tr><td>lead text lead text lead text lead text <img src=3D"https:/=',
  '/x.test/2494f1185a00ab29/logo.png" alt=3D"Acme"></td></tr></table><p>more=',
  ' text <img src=3D"https=3A//x.test/aaaaaaaaaaaaaaaa/shield.png"> and a ver=',
  'y long tail with a <a href=3D"https://x.test/link">link</a> and https://x.=',
  "tes=",
  "t/bbbbbbbbbbbbbbbb/logo.png in text <td style=3D\"background:url('https://x=",
  ".test/cccccccccccccccc/bg.png')\">x</td></p>",
];
const QP_MESSAGE = [
  "From: a@example.test",
  "To: b@example.test",
  "Subject: x",
  "List-Unsubscribe: <https://x.test/unsub>",
  "MIME-Version: 1.0",
  'Content-Type: multipart/alternative; boundary="=_b1"',
  "",
  "preamble",
  "--=_b1",
  "Content-Type: text/plain; charset=utf-8",
  "Content-Transfer-Encoding: quoted-printable",
  "",
  "See https://x.test/0123456789abcdef/logo.png caf=C3=A9",
  "",
  "--=_b1",
  "Content-Type: text/html; charset=utf-8",
  "Content-Transfer-Encoding: quoted-printable",
  "",
  ...QP_HTML_LINES,
  "--=_b1--",
  "epilogue",
  "",
].join("\r\n");
// The HTML part as it must decode after the rewrite, written out.
const QP_HTML_WANT =
  `<table><tr><td>lead text lead text lead text lead text <img src="${TO}2494f1185a00ab29/logo.png" alt="Acme"></td></tr></table>` +
  `<p>more text <img src="${TO}aaaaaaaaaaaaaaaa/shield.png"> and a very long tail with a <a href="https://x.test/link">link</a> ` +
  `and https://x.test/bbbbbbbbbbbbbbbb/logo.png in text <td style="background:url('${TO}cccccccccccccccc/bg.png')">x</td></p>`;

// Every resource-loading context, and the near misses that are not.
const CONTEXTS_HTML = [
  `<html><head><style>.h{background-image:url("https://x.test/h/s.png")} .k{background:URL( https://x.test/h/k.png )}</style></head>`,
  `<body background="https://x.test/b/body.png">`,
  `<img SRC="https://x.test/i/a.png" srcset="https://x.test/i/a.png 1x, https://x.test/i/a2.png 2x, https://cdn.example/a3.png 3x" alt="https://x.test/alt">`,
  `<img src=https://x.test/i/unquoted.png data-src="https://x.test/i/lazy.png">`,
  `<table><tr><td style="background-image: url('https://x.test/i/td.png'); color: red">`,
  `<!--[if gte mso 9]><v:rect xmlns:v="urn:schemas-microsoft-com:vml" fill="true" stroke="false" style="width:600px;"><v:fill type="frame" src="https://x.test/v/hero.png" color="#ffffff" /><v:textbox inset="0,0,0,0"><![endif]-->`,
  `<a href="https://x.test/link">Visit https://x.test/ today</a> <p title="url(https://x.test/t)">url(https://x.test/text)</p>`,
  `<img src="https://cdn.example/?u=https://x.test/x.png"></td></tr></table>`,
  `</body></html>`,
].join("\r\n");
const CONTEXTS_WANT = [
  `<html><head><style>.h{background-image:url("${TO}h/s.png")} .k{background:URL( ${TO}h/k.png )}</style></head>`,
  `<body background="${TO}b/body.png">`,
  `<img SRC="${TO}i/a.png" srcset="${TO}i/a.png 1x, ${TO}i/a2.png 2x, https://cdn.example/a3.png 3x" alt="https://x.test/alt">`,
  `<img src=${TO}i/unquoted.png data-src="https://x.test/i/lazy.png">`,
  `<table><tr><td style="background-image: url('${TO}i/td.png'); color: red">`,
  `<!--[if gte mso 9]><v:rect xmlns:v="urn:schemas-microsoft-com:vml" fill="true" stroke="false" style="width:600px;"><v:fill type="frame" src="${TO}v/hero.png" color="#ffffff" /><v:textbox inset="0,0,0,0"><![endif]-->`,
  `<a href="https://x.test/link">Visit https://x.test/ today</a> <p title="url(https://x.test/t)">url(https://x.test/text)</p>`,
  `<img src="https://cdn.example/?u=https://x.test/x.png"></td></tr></table>`,
  `</body></html>`,
].join("\r\n");
const CONTEXTS_COUNT = 9;
const PLAIN_PART = `Content-Type: text/plain\r\n\r\nplain <img src="${FROM}p.png"> ${FROM}q`;

describe("asset origin rewrite", () => {
  it("rewrites resource URLs across quoted-printable soft breaks and escapes, keeping every other byte and 76-character lines", () => {
    for (const l of QP_MESSAGE.split("\r\n")) assert.ok(l.length <= 76, l);
    const input = bytes(QP_MESSAGE);
    const r = rewriteAssetOrigin(input, FROM, TO);
    assert.equal(r.count, 3);
    const out = text(r.bytes);
    const before = pythonLeaves(input);
    const after = pythonLeaves(r.bytes);
    assert.equal(after.length, 2);
    // The literal expectation, checked against the original too.
    assert.equal(before[1]!.body, QP_HTML_WANT.split(TO).join(FROM));
    assert.equal(after[1]!.type, "text/html");
    assert.equal(after[1]!.body, QP_HTML_WANT);
    // The text part, the href and the visible text keep the origin.
    assert.equal(after[0]!.body, before[0]!.body);
    assert.ok(after[0]!.body.includes(FROM));
    // Headers, preamble, delimiters and epilogue are kept byte for byte.
    const head = QP_MESSAGE.slice(0, QP_MESSAGE.indexOf("--=_b1"));
    assert.ok(out.startsWith(head), "headers and preamble unchanged");
    assert.ok(out.includes("<https://x.test/unsub>"), "headers never touched");
    assert.equal(out.split("--=_b1").length, QP_MESSAGE.split("--=_b1").length);
    assert.ok(out.endsWith("--=_b1--\r\nepilogue\r\n"));
    // Lines the rewrite did not touch are the library's own.
    const outLines = new Set(out.split("\r\n"));
    for (const l of QP_MESSAGE.split("\r\n"))
      if (!/src=3D"https|^\/x\.test|^\.test\/c|url\('https/.test(l) && l !== "")
        assert.ok(outLines.has(l), `kept: ${l}`);
    for (const l of out.split("\r\n"))
      assert.ok(l.length <= 76, `${l.length}: ${l}`);
  });

  it("rewrites src, srcset, background, CSS url() in style attributes and <style> blocks, and VML fill src, and nothing else", () => {
    const msg = message([
      `Content-Type: text/html; charset=utf-8\r\n\r\n${CONTEXTS_HTML}`,
      PLAIN_PART,
    ]);
    const r = rewriteAssetOrigin(bytes(msg), FROM, TO);
    assert.equal(r.count, CONTEXTS_COUNT);
    const after = pythonLeaves(r.bytes);
    assert.equal(after[0]!.body, CONTEXTS_WANT);
    // A text/plain part is never rewritten, whatever it holds.
    assert.equal(after[1]!.type, "text/plain");
    assert.equal(after[1]!.body, `plain <img src="${FROM}p.png"> ${FROM}q`);
  });

  it("leaves visible text and an href on the origin unchanged", () => {
    const html = `<p>Visit https://x.test/ today, <a href="https://x.test/a">or here</a> or HREF=https://x.test/b</p>`;
    const msg = message([`Content-Type: text/html\r\n\r\n${html}`]);
    const r = rewriteAssetOrigin(bytes(msg), FROM, TO);
    assert.equal(r.count, 0);
    assert.equal(text(r.bytes), msg);
    assert.deepEqual(resourceOccurrences(html, FROM), []);
  });

  for (const enc of ["quoted-printable", "base64"] as const)
    it(`finds the same contexts in a ${enc} HTML part and rewrites them in that encoding`, () => {
      const encoded =
        enc === "quoted-printable"
          ? pythonQpEncode(CONTEXTS_HTML)
          : Buffer.from(CONTEXTS_HTML, "latin1")
              .toString("base64")
              .match(/.{1,76}/g)!
              .join("\r\n");
      const msg = message([
        `Content-Type: text/html\r\nContent-Transfer-Encoding: ${enc}\r\n\r\n${encoded}`,
        PLAIN_PART,
      ]);
      const r = rewriteAssetOrigin(bytes(msg), FROM, TO);
      assert.equal(r.count, CONTEXTS_COUNT);
      const after = pythonLeaves(r.bytes);
      assert.equal(after[0]!.body, CONTEXTS_WANT);
      assert.equal(after[1]!.body, `plain <img src="${FROM}p.png"> ${FROM}q`);
      const part = text(r.bytes).split("\r\n--=_b1")[1]!;
      assert.match(part, new RegExp(`Content-Transfer-Encoding: ${enc}\r\n`));
      for (const l of part.split("\r\n")) assert.ok(l.length <= 76, l);
    });

  it("rewrites base64 HTML parts at their line length and leaves other parts alone", () => {
    const html = `<p><img src="${FROM}2494f1185a00ab29/logo.png"></p>\n`.repeat(
      4,
    );
    const b64 = Buffer.from(html).toString("base64");
    const lines = b64.match(/.{1,60}/g)!.join("\r\n");
    // Binary content that happens to contain the origin's bytes.
    const binary = Buffer.from(`\x89PNG<img src="${FROM}">not a URL`, "latin1");
    const msg = [
      "MIME-Version: 1.0",
      'Content-Type: multipart/related; boundary="r"',
      "",
      "--r",
      "Content-Type: text/html",
      "Content-Transfer-Encoding: base64",
      "",
      lines,
      "--r",
      "Content-Type: image/png",
      "Content-Transfer-Encoding: base64",
      "",
      binary.toString("base64"),
      "--r",
      "Content-Type: text/plain",
      "",
      `7bit <img src="${FROM}x">`,
      "--r--",
      "",
    ].join("\r\n");
    const r = rewriteAssetOrigin(bytes(msg), FROM, TO);
    assert.equal(r.count, 4);
    const after = pythonLeaves(r.bytes);
    assert.equal(
      after[0]!.body,
      `<p><img src="${TO}2494f1185a00ab29/logo.png"></p>\n`.repeat(4),
    );
    assert.equal(after[1]!.body, binary.toString("latin1"), "image untouched");
    assert.equal(after[2]!.body, `7bit <img src="${FROM}x">`);
    const htmlLines = text(r.bytes)
      .split("\r\n--r")[1]!
      .split("\r\n\r\n")[1]!
      .split("\r\n");
    for (const l of htmlLines.slice(0, -1)) assert.equal(l.length, 60);
  });

  it("descends into nested multiparts (alternative holding related holding the HTML)", () => {
    const msg = [
      "MIME-Version: 1.0",
      'Content-Type: multipart/alternative; boundary="o"',
      "",
      "--o",
      "Content-Type: text/plain",
      "",
      `plain ${FROM}p`,
      "--o",
      'Content-Type: multipart/related; boundary="o2"',
      "",
      "--o2",
      "Content-Type: text/html",
      "Content-Transfer-Encoding: quoted-printable",
      "",
      `<img src=3D"${FROM}a/b.png">`,
      "--o2",
      "Content-Type: image/png",
      "Content-Transfer-Encoding: base64",
      `Content-Location: ${FROM}a/b.png`,
      "",
      Buffer.from(`<img src="${FROM}">`).toString("base64"),
      "--o2--",
      "--o--",
      "",
    ].join("\r\n");
    const r = rewriteAssetOrigin(bytes(msg), FROM, TO);
    assert.equal(r.count, 1);
    const after = pythonLeaves(r.bytes);
    assert.deepEqual(
      after.map((l) => l.type),
      ["text/plain", "text/html", "image/png"],
    );
    assert.equal(after[0]!.body, `plain ${FROM}p`);
    assert.equal(after[1]!.body, `<img src="${TO}a/b.png">`);
    assert.equal(after[2]!.body, `<img src="${FROM}">`);
    assert.ok(text(r.bytes).includes(`Content-Location: ${FROM}a/b.png`));
  });

  it("parses a header-less MIME part as a text/plain body starting after the blank line", () => {
    // The first part has no headers: its boundary line is followed by
    // an empty line, so what looks like a Content-Type header is body
    // text of a text/plain part, and must not be rewritten as HTML.
    const msg = [
      "MIME-Version: 1.0",
      'Content-Type: multipart/mixed; boundary="m"',
      "",
      "--m",
      "",
      "Content-Type: text/html",
      "",
      `<img src="${FROM}a.png">`,
      "--m",
      "Content-Type: text/html",
      "",
      `<img src="${FROM}b.png">`,
      "--m--",
      "",
    ].join("\r\n");
    const r = rewriteAssetOrigin(bytes(msg), FROM, TO);
    assert.equal(r.count, 1);
    const after = pythonLeaves(r.bytes);
    assert.equal(after[0]!.type, "text/plain");
    assert.equal(
      after[0]!.body,
      `Content-Type: text/html\r\n\r\n<img src="${FROM}a.png">`,
    );
    assert.equal(after[1]!.body, `<img src="${TO}b.png">`);
    const p = parseEntity(`\r\nContent-Type: text/html\r\n\r\nbody`);
    assert.equal(p.headers, "\r\n");
    assert.equal(p.contentType, "text/plain");
    assert.equal(p.body, "Content-Type: text/html\r\n\r\nbody");
  });

  it("never splits an =XX escape when re-splitting at the 76-character cut", () => {
    // After the rewrite the merged line has an escape starting at index
    // 73: cutting at 75 (76 with the soft break's "=") would split it.
    const prefix = "a".repeat(38) + '<img src=3D"';
    assert.equal((prefix + TO).length, 73);
    const msg = message([
      [
        "Content-Type: text/html; charset=utf-8",
        "Content-Transfer-Encoding: quoted-printable",
        "",
        prefix + "https://x.te=",
        "st/" + "=C3=A9".repeat(4) + '">',
      ].join("\r\n"),
    ]);
    const r = rewriteAssetOrigin(bytes(msg), FROM, TO);
    assert.equal(r.count, 1);
    const after = pythonLeaves(r.bytes);
    assert.equal(
      after[0]!.body,
      "a".repeat(38) + `<img src="${TO}` + "\xc3\xa9".repeat(4) + '">',
    );
    for (const l of text(r.bytes).split("\r\n")) assert.ok(l.length <= 76, l);
  });

  it("decodes quoted-printable per RFC 2045: an escape is never joined across a soft line break", () => {
    for (const s of ["ab=C=\r\n3D", "x=\r\n=3D", "=3d=3D", "=4", "end="])
      assert.equal(
        decodeQuotedPrintable(s),
        pythonQpDecode(s),
        JSON.stringify(s),
      );
    assert.equal(decodeQuotedPrintable("ab=C=\r\n3D"), "ab=C3D");
  });

  it("the post-check fails a rewrite whose output is wrong", () => {
    const msg = message([
      `Content-Type: text/html\r\n\r\n<img src="${FROM}a.png">`,
      `Content-Type: text/plain\r\n\r\nplain`,
    ]);
    // The rewrite's output replaced by the original: the resource URL
    // is left in the HTML part.
    assert.throws(
      () =>
        rewriteAssetOrigin(bytes(msg), FROM, TO, {
          beforeCheck: () => bytes(msg),
        }),
      /a resource URL on https:\/\/x\.test\/ is left in part 1/,
    );
    // An HTML part changed beyond its resource URLs (an href too).
    assert.throws(
      () =>
        rewriteAssetOrigin(bytes(msg), FROM, TO, {
          beforeCheck: (b) =>
            bytes(text(b).replace("<img", `<a href="${TO}"></a><img`)),
        }),
      /does not decode to the original/,
    );
    // A non-HTML part changed on the way.
    assert.throws(
      () =>
        rewriteAssetOrigin(bytes(msg), FROM, TO, {
          beforeCheck: (b) =>
            bytes(text(b).replace("\r\n\r\nplain", "\r\n\r\nPLAIN")),
        }),
      /not an HTML part but changed/,
    );
    // Directly: an href rewritten too, a part dropped, a header changed.
    const good = rewriteAssetOrigin(bytes(msg), FROM, TO).bytes;
    assert.equal(checkRewrite(bytes(msg), good, FROM, TO), 1);
    const withHref = bytes(
      text(good).replace("<img", `<a href="${TO}"></a><img`),
    );
    assert.throws(
      () => checkRewrite(bytes(msg), withHref, FROM, TO),
      /does not decode to the original/,
    );
    assert.throws(
      () => checkRewrite(bytes(msg), bytes(msg), FROM, TO),
      /is left in part 1/,
    );
    assert.throws(
      () =>
        checkRewrite(
          bytes(msg),
          bytes(
            text(good).replace(
              "Content-Type: text/plain",
              "Content-Type: text/plain; x=1",
            ),
          ),
          FROM,
          TO,
        ),
      /headers of part 2/,
    );
    assert.throws(
      () =>
        checkRewrite(
          bytes(msg),
          bytes(
            message([`Content-Type: text/html\r\n\r\n<img src="${TO}a.png">`]),
          ),
          FROM,
          TO,
        ),
      /1 parts after the rewrite, 2 before/,
    );
  });

  it("refuses what it cannot rewrite instead of skipping it", () => {
    const html = `<img src="${FROM}a.png">`;
    for (const [what, msg, re] of [
      [
        "an HTML part in an unknown transfer encoding",
        message([
          `Content-Type: text/html\r\nContent-Transfer-Encoding: x-uuencode\r\n\r\n${html}`,
        ]),
        /transfer encoding x-uuencode/,
      ],
      [
        "a UTF-16 HTML part",
        message([`Content-Type: text/html; charset=UTF-16\r\n\r\n${html}`]),
        /charset utf-16/,
      ],
      [
        "a multipart without its closing delimiter",
        message([`Content-Type: text/html\r\n\r\n${html}`]).replace(
          "--=_b1--\r\n",
          "",
        ),
        /closing delimiter/,
      ],
      [
        "a multipart without a boundary",
        `MIME-Version: 1.0\r\nContent-Type: multipart/mixed\r\n\r\n${html}\r\n`,
        /without a boundary/,
      ],
    ] as const)
      assert.throws(() => rewriteAssetOrigin(bytes(msg), FROM, TO), re, what);
  });

  it("leaves a message without the origin byte for byte as it was", () => {
    // Every spelling of the origin in it, across soft breaks too.
    const msg = QP_MESSAGE.replaceAll("//x", "//y").replaceAll(
      "\r\n/x.test",
      "\r\n/y.test",
    );
    assert.ok(!pythonLeaves(bytes(msg)).some((l) => l.body.includes(FROM)));
    const r = rewriteAssetOrigin(bytes(msg), FROM, TO);
    assert.equal(r.count, 0);
    assert.equal(text(r.bytes), msg);
  });

  it("refuses a target quoted-printable cannot carry literally", () => {
    assert.throws(
      () => rewriteAssetOrigin(bytes(QP_MESSAGE), FROM, "http://h/?a=b"),
      /printable ASCII without "="/,
    );
  });
});

// Character references in attribute values. The library's serialiser
// escapes attribute values, style included, with this table (copied
// verbatim from its attribute escaper): '"' -> "&quot;", "&" ->
// "&amp;", "'" -> "&#x27;", "<" -> "&lt;". So a quoted url() in a style
// attribute reaches the mail as url(&quot;…&quot;), which a parser
// decodes before the browser loads it.
function serialiserEscape(v: string): string {
  return v.replace(/["&'<]/g, (c) =>
    c === '"' ? "&quot;" : c === "&" ? "&amp;" : c === "'" ? "&#x27;" : "&lt;",
  );
}

// The attribute values of every start tag, decoded by Python's
// html.parser (an HTML decoder independent of the rewrite's): one
// [tag, name, value] per attribute, in document order.
function pythonAttrs(html: string): [string, string, string][] {
  const r = spawnSync(
    "python3",
    [
      "-c",
      [
        "import sys, json",
        "from html.parser import HTMLParser",
        "out = []",
        "class P(HTMLParser):",
        "    def handle_starttag(self, tag, attrs):",
        "        out.extend([tag, k, v or ''] for k, v in attrs)",
        "    handle_startendtag = handle_starttag",
        "p = P(convert_charrefs=True)",
        "p.feed(sys.stdin.buffer.read().decode('latin1'))",
        "p.close()",
        "json.dump(out, sys.stdout)",
      ].join("\n"),
    ],
    { input: Buffer.from(html, "latin1"), encoding: "utf8" },
  );
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout) as [string, string, string][];
}

// Python's html.unescape: the reference decoding of character references.
function pythonUnescape(s: string): string {
  const r = spawnSync(
    "python3",
    [
      "-c",
      "import sys, html, json; print(json.dumps(html.unescape(json.loads(sys.stdin.read()))))",
    ],
    { input: JSON.stringify(s), encoding: "utf8" },
  );
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout) as string;
}

// A message produced by the library itself (the story render pipeline,
// then toMessage and toRfc5322 at the capture clock), kept verbatim: a
// table cell styled `background: url("https://x.test/a/hero.png")
// #ffffff` and a paragraph styled `background:
// url('https://x.test/a/q.png')`. The serialiser wrote the quotes as
// &quot; and &#x27;, and quoted-printable split the first URL across a
// soft line break.
const SERIALISED_LINES = [
  "MIME-Version: 1.0",
  "Date: Thu, 01 Jan 2026 12:00:00 +0000",
  "From: IsoNim Shots <shots@example.test>",
  "To: qa@example.test",
  "Subject: [shots] bg",
  "Message-ID: <bg.8c4903e73ab834b8@example.test>",
  'Content-Type: multipart/alternative; boundary="=_e_bg_5d07635501d5"',
  "",
  "--=_e_bg_5d07635501d5",
  "Content-Type: text/plain; charset=utf-8; format=flowed",
  "Content-Transfer-Encoding: quoted-printable",
  "",
  "Hero",
  "",
  "--=_e_bg_5d07635501d5",
  "Content-Type: text/html; charset=utf-8",
  "Content-Transfer-Encoding: quoted-printable",
  "",
  '<!doctype html><html lang=3D"en" dir=3D"ltr" xmlns=3D"http://www.w3.org/199=',
  '9/xhtml" xmlns:v=3D"urn:schemas-microsoft-com:vml" xmlns:o=3D"urn:schemas-m=',
  'icrosoft-com:office:office"><head><meta charset=3D"utf-8"><meta name=3D"vie=',
  'wport" content=3D"width=3Ddevice-width, initial-scale=3D1, user-scalable=3D=',
  'yes"><!--[if !mso]><!--><meta http-equiv=3D"X-UA-Compatible" content=3D"IE=',
  '=3Dedge"><!--<![endif]--><meta name=3D"format-detection" content=3D"telepho=',
  'ne=3Dno, date=3Dno, address=3Dno, email=3Dno, url=3Dno"><meta name=3D"x-app=',
  'le-disable-message-reformatting"><meta name=3D"color-scheme" content=3D"lig=',
  'ht dark"><meta name=3D"supported-color-schemes" content=3D"light dark"><tit=',
  "le>Bg</title><!--[if mso]><noscript><xml><o:OfficeDocumentSettings><o:Allow=",
  "PNG/><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml>=",
  "</noscript><![endif]--><style>html,body{margin:0 auto !important;padding:0 =",
  "!important;height:100% !important;width:100% !important;}*{-ms-text-size-ad=",
  'just:100%;-webkit-text-size-adjust:100%;}div[style*=3D"margin: 16px 0"]{mar=',
  "gin:0 !important;}#MessageViewBody,#MessageWebViewDiv{width:100% !important=",
  ";}table,td{mso-table-lspace:0pt !important;mso-table-rspace:0pt !important;=",
  "}table{border-spacing:0 !important;border-collapse:collapse !important;tabl=",
  "e-layout:fixed !important;margin:0 auto !important;}img{-ms-interpolation-m=",
  "ode:bicubic;border:0;height:auto;line-height:100%;outline:none;text-decorat=",
  "ion:none;}a{text-decoration:none;}#outlook a{padding:0;}a[x-apple-data-dete=",
  "ctors],.unstyle-auto-detected-links a,.aBn{border-bottom:0 !important;curso=",
  "r:default !important;color:inherit !important;text-decoration:none !importa=",
  "nt;font-size:inherit !important;font-family:inherit !important;font-weight:=",
  "inherit !important;line-height:inherit !important;}.im{color:inherit !impor=",
  "tant;}.a6S{display:none !important;opacity:0.01 !important;}img.g-img+div{d=",
  "isplay:none !important;}</style><!--[if lte mso 11]><style>.e-mso-group-fix=",
  '{width:100% !important;}</style><![endif]--></head><body class=3D"body" xml=',
  ':lang=3D"en" style=3D"margin:0;padding:0;word-spacing:normal;background-col=',
  'or:#ffffff;"><div style=3D"display:none;font-size:1px;color:#ffffff;line-he=',
  'ight:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;">=',
  'Background probe.</div><div style=3D"display:none;font-size:1px;line-height=',
  ':1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;" aria=',
  '-hidden=3D"true">&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#84=',
  "7;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&=",
  "zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwn=",
  "j;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&=",
  "nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbs=",
  "p;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&=",
  "#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#84=",
  "7;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&=",
  "zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwn=",
  "j;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&=",
  "nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbs=",
  "p;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&=",
  "#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#84=",
  "7;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&=",
  "zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwn=",
  "j;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&=",
  "nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbs=",
  "p;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&=",
  "#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#84=",
  "7;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&=",
  'zwnj;&nbsp;</div><div role=3D"article" aria-roledescription=3D"email" aria-=',
  'label=3D"Bg" lang=3D"en" dir=3D"ltr" style=3D"background-color:#ffffff;font=',
  '-size:medium;font-size:max(16px, 1rem);"><table role=3D"presentation" width=',
  '=3D"100%" border=3D"0" cellpadding=3D"0" cellspacing=3D"0" style=3D"backgro=',
  'und-color:#ffffff;"><tr><td align=3D"center"><div><h1>Bg</h1><table role=3D=',
  '"presentation" style=3D"mso-table-lspace:0pt;mso-table-rspace:0pt;"><tr><td=',
  ' bgcolor=3D"#ffffff" style=3D"background:url(&quot;https://x.test/a/hero.pn=',
  'g&quot;);background-color:#ffffff;">Hero</td></tr></table><p style=3D"backg=',
  'round:url(&#x27;https://x.test/a/q.png&#x27;);">Q</p></div></td></tr></tabl=',
  "e></div></body></html>",
  "--=_e_bg_5d07635501d5--",
];
const SERIALISED = SERIALISED_LINES.join("\r\n") + "\r\n";

function htmlMessage(html: string): string {
  return message([`Content-Type: text/html\r\n\r\n${html}`]);
}

describe("asset origin rewrite: character references in attribute values", () => {
  it("rewrites a library-rendered message whose style attributes quote url() with &quot; and &#x27;", () => {
    const r = rewriteAssetOrigin(bytes(SERIALISED), FROM, TO);
    assert.equal(r.count, 2);
    const before = pythonLeaves(bytes(SERIALISED));
    const after = pythonLeaves(r.bytes);
    assert.equal(after.length, 2);
    assert.equal(after[0]!.body, before[0]!.body, "text part untouched");
    // Only the two URLs changed, with the same escaping around them.
    assert.equal(
      after[1]!.body,
      before[1]!.body
        .replace(
          "url(&quot;https://x.test/a/hero.png&quot;)",
          `url(&quot;${TO}a/hero.png&quot;)`,
        )
        .replace(
          "url(&#x27;https://x.test/a/q.png&#x27;)",
          `url(&#x27;${TO}a/q.png&#x27;)`,
        ),
    );
    // As an HTML parser decodes the styles: the target is what loads.
    const styles = pythonAttrs(after[1]!.body)
      .filter(([, k, v]) => k === "style" && v.includes("url("))
      .map(([tag, , v]) => [tag, v]);
    assert.deepEqual(styles, [
      ["td", `background:url("${TO}a/hero.png");background-color:#ffffff;`],
      ["p", `background:url('${TO}a/q.png');`],
    ]);
    for (const l of text(r.bytes).split("\r\n")) assert.ok(l.length <= 76, l);
  });

  it("matches the serialiser's escaping: &quot;, &#x27; and &#x2F; in src, poster and style, and a string @import in <style>", () => {
    const html = [
      `<style>@import "https://x.test/s/a.css"; @import 'https://x.test/s/b.css';</style>`,
      `<td style="${serialiserEscape('background:url("https://x.test/i/q.png")')}">`,
      `<td style="${serialiserEscape("background:url('https://x.test/i/a.png')")}">`,
      `<img src="https:&#x2F;&#x2F;x.test/i/s.png">`,
      `<img src="&#104;ttps&#58;//X.TEST/i/d.png" srcset="https:&sol;&sol;x.test/i/e.png 2x">`,
      `<video poster="https:&#x2F;&#x2F;x.test/v.png"></video>`,
    ].join("");
    const r = rewriteAssetOrigin(bytes(htmlMessage(html)), FROM, TO);
    assert.equal(r.count, 8);
    const got = pythonLeaves(r.bytes)[0]!.body;
    assert.equal(
      got,
      [
        `<style>@import "${TO}s/a.css"; @import '${TO}s/b.css';</style>`,
        `<td style="background:url(&quot;${TO}i/q.png&quot;)">`,
        `<td style="background:url(&#x27;${TO}i/a.png&#x27;)">`,
        `<img src="${TO}i/s.png">`,
        `<img src="${TO}i/d.png" srcset="${TO}i/e.png 2x">`,
        `<video poster="${TO}v.png"></video>`,
      ].join(""),
    );
    assert.deepEqual(
      pythonAttrs(got).map(([, , v]) => v),
      [
        `background:url("${TO}i/q.png")`,
        `background:url('${TO}i/a.png')`,
        `${TO}i/s.png`,
        `${TO}i/d.png`,
        `${TO}i/e.png 2x`,
        `${TO}v.png`,
      ],
    );
  });

  it("writes a replacement into an attribute value escaped like the serialiser", () => {
    const to = "http://h/a&b/";
    const html = `<p style="${serialiserEscape('background:url("https://x.test/x.png")')}">x</p><style>.a{background:url(https://x.test/y.png)}</style>`;
    const r = rewriteAssetOrigin(bytes(htmlMessage(html)), FROM, to);
    assert.equal(r.count, 2);
    const got = pythonLeaves(r.bytes)[0]!.body;
    assert.equal(
      got,
      `<p style="background:url(&quot;http://h/a&amp;b/x.png&quot;)">x</p><style>.a{background:url(http://h/a&b/y.png)}</style>`,
    );
    assert.deepEqual(pythonAttrs(got), [
      ["p", "style", 'background:url("http://h/a&b/x.png")'],
    ]);
  });

  it("keeps an href, a title, a data attribute and visible text that spell the origin with character references", () => {
    const html = `<a href="https:&#x2F;&#x2F;x.test/l" title="url(&quot;https://x.test/t&quot;)">https:&#x2F;&#x2F;x.test/v</a> <p data-bg="url(&quot;https://x.test/d&quot;)">&quot;https://x.test/q&quot;</p>`;
    const msg = htmlMessage(html);
    // The oracle agrees the href does point at the origin once decoded.
    assert.equal(pythonAttrs(html)[0]![2], "https://x.test/l");
    const r = rewriteAssetOrigin(bytes(msg), FROM, TO);
    assert.equal(r.count, 0);
    assert.equal(text(r.bytes), msg);
    assert.equal(leftoverResource(html, FROM), null);
  });

  it("decodes character references in attribute values as Python's html.unescape does", () => {
    for (const s of [
      "&quot;a&#x27;b&#47;&#X2F;&sol;&colon;&amp;&lt;&gt;&apos;&#0000104;",
      "url(&quot)&amp x &#x68&#116tps&#x3A//",
      "&nosuchref; &amp;amp; &#0; &#x110000; &Tab;&NewLine;&period;",
    ])
      assert.equal(decodeAttrValue(s), pythonUnescape(s), s);
    // In an attribute value a reference without ";" is not decoded
    // before "=" (the HTML attribute rule).
    assert.equal(decodeAttrValue("a&amp=b&quot"), 'a&amp=b"');
    // The scanner reads attribute values the same way.
    for (const v of [
      "&#x68&#116tps&#x3A//x.test/a",
      "https&colon;&sol;/x&period;test/a",
    ]) {
      assert.equal(decodeAttrValue(v), "https://x.test/a");
      assert.equal(resourceOccurrences(`<img src="${v}">`, FROM).length, 1, v);
    }
    assert.deepEqual(
      resourceOccurrences(`<img src="https&colon=//x.test/">`, FROM),
      [],
    );
  });

  it("the post-check decodes on its own: an encoded URL left in place, a CSS-escaped URL and an image-set() string all fail the rewrite", () => {
    const encoded = htmlMessage(
      `<img src="https:&#x2F;&#x2F;x.test/a.png"><p style="background:url(&quot;https://x.test/b.png&quot;)">x</p>`,
    );
    // The original handed back as the "rewritten" message: both URLs
    // are still there, spelled with character references.
    assert.throws(
      () => checkRewrite(bytes(encoded), bytes(encoded), FROM, TO),
      /a resource URL on https:\/\/x\.test\/ is left in part 1 .*<img src>/,
    );
    assert.throws(
      () =>
        rewriteAssetOrigin(bytes(encoded), FROM, TO, {
          beforeCheck: (b) =>
            bytes(
              text(b).replace(`${TO}b.png`, "https:&#x2F;&#x2F;x.test/b.png"),
            ),
        }),
      /is left in part 1 .*<p style>/,
    );
    // Spellings the rewrite does not handle are refused, not skipped:
    // its scanner finds nothing, and the post-check still sees them.
    for (const html of [
      "<style>.a{background:url(https\\:\\/\\/x.test/a.png)}</style>",
      `<td style="background-image:image-set(&quot;https://x.test/a.png&quot; 1x)">`,
    ]) {
      assert.deepEqual(resourceOccurrences(html, FROM), [], html);
      assert.throws(
        () => rewriteAssetOrigin(bytes(htmlMessage(html)), FROM, TO),
        /is left in part 1 .*(<style>|<td style>)/,
        html,
      );
    }
    // A comment opener inside a CSS string is not a comment.
    const strings = `<style>.a{content:"/*"}.b{background:url(https://x.test/a.png)}.c{content:"*/"}</style>`;
    assert.throws(
      () =>
        rewriteAssetOrigin(bytes(htmlMessage(strings)), FROM, TO, {
          beforeCheck: () => bytes(htmlMessage(strings)),
        }),
      /is left in part 1 .*<style>/,
    );
  });
});
