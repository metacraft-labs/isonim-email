// tools/capture/providers/desktop_teardown.test.ts — how a desktop
// session waits for a killed client to be gone (teardownVerdict and
// teardownSample in desktop_session.ts).
//
// The verdict is checked on hand-made samples (the cases a real
// teardown passes through), and the sampler on real processes: a
// process that is alive, one that is killed, and one that is a zombie
// nobody has collected yet. Linux only (the sampler reads /proc).
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  teardownSample,
  type TeardownTask,
  teardownVerdict,
} from "./desktop_session.ts";

const task = (
  id: string,
  state: string,
  cpu: number,
  wchan = "",
): TeardownTask => ({ id, state, cpu, wchan });

describe("teardownVerdict: the wait follows the teardown", () => {
  it("is gone when no task is left", () => {
    assert.deepEqual(teardownVerdict([task("1/1", "R", 5)], [], 0, 10000), {
      state: "gone",
    });
  });

  it("is progress while a task uses CPU time, is runnable, or a task finishes, long past the stall bound", () => {
    // CPU time used since the last sample: still tearing down, even
    // long past the bound.
    assert.equal(
      teardownVerdict(
        [task("1/2", "D", 100, "unmap_page_range")],
        [task("1/2", "D", 101, "unmap_page_range")],
        60000,
        10000,
      ).state,
      "progress",
    );
    // Runnable: waiting only for a CPU.
    assert.equal(
      teardownVerdict(
        [task("1/2", "R", 100)],
        [task("1/2", "R", 100)],
        60000,
        10000,
      ).state,
      "progress",
    );
    // One of two tasks finished.
    assert.equal(
      teardownVerdict(
        [task("1/2", "S", 7), task("1/3", "S", 9)],
        [task("1/3", "S", 9)],
        60000,
        10000,
      ).state,
      "progress",
    );
  });

  it("stops following the teardown at the overall cap: a task that keeps running past it fails the wait", () => {
    const busy = [task("7/7", "R", 100)];
    const busier = [task("7/7", "R", 140)];
    assert.equal(
      teardownVerdict(busy, busier, 0, 10000, {
        elapsedMs: 59999,
        capMs: 60000,
      }).state,
      "progress",
    );
    assert.deepEqual(
      teardownVerdict(busy, busier, 0, 10000, {
        elapsedMs: 60000,
        capMs: 60000,
      }),
      {
        state: "stalled",
        reason:
          "the killed processes were not gone 60 s after the kill (7/7 R)",
      },
    );
    // Gone wins over the cap: a teardown that finished is not a failure.
    assert.equal(
      teardownVerdict(busy, [], 0, 10000, { elapsedMs: 90000, capMs: 60000 })
        .state,
      "gone",
    );
  });

  it("waits through a pause shorter than the bound, and fails naming each task's wait once nothing moved for the bound", () => {
    const stuck = [task("41/42", "D", 300, "os_acquire_rwlock_write")];
    assert.equal(teardownVerdict(stuck, stuck, 9999, 10000).state, "waiting");
    const v = teardownVerdict(stuck, stuck, 10000, 10000);
    assert.deepEqual(v, {
      state: "stalled",
      reason:
        "the killed processes made no progress for 10 s (41/42 D in os_acquire_rwlock_write)",
    });
  });
});

describe(
  "teardownSample: what is left of real processes",
  { skip: process.platform !== "linux" },
  () => {
    it("lists a live process's task, nothing once it is killed and only an uncollected zombie is left, and nothing for a pid that is gone", async () => {
      const child = spawn("sleep", ["1000"], { stdio: "ignore" });
      const pid = child.pid!;
      const live = teardownSample([pid]);
      assert.equal(live.length, 1, JSON.stringify(live));
      assert.equal(live[0]!.id, `${pid}/${pid}`);
      assert.match(live[0]!.state, /^[RS]$/);
      // A zombie (killed, its status not collected yet: node collects it
      // only after the exit event, which this synchronous code holds off)
      // has nothing left to tear down.
      process.kill(pid, "SIGKILL");
      const t0 = Date.now();
      while (teardownSample([pid]).length > 0) {
        assert.ok(
          Date.now() - t0 < 5000,
          "the killed process never became a zombie",
        );
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
      }
      await new Promise((ok) => child.once("exit", ok));
      assert.deepEqual(teardownSample([pid]), []);
    });
  },
);
