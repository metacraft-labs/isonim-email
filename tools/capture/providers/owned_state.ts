// tools/capture/providers/owned_state.ts — owner records for the
// on-disk state and the server processes a capture run starts, and the
// sweep that removes what a dead run left behind.
//
// Every service that starts long-running processes for a run (the imap
// service's Dovecot, the self-hosted webmail's php-fpm and caddy) keeps
// two directories: a state directory directly inside its state root
// under build/, and a short-named private directory for unix sockets
// directly inside a socket base ($XDG_RUNTIME_DIR or /tmp), named with
// the service's prefix. Both carry an owner.json written before anything
// else goes into them: the pid and start time of the run that owns them,
// the run id, both directories, and the pid and start time of every
// server process once it is spawned.
//
// A start first sweeps: every entry (a directory directly inside the
// state root, or a prefixed directory directly inside a socket base)
// whose owner.json names an owner that is no longer running has the
// server processes it records stopped (SIGTERM, then SIGKILL; only where
// they still run with the recorded start time) and is removed. The other directory a record
// names is removed with it only when it resolves to a real directory of
// the same shape AND its own owner.json names the same dead owner (pid
// and start time) and the same run: a forged, corrupt or stale record
// can never take another run's directory with it. An entry whose owner
// is alive, or that has no readable owner.json, is never touched.

import {
  existsSync,
  lstatSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";

export const OWNER_FILE = "owner.json";

export interface ProcessId {
  pid: number;
  // The process start time (Linux /proc/<pid>/stat field 22), so a
  // reused pid is not mistaken for the recorded process; null where
  // unknown.
  start: string | null;
}

export interface OwnerRecord {
  owner: ProcessId;
  run: string;
  stateDir: string;
  socketDir: string;
  // The imap service's Dovecot (kept under its own name for records
  // written before the list below existed).
  dovecot?: ProcessId | null;
  // Every other server process the service started for the run.
  processes?: ProcessId[];
}

export function processStart(pid: number): string | null {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, "latin1");
    return stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19] ?? null;
  } catch {
    return null;
  }
}

export function thisProcess(pid: number): ProcessId {
  return { pid, start: processStart(pid) };
}

export function processAlive(p: ProcessId): boolean {
  try {
    process.kill(p.pid, 0);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "EPERM") return false;
  }
  return p.start === null || processStart(p.pid) === p.start;
}

function isProcessId(v: unknown): v is ProcessId {
  return (
    typeof v === "object" &&
    v !== null &&
    typeof (v as ProcessId).pid === "number" &&
    ((v as ProcessId).start === null ||
      typeof (v as ProcessId).start === "string")
  );
}

// The record in `dir`, or null when it is missing or not a record.
export function readOwner(dir: string): OwnerRecord | null {
  try {
    const o = JSON.parse(
      readFileSync(join(dir, OWNER_FILE), "utf8"),
    ) as OwnerRecord;
    return isProcessId(o.owner) && typeof o.run === "string" ? o : null;
  } catch {
    return null;
  }
}

// Writes the record into both of its directories, each atomically.
export function writeOwner(o: OwnerRecord): void {
  for (const dir of [o.stateDir, o.socketDir]) {
    const tmp = join(dir, `.${OWNER_FILE}.tmp`);
    writeFileSync(tmp, JSON.stringify(o) + "\n", { mode: 0o600 });
    renameSync(tmp, join(dir, OWNER_FILE));
  }
}

// The real path of `p` when it is a directory (not a symlink) owned by
// `uid` that, with symlinks and ".." resolved, sits directly inside one
// of `roots` (also resolved); null otherwise. uid -1: any owner.
export function directChildOf(
  p: string,
  roots: string[],
  uid: number,
): string | null {
  let real: string;
  try {
    const st = lstatSync(p);
    if (!st.isDirectory() || (uid !== -1 && st.uid !== uid)) return null;
    real = realpathSync(p);
  } catch {
    return null;
  }
  for (const r of roots) {
    let root: string;
    try {
      root = realpathSync(r);
    } catch {
      continue;
    }
    if (dirname(real) === root && real !== root) return real;
  }
  return null;
}

// Removes a run's directory, synchronously (also from an exit handler).
// A server process that was just killed can still be writing into it
// (a php-fpm worker its log, Dovecot its own): a file it creates after
// the removal listed the directory makes the final rmdir fail with
// ENOTEMPTY and leaves the directory behind. So the removal is
// repeated, every 20 ms, until it succeeds; after `timeoutMs` the last
// error is thrown, never swallowed.
export function removeRunDirSync(dir: string, timeoutMs = 5000): void {
  const t0 = Date.now();
  for (;;) {
    try {
      rmSync(dir, { recursive: true, force: true });
      return;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException).code;
      if (
        (code !== "ENOTEMPTY" && code !== "EBUSY") ||
        Date.now() - t0 > timeoutMs
      )
        throw err;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
    }
  }
}

function sameOwner(a: OwnerRecord, b: OwnerRecord): boolean {
  return (
    a.owner.pid === b.owner.pid &&
    a.owner.start === b.owner.start &&
    a.run === b.run
  );
}

async function waitDead(p: ProcessId, ms: number): Promise<boolean> {
  const t0 = Date.now();
  while (processAlive(p)) {
    if (Date.now() - t0 > ms) return false;
    await new Promise((r) => setTimeout(r, 20));
  }
  return true;
}

// Removes what dead runs left (see the file header). Returns the
// directories removed.
export async function sweepDeadOwners(
  stateRoot: string,
  bases: string[],
  socketPrefix: string,
): Promise<string[]> {
  const uid = process.getuid?.() ?? -1;
  const found: { dir: string; owner: OwnerRecord }[] = [];
  const consider = (dir: string): void => {
    try {
      const st = lstatSync(dir);
      if (!st.isDirectory() || (uid !== -1 && st.uid !== uid)) return;
    } catch {
      return;
    }
    const owner = readOwner(dir);
    if (owner !== null && !processAlive(owner.owner))
      found.push({ dir, owner });
  };
  const list = (d: string): string[] => {
    try {
      return readdirSync(d);
    } catch {
      return [];
    }
  };
  for (const e of list(stateRoot)) consider(join(stateRoot, e));
  for (const base of bases)
    for (const e of list(base))
      if (e.startsWith(socketPrefix)) consider(join(base, e));
  const stateDir = (p: unknown): string | null =>
    typeof p === "string" ? directChildOf(p, [stateRoot], uid) : null;
  const socketDir = (p: unknown): string | null => {
    const real = typeof p === "string" ? directChildOf(p, bases, uid) : null;
    return real !== null && basename(real).startsWith(socketPrefix)
      ? real
      : null;
  };
  const removed: string[] = [];
  for (const { dir, owner } of found) {
    const procs = [
      ...(isProcessId(owner.dovecot) ? [owner.dovecot] : []),
      ...(Array.isArray(owner.processes)
        ? owner.processes.filter(isProcessId)
        : []),
    ];
    // SIGTERM first, so a server that manages workers of its own
    // (php-fpm, Dovecot) takes them down with it; SIGKILL if it does
    // not go within two seconds.
    for (const sig of ["SIGTERM", "SIGKILL"] as const)
      for (const p of procs)
        if (processAlive(p)) {
          try {
            process.kill(p.pid, sig);
          } catch {
            // gone in between
          }
          await waitDead(p, sig === "SIGTERM" ? 2000 : 5000);
        }
    // The entry itself goes. The record names its partner directory;
    // that is not trusted: it goes only where it resolves to one of the
    // two shapes this service creates and its own record names the
    // same dead owner and run.
    const targets = new Set<string>();
    const self = stateDir(dir) ?? socketDir(dir);
    if (self !== null) targets.add(self);
    for (const t of [stateDir(owner.stateDir), socketDir(owner.socketDir)]) {
      if (t === null || t === self) continue;
      const theirs = readOwner(t);
      if (theirs !== null && sameOwner(theirs, owner)) targets.add(t);
    }
    for (const t of targets)
      if (existsSync(t)) {
        rmSync(t, { recursive: true, force: true });
        removed.push(t);
      }
  }
  return removed;
}
