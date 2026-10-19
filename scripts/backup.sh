#!/usr/bin/env bash
# Write one encrypted archive of everything a disaster would lose: every
# repo's full git history (unpushed commits, local branches), uncommitted
# changes, untracked files, stashes, .env files, and Claude Code's memory and
# settings for this workspace.
#
#   bin/backup.sh create [dest-dir]            one archive now (default: CABINET_BACKUP_DIR in cabinet.env)
#   bin/backup.sh verify [dest-dir] [--json]   restore the newest archive into a temporary folder,
#                                              check it against the workspace and its repos, delete it
#   bin/backup.sh restore <archive> [dir]      rebuild a workspace and its repos from an archive
#                                              (below; it runs before any workspace exists)
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
usage="usage: bin/backup.sh create [dest-dir] | verify [dest-dir] [--json] | restore <archive> [dir]"

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
#   bin/backup.sh restore <archive.tar.gz.enc> [workspace-dir]
#
# Passphrase as in backup.sh. Then run bin/bootstrap.sh and bin/doctor.sh.
# Needs no cabinet.env: it may run before the workspace exists.
b_restore() {
archive="${1:-}"; [[ -n "$archive" ]] || { echo "usage: bin/backup.sh restore <archive> [workspace-dir]" >&2; exit 2; }
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
}
# Restore needs no cabinet.env: it may run on a new Mac, before the workspace exists.
if [[ "${1:-}" == restore ]]; then shift; b_restore "$@"; exit 0; fi

source "$(dirname "$0")/lib.sh"
umask 077   # archives and staging are readable by you only

verb="${1:-}"; (($#)) && shift
case "$verb" in create) verify=0 ;; verify) verify=1 ;; *) echo "$usage" >&2; exit 2 ;; esac
json=0 dest=""
for a in "$@"; do
  case "$a" in --json) ((verify)) || { echo "$usage" >&2; exit 2; }; json=1 ;; -*) echo "$usage" >&2; exit 2 ;; *) dest="$a" ;; esac
done
dest="${dest:-$CABINET_BACKUP_DIR}"
[[ -n "$dest" ]] || { echo "$usage (or set CABINET_BACKUP_DIR)" >&2; exit 2; }
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
  ((json)) || echo "Verifying $file (backed up $(human_stamp "$stamp"))"
  problems=0
  # Each result once: printed for people, or collected for --json.
  say() {  # say <name> <ok|skipped|problem> <text>
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp/results"
    ((json)) && return 0
    if [[ "$2" == problem ]]; then echo "  PROBLEM ${1:+$1: }$3"; else echo "  $1: $3"; fi
  }
  problem() { say "$1" problem "$2"; problems=$((problems + 1)); }
  : > "$tmp/results"
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass fd:3 3<<<"$pass" < "$dest/$file" 2>"$tmp/err" | tar -C "$tmp" -xzf - 2>>"$tmp/err"; then
    problem "" "the archive does not open (a wrong passphrase, or a damaged file): $(head -1 "$tmp/err")"
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
      [[ -e "$dir/.git" ]] || { say "$name" skipped "no repo at $dir, not checked"; continue; }
      [[ -d "$o" ]] || { problem "$name" "not in the archive (back up again)"; continue; }
      if [[ ! -f "$o/repo.bundle" ]]; then
        tar -tf "$o/untracked.tar" >/dev/null 2>&1 && say "$name" ok "its files restore (it had no commits)" || problem "$name" "its files do not restore"
        continue
      fi
      if ! { git clone -q --no-checkout "$o/repo.bundle" "$r" && git -C "$r" fetch -q --update-head-ok "$o/repo.bundle" '+refs/heads/*:refs/heads/*'; } 2>"$tmp/err"; then
        problem "$name" "its history does not restore: $(head -1 "$tmp/err")"; continue
      fi
      b="$(cat "$o/branch" 2>/dev/null || true)"
      if [[ -n "$b" && "$b" != - ]]; then git -C "$r" symbolic-ref HEAD "refs/heads/$b"
      else git -C "$r" fetch -q "$o/repo.bundle" HEAD 2>/dev/null && git -C "$r" update-ref --no-deref HEAD FETCH_HEAD; fi
      git -C "$r" reset -q --hard 2>/dev/null || { problem "$name" "the branch it was on ($b) is not in the archive"; continue; }
      [[ ! -s "$o/worktree.patch" ]] || git -C "$r" apply --binary "$o/worktree.patch" 2>/dev/null || { problem "$name" "its uncommitted changes do not apply"; continue; }
      [[ ! -f "$o/untracked.tar" ]] || tar -C "$r" -xf "$o/untracked.tar" 2>/dev/null || { problem "$name" "its untracked files do not restore"; continue; }
      [[ ! -f "$o/env.tar" ]] || tar -tf "$o/env.tar" >/dev/null 2>&1 || { problem "$name" "its .env files do not restore"; continue; }
      n="$(git -C "$r" rev-list --count --all)" ah="$(git -C "$r" rev-parse HEAD)" lh="$(git -C "$dir" rev-parse -q --verify HEAD || true)"
      if [[ "$ah" == "$lh" ]]; then
        d="$(differ "$dir" "$r")"
        ((d == 0)) && say "$name" ok "restores exactly as it is now ($n commits)" || say "$name" ok "restores ($n commits); $d file(s) changed since the backup"
      elif [[ -n "$lh" ]] && git -C "$dir" merge-base --is-ancestor "$ah" "$lh" 2>/dev/null; then
        say "$name" ok "restores ($n commits); $(git -C "$dir" rev-list --count "$ah..$lh") commit(s) since the backup"
      else
        say "$name" ok "restores ($n commits); its history changed since the backup (a rebase, a reset or another branch)"
      fi
    done < <(targets)
  fi
  # The doctor reads the date of the last good verify from here, never from the backup folder.
  ((problems)) || { mkdir -p -m 700 "$LOGDIR"; echo "$file" > "$LOGDIR/backup-verified"; }
  if ((json)); then
    jq -Rn --arg a "$file" --arg at "$(sed -E 's/^(....)(..)(..)-(..)(..)(..)$/\1-\2-\3T\4:\5:\6/' <<<"$stamp")" --argjson p "$problems" \
      '{archive: $a, backed_up: $at, ok: ($p == 0), problems: $p, results: [inputs | split("\t") | {repo: (if .[0] == "" then null else .[0] end), result: .[1], text: .[2]}]}' < "$tmp/results"
  elif ((problems)); then echo "Verify failed: $problems problem(s). Back up again (bin/backup.sh create), then verify that archive."
  else echo "Verified: $file restores. The temporary copy is deleted."; fi
  ((problems)) && exit 1
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
"$WS/bin/repo.sh" snapshot >/dev/null

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
