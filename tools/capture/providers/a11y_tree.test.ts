// tools/capture/providers/a11y_tree.test.ts — what the hosted-webmail
// captures read from the browser's accessibility tree, on synthetic
// trees shaped as GuiAssert reports Chrome's.
//
// What is proven: a locator matches on every field it gives and only on
// showing nodes; the address bar's value and its host (with or without
// the scheme Chrome hides) are read; the story's visible text leaves out
// the hidden preheader, the head and styles, keeps image alt text and
// decodes entities; the story region is the message column between the
// webmail's elements above and below the story's text (Chrome prunes the
// containers a body sits in), counting other text inside it, ignoring
// story text above the subject or inside a control, and absent when no
// leaf carries the story's text; the fingerprint ignores names, text and
// what it is told to skip, but not the page's structure;
// masks are painted clipped to the crop, and nothing is re-encoded
// without one; the mean luminance tells dark from light. The address bar
// holds a URL when it does percent-decoded (Chrome shows a fragment's
// `:` and `@` unescaped). A message's row is found by the run token in
// its accessible text (its name, or its cells' text when Chrome names it
// after the sender alone), by the first row locator that has one, only
// inside the page, never in an editable field, the address bar, a
// suggestions list a row locator does not match, a nested row, or a row
// of another run; the token on the page outside any row is reported. A
// failure's tree summary keeps showing nodes only, clipped, capped, with
// the account's address replaced.
// Run with:
//   node --test tools/capture/providers/a11y_tree.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readPng, writePng } from "../contact_sheet.ts";
import {
  addressBarValue,
  carriesToken,
  clickTarget,
  clipText,
  findShowing,
  flatten,
  insideRect,
  locateStoryRegion,
  locationHost,
  matches,
  MASK_RGB,
  meanLuminance,
  paintMasks,
  percentDecoded,
  rowText,
  sameLocation,
  storyTexts,
  structureFingerprint,
  tokenNodes,
  tokenRows,
  treeSummary,
} from "./a11y_tree.ts";
import type { GaNode, Rect } from "./guiassert.ts";
import { WEBMAIL_CHROME } from "./webmail_adapters.ts";

let paths = 0;
function n(
  role: string,
  nativeRole: string,
  name: string | null,
  bounds: Rect | null,
  children: GaNode[] = [],
  extra: Partial<GaNode> = {},
): GaNode {
  return {
    path: `/app[1]/n[${paths++}]`,
    role,
    nativeRole,
    name,
    bounds,
    states: ["visible", "enabled"],
    children,
    ...extra,
  };
}
// A static text leaf as Chrome exposes it: its name is its text.
const text = (t: string, b: Rect): GaNode =>
  n("label", "static", t, b, [], { text: t });

const TOKEN = "[es:run1:abcd1234]";
const STORY = `<html><head><title>Receipt</title><style>p{color:red}</style></head><body><div style="display:none;max-height:0">Preheader words</div><table role="presentation"><tr><td><img src="x.png" alt="Acme logo"></td></tr><tr><td><p>Your receipt &amp; invoice</p><p>Total:&nbsp;12&euro;</p></td></tr></table><p>Thank you.</p></body></html>`;

// A Gmail-like opened message as Chrome exposes it (measured
// 2026-10-31): the generic containers pruned, so the toolbar, the
// subject, the sender line and the body's leaves are all children of the
// document; Reply and Forward after the body; the folder list at the left.
function opened(
  over: { foreign?: boolean; bodyHidden?: boolean; trailing?: boolean } = {},
) {
  // A centred 600 px story: its leaves are narrower than the column.
  const body = [
    n("image", "image", "Acme logo", [320, 210, 120, 40]),
    text("Your receipt & invoice", [320, 260, 300, 20]),
    ...(over.foreign === true
      ? [text("Translated by the webmail", [320, 290, 300, 10])]
      : []),
    text("Total: 12€", [340, 380, 200, 20]),
    text("Thank you.", [320, 420, 200, 20]),
  ];
  const subject = n(
    "label",
    "heading",
    `${TOKEN} Your receipt`,
    [220, 130, 800, 30],
  );
  const doc = n(
    "unknown",
    "document web",
    null,
    [0, 80, 1240, 2300],
    [
      text("Inbox", [10, 300, 100, 20]),
      n(
        "toolbar",
        "tool bar",
        null,
        [220, 90, 800, 30],
        [n("button", "push button", "Delete", [230, 95, 60, 20])],
      ),
      subject,
      text("Acme Billing", [220, 175, 120, 20]),
      n("button", "push button", "Reply", [900, 175, 60, 20]),
      ...(over.bodyHidden === true ? [] : body),
      ...(over.trailing === false
        ? []
        : [
            n("button", "push button", "Reply", [220, 720, 80, 30]),
            n("button", "push button", "Forward", [320, 720, 80, 30]),
          ]),
    ],
  );
  const root = n("application", "application", "Google Chrome", null, [
    n(
      "window",
      "frame",
      "Gmail",
      [0, 0, 1240, 2400],
      [
        n(
          "text-field",
          "entry",
          "Address and search bar",
          [140, 50, 900, 26],
          [],
          {
            text: "127.0.0.1:4711/mail/u/0/#inbox",
          },
        ),
        doc,
      ],
    ),
  ]);
  const flat = flatten(root);
  const find = (x: GaNode) => flat.find((f) => f.node === x)!;
  return { flat, doc: find(doc), subject: find(subject) };
}

describe("locators and the address bar", () => {
  it("match on every given field, and only showing nodes are found", () => {
    const a = n("button", "push button", "Delete forever", [0, 0, 10, 10]);
    assert.ok(matches(a, { role: "button" }));
    assert.ok(matches(a, { role: "button", name: "Delete forever" }));
    assert.ok(!matches(a, { role: "button", name: "Delete" }));
    assert.ok(matches(a, { nameContains: "forever" }));
    assert.ok(!matches(a, { nameContains: "Forever" }));
    assert.ok(matches(a, { namePattern: "^delete" }));
    assert.ok(!matches(a, { nativeRole: "toggle button" }));
    assert.ok(!matches(a, { role: "link", name: "Delete forever" }));
    const off = n("button", "push button", "Delete", [0, 0, 10, 10], [], {
      states: ["visible", "offscreen"],
    });
    const nob = n("button", "push button", "Delete", null);
    const on = n("button", "push button", "Delete", [5, 5, 10, 10]);
    const flat = flatten(
      n("application", "application", "x", null, [off, nob, on]),
    );
    assert.deepEqual(
      findShowing(flat, { role: "button", name: "Delete" }).map((f) => f.node),
      [on],
    );
  });

  it("reads the address bar and its host, with or without the scheme", () => {
    assert.equal(
      addressBarValue(opened().flat),
      "127.0.0.1:4711/mail/u/0/#inbox",
    );
    assert.equal(
      locationHost("127.0.0.1:4711/mail/u/0/#inbox"),
      "127.0.0.1:4711",
    );
    assert.equal(locationHost("mail.google.com/mail/u/0/"), "mail.google.com");
    assert.equal(
      locationHost("https://outlook.live.com/mail/0/inbox"),
      "outlook.live.com",
    );
    assert.equal(locationHost("Search Google or type a URL"), null);
    assert.equal(locationHost(""), null);
    assert.ok(
      sameLocation(
        "127.0.0.1:4711/mail/u/0/#search/a",
        "http://127.0.0.1:4711/mail/u/0/#search/a",
      ),
    );
    assert.ok(
      sameLocation(
        "mail.yahoo.com/d/folders/1",
        "https://mail.yahoo.com/d/folders/1/",
      ),
    );
    assert.ok(
      !sameLocation(
        "mail.yahoo.com/d/folders/1",
        "https://mail.yahoo.com/d/folders/6",
      ),
    );
    assert.ok(!sameLocation(null, "https://mail.yahoo.com/"));
  });

  it("compares the address bar percent-decoded: Chrome shows a fragment's ':' and '@' unescaped", () => {
    const typed =
      "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Arun.abcd.n1%40render-test.example";
    assert.ok(
      sameLocation(
        "mail.google.com/mail/u/0/#search/rfc822msgid:run.abcd.n1@render-test.example",
        typed,
      ),
    );
    assert.ok(sameLocation(typed.replace("https://", ""), typed));
    // A token search, shown unescaped too.
    assert.ok(
      sameLocation(
        'mail.google.com/mail/u/0/#search/"[es:run1:abcd1234]"',
        "https://mail.google.com/mail/u/0/#search/%22%5Bes%3Arun1%3Aabcd1234%5D%22",
      ),
    );
    // Another message's id is another location.
    assert.ok(
      !sameLocation(
        "mail.google.com/mail/u/0/#search/rfc822msgid:other@render-test.example",
        typed,
      ),
    );
    assert.equal(percentDecoded("a%3Ab%40c"), "a:b@c");
    // An invalid escape is kept as it is.
    assert.equal(percentDecoded("100%zz%E2"), "100%zz%E2");
  });
});

// A list page as Chrome exposes it: the address bar (holding a token
// search), the page's document with a search field holding the query,
// a suggestions list echoing it, and a grid of rows.
function list(
  over: {
    rowName?: "content" | "sender";
    otherRun?: boolean;
    nested?: boolean;
    noRows?: boolean;
  } = {},
) {
  const row = (subject: string, y: number): GaNode =>
    n(
      "row",
      "table row",
      over.rowName === "sender" ? "Acme Billing" : `Acme Billing ${subject}`,
      [220, y, 800, 30],
      [
        n("cell", "table cell", null, [220, y, 200, 30], [], {
          text: "Acme Billing",
        }),
        n("cell", "table cell", null, [420, y, 600, 30], [], {
          text: `${subject} - Preheader words`,
        }),
      ],
    );
  const rows = over.noRows
    ? []
    : [
        row("Weekly digest", 300),
        row(
          over.otherRun === true
            ? "[es:run0:abcd1234] Your receipt"
            : `${TOKEN} Your receipt`,
          330,
        ),
      ];
  if (over.nested === true)
    rows[1]!.children.push(
      n("row", "table row", `${TOKEN} quoted`, [420, 340, 100, 10]),
    );
  const doc = n(
    "unknown",
    "document web",
    null,
    [0, 80, 1240, 2300],
    [
      n("text-field", "entry", "Search mail", [220, 90, 600, 26], [], {
        value: `"${TOKEN}"`,
      }),
      n(
        "list",
        "list box",
        "Search suggestions",
        [220, 116, 600, 30],
        [n("list-item", "list item", `"${TOKEN}"`, [220, 116, 600, 30])],
      ),
      n("table", "table", null, [220, 300, 800, 60], rows),
    ],
  );
  const root = n("application", "application", "Google Chrome", null, [
    n(
      "window",
      "frame",
      "Gmail",
      [0, 0, 1240, 2400],
      [
        n(
          "text-field",
          "entry",
          "Address and search bar",
          [140, 50, 900, 26],
          [],
          { text: `mail.google.com/mail/u/0/#search/"${TOKEN}"` },
        ),
        // Chrome's own popup under the address bar.
        n(
          "list",
          "list box",
          null,
          [140, 76, 900, 30],
          [
            n(
              "list-item",
              "list item",
              `"${TOKEN}" - Search`,
              [140, 76, 900, 30],
            ),
          ],
        ),
        doc,
      ],
    ),
  ]);
  const flat = flatten(root);
  return { flat, doc: flat.find((f) => f.node === doc)! };
}

describe("a message's row, by the run token", () => {
  const ROW = [{ role: "row" }];

  it("is the row whose accessible text carries the token: its name, or its cells when Chrome names it after the sender", () => {
    for (const rowName of ["content", "sender"] as const) {
      const { flat, doc } = list({ rowName });
      const r = tokenRows(flat, ROW, TOKEN, doc);
      assert.equal(r.rows.length, 1, rowName);
      assert.equal(r.rows[0]!.node.bounds![1], 330);
      assert.equal(r.locator, 0);
      assert.equal(r.seen.length, 2, "both rows seen");
    }
    // The row's text joins its name and its cells' text.
    const { flat, doc } = list({ rowName: "sender" });
    const row = tokenRows(flat, ROW, TOKEN, doc).rows[0]!;
    assert.match(rowText(row.node), /^Acme Billing Acme Billing \[es:run1/);
  });

  it("is never the search field, the suggestions list, the address bar or Chrome's popup, a nested row, or another run's row", () => {
    // Only look-alikes carry the token: no row is found.
    const none = list({ otherRun: true });
    assert.deepEqual(tokenRows(none.flat, ROW, TOKEN, none.doc).rows, []);
    // A row locator that matches list items still stays inside the
    // page: Chrome's popup under the address bar is never a row.
    const items = tokenRows(
      none.flat,
      [{ role: "list-item" }],
      TOKEN,
      none.doc,
    );
    assert.deepEqual(
      items.rows.map((f) => f.node.name),
      [`"${TOKEN}"`],
      "only the page's own suggestion, which the Gmail adapter's row locator does not match",
    );
    // Without a page scope the popup would be taken too.
    assert.equal(
      tokenRows(none.flat, [{ role: "list-item" }], TOKEN, null).rows.length,
      2,
    );
    // A row inside a row is the outer row's part, not a second message.
    const nested = list({ nested: true });
    assert.equal(tokenRows(nested.flat, ROW, TOKEN, nested.doc).rows.length, 1);
    // An editable field inside a row (an inline reply holding the
    // token) is not the row's text.
    const reply = flatten(
      n(
        "unknown",
        "document web",
        null,
        [0, 0, 900, 900],
        [
          n(
            "row",
            "table row",
            "Acme Billing",
            [0, 10, 900, 30],
            [
              n("text-field", "entry", "Reply", [0, 10, 400, 30], [], {
                text: `Re: ${TOKEN}`,
              }),
            ],
          ),
        ],
      ),
    );
    assert.deepEqual(tokenRows(reply, ROW, TOKEN, reply[0]!).rows, []);
    assert.deepEqual(tokenNodes(reply, TOKEN), []);
    // The token is matched whole: a longer token is another message.
    assert.ok(!carriesToken("Re [es:run1:abcd12345]", TOKEN));
    assert.ok(carriesToken("Acme [ES:RUN1:ABCD1234] x", TOKEN));
  });

  it("takes the first row locator that finds one, and reports the token outside any row", () => {
    const { flat, doc } = list();
    const r = tokenRows(flat, [{ role: "link" }, { role: "row" }], TOKEN, doc);
    assert.equal(r.locator, 1);
    assert.equal(r.rows.length, 1);
    const empty = list({ noRows: true });
    const r2 = tokenRows(empty.flat, ROW, TOKEN, empty.doc);
    assert.deepEqual([r2.rows, r2.seen, r2.locator], [[], [], null]);
    // The token is on the page (the suggestion), and in the address
    // bar's popup: the search record names where.
    assert.deepEqual(
      tokenNodes(empty.flat, TOKEN).map((f) => f.node.role),
      ["list-item", "list-item"],
    );
  });
});

describe("a failure's tree summary", () => {
  it("keeps the showing nodes, clipped and capped, the address bar's value, and never the account's address", () => {
    const addr = "qa-1@receiver.invalid";
    const { flat } = list();
    const long = "x".repeat(400);
    flat[flat.length - 1]!.node.name =
      `Signed in as ${addr.toUpperCase()} ${long}`;
    const hidden = n("button", "push button", "Hidden", [0, 0, 5, 5], [], {
      states: ["visible", "offscreen"],
    });
    flat.push({ node: hidden, parent: null, depth: 0, order: flat.length });
    const s = treeSummary(
      {
        flat,
        location: `mail.google.com/#search/to:${addr}`,
        nodes: 99,
        truncated: false,
        ms: 12.4,
      },
      [addr],
    );
    assert.equal(s.schema, "isonim-email/a11y-summary/1");
    assert.equal(s.location, "mail.google.com/#search/to:<account address>");
    assert.equal(s.nodes, 99);
    assert.equal(s.read_ms, 12);
    assert.ok(!JSON.stringify(s).toLowerCase().includes(addr));
    assert.ok(!s.showing.some((x) => x.name === "Hidden"));
    assert.equal(s.showing_count, s.showing.length);
    const clipped = s.showing.find((x) => x.name.startsWith("Signed in as"))!;
    assert.equal(clipped.name.length, 161);
    assert.ok(clipped.name.endsWith("…"));
    assert.ok(clipped.name.includes("<account address>"));
    assert.ok(s.showing.some((x) => x.value === `"${TOKEN}"`));
    const capped = treeSummary(
      { flat, location: null, nodes: 1, truncated: true, ms: 0 },
      [],
      3,
    );
    assert.equal(capped.showing.length, 3);
    assert.ok(capped.showing_count > 3);
    assert.equal(clipText(" a\n  b ", 10), "a b");
  });

  it("replaces the address percent-encoded too, and never keeps a password field's value", () => {
    const addr = "qa-1@receiver.invalid";
    const { flat } = list();
    const pw = n(
      "password-text",
      "password text",
      "Password",
      [10, 10, 200, 20],
      [],
      { value: "secret-value" },
    );
    flat.push({ node: pw, parent: null, depth: 0, order: flat.length });
    const s = treeSummary(
      {
        flat,
        location: `login.live.com/oauth?login_hint=${encodeURIComponent(addr)}&x=1`,
        nodes: 9,
        truncated: false,
        ms: 1,
      },
      [addr],
    );
    assert.equal(
      s.location,
      "login.live.com/oauth?login_hint=<account address>&x=1",
    );
    const field = s.showing.find((x) => x.name === "Password")!;
    assert.equal(field.value, "");
    assert.ok(!JSON.stringify(s).includes("secret-value"));
    assert.equal(
      clipText(`to QA-1%40RECEIVER.invalid`, 80, [addr]),
      "to <account address>",
    );
  });
});

describe("where a row is clicked", () => {
  it("is its deepest showing text carrying the token, else its own box", () => {
    // A link wrapped over two lines: its box's centre is on neither.
    const subject = text(`${TOKEN} Your receipt`, [600, 300, 200, 20]);
    const row = n(
      "link",
      "link",
      `Acme ${TOKEN} Your receipt preview`,
      [220, 300, 800, 44],
      [
        text("Acme", [220, 300, 60, 20]),
        n(
          "group",
          "section",
          `${TOKEN} Your receipt`,
          [580, 296, 240, 28],
          [subject],
        ),
        text("preview", [220, 324, 80, 20]),
      ],
    ) as GaNode & { bounds: Rect };
    assert.deepEqual(clickTarget(row, TOKEN), [600, 300, 200, 20]);
    subject.states = ["visible", "offscreen"];
    assert.deepEqual(clickTarget(row, TOKEN), [580, 296, 240, 28]);
    assert.deepEqual(clickTarget(row, "[es:other]"), [220, 300, 800, 44]);
  });
});

describe("the story's text", () => {
  it("is the visible text by block: no preheader, head or style; alt text kept; entities decoded", () => {
    assert.deepEqual(storyTexts(STORY), [
      "Acme logo",
      "Your receipt & invoice",
      "Total: 12€",
      "Thank you.",
    ]);
  });
});

describe("the story region", () => {
  const texts = storyTexts(STORY);
  const region = (o: ReturnType<typeof opened>) =>
    locateStoryRegion(o.flat, texts, {
      scope: o.doc,
      chrome: WEBMAIL_CHROME,
      subject: o.subject,
    });

  it("is the message column between the webmail's elements above and below the story", () => {
    const r = region(opened());
    assert.ok(r !== null);
    // The column is the subject's block; above, the sender line ends at
    // 195; below, Reply and Forward start at 720.
    assert.deepEqual(r.rect, [220, 195, 800, 525]);
    assert.equal(r.carriers, 4);
    assert.equal(r.foreignInside, 0);
    assert.equal(r.top, "webmail");
    assert.equal(r.bottom, "webmail");
  });

  it("ends at the story's last leaf when nothing of the webmail follows", () => {
    const r = region(opened({ trailing: false }));
    assert.deepEqual(r?.rect, [220, 195, 800, 245]);
    assert.equal(r?.bottom, "story");
  });

  it("counts other text inside it, and ignores the story's text above the subject or in a control", () => {
    const f = region(opened({ foreign: true }));
    assert.deepEqual(f?.rect, [220, 195, 800, 525]);
    assert.equal(f?.foreignInside, 1);
    const o = opened();
    // A story line in the sender line's button (its label a child of
    // it): never a carrier, still the webmail's.
    const reply = o.flat.find((x) => x.node.name === "Reply")!.node;
    reply.name = "Thank you.";
    reply.children.push(text("Thank you.", [905, 178, 50, 14]));
    // One above the subject (the list's preview, say), and one beside
    // the subject, level with it.
    o.doc.node.children.unshift(text("Thank you.", [300, 84, 60, 4]));
    o.doc.node.children.push(text("Thank you.", [700, 140, 60, 10]));
    const of = flatten(o.flat[0]!.node);
    const r = locateStoryRegion(of, texts, {
      scope: of.find((x) => x.node === o.doc.node)!,
      chrome: WEBMAIL_CHROME,
      subject: of.find((x) => x.node === o.subject.node)!,
    });
    assert.deepEqual(r?.rect, [220, 195, 800, 525]);
    assert.equal(r?.carriers, 4);
  });

  it("is absent when no leaf below the subject carries the story's text", () => {
    assert.equal(region(opened({ bodyHidden: true })), null);
  });
});

describe("the UI fingerprint", () => {
  it("ignores names, text and what is skipped, not the page's structure", () => {
    const skipBody = (r: Rect) => (f: { node: GaNode }) =>
      insideRect(f.node.bounds, r);
    const a = opened();
    const ra = region0(a);
    const fa = structureFingerprint(a.flat, a.doc, skipBody(ra));
    assert.match(fa, /^[0-9a-f]{12}$/);
    const b = opened({ foreign: true });
    for (const f of b.flat) if (f.node.name !== null) f.node.name = "renamed";
    assert.equal(structureFingerprint(b.flat, b.doc, skipBody(ra)), fa);
    const c = opened();
    c.doc.node.children.unshift(n("link", "link", "Back", [220, 85, 40, 10]));
    const cf = flatten(c.flat[0]!.node);
    assert.notEqual(
      structureFingerprint(
        cf,
        cf.find((f) => f.node === c.doc.node)!,
        skipBody(ra),
      ),
      fa,
    );
  });
});

function region0(o: ReturnType<typeof opened>): Rect {
  return locateStoryRegion(o.flat, storyTexts(STORY), {
    scope: o.doc,
    chrome: WEBMAIL_CHROME,
    subject: o.subject,
  })!.rect;
}

describe("pixels", () => {
  const solid = (w: number, h: number, v: number): Uint8Array =>
    writePng({ width: w, height: h, data: new Uint8Array(w * h * 3).fill(v) });

  it("paints masks clipped to the crop, and leaves an unmasked crop as it was", () => {
    const png = solid(20, 10, 255);
    assert.equal(paintMasks(png, [100, 200], []), png);
    const out = readPng(paintMasks(png, [100, 200], [[115, 195, 50, 10]]));
    const at = (x: number, y: number) =>
      Array.from(out.data.slice((y * 20 + x) * 4, (y * 20 + x) * 4 + 3));
    assert.deepEqual(at(15, 0), [...MASK_RGB]);
    assert.deepEqual(at(19, 4), [...MASK_RGB]);
    assert.deepEqual(at(19, 5), [255, 255, 255]);
    assert.deepEqual(at(14, 0), [255, 255, 255]);
  });

  it("the mean luminance tells dark from light", () => {
    assert.equal(Math.round(meanLuminance(solid(4, 4, 0))), 0);
    assert.equal(Math.round(meanLuminance(solid(4, 4, 255))), 255);
  });
});
