#!/usr/bin/env bash
# Specs, one per feature in specs/ (.cabinet/rules/ready-to-build.md).
#
#   bin/spec.sh check [spec] [--json]
#       Every spec (or one) against what its status needs. ready: acceptance criteria, no TBD in
#       Rules, every decision answered, its repos (or workspace areas) named, and a qa PASS on the
#       acceptance criteria as they are now; for one built in a repo a web or mobile builder owns, with
#       design-lead on the team, also a "## Design" section with a design-lead PASS on it as it is now. building: also a plan for each repo ("### <repo>" under "## Plan"), and, for
#       more than one repo, an architect PASS on the plan as it is now. draft, shipped and dropped
#       need nothing. Prints each spec with its problems; exit 1 when any has one.
#       --json: [{spec, status, problems}].
#   bin/spec.sh record <spec> --role qa|architect|design-lead <PASS|BLOCK> --note <file>
#       A review of a spec: qa of its acceptance criteria (can each be tested?), architect of its
#       plan, design-lead of its design. Writes, or replaces, the role's "- Verdict:" line under "## Reviews" with today's date
#       and a fingerprint of the part reviewed, so a later change to it needs a new review, and
#       commits the spec. The spec and the note must be committed.
#   bin/spec.sh run <spec> [--retries <n>] [--dry-run]
#       Move a spec that is ready to build until all its work is ready to push, an agent run per step:
#       chief-of-staff routes it (one handoff per builder, --spec), each builder writes its plan, and
#       for more than one repo architect reviews the plan; then each of its handoffs is run in order
#       (bin/handoff.sh run, with --retries). It stops at the first step that does not finish, as
#       handoff run does. Logged as run-<spec>.log; routing, plans and review are recorded under the
#       spec's path in the spend file, each handoff's runs under its ID.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# spec_py check <spec>... | record <spec> <role> <verdict> <date> <note>: reads and writes specs.
spec_py() {
  local mode=$1; shift
  node "$LIBJS" "spec-$mode" "$WS" "$@"
}

s_check() {
local json=0 one="" f
local -a files
files=()
while (($#)); do
  case "$1" in
    --json) json=1; shift ;;
    -*) echo "unknown option $1. usage: bin/spec.sh check [spec] [--json]" >&2; exit 2 ;;
    *) [[ -z "$one" ]] || { echo "one spec at a time. usage: bin/spec.sh check [spec] [--json]" >&2; exit 2; }; one="$1"; shift ;;
  esac
done
if [[ -n "$one" ]]; then
  if [[ -f "$one" ]]; then one="$(cd "$(dirname "$one")" && pwd -P)/$(basename "$one")"; one="${one#"$WS"/}"; fi
  [[ "$one" =~ ^specs/[^/]+\.md$ && -f "$WS/$one" ]] || { echo "no spec $one (a file specs/<feature>.md in the workspace)" >&2; exit 2; }
  files=("$one")
else
  for f in "$WS"/specs/*.md; do
    [[ -f "$f" ]] || continue
    case "${f##*/}" in _template.md|ROADMAP.md) continue ;; esac
    files+=("specs/${f##*/}")
  done
fi
local out='[]' n o ui=""
# What people see is designed first, when design-lead is on the team (.cabinet/rules/ready-to-build.md).
if has "$(team_roles)" design-lead; then
  for n in $(repos 2>/dev/null | cut -f1); do o="$(owner_of "$n")"; [[ "$o" == web || "$o" == mobile ]] && ui+="$n "; done
fi
((${#files[@]})) && out="$(UI_REPOS="$ui" AREAS="$(critical_areas | cut -f1 | tr '\n' ' ')" spec_py check "${files[@]}")"
if ((json)); then json '$' <<<"$out"
else
  json -r --each '$.map((s) => s.spec + " (" + (s.status || "no status") + "): " + (s.problems.length ? s.problems.join("; ") : "ok"))' <<<"$out"
  [[ "$(json '$.filter((s) => s.problems.length).length' <<<"$out")" == 0 ]] && echo "Every spec has what its status needs." \
    || echo "Not ready for their status: fix each problem, or set the spec's status back (draft)."
fi
[[ "$(json '$.filter((s) => s.problems.length).length' <<<"$out")" == 0 ]]
}

s_record() {
usage="usage: bin/spec.sh record <spec> --role qa|architect|design-lead <PASS|BLOCK> --note <file>"
local spec="" role="" verdict="" note="" rel
while (($#)); do
  case "$1" in
    --role|--note)
      (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }
      [[ "$1" == --role ]] && role="$(printf %s "$2" | tr '[:upper:]' '[:lower:]')" || note="$2"
      shift 2 ;;
    -*) echo "unknown option $1. $usage" >&2; exit 2 ;;
    *) if [[ -z "$spec" ]]; then spec="$1"; elif [[ -z "$verdict" ]]; then verdict="$(printf %s "$1" | tr '[:lower:]' '[:upper:]')"; else echo "one verdict only. $usage" >&2; exit 2; fi; shift ;;
  esac
done
[[ -n "$spec" ]] || { echo "the spec first. $usage" >&2; exit 2; }
[[ "$role" =~ ^(qa|architect|design-lead)$ ]] || { echo "--role is qa (the acceptance criteria), architect (the plan) or design-lead (the design). $usage" >&2; exit 2; }
[[ "$verdict" =~ ^(PASS|BLOCK)$ ]] || { echo "the verdict is PASS or BLOCK. $usage" >&2; exit 2; }
[[ -n "$note" ]] || { echo "--note needs the file that holds the details. $usage" >&2; exit 2; }
spec="$(ws_md "the spec" "$spec")" || exit 1
[[ "$spec" =~ ^specs/[^/]+\.md$ && "$spec" != specs/_template.md && "$spec" != specs/ROADMAP.md ]] || { echo "$spec is not a spec (specs/<feature>.md)" >&2; exit 1; }
rel="$(ws_md --note "$note")" || exit 1
[[ "$rel" != "$spec" ]] || { echo "the note is the review's own file, not the spec" >&2; exit 1; }
spec_py record "$spec" "$role" "$verdict" "$(date +%F)" "$rel"
git -C "$WS" commit -q -m "specs: ${spec#specs/} $role $verdict" -- "$spec" || { echo "recorded on $spec, but the commit failed (see above): commit it yourself" >&2; exit 1; }
echo "$spec: $role $verdict recorded and committed"
}

s_run() {
usage="usage: bin/spec.sh run <spec> [--retries <n>] [--dry-run]"
local spec="" retries=2 dry=0 routed=0 step=0 st works w r o x c total
local -a pass
pass=()
while (($#)); do
  case "$1" in
    --retries) (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }; retries="$2"; pass+=(--retries "$2"); shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*) echo "unknown option $1. $usage" >&2; exit 2 ;;
    *) [[ -z "$spec" ]] || { echo "one spec at a time. $usage" >&2; exit 2; }; spec="$1"; shift ;;
  esac
done
[[ "$retries" =~ ^[0-9]+$ ]] || { echo "--retries is a number of fix rounds, like 2. $usage" >&2; exit 2; }
[[ -n "$spec" ]] || { echo "the spec first. $usage" >&2; exit 2; }
spec="$(ws_md "the spec" "$spec")" || exit 1
[[ "$spec" =~ ^specs/[^/]+\.md$ && "$spec" != specs/_template.md && "$spec" != specs/ROADMAP.md ]] || { echo "$spec is not a spec (specs/<feature>.md)" >&2; exit 1; }
cd "$WS"
sc() { "$WS/bin/spec.sh" check "$spec" --json 2>/dev/null | json -c '$[0]'; }
st="$(sc)"
[[ "$(json -r '$.status' <<<"$st")" =~ ^(ready|building)$ && "$(json '$.problems.length' <<<"$st")" == 0 ]] \
  || { echo "$spec is not ready to build: $(json -r '$.status + ": " + $.problems.join("; ")' <<<"$st") (bin/spec.sh check $spec)" >&2; exit 1; }

mkdir -p -m 700 "$LOGDIR"
local name="${spec#specs/}"; name="${name%.md}"
local lock="$K/run-spec-$name.lock" log="$LOGDIR/run-$name.log"
if ((dry == 0)); then
  mkdir "$lock" 2>/dev/null || { echo "$spec is already being run ($lock; remove the folder if no run is)" >&2; exit 1; }
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
fi
SPEND_LABEL="$spec"
local mark="$LOGDIR/run-spec-$name.stopped"
((dry)) || [[ -n "${CABINET_RUN_SCHEDULED:-}" ]] || rm -f "$mark"
say() { echo "$*"; ((dry)) || echo "=== $(date '+%F %T') $*" >>"$log"; }
stop() { say "Stopped: $1"; echo "Log: $log"; printf '%s %s\n' "$(date +%F)" "$1" > "$mark"; exit 1; }
agent() {  # agent <role> <what it does> <prompt>
  if run_over_limit; then say "Paused: this run's cost limit (\$$CABINET_RUN_LIMIT) is reached; the next run goes on from here"; exit 3; fi
  say "$1: $2"
  ((dry)) && exit 0
  AGENT=$1 PROMPT=$3
  run_limited "$CABINET_JOB_TIMEOUT" "the run's time limit (CABINET_JOB_TIMEOUT in cabinet.env)" >>"$log" 2>&1 || stop "$1 did not finish (exit $?): see the log"
}
# Its work: every handoff filed with --spec for it, not sent back, oldest first (the order routing set).
work() { readiness | json -r --each --arg s "$spec" 'Object.keys($).filter((k) => $[k].spec == $s && !/^rejected/.test($[k].status_now)).sort()'; }
while :; do
  step=$((step + 1)); ((step <= 20)) || stop "more steps than a spec takes; the owner looks at it"
  works="$(work)"
  if [[ -z "$works" ]]; then
    ((routed == 0)) || stop "chief-of-staff routed nothing for $spec"
    agent chief-of-staff "routes $spec" "Route $spec as your role says (\"Routing a task\"): one handoff per owning builder, each filed with --spec $spec, ordered by dependency, a later entry naming the earlier IDs it depends on, as that section says. Route nothing else."
    routed=1; continue
  fi
  st="$(sc)"
  x="$(json -r --each '$.missing_plans' <<<"$st" | head -1)"
  if [[ -n "$x" ]]; then
    o="$(owner_of "$x")"; [[ -n "$o" ]] || stop "$x has no owning role in the team table, so no one plans it"
    agent "$o" "plans $x" "Write your plan for $x in $spec, under \"## Plan\" as \"### $x\" (.cabinet/rules/ready-to-build.md): the files you change, the tests you add, the order across repos, the risks. Commit the spec. Do not build yet."
    [[ "$(sc | json --arg x "$x" '$.missing_plans.includes($x)')" == false ]] || stop "$o wrote no plan for $x in $spec"
    continue
  fi
  if [[ "$(json '$.repos.length' <<<"$st")" -gt 1 && "$(json -r '$.plan_review' <<<"$st")" != PASS ]]; then
    [[ "$(json -r '$.plan_review' <<<"$st")" != BLOCK ]] || stop "architect blocked the plan in $spec: the builders revise it (its note says why), then run again"
    agent architect "reviews the plan in $spec" "Review the plan in $spec as your role says, then record bin/spec.sh record $spec --role architect PASS|BLOCK --note specs/adr/<note>.md."
    [[ "$(sc | json -r '$.plan_review')" =~ ^(PASS|BLOCK)$ ]] || stop "architect recorded no review of the plan in $spec"
    continue
  fi
  for w in $works; do
    if ((dry)); then "$WS/bin/handoff.sh" run "$w" --dry-run; exit 0; fi
    say "running $w"
    x=0; "$WS/bin/handoff.sh" run "$w" ${pass[@]+"${pass[@]}"} || x=$?
    ((x != 3)) || exit 3   # the cost limit: paused, not stopped
    ((x == 0)) || stop "$w did not reach ready to push (see above), so the rest of $spec waits"
  done
  # What it cost: routing, plans and review under the spec, each handoff's runs under its ID.
  total="$(awk -F'\t' -v l=" $spec $(printf '%s' "$works" | tr '\n' ' ') " 'index(l, " " $2 " ") { t += $4 } END { printf "%.6f", t }' "$SPEND" 2>/dev/null || echo 0)"
  say "$spec is ready to push: all its work ($(printf '%s' "$works" | paste -sd ' ' - | sed 's/ /, /g')) passed review$(awk -v t="$total" 'BEGIN { if (t > 0) printf ", $%.2f in all", t }'). Push it from your terminal."
  rm -f "$mark"; exit 0
done
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  check) s_check "$@" ;;
  record) s_record "$@" ;;
  run) s_run "$@" ;;
  *) echo "usage: bin/spec.sh check|record|run (see the top of this file)" >&2; exit 2 ;;
esac
