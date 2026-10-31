// tools/capture/providers/webmail_adapters.ts — what the hosted-webmail
// provider knows about each webmail's UI, as data.
//
// One adapter per webmail (Gmail, Yahoo Mail, Outlook.com): the folder
// URLs the arrival search opens (Inbox, then Spam/Junk; Trash for the
// removal), and accessibility locators (a11y_tree.ts) for a message
// row, the opened message's subject and body, the delete controls,
// Outlook.com's tabs and per-message background toggle, plus how much
// wider than the requested width the window is so that the body gets
// the requested width, and the browser's colour scheme. The capture
// procedure (hosted_webmail.ts) is one implementation over these,
// driving the webmail browser through GuiAssert (webmail_desktop.ts):
// the page is read from the browser's accessibility tree, as a screen
// reader reads it, never from its DOM.
//
// - A row is the row-role node whose accessible name carries the run
//   token (rows, options and links take their name from their content).
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
// EVERY LOCATOR HERE IS UNVERIFIED-LIVE. They are written from the
// webmails' public descriptions and their known ARIA markup, not
// measured against the live UIs. Each carries its status (`status:
// "unverified-live"`), and the provenance of every capture records the
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

// Every locator of this file is made by this: none is confirmed yet.
const u = (loc: A11yLocator): WebmailLocator => ({
  ...loc,
  status: "unverified-live",
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
  url: string;
  // Tabs to look in as well, in order (Outlook.com's Focused/Other).
  tabs: WebmailLocator[];
}

export interface AdapterUi {
  device: "desktop";
  folders: Record<FolderName, FolderSpec>;
  // One message in a folder or search list; the arrival search keeps
  // the one whose accessible name carries the run token.
  row: WebmailLocator;
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
  };
  // The opened message's background toggle (Outlook.com), checked when
  // the body is shown on a light background; null when the webmail does
  // not recolour the body.
  darkToggle: WebmailLocator | null;
  // Pixels the window is wider than the requested width, so that the
  // reading pane gives the body the requested width (folders, side
  // bars). [calibrate on the first live capture; the provenance records
  // the body width actually measured]
  windowAllowance: number;
  // The browser's colour scheme, fixed when it starts: "dark" for a
  // webmail that runs its dark theme for both of its states (the body
  // toggle decides the body).
  browserScheme: Scheme;
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
  url: string,
  tabs: WebmailLocator[] = [],
): FolderSpec => ({ label, url, tabs });

// Gmail (consumer or Workspace; the same web UI). A Gmail search leaves
// Spam and Trash out unless the query names them, so each folder is a
// search URL; rfc822msgid: finds exactly the delivered message. Its list
// is a grid of rows; the opened subject an h2; the body unnamed.
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
  row: u({ role: "row" }),
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
  },
  darkToggle: null,
  windowAllowance: 440,
  browserScheme: "light",
};

const YAHOO_DESKTOP: AdapterUi = {
  device: "desktop",
  folders: {
    inbox: folder("Inbox", "https://mail.yahoo.com/d/folders/1"),
    spam: folder("Spam", "https://mail.yahoo.com/d/folders/6"),
    trash: folder("Trash", "https://mail.yahoo.com/d/folders/4"),
  },
  // Each message of a folder is a link to it.
  row: u({ role: "link" }),
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
  },
  darkToggle: null,
  windowAllowance: 560,
  browserScheme: "light",
};

const OUTLOOK_FOLDERS = (base: string): Record<FolderName, FolderSpec> => ({
  inbox: folder("Inbox", `${base}/inbox`, [
    u({ role: "tab", name: "Focused" }),
    u({ role: "tab", name: "Other" }),
  ]),
  spam: folder("Junk Email", `${base}/junkemail`),
  trash: folder("Deleted Items", `${base}/deleteditems`),
});

// Outlook.com: a listbox of options, the opened subject a heading, the
// body named "Message body"; its dark theme for both states, the
// per-message background toggle deciding the body.
const OUTLOOK_DESKTOP: AdapterUi = {
  device: "desktop",
  folders: OUTLOOK_FOLDERS("https://outlook.live.com/mail/0"),
  row: u({ role: "list-item" }),
  opened: {
    subject: u({ nativeRole: "heading" }),
    body: u({ name: "Message body" }),
    masks: [],
  },
  remove: {
    del: u({ role: "button", name: "Delete" }),
    deleteForever: u({ role: "button", name: "Delete" }),
    confirm: u({ role: "button", name: "OK" }),
    permanentIn: [],
  },
  darkToggle: u({ role: "button", namePattern: "background" }),
  windowAllowance: 640,
  browserScheme: "dark",
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
        // Dark: the app theme dark, the body in its dark state; light:
        // the per-message background toggle on.
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
  const ui = a.desktop;
  const add = (name: string, l: WebmailLocator | null): void => {
    if (l !== null) out.push({ name: `desktop.${name}`, locator: l });
  };
  add("row", ui.row);
  add("opened.subject", ui.opened.subject);
  add("opened.body", ui.opened.body);
  ui.opened.masks.forEach((m, i) => add(`opened.mask${i}`, m));
  add("remove.delete", ui.remove.del);
  add("remove.deleteForever", ui.remove.deleteForever);
  add("remove.confirm", ui.remove.confirm);
  add("darkToggle", ui.darkToggle);
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
        inbox: { ...x.folders.inbox, url: move(x.folders.inbox.url) },
        spam: { ...x.folders.spam, url: move(x.folders.spam.url) },
        trash: { ...x.folders.trash, url: move(x.folders.trash.url) },
      },
    },
  };
}
