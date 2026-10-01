// tools/capture/providers/marionette.ts — a minimal client for Gecko's
// Marionette remote protocol, which Thunderbird ships and enables with
// `--marionette` (and, for privileged scripts in its own windows,
// `--remote-allow-system-access`).
//
// The linux-desktop provider drives Thunderbird through it: it points
// the running client at a capture's account, opens the message in its
// own window, and reads the geometry of the message body from the
// client's own layout (the crop), the scheme the client applied and
// which images it loaded. The protocol is a TCP stream of
// `<length>:<json>` frames on 127.0.0.1: the server greets first, then
// answers each `[0, id, command, params]` with `[1, id, error, result]`.

import { createConnection, type Socket } from "node:net";

export class MarionetteError extends Error {}

interface Pending {
  ok: (v: unknown) => void;
  fail: (e: Error) => void;
  command: string;
}

export class Marionette {
  private buf = Buffer.alloc(0);
  private seq = 0;
  private readonly pending = new Map<number, Pending>();
  private greeted: ((v: Record<string, unknown>) => void) | null = null;
  private closed: Error | null = null;
  greeting: Record<string, unknown> | null = null;

  private readonly sock: Socket;

  private constructor(sock: Socket) {
    this.sock = sock;
    sock.on("data", (d: Buffer) => {
      this.buf = Buffer.concat([this.buf, d]);
      this.pump();
    });
    const lost = (why: string): void => {
      this.closed ??= new MarionetteError(`marionette connection ${why}`);
      for (const p of this.pending.values()) p.fail(this.closed);
      this.pending.clear();
    };
    sock.on("close", () => lost("closed"));
    sock.on("error", (e) => lost(`failed: ${e.message}`));
  }

  // Connects, retrying while the client starts, and resolves once the
  // server has greeted. `open` makes one connection attempt (by default
  // TCP to 127.0.0.1:port; a desktop session bridges into its network
  // namespace instead); `where` names it in errors.
  static async connect(
    port: number,
    timeoutMs: number,
    open: () => Socket = () => createConnection({ host: "127.0.0.1", port }),
    where = `127.0.0.1:${port}`,
  ): Promise<Marionette> {
    const t0 = Date.now();
    let last = "";
    while (Date.now() - t0 < timeoutMs) {
      const m = await new Promise<Marionette | null>((ok) => {
        const s = open();
        let settled = false;
        const give = (v: Marionette | null, why: string): void => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (v === null) {
            last = why;
            s.destroy();
          }
          ok(v);
        };
        const timer = setTimeout(() => give(null, "no greeting"), 5000);
        s.once("error", (e) => give(null, e.message));
        // A bridge that cannot reach the port yet closes at once.
        s.once("close", () => give(null, "closed before the greeting"));
        const c = new Marionette(s);
        c.greeted = (g) => {
          c.greeting = g;
          give(c, "");
        };
      });
      if (m !== null) return m;
      await new Promise((r) => setTimeout(r, 50));
    }
    throw new MarionetteError(
      `no Marionette server at ${where} within ${timeoutMs / 1000} s (${last})`,
    );
  }

  private pump(): void {
    for (;;) {
      const colon = this.buf.indexOf(0x3a);
      if (colon < 0) return;
      const n = Number(this.buf.subarray(0, colon).toString("latin1"));
      if (!Number.isInteger(n) || n < 0) {
        this.sock.destroy(new MarionetteError("malformed frame"));
        return;
      }
      if (this.buf.length < colon + 1 + n) return;
      const body = this.buf.subarray(colon + 1, colon + 1 + n);
      this.buf = this.buf.subarray(colon + 1 + n);
      const msg = JSON.parse(body.toString("utf8")) as unknown;
      if (!Array.isArray(msg)) {
        this.greeted?.(msg as Record<string, unknown>);
        this.greeted = null;
        continue;
      }
      const [, id, err, result] = msg as [number, number, unknown, unknown];
      const p = this.pending.get(id);
      if (p === undefined) continue;
      this.pending.delete(id);
      if (err !== null && err !== undefined) {
        const e = err as { error?: string; message?: string };
        p.fail(
          new MarionetteError(
            `${p.command}: ${e.error ?? "error"}: ${e.message ?? JSON.stringify(err)}`,
          ),
        );
      } else p.ok(result);
    }
  }

  send(
    command: string,
    params: Record<string, unknown> = {},
  ): Promise<unknown> {
    if (this.closed !== null) return Promise.reject(this.closed);
    const id = ++this.seq;
    const frame = JSON.stringify([0, id, command, params]);
    return new Promise((ok, fail) => {
      this.pending.set(id, { ok, fail, command });
      this.sock.write(`${Buffer.byteLength(frame)}:${frame}`);
    });
  }

  // A script in the current context; `arguments` holds args. Returns
  // the script's value.
  async script(script: string, args: unknown[] = []): Promise<unknown> {
    const r = (await this.send("WebDriver:ExecuteScript", {
      script,
      args,
    })) as { value: unknown };
    return r.value;
  }

  // An asynchronous script: its last argument is the callback that
  // resolves it.
  async asyncScript(
    script: string,
    args: unknown[] = [],
    timeoutMs = 30000,
  ): Promise<unknown> {
    await this.send("WebDriver:SetTimeouts", { script: timeoutMs });
    const r = (await this.send("WebDriver:ExecuteAsyncScript", {
      script,
      args,
    })) as { value: unknown };
    return r.value;
  }

  close(): void {
    this.closed ??= new MarionetteError("marionette connection closed");
    this.sock.destroy();
  }
}
