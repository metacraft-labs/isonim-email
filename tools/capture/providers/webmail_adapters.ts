// tools/capture/providers/webmail_adapters.ts — what the hosted-webmail
// provider knows about each webmail's UI, as data.
//
// One adapter per webmail (Gmail, Yahoo Mail, Outlook.com): the folder
// URLs the arrival search opens (Inbox, then Spam/Junk; Trash for the
// removal; alternatives, tried in order), and accessibility locators
// (a11y_tree.ts) for a message row (alternatives too), the opened
// message's subject and body, the delete controls, Outlook.com's tabs
// and its optional reading-pane background toggle, where a delete may
// be permanent, plus how much wider than the requested width the window
// is so that the body gets the requested width. The capture
// procedure (hosted_webmail.ts) is one implementation over these,
// driving the webmail browser through GuiAssert (webmail_desktop.ts):
// the page is read from the browser's accessibility tree, as a screen
// reader reads it, never from its DOM.
//
// - A row is a node one of the row locators matches inside the page
//   whose accessible text (its name, or the names and text inside it)
//   carries the run token (a11y_tree.ts `tokenRows`): Chrome names some
//   rows from their content and folds pruned containers' text into the
//   cells, so the token may be in either.
// - The opened message is the delivered one when a heading's name
//   carries the token.
// - The body is the node `opened.body` names, or, when the webmail gives
//   the body no name (Gmail, Yahoo), the story region: the message
//   column from below the webmail's last element above the story's own
//   text to above its first element after it (a11y_tree.ts
//   `locateStoryRegion`; Chrome prunes the generic containers a body
//   sits in, so there is no body node). WEBMAIL_CHROME are the
//   webmail's own controls, never part of a body.
//
// The locators are written from the webmails' public descriptions and
// their known ARIA markup. Each carries its status: "unverified-live"
// until a live capture used it successfully, "verified-live" after (with
// the run that did, below); the provenance of every capture records the
// adapter's status, so a capture made with an unconfirmed locator says
// so. The first live capture of each adapter confirms or corrects them;
// a locator that matches nothing or more than one element fails the
// capture loudly, naming it (UI drift), so a wrong locator can never
// produce a wrong crop silently.
//
// The URLs are templates: {mid} is the Message-ID without its angle
// brackets and {token} the run token, both URL-encoded.

import type { A11yLocator } from "./a11y_tree.ts";
import { WEBMAIL_SIGNIN, type WebmailSignin } from "./webmail_profiles.ts";
import type { Scheme, ViewportSpec } from "./types.ts";

export type LocatorStatus = "unverified-live" | "verified-live";

export interface WebmailLocator extends A11yLocator {
  status: LocatorStatus;
}

// A locator no live capture has used yet.
const u = (loc: A11yLocator): WebmailLocator => ({
  ...loc,
  status: "unverified-live",
});
// A locator a live capture used successfully (the run is named where it
// is used).
const v = (loc: A11yLocator): WebmailLocator => ({
  ...loc,
  status: "verified-live",
});

/** A locator as one line, for diagnostics. */
export function describeLocator(l: A11yLocator): string {
  const parts: string[] = [];
  if (l.role !== undefined) parts.push(`role=${l.role}`);
  if (l.nativeRole !== undefined) parts.push(`nativeRole=${l.nativeRole}`);
  if (l.name !== undefined) parts.push(`name=${JSON.stringify(l.name)}`);
  if (l.nameContains !== undefined)
    parts.push(`name*=${JSON.stringify(l.nameContains)}`);
  if (l.namePattern !== undefined) parts.push(`name~/${l.namePattern}/i`);
  return parts.join(" ");
}

export type FolderName = "inbox" | "spam" | "trash";

export interface FolderSpec {
  // What the provenance and the reports call it ("Inbox", "Spam",
  // "Junk Email", …).
  label: string;
  // The URLs that list the folder (or search it), tried in order within
  // one look until one shows a row carrying the token.
  urls: string[];
  // Tabs to look in as well, in order (Outlook.com's Focused/Other).
  tabs: WebmailLocator[];
}

export interface AdapterUi {
  device: "desktop";
  folders: Record<FolderName, FolderSpec>;
  // One message in a folder or search list, as alternatives tried in
  // order; the arrival search keeps the row whose accessible text
  // carries the run token (a11y_tree.ts `tokenRows`).
  rows: WebmailLocator[];
  opened: {
    // The opened message's subject (its name must carry the run token).
    subject: WebmailLocator;
    // The message body, when the webmail names it; null: the story region.
    body: WebmailLocator | null;
    // Inside the body's box: the webmail's own elements, masked.
    masks: WebmailLocator[];
  };
  remove: {
    // In the opened message: moves it to Trash / Deleted Items.
    del: WebmailLocator;
    // In the opened message in Trash: deletes it for good.
    deleteForever: WebmailLocator;
    // A confirmation the permanent delete asks for, if any.
    confirm: WebmailLocator | null;
    // The folders whose opened message offers only the permanent delete
    // (`deleteForever`, no Trash step): Gmail's Spam, whose toolbar
    // reads "Delete forever" and "Not spam" [unverified-live].
    permanentIn: FolderName[];
    // The folders from which the delete may itself be permanent: a
    // message deleted there that never shows up in Trash / Deleted
    // Items is removed (`via: "permanent"`), not a failed cleanup.
    // [unverified-live: which of the two happens, the first live
    // cleanup records say]
    mayBePermanentIn: FolderName[];
  };
  // A webmail that recolours a body in its dark theme (Outlook.com):
  // its theme follows the browser's colour mode (light in a light
  // capture, dark in a dark one, each checked by the subject heading's
  // luminance), and in dark its reading-pane background toggle, when
  // one is shown, must be unchecked (checked: the body switched back to
  // light). null: the webmail does not recolour the body.
  dark: { toggle: WebmailLocator } | null;
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
  ui: "desktop";
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
  clients: AdapterClient[];
}

/**
 * The webmails' own controls, never part of a message body: a body is
 * HTML mail, which every webmail strips of buttons and form fields (a
 * story's call to action is a link).
 */
export const WEBMAIL_CHROME: A11yLocator[] = [
  { role: "button" },
  { role: "text-field" },
  { role: "combo-box" },
  { role: "checkbox" },
  { role: "toolbar" },
  { role: "tab" },
  { role: "menu" },
];

export const DESKTOP_VIEWPORT: ViewportSpec = {
  name: "desktop",
  width: 800,
  dpr: 1,
};
// The height of a capture's window (and of its session's display): the
// reading pane shows a body up to about this tall without scrolling. A
// taller body fails, naming its height (scroll-and-stitch is later).
// [measure: whether so tall a screen changes a provider's layout]
export const CAPTURE_WINDOW_HEIGHT = 2400;

const folder = (
  label: string,
  urls: string[],
  tabs: WebmailLocator[] = [],
): FolderSpec => ({ label, urls, tabs });

// Gmail (consumer or Workspace; the same web UI). A Gmail search leaves
// Spam and Trash out unless the query names them, so each folder is a
// search URL: rfc822msgid: first (exactly the delivered message, if
// Gmail kept the submitted Message-ID: not measured), then the run token
// as a quoted phrase. Its list is a grid of rows (a table row in
// Chrome's tree); the opened subject an h2; the body unnamed.
const GMAIL = "https://mail.google.com/mail/u/0/#search/";
const GMAIL_DESKTOP: AdapterUi = {
  device: "desktop",
  folders: {
    inbox: folder("Inbox", [
      `${GMAIL}rfc822msgid%3A{mid}`,
      `${GMAIL}%22{token}%22`,
    ]),
    spam: folder("Spam", [
      `${GMAIL}in%3Aspam+rfc822msgid%3A{mid}`,
      `${GMAIL}in%3Aspam+%22{token}%22`,
    ]),
    trash: folder("Trash", [
      `${GMAIL}in%3Atrash+rfc822msgid%3A{mid}`,
      `${GMAIL}in%3Atrash+%22{token}%22`,
    ]),
  },
  // A grid row ("table row" in Chrome's tree); its accessible text holds
  // the subject whether Chrome names the row from its cells or not.
  rows: [u({ role: "row" })],
  opened: {
    subject: u({ nativeRole: "heading" }),
    body: null,
    masks: [],
  },
  remove: {
    del: u({ role: "button", name: "Delete" }),
    deleteForever: u({ role: "button", name: "Delete forever" }),
    confirm: null,
    permanentIn: ["spam"],
    mayBePermanentIn: [],
  },
  dark: null,
  windowAllowance: 440,
};

const YAHOO_DESKTOP: AdapterUi = {
  device: "desktop",
  folders: {
    inbox: folder("Inbox", ["https://mail.yahoo.com/d/folders/1"]),
    spam: folder("Spam", ["https://mail.yahoo.com/d/folders/6"]),
    trash: folder("Trash", ["https://mail.yahoo.com/d/folders/4"]),
  },
  // Each message of a folder is a link to it (or an option of a list).
  rows: [u({ role: "link" }), u({ role: "list-item" })],
  opened: {
    subject: u({ nativeRole: "heading" }),
    body: null,
    masks: [],
  },
  remove: {
    del: u({ role: "button", name: "Delete" }),
    deleteForever: u({ role: "button", name: "Delete" }),
    confirm: u({ role: "button", name: "OK" }),
    permanentIn: [],
    mayBePermanentIn: ["spam"],
  },
  dark: null,
  windowAllowance: 560,
};

const OUTLOOK_FOLDERS = (base: string): Record<FolderName, FolderSpec> => ({
  inbox: folder(
    "Inbox",
    [`${base}/inbox`],
    [u({ role: "tab", name: "Focused" }), u({ role: "tab", name: "Other" })],
  ),
  spam: folder("Junk Email", [`${base}/junkemail`]),
  trash: folder("Deleted Items", [`${base}/deleteditems`]),
});

// Outlook.com: a listbox of options, the opened subject a heading, the
// body named "Message body"; its theme follows the browser's colour
// mode, and in dark the reading pane's background toggle, if shown,
// keeps the body in its dark state. The row and the subject were used
// by the first live capture (2026-10-31, run a1-20261031T083958Z: the
// message found in Junk Email and opened, its heading carrying the run
// token).
const OUTLOOK_DESKTOP: AdapterUi = {
  device: "desktop",
  folders: OUTLOOK_FOLDERS("https://outlook.live.com/mail/0"),
  rows: [v({ role: "list-item" })],
  opened: {
    subject: v({ nativeRole: "heading" }),
    body: u({ name: "Message body" }),
    masks: [],
  },
  remove: {
    del: u({ role: "button", name: "Delete" }),
    deleteForever: u({ role: "button", name: "Delete" }),
    confirm: u({ role: "button", name: "OK" }),
    permanentIn: [],
    mayBePermanentIn: ["spam"],
  },
  dark: { toggle: u({ role: "button", namePattern: "background" }) },
  windowAllowance: 640,
};

export const WEBMAIL_ADAPTERS: WebmailAdapter[] = [
  {
    id: "gmail",
    set: "gmail-workspace",
    label: "Gmail",
    signin: WEBMAIL_SIGNIN["gmail-workspace"]!,
    status: "unverified-live",
    desktop: GMAIL_DESKTOP,
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
    clients: [
      {
        clientId: "outlook-web",
        family: "outlookWeb",
        kind: "message",
        ui: "desktop",
        viewports: [DESKTOP_VIEWPORT],
        // Light in a light browser, the toggle untouched; dark in a dark
        // browser, the body in its dark state (the toggle, if shown,
        // unchecked); each theme checked.
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

// A folder's URLs for one message, in order.
export function folderUrls(
  f: FolderSpec,
  h: { messageId: string; token: string },
): string[] {
  const mid = h.messageId.replace(/^</, "").replace(/>$/, "");
  return f.urls.map((url) =>
    url
      .replaceAll("{mid}", encodeURIComponent(mid))
      .replaceAll("{token}", encodeURIComponent(h.token)),
  );
}

// Every locator of an adapter, named (for the status report and the
// drift diagnostics).
export function adapterLocators(
  a: WebmailAdapter,
): { name: string; locator: WebmailLocator }[] {
  const out: { name: string; locator: WebmailLocator }[] = [];
  const ui = a.desktop;
  const add = (name: string, l: WebmailLocator | null): void => {
    if (l !== null) out.push({ name: `desktop.${name}`, locator: l });
  };
  ui.rows.forEach((r, i) => add(`rows${i}`, r));
  add("opened.subject", ui.opened.subject);
  add("opened.body", ui.opened.body);
  ui.opened.masks.forEach((m, i) => add(`opened.mask${i}`, m));
  add("remove.delete", ui.remove.del);
  add("remove.deleteForever", ui.remove.deleteForever);
  add("remove.confirm", ui.remove.confirm);
  add("dark.toggle", ui.dark?.toggle ?? null);
  for (const [name, f] of Object.entries(ui.folders))
    f.tabs.forEach((t, i) => add(`folders.${name}.tab${i}`, t));
  return out;
}

// The adapter with its URLs moved to another origin per webmail host
// (tests: a stand-in webmail on loopback implementing the same
// accessibility contract). Locators are kept as they are.
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
  const x = a.desktop;
  return {
    ...a,
    signin: {
      ...a.signin,
      inboxUrl: move(a.signin.inboxUrl),
      mailHosts: a.signin.mailHosts.map((h) =>
        origins[h] === undefined ? h : new URL(origins[h]).host,
      ),
    },
    desktop: {
      ...x,
      folders: {
        inbox: { ...x.folders.inbox, urls: x.folders.inbox.urls.map(move) },
        spam: { ...x.folders.spam, urls: x.folders.spam.urls.map(move) },
        trash: { ...x.folders.trash, urls: x.folders.trash.urls.map(move) },
      },
    },
  };
}
