# Shared by every bin/*.sh: the workspace path, its cabinet.env, and the names
# every machine-wide thing is scoped by, so two projects (or two kits) never
# share a schedule, a log folder or a secret. Sourced, never run.

# The real path, symlinks resolved, so the same workspace always has the same name.
WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LIBJS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.js"   # the scripts' JavaScript, run with node
[[ -f "$WS/cabinet.env" ]] || { echo "no cabinet.env in $WS" >&2; exit 1; }
CABINET_UPDATE_ENV="${CABINET_UPDATE_CHECK-}"   # the environment's, before cabinet.env (platform.sh, update_on)
# shellcheck disable=SC1091
source "$WS/cabinet.env"
source "$WS/bin/when.sh"   # when_norm, when_calendar, when_human: one parser for every schedule
source "$WS/bin/platform.sh"   # this machine: logs, dates, the passphrase, schedules (launchd, systemd or cron)
: "${CABINET_SLUG:?set CABINET_SLUG in cabinet.env}"
CABINET_ROLES="${CABINET_ROLES:-}"
CABINET_RUNNER="${CABINET_RUNNER:-claude}"
CABINET_RUNNER_CMD="${CABINET_RUNNER_CMD:-}"
CABINET_MODEL="${CABINET_MODEL:-}"   # the model every run asks for; empty: the tool's default
# A model name, checked before it reaches a tool (bin/cabinet checks the same): never a leading -, which
# a tool would read as an option of its own.
model_ok() {
  local LC_ALL=C re='^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,99}$'   # C: A-Z is ASCII only
  [[ "$1" =~ $re ]]
}
RUNNERS="claude codex antigravity qwen grok opencode cursor"   # built in; "custom" runs CABINET_RUNNER_CMD
CABINET_BACKUP_DIR="${CABINET_BACKUP_DIR:-}"
CABINET_BACKUP_TIME="${CABINET_BACKUP_TIME:-1:00 PM}"
CABINET_BACKUP_KEEP="${CABINET_BACKUP_KEEP:-14}"
CABINET_JOB_TIMEOUT="${CABINET_JOB_TIMEOUT:-60}"
CABINET_BUDGET="${CABINET_BUDGET:-}"   # US dollars a week for the agent runs cabinet starts; empty: none
CABINET_PIPELINE="${CABINET_PIPELINE:-off}"   # what the scheduled runner may move: off, small or all
CABINET_PIPELINE_LIMIT="${CABINET_PIPELINE_LIMIT:-}"   # US dollars one scheduled run may spend
# Settings for this machine only, in cabinet.local.env: never committed (the workspace's
# .gitignore tracks only its own files), so each teammate's machine keeps its own. Read, never
# sourced. CABINET_SCHEDULES="off": another machine runs the jobs (cabinet bootstrap --no-schedules).
# CABINET_BACKUP_DIR and CABINET_BACKUP_TIME, when present, replace cabinet.env's on this machine
# (cabinet config --this-machine); an empty CABINET_BACKUP_DIR turns backups off here.
LOCAL_ENV="$WS/cabinet.local.env"
local_has() { grep -q "^$1=" "$LOCAL_ENV" 2>/dev/null; }
local_get() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$LOCAL_ENV" 2>/dev/null | tail -1 || true; }
CABINET_SCHEDULES="$(local_get CABINET_SCHEDULES)"
[[ "$CABINET_SCHEDULES" == off ]] || CABINET_SCHEDULES=on
BACKUP_DIR_LOCAL=0
if local_has CABINET_BACKUP_DIR; then CABINET_BACKUP_DIR="$(local_get CABINET_BACKUP_DIR)"; BACKUP_DIR_LOCAL=1; fi
if local_has CABINET_BACKUP_TIME; then CABINET_BACKUP_TIME="$(local_get CABINET_BACKUP_TIME)"; fi
# Credit roles (cabinet config --credit-roles off|on): a commit made in a Cabinet run credits its role
# (guardrails/prepare-commit-msg). Read as written; only an exact "on" turns it on.
CREDIT_KIT_EMAIL="347351783+cabinet-team[bot]@users.noreply.github.com"
credit_email_ok() {   # a GitHub App's bot noreply email, exactly
  local LC_ALL=C re='^[0-9]+\+[a-z0-9]+(-[a-z0-9]+)*\[bot\]@users\.noreply\.github\.com$'   # C: a-z is ASCII only
  [[ "$1" =~ $re ]]
}
credit_shared() { [[ "${CABINET_LAYOUT:-}" == inside && "${CABINET_VISIBILITY:-}" == shared ]]; }
# In a shared workspace, off for everyone wins: while the committed setting is not on, it is the answer.
credit_project_wins() { credit_shared && [[ "${CABINET_CREDIT_ROLES-}" != on ]]; }
# Answered on this machine: cabinet.local.env's line, else cabinet.env's, except in a shared workspace,
# where each machine answers for itself (cabinet config --this-machine --credit-roles) while the project's is on.
credit_answered() {
  if credit_project_wins; then grep -q '^CABINET_CREDIT_ROLES=' "$WS/cabinet.env"
  else local_has CABINET_CREDIT_ROLES || { ! credit_shared && grep -q '^CABINET_CREDIT_ROLES=' "$WS/cabinet.env"; }; fi
}
credit_value() {   # the answer as written, or nothing
  if ! credit_project_wins && local_has CABINET_CREDIT_ROLES; then local_get CABINET_CREDIT_ROLES
  elif credit_answered; then printf '%s' "${CABINET_CREDIT_ROLES-}"; fi
}
credit_mode() { [[ "$(credit_value)" == on ]] && credit_email_ok "${CABINET_CREDIT_EMAIL:-$CREDIT_KIT_EMAIL}" && echo on || echo off; }

K="$WS/.cabinet"                                   # kit-managed files
LABEL="ai.cabinet.$CABINET_SLUG"                   # schedule labels: $LABEL.<job>
LOGDIR="$LOGROOT/$CABINET_SLUG"
KEYCHAIN_ITEM="cabinet.$CABINET_SLUG.backup"
# What the agent runs cabinet starts cost, as the tool reports it: one line per run, on this
# machine only: seconds, what ran ($SPEND_LABEL: the job, or "role draft <role>"), runner, US dollars.
SPEND="$LOGDIR/spend.tsv"
CABINET_PRICE="${CABINET_PRICE:-}"   # US dollars per million tokens: "<input> <output> [<cached input>]"
# The runners that report dollars, and those that report only tokens (dollars with CABINET_PRICE).
SPEND_DOLLARS="claude grok opencode"
SPEND_TOKENS="codex cursor qwen antigravity"
# How the week's dollars were found, for messages.
spend_source() { if has "$SPEND_DOLLARS" "$CABINET_RUNNER"; then echo "as $CABINET_RUNNER reports it"; else echo "priced from $CABINET_RUNNER's token counts"; fi; }
spend_counts() { has "$SPEND_DOLLARS" "$CABINET_RUNNER" || { has "$SPEND_TOKENS" "$CABINET_RUNNER" && [[ -n "$CABINET_PRICE" ]]; }; }
# What each runner's JSON says, as {text, usd, in, cached, out}: the reply, the dollars it reports,
# and tokens (in: uncached input). Shapes seen live (Grok 1.0.62, opencode 2.0.32, Codex 0.163.0,
# Cursor 2026.10.16, Antigravity CLI 1.4.2, Qwen Code 0.25.3's envelope) or documented (Claude Code).
spend_js() {
  case "$1" in
    claude)   echo '({text: $.result, usd: $.total_cost_usd})' ;;
    grok)     echo '({text: $.text, usd: $.total_cost_usd, in: $.usage?.input_tokens, cached: $.usage?.cache_read_input_tokens, out: $.usage?.output_tokens})' ;;
    cursor)   echo '({text: $.result, in: $.usage?.inputTokens, cached: $.usage?.cacheReadTokens, out: $.usage?.outputTokens})' ;;
    qwen)     echo '((r) => ({text: r?.result, in: r?.usage?.input_tokens, cached: r?.usage?.cache_read_input_tokens ?? 0, out: r?.usage?.output_tokens}))($.filter((x) => x.type == "result").at(-1))' ;;
    # ponytail: takes input_tokens to include cache_read_tokens (total_tokens leaves the cache out);
    # a run with cache reads, seen live, would settle it.
    antigravity) echo '({text: $.response, cached: $.usage?.cache_read_tokens ?? 0, out: ($.usage?.output_tokens ?? 0) + ($.usage?.thinking_tokens ?? 0),
                in: ($.usage?.input_tokens ?? 0) - ($.usage?.cache_read_tokens ?? 0)})' ;;
    # JSON lines, read with json -s.
    codex)    echo '((u) => ({text: $.filter((x) => x.type == "item.completed" && x.item?.type == "agent_message").map((x) => x.item.text).join("\n"),
                cached: sum(u.map((x) => x?.cached_input_tokens ?? 0)), out: sum(u.map((x) => x?.output_tokens ?? 0)),
                in: sum(u.map((x) => (x?.input_tokens ?? 0) - (x?.cached_input_tokens ?? 0)))}))($.filter((x) => x.type == "turn.completed").map((x) => x.usage))' ;;
    opencode) echo '((p) => ({text: $.filter((x) => x.type == "text").map((x) => x.part?.text ?? "").join(""), usd: sum(p.map((x) => x?.cost ?? 0)),
                in: sum(p.map((x) => x?.tokens?.input ?? 0)), cached: sum(p.map((x) => x?.tokens?.cache?.read ?? 0)),
                out: sum(p.map((x) => (x?.tokens?.output ?? 0) + (x?.tokens?.reasoning ?? 0)))}))($.filter((x) => x.type == "step_finish").map((x) => x.part))' ;;
  esac
}
# spend_report <out file>: print the reply from the runner's JSON (or the output as it is, when it
# is not that JSON) and record the run: dollars the tool reported, else priced from tokens.
spend_report() {
  local f="$1" j slurp="" usd tin tc tout
  case "$CABINET_RUNNER" in codex|opencode) slurp=-s ;; esac
  if ! j="$(json -c $slurp "$(spend_js "$CABINET_RUNNER")" "$f" 2>/dev/null)" || [[ "$(json -r 'typeof $.text' <<<"$j" 2>/dev/null)" != string ]]; then
    cat "$f"; return 0
  fi
  json -r '$.text' <<<"$j"
  read -r usd tin tc tout <<<"$(json -r '[$.usd, $.in, $.cached, $.out].map((x) => (x == null ? "-" : String(x))).join(" ")' <<<"$j")"
  if [[ "$usd" == - || "$usd" == 0 ]] && [[ -n "$CABINET_PRICE" && "$tin$tout" != -- ]]; then
    usd="$(awk -v p="$CABINET_PRICE" -v i="${tin/-/0}" -v c="${tc/-/0}" -v o="${tout/-/0}" \
      'BEGIN { n = split(p, x, " "); if (n < 3) x[3] = x[1]; printf "%.6f", (i * x[1] + c * x[3] + o * x[2]) / 1000000 }')"
  fi
  [[ "$usd" == - ]] && usd=""
  [[ -z "$usd$tin$tout" || "$usd$tin$tout" == -- ]] && return 0
  mkdir -p -m 700 "$LOGDIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${SPEND_LABEL:-$AGENT}" "$CABINET_RUNNER" "$usd" "${tin/-/}" "${tc/-/}" "${tout/-/}" >> "$SPEND"
}
# Midnight at the start of this week, the day "Week starts on" in AGENTS.md names (Sunday by default).
# ponytail: counts days as 24 hours, so in the week a clock changes the week starts an hour off.
week_start() {
  local d i=0 s=0 x now w h m sec
  d="$(sed -n 's/^- \*\*Week starts on:\*\* \([A-Za-z]*\)\..*/\1/p' "$WS/AGENTS.md" 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]' | cut -c1-3)"
  for x in sun mon tue wed thu fri sat; do [[ "$x" == "${d:-sun}" ]] && s=$i; i=$((i + 1)); done
  read -r now w h m sec <<<"$(date '+%s %w %H %M %S')"
  echo $(( now - 10#$h * 3600 - 10#$m * 60 - 10#$sec - (w - s + 7) % 7 * 86400 ))
}
# ws_md <what> <file>: a committed .md file under specs/ (a verdict's note, a spec), read from the
# caller's folder or else the workspace; printed from the workspace root. Safe characters only: the
# path is written into files a shell later reads.
ws_md() {
  local f=$2 abs
  if [[ -f "$f" ]]; then abs="$(cd "$(dirname "$f")" && pwd -P)/$(basename "$f")"
  elif [[ "$f" != /* && -f "$WS/$f" ]]; then abs="$(cd "$(dirname "$WS/$f")" && pwd -P)/$(basename "$f")"
  else echo "$1 $f: no such file" >&2; return 1; fi
  f="${abs#"$WS"/}"
  [[ "$f" =~ ^specs/[A-Za-z0-9._/-]+\.md$ ]] || { echo "$1 must be a .md file under specs/ in the workspace, named with letters, digits, . _ - and / only" >&2; return 1; }
  git -C "$WS" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && [[ -z "$(git -C "$WS" status --porcelain -- "$f")" ]] \
    || { echo "$f is not committed: commit it first" >&2; return 1; }
  printf '%s\n' "$f"
}
# run_over_limit: true when a run with a cost limit (CABINET_RUN_LIMIT dollars, spent since
# CABINET_RUN_SINCE, both set by a scheduled run) has reached it; checked before each agent starts.
run_over_limit() {
  [[ -n "${CABINET_RUN_LIMIT:-}" ]] || return 1
  awk -v s="$(spend_since "${CABINET_RUN_SINCE:-0}")" -v l="$CABINET_RUN_LIMIT" 'BEGIN { exit !(s + 0 >= l + 0) }'
}
# spend_since <seconds> [<label>]: dollars spent since then, by every run or one label's, as "1.25".
spend_since() { awk -F'\t' -v s="$1" -v l="${2:-}" '$1 >= s && (l == "" || $2 == l) { t += $4 } END { printf "%.2f", t }' "$SPEND" 2>/dev/null || printf '0.00'; }

# The agent runs in its own process group, so a run past its limit is stopped with
# everything it started: TERM, then KILL 10 seconds later. Exit 124, as timeout(1).
# Its own group misses Ctrl-C and launchd's stop, so those are passed on; it gets no
# terminal input, which a background group would stop on.
run_limited() {  # run_limited <minutes, 0 for none> <what set the limit> [<model> <its file>]: run_agent, stopped at the limit
  local limit=$1 why=$2; shift 2
  ((limit)) || { run_agent "$@"; return; }
  local secs=$((limit * ${CABINET_TEST_MINUTE:-60})) st=0   # CABINET_TEST_MINUTE: tests only
  # Stopped means the watchdog stopped it (it writes the mark), never that the clock moved past the
  # limit: a machine that sleeps during a run moves the clock, not the watchdog's timer.
  local mark; mark="$(mktemp "${TMPDIR:-/tmp}/cabinet-run.XXXXXX")"
  set -m; run_agent "$@" </dev/null & pid=$!; set +m
  node "$LIBJS" watchdog "$secs" "$pid" "$mark" & dog=$!
  trap 'kill -TERM -- "-$pid" "$dog" 2>/dev/null; rm -f "$mark"; exit 130' INT TERM
  wait "$pid" || st=$?
  trap - INT TERM
  kill "$dog" 2>/dev/null || true
  wait "$dog" 2>/dev/null || true   # collected quietly: no "Terminated" line from the shell
  if [[ -s "$mark" ]]; then rm -f "$mark"; echo "stopped after $limit min: $why" >&2; return 124; fi
  rm -f "$mark"
  return "$st"
}

# Run $AGENT on $PROMPT headless with the configured agent tool, in the current folder:
# scheduled jobs and role drafts.
run_agent() {  # run_agent [<model> <the file that set it>]: a job's MODEL, else CABINET_MODEL from cabinet.env
  local model="${1:-}" from="${2:-}"
  [[ -n "$model" ]] || { model="$CABINET_MODEL"; from=cabinet.env; }
  # First, for every runner: a model reaches a tool only as a name, never as code or an option.
  [[ -z "$model" ]] || model_ok "$model" || { echo "the model '$model' in $from is not a model name (letters, digits and . _ : / @ -, up to 100, not starting with -): no agent was started. Fix it, or cabinet config --model off" >&2; return 2; }
  local -a mo
  mo=(); [[ -z "$model" ]] || mo=(--model "$model")
  # Tools without cabinet's named agents get the role file as their first instruction.
  local as_role="Act as the $AGENT role: read agents/$AGENT.md and follow it as your instructions. $PROMPT"
  # Every runner gets the role in $CABINET_AGENT and the credit its commits carry (credit roles):
  # CABINET_CREDIT, on or off, and CABINET_CREDIT_ADDRESS, the email; the credit hook reads them.
  local credit address=""; credit="$(credit_mode)"
  [[ "$credit" == on ]] && address="${CABINET_CREDIT_EMAIL:-$CREDIT_KIT_EMAIL}"
  # Any other tool: CABINET_RUNNER_CMD runs with the prompt in $CABINET_PROMPT
  # and the role name in $CABINET_AGENT, for example 'mytool --run "$CABINET_PROMPT"'.
  if [[ "$CABINET_RUNNER" == custom ]]; then
    [[ -n "${CABINET_RUNNER_CMD:-}" ]] || { echo "CABINET_RUNNER=custom needs CABINET_RUNNER_CMD in cabinet.env" >&2; return 2; }
    CABINET_AGENT="$AGENT" CABINET_CREDIT="$credit" CABINET_CREDIT_ADDRESS="$address" CABINET_PROMPT="$as_role" CABINET_MODEL="$model" bash -c "$CABINET_RUNNER_CMD"; return
  fi
  [[ "$CABINET_RUNNER" != gemini ]] || { echo "CABINET_RUNNER=gemini is no longer a runner (Gemini CLI users moved to Antigravity): cabinet config --runner antigravity" >&2; return 2; }
  has "$RUNNERS" "$CABINET_RUNNER" || { echo "unknown CABINET_RUNNER: $CABINET_RUNNER ($RUNNERS or custom)" >&2; return 2; }
  # Each built-in runner prints JSON, for the cost it reports: the reply goes on to the log as
  # before, the cost to $SPEND (spend_report).
  local out st=0; out="$(mktemp)"
  # In a subshell, so the caller keeps none of the run's variables. The model, when there is one, is its
  # own argument right after the tool's --model option, before the prompt (docs/agent-setup.md).
  ( export CABINET_AGENT="$AGENT" CABINET_CREDIT="$credit" CABINET_CREDIT_ADDRESS="$address"
  case "$CABINET_RUNNER" in
    claude)   claude -p --agent "$AGENT" --permission-mode auto --output-format json ${mo[@]+"${mo[@]}"} "$PROMPT" ;;
    codex)    codex exec --json ${mo[@]+"${mo[@]}"} "$as_role" ;;
    # Headless agy denies what it cannot ask (--mode auto needs a plan that has it); skipping the
    # prompts keeps its deny rules, as the owner saw with a denied command (docs/guardrails.md).
    antigravity) agy ${mo[@]+"${mo[@]}"} -p "$as_role" --output-format json --dangerously-skip-permissions ;;
    qwen)     qwen --approval-mode auto -o json ${mo[@]+"${mo[@]}"} "$as_role" ;;
    grok)     grok ${mo[@]+"${mo[@]}"} -p "$as_role" --permission-mode auto --output-format json ;;
    opencode) opencode run --format json ${mo[@]+"${mo[@]}"} "$as_role" ;;
    # --force lets print mode write files (the brief); deny rules are the guardrail.
    cursor)   "$(cursor_bin || echo cursor-agent)" -p --force --output-format json ${mo[@]+"${mo[@]}"} "$as_role" ;;
  esac ) > "$out" || st=$?
  spend_report "$out"; rm -f "$out"; return "$st"
}

# Claude Code keeps per-folder memory under the folder's path with every non-alphanumeric as "-".
# One dash per character, whatever the locale (launchd runs without one).
claude_slug() {   # plain ASCII in bash; anything else through node, one character at a time
  if [[ "$1" =~ ^[\ -~]*$ ]]; then printf '%s' "${1//[^A-Za-z0-9]/-}"; else node "$LIBJS" slug "$1"; fi
}
CLAUDE_SLUG="$(claude_slug "$WS")"

# A workspace inside a project (cabinet init --inside) has the project as the folder above.
CABINET_LAYOUT="${CABINET_LAYOUT:-new}"
CABINET_VISIBILITY="${CABINET_VISIBILITY:-}"
HOST=""; [[ "$CABINET_LAYOUT" == inside ]] && HOST="$(cd "$WS/.." && pwd -P)"

# repos.tsv rows as "name url files link path", skipping comments and blanks.
# path is where the repo lives: absolute, ~/..., or relative to the workspace (default: its name).
# Windows line endings are tolerated; a row without tabs is skipped, and so is a
# name that is not a plain folder name (it becomes part of paths in local/ and backups).
repos() {
  [[ -f "$WS/repos.tsv" ]] || return 0
  awk -F'\t' -v OFS='\t' '{ sub(/\r$/, "") } !/^#/ && NF >= 2 {
    # The name is shown with each control character as ?: the row is skipped, so the name is only quoted.
    if ($1 !~ /^[A-Za-z0-9._-]+$/ || $1 == "." || $1 == "..") { n = $1; gsub(/[[:cntrl:]]/, "?", n); print "repos.tsv: skipped the row named \"" n "\" (not a plain folder name)" > "/dev/stderr"; next }
    if ($3 == "") $3 = "-"; if ($4 == "") $4 = "no"; if ($5 == "") $5 = $1; print $1, $2, $3, $4, $5 }' "$WS/repos.tsv"
}
# Where the workspace's pre-commit hook goes, or "none" when the workspace has no git of its
# own (a shared cabinet/ inside a project). The common dir, so it is right in a worktree too.
secrets_hook() {
  local top; top="$(cd "$(git -C "$WS" rev-parse --show-toplevel 2>/dev/null || echo /nonexistent)" 2>/dev/null && pwd -P || true)"
  [[ "$top" == "$WS" ]] || { echo none; return 0; }
  echo "$(git -C "$WS" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-commit"
}
repo_dir() { case "$1" in /*) echo "$1" ;; "~/"*) echo "$HOME/${1#"~/"}" ;; *) echo "$WS/$1" ;; esac; }

# The absolute, symlink-free form of a path that may not exist yet.
abspath() {
  local p="$1" tail=""
  case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#"~/"}" ;; /*) ;; *) p="$PWD/$p" ;; esac
  while [[ ! -d "$p" ]]; do tail="/${p##*/}$tail"; p="$(dirname "$p")"; done
  printf '%s%s' "$(cd "$p" && pwd -P)" "$tail"
}
# within <path> <folder>: true when path is the folder or inside it.
within() { local a b; a="$(abspath "$1")" b="$(abspath "$2")"; [[ "$a" == "$b" || "$a" == "$b"/* ]]; }

# Every folder the workspace holds data in: itself, its repos, and the project around it.
data_dirs() {
  local name url files link path d
  { echo "$WS"; [[ -n "$HOST" ]] && echo "$HOST"
    while IFS=$'\t' read -r name url files link path; do repo_dir "$path"; done < <(repos 2>/dev/null)
  } | while IFS= read -r d; do abspath "$d"; echo; done | awk '!seen[$0]++'
}

has() { [[ " $1 " == *" $2 "* ]]; }   # has "<words>" <word>

# The kit's builder roles. Each is built when it owns a repo in the team table of AGENTS.md,
# so the table is the one record of who builds what; CABINET_ROLES holds the other roles.
BUILDERS="backend web mobile infrastructure"
ROLES_OPTIONAL="brand-designer dba code-reviewer auditor"   # kit roles a project turns on (ROLES_OPT in bin/cabinet)
builders() {
  awk -F'|' '/^## / {on = ($0 ~ /^## The team/)} on && NF >= 4 && $2 ~ /`/ {o = $4; gsub(/^ +| +$/, "", o); print o}' "$WS/AGENTS.md" 2>/dev/null \
    | while IFS= read -r o; do has "$BUILDERS" "$o" && ! has "$CABINET_ROLES" "$o" && echo "$o"; done | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//'
}
team_roles() { echo $CABINET_ROLES $(builders); }
# team_rows: "<area>\t<owner>" for each row of the team table in AGENTS.md whose area is in backticks
# (a repo or a path), without the backticks or a trailing /.
team_rows() {
  awk -F'|' '/^## / {on = ($0 ~ /^## The team/)} on && NF >= 4 && $2 ~ /`/ {
      a = $2; o = $4; gsub(/[ `]/, "", a); sub(/\/$/, "", a); gsub(/^ +| +$/, "", o); if (a != "" && o != "") print a "\t" o
    }' "$WS/AGENTS.md" 2>/dev/null
}
# owner_of <path>: the owner of the most specific area in the team table that holds the path, or
# nothing (CABINET.md, "Ownership": the most specific row wins).
owner_of() {
  local p="${1%/}" a o best="" who=""
  while IFS=$'\t' read -r a o; do
    if [[ "$p" == "$a" || "$p" == "$a/"* ]] && (( ${#a} > ${#best} )); then best="$a" who="$o"; fi
  done < <(team_rows)
  printf '%s' "$who"
}
# role_team <role> <Field>: a line of the "## Team" section of roles/<role>.md ("- Reports to: qa"),
# the value only, or nothing (.cabinet/rules/seats.md, "Sub-teams").
role_team() {
  awk -v f="- $2:" '/^## / {t = ($0 == "## Team"); next} t && index($0, f) == 1 { sub(/^- [^:]*: */, ""); gsub(/`/, ""); print; exit }' "$WS/roles/$1.md" 2>/dev/null || true
}
# delegates: "<role>\t<lead>\t<covers, comma separated>\t<trial until>" for each role on the team that
# reports to a lead and covers work for it: its verdicts count for its lead's on that work.
delegates() {
  local r lead cov
  for r in $(team_roles); do
    lead="$(role_team "$r" "Reports to")"; cov="$(role_team "$r" "Covers")"
    [[ -n "$lead" && -n "$cov" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$r" "$lead" "$(printf '%s' "$cov" | tr -d ' ' | tr '[:upper:]' '[:lower:]')" "$(role_team "$r" "Trial until")"
  done
}
# readiness: {"<ID>": {verdicts, needs, missing, blocking, stale, ready, unread_verdicts}} for every
# entry. Needed: each reviewer the entry is addressed to, and for code (from a builder, or a verdict
# that names commits) qa, security and code-reviewer, with design-lead for a web or mobile builder,
# each when on the team. The work's commits are every commit a verdict names; a PASS counts only when
# it covers them all, so a fix after a PASS needs that reviewer again.
readiness() {
  local names builds ui n o
  names="$(repos 2>/dev/null | cut -f1 | tr '\n' ' ')"
  builds="$names $BUILDERS" ui="web mobile"
  while IFS=$'\t' read -r n o; do
    has "$names" "$n" || continue
    builds+=" $o"; [[ "$o" == web || "$o" == mobile ]] && ui+=" $n"
  done < <(team_rows)
  local -a arch
  arch=(); for n in "$WS"/handoffs/archive-*.md; do [[ -f "$n" ]] && arch+=("$n"); done
  # Critical areas, only when the project declares any: each named in the specs, and the areas the
  # commits of open entries' verdicts change.
  local areas="" touch="" sareas="" c a
  areas="$(critical_areas)"
  if [[ -n "$areas" ]]; then
    for c in $(grep -hoE '^- Verdict: [a-z0-9-]+ [A-Z]+ [0-9-]+ [0-9a-f]+(,[0-9a-f]+)*' "$WS/HANDOFFS.md" 2>/dev/null | awk '{ print $NF }' | tr ',' '\n' | sort -u); do
      while IFS= read -r a; do [[ -n "$a" ]] && touch+="$c"$'\t'"$a"$'\n'; done < <(areas_hit "$c")
    done
    for n in "$WS"/specs/*.md; do
      [[ -f "$n" ]] || continue
      # One area per comma, kept whole: a name can have spaces.
      while IFS= read -r c; do sareas+="specs/${n##*/}"$'\t'"$c"$'\n'; done < <(awk '/^---$/ { f++; next } f == 1 && /^areas:/ {
          sub(/^areas: *\[?/, ""); sub(/\].*$/, ""); sub(/ *#.*$/, ""); k = split($0, x, ",")
          for (i = 1; i <= k; i++) { gsub(/^[ \t]+|[ \t]+$/, "", x[i]); if (x[i] != "") print tolower(x[i]) }
          exit }' "$n")
    done
  fi
  WSDIR="$WS" TEAM="$(team_roles)" BUILDS="$builds" UI="$ui" DELEGATES="$(delegates)" AREAS="$areas" TOUCH="$touch" SAREAS="$sareas" node "$LIBJS" readiness "$SPEND" "$WS/HANDOFFS.md" ${arch[@]+"${arch[@]}"}
}
# builds_repos <name>: true when the name is a repo in repos.tsv, a kit builder, or the owning agent of
# a repo in the team table: whoever it is, work sent to it is built (.cabinet/rules/ready-to-build.md).
builds_repos() {
  local n=$1 names
  names="$(repos 2>/dev/null | cut -f1 | tr '\n' ' ')"
  has "$names $BUILDERS" "$n" && return 0
  awk -F'|' -v names=" $names " '/^## / {on = ($0 ~ /^## The team/)} on && NF >= 4 {
      a = $2; o = $4; gsub(/[ `]/, "", a); gsub(/^ +| +$/, "", o); if (index(names, " " a " ")) print o
    }' "$WS/AGENTS.md" 2>/dev/null | grep -qxF "$n"
}
# guarded_paths: "<repo>\t<path>" for every path a small task must not touch: the files contracts live
# in ("Source of truth" in the contracts table of AGENTS.md) and the paths under "Hard to undo", each
# written as `<repo>/<path>`.
guarded_paths() {
  awk -F'|' '/^## / {c = ($0 ~ /^## Contracts/); h = ($0 ~ /^## Hard to undo/); next}
    c && NF >= 5 {print $4} h && /^- / {print}' "$WS/AGENTS.md" 2>/dev/null \
    | grep -o '`[A-Za-z0-9._-]*/[^`[:space:]]*`' | tr -d '`' | sed 's#/#\t#' || true
}
# hard_paths: "<repo>\t<path>" for each path under "Hard to undo" only: a change there needs a way back.
hard_paths() {
  awk '/^## / {h = ($0 ~ /^## Hard to undo/); next} h && /^- /' "$WS/AGENTS.md" 2>/dev/null \
    | grep -o '`[A-Za-z0-9._-]*/[^`[:space:]]*`' | tr -d '`' | sed 's#/#\t#' || true
}
# hard_hit <hash,...>: the first file the commits change under a "Hard to undo" path, as <repo>/<file>.
hard_hit() {
  local touched gr gp r f
  touched="$(commit_files "$1")"
  while IFS=$'\t' read -r gr gp; do
    [[ -n "$gr" ]] || continue
    while IFS=$'\t' read -r r f; do
      [[ "$r" == "$gr" && ( "$f" == "$gp" || "$f" == "${gp%/}/"* ) ]] && { echo "$r/$f"; return 0; }
    done <<<"$touched"
  done < <(hard_paths)
  return 0
}
# commit_files <hash,...>: "<repo>\t<file>" for every file the commits change, each commit found in
# the workspace ("workspace") or a repo on this machine; "?\t<hash>" for one found nowhere.
commit_files() {
  local c name url files link path d found t=$'\t'
  local -a dirs
  dirs=("workspace$t$WS")
  while IFS=$'\t' read -r name url files link path; do dirs+=("$name$t$(repo_dir "$path")"); done < <(repos 2>/dev/null)
  for c in ${1//,/ }; do
    found=""
    for d in "${dirs[@]}"; do
      git -C "${d#*$t}" cat-file -e "$c^{commit}" 2>/dev/null || continue
      found="${d%%$t*}"
      git -C "${d#*$t}" diff-tree --root --no-commit-id --name-only -r "$c" | sed "s#^#$found$t#"
      break
    done
    [[ -n "$found" ]] || printf '?\t%s\n' "$c"
  done
  return 0
}
# critical_areas: "<area>\t<paths>\t<reviewers>\t<evidence>\t<check>" for each row of "Critical areas"
# in AGENTS.md: paths as <repo>/<path> and reviewers space separated, the check a command in tools/ or
# empty (.cabinet/rules/reviews.md, "Critical areas").
critical_areas() {
  awk -F'|' '/^## / {on = ($0 == "## Critical areas"); next} on && NF >= 7 {
      for (i = 2; i <= 6; i++) { gsub(/^ +| +$/, "", $i) }
      a = tolower($2); if (a == "" || a == "area" || a ~ /^-+$/ || a ~ /^none/) next
      p = ""; s = $3; while (match(s, /`[^`]+`/)) { p = p " " substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH) }
      r = tolower($4); gsub(/[`,]/, " ", r); gsub(/ +/, " ", r); gsub(/^ | $/, "", r)
      c = $6; gsub(/`/, "", c); if (tolower(c) ~ /^(none|-)?$/) c = ""
      print a "\t" substr(p, 2) "\t" r "\t" $5 "\t" c
    }' "$WS/AGENTS.md" 2>/dev/null
}
# areas_hit <hash,...>: the critical areas the commits change, one per line.
areas_hit() {
  local a p r e c x f files
  files="$(commit_files "$1" | awk -F'\t' '$1 != "?" { print $1 "/" $2 }')"
  while IFS=$'\t' read -r a p r e c; do
    for x in $p; do
      while IFS= read -r f; do [[ -n "$f" && ( "$f" == "${x%/}" || "$f" == "${x%/}/"* ) ]] && { echo "$a"; continue 3; }; done <<<"$files"
    done
  done < <(critical_areas)
  return 0   # the loop's last test is no failure (pipefail would make it one)
}
# small_problems <hash,...>: why commits are not a small task, or nothing: they must sit in one repo on
# this machine (the workspace counts as "workspace") and touch no guarded path.
small_problems() {
  local in="" touched gr gp f name
  touched="$(commit_files "$1")"
  name="$(awk -F'\t' '$1 == "?" { print $2; exit }' <<<"$touched")"
  [[ -z "$name" ]] || { echo "commit $name is in no repo on this machine"; return 0; }
  in="$(cut -f1 <<<"$touched" | sort -u | paste -sd ' ' -)"
  [[ "$in" != *" "* ]] || { echo "its commits span more than one repo ($in)"; return 0; }
  while IFS=$'\t' read -r gr gp; do
    [[ -n "$gr" && "$gr" == "$in" ]] || continue
    while IFS=$'\t' read -r name f; do
      [[ "$f" == "$gp" || "$f" == "${gp%/}/"* ]] && { echo "it changes $gr/$f, which a contract or the \"Hard to undo\" list in AGENTS.md names"; return 0; }
    done <<<"$touched"
  done < <(guarded_paths)
  return 0
}
# The builder a repo most looks like, from the files at its top (package.json is read as data only).
builder_for() {
  local d=$1 deps=""
  [[ -f "$d/package.json" ]] && deps="$(json -r '[...Object.keys($.dependencies ?? {}), ...Object.keys($.devDependencies ?? {})].join(" ")' "$d/package.json" 2>/dev/null)"
  if [[ -d "$d/ios" || -d "$d/android" || -f "$d/pubspec.yaml" ]] || ls -d "$d"/*.xcodeproj >/dev/null 2>&1 || has "$deps" react-native || has "$deps" expo; then echo mobile
  elif ls "$d"/*.tf >/dev/null 2>&1 || [[ -d "$d/terraform" || -f "$d/Pulumi.yaml" || -f "$d/Chart.yaml" || -f "$d/cdk.json" ]]; then echo infrastructure
  elif has "$deps" react || has "$deps" next || has "$deps" vue || has "$deps" svelte || has "$deps" @angular/core || has "$deps" astro || has "$deps" nuxt || [[ -f "$d/index.html" ]]; then echo web
  else echo backend; fi
}

# The Cursor CLI: `cursor-agent`, or an `agent` that really is Cursor's (the name is generic).
cursor_bin() {
  local b
  b="$(command -v cursor-agent 2>/dev/null)" && { echo "$b"; return 0; }
  b="$(command -v agent 2>/dev/null)" || return 1
  [[ "$(readlink -f "$b" 2>/dev/null || echo "$b")" == *[Cc]ursor* ]] && echo "$b"
}

# mine <schedule file>: the schedule runs a script of this workspace.
mine() { [[ "$(sched_ws "$1")" == "$WS" ]]; }

# PATH for scheduled jobs: the usual places plus wherever this machine keeps the
# runner, node (for tools that are node scripts) and the kit's own tools.
job_path() {
  local p="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" t d
  local runner="$CABINET_RUNNER"; [[ "$runner" == custom ]] && runner="${CABINET_RUNNER_CMD%% *}"
  [[ "$runner" == cursor ]] && runner="$(cursor_bin || echo cursor-agent)"
  [[ "$runner" == antigravity ]] && runner=agy
  for t in "$runner" node git openssl; do
    d="$(command -v "$t" 2>/dev/null)" || continue
    [[ "$d" == /* ]] || continue
    d="$(dirname "$d")"; [[ ":$p:" == *":$d:"* ]] || p="$d:$p"
  done
  printf '%s' "$p"
}
