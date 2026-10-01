// tools/capture/providers/netns_bridge.ts — the inside half of a
// desktop session's network bridge (desktop_session.ts).
//
// A desktop session runs in a network namespace of its own whose only
// interface is loopback: nothing a client does can leave the machine,
// whatever it makes of its proxy settings. The few loopback services
// the client must reach (the imap and assets services, which listen on
// the host's 127.0.0.1) are bridged in over unix sockets, which a
// network namespace does not separate:
// - for each forwarded port P this process listens on 127.0.0.1:P
//   inside the namespace and relays every connection to the unix socket
//   <runtime>/bridge-out-P.sock, where the session (outside) relays it on
//   to the host's 127.0.0.1:P; the ports are the same on both sides, so
//   an account's host and port and an asset URL mean the same thing
//   inside and out;
// - <runtime>/bridge-in.sock lets the outside reach a port inside (a
//   client's remote-control port): a connection's first line names the
//   port, and the rest of the stream is relayed to 127.0.0.1:<port>.
// Once listening it writes <runtime>/bridge-ready.
//
// Usage (run by the session inside the namespace):
//   node netns_bridge.ts <runtime-dir> <port>…

import { createConnection, createServer, type Socket } from "node:net";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

function relay(a: Socket, b: Socket): void {
  a.pipe(b);
  b.pipe(a);
  const close = (): void => {
    a.destroy();
    b.destroy();
  };
  a.on("error", close);
  b.on("error", close);
  a.on("close", close);
  b.on("close", close);
}

function listen(
  server: ReturnType<typeof createServer>,
  at: { port: number; host: string } | { path: string },
): Promise<void> {
  return new Promise((ok, fail) => {
    server.once("error", fail);
    server.listen(at, () => {
      server.off("error", fail);
      ok();
    });
  });
}

export async function runBridge(
  runtime: string,
  ports: number[],
): Promise<void> {
  for (const port of ports) {
    const server = createServer((inside) => {
      relay(
        inside,
        createConnection({ path: join(runtime, `bridge-out-${port}.sock`) }),
      );
    });
    await listen(server, { port, host: "127.0.0.1" });
  }

  const inbound = createServer((outside) => {
    let head = Buffer.alloc(0);
    const onData = (d: Buffer): void => {
      head = Buffer.concat([head, d]);
      const nl = head.indexOf(0x0a);
      if (nl < 0) {
        if (head.length > 16) outside.destroy();
        return;
      }
      outside.off("data", onData);
      outside.pause();
      const port = Number(head.subarray(0, nl).toString("latin1"));
      const rest = head.subarray(nl + 1);
      const inside = createConnection({ port, host: "127.0.0.1" }, () => {
        if (rest.length > 0) inside.write(rest);
        relay(outside, inside);
        outside.resume();
      });
      inside.on("error", () => outside.destroy());
    };
    outside.on("data", onData);
    outside.on("error", () => outside.destroy());
  });
  await listen(inbound, { path: join(runtime, "bridge-in.sock") });
  writeFileSync(join(runtime, "bridge-ready"), `${process.pid}\n`);
}

// Run as a script (imported, it only defines runBridge).
if (
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const [runtime, ...ports] = process.argv.slice(2);
  if (runtime === undefined) {
    process.stderr.write("usage: netns_bridge.ts <runtime-dir> <port>…\n");
    process.exit(2);
  }
  await runBridge(runtime, ports.map(Number));
}
