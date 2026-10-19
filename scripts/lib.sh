# Shared by every bin/*.sh: the workspace path, its cabinet.env, and the names
# every machine-wide thing is scoped by, so two projects (or two kits) never
# share a schedule, a log folder or a secret. Sourced, never run.

# The real path, symlinks resolved, so the same workspace always has the same name.
WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$WS/cabinet.env" ]] || { echo "no cabinet.env in $WS" >&2; exit 1; }
# shellcheck disable=SC1091
source "$WS/cabinet.env"
source "$WS/bin/when.sh"   # when_norm, when_calendar, when_human: one parser for every schedule
: "${CABINET_SLUG:?set CABINET_SLUG in cabinet.env}"
CABINET_ROLES="${CABINET_ROLES:-}"
CABINET_RUNNER="${CABINET_RUNNER:-claude}"
CABINET_RUNNER_CMD="${CABINET_RUNNER_CMD:-}"
RUNNERS="claude codex gemini qwen grok opencode cursor"   # built in; "custom" runs CABINET_RUNNER_CMD
CABINET_BACKUP_DIR="${CABINET_BACKUP_DIR:-}"
CABINET_BACKUP_TIME="${CABINET_BACKUP_TIME:-1:00 PM}"
CABINET_BACKUP_KEEP="${CABINET_BACKUP_KEEP:-14}"
CABINET_JOB_TIMEOUT="${CABINET_JOB_TIMEOUT:-60}"
# Settings for this Mac only, in cabinet.local.env: never committed (the workspace's
# .gitignore tracks only its own files), so each teammate's Mac keeps its own. Read, never
# sourced. CABINET_SCHEDULES="off": another Mac runs the jobs (cabinet bootstrap --no-schedules).
# CABINET_BACKUP_DIR and CABINET_BACKUP_TIME, when present, replace cabinet.env's on this Mac
# (cabinet config --this-mac); an empty CABINET_BACKUP_DIR turns backups off here.
LOCAL_ENV="$WS/cabinet.local.env"
local_has() { grep -q "^$1=" "$LOCAL_ENV" 2>/dev/null; }
local_get() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$LOCAL_ENV" 2>/dev/null | tail -1 || true; }
CABINET_SCHEDULES="$(local_get CABINET_SCHEDULES)"
[[ "$CABINET_SCHEDULES" == off ]] || CABINET_SCHEDULES=on
BACKUP_DIR_LOCAL=0
if local_has CABINET_BACKUP_DIR; then CABINET_BACKUP_DIR="$(local_get CABINET_BACKUP_DIR)"; BACKUP_DIR_LOCAL=1; fi
if local_has CABINET_BACKUP_TIME; then CABINET_BACKUP_TIME="$(local_get CABINET_BACKUP_TIME)"; fi

K="$WS/.cabinet"                                   # kit-managed files
LABEL="ai.cabinet.$CABINET_SLUG"                   # launchd labels: $LABEL.<job>
LOGDIR="$HOME/Library/Logs/cabinet/$CABINET_SLUG"
KEYCHAIN_ITEM="cabinet.$CABINET_SLUG.backup"
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

# Dates people read, in the house format (18 Oct 2026, 1:00 PM), English on every machine.
human_stamp() { LC_ALL=C date -j -f %Y%m%d-%H%M%S "$1" "+%-d %b %Y, %-I:%M %p" 2>/dev/null || printf '%s' "$1"; }
human_mtime() { LC_ALL=C date -r "$1" "+%-d %b %Y, %-I:%M %p" 2>/dev/null; }

# The Cursor CLI: `cursor-agent`, or an `agent` that really is Cursor's (the name is generic).
cursor_bin() {
  local b
  b="$(command -v cursor-agent 2>/dev/null)" && { echo "$b"; return 0; }
  b="$(command -v agent 2>/dev/null)" || return 1
  [[ "$(readlink -f "$b" 2>/dev/null || echo "$b")" == *[Cc]ursor* ]] && echo "$b"
}

# mine <plist>: the schedule runs a script of this workspace (paths XML-escaped as written).
mine() { grep -qF "$(W="$WS" perl -e '$_ = $ENV{W}; s/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g; print "<string>$_/bin/"')" "$1"; }

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
