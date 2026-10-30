// tools/capture/providers/webmail_signin_steps.test.ts — the automated
// webmail sign-in's screen recognition: each provider's screens, every
// challenge kind, the errors, the account-setup interstitials, and the
// order that settles a page carrying words of two screens; an unknown
// screen is not guessed.
//
// The OCR texts below are invented in the providers' wording (with the
// noise OCR adds: the browser's own bar, lost apostrophes, odd line
// breaks); the live sign-in of each QA account checks the wording itself.
// Yahoo's privacy-consent page is the measured one (2026-10-28, in
// Bulgarian), recognised by its address whatever its language, and so is
// Google's sign-in-again page (2026-10-29), by its address and wording.
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
  CONSENT_CONTROLS,
  consentHinted,
  GMAIL_SIGNIN,
  normalize,
  OUTLOOK_SIGNIN,
  PROVIDER_SIGNIN,
  type ProviderSignin,
  signInAgainHinted,
  SKIP_CONTROLS,
  splitLocation,
  YAHOO_SIGNIN,
} from "./webmail_signin_steps.ts";

// What OCR reads of the browser's own frame on every screen: the tab
// strip and the address bar of Google Chrome (no infobar), with a URL
// whose words must not count as the page's.
const CHROME_BAR =
  "Gmail\nx\n+\naccounts.google.com/v3/signin/identifier?continue=https%3A%2F%2Fmail.google.com%2Fmail%2Fu%2F0%2F&service=mail";

const screen = (...lines: string[]): string =>
  [CHROME_BAR, ...lines].join("\n");

const kind = (
  p: ProviderSignin,
  text: string,
  location?: string | null,
): string => {
  const s = classifyScreen(p, text, location);
  switch (s.kind) {
    case "step":
      return `step:${s.step}`;
    case "challenge":
      return `challenge:${s.challenge}`;
    case "error":
      return `error:${s.error}`;
    case "interstitial":
      return `interstitial:${s.interstitial}`;
    case "consent":
      return `consent:${s.consent}`;
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
        "Use your passkey to confirm it's really you\nYour device will ask for your fingerprint, face, or screen lock",
        "passkey",
      ],
      [
        // A challenge that mentions protecting the account is still the
        // challenge: hard challenges come before interstitials.
        "Verify it's you\nTo protect your account, Google wants to make sure it's really you",
        "verify-identity",
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
  it("reads Google's account-setup screens after the sign-in as interstitials, not challenges", () => {
    // As measured on 2026-10-28 (gds.google.com/web/homeaddress), with
    // and without Chrome's own sign-in bubble over it.
    const homeAddress = [
      "Set a home address",
      "Your home and work addresses are used to personalize your experiences across Google products, and for ads purposes as described in Google's Privacy Policy.",
      "qa@example.com",
      "Home address",
      "You can change or remove this any time in your Google Account settings.",
      "Skip",
      "Save",
    ];
    assert.equal(kind(g, screen(...homeAddress)), "interstitial:home-address");
    assert.equal(
      kind(
        g,
        screen(
          ...homeAddress,
          "Sign in to Chrome?",
          "Make Chrome your own",
          "To get your passwords and more on all your devices, sign in to Chrome",
          "Continue as QA",
          "Use Chrome without an account",
        ),
      ),
      "interstitial:home-address",
    );
    const cases: [string, string][] = [
      [
        "Make sure you can always sign in to your Google Account\nAdd recovery phone\nCancel\nSave",
        "always-sign-in",
      ],
      [
        "Add a recovery phone\nIf you forget your password, Google can send you a text message with a code\nNot now\nNext",
        "recovery-phone",
      ],
      [
        "Add a recovery email\nIf you get locked out, Google can send a code to this email\nSkip\nNext",
        "recovery-email",
      ],
      [
        "Simplify your sign-in\nWith passkeys, you can now use your fingerprint, face, or screen lock\nCreate a passkey\nNot now",
        "passkey-enrolment",
      ],
      [
        "Protect your account\nReview these settings to keep your account safe\nRemind me later",
        "protect-account",
      ],
      ["Set a work address\nWork address\nSkip\nSave", "work-address"],
    ];
    for (const [text, want] of cases)
      assert.equal(kind(g, screen(text)), `interstitial:${want}`, text);
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
      // As measured on 2026-10-28: "Username, email or phone number",
      // beside an advertisement.
      assert.equal(
        kind(
          y,
          screen(
            "yahoo!",
            "Help Terms Privacy",
            "yahoo!finance",
            "THE #1 FINANCE DESTINATION",
            "DISCOVER WHAT'S NEW",
            "Sign in to Yahoo Mail",
            "Username, email or phone number",
            "Stay signed in",
            "Forgot username",
            "Next",
            "or",
            "Sign in with Google",
            "Create account",
            "Real-time alerts to keep your edge",
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
      // A password screen without the heading.
      assert.equal(
        kind(
          y,
          screen(
            "yahoo!",
            "qa@example.com",
            "Password",
            "Show",
            "Next",
            "Forgot password?",
          ),
        ),
        "step:password",
      );
      // Its address screen is never a password screen.
      assert.equal(
        kind(
          y,
          screen(
            "Sign in to Yahoo Mail",
            "Username, email or phone number",
            "Next",
            "Forgot username",
          ),
        ),
        "step:address",
      );
      assert.equal(
        kind(y, screen("Password", "Incorrect password. Try again.", "Next")),
        "error:wrong-password",
      );
      assert.equal(
        kind(
          y,
          screen(
            "Add a recovery phone",
            "Help keep your account secure",
            "Remind me later",
          ),
        ),
        "interstitial:recovery-phone",
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
    // As measured on 2026-10-28.
    assert.equal(
      kind(
        o,
        screen(
          "Microsoft",
          "qa@example.com",
          "Enter your password",
          "Password",
          "That password is incorrect for your Microsoft account.",
          "Next",
          "Send a code to qa*****@example.com",
          "Sign in with a different Microsoft account",
        ),
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
  it("never give an interstitial a phrase a challenge or an error of the same provider would claim first", () => {
    for (const p of Object.values(PROVIDER_SIGNIN))
      for (const r of p.interstitials) {
        assert.ok(r.any.length > 0, `${p.label} ${r.name}`);
        for (const ip of r.any)
          for (const rule of [...p.hardChallenges, ...p.errors])
            for (const cp of rule.any)
              assert.ok(
                !normalize(ip).includes(normalize(cp)),
                `${p.label}: interstitial ${r.name} "${ip}" is shadowed by "${cp}"`,
              );
      }
    assert.ok(GMAIL_SIGNIN.interstitials.length > 0);
  });
  it("dismiss an interstitial only through a control that declines it", () => {
    for (const c of SKIP_CONTROLS)
      assert.doesNotMatch(
        c,
        /save|next|continue|confirm|done|yes|ok|add|update|create|verify/i,
        c,
      );
    assert.ok(SKIP_CONTROLS.includes("Skip"));
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
    assert.ok(
      YAHOO_SIGNIN.addressField.test("Username, email or phone number"),
    );
    assert.ok(!GMAIL_SIGNIN.addressField.test("Address and search bar"));
    assert.ok(!YAHOO_SIGNIN.addressField.test("Address and search bar"));
    assert.ok(!OUTLOOK_SIGNIN.addressField.test("Address and search bar"));
  });
});

describe("privacy-consent pages, by address", () => {
  // As measured 2026-10-28: Chrome's bar shows the address without its
  // scheme; the page is in Bulgarian although the browser asked for en-US.
  const CONSENT_URL =
    "consent.yahoo.com/mailbox/collectConsent?sessionId=3_cc-session_85bc0201";
  const consentPage = (bar = CONSENT_URL) =>
    [
      "Welcome to Mail!\nx\n+",
      bar,
      "yahoo!",
      "Актуализирайте настройките си за поверителност, за да се възползвате максимално от имейлите си",
      "Използване на информация от всички имейли",
      "Отхвърляне Разрешаване",
      "Продължаване",
    ].join("\n");

  it("reads the address bar's value: host and the rest, scheme or none", () => {
    assert.deepEqual(splitLocation(CONSENT_URL), {
      host: "consent.yahoo.com",
      rest: "/mailbox/collectconsent?sessionid=3_cc-session_85bc0201",
    });
    assert.deepEqual(splitLocation("https://Consent.Yahoo.com/v2/x"), {
      host: "consent.yahoo.com",
      rest: "/v2/x",
    });
    assert.equal(splitLocation("two words"), null);
  });

  it("reads the host without its port, and nothing else after the host as part of it", () => {
    assert.deepEqual(
      splitLocation("consent.localhost:41234/collectConsent?x=1"),
      {
        host: "consent.localhost",
        rest: "/collectconsent?x=1",
      },
    );
    assert.deepEqual(splitLocation("http://consent.yahoo.com:8080"), {
      host: "consent.yahoo.com",
      rest: "",
    });
    // Not an address of the consent host at all.
    assert.equal(splitLocation("consent.yahoo.com:evil/x"), null);
    assert.equal(splitLocation("consent.yahoo.com@example.net/x"), null);
    // So a consent host on another port is the consent page ...
    assert.equal(
      kind(
        YAHOO_SIGNIN,
        consentPage(),
        "consent.yahoo.com:8443/v2/collectConsent",
      ),
      "consent:yahoo-consent",
    );
    // ... and one that only starts like it is not.
    assert.equal(
      kind(
        YAHOO_SIGNIN,
        consentPage(),
        "consent.yahoo.com@example.net/collectConsent",
      ),
      "unknown",
    );
  });

  it("recognises Yahoo's consent page by the address the browser reports, in any language", () => {
    for (const p of [YAHOO_SIGNIN, AOL_SIGNIN]) {
      assert.equal(
        kind(p, consentPage(), `https://${CONSENT_URL}`),
        "consent:yahoo-consent",
      );
      // The cookie consent's address too.
      assert.equal(
        kind(
          p,
          consentPage(),
          "consent.yahoo.com/v2/collectConsent?sessionId=1",
        ),
        "consent:yahoo-consent",
      );
      assert.equal(
        kind(p, consentPage(), "guce.aol.com/consent?x=1"),
        "consent:yahoo-consent",
      );
    }
  });

  it("without the browser's address, needs the OCR text to name the host and the path", () => {
    assert.equal(kind(YAHOO_SIGNIN, consentPage()), "consent:yahoo-consent");
    assert.equal(
      kind(YAHOO_SIGNIN, consentPage(), null),
      "consent:yahoo-consent",
    );
    // The host alone (a page that mentions it) is not enough.
    assert.equal(
      kind(YAHOO_SIGNIN, consentPage("consent.yahoo.com")),
      "unknown",
    );
  });

  it("takes the browser's address over the OCR text: another address is not the consent page", () => {
    assert.equal(
      kind(YAHOO_SIGNIN, consentPage(), "mail.yahoo.com/n/inbox"),
      "unknown",
    );
    // A consent host with another path is not the consent page either.
    assert.equal(
      kind(YAHOO_SIGNIN, consentPage(), "consent.yahoo.com/help"),
      "unknown",
    );
    // A look-alike host is not one of the provider's.
    assert.equal(
      kind(
        YAHOO_SIGNIN,
        consentPage(),
        "consent.yahoo.com.example.net/collectConsent",
      ),
      "unknown",
    );
  });

  it("is looked for only when the OCR text names a consent host", () => {
    assert.equal(consentHinted(YAHOO_SIGNIN, consentPage()), true);
    assert.equal(
      consentHinted(YAHOO_SIGNIN, screen("Sign in to Yahoo Mail")),
      false,
    );
    assert.equal(consentHinted(OUTLOOK_SIGNIN, consentPage()), false);
  });

  it("is hinted whatever punctuation and port OCR keeps of the host (measured: 'consentlocalhost33875')", () => {
    const loopback: ProviderSignin = {
      ...YAHOO_SIGNIN,
      consent: { name: "loopback", hosts: ["consent.localhost"], paths: [""] },
    };
    // As OCR read Chrome's address bar on consent.localhost:33875.
    const seen = screen(
      "G @ consentlocalhost33875/collectConsent?sessionld=x",
      "OTxBbpnsiHe O PaspeluaBaHe",
    );
    assert.equal(consentHinted(loopback, seen), true);
    assert.equal(
      consentHinted(YAHOO_SIGNIN, screen("consentyahoo com:443/v2")),
      true,
    );
    // A hint only: the address bar decides.
    assert.equal(
      kind(
        loopback,
        seen,
        "consent.localhost:33875/collectConsent?sessionId=x",
      ),
      "consent:loopback",
    );
    assert.equal(kind(loopback, seen, "mail.localhost:33875/x"), "unknown");
    assert.equal(
      consentHinted(loopback, screen("Sign in", "localhost")),
      false,
    );
  });

  it("lets a challenge on a consent page win", () => {
    assert.equal(
      kind(YAHOO_SIGNIN, `${consentPage()}\nAre you a robot?`, CONSENT_URL),
      "challenge:captcha",
    );
    assert.equal(
      kind(
        YAHOO_SIGNIN,
        `${consentPage()}\nEnter the code we sent`,
        CONSENT_URL,
      ),
      "challenge:code-verification",
    );
  });

  it("is not a consent page for a provider without one, and not the mailbox while on one", () => {
    assert.equal(kind(OUTLOOK_SIGNIN, consentPage(), CONSENT_URL), "unknown");
    // A blurred mailbox behind the consent dialog read by OCR is not done.
    assert.equal(
      kind(YAHOO_SIGNIN, `${consentPage()}\nCompose\nInbox`, CONSENT_URL),
      "consent:yahoo-consent",
    );
    assert.equal(
      kind(
        GMAIL_SIGNIN,
        "consent.google.com/ml?continue=x\nBefore you continue to Google\nReject all\nAccept all",
        "consent.google.com/ml?continue=x",
      ),
      "consent:google-consent",
    );
  });

  it("lists, per language, only controls that reject or go on, never one that accepts", () => {
    const never = CONSENT_CONTROLS.never.map(normalize);
    const acceptWords =
      /accept|allow all|agree|приема|разрешаване на всички|съглас/i;
    for (const list of [
      CONSENT_CONTROLS.rejectAll,
      CONSENT_CONTROLS.reject,
      CONSENT_CONTROLS.save,
      CONSENT_CONTROLS.proceed,
    ])
      for (const c of list) {
        assert.ok(!never.includes(normalize(c)), c);
        assert.doesNotMatch(c, acceptWords, c);
        for (const n of never)
          assert.ok(!normalize(c).includes(n), `${c} contains ${n}`);
      }
    for (const c of CONSENT_CONTROLS.never) assert.match(c, acceptWords, c);
    // English and Bulgarian, each with every kind of control.
    for (const list of Object.values(CONSENT_CONTROLS)) {
      assert.ok(
        list.some((c) => /^[\x20-\x7e]+$/.test(c)),
        list.join(),
      );
      assert.ok(
        list.some((c) => /[а-я]/i.test(c)),
        list.join(),
      );
    }
  });
});

describe("Google's password re-verification", () => {
  const g = GMAIL_SIGNIN;
  it("is the reauth-password step: 'verify it's you' with only a password field", () => {
    for (const text of [
      "Verify it's you\nqa.tester@example.com\nEnter your password\nShow password\nForgot password?\nNext",
      "Hi QA\nqa.tester@example.com\nTo continue, first verify it’s you\nEnter your password\nNext",
      "Verify it's you\nTo help keep your account safe, Google wants to make sure it's really you trying to sign in\nEnter your password\nTry another way\nNext",
    ])
      assert.equal(kind(g, screen(text)), "step:reauth-password", text);
  });

  it("stays a challenge with any other challenge on it, or without a password field", () => {
    const cases: [string, string][] = [
      [
        "Verify it's you\nEnter your password\nGet a verification code at (•••) •••-••12",
        "challenge:code-verification",
      ],
      [
        "Verify it's you\nEnter your password\nCheck your phone\nTap Yes on the notification",
        "challenge:app-approval",
      ],
      [
        "Verify it's you\nEnter your password\nConfirm you're not a robot",
        "challenge:captcha",
      ],
      [
        "Verify it's you\n2-Step Verification\nEnter your password",
        "challenge:verify-identity",
      ],
      [
        "Verify it's you\nTo help keep your account safe, Google wants to make sure it's really you",
        "challenge:verify-identity",
      ],
    ];
    for (const [text, want] of cases)
      assert.equal(kind(g, screen(text)), want, text);
  });

  it("gives way to a wrong password on it, and to the mailbox", () => {
    assert.equal(
      kind(
        g,
        screen(
          "Verify it's you\nEnter your password\nWrong password. Try again or click Forgot password to reset it.",
        ),
      ),
      "error:wrong-password",
    );
    assert.equal(
      kind(g, screen("Compose\nInbox\nverify it's you\nenter your password")),
      "done",
    );
  });

  it("is Gmail's only: other providers keep 'verify it's you' a challenge", () => {
    for (const p of [YAHOO_SIGNIN, OUTLOOK_SIGNIN])
      assert.equal(
        kind(p, screen("Verify it's you\nEnter your password")),
        "challenge:verify-identity",
        p.label,
      );
  });
});

describe("Google's sign-in-again page", () => {
  const g = GMAIL_SIGNIN;
  // The page measured on 2026-10-29 (the address bar's value as Chrome
  // shows it, without the scheme; an invented address on the chip).
  const AGAIN_AT =
    "accounts.google.com/v3/signin/confirmidentifier?continue=https://mail.google.com/mail/u/0/&hl=en&service=mail&flowName=GlifWebSignIn&flowEntry=ServiceLogin";
  const again = (...extra: string[]): string =>
    [
      "Gmail\nx\n+",
      `${AGAIN_AT.slice(0, 120)}…`,
      "G",
      "Verify it’s you",
      "S qa.tester@example.com",
      "To help keep your account secure, Google needs to verify",
      "it’s you. Please sign in again to continue to Gmail.",
      ...extra,
      "Next",
      "English (United States)",
      "Help Privacy Terms",
    ].join("\n");

  it("is the sign-in-again step on its address with its wording, by the address bar or by the OCR text alone", () => {
    assert.equal(kind(g, again(), AGAIN_AT), "step:sign-in-again");
    assert.equal(kind(g, again(), `https://${AGAIN_AT}`), "step:sign-in-again");
    // No address from the tree: the address bar as OCR read it.
    assert.equal(kind(g, again()), "step:sign-in-again");
    assert.equal(kind(g, again(), undefined), "step:sign-in-again");
    assert.ok(signInAgainHinted(g, again()));
  });

  it("is not that step anywhere else: another address, or its address without the wording", () => {
    // The same words on another page of Google's: "verify it's you" is
    // the challenge it always was.
    for (const at of [
      "accounts.google.com/v3/signin/identifier?continue=x",
      "accounts.google.com.example.net/v3/signin/confirmidentifier",
      "evil.example/accounts.google.com/v3/signin/confirmidentifier",
      "accounts.google.com@evil.example/v3/signin/confirmidentifier",
    ])
      assert.equal(kind(g, again(), at), "challenge:verify-identity", at);
    const unworded = again().replace(
      "Please sign in again to continue",
      "Please continue",
    );
    assert.equal(kind(g, unworded, AGAIN_AT), "challenge:verify-identity");
    assert.ok(!signInAgainHinted(g, unworded));
    // A page without the address in its OCR text and no address read.
    assert.equal(
      kind(
        g,
        again().replace(
          /accounts\.google\.com\S*/,
          "accounts.google.com/v3/signin/identifier",
        ),
      ),
      "challenge:verify-identity",
    );
  });

  it("gives way to any challenge or error on it, and to a password field (the re-verification)", () => {
    const cases: [string, string][] = [
      [
        "Get a verification code at (•••) •••-••12",
        "challenge:code-verification",
      ],
      [
        "Check your phone\nTap Yes on the notification",
        "challenge:app-approval",
      ],
      ["Confirm you're not a robot", "challenge:captcha"],
      ["2-Step Verification", "challenge:verify-identity"],
      ["Use your passkey", "challenge:passkey"],
      ["Enter a phone number", "challenge:phone-verification"],
      ["Something unusual happened", "challenge:unusual-activity"],
      ["Couldn't find your Google Account", "error:unknown-account"],
      ["Enter your password", "step:reauth-password"],
    ];
    for (const [extra, want] of cases)
      assert.equal(kind(g, again(extra), AGAIN_AT), want, extra);
  });

  it("is Gmail's only: other providers keep the page a challenge", () => {
    for (const p of [YAHOO_SIGNIN, OUTLOOK_SIGNIN, AOL_SIGNIN]) {
      assert.equal(p.signInAgain, undefined, p.label);
      assert.equal(
        kind(p, again(), AGAIN_AT),
        "challenge:verify-identity",
        p.label,
      );
    }
  });
});

describe("the start URLs ask for English", () => {
  it("Google with hl=en, Yahoo with .lang=en-US", () => {
    assert.equal(new URL(GMAIL_SIGNIN.startUrl).searchParams.get("hl"), "en");
    assert.equal(
      new URL(YAHOO_SIGNIN.startUrl).searchParams.get(".lang"),
      "en-US",
    );
    assert.equal(
      new URL(YAHOO_SIGNIN.startUrl).searchParams.get("done"),
      "https://mail.yahoo.com/",
    );
  });
});
