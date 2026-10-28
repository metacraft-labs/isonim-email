// tools/capture/providers/webmail_adapters.ts — what the hosted-webmail
// provider knows about each webmail's UI, as data.
//
// One adapter per webmail (Gmail, Yahoo Mail, Outlook.com): the folder
// URLs the arrival search opens (Inbox, then Spam/Junk; Trash for the
// removal), the locators of a message row and its parts, of the opened
// message, its body and the chrome to mask inside it, of the delete
// controls, of Outlook.com's per-message background toggle, the root of
// the reading pane whose structure is the UI fingerprint, and how much
// wider than the requested width the window is so that the body gets
// the requested width. The capture procedure (hosted_webmail.ts) is one
// implementation over these.
//
// EVERY LOCATOR HERE IS UNVERIFIED-LIVE. They are written from the
// webmails' public descriptions and long-standing knowledge of their
// DOM, not measured against the live UIs (no sign-in had been made when
// they were written). Each carries its status
// (`status: "unverified-live"`), and the provenance of every capture
// records the adapter's status, so a capture made with an unconfirmed
// locator says so. The first live capture of each adapter confirms or
// corrects them; a locator that matches nothing or more than one
// element fails the capture loudly, naming it (UI drift), so a wrong
// locator can never produce a wrong crop silently.
//
// The URLs are templates: {mid} is the Message-ID without its angle
// brackets and {token} the run token, both URL-encoded.

import { WEBMAIL_SIGNIN, type WebmailSignin } from "./webmail_profiles.ts";
import type { Scheme, ViewportSpec } from "./types.ts";

export type LocatorStatus = "unverified-live" | "verified-live";

export interface WebmailLocator {
  css: string;
  status: LocatorStatus;
}

// Every locator of this file is made by this: none is confirmed yet.
const u = (css: string): WebmailLocator => ({
  css,
  status: "unverified-live",
});

export type FolderName = "inbox" | "spam" | "trash";

export interface FolderSpec {
  // What the provenance and the reports call it ("Inbox", "Spam",
  // "Junk Email", …).
  label: string;
  url: string;
  // Tabs to look in as well, in order (Outlook.com's Focused/Other).
  tabs: WebmailLocator[];
}

export interface AdapterUi {
  // Desktop window or a phone's mobile web UI.
  device: "desktop" | "iphone";
  folders: Record<FolderName, FolderSpec>;
  // One message in a folder or search list; the arrival search keeps
  // the ones whose text carries the run token.
  row: WebmailLocator;
  // Inside a row: the texts a list-row capture records.
  rowParts: {
    sender: WebmailLocator;
    subject: WebmailLocator;
    preview: WebmailLocator;
  };
  opened: {
    // The opened message's subject (it must carry the run token).
    subject: WebmailLocator;
    // The message body: the crop.
    body: WebmailLocator;
    // Inside the body, present once the message HTML is in.
    bodyReady: WebmailLocator | null;
    // Chrome the webmail draws inside the body's box, masked.
    masks: WebmailLocator[];
  };
  remove: {
    // In the opened message: moves it to Trash / Deleted Items.
    del: WebmailLocator;
    // In the opened message in Trash: deletes it for good.
    deleteForever: WebmailLocator;
    // A confirmation the permanent delete asks for, if any.
    confirm: WebmailLocator | null;
  };
  // The opened message's background toggle (Outlook.com), whose
  // aria-pressed="true" means the body is shown on a light background;
  // null when the webmail does not recolour the body.
  darkToggle: WebmailLocator | null;
  // The reading pane: its structure (the body's own subtree left out)
  // is the UI fingerprint.
  fingerprintRoot: WebmailLocator;
  // Pixels the window is wider than the requested width, so that the
  // reading pane gives the body the requested width (folders, side
  // bars). [calibrate on the first live capture; the provenance records
  // the body width actually measured]
  windowAllowance: number;
}

export interface AdapterClient {
  clientId: string;
  family: string;
  // "message": the opened body; "list": the message's row (named-only).
  kind: "message" | "list";
  ui: "desktop" | "mobile";
  viewports: ViewportSpec[];
  schemes: Scheme[];
}

export interface WebmailAdapter {
  id: string;
  // The credential set (credentials.ts) and profile set (webmail_profiles.ts).
  set: string;
  label: string;
  signin: WebmailSignin;
  status: LocatorStatus;
  desktop: AdapterUi;
  mobile: AdapterUi | null;
  clients: AdapterClient[];
}

export const DESKTOP_VIEWPORT: ViewportSpec = {
  name: "desktop",
  width: 800,
  dpr: 1,
};
export const MOBILE_VIEWPORT: ViewportSpec = {
  name: "mobile",
  width: 375,
  dpr: 3,
};

// The window height a capture starts with; a taller body grows it.
export const WINDOW_HEIGHT = { desktop: 900, mobile: 812 };

// The phone the mobile-web variant presents as: an iPhone's UA, touch
// and mobile flag, at the requested viewport (375 wide at DPR 3).
export const IPHONE_USER_AGENT =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1";

const folder = (
  label: string,
  url: string,
  tabs: WebmailLocator[] = [],
): FolderSpec => ({ label, url, tabs });

// Gmail (consumer or Workspace; the same web UI). A Gmail search leaves
// Spam and Trash out unless the query names them, so each folder is a
// search URL; rfc822msgid: finds exactly the delivered message.
const GMAIL_DESKTOP: AdapterUi = {
  device: "desktop",
  folders: {
    inbox: folder(
      "Inbox",
      "https://mail.google.com/mail/u/0/#search/rfc822msgid%3A{mid}",
    ),
    spam: folder(
      "Spam",
      "https://mail.google.com/mail/u/0/#search/in%3Aspam+rfc822msgid%3A{mid}",
    ),
    trash: folder(
      "Trash",
      "https://mail.google.com/mail/u/0/#search/in%3Atrash+rfc822msgid%3A{mid}",
    ),
  },
  row: u("tr.zA"),
  rowParts: {
    sender: u("span[email]"),
    subject: u("span.bog"),
    preview: u("span.y2"),
  },
  opened: {
    subject: u("h2.hP"),
    body: u("div.a3s"),
    bodyReady: null,
    masks: [],
  },
  remove: {
    del: u('[role="button"][aria-label="Delete"]'),
    deleteForever: u('[role="button"]:has-text("Delete forever")'),
    confirm: null,
  },
  darkToggle: null,
  fingerprintRoot: u('div[role="main"]'),
  windowAllowance: 440,
};

// Gmail's mobile web UI, served to a phone's user agent.
const GMAIL_MOBILE: AdapterUi = {
  device: "iphone",
  folders: {
    inbox: folder(
      "Inbox",
      "https://mail.google.com/mail/mu/mp/#tl/search/rfc822msgid%3A{mid}",
    ),
    spam: folder(
      "Spam",
      "https://mail.google.com/mail/mu/mp/#tl/search/in%3Aspam+rfc822msgid%3A{mid}",
    ),
    trash: folder(
      "Trash",
      "https://mail.google.com/mail/mu/mp/#tl/search/in%3Atrash+rfc822msgid%3A{mid}",
    ),
  },
  row: u('div[role="listitem"]'),
  rowParts: {
    sender: u('[role="listitem"] [email], .fl'),
    subject: u(".tl-subject, .Bk"),
    preview: u(".tl-snippet, .Ck"),
  },
  opened: {
    subject: u('[role="heading"][aria-level="2"]'),
    body: u("div.msg-body, div.a3s"),
    bodyReady: null,
    masks: [],
  },
  remove: {
    del: u('[role="button"][aria-label="Delete"]'),
    deleteForever: u('[role="button"]:has-text("Delete forever")'),
    confirm: null,
  },
  darkToggle: null,
  fingerprintRoot: u('[role="main"]'),
  windowAllowance: 0,
};

const YAHOO_DESKTOP: AdapterUi = {
  device: "desktop",
  folders: {
    inbox: folder("Inbox", "https://mail.yahoo.com/d/folders/1"),
    spam: folder("Spam", "https://mail.yahoo.com/d/folders/6"),
    trash: folder("Trash", "https://mail.yahoo.com/d/folders/4"),
  },
  row: u('[data-test-id="message-list-item"]'),
  rowParts: {
    sender: u('[data-test-id="senders"]'),
    subject: u('[data-test-id="message-subject"]'),
    preview: u('[data-test-id="snippet"]'),
  },
  opened: {
    subject: u('[data-test-id="message-group-subject-text"]'),
    body: u('[data-test-id="message-view-body-content"]'),
    bodyReady: null,
    masks: [],
  },
  remove: {
    del: u('button[data-test-id="toolbar-delete"]'),
    deleteForever: u('button[data-test-id="toolbar-delete"]'),
    confirm: u('button[data-test-id="primary-btn"]'),
  },
  darkToggle: null,
  fingerprintRoot: u('[data-test-id="message-view"]'),
  windowAllowance: 560,
};

const OUTLOOK_FOLDERS = (base: string): Record<FolderName, FolderSpec> => ({
  inbox: folder("Inbox", `${base}/inbox`, [
    u('[role="tab"]:has-text("Focused")'),
    u('[role="tab"]:has-text("Other")'),
  ]),
  spam: folder("Junk Email", `${base}/junkemail`),
  trash: folder("Deleted Items", `${base}/deleteditems`),
});

const OUTLOOK_DESKTOP: AdapterUi = {
  device: "desktop",
  folders: OUTLOOK_FOLDERS("https://outlook.live.com/mail/0"),
  row: u('[role="listbox"] [role="option"]'),
  rowParts: {
    sender: u("span[title*='@']"),
    subject: u('[data-testid="SubjectLine"], span.TtcXM'),
    preview: u('[data-testid="PreviewText"], span.FqgPc'),
  },
  opened: {
    subject: u('[role="main"] [role="heading"][aria-level="2"]'),
    body: u('[aria-label="Message body"]'),
    bodyReady: null,
    masks: [],
  },
  remove: {
    del: u('button[aria-label="Delete"]'),
    deleteForever: u('button[aria-label="Delete"]'),
    confirm: u('[role="dialog"] button:has-text("OK")'),
  },
  darkToggle: u('button[aria-label*="background" i]'),
  fingerprintRoot: u('[role="main"]'),
  windowAllowance: 640,
};

const OUTLOOK_MOBILE: AdapterUi = {
  ...OUTLOOK_DESKTOP,
  device: "iphone",
  windowAllowance: 0,
};

export const WEBMAIL_ADAPTERS: WebmailAdapter[] = [
  {
    id: "gmail",
    set: "gmail-workspace",
    label: "Gmail",
    signin: WEBMAIL_SIGNIN["gmail-workspace"]!,
    status: "unverified-live",
    desktop: GMAIL_DESKTOP,
    mobile: GMAIL_MOBILE,
    clients: [
      {
        clientId: "gmail-web",
        family: "gmailWeb",
        kind: "message",
        ui: "desktop",
        viewports: [DESKTOP_VIEWPORT],
        // Gmail web does not recolour the body: dark is not-applicable.
        schemes: ["light"],
      },
      {
        clientId: "gmail-mobile-web",
        family: "gmailWeb",
        kind: "message",
        ui: "mobile",
        viewports: [MOBILE_VIEWPORT],
        schemes: ["light"],
      },
      {
        clientId: "gmail-list",
        family: "gmailWeb",
        kind: "list",
        ui: "desktop",
        viewports: [DESKTOP_VIEWPORT],
        schemes: ["light"],
      },
    ],
  },
  {
    id: "yahoo",
    set: "yahoo",
    label: "Yahoo Mail",
    signin: WEBMAIL_SIGNIN.yahoo!,
    status: "unverified-live",
    desktop: YAHOO_DESKTOP,
    mobile: null,
    clients: [
      {
        clientId: "yahoo-web",
        family: "yahoo",
        kind: "message",
        ui: "desktop",
        viewports: [DESKTOP_VIEWPORT],
        schemes: ["light"],
      },
      {
        clientId: "yahoo-list",
        family: "yahoo",
        kind: "list",
        ui: "desktop",
        viewports: [DESKTOP_VIEWPORT],
        schemes: ["light"],
      },
    ],
  },
  {
    id: "outlook-com",
    set: "outlook-com",
    label: "Outlook.com",
    signin: WEBMAIL_SIGNIN["outlook-com"]!,
    status: "unverified-live",
    desktop: OUTLOOK_DESKTOP,
    mobile: OUTLOOK_MOBILE,
    clients: [
      {
        clientId: "outlook-web",
        family: "outlookWeb",
        kind: "message",
        ui: "desktop",
        viewports: [DESKTOP_VIEWPORT],
        // Dark: the app theme dark, the body in its dark state; light:
        // the per-message background toggle on.
        schemes: ["light", "dark"],
      },
      {
        clientId: "outlook-mobile-web",
        family: "outlookWeb",
        kind: "message",
        ui: "mobile",
        viewports: [MOBILE_VIEWPORT],
        schemes: ["light", "dark"],
      },
      {
        clientId: "outlook-list",
        family: "outlookWeb",
        kind: "list",
        ui: "desktop",
        viewports: [DESKTOP_VIEWPORT],
        schemes: ["light"],
      },
    ],
  },
];

export function adapterFor(clientId: string): {
  adapter: WebmailAdapter;
  client: AdapterClient;
} | null {
  for (const adapter of WEBMAIL_ADAPTERS)
    for (const client of adapter.clients)
      if (client.clientId === clientId) return { adapter, client };
  return null;
}

// A folder URL for one message.
export function folderUrl(
  f: FolderSpec,
  h: { messageId: string; token: string },
): string {
  const mid = h.messageId.replace(/^</, "").replace(/>$/, "");
  return f.url
    .replaceAll("{mid}", encodeURIComponent(mid))
    .replaceAll("{token}", encodeURIComponent(h.token));
}

// Every locator of an adapter, named (for the status report and the
// drift diagnostics).
export function adapterLocators(
  a: WebmailAdapter,
): { name: string; locator: WebmailLocator }[] {
  const out: { name: string; locator: WebmailLocator }[] = [];
  const uis: [string, AdapterUi | null][] = [
    ["desktop", a.desktop],
    ["mobile", a.mobile],
  ];
  for (const [mode, ui] of uis) {
    if (ui === null) continue;
    const add = (name: string, l: WebmailLocator | null): void => {
      if (l !== null) out.push({ name: `${mode}.${name}`, locator: l });
    };
    add("row", ui.row);
    add("row.sender", ui.rowParts.sender);
    add("row.subject", ui.rowParts.subject);
    add("row.preview", ui.rowParts.preview);
    add("opened.subject", ui.opened.subject);
    add("opened.body", ui.opened.body);
    add("opened.bodyReady", ui.opened.bodyReady);
    ui.opened.masks.forEach((m, i) => add(`opened.mask${i}`, m));
    add("remove.delete", ui.remove.del);
    add("remove.deleteForever", ui.remove.deleteForever);
    add("remove.confirm", ui.remove.confirm);
    add("darkToggle", ui.darkToggle);
    add("fingerprintRoot", ui.fingerprintRoot);
    for (const [name, f] of Object.entries(ui.folders))
      f.tabs.forEach((t, i) => add(`folders.${name}.tab${i}`, t));
  }
  return out;
}

// The adapter with its URLs moved to another origin per webmail host
// (tests: a stand-in webmail on loopback implementing the same DOM
// contract). Locators are kept as they are.
export function rebaseAdapter(
  a: WebmailAdapter,
  origins: Record<string, string>,
): WebmailAdapter {
  const move = (url: string): string => {
    const m = /^https?:\/\/([^/#?]+)/.exec(url);
    const to = m === null ? undefined : origins[m[1]!];
    if (m === null || to === undefined) return url;
    return to.replace(/\/$/, "") + url.slice(m[0].length);
  };
  const ui = (x: AdapterUi | null): AdapterUi | null =>
    x === null
      ? null
      : {
          ...x,
          folders: {
            inbox: { ...x.folders.inbox, url: move(x.folders.inbox.url) },
            spam: { ...x.folders.spam, url: move(x.folders.spam.url) },
            trash: { ...x.folders.trash, url: move(x.folders.trash.url) },
          },
        };
  return {
    ...a,
    signin: {
      ...a.signin,
      inboxUrl: move(a.signin.inboxUrl),
      mailHosts: a.signin.mailHosts.map((h) =>
        origins[h] === undefined ? h : new URL(origins[h]).host,
      ),
    },
    desktop: ui(a.desktop)!,
    mobile: ui(a.mobile),
  };
}
