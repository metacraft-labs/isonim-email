// tools/preview/server.ts — `just email-preview`: a local preview server
// for the registered stories.
//
// It builds the story driver (tools/capture/build_stories.nim, the same
// driver the captures use) into a directory of its own, runs it in its
// `--preview` mode over every registered story (the reference emails, the
// layout and element sets and the capture fixtures included:
// ISONIM_CAPTURE_LAYOUT=1 and ISONIM_CAPTURE_FIXTURES=1), and serves:
//
//   GET /                         the preview page (ui.html)
//   GET /api/stories              the build's status and the story list,
//                                 each story with its diagnostic counts
//   GET /api/story?story=S        one story: its diagnostics (with their
//                                 source spans), its error if refused
//   GET /render?story=S&family=F&images=on|off&scheme=light|dark
//                                 the story's HTML through the emulation
//                                 transforms of family F (the capture's
//                                 tools/capture/transforms.ts chain), its
//                                 fixture-host image URLs pointed at this
//                                 server, and prefers-color-scheme emulated
//   GET /text?story=S             the plain-text part
//   GET /shot?story=S&family=F&images=on|off&width=W
//                                 a PNG of the story in the pinned Chromium
//                                 under Blink's automatic dark mode (forced
//                                 dark, which only a browser launch switch
//                                 turns on, so it cannot be an iframe)
//   GET /source?file=PATH&line=N  a source file under the root, its lines
//                                 numbered and anchored (#L<n>), for the
//                                 diagnostics' file:line links
//   GET /x.test/<hash>/<name>     the fixture host's images
//                                 (tools/capture/fixture_host.ts)
//   GET /events                   server-sent events: `status` on every
//                                 build start and end (with the build's
//                                 generation), which the page reloads on
//
// Reload on change: src/, examples/ and tests/stories/ under the root are
// watched; a change rebuilds the driver (an incremental `nim c`), re-runs
// it and pushes the new generation. A build that fails keeps serving the
// last good stories and sends the compiler's output to the page.
//
// The dark scheme is emulated in the HTML, not asked of the viewer's
// browser (an iframe's prefers-color-scheme follows the viewer's own
// setting): each `(prefers-color-scheme: dark)` / `(… light)` media
// feature is replaced by one that always or never matches, and the
// message's used color-scheme is pinned to the scheme asked for when the
// message declares it supports it (a `color-scheme` meta naming it), to
// light otherwise.
//
// Bound to 127.0.0.1 only. Nothing is fetched from the network; the page
// has no third-party dependency.

import { type ChildProcess, spawn } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  watch,
  type FSWatcher,
} from "node:fs";
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import type { AddressInfo } from "node:net";
import { dirname, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import type { Browser } from "playwright-core";
import {
  FIXTURE_HOST,
  installCapturePolicy,
  resolveFixture,
  firstFrameGif,
} from "../capture/fixture_host.ts";
import { launchOptions } from "../capture/launch.ts";
import { resolveDriver } from "../capture/providers/browser_emulation.ts";
import {
  TRANSFORMS,
  applyChain,
  transformChain,
} from "../capture/transforms.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");

/** The families whose transform the page offers, in its order. "" is
 *  the message as authored. */
export const FAMILIES = ["", ...Object.keys(TRANSFORMS)];

export const VIEWPORTS: Record<string, number> = {
  "320": 320,
  mobile: 375,
  desktop: 800,
};

export interface Diagnostic {
  severity: string;
  code: string;
  message: string;
  file: string;
  line: number;
  col: number;
  rules: string[];
}

export interface StoryEntry {
  story: string;
  group: string;
  description: string;
  diagnostics: Diagnostic[];
  error?: string;
  html?: string;
  text?: string;
}

export interface BuildStatus {
  /** "building" while a build runs, then "ok" or "failed". */
  state: "building" | "ok" | "failed";
  /** Bumped by every build that produced stories. */
  generation: number;
  /** The failed build's output (compiler or driver), else "". */
  log: string;
  /** When the current stories were built (ISO time), "" before any. */
  builtAt: string;
}

export interface PreviewOptions {
  /** The checkout whose stories are built and watched. */
  root: string;
  /** Where the driver, its nimcache and the builds go. */
  out: string;
  /** 0 picks a free port. */
  port: number;
  /** The Tailwind map the driver compiles against. */
  tailwindMap: string;
  /** Regenerate the Tailwind map before each build. */
  tailwind: boolean;
  /** Watch the sources and rebuild on change. */
  watch: boolean;
  /** Debounce of a burst of changes, ms. */
  debounceMs: number;
  /** Progress lines (default: none). */
  log?: (line: string) => void;
}

export interface PreviewServer {
  url: string;
  status(): BuildStatus;
  stories(): StoryEntry[];
  /** Resolves once a build has finished after this call (for tests). */
  nextBuild(): Promise<BuildStatus>;
  close(): Promise<void>;
}

export function defaultOptions(): PreviewOptions {
  return {
    root: repoRoot,
    out: join(repoRoot, "build", "email-preview"),
    port: 4610,
    tailwindMap: join(repoRoot, "build", "tailwind-styles.json"),
    tailwind: true,
    watch: true,
    debounceMs: 250,
  };
}

// --- The HTML the page shows ------------------------------------------------

const ALWAYS = "(min-width: 0px)";
const NEVER = "(max-width: -1px)"; // invalid, so the query is `not all`

/** The message as a reader who prefers `scheme` sees it in a client
 *  that honours the message's own schemes (see the header). */
export function emulateScheme(html: string, scheme: string): string {
  const dark = scheme === "dark";
  let out = html.replace(
    /\(\s*prefers-color-scheme\s*:\s*(dark|light)\s*\)/gi,
    (_m, want: string) =>
      (want.toLowerCase() === "dark") === dark ? ALWAYS : NEVER,
  );
  const meta = /<meta\b[^>]*name\s*=\s*["']?color-scheme["']?[^>]*>/i.exec(out);
  const supportsDark =
    meta !== null && /content\s*=\s*["'][^"']*\bdark\b/i.test(meta[0]);
  const used = dark && supportsDark ? "dark" : "light";
  const pin = `<style data-email-preview>:root{color-scheme:${used} !important}</style>`;
  out = /<\/head\s*>/i.test(out)
    ? out.replace(/<\/head\s*>/i, `${pin}</head>`)
    : pin + out;
  return out;
}

/** The fixture host's URLs, pointed at this server's /x.test/. */
export function localFixtureUrls(html: string): string {
  return html.split(`${FIXTURE_HOST}/`).join("/x.test/");
}

/** What /render serves (see the header). */
export function previewHtml(
  html: string,
  family: string,
  images: string,
  scheme: string,
): string {
  const chain = transformChain(family, images);
  return localFixtureUrls(
    emulateScheme(applyChain(chain, html, scheme), scheme),
  );
}

// --- Helpers ------------------------------------------------------------------

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function send(
  res: ServerResponse,
  status: number,
  type: string,
  body: string | Buffer,
): void {
  res.writeHead(status, {
    "content-type": type,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
  });
  res.end(body);
}

function sendJson(res: ServerResponse, value: unknown): void {
  send(res, 200, "application/json; charset=utf-8", JSON.stringify(value));
}

function isInside(child: string, parent: string): boolean {
  const rel = relative(parent, child);
  return (
    rel === "" ||
    (!rel.startsWith("..") && !rel.startsWith(sep) && rel !== "..")
  );
}

/** Runs a command, resolving with its exit code and combined output. */
function run(
  cmd: string,
  args: string[],
  cwd: string,
  env: NodeJS.ProcessEnv,
  children: Set<ChildProcess>,
): Promise<{ code: number; output: string }> {
  return new Promise((done) => {
    const child = spawn(cmd, args, {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    children.add(child);
    let output = "";
    child.stdout?.on("data", (b: Buffer) => (output += b.toString()));
    child.stderr?.on("data", (b: Buffer) => (output += b.toString()));
    child.on("error", (e) => {
      children.delete(child);
      done({ code: 127, output: `${output}${String(e)}\n` });
    });
    child.on("close", (code, signal) => {
      children.delete(child);
      done({ code: code ?? (signal ? 128 : 1), output });
    });
  });
}

/** The last `n` lines of `s`. */
function tail(s: string, n: number): string {
  const lines = s.split("\n");
  return lines.slice(Math.max(lines.length - n, 0)).join("\n");
}

// --- The server ---------------------------------------------------------------

export async function startPreviewServer(
  o: PreviewOptions,
): Promise<PreviewServer> {
  const root = realpathSync(o.root);
  const out = resolve(o.out);
  mkdirSync(out, { recursive: true });
  const driver = join(out, "driver", "build-stories");
  const derived = join(out, "derived-assets");
  const assetsDirs = [
    join(root, "tests", "stories", "assets"),
    join(root, "src", "isonim_email", "assets", "social"),
    derived,
  ];
  const say = o.log ?? (() => {});
  const ui = readFileSync(join(scriptDir, "ui.html"), "utf8");

  const children = new Set<ChildProcess>();
  const clients = new Set<ServerResponse>();
  const waiters: ((s: BuildStatus) => void)[] = [];
  let status: BuildStatus = {
    state: "building",
    generation: 0,
    log: "",
    builtAt: "",
  };
  let stories: StoryEntry[] = [];
  let storyDir = "";
  let closed = false;
  let building = false;
  let dirty = false;
  let browser: Browser | null = null;
  let browserLaunch: Promise<Browser> | null = null;

  const broadcast = (): void => {
    const data = `event: status\ndata: ${JSON.stringify(status)}\n\n`;
    for (const c of clients) c.write(data);
  };

  async function buildOnce(): Promise<void> {
    status = { ...status, state: "building", log: "" };
    broadcast();
    const env = { ...process.env };
    if (
      o.tailwind &&
      existsSync(join(root, "tools", "tailwind", "build-tailwind.mjs"))
    ) {
      const tw = await run(
        process.execPath,
        ["tools/tailwind/build-tailwind.mjs"],
        root,
        env,
        children,
      );
      if (closed) return;
      if (tw.code !== 0) {
        status = { ...status, state: "failed", log: tail(tw.output, 80) };
        return;
      }
    }
    say("email-preview: compiling the story driver");
    const nim = await run(
      "nim",
      [
        "c",
        "--styleCheck:usages",
        "--styleCheck:error",
        "--hints:off",
        "--path:src",
        "--path:tests",
        "--path:examples",
        `-d:tailwindStylesPathOverride=${o.tailwindMap}`,
        `--out:${driver}`,
        `--nimcache:${join(out, "nimcache")}`,
        "tools/capture/build_stories.nim",
      ],
      root,
      env,
      children,
    );
    if (closed) return;
    if (nim.code !== 0) {
      say("email-preview: the story driver failed to compile");
      status = { ...status, state: "failed", log: tail(nim.output, 80) };
      return;
    }
    const gen = status.generation + 1;
    const dir = join(out, `gen-${gen}`);
    rmSync(dir, { recursive: true, force: true });
    const ran = await run(
      driver,
      ["--preview", dir],
      root,
      {
        ...env,
        ISONIM_CAPTURE_LAYOUT: "1",
        ISONIM_CAPTURE_FIXTURES: "1",
        ISONIM_EMAIL_DERIVED_ASSETS: derived,
      },
      children,
    );
    if (closed) return;
    if (ran.code !== 0) {
      status = { ...status, state: "failed", log: tail(ran.output, 80) };
      return;
    }
    const manifest = JSON.parse(
      readFileSync(join(dir, "manifest.json"), "utf8"),
    ) as {
      stories: StoryEntry[];
    };
    const previous = storyDir;
    stories = manifest.stories;
    storyDir = dir;
    status = {
      state: "ok",
      generation: gen,
      log: "",
      builtAt: new Date().toISOString(),
    };
    if (previous !== "" && previous !== dir)
      rmSync(previous, { recursive: true, force: true });
    say(`email-preview: ${stories.length} stories (generation ${gen})`);
  }

  async function build(): Promise<void> {
    if (building) {
      dirty = true;
      return;
    }
    building = true;
    try {
      do {
        dirty = false;
        try {
          await buildOnce();
        } catch (e) {
          status = { ...status, state: "failed", log: String(e) };
        }
        if (closed) return;
        broadcast();
      } while (dirty && !closed);
    } finally {
      building = false;
      const ws = waiters.splice(0);
      for (const w of ws) w(status);
    }
  }

  // Old generations of a previous run are not kept.
  for (const name of existsSync(out) ? readdirSync(out) : [])
    if (/^gen-\d+$/.test(name))
      rmSync(join(out, name), { recursive: true, force: true });

  // --- Watching ---
  const watchers: FSWatcher[] = [];
  let timer: NodeJS.Timeout | null = null;
  if (o.watch) {
    for (const d of ["src", "examples", join("tests", "stories")]) {
      const dir = join(root, d);
      if (!existsSync(dir)) continue;
      watchers.push(
        watch(dir, { recursive: true }, (_event, file) => {
          if (closed) return;
          if (file !== null && /(^|[/\\])\.|~$|\.swp$/.test(String(file)))
            return;
          if (timer !== null) clearTimeout(timer);
          timer = setTimeout(() => {
            timer = null;
            say(
              `email-preview: ${join(d, String(file ?? ""))} changed, rebuilding`,
            );
            void build();
          }, o.debounceMs);
        }),
      );
    }
  }

  // --- Forced dark ---
  async function chromium(): Promise<Browser> {
    if (browser !== null) return browser;
    if (browserLaunch === null) {
      browserLaunch = (async () => {
        const d = resolveDriver(process.env);
        if ("reason" in d) throw new Error(d.reason);
        const pw = (await import(
          pathToFileURL(join(d.dir, "index.mjs")).href
        )) as typeof import("playwright-core");
        const b = await pw.chromium.launch(
          launchOptions("chromium", true, process.platform),
        );
        if (closed) {
          await b.close();
          throw new Error("the server is closing");
        }
        browser = b;
        return b;
      })();
    }
    return browserLaunch;
  }

  async function forcedDarkShot(
    html: string,
    family: string,
    images: string,
    width: number,
  ): Promise<Buffer> {
    const b = await chromium();
    const context = await b.newContext({
      viewport: { width, height: 800 },
      // Forced dark darkens the light design (tools/capture/launch.ts).
      colorScheme: "light",
    });
    try {
      await installCapturePolicy(context, assetsDirs, images);
      const page = await context.newPage();
      await page.setContent(
        applyChain(transformChain(family, images), html, "light"),
        {
          waitUntil: "load",
        },
      );
      return await page.screenshot({
        fullPage: true,
        animations: "disabled",
        caret: "hide",
      });
    } finally {
      await context.close();
    }
  }

  // --- HTTP ---
  const find = (name: string | null): StoryEntry | undefined =>
    name === null ? undefined : stories.find((s) => s.story === name);

  const storyFile = (s: StoryEntry, key: "html" | "text"): string | null => {
    const f = s[key];
    return f === undefined ? null : readFileSync(join(storyDir, f), "utf8");
  };

  async function handle(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    const q = url.searchParams;
    if (req.method !== "GET") return send(res, 405, "text/plain", "GET only\n");
    switch (url.pathname) {
      case "/":
        return send(res, 200, "text/html; charset=utf-8", ui);
      case "/events": {
        res.writeHead(200, {
          "content-type": "text/event-stream",
          "cache-control": "no-store",
          connection: "keep-alive",
        });
        res.write(`event: status\ndata: ${JSON.stringify(status)}\n\n`);
        clients.add(res);
        req.on("close", () => clients.delete(res));
        return;
      }
      case "/api/stories":
        return sendJson(res, {
          status,
          families: FAMILIES,
          viewports: VIEWPORTS,
          stories: stories.map((s) => ({
            story: s.story,
            group: s.group,
            description: s.description,
            refused: s.error !== undefined,
            counts: {
              error: s.diagnostics.filter((d) => d.severity === "error").length,
              warning: s.diagnostics.filter((d) => d.severity === "warning")
                .length,
              info: s.diagnostics.filter((d) => d.severity === "info").length,
            },
          })),
        });
      case "/api/story": {
        const s = find(q.get("story"));
        if (s === undefined)
          return send(res, 404, "text/plain", "no such story\n");
        return sendJson(res, {
          story: s.story,
          group: s.group,
          description: s.description,
          error: s.error ?? "",
          diagnostics: s.diagnostics.map((d) => ({
            ...d,
            source:
              d.file !== "" && isInside(resolve(d.file), root)
                ? relative(root, resolve(d.file))
                : "",
          })),
        });
      }
      case "/render": {
        const s = find(q.get("story"));
        if (s === undefined)
          return send(res, 404, "text/plain", "no such story\n");
        const html = storyFile(s, "html");
        if (html === null)
          return send(
            res,
            200,
            "text/html; charset=utf-8",
            `<!doctype html><meta charset="utf-8"><title>refused</title><body style="font:14px sans-serif;padding:16px"><h1>${escapeHtml(s.story)} was refused</h1><pre style="white-space:pre-wrap">${escapeHtml(s.error ?? "")}</pre></body>`,
          );
        return send(
          res,
          200,
          "text/html; charset=utf-8",
          previewHtml(
            html,
            q.get("family") ?? "",
            q.get("images") ?? "on",
            q.get("scheme") ?? "light",
          ),
        );
      }
      case "/text": {
        const s = find(q.get("story"));
        const text = s === undefined ? null : storyFile(s, "text");
        if (text === null)
          return send(res, 404, "text/plain", "no text part\n");
        return send(res, 200, "text/plain; charset=utf-8", text);
      }
      case "/shot": {
        const s = find(q.get("story"));
        const html = s === undefined ? null : storyFile(s, "html");
        if (html === null)
          return send(res, 404, "text/plain", "no such story\n");
        const width = Number(q.get("width") ?? "800");
        if (!Number.isInteger(width) || width < 200 || width > 2000)
          return send(res, 400, "text/plain", "width must be 200-2000\n");
        try {
          const png = await forcedDarkShot(
            html,
            q.get("family") ?? "",
            q.get("images") ?? "on",
            width,
          );
          return send(res, 200, "image/png", png);
        } catch (e) {
          return send(
            res,
            503,
            "text/plain",
            `forced dark is unavailable: ${String(e)}\n`,
          );
        }
      }
      case "/source": {
        const file = q.get("file") ?? "";
        const path = resolve(root, file);
        if (
          file === "" ||
          !isInside(path, root) ||
          !existsSync(path) ||
          !statSync(path).isFile()
        )
          return send(
            res,
            404,
            "text/plain",
            "not a file under the preview's root\n",
          );
        if (!isInside(realpathSync(path), root))
          return send(
            res,
            404,
            "text/plain",
            "not a file under the preview's root\n",
          );
        const line = Number(q.get("line") ?? "0");
        const rows = readFileSync(path, "utf8")
          .split("\n")
          .map(
            (t, i) =>
              `<tr id="L${i + 1}"${i + 1 === line ? ' class="hit"' : ""}><td>${i + 1}</td><td>${escapeHtml(t)}</td></tr>`,
          )
          .join("");
        return send(
          res,
          200,
          "text/html; charset=utf-8",
          `<!doctype html><meta charset="utf-8"><title>${escapeHtml(relative(root, path))}</title><style>body{margin:0;font:13px/1.45 ui-monospace,Menlo,monospace;background:#fff;color:#111}h1{font-size:14px;padding:8px 12px;margin:0;background:#f3f4f6;position:sticky;top:0}table{border-collapse:collapse}td{padding:0 12px;white-space:pre;vertical-align:top}td:first-child{color:#6b7280;text-align:right;user-select:none}tr{scroll-margin-top:48px}tr.hit{background:#fef3c7}@media (prefers-color-scheme:dark){body{background:#111827;color:#e5e7eb}h1{background:#1f2937}tr.hit{background:#78350f}}</style><h1>${escapeHtml(relative(root, path))}${line > 0 ? `:${line}` : ""}</h1><table>${rows}</table>`,
        );
      }
    }
    if (url.pathname.startsWith("/x.test/")) {
      const f = resolveFixture(
        `${FIXTURE_HOST}${url.pathname.slice("/x.test".length)}`,
        assetsDirs,
      );
      return send(
        res,
        f.status,
        f.contentType,
        f.status === 200 && f.contentType === "image/gif"
          ? firstFrameGif(f.body)
          : f.body,
      );
    }
    return send(res, 404, "text/plain", "not found\n");
  }

  const server: Server = createServer((req, res) => {
    handle(req, res).catch((e: unknown) => {
      if (!res.headersSent) send(res, 500, "text/plain", `${String(e)}\n`);
      else res.end();
    });
  });
  await new Promise<void>((ok, fail) => {
    server.once("error", fail);
    server.listen(o.port, "127.0.0.1", () => ok());
  });
  const port = (server.address() as AddressInfo).port;

  void build();

  return {
    url: `http://127.0.0.1:${port}/`,
    status: () => status,
    stories: () => stories,
    nextBuild: () => new Promise((r) => waiters.push(r)),
    async close(): Promise<void> {
      closed = true;
      if (timer !== null) clearTimeout(timer);
      for (const w of watchers) w.close();
      for (const c of clients) c.end();
      clients.clear();
      for (const c of children) c.kill("SIGTERM");
      await new Promise<void>((r) => server.close(() => r()));
      server.closeAllConnections();
      if (browserLaunch !== null) {
        const b = await browserLaunch.catch(() => null);
        if (b !== null) await b.close();
      }
      for (const w of waiters.splice(0)) w(status);
    },
  };
}

// --- CLI ----------------------------------------------------------------------

const USAGE = `usage: email-preview [--port N] [--root DIR] [--out DIR] [--no-watch] [--no-tailwind]

Serves the registered stories on http://127.0.0.1:N/ (default 4610; 0 picks
a free port): a story list, the message in an iframe through the emulation
transforms, viewport and scheme toggles (forced dark as a Chromium shot), the
render's diagnostics with links to their source lines, and a reload whenever
a file under src/, examples/ or tests/stories/ changes. The story driver is
built into DIR (default build/email-preview), separate from the captures'.
Stop it with Ctrl-C.
`;

async function main(): Promise<number> {
  const o = defaultOptions();
  o.log = (line) => process.stdout.write(`${line}\n`);
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const value = (): string => {
      const v = args[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    switch (a) {
      case "--help":
        process.stdout.write(USAGE);
        return 0;
      case "--port":
        o.port = Number(value());
        break;
      case "--root":
        o.root = resolve(value());
        break;
      case "--out":
        o.out = resolve(value());
        break;
      case "--no-watch":
        o.watch = false;
        break;
      case "--no-tailwind":
        o.tailwind = false;
        break;
      default:
        process.stderr.write(`email-preview: unknown argument ${a}\n${USAGE}`);
        return 2;
    }
  }
  if (!Number.isInteger(o.port) || o.port < 0 || o.port > 65535) {
    process.stderr.write(`email-preview: bad --port\n`);
    return 2;
  }
  const server = await startPreviewServer(o);
  process.stdout.write(`email-preview: ${server.url}\n`);
  await new Promise<void>((done) => {
    const stop = (): void => {
      process.off("SIGINT", stop);
      process.off("SIGTERM", stop);
      void server.close().then(done);
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
  });
  return 0;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href)
  process.exit(await main());
