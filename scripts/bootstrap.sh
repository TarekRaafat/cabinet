#!/usr/bin/env bash
# Set up this machine for the workspace: clone the repos, restore their
# local-only files, link CLAUDE.md, build the roles, install the push and
# publish guardrails for every agent tool, and install the schedules.
#
#   bin/bootstrap.sh --dry-run        show what would happen
#   bin/bootstrap.sh                  do it
#   bin/bootstrap.sh --no-schedules   and from now on, schedule no jobs on this machine (another machine
#                                     runs them; remembered in cabinet.local.env); --schedules undoes it
#
# Safe to run again at any time. It never overwrites an existing file: a file
# that differs from the kit's copy is reported and left alone. Live configs are
# backed up before a merge, and a merge only adds rules, so several workspaces
# (or kits) installing the same guardrails never undo each other.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
G="$K/guardrails"
DRY=0 failures=0 set_schedules=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-schedules) set_schedules=off ;;
    --schedules) set_schedules=on ;;
    *) echo "usage: bootstrap.sh [--dry-run] [--no-schedules | --schedules]" >&2; exit 2 ;;
  esac
done

run() { if ((DRY)); then echo "  would: $*"; else "$@"; fi; }

# Place a file only when the destination does not exist yet.
place() {
  local src=$1 dst=$2
  [[ -f "$src" ]] || return 0
  if [[ -e "$dst" || -L "$dst" ]]; then
    cmp -s "$src" "$dst" || echo "  differs, left as is: $dst"
  else
    if ((DRY)); then echo "  would place $dst"; return 0; fi
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
    echo "  placed $dst"
  fi
}

backup() { [[ -f "$1" ]] && run cp -p "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; return 0; }

# Write new content into an existing config in place, so its permissions, owner
# and any symlink (dotfiles) stay as they were. The new content reaches the file
# only when the command succeeded and its output is non-empty (and, for JSON, valid):
# a failed merge never empties a config. Usage: write_into <file> json|text <command...>
write_into() {
  local target=$1 kind=$2 tmp; shift 2
  tmp="$(mktemp)"
  if "$@" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && { [[ "$kind" != json ]] || jq -e . "$tmp" >/dev/null 2>&1; }; then
    cat "$tmp" > "$target"; rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  echo "  $target: the merge did not produce a valid file (its shape is not what the kit expects), left as is: add the kit's rules by hand"
  failures=1; return 1
}

# A config that is not plain JSON (comments, trailing commas) is never rewritten.
json_ok() { [[ ! -f "$1" ]] || jq -e . "$1" >/dev/null 2>&1; }

# Union-merge a {permissions:{deny,ask}} snippet into a JSON settings file.
merge_permissions() {
  local snippet=$1 target=$2 missing
  [[ -f "$snippet" ]] || return 0
  json_ok "$target" || { echo "  $target is not plain JSON, left as is: add the rules in $snippet by hand"; failures=1; return 0; }
  missing="$(jq -s '((.[1].permissions.deny // []) - (.[0].permissions.deny // []))
    + ((.[1].permissions.ask // []) - (.[0].permissions.ask // [])) | length' \
    "$target" "$snippet" 2>/dev/null)" || missing="$(jq '(.permissions.deny // []) + (.permissions.ask // []) | length' "$snippet")"
  [[ "$missing" == "0" ]] && return 0
  if ((DRY)); then echo "  would add $missing permission rule(s) to $target"; return 0; fi
  [[ -f "$target" ]] || { mkdir -p "$(dirname "$target")"; echo '{}' > "$target"; }
  backup "$target"
  write_into "$target" json jq -s '.[0] as $a | .[1] as $b | $a
    | .permissions.deny = (($a.permissions.deny // []) + (($b.permissions.deny // []) - ($a.permissions.deny // [])))
    | .permissions.ask  = (($a.permissions.ask  // []) + (($b.permissions.ask  // []) - ($a.permissions.ask  // [])))' \
    "$target" "$snippet" && echo "  added $missing permission rule(s) to $target"
  return 0
}

# A clone URL from repos.tsv: a plain git URL, never an option or a line with control characters.
# A relative path (./x, ../x) is relative to the workspace.
url_ok() { [[ "$1" =~ ^(https://|http://|ssh://|git://|file://|git@[A-Za-z0-9.-]+:|/|\./|\.\./)[^[:space:][:cntrl:]]*$ ]]; }

echo "== Product repos"
while IFS=$'\t' read -r name url files link path; do
  repo="$(repo_dir "$path")"
  if [[ ! -e "$repo/.git" ]]; then
    [[ "$url" == - ]] && { echo "  $name: no repo at $repo and no clone URL in repos.tsv"; continue; }
    url_ok "$url" || { echo "  $name: '$url' is not a git URL, not cloned"; failures=1; continue; }
    # One repo that cannot be reached never stops the rest of the setup.
    [[ "$url" == ./* || "$url" == ../* ]] && url="$WS/$url"
    run git clone -- "$url" "$repo" || { echo "  $name: clone failed (see above); everything else continues"; failures=1; continue; }
  fi
  [[ -d "$repo" ]] || continue
  if [[ "${files:--}" != "-" ]]; then
    for f in $files; do place "$WS/local/$name/$f" "$repo/$f"; done
  fi
  ex_src="$WS/local/$name/git-info-exclude"
  if [[ -f "$ex_src" && -d "$repo/.git" ]]; then
    while IFS= read -r line; do
      grep -qxF "$line" "$repo/.git/info/exclude" 2>/dev/null || {
        ((DRY)) && echo "  would exclude in $name: $line" || { echo "$line" >> "$repo/.git/info/exclude"; echo "  excluded in $name: $line"; }
      }
    done < "$ex_src"
  fi
  if [[ "${link:-}" == "yes" && -f "$repo/AGENTS.md" && ! -e "$repo/CLAUDE.md" ]]; then
    run ln -s AGENTS.md "$repo/CLAUDE.md"
    echo "  linked $name/CLAUDE.md"
  fi
done < <(repos)

echo "== Builders"
# A repo whose owning agent is TBD in the team table gets the builder it most looks like.
# The owner may change the row to another builder, a project role or owner; a row that is
# not TBD is never touched.
assigned=0
while IFS=$'\t' read -r name url files link path; do
  repo="$(repo_dir "$path")"
  [[ -e "$repo/.git" ]] || continue
  N="$name" perl -ne 'exit 1 if /^\| `\Q$ENV{N}\E` \|[^|]*\|\s*TBD\s*\|\s*$/' "$WS/AGENTS.md" 2>/dev/null && continue
  b="$(builder_for "$repo")"
  if ((DRY)); then echo "  would make $b the owner of $name"; continue; fi
  N="$name" B="$b" perl -i -pe 's/^(\| `\Q$ENV{N}\E` \|[^|]*\|)\s*TBD\s*\|\s*$/$1 $ENV{B} |\n/' "$WS/AGENTS.md"
  echo "  $name: owned by the $b builder, from what the repo holds (change its row in AGENTS.md to choose another)"
  assigned=1
done < <(repos)
((assigned)) && echo "  review and commit AGENTS.md and the built roles (agents/, .claude/agents/)"

echo "== Shared instructions and roles"
[[ -e "$WS/CLAUDE.md" ]] || { run ln -s AGENTS.md "$WS/CLAUDE.md"; echo "  linked CLAUDE.md"; }
run "$WS/bin/role.sh" build

echo "== Git push gate"
# A global core.hooksPath makes git skip every repo's own .git/hooks, so every other
# hook gets a stub that passes the call on to the repo's own hook (pre-commit
# secret scanners keep working). pre-push is the gate itself, and passes on too.
# Not push-to-checkout or fsmonitor-watchman: git changes its behavior when those merely exist.
hooks="$HOME/.config/git/hooks"
place "$G/pre-push" "$hooks/pre-push"
for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg \
         post-commit pre-rebase post-checkout post-merge post-rewrite pre-auto-gc reference-transaction \
         post-index-change sendemail-validate; do
  place "$G/hook-passthrough" "$hooks/$h"
done
for h in "$hooks"/*; do [[ -f "$h" && ! -x "$h" ]] && run chmod +x "$h"; done
current="$(git config --global core.hooksPath || true)"
if [[ -z "$current" ]]; then
  run git config --global core.hooksPath "$hooks"
elif [[ "$current" != "$hooks" ]]; then
  echo "  core.hooksPath is $current, not $hooks. Left as is: check the gate there (bin/doctor.sh)."
fi

echo "== Secrets check"
# The workspace's own pre-commit hook refuses a commit that adds a likely secret. Only in a
# workspace with its own git: a shared cabinet/ is committed with the project, whose hooks
# are the project's. An existing hook is left as is (place never overwrites).
if [[ "$(secrets_hook)" == none ]]; then
  echo "  the workspace is committed with the project, whose own hooks run; bin/doctor.sh still checks"
else
  sh_hook="$(secrets_hook)"
  place "$G/pre-commit-secrets" "$sh_hook"
  [[ -f "$sh_hook" && ! -x "$sh_hook" ]] && cmp -s "$G/pre-commit-secrets" "$sh_hook" && run chmod +x "$sh_hook"
fi

echo "== Claude Code"
merge_permissions "$G/claude-permissions.json" "$HOME/.claude/settings.json"

echo "== Codex"
if [[ -d "$HOME/.codex" ]] || command -v codex >/dev/null; then
  place "$G/codex-default.rules" "$HOME/.codex/rules/default.rules"
  cfg="$HOME/.codex/config.toml"
  if [[ -f "$cfg" ]] && ! grep -q '^approval_policy' "$cfg"; then
    backup "$cfg"
    # Top-level keys must come before the first [table].
    # Codex then asks before running anything its sandbox does not allow.
    ((DRY)) && echo "  would add approval_policy = \"on-request\" to $cfg" || {
      write_into "$cfg" text awk 'BEGIN{done=0} /^\[/ && !done {print "approval_policy = \"on-request\""; done=1} {print} END{if(!done) print "approval_policy = \"on-request\""}' "$cfg" &&
      echo "  added approval_policy = \"on-request\" to $cfg (Codex asks before commands outside its sandbox)"
    }
  fi
fi

echo "== Antigravity CLI (agy)"
if [[ -d "$HOME/.gemini/antigravity-cli" ]] || command -v agy >/dev/null; then
  merge_permissions "$G/agy-permissions.json" "$HOME/.gemini/antigravity-cli/settings.json"
fi

echo "== Gemini CLI"
if [[ -d "$HOME/.gemini" ]] || command -v gemini >/dev/null; then
  place "$G/gemini-owner-control.toml" "$HOME/.gemini/policies/owner-control.toml"
  g="$HOME/.gemini/settings.json"
  if ! json_ok "$g"; then
    echo "  $g is not plain JSON, left as is: set context.fileName to [\"AGENTS.md\", \"GEMINI.md\"] by hand"; failures=1
  elif [[ ! -f "$g" ]]; then
    place "$G/gemini-context.json" "$g"
  elif [[ "$(jq '.context.fileName // empty' "$g")" == "" ]]; then
    ((DRY)) && echo "  would set context.fileName in $g" || { backup "$g"; write_into "$g" json jq -s '.[0] * .[1]' "$g" "$G/gemini-context.json" && echo "  set context.fileName in $g (Gemini reads AGENTS.md)"; }
  fi
fi

echo "== Qwen Code"
# Same rule format as Claude Code (permissions.deny / ask), so the same rules.
if [[ -d "$HOME/.qwen" ]] || command -v qwen >/dev/null; then
  merge_permissions "$G/claude-permissions.json" "$HOME/.qwen/settings.json"
fi

echo "== Cursor CLI"
# Cursor's format (~/.cursor/cli-config.json, permissions.deny, Shell(command:args) globs;
# deny wins). Probed live on Cursor CLI 2026.10.16: it drops a leading VAR= before
# matching but does not look inside wrappers, hence the wrapper rules. The Cursor
# editor's agent keeps its command rules in the editor's own settings, which the kit
# does not change: there only the git push gate applies.
if [[ -d "$HOME/.cursor" ]] || cursor_bin >/dev/null; then
  merge_permissions "$G/cursor-permissions.json" "$HOME/.cursor/cli-config.json"
fi

echo "== Grok"
# Grok reads ~/.claude/settings.json, so the Claude Code rules above cover it.
command -v grok >/dev/null && echo "  covered by the Claude Code rules (bin/doctor.sh checks with grok inspect)"

echo "== opencode"
# opencode keeps bash rules as {pattern: action} under permission.bash, and the
# last matching rule wins. So the kit's rules go last: after any catch-all,
# with bash after any tool-wide "*". They go in opencode.json even when
# opencode.jsonc exists: opencode reads both (the .jsonc after), and a commented
# file is never rewritten. bin/doctor.sh checks the order opencode resolves.
merge_opencode() {
  local snippet=$1 target=$2 rules missing
  rules="$(jq -c '[((.permissions.deny // [])[] | {r: ., a: "deny"}), ((.permissions.ask // [])[] | {r: ., a: "ask"})]
    | map(select(.r | startswith("Bash(")) | {key: (.r | sub("^Bash\\((?<p>.*)\\)$"; "\(.p)")), value: .a}) | from_entries' "$snippet")"
  if ! json_ok "$target"; then
    echo "  $target is not plain JSON, left as is: add these under permission.bash by hand: $rules"; failures=1; return 0
  fi
  if [[ ! -f "$target" ]]; then
    if ((DRY)); then echo "  would create $target with $(jq length <<<"$rules") bash rule(s)"; return 0; fi
    mkdir -p "$(dirname "$target")"; echo '{"$schema": "https://opencode.ai/config.json"}' > "$target"
  fi
  # Missing: any kit rule absent, different, or not among the last entries.
  missing="$(jq --argjson r "$rules" '(.permission | if type == "object" then .bash else null end) as $b
    | if ($b | type) != "object" then ($r | length)
      else ($b | to_entries | .[-($r | length):] | from_entries) as $tail | [$r | to_entries[] | select($tail[.key] != .value)] | length end' "$target")"
  [[ "$missing" == 0 ]] && return 0
  backup "$target"
  if ((DRY)); then echo "  would add or reorder $missing bash rule(s) in $target"; return 0; fi
  write_into "$target" json jq --argjson r "$rules" '
    .permission = (.permission // {} | if type == "string" then {"*": .} else . end)
    | (.permission.bash // {} | if type == "string" then {"*": .} else . end) as $b
    | .permission = (.permission | del(.bash)) + {bash: (($b | with_entries(select(.key as $k | $r | has($k) | not))) + $r)}' \
    "$target" && echo "  added or reordered $missing bash rule(s) in $target"
  return 0
}
if [[ -d "$HOME/.config/opencode" ]] || command -v opencode >/dev/null; then
  merge_opencode "$G/claude-permissions.json" "$HOME/.config/opencode/opencode.json"
fi

echo "== Schedules ($SCHEDULER)"
# Remember the choice for this machine in cabinet.local.env (only the one line; other lines are kept).
if [[ -n "$set_schedules" && "$set_schedules" != "$CABINET_SCHEDULES" ]]; then
  if ((DRY)); then echo "  would set CABINET_SCHEDULES=\"$set_schedules\" in $LOCAL_ENV"
  else
    { grep -v '^CABINET_SCHEDULES=' "$LOCAL_ENV" 2>/dev/null || true; [[ "$set_schedules" == off ]] && echo 'CABINET_SCHEDULES="off"'; } > "$LOCAL_ENV.new"
    if [[ -s "$LOCAL_ENV.new" ]]; then mv "$LOCAL_ENV.new" "$LOCAL_ENV"; else rm -f "$LOCAL_ENV.new" "$LOCAL_ENV"; fi
    echo "  this machine: jobs scheduled $set_schedules (saved in cabinet.local.env, which git does not track)"
  fi
fi
[[ -n "$set_schedules" ]] && CABINET_SCHEDULES="$set_schedules"
# Days and times: when_norm and the scheduler's own form (bin/when.sh), shared with the doctor and the digest.
JOB_PATH="$(job_path)"
wanted=" "
# Install, replace or keep one schedule, so an edited WHEN or backup time takes effect.
schedule() {  # schedule <name> <program> <verb> <arg> <when>
  local name=$1 label="$LABEL.$1" live new
  live="$(sched_file "$label")"
  wanted+="$name "   # wanted even when its WHEN is wrong, so a typo never removes a working schedule
  local when=$5
  if ! new="$(sched_render "$label" "$when" "$LOGDIR/$name.log" "$JOB_PATH" "$2" "$3" "$4")"; then
    echo "  $label: bad schedule '$when' (use a time like 7 AM for every day, or days and a time like fri 4 PM or sun,mon,tue,wed,thu 8 AM); the current one, if any, is kept"; failures=1; return 0
  fi
  if [[ -f "$live" ]] && ! mine "$live"; then
    echo "  $label already runs another workspace, left as is: give this one its own slug (cabinet config --slug)"; failures=1; return 0
  fi
  [[ -f "$live" && "$(cat "$live")" == "$new" ]] && sched_loaded "$label" && return 0
  local verb=install past=installed; [[ -f "$live" ]] && verb=update past=updated
  if ((DRY)); then echo "  would $verb $label ($when)"; return 0; fi
  if sched_load "$label" "$new"; then echo "  $past $label ($when)"
  else echo "  $label could not be loaded by $SCHEDULER (see above); nothing installed"; failures=1; fi
}
if [[ "$SCHEDULER" == none ]]; then
  echo "  no scheduler found (a running systemd user session, or cron): install cron, or run cabinet job run <job> by hand"
else
  # The log folder records which workspace owns this slug.
  # Claimed only when it is free, already ours, or its workspace folder is gone.
  if ((DRY == 0)); then
    mkdir -p -m 700 "$LOGDIR"
    owner_ws="$(cat "$LOGDIR/workspace" 2>/dev/null || true)"
    if [[ -z "$owner_ws" || "$owner_ws" == "$WS" || ! -d "$owner_ws" ]]; then printf '%s\n' "$WS" > "$LOGDIR/workspace"
    else echo "  the log folder $LOGDIR belongs to the workspace at $owner_ws: give this one its own slug (cabinet config --slug)"; failures=1; fi
  fi
  # Every job runs the runner with this PATH: say so now if it cannot find it there.
  runner="$CABINET_RUNNER"; [[ "$runner" == custom ]] && runner="${CABINET_RUNNER_CMD%% *}"
  [[ "$runner" == cursor ]] && runner="$(basename "$(cursor_bin || echo cursor-agent)")"
  if [[ -n "$runner" ]] && ! env -i HOME="$HOME" PATH="$JOB_PATH" /bin/sh -c 'command -v "$0"' "$runner" >/dev/null 2>&1; then
    echo "  scheduled jobs will not find '$runner' (install it, or run bin/bootstrap.sh from a shell where it is on PATH)"; failures=1
  fi
  if [[ "$CABINET_SCHEDULES" == off ]]; then
    echo "  jobs are not scheduled on this machine (another machine runs them; cabinet bootstrap --schedules turns them on). cabinet job run <job> still runs one by hand."
  else
    for jf in "$WS"/jobs/*.job; do
      [[ -f "$jf" ]] || continue
      WHEN="$(WHEN=""; source "$jf"; echo "$WHEN")"
      [[ -z "$WHEN" ]] || schedule "$(basename "$jf" .job)" "$WS/bin/job.sh" run "$(basename "$jf" .job)" "$WHEN"
    done
  fi
  [[ -z "$CABINET_BACKUP_DIR" ]] || schedule backup "$WS/bin/backup.sh" create "$CABINET_BACKUP_DIR" "$CABINET_BACKUP_TIME"
  # Remove this workspace's schedules that are no longer wanted: a job with an
  # empty WHEN or no job file, every job when this machine schedules none, or the
  # backup with CABINET_BACKUP_DIR empty.
  # Only schedules that run this workspace: another workspace's are never touched.
  for live in "$SCHED_DIR/$LABEL".*"$SCHED_EXT"; do
    [[ -f "$live" ]] && mine "$live" || continue
    name="$(sched_label "$live")"; name="${name#"$LABEL."}"
    [[ "$wanted" == *" $name "* ]] && continue
    if ((DRY)); then echo "  would remove $LABEL.$name (no longer scheduled)"; continue; fi
    sched_unload "$LABEL.$name"
    echo "  removed $LABEL.$name (no longer scheduled)"
  done
fi

cat <<EOF

== Manual steps
1. Sign in: gh auth login (and each agent tool you use).
2. Backups (if CABINET_BACKUP_DIR is set): put the passphrase, kept in your password manager, in the $PASS_STORE:
   $(pass_add_cmd "$KEYCHAIN_ITEM")$( [[ -n "$CABINET_BACKUP_DIR" && -n "$(deps_backups)" ]] && printf '\n   Backups need %s first: %s' "$(deps_backups)" "$(deps_hint "$(deps_backups)")")
3. Restoring after a loss: cabinet backup restore <newest archive> before step 4.
4. Run cabinet doctor and fix anything it reports (cabinet doctor --fix runs the fixes it knows).
EOF
((failures == 0)) || { echo; echo "Some steps did not complete: see the messages above."; exit 1; }
