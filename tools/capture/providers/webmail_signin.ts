// tools/capture/providers/webmail_signin.ts — the automated sign-in of
// one hosted-webmail QA account, driven through GuiAssert in a private
// off-screen session (email-webmail-signin.ts starts the session and the
// browser, and owns the guard and the check).
//
// The procedure reads the display with OCR, classifies it
// (webmail_signin_steps.ts) and takes the one step that screen calls
// for, until the mailbox shows, a challenge or an error stops it, or a
// bound runs out:
// - every OCR read and every kept screenshot goes through GuiAssert's
//   `--secret-stdin` guard with the password, so a frame in which the
//   password is legible is never answered or kept (the attempt then
//   stops: `secret-visible`);
// - the address is typed only into a focused, editable, unprotected
//   text field whose accessible name is the provider's address field,
//   and the password only into a focused field with the `protected`
//   state, on a recognised password screen; the focus is read from the
//   accessibility tree of the browser process, after a click on the
//   field when it did not have it already;
// - input is GuiAssert's OS-level input (`type --stdin`, `key`, `click`):
//   the address and the password reach it on stdin only;
// - each step is taken at most once (the password is typed at most once
//   per attempt), a step whose screen is still shown `stuckMs` after it
//   ends the attempt as `stuck`, a screen that matches nothing for
//   `unknownMs` as `unknown-screen`, and the whole attempt has
//   `deadlineMs`;
// - an account-setup interstitial after the sign-in (a home address, a
//   recovery phone, a passkey offer, ...) is only ever dismissed: one
//   click on a button or link named exactly as one of SKIP_CONTROLS
//   ("Skip", "Not now", ...), never a keystroke and never another
//   control; each interstitial at most once (`stuck` and
//   `field-not-found` as for a step, named `interstitial:<name>`);
// - a privacy-consent page (recognised by its address, read from the
//   browser's address bar in the accessibility tree, whatever language
//   the page is in) is answered the most privacy-preserving way, by exact
//   control names (CONSENT_CONTROLS): a reject-all control, or every
//   row's reject choice and then a continue control; never an accepting
//   control, and never past a check box or switch; anything it cannot
//   identify ends the attempt
//   `consent-required` for a person to answer once;
// - Google's password re-verification of an existing session is the
//   step `reauth-password`, typed like the password screen, and the
//   password is still typed at most once per attempt;
// - Google's "sign in again" page (the step `sign-in-again`: its address
//   and wording, webmail_signin_steps.ts) is answered with one click on
//   its only button, "Next", and only when the page has exactly one
//   button of that exact name and no field to fill; that click is an
//   input (it starts the attempt), and the password screen that follows
//   is the ordinary one (the password still typed at most once);
// - Chrome's own sign-in bubble, should it show despite the profile's
//   preferences, is closed once through its "Use Chrome without an
//   account" button (a click on the browser, not on the provider's page);
// - a challenge stops it at once with no further input, and nothing in
//   here retries: the caller reports the result and the cool-down
//   (webmail_signin_guard.ts) keeps a second attempt from following.
// `verifySignedIn` is the check afterwards, in the same way: OCR of the
// mailbox in a browser started again on the profile, with no input.

import { chmodSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import {
  type GaElement,
  type GuiAssert,
  GuiAssertError,
  type Rect,
  type Secret,
} from "./guiassert.ts";
import {
  type ChallengeKind,
  classifyScreen,
  CONSENT_CONTROLS,
  consentHinted,
  normalize,
  type ProviderSignin,
  type Screen,
  type SigninErrorKind,
  signInAgainHinted,
  SKIP_CONTROLS,
  type StepId,
} from "./webmail_signin_steps.ts";

/**
 * What the procedure acted on: a step, an interstitial it dismissed, or a
 * consent page it answered.
 */
export type ActionId = StepId | `interstitial:${string}` | `consent:${string}`;

/** The private session's one display. */
export const SIGNIN_SCREEN = { width: 1280, height: 900 } as const;

/**
 * The sign-in browser's switches beyond the profile's
 * (webmail_profiles.ts `signinBrowserArgs`). None of them is an
 * automation switch: no DevTools port, no --enable-automation, nothing
 * that sets navigator.webdriver, and none puts a bar or a warning in the
 * browser's window (checked on a screenshot of Google Chrome 147 in the
 * session, 2026-10-28).
 * - --force-renderer-accessibility: Chromium's accessibility tree on the
 *   session's AT-SPI bus, as it is built for a screen reader; the
 *   procedure reads the focused field from it. Needed: without it the
 *   browser exposed no page element at all in the session (probe,
 *   2026-10-28: `guiassert find --role text-field` found the page's two
 *   fields with it and none without). Not visible to a page: the web
 *   platform has no API that reports whether an assistive technology is
 *   attached, and screen-reader users run browsers in exactly this mode.
 * - --force-device-scale-factor=1: Google Chrome (a GTK-integrated
 *   build) otherwise picks a scale of about 1.047 on the session's Xvfb
 *   display and reports its accessibility extents in its own scaled
 *   pixels, which GuiAssert cannot place on the display (every field's
 *   bounds null, so a field that needs a click cannot be clicked; probe,
 *   2026-10-28; recorded as a GuiAssert issue). A page sees only
 *   `devicePixelRatio` 1, the common desktop value.
 * - --lang=en-US: the browser's own interface in English (its bubbles,
 *   and the address bar's accessible name, ADDRESS_BAR_NAME); the pages'
 *   language comes from the profile's preferences and the start URLs.
 * - the window placed on the whole display, so OCR reads all of it.
 */
export const SIGNIN_SESSION_SWITCHES: readonly string[] = [
  "--force-renderer-accessibility",
  "--force-device-scale-factor=1",
  "--lang=en-US",
  "--window-position=0,0",
  `--window-size=${SIGNIN_SCREEN.width},${SIGNIN_SCREEN.height}`,
];

/** Switches the sign-in browser must never carry. */
export const AUTOMATION_SWITCHES: readonly RegExp[] = [
  /^--remote-debugging/,
  /^--enable-automation/,
  /^--headless/,
  /^--test-type/,
  /^--remote-allow-origins/,
  /^--disable-blink-features=AutomationControlled/,
];

export interface SigninTimings {
  pollMs: number;
  unknownMs: number;
  stuckMs: number;
  deadlineMs: number;
  /** After a click into a field, before its focus is read back. */
  focusSettleMs: number;
}

export const DEFAULT_TIMINGS: SigninTimings = {
  pollMs: 1000,
  unknownMs: 30_000,
  stuckMs: 20_000,
  deadlineMs: 180_000,
  focusSettleMs: 400,
};

export type SigninOutcome =
  | { result: "signed-in"; typed: boolean }
  | { result: "challenged"; challenge: ChallengeKind; phrase: string }
  | { result: SigninErrorKind; phrase: string }
  | { result: "unknown-screen" }
  | { result: "consent-required"; consent: string; why: string }
  | { result: "stuck"; step: ActionId }
  | { result: "field-not-found"; step: ActionId }
  | { result: "secret-visible" }
  | { result: "deadline" };

/** The outcome as one word for records and the exit line. */
export function outcomeName(o: SigninOutcome): string {
  switch (o.result) {
    case "challenged":
      return `challenged:${o.challenge}`;
    case "consent-required":
      return `consent-required:${o.consent}`;
    case "stuck":
    case "field-not-found":
      return `${o.result}:${o.step}`;
    default:
      return o.result;
  }
}

export interface SigninContext {
  /** A client acting in the sign-in's session. */
  ga: GuiAssert;
  provider: ProviderSignin;
  /** The browser's process: the accessibility tree is read from it only. */
  browserPid: number;
  address: string;
  password: Secret;
  /** Where OCR frames are written (each removed once read). */
  framesDir: string;
  /** The screenshot kept when the attempt stops short of the mailbox. */
  keepPath: string;
  timings: SigninTimings;
  /** Before the first input reaches the provider (the guard's record). */
  onFirstInput: () => void;
  /** Before the password is typed. */
  onBeforePassword: () => void;
  log: (line: string) => void;
}

export interface SigninResult {
  outcome: SigninOutcome;
  /** The kept screenshot, when one was taken and the guard kept it. */
  screen: string | null;
  steps: ActionId[];
  elapsedMs: number;
}

const centre = (b: Rect): [number, number] => [
  b[0] + b[2] / 2,
  b[1] + b[3] / 2,
];

const usable = (e: GaElement): e is GaElement & { bounds: Rect } =>
  e.bounds !== null &&
  e.bounds[2] > 0 &&
  e.bounds[3] > 0 &&
  e.states.includes("visible") &&
  !e.states.includes("offscreen");

/** The address field: focused-able, editable, NOT protected, named as the provider names it. */
export function isAddressField(p: ProviderSignin, e: GaElement): boolean {
  return (
    e.role === "text-field" &&
    e.states.includes("editable") &&
    !e.states.includes("protected") &&
    e.name !== null &&
    p.addressField.test(e.name)
  );
}

/** The password field: an editable text field with the `protected` state. */
export function isPasswordField(e: GaElement): boolean {
  return (
    e.role === "text-field" &&
    e.states.includes("editable") &&
    e.states.includes("protected")
  );
}

async function focusedElement(ctx: FieldFocuser): Promise<GaElement | null> {
  const f = await ctx.ga.find({
    pid: ctx.browserPid,
    states: ["focused"],
    limit: 5,
  });
  return f.find((e) => e.role === "text-field") ?? null;
}

/** What finding and focusing a field needs. */
export type FieldFocuser = Pick<SigninContext, "ga" | "browserPid"> & {
  timings: Pick<SigninTimings, "focusSettleMs">;
};

/**
 * Leaves the focus in a field `want` accepts, clicking the first visible
 * such field when the focus is elsewhere; true only when the focused
 * element, read back, is one.
 */
export async function focusField(
  ctx: FieldFocuser,
  want: (e: GaElement) => boolean,
): Promise<boolean> {
  const now = await focusedElement(ctx);
  if (now !== null && want(now)) return true;
  const candidates = (
    await ctx.ga.find({ pid: ctx.browserPid, role: "text-field" })
  ).filter((e) => want(e) && usable(e));
  const target = candidates[0];
  if (target === undefined) return false;
  const [x, y] = centre(target.bounds!);
  await ctx.ga.click(x, y);
  await sleep(ctx.timings.focusSettleMs);
  const after = await focusedElement(ctx);
  return after !== null && want(after);
}

async function clickControl(
  ctx: SigninContext,
  name: string,
  role: string | undefined,
  before: () => void,
): Promise<boolean> {
  const found = (
    await ctx.ga.find({
      pid: ctx.browserPid,
      ...(role === undefined
        ? { nameContains: name, ignoreCase: true }
        : { role, name }),
    })
  ).filter(usable);
  const target = found[0];
  if (target === undefined) return false;
  const [x, y] = centre(target.bounds!);
  before();
  await ctx.ga.click(x, y);
  return true;
}

/**
 * Clicks the first visible button or link named exactly as one of
 * SKIP_CONTROLS, in their order; the name clicked, or null when there is
 * none (then nothing was clicked).
 */
async function clickSkipControl(
  ctx: SigninContext,
  before: () => void,
): Promise<string | null> {
  for (const name of SKIP_CONTROLS)
    for (const role of ["button", "link"]) {
      const target = (
        await ctx.ga.find({ pid: ctx.browserPid, role, name })
      ).filter(usable)[0];
      if (target === undefined) continue;
      const [x, y] = centre(target.bounds!);
      before();
      await ctx.ga.click(x, y);
      return name;
    }
  return null;
}

/** Types the password into the focused protected field (the --manual path). */
export async function typePasswordIntoField(
  ctx: SigninContext,
): Promise<boolean> {
  if (!(await focusField(ctx, isPasswordField))) return false;
  await ctx.ga.type(ctx.password);
  return true;
}

/** What reading the display needs. */
type ScreenReader = Pick<SigninContext, "ga" | "password" | "framesDir">;

/** Reads the display; null when the password is legible in it. */
async function readScreen(
  ctx: ScreenReader,
  n: number,
): Promise<string | null> {
  const frame = join(ctx.framesDir, `frame-${n}.png`);
  try {
    return (await ctx.ga.ocr(frame, ctx.password)).text;
  } catch (err) {
    if (err instanceof GuiAssertError && err.reason === "secret-visible")
      return null;
    throw err;
  } finally {
    // The frame passed the guard, but no frame is kept but the one below.
    rmSync(frame, { force: true });
  }
}

/** A guarded screenshot kept at `keepPath` (0600); null when refused. */
async function keepScreen(
  ctx: Pick<SigninContext, "ga" | "password" | "keepPath" | "log">,
): Promise<string | null> {
  rmSync(ctx.keepPath, { force: true });
  try {
    await ctx.ga.screenshot(ctx.keepPath, ctx.password);
    // GuiAssert writes it with its own umask: owner-only, like every
    // other file in the profile directory.
    if (existsSync(ctx.keepPath)) chmodSync(ctx.keepPath, 0o600);
    return ctx.keepPath;
  } catch (err) {
    if (err instanceof GuiAssertError) {
      ctx.log(
        err.reason === "secret-visible"
          ? "no screenshot kept: the password was legible in it"
          : `no screenshot kept: ${err.message}`,
      );
      return null;
    }
    throw err;
  }
}

/** The accessible name of Chrome's address bar (its interface in English). */
export const ADDRESS_BAR_NAME = "Address and search bar";

/**
 * The page's address as the browser's address bar holds it, read from
 * the accessibility tree of the browser's process; null when there is no
 * such field or it gives no value.
 */
export async function readLocation(
  ga: GuiAssert,
  browserPid: number,
): Promise<string | null> {
  const bars = await ga.find({
    pid: browserPid,
    role: "text-field",
    name: ADDRESS_BAR_NAME,
  });
  for (const b of bars) {
    const v = b.value ?? b.text ?? null;
    if (v !== null && v.trim() !== "") return v.trim();
  }
  return null;
}

/**
 * Reads the address only when the OCR text names a consent host or
 * carries the wording of the "sign in again" page.
 */
async function locationFor(
  p: ProviderSignin,
  ga: GuiAssert,
  browserPid: number | undefined,
  text: string,
): Promise<string | null | undefined> {
  if (
    browserPid === undefined ||
    !(consentHinted(p, text) || signInAgainHinted(p, text))
  )
    return undefined;
  return readLocation(ga, browserPid);
}

/**
 * Chrome's own sign-in bubble ("Make Chrome your own … Continue as …"):
 * the phrase that shows it on the screen, and the button that closes it
 * without signing the browser in.
 */
export const BROWSER_SIGNIN_BUBBLE = {
  phrase: "Use Chrome without an account",
  control: "Use Chrome without an account",
} as const;

const onScreen = (e: GaElement): e is GaElement & { bounds: Rect } =>
  usable(e) &&
  e.bounds![0] >= 0 &&
  e.bounds![1] >= 0 &&
  e.bounds![0] + e.bounds![2] <= SIGNIN_SCREEN.width &&
  e.bounds![1] + e.bounds![3] <= SIGNIN_SCREEN.height;

const sameName = (a: string | null, b: string): boolean =>
  a !== null && normalize(a) === normalize(b);

/** At most this many clicks and scrolls on consent pages per attempt. */
export const CONSENT_MAX_ACTIONS = 20;
/** At most this many clicks on a continue control. */
export const CONSENT_MAX_PROCEED = 3;
/** The wheel, in lines, to bring the next rows on screen. */
export const CONSENT_SCROLL_LINES = 3;

/**
 * Which choice a consent row's radio button is, by its accessible name:
 * a listed reject or allow name, exactly or followed by more words that
 * do not name the other choice; null otherwise.
 */
export function consentChoice(name: string | null): "reject" | "allow" | null {
  if (name === null) return null;
  const n = normalize(name);
  const reject = CONSENT_CONTROLS.reject.map(normalize);
  const allow = CONSENT_CONTROLS.allow.map(normalize);
  const startsWith = (ws: string[]) => ws.some((w) => n.startsWith(w));
  const mentions = (ws: string[]) => ws.some((w) => n.includes(w));
  if (startsWith(reject) && !mentions(allow)) return "reject";
  if (startsWith(allow) && !mentions(reject)) return "allow";
  return null;
}

export interface ConsentState {
  actions: number;
  proceeds: number;
}

export type ConsentStep =
  | { kind: "acted"; what: string }
  | { kind: "unidentified"; why: string };

/** The first on-screen element of `roles` named exactly as one of `names`. */
async function findNamed(
  ctx: Pick<SigninContext, "ga" | "browserPid">,
  roles: string[],
  names: readonly string[],
): Promise<{ el: GaElement & { bounds: Rect }; name: string } | null> {
  for (const role of roles) {
    const els = (await ctx.ga.find({ pid: ctx.browserPid, role })).filter(
      onScreen,
    );
    for (const name of names) {
      const el = els.find((e) => sameName(e.name, name));
      if (el !== undefined) return { el, name };
    }
  }
  return null;
}

async function clickAt(ga: GuiAssert, b: Rect): Promise<void> {
  const [x, y] = centre(b);
  await ga.click(x, y);
}

/**
 * One round on a consent page (the procedure's header says what it
 * does); `before` runs before its first input. Every control is matched
 * by exact name; a name of CONSENT_CONTROLS.never is never clicked.
 */
export async function consentRound(
  ctx: Pick<SigninContext, "ga" | "browserPid">,
  st: ConsentState,
  before: () => void,
): Promise<ConsentStep> {
  const never = CONSENT_CONTROLS.never.map(normalize);
  const click = async (el: GaElement & { bounds: Rect }): Promise<void> => {
    if (el.name !== null && never.includes(normalize(el.name)))
      throw new Error(`refusing to click "${el.name}" on a consent page`);
    before();
    await clickAt(ctx.ga, el.bounds);
    st.actions++;
  };
  const scroll = async (why: string): Promise<ConsentStep> => {
    before();
    await ctx.ga.scroll(
      SIGNIN_SCREEN.width / 2,
      SIGNIN_SCREEN.height / 2,
      CONSENT_SCROLL_LINES,
    );
    st.actions++;
    return { kind: "acted", what: `scrolled down ${why}` };
  };
  if (st.actions >= CONSENT_MAX_ACTIONS)
    return {
      kind: "unidentified",
      why: `still on the page after ${CONSENT_MAX_ACTIONS} clicks and scrolls`,
    };
  const all = await findNamed(
    ctx,
    ["button", "link"],
    CONSENT_CONTROLS.rejectAll,
  );
  if (all !== null) {
    await click(all.el);
    return { kind: "acted", what: `clicked "${all.name}"` };
  }
  // A check box or a switch (an optional use the page may have on by
  // default) is never answered: only reject choices are clicked, so
  // going on past one would accept its default.
  const boxes = await ctx.ga.find({ pid: ctx.browserPid, role: "checkbox" });
  if (boxes.length > 0)
    return {
      kind: "unidentified",
      why: `a check box or switch named ${JSON.stringify(boxes[0]!.name ?? "")}, which it does not answer`,
    };
  const radios = await ctx.ga.find({ pid: ctx.browserPid, role: "radio" });
  if (radios.length === 0)
    return {
      kind: "unidentified",
      why: "no reject-all control and no reject choices",
    };
  const odd = radios.find((r) => consentChoice(r.name) === null);
  if (odd !== undefined)
    return {
      kind: "unidentified",
      why: `a choice named ${JSON.stringify(odd.name ?? "")}, neither a reject nor an allow choice of a listed language`,
    };
  const rejects = radios.filter((r) => consentChoice(r.name) === "reject");
  const allows = radios.filter((r) => consentChoice(r.name) === "allow");
  if (rejects.length !== allows.length)
    return {
      kind: "unidentified",
      why: `${rejects.length} reject and ${allows.length} allow choices, not one of each per row`,
    };
  const todo = rejects.filter((r) => !r.states.includes("checked"));
  const reachable = todo.filter(onScreen);
  if (reachable.length > 0) {
    for (const r of reachable) await click(r);
    return {
      kind: "acted",
      what: `chose "${reachable[0]!.name}" on ${reachable.length} row(s)`,
    };
  }
  if (todo.length > 0) return scroll("to the next reject choices");
  if (allows.some((a) => a.states.includes("checked")))
    return {
      kind: "unidentified",
      why: "an allow choice stays selected with every reject choice checked",
    };
  const go = await findNamed(ctx, ["button"], CONSENT_CONTROLS.proceed);
  if (go !== null) {
    if (st.proceeds >= CONSENT_MAX_PROCEED)
      return {
        kind: "unidentified",
        why: `still on the page after "${go.name}" ${CONSENT_MAX_PROCEED} times`,
      };
    await click(go.el);
    st.proceeds++;
    return {
      kind: "acted",
      what: `every row rejected (${rejects.length}); clicked "${go.name}"`,
    };
  }
  return scroll("to a continue control");
}

export async function driveSignin(ctx: SigninContext): Promise<SigninResult> {
  const t0 = Date.now();
  const deadline = t0 + ctx.timings.deadlineMs;
  const acted = new Map<ActionId, number>();
  const steps: ActionId[] = [];
  let typedAnything = false;
  let passwordTyped = false;
  let bubbleClosed = false;
  const consent: ConsentState = { actions: 0, proceeds: 0 };
  let unknownSince: number | null = null;
  let reads = 0;

  const firstInput = (): void => {
    if (!typedAnything) {
      typedAnything = true;
      ctx.onFirstInput();
    }
  };
  const end = async (
    outcome: SigninOutcome,
    keep: boolean,
  ): Promise<SigninResult> => ({
    outcome,
    screen: keep ? await keepScreen(ctx) : null,
    steps,
    elapsedMs: Date.now() - t0,
  });

  for (;;) {
    if (Date.now() >= deadline) return end({ result: "deadline" }, true);
    const text = await readScreen(ctx, reads++);
    if (text === null) return end({ result: "secret-visible" }, false);
    // Chrome's own sign-in bubble over the page: closed once, through
    // its button, then the screen is read again.
    if (
      !bubbleClosed &&
      normalize(text).includes(normalize(BROWSER_SIGNIN_BUBBLE.phrase))
    ) {
      bubbleClosed = true;
      const b = (
        await ctx.ga.find({
          pid: ctx.browserPid,
          role: "button",
          name: BROWSER_SIGNIN_BUBBLE.control,
        })
      ).filter(onScreen)[0];
      if (b !== undefined) {
        await clickAt(ctx.ga, b.bounds);
        ctx.log(
          `browser: closed Chrome's sign-in bubble with "${BROWSER_SIGNIN_BUBBLE.control}"`,
        );
        await sleep(ctx.timings.pollMs);
        continue;
      }
    }
    const screen = classifyScreen(
      ctx.provider,
      text,
      await locationFor(ctx.provider, ctx.ga, ctx.browserPid, text),
    );
    const now = Date.now();
    if (screen.kind !== "unknown") unknownSince = null;

    switch (screen.kind) {
      case "done":
        ctx.log("screen: the mailbox");
        return end({ result: "signed-in", typed: typedAnything }, false);
      case "challenge":
        ctx.log(
          `screen: a challenge (${screen.challenge}: "${screen.phrase}")`,
        );
        return end(
          {
            result: "challenged",
            challenge: screen.challenge,
            phrase: screen.phrase,
          },
          true,
        );
      case "error":
        ctx.log(`screen: ${screen.error} ("${screen.phrase}")`);
        return end({ result: screen.error, phrase: screen.phrase }, true);
      case "unknown":
        unknownSince ??= now;
        if (now - unknownSince >= ctx.timings.unknownMs)
          return end({ result: "unknown-screen" }, true);
        break;
      case "consent": {
        const id: ActionId = `consent:${screen.consent}`;
        if (!acted.has(id)) {
          ctx.log(`screen: a privacy-consent page (${screen.consent})`);
          acted.set(id, now);
          steps.push(id);
        }
        const r = await consentRound(ctx, consent, firstInput);
        if (r.kind === "unidentified") {
          ctx.log(`  cannot answer it: ${r.why}`);
          return end(
            {
              result: "consent-required",
              consent: screen.consent,
              why: r.why,
            },
            true,
          );
        }
        ctx.log(`  ${r.what}`);
        break;
      }
      case "interstitial": {
        const id: ActionId = `interstitial:${screen.interstitial}`;
        const at = acted.get(id);
        if (at !== undefined) {
          if (now - at >= ctx.timings.stuckMs)
            return end({ result: "stuck", step: id }, true);
          break;
        }
        ctx.log(
          `screen: an account-setup screen (${screen.interstitial}: "${screen.phrase}")`,
        );
        const clicked = await clickSkipControl(ctx, firstInput);
        if (clicked === null)
          return end({ result: "field-not-found", step: id }, true);
        ctx.log(`  dismissed it with "${clicked}"`);
        acted.set(id, Date.now());
        steps.push(id);
        break;
      }
      case "step": {
        const step = screen.step;
        const at = acted.get(step);
        if (at !== undefined) {
          // Its step was taken; the page may still be moving on.
          if (now - at >= ctx.timings.stuckMs)
            return end({ result: "stuck", step }, true);
          break;
        }
        const typesPassword = step === "password" || step === "reauth-password";
        // The password is typed at most once per attempt: Google asking
        // for it again after it was typed (its password again, or to sign
        // in again) is a challenge.
        if ((typesPassword || step === "sign-in-again") && passwordTyped)
          return end(
            {
              result: "challenged",
              challenge: "verify-identity",
              phrase: "verify it's you",
            },
            true,
          );
        ctx.log(`screen: ${step}`);
        const ok = await takeStep(ctx, step, firstInput);
        if (!ok) return end({ result: "field-not-found", step }, true);
        if (typesPassword) passwordTyped = true;
        acted.set(step, Date.now());
        steps.push(step);
        break;
      }
    }
    await sleep(ctx.timings.pollMs);
  }
}

async function takeStep(
  ctx: SigninContext,
  step: StepId,
  firstInput: () => void,
): Promise<boolean> {
  const p = ctx.provider;
  switch (step) {
    case "address":
      if (!(await focusField(ctx, (e) => isAddressField(p, e)))) return false;
      firstInput();
      await ctx.ga.type(ctx.address);
      await ctx.ga.key("Return");
      ctx.log(
        `  typed the address (${ctx.address.length} characters) and Return`,
      );
      return true;
    case "password":
    case "reauth-password":
      if (!(await focusField(ctx, isPasswordField))) return false;
      firstInput();
      ctx.onBeforePassword();
      await ctx.ga.type(ctx.password);
      await ctx.ga.key("Return");
      ctx.log(
        step === "password"
          ? "  typed the password into the protected field, and Return"
          : "  Google asks the session to confirm its password: typed it into the protected field, and Return",
      );
      return true;
    case "sign-in-again": {
      const rule = p.signInAgain;
      if (rule === undefined) return false;
      // Nothing to fill on it: no field of the page (the browser's own
      // address bar aside), and exactly one button of the exact name.
      const fields = (
        await ctx.ga.find({ pid: ctx.browserPid, role: "text-field" })
      ).filter((e) => usable(e) && !sameName(e.name, ADDRESS_BAR_NAME));
      if (fields.length > 0) return false;
      const go = (
        await ctx.ga.find({
          pid: ctx.browserPid,
          role: "button",
          name: rule.control,
        })
      ).filter(onScreen);
      if (go.length !== 1) return false;
      firstInput();
      await clickAt(ctx.ga, go[0]!.bounds);
      ctx.log(`  Google asks to sign in again: clicked "${rule.control}"`);
      return true;
    }
    case "choose-password":
      if (p.choosePasswordControl === undefined) return false;
      if (
        !(await clickControl(
          ctx,
          p.choosePasswordControl,
          undefined,
          firstInput,
        ))
      )
        return false;
      ctx.log(`  chose "${p.choosePasswordControl}"`);
      return true;
    case "stay-signed-in":
      if (p.staySignedInControl === undefined) return false;
      if (
        !(await clickControl(ctx, p.staySignedInControl, "button", firstInput))
      )
        return false;
      ctx.log(`  answered "${p.staySignedInControl}"`);
      return true;
  }
}

export interface VerifyContext extends ScreenReader {
  provider: ProviderSignin;
  /** The browser's process, to read its address bar (a consent page). */
  browserPid?: number;
  /**
   * Where the screen is kept (guarded, 0600) when the check finds no
   * mailbox; removed when it does. None kept when unset.
   */
  keepPath?: string;
  /** How long the mailbox may take to show. */
  timeoutMs: number;
  /** How long a sign-in, challenge or error screen must stay to count. */
  settleMs: number;
  pollMs: number;
  log: (line: string) => void;
}

export type VerifyOutcome =
  | { signedIn: true }
  | {
      signedIn: false;
      reason: string;
      /** The screen it saw, classified ("unrecognised" when nothing matched). */
      seen?: string;
      /** The kept screenshot, when `keepPath` was given and the guard kept it. */
      screen?: string | null;
    };

/** How the check names a screen that is not the mailbox; null for none it names. */
function checkScreenName(screen: Screen): string | null {
  switch (screen.kind) {
    case "step":
      return screen.step === "reauth-password"
        ? `Google's password re-verification of the session ("verify it's you" with only a password field)`
        : screen.step === "sign-in-again"
          ? `Google's sign-in-again page ("please sign in again", the account and only "Next")`
          : `the ${screen.step} screen of the sign-in`;
    case "challenge":
      return `a challenge (${screen.challenge}: "${screen.phrase}")`;
    case "error":
      return `an error (${screen.error}: "${screen.phrase}")`;
    case "interstitial":
      return `an account-setup screen (${screen.interstitial}: "${screen.phrase}")`;
    case "consent":
      return `a privacy-consent page (${screen.consent})`;
    default:
      return null;
  }
}

function notSignedInBecause(what: string): string {
  if (what.startsWith("an account-setup screen"))
    return `the inbox URL showed ${what}, not the mailbox: the provider asks for it before the mailbox, and the check dismisses nothing (the sign-in does, through its skip control)`;
  if (what.startsWith("a privacy-consent page"))
    return `the inbox URL showed ${what}, not the mailbox: the provider asks for the privacy choices first, and the check answers nothing (the sign-in does, rejecting every optional use)`;
  if (what.startsWith("Google's sign-in-again page"))
    return `signed out: Google asks to sign in again (the inbox URL showed ${what}); the check never clicks, an automated attempt answers it ("Next", then the password, typed once)`;
  if (what.startsWith("Google's password re-verification"))
    return `the inbox URL showed ${what}, not the mailbox: the session must confirm its password; an automated attempt answers it once, the check never types`;
  return `the inbox URL showed ${what}, not the mailbox: the profile is not signed in`;
}

/**
 * Whether the browser on the session's display shows the provider's
 * mailbox, read by OCR only (every frame through the password guard):
 * the check after a sign-in, in a webmail browser started again on the
 * inbox URL, without automation, so the check is invisible to the
 * provider (Playwright's would show it `navigator.webdriver` and
 * `--enable-automation`). It never types, clicks or presses a key.
 * - the mailbox screen: signed in;
 * - a sign-in step (Google's password re-verification among them), a
 *   challenge, an error, an account-setup screen or a privacy-consent
 *   page (never answered here) that stays for `settleMs`: not signed in,
 *   naming the screen;
 * - neither within `timeoutMs`: not signed in, naming the last screen
 *   it recognised, or "unrecognised";
 * - a frame showing the password: not signed in (it never should here).
 * Not signed in (but for the password), the screen is kept at `keepPath`
 * through the guard; signed in, an older one there is removed.
 */
export async function verifySignedIn(
  ctx: VerifyContext,
): Promise<VerifyOutcome> {
  const deadline = Date.now() + ctx.timeoutMs;
  type Seen = { what: string; since: number };
  let seen = null as Seen | null;
  // Not signed in: the screen kept first (while the browser still shows it).
  const notSignedIn = async (
    reason: string,
    what: string,
    keep: boolean,
  ): Promise<VerifyOutcome> => ({
    signedIn: false,
    reason,
    seen: what,
    screen:
      keep && ctx.keepPath !== undefined
        ? await keepScreen({ ...ctx, keepPath: ctx.keepPath })
        : null,
  });
  for (let n = 0; ; n++) {
    const text = await readScreen(ctx, n);
    if (text === null)
      return notSignedIn(
        "the password was legible on the screen",
        "the password, legible",
        false,
      );
    const screen = classifyScreen(
      ctx.provider,
      text,
      await locationFor(ctx.provider, ctx.ga, ctx.browserPid, text),
    );
    const now = Date.now();
    if (screen.kind === "done") {
      ctx.log("check: the mailbox shows");
      if (ctx.keepPath !== undefined) rmSync(ctx.keepPath, { force: true });
      return { signedIn: true };
    }
    const what = checkScreenName(screen);
    // The same non-mailbox screen since when (a new one restarts it).
    const cur: Seen | null =
      what === null ? null : seen?.what === what ? seen : { what, since: now };
    seen = cur;
    if (cur !== null && now - cur.since >= ctx.settleMs)
      return notSignedIn(notSignedInBecause(cur.what), cur.what, true);
    if (now >= deadline)
      return notSignedIn(
        `the mailbox did not show within ${Math.round(ctx.timeoutMs / 1000)} s (the screen: ${cur === null ? "unrecognised" : cur.what})`,
        cur === null ? "unrecognised" : cur.what,
        true,
      );
    await sleep(ctx.pollMs);
  }
}
