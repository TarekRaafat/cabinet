#!/usr/bin/env bash
# The workspace's scheduled agent jobs: jobs/<job>.job, each run headless by the configured agent
# tool. launchd starts them (bin/bootstrap.sh installs the schedules); run one by hand to see it
# now. Logs go to ~/Library/Logs/cabinet/<slug>/.
#
#   bin/job.sh run <job>
#       Run it now. The agent tool comes from CABINET_RUNNER in cabinet.env: claude, codex, gemini,
#       qwen, grok, opencode, cursor, or custom (CABINET_RUNNER_CMD, any other tool). A run is
#       stopped after TIMEOUT minutes (the job's, else CABINET_JOB_TIMEOUT; 0 for none). A scheduled
#       run of a job with QUIET_DAYS is skipped when nothing changed since its last full run.
#   bin/job.sh list [--json]
#       Every job: its name, role, schedule, time limit and what it cost this week, with the week's
#       total and budget (CABINET_BUDGET), from what the agent tool reports.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

j_list() {
  local json=0 a jf ws reported=0
  for a in "$@"; do case "$a" in --json) json=1 ;; *) echo "usage: bin/job.sh list [--json]" >&2; exit 2 ;; esac; done
  ws="$(week_start)"; spend_counts && reported=1
  for jf in "$WS"/jobs/*.job; do
    [[ -f "$jf" ]] || continue
    ( AGENT="" WHEN="" TIMEOUT=""; source "$jf"; j="$(basename "$jf" .job)"
      printf '%s\t%s\t%s\t%s\t%s\n' "$j" "$AGENT" "$([[ -n "$WHEN" ]] && when_human "$WHEN" || echo "by hand only")" "${TIMEOUT:-$CABINET_JOB_TIMEOUT}" \
        "$( ((reported)) && spend_since "$ws" "$j")" )
  done | if ((json)); then jq -Rn '[inputs | split("\t") | {name: .[0], role: .[1], when: .[2], timeout_minutes: (.[3] | tonumber? // null), cost_this_week_usd: (.[4] | tonumber? // null)}]'
         else awk -F'\t' 'BEGIN {n = 0} {n++; printf "%-16s %-18s %-34s %4s min  %s\n", $1, $2, $3, $4, ($5 == "" ? "-" : "$" $5)} END {if (!n) print "No jobs in jobs/."}'; fi
  ((json)) && return 0
  if ((reported)); then echo "This week: \$$(spend_since "$ws") in all, $(spend_source), $( [[ -n "$CABINET_BUDGET" ]] && echo "of a \$$CABINET_BUDGET budget" || echo "no budget set (cabinet config --budget <dollars>)")."
  elif has "$SPEND_TOKENS" "$CABINET_RUNNER"; then echo "Cost: $CABINET_RUNNER reports tokens, not dollars: set its price to count them (cabinet config --price \"<input> <output> [<cached input>]\")."
  else echo "Cost: $CABINET_RUNNER does not report what a run costs, so cabinet cannot count it."; fi
}

j_run() {
job="${1:-}"; [[ -n "$job" ]] || { echo "usage: bin/job.sh run <job> (one of: $(cd "$WS/jobs" 2>/dev/null && ls *.job 2>/dev/null | sed 's/\.job$//' | tr '\n' ' '))" >&2; exit 2; }
jf="$WS/jobs/$job.job"
[[ -f "$jf" ]] || { echo "unknown job: $job (no jobs/$job.job)" >&2; exit 2; }
AGENT="" PROMPT="" MINUTES="a few" RESULT="the log" AFTER="" TIMEOUT="" QUIET_DAYS=""
# shellcheck disable=SC1090
source "$jf"
[[ -n "$AGENT" && -n "$PROMPT" ]] || { echo "jobs/$job.job needs AGENT and PROMPT" >&2; exit 2; }
limit="${TIMEOUT:-$CABINET_JOB_TIMEOUT}"
[[ "$limit" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "TIMEOUT in jobs/$job.job (or CABINET_JOB_TIMEOUT) must be whole minutes, or 0 for no limit, not '$limit'" >&2; exit 2; }
QUIET_DAYS="${QUIET_DAYS:-0}"
[[ "$QUIET_DAYS" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "QUIET_DAYS in jobs/$job.job must be whole days, or 0 to run every time, not '$QUIET_DAYS'" >&2; exit 2; }

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

# What a quiet run is judged by: every branch and remote branch of the workspace and its repos,
# the doctor's problems, and the result file as the last run left it. Fails when any of them has
# uncommitted changes: work pending for a day is asked about, so it never counts as quiet.
quiet_state() {
  local d
  while IFS= read -r d; do
    [[ -e "$d/.git" ]] || continue
    [[ -z "$(git -C "$d" status --porcelain 2>/dev/null)" ]] || return 1
    echo "$d"; git -C "$d" for-each-ref --format='%(refname) %(objectname)'
  done < <(data_dirs)
  { "$WS/bin/doctor.sh" --json 2>/dev/null || true; } | jq -r '.results[] | select(.level == "fix") | .id' | sort -u
  [[ -f "$WS/$RESULT" ]] && sha256 "$WS/$RESULT"
}
state_file="$LOGDIR/$job.quiet"   # the start of the last full run, and quiet_state after it
remember() {
  local s
  if ((QUIET_DAYS)) && s="$(quiet_state)"; then printf '%s\n%s\n' "$started" "$(printf '%s' "$s" | sha256 /dev/stdin)" > "$state_file"; else rm -f "$state_file"; fi
}
# Skip when nothing changed since the last full run, for at most QUIET_DAYS days after it, and never
# while a reversible sign-off item waits: it goes ahead after 72 hours, and only a run says so.
quiet() {
  local since was s
  ((QUIET_DAYS)) && [[ -f "$state_file" && -f "$WS/$RESULT" ]] || return 1
  { read -r since; read -r was; } < "$state_file" || return 1
  [[ "$since" =~ ^[0-9]+$ ]] && (( $(date +%s) - since < QUIET_DAYS * 86400 )) || return 1
  awk '/^## / { q = ($0 == "## Sign-off queue") } q && tolower($0) ~ /default/ { f = 1 } END { exit f }' "$WS/$RESULT" || return 1
  s="$(quiet_state)" && [[ "$(printf '%s' "$s" | sha256 /dev/stdin)" == "$was" ]]
}

after() { [[ -z "$AFTER" ]] || (cd "$WS" && bash -c "$AFTER") >>"$log" 2>&1 || echo "after-step failed: see the lines above" >>"$log"; }

cd "$WS"
mkdir -p -m 700 "$LOGDIR"
log="$LOGDIR/$job.log"
started="$(date +%s)"
SPEND_LABEL="$job"
# The run's cost and the week's, when the tool reported it.
cost() {
  [[ "$(spend_since "$started" "$job")" != 0.00 ]] || return 0
  echo "cost \$$(spend_since "$started" "$job"), $(spend_source); this week \$$(spend_since "$(week_start)")${CABINET_BUDGET:+ of the \$$CABINET_BUDGET budget}"
}
if [[ ! -t 1 ]] && quiet; then
  # Touched, so the digest and cabinet next see it as current, not late.
  msg="$job skipped: nothing changed since the full run of $(epoch_date "$(head -1 "$state_file")" '+%F %T') (QUIET_DAYS in jobs/$job.job)"
  echo "=== $(date '+%F %T') $msg" >>"$log"; echo "$msg"
  touch "$WS/$RESULT"
  exit 0
fi
echo "=== $(date '+%F %T') $job ($AGENT, $CABINET_RUNNER)" >>"$log"
rm -f "$state_file"
if [[ -t 1 ]]; then
  # Started by hand: say what is happening, then show the result here too.
  echo "Running $job with $AGENT. It takes $MINUTES minutes and prints nothing until it finishes."
  echo "Result: $RESULT and $log"
  start=$SECONDS status=0
  limited 2>&1 | tee -a "$log" || status=$?
  cost | tee -a "$log"
  ((status)) || { after; remember; }
  echo
  echo "Finished in $(( (SECONDS - start) / 60 )) min (exit $status). Open $RESULT."
  exit "$status"
fi
st=0; limited >>"$log" 2>&1 || st=$?
cost >>"$log"
((st == 0)) || { echo "exit $st at $(date '+%T'): see the lines above" >>"$log"; exit 1; }
after
remember
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  run) j_run "$@" ;;
  list) j_list "$@" ;;
  *) echo "usage: bin/job.sh run <job> | list [--json]" >&2; exit 2 ;;
esac
