#!/usr/bin/env bash
# run-recipes.sh — run several just recipes at the same time.
#
#   tools/test/run-recipes.sh <recipe>...
#
# `just test` uses this to run its test recipes concurrently once their
# shared prerequisites are built (each recipe runs with --no-deps, so the
# Tailwind map and the story drivers are not rebuilt by six recipes at
# once). The recipes are independent by construction: every test keeps
# its services, browsers, desktop sessions, ports and scratch state under
# directories of its own, and the checks that no process or state is left
# behind are scoped to those (see the end-to-end test files' headers).
#
# Each recipe's output goes to test-logs/<recipe>.log. A line is printed
# as each one finishes (PASS or FAIL, its wall time, and the counts from
# its summary); at the end every failed recipe's log is printed in full
# under its name (a Nim recipe's log names each failing file and test;
# of a node:test log, the part from its failing-tests list, each test
# with its file:line and assertion), and the
# exit status is 1 if any recipe failed. Ctrl-C stops them all.
#
# Every recipe runs in a session and process group of its own (setsid),
# with a marker in its environment that its descendants inherit. Its
# processes are therefore found whole — the group, every descendant, and
# on Linux anything carrying the marker even after it re-parented or
# left the group — and killed whole:
# - a recipe still running after ISONIM_EMAIL_RECIPE_TIMEOUT seconds
#   (default 1800, several times the slowest recipe's normal few
#   minutes on a loaded host) is reported FAIL "timed out after N s"
#   and all of its processes are killed (TERM, then KILL after 5 s); a
#   leaked handle in a test (a server nobody closed keeps `node --test`
#   waiting forever) therefore fails the run instead of hanging it;
# - a recipe that exits but leaves processes running is reported FAIL
#   "left N process(es) running", naming them, and they are killed.
set -euo pipefail

[ $# -gt 0 ] || {
  echo "usage: $0 <recipe>..." >&2
  exit 2
}
timeout_s=${ISONIM_EMAIL_RECIPE_TIMEOUT:-1800}
case "$timeout_s" in
  '' | *[!0-9]* | 0)
    echo "$0: ISONIM_EMAIL_RECIPE_TIMEOUT must be a positive number of seconds (got '$timeout_s')" >&2
    exit 2
    ;;
esac
mkdir -p test-logs

# The command that starts a recipe in a new session (its own process
# group, pgid = its pid): util-linux setsid where there is one (the dev
# shell has it on Linux), Perl's POSIX::setsid otherwise (macOS has no
# setsid command). A background job of this non-interactive script is
# not a group leader, so setsid execs in place rather than forking: $!
# is the session's leader.
if command -v setsid >/dev/null 2>&1; then
  new_session=(setsid)
else
  # shellcheck disable=SC2016 # $! and @ARGV are Perl's
  new_session=(perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"')
fi

marker=ISONIM_EMAIL_RECIPE_RUN
run_id="$$-$(date +%s)"

# Every live process of recipe $1 (leader pid $2): its process group,
# the descendants of its leader, and (Linux) every process whose
# environment carries the recipe's marker. One pid per line, never this
# script itself.
recipe_procs() {
  local tag="$marker=$run_id-$1" leader=$2
  {
    # The group and the leader's descendants, from one process listing.
    ps -A -o pid= -o ppid= -o pgid= 2>/dev/null | awk -v root="$leader" '
      { pid[NR] = $1; ppid[NR] = $2; pgid[NR] = $3 }
      END {
        want[root] = 1
        for (i = 1; i <= NR; i++) if (pgid[i] == root) want[pid[i]] = 1
        do {
          grew = 0
          for (i = 1; i <= NR; i++)
            if ((ppid[i] in want) && !(pid[i] in want)) { want[pid[i]] = 1; grew = 1 }
        } while (grew)
        for (i = 1; i <= NR; i++) if (pid[i] in want) print pid[i]
      }'
    # Re-parented or regrouped processes still carry the marker.
    if [ -d /proc/self ]; then
      grep -lzx -F -e "$tag" /proc/[0-9]*/environ 2>/dev/null |
        sed -e 's|^/proc/||' -e 's|/environ$||' || true
    fi
  } | sort -un | grep -vx -e "$$" -e "$BASHPID" || true
}

# The command lines of the given pids, one per line (for a report).
describe_procs() {
  local p
  for p in "$@"; do
    printf '    %s %s\n' "$p" "$(ps -o args= -p "$p" 2>/dev/null | cut -c1-160 || true)"
  done
}

# Kill every process of recipe $1 (leader $2): TERM, up to 5 s for them
# to go, then KILL, repeated until none is left (a process can fork while
# its siblings are being killed).
kill_recipe() {
  local r=$1 leader=$2 procs
  for _ in 1 2 3 4 5; do
    mapfile -t procs < <(recipe_procs "$r" "$leader")
    [ ${#procs[@]} -gt 0 ] || return 0
    kill -TERM -- "-$leader" 2>/dev/null || true
    kill -TERM "${procs[@]}" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      mapfile -t procs < <(recipe_procs "$r" "$leader")
      [ ${#procs[@]} -gt 0 ] || return 0
      sleep 0.5
    done
    kill -KILL -- "-$leader" 2>/dev/null || true
    kill -KILL "${procs[@]}" 2>/dev/null || true
    sleep 0.2
  done
  mapfile -t procs < <(recipe_procs "$r" "$leader")
  if [ ${#procs[@]} -gt 0 ]; then
    echo "run-recipes: could not kill every process of $r:" >&2
    describe_procs "${procs[@]}" >&2
  fi
}

declare -A pids starts watchdogs
running=()
stop_all() {
  local r
  for r in "${running[@]+"${running[@]}"}"; do
    kill "${watchdogs[$r]}" 2>/dev/null || true
    kill_recipe "$r" "${pids[$r]}"
  done
}
trap 'stop_all; exit 130' INT TERM

t0=$(date +%s)
echo "running concurrently: $* (logs: test-logs/<recipe>.log; timeout ${timeout_s} s each; load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo n/a))"
for r in "$@"; do
  # The marker is set for the recipe only (an assignment on its command).
  # The log is opened for appending, so the runner's own notes added to
  # it below land after the recipe's output rather than over it.
  : >"test-logs/$r.log"
  env "$marker=$run_id-$r" "${new_session[@]}" just --no-deps "$r" \
    >>"test-logs/$r.log" 2>&1 </dev/null &
  pids[$r]=$!
  starts[$r]=$(date +%s)
  # The recipe's deadline: a sleep that ends when it is due.
  sleep "$timeout_s" &
  watchdogs[$r]=$!
  running+=("$r")
done

# A one-line digest of a finished recipe's log: the Nim runner's
# "N of M test files passed" line, node:test's tests/pass/fail/skipped
# counts, or the capture checks' verdict.
digest() {
  grep -E -e '^(c|js): [0-9]+ of [0-9]+ test files passed' \
    -e '^ℹ (tests|pass|fail|skipped) [0-9]+' \
    -e '^capture-ci: (PASS|FAIL)' \
    -e 'NOT RUN on' "$1" 2>/dev/null |
    sed -e 's/^ℹ //' -e 's/ (run at [^)]*)//' | paste -sd ' ' - || true
}

failed=()
while [ ${#running[@]} -gt 0 ]; do
  # Block until a running recipe or one of their deadlines ends. Only
  # pids not yet waited for are listed: a reaped pid would make `wait -n`
  # return at once, every time, and the loop would spin.
  waitfor=()
  for r in "${running[@]}"; do waitfor+=("${pids[$r]}" "${watchdogs[$r]}"); done
  wait -n "${waitfor[@]}" 2>/dev/null || true
  still=()
  for r in "${running[@]}"; do
    pid=${pids[$r]}
    note=""
    if kill -0 "$pid" 2>/dev/null; then
      if kill -0 "${watchdogs[$r]}" 2>/dev/null; then
        still+=("$r")
        continue
      fi
      # The deadline passed with the recipe still running.
      wait "${watchdogs[$r]}" 2>/dev/null || true
      mapfile -t procs < <(recipe_procs "$r" "$pid")
      {
        echo
        echo "run-recipes: TIMED OUT after $timeout_s s; killing its ${#procs[@]} process(es):"
        describe_procs "${procs[@]+"${procs[@]}"}"
      } >>"test-logs/$r.log"
      kill_recipe "$r" "$pid"
      wait "$pid" 2>/dev/null || true
      status=timeout
    else
      kill "${watchdogs[$r]}" 2>/dev/null || true
      wait "${watchdogs[$r]}" 2>/dev/null || true
      status=0
      wait "$pid" || status=$?
      # Its processes should all be gone with it; give a stopping
      # service a moment, then whatever is left is a leak.
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        mapfile -t procs < <(recipe_procs "$r" "$pid")
        [ ${#procs[@]} -gt 0 ] || break
        sleep 0.5
      done
      if [ ${#procs[@]} -gt 0 ]; then
        {
          echo
          echo "run-recipes: the recipe exited and left ${#procs[@]} process(es) running; killing them:"
          describe_procs "${procs[@]}"
        } >>"test-logs/$r.log"
        note="left ${#procs[@]} process(es) running (killed; see the log) "
        kill_recipe "$r" "$pid"
        [ "$status" != 0 ] || status=leak
      fi
    fi
    secs=$(($(date +%s) - ${starts[$r]}))
    case "$status" in
      0)
        printf 'PASS %s (%d s) %s\n' "$r" "$secs" "$(digest "test-logs/$r.log")"
        ;;
      timeout)
        printf 'FAIL %s (timed out after %d s; every process of it killed) %s\n' \
          "$r" "$timeout_s" "$(digest "test-logs/$r.log")"
        failed+=("$r")
        ;;
      leak)
        printf 'FAIL %s (%d s) %s%s\n' "$r" "$secs" "$note" "$(digest "test-logs/$r.log")"
        failed+=("$r")
        ;;
      *)
        printf 'FAIL %s (%d s, exit %d) %s%s\n' "$r" "$secs" "$status" "$note" \
          "$(digest "test-logs/$r.log")"
        failed+=("$r")
        ;;
    esac
  done
  running=("${still[@]+"${still[@]}"}")
done

for r in "${failed[@]+"${failed[@]}"}"; do
  echo
  echo "=== FAILED: just $r — test-logs/$r.log"
  # node:test ends with its failing tests (file:line, assertion); the
  # passing tests before that are left to the log.
  if grep -q '^✖ failing tests:' "test-logs/$r.log"; then
    echo "(the passing tests are in the log)"
    sed -n '/^✖ failing tests:/,$p' "test-logs/$r.log"
  else
    cat "test-logs/$r.log"
  fi
done
echo
echo "$(($# - ${#failed[@]})) of $# recipes passed in $(($(date +%s) - t0)) s (load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo n/a))"
if [ ${#failed[@]} -gt 0 ]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
