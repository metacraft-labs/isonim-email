// tools/capture/clipboard_guard.ts — a secret put on the desktop
// clipboard for a person to paste, and taken off it again on every way
// out: when the caller is done, after a deadline, and (through
// installSignalCleanup) on SIGINT, SIGTERM or SIGHUP and at exit.
//
// It clears the clipboard only while the clipboard still holds the
// value it put there (read back and compared in memory, never printed),
// so a person who has copied something else since keeps it. When the
// clipboard cannot be read back at all (no paste tool on PATH), it
// clears it anyway: losing a person's clipboard is the lesser harm.
//
// The tools: wl-copy/wl-paste on Wayland, else xclip or xsel on X11.

import { spawnSync } from "node:child_process";
import { findExecutable, type HostEnv } from "./providers/requirements.ts";

/** How long a copied secret may stay on the clipboard. */
export const CLIPBOARD_CLEAR_MS = 60_000;

export interface ClipboardTool {
  // The copy command (reads the value on stdin).
  copy: string[];
  // The command that prints the clipboard, or null when there is none.
  paste: string[] | null;
  // The command that empties the clipboard.
  clear: string[];
}

export function clipboardTool(host: HostEnv): ClipboardTool | null {
  const has = (name: string): boolean => findExecutable(name, host) !== null;
  if (host.env.WAYLAND_DISPLAY && has("wl-copy"))
    return {
      copy: ["wl-copy"],
      paste: has("wl-paste") ? ["wl-paste", "--no-newline"] : null,
      clear: ["wl-copy", "--clear"],
    };
  if (host.env.DISPLAY) {
    if (has("xclip"))
      return {
        copy: ["xclip", "-selection", "clipboard"],
        paste: ["xclip", "-selection", "clipboard", "-o"],
        clear: ["xclip", "-selection", "clipboard"],
      };
    if (has("xsel"))
      return {
        copy: ["xsel", "--clipboard", "--input"],
        paste: ["xsel", "--clipboard", "--output"],
        clear: ["xsel", "--clipboard", "--clear"],
      };
  }
  return null;
}

// Synchronous throughout, so it can run in a signal or exit handler.
function run(cmd: string[], input: string, env: HostEnv["env"]): number | null {
  const r = spawnSync(cmd[0]!, cmd.slice(1), {
    input,
    stdio: ["pipe", "ignore", "ignore"],
    env,
    timeout: 5000,
  });
  return r.status;
}

const SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"] as const;
const SIGNAL_NUMBERS: Record<(typeof SIGNALS)[number], number> = {
  SIGHUP: 1,
  SIGINT: 2,
  SIGTERM: 15,
};

export class ClipboardGuard {
  private value: string | null = null;
  private timer: NodeJS.Timeout | null = null;
  private readonly tool: ClipboardTool;
  private readonly env: HostEnv["env"];
  private readonly clearAfterMs: number;

  constructor(
    tool: ClipboardTool,
    env: HostEnv["env"],
    clearAfterMs = CLIPBOARD_CLEAR_MS,
  ) {
    this.tool = tool;
    this.env = env;
    this.clearAfterMs = clearAfterMs;
  }

  get name(): string {
    return this.tool.copy[0]!;
  }

  /** Whether a secret of ours may still be on the clipboard. */
  get holding(): boolean {
    return this.value !== null;
  }

  /** Puts `value` on the clipboard and arms the deadline. */
  fill(value: string): boolean {
    if (value === "" || run(this.tool.copy, value, this.env) !== 0)
      return false;
    this.value = value;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = setTimeout(() => this.clear(), this.clearAfterMs);
    this.timer.unref();
    return true;
  }

  /** Whether the clipboard holds our value now: true, false, or null
   *  when it cannot be read. */
  private stillOurs(): boolean | null {
    if (this.value === null) return false;
    if (this.tool.paste === null) return null;
    const r = spawnSync(this.tool.paste[0]!, this.tool.paste.slice(1), {
      stdio: ["ignore", "pipe", "ignore"],
      env: this.env,
      timeout: 5000,
      maxBuffer: 1 << 20,
    });
    if (r.status !== 0 || !Buffer.isBuffer(r.stdout)) return false;
    return r.stdout.equals(Buffer.from(this.value, "utf8"));
  }

  /** Empties the clipboard if it still holds our value (or cannot be
   *  read), and forgets the value. Returns whether it emptied it. */
  clear(): boolean {
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    if (this.value === null) return false;
    const ours = this.stillOurs();
    this.value = null;
    if (ours === false) return false;
    return run(this.tool.clear, "", this.env) === 0;
  }
}

// Runs `cleanup` (synchronously) at process exit, so a normal return,
// an uncaught exception or process.exit all reach it; and turns
// SIGINT, SIGTERM and SIGHUP, which would otherwise kill the process
// without an exit event, into an exit with 128 + the signal's number.
// `cleanup` must be idempotent. Returns a function that removes the
// handlers.
export function installSignalCleanup(cleanup: () => void): () => void {
  const handlers = SIGNALS.map((sig) => {
    const h = (): void => {
      process.exit(128 + SIGNAL_NUMBERS[sig]);
    };
    process.on(sig, h);
    return [sig, h] as const;
  });
  process.on("exit", cleanup);
  return () => {
    for (const [sig, h] of handlers) process.off(sig, h);
    process.off("exit", cleanup);
  };
}
