# Runbook: signing in the hosted-webmail QA accounts

The hosted-webmail captures (`just email-shots --backends b`) open each
QA account's webmail in a persistent browser profile. This runbook says
how those profiles get signed in, what each result means, what a
person does when a provider asks for more than a password, and how the
captures then run on a signed-in profile
([Capturing on a signed-in profile](#capturing-on-a-signed-in-profile)).

`just email-webmail-signin` signs a profile in by itself, with the
account file's address and password:

- it starts a private off-screen display session (GuiAssert, on Xvfb),
  so it needs no display of yours;
- it starts the dev shell's webmail browser in that session as an
  ordinary browser (no Playwright, no DevTools port, no automation
  switch), on the account's profile, with Chromium's sandbox (checked).
  The webmail browser is Google Chrome, the regular release build from
  nixpkgs (nixpkgs' Chromium on Linux machines other than x86_64), not
  Playwright's Chrome for Testing, which shows an "only for automated
  testing" bar. Its extra switches are `--force-renderer-accessibility`
  (the page's accessibility tree, as a screen reader turns it on),
  `--force-device-scale-factor=1`, `--lang=en-US` and a fixed window;
  none of them shows a bar or a warning, or is visible to a page as
  automation. Before each start it writes the profile's preferences
  into `Default/Preferences` (every other setting kept): Chrome's
  password manager off (Settings, "Offer to save passwords", with
  auto sign-in and the leak check), so Chrome never offers to save the
  QA password and never keeps it; the web sign-in interception off, so
  Chrome never offers "Make Chrome your own … Continue as …" over the
  provider's page, while Chrome's own sign-in stays allowed (its
  default: turning it off also stops Chrome's account consistency with
  Google, which changes what Google sees of an already signed-in
  session); the pages' languages, `en-US, en`; and page translation
  off (Settings, "Use Google Translate"), so Chrome never offers its
  Translate bubble, whose "Always translate" check box would otherwise
  stop the consent answer below on a page in the host region's
  language. These are user settings, not automation switches, and a
  page cannot see them. If
  the "Continue as …" bubble shows anyway, the recipe closes it once
  through its button `Use Chrome without an account` (an input to the
  browser, not to the provider);
- it reads each screen by OCR, and types the address and the password
  through OS-level input, each only into the field meant for it (read
  from the browser's accessibility tree);
- it acts on nothing it saw only once: a screen is answered (or the
  attempt stopped on it) only when two reads in a row, about a second
  apart, saw the same screen with the same browser address. A page that
  is changing, or a frame read while the browser was already moving to
  the next page, is read again with no input. This costs a second or
  two per screen;
- it stops at any challenge (a captcha, a code, a phone, a passkey,
  "verify it's you", ...) and never retries. One exception: Google's
  password re-verification of an existing session ("Verify it's you"
  with only the account and a password field, nothing else) is answered
  once during an automated attempt, with the password, which is still
  typed at most once per attempt;
- Google's "sign in again" page is not a challenge either: a session
  Google no longer accepts is sent to
  `accounts.google.com/…/signin/confirmidentifier`, headed "Verify it's
  you", with the account, "Please sign in again to continue to Gmail" and
  one "Next" button, nothing to fill. The recipe recognises it by that
  address (read from the browser's address bar) and that wording. During
  an automated attempt it clicks "Next" once, only when the page has
  exactly one button named exactly `Next` and no field (this click starts
  the attempt), and then signs in on the password screen that follows,
  the password typed at most once. Google may change the page in place:
  the browser's address moves to the password page
  (`…/signin/challenge/pwd`) while "Please sign in again" still shows
  for a few seconds. For 20 s after "Next", that wording under another
  address is read as the page moving on, with no input; still there
  after 20 s, it stops the attempt as `verify-identity`. Any challenge
  on the page (a code, a phone, a device, a passkey, "2-Step
  Verification", ...) still stops the attempt. A check (`--check-only`,
  or the check after a sign-in) clicks nothing and reports it as
  "signed out: Google asks to sign in again";
- a provider may show a privacy-consent page (Yahoo's
  `consent.yahoo.com/…/collectConsent`, Google's `consent.google.com`),
  sometimes in the language of the host's region whatever the browser
  asks for. The recipe recognises it by its address (read from the
  browser's address bar; the port does not matter) and gives the most
  privacy-preserving answer by exact control names, in English or
  Bulgarian: a "Reject all" control when there is one; otherwise the
  "Reject" choice of every row, then a save control ("Save choices",
  "Запазване на избора", ...) or "Continue". A row's choices may be
  named by the choice alone ("Отхвърляне" / "Разрешаване") or by the
  row's purpose and the choice, joined by a comma (or another
  separator) or by a space ("За предоставяне на интелигентни функции,
  Отхвърляне" and "За да Ви показваме персонализирани реклами и
  съдържание Отхвърляне", both seen on Yahoo's second consent page);
  each purpose must then have exactly one reject and one allow choice,
  whichever way each is joined. When only a space joins them, the words
  before the choice must read as a purpose: a name such as "Ads, do not
  reject", "Click to reject" or "Без отхвърляне" (a negation, a modal,
  "to", "or", "if", a preposition before the word) or one that already names
  a choice ("Allow or Reject") is no choice, and stops the attempt.
  Rows off the screen in a dialog that scrolls are reached with the
  mouse wheel, up or down, whichever way they lie; a choice already on
  "Reject" is left as it is. A "Reject all" or save control is clicked
  once per page: if the page is still there 20 s later, the attempt
  stops. At most three consent pages are answered per attempt. It
  never clicks an accept or allow control. A page it cannot answer that
  way (another language, a choice named otherwise, a check box or
  switch, a "Reject" that does not stay selected, no save or continue
  control) stops the attempt `consent-required` with no further input.
  It looks for check boxes in the whole browser window, Chrome's own
  bubbles included: a `consent-required` naming a check box the page
  does not have (such as "Always translate") means a bubble of
  Chrome's was open over the page; check that the profile's
  preferences above were written (the run writes them before each
  start), and run again after the cool-down;
- after the password, a provider may ask for more account data (Gmail's
  "Set a home address", a recovery phone or email, "protect your
  account", a passkey offer). The recipe only declines such a screen:
  one click on a button or link named exactly `Skip`, `Skip for now`,
  `Not now`, `Remind me later`, `Maybe later`, `No thanks` or `Cancel`.
  It never types into it and never clicks `Save`, `Next`, `Continue` or
  `Confirm`. A screen without such a control stops the attempt;
- it closes the browser, starts it again on the inbox URL (still without
  automation, typing nothing) and reads the mailbox off the screen; on
  success it writes `signin.json` in the profile. Nothing opens a
  webmail profile under Playwright, the DevTools protocol or WebDriver;
  see [Capturing on a signed-in profile](#capturing-on-a-signed-in-profile).

The password is read from the account file and handed only to GuiAssert
over a pipe: never on a command line, in an environment variable, on the
terminal, in a log or record, or in a kept screenshot. Every screen it
reads and every screenshot it keeps passes GuiAssert's guard, which
refuses a frame in which the password is legible.

## The safety rails

A provider that sees repeated password sign-ins from a new browser
answers with challenges and then locks the account. A locked QA account
needs a person and days. So:

- **One automated attempt per account, then a 24 h cool-down.** The
  attempt record, `signin-attempt.json` in the account's profile
  directory, is written before the first keystroke. A second automated
  attempt within 24 h of the last one's start is refused before any
  browser starts (exit 6), whatever the last result was. A run that was
  killed mid-attempt still counts.
- **Only input counts.** An attempt starts when the first keystroke or
  click is about to reach the provider's page. A run that ended before
  that (a screen it did not recognise, a challenge already on the first
  screen, a browser that would not start) showed the provider nothing,
  records nothing and starts no cool-down; it says "no input reached the
  provider: no attempt recorded". Declining an account-setup screen is
  an input, and counts like any other.
- **No retries.** A challenge, a wrong password or a screen the recipe
  does not recognise ends the attempt.
- **The password is typed at most once per attempt**, and only into a
  focused field the browser reports as a password field.

## Prerequisites

1. Linux, inside the dev shell: `cd isonim-email && nix develop`. The
   shell provides `guiassert` (pinned in `flake.nix`, with Xvfb, x11vnc
   and tesseract) and the webmail browser
   (`$ISONIM_EMAIL_WEBMAIL_BROWSER`; `$ISONIM_EMAIL_WEBMAIL_BROWSER_LABEL`
   says which build). Google Chrome is unfree: the flake allows that one
   package and nothing else, so no nixpkgs configuration is needed.
2. Unprivileged user namespaces (Chromium's sandbox needs them). Without
   them the recipe stops with exit 4; `--unsafe-no-sandbox` runs without
   the sandbox, and should not be used for the real web.
3. The credentials directory with the QA account files
   (`$ISONIM_EMAIL_CREDENTIALS_DIR`, mode 0700, each file 0600:
   `<set>/<account>.json` with `address` and `password`). A team's
   credential materialiser fills it; otherwise run
   `just email-credentials-template` and fill it in. Check it with
   `just email-credentials-check`. Never print or copy these files.
4. Profiles live under `$ISONIM_EMAIL_WEBMAIL_PROFILES_DIR` (default
   `${XDG_STATE_HOME:-$HOME/.local/state}/isonim-email/webmail-profiles`),
   one directory per account, `<set>/<account>/`, every level 0700:
   - `chromium/`: the browser profile;
   - `signin.json`: the last verified sign-in (no secret);
   - `signin-attempt.json`: the last automated attempt (no secret);
   - `signin-screen.png`: the screen kept when an attempt stopped short
     of the mailbox (checked not to show the password; 0600);
   - `check-screen.png`: the screen a check saw when it found the
     profile not signed in (same guard; 0600).

## Running it

One account:

```sh
just email-webmail-signin gmail-workspace qa1
just email-webmail-signin yahoo qa1
just email-webmail-signin outlook-com qa1
```

Every account of a set: `just email-webmail-signin yahoo`.

A first attempt for an account is best run watched and ready to take
over, so a challenge can be finished at once instead of after the
cool-down:

```sh
just email-webmail-signin gmail-workspace qa1 --takeover
```

A successful run prints, per account, the screens it recognised and the
step it took on each, then the check (one long line is wrapped here):

```text
gmail-workspace/qa1: signing in to Gmail (https://accounts.google.com/…)
gmail-workspace/qa1: screen: address
gmail-workspace/qa1:   typed the address (… characters) and Return
gmail-workspace/qa1: screen: password
gmail-workspace/qa1:   typed the password into the protected field, and Return
gmail-workspace/qa1: screen: the mailbox
gmail-workspace/qa1: checking the profile: Google Chrome … started again on
  https://mail.google.com/mail/u/0/#inbox, the mailbox read off the screen…
gmail-workspace/qa1: check: the mailbox shows
SIGNED IN: gmail-workspace/qa1 on mail.google.com; recorded in …/signin.json
```

To watch it, add `--vnc`; to be able to finish a challenge yourself, add
`--takeover` (which implies `--vnc`). The recipe prints where the
session's VNC socket is. The socket is a Unix socket in the session's
private directory: only your user can connect. From another machine,
forward it over SSH and point a VNC viewer at the forwarded port:

```sh
ssh -L 5901:/tmp/gaxv-…/vnc.sock you@capture-host   # the line it prints
vncviewer localhost:5901
```

Afterwards, `just email-webmail-checklist` shows each account's state.

## What the results mean

- **0, `SIGNED IN`**: the inbox loaded signed in; `signin.json` is
  written. If it says the profile was still signed in, nothing was
  typed and no attempt was counted.
- **1, `FAILED (wrong-password)`**: the provider refused the password.
  The account file does not hold the account's password. Do not run the
  sign-in again until it is fixed: see
  [Re-sealing a QA password](#re-sealing-a-qa-password), and confirm
  with `--typing-check`.
- **1, `FAILED (unknown-account)`**: the provider does not know the
  address. Check the account file.
- **1, `FAILED (unknown-screen)`, `FAILED (stuck:<step>)`,
  `FAILED (field-not-found:<step>)`**: a screen the recipe does not
  recognise (a new page, changed wording), a step whose screen stayed,
  or a field that was missing or would not take the focus. Look at
  `signin-screen.png`, finish the sign-in with `--manual`, and report
  the screen so the provider's table
  (`tools/capture/providers/webmail_signin_steps.ts`) can learn it.
  `field-not-found:interstitial:<name>` is an account-setup screen with
  no control that declines it, and `stuck:interstitial:<name>` one that
  stayed after it was declined: finish it with `--manual` (or run with
  `--takeover`). The profile is usually signed in by then;
  `--check-only` tells.
- **1, `NOT SIGNED IN`**: the sign-in ended but the check did not find
  the mailbox on the inbox URL (it names the screen it saw instead, for
  example the provider's sign-in, a challenge, a consent page,
  Google's password re-verification or Google's "sign in again" page,
  none of which the check answers) and keeps it as `check-screen.png`.
  Read the reason; `--check-only` repeats the check, which types nothing.
  "signed out: Google asks to sign in again" is not a challenge: an
  automated attempt (after the cool-down) signs the profile in again.
- **3, `PENDING`**: no account file, or one without a password.
- **4, `CANNOT RUN`**: no usable browser sandbox, no `guiassert`, no
  webmail browser (outside the dev shell), or the display session would
  not start.
- **5, `CHALLENGED (<kind>)`**: the provider asked for more than a
  password. The kinds: `captcha`, `phone-verification`,
  `code-verification`, `app-approval`, `passkey`, `insecure-browser`,
  `verify-identity`, `unusual-activity`, `account-recovery`,
  `protect-account`, `passwordless-default`, `account-locked`,
  `sign-in-refused`. See below.
- **5, `CONSENT REQUIRED (<name>)`**: a privacy-consent page the recipe
  could not answer by rejecting every optional use (it names why).
  Answer it once yourself, rejecting everything optional: `--takeover`
  on the next attempt, or `--manual` now. Report the page (a language
  or a control name the table does not list) with `signin-screen.png`.
- **6, `REFUSED`**: within the cool-down (it says until when), or a
  capture run holds the account.
- **7, `STOPPED (secret-visible)`**: the password was legible on the
  screen (typed into the wrong place, or shown). The attempt stopped
  and no frame was kept. Look at what changed on the page with
  `--manual`; treat the password as exposed only if someone was
  watching the session.
- **8, `SECRET AT REST`**: after the run, the browser profile holds a
  saved password, a password hash the recipe could not remove, or a file
  it could not count, or a browser still runs on the profile after the
  run (it may write a hash back as it exits), whatever the sign-in's
  result. See
  [No saved password at rest](#no-saved-password-at-rest).

## Checking the typing: `--typing-check`

Before a sign-in, and always after a credential was changed, check that
the account's password reaches a page exactly as the account file holds
it, without contacting any provider:

```sh
just email-webmail-signin outlook-com qa1 --typing-check
```

It starts the same private session and the same webmail browser (on a
throw-away profile, removed afterwards) at a page on `127.0.0.1` with one
password field, and types the password into it as the sign-in does. The
page compares a salted SHA-256 of what it received with one the recipe
computed from the account file; the password itself never reaches the
page. The result is one line:

```text
TYPING CHECK MATCH: outlook-com/qa1 (length match: yes)
```

or `TYPING CHECK MISMATCH: … (length match: yes|no)` with exit 1: what
reached the page differs from the file (a keyboard-layout or input
problem on this machine, not a provider problem). A mismatch with
`length match: no` means characters were lost or added. It is not an
attempt: no record, no cool-down, and the account's profile is not
opened, so it can run at any time. `--vnc` shows it.

## When a provider challenges

A challenge is never answered automatically. Either:

- run the next attempt with `--takeover` (after the cool-down, or now
  with `--override-cooldown`, see below): on a challenge the browser
  stays open, you finish it over VNC, press Enter in the terminal, and
  the recipe checks and records the profile; or
- sign in by hand over VNC now, without an automated attempt:
  `just email-webmail-signin <set> <account> --manual`. The recipe
  types nothing; when the password field has the focus you can type
  `p` and Enter in the terminal to have it typed for you (once). Press
  Enter alone when the inbox shows; the profile is then checked and
  recorded.

A `--manual` sign-in is not an automated attempt and does not start a
cool-down.

## Resetting

- **The cool-down.** Wait it out (the refusal says until when). To make
  an attempt anyway, pass `--override-cooldown`; the attempt is
  recorded as overridden. Only do it when you know why the last attempt
  failed and that it will not repeat (for example, the credential was
  wrong and is now fixed): each challenged attempt raises the chance
  that the provider locks the account. Deleting `signin-attempt.json`
  has the same effect and leaves no trace; prefer the flag.
- **A profile.** Stop any capture run, then delete the account's
  `chromium/` directory and `signin.json`. The next sign-in starts from
  an empty profile (expect the provider to ask for more: a new browser
  is the case providers challenge most). Keep `signin-attempt.json`, so
  the cool-down still holds.

## No saved password at rest

The QA password lives in the credential store and nowhere else. A
browser that saved it would keep a second copy in the profile, readable
by anyone who can read the profile directory (`Login Data` is a SQLite
file, and on a capture host its key is a fixed one). The profile's
preferences keep the password manager off.

Chrome also keeps a salted hash of a Google account's password, with
its length, for its password-reuse warning. It is not the password, but
it is enough to test guesses offline. Chrome writes it when a password is
submitted on Google's sign-in page and the sign-in succeeds, **whatever
the password manager's settings**: no profile preference prevents it
(only an incognito window does, which keeps no session). So the recipe
removes it. Before every browser start, and after every run once the
account's browsers have stopped, it deletes these keys and keeps
everything else in their files (each file rewritten atomically, 0600):

- `profile.password_hash_data_list` in `chromium/Default/Preferences`
  (a Google account's password);
- `local.password_hash_data_list` in `chromium/Local State` (Chrome keeps
  an enterprise password's there).

Then it checks that nothing is left. It counts, without reading any value:

- the saved logins in `chromium/Default/Login Data` and
  `chromium/Default/Login Data For Account` ("never save" entries do
  not count);
- the entries left in the two password-hash lists above.

Any of them, or a file it cannot read, ends the run with exit 8, so a
hash in the count means the removal failed (it says why):

```text
SECRET AT REST: yahoo/qa1: the browser profile holds 1 saved login(s) in Login Data, 0 in Login Data For Account and 0 password hash(es) (…/chromium). …
```

To clear it:

1. Stop every run on the account (sign-in, check, capture): no browser
   may run on the profile.
2. Remove the saved password. Either open the profile in a `--manual`
   session (`just email-webmail-signin <set> <account> --manual`), go to
   `chrome://password-manager/passwords` over VNC, and delete the entry;
   or, with no browser running, delete the two files
   `chromium/Default/Login Data` and `chromium/Default/Login Data For
Account` (and their `-journal` files). Deleting them removes saved
   passwords only, not the provider's session.
3. Remove a password hash with no browser:
   `just email-webmail-signin <set> <account> --scrub-profile`. It starts
   no browser and no session and needs no account file; it refuses
   (exit 6) while a run holds the account or a browser runs on the
   profile (a running browser writes its preferences back when it
   exits). It removes the two keys above, then counts as a run does:
   `SCRUBBED: <set>/<account>: nothing at rest …` and exit 0, or
   `SECRET AT REST` and exit 8 (a saved login is not removed by it: see
   step 2). A profile signed in before the recipe removed hashes by
   itself still holds one: scrub it once.
4. Check: `just email-webmail-signin <set> <account> --check-only`
   counts again and must not print `SECRET AT REST`.
5. If the profile was copied anywhere (a backup, another machine, an
   archive) while the password or its hash was in it, treat the password
   as exposed: [rotate it](#rotating-a-password).
6. Find out how a saved login got there: only this recipe writes the
   preferences before a start, so the usual cause is the profile opened
   by another browser or tool, which starts it without them and lets
   Chrome offer "Save password?". A hash comes from every Google sign-in
   in the profile, the recipe's included, and is removed at the end of
   every run.

## Capturing on a signed-in profile

`just email-shots --backends b` drives the same webmail browser on the
same profiles the way the sign-in does, never under Playwright:

- the browser is started by the launcher the sign-in uses
  (`tools/capture/providers/webmail_browser.ts`): the profile's
  preferences written and its password hashes removed first, the
  sandbox on and checked, and no automation switch. The launcher
  refuses a command line carrying one (`--remote-debugging-*`,
  `--enable-automation`, `--headless`, `--test-type`, an extension,
  `--user-agent`, …) before it starts anything, so the page always sees
  `navigator.webdriver` false;
- each account's browser runs in a private GuiAssert session of its
  own, as wide as the adapter's window and 2400 px high; no display of
  yours is needed;
- it moves by typing URLs into the browser's address bar and clicking
  at the centre of elements the accessibility tree names (a message's
  row, its delete button, Outlook.com's background toggle); it reads the
  mailbox off the screen (OCR) and the page from the accessibility tree;
  it crops the message body as a region of the display. Nothing is
  evaluated in a page and nothing in one is changed;
- the browser runs in the requested scheme, by the profile's colour
  mode (Chrome's Settings, Appearance, Mode, written into the profile
  before the start; no command-line switch): light captures in a light
  browser, dark ones in a dark browser (Outlook.com's only: its light
  capture comes first, then the browser is restarted dark and the
  message opened again). Outlook.com follows the browser into its own
  dark theme only when its Appearance setting follows the system (set
  it once while signing in: Settings, General, Appearance); each capture
  checks the theme and fails rather than capture the other scheme. In
  dark, the reading pane's background toggle is switched off when it is
  on, and left alone when Outlook.com does not show one; a light capture
  never touches it. Every sign-in runs light, so a dark capture never
  leaves a profile dark;
- a capture never reads an account's password and never types into a
  sign-in page. A profile found signed out is marked `needs-login`: sign
  it in again with this recipe (after the cool-down, if an attempt was
  made in the last 24 h).

No browser on a webmail profile is ever started under Playwright, the
DevTools protocol or WebDriver: the sign-in and the captures share one
launcher, which refuses an automation switch before it starts anything.

### Before the first capture

1. Every step of `just email-webmail-checklist` up to the sign-in is
   `ok` (credentials unlocked, the Workspace sender, the account signed
   in), and a smoke send has reached the account.
2. Check that the profile still reads as signed in, typing nothing:
   `just email-webmail-signin <set> <account> --check-only`.
3. No other run holds the account: a sign-in, another capture, or a
   check takes the account's lease (`lease.json` in its profile
   directory) and a capture waits for it up to 10 minutes.

### The first capture, per webmail

Run one story, one client at a time, watched, with no cache.
`receiptTypical` is a reference email, which the story driver registers
only under `ISONIM_CAPTURE_LAYOUT=1` (without it the run stops at
`unknown story 'receiptTypical' (registered: canary, receipt, alert)`):

```sh
ISONIM_CAPTURE_LAYOUT=1 ISONIM_EMAIL_WEBMAIL_VNC=1 just email-shots receiptTypical --backends b --clients outlook-web --viewports desktop --schemes light --no-cache
ISONIM_CAPTURE_LAYOUT=1 ISONIM_EMAIL_WEBMAIL_VNC=1 just email-shots receiptTypical --backends b --clients outlook-web --viewports desktop --schemes dark --no-cache
ISONIM_CAPTURE_LAYOUT=1 ISONIM_EMAIL_WEBMAIL_VNC=1 just email-shots receiptTypical --backends b --clients gmail-web --viewports desktop --no-cache
ISONIM_CAPTURE_LAYOUT=1 ISONIM_EMAIL_WEBMAIL_VNC=1 just email-shots receiptTypical --backends b --clients gmail-list,outlook-list --viewports desktop --no-cache
```

and Yahoo's (`yahoo-web`, `yahoo-list`) once its profile is signed in.
Run them one after another, not at once: each run takes the account's
lease. After each, read its provenance (below) and the cleanup record
before the next; a failure leaves its screen behind for you (below).
With `ISONIM_EMAIL_WEBMAIL_VNC=1` every capture session serves an
owner-only VNC socket and the run prints where, as the sign-in's
`--vnc` does: forward it with `ssh -L 5901:<socket> you@capture-host`
and point a viewer at `localhost:5901`. Watch only: the run needs no
input, and a click of yours changes what it reads.

Each capture sends one real message to the account and counts it
against the account's daily budget; the run deletes it afterwards
(from Trash too) and records that in `<run>/hosted-webmail-cleanup.jsonl`.

### Reading a capture's provenance

Every PNG has a JSON file beside it. For a first capture, check:

- `crop.locator`: `story region` (Gmail, Yahoo: the message column
  between the webmail's elements above and below the story's own text)
  or the body's own name (Outlook.com, `name="Message body"`);
  `crop.foreign_inside` should be 0 (text inside the crop that is not
  the story's: a banner the webmail put in the body);
- `width_check`: the body's measured width against the requested 800.
  A delta other than 0 means the adapter's `windowAllowance` in
  `webmail_adapters.ts` needs calibrating;
- `settle.settled`: false means the body's pixels never held still
  within the bound (an animation, or images still loading);
- `scheme_applied` (Outlook.com): the toggle's state and the crop's mean
  luminance, light against dark;
- `tree`: how many accessibility nodes the page had and how long one
  read took; `timing_ms`: each step;
- `client.locators`: `unverified-live` until the adapter's locators are
  confirmed against the live webmail;
- `arrival.looks`: each URL the search typed (Gmail's: the Message-ID
  search, then the run token's), whether the address bar then held it
  (`location_matched`), the rows it saw, which row locator found the
  message (`row_locator`), and `token_nodes`, every element showing the
  run token; `arrival.row_locator` is the one that found it;
- `scheme_applied` (Outlook.com): `browser` (the colour mode),
  `theme_luminance` (the subject heading's: below 128 is dark),
  `toggle` (`untouched` in light; `unchecked`, `switched` or `absent` in
  dark), and the crop's `luminance`.

### What a failure leaves behind

When a capture fails with its browser running, the run keeps the
screen and what the browser told a screen reader, in
`<run>/hosted-webmail-failures/` (only you can read it):

- `<webmail>-<account>-<step>-<n>.png`: the whole capture display at
  the moment of failure;
- `<webmail>-<account>-<step>-<n>.tree.json`: the address bar, and every
  element shown (role, accessible name, text, value, position, whether
  it is checked or selected), the account's address replaced by
  `<account address>`.

The failed request's provenance names both (`failure.frame`,
`failure.tree`, and the `step`: `arrival`, `list-row`, `restart-dark`,
`open`, `body-light`, `body-dark`, or a `cleanup-…` step), and a
delivery failure's provenance carries the last two rounds of looks
(`search`); a failed cleanup's line in `hosted-webmail-cleanup.jsonl`
carries the same. The screen may show the QA mailbox; keep these files
out of tickets and chats, and delete the run directory when you are
done with it.

### When a capture fails

- `session lost: …`: the profile is signed out; run the sign-in it
  names.
- `UI drift: <webmail> adapter locator '<name>' (…)`: the webmail no
  longer shows what the adapter's locator names; the adapter is down for
  the rest of the run. Open the failure's frame and tree (above): find
  the element the locator meant in the tree (its role and name), then
  fix the locator in `tools/capture/providers/webmail_adapters.ts`.
- `the page is light … in a dark browser` (or dark in a light one):
  Outlook.com's Appearance does not follow the system. Set it to follow
  the system in a sign-in session (`just email-webmail-signin outlook-com
<account> --manual --vnc`), then capture again.
- `the message body is … px tall …, past the window's visible part`:
  bodies taller than the window are not captured yet (never cut).
- `delivery failure: … was not found …`: the message did not show in
  Inbox or Spam/Junk within 60 s, or the search did not recognise it.
  Read the provenance's `search`: `location_matched: false` means the
  webmail rewrote the URL the search typed (compare `url` and
  `location`); `rows` empty means no row locator matched the list (the
  frame and tree show what the list is made of); `token_nodes` naming an
  element means the message was on the screen but not in anything the
  row locators recognise. Its cleanup record is `not-found`; the message
  may still be in the mailbox.
- `cleanup FAILED for <Message-ID>`: the message may still be in the
  mailbox; the line names the kept screen, and the cleanup record's
  `search` the looks that saw it. A removal's `via` says how it went:
  `trash` (deleted, then deleted again from Trash / Deleted Items),
  `delete-forever` (Gmail's Spam), or `permanent` (deleted from
  Outlook.com's Junk Email or Yahoo's Spam, and never seen in Trash:
  the delete there was for good). Sign nothing in: open the account's profile only through the
  recipes (a check with `--check-only`, or a sign-in with `--manual` over
  VNC to delete it by hand), never by starting a browser on it yourself.
- `the capture browser cannot run: …`: no GuiAssert session or no
  sandbox, as for the sign-in (Prerequisites).
- `delivery failed: token: cannot reach oauth2.googleapis.com: … (after
one retry)`: the Workspace sender's token request got no answer twice,
  2 s apart (a network problem on this machine; nothing was sent). Run
  the capture again; an HTTP refusal (`token: HTTP 401 …`) is not
  retried, and names what to fix.

## Re-sealing a QA password

When a provider answers `FAILED (wrong-password)`, the account file does
not hold the account's password. Fix the file at its source; never edit
a materialised copy in place.

1. **Find the right password.** If the account's owner knows it, use
   that. If nobody does, reset it in the provider's "forgot password"
   flow (in a `--manual` session or any browser), with a newly generated
   password, never one chosen by hand; this needs the account's recovery
   channel. Do not try passwords against the provider: each refusal
   brings a lock closer.
2. **Replace it at the source.** For a file you keep yourself, edit
   `<set>/<account>.json` (`password`; mode 0600). For a team's sealed
   credential set, use that team's sealing tool: the sealed file of the
   account is removed and sealed again with the new password, typed at a
   prompt that does not echo (or generated by the tool), the change goes
   through review, and every machine re-materialises or re-unlocks the
   set afterwards. Your team's credentials runbook has the exact
   commands.
3. **Check the file:** `just email-credentials-check`.
4. **Check the typing:**
   `just email-webmail-signin <set> <account> --typing-check` must say
   `MATCH`.
5. **Sign in again**, after the cool-down, or at once with
   `--override-cooldown` (now the cause is known and fixed), watched:
   `just email-webmail-signin <set> <account> --override-cooldown --takeover`.

## Rotating a password

1. Change the password in the provider's own account settings (in a
   `--manual` session, or on any browser), to a generated one.
2. Replace it at the source as in
   [Re-sealing a QA password](#re-sealing-a-qa-password) (steps 2 to 4).
3. The signed-in profile usually stays signed in; check with
   `just email-webmail-signin <set> <account> --check-only`. If the
   provider signed it out, run the sign-in again after the cool-down.
