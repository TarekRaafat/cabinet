#!/usr/bin/env bash
# Restore from an archive written by bin/backup.sh. Never loses a file:
# - a repo that already exists gets the archive's branches under refs/remotes/backup/
#   to compare and merge by hand;
# - a missing repo, or an empty folder, is restored with its uncommitted work;
# - in the workspace folder itself, or a project folder that holds nothing but the
#   workspace being restored, files are checked out in place, and any file the
#   archive would replace with different content (tracked or untracked) is first
#   copied to recovered/;
# - any other folder that already holds files is left alone, and the repo is
#   restored into recovered/<archive>/<name>/repo instead.
# Stashes are left as patches.
#
#   bin/restore.sh <archive.tar.gz.enc> [workspace-dir]
#
# Passphrase as in backup.sh. Then run bin/bootstrap.sh and bin/doctor.sh.
# Needs no cabinet.env: it may run before the workspace exists.
set -euo pipefail

archive="${1:?usage: restore.sh <archive> [workspace-dir]}"
target="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
slug="$(basename "$archive")"; slug="${slug%.tar.gz.enc}"; slug="${slug%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*}"
pass="${CABINET_BACKUP_PASSPHRASE:-$(security find-generic-password -a "$USER" -s "cabinet.$slug.backup" -w 2>/dev/null || true)}"
[[ -n "$pass" ]] || { echo "no passphrase: set CABINET_BACKUP_PASSPHRASE or create the keychain item cabinet.$slug.backup" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass fd:3 3<<<"$pass" < "$archive" | tar -C "$tmp" -xzf -
src="$(echo "$tmp"/"$slug"-*)"
mkdir -p "$target"; target="$(cd "$target" && pwd -P)"
kept="$target/recovered/$(basename "$src")"
stamp="${src##*/}"; stamp="${stamp#"$slug"-}"
echo "Restoring $slug from the backup of $(LC_ALL=C date -j -f %Y%m%d-%H%M%S "$stamp" "+%-d %b %Y, %-I:%M %p" 2>/dev/null || echo "$stamp") into $target"

# The branch the repo was on when the backup ran; else the one HEAD pointed at; empty when detached.
branch_of() {
  local o=$1 heads hsha b
  b="$(cat "$o/branch" 2>/dev/null || true)"
  [[ "$b" == - ]] && return 0   # detached when backed up
  if [[ -n "$b" ]]; then echo "refs/heads/$b"; return; fi
  heads="$(git bundle list-heads "$o/repo.bundle")"
  hsha="$(awk '$2 == "HEAD" {print $1}' <<<"$heads")"
  b="$(awk -v h="$hsha" '$2 ~ /^refs\/heads\// && $1 == h {print $2; exit}' <<<"$heads")"
  echo "$b"
}

# Extract a tar of files into a folder, first copying any existing file it would change to <keep>.
extract_keeping() {  # extract_keeping <tar> <folder> <keep-folder>
  local t=$1 into=$2 keep=$3 x f n=0
  x="$(mktemp -d)"; tar -C "$x" -xf "$t"
  while IFS= read -r -d '' f; do
    f="${f#./}"
    # A folder or link where the archive has a file is moved aside whole, so extraction cannot fail on it.
    if [[ -d "$into/$f" || -L "$into/$f" ]]; then mkdir -p "$keep/$(dirname "$f")"; mv "$into/$f" "$keep/$f"; n=$((n + 1))
    elif [[ -e "$into/$f" ]] && ! cmp -s "$x/$f" "$into/$f"; then mkdir -p "$keep/$(dirname "$f")"; cp -p "$into/$f" "$keep/$f"; n=$((n + 1)); fi
  done < <(cd "$x" && find . -type f -print0)
  tar -C "$into" -xf "$t"; rm -rf "$x"
  ((n == 0)) || echo "    $n existing file(s) differed from the archive; your copies are in $keep"
}

# Point HEAD at the archived branch, or at the archived commit when the repo was detached.
set_head() {  # set_head <repo> <bundle> <branch-ref or empty>
  if [[ -n "$3" ]]; then git -C "$1" symbolic-ref HEAD "$3"
  else git -C "$1" fetch -q "$2" HEAD && git -C "$1" update-ref --no-deref HEAD FETCH_HEAD; fi
}

restore_one() {
  local name=$1 o=$2 repo=$3 inplace=$4 head f n
  if [[ ! -f "$o/repo.bundle" ]]; then
    # A repo with no commits yet was archived as its files only.
    if [[ -f "$o/untracked.tar" ]]; then mkdir -p "$repo"; extract_keeping "$o/untracked.tar" "$repo" "$kept/$name"; echo "  $name: files restored (it had no commits)"; fi
    return 0
  fi
  if [[ -e "$repo/.git" ]]; then
    git -C "$repo" fetch -q "$o/repo.bundle" '+refs/heads/*:refs/remotes/backup/*'
    echo "  $name exists: archive branches fetched to refs/remotes/backup/*; compare and merge by hand"
    mkdir -p "$kept/$name"; cp -p "$o"/*.patch "$o"/untracked.tar "$kept/$name/" 2>/dev/null || true
    return 0
  fi
  head="$(branch_of "$o")"
  if [[ -n "$(ls -A "$repo" 2>/dev/null)" ]]; then
    if ((inplace == 0)); then
      # A folder that holds files of its own is never turned into a repo.
      echo "  $name: $repo already holds files and is not a repo, so it is left alone; restored into $kept/$name/repo instead"
      repo="$kept/$name/repo"; mkdir -p "$(dirname "$repo")"
      git clone -q --no-checkout "$o/repo.bundle" "$repo"
      git -C "$repo" fetch -q --update-head-ok "$o/repo.bundle" '+refs/heads/*:refs/heads/*'
      set_head "$repo" "$o/repo.bundle" "$head"; git -C "$repo" reset -q --hard
    else
      # Check out in place, after copying every file it would replace with different content.
      git -C "$repo" init -q
      git -C "$repo" fetch -q --update-head-ok "$o/repo.bundle" '+refs/heads/*:refs/heads/*'
      set_head "$repo" "$o/repo.bundle" "$head"
      git -C "$repo" read-tree HEAD
      n=0
      while IFS= read -r -d '' f; do
        [[ -e "$repo/$f" ]] || continue
        mkdir -p "$kept/$name/$(dirname "$f")"; cp -p "$repo/$f" "$kept/$name/$f"; n=$((n + 1))
      done < <(git -C "$repo" diff --name-only -z)
      ((n == 0)) || echo "  $name: $n existing file(s) differed from the archive; your copies are in $kept/$name"
      git -C "$repo" reset -q --hard
    fi
  else
    mkdir -p "$(dirname "$repo")"; rmdir "$repo" 2>/dev/null || true
    git clone -q --no-checkout "$o/repo.bundle" "$repo"
    git -C "$repo" fetch -q --update-head-ok "$o/repo.bundle" '+refs/heads/*:refs/heads/*'
    set_head "$repo" "$o/repo.bundle" "$head"; git -C "$repo" reset -q --hard
  fi
  # The clone's origin is the archive's bundle: point it back at the real remote, or remove it.
  git -C "$repo" remote remove origin 2>/dev/null || true
  [[ -s "$o/origin" ]] && git -C "$repo" remote add origin "$(cat "$o/origin")"
  [[ -s "$o/worktree.patch" ]] && git -C "$repo" apply --binary "$o/worktree.patch"
  [[ -f "$o/untracked.tar" ]] && extract_keeping "$o/untracked.tar" "$repo" "$kept/$name"
  echo "  $name: restored with its uncommitted work"
  if ls "$o"/stash-*.patch >/dev/null 2>&1; then mkdir -p "$kept/$name"; cp -p "$o"/stash-*.patch "$kept/$name/"; echo "    stashes kept as patches in $kept/$name"; fi
  if [[ -f "$o/env.tar" ]]; then
    while IFS= read -r f; do
      if [[ -e "$repo/$f" ]]; then echo "    $f exists, left as is"; else tar -C "$repo" -xf "$o/env.tar" "$f"; echo "    restored $f"; fi
    done < <(tar -tf "$o/env.tar")
  fi
}

restore_one workspace "$src/workspace" "$target" 1
for o in "$src"/repos/*/; do
  [[ -d "$o" ]] || continue
  name="$(basename "$o")"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$name" != . && "$name" != .. ]] || { echo "  skipped an archived repo with an unusable name"; continue; }
  # Where repos.tsv (restored first, with the workspace) says the repo lives; default <workspace>/<name>.
  p="$(awk -F'\t' -v n="$name" '{ sub(/\r$/, "") } !/^#/ && $1 == n {print $5}' "$target/repos.tsv" 2>/dev/null)"; p="${p:-$name}"
  case "$p" in /*) repo="$p" ;; "~/"*) repo="$HOME/${p#"~/"}" ;; *) repo="$target/$p" ;; esac
  mkdir -p "$repo"; repo="$(cd "$repo" && pwd -P)"
  # In place only when the folder holds nothing but the workspace just restored (the project around cabinet/).
  inplace=0
  others="$(ls -A "$repo" | { [[ "$target" == "$repo"/* ]] && grep -vxF "$(basename "$target")" || cat; } || true)"
  [[ -z "$others" ]] && inplace=1
  restore_one "$name" "${o%/}" "$repo" "$inplace"
done

# Claude Code memory and settings, only where missing.
if [[ -d "$src/claude" ]]; then
  cslug="$(perl -CSA -e '$_ = shift; s/[^A-Za-z0-9]/-/g; print' "$(cd "$target" && pwd)")"
  mem="$HOME/.claude/projects/$cslug/memory"
  if [[ -d "$src/claude/memory" && ! -d "$mem" ]]; then mkdir -p "$(dirname "$mem")"; cp -Rp "$src/claude/memory" "$mem"; echo "  Claude memory restored"; fi
  if [[ -f "$src/claude/settings.json" && ! -f "$HOME/.claude/settings.json" ]]; then mkdir -p "$HOME/.claude"; cp -p "$src/claude/settings.json" "$HOME/.claude/settings.json"; echo "  Claude settings restored"; fi
fi

echo "Done. Next: bin/bootstrap.sh (guardrails, links, schedules), then bin/doctor.sh."
