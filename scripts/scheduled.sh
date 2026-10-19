#!/usr/bin/env bash
# Run one scheduled agent job headless. Each job is jobs/<job>.job in the
# workspace; launchd starts it (bin/bootstrap.sh installs the schedule), or
# run it by hand to see it now. Logs go to ~/Library/Logs/cabinet/<slug>/.
#
#   bin/scheduled.sh <job>
#
# The agent tool comes from CABINET_RUNNER in cabinet.env: claude, codex, gemini,
# qwen, grok, opencode, cursor, or custom (CABINET_RUNNER_CMD, any other tool).
# A run is stopped after TIMEOUT minutes (the job's, else CABINET_JOB_TIMEOUT; 0 for none).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

job="${1:?usage: scheduled.sh <job> (one of: $(cd "$WS/jobs" 2>/dev/null && ls *.job 2>/dev/null | sed 's/\.job$//' | tr '\n' ' '))}"
jf="$WS/jobs/$job.job"
[[ -f "$jf" ]] || { echo "unknown job: $job (no jobs/$job.job)" >&2; exit 2; }
AGENT="" PROMPT="" MINUTES="a few" RESULT="the log" AFTER="" TIMEOUT=""
# shellcheck disable=SC1090
source "$jf"
[[ -n "$AGENT" && -n "$PROMPT" ]] || { echo "jobs/$job.job needs AGENT and PROMPT" >&2; exit 2; }
limit="${TIMEOUT:-$CABINET_JOB_TIMEOUT}"
[[ "$limit" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "TIMEOUT in jobs/$job.job (or CABINET_JOB_TIMEOUT) must be whole minutes, or 0 for no limit, not '$limit'" >&2; exit 2; }

# The agent runs in its own process group, so a run past its limit is stopped with
# everything it started: TERM, then KILL 10 seconds later. Exit 124, as timeout(1).
# Its own group misses Ctrl-C and launchd's stop, so those are passed on; it gets no
# terminal input, which a background group would stop on.
limited() {
  ((limit)) || { run_agent; return; }
  local secs=$((limit * ${CABINET_TEST_MINUTE:-60})) st=0   # CABINET_TEST_MINUTE: tests only
  set -m; run_agent </dev/null & pid=$!; set +m
  perl -e 'sleep shift; kill "TERM", -$ARGV[0]; sleep 10; kill "KILL", -$ARGV[0]' "$secs" "$pid" & dog=$!
  trap 'kill -TERM -- "-$pid" "$dog" 2>/dev/null; exit 130' INT TERM
  local start=$SECONDS
  wait "$pid" || st=$?
  trap - INT TERM
  kill "$dog" 2>/dev/null || true
  if ((SECONDS - start >= secs)); then echo "stopped after $limit min: the job's time limit (TIMEOUT in jobs/$job.job, or CABINET_JOB_TIMEOUT)" >&2; return 124; fi
  return "$st"
}

after() { [[ -z "$AFTER" ]] || (cd "$WS" && bash -c "$AFTER") >>"$log" 2>&1 || echo "after-step failed: see the lines above" >>"$log"; }

cd "$WS"
mkdir -p -m 700 "$LOGDIR"
log="$LOGDIR/$job.log"
echo "=== $(date '+%F %T') $job ($AGENT, $CABINET_RUNNER)" >>"$log"
if [[ -t 1 ]]; then
  # Started by hand: say what is happening, then show the result here too.
  echo "Running $job with $AGENT. It takes $MINUTES minutes and prints nothing until it finishes."
  echo "Result: $RESULT and $log"
  start=$SECONDS status=0
  limited 2>&1 | tee -a "$log" || status=$?
  ((status)) || after
  echo
  echo "Finished in $(( (SECONDS - start) / 60 )) min (exit $status). Open $RESULT."
  exit "$status"
fi
limited >>"$log" 2>&1 || { echo "exit $? at $(date '+%T'): see the lines above" >>"$log"; exit 1; }
after
