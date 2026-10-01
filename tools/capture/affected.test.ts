// tools/capture/affected.test.ts — fixtures: the per-module affects
// declarations (parsing, the declared set of every real module, the
// backend-A mapping), family selection from the change, dark-scheme
// trigger, the all-families fallback, and the tree-to-tree
// changed-files diff with a stubbed runner (the real-git half lives in
// affected_worktree.test.ts). Run with:
//   node --test tools/capture/affected.test.ts

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import {
  BACKEND_A_FAMILIES,
  CLIENT_FAMILIES,
  backendAFamilies,
  changedFilesSince,
  type CommandRunner,
  darkNeeded,
  familiesForChange,
  MODULE_ROOT,
  parseAffects,
  selectFamilies,
} from "./affected.ts";

const repoRoot = resolve(
  dirname(new URL(import.meta.url).pathname),
  "..",
  "..",
);
const ALL8 = [...BACKEND_A_FAMILIES];
const NO_GANGA = ALL8.filter((f) => f !== "ganga");

function modules(dir: string): string[] {
  const out: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...modules(p));
    else if (e.name.endsWith(".nim")) out.push(relative(repoRoot, p));
  }
  return out.sort();
}

describe("parseAffects", () => {
  it("reads allFamilies, set literals and set arithmetic", () => {
    assert.deepEqual(
      parseAffects("const affects*: set[ClientFamily] = allFamilies\n"),
      CLIENT_FAMILIES,
    );
    assert.deepEqual(
      parseAffects("const affects*: set[ClientFamily] = {cfOutlookWord}"),
      ["outlookWord"],
    );
    assert.deepEqual(
      parseAffects("const affects*: set[ClientFamily] = {}"),
      [],
    );
    assert.deepEqual(
      parseAffects("const affects* = allFamilies - {cfGanga, cfHey}"),
      CLIENT_FAMILIES.filter((f) => f !== "ganga" && f !== "hey"),
    );
    assert.deepEqual(
      parseAffects("const affects* = {cfApple} + {cfThunderbird}"),
      ["apple", "thunderbird"],
    );
  });

  it("returns null without a declaration and throws on what it cannot read", () => {
    assert.equal(parseAffects("const other* = allFamilies"), null);
    assert.throws(
      () => parseAffects("const affects* = {cfNotAFamily}"),
      /unknown family/,
    );
    assert.throws(
      () => parseAffects("const affects* = someProc()"),
      /cannot read/,
    );
  });
});

describe("the modules' own declarations", () => {
  it("every module under src/isonim_email/ declares a readable affects", () => {
    const mods = modules(join(repoRoot, MODULE_ROOT));
    assert.ok(mods.length > 30, `only ${mods.length} modules found`);
    for (const m of mods) {
      const set = parseAffects(readFileSync(join(repoRoot, m), "utf8"));
      assert.ok(set !== null, `${m} declares no affects`);
    }
  });

  it("the narrow declarations: mso/ is Word-only, head CSS spares ganga, transports and briefs affect no capture", () => {
    const read = (m: string): string[] | null =>
      parseAffects(readFileSync(join(repoRoot, MODULE_ROOT, m), "utf8"));
    for (const m of ["mso/cond.nim", "mso/document.nim"])
      assert.deepEqual(read(m), ["outlookWord"], m);
    for (const m of ["passes/head.nim", "style/css.nim", "style/classes.nim"])
      assert.deepEqual(
        read(m),
        CLIENT_FAMILIES.filter((f) => f !== "ganga"),
        m,
      );
    for (const m of [
      "transport/smtp.nim",
      "transport/mailpit.nim",
      "transport/mailgun.nim",
      "review/brief.nim",
    ])
      assert.deepEqual(read(m), [], m);
  });
});

describe("backendAFamilies", () => {
  it("outlookWord → wordApprox only", () => {
    assert.deepEqual(backendAFamilies(["outlookWord"]), ["wordApprox"]);
  });

  it("every family but ganga → all but ganga", () => {
    assert.deepEqual(
      backendAFamilies(CLIENT_FAMILIES.filter((f) => f !== "ganga")),
      NO_GANGA,
    );
  });

  it("every family → all 8", () => {
    assert.deepEqual(backendAFamilies(CLIENT_FAMILIES), ALL8);
  });

  it("a family with no backend-A stand-in still selects the standards-engine views", () => {
    assert.deepEqual(backendAFamilies(["yahoo"]), [
      "chromium-baseline",
      "imagesOff",
    ]);
  });
});

describe("selection reads the declaration, not the path", () => {
  it("a lower/ module selects exactly what it declares", () => {
    // A scratch repository root holding one lower/ module; nothing but
    // its declaration can narrow the selection.
    const root = mkdtempSync(join(tmpdir(), "affects-decl-"));
    try {
      mkdirSync(join(root, MODULE_ROOT, "lower"), { recursive: true });
      const mod = `${MODULE_ROOT}lower/button.nim`;
      writeFileSync(
        join(root, mod),
        "import ../target\n\nconst affects*: set[ClientFamily] = {cfThunderbird}\n",
      );
      assert.deepEqual(selectFamilies([mod], root), [
        "thunderbird",
        "chromium-baseline",
        "imagesOff",
      ]);
      writeFileSync(
        join(root, mod),
        "import ../target\n\nconst affects*: set[ClientFamily] = {cfOutlookWord}\n",
      );
      assert.deepEqual(selectFamilies([mod], root), ["wordApprox"]);
      // No declaration (or a deleted module): every family.
      writeFileSync(join(root, mod), "discard\n");
      assert.deepEqual(selectFamilies([mod], root), ALL8);
      rmSync(join(root, mod));
      assert.deepEqual(selectFamilies([mod], root), ALL8);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("the real lower/ modules declare every family", () => {
    for (const m of [
      "lower/document.nim",
      "lower/elements.nim",
      "lower/image.nim",
    ])
      assert.deepEqual(selectFamilies([`${MODULE_ROOT}${m}`]), ALL8, m);
  });
});

describe("selectFamilies", () => {
  it("mso/ edit → wordApprox only", () => {
    assert.deepEqual(selectFamilies(["src/isonim_email/mso/cond.nim"]), [
      "wordApprox",
    ]);
  });

  it("passes/head.nim edit → all except ganga", () => {
    assert.deepEqual(
      selectFamilies(["src/isonim_email/passes/head.nim"]),
      NO_GANGA,
    );
  });

  it("passes/styles.nim edit → all 8 (negative control: only head.nim narrows)", () => {
    assert.deepEqual(
      selectFamilies(["src/isonim_email/passes/styles.nim"]),
      ALL8,
    );
  });

  it("unknown path → all 8", () => {
    assert.deepEqual(selectFamilies(["docs/notes.md"]), ALL8);
  });

  it("unions across files and keeps BACKEND_A_FAMILIES order", () => {
    assert.deepEqual(
      selectFamilies([
        "src/isonim_email/mso/cond.nim",
        "src/isonim_email/passes/head.nim",
      ]),
      NO_GANGA,
    );
    assert.deepEqual(
      selectFamilies([
        "src/isonim_email/mso/cond.nim",
        "src/isonim_email/passes/styles.nim",
      ]),
      ALL8,
    );
  });

  it("empty change → no families", () => {
    assert.deepEqual(selectFamilies([]), []);
  });
});

describe("darkNeeded", () => {
  it("true for a token change", () => {
    assert.equal(darkNeeded(["src/isonim_email/style/tokens.nim"]), true);
  });

  it("false for an mso-only change", () => {
    assert.equal(darkNeeded(["src/isonim_email/mso/cond.nim"]), false);
  });
});

describe("changedFilesSince", () => {
  it("diffs the previous run's tree against this run's; runner stubbed", () => {
    const calls: string[][] = [];
    const run: CommandRunner = (cmd) => {
      calls.push(cmd);
      return "src/isonim_email/mso/cond.nim\n  \nsrc/isonim_email/style/tokens.nim\n";
    };
    assert.deepEqual(changedFilesSince(run, "abc123", "def456"), [
      "src/isonim_email/mso/cond.nim",
      "src/isonim_email/style/tokens.nim",
    ]);
    assert.deepEqual(calls, [
      ["git", "diff", "--name-only", "abc123", "def456"],
    ]);
  });
});

describe("familiesForChange", () => {
  const all = ["apple", "thunderbird", "wordApprox"];
  it("selects from the changed files when there are any", () => {
    assert.deepEqual(
      familiesForChange(["src/isonim_email/mso/cond.nim"], all),
      ["wordApprox"],
    );
  });
  it("selects every family when the MIME changed but no file did", () => {
    assert.deepEqual(familiesForChange([], all), all);
  });
});
