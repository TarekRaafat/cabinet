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
  if "$@" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && { [[ "$kind" != json ]] || json -e '$' "$tmp" >/dev/null 2>&1; }; then
    if { cat "$tmp" > "$target"; } 2>/dev/null; then rm -f "$tmp"; return 0; fi
    rm -f "$tmp"
    echo "  $target could not be written, so it may be cut short: restore it from its newest .bak copy beside it, then run cabinet bootstrap again"
    failures=1; return 1
  fi
  rm -f "$tmp"
  echo "  $target: the merge did not produce a valid file (its shape is not what the kit expects), left as is: add the kit's rules by hand"
  failures=1; return 1
}

# A config that is not plain JSON (comments, trailing commas), or holds a value that a rewrite would
# change (json --exact: 1.0, 1e3, a number beyond a double, a whole-number key), is never rewritten.
json_ok() { [[ ! -f "$1" ]] || json --exact -e '$' "$1" >/dev/null 2>&1; }

# Union-merge a {permissions:{deny,ask}} snippet into a JSON settings file.
merge_permissions() {
  local snippet=$1 target=$2 missing
  [[ -f "$snippet" ]] || return 0
  json_ok "$target" || { echo "  $target is not plain JSON, or a rewrite would change one of its values, left as is: add the rules in $snippet by hand"; failures=1; return 0; }
  missing="$(json -s '((a, b) => ["deny", "ask"].map((k) => list(b[k]).filter((x) => !list(a[k]).includes(x)).length).reduce((x, y) => x + y))
    (obj(obj($[0]).permissions), obj(obj($[1]).permissions))' "$target" "$snippet" 2>/dev/null)" \
    || missing="$(json 'list(obj($.permissions).deny).length + list(obj($.permissions).ask).length' "$snippet")"
  [[ "$missing" == "0" ]] && return 0
  if ((DRY)); then echo "  would add $missing permission rule(s) to $target"; return 0; fi
  [[ -f "$target" ]] || { mkdir -p "$(dirname "$target")"; echo '{}' > "$target"; }
  backup "$target"
  write_into "$target" json json -s '((a, b) => ({...obj($[0]), permissions: {...a, ...Object.fromEntries(["deny", "ask"].map((k) =>
      [k, [...list(a[k]), ...list(b[k]).filter((x) => !list(a[k]).includes(x))]]))}}))(obj(obj($[0]).permissions), obj(obj($[1]).permissions))' \
    "$target" "$snippet" && echo "  added $missing permission rule(s) to $target"
  return 0
}

# Complete an older copy of the Codex rules or the Gemini policy with the kit's rules it lacks (counted as
# the doctor counts them): the result is built and checked first, then the file is backed up (a plain copy
# beside the path given), then written in place; it only adds lines at the end, after a comment line. A file
# that holds every rule is not touched; a check or a backup that fails leaves it as it is, with the reason.
add_rules() {  # add_rules codex|gemini <file> <kit's file>
  local kind=$1 f=$2 kit=$3 n tmp bak err
  n="$(node "$LIBJS" rules-missing "$kind" "$f" "$kit" 2>/dev/null)" || { echo "  $f could not be read, left as is: add the rules in $kit by hand"; failures=1; return 0; }
  [[ "$n" == 0 ]] && return 0
  if ((DRY)); then echo "  would add $n kit rule(s) to $f, after a backup"; return 0; fi
  tmp="$(mktemp)"
  if ! node "$LIBJS" rules-add "$kind" "$f" "$kit" > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]] ||
     { [[ "$kind" == gemini ]] && [[ "$(node "$LIBJS" rules-missing gemini "$tmp" "$kit" 2>/dev/null)" != 0 ]]; } ||
     { [[ "$kind" == codex ]] && command -v codex >/dev/null &&
       [[ "$(codex execpolicy check --rules "$tmp" git push origin main 2>/dev/null | json -r '$.decision' 2>/dev/null)" != "forbidden" ]]; }; then
    rm -f "$tmp"
    echo "  $f lacks $n kit rule(s), and with them added it no longer checks out, so it is left as is. Add these lines by hand:"
    node "$LIBJS" rules-missing "$kind" "$f" "$kit" --list 2>/dev/null | sed 's/^/    /'
    failures=1; return 0
  fi
  bak="$f.bak.$(date +%Y%m%d%H%M%S)"
  if ! err="$(cp -p "$f" "$bak" 2>&1)"; then
    rm -f "$tmp" "$bak" 2>/dev/null
    echo "  $f was not changed: its backup could not be written beside it (${err:-cp failed}). Free the folder, then run cabinet bootstrap again"
    failures=1; return 0
  fi
  write_into "$f" text cat "$tmp" && echo "  added $n kit rule(s) to $f (a newer kit has them; the file was backed up to $bak)"
  rm -f "$tmp"
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
# What a new builder changes. Committed below when the workspace has its own git and none of it
# held uncommitted changes before, so the owner's own edits are never swept into the commit.
built=(AGENTS.md ORG.md agents .claude/agents)
own_git=0
[[ "$(secrets_hook)" != none && -z "$(git -C "$WS" status --porcelain -- "${built[@]}" 2>/dev/null)" ]] && own_git=1
while IFS=$'\t' read -r name url files link path; do
  repo="$(repo_dir "$path")"
  [[ -e "$repo/.git" ]] || continue
  N="$name" node "$LIBJS" has "$WS/AGENTS.md" '/^\| `${N}` \|[^|]*\|\s*TBD\s*\|\s*$/' 2>/dev/null || continue
  b="$(builder_for "$repo")"
  if ((DRY)); then echo "  would make $b the owner of $name"; continue; fi
  N="$name" B="$b" node "$LIBJS" sub "$WS/AGENTS.md" -- '/^(\| `${N}` \|[^|]*\|)\s*TBD\s*\|\s*$/' '$1 ${B} |'
  echo "  $name: owned by the $b builder, from what the repo holds (change its row in AGENTS.md to choose another)"
  assigned=1
done < <(repos)

echo "== Shared instructions and roles"
[[ -e "$WS/CLAUDE.md" ]] || { run ln -s AGENTS.md "$WS/CLAUDE.md"; echo "  linked CLAUDE.md"; }
run "$WS/bin/role.sh" build
if ((assigned)); then
  if ((own_git)) && git -C "$WS" add -A -- "${built[@]}" 2>/dev/null &&
     git -C "$WS" -c commit.gpgsign=false commit -q -m "roles: builders for new repos, from bootstrap" -- "${built[@]}" >/dev/null 2>&1; then
    echo "  committed the new builders (AGENTS.md, ORG.md, agents/, .claude/agents/)"
  else
    echo "  review and commit AGENTS.md, ORG.md and the built roles (agents/, .claude/agents/)"
  fi
fi

echo "== Git push gate"
# A global core.hooksPath makes git skip every repo's own .git/hooks, so every other
# hook gets a stub that passes the call on to the repo's own hook (pre-commit
# secret scanners keep working). pre-push is the gate itself, and passes on too.
# Not push-to-checkout or fsmonitor-watchman: git changes its behavior when those merely exist.
hooks="$HOME/.config/git/hooks"
for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit commit-msg \
         post-commit post-checkout post-merge post-rewrite pre-auto-gc reference-transaction \
         post-index-change sendemail-validate; do
  place "$G/hook-passthrough" "$hooks/$h"
done
# Three hooks are the kit's own, and pass the call on too: pre-push is the push gate, prepare-commit-msg
# is the credit hook (credit roles), which also refuses an amend in a Cabinet run, and pre-rebase refuses
# a rebase there. Each replaces only what the kit put there: no file, the pass-through stub, an earlier
# version of the same hook (its line 2, "# cabinet <what> v<N>", with a lower N), or a released kit copy,
# known by its SHA-256 (the push gate's from before line 2 too). An earlier version that is no released
# copy was edited: it is kept first as <hook>.cabinet-v<N>, where git never runs it, and when that name
# holds something else, the hook is left as it is. Anything else is yours, and left as it is.
hook_v() { sed -n "2s/^# cabinet $2 v\\([0-9][0-9]*\\)\$/\\1/p" "$1" 2>/dev/null; }
sha256() { node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update(require("node:fs").readFileSync(process.argv[1])).digest("hex"))' "$1" 2>/dev/null; }
kit_hook() {  # kit_hook <hook> <what> <what is lost when it is left as is> [<SHA-256 of a released kit copy>...]
  local h="$hooks/$1" src="$G/$1" what="$2" lost="$3" old="" kit=0 keep="" sum s
  shift 3
  if [[ -f "$h" && ! -L "$h" ]]; then
    old="$(hook_v "$h" "$what")"; sum="$(sha256 "$h")"
    for s in "$@"; do [[ "$sum" != "$s" ]] || kit=1; done
    cmp -s "$G/hook-passthrough" "$h" && kit=1
    if ((kit == 0)) && [[ -n "$old" && "$old" -lt "$(hook_v "$src" "$what")" ]]; then
      keep="$h.cabinet-v$old"
      [[ ! -e "$keep" && ! -L "$keep" ]] || cmp -s "$h" "$keep" || keep="!"
    fi
  fi
  if [[ -f "$h" && ! -L "$h" ]] && cmp -s "$src" "$h"; then :
  elif [[ "$keep" != "!" ]] && { [[ ! -e "$h" && ! -L "$h" ]] || ((kit)) || [[ -n "$keep" ]]; }; then
    if ((DRY)); then echo "  would place the $what at $h"; [[ -z "$keep" ]] || echo "  would keep your edited copy of the earlier $what as $keep"
    else
      mkdir -p "$hooks"
      if [[ -n "$keep" ]]; then
        cp -p "$h" "$keep" || { echo "  could not keep your edited copy as $keep, so left as is: $h ($lost on this machine)"; return 0; }
        echo "  kept your edited copy of the earlier $what as $keep"
      fi
      cp "$src" "$h.cabinet-new" && chmod +x "$h.cabinet-new" && mv -f "$h.cabinet-new" "$h" && echo "  placed the $what at $h"
    fi
  else
    echo "  differs, left as is: $h ($lost on this machine; cabinet doctor says why)"
  fi
}
# The push gate's 0.1.0 copy had no line 2. Left as is, a gate of your own still asks before every push, in every repo.
kit_hook pre-push "push gate" "the gate asks in every repo, not only Cabinet's," de138ae20c0786fd3125a7202e900b1bb49085b8963265f57473a0825ea8cfc5
# Its helper, beside it, whenever the gate there is the kit's: it finds Cabinet's repos.
if cmp -s "$G/pre-push" "$hooks/pre-push" && ! cmp -s "$G/cabinet-push-gate.js" "$hooks/cabinet-push-gate.js"; then
  if ((DRY)); then echo "  would place the push gate's helper at $hooks/cabinet-push-gate.js"
  else cp "$G/cabinet-push-gate.js" "$hooks/cabinet-push-gate.js.cabinet-new" && mv -f "$hooks/cabinet-push-gate.js.cabinet-new" "$hooks/cabinet-push-gate.js" && echo "  placed the push gate's helper at $hooks/cabinet-push-gate.js"; fi
fi
# The credit hook as released: v3 in 0.2.0 and 0.2.1, v4 in 0.3.0. Add the current one's here when it changes.
kit_hook prepare-commit-msg "credit hook" "credit roles cannot add their line, and runs are not refused an amend," \
  7184259644c63e37567e8b7d41b278f6534cfac98a05afcee543cf69b868c706 7f3e0132d1f4b10b9b5a76e6d3e3863714fd8e71ad762c4efd9d97ca4320bbca
kit_hook pre-rebase "pre-rebase hook" "runs are not refused a rebase"
for h in "$hooks"/*; do [[ -f "$h" && ! -x "$h" ]] && run chmod +x "$h"; done
current="$(git config --global core.hooksPath || true)"
if [[ -z "$current" ]]; then
  run git config --global core.hooksPath "$hooks"
elif [[ "$current" != "$hooks" ]]; then
  echo "  core.hooksPath is $current, not $hooks. Left as is: check the gate there (bin/doctor.sh)."
fi
echo "  The strongest guardrail is a key that asks you on every push: see \"A hard boundary\" in the kit's docs/guardrails.md."

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
  if [[ -e "$HOME/.codex/rules/default.rules" ]]; then add_rules codex "$HOME/.codex/rules/default.rules" "$G/codex-default.rules"
  else place "$G/codex-default.rules" "$HOME/.codex/rules/default.rules"; fi
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
  if [[ -e "$HOME/.gemini/policies/owner-control.toml" ]]; then add_rules gemini "$HOME/.gemini/policies/owner-control.toml" "$G/gemini-owner-control.toml"
  else place "$G/gemini-owner-control.toml" "$HOME/.gemini/policies/owner-control.toml"; fi
  g="$HOME/.gemini/settings.json"
  if ! json_ok "$g"; then
    echo "  $g is not plain JSON, or a rewrite would change one of its values, left as is: set context.fileName to [\"AGENTS.md\", \"GEMINI.md\"] by hand"; failures=1
  elif [[ ! -f "$g" ]]; then
    place "$G/gemini-context.json" "$g"
  elif [[ "$(json 'obj(obj($).context).fileName ?? undefined' "$g" 2>/dev/null)" == "" ]]; then
    # The kit's file merged in, an object inside an object key by key; anything else is replaced.
    ((DRY)) && echo "  would set context.fileName in $g" || { backup "$g"; write_into "$g" json json -s '(function m(a, b) {
      const o = (x) => x !== null && typeof x == "object" && !Array.isArray(x);
      return o(a) && o(b) ? Object.keys(b).reduce((r, k) => ({...r, [k]: k in a ? m(a[k], b[k]) : b[k]}), a) : b;
    })(obj($[0]), $[1])' "$g" "$G/gemini-context.json" && echo "  set context.fileName in $g (Gemini reads AGENTS.md)"; }
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
  rules="$(json -c '((p) => Object.fromEntries([...list(p.deny).map((r) => [r, "deny"]), ...list(p.ask).map((r) => [r, "ask"])]
    .filter(([r]) => r.startsWith("Bash(")).map(([r, a]) => [r.replace(/^Bash\((.*)\)$/, "$1"), a])))(obj(obj($).permissions))' "$snippet")"
  if ! json_ok "$target"; then
    echo "  $target is not plain JSON, or a rewrite would change one of its values, left as is: add these under permission.bash by hand: $rules"; failures=1; return 0
  fi
  if [[ ! -f "$target" ]]; then
    if ((DRY)); then echo "  would create $target with $(json 'Object.keys($).length' <<<"$rules") bash rule(s)"; return 0; fi
    mkdir -p "$(dirname "$target")"; echo '{"$schema": "https://opencode.ai/config.json"}' > "$target"
  fi
  # Missing: any kit rule absent, different, or not among the last entries.
  missing="$(json --argjson r "$rules" '((p, n) => ((b) => (b === null || typeof b != "object" || Array.isArray(b) ? n
    : ((tail) => Object.keys($r).filter((k) => tail[k] !== $r[k]).length)(Object.fromEntries(Object.entries(b).slice(-n)))))
    (p !== null && typeof p == "object" && !Array.isArray(p) ? p.bash : null))(obj($).permission, Object.keys($r).length)' "$target")"
  [[ "$missing" == 0 ]] && return 0
  backup "$target"
  if ((DRY)); then echo "  would add or reorder $missing bash rule(s) in $target"; return 0; fi
  # A rule set as one string ("permission": "ask") is the catch-all "*"; the kit's rules go last.
  write_into "$target" json json --argjson r "$rules" '((p) => ((b) => ({...obj($), permission: {
      ...Object.fromEntries(Object.entries(p).filter(([k]) => k != "bash")),
      bash: {...Object.fromEntries(Object.entries(b).filter(([k]) => !Object.hasOwn($r, k))), ...$r}}}))
    (typeof p.bash == "string" ? {"*": p.bash} : obj(p.bash)))(typeof obj($).permission == "string" ? {"*": $.permission} : obj($.permission))' \
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
# The log folder records which workspace owns this slug, whatever the scheduler: the push gate reads it.
# Claimed only when it is free, already ours, or its workspace folder is gone. A workspace that finds it held
# by another is listed in its shared file instead, so the gate still asks in this workspace's repos.
# Compared as real paths, as the doctor compares them, so a claim naming this workspace through a link is its own.
if ((DRY == 0)) && ! mkdir -p -m 700 "$LOGDIR"; then
  echo "  the log folder $LOGDIR could not be made, so the push gate may not ask in this workspace's repos"; failures=1
elif ((DRY == 0)); then
  owner_ws="$(head -1 "$LOGDIR/workspace" 2>/dev/null || true)"
  if [[ -z "$owner_ws" || ! -d "$owner_ws" || "$(cd "$owner_ws" && pwd -P)" == "$WS" ]]; then
    printf '%s\n' "$WS" > "$LOGDIR/workspace" || { echo "  $LOGDIR/workspace could not be written, so the push gate may not ask in this workspace's repos"; failures=1; }
  else
    grep -qxF "$WS" "$LOGDIR/shared" 2>/dev/null || printf '%s\n' "$WS" >> "$LOGDIR/shared" || { echo "  $LOGDIR/shared could not be written, so the push gate may not ask in this workspace's repos"; failures=1; }
    echo "  the log folder $LOGDIR belongs to the workspace at $owner_ws: give this one its own slug (cabinet config --slug); until then the push gate still asks in this workspace's repos"; failures=1
  fi
fi
if [[ "$SCHEDULER" == none ]]; then
  echo "  no scheduler found (a running systemd user session, or cron): install cron, or run cabinet job run <job> by hand"
else
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
