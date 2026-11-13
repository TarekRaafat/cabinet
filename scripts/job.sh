#!/usr/bin/env bash
# The workspace's scheduled agent jobs: jobs/<job>.job, each run headless by the configured agent
# tool. launchd starts them (bin/bootstrap.sh installs the schedules); run one by hand to see it
# now. Logs go to ~/Library/Logs/cabinet/<slug>/.
#
#   bin/job.sh run <job>
#       Run it now. The agent tool comes from CABINET_RUNNER in cabinet.env: claude, codex, antigravity,
#       qwen, grok, opencode, cursor, or custom (CABINET_RUNNER_CMD, any other tool). One run of a job
#       at a time on this machine: a run takes the job's lock first, and a second run while it is held
#       starts nothing ("<job> is already running (process <pid>): this run started nothing", exit 1).
#       Every run, a COMMAND job's too, is stopped after TIMEOUT minutes (the job's, else
#       CABINET_JOB_TIMEOUT; 0 for none). A failed after-step (AFTER) fails the run (exit 1). A scheduled
#       run of a job with QUIET_DAYS is skipped when nothing changed since its last full run; RESULT must
#       then be a file inside the workspace, or every run is a full run. A job with COMMAND instead of
#       AGENT and PROMPT runs that command in the workspace (the pipeline job: bin/handoff.sh run
#       --scheduled, with TIMEOUT="0"). MODEL="<name>" in an agent job asks for that model in place of
#       CABINET_MODEL; a COMMAND job with MODEL is refused.
#   bin/job.sh list [--by-model] [--json]
#       Every job: its name, role, schedule, time limit and what it cost this week, with the week's
#       total and budget (CABINET_BUDGET), from what the agent tool reports. --by-model: this week's cost
#       per model and effort instead, from every run cabinet started (spend.tsv, columns 8 and 9): rows
#       "<model> <effort or -> $<dollars>", sorted by model, tool-default (no model asked for) and then
#       unknown (a row from before the columns) last; JSON [{model, effort, cost_this_week_usd}], with
#       model null for the tool's default and effort null for none.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

j_list() {
  local json=0 bymodel=0 a jf ws reported=0
  for a in "$@"; do case "$a" in --json) json=1 ;; --by-model) bymodel=1 ;; *) echo "usage: bin/job.sh list [--by-model] [--json]" >&2; exit 2 ;; esac; done
  ws="$(week_start)"; spend_counts && reported=1
  if ((bymodel)); then
    # One pass over this week's rows; dollars counted as spend_since counts them.
    LC_ALL=C awk -F'\t' -v s="$ws" '$1 >= s && $4 ~ /^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/ {
        k = (NF < 9 ? "unknown\t" : ($8 == "" ? "tool-default" : $8) "\t" $9); t[k] += $4 }
      END { for (k in t) { split(k, x, "\t"); o = (x[1] == "unknown" ? 2 : x[1] == "tool-default" ? 1 : 0); printf "%d\t%s\t%s\t%.2f\n", o, x[1], x[2], t[k] } }' "$([[ -f "$SPEND" ]] && echo "$SPEND" || echo /dev/null)" 2>/dev/null \
      | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3 | cut -f2- \
      | if ((json)); then json -R '$.map((l) => l.split("\t")).map((r) => ({model: r[0] == "tool-default" ? null : r[0], effort: r[1] || null, cost_this_week_usd: num(r[2])}))'
        else awk -F'\t' 'BEGIN { n = 0 } { n++; printf "%s %s $%s\n", $1, ($2 == "" ? "-" : $2), $3 } END { if (!n) print "No runs this week." }'; fi
    return 0
  fi
  # Each job as the reader read it (lib.sh): a file whose name is not a job name is left out, and an
  # unreadable one is said on stderr, by its message, while the others are listed.
  for jf in "$WS"/jobs/*.job; do
    [[ -f "$jf" ]] || job_bad "$(basename "$jf" .job)" >/dev/null || continue   # a link to nothing is said by its message
    j="$(basename "$jf" .job)"
    job_name_ok "$j" || continue
    if m="$(job_bad "$j")"; then shown "$m" >&2; echo >&2; continue; fi
    ( AGENT="$(job_get "$j" AGENT)" COMMAND="$(job_get "$j" COMMAND)" WHEN="$(job_get "$j" WHEN)" TIMEOUT="$(job_get "$j" TIMEOUT)"
      printf '%s\t%s\t%s\t%s\t%s\n' "$j" "${AGENT:-${COMMAND:+command}}" "$([[ -n "$WHEN" ]] && when_human "$WHEN" || echo "by hand only")" "${TIMEOUT:-$CABINET_JOB_TIMEOUT}" \
        "$( ((reported)) && spend_since "$ws" "$j")" )
  done | if ((json)); then json -R '$.map((l) => l.split("\t")).map((r) => ({name: r[0], role: r[1], when: r[2], timeout_minutes: num(r[3]), cost_this_week_usd: num(r[4])}))'
         else awk -F'\t' 'BEGIN {n = 0} {n++; printf "%-16s %-18s %-34s %4s min  %s\n", $1, $2, $3, $4, ($5 == "" ? "-" : "$" $5)} END {if (!n) print "No jobs in jobs/."}'; fi
  ((json)) && return 0
  if ((reported)); then echo "This week: \$$(spend_since "$ws") in all, $(spend_source), $( [[ -n "$CABINET_BUDGET" ]] && echo "of a \$$CABINET_BUDGET budget" || echo "no budget set (cabinet config --budget <dollars>)")."
  elif has "$SPEND_TOKENS" "$CABINET_RUNNER"; then echo "Cost: $CABINET_RUNNER reports tokens, not dollars: set its price to count them (cabinet config --price \"<input> <output> [<cached input>]\")."
  else echo "Cost: $CABINET_RUNNER does not report what a run costs, so cabinet cannot count it."; fi
}

j_run() {
job="${1:-}"; [[ -n "$job" ]] || { echo "usage: bin/job.sh run <job> (one of: $(cd "$WS/jobs" 2>/dev/null && ls *.job 2>/dev/null | sed 's/\.job$//' | tr '\n' ' '))" >&2; exit 2; }
# The name becomes a file path and a log's name: checked before either is built.
job_name_ok "$job" || { echo "not a job name: $(shown "$job")" >&2; exit 2; }
jf="$WS/jobs/$job.job"
[[ -f "$jf" ]] || { echo "unknown job: $job (no jobs/$job.job)" >&2; exit 2; }
# MODEL too: one from the caller's environment never applies, nor is passed on.
unset MODEL
# Every run of a job is a scheduled run, a COMMAND job's too: --force never deletes in one (lib.js delete-plan).
export CABINET_JOB="$job"
# Read as text (lib.sh): an unreadable job file runs nothing.
if m="$(job_bad "$job")"; then shown "$m" >&2; echo >&2; exit 2; fi
AGENT="" PROMPT="" COMMAND="" MINUTES="a few" RESULT="the log" AFTER="" TIMEOUT="" QUIET_DAYS="" MODEL=""
job_set "$job"
[[ -z "$AGENT" ]] || role_ok "$AGENT" || { echo "jobs/$job.job: AGENT \"$(shown "$AGENT")\" is not a role name" >&2; exit 2; }
[[ -n "$AGENT" && -n "$PROMPT" ]] || [[ -n "$COMMAND" ]] || { echo "jobs/$job.job needs AGENT and PROMPT, or COMMAND" >&2; exit 2; }
[[ -z "$COMMAND" || -z "$MODEL" ]] || { echo "jobs/$job.job sets MODEL, but it runs COMMAND, whose agent runs use CABINET_MODEL: remove the MODEL line, or set the model with cabinet config --model" >&2; exit 2; }
limit="${TIMEOUT:-$CABINET_JOB_TIMEOUT}"
[[ "$limit" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "TIMEOUT in jobs/$job.job (or CABINET_JOB_TIMEOUT) must be whole minutes, or 0 for no limit, not '$limit'" >&2; exit 2; }
QUIET_DAYS="${QUIET_DAYS:-0}"
[[ "$QUIET_DAYS" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "QUIET_DAYS in jobs/$job.job must be whole days, or 0 to run every time, not '$QUIET_DAYS'" >&2; exit 2; }
# A command from the files runs only once approved on this machine; nothing runs when one is not.
[[ -z "$COMMAND" ]] || approved "jobs/$job.job" COMMAND "$COMMAND" || { not_approved "jobs/$job.job" COMMAND >&2; exit 1; }
[[ -n "$COMMAND" || "$CABINET_RUNNER" != custom ]] || approved cabinet.env CABINET_RUNNER_CMD "$CABINET_RUNNER_CMD" || { not_approved cabinet.env CABINET_RUNNER_CMD >&2; exit 1; }

# A COMMAND as an agent: its own process group, stopped at the limit with everything it started.
limited() {
  local why="the job's time limit (TIMEOUT in jobs/$job.job, or CABINET_JOB_TIMEOUT)"
  if [[ -n "$COMMAND" ]]; then run_limited "$limit" "$why" bash -c "$COMMAND"; return; fi
  run_limited "$limit" "$why" run_agent "$MODEL" "jobs/$job.job"
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
  { "$WS/bin/doctor.sh" --json 2>/dev/null || true; } | json -r --each '$.results.filter((x) => x.level == "fix").map((x) => x.id)' | sort -u
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

after() {
  [[ -n "$AFTER" ]] || return 0
  approved "jobs/$job.job" AFTER "$AFTER" 2>>"$log" || { not_approved "jobs/$job.job" AFTER >>"$log"; return 0; }
  (cd "$WS" && bash -c "$AFTER") >>"$log" 2>&1 && return 0
  echo "after-step failed: see the lines above" >>"$log"; return 1
}

cd "$WS"
mkdir -p -m 700 "$LOGDIR"
log="$LOGDIR/$job.log"
# One run of a job at a time: the folder <log folder>/<job>.lock (this machine's, never in the workspace)
# holds this run's process ID, and the EXIT trap removes it however the run ends, while it still holds that
# ID. A lock whose run is gone (writer_gone in lib.sh) is taken over; any other means a second run, which
# starts nothing. Its file run says what runs now (cabinet status; run_note in lib.sh). Names other than
# pid, which run_limited sets.
# ponytail: a run that saw the lock stale just as another took it over could move the new lock; a lost race refuses.
# ponytail: a process ID reused after a crash reads as a running job until that process ends; the refusal names it.
job_lock="$LOGDIR/$job.lock" lock_held=""
take_lock() { mkdir "$job_lock" 2>/dev/null || return 1; lock_held=1; trap release_lock EXIT; echo $$ > "$job_lock/pid"; RUN_LOCK="$job_lock" RUN_KIND=job RUN_WORK="$job"; run_note "" "" ""; }
release_lock() { [[ -z "${lock_held:-}" || "$(cat "$job_lock/pid" 2>/dev/null)" != "$$" ]] || rm -rf "$job_lock"; }
if ! take_lock; then
  lock_pid="$(cat "$job_lock/pid" 2>/dev/null || true)"
  if writer_gone "$lock_pid" "$job_lock" && mv "$job_lock" "$job_lock.stale.$$" 2>/dev/null; then
    rm -rf "$job_lock.stale.$$"
    take_lock || lock_pid="$(cat "$job_lock/pid" 2>/dev/null || true)"
  fi
  if [[ -z "$lock_held" ]]; then
    # The ID is named only when it is one: a file's text never reaches the terminal.
    [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && lock_pid="process $lock_pid" || lock_pid="process unknown"
    msg="$job is already running ($lock_pid): this run started nothing"
    echo "$msg" >>"$log"; echo "$msg" >&2
    exit 1
  fi
fi
# RESULT counts for QUIET_DAYS only as a file inside the workspace (lib.js inside-file): otherwise nothing
# at it is read or touched, and the run is a full one.
result_note=""
if ((QUIET_DAYS)) && ! node "$LIBJS" inside-file "$WS" "$RESULT"; then
  result_note="$job: RESULT \"$(shown "$RESULT")\" is not a file inside the workspace, so QUIET_DAYS does not apply: a full run"
  QUIET_DAYS=0
fi
started="$(date +%s)"
SPEND_LABEL="$job"
# The run's cost and the week's, when the tool reported it.
cost() {
  # Any recorded run counts: one under half a cent rounds to 0.00 and still cost something.
  awk -F'\t' -v s="$started" -v l="$job" '$1 >= s && $2 == l { f = 1 } END { exit !f }' "$SPEND" 2>/dev/null || return 0
  local c; c="\$$(spend_since "$started" "$job")"; [[ "$c" != '$0.00' ]] || c='under $0.01'
  echo "cost $c, $(spend_source); this week \$$(spend_since "$(week_start)")${CABINET_BUDGET:+ of the \$$CABINET_BUDGET budget}"
}
if [[ ! -t 1 ]] && quiet; then
  # Touched, so the digest and cabinet next see it as current, not late.
  msg="$job skipped: nothing changed since the full run of $(epoch_date "$(head -1 "$state_file")" '+%F %T') (QUIET_DAYS in jobs/$job.job)"
  echo "=== $(date '+%F %T') $msg" >>"$log"; echo "$msg"
  touch "$WS/$RESULT"
  exit 0
fi
echo "=== $(date '+%F %T') $job (${AGENT:-$COMMAND}, $CABINET_RUNNER)" >>"$log"
[[ -z "$result_note" ]] || echo "$result_note" >>"$log"
rm -f "$state_file"
# How long it took, logged by hand and unattended, after AFTER (lib.js estimate reads it back).
took() { echo "=== $(date '+%F %T') $job took $(estimate took "$started") (exit $1)" >>"$log"; }
if [[ -t 1 ]]; then
  # Started by hand: say what is happening, with how long it should take, then show the result here too.
  estimate job "$job" "$MINUTES" "$limit"
  echo "Running $job with ${AGENT:-$COMMAND}. It takes $MINUTES minutes and prints nothing until it finishes."
  echo "Result: $RESULT and $log"
  status=0
  limited 2>&1 | tee -a "$log" || status=$?
  cost | tee -a "$log"
  ((status)) || { after || status=1; ((status)) || remember; }
  took "$status"
  echo
  echo "Finished in $(estimate took "$started") (exit $status). Open $RESULT."
  exit "$status"
fi
st=0; limited >>"$log" 2>&1 || st=$?
cost >>"$log"
((st == 0)) || { took "$st"; echo "exit $st at $(date '+%T'): see the lines above" >>"$log"; exit 1; }
after || { took 1; exit 1; }
took 0
remember
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  run) j_run "$@" ;;
  list) j_list "$@" ;;
  *) echo "usage: bin/job.sh run <job> | list [--by-model] [--json]" >&2; exit 2 ;;
esac
