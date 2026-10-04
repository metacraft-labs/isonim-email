// tools/preview/preview.test.ts — `just email-preview` end to end: the
// real server over real HTTP, its page in the pinned Chromium, the story
// driver compiled and run by the server, a real file change.
//
// The server builds and watches a copy of this checkout's story sources
// (config.nims, src/, examples/, tests/stories/ and the driver's source,
// with the sibling repositories linked beside it), so the reload test can
// edit a story without touching the files the other test recipes compile
// at the same time. What the server lists is checked against the story
// driver `just email-shots-build` built from this checkout (`--list`, the
// registry as the capture CLI sees it), and what it renders against that
// driver's own output put through the capture's transform chain.
//
// Everything the tests start (the server, its builds, the browsers) is
// stopped in `after`, and the copy is removed.
// Run with:
//   node --test tools/preview/preview.test.ts

import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import type { Browser, Frame, Page } from "playwright-core";
import { applyChain, transformChain } from "../capture/transforms.ts";
import { launchChromium } from "../web/static_page.ts";
import {
  type BuildStatus,
  type PreviewServer,
  emulateScheme,
  localFixtureUrls,
  startPreviewServer,
} from "./server.ts";

const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = resolve(scriptDir, "..", "..");
const driver = join(repoRoot, "build", "capture", "build-stories");
const SIBLINGS = [
  "isonim",
  "nim-everywhere",
  "nim-faststreams",
  "nim-stew",
  "isonim-docs",
];
const STORY_ENV = { ISONIM_CAPTURE_LAYOUT: "1", ISONIM_CAPTURE_FIXTURES: "1" };
const BUILD_TIMEOUT_MS = 15 * 60_000;

let scratch: string;
let root: string;
let server: PreviewServer;
let browser: Browser;

interface Listed {
  story: string;
  group: string;
  description: string;
}

/** The registered stories, as this checkout's capture driver lists them. */
function registered(): Listed[] {
  assert.ok(existsSync(driver), `${driver} is built (just email-shots-build)`);
  const out = execFileSync(driver, ["--list"], {
    env: { ...process.env, ...STORY_ENV },
    encoding: "utf8",
  });
  return (JSON.parse(out) as { stories: Listed[] }).stories;
}

/** One story's HTML as this checkout's capture driver writes it. */
function driverHtml(story: string): string {
  const out = join(scratch, "oracle");
  execFileSync(driver, [out, story], {
    env: {
      ...process.env,
      ...STORY_ENV,
      ISONIM_EMAIL_DERIVED_ASSETS: join(scratch, "oracle-assets"),
    },
    stdio: ["ignore", "ignore", "inherit"],
  });
  return readFileSync(join(out, `${story}.html`), "utf8");
}

/** One story's text part as this checkout's capture driver writes it
 *  (its `--preview` mode's `<story>.txt`), as bytes. */
function driverText(story: string): Buffer {
  const out = join(scratch, "oracle-preview");
  execFileSync(driver, ["--preview", out, story], {
    env: {
      ...process.env,
      ...STORY_ENV,
      ISONIM_EMAIL_DERIVED_ASSETS: join(scratch, "oracle-assets"),
    },
    stdio: ["ignore", "ignore", "inherit"],
  });
  return readFileSync(join(out, `${story}.txt`));
}

/** Waits for the build after now to finish, and for the server to be ok. */
async function settled(): Promise<BuildStatus> {
  const deadline = Date.now() + BUILD_TIMEOUT_MS;
  for (;;) {
    const s = server.status();
    if (s.state !== "building") return s;
    assert.ok(Date.now() < deadline, "the preview build finishes");
    await Promise.race([
      server.nextBuild(),
      new Promise((r) => setTimeout(r, 1000)),
    ]);
  }
}

async function getJson<T>(path: string): Promise<T> {
  const r = await fetch(new URL(path, server.url));
  assert.equal(r.status, 200, `GET ${path}`);
  return (await r.json()) as T;
}

/** The iframe's frame once it shows a /render URL holding every one of
 *  `fragments`. */
async function previewFrame(
  page: Page,
  ...fragments: string[]
): Promise<Frame> {
  await page.waitForFunction(
    `(() => { const f = document.querySelector("#frame"); const d = f && f.contentDocument; return !!d && f.src === d.location.href && d.location.href.includes("/render?") && ${JSON.stringify(fragments)}.every((x) => d.location.href.includes(x)) && d.readyState === "complete" && !!d.body && d.body.childElementCount > 0; })()`,
    undefined,
    { timeout: 30_000 },
  );
  const frame = page
    .frames()
    .find(
      (f) =>
        f !== page.mainFrame() &&
        f.url().includes("/render?") &&
        fragments.every((x) => f.url().includes(x)),
    );
  assert.ok(frame, `a frame shows ${fragments.join(", ")}`);
  return frame;
}

before(async () => {
  scratch = mkdtempSync(join(tmpdir(), "isonim-email-preview-"));
  const ws = join(scratch, "ws");
  root = join(ws, "isonim-email");
  mkdirSync(join(root, "tests"), { recursive: true });
  mkdirSync(join(root, "tools", "capture"), { recursive: true });
  for (const d of ["src", "examples", join("tests", "stories")])
    cpSync(join(repoRoot, d), join(root, d), { recursive: true });
  for (const f of [
    "config.nims",
    join("tools", "capture", "build_stories.nim"),
  ])
    cpSync(join(repoRoot, f), join(root, f));
  for (const s of SIBLINGS)
    symlinkSync(resolve(repoRoot, "..", s), join(ws, s));
  server = await startPreviewServer({
    root,
    out: join(scratch, "out"),
    port: 0,
    tailwindMap: join(repoRoot, "build", "tailwind-styles.json"),
    tailwind: false,
    watch: true,
    debounceMs: 200,
  });
  browser = await launchChromium();
  const s = await settled();
  assert.equal(s.state, "ok", `the first build succeeds:\n${s.log}`);
});

after(async () => {
  await browser?.close();
  await server?.close();
  if (scratch) rmSync(scratch, { recursive: true, force: true });
});

describe("the email preview server", () => {
  it("e2e_preview_lists_all_stories", async () => {
    const want = registered();
    // The reference emails and the layout stories are among them.
    const names = want.map((s) => s.story);
    for (const n of [
      "canary",
      "receiptTypical",
      "newsletterColumns",
      "layoutOneColumn",
      "boxMinimal",
      "invoiceSummary",
      "overflowFixed",
    ])
      assert.ok(names.includes(n), `${n} is registered`);
    assert.equal(want.filter((s) => s.group === "reference").length, 14);

    // Over HTTP: every registered story, in order, with its group.
    const api = await getJson<{ stories: Listed[] }>("api/stories");
    assert.deepEqual(
      api.stories.map((s) => [s.story, s.group, s.description]),
      want.map((s) => [s.story, s.group, s.description]),
    );

    // In the page: the same list.
    const page = await browser.newPage({
      viewport: { width: 1400, height: 900 },
    });
    try {
      await page.goto(
        `${server.url}#story=receiptTypical&family=gmailWeb&images=on&viewport=desktop&scheme=light`,
      );
      await page.waitForFunction(
        `document.querySelectorAll("[data-story]").length === ${want.length}`,
        undefined,
        { timeout: 30_000 },
      );
      const shown = (await page.evaluate(
        `Array.from(document.querySelectorAll("[data-story]")).map((e) => e.dataset.story)`,
      )) as string[];
      assert.deepEqual(shown, names);

      // One story with a transform applied: the capture's gmailWeb chain
      // over the driver's HTML, its images on this server.
      const frame = await previewFrame(page, "family=gmailWeb");
      const html = driverHtml("receiptTypical");
      const expected = localFixtureUrls(
        emulateScheme(
          applyChain(transformChain("gmailWeb", "on"), html, "light"),
          "light",
        ),
      );
      const served = await (await fetch(new URL(frame.url()))).text();
      assert.equal(served, expected);
      const raw = await (
        await fetch(new URL("render?story=receiptTypical", server.url))
      ).text();
      assert.notEqual(raw, served, "the transform changed the message");
      assert.equal(raw, localFixtureUrls(emulateScheme(html, "light")));
      // In the frame: Gmail's class rewrite, and the images loaded.
      const dom = (await frame.evaluate(`(() => ({
        classes: Array.from(document.querySelectorAll("[class]")).map((e) => e.getAttribute("class")),
        imgs: Array.from(document.images).filter((i) => i.getAttribute("src").startsWith("/x.test/")).length,
      }))()`)) as { classes: string[]; imgs: number };
      // Gmail's class rewrite: none of the message's own class names is
      // left, each is now an m_<hash> name.
      const tokens = (list: string[]): Set<string> =>
        new Set(list.flatMap((c) => c.split(/\s+/)).filter((k) => k !== ""));
      const own = tokens(
        [...html.matchAll(/class="([^"]*)"/g)].map((m) => m[1] ?? ""),
      );
      const inFrame = tokens(dom.classes);
      assert.ok(own.size > 0, "the receipt has classes");
      assert.deepEqual(
        [...inFrame].filter((k) => own.has(k)),
        [],
        "no class is left as the message wrote it",
      );
      assert.ok(
        [...inFrame].some((k) => k.startsWith("m_")),
        "Gmail's m_ names are in the frame",
      );
      assert.ok(dom.imgs > 0, "the receipt has images");
      await frame.waitForFunction(
        `Array.from(document.images).filter((i) => i.getAttribute("src").startsWith("/x.test/")).every((i) => i.complete)`,
      );
      const loaded = (await frame.evaluate(
        `Array.from(document.images).filter((i) => i.getAttribute("src").startsWith("/x.test/") && i.naturalWidth > 0).length`,
      )) as number;
      assert.ok(loaded > 0, "the fixture host served its images");

      // The text part: byte for byte the driver's, served as plain text
      // and shown as such.
      await page.check("#show-text");
      const textRes = await fetch(
        new URL("text?story=receiptTypical", server.url),
      );
      assert.match(textRes.headers.get("content-type") ?? "", /^text\/plain/);
      const textBytes = Buffer.from(await textRes.arrayBuffer());
      const wantText = driverText("receiptTypical");
      assert.ok(wantText.length > 0, "the receipt has a text part");
      assert.ok(textBytes.equals(wantText), "/text is the driver's text part");
      const textPart = textBytes.toString("utf8");
      await page.waitForFunction(
        `document.querySelector("#text").textContent === ${JSON.stringify(textPart)}`,
      );
      assert.equal(
        await page.evaluate(
          `getComputedStyle(document.querySelector("#frame")).display`,
        ),
        "none",
      );
      await page.uncheck("#show-text");

      // The viewport toggle sizes the frame.
      await page.click('[data-viewport="320"]');
      await page.waitForFunction(
        `document.querySelector("#frame").getBoundingClientRect().width === 320`,
      );

      // The dark toggle: the designed dark palette's dark rules apply in
      // the frame, whatever the viewer's own scheme (as authored: Gmail's
      // web client drops them, and gmailWeb with it).
      await page.selectOption("#family", "");
      await page.click('[data-scheme="light"]');
      await page.evaluate(
        `document.querySelector('[data-story="darkPalette"]').click()`,
      );
      const light = await previewFrame(
        page,
        "story=darkPalette&",
        "&family=&",
        "&scheme=light",
      );
      const lightInk = await light.evaluate(
        `getComputedStyle(document.querySelector("h1")).color`,
      );
      await page.click('[data-scheme="dark"]');
      const dark = await previewFrame(
        page,
        "story=darkPalette&",
        "&family=&",
        "&scheme=dark",
      );
      const darkInk = await dark.evaluate(
        `getComputedStyle(document.querySelector("h1")).color`,
      );
      assert.notEqual(darkInk, lightInk, "the heading takes its dark colour");
      // Forced dark: a shot of the pinned Chromium's automatic dark mode.
      await page.click('[data-scheme="forced-dark"]');
      await page.waitForFunction(
        `(() => { const i = document.querySelector("#shot"); return i.style.display === "block" && i.complete && i.naturalWidth > 0; })()`,
        undefined,
        { timeout: 120_000 },
      );
      assert.equal(
        await page.evaluate(`document.querySelector("#shot").naturalWidth`),
        320,
      );
      await page.click('[data-scheme="light"]');

      // The diagnostics panel: a reference email's, with links to the
      // lines that built the elements they are about.
      await page.evaluate(
        `document.querySelector('[data-story="alertCritical"]').click()`,
      );
      const story = await getJson<{
        diagnostics: { code: string; source: string; line: number }[];
      }>("api/story?story=alertCritical");
      assert.ok(story.diagnostics.length > 0);
      await page.waitForFunction(
        `document.querySelectorAll("#diagnostics li").length === ${story.diagnostics.length}`,
        undefined,
        { timeout: 30_000 },
      );
      const links = (await page.evaluate(
        `Array.from(document.querySelectorAll("#diagnostics a.span")).map((a) => [a.textContent, a.getAttribute("href")])`,
      )) as [string, string][];
      const inEmail = links.find(([label]) =>
        label.startsWith("examples/reference_set.nim:"),
      );
      assert.ok(
        inEmail,
        `a diagnostic links into the reference email (${links.length} links)`,
      );
      const line = Number(inEmail[0].split(":")[1]);
      const src = await fetch(new URL(inEmail[1], server.url));
      assert.equal(src.status, 200);
      const body = await src.text();
      assert.match(body, new RegExp(`<tr id="L${line}" class="hit">`));
      // Jumping to the line leaves it below the sticky file-name header.
      const src2 = await browser.newPage({
        viewport: { width: 1000, height: 600 },
      });
      try {
        await src2.goto(new URL(inEmail[1], server.url).href);
        const geo = (await src2.evaluate(
          `(() => { const h = document.querySelector("h1").getBoundingClientRect(); const r = document.getElementById("L${line}").getBoundingClientRect(); return [h.bottom, r.top, r.bottom, innerHeight]; })()`,
        )) as number[];
        const [headerBottom, top, bottom, height] = geo as [
          number,
          number,
          number,
          number,
        ];
        assert.ok(
          top >= headerBottom && bottom <= height,
          `line ${line} visible below the header (${geo.join(", ")})`,
        );
      } finally {
        await src2.close();
      }
      // Outside the root nothing is served: not by a path that climbs
      // out, not by an absolute one, not through a link out of it.
      for (const outside of [
        "../isonim/src/isonim.nim",
        "/etc/hostname",
        "/etc/passwd",
      ]) {
        const r = await fetch(
          new URL(
            `source?${new URLSearchParams({ file: outside })}`,
            server.url,
          ),
        );
        assert.equal(r.status, 404, outside);
      }
      // (The link sits outside the watched directories, so making it
      // starts no build.)
      symlinkSync("/etc/passwd", join(root, "passwd-link"));
      try {
        const r = await fetch(new URL("source?file=passwd-link", server.url));
        assert.equal(r.status, 404, "a link out of the root");
      } finally {
        rmSync(join(root, "passwd-link"));
      }
    } finally {
      await page.close();
    }
  });

  it("e2e_preview_reloads_on_change", async () => {
    const page = await browser.newPage({
      viewport: { width: 1400, height: 900 },
    });
    const file = join(root, "src", "isonim_email", "stories.nim");
    const original = readFileSync(file, "utf8");
    try {
      await page.goto(
        `${server.url}#story=canary&family=&images=on&viewport=desktop&scheme=light`,
      );
      const first = await previewFrame(page, "story=canary");
      assert.match(
        (await first.evaluate(`document.body.innerText`)) as string,
        /The canary sings at noon\./,
      );
      const gen = Number(
        await page.evaluate(`document.body.dataset.generation`),
      );
      await page.evaluate(`window.__sameDocument = true`);

      // A story changes: the driver is rebuilt and the page shows it.
      const changed = original.replace(
        `r.setTextContent(p, "The canary sings at noon.")`,
        `r.setTextContent(p, "The canary sings at dusk.")`,
      );
      assert.notEqual(
        changed,
        original,
        "the canary's paragraph is where the test expects it",
      );
      writeFileSync(file, changed);
      await page.waitForFunction(
        `Number(document.body.dataset.generation) > ${gen}`,
        undefined,
        { timeout: BUILD_TIMEOUT_MS },
      );
      const again = await previewFrame(page, `gen=${gen + 1}`);
      assert.match(
        (await again.evaluate(`document.body.innerText`)) as string,
        /The canary sings at dusk\./,
      );
      // The page kept its place: same document, same story selected.
      assert.equal(await page.evaluate(`window.__sameDocument === true`), true);
      assert.match(page.url(), /story=canary/);

      // A change that does not compile: the page says so, with the
      // compiler's output, and keeps showing the last good build.
      writeFileSync(file, `${changed}\nproc broken( =\n`);
      await page.waitForFunction(
        `document.querySelector("#status").dataset.state === "failed"`,
        undefined,
        { timeout: BUILD_TIMEOUT_MS },
      );
      assert.match(
        (await page.evaluate(
          `document.querySelector("#build-log").textContent`,
        )) as string,
        /stories\.nim/,
      );
      assert.equal(
        Number(await page.evaluate(`document.body.dataset.generation`)),
        gen + 1,
      );
      const kept = await fetch(new URL("render?story=canary", server.url));
      assert.match(await kept.text(), /The canary sings at dusk\./);

      // Fixed: built and shown again.
      writeFileSync(file, original);
      await page.waitForFunction(
        `Number(document.body.dataset.generation) > ${gen + 1}`,
        undefined,
        { timeout: BUILD_TIMEOUT_MS },
      );
      const back = await previewFrame(page, `gen=${gen + 2}`);
      assert.match(
        (await back.evaluate(`document.body.innerText`)) as string,
        /The canary sings at noon\./,
      );
      assert.equal(
        await page.evaluate(`document.querySelector("#status").dataset.state`),
        "ok",
      );
    } finally {
      writeFileSync(file, original);
      await page.close();
    }
  });
});
