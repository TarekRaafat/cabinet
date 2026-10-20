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
spend_jq() {
  case "$1" in
    claude)   echo '{text: .result, usd: .total_cost_usd}' ;;
    grok)     echo '{text: .text, usd: .total_cost_usd, in: .usage.input_tokens, cached: .usage.cache_read_input_tokens, out: .usage.output_tokens}' ;;
    cursor)   echo '{text: .result, in: .usage.inputTokens, cached: .usage.cacheReadTokens, out: .usage.outputTokens}' ;;
    qwen)     echo 'map(select(.type == "result")) | last | {text: .result, in: .usage.input_tokens, cached: (.usage.cache_read_input_tokens // 0), out: .usage.output_tokens}' ;;
    # ponytail: takes input_tokens to include cache_read_tokens (total_tokens leaves the cache out);
    # a run with cache reads, seen live, would settle it.
    antigravity) echo '{text: .response, cached: (.usage.cache_read_tokens // 0), out: ((.usage.output_tokens // 0) + (.usage.thinking_tokens // 0))}
                + {in: ((.usage.input_tokens // 0) - (.usage.cache_read_tokens // 0))}' ;;
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
run_limited() {  # run_limited <minutes, 0 for none> <what set the limit>: run_agent, stopped at the limit
  local limit=$1 why=$2
  ((limit)) || { run_agent; return; }
  local secs=$((limit * ${CABINET_TEST_MINUTE:-60})) st=0   # CABINET_TEST_MINUTE: tests only
  set -m; run_agent </dev/null & pid=$!; set +m
  perl -e 'sleep shift; kill "TERM", -$ARGV[0]; sleep 10; kill "KILL", -$ARGV[0]' "$secs" "$pid" & dog=$!
  trap 'kill -TERM -- "-$pid" "$dog" 2>/dev/null; exit 130' INT TERM
  local start=$SECONDS
  wait "$pid" || st=$?
  trap - INT TERM
  kill "$dog" 2>/dev/null || true
  wait "$dog" 2>/dev/null || true   # collected quietly: no "Terminated" line from the shell
  if ((SECONDS - start >= secs)); then echo "stopped after $limit min: $why" >&2; return 124; fi
  return "$st"
}

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
  [[ "$CABINET_RUNNER" != gemini ]] || { echo "CABINET_RUNNER=gemini is no longer a runner (Gemini CLI users moved to Antigravity): cabinet config --runner antigravity" >&2; return 2; }
  has "$RUNNERS" "$CABINET_RUNNER" || { echo "unknown CABINET_RUNNER: $CABINET_RUNNER ($RUNNERS or custom)" >&2; return 2; }
  # Each built-in runner prints JSON, for the cost it reports: the reply goes on to the log as
  # before, the cost to $SPEND (spend_report).
  local out st=0; out="$(mktemp)"
  case "$CABINET_RUNNER" in
    claude)   claude -p --agent "$AGENT" --permission-mode auto --output-format json "$PROMPT" ;;
    codex)    codex exec --json "$as_role" ;;
    # Headless agy denies what it cannot ask (--mode auto needs a plan that has it); skipping the
    # prompts keeps its deny rules, as the owner saw with a denied command (docs/guardrails.md).
    antigravity) agy -p "$as_role" --output-format json --dangerously-skip-permissions ;;
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
  TEAM="$(team_roles)" BUILDS="$builds" UI="$ui" DELEGATES="$(delegates)" python3 -I - "$SPEND" "$WS/HANDOFFS.md" ${arch[@]+"${arch[@]}"} <<'PY'
import datetime, json, os, re, sys
cost = {}
today = datetime.date.today().isoformat()
# A role that reports to a lead and covers some work reviews it for the lead (its verdict counts),
# with the lead's PASS needed too until its trial ends.
dl = [l.split("\t") for l in os.environ.get("DELEGATES", "").split("\n") if l.count("\t") == 3]
try:
    for row in open(sys.argv[1], encoding="utf-8"):
        f = row.rstrip("\n").split("\t")
        if len(f) >= 4 and f[3]:
            cost[f[1]] = cost.get(f[1], 0) + float(f[3])
except (OSError, ValueError):
    pass
team, builds, ui = (set(os.environ.get(k, "").split()) for k in ("TEAM", "BUILDS", "UI"))
VER = re.compile(r"- Verdict: ([a-z0-9-]+) (PASS|BLOCK|CHANGES) (\d{4}-\d{2}-\d{2}) ([0-9a-f]+(?:,[0-9a-f]+)*|none) (\S+)$")
def names(s):
    s = re.sub(r"\([^)]*\)", "", s).replace(" and ", ",").replace("&", ",").replace("`", "")
    return [n.strip().lower() for n in s.split(",") if n.strip()]
def covers(have, want):  # short and long hashes of one commit match
    return all(any(w.startswith(h) or h.startswith(w) for h in have) for w in want)
entries, cur = [], None
for n, path in enumerate(sys.argv[2:]):  # HANDOFFS.md, then the archives (closed work a run may still need)
    on = n > 0
    for l in open(path, encoding="utf-8").read().split("\n"):
        if l.startswith("## "):
            on, cur = l.startswith(("## Open", "## Archive")), None
        elif on and l.startswith("### H-"):
            cur = {"id": l.split()[1].rstrip(":"), "lines": [], "archived": n > 0}
            entries.append(cur)
        elif cur is not None:
            cur["lines"].append(l)
out = {}
for e in entries:
    frm, to, vs, unread = "", "", [], []
    for l in e["lines"]:
        m = re.match(r"- From: (.*?) -> To: (.*)", l)
        if m and not frm:
            frm, to = m.group(1).strip().lower(), m.group(2)
        v = VER.match(l.strip())
        if v:
            vs.append({"role": v.group(1), "verdict": v.group(2), "date": v.group(3),
                       "commits": [] if v.group(4) == "none" else v.group(4).split(","), "note": v.group(5)})
        elif re.search(r"\b(PASS|BLOCK|CHANGES)\b", l):
            unread.append(l.strip())
    needs = []
    for n in names(to):
        if n in team and n not in builds and n != "chief-of-staff" and n not in needs:
            needs.append(n)
    if frm in builds or any(v["commits"] for v in vs):
        for r in ["qa", "security", "code-reviewer"] + (["design-lead"] if frm in ui else []):
            if r in team and r not in needs:
                needs.append(r)
    work = []
    for c in (c for v in vs for c in v["commits"]):
        if not covers(work, [c]):
            work.append(c)
    last = {v["role"]: v for v in vs}
    blocking = [r for r, v in last.items() if v["verdict"] != "PASS"]
    # Who does each review: the role that covers this sender's work for the lead, else the lead; the
    # lead's own PASS always counts.
    who = []
    for r in needs:
        d = next((d for d in dl if d[1] == r and frm in d[2].split(",")), None)
        if d:
            who.append((d[0], [d[0], r]))
            if d[3] and d[3] >= today:
                who.append((r, [r]))
        else:
            who.append((r, [r]))
    needs, stale, missing = [], [], []
    for w, ok in who:
        needs.append(w)
        passed = [last[o] for o in ok if o in last and last[o]["verdict"] == "PASS"]
        if any(covers(p["commits"], work) for p in passed) or any(o in blocking for o in ok):
            continue   # passed, or blocking (and listed there)
        (stale if passed else missing).append(w)
    dep = next((l[len("- Depends on:"):].strip() for l in e["lines"] if l.startswith("- Depends on:")), "")
    st = next((l[len("- Status:"):].strip() for l in e["lines"] if l.startswith("- Status:")), "")
    out[e["id"]] = {"archived": e["archived"], "depends_on": dep, "status_now": st.split(" ")[0] if st else "", "small": any(l.strip() == "- Size: small" for l in e["lines"]),
                    "spec": next((l[len("- Spec:"):].strip() for l in e["lines"] if l.startswith("- Spec:")), ""),
                    "cost_usd": round(cost[e["id"]], 6) if e["id"] in cost else None, "verdicts": vs, "needs": needs, "missing": missing, "blocking": blocking, "stale": stale,
                    "ready": (not missing and not blocking and not stale) if needs else None, "unread_verdicts": unread}
print(json.dumps(out))
PY
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
# small_problems <hash,...>: why commits are not a small task, or nothing: they must sit in one repo on
# this machine (the workspace counts as "workspace") and touch no guarded path.
small_problems() {
  local c name url files link path d found in="" touched="" gr gp f t=$'\t'
  local -a dirs
  dirs=("workspace$t$WS")
  while IFS=$'\t' read -r name url files link path; do dirs+=("$name$t$(repo_dir "$path")"); done < <(repos 2>/dev/null)
  for c in ${1//,/ }; do
    found=""
    for d in "${dirs[@]}"; do
      git -C "${d#*$t}" cat-file -e "$c^{commit}" 2>/dev/null || continue
      found="${d%%$t*}"
      has "$in" "$found" || in="${in:+$in }$found"
      touched+="$(git -C "${d#*$t}" diff-tree --root --no-commit-id --name-only -r "$c" | sed "s#^#$found$t#")"$'\n'
      break
    done
    [[ -n "$found" ]] || { echo "commit $c is in no repo on this machine"; return 0; }
  done
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
  [[ "$runner" == antigravity ]] && runner=agy
  for t in "$runner" node git jq perl openssl python3; do
    d="$(command -v "$t" 2>/dev/null)" || continue
    [[ "$d" == /* ]] || continue
    d="$(dirname "$d")"; [[ ":$p:" == *":$d:"* ]] || p="$d:$p"
  done
  printf '%s' "$p"
}
