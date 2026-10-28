// tools/capture/providers/webmail_typing_check.test.ts — the typing
// check's loopback server and expectation, without a browser: the
// digest and the length it expects, what it serves (never the password),
// that the page and the expectation are each served once (a second
// fetch fails the check), and which results it accepts. The page's own
// script, typed into by GuiAssert in Google Chrome, is exercised in
// webmail_signin_session.test.ts; the command line's `--typing-check`
// in webmail_signin.test.ts.
// Run with:
//   node --test tools/capture/providers/webmail_typing_check.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { Secret } from "./guiassert.ts";
import {
  startTypingCheckServer,
  typingCheckPage,
  typingExpectation,
} from "./webmail_typing_check.ts";

const SENTINEL = "Sentinel-pw-7Qx!9z €é";

describe("the expectation", () => {
  it("is a SHA-256 of the salt and the UTF-8 password, with its length in code points", () => {
    const salt = Buffer.from("00112233445566778899aabbccddeeff", "hex");
    const e = typingExpectation(new Secret("pä€😀"), salt);
    assert.equal(e.salt, "00112233445566778899aabbccddeeff");
    assert.equal(
      e.digest,
      createHash("sha256")
        .update(Buffer.concat([salt, Buffer.from("pä€😀", "utf8")]))
        .digest("hex"),
    );
    assert.equal(e.length, 4);
  });
  it("uses a fresh random salt each time", () => {
    const a = typingExpectation(new Secret(SENTINEL));
    const b = typingExpectation(new Secret(SENTINEL));
    assert.notEqual(a.salt, b.salt);
    assert.notEqual(a.digest, b.digest);
  });
});

describe("the loopback server", () => {
  it("serves the page and the expectation once each, never the password, and takes the page's verdict", async () => {
    const s = await startTypingCheckServer(new Secret(SENTINEL));
    try {
      assert.match(s.url, /^http:\/\/127\.0\.0\.1:\d+\/[0-9a-f]{32}\/$/);
      const page = await (await fetch(s.url)).text();
      assert.equal(page, typingCheckPage());
      assert.match(page, /type="password"/);
      assert.ok(!page.includes(SENTINEL));
      const exp = (await (await fetch(`${s.url}expect`)).json()) as Record<
        string,
        unknown
      >;
      assert.deepEqual(Object.keys(exp).sort(), ["digest", "length", "salt"]);
      assert.ok(!JSON.stringify(exp).includes(SENTINEL));
      assert.equal(exp.length, [...SENTINEL].length);
      await s.expectationFetched;
      // Elsewhere: nothing.
      const base = s.url.replace(/[0-9a-f]{32}\/$/, "");
      assert.equal((await fetch(`${base}expect`)).status, 404);
      assert.equal(
        (await fetch(`${base}00000000000000000000000000000000/expect`)).status,
        404,
      );
      const r = await fetch(`${s.url}result`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ match: true, lengthMatch: true }),
      });
      assert.equal(r.status, 204);
      assert.deepEqual(await s.verdict, {
        kind: "verdict",
        match: true,
        lengthMatch: true,
      });
    } finally {
      await s.close();
    }
  });

  it("listens on 127.0.0.1 only", async () => {
    const s = await startTypingCheckServer(new Secret(SENTINEL));
    try {
      assert.equal(s.address, "127.0.0.1");
    } finally {
      await s.close();
    }
  });

  it("fails the check when the expectation is fetched twice", async () => {
    const s = await startTypingCheckServer(new Secret(SENTINEL));
    try {
      assert.equal((await fetch(`${s.url}expect`)).status, 200);
      assert.equal((await fetch(`${s.url}expect`)).status, 410);
      const v = await s.verdict;
      assert.equal(v.kind, "error");
      assert.match((v as { reason: string }).reason, /fetched more than once/);
    } finally {
      await s.close();
    }
  });

  it("fails the check when the page is fetched twice", async () => {
    const s = await startTypingCheckServer(new Secret(SENTINEL));
    try {
      assert.equal((await fetch(s.url)).status, 200);
      assert.equal((await fetch(s.url)).status, 410);
      assert.equal((await s.verdict).kind, "error");
    } finally {
      await s.close();
    }
  });

  it("takes the page's error, and refuses a result without a verdict", async () => {
    for (const [body, want] of [
      [
        { error: "the page could not fetch its expectation" },
        /could not fetch/,
      ],
      [{ match: "yes" }, /had no verdict/],
      ["not json", /not JSON/],
    ] as const) {
      const s = await startTypingCheckServer(new Secret(SENTINEL));
      try {
        await fetch(`${s.url}result`, {
          method: "POST",
          body: typeof body === "string" ? body : JSON.stringify(body),
        });
        const v = await s.verdict;
        assert.equal(v.kind, "error");
        assert.match((v as { reason: string }).reason, want);
      } finally {
        await s.close();
      }
    }
  });
});
