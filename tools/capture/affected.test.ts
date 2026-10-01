// tools/capture/affected.test.ts — fixtures: the per-module affects
// declarations (parsing, the declared set of every real module, the
// backend-A mapping), family selection from the change, a run's
// families with explicit --clients/--backends over the registered
// providers' real clients, dark-scheme
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
  emptyMatrixReason,
  familiesForChange,
  MODULE_ROOT,
  parseAffects,
  selectFamilies,
  selectRunFamilies,
  type RunSelection,
  type ServedClient,
} from "./affected.ts";
import { servedFamilies } from "./providers/harness.ts";
import { registeredProviders } from "./providers/registry.ts";

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

  it("the narrow declarations: mso/document is Word-only, head CSS spares ganga, transports and briefs affect no capture", () => {
    const read = (m: string): string[] | null =>
      parseAffects(readFileSync(join(repoRoot, MODULE_ROOT, m), "utf8"));
    assert.deepEqual(read("mso/document.nim"), ["outlookWord"]);
    // mso/cond.nim also builds the [if !mso] wrapper, which every family
    // but Word renders.
    assert.deepEqual(read("mso/cond.nim"), CLIENT_FAMILIES);
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

// Code lines only: a module that merely mentions the wrapper in a
// comment does not emit it.
function codeOf(src: string): string {
  return src
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("#"))
    .join("\n");
}

// Builds or writes `<!--[if !mso]><!-->…` content: defines or calls the
// IR constructor or the wrapper over it, or writes the literal opener.
const EMITS_NOT_MSO = /\b(newNotMso|notMsoWrap)\*?\s*\(|"[^"\n]*\[if !mso\]/;

describe("modules that emit [if !mso] content", () => {
  it("declare every family but Word, whatever directory they live in", () => {
    const mods = modules(join(repoRoot, MODULE_ROOT));
    const emitters = mods.filter((m) =>
      EMITS_NOT_MSO.test(codeOf(readFileSync(join(repoRoot, m), "utf8"))),
    );
    // The detector must see the known emitters, or it is blind: the IR
    // constructor, the wrapper, the serialiser's literal, and the
    // document lowering that calls the wrapper.
    for (const m of [
      "ir.nim",
      "mso/cond.nim",
      "serialize.nim",
      "lower/document.nim",
    ])
      assert.ok(emitters.includes(`${MODULE_ROOT}${m}`), `${m} not detected`);
    const nonWord = CLIENT_FAMILIES.filter((f) => f !== "outlookWord");
    for (const m of emitters) {
      const set = parseAffects(readFileSync(join(repoRoot, m), "utf8")) ?? [];
      for (const f of nonWord)
        assert.ok(
          set.includes(f),
          `${m} emits [if !mso] content, which ${f} renders, but its affects omits ${f}`,
        );
    }
  });

  it("the detector ignores comments and Word-only wrappers", () => {
    assert.equal(
      EMITS_NOT_MSO.test(codeOf("## calls `newNotMso(` in prose\n")),
      false,
    );
    assert.equal(EMITS_NOT_MSO.test(codeOf('newMsoIf("mso", @c)\n')), false);
    assert.equal(EMITS_NOT_MSO.test(codeOf("  notMsoWrap(b)\n")), true);
    assert.equal(
      EMITS_NOT_MSO.test(codeOf("proc newNotMso*(c: seq[EmailNode])\n")),
      true,
    );
    assert.equal(
      EMITS_NOT_MSO.test(codeOf('  sink.put("<!--[if !mso]><!-->")\n')),
      true,
    );
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
  it("Word-only mso/ edit → wordApprox only", () => {
    assert.deepEqual(selectFamilies(["src/isonim_email/mso/document.nim"]), [
      "wordApprox",
    ]);
  });

  it("mso/cond.nim edit → all 8 (its [if !mso] wrapper reaches every other family)", () => {
    assert.deepEqual(selectFamilies(["src/isonim_email/mso/cond.nim"]), ALL8);
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
        "src/isonim_email/mso/document.nim",
        "src/isonim_email/passes/head.nim",
      ]),
      NO_GANGA,
    );
    assert.deepEqual(
      selectFamilies([
        "src/isonim_email/mso/document.nim",
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
      familiesForChange(["src/isonim_email/mso/document.nim"], all),
      ["wordApprox"],
    );
  });
  it("selects every family when the MIME changed but no file did", () => {
    assert.deepEqual(familiesForChange([], all), all);
  });
});

describe("selectRunFamilies over the registered providers", () => {
  const providers = registeredProviders();
  const served: ServedClient[] = providers.flatMap((p) =>
    p.clients().map((c) => ({
      backend: p.backend,
      clientId: c.clientId,
      family: c.family,
    })),
  );
  const all = servedFamilies(providers);
  const docsEdit = ["docs/rendering-rules.md"];
  const wordEdit = ["src/isonim_email/mso/document.nim"];
  const base = (over: Partial<RunSelection>): RunSelection => ({
    served,
    families: all,
    familiesExplicit: false,
    full: false,
    changedFiles: docsEdit,
    clients: null,
    backends: null,
    ...over,
  });
  const fams = (over: Partial<RunSelection>): string[] =>
    selectRunFamilies(base(over)).families;

  it("the verification clients are registered (the cases below depend on it)", () => {
    for (const id of ["roundcube", "snappymail"])
      assert.deepEqual(
        served.filter((c) => c.clientId === id).map((c) => c.family),
        ["verification"],
        id,
      );
    assert.ok(all.includes("verification"));
  });

  it("a bare run with a previous run selects the change's backend-A families, never verification", () => {
    assert.deepEqual(fams({}), ALL8);
    assert.deepEqual(fams({ changedFiles: wordEdit }), ["wordApprox"]);
    assert.equal(selectRunFamilies(base({})).source, "change");
  });

  it("a bare run without a previous run (full) selects every served family, verification included", () => {
    const r = selectRunFamilies(base({ full: true }));
    assert.deepEqual(r.families, all);
    assert.equal(r.source, "full");
    // And a MIME change with no changed file falls back to every family.
    assert.deepEqual(fams({ changedFiles: [] }), all);
  });

  it("--clients roundcube selects verification whatever the change selected", () => {
    for (const changedFiles of [docsEdit, wordEdit])
      assert.ok(
        fams({ changedFiles, clients: ["roundcube"] }).includes("verification"),
        changedFiles.join(","),
      );
  });

  it("--clients snappymail selects verification", () => {
    assert.ok(fams({ clients: ["snappymail"] }).includes("verification"));
  });

  it("--backends selfhosted-webmail selects verification; --backends a does not", () => {
    assert.ok(
      fams({ backends: ["selfhosted-webmail"] }).includes("verification"),
    );
    assert.deepEqual(fams({ backends: ["a"] }), ALL8);
    assert.deepEqual(
      fams({ changedFiles: wordEdit, backends: ["a", "selfhosted-webmail"] }),
      ["wordApprox", "verification"],
    );
  });

  it("mixed --clients across backends: each named client gets its families", () => {
    // chromium's families include the change's wordApprox, so it keeps
    // the narrowing; roundcube's verification is added.
    assert.deepEqual(
      fams({ changedFiles: wordEdit, clients: ["chromium", "roundcube"] }),
      ["wordApprox", "verification"],
    );
    // webkit serves none of the change's families: its own are added.
    assert.deepEqual(
      fams({ changedFiles: wordEdit, clients: ["webkit", "snappymail"] }),
      ["apple", "wordApprox", "verification"],
    );
  });

  it("an explicit --families is taken as given", () => {
    const r = selectRunFamilies(
      base({
        families: ["apple"],
        familiesExplicit: true,
        clients: ["roundcube"],
      }),
    );
    assert.deepEqual(r.families, ["apple"]);
    assert.equal(r.source, "--families");
  });

  it("the empty-matrix message names the cause", () => {
    assert.match(
      emptyMatrixReason(
        served,
        ["apple"],
        "--families",
        ["a", "selfhosted-webmail"],
        ["roundcube"],
      ),
      /client 'roundcube' serves verification, none of the selected families/,
    );
    assert.match(
      emptyMatrixReason(
        served,
        ["verification"],
        "change",
        ["a"],
        ["roundcube"],
      ),
      /client 'roundcube' is served by backend selfhosted-webmail, which --backends leaves out/,
    );
    assert.match(
      emptyMatrixReason(
        served,
        ["wordApprox"],
        "change",
        ["selfhosted-webmail"],
        null,
      ),
      /families \[wordApprox\] \(selected by the change since the previous run\).*backend 'selfhosted-webmail' serves verification, none of the selected families/,
    );
    // Families an explicit client added are not labelled as the
    // change's: --clients roundcube --backends a after a Word-only edit.
    const named = selectRunFamilies(
      base({
        changedFiles: wordEdit,
        clients: ["roundcube"],
        backends: ["a"],
      }),
    );
    assert.deepEqual(named, {
      families: ["wordApprox", "verification"],
      source: "change+named",
    });
    const msg = emptyMatrixReason(
      served,
      named.families,
      named.source,
      ["a"],
      ["roundcube"],
    );
    assert.match(
      msg,
      /families \[wordApprox, verification\] \(selected by the change since the previous run, plus those of the named clients and backends\)/,
    );
    assert.doesNotMatch(msg, /since the previous run\)/);
    // With nothing added, the change alone is named.
    assert.equal(
      selectRunFamilies(base({ changedFiles: wordEdit, clients: ["chromium"] }))
        .source,
      "change",
    );
  });
});
