#!/usr/bin/env bash
# Move the workspace to a new folder and update everything that remembers its
# path: Claude Code's per-folder memory and history, its trusted projects,
# Codex's trusted projects, and the schedules.
#
#   bin/move.sh <new-path> [--dry-run]
#
# Run it from a plain Terminal with every Claude Code, Codex and dev server
# session closed: they hold the old path open and would rewrite the configs.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

OLD="$WS"
NEW="${1:?usage: move.sh <new-path> [--dry-run]}"; NEW="${NEW%/}"
[[ "$NEW" = /* ]] || NEW="$PWD/$NEW"
DRY=0; [[ "${2:-}" == "--dry-run" ]] && DRY=1
run() { if ((DRY)); then echo "  would: $*"; else "$@"; fi; }
die() { echo "stop: $*" >&2; exit 1; }
backup() { [[ -f "$1" ]] && run cp -p "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; return 0; }

# A workspace inside or beside a project points at it by a path relative to itself:
# moving the workspace alone would break that. Move the project with it by hand.
case "$CABINET_LAYOUT" in
  inside) die "this workspace is cabinet/ inside a project: move the whole project folder instead, then run cabinet/bin/bootstrap.sh" ;;
  beside) die "this workspace points at a project beside it (repos.tsv): move both by hand, fix the path in repos.tsv, then run bin/bootstrap.sh" ;;
esac
[[ -e "$NEW" ]] && die "$NEW already exists"
[[ -d "$(dirname "$NEW")" ]] || die "$(dirname "$NEW") does not exist"
case "$NEW" in
  "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Library/Mobile Documents"*)
    die "iCloud syncs $NEW; syncing .git and node_modules corrupts repos. Pick a folder like ~/dev/$CABINET_SLUG." ;;
esac
open_cwd="$(lsof -a -d cwd -c claude -c codex -c node -c bun -Fn 2>/dev/null | grep "^n$OLD" | head -3 || true)"
[[ -z "$open_cwd" ]] || die "close the sessions still open in the workspace first:
${open_cwd//n\//  /}"

slug() { claude_slug "$1"; }
os="$(slug "$OLD")" ns="$(slug "$NEW")"

echo "== Schedules: stop"
for live in "$SCHED_DIR/$LABEL".*"$SCHED_EXT"; do
  [[ -f "$live" ]] && mine "$live" || continue
  run sched_unload "$(sched_label "$live")"
done

# The workspace and its folders, listed before the move (Claude memory follows them below).
cands=("$OLD")
while IFS= read -r -d '' sub; do cands+=("$sub"); done < <(find "$OLD" -mindepth 1 -maxdepth 3 -type d \( -name .git -o -name node_modules \) -prune -o -type d -print0 2>/dev/null)

echo "== Move $OLD -> $NEW"
run mv "$OLD" "$NEW"

echo "== Claude Code memory and history"
# Claude names a folder's memory after its path, so only folders that really are the
# workspace or inside it move: a sibling such as <workspace>-old keeps its own memory.
for c in "${cands[@]}"; do
  d="$HOME/.claude/projects/$(slug "$c")"
  [[ -d "$d" ]] || continue
  run mv "$d" "$HOME/.claude/projects/$(slug "$NEW${c#"$OLD"}")"
done

echo "== Claude Code trusted projects"
cj="$HOME/.claude.json"
if [[ -f "$cj" ]]; then
  backup "$cj"
  ((DRY)) && echo "  would rename $(jq --arg o "$OLD" '[.projects // {} | keys[] | select(. == $o or startswith($o + "/"))] | length' "$cj") project entries" || {
    out="$(jq --arg o "$OLD" --arg n "$NEW" '.projects |= ((. // {}) | with_entries(
      if (.key == $o or (.key | startswith($o + "/"))) then .key = $n + (.key | ltrimstr($o)) else . end))' "$cj")" && printf '%s\n' "$out" > "$cj"; }
fi

echo "== Codex trusted projects"
cx="$HOME/.codex/config.toml"
# Exactly the workspace's path or paths inside it ("OLD" or "OLD/..."), never a sibling like "OLD-old".
if [[ -f "$cx" ]] && grep -qF "\"$OLD" "$cx"; then
  backup "$cx"
  ((DRY)) && echo "  would update $cx" || { out="$(O="$OLD" N="$NEW" perl -pe 's/"\Q$ENV{O}\E(?=["\/])/"$ENV{N}/g' "$cx")" && printf '%s\n' "$out" > "$cx"; }
fi

echo "== Schedules: reinstall at the new path"
if ((DRY)); then echo "  would run $NEW/bin/bootstrap.sh and $NEW/bin/doctor.sh"; else
  # A problem bootstrap reports must not stop the steps after the move.
  { "$NEW/bin/bootstrap.sh" || echo "bootstrap reported a problem: see above, then rerun $NEW/bin/bootstrap.sh"; } | sed -n '/Schedules/,$p'
  "$NEW/bin/doctor.sh" || true
fi

cat <<EOF

Done. By hand:
- Open new Terminal and editor windows at $NEW (old ones point at a path that is gone).
- Any scheduled task you created inside an app (not a cabinet schedule) that names $OLD: edit it to $NEW.
EOF
