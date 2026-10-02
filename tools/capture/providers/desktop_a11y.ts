// tools/capture/providers/desktop_a11y.ts — the accessibility side of
// the linux-desktop provider: what the drivers of clients without a
// remote-control protocol of their own (Evolution, Geary, KMail, Claws
// Mail) use to read a client's widget geometry and press its buttons.
//
// The session's accessibility bus is started inside the session
// (at-spi-bus-launcher, before the client, so the client's toolkit
// registers with it); the client side is atspi_helper.py, a Python
// process with the AT-SPI library running outside the session against
// the session's own bus, spoken to in JSON lines. Extents are
// window-relative, which is output-relative for a fullscreen window.

import { spawn, type ChildProcess } from "node:child_process";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import type { DesktopSession, Rect } from "./desktop_session.ts";
import { currentHost, findExecutable } from "./requirements.ts";
import type { Requirement } from "./types.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const HELPER = join(scriptDir, "atspi_helper.py");
export const ATSPI_PYTHON = "isonim-email-atspi";

export const A11Y_REQUIREMENTS: Requirement[] = [
  {
    kind: "binary",
    name: ATSPI_PYTHON,
    why: "the accessibility client the driver reads the client's widgets through (the dev shell provides it)",
  },
  {
    kind: "binary",
    name: "at-spi-bus-launcher",
    why: "the session's accessibility bus (the dev shell provides it)",
  },
];

export interface A11yNode {
  path: number[];
  role: string;
  name: string;
  extents: Rect | null;
  states: string[];
  actions: string[];
  text: string | null;
  // The window first, the node's parent last.
  ancestors: {
    role: string;
    name: string;
    extents: Rect | null;
    path: number[];
  }[];
}

export interface A11yQuery {
  // The application's accessible name (e.g. "geary", "kmail2").
  app?: string;
  // A pattern the toplevel window's accessible name must match.
  window?: string;
  role?: string | string[];
  name?: string;
  nameRe?: string;
  showing?: boolean;
  // Roles whose subtrees are not searched (menus, say).
  prune?: string[];
  limit?: number;
}

export class A11yClient {
  private readonly child: ChildProcess;
  private readonly waiting: ((line: string) => void)[] = [];
  private closed = false;
  private stderr = "";

  private constructor(child: ChildProcess) {
    this.child = child;
    const rl = createInterface({ input: child.stdout! });
    rl.on("line", (line) => this.waiting.shift()?.(line));
    child.stderr!.on("data", (d: Buffer) => {
      this.stderr = (this.stderr + d.toString()).slice(-2000);
    });
    child.once("exit", () => {
      this.closed = true;
      for (const w of this.waiting.splice(0))
        w(
          JSON.stringify({ ok: false, error: `helper exited: ${this.stderr}` }),
        );
    });
  }

  // Starts the session's accessibility bus (if not yet) and a client
  // connected to it; resolves once the bus is up.
  static async start(session: DesktopSession): Promise<A11yClient> {
    const py = findExecutable(ATSPI_PYTHON, currentHost());
    if (py === null)
      throw new Error(
        `${ATSPI_PYTHON} is not on PATH (run inside the dev shell)`,
      );
    if (!session.hasLaunched("a11y-bus"))
      session.launch("a11y-bus", [
        "at-spi-bus-launcher",
        "--launch-immediately",
      ]);
    const child = spawn(py, [HELPER], {
      env: {
        PATH: process.env.PATH ?? "",
        DBUS_SESSION_BUS_ADDRESS: session.busAddress(),
        XDG_RUNTIME_DIR: session.runtimeDir,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    const c = new A11yClient(child);
    await c.waitName("org.a11y.Bus", 15000);
    return c;
  }

  async request(req: Record<string, unknown>): Promise<unknown> {
    if (this.closed) throw new Error(`a11y helper is gone: ${this.stderr}`);
    const line = await new Promise<string>((ok) => {
      this.waiting.push(ok);
      this.child.stdin!.write(JSON.stringify(req) + "\n");
    });
    const ans = JSON.parse(line) as {
      ok: boolean;
      result?: unknown;
      error?: string;
    };
    if (!ans.ok) throw new Error(`a11y ${String(req.op)}: ${ans.error}`);
    return ans.result;
  }

  async find(q: A11yQuery): Promise<A11yNode[]> {
    return (await this.request({
      op: "find",
      app: q.app,
      window: q.window,
      role: q.role,
      name: q.name,
      name_re: q.nameRe,
      showing: q.showing,
      prune: q.prune,
      limit: q.limit,
    })) as A11yNode[];
  }

  // The first node matching `q`, once there is one.
  async waitFor(
    q: A11yQuery,
    what: string,
    timeoutMs: number,
  ): Promise<A11yNode> {
    const t0 = Date.now();
    for (;;) {
      const [n] = await this.find({ ...q, limit: 1 });
      if (n !== undefined) return n;
      if (Date.now() - t0 > timeoutMs)
        throw new Error(`no ${what} within ${timeoutMs / 1000} s`);
      await new Promise((r) => setTimeout(r, 50));
    }
  }

  // Runs the node's action; true when the toolkit says it performed it
  // (GTK refuses, answering false, an action on an insensitive widget).
  async act(node: A11yNode, action?: string): Promise<boolean> {
    return (
      (await this.request({ op: "act", path: node.path, action })) === true
    );
  }

  // The names of an app's top-level windows as the app reports them now:
  // a window is listed as soon as the app created it, before the
  // compositor shows it.
  async windows(app: string): Promise<string[]> {
    return (await this.request({ op: "windows", app })) as string[];
  }

  async focus(node: A11yNode): Promise<void> {
    await this.request({ op: "focus", path: node.path });
  }

  async waitName(name: string, timeoutMs: number): Promise<void> {
    await this.request({ op: "wait_name", name, timeout_ms: timeoutMs });
  }

  // A method call on the session bus; `args` in GVariant text form.
  async dbusCall(c: {
    dest: string;
    path: string;
    iface: string;
    method: string;
    args?: string;
  }): Promise<unknown> {
    return this.request({ op: "dbus_call", ...c });
  }

  async setText(node: A11yNode, text: string): Promise<void> {
    await this.request({ op: "set_text", path: node.path, text });
  }

  async sql(
    db: string,
    sql: string,
    params: unknown[] = [],
  ): Promise<unknown[][]> {
    return (await this.request({ op: "sql", db, sql, params })) as unknown[][];
  }

  close(): void {
    this.child.stdin?.end();
    this.child.kill("SIGKILL");
  }
}

// Answers a client's password prompt: the prompt's password field gets
// the password (written through the accessibility tree, never typed or
// echoed), then its confirming button is pressed. Returns false when
// no prompt is showing, or when the toolkit refused the press (the
// button not yet sensitive): the caller asks again.
export async function answerPasswordPrompt(
  a11y: A11yClient,
  app: string,
  password: string,
  button: string,
): Promise<boolean> {
  const [field] = await a11y.find({ app, role: "password text", limit: 1 });
  if (field === undefined) return false;
  await a11y.setText(field, password);
  const [ok] = await a11y.find({
    app,
    role: ["button", "push button"],
    name: button,
    limit: 1,
  });
  if (ok === undefined)
    throw new Error(`${app}: the password prompt has no '${button}' button`);
  return a11y.act(ok);
}

// Whether the client's chrome is dark, from the pixels of a region of
// the window (output-logical pixels): the evidence for a scheme a client
// applies through its toolkit's theme, which it cannot report itself.
export function chromeScheme(
  session: DesktopSession,
  region: Rect,
): { dark: boolean; evidence: Record<string, unknown> } {
  const img = session.screenshot();
  const s = session.output.scale;
  const x0 = Math.max(0, Math.round(region.x * s));
  const y0 = Math.max(0, Math.round(region.y * s));
  const x1 = Math.min(img.width, Math.round((region.x + region.width) * s));
  const y1 = Math.min(img.height, Math.round((region.y + region.height) * s));
  let sum = 0;
  let n = 0;
  for (let y = y0; y < y1; y++)
    for (let x = x0; x < x1; x++) {
      const i = (y * img.width + x) * 4;
      sum +=
        0.2126 * img.data[i]! +
        0.7152 * img.data[i + 1]! +
        0.0722 * img.data[i + 2]!;
      n++;
    }
  const luminance = n === 0 ? 255 : sum / n;
  return {
    dark: luminance < 110,
    evidence: {
      chrome_region: region,
      chrome_luminance: Math.round(luminance * 10) / 10,
    },
  };
}
