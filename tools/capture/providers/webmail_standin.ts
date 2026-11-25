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
// - Gmail's search (rfc822msgid:, a quoted phrase of the subject,
//   in:spam, in:trash; no Spam or Trash unless asked; the search field
//   holding the query), Yahoo's and Outlook.com's folders, opening a
//   message, delete (to Trash) and delete forever (with Yahoo's and
//   Outlook's confirmation; Gmail's open Spam message, as live, its
//   "Delete" moving it to Trash), Outlook.com's theme following the browser's colour scheme
//   and, in dark only, its background toggle (unpressed: the body
//   recoloured dark and marked data-ogsc; pressed: the body light);
// - every page reports what it sees of the browser (`probes`:
//   navigator.webdriver, prefers-color-scheme, the user agent, the
//   notification permission, the viewport's size);
// - as the live webmails do: Gmail's "Enable desktop notifications"
//   toast while the page's notification permission is undecided (its
//   "OK" and "No thanks" reported as events), Gmail's open message in
//   Trash offering a "Delete" that leaves it in Trash (live 2026-11-02),
//   its lists' rows with a check box each and the "Trash" label in a
//   Trash row's subject cell, the toolbar's "Delete forever" (in a
//   Trash search) or "Delete" shown once a row is selected, its Reply and
//   Forward links below the body;
//   Outlook.com's Inbox address rewritten to the bare /mail/0/, and its
//   lists drawn as placeholders (not in the tree) for a while before
//   their rows or an empty folder's notice;
// - test switches: drift (the body is hidden from the accessibility tree,
//   or loses the name the adapter finds it by), expire a session now or
//   when a message is opened,
//   show an opened Gmail message under another subject (a message the
//   adapter must not take for the delivered one), keep a message whose
//   delete-forever was answered; Gmail rewriting the Message-ID (so
//   rfc822msgid: finds nothing), naming its rows after the sender only,
//   or showing a search-suggestions list echoing the query (a
//   look-alike carrying the token); Outlook.com without its toggle,
//   ignoring the browser's dark scheme, or deleting Junk for good; a
//   delete that answers but leaves the message in its folder; Gmail's
//   views answering late (the previous list shown under the new address);
//   Gmail's toast shown whatever the permission, a Trash row without its
//   Trash label, or a confirmation dialog after "Delete forever"; another
//   message's row in its Trash lists, a selection already made there, or
//   one that grows to every row after a row's check box is clicked;
//   Outlook.com's lists loading slowly, or one folder's never, and its
//   reading pane's width a function of the window's; Yahoo in Bulgarian
//   (its controls and folders so named, the account's address in the
//   title), its old folder URLs sending to the Inbox, and its /n/ Inbox
//   laid out as a mailbox only in a window no larger than a size;
//   Gmail's search box in its banner heading (the box's wrapper named
//   after the query) and the search's highlight as a heading nested in
//   the subject; Yahoo's rows as live (a link holding a check box and
//   hover actions named after the message, the subject hidden from the
//   tree), a click on the row that selects it, a row selected when the
//   list is drawn, a sender's messages as one conversation row with its
//   count, and a folder whose /n/ id moved;
//   as the live runs of 2026-11-16 and 2026-11-22: Gmail's Trash list
//   redrawn once after a row is selected (the selection cleared) and its
//   toolbar's action shown a while after a selection; Yahoo's reloaded
//   list drawn with its rows named after their senders alone for a
//   while, an opened message's row no longer "unread", its list pages
//   answering late after a message was opened, and the column the list
//   and the opened message take a function of the window's width.
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
  // Yahoo: opened once (its row no longer named "unread").
  read?: boolean;
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
const PROBE = `fetch("/probe?webdriver=" + String(navigator.webdriver) + "&dark=" + String(matchMedia("(prefers-color-scheme: dark)").matches) + "&page=" + encodeURIComponent(location.pathname + location.hash) + "&ua=" + encodeURIComponent(navigator.userAgent) + "&notif=" + encodeURIComponent(typeof Notification === "undefined" ? "none" : Notification.permission) + "&vw=" + innerWidth + "&vh=" + innerHeight);`;

const page = (
  body: string,
  script = "",
  followsDark = true,
  title = "Mail",
): string =>
  `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${esc(title)}</title><style>body{font:16px sans-serif;margin:0;background:#fff;color:#111}.nav{position:fixed;left:0;top:0;bottom:0;width:200px;background:#eee;padding:8px}.main{margin-left:220px;padding:8px;width:800px}${followsDark ? "@media (prefers-color-scheme: dark){body{background:#202020;color:#eee}.nav{background:#333}}" : ""}</style><script>${PROBE}</script></head><body>${body}${script === "" ? "" : `<script>${script}</script>`}</body></html>`;

export interface StandinProbe {
  webdriver: string;
  dark: boolean;
  page: string;
  ua: string;
  // Notification.permission: "default", "denied" or "granted".
  notif: string;
  // The viewport's size (innerWidth, innerHeight).
  vw: number;
  vh: number;
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
  // Gmail: the delivered message's Message-ID replaced (rfc822msgid:
  // finds nothing; the token search does).
  rewriteMessageId = false;
  // Gmail: each row named after its sender alone (aria-labelledby); the
  // subject is only in its cells.
  rowNamedBySender = false;
  // Gmail: a search-suggestions list under the search field, echoing
  // the query (it carries the token in a token search).
  suggestions = false;
  // Outlook.com: no background toggle in dark.
  noToggle = false;
  // Outlook.com: the toggle starts pressed (the body switched to light).
  togglePressed = false;
  // Outlook.com: its theme stays light in a dark browser.
  ignoresDark = false;
  // Outlook.com: a delete in Junk Email is for good (no Deleted Items).
  junkDeletePermanent = false;
  // A delete (to Trash) that answers but leaves the message where it is.
  deleteIgnored = false;
  // Gmail: how long a view takes to answer (the previous list stays on
  // the page meanwhile, under the new address).
  viewDelayMs = 0;
  // What the pages reported doing (e.g. "toggle": a toggle click;
  // "toast-ok", "toast-no": Gmail's notifications toast answered).
  events: string[] = [];
  // Gmail: the notifications toast shown whatever the permission.
  toastAlways = false;
  // Gmail: no "Trash" label in the Trash row (and no chip on the open
  // message) of a message whose subject holds this.
  noTrashChipFor: string | null = null;
  // Gmail: the toolbar's "Delete forever" asks to confirm in a dialog.
  confirmForever = false;
  // Gmail: the toolbar never shows "Delete forever" (a Trash list that
  // offers no permanent delete).
  noListForever = false;
  // Gmail: every Trash list also shows another message's row (id
  // "decoy", without the run token), as a looser search would.
  trashDecoy = false;
  // Gmail: a selection already made when a Trash list is drawn: the
  // decoy row's check box checked, the toolbar's select-all partly
  // ("decoy"), or only the select-all checked ("toolbar": every row of
  // the page selected, those shown here scrolled out of view).
  preselect: "decoy" | "toolbar" | null = null;
  // Gmail: after a click on a row's check box, every row's check box
  // checked this many ms later (a selection that does not stay the
  // row's), the toolbar's action shown only then.
  selectAllAfterMs: number | null = null;
  // Outlook.com: the reading pane's width as CSS (e.g. "calc(100vw -
  // 1200px)"): a pane between the webmail's columns that grows with the
  // window; null: 800 px.
  paneWidth: string | null = null;
  // Yahoo: its bare address landing on the /n/ Inbox, and the page it
  // lands on laid out as a mailbox only in a viewport no wider and no
  // taller than this (otherwise a page without its folder list or
  // compose button, its title still the account's); null: always, the
  // bare address landing on /d/folders/1. A landing laid out by the
  // window's size, as the live one may be: its capture session check in
  // a 1360 x 2400 window failed where --check-only's in 1280 x 900
  // passed (2026-11-02, cause not seen). Only the landing: the /n/
  // Inbox opened by its address was a mailbox in the capture's 1360 px
  // window (live, 2026-11-13).
  mailboxOnlyIn: { width: number; height: number } | null = null;
  // Yahoo: the next /n/ Inbox page is a landing from the bare address.
  private landing = false;
  // Outlook.com: how long a list is drawn as placeholders before its
  // rows (or the empty folder's notice) show.
  listLoadingMs = 0;
  // Outlook.com: folders whose list never stops loading.
  neverLoads: StandinFolder[] = [];
  // Yahoo: its pages in this language ("en", or "bg": Bulgarian, as the
  // live account showed, with a compose button, the folder list as
  // links and the account's address in the title).
  lang: "en" | "bg" = "en";
  // Yahoo: each account's address (for the Bulgarian title).
  addresses: Record<string, string> = {};
  // Yahoo: the /d/folders/ URLs of Spam and Trash send to the Inbox.
  oldFolderUrlsGone = false;
  // Yahoo: the new Yahoo Mail (live, 2026-11-13): every /d/folders/
  // list URL sends to /n/folders/00_1?.src=ym&reason=unexpected_ymv;
  // the folder list is buttons in the navigation landmark's list items,
  // the current folder's named after a state ("Избрано, …"); an
  // advertising banner and a header with links above the page; a
  // toolbar's "Спам" (report spam) over the message list; a query added
  // to a folder's address (?.src=ym) when it has none. Its Spam and
  // Trash are /n/folders/00_6 and /n/folders/00_4 here only: the live
  // ids are not known.
  newUi = false;
  // Yahoo: folders whose control the new UI's folder list leaves out.
  hiddenFolders: StandinFolder[] = [];
  // Outlook.com: its loading screen (an image and "Microsoft" in an
  // otherwise empty page, live 2026-11-13) on the next this-many folder
  // pages, for splashMs (negative: for ever) before the page shows.
  splashLoads = 0;
  splashMs = 0;
  // Gmail: a "Labels" heading in its folder pane and, in Spam, "Why is
  // this message in spam?" above the body (as the live page's);
  // the opened subject drawn this long after the rest of the message;
  // the subject heading named "Conversation", its text (the search's
  // highlight splitting the run token from the rest) in its children.
  labelsHeading = false;
  subjectLaterMs = 0;
  subjectNamedOther = false;
  // Gmail: a search list's heading echoing its query (which holds the
  // run token), a heading that is no opened message's subject.
  queryHeading = false;
  // Gmail (live tree, 2026-11-13): the search box inside an unnamed
  // banner heading, its wrapper named after the field's value (the token
  // query); and the search's highlight in the opened subject drawn as a
  // heading of its own nested in it (the token in both).
  bannerSearch = false;
  nestedHighlight = false;
  // Yahoo (live tree, 2026-11-13): each row a link named after the
  // message, holding its check box and, under the pointer, its hover
  // actions, both named after the message too; the subject's text not
  // in the tree. A click on the check box selects the row (never opens
  // it), a hover action does nothing here; with rowClickSelects, a click
  // anywhere on the row selects it instead of opening it. Events:
  // "select", "unselect", "hover-action".
  liveRows = false;
  rowClickSelects = false;
  // Yahoo, with liveRows: the hover actions shown whatever the pointer.
  hoverAlways = false;
  // Yahoo: the token's row's check box ("own") or another row's
  // ("other") checked when a list is drawn.
  rowPreselect: "own" | "other" | null = null;
  // Yahoo: a folder's messages from one sender shown as one row, a
  // conversation, its count shown ("2 messages"), opening its latest.
  conversations = false;
  // Yahoo: folders whose /n/ id now leads to the Inbox (their id
  // changed), their controls pointing at the new one (mN).
  movedIds: StandinFolder[] = [];
  // Gmail: how much longer an opened message's view takes than a list's.
  openDelayMs = 0;
  // Gmail: after the first click on a Trash row's check box, the list
  // redrawn this many ms later, every selection cleared (as a refresh
  // of a search's results does), this many times in all ("redraw"
  // events); null: never.
  selectionLostAfterMs: number | null = null;
  selectionLosses = 0;
  // Gmail: the toolbar's action shown this long after a row is selected
  // (0: at once).
  bulkAfterMs = 0;
  // Yahoo, with liveRows: a list loaded by a reload (F5) draws its rows
  // named after their senders alone, read and unread alike (the link's
  // name its "unread" word and sender, the check box's the sender, the
  // hover actions' their action), for this long, then their full names
  // (live, 2026-11-22: a reloaded Inbox read so twice 1.4 s after the
  // reload, the token nowhere in the tree). 0: never.
  partialOnReloadMs = 0;
  // Yahoo (`slowAfterOpen`): once a message has been opened, the first
  // list page asked for starts a slow spell of slowMs, and every list
  // page asked for during it is answered only when it ends (a restarted
  // browser shows no page meanwhile, as the live one after its widening
  // restart did, 2026-11-22). By time, not by count: Chrome's address
  // bar fetches a typed URL ahead of the Return, a request of its own.
  private slowMs = 0;
  private openedOnce = false;
  private slowUntil: number | null = null;

  slowAfterOpen(ms: number): void {
    this.openedOnce = false;
    this.slowMs = ms;
    this.slowUntil = null;
  }

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
      messageId: this.rewriteMessageId
        ? `<rewritten-${randomBytes(4).toString("hex")}@mail.invalid>`
        : header(head, "Message-ID"),
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
        notif: url.searchParams.get("notif") ?? "",
        vw: Number(url.searchParams.get("vw") ?? "0"),
        vh: Number(url.searchParams.get("vh") ?? "0"),
      });
      return this.send(res, 204, "text/plain", "");
    }
    if (url.pathname === "/event") {
      if (url.searchParams.get("what") === "redraw" && this.selectionLosses > 0)
        this.selectionLosses--;
      this.events.push(url.searchParams.get("what") ?? "");
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
      if (this.deleteIgnored) void 0;
      else if (
        m !== undefined &&
        m.folder === "spam" &&
        this.junkDeletePermanent
      )
        this.messages = this.messages.filter((x) => x !== m);
      else if (m !== undefined) m.folder = "trash";
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
    if (url.pathname === "/api/view") {
      const delay =
        this.viewDelayMs + (url.searchParams.get("id") ? this.openDelayMs : 0);
      if (delay > 0) await new Promise((r) => setTimeout(r, delay));
      return this.gmailView(url, account, res);
    }
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
        const q = document.querySelector('[name="q"]');
        q.value = h.startsWith("#search/") ? decodeURIComponent(h.slice(8).replace(/[+]/g, " ")) : "";
        // The search box's wrapper named after its value, as Chrome
        // names Gmail's.
        const wrap = document.getElementById("qwrap");
        if (wrap !== null) { if (q.value === "") wrap.removeAttribute("aria-label"); else wrap.setAttribute("aria-label", q.value); }
        const r = await fetch("/api/view?hash=" + encodeURIComponent(h) + (id ? "&id=" + id : ""));
        if (r.status === 401) { location.href = ${JSON.stringify(this.signinUrl())}; return; }
        document.getElementById("main").innerHTML = await r.text();
        // What a view draws later (the opened subject on a loaded host).
        for (const el of document.querySelectorAll("[data-later]")) setTimeout(() => { el.hidden = false; }, Number(el.dataset.later));
        for (const row of document.querySelectorAll("[data-open]")) row.addEventListener("click", () => render(row.dataset.open));
        for (const b of document.querySelectorAll("[data-act]")) b.addEventListener("click", async () => {
          await fetch("/api/" + b.dataset.act + "?id=" + b.dataset.id, { method: "POST" });
          render(null);
        });
        // A row's check box selects it (never opens it); the toolbar's
        // action shows once a row is selected.
        const boxes = () => [...document.querySelectorAll("[data-sel]")];
        for (const box of boxes()) box.addEventListener("click", (e) => {
          e.stopPropagation();
          box.setAttribute("aria-checked", box.getAttribute("aria-checked") === "true" ? "false" : "true");
          const any = boxes().some((x) => x.getAttribute("aria-checked") === "true");
          // The list redrawn after a selection (once per page, as many
          // times in all as selectionLosses allows).
          if (${this.selectionLostAfterMs !== null && this.selectionLosses > 0} && any && !window.__redrawn) {
            window.__redrawn = true;
            setTimeout(() => { fetch("/event?what=redraw"); render(null); }, ${this.selectionLostAfterMs ?? 0});
          }
          if (${this.selectAllAfterMs} !== null) {
            setTimeout(() => {
              for (const x of boxes()) x.setAttribute("aria-checked", "true");
              for (const b of document.querySelectorAll("[data-bulk]")) b.hidden = false;
            }, ${this.selectAllAfterMs ?? 0});
            return;
          }
          const show = () => {
            const now = boxes().some((x) => x.isConnected && x.getAttribute("aria-checked") === "true");
            for (const b of document.querySelectorAll("[data-bulk]")) b.hidden = !now;
          };
          if (${this.bulkAfterMs} > 0) setTimeout(show, ${this.bulkAfterMs}); else show();
        });
        for (const b of document.querySelectorAll("[data-bulk]")) b.addEventListener("click", () => {
          const ids = boxes().filter((x) => x.getAttribute("aria-checked") === "true").map((x) => x.dataset.sel);
          fetch("/event?what=bulk-" + b.dataset.bulk);
          const go = async () => {
            for (const id of ids) await fetch("/api/" + b.dataset.bulk + "?id=" + id, { method: "POST" });
            render(null);
          };
          if (${this.confirmForever} && b.dataset.bulk === "destroy") {
            const d = document.createElement("div");
            d.innerHTML = '<div role="dialog" aria-label="Delete forever" style="position:fixed;top:40%;left:40%;z-index:10;background:#fff;padding:20px;border:1px solid #888"><span>This action will affect the selected conversation.</span> <div role="button" tabindex="0" aria-label="OK">OK</div></div>';
            document.body.append(d);
            d.querySelector('[role="button"]').addEventListener("click", () => { fetch("/event?what=confirm-ok"); d.remove(); go(); });
            return;
          }
          go();
        });
      }
      window.addEventListener("hashchange", () => render(null));
      render(null);
      if (${this.toastAlways} || (typeof Notification !== "undefined" && Notification.permission === "default")) {
        const t = document.createElement("div");
        t.setAttribute("style", "position:fixed;left:8px;bottom:8px;width:460px;background:#202124;color:#fff;padding:12px");
        t.innerHTML = '<span>Enable desktop notifications for Gmail.</span> <a href="#" data-toast="ok" style="color:#8ab4f8">OK</a> <a href="#" data-toast="no" style="color:#8ab4f8">No thanks</a>';
        document.body.append(t);
        for (const a of t.querySelectorAll("[data-toast]")) a.addEventListener("click", (e) => {
          e.preventDefault();
          fetch("/event?what=toast-" + a.dataset.toast);
          if (a.dataset.toast === "ok" && typeof Notification !== "undefined") Notification.requestPermission();
          t.remove();
        });
      }`;
    this.send(
      res,
      200,
      "text/html",
      page(
        `<div class="nav" role="navigation"><p>Gmail</p><p>Compose</p><p>Inbox</p>${this.labelsHeading ? "<h2>Labels</h2>" : ""}</div><div class="main">${this.bannerSearch ? `<div role="heading" aria-level="1"><div role="button" tabindex="0" aria-label="Main menu">=</div> <a href="#inbox">Gmail</a> <form role="search"><div role="group" id="qwrap"><input name="q" aria-label="Search mail"></div></form></div>` : `<form role="search"><input name="q" aria-label="Search mail"></form>`}<div role="main" id="main"></div></div>`,
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
    // A quoted phrase: the subject must hold it (as Gmail's, punctuation
    // and case ignored).
    const phrase = /"([^"]+)"/.exec(q)?.[1] ?? null;
    const norm = (t: string): string =>
      t
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, " ")
        .trim();
    const folder: StandinFolder[] = inSpam
      ? ["spam"]
      : inTrash
        ? ["trash"]
        : ["inbox", "other"];
    let list = this.mine(account, folder);
    if (mid !== null)
      list = list.filter((m) => m.messageId.replace(/^<|>$/g, "") === mid);
    if (phrase !== null)
      list = list.filter((m) =>
        ` ${norm(m.subject)} `.includes(` ${norm(phrase)} `),
      );
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
      const btn = (label: string, act = ""): string =>
        `<div role="button" tabindex="0" aria-label="${label}"${act === "" ? "" : ` data-act="${act}" data-id="${m.id}"`}>${label}</div>`;
      // As Gmail's (live, 2026-10-31): the open message in Trash offers
      // "Delete" beside "Move to Inbox", under a banner, with the "Trash"
      // label chip by the subject, and that "Delete" leaves it in Trash
      // (live, 2026-11-02); in Spam the same toolbar, its "Delete"
      // moving it to Trash (live tree, 2026-11-13: no "Delete forever");
      // elsewhere "Delete" moves it to Trash.
      const trash = m.folder === "trash";
      const del =
        trash || m.folder === "spam"
          ? `${btn("Back to Search Results")}${btn("Archive")}${btn("Report spam")}${btn("Delete", "delete")}${btn("Mark as unread")}${btn("Move to Inbox")}${btn("More email options")}`
          : btn("Delete", "delete");
      const chip =
        trash &&
        !(
          this.noTrashChipFor !== null &&
          m.subject.includes(this.noTrashChipFor)
        )
          ? ` <span>Trash</span><div role="button" tabindex="0" aria-label="Search for all messages with label Trash">x</div>`
          : "";
      // In Spam, as the live page (with labelsHeading): a heading of its
      // own above the body, drawn with the rest.
      const banner = trash
        ? `<p>This message has been deleted. <a href="#">Restore message</a></p>`
        : m.folder === "spam" && this.labelsHeading
          ? `<div><h3>Why is this message in spam?</h3><p>This message is similar to messages that were identified as spam in the past.</p></div>`
          : "";
      const subject = this.openedSubject ?? m.subject;
      // The search's highlight splitting the run token from the rest of
      // the subject, under another name, when asked.
      const tok = /\[(es:[^\]]+)\]/.exec(subject);
      const shown =
        this.subjectNamedOther && tok !== null
          ? `${esc(subject.slice(0, tok.index))}[<mark>${esc(tok[1]!)}</mark>]${esc(subject.slice(tok.index + tok[0].length))}`
          : this.nestedHighlight && tok !== null
            ? `${esc(subject.slice(0, tok.index))}<span role="heading" aria-level="3">${esc(tok[0])}</span>${esc(subject.slice(tok.index + tok[0].length))}`
            : esc(subject);
      const named = this.subjectNamedOther ? ' aria-label="Conversation"' : "";
      const later =
        this.subjectLaterMs > 0
          ? ` hidden data-later="${this.subjectLaterMs}"`
          : "";
      return this.send(
        res,
        200,
        "text/html",
        `<div class="toolbar" role="toolbar">${del}</div><h2 class="hP"${named}${later}>${shown}</h2>${chip}<div class="sender"><span>${esc(m.fromName)}</span> <div role="button" tabindex="0">Reply</div></div>${banner}<div class="ii gt"><div class="a3s aiL"${hidden}>${m.html}</div></div><div class="actions" style="margin-top:16px"><a href="#" role="link">Reply</a> <a href="#" role="link">Forward</a></div>`,
      );
    }
    // As Gmail's (live Trash search list, 2026-11-02): a check box per
    // row named after the row, and a Trash row's subject cell led by its
    // "Trash" label.
    const label = (m: StandinMessage): string =>
      m.folder === "trash" &&
      !(this.noTrashChipFor !== null && m.subject.includes(this.noTrashChipFor))
        ? `<span class="ar">Trash</span> `
        : "";
    const decoy: StandinMessage = {
      id: "decoy",
      account,
      folder: "trash",
      fromName: "Someone else",
      subject: "An older message",
      preview: "not the run's",
      html: "",
      messageId: "<decoy@mail.invalid>",
      deliveredAt: 0,
    };
    const shown = inTrash && this.trashDecoy ? [...list, decoy] : list;
    const rows = shown
      .map(
        (m) =>
          `<tr class="zA zE" role="row" data-open="${m.id}"${this.rowNamedBySender ? ` aria-labelledby="from-${m.id}"` : ""}><td role="gridcell"><div role="checkbox" tabindex="0" aria-checked="${inTrash && this.preselect === "decoy" && m.id === "decoy"}" aria-label="${esc(m.fromName)}" data-sel="${m.id}" style="display:inline-block;width:14px;height:14px;margin-right:16px"></div></td><td role="gridcell" style="white-space:nowrap"><span class="yP" id="from-${m.id}" email="sender@standin.invalid">${esc(m.fromName)}</span></td><td role="gridcell">${label(m)}<span class="bog">${esc(m.subject)}</span><span class="y2"> - ${esc(m.preview)}</span></td></tr>`,
      )
      .join("");
    // The toolbar over the list: "Select", and the selection's action
    // (hidden until a row is selected).
    const bulk =
      inTrash && this.noListForever
        ? ""
        : `<div role="button" tabindex="0" aria-label="${inTrash ? "Delete forever" : "Delete"}" data-bulk="${inTrash ? "destroy" : "delete"}"${inTrash && this.preselect !== null ? "" : " hidden"}>${inTrash ? "Delete forever" : "Delete"}</div>`;
    const toolbar = `<div role="toolbar" aria-label="List actions"><div role="checkbox" tabindex="0" aria-checked="${inTrash && this.preselect === "toolbar" ? "true" : inTrash && this.preselect === "decoy" ? "mixed" : "false"}" aria-label="Select" style="display:inline-block;width:14px;height:14px"></div> ${bulk}</div>`;
    // The look-alike: the query echoed as a suggestion (an option).
    const suggest =
      this.suggestions && q !== ""
        ? `<div role="listbox" aria-label="Search suggestions"><div role="option" tabindex="-1">${esc(q)}</div></div>`
        : "";
    this.send(
      res,
      200,
      "text/html",
      `${suggest}${this.queryHeading && q !== "" ? `<h2>Search results for ${esc(q)}</h2>` : ""}${toolbar}<table role="grid" style="width:100%"><tbody>${rows}</tbody></table>`,
    );
  }

  // --- Yahoo: server-rendered folders -------------------------------------

  private yahoo(url: URL, account: string, res: ServerResponse): void {
    // /d/folders/N (the adapter's URLs) and, as Yahoo's newer pages,
    // /n/folders/00_N.
    const folders: Record<string, StandinFolder> = {
      "1": "inbox",
      "6": "spam",
      "4": "trash",
      "00_1": "inbox",
      "00_6": "spam",
      "00_4": "trash",
      m6: "spam",
      m4: "trash",
    };
    // A folder's /n/ id (its moved one for a folder of movedIds).
    const nid = (f: StandinFolder): string =>
      f === "inbox"
        ? "00_1"
        : `${this.movedIds.includes(f) ? "m" : "00_"}${f === "spam" ? "6" : "4"}`;
    const m1 = /^\/(d|n)\/folders\/(\w+)(?:\/messages\/([0-9a-f]+))?$/.exec(
      url.pathname,
    );
    if (m1 === null || folders[m1[2]!] === undefined) {
      this.landing = this.mailboxOnlyIn !== null && url.pathname === "/";
      return this.send(res, 302, "text/plain", "", {
        location:
          this.mailboxOnlyIn === null ? "/d/folders/1" : "/n/folders/00_1",
      });
    }
    // The old folder URLs gone: Spam's and Trash's lists sent to the
    // Inbox (their links in the folder list still open them).
    if (
      this.oldFolderUrlsGone &&
      m1[1] === "d" &&
      m1[3] === undefined &&
      m1[2] !== "1"
    )
      return this.send(res, 302, "text/plain", "", {
        location: "/n/folders/00_1",
      });
    // A moved folder's old /n/ id sends to the Inbox.
    if (
      m1[1] === "n" &&
      m1[3] === undefined &&
      m1[2]!.startsWith("00_") &&
      this.movedIds.includes(folders[m1[2]!]!)
    )
      return this.send(res, 302, "text/plain", "", {
        location: "/n/folders/00_1?.src=ym&reason=unexpected_ymv",
      });
    // The new Yahoo Mail: every old list URL sends to its Inbox.
    if (this.newUi && m1[1] === "d" && m1[3] === undefined)
      return this.send(res, 302, "text/plain", "", {
        location: "/n/folders/00_1?.src=ym&reason=unexpected_ymv",
      });
    const base = `/${m1[1]}/folders/${m1[2]}`;
    const folder = folders[m1[2]!]!;
    const bg = this.lang === "bg";
    const L = bg
      ? {
          compose: "Ново съобщение",
          inbox: "Входяща поща",
          spam: "Спам",
          trash: "Кошче",
          search: "Търсете в пощата си",
          del: "Изтриване",
          ok: "Добре",
          selected: "Избрано",
          navigation: "Навигация",
          messages: "съобщения",
          unread: "Непрочетено съобщение",
          actions: ["Преместване", "Отговор", "Изтриване"],
          learn: "Научете още",
          subscribe: "Абониране",
        }
      : {
          compose: "Compose",
          inbox: "Inbox",
          spam: "Spam",
          trash: "Trash",
          search: "Search",
          del: "Delete",
          ok: "OK",
          selected: "Selected",
          navigation: "Navigation",
          messages: "messages",
          unread: "Unread message",
          actions: ["Move", "Reply", "Delete"],
          learn: "Learn more",
          subscribe: "Subscribe",
        };
    // In Bulgarian (as the live Yahoo of 2026-10-31): a compose button
    // and the folder list as links, the account's address in the title,
    // and no English word the mailbox phrases look for.
    // The new Yahoo Mail's folder list: buttons, the current folder's
    // named after a state.
    const folderButton = (f: StandinFolder, id: string, label: string) =>
      this.hiddenFolders.includes(f)
        ? ""
        : `<li><button onclick="location.href='/n/folders/${id}'"${f === folder ? ` aria-label="${L.selected}, ${label}"` : ""}>${label}</button></li>`;
    const nav = this.newUi
      ? `<div class="nav"><nav aria-label="${L.navigation}"><button>${L.compose}</button><ul>${folderButton("inbox", "00_1", L.inbox)}${folderButton("trash", nid("trash"), L.trash)}${folderButton("spam", nid("spam"), L.spam)}</ul></nav><input type="search" name="p" aria-label="${L.search}"></div>`
      : bg
        ? `<div class="nav" role="navigation"><button>${L.compose}</button><input type="search" name="p" aria-label="${L.search}"><ul><li><a href="/n/folders/00_1">${L.inbox}</a></li><li><a href="/n/folders/${nid("spam")}">${L.spam}</a></li><li><a href="/n/folders/${nid("trash")}">${L.trash}</a></li></ul></div>`
        : `<div class="nav" role="navigation"><p>Compose</p><p>Inbox</p><input type="search" name="p" aria-label="Search"></div>`;
    const title = bg
      ? `(1 непрочетен) – ${this.addresses[account] ?? account}`
      : "Mail";
    // The column the list and the opened message take, when the test
    // sets one (between the navigation and a side section, growing with
    // the window).
    const pane =
      this.paneWidth === null
        ? ""
        : `<style>.main{width:${this.paneWidth}}</style>`;
    if (m1[3] !== undefined) {
      const m = this.find(account, m1[3]);
      if (m === undefined)
        return this.send(res, 302, "text/plain", "", { location: base });
      m.read = true;
      this.openedOnce = true;
      const trash = m.folder === "trash";
      const script = `
        const b = document.querySelector('[data-test-id="toolbar-delete"]');
        b.addEventListener("click", async () => {
          if (${trash}) {
            const d = document.createElement("div");
            d.innerHTML = '<div role="dialog" aria-label="Delete forever?" style="position:fixed;top:40%;left:40%;z-index:10;background:#fff;padding:20px;border:1px solid #888"><button data-test-id="primary-btn">${L.ok}</button></div>';
            document.body.append(d);
            d.querySelector("button").addEventListener("click", async () => {
              await fetch("/api/destroy?id=${m.id}", { method: "POST" });
              location.href = "${base}";
            });
            return;
          }
          await fetch("/api/delete?id=${m.id}", { method: "POST" });
          location.href = "${base}";
        });`;
      // Drift: the body hidden from the accessibility tree.
      const hidden = this.drift ? ' aria-hidden="true"' : "";
      return this.send(
        res,
        200,
        "text/html",
        page(
          `${pane}${nav}<div class="main"><div data-test-id="message-view"><button data-test-id="toolbar-delete">${L.del}</button><h2 data-test-id="message-group-subject-text">${esc(m.subject)}</h2><div data-test-id="message-view-body-content"${hidden}>${m.html}</div></div></div>`,
          script,
          true,
          title,
        ),
      );
    }
    // The /n/ Inbox the bare address landed on laid out as a mailbox
    // only in a window no larger than `mailboxOnlyIn`; in a larger one a
    // page without the folder list or the compose button (its title
    // still the account's).
    const landed = this.landing && m1[1] === "n" && folder === "inbox";
    if (m1[3] === undefined) this.landing = false;
    const sized =
      this.mailboxOnlyIn !== null && landed
        ? `<script>if (innerWidth > ${this.mailboxOnlyIn.width} || innerHeight > ${this.mailboxOnlyIn.height}) { document.body.innerHTML = '<div class="main" role="main"><p>${bg ? "Зареждане" : "Loading"}</p></div>'; }</script>`
        : "";
    const list = this.mine(
      account,
      folder === "inbox" ? ["inbox", "other"] : folder,
    );
    // Its message list: a list whose items hold a check box and the
    // message's link (as the live one's, in either language).
    const plain =
      !this.liveRows && !this.conversations && this.rowPreselect === null;
    const rows = plain
      ? `<ul aria-label="">${list
          .map(
            (m) =>
              `<li><input type="checkbox" aria-label=""> <a data-test-id="message-list-item" href="${base}/messages/${m.id}"><span data-test-id="senders">${esc(m.fromName)}</span> <span data-test-id="message-subject">${esc(m.subject)}</span> <span data-test-id="snippet">${esc(m.preview)}</span></a></li>`,
          )
          .join("")}</ul>`
      : this.liveList(list, base, L);
    // The new Yahoo Mail's banner and header links (never rows), and a
    // toolbar's "Spam" that reports a message as spam (never a folder).
    const chrome = this.newUi
      ? `<div><p>Yahoo <a href="#">${L.learn}</a></p></div><header><a href="#">Yahoo Mail</a> <a href="#">${L.subscribe}</a></header><div role="toolbar"><button onclick="fetch('/event?what=report-spam')">${L.spam}</button></div>`
      : "";
    if (this.openedOnce && this.slowMs > 0 && this.slowUntil === null) {
      this.slowUntil = Date.now() + this.slowMs;
      this.events.push("slow");
    }
    const wait = this.slowUntil === null ? 0 : this.slowUntil - Date.now();
    const send = (body: string): void =>
      wait > 0
        ? void setTimeout(() => this.send(res, 200, "text/html", body), wait)
        : this.send(res, 200, "text/html", body);
    send(
      page(
        `${pane}${nav}<div class="main" role="main">${chrome}${rows}</div>${sized}`,
        // The new Yahoo Mail adds a query to a folder's address.
        `${
          this.newUi
            ? `if (location.search === "") history.replaceState(null, "", location.pathname + "?.src=ym");`
            : ""
        }${plain ? "" : this.liveRowScript()}`,
        true,
        title,
      ),
    );
  }

  // Yahoo's rows as live (liveRows, conversations, rowPreselect): a
  // link per row (or conversation) named after the message, holding its
  // check box and its hover actions named after it too, the subject's
  // text hidden from the tree; a conversation's count as a group named
  // "N <messages>" showing N.
  private liveList(
    list: StandinMessage[],
    base: string,
    L: { messages: string; unread: string; actions: string[] },
  ): string {
    type Row = { latest: StandinMessage; count: number; decoy: boolean };
    let rows: Row[] = list.map((m) => ({ latest: m, count: 1, decoy: false }));
    if (this.conversations) {
      const by = new Map<string, Row>();
      for (const m of list) {
        const r = by.get(m.fromName);
        if (r === undefined)
          by.set(m.fromName, { latest: m, count: 1, decoy: false });
        else {
          r.count++;
          if (m.deliveredAt >= r.latest.deliveredAt) r.latest = m;
        }
      }
      rows = [...by.values()];
    }
    if (this.rowPreselect === "other")
      rows.push({
        latest: {
          id: "decoy",
          account: "",
          folder: "spam",
          fromName: "Someone else",
          subject: "An older message",
          preview: "not the run's",
          html: "",
          messageId: "<decoy@mail.invalid>",
          deliveredAt: 0,
        },
        count: 1,
        decoy: true,
      });
    const item = ({ latest: m, count, decoy }: Row): string => {
      const named = `${m.fromName} ${m.subject}`;
      const checked =
        (this.rowPreselect === "own" && !decoy) ||
        (this.rowPreselect === "other" && decoy);
      const actions = L.actions
        .map(
          (a) =>
            `<div role="button" tabindex="0" data-hover aria-label="${esc(`${a} ${m.subject}`)}" data-partial="${esc(a)}" style="display:inline-block;width:40px;height:36px">${esc(a.slice(0, 1))}</div>`,
        )
        .join("");
      // An unread message's link is named with the "unread" word first.
      const unread = m.read === true ? "" : `${L.unread} `;
      return `<li><a data-test-id="message-list-item" href="${base}/messages/${m.id}" aria-label="${esc(`${unread}${named}`)}" data-partial="${esc(`${unread}${m.fromName}`)}" style="position:relative;display:block;height:44px;width:760px"><div role="checkbox" tabindex="0" aria-checked="${checked}" aria-label="${esc(named)}" data-partial="${esc(m.fromName)}" data-sel style="display:inline-block;width:20px;height:20px;margin:12px"></div><span>${esc(m.fromName)}</span>${count > 1 ? ` <span role="group" aria-label="${count} ${L.messages}">${count}</span>` : ""} <span aria-hidden="true">${esc(m.subject)}</span><span class="hover" role="toolbar" aria-label="Message actions" style="position:absolute;right:0;top:4px;${this.hoverAlways ? "" : "display:none"}">${actions}</span></a></li>`;
    };
    return `<style>li:hover .hover{display:inline-block !important}</style><ul aria-label="">${rows.map(item).join("")}</ul>`;
  }

  // The live rows' behaviour: a check box selects its row (never opens
  // it), a hover action does nothing, and with rowClickSelects a click
  // on the row selects it too.
  private liveRowScript(): string {
    return `
      // A list loaded by a reload: its rows named after their senders
      // alone for a while (partialOnReloadMs).
      const loadedBy = performance.getEntriesByType("navigation")[0];
      if (${this.partialOnReloadMs} > 0 && loadedBy !== undefined && loadedBy.type === "reload") {
        const els = [...document.querySelectorAll("[data-partial]")];
        for (const el of els) { el.dataset.full = el.getAttribute("aria-label"); el.setAttribute("aria-label", el.dataset.partial); }
        fetch("/event?what=partial");
        setTimeout(() => { for (const el of els) el.setAttribute("aria-label", el.dataset.full); }, ${this.partialOnReloadMs});
      }
      for (const box of document.querySelectorAll("[data-sel]")) box.addEventListener("click", (e) => {
        e.preventDefault(); e.stopPropagation();
        const on = box.getAttribute("aria-checked") !== "true";
        box.setAttribute("aria-checked", String(on));
        fetch("/event?what=" + (on ? "select" : "unselect"));
      });
      for (const b of document.querySelectorAll("[data-hover]")) b.addEventListener("click", (e) => {
        e.preventDefault(); e.stopPropagation();
        fetch("/event?what=hover-action");
      });
      if (${this.rowClickSelects}) for (const a of document.querySelectorAll('[data-test-id="message-list-item"]')) a.addEventListener("click", (e) => {
        e.preventDefault();
        a.querySelector("[data-sel]").click();
      });`;
  }

  // --- Outlook.com: folders with Focused/Other, a background toggle -------

  private outlook(url: URL, account: string, res: ServerResponse): void {
    const names: Record<string, StandinFolder> = {
      inbox: "inbox",
      junkemail: "spam",
      deleteditems: "trash",
    };
    // The bare /mail/0/ is the Inbox (the address Outlook.com shows it
    // at).
    const m1 =
      /^\/mail\/0\/(inbox|junkemail|deleteditems)(?:\/id\/([0-9a-f]+))?$/.exec(
        url.pathname === "/mail/0/" ? "/mail/0/inbox" : url.pathname,
      );
    if (m1 === null)
      return this.send(res, 302, "text/plain", "", {
        location: "/mail/0/inbox",
      });
    const fname = m1[1]!;
    // The reading pane's width, when the test sets one (a pane between
    // the webmail's columns, growing with the window).
    const pane =
      this.paneWidth === null
        ? ""
        : `<style>.main{width:${this.paneWidth}}</style>`;
    const nav = `${pane}<div class="nav" role="navigation"><p>New mail</p><p>Inbox</p><input id="topSearchInput" type="search" aria-label="Search"></div>`;
    if (m1[2] !== undefined) {
      const m = this.find(account, m1[2]);
      if (m === undefined)
        return this.send(res, 302, "text/plain", "", {
          location: `/mail/0/${fname}`,
        });
      const trash = m.folder === "trash";
      // Its theme follows the browser's scheme (unless ignoresDark); the
      // toggle exists only in dark (and not with noToggle).
      const script = `
        const body = document.querySelector('[data-body]');
        const dark = ${!this.ignoresDark} && matchMedia("(prefers-color-scheme: dark)").matches;
        let toggle = null;
        if (dark && ${!this.noToggle}) {
          toggle = document.createElement("button");
          toggle.setAttribute("aria-label", "Switch background");
          toggle.setAttribute("aria-pressed", "${this.togglePressed}");
          toggle.textContent = "Background";
          document.querySelector('[data-del]').after(toggle);
        }
        function paint() {
          const light = !dark || (toggle !== null && toggle.getAttribute("aria-pressed") === "true");
          body.style.background = light ? "#ffffff" : "#1f1f1f";
          body.style.color = light ? "" : "#f0f0f0";
          for (const el of body.querySelectorAll("*")) {
            if (light) { el.removeAttribute("data-ogsc"); el.style.removeProperty("filter"); }
            else if (getComputedStyle(el).backgroundColor !== "rgba(0, 0, 0, 0)" || el.style.color) { el.setAttribute("data-ogsc", ""); el.style.setProperty("filter", "invert(0.9) hue-rotate(180deg)"); }
          }
        }
        if (toggle !== null) toggle.addEventListener("click", () => { fetch("/event?what=toggle"); toggle.setAttribute("aria-pressed", toggle.getAttribute("aria-pressed") === "true" ? "false" : "true"); paint(); });
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
          `${nav}<div class="main" role="main"><div role="heading" aria-level="2">${esc(m.subject)}</div><button aria-label="Delete" data-del>Delete</button> <div role="document" aria-label="${bodyLabel}" data-body>${m.html}</div></div>`,
          script,
          !this.ignoresDark,
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
    // Its list: placeholder rows first (hidden from the tree, as
    // Outlook.com's are), then the rows, or the empty folder's notice.
    const content =
      rows === ""
        ? `<div><div>Nothing in folder</div><div>Looks empty over here.</div></div>`
        : `<div role="listbox">${rows}</div>`;
    const loads = this.neverLoads.includes(folder) ? -1 : this.listLoadingMs;
    const placeholders = `<div aria-hidden="true">${'<div style="height:40px;margin:8px 0;background:#e8e8e8"></div>'.repeat(6)}</div>`;
    // The Inbox's address shown as the bare /mail/0/ (its tab kept).
    const script = `${fname === "inbox" && url.pathname !== "/mail/0/" ? `history.replaceState(null, "", "/mail/0/" + location.search);` : ""}
      const list = document.getElementById("list");
      const show = () => { list.innerHTML = document.getElementById("rows").innerHTML; };
      ${loads === 0 ? "show();" : loads > 0 ? `setTimeout(show, ${loads});` : ""}`;
    const app = `${nav}<div class="main" role="main">${tabs}<div role="region" aria-label="Message list"><div id="list">${placeholders}</div></div><template id="rows">${content}</template></div>`;
    // Its loading screen first (the app hidden, so not in the tree): a
    // logo and "Microsoft" as images in an otherwise empty page.
    if (this.splashLoads > 0) {
      this.splashLoads--;
      const end =
        this.splashMs < 0
          ? ""
          : `setTimeout(() => { document.getElementById("splash").remove(); document.getElementById("app").hidden = false; }, ${this.splashMs});`;
      return this.send(
        res,
        200,
        "text/html",
        page(
          `<div id="splash"><div><div role="img" aria-label="" style="position:fixed;left:45%;top:40%;width:160px;height:160px;background:#4f6bed;border-radius:24px"></div></div><div role="img" aria-label="Microsoft" style="position:fixed;left:46%;bottom:40px;width:100px;height:22px;background:#737373"></div></div><div id="app" hidden>${app}</div>`,
          `${script}\n${end}`,
          !this.ignoresDark,
          "Outlook",
        ),
      );
    }
    this.send(res, 200, "text/html", page(app, script, !this.ignoresDark));
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
