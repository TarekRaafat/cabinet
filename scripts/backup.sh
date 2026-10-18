#!/usr/bin/env bash
# Write one encrypted archive of everything a disaster would lose: every
# repo's full git history (unpushed commits, local branches), uncommitted
# changes, untracked files, stashes, .env files, and Claude Code's memory and
# settings for this workspace. Restore with bin/restore.sh.
#
#   bin/backup.sh [dest-dir]     default: CABINET_BACKUP_DIR in cabinet.env
#
# Passphrase: $CABINET_BACKUP_PASSPHRASE, else the login keychain item
# cabinet.<slug>.backup (bin/bootstrap.sh prints how to create it). Keep the
# same passphrase in your password manager: without it no archive opens.
# Keeps the newest CABINET_BACKUP_KEEP archives (at least 1) of this workspace
# only. The folder must be outside the workspace and every repo it lists: a
# backup next to what it protects is lost with it, and inside a repo it would
# copy itself into every later archive and could be committed.
# Reads repos; never changes them.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
umask 077   # archives and staging are readable by you only

dest="${1:-$CABINET_BACKUP_DIR}"
[[ -n "$dest" ]] || { echo "usage: backup.sh <dest-dir> (or set CABINET_BACKUP_DIR)" >&2; exit 2; }
[[ "$dest" == /* || "$dest" == "~/"* ]] || { echo "the backup folder must be an absolute path, not '$dest'" >&2; exit 2; }
dest="$(abspath "$dest")"
while IFS= read -r d; do
  within "$dest" "$d" && { echo "the backup folder $dest is inside $d: choose a folder outside the workspace and its repos (a synced drive or an external disk)" >&2; exit 2; }
done < <(data_dirs)
[[ "$CABINET_BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "CABINET_BACKUP_KEEP must be 1 or more, not '$CABINET_BACKUP_KEEP'" >&2; exit 2; }
pass="${CABINET_BACKUP_PASSPHRASE:-$(security find-generic-password -a "$USER" -s "$KEYCHAIN_ITEM" -w 2>/dev/null || true)}"
[[ -n "$pass" ]] || { echo "no passphrase: set CABINET_BACKUP_PASSPHRASE or create the keychain item $KEYCHAIN_ITEM" >&2; exit 1; }

stamp="$(date +%Y%m%d-%H%M%S)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
out="$tmp/$CABINET_SLUG-$stamp"
mkdir -p "$out" "$dest"

# The archive holds workspace/, repos/<name>/ and claude/, so no repo name collides.
save_repo() {
  local name=$1 repo=$2 o="$out/$3"
  [[ -e "$repo/.git" ]] || { echo "skip $name: no repo at $repo"; return 0; }
  mkdir -p "$o"
  if ! git -C "$repo" rev-parse -q --verify HEAD >/dev/null; then
    # No commits yet (for example a workspace made without an owner identity): keep its files.
    git -C "$repo" ls-files --cached --others --exclude-standard -z | (cd "$repo" && tar --null -T - -cf "$o/untracked.tar" 2>/dev/null) || true
    echo "  $name: no commits yet, files only"; return 0
  fi
  git -C "$repo" bundle create "$o/repo.bundle" --all 2>/dev/null
  git -C "$repo" remote get-url origin > "$o/origin" 2>/dev/null || true
  # The branch it is on, or "-" when HEAD is detached, so restore brings back exactly that.
  git -C "$repo" symbolic-ref -q --short HEAD > "$o/branch" 2>/dev/null || echo - > "$o/branch"
  git -C "$repo" diff HEAD --binary > "$o/worktree.patch"
  git -C "$repo" ls-files --others --exclude-standard -z | (cd "$repo" && tar --null -T - -cf "$o/untracked.tar" 2>/dev/null) || true
  local n=0
  while git -C "$repo" rev-parse -q --verify "stash@{$n}" >/dev/null; do
    git -C "$repo" stash show -p --include-untracked --binary "stash@{$n}" > "$o/stash-$n.patch" 2>/dev/null || true
    n=$((n + 1))
  done
  # .env files are ignored by git, so nothing else keeps them.
  # Stops at nested repos, so the workspace never captures a product repo's files.
  (cd "$repo" && find . -mindepth 1 -maxdepth 3 \( -type d \( -name node_modules -o -exec test -e '{}/.git' \; \) -prune \) \
    -o \( -name '.env*' ! -name '*.example' -type f -print0 \) \
    | tar --null -T - -cf "$o/env.tar" 2>/dev/null) || true
  echo "  $name: $(git -C "$repo" rev-list --count --all) commits, $n stashes"
}

# Fresh snapshot first, so local-only files are current.
"$WS/bin/snapshot.sh" >/dev/null

echo "== Repos"
# A shared workspace inside a project has no git of its own: the project's repo holds it.
[[ "$(git -C "$WS" rev-parse --show-toplevel 2>/dev/null)" == "$(cd "$WS" && pwd -P)" ]] && save_repo workspace "$WS" workspace
while IFS=$'\t' read -r name url files link path; do save_repo "$name" "$(repo_dir "$path")" "repos/$name"; done < <(repos)

echo "== Claude Code"
mem="$HOME/.claude/projects/$CLAUDE_SLUG/memory"
[[ -d "$mem" ]] && mkdir -p "$out/claude" && cp -Rp "$mem" "$out/claude/memory" && echo "  memory"
[[ -f "$HOME/.claude/settings.json" ]] && mkdir -p "$out/claude" && cp -p "$HOME/.claude/settings.json" "$out/claude/settings.json" && echo "  settings"

file="$dest/$CABINET_SLUG-$stamp.tar.gz.enc"
tar -C "$tmp" -czf - "$CABINET_SLUG-$stamp" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass fd:3 3<<<"$pass" > "$file.part"
mv "$file.part" "$file"
echo "== Wrote $file ($(du -h "$file" | cut -f1))"

# Only this workspace's archives count and are removed: <slug>-YYYYMMDD-HHMMSS.tar.gz.enc exactly,
# so app's cleanup never touches app-web's.
ls -1t "$dest" 2>/dev/null | grep -E "^${CABINET_SLUG//./\\.}-[0-9]{8}-[0-9]{6}\.tar\.gz\.enc$" \
  | tail -n +$((CABINET_BACKUP_KEEP + 1)) | while IFS= read -r old; do rm -f "$dest/$old"; done
