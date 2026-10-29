// tools/capture/providers/guiassert.ts — a client of GuiAssert's
// command-line contract (guiassert-desktop/1.1,
// https://github.com/metacraft-labs/GuiAssert, its
// Planned-Work/Desktop-Substrate.md §7): every call runs the `guiassert`
// binary once and reads the one JSON envelope it prints on stdout, and
// the process's exit code is the envelope's `error.code`.
//
// Used by the webmail sign-in (email-webmail-signin.ts) to start a
// private off-screen session, read the screen (OCR), find fields in the
// accessibility tree, and send OS-level input (keys, clicks, the wheel).
// Secrets never travel on a command line or in the environment: a
// `Secret` is only ever written to the child's standard input (`type
// --stdin`, `--secret-stdin`), and a `Secret` prints as "[secret]"
// wherever it is formatted by accident.

import { spawn, spawnSync } from "node:child_process";
import { inspect } from "node:util";

/** A value that must not be printed, logged or put on a command line. */
export class Secret {
  readonly #value: string;
  constructor(value: string) {
    this.#value = value;
  }
  /** The value, for a pipe. Never for argv, env, a log or a file. */
  reveal(): string {
    return this.#value;
  }
  get length(): number {
    return this.#value.length;
  }
  toString(): string {
    return "[secret]";
  }
  toJSON(): string {
    return "[secret]";
  }
  [inspect.custom](): string {
    return "[secret]";
  }
}

/** The contract's exit codes (§7.3). */
export const GA_EXIT = {
  ok: 0,
  internal: 1,
  badArgs: 2,
  notFound: 3,
  backendUnavailable: 4,
  backendError: 5,
  permissionDenied: 6,
  timeout: 7,
  cancelled: 8,
} as const;

export interface GaErrorBody {
  code: number;
  kind: string;
  message: string;
  reason: string | null;
  remedy: string | null;
}

export class GuiAssertError extends Error {
  readonly verb: string;
  readonly code: number;
  readonly kind: string;
  readonly reason: string | null;
  readonly remedy: string | null;
  constructor(verb: string, e: GaErrorBody) {
    super(
      `guiassert ${verb}: ${e.kind}${e.reason === null ? "" : `/${e.reason}`}: ${e.message}${e.remedy === null ? "" : ` (${e.remedy})`}`,
    );
    this.name = "GuiAssertError";
    this.verb = verb;
    this.code = e.code;
    this.kind = e.kind;
    this.reason = e.reason;
    this.remedy = e.remedy;
  }
}

export type Rect = [number, number, number, number];

export interface GaSession {
  id: string;
  state: string;
  env: Record<string, string>;
  envUnset: string[];
  vncSocket: string | null;
  displays: { id: string; bounds: Rect; primary: boolean }[];
}

export interface GaImage {
  path: string;
  width: number;
  height: number;
  scale: number;
  origin: [number, number];
}

export interface GaOcrWord {
  text: string;
  confidence: number;
  bbox: Rect;
}

export interface GaOcr {
  image: GaImage;
  words: GaOcrWord[];
  text: string;
}

/** An accessibility node as `find` reports it (§7.5 `Element`). */
export interface GaElement {
  path: string;
  role: string;
  nativeRole: string;
  name: string | null;
  bounds: Rect | null;
  states: string[];
  /** The Value interface's value, or an editable text's content (never a protected field's). */
  value?: string | null;
  /** The Text interface's whole content (never a protected field's). */
  text?: string | null;
}

export interface FindFilter {
  pid?: number;
  role?: string;
  name?: string;
  nameContains?: string;
  ignoreCase?: boolean;
  states?: string[];
  limit?: number;
}

export interface GuiAssertOptions {
  /** The `guiassert` executable. */
  bin: string;
  /** Its state directory (`--state-dir`): sessions are recorded there. */
  stateDir: string;
  /** The environment the binary runs with (never carries a secret). */
  env: Record<string, string | undefined>;
  /** The session the verbs act in (`--session`); `host` when unset. */
  session?: string;
  /** Each verb's deadline (`--timeout-ms`). */
  timeoutMs?: number;
}

interface Envelope {
  ok: boolean;
  verb: string;
  data?: unknown;
  error?: GaErrorBody;
}

function parseEnvelope(verb: string, stdout: string, status: number): unknown {
  const line = stdout.trim().split("\n").pop() ?? "";
  let env: Envelope;
  try {
    env = JSON.parse(line) as Envelope;
  } catch {
    throw new GuiAssertError(verb, {
      code: status,
      kind: "internal",
      message: `exit ${status} without a JSON envelope on stdout`,
      reason: null,
      remedy: null,
    });
  }
  if (env.ok === true) return env.data;
  throw new GuiAssertError(
    verb,
    env.error ?? {
      code: status,
      kind: "internal",
      message: "an envelope without ok or error",
      reason: null,
      remedy: null,
    },
  );
}

export class GuiAssert {
  readonly opts: GuiAssertOptions;
  constructor(opts: GuiAssertOptions) {
    this.opts = opts;
  }

  /** The same client acting in `session`. */
  inSession(session: string): GuiAssert {
    return new GuiAssert({ ...this.opts, session });
  }

  private argv(verb: string, args: string[]): string[] {
    const a = ["--state-dir", this.opts.stateDir, "--contract", "1"];
    if (this.opts.session !== undefined) a.push("--session", this.opts.session);
    if (this.opts.timeoutMs !== undefined)
      a.push("--timeout-ms", String(this.opts.timeoutMs));
    return [...a, verb, ...args];
  }

  /**
   * Runs one verb. `stdin`, when given, is written to the child's
   * standard input and the pipe closed; nothing else reaches it.
   */
  run(verb: string, args: string[], stdin?: Secret | string): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const child = spawn(this.opts.bin, this.argv(verb, args), {
        env: this.opts.env as NodeJS.ProcessEnv,
        stdio: ["pipe", "pipe", "pipe"],
      });
      let out = "";
      let err = "";
      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (d: string) => (out += d));
      child.stderr.on("data", (d: string) => {
        err = (err + d).slice(-4096);
      });
      child.on("error", reject);
      child.on("close", (code, signal) => {
        if (code === null) {
          reject(
            new GuiAssertError(verb, {
              code: 1,
              kind: "internal",
              message: `killed by ${signal}`,
              reason: null,
              remedy: null,
            }),
          );
          return;
        }
        try {
          resolve(parseEnvelope(verb, out, code));
        } catch (e) {
          // GuiAssert keeps captured content off stderr (§7.5), so its
          // tail can name what went wrong when there was no envelope.
          if (
            e instanceof GuiAssertError &&
            e.kind === "internal" &&
            err !== ""
          )
            e.message += `; stderr: ${err.trim().split("\n").slice(-2).join(" | ")}`;
          // Belt and braces: a secret this call piped in never comes
          // back out in an error message, whatever the child printed.
          if (e instanceof Error && stdin instanceof Secret && stdin.length > 0)
            e.message = e.message.split(stdin.reveal()).join("[secret]");
          reject(e);
        }
      });
      // A closed stdin is "no input" to every verb that does not read it.
      child.stdin.on("error", () => undefined);
      if (stdin !== undefined)
        child.stdin.end(stdin instanceof Secret ? stdin.reveal() : stdin);
      else child.stdin.end();
    });
  }

  async sessionStart(o: {
    name: string;
    width: number;
    height: number;
    vncSocket: boolean;
  }): Promise<GaSession> {
    const args = [
      "--kind",
      "headless",
      "--session-backend",
      "linux-xvfb",
      "--name",
      o.name,
      "--width",
      String(o.width),
      "--height",
      String(o.height),
    ];
    if (o.vncSocket) args.push("--vnc-socket");
    const d = (await this.run("session-start", args)) as { session: GaSession };
    return d.session;
  }

  async sessionStop(id: string): Promise<void> {
    await this.run("session-stop", [id]);
  }

  /** session-stop for an exit handler, where nothing may be awaited. */
  sessionStopSync(id: string): void {
    spawnSync(this.opts.bin, this.argv("session-stop", [id]), {
      env: this.opts.env as NodeJS.ProcessEnv,
      stdio: "ignore",
      timeout: 20_000,
    });
  }

  /** OCR of the primary display, guarded against `secret` (exit 5 / `secret-visible`). */
  async ocr(out: string, secret: Secret): Promise<GaOcr> {
    return (await this.run(
      "ocr",
      ["--display", "0", "--out", out, "--secret-stdin"],
      secret,
    )) as GaOcr;
  }

  /** A screenshot of the primary display kept only if `secret` is not legible in it. */
  async screenshot(out: string, secret: Secret): Promise<GaImage> {
    const d = (await this.run(
      "screenshot",
      ["--display", "0", "--out", out, "--secret-stdin"],
      secret,
    )) as { image: GaImage };
    return d.image;
  }

  async find(f: FindFilter): Promise<GaElement[]> {
    const args: string[] = [];
    if (f.pid !== undefined) args.push("--pid", String(f.pid));
    if (f.role !== undefined) args.push("--role", f.role);
    if (f.name !== undefined) args.push("--name", f.name);
    if (f.nameContains !== undefined)
      args.push("--name-contains", f.nameContains);
    if (f.ignoreCase === true) args.push("--ignore-case");
    for (const s of f.states ?? []) args.push("--state", s);
    if (f.limit !== undefined) args.push("--limit", String(f.limit));
    const d = (await this.run("find", args)) as { elements: GaElement[] };
    return d.elements;
  }

  async click(x: number, y: number): Promise<void> {
    await this.run("click", ["--at", `${Math.round(x)},${Math.round(y)}`]);
  }

  /** Scrolls the wheel at (x, y) by `dy` lines (positive: down). */
  async scroll(x: number, y: number, dy: number): Promise<void> {
    await this.run("scroll", [
      "--at",
      `${Math.round(x)},${Math.round(y)}`,
      "--dx",
      "0",
      "--dy",
      String(dy),
      "--unit",
      "line",
    ]);
  }

  /** Types `text` through OS-level input; it is read from stdin, never argv. */
  async type(text: Secret | string): Promise<void> {
    await this.run("type", ["--stdin"], text);
  }

  async key(combo: string): Promise<void> {
    await this.run("key", [combo]);
  }
}

/** The environment a process started into `s` gets (§6.1). */
export function sessionEnv(
  base: Record<string, string | undefined>,
  s: GaSession,
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(base))
    if (v !== undefined && !s.envUnset.includes(k)) env[k] = v;
  return { ...env, ...s.env };
}
