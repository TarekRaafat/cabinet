#!/usr/bin/env bash
# Run one scheduled agent job headless. Each job is jobs/<job>.job in the
# workspace; launchd starts it (bin/bootstrap.sh installs the schedule), or
# run it by hand to see it now. Logs go to ~/Library/Logs/cabinet/<slug>/.
#
#   bin/scheduled.sh <job>
#
# The agent tool comes from CABINET_RUNNER in cabinet.env: claude, codex, gemini,
# qwen, grok, opencode, cursor, or custom (CABINET_RUNNER_CMD, any other tool).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

job="${1:?usage: scheduled.sh <job> (one of: $(cd "$WS/jobs" 2>/dev/null && ls *.job 2>/dev/null | sed 's/\.job$//' | tr '\n' ' '))}"
jf="$WS/jobs/$job.job"
[[ -f "$jf" ]] || { echo "unknown job: $job (no jobs/$job.job)" >&2; exit 2; }
AGENT="" PROMPT="" MINUTES="a few" RESULT="the log" AFTER=""
# shellcheck disable=SC1090
source "$jf"
[[ -n "$AGENT" && -n "$PROMPT" ]] || { echo "jobs/$job.job needs AGENT and PROMPT" >&2; exit 2; }

run_agent() {
  # Tools without cabinet's named agents get the role file as their first instruction.
  local as_role="Act as the $AGENT role: read agents/$AGENT.md and follow it as your instructions. $PROMPT"
  case "$CABINET_RUNNER" in
    claude)   claude -p --agent "$AGENT" --permission-mode auto "$PROMPT" ;;
    codex)    codex exec "$as_role" ;;
    gemini)   gemini -p "$as_role" ;;
    qwen)     qwen --approval-mode auto "$as_role" ;;
    grok)     grok -p "$as_role" --permission-mode auto ;;
    opencode) opencode run "$as_role" ;;
    # --force lets print mode write files (the brief); deny rules are the guardrail.
    cursor)   "$(cursor_bin || echo cursor-agent)" -p --force "$as_role" ;;
    # Any other tool: CABINET_RUNNER_CMD runs with the prompt in $CABINET_PROMPT
    # and the role name in $CABINET_AGENT, for example 'mytool --run "$CABINET_PROMPT"'.
    custom)
      [[ -n "${CABINET_RUNNER_CMD:-}" ]] || { echo "CABINET_RUNNER=custom needs CABINET_RUNNER_CMD in cabinet.env" >&2; return 2; }
      CABINET_AGENT="$AGENT" CABINET_PROMPT="$as_role" bash -c "$CABINET_RUNNER_CMD" ;;
    *) echo "unknown CABINET_RUNNER: $CABINET_RUNNER ($RUNNERS or custom)" >&2; return 2 ;;
  esac
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
  run_agent 2>&1 | tee -a "$log" || status=$?
  ((status)) || after
  echo
  echo "Finished in $(( (SECONDS - start) / 60 )) min (exit $status). Open $RESULT."
  exit "$status"
fi
run_agent >>"$log" 2>&1 || { echo "exit $? at $(date '+%T'): see the lines above" >>"$log"; exit 1; }
after
