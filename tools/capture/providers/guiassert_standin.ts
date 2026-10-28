// tools/capture/providers/guiassert_standin.ts — a stand-in `guiassert`
// binary for the webmail sign-in's tests (webmail_signin.test.ts).
//
// Why a stand-in (the repository's mock policy): the real GuiAssert is
// exercised against a real browser in webmail_signin_session.test.ts,
// but the screens the procedure must react to (each provider's sign-in
// pages, every challenge, a password that shows on the screen, a page
// that never moves on) belong to the real providers, which a test must
// never sign in to. This stand-in speaks the same command-line contract
// (guiassert-desktop/1.1: one JSON envelope on stdout, the exit code its
// error.code; `session-start`, `session-stop`, `ocr` and `screenshot`
// with `--secret-stdin`, `find`, `click`, `type --stdin`, `key`) over a
// scripted desktop, and records every invocation, so a test can see
// every argument, environment and standard input the procedure handed
// to it.
//
// Run as `node guiassert_standin.ts <guiassert arguments>` (the tests
// put a `guiassert` wrapper on PATH). The scenario is the JSON file
// named by GUIASSERT_STANDIN_SCENARIO; the simulated desktop's state
// and the invocation log (`standin-log.jsonl`) live in `--state-dir`.
//
// The simulated desktop: one screen at a time; its OCR text is the
// screen's `text` plus the value of every field (a protected field shows
// one "•" per character unless the screen reveals it); `click --at`
// inside a field focuses it, inside a button moves to the button's next
// screen; `type --stdin` appends to the focused field; `key Return`
// moves to the screen's `submit` (optionally depending on a field's
// value). A frame written by `ocr` / `screenshot` is a text file holding
// what the simulated display shows, so a test can look into it.

import {
  appendFileSync,
  existsSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

type Rect = [number, number, number, number];

export interface StandinField {
  name: string;
  protected?: boolean;
  bounds: Rect;
}

export interface StandinButton {
  name: string;
  role?: string;
  bounds: Rect;
  next: string;
}

export type StandinSubmit =
  | string
  | { field: string; equals: string; then: string; else: string };

export interface StandinScreen {
  text: string;
  fields?: StandinField[];
  buttons?: StandinButton[];
  /** The field that has the focus when the screen shows. */
  focus?: string;
  /** Where Return goes. */
  submit?: StandinSubmit;
  /** Protected fields show their value in clear (a "show password" toggle). */
  revealPassword?: boolean;
}

export interface StandinScenario {
  start: string;
  screens: Record<string, StandinScreen>;
}

export interface StandinLogEntry {
  verb: string;
  argv: string[];
  env: Record<string, string>;
  /** What the call read on stdin; null when it reads none. */
  stdin: string | null;
  /** The screen shown when the call ran, and the focused field. */
  screen: string;
  focused: string | null;
}

interface State {
  screen: string;
  focused: string | null;
  values: Record<string, string>;
  sessions: Record<string, { state: string; vncSocket: string | null }>;
}

function out(verb: string, data: unknown): number {
  process.stdout.write(`${JSON.stringify({ ok: true, verb, data })}\n`);
  return 0;
}

function fail(
  verb: string,
  code: number,
  kind: string,
  reason: string | null,
  message: string,
): number {
  process.stdout.write(
    `${JSON.stringify({
      ok: false,
      verb,
      error: { code, kind, message, reason, remedy: null, details: null },
    })}\n`,
  );
  return code;
}

const inside = (b: Rect, x: number, y: number): boolean =>
  x >= b[0] && x < b[0] + b[2] && y >= b[1] && y < b[1] + b[3];

export function main(argv: string[]): number {
  // Global flags, then the verb and its flags (the CLI's own order).
  const flags = new Map<string, string[]>();
  const positional: string[] = [];
  const booleans = new Set([
    "--vnc-socket",
    "--vnc",
    "--secret-stdin",
    "--stdin",
    "--ignore-case",
    "--force",
  ]);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a.startsWith("--")) {
      if (booleans.has(a)) flags.set(a, [...(flags.get(a) ?? []), ""]);
      else flags.set(a, [...(flags.get(a) ?? []), argv[++i] ?? ""]);
    } else positional.push(a);
  }
  const flag = (n: string): string | undefined => flags.get(n)?.[0];
  const verb = positional[0] ?? "";
  const stateDir = flag("--state-dir");
  const scenarioPath = process.env.GUIASSERT_STANDIN_SCENARIO;
  if (stateDir === undefined || scenarioPath === undefined)
    return fail(
      verb,
      2,
      "bad-args",
      "missing-argument",
      "the stand-in needs --state-dir and GUIASSERT_STANDIN_SCENARIO",
    );
  const scenario = JSON.parse(
    readFileSync(scenarioPath, "utf8"),
  ) as StandinScenario;
  const statePath = join(stateDir, "standin-state.json");
  const state: State = existsSync(statePath)
    ? (JSON.parse(readFileSync(statePath, "utf8")) as State)
    : {
        screen: scenario.start,
        focused: scenario.screens[scenario.start]?.focus ?? null,
        values: {},
        sessions: {},
      };
  const screen = (): StandinScreen => {
    const s = scenario.screens[state.screen];
    if (s === undefined) throw new Error(`no screen ${state.screen}`);
    return s;
  };
  const show = (id: string): void => {
    state.screen = id;
    state.focused = scenario.screens[id]?.focus ?? null;
  };

  const readsStdin = flags.has("--secret-stdin") || flags.has("--stdin");
  const stdin = readsStdin ? readFileSync(0, "utf8") : null;
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env))
    if (v !== undefined) env[k] = v;
  const entry: StandinLogEntry = {
    verb,
    argv,
    env,
    stdin,
    screen: state.screen,
    focused: state.focused,
  };
  appendFileSync(
    join(stateDir, "standin-log.jsonl"),
    `${JSON.stringify(entry)}\n`,
  );

  const injected = (process.env.GUIASSERT_STANDIN_FAIL ?? "")
    .split(",")
    .map((x) => x.split(":"))
    .find((x) => x[0] === verb);
  if (injected !== undefined)
    return fail(
      verb,
      Number(injected[1]),
      "backend-error",
      injected[2] ?? null,
      "injected failure",
    );

  const display = (): string => {
    const s = screen();
    const values = (s.fields ?? []).map((f) => {
      const v = state.values[`${state.screen}/${f.name}`] ?? "";
      return f.protected === true && s.revealPassword !== true
        ? "•".repeat(v.length)
        : v;
    });
    return [s.text, ...values].join("\n");
  };
  const guard = (): number | null => {
    const secret = flags.has("--secret-stdin") ? (stdin ?? "") : null;
    if (secret !== null && secret.length > 0 && display().includes(secret))
      return fail(
        verb,
        5,
        "backend-error",
        "secret-visible",
        "the secret given on --secret-stdin is legible in the frame",
      );
    return null;
  };
  const save = (): void => writeFileSync(statePath, JSON.stringify(state));

  let code: number;
  switch (verb) {
    case "session-start": {
      const id = flag("--name") ?? "standin";
      const vncSocket = flags.has("--vnc-socket")
        ? join(stateDir, `${id}.vnc.sock`)
        : null;
      state.sessions[id] = { state: "running", vncSocket };
      code = out(verb, {
        session: {
          id,
          state: "running",
          env: { DISPLAY: ":standin", GUIASSERT_SESSION: id },
          envUnset: ["WAYLAND_DISPLAY"],
          vncSocket,
          displays: [{ id: "0", bounds: [0, 0, 1280, 900], primary: true }],
        },
      });
      break;
    }
    case "session-stop": {
      const id = positional[1] ?? "";
      const s = state.sessions[id];
      if (s !== undefined) s.state = "stopped";
      code = out(verb, { session: { id, state: "stopped" } });
      break;
    }
    case "ocr":
    case "screenshot": {
      const refused = guard();
      if (refused !== null) {
        code = refused;
        break;
      }
      const path = flag("--out") ?? "";
      writeFileSync(path, display());
      const image = {
        path,
        format: "png",
        width: 1280,
        height: 900,
        scale: 1,
        origin: [0, 0],
      };
      code =
        verb === "ocr"
          ? out(verb, {
              image,
              backend: "standin",
              languages: ["eng"],
              words: [],
              text: display(),
            })
          : out(verb, { image });
      break;
    }
    case "find": {
      const s = screen();
      const role = flag("--role");
      const name = flag("--name");
      const contains = flag("--name-contains");
      const ic = flags.has("--ignore-case");
      const states = flags.get("--state") ?? [];
      const els = [
        ...(s.fields ?? []).map((f, i) => ({
          path: `/app[1]/text-field[${i}]`,
          role: "text-field",
          nativeRole: f.protected === true ? "password text" : "entry",
          name: f.name,
          bounds: f.bounds,
          states: [
            "focusable",
            "enabled",
            "editable",
            "visible",
            ...(f.protected === true ? ["protected"] : []),
            ...(state.focused === f.name ? ["focused"] : []),
          ],
        })),
        ...(s.buttons ?? []).map((b, i) => ({
          path: `/app[1]/${b.role ?? "button"}[${i}]`,
          role: b.role ?? "button",
          nativeRole: "push button",
          name: b.name,
          bounds: b.bounds,
          states: ["focusable", "enabled", "visible"],
        })),
      ].filter(
        (e) =>
          (role === undefined || e.role === role) &&
          (name === undefined ||
            (ic
              ? e.name.toLowerCase() === name.toLowerCase()
              : e.name === name)) &&
          (contains === undefined ||
            (ic
              ? e.name.toLowerCase().includes(contains.toLowerCase())
              : e.name.includes(contains))) &&
          states.every((st) => e.states.includes(st)),
      );
      code = out(verb, { elements: els, truncated: false });
      break;
    }
    case "click": {
      const [x, y] = (flag("--at") ?? "0,0").split(",").map(Number) as [
        number,
        number,
      ];
      const s = screen();
      const field = (s.fields ?? []).find((f) => inside(f.bounds, x, y));
      const button = (s.buttons ?? []).find((b) => inside(b.bounds, x, y));
      if (field !== undefined) state.focused = field.name;
      else if (button !== undefined) show(button.next);
      else state.focused = null;
      code = out(verb, { input: { kind: "click", at: [x, y] } });
      break;
    }
    case "type": {
      if (state.focused !== null) {
        const k = `${state.screen}/${state.focused}`;
        state.values[k] =
          (state.values[k] ?? "") + (stdin ?? positional[1] ?? "");
      }
      code = out(verb, {
        input: { kind: "type", length: (stdin ?? "").length },
      });
      break;
    }
    case "key": {
      const s = screen();
      if (positional[1] === "Return" && s.submit !== undefined) {
        const sub = s.submit;
        if (typeof sub === "string") show(sub);
        else
          show(
            (state.values[`${state.screen}/${sub.field}`] ?? "") === sub.equals
              ? sub.then
              : sub.else,
          );
      }
      code = out(verb, { input: { kind: "key", keys: positional[1] ?? "" } });
      break;
    }
    default:
      code = fail(
        verb,
        2,
        "bad-args",
        "unknown-verb",
        `the stand-in has no verb ${verb}`,
      );
  }
  save();
  return code;
}

if (
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href
)
  process.exitCode = main(process.argv.slice(2));
