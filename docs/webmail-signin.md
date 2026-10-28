# Runbook: signing in the hosted-webmail QA accounts

The hosted-webmail captures (`just email-shots --backends b`) open each
QA account's webmail in a persistent browser profile. This runbook says
how those profiles get signed in, what each result means, and what a
person does when a provider asks for more than a password.

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
  automation. Before each start it turns the browser's own sign-in off
  in the profile (Chrome's "Allow Chrome sign-in" setting:
  `signin.allowed` and `signin.allowed_on_next_startup` false in
  `Default/Preferences`), so Chrome never offers "Make Chrome your own
  … Continue as …" over the provider's page; that is a user setting, not
  an automation switch, and a page cannot see it;
- it reads each screen by OCR, and types the address and the password
  through OS-level input, each only into the field meant for it (read
  from the browser's accessibility tree);
- it stops at any challenge (a captcha, a code, a phone, a passkey,
  "verify it's you", ...) and never retries;
- after the password, a provider may ask for more account data (Gmail's
  "Set a home address", a recovery phone or email, "protect your
  account", a passkey offer). The recipe only declines such a screen:
  one click on a button or link named exactly `Skip`, `Skip for now`,
  `Not now`, `Remind me later`, `Maybe later`, `No thanks` or `Cancel`.
  It never types into it and never clicks `Save`, `Next`, `Continue` or
  `Confirm`. A screen without such a control stops the attempt;
- it closes the browser, starts it again on the inbox URL (still without
  automation, typing nothing) and reads the mailbox off the screen; on
  success it writes `signin.json` in the profile. `--playwright-check`
  also opens the profile under Playwright (see the open risk below), and
  is off by default.

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
     of the mailbox (checked not to show the password; 0600).

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
  example the provider's sign-in or a challenge). Read the reason;
  `--check-only` repeats the check, which types nothing.
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
- **6, `REFUSED`**: within the cool-down (it says until when), or a
  capture run holds the account.
- **7, `STOPPED (secret-visible)`**: the password was legible on the
  screen (typed into the wrong place, or shown). The attempt stopped
  and no frame was kept. Look at what changed on the page with
  `--manual`; treat the password as exposed only if someone was
  watching the session.

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

## Open risk: Playwright on a signed-in profile

The sign-in and its check never show the provider an automated browser.
Two things still open a profile under Playwright, which starts the
browser with `--enable-automation` and makes `navigator.webdriver` true,
so the provider can tell that the session is being driven:

- `--playwright-check`, which is why it is off by default;
- the hosted-webmail captures themselves (`just email-shots --backends
b`), which drive the webmail through Playwright on the same profile.

A provider may answer that by ending the session or by challenging the
next sign-in. A capture that finds the profile signed out marks the
account `needs-login` and names the sign-in command; run it (after the
cool-down, if an attempt was made in the last 24 h). If that happens
often, record it with the provider and the date: it is the signal to
move the captures off Playwright too.

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
