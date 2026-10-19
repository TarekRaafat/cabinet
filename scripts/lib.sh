# Shared by every bin/*.sh: the workspace path, its cabinet.env, and the names
# every machine-wide thing is scoped by, so two projects (or two kits) never
# share a schedule, a log folder or a secret. Sourced, never run.

# The real path, symlinks resolved, so the same workspace always has the same name.
WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$WS/cabinet.env" ]] || { echo "no cabinet.env in $WS" >&2; exit 1; }
# shellcheck disable=SC1091
source "$WS/cabinet.env"
source "$WS/bin/when.sh"   # when_norm, when_calendar, when_human: one parser for every schedule
source "$WS/bin/platform.sh"   # this machine: logs, dates, the passphrase, schedules (launchd, systemd or cron)
: "${CABINET_SLUG:?set CABINET_SLUG in cabinet.env}"
CABINET_ROLES="${CABINET_ROLES:-}"
CABINET_RUNNER="${CABINET_RUNNER:-claude}"
CABINET_RUNNER_CMD="${CABINET_RUNNER_CMD:-}"
RUNNERS="claude codex gemini qwen grok opencode cursor"   # built in; "custom" runs CABINET_RUNNER_CMD
CABINET_BACKUP_DIR="${CABINET_BACKUP_DIR:-}"
CABINET_BACKUP_TIME="${CABINET_BACKUP_TIME:-1:00 PM}"
CABINET_BACKUP_KEEP="${CABINET_BACKUP_KEEP:-14}"
CABINET_JOB_TIMEOUT="${CABINET_JOB_TIMEOUT:-60}"
CABINET_BUDGET="${CABINET_BUDGET:-}"   # US dollars a week for the agent runs cabinet starts; empty: none
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
SPEND_TOKENS="codex cursor qwen gemini"
# How the week's dollars were found, for messages.
spend_source() { if has "$SPEND_DOLLARS" "$CABINET_RUNNER"; then echo "as $CABINET_RUNNER reports it"; else echo "priced from $CABINET_RUNNER's token counts"; fi; }
spend_counts() { has "$SPEND_DOLLARS" "$CABINET_RUNNER" || { has "$SPEND_TOKENS" "$CABINET_RUNNER" && [[ -n "$CABINET_PRICE" ]]; }; }
# What each runner's JSON says, as {text, usd, in, cached, out}: the reply, the dollars it reports,
# and tokens (in: uncached input). Shapes seen live (Grok 1.0.62, opencode 2.0.32, Codex 0.163.0,
# Cursor 2026.10.16, Qwen Code 0.25.3's envelope) or documented (Claude Code, Gemini CLI).
spend_jq() {
  case "$1" in
    claude)   echo '{text: .result, usd: .total_cost_usd}' ;;
    grok)     echo '{text: .text, usd: .total_cost_usd, in: .usage.input_tokens, cached: .usage.cache_read_input_tokens, out: .usage.output_tokens}' ;;
    cursor)   echo '{text: .result, in: .usage.inputTokens, cached: .usage.cacheReadTokens, out: .usage.outputTokens}' ;;
    qwen)     echo 'map(select(.type == "result")) | last | {text: .result, in: .usage.input_tokens, cached: (.usage.cache_read_input_tokens // 0), out: .usage.output_tokens}' ;;
    gemini)   echo '[.stats.models[]?.tokens] as $t | {text: .response, cached: ([$t[].cached // 0] | add), out: ([$t[] | .candidates // .response // 0] | add)}
                + {in: (([$t[].prompt // 0] | add) - ([$t[].cached // 0] | add))}' ;;
    # JSON lines, read with jq -s.
    codex)    echo '[.[] | select(.type == "turn.completed") | .usage] as $u | {text: ([.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | join("\n")),
                cached: ([$u[].cached_input_tokens // 0] | add), out: ([$u[].output_tokens // 0] | add)} + {in: (([$u[].input_tokens // 0] | add) - ([$u[].cached_input_tokens // 0] | add))}' ;;
    opencode) echo '[.[] | select(.type == "step_finish") | .part] as $p | {text: ([.[] | select(.type == "text") | .part.text] | join("")), usd: ([$p[].cost // 0] | add),
                in: ([$p[].tokens.input // 0] | add), cached: ([$p[].tokens.cache.read // 0] | add), out: ([$p[] | (.tokens.output // 0) + (.tokens.reasoning // 0)] | add)}' ;;
  esac
}
# spend_report <out file>: print the reply from the runner's JSON (or the output as it is, when it
# is not that JSON) and record the run: dollars the tool reported, else priced from tokens.
spend_report() {
  local f="$1" j slurp="" usd tin tc tout
  case "$CABINET_RUNNER" in codex|opencode) slurp=-s ;; esac
  if ! j="$(jq -c $slurp "$(spend_jq "$CABINET_RUNNER")" "$f" 2>/dev/null)" || [[ "$(jq -r '.text | type' <<<"$j" 2>/dev/null)" != string ]]; then
    cat "$f"; return 0
  fi
  jq -r '.text' <<<"$j"
  read -r usd tin tc tout <<<"$(jq -r '[.usd, .in, .cached, .out] | map(if . == null then "-" else tostring end) | join(" ")' <<<"$j")"
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
# spend_since <seconds> [<label>]: dollars spent since then, by every run or one label's, as "1.25".
spend_since() { awk -F'\t' -v s="$1" -v l="${2:-}" '$1 >= s && (l == "" || $2 == l) { t += $4 } END { printf "%.2f", t }' "$SPEND" 2>/dev/null || printf '0.00'; }

# Run $AGENT on $PROMPT headless with the configured agent tool, in the current folder:
# scheduled jobs and role drafts.
run_agent() {
  # Tools without cabinet's named agents get the role file as their first instruction.
  local as_role="Act as the $AGENT role: read agents/$AGENT.md and follow it as your instructions. $PROMPT"
  # Any other tool: CABINET_RUNNER_CMD runs with the prompt in $CABINET_PROMPT
  # and the role name in $CABINET_AGENT, for example 'mytool --run "$CABINET_PROMPT"'.
  if [[ "$CABINET_RUNNER" == custom ]]; then
    [[ -n "${CABINET_RUNNER_CMD:-}" ]] || { echo "CABINET_RUNNER=custom needs CABINET_RUNNER_CMD in cabinet.env" >&2; return 2; }
    CABINET_AGENT="$AGENT" CABINET_PROMPT="$as_role" bash -c "$CABINET_RUNNER_CMD"; return
  fi
  has "$RUNNERS" "$CABINET_RUNNER" || { echo "unknown CABINET_RUNNER: $CABINET_RUNNER ($RUNNERS or custom)" >&2; return 2; }
  # Each built-in runner prints JSON, for the cost it reports: the reply goes on to the log as
  # before, the cost to $SPEND (spend_report).
  local out st=0; out="$(mktemp)"
  case "$CABINET_RUNNER" in
    claude)   claude -p --agent "$AGENT" --permission-mode auto --output-format json "$PROMPT" ;;
    codex)    codex exec --json "$as_role" ;;
    gemini)   gemini -p "$as_role" -o json ;;
    qwen)     qwen --approval-mode auto -o json "$as_role" ;;
    grok)     grok -p "$as_role" --permission-mode auto --output-format json ;;
    opencode) opencode run --format json "$as_role" ;;
    # --force lets print mode write files (the brief); deny rules are the guardrail.
    cursor)   "$(cursor_bin || echo cursor-agent)" -p --force --output-format json "$as_role" ;;
  esac > "$out" || st=$?
  spend_report "$out"; rm -f "$out"; return "$st"
}

# Claude Code keeps per-folder memory under the folder's path with every non-alphanumeric as "-".
# One dash per character, whatever the locale (launchd runs without one).
claude_slug() { perl -CSA -e '$_ = shift; s/[^A-Za-z0-9]/-/g; print' "$1"; }
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
    if ($1 !~ /^[A-Za-z0-9._-]+$/ || $1 == "." || $1 == "..") { print "repos.tsv: skipped the row named \"" $1 "\" (not a plain folder name)" > "/dev/stderr"; next }
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
# The builder a repo most looks like, from the files at its top (package.json is read as data only).
builder_for() {
  local d=$1 deps=""
  [[ -f "$d/package.json" ]] && deps="$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]' "$d/package.json" 2>/dev/null | tr '\n' ' ')"
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
  for t in "$runner" node git jq perl openssl python3; do
    d="$(command -v "$t" 2>/dev/null)" || continue
    [[ "$d" == /* ]] || continue
    d="$(dirname "$d")"; [[ ":$p:" == *":$d:"* ]] || p="$d:$p"
  done
  printf '%s' "$p"
}
