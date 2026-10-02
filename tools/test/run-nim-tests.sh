#!/usr/bin/env bash
# run-nim-tests.sh — compile and run Nim test files concurrently.
#
#   tools/test/run-nim-tests.sh <c|js> "<nim flags>" <test file>...
#
# Each file is still its own `nim c -r` (or `nim js -r`) with its own
# --out: and, on C, its own --nimcache:, exactly as a serial run would
# build it, so no build state is shared between files and each binary
# runs in its own process. Up to $ISONIM_EMAIL_TEST_JOBS files run at a
# time; unset, the count follows the host (see test_jobs below).
#
# Each file's compiler and test output goes to test-logs/<stem>-<backend>.log
# (the names the serial loop used). A line per file is printed as it
# finishes: PASS or FAIL, the file, the backend, its wall time, and for a
# failure the unittest `[FAILED]` lines naming the failing tests. Every
# file runs even after a failure; at the end each failed file's whole log
# is printed under its name, then a summary, and the exit status is 1 if
# any file failed (a compile error counts: the binary never ran).
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <c|js> \"<nim flags>\" <test file>..." >&2
  exit 2
fi
backend=$1
flags=$2
shift 2
case "$backend" in
  c | js) ;;
  *)
    echo "$0: unknown backend '$backend' (want c or js)" >&2
    exit 2
    ;;
esac
[ $# -gt 0 ] || {
  echo "$0: no test files given" >&2
  exit 2
}

# An explicit job count must be a positive number (xargs -P 0 would mean
# "no limit", the opposite of what 0 reads as).
case "${ISONIM_EMAIL_TEST_JOBS-}" in
  '' | *[!0-9]* | 0)
    if [ -n "${ISONIM_EMAIL_TEST_JOBS+set}" ]; then
      echo "$0: ISONIM_EMAIL_TEST_JOBS must be a positive number of files (got '$ISONIM_EMAIL_TEST_JOBS'); unset it to follow the host" >&2
      exit 2
    fi
    ;;
esac

# How many files at a time. The host's spare cores (cores minus the
# 1-minute load average), kept between a quarter and half of the cores:
# on an idle machine half the cores (the C and JS runs, the TypeScript
# suites and the browsers of the end-to-end files share the rest), on a
# loaded one still a quarter (a compile is a single-threaded nim process,
# so fewer would leave the run serial in all but name).
test_jobs() {
  if [ -n "${ISONIM_EMAIL_TEST_JOBS:-}" ]; then
    echo "$ISONIM_EMAIL_TEST_JOBS"
    return
  fi
  local cores load free lo hi
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  load=0
  if [ -r /proc/loadavg ]; then
    load=$(cut -d' ' -f1 /proc/loadavg)
    load=${load%.*}
  fi
  free=$((cores - load))
  lo=$((cores / 4))
  hi=$((cores / 2))
  [ "$lo" -ge 2 ] || lo=2
  [ "$hi" -ge "$lo" ] || hi=$lo
  [ "$free" -ge "$lo" ] || free=$lo
  [ "$free" -le "$hi" ] || free=$hi
  echo "$free"
}

mkdir -p build/test-bin build/test-bin-js test-logs
results=$(mktemp -d "${TMPDIR:-/tmp}/isonim-email-nim-tests.XXXXXX")
trap 'rm -rf "$results"' EXIT

# One file: compile + run, log, record the outcome. Runs in a child bash
# (xargs), so everything it needs is passed in or exported.
run_one() {
  local file=$1 stem log t0 status secs failed
  stem=$(basename "$file" .nim)
  log="test-logs/$stem-$BACKEND.log"
  t0=$(date +%s)
  status=0
  # shellcheck disable=SC2086 # $FLAGS is a flag list, split on purpose
  if [ "$BACKEND" = c ]; then
    nim c $FLAGS "--out:build/test-bin/$stem" "--nimcache:build/nimcache-$stem" \
      -r "$file" >"$log" 2>&1 || status=$?
  else
    nim js $FLAGS "--out:build/test-bin-js/$stem.js" -r "$file" >"$log" 2>&1 ||
      status=$?
  fi
  secs=$(($(date +%s) - t0))
  echo "$status" >"$RESULTS/$stem"
  if [ "$status" -eq 0 ]; then
    printf 'PASS %s (%s, %d s)\n' "$file" "$BACKEND" "$secs"
  else
    failed=$(grep -F '[FAILED]' "$log" | sed 's/^ */       /' || true)
    printf 'FAIL %s (%s, %d s, exit %d; log %s)\n%s\n' "$file" "$BACKEND" \
      "$secs" "$status" "$log" "$failed"
  fi
}
export -f run_one
export BACKEND=$backend FLAGS=$flags RESULTS=$results

jobs=$(test_jobs)
# The test files see the same bound (tests/compile_fail_checks.nim runs
# its compiler processes at most this many at a time), so
# ISONIM_EMAIL_TEST_JOBS=1 is serial all the way down.
export ISONIM_EMAIL_TEST_JOBS=$jobs
echo "$backend: $# test files, $jobs at a time (ISONIM_EMAIL_TEST_JOBS overrides)"
t0=$(date +%s)
# run_one always exits 0; outcomes are read from $results below (a file
# xargs never got to run reads as missing, which is a failure).
# shellcheck disable=SC2016 # $1 is expanded by the child bash
printf '%s\n' "$@" | xargs -P "$jobs" -I{} bash -c 'run_one "$1"' _ {} || true

failures=()
for file in "$@"; do
  stem=$(basename "$file" .nim)
  status=$(cat "$results/$stem" 2>/dev/null || echo missing)
  [ "$status" = 0 ] || failures+=("$file")
done
for file in "${failures[@]}"; do
  stem=$(basename "$file" .nim)
  echo
  echo "=== FAILED: $file ($backend) — test-logs/$stem-$backend.log"
  cat "test-logs/$stem-$backend.log" 2>/dev/null || echo "(no log)"
done
echo
echo "$backend: $(($# - ${#failures[@]})) of $# test files passed in $(($(date +%s) - t0)) s"
if [ "${#failures[@]}" -gt 0 ]; then
  echo "$backend: FAILED: ${failures[*]}"
  exit 1
fi
