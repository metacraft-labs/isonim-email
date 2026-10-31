// tools/capture/providers/webmail_standin.ts — local stand-ins for the
// hosted webmails and for Google's token endpoint and Gmail API, for
// the hosted-webmail provider's tests (hosted_webmail.test.ts).
//
// Why stand-ins (the repository's mock policy): the real webmails need
// a real account signed in, the real Gmail API sends real mail, and neither
// can be reached from a test. Each stand-in implements the accessibility
// contract of one adapter in webmail_adapters.ts (the roles and names its
// locators match, the same folder URLs, moved to loopback by
// rebaseAdapter), the mailbox wording the session check reads off the
// screen, and the behaviour the procedure relies on:
// - a session cookie that a "sign-in" (GET /login?account=NAME, the
//   test playing the person) sets; without it, or once the test expires
//   it, the mailbox redirects to a sign-in page on ANOTHER host
//   (localhost instead of 127.0.0.1), which records any typing;
// - delivery: the fake Gmail API's send decodes `raw` and files the
//   message for the account its To names, in Inbox, Spam (or Outlook's
//   Other tab), or withholds it, after a delay;
// - Gmail's search (rfc822msgid:, in:spam, in:trash; no Spam or Trash
//   unless asked), Yahoo's and Outlook.com's folders, opening a message,
//   delete (to Trash) and delete forever (with Yahoo's and Outlook's
//   confirmation; Gmail's Spam, as Gmail's, offers only delete forever), Outlook.com's background toggle (dark: the body
//   recoloured and marked data-ogsc);
// - every page reports what it sees of the browser (`probes`:
//   navigator.webdriver, prefers-color-scheme, the user agent);
// - test switches: drift (the body is hidden from the accessibility tree,
//   or loses the name the adapter finds it by), expire a session now or
//   when a message is opened,
//   show an opened Gmail message under another subject (a message the
//   adapter must not take for the delivered one), keep a message whose
//   delete-forever was answered.
// The webmail browser, GuiAssert, the profiles, TLS and the provider are
// real.

import { Buffer } from "node:buffer";
import { randomBytes } from "node:crypto";
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import {
  createServer as createHttpsServer,
  type Server as HttpsServer,
} from "node:https";
import type { AddressInfo } from "node:net";
import { decodeQuotedPrintable, parseEntity } from "./mime_rewrite.ts";
import { makeTestPki, type TestPki } from "./test_pki.ts";
import type { WorkspaceEndpoints } from "./workspace_send.ts";

export type Skin = "gmail" | "yahoo" | "outlook-com";
export type StandinFolder = "inbox" | "other" | "spam" | "trash";
export type Filing = "inbox" | "other" | "spam" | "withhold";

export interface StandinMessage {
  id: string;
  account: string;
  folder: StandinFolder;
  fromName: string;
  subject: string;
  preview: string;
  html: string;
  messageId: string;
  deliveredAt: number;
}

const esc = (s: string): string =>
  s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

function header(head: string, name: string): string {
  const unfolded = head.replace(/\r?\n[ \t]+/g, " ");
  return (
    new RegExp(`^${name}:[ \\t]*(.*)$`, "im").exec(unfolded)?.[1]?.trim() ?? ""
  );
}

function decodeBody(body: string, encoding: string): string {
  if (encoding === "quoted-printable") return decodeQuotedPrintable(body);
  if (encoding === "base64")
    return Buffer.from(body.replace(/\s+/g, ""), "base64").toString("latin1");
  return body;
}

// The first text/html part of a message (latin1 octets decoded as
// UTF-8), and the first text/plain part's opening as a fallback preview.
export function htmlOf(raw: string): { html: string; text: string } {
  let html = "";
  let text = "";
  const walk = (entity: string): void => {
    const p = parseEntity(entity);
    if (p.contentType.startsWith("multipart/") && p.boundary !== null) {
      const parts = p.body.split(
        new RegExp(
          `\\r?\\n?--${p.boundary.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:--)?[ \\t]*\\r?\\n`,
        ),
      );
      for (const part of parts.slice(1)) walk(part);
      return;
    }
    const decoded = Buffer.from(
      decodeBody(p.body, p.encoding),
      "latin1",
    ).toString("utf8");
    if (p.contentType === "text/html" && html === "") html = decoded;
    if (p.contentType === "text/plain" && text === "") text = decoded;
  };
  walk(raw);
  return { html, text };
}

// What a webmail shows as the preview line: the start of the body's
// visible text (a hidden preheader first, as the webmails do).
function previewOf(html: string, text: string): string {
  const pre = /<div[^>]*display:\s*none[^>]*>([^<]*)</i.exec(html)?.[1];
  const body = (
    html === ""
      ? text
      : html.replace(/<style[\s\S]*?<\/style>/gi, "").replace(/<[^>]+>/g, " ")
  )
    .replace(/&[a-z#0-9]+;/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
  return `${pre === undefined ? "" : `${pre.trim()} `}${body}`.slice(0, 140);
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((ok) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => ok(Buffer.concat(chunks).toString("utf8")));
  });
}

// Every page reports what it sees of the browser once (`probes`).
const PROBE = `fetch("/probe?webdriver=" + String(navigator.webdriver) + "&dark=" + String(matchMedia("(prefers-color-scheme: dark)").matches) + "&page=" + encodeURIComponent(location.pathname + location.hash) + "&ua=" + encodeURIComponent(navigator.userAgent));`;

const page = (body: string, script = ""): string =>
  `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Mail</title><style>body{font:16px sans-serif;margin:0;background:#fff;color:#111}.nav{position:fixed;left:0;top:0;bottom:0;width:200px;background:#eee;padding:8px}.main{margin-left:220px;padding:8px;width:800px}@media (prefers-color-scheme: dark){body{background:#202020;color:#eee}.nav{background:#333}}</style><script>${PROBE}</script></head><body>${body}${script === "" ? "" : `<script>${script}</script>`}</body></html>`;

export interface StandinProbe {
  webdriver: string;
  dark: boolean;
  page: string;
  ua: string;
}

export class StandinWebmail {
  readonly skin: Skin;
  server!: Server;
  port = 0;
  messages: StandinMessage[] = [];
  // Session token -> account.
  private readonly sessions = new Map<string, string>();
  // Keys typed into the sign-in page (never expected).
  signinTyped = 0;
  signinVisits = 0;
  // Requests to /login (only the test's own "person" may make them).
  logins: string[] = [];
  deliveryDelayMs = 0;
  filing: (m: { subject: string; account: string }) => Filing = () => "inbox";
  drift = false;
  expireOnOpen = false;
  // A delete-forever that answers but keeps the message (in Trash).
  keepDestroyed = false;
  // Gmail: an opened message shows this subject instead of its own.
  openedSubject: string | null = null;
  // User agents seen on the mailbox pages.
  userAgents: string[] = [];
  // What every page loaded saw of the browser.
  probes: StandinProbe[] = [];
  // Every delete-forever, with when.
  destroyed: { id: string; at: number }[] = [];

  constructor(skin: Skin) {
    this.skin = skin;
  }

  get origin(): string {
    return `http://127.0.0.1:${this.port}`;
  }

  private cookieName(): string {
    return `${this.skin.replace(/-/g, "_")}_session`;
  }

  private account(req: IncomingMessage): string | null {
    const m = new RegExp(`(?:^|; )${this.cookieName()}=([^;]+)`).exec(
      req.headers.cookie ?? "",
    );
    return m === null ? null : (this.sessions.get(m[1]!) ?? null);
  }

  expire(account: string): void {
    for (const [t, a] of this.sessions)
      if (a === account) this.sessions.delete(t);
  }

  // Files a message the fake Gmail API was asked to send.
  receive(account: string, raw: string): void {
    const end = raw.search(/\r?\n\r?\n/);
    const head = raw.slice(0, end < 0 ? raw.length : end);
    const subject = header(head, "Subject");
    const from = header(head, "From");
    const fromName = /^"?([^"<]*?)"?\s*</.exec(from)?.[1]?.trim() || from;
    const { html, text } = htmlOf(raw);
    const where = this.filing({ subject, account });
    if (where === "withhold") return;
    const msg: StandinMessage = {
      id: randomBytes(6).toString("hex"),
      account,
      folder: where,
      fromName,
      subject,
      preview: previewOf(html, text),
      html: html === "" ? `<pre>${esc(text)}</pre>` : html,
      messageId: header(head, "Message-ID"),
      deliveredAt: Date.now(),
    };
    setTimeout(() => this.messages.push(msg), this.deliveryDelayMs);
  }

  async start(): Promise<void> {
    this.server = createServer((req, res) => {
      this.handle(req, res).catch((err: unknown) => {
        res.writeHead(500, { "content-type": "text/plain" });
        res.end(String(err));
      });
    });
    await new Promise<void>((r) => this.server.listen(0, "127.0.0.1", r));
    this.port = (this.server.address() as AddressInfo).port;
  }

  async stop(): Promise<void> {
    this.server.closeAllConnections();
    await new Promise<void>((r) => this.server.close(() => r()));
  }

  private signinUrl(): string {
    return `http://localhost:${this.port}/signin`;
  }

  private send(
    res: ServerResponse,
    status: number,
    type: string,
    body: string,
    headers: Record<string, string> = {},
  ): void {
    res.writeHead(status, { "content-type": type, ...headers });
    res.end(body);
  }

  private mine(
    account: string,
    folder: StandinFolder | StandinFolder[],
  ): StandinMessage[] {
    const fs = Array.isArray(folder) ? folder : [folder];
    return this.messages
      .filter((m) => m.account === account && fs.includes(m.folder))
      .sort((a, b) => b.deliveredAt - a.deliveredAt);
  }

  private find(account: string, id: string): StandinMessage | undefined {
    return this.messages.find((m) => m.account === account && m.id === id);
  }

  private async handle(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const url = new URL(req.url ?? "/", this.origin);
    const host = req.headers.host ?? "";
    if (url.pathname === "/probe") {
      this.probes.push({
        webdriver: url.searchParams.get("webdriver") ?? "",
        dark: url.searchParams.get("dark") === "true",
        page: url.searchParams.get("page") ?? "",
        ua: url.searchParams.get("ua") ?? "",
      });
      return this.send(res, 204, "text/plain", "");
    }
    // The sign-in page, on another host: it records any typing.
    if (url.pathname === "/signin") {
      this.signinVisits++;
      return this.send(
        res,
        200,
        "text/html",
        page(
          '<form><input name="identifier" aria-label="Email or phone" autofocus><input type="password" name="password" aria-label="Password"></form><h1>Sign in</h1><p>to continue to your mailbox</p>',
          `for (const i of document.querySelectorAll("input")) i.addEventListener("input", () => fetch("/signin-typed", {method: "POST"}));`,
        ),
      );
    }
    if (url.pathname === "/signin-typed") {
      this.signinTyped++;
      return this.send(res, 204, "text/plain", "");
    }
    // The person's sign-in (the test plays it).
    if (url.pathname === "/login") {
      const account = url.searchParams.get("account") ?? "";
      this.logins.push(account);
      const token = randomBytes(8).toString("hex");
      this.sessions.set(token, account);
      return this.send(res, 302, "text/plain", "", {
        "set-cookie": `${this.cookieName()}=${token}; Max-Age=86400; Path=/`,
        location: "/",
      });
    }
    if (host.startsWith("localhost"))
      return this.send(res, 404, "text/plain", "not here");
    const account = this.account(req);
    if (url.pathname.startsWith("/api/")) {
      if (account === null)
        return this.send(res, 401, "application/json", "{}");
      return this.api(url, account, res, req);
    }
    if (account === null)
      return this.send(res, 302, "text/plain", "", {
        location: this.signinUrl(),
      });
    this.userAgents.push(String(req.headers["user-agent"] ?? ""));
    if (this.skin === "gmail") return this.gmailShell(url, res);
    if (this.skin === "yahoo") return this.yahoo(url, account, res);
    return this.outlook(url, account, res);
  }

  private async api(
    url: URL,
    account: string,
    res: ServerResponse,
    req: IncomingMessage,
  ): Promise<void> {
    const id = url.searchParams.get("id") ?? "";
    if (url.pathname === "/api/delete" && req.method === "POST") {
      const m = this.find(account, id);
      if (m !== undefined) m.folder = "trash";
      return this.send(res, 200, "application/json", "{}");
    }
    if (url.pathname === "/api/destroy" && req.method === "POST") {
      if (!this.keepDestroyed)
        this.messages = this.messages.filter(
          (m) => !(m.account === account && m.id === id),
        );
      this.destroyed.push({ id, at: Date.now() });
      return this.send(res, 200, "application/json", "{}");
    }
    if (url.pathname === "/api/view") return this.gmailView(url, account, res);
    return this.send(res, 404, "application/json", "{}");
  }

  // --- Gmail: a hash-routed shell whose views come from /api/view ----------

  private gmailShell(url: URL, res: ServerResponse): void {
    if (!url.pathname.startsWith("/mail/u/"))
      return this.send(res, 302, "text/plain", "", {
        location: "/mail/u/0/#inbox",
      });
    const script = `
      async function render(id) {
        const h = location.hash;
        const r = await fetch("/api/view?hash=" + encodeURIComponent(h) + (id ? "&id=" + id : ""));
        if (r.status === 401) { location.href = ${JSON.stringify(this.signinUrl())}; return; }
        document.getElementById("main").innerHTML = await r.text();
        for (const row of document.querySelectorAll("[data-open]")) row.addEventListener("click", () => render(row.dataset.open));
        for (const b of document.querySelectorAll("[data-act]")) b.addEventListener("click", async () => {
          await fetch("/api/" + b.dataset.act + "?id=" + b.dataset.id, { method: "POST" });
          render(null);
        });
      }
      window.addEventListener("hashchange", () => render(null));
      render(null);`;
    this.send(
      res,
      200,
      "text/html",
      page(
        `<div class="nav" role="navigation"><p>Gmail</p><p>Compose</p><p>Inbox</p></div><div class="main"><form role="search"><input name="q" aria-label="Search mail"></form><div role="main" id="main"></div></div>`,
        script,
      ),
    );
  }

  private gmailView(url: URL, account: string, res: ServerResponse): void {
    const hash = url.searchParams.get("hash") ?? "";
    const id = url.searchParams.get("id");
    const q = decodeURIComponent(
      hash.replace(/^#search\//, "").replace(/\+/g, " "),
    );
    const inSpam = /(^| )in:spam( |$)/.test(q);
    const inTrash = /(^| )in:trash( |$)/.test(q);
    const mid = /rfc822msgid:(\S+)/.exec(q)?.[1] ?? null;
    const folder: StandinFolder[] = inSpam
      ? ["spam"]
      : inTrash
        ? ["trash"]
        : ["inbox", "other"];
    let list = this.mine(account, folder);
    if (mid !== null)
      list = list.filter((m) => m.messageId.replace(/^<|>$/g, "") === mid);
    if (id !== null) {
      const m = this.find(account, id);
      if (m === undefined)
        return this.send(res, 200, "text/html", "<p>Gone</p>");
      if (this.expireOnOpen) {
        this.expire(account);
        return this.send(res, 401, "text/html", "");
      }
      // Drift: the body hidden from the accessibility tree, so no node
      // carries the story's text.
      const hidden = this.drift ? ' aria-hidden="true"' : "";
      const del =
        m.folder === "trash" || m.folder === "spam"
          ? `<div role="button" tabindex="0" data-act="destroy" data-id="${m.id}">Delete forever</div>`
          : `<div role="button" tabindex="0" aria-label="Delete" data-act="delete" data-id="${m.id}">Delete</div>`;
      const shown = esc(this.openedSubject ?? m.subject);
      return this.send(
        res,
        200,
        "text/html",
        `<div class="toolbar" role="toolbar">${del}</div><h2 class="hP">${shown}</h2><div class="sender"><span>${esc(m.fromName)}</span> <div role="button" tabindex="0">Reply</div></div><div class="ii gt"><div class="a3s aiL"${hidden}>${m.html}</div></div>`,
      );
    }
    const rows = list
      .map(
        (m) =>
          `<tr class="zA zE" role="row" data-open="${m.id}"><td role="gridcell"><span class="yP" email="sender@standin.invalid">${esc(m.fromName)}</span></td><td role="gridcell"><span class="bog">${esc(m.subject)}</span><span class="y2"> - ${esc(m.preview)}</span></td></tr>`,
      )
      .join("");
    this.send(
      res,
      200,
      "text/html",
      `<table role="grid" style="width:100%"><tbody>${rows}</tbody></table>`,
    );
  }

  // --- Yahoo: server-rendered folders -------------------------------------

  private yahoo(url: URL, account: string, res: ServerResponse): void {
    const folders: Record<string, StandinFolder> = {
      "1": "inbox",
      "6": "spam",
      "4": "trash",
    };
    const m1 = /^\/d\/folders\/(\d+)(?:\/messages\/([0-9a-f]+))?$/.exec(
      url.pathname,
    );
    if (m1 === null)
      return this.send(res, 302, "text/plain", "", {
        location: "/d/folders/1",
      });
    const folder = folders[m1[1]!] ?? "inbox";
    const nav = `<div class="nav" role="navigation"><p>Compose</p><p>Inbox</p><input type="search" name="p" aria-label="Search"></div>`;
    if (m1[2] !== undefined) {
      const m = this.find(account, m1[2]);
      if (m === undefined)
        return this.send(res, 302, "text/plain", "", {
          location: `/d/folders/${m1[1]}`,
        });
      const trash = m.folder === "trash";
      const script = `
        const b = document.querySelector('[data-test-id="toolbar-delete"]');
        b.addEventListener("click", async () => {
          if (${trash}) {
            const d = document.createElement("div");
            d.innerHTML = '<div role="dialog" aria-label="Delete forever?" style="position:fixed;top:40%;left:40%;z-index:10;background:#fff;padding:20px;border:1px solid #888"><button data-test-id="primary-btn">OK</button></div>';
            document.body.append(d);
            d.querySelector("button").addEventListener("click", async () => {
              await fetch("/api/destroy?id=${m.id}", { method: "POST" });
              location.href = "/d/folders/4";
            });
            return;
          }
          await fetch("/api/delete?id=${m.id}", { method: "POST" });
          location.href = "/d/folders/${m1[1]}";
        });`;
      // Drift: the body hidden from the accessibility tree.
      const hidden = this.drift ? ' aria-hidden="true"' : "";
      return this.send(
        res,
        200,
        "text/html",
        page(
          `${nav}<div class="main"><div data-test-id="message-view"><button data-test-id="toolbar-delete">Delete</button><h2 data-test-id="message-group-subject-text">${esc(m.subject)}</h2><div data-test-id="message-view-body-content"${hidden}>${m.html}</div></div></div>`,
          script,
        ),
      );
    }
    const rows = this.mine(
      account,
      folder === "inbox" ? ["inbox", "other"] : folder,
    )
      .map(
        (m) =>
          `<a data-test-id="message-list-item" href="/d/folders/${m1[1]}/messages/${m.id}"><span data-test-id="senders">${esc(m.fromName)}</span> <span data-test-id="message-subject">${esc(m.subject)}</span> <span data-test-id="snippet">${esc(m.preview)}</span></a><br>`,
      )
      .join("");
    this.send(
      res,
      200,
      "text/html",
      page(`${nav}<div class="main" role="main">${rows}</div>`),
    );
  }

  // --- Outlook.com: folders with Focused/Other, a background toggle -------

  private outlook(url: URL, account: string, res: ServerResponse): void {
    const names: Record<string, StandinFolder> = {
      inbox: "inbox",
      junkemail: "spam",
      deleteditems: "trash",
    };
    const m1 =
      /^\/mail\/0\/(inbox|junkemail|deleteditems)(?:\/id\/([0-9a-f]+))?$/.exec(
        url.pathname,
      );
    if (m1 === null)
      return this.send(res, 302, "text/plain", "", {
        location: "/mail/0/inbox",
      });
    const fname = m1[1]!;
    const nav = `<div class="nav" role="navigation"><p>New mail</p><p>Inbox</p><input id="topSearchInput" type="search" aria-label="Search"></div>`;
    if (m1[2] !== undefined) {
      const m = this.find(account, m1[2]);
      if (m === undefined)
        return this.send(res, 302, "text/plain", "", {
          location: `/mail/0/${fname}`,
        });
      const trash = m.folder === "trash";
      const script = `
        const body = document.querySelector('[data-body]');
        const toggle = document.querySelector('[data-toggle]');
        function paint() {
          const light = toggle.getAttribute("aria-pressed") === "true";
          body.style.background = light ? "#ffffff" : "#1f1f1f";
          body.style.color = light ? "" : "#f0f0f0";
          for (const el of body.querySelectorAll("*")) {
            if (light) { el.removeAttribute("data-ogsc"); el.style.removeProperty("filter"); }
            else if (getComputedStyle(el).backgroundColor !== "rgba(0, 0, 0, 0)" || el.style.color) { el.setAttribute("data-ogsc", ""); el.style.setProperty("filter", "invert(0.9) hue-rotate(180deg)"); }
          }
        }
        toggle.addEventListener("click", () => { toggle.setAttribute("aria-pressed", toggle.getAttribute("aria-pressed") === "true" ? "false" : "true"); paint(); });
        paint();
        document.querySelector('[data-del]').addEventListener("click", async () => {
          if (${trash}) {
            const d = document.createElement("div");
            d.innerHTML = '<div role="dialog" aria-label="Delete permanently?" style="position:fixed;top:40%;left:40%;z-index:10;background:#fff;padding:20px;border:1px solid #888"><button>OK</button></div>';
            document.body.append(d);
            d.querySelector("button").addEventListener("click", async () => {
              await fetch("/api/destroy?id=${m.id}", { method: "POST" });
              location.href = "/mail/0/deleteditems";
            });
            return;
          }
          await fetch("/api/delete?id=${m.id}", { method: "POST" });
          location.href = "/mail/0/${fname}";
        });`;
      const bodyLabel = this.drift ? "Message" : "Message body";
      return this.send(
        res,
        200,
        "text/html",
        page(
          `${nav}<div class="main" role="main"><div role="heading" aria-level="2">${esc(m.subject)}</div><button aria-label="Delete" data-del>Delete</button> <button aria-label="Switch background" aria-pressed="false" data-toggle>Background</button><div role="document" aria-label="${bodyLabel}" data-body>${m.html}</div></div>`,
          script,
        ),
      );
    }
    const folder = names[fname]!;
    const tab = url.searchParams.get("tab") === "other" ? "other" : "inbox";
    const list =
      folder === "inbox" ? this.mine(account, tab) : this.mine(account, folder);
    const tabs =
      folder === "inbox"
        ? `<div role="tablist"><button role="tab" onclick="location.href='?tab=focused'">Focused</button><button role="tab" onclick="location.href='?tab=other'">Other</button></div>`
        : "";
    const rows = list
      .map(
        (m) =>
          `<div role="option" onclick="location.href='/mail/0/${fname}/id/${m.id}'"><span title="sender@standin.invalid">${esc(m.fromName)}</span> <span data-testid="SubjectLine">${esc(m.subject)}</span> <span data-testid="PreviewText">${esc(m.preview)}</span></div>`,
      )
      .join("");
    this.send(
      res,
      200,
      "text/html",
      page(
        `${nav}<div class="main" role="main">${tabs}<div role="listbox">${rows}</div></div>`,
      ),
    );
  }
}

// Google's token endpoint and the Gmail API's send, over TLS with a
// throwaway authority: tokens for any well-formed JWT bearer grant, and
// each sent message handed to the stand-in webmail its To names.
export class FakeGmailApi {
  server!: HttpsServer;
  readonly pki: TestPki = makeTestPki("hosted-webmail test CA");
  sent: { at: number; to: string; raw: string }[] = [];
  private readonly route: (
    to: string,
  ) => { webmail: StandinWebmail; account: string } | null;

  constructor(
    route: (to: string) => { webmail: StandinWebmail; account: string } | null,
  ) {
    this.route = route;
  }

  async start(): Promise<WorkspaceEndpoints> {
    this.server = createHttpsServer(
      { key: this.pki.keyPem, cert: this.pki.certChainPem },
      (req, res) => {
        void readBody(req).then((body) => {
          const reply = (status: number, o: unknown): void => {
            res.writeHead(status, { "content-type": "application/json" });
            res.end(JSON.stringify(o));
          };
          if (req.url === "/token") {
            const form = new URLSearchParams(body);
            if (
              form.get("grant_type") !==
              "urn:ietf:params:oauth:grant-type:jwt-bearer"
            )
              return reply(400, { error: "invalid_request" });
            return reply(200, {
              access_token: "standin-token",
              expires_in: 3599,
              token_type: "Bearer",
            });
          }
          if (
            /^\/gmail\/v1\/users\/[^/]+\/messages\/send$/.test(req.url ?? "")
          ) {
            const raw = Buffer.from(
              (JSON.parse(body) as { raw: string }).raw,
              "base64url",
            ).toString("latin1");
            const head = raw.slice(0, raw.search(/\r?\n\r?\n/));
            const to = header(head, "To");
            this.sent.push({ at: Date.now(), to, raw });
            const r = this.route(to);
            if (r !== null) r.webmail.receive(r.account, raw);
            const id = `api${this.sent.length}`;
            return reply(200, { id, threadId: `t${id}`, labelIds: ["SENT"] });
          }
          reply(404, { error: "not found" });
        });
      },
    );
    await new Promise<void>((r) => this.server.listen(0, "127.0.0.1", r));
    const port = (this.server.address() as AddressInfo).port;
    return {
      tokenUrl: `https://localhost:${port}/token`,
      gmailBase: `https://localhost:${port}`,
    };
  }

  async stop(): Promise<void> {
    this.server.closeAllConnections();
    await new Promise<void>((r) => this.server.close(() => r()));
  }
}
