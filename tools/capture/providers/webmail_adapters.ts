// tools/capture/providers/webmail_adapters.ts — what the hosted-webmail
// provider knows about each webmail's UI, as data.
//
// One adapter per webmail (Gmail, Yahoo Mail, Outlook.com): the folder
// URLs the arrival search opens (Inbox, then Spam/Junk; Trash for the
// removal; alternatives, tried in order, and the addresses the webmail
// rewrites them to), how a folder's list reads while it loads and when
// it is empty, the notices it lays over its page, and accessibility
// locators
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
// - The opened message is the delivered one when a heading's
//   accessible text (its name, or the text inside it) carries the token
//   (a11y_tree.ts `textCarriesToken`).
// - The body is the node `opened.body` names, or, when the webmail gives
//   the body no name (Gmail, Yahoo), the story's own article (the
//   library's role="article" wrapper, named after the story; Chrome
//   keeps it), else the story region: the message
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
  if (l.holds !== undefined) parts.push(`holds(${describeLocator(l.holds)})`);
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
  // Other addresses the address bar shows for this folder (Outlook.com
  // rewrites a typed /mail/0/inbox to /mail/0/): the address bar holds
  // the folder when it holds one of its URLs or one of these, an alias
  // with whatever query the webmail adds (a11y_tree.ts `atAddress`).
  aliases: string[];
  // The folder's names in the webmail's languages (LOCALE_NAMES): when
  // its URL leaves the address bar elsewhere, the folder is opened by
  // its control of one of these names (a fallback; the URL comes first;
  // a11y_tree.ts `folderControls`).
  names: string[];
}

/**
 * The names the adapters match, per language the QA accounts have been
 * seen in: English, and Bulgarian (Yahoo shows its mail in the account's
 * language whatever the browser asks; live, 2026-10-31: "Ново
 * съобщение", "Търсете в пощата си", "Входяща поща", "Кошче", "Спам").
 * Names are a fallback: folders are reached by their URLs and controls
 * found by role first. [unverified-live: Yahoo's Bulgarian delete and
 * confirmation names]
 */
export const LOCALE_NAMES = {
  inbox: ["Inbox", "Входяща поща"],
  spam: ["Spam", "Спам"],
  trash: ["Trash", "Кошче"],
  compose: ["Compose", "New mail", "Ново съобщение"],
  search: ["Search", "Търсете в пощата си"],
  delete: ["Delete", "Изтриване", "Изтрий"],
  confirm: ["OK", "Добре", "ОК"],
} as const;

/** A name pattern matching exactly one of `names` (any case). */
export function oneOf(names: readonly string[]): string {
  return `^(?:${names.map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})$`;
}

// How a folder's list reads while it loads and when it is empty
// (hosted_webmail.ts `settleList`): a look counts as "not there" only
// over a settled list.
export interface ListSpec {
  // Where the notices below are looked for (the page when null or not
  // shown).
  scope: WebmailLocator | null;
  // Shown while the list loads (a progress bar).
  loading: WebmailLocator[];
  // Shown in an empty folder. When the adapter declares any, a list
  // with neither a row nor one of these is still loading (a list drawn
  // as placeholders, which are not in the tree); with none declared, it
  // is quiet, settled by two equal readings alone.
  empty: WebmailLocator[];
}

// A notice the webmail lays over its page (Gmail's "Enable desktop
// notifications" toast), dismissed with its refusing control before a
// row or a body is captured.
export interface NoticeSpec {
  text: WebmailLocator;
  dismiss: WebmailLocator;
}

export interface AdapterUi {
  device: "desktop";
  folders: Record<FolderName, FolderSpec>;
  list: ListSpec;
  notices: NoticeSpec[];
  // One message in a folder or search list, as alternatives tried in
  // order; the arrival search keeps the row whose accessible text
  // carries the run token (a11y_tree.ts `tokenRows`).
  rows: WebmailLocator[];
  // Where rows are matched: the page, or only its message list, found
  // by structure (a11y_tree.ts `messageList`) for an adapter whose row
  // locators also match the page's other links (Yahoo's banner and
  // header links, live 2026-11-13). A page with no message list has
  // no rows.
  rowsIn: "page" | "message-list";
  opened: {
    // The opened message's subject (its accessible text must carry the
    // run token).
    subject: WebmailLocator;
    // The message body, when the webmail names it; null: the story region.
    body: WebmailLocator | null;
    // Inside the body's box: the webmail's own elements, masked.
    masks: WebmailLocator[];
  };
  remove: {
    // In the opened message: moves it to Trash / Deleted Items.
    del: WebmailLocator;
    // In the opened message in Trash: deletes it for good. Alternatives,
    // the first with exactly one showing match wins (unused when
    // `trashList` is set).
    deleteForever: WebmailLocator[];
    // The permanent delete made from the Trash list instead of the opened
    // message (Gmail: in an open Trash conversation its "Delete" is not
    // the permanent delete, live 2026-11-02): the row's check box
    // (`select`, inside the row), the toolbar's permanent delete
    // (`button`, shown once a row is selected), the row's own Trash
    // label (`rowLabel`, inside the row: the Trash guard's chip for a
    // row), and a confirmation a dialog may ask (`confirm`, clicked only
    // inside a dialog, when one shows).
    trashList: {
      select: WebmailLocator;
      button: WebmailLocator;
      rowLabel: WebmailLocator;
      confirm: WebmailLocator | null;
    } | null;
    // When Trash empties itself after this many days (Gmail: 30), a
    // message the permanent delete could not be shown to remove, left in
    // Trash and in no other folder, is recorded `in-trash` (`permanent:
    // false`, never "removed"); null: it is a failed cleanup.
    trashPurgeDays: number | null;
    // What must hold before a click on `deleteForever` (null: nothing
    // more than the opened message's identity): the address bar,
    // percent-decoded, matching `location` (a regular expression), and
    // `chip` shown. Gmail's "Delete" moves a message to Trash anywhere
    // else, so it is clicked only where the page is shown to be Trash.
    trashGuard: { location: string; chip: WebmailLocator | null } | null;
    // In the opened message in a folder of `permanentIn`: its one-step
    // permanent delete.
    permanentDelete: WebmailLocator;
    // A confirmation the permanent delete asks for, if any.
    confirm: WebmailLocator | null;
    // The folders whose opened message offers only the permanent delete
    // (`permanentDelete`, no Trash step). None so far: Gmail's open Spam
    // message offers "Delete", not "Delete forever" (live tree,
    // 2026-11-13).
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
  aliases: string[] = [],
  names: readonly string[] = [],
): FolderSpec => ({ label, urls, tabs, aliases, names: [...names] });

// A list with no notices declared: settled by two equal readings alone.
const QUIET_LIST: ListSpec = { scope: null, loading: [], empty: [] };

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
  list: QUIET_LIST,
  // Gmail's own toast (live capture, 2026-10-31: "Enable desktop
  // notifications for Gmail." with links "OK" and "No thanks"); the
  // profile blocks notifications, so it should not show at all.
  notices: [
    {
      text: u({ namePattern: "^Enable desktop notifications" }),
      dismiss: u({ role: "link", name: "No thanks" }),
    },
  ],
  // A grid row ("table row" in Chrome's tree); its accessible text holds
  // the subject whether Chrome names the row from its cells or not.
  rows: [u({ role: "row" })],
  rowsIn: "page",
  opened: {
    subject: u({ nativeRole: "heading" }),
    body: null,
    masks: [],
  },
  remove: {
    del: u({ role: "button", name: "Delete" }),
    // The open message in Trash (live cleanup frame, 2026-10-31): its
    // toolbar has "Delete" and no "Delete forever"; that "Delete" left
    // the message in Trash (live cleanup, 2026-11-02), so the permanent
    // delete is made from the Trash search list (`trashList`).
    deleteForever: [],
    // The live Trash search list (2026-11-02): each row a table row with
    // a check box named after the row, its subject cell and link named
    // "Trash [es:…] …" (the label first); "Delete forever" is the
    // toolbar's once a row is selected [unverified-live].
    trashList: {
      select: u({ role: "checkbox" }),
      button: u({ role: "button", name: "Delete forever" }),
      rowLabel: u({ namePattern: "^Trash\\b" }),
      confirm: u({ role: "button", name: "OK" }),
    },
    trashPurgeDays: 30,
    // The address bar on Trash; the chip for a row is `trashList.rowLabel`
    // (the open message's "Search for all messages with label Trash"
    // chip is not used: nothing is deleted from the open message).
    trashGuard: {
      location: "#search/in:trash(?:[+ ]|$)|#trash(?:/|$)",
      chip: null,
    },
    permanentDelete: u({ role: "button", name: "Delete forever" }),
    confirm: null,
    // The open message in Spam (live tree, 2026-11-13, run
    // a1-20261113T020457Z): its toolbar reads Back to Search Results,
    // Archive, Report spam, Delete, Mark as unread, Move to Inbox, More
    // email options; no "Delete forever". Its "Delete" is the delete to
    // Trash, then the Trash list's permanent delete; whether Spam's
    // "Delete" is itself permanent is not measured, so both are
    // accepted.
    permanentIn: [],
    mayBePermanentIn: ["spam"],
  },
  dark: null,
  windowAllowance: 440,
};

const YAHOO_DESKTOP: AdapterUi = {
  device: "desktop",
  folders: {
    // The new Yahoo Mail's Inbox is /n/folders/00_1 (live, 2026-10-31;
    // on 2026-11-13 a typed /d/folders/1 and /d/folders/6 both led to
    // /n/folders/00_1?.src=ym&reason=unexpected_ymv), the old
    // /d/folders/1 an alias. Its Spam is /n/folders/00_6 (live,
    // 2026-11-13: its folder button led to
    // /n/folders/00_6?.src=ym&reason=unexpected_ymv), the address itself
    // an alias (any query). Trash's /n/ id is not known (none is
    // guessed): its old URL is tried. Where a URL leads elsewhere the
    // folder is opened by its control (the look records the address it
    // led to).
    inbox: folder(
      "Inbox",
      ["https://mail.yahoo.com/n/folders/00_1"],
      [],
      [
        "https://mail.yahoo.com/n/folders/00_1",
        "https://mail.yahoo.com/d/folders/1",
      ],
      LOCALE_NAMES.inbox,
    ),
    spam: folder(
      "Spam",
      ["https://mail.yahoo.com/n/folders/00_6"],
      [],
      ["https://mail.yahoo.com/n/folders/00_6"],
      LOCALE_NAMES.spam,
    ),
    trash: folder(
      "Trash",
      ["https://mail.yahoo.com/d/folders/4"],
      [],
      [],
      LOCALE_NAMES.trash,
    ),
  },
  list: QUIET_LIST,
  notices: [],
  // Each message of a folder is a link to it (or an option of a list),
  // matched only in the message list (live, 2026-11-13: the page's
  // banner and header links are links too). The new UI's row first: a
  // link spanning the row that holds the row's check box, both named
  // after the message, the link's name led by "Непрочетено съобщение"
  // while it is unread (live trees, 2026-11-13 and 2026-11-22); the old
  // UI's list items hold the check box beside the link.
  rows: [
    u({ role: "link", holds: { role: "checkbox" } }),
    u({ role: "link" }),
    u({ role: "list-item" }),
  ],
  rowsIn: "message-list",
  opened: {
    subject: u({ nativeRole: "heading" }),
    body: null,
    masks: [],
  },
  // Its controls in any of its languages (LOCALE_NAMES).
  remove: {
    del: u({ role: "button", namePattern: oneOf(LOCALE_NAMES.delete) }),
    deleteForever: [
      u({ role: "button", namePattern: oneOf(LOCALE_NAMES.delete) }),
    ],
    trashList: null,
    trashPurgeDays: null,
    trashGuard: null,
    permanentDelete: u({
      role: "button",
      namePattern: oneOf(LOCALE_NAMES.delete),
    }),
    confirm: u({ role: "button", namePattern: oneOf(LOCALE_NAMES.confirm) }),
    permanentIn: [],
    mayBePermanentIn: ["spam"],
  },
  dark: null,
  // Live, 2026-11-22 (run a1-20261122T015845Z): at 560 the body
  // measured 626 px in the 1360 px window. The opened message takes the
  // message list's column (no pane beside the list) between the 260 px
  // folder navigation and a 336 px side section; that column grew
  // 190 px for 195 px of window (691 px at 1355, 881 px at 1550). 750
  // is 560 plus the 190 px the widening added: a 1550 px window, the
  // body about 816 px [measure: the next live capture's width_check].
  windowAllowance: 750,
};

// Outlook.com shows its Inbox at the bare /mail/0/ (live, 2026-10-31:
// a typed /mail/0/inbox read back as outlook.live.com/mail/0/).
const OUTLOOK_FOLDERS = (base: string): Record<FolderName, FolderSpec> => ({
  inbox: folder(
    "Inbox",
    [`${base}/inbox`],
    [u({ role: "tab", name: "Focused" }), u({ role: "tab", name: "Other" })],
    [`${base}/`],
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
  // The live failure frame (2026-10-31): a list still loading is drawn
  // as placeholder rows, which are not in the tree; the landmark
  // "Message list" is, with nothing in it. An empty folder says so.
  list: {
    scope: u({ nativeRole: "landmark", name: "Message list" }),
    loading: [
      u({ nativeRole: "progress bar" }),
      u({ namePattern: "^loading\\b" }),
    ],
    empty: [
      u({
        namePattern:
          "^(nothing in |this folder is empty|looks empty|all caught up|no items|no messages)",
      }),
    ],
  },
  notices: [],
  rows: [v({ role: "list-item" })],
  rowsIn: "page",
  opened: {
    subject: v({ nativeRole: "heading" }),
    body: u({ name: "Message body" }),
    masks: [],
  },
  remove: {
    del: u({ role: "button", name: "Delete" }),
    deleteForever: [u({ role: "button", name: "Delete" })],
    trashList: null,
    trashPurgeDays: null,
    trashGuard: null,
    permanentDelete: u({ role: "button", name: "Delete" }),
    confirm: u({ role: "button", name: "OK" }),
    permanentIn: [],
    mayBePermanentIn: ["spam"],
  },
  dark: { toggle: u({ role: "button", namePattern: "background" }) },
  // Live, 2026-11-02 (run a1-20261102T013834Z): at 640 the body
  // ("Message body") measured 513 px in the 1440 px window, the reading
  // pane between the folder pane and the list on its left and a column
  // on its right; 960 asks for the 287 px it lacked and a margin
  // [measure: whether the pane grows one pixel per pixel of window].
  windowAllowance: 960,
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
  ui.remove.deleteForever.forEach((l, i) => add(`remove.deleteForever${i}`, l));
  add("remove.trashGuard.chip", ui.remove.trashGuard?.chip ?? null);
  const tl = ui.remove.trashList;
  if (tl !== null) {
    add("remove.trashList.select", tl.select);
    add("remove.trashList.button", tl.button);
    add("remove.trashList.rowLabel", tl.rowLabel);
    add("remove.trashList.confirm", tl.confirm);
  }
  add("remove.permanentDelete", ui.remove.permanentDelete);
  add("remove.confirm", ui.remove.confirm);
  add("list.scope", ui.list.scope);
  ui.list.loading.forEach((l, i) => add(`list.loading${i}`, l));
  ui.list.empty.forEach((l, i) => add(`list.empty${i}`, l));
  ui.notices.forEach((n, i) => {
    add(`notices${i}.text`, n.text);
    add(`notices${i}.dismiss`, n.dismiss);
  });
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
  const moveFolder = (f: FolderSpec): FolderSpec => ({
    ...f,
    urls: f.urls.map(move),
    aliases: f.aliases.map(move),
    names: f.names,
  });
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
        inbox: moveFolder(x.folders.inbox),
        spam: moveFolder(x.folders.spam),
        trash: moveFolder(x.folders.trash),
      },
    },
  };
}
