// tools/capture/providers/webmail_signin_steps.test.ts — the automated
// webmail sign-in's screen recognition: each provider's screens, every
// challenge kind, the errors, and the order that settles a page carrying
// words of two screens; an unknown screen is not guessed.
//
// The OCR texts below are invented in the providers' wording (with the
// noise OCR adds: the browser's own bar, lost apostrophes, odd line
// breaks); the live sign-in of each QA account checks the wording itself.
// Pure functions: no browser, no GuiAssert, no network.
// Run with:
//   node --test tools/capture/providers/webmail_signin_steps.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  AOL_SIGNIN,
  CHALLENGE_KINDS,
  type ChallengeKind,
  classifyScreen,
  GMAIL_SIGNIN,
  normalize,
  OUTLOOK_SIGNIN,
  PROVIDER_SIGNIN,
  type ProviderSignin,
  YAHOO_SIGNIN,
} from "./webmail_signin_steps.ts";

// What OCR reads of the browser's own frame on every screen: the tab
// strip and the address bar of Google Chrome (no infobar), with a URL
// whose words must not count as the page's.
const CHROME_BAR =
  "Gmail\nx\n+\naccounts.google.com/v3/signin/identifier?continue=https%3A%2F%2Fmail.google.com%2Fmail%2Fu%2F0%2F&service=mail";

const screen = (...lines: string[]): string =>
  [CHROME_BAR, ...lines].join("\n");

const kind = (p: ProviderSignin, text: string): string => {
  const s = classifyScreen(p, text);
  switch (s.kind) {
    case "step":
      return `step:${s.step}`;
    case "challenge":
      return `challenge:${s.challenge}`;
    case "error":
      return `error:${s.error}`;
    default:
      return s.kind;
  }
};

describe("normalize", () => {
  it("lowers case, drops apostrophes and folds punctuation and line breaks into single spaces", () => {
    assert.equal(
      normalize("Email, phone,\n or  Skype"),
      " email phone or skype ",
    );
    assert.equal(normalize("Verify it’s you"), normalize("Verify its you"));
    assert.equal(normalize("Verify it's you"), " verify its you ");
    assert.equal(normalize("2-Step Verification"), " 2 step verification ");
  });
});

describe("Gmail screens", () => {
  const g = GMAIL_SIGNIN;
  it("recognises the address, password and mailbox screens", () => {
    assert.equal(
      kind(
        g,
        screen(
          "Google",
          "Sign in",
          "to continue to Gmail",
          "Email or phone",
          "Forgot email?",
          "Create account",
          "Next",
        ),
      ),
      "step:address",
    );
    assert.equal(
      kind(
        g,
        screen(
          "Google",
          "Welcome",
          "qa@example.com",
          "Enter your password",
          "Show password",
          "Forgot password?",
          "Next",
        ),
      ),
      "step:password",
    );
    assert.equal(
      kind(
        g,
        screen("Gmail", "Compose", "Inbox 3", "Starred", "Snoozed", "Sent"),
      ),
      "done",
    );
  });
  it("names its refusals and errors", () => {
    assert.equal(
      kind(
        g,
        screen(
          "Couldn’t sign you in",
          "This browser or app may not be secure. Learn more",
          "Try using a different browser.",
        ),
      ),
      "challenge:insecure-browser",
    );
    assert.equal(
      kind(g, screen("Couldnt sign you in")),
      "challenge:sign-in-refused",
    );
    assert.equal(
      kind(
        g,
        screen(
          "Welcome",
          "Enter your password",
          "Wrong password. Try again or click Forgot password to reset it.",
        ),
      ),
      "error:wrong-password",
    );
    assert.equal(
      kind(
        g,
        screen(
          "Sign in",
          "Email or phone",
          "Couldn't find your Google Account",
        ),
      ),
      "error:unknown-account",
    );
  });
  it("stops at Google's challenges", () => {
    const cases: [string, ChallengeKind][] = [
      [
        "Verify it's you\nTo help keep your account safe, Google wants to make sure it's really you trying to sign in",
        "verify-identity",
      ],
      [
        "2-Step Verification\nThis extra step shows it's really you trying to sign in",
        "verify-identity",
      ],
      [
        "Check your phone\nGoogle sent a notification to your Pixel. Tap Yes on the notification to verify it's you",
        "app-approval",
      ],
      ["Confirm you’re not a robot\nType the text you hear or see", "captcha"],
      [
        "Simplify your sign-in\nWith passkeys, you can now use your fingerprint, face, or screen lock",
        "passkey",
      ],
      [
        "Use your passkey to confirm it's really you\nYour device will ask for your fingerprint, face, or screen lock",
        "passkey",
      ],
      [
        "Make sure you can always sign in to your Google Account\nAdd recovery phone",
        "protect-account",
      ],
      [
        "Account recovery\nThis helps show that this account really belongs to you",
        "account-recovery",
      ],
      [
        "Get a verification code\nGoogle will send a verification code to (•••) •••-••12",
        "code-verification",
      ],
      [
        "Enter a phone number to get a text message with a verification code",
        "phone-verification",
      ],
    ];
    for (const [text, want] of cases)
      assert.equal(kind(g, screen(text)), `challenge:${want}`, text);
  });
});

describe("Yahoo screens (and AOL's, which are Yahoo's)", () => {
  for (const y of [YAHOO_SIGNIN, AOL_SIGNIN]) {
    it(`${y.label}: address, password, mailbox, errors and challenges`, () => {
      assert.equal(
        kind(
          y,
          screen(
            "yahoo!",
            "Sign in to Yahoo Mail",
            "using your Yahoo account",
            "Username, email, or mobile",
            "Next",
            "Stay signed in",
            "Forgot username?",
          ),
        ),
        "step:address",
      );
      assert.equal(
        kind(
          y,
          screen(
            "yahoo!",
            "qa@example.com",
            "Enter password",
            "to finish sign in",
            "Password",
            "Next",
            "Forgot password?",
          ),
        ),
        "step:password",
      );
      assert.equal(
        kind(y, screen("Compose", "Inbox", "Unread", "Starred", "Drafts")),
        "done",
      );
      assert.equal(
        kind(y, screen("Enter password", "Invalid password. Please try again")),
        "error:wrong-password",
      );
      assert.equal(
        kind(
          y,
          screen(
            "Username, email, or mobile",
            "Sorry, we don't recognize this email.",
          ),
        ),
        "error:unknown-account",
      );
      assert.equal(
        kind(y, screen("Are you a robot?", "I'm not a robot", "reCAPTCHA")),
        "challenge:captcha",
      );
      assert.equal(
        kind(
          y,
          screen("Yahoo Account Key", "Tap Yes on your phone to sign in"),
        ),
        "challenge:app-approval",
      );
      assert.equal(
        kind(
          y,
          screen(
            "Choose how you want to sign in",
            "Get a verification code",
            "Send code",
          ),
        ),
        "challenge:passwordless-default",
      );
      assert.equal(
        kind(
          y,
          screen(
            "Enter verification code",
            "We sent a code to •••@example.com",
          ),
        ),
        "challenge:code-verification",
      );
    });
  }
  it("AOL starts at its own sign-in", () => {
    assert.match(AOL_SIGNIN.startUrl, /^https:\/\/login\.aol\.com\//);
    assert.match(YAHOO_SIGNIN.startUrl, /^https:\/\/login\.yahoo\.com\//);
  });
});

describe("Outlook.com screens", () => {
  const o = OUTLOOK_SIGNIN;
  it("recognises the address, the password option, the password, 'stay signed in' and the mailbox", () => {
    assert.equal(
      kind(
        o,
        screen(
          "Microsoft",
          "Sign in",
          "to continue to Outlook",
          "Email, phone, or Skype",
          "No account? Create one!",
          "Can't access your account?",
          "Next",
        ),
      ),
      "step:address",
    );
    assert.equal(
      kind(o, screen("Microsoft", "Sign in", "Email or phone number", "Next")),
      "step:address",
    );
    assert.equal(
      kind(
        o,
        screen(
          "Microsoft",
          "qa@example.com",
          "Get a code to sign in",
          "We'll send a code to qa@example.com",
          "Send code",
          "Other ways to sign in",
          "Use your password",
        ),
      ),
      "step:choose-password",
    );
    assert.equal(
      kind(
        o,
        screen(
          "Microsoft",
          "qa@example.com",
          "Enter password",
          "Forgot your password?",
          "Email code to qa@example.com",
          "Sign in",
        ),
      ),
      "step:password",
    );
    assert.equal(
      kind(
        o,
        screen(
          "Microsoft",
          "qa@example.com",
          "Stay signed in?",
          "Do this to reduce the number of times you are asked to sign in.",
          "Don't show this again",
          "No",
          "Yes",
        ),
      ),
      "step:stay-signed-in",
    );
    assert.equal(
      kind(o, screen("Outlook", "New mail", "Inbox", "Focused", "Other")),
      "done",
    );
  });
  it("names its errors and challenges", () => {
    assert.equal(
      kind(
        o,
        screen("Enter password", "Your account or password is incorrect."),
      ),
      "error:wrong-password",
    );
    assert.equal(
      kind(
        o,
        screen(
          "Sign in",
          "That Microsoft account doesn't exist. Enter a different account",
        ),
      ),
      "error:unknown-account",
    );
    const cases: [string, ChallengeKind][] = [
      [
        "Help us protect your account\nBefore you can continue, we need to verify your identity",
        "verify-identity",
      ],
      [
        "Let's prove you're human\nPlease solve the puzzle so we know you're not a robot",
        "captcha",
      ],
      [
        "Approve sign in request\nOpen your Authenticator app, and enter the number shown to sign in",
        "app-approval",
      ],
      [
        "Your account has been locked\nWe've detected some activity that violates our Microsoft Services Agreement",
        "account-locked",
      ],
      ["We detected something unusual about this sign-in", "unusual-activity"],
      [
        "Get a code to sign in\nWe'll send a code to qa@example.com\nSend code",
        "passwordless-default",
      ],
      ["Enter code\nWe emailed a code to qa@example.com", "code-verification"],
      [
        "Sign in faster with your face, fingerprint, or PIN\nCreate a passkey",
        "passkey",
      ],
    ];
    for (const [text, want] of cases)
      assert.equal(kind(o, screen(text)), `challenge:${want}`, text);
  });
});

describe("the order of the checks", () => {
  it("reads a mailbox whose messages talk about verification as the mailbox", () => {
    // A security notice in the inbox list says "Verify it's you": the
    // mailbox words come first.
    assert.equal(
      kind(
        GMAIL_SIGNIN,
        screen(
          "Compose",
          "Inbox",
          "Google — Security alert: Verify it's you — unusual activity",
        ),
      ),
      "done",
    );
  });
  it("puts a hard challenge before any step screen on the same page", () => {
    assert.equal(
      kind(
        GMAIL_SIGNIN,
        screen("Verify it's you", "Sign in", "Email or phone", "Next"),
      ),
      "challenge:verify-identity",
    );
    assert.equal(
      kind(
        OUTLOOK_SIGNIN,
        screen("Enter password", "Let's prove you're human"),
      ),
      "challenge:captcha",
    );
  });
  it("puts an error before the step screen it is shown on", () => {
    assert.equal(
      kind(
        OUTLOOK_SIGNIN,
        screen("Enter password", "Your account or password is incorrect."),
      ),
      "error:wrong-password",
    );
  });
  it("puts a step screen before a soft challenge it offers as an alternative", () => {
    assert.equal(
      kind(
        OUTLOOK_SIGNIN,
        screen(
          "Enter password",
          "Email code to qa@example.com",
          "Sign in another way",
        ),
      ),
      "step:password",
    );
  });
  it("does not guess at a screen it does not know, nor take the browser's own bar for anything", () => {
    for (const p of Object.values(PROVIDER_SIGNIN)) {
      assert.equal(kind(p, screen()), "unknown", p.label);
      assert.equal(kind(p, screen("Loading…")), "unknown", p.label);
      assert.equal(
        kind(p, screen("This site can't be reached", "ERR_NAME_NOT_RESOLVED")),
        "unknown",
        p.label,
      );
      assert.equal(kind(p, ""), "unknown", p.label);
    }
  });
});

describe("the tables", () => {
  it("cover every challenge kind with at least one provider's phrase", () => {
    const covered = new Set<ChallengeKind>();
    for (const p of Object.values(PROVIDER_SIGNIN))
      for (const r of [...p.hardChallenges, ...p.softChallenges])
        covered.add(r.kind);
    assert.deepEqual([...covered].sort(), [...CHALLENGE_KINDS].sort());
  });
  it("give every provider an address and a password screen and a field name for the address", () => {
    for (const p of Object.values(PROVIDER_SIGNIN)) {
      const steps = p.steps.map((s) => s.step);
      assert.ok(
        steps.includes("address") && steps.includes("password"),
        p.label,
      );
      assert.match(p.startUrl, /^https:\/\//, p.label);
    }
    assert.ok(GMAIL_SIGNIN.addressField.test("Email or phone"));
    assert.ok(!GMAIL_SIGNIN.addressField.test("Address and search bar"));
    assert.ok(!YAHOO_SIGNIN.addressField.test("Address and search bar"));
    assert.ok(!OUTLOOK_SIGNIN.addressField.test("Address and search bar"));
  });
});
