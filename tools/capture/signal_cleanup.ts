// tools/capture/signal_cleanup.ts — cleanup that runs however a CLI
// ends: at a normal return, an uncaught exception, process.exit, and on
// SIGINT, SIGTERM or SIGHUP, which would otherwise kill the process
// without an exit event.

const SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"] as const;
const SIGNAL_NUMBERS: Record<(typeof SIGNALS)[number], number> = {
  SIGHUP: 1,
  SIGINT: 2,
  SIGTERM: 15,
};

// Runs `cleanup` (synchronously) at process exit, and turns SIGINT,
// SIGTERM and SIGHUP into an exit with 128 + the signal's number.
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
