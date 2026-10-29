// tools/capture/providers/webmail_signin_steps.ts — what the automated
// webmail sign-in recognises on each provider's screens, and which one
// step it takes on each. Data plus a classifier; the procedure that acts
// on it is webmail_signin.ts.
//
// A screen is recognised from the OCR text of the whole display, by
// phrases. Text and phrases are compared after the same normalisation:
// lower case, apostrophes dropped (OCR often loses them: "it's" and
// "its" compare equal), every other run of characters that is not a
// letter or a digit turned into one space (so "Email, phone, or Skype"
// and a line break compare as written here). An OCR text
// is classified in a fixed order, so that a page carrying words of two
// screens is read the safe way:
//   0. a privacy-consent page (`consent`), recognised by its address, not
//      by its words (a provider may show it in the language of the
//      visitor's region): a challenge phrase on it still makes it a
//      challenge; otherwise nothing below is looked for on it;
//   1. the mailbox (`done`): phrases no sign-in or challenge page has;
//   1a. Google's password re-verification of an existing session
//      (`reauth-password`): "Verify it's you" with only a password field;
//      anything else on such a page is the more precise reason and is
//      reported as itself (another hard challenge, an error, then a code
//      or phone challenge), the re-verification's own wording not
//      counted;
//   1b. Google's "sign in again" page (`sign-in-again`), recognised by its
//      address (`accounts.google.com/…/signin/confirmidentifier`, read
//      from the browser's address bar) and its wording ("Please sign in
//      again"): the account and a single "Next", nothing to fill; the
//      same more precise reasons as 1a win over it;
//   2. hard challenges: whatever else the page says, a person is needed;
//   3. errors (wrong password, unknown account): stop, never retry;
//   4. the step screens: address, password, and the two small ones
//      (Outlook.com's "Use your password" option, "Stay signed in?");
//   5. account-setup interstitials: what a provider asks for once the
//      sign-in has succeeded (a home address, a recovery phone, a passkey
//      offer, ...); the procedure only ever dismisses one through an
//      explicit skip control (SKIP_CONTROLS), never answers it;
//   6. soft challenges (a code, a phone): only when no step screen or
//      interstitial matched, because a password screen may offer "email a
//      code" as an alternative, and a recovery-phone interstitial talks
//      about text messages;
//   7. otherwise `unknown`: never guessed at.
//
// A phrase is never both a challenge and an interstitial of one
// provider (the test checks it): hard challenges come first, so such an
// interstitial could never be reached.
//
// Every phrase is an expectation until the live sign-in of each QA
// account confirms it [measure: the first real attempt per provider].
// The pages are asked for in English (the browser's languages are
// en-US, en; Google's and Yahoo's start URLs force English too), so the
// phrases are English. A page a provider localises by region whatever
// the browser asks for (Yahoo's privacy consent, measured in
// Bulgarian) is recognised by its address, and its controls by exact
// names per language (CONSENT_CONTROLS).

export type ChallengeKind =
  | "captcha"
  | "phone-verification"
  | "code-verification"
  | "app-approval"
  | "passkey"
  | "insecure-browser"
  | "verify-identity"
  | "unusual-activity"
  | "account-recovery"
  | "protect-account"
  | "passwordless-default"
  | "account-locked"
  | "sign-in-refused";

export const CHALLENGE_KINDS: readonly ChallengeKind[] = [
  "captcha",
  "phone-verification",
  "code-verification",
  "app-approval",
  "passkey",
  "insecure-browser",
  "verify-identity",
  "unusual-activity",
  "account-recovery",
  "protect-account",
  "passwordless-default",
  "account-locked",
  "sign-in-refused",
];

export type SigninErrorKind = "wrong-password" | "unknown-account";

export type StepId =
  | "address"
  | "password"
  | "reauth-password"
  | "sign-in-again"
  | "choose-password"
  | "stay-signed-in";

/** A screen: every phrase of `all` and at least one of `any` (when given). */
export interface ScreenMatch {
  all?: string[];
  any?: string[];
}

export interface StepScreen extends ScreenMatch {
  step: StepId;
}

export interface ChallengeRule {
  kind: ChallengeKind;
  any: string[];
}

export interface ErrorRule {
  kind: SigninErrorKind;
  any: string[];
}

/** A screen asking for more account data after the sign-in. */
export interface InterstitialRule {
  /** A short name for logs and results (`home-address`, ...). */
  name: string;
  any: string[];
}

/**
 * The accessible names of the controls that dismiss an interstitial
 * without answering it, in order of preference. Nothing else is ever
 * clicked on one: not "Save", "Next", "Continue", "Confirm" or "Done".
 */
export const SKIP_CONTROLS: readonly string[] = [
  "Skip",
  "Skip for now",
  "Not now",
  "Remind me later",
  "Maybe later",
  "No thanks",
  "Cancel",
];

/**
 * Pages by address: the host is one of `hosts` and the path (with its
 * query) contains one of `paths`, both compared in lower case ("" matches
 * any path).
 */
export interface AddressRule {
  hosts: string[];
  paths: string[];
}

/** A provider's privacy-consent pages, by address. */
export interface ConsentRule extends AddressRule {
  /** A short name for logs and results (`yahoo-consent`). */
  name: string;
}

/**
 * Google's password re-verification of an existing session: the screen
 * matches `match`, and no challenge phrase but `allowed` (the wording of
 * the re-verification itself) is on it.
 */
export interface ReauthRule {
  match: ScreenMatch;
  allowed: string[];
}

/**
 * Google's "sign in again" page of a session it no longer accepts: the
 * page is on `address` and matches `match`, no challenge phrase but
 * `allowed` is on it, and the procedure finds exactly one button named
 * exactly `control` and no field to fill (webmail_signin.ts).
 */
export interface SignInAgainRule {
  address: AddressRule;
  match: ScreenMatch;
  allowed: string[];
  /** The accessible name of the one button that goes on. */
  control: string;
}

/**
 * The controls of a privacy-consent page, by exact accessible name (after
 * `normalize`), per language: English, Bulgarian (the languages met so
 * far; measured 2026-10-28: Yahoo's mail consent in Bulgarian, its rows'
 * radio buttons "Отхвърляне" / "Разрешаване", a "Продължаване" button;
 * Yahoo's cookie consent's "Отхвърляне на всички" / "Приемане на всички"
 * buttons). The procedure (webmail_signin.ts) clicks a reject-all control,
 * or every reject choice and then a continue control; it never clicks a
 * name in `never`, and no other list may contain a word of it (the test
 * checks it).
 */
export const CONSENT_CONTROLS = {
  /** Buttons or links that reject every optional use at once. */
  rejectAll: ["Reject all", "Отхвърляне на всички"],
  /** Radio buttons that reject one row's use. */
  reject: ["Reject", "Отхвърляне"],
  /** Radio buttons that allow one row's use: only ever counted, never clicked. */
  allow: ["Allow", "Разрешаване"],
  /** Buttons that go on once every row is rejected. */
  proceed: ["Continue", "Продължаване"],
  /** Never clicked. */
  never: [
    "Accept all",
    "Allow all",
    "Agree",
    "Accept",
    "I agree",
    "Приемане на всички",
    "Разрешаване на всички",
    "Приемане",
    "Съгласявам се",
  ],
} as const;

export interface ProviderSignin {
  set: string;
  label: string;
  /** Where the sign-in browser starts: the mailbox, by way of the sign-in. */
  startUrl: string;
  /** Its privacy-consent pages, when it has any. */
  consent?: ConsentRule;
  /** Its password re-verification of an existing session, when it has one. */
  reauth?: ReauthRule;
  /** Its "sign in again" page, when it has one. */
  signInAgain?: SignInAgainRule;
  done: ScreenMatch;
  /** In order of precedence. */
  steps: StepScreen[];
  /** The accessible name of the address field. */
  addressField: RegExp;
  /** The accessible name of the element "Use your password" clicks. */
  choosePasswordControl?: string;
  /** The accessible name of the "Stay signed in?" button that says yes. */
  staySignedInControl?: string;
  hardChallenges: ChallengeRule[];
  errors: ErrorRule[];
  interstitials: InterstitialRule[];
  softChallenges: ChallengeRule[];
}

/** Lower case, apostrophes dropped, every other non-alphanumeric run one space. */
export function normalize(text: string): string {
  return ` ${text
    .normalize("NFKC")
    .toLowerCase()
    .replace(/['\u2018\u2019\u02bc`]/g, "")
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim()} `;
}

const has = (norm: string, phrase: string): boolean =>
  norm.includes(normalize(phrase));

function matches(norm: string, m: ScreenMatch): boolean {
  if (m.all === undefined && m.any === undefined) return false;
  if (m.all !== undefined && !m.all.every((p) => has(norm, p))) return false;
  if (m.any !== undefined && !m.any.some((p) => has(norm, p))) return false;
  return true;
}

function firstPhrase(
  norm: string,
  rules: { any: string[] }[],
): { index: number; phrase: string } | null {
  for (let i = 0; i < rules.length; i++)
    for (const p of rules[i]!.any)
      if (has(norm, p)) return { index: i, phrase: p };
  return null;
}

export type Screen =
  | { kind: "done" }
  | { kind: "challenge"; challenge: ChallengeKind; phrase: string }
  | { kind: "error"; error: SigninErrorKind; phrase: string }
  | { kind: "step"; step: StepId }
  | { kind: "interstitial"; interstitial: string; phrase: string }
  | { kind: "consent"; consent: string }
  | { kind: "unknown" };

/**
 * A page address as the browser's address bar shows it: host (without a
 * port: a provider's consent host is the same on any port), then the
 * rest. Anything after the host but a port and a path, query or fragment
 * (`host:x`, `host@other`) is no address of that host: null.
 */
export function splitLocation(
  location: string,
): { host: string; rest: string } | null {
  const m =
    /^\s*(?:[a-z][a-z0-9+.-]*:\/\/)?([^/?#\s:@]+)(?::\d+)?((?:[/?#][^\s]*)?)\s*$/i.exec(
      location,
    );
  if (m === null) return null;
  return { host: m[1]!.toLowerCase(), rest: (m[2] ?? "").toLowerCase() };
}

// Letters and digits only, lower case: OCR of the address bar may drop a
// host's dots and the colon before its port ("consentlocalhost33875").
const squash = (text: string): string =>
  text
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "");

/**
 * Whether the OCR text may show one of the rule's consent hosts in the
 * address bar: the host's letters and digits in order, whatever the
 * punctuation and port around them. Only a hint to read the address
 * bar, which decides.
 */
export function consentHinted(p: ProviderSignin, ocrText: string): boolean {
  if (p.consent === undefined) return false;
  const text = squash(ocrText);
  return p.consent.hosts.some((h) => text.includes(squash(h)));
}

function isRuleAddress(rule: AddressRule, location: string): boolean {
  const l = splitLocation(location);
  return (
    l !== null &&
    rule.hosts.includes(l.host) &&
    rule.paths.some((x) => l.rest.includes(x.toLowerCase()))
  );
}

/**
 * Whether the page is on one of `rule`'s addresses: by `location` (the
 * address bar's value, from the accessibility tree) when there is one,
 * else by a word of the OCR text that is such an address (a host of the
 * rule, then one of its paths: a page that only mentions the host is not
 * on it).
 */
export function onAddress(
  rule: AddressRule | undefined,
  ocrText: string,
  location: string | null | undefined,
): boolean {
  if (rule === undefined) return false;
  if (location !== null && location !== undefined)
    return isRuleAddress(rule, location);
  return ocrText.split(/\s+/).some((w) => w !== "" && isRuleAddress(rule, w));
}

/** Whether the page is one of the provider's consent pages (`onAddress`). */
export function onConsentPage(
  p: ProviderSignin,
  ocrText: string,
  location: string | null | undefined,
): boolean {
  return onAddress(p.consent, ocrText, location);
}

/**
 * Whether the OCR text may be the provider's "sign in again" page: its
 * wording is on it. Only a hint to read the address bar, which decides.
 */
export function signInAgainHinted(p: ProviderSignin, ocrText: string): boolean {
  return (
    p.signInAgain !== undefined &&
    matches(normalize(ocrText), p.signInAgain.match)
  );
}

/**
 * A challenge or an error on a page that is otherwise one of Google's
 * session pages (1a, 1b): another hard challenge, an error, then a code
 * or phone challenge, the page's own wording (`allowed`) not counted;
 * null when there is none.
 */
function morePrecise(
  p: ProviderSignin,
  norm: string,
  allowed: string[],
): Screen | null {
  const other = without(p.hardChallenges, allowed);
  const hit = firstPhrase(norm, other);
  if (hit !== null)
    return {
      kind: "challenge",
      challenge: other[hit.index]!.kind,
      phrase: hit.phrase,
    };
  const e = firstPhrase(norm, p.errors);
  if (e !== null)
    return { kind: "error", error: p.errors[e.index]!.kind, phrase: e.phrase };
  const soft = firstPhrase(norm, p.softChallenges);
  if (soft !== null)
    return {
      kind: "challenge",
      challenge: p.softChallenges[soft.index]!.kind,
      phrase: soft.phrase,
    };
  return null;
}

/**
 * Classifies one OCR text of the display (the order is the header's).
 * `location` is the page's address from the browser's address bar, when
 * the caller read it (only a consent page and the "sign in again" page
 * need it).
 */
export function classifyScreen(
  p: ProviderSignin,
  ocrText: string,
  location?: string | null,
): Screen {
  const norm = normalize(ocrText);
  if (onConsentPage(p, ocrText, location)) {
    // A challenge still wins: hard ones, then the code and phone ones.
    for (const rules of [p.hardChallenges, p.softChallenges]) {
      const hit = firstPhrase(norm, rules);
      if (hit !== null)
        return {
          kind: "challenge",
          challenge: rules[hit.index]!.kind,
          phrase: hit.phrase,
        };
    }
    return { kind: "consent", consent: p.consent!.name };
  }
  if (matches(norm, p.done)) return { kind: "done" };
  if (p.reauth !== undefined && matches(norm, p.reauth.match))
    // Anything else on it is the more precise reason.
    return (
      morePrecise(p, norm, p.reauth.allowed) ?? {
        kind: "step",
        step: "reauth-password",
      }
    );
  const again = p.signInAgain;
  if (
    again !== undefined &&
    matches(norm, again.match) &&
    onAddress(again.address, ocrText, location)
  )
    return (
      morePrecise(p, norm, again.allowed) ?? {
        kind: "step",
        step: "sign-in-again",
      }
    );
  const hard = firstPhrase(norm, p.hardChallenges);
  if (hard !== null)
    return {
      kind: "challenge",
      challenge: p.hardChallenges[hard.index]!.kind,
      phrase: hard.phrase,
    };
  const err = firstPhrase(norm, p.errors);
  if (err !== null)
    return {
      kind: "error",
      error: p.errors[err.index]!.kind,
      phrase: err.phrase,
    };
  for (const s of p.steps)
    if (matches(norm, s)) return { kind: "step", step: s.step };
  const inter = firstPhrase(norm, p.interstitials);
  if (inter !== null)
    return {
      kind: "interstitial",
      interstitial: p.interstitials[inter.index]!.name,
      phrase: inter.phrase,
    };
  const soft = firstPhrase(norm, p.softChallenges);
  if (soft !== null)
    return {
      kind: "challenge",
      challenge: p.softChallenges[soft.index]!.kind,
      phrase: soft.phrase,
    };
  return { kind: "unknown" };
}

// ---------------------------------------------------------------------------
// The challenges every provider shares, worded as Google, Yahoo and
// Microsoft word them. Provider tables add their own in front.
// ---------------------------------------------------------------------------

const COMMON_HARD: ChallengeRule[] = [
  {
    kind: "captcha",
    any: [
      "not a robot",
      "are you a robot",
      "recaptcha",
      "type the text you hear or see",
      "prove you're human",
      "verify you're human",
      "solve the puzzle",
      "solve this puzzle",
    ],
  },
  {
    kind: "insecure-browser",
    any: ["this browser or app may not be secure", "browser may not be secure"],
  },
  {
    kind: "account-locked",
    any: [
      "account has been locked",
      "account is locked",
      "temporarily locked",
      "account has been temporarily blocked",
    ],
  },
  {
    kind: "unusual-activity",
    any: [
      "unusual activity",
      "suspicious activity",
      "something unusual",
      "unusual sign in",
    ],
  },
  {
    kind: "app-approval",
    any: [
      "check your phone",
      "sent a notification",
      "approve sign in request",
      "approve the request",
      "authenticator app",
      "account key",
      "tap yes on",
    ],
  },
  {
    kind: "passkey",
    any: [
      "use your passkey",
      "use a passkey",
      "create a passkey",
      "choose a passkey",
      "use your screen lock",
      "simplify your sign in",
      "security key",
    ],
  },
  {
    kind: "verify-identity",
    any: [
      "verify it's you",
      "verify that it's you",
      "confirm it's you",
      "verify your identity",
      "2 step verification",
      "really you",
    ],
  },
  {
    kind: "account-recovery",
    any: ["account recovery", "recover your account"],
  },
  {
    kind: "protect-account",
    any: [
      "protect your account",
      "secure your account",
      "make sure you can always sign in",
    ],
  },
];

const COMMON_SOFT: ChallengeRule[] = [
  {
    kind: "phone-verification",
    any: [
      "enter a phone number",
      "add a phone number",
      "verify your phone number",
      "text message",
    ],
  },
  {
    kind: "code-verification",
    any: [
      "verification code",
      "enter the code",
      "enter code",
      "sent a code",
      "send a code",
      "security code",
    ],
  },
];

/** `rules` without `phrases` (a rule left with none is dropped). */
function without(rules: ChallengeRule[], phrases: string[]): ChallengeRule[] {
  const drop = new Set(phrases.map(normalize));
  return rules
    .map((r) => ({ ...r, any: r.any.filter((p) => !drop.has(normalize(p))) }))
    .filter((r) => r.any.length > 0);
}

// Google's account-setup screens after a successful sign-in (measured
// 2026-10-28: "Set a home address" with "Skip" and "Save", on
// gds.google.com). The others are Google's known prompts of the same
// family [measure: as they appear].
const GMAIL_INTERSTITIALS: InterstitialRule[] = [
  {
    name: "home-address",
    any: ["set a home address", "add a home address", "set your home address"],
  },
  {
    name: "work-address",
    any: ["set a work address", "add a work address", "set your work address"],
  },
  // A heading over several prompts, before the prompts it lists.
  {
    name: "always-sign-in",
    any: ["make sure you can always sign in"],
  },
  {
    name: "recovery-phone",
    any: [
      "add a recovery phone",
      "add recovery phone",
      "confirm your recovery phone",
      "update your recovery phone",
    ],
  },
  {
    name: "recovery-email",
    any: [
      "add a recovery email",
      "add recovery email",
      "confirm your recovery email",
      "update your recovery email",
    ],
  },
  { name: "protect-account", any: ["protect your account"] },
  {
    name: "passkey-enrolment",
    any: [
      "simplify your sign in",
      "create a passkey",
      "sign in faster with passkeys",
      "sign in with passkeys",
    ],
  },
];

// ---------------------------------------------------------------------------
// The providers
// ---------------------------------------------------------------------------

// The wording of Google's password re-verification that may share a
// screen with its password field (and is a challenge everywhere else).
const GMAIL_REAUTH_WORDING = [
  "verify it's you",
  "verify that it's you",
  "confirm it's you",
  "first verify it's you",
  "really you",
];

export const GMAIL_SIGNIN: ProviderSignin = {
  set: "gmail-workspace",
  label: "Gmail",
  // ServiceLogin lands a signed-in profile on the mailbox and a
  // signed-out one on the address screen. hl=en: the pages in English
  // whatever the region (measured 2026-10-28: lang="bg" for a Bulgarian
  // Accept-Language without it, lang="en" with it).
  startUrl:
    "https://accounts.google.com/ServiceLogin?service=mail&hl=en&continue=https%3A%2F%2Fmail.google.com%2Fmail%2Fu%2F0%2F",
  // Google's cookie consent for a signed-out visitor in the EU ("Before
  // you continue to Google") [measure: as it appears].
  consent: {
    name: "google-consent",
    hosts: ["consent.google.com"],
    paths: [""],
  },
  // "Verify it's you" / "To continue, first verify it's you" over the
  // account and a password field only: an existing session asked to
  // confirm its password [measure: as it appears].
  reauth: {
    match: {
      all: ["enter your password"],
      any: ["verify it's you", "verify that it's you"],
    },
    allowed: GMAIL_REAUTH_WORDING,
  },
  // Measured 2026-10-29 (a profile whose session cookies Google no longer
  // accepted, on its inbox URL and on the start URL alike):
  // accounts.google.com/v3/signin/confirmidentifier?…&flowName=GlifWebSignIn…,
  // "Verify it's you", the account's chip, "To help keep your account
  // secure, Google needs to verify it's you. Please sign in again to
  // continue to Gmail.", one "Next" button, nothing else. Google's
  // ordinary re-sign-in: "Next" leads to the password screen.
  signInAgain: {
    address: {
      hosts: ["accounts.google.com"],
      paths: ["/signin/confirmidentifier"],
    },
    match: { all: ["sign in again"] },
    allowed: GMAIL_REAUTH_WORDING,
    control: "Next",
  },
  done: { all: ["compose", "inbox"] },
  steps: [
    { step: "password", any: ["enter your password"] },
    { step: "address", all: ["sign in"], any: ["email or phone"] },
  ],
  addressField: /email or phone/i,
  // "Couldn't sign you in" heads several refusals; the more precise
  // reason under it (an insecure browser, ...) is checked first. The
  // account-setup prompts Google shows after a successful sign-in are
  // interstitials here, not challenges.
  hardChallenges: [
    ...without(
      COMMON_HARD,
      GMAIL_INTERSTITIALS.flatMap((r) => r.any),
    ),
    { kind: "sign-in-refused", any: ["couldn't sign you in"] },
  ],
  errors: [
    { kind: "wrong-password", any: ["wrong password"] },
    { kind: "unknown-account", any: ["couldn't find your google account"] },
  ],
  interstitials: GMAIL_INTERSTITIALS,
  softChallenges: [...COMMON_SOFT],
};

// Yahoo's (and AOL's, the same platform's) privacy-consent pages:
// measured 2026-10-28, consent.yahoo.com/mailbox/collectConsent after the
// password (the mail consent, in Bulgarian); guce.yahoo.com/consent
// redirects to consent.yahoo.com/v2/collectConsent (the cookie consent).
const YAHOO_CONSENT: ConsentRule = {
  name: "yahoo-consent",
  hosts: [
    "consent.yahoo.com",
    "guce.yahoo.com",
    "consent.aol.com",
    "guce.aol.com",
  ],
  paths: ["consent"],
};

export const YAHOO_SIGNIN: ProviderSignin = {
  set: "yahoo",
  label: "Yahoo Mail",
  // .lang=en-US: the sign-in pages in English whatever the region
  // (measured 2026-10-28: lang="bg-BG" for a Bulgarian Accept-Language
  // without it, lang="en-US" with it). The consent pages ignore it.
  startUrl:
    "https://login.yahoo.com/?.src=ym&.lang=en-US&done=https%3A%2F%2Fmail.yahoo.com%2F",
  consent: YAHOO_CONSENT,
  done: { all: ["compose", "inbox"] },
  // Measured 2026-10-28: the address screen reads "Sign in to Yahoo
  // Mail", "Username, email or phone number", "Stay signed in", "Next"
  // (with a large advertisement beside it). The password screen's
  // heading is not measured yet; "Forgot password?" with "Next" is on it
  // and on no address screen.
  steps: [
    { step: "password", any: ["enter password", "enter your password"] },
    { step: "password", all: ["forgot password", "next"] },
    {
      step: "address",
      any: ["username email or phone number", "username email or mobile"],
    },
  ],
  addressField: /username|email|mobile|phone/i,
  hardChallenges: [...COMMON_HARD],
  errors: [
    {
      kind: "wrong-password",
      any: ["invalid password", "incorrect password"],
    },
    {
      kind: "unknown-account",
      any: [
        "don't recognize this email",
        "we don't recognize",
        "we don't recognise",
      ],
    },
  ],
  // Yahoo's prompts after a sign-in [measure: as they appear].
  interstitials: [
    {
      name: "recovery-phone",
      any: [
        "add a recovery phone",
        "add your phone number",
        "is this still your phone",
      ],
    },
    {
      name: "recovery-email",
      any: ["add a recovery email", "is this still your email"],
    },
  ],
  softChallenges: [
    {
      kind: "passwordless-default",
      any: ["choose how you want to sign in", "sign in with a code"],
    },
    ...COMMON_SOFT,
  ],
};

/** AOL runs on Yahoo's platform: Yahoo's screens, its own start URL. */
export const AOL_SIGNIN: ProviderSignin = {
  ...YAHOO_SIGNIN,
  set: "aol",
  label: "AOL Mail",
  startUrl: "https://login.aol.com/?done=https%3A%2F%2Fmail.aol.com%2F",
};

export const OUTLOOK_SIGNIN: ProviderSignin = {
  set: "outlook-com",
  label: "Outlook.com",
  // nlp=1 skips the marketing page and asks for the sign-in directly.
  startUrl: "https://outlook.live.com/mail/0/?nlp=1",
  done: { all: ["new mail", "inbox"] },
  steps: [
    { step: "stay-signed-in", all: ["stay signed in"] },
    { step: "password", any: ["enter password", "enter your password"] },
    { step: "choose-password", any: ["use your password"] },
    {
      step: "address",
      all: ["sign in"],
      any: ["email phone or skype", "email or phone number"],
    },
  ],
  addressField: /email|phone|skype/i,
  choosePasswordControl: "Use your password",
  staySignedInControl: "Yes",
  hardChallenges: [...COMMON_HARD],
  errors: [
    // Measured 2026-10-28: "That password is incorrect for your
    // Microsoft account."
    { kind: "wrong-password", any: ["password is incorrect"] },
    {
      kind: "unknown-account",
      any: ["account doesn't exist", "couldn't find an account"],
    },
  ],
  interstitials: [],
  softChallenges: [
    {
      kind: "passwordless-default",
      any: ["get a code to sign in", "sign in another way"],
    },
    ...COMMON_SOFT,
  ],
};

export const PROVIDER_SIGNIN: Record<string, ProviderSignin> = {
  "gmail-workspace": GMAIL_SIGNIN,
  yahoo: YAHOO_SIGNIN,
  aol: AOL_SIGNIN,
  "outlook-com": OUTLOOK_SIGNIN,
};
