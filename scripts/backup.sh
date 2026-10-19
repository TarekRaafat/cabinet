#!/usr/bin/env bash
# Write one encrypted archive of everything a disaster would lose: every
# repo's full git history (unpushed commits, local branches), uncommitted
# changes, untracked files, stashes, .env files, and Claude Code's memory and
# settings for this workspace. Restore with bin/restore.sh.
#
#   bin/backup.sh [dest-dir]            default: CABINET_BACKUP_DIR in cabinet.env
#   bin/backup.sh --verify [dest-dir]   restore the newest archive into a temporary folder,
#                                       check it against the workspace and its repos, delete it
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

verify=0 dest=""
for a in "$@"; do
  case "$a" in --verify) verify=1 ;; -*) echo "usage: backup.sh [--verify] [dest-dir]" >&2; exit 2 ;; *) dest="$a" ;; esac
done
dest="${dest:-$CABINET_BACKUP_DIR}"
[[ -n "$dest" ]] || { echo "usage: backup.sh [--verify] <dest-dir> (or set CABINET_BACKUP_DIR)" >&2; exit 2; }
[[ "$dest" == /* || "$dest" == "~/"* ]] || { echo "the backup folder must be an absolute path, not '$dest'" >&2; exit 2; }
dest="$(abspath "$dest")"
while IFS= read -r d; do
  within "$dest" "$d" && { echo "the backup folder $dest is inside $d: choose a folder outside the workspace and its repos (a synced drive or an external disk)" >&2; exit 2; }
done < <(data_dirs)
[[ "$CABINET_BACKUP_KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "CABINET_BACKUP_KEEP must be 1 or more, not '$CABINET_BACKUP_KEEP'" >&2; exit 2; }
pass="${CABINET_BACKUP_PASSPHRASE:-$(security find-generic-password -a "$USER" -s "$KEYCHAIN_ITEM" -w 2>/dev/null || true)}"
[[ -n "$pass" ]] || { echo "no passphrase: set CABINET_BACKUP_PASSPHRASE or create the keychain item $KEYCHAIN_ITEM" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# This workspace's archives only: <slug>-YYYYMMDD-HHMMSS.tar.gz.enc exactly, so app never takes app-web's.
mine() { ls -1t "$dest" 2>/dev/null | grep -E "^${CABINET_SLUG//./\\.}-[0-9]{8}-[0-9]{6}\.tar\.gz\.enc$" || true; }
# What the backup holds: "label<TAB>folder<TAB>place in the archive". A shared workspace inside a
# project has no git of its own: the project's repo holds it.
targets() {
  [[ "$(git -C "$WS" rev-parse --show-toplevel 2>/dev/null)" == "$(cd "$WS" && pwd -P)" ]] && printf 'workspace\t%s\tworkspace\n' "$WS"
  while IFS=$'\t' read -r name url files link path; do printf '%s\t%s\trepos/%s\n' "$name" "$(repo_dir "$path")" "$name"; done < <(repos)
}

if ((verify)); then
  # Rebuild every repo from the newest archive in a temporary folder, as restore would, and compare
  # it with now. A failure to open, rebuild or apply is a problem; work done since the backup is not.
  file="$(mine | head -1)"
  [[ -n "$file" ]] || { echo "no archive of $CABINET_SLUG in $dest" >&2; exit 1; }
  stamp="${file#"$CABINET_SLUG"-}"; stamp="${stamp%.tar.gz.enc}"
  echo "Verifying $file (backed up $(human_stamp "$stamp"))"
  problems=0
  problem() { echo "  PROBLEM $*"; problems=$((problems + 1)); }
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass fd:3 3<<<"$pass" < "$dest/$file" 2>"$tmp/err" | tar -C "$tmp" -xzf - 2>>"$tmp/err"; then
    problem "the archive does not open (a wrong passphrase, or a damaged file): $(head -1 "$tmp/err")"
  else
    src="$tmp/$CABINET_SLUG-$stamp"
    # Files that differ between two folders, over what git sees in either (tracked, and untracked not ignored).
    differ() {
      { git -C "$1" ls-files -co --exclude-standard; git -C "$2" ls-files -co --exclude-standard; } | sort -u | while IFS= read -r f; do
        if [[ -L "$1/$f" || -L "$2/$f" ]]; then [[ "$(readlink "$1/$f" 2>/dev/null)" == "$(readlink "$2/$f" 2>/dev/null)" ]] || echo "$f"
        else cmp -s "$1/$f" "$2/$f" || echo "$f"; fi
      done | wc -l | tr -d ' '
    }
    while IFS=$'\t' read -r name dir sub; do
      o="$src/$sub" r="$tmp/check/$sub"
      [[ -e "$dir/.git" ]] || { echo "  $name: no repo at $dir, not checked"; continue; }
      [[ -d "$o" ]] || { problem "$name: not in the archive (back up again)"; continue; }
      if [[ ! -f "$o/repo.bundle" ]]; then
        tar -tf "$o/untracked.tar" >/dev/null 2>&1 && echo "  $name: its files restore (it had no commits)" || problem "$name: its files do not restore"
        continue
      fi
      if ! { git clone -q --no-checkout "$o/repo.bundle" "$r" && git -C "$r" fetch -q --update-head-ok "$o/repo.bundle" '+refs/heads/*:refs/heads/*'; } 2>"$tmp/err"; then
        problem "$name: its history does not restore: $(head -1 "$tmp/err")"; continue
      fi
      b="$(cat "$o/branch" 2>/dev/null || true)"
      if [[ -n "$b" && "$b" != - ]]; then git -C "$r" symbolic-ref HEAD "refs/heads/$b"
      else git -C "$r" fetch -q "$o/repo.bundle" HEAD 2>/dev/null && git -C "$r" update-ref --no-deref HEAD FETCH_HEAD; fi
      git -C "$r" reset -q --hard 2>/dev/null || { problem "$name: the branch it was on ($b) is not in the archive"; continue; }
      [[ ! -s "$o/worktree.patch" ]] || git -C "$r" apply --binary "$o/worktree.patch" 2>/dev/null || { problem "$name: its uncommitted changes do not apply"; continue; }
      [[ ! -f "$o/untracked.tar" ]] || tar -C "$r" -xf "$o/untracked.tar" 2>/dev/null || { problem "$name: its untracked files do not restore"; continue; }
      [[ ! -f "$o/env.tar" ]] || tar -tf "$o/env.tar" >/dev/null 2>&1 || { problem "$name: its .env files do not restore"; continue; }
      n="$(git -C "$r" rev-list --count --all)" ah="$(git -C "$r" rev-parse HEAD)" lh="$(git -C "$dir" rev-parse -q --verify HEAD || true)"
      if [[ "$ah" == "$lh" ]]; then
        d="$(differ "$dir" "$r")"
        ((d == 0)) && echo "  $name: restores exactly as it is now ($n commits)" || echo "  $name: restores ($n commits); $d file(s) changed since the backup"
      elif [[ -n "$lh" ]] && git -C "$dir" merge-base --is-ancestor "$ah" "$lh" 2>/dev/null; then
        echo "  $name: restores ($n commits); $(git -C "$dir" rev-list --count "$ah..$lh") commit(s) since the backup"
      else
        echo "  $name: restores ($n commits); its history changed since the backup (a rebase, a reset or another branch)"
      fi
    done < <(targets)
  fi
  if ((problems)); then echo "Verify failed: $problems problem(s). Back up again (bin/backup.sh), then verify that archive."; exit 1; fi
  # The doctor reads the date of the last good verify from here, never from the backup folder.
  mkdir -p -m 700 "$LOGDIR"; echo "$file" > "$LOGDIR/backup-verified"
  echo "Verified: $file restores. The temporary copy is deleted."
  exit 0
fi

stamp="$(date +%Y%m%d-%H%M%S)"
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
while IFS=$'\t' read -r name dir sub; do save_repo "$name" "$dir" "$sub"; done < <(targets)

echo "== Claude Code"
mem="$HOME/.claude/projects/$CLAUDE_SLUG/memory"
[[ -d "$mem" ]] && mkdir -p "$out/claude" && cp -Rp "$mem" "$out/claude/memory" && echo "  memory"
[[ -f "$HOME/.claude/settings.json" ]] && mkdir -p "$out/claude" && cp -p "$HOME/.claude/settings.json" "$out/claude/settings.json" && echo "  settings"

file="$dest/$CABINET_SLUG-$stamp.tar.gz.enc"
tar -C "$tmp" -czf - "$CABINET_SLUG-$stamp" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass fd:3 3<<<"$pass" > "$file.part"
mv "$file.part" "$file"
echo "== Wrote $file ($(du -h "$file" | cut -f1))"

# Only this workspace's archives are removed, never another's in the same folder.
mine | tail -n +$((CABINET_BACKUP_KEEP + 1)) | while IFS= read -r old; do rm -f "$dest/$old"; done
