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
  type ProviderSignin,
  type SigninErrorKind,
  SKIP_CONTROLS,
  type StepId,
} from "./webmail_signin_steps.ts";

/** What the procedure acted on: a step, or an interstitial it dismissed. */
export type ActionId = StepId | `interstitial:${string}`;

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
 * - --lang=en-US: the screens are recognised by their English wording.
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
  | { result: "stuck"; step: ActionId }
  | { result: "field-not-found"; step: ActionId }
  | { result: "secret-visible" }
  | { result: "deadline" };

/** The outcome as one word for records and the exit line. */
export function outcomeName(o: SigninOutcome): string {
  switch (o.result) {
    case "challenged":
      return `challenged:${o.challenge}`;
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

async function keepScreen(ctx: SigninContext): Promise<string | null> {
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

export async function driveSignin(ctx: SigninContext): Promise<SigninResult> {
  const t0 = Date.now();
  const deadline = t0 + ctx.timings.deadlineMs;
  const acted = new Map<ActionId, number>();
  const steps: ActionId[] = [];
  let typedAnything = false;
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
    const screen = classifyScreen(ctx.provider, text);
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
        ctx.log(`screen: ${step}`);
        const ok = await takeStep(ctx, step, firstInput);
        if (!ok) return end({ result: "field-not-found", step }, true);
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
      if (!(await focusField(ctx, isPasswordField))) return false;
      firstInput();
      ctx.onBeforePassword();
      await ctx.ga.type(ctx.password);
      await ctx.ga.key("Return");
      ctx.log("  typed the password into the protected field, and Return");
      return true;
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
  /** How long the mailbox may take to show. */
  timeoutMs: number;
  /** How long a sign-in, challenge or error screen must stay to count. */
  settleMs: number;
  pollMs: number;
  log: (line: string) => void;
}

export type VerifyOutcome =
  | { signedIn: true }
  | { signedIn: false; reason: string };

/**
 * Whether the browser on the session's display shows the provider's
 * mailbox, read by OCR only (every frame through the password guard):
 * the check after a sign-in, in a webmail browser started again on the
 * inbox URL, without automation, so the check is invisible to the
 * provider (Playwright's would show it `navigator.webdriver` and
 * `--enable-automation`). It never types, clicks or presses a key.
 * - the mailbox screen: signed in;
 * - a sign-in step, a challenge, an error or an account-setup screen
 *   (never dismissed here) that stays for
 *   `settleMs`: not signed in, naming the screen (the profile was sent
 *   to a sign-in page);
 * - neither within `timeoutMs`: not signed in;
 * - a frame showing the password: not signed in (it never should here).
 */
export async function verifySignedIn(
  ctx: VerifyContext,
): Promise<VerifyOutcome> {
  const deadline = Date.now() + ctx.timeoutMs;
  type Seen = { what: string; since: number };
  let seen = null as Seen | null;
  for (let n = 0; ; n++) {
    const text = await readScreen(ctx, n);
    if (text === null)
      return {
        signedIn: false,
        reason: "the password was legible on the screen",
      };
    const screen = classifyScreen(ctx.provider, text);
    const now = Date.now();
    if (screen.kind === "done") {
      ctx.log("check: the mailbox shows");
      return { signedIn: true };
    }
    const what =
      screen.kind === "step"
        ? `the ${screen.step} screen of the sign-in`
        : screen.kind === "challenge"
          ? `a challenge (${screen.challenge}: "${screen.phrase}")`
          : screen.kind === "error"
            ? `an error (${screen.error}: "${screen.phrase}")`
            : screen.kind === "interstitial"
              ? `an account-setup screen (${screen.interstitial}: "${screen.phrase}")`
              : null;
    // The same non-mailbox screen since when (a new one restarts it).
    const cur: Seen | null =
      what === null ? null : seen?.what === what ? seen : { what, since: now };
    seen = cur;
    if (cur !== null && now - cur.since >= ctx.settleMs)
      return {
        signedIn: false,
        reason: cur.what.startsWith("an account-setup screen")
          ? `the inbox URL showed ${cur.what}, not the mailbox: the provider asks for it before the mailbox, and the check dismisses nothing (the sign-in does, through its skip control)`
          : `the inbox URL showed ${cur.what}, not the mailbox: the profile is not signed in`,
      };
    if (now >= deadline)
      return {
        signedIn: false,
        reason: `the mailbox did not show within ${Math.round(ctx.timeoutMs / 1000)} s${cur === null ? "" : ` (the screen: ${cur.what})`}`,
      };
    await sleep(ctx.pollMs);
  }
}
