// tools/capture/providers/webmail_typing_check.ts — the typing-fidelity
// self-check of the automated webmail sign-in
// (`email-webmail-signin SET ACCOUNT --typing-check`): does the
// account's password reach a page exactly as the account file holds it,
// typed the way the sign-in types it? No provider is contacted.
//
// A page on loopback (127.0.0.1, an ephemeral port, a random path token)
// with one password field. The page never receives the password:
// - the harness computes SHA-256(salt ‖ UTF-8(password)) with a random
//   per-run salt, and the password's length in code points;
// - the page fetches that expectation once (`/expect`), computes the same
//   digest over what was typed into its field (WebCrypto), and posts back
//   two booleans only (`/result`): whether the digests match and whether
//   the lengths match; it clears the field;
// - the page and the expectation are each served once; a second fetch is
//   refused and fails the check (someone else on the machine read the
//   token from the browser's command line), so the digest cannot be
//   fetched after the page has, and a page that could not fetch it says
//   so.
// The procedure (`runTypingCheck`) focuses the page's protected field
// the way the sign-in does (`focusField`, `isPasswordField`), types
// through GuiAssert's `type --stdin`, presses Return, waits for the
// verdict, and reads the display once through the password guard.

import { createHash, randomBytes } from "node:crypto";
import { rmSync } from "node:fs";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { GuiAssertError, type GuiAssert, type Secret } from "./guiassert.ts";
import {
  type FieldFocuser,
  focusField,
  isPasswordField,
} from "./webmail_signin.ts";

/** What the page compares against: no secret, only its salted digest. */
export interface TypingExpectation {
  /** Hex, 16 random bytes. */
  salt: string;
  /** Hex SHA-256 of salt ‖ UTF-8(password). */
  digest: string;
  /** The password's length in Unicode code points. */
  length: number;
}

export function typingExpectation(
  password: Secret,
  salt: Buffer = randomBytes(16),
): TypingExpectation {
  const value = password.reveal();
  return {
    salt: salt.toString("hex"),
    digest: createHash("sha256")
      .update(salt)
      .update(Buffer.from(value, "utf8"))
      .digest("hex"),
    length: [...value].length,
  };
}

export type TypingVerdict =
  | { kind: "verdict"; match: boolean; lengthMatch: boolean }
  | { kind: "error"; reason: string };

export interface TypingCheckServer {
  /** The page's URL (carries the path token). */
  url: string;
  /** The address the server listens on, as the socket reports it. */
  address: string;
  /** Resolves once the page has fetched its expectation. */
  expectationFetched: Promise<void>;
  /** The page's verdict, or why there is none. */
  verdict: Promise<TypingVerdict>;
  close(): Promise<void>;
}

/** The page: one password field; the digest is computed in the page. */
export function typingCheckPage(): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Typing check</title>
<style>body{font-family:sans-serif;font-size:20px;margin:48px 80px}
h1{font-size:30px;font-weight:400} input{font-size:20px;padding:10px;width:420px;display:block;margin:18px 0}</style>
</head><body>
<h1>Typing check</h1>
<p>No provider is contacted. What is typed below is compared with the account file's password by a salted SHA-256, here in the page.</p>
<form id="f"><input type="password" id="pw" aria-label="Typing check password" autocomplete="off"></form>
<p id="status">Loading</p>
<script>
const base = location.pathname.replace(/\\/$/, "");
const status = document.getElementById("status");
const field = document.getElementById("pw");
let expected = null;
const post = (o) => fetch(base + "/result", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(o) });
const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const bytes = (h) => new Uint8Array(h.match(/../g).map((x) => parseInt(x, 16)));
fetch(base + "/expect")
  .then((r) => (r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status))))
  .then((e) => { expected = e; status.textContent = "Ready"; })
  .catch((e) => { status.textContent = "Unavailable"; post({ error: "the page could not fetch its expectation (" + e.message + ")" }); });
document.getElementById("f").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const typed = field.value;
  field.value = "";
  if (expected === null) { await post({ error: "Return reached the page before its expectation" }); return; }
  const salt = bytes(expected.salt);
  const text = new TextEncoder().encode(typed);
  const all = new Uint8Array(salt.length + text.length);
  all.set(salt);
  all.set(text, salt.length);
  const digest = hex(await crypto.subtle.digest("SHA-256", all));
  await post({ match: digest === expected.digest, lengthMatch: [...typed].length === expected.length });
  status.textContent = "Done";
});
</script>
</body></html>
`;
}

function readSmallBody(req: IncomingMessage, max: number): Promise<string> {
  return new Promise((resolve, reject) => {
    let b = "";
    req.setEncoding("utf8");
    req.on("data", (d: string) => {
      b += d;
      if (b.length > max) {
        reject(new Error("body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(b));
    req.on("error", reject);
  });
}

/**
 * Serves the page for `expected` on 127.0.0.1. `expectation` is for the
 * tests (a fixed salt); otherwise a random one.
 */
export async function startTypingCheckServer(
  expected: Secret,
  expectation: TypingExpectation = typingExpectation(expected),
): Promise<TypingCheckServer> {
  const token = randomBytes(16).toString("hex");
  const served = { page: 0, expect: 0 };
  let settle!: (v: TypingVerdict) => void;
  const verdict = new Promise<TypingVerdict>((r) => (settle = r));
  let settled = false;
  const finish = (v: TypingVerdict): void => {
    if (!settled) {
      settled = true;
      settle(v);
    }
  };
  let fetched!: () => void;
  const expectationFetched = new Promise<void>((r) => (fetched = r));

  const server: Server = createServer((req, res) => {
    void (async () => {
      const path = new URL(req.url ?? "/", "http://127.0.0.1").pathname;
      const send = (code: number, type: string, body: string): void => {
        res.writeHead(code, {
          "content-type": type,
          "cache-control": "no-store",
        });
        res.end(body);
      };
      if (path === `/${token}/` && req.method === "GET") {
        if (served.page++ > 0) {
          finish({
            kind: "error",
            reason: "the check page was fetched more than once",
          });
          return send(410, "text/plain", "gone");
        }
        return send(200, "text/html; charset=utf-8", typingCheckPage());
      }
      if (path === `/${token}/expect` && req.method === "GET") {
        if (served.expect++ > 0) {
          finish({
            kind: "error",
            reason:
              "the expectation was fetched more than once (another process read the page's token)",
          });
          return send(410, "text/plain", "gone");
        }
        fetched();
        return send(200, "application/json", JSON.stringify(expectation));
      }
      if (path === `/${token}/result` && req.method === "POST") {
        let body: unknown;
        try {
          body = JSON.parse(await readSmallBody(req, 1024));
        } catch {
          send(400, "text/plain", "bad result");
          return finish({
            kind: "error",
            reason: "the page's result was not JSON",
          });
        }
        const r = body as {
          match?: unknown;
          lengthMatch?: unknown;
          error?: unknown;
        };
        send(204, "text/plain", "");
        if (typeof r.error === "string")
          return finish({ kind: "error", reason: r.error.slice(0, 200) });
        if (typeof r.match === "boolean" && typeof r.lengthMatch === "boolean")
          return finish({
            kind: "verdict",
            match: r.match,
            lengthMatch: r.lengthMatch,
          });
        return finish({
          kind: "error",
          reason: "the page's result had no verdict",
        });
      }
      send(404, "text/plain", "not found");
    })();
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const bound = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${bound.port}/${token}/`,
    address: bound.address,
    expectationFetched,
    verdict,
    close: () =>
      new Promise<void>((r) => {
        server.closeAllConnections();
        server.close(() => r());
      }),
  };
}

export interface TypingCheckContext extends FieldFocuser {
  ga: GuiAssert;
  server: TypingCheckServer;
  /** What is typed: the account's password (the check's `expected`). */
  typed: Secret;
  /** The secret every OCR frame is guarded against (the same password). */
  guard: Secret;
  framesDir: string;
  /** How long the page may take to load and to answer. */
  timeoutMs: number;
  pollMs: number;
  log: (line: string) => void;
}

export type TypingCheckOutcome =
  | { result: "match"; lengthMatch: true }
  | { result: "mismatch"; lengthMatch: boolean }
  | { result: "failed"; reason: string }
  | { result: "secret-visible" };

async function within<T>(p: Promise<T>, ms: number): Promise<T | null> {
  const timer = sleep(ms).then(() => null);
  return Promise.race([p, timer]);
}

export async function runTypingCheck(
  ctx: TypingCheckContext,
): Promise<TypingCheckOutcome> {
  if ((await within(ctx.server.expectationFetched, ctx.timeoutMs)) === null) {
    const v = await within(ctx.server.verdict, 0);
    return {
      result: "failed",
      reason:
        v !== null && v.kind === "error"
          ? v.reason
          : `the check page did not load within ${Math.round(ctx.timeoutMs / 1000)} s`,
    };
  }
  // The field, focused as the sign-in focuses the password field.
  const deadline = Date.now() + ctx.timeoutMs;
  let focused = false;
  while (!focused && Date.now() < deadline) {
    focused = await focusField(ctx, isPasswordField);
    if (!focused) await sleep(ctx.pollMs);
  }
  if (!focused)
    return {
      result: "failed",
      reason: "the page's password field did not take the focus",
    };
  await ctx.ga.type(ctx.typed);
  await ctx.ga.key("Return");
  ctx.log(
    "typed the password into the check page's protected field, and Return",
  );
  const v = await within(ctx.server.verdict, ctx.timeoutMs);
  // One read of the display through the guard: the password is not
  // legible anywhere on it.
  const frame = join(ctx.framesDir, "typing-check.png");
  try {
    await ctx.ga.ocr(frame, ctx.guard);
  } catch (err) {
    if (err instanceof GuiAssertError && err.reason === "secret-visible")
      return { result: "secret-visible" };
    throw err;
  } finally {
    rmSync(frame, { force: true });
  }
  if (v === null)
    return {
      result: "failed",
      reason: `the page gave no verdict within ${Math.round(ctx.timeoutMs / 1000)} s`,
    };
  if (v.kind === "error") return { result: "failed", reason: v.reason };
  return v.match && v.lengthMatch
    ? { result: "match", lengthMatch: true }
    : { result: "mismatch", lengthMatch: v.lengthMatch };
}
