#!/usr/bin/env bash
# Write one encrypted archive of everything a disaster would lose: every
# repo's full git history (unpushed commits, local branches), uncommitted
# changes, untracked files, stashes, .env files, and Claude Code's memory and
# settings for this workspace.
#
#   bin/backup.sh create [dest-dir]            one archive now (default: CABINET_BACKUP_DIR in cabinet.env)
#   bin/backup.sh verify [dest-dir] [--json]   restore the newest archive into a temporary folder,
#                                              check it against the workspace and its repos, delete it
#   bin/backup.sh restore <archive> [dir] [--force]
#                                              rebuild a workspace and its repos from an archive
#                                              (below; it runs before any workspace exists)
#
# Passphrase: $CABINET_BACKUP_PASSPHRASE, else the item cabinet.<slug>.backup in the login
# keychain (macOS) or the secret store (Linux; bin/bootstrap.sh prints how to create it). Keep the
# same passphrase in your password manager: without it no archive opens.
# Keeps the newest CABINET_BACKUP_KEEP archives (at least 1, newest by the time in the name) of
# this workspace only, and never deletes the one it just wrote. The folder must be outside the
# workspace and every repo it lists: a backup next to what it protects is lost with it, and inside
# a repo it would copy itself into every later archive and could be committed.
# Reads repos; never changes them.
set -euo pipefail
usage="usage: bin/backup.sh create [dest-dir] | verify [dest-dir] [--json] | restore <archive> [dir] [--force]"

# Restore from an archive written by bin/backup.sh. Never loses a file:
# - a repo that already exists gets the archive's branches under refs/remotes/backup/
#   to compare and merge by hand;
# - a missing repo, or an empty folder, is restored with its uncommitted work;
# - in the workspace folder itself, or a project folder that holds nothing but the
#   workspace being restored, files are checked out in place, and any path the archive
#   would replace or delete (a file with other content, tracked or untracked, a file
#   where a folder goes, a folder where a file goes) is first moved to recovered/;
# - any other folder that already holds files is left alone, and the repo is
#   restored into recovered/<archive>/<name>/repo instead.
# Stashes are left as patches. It reads the whole archive, and moves aside (or with --force,
# after yes at a terminal, deletes) what is in the way, before it writes anything (kit rule 5:
# node lib.js delete-plan incoming). A restore stopped half way finishes when run again.
#
#   bin/backup.sh restore <archive.tar.gz.enc> [workspace-dir] [--force]
#
# Passphrase as in backup.sh. Then run bin/bootstrap.sh and bin/doctor.sh.
# Needs no cabinet.env: it may run before the workspace exists.
b_restore() {
source "$(dirname "$0")/platform.sh"   # pass_get, human_stamp, term_text
local rusage="usage: bin/backup.sh restore <archive> [workspace-dir] [--force]" a
archive="" target="" force=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;
    -*) echo "$rusage" >&2; exit 2 ;;
    *) if [[ -z "$archive" ]]; then archive=$a; elif [[ -z "$target" ]]; then target=$a; else echo "$rusage" >&2; exit 2; fi ;;
  esac
done
[[ -n "$archive" ]] || { echo "$rusage" >&2; exit 2; }
target="${target:-$(cd "$(dirname "$0")/.." && pwd)}"
slug="$(basename "$archive")"; slug="${slug%.tar.gz.enc}"; slug="${slug%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*}"
pass="${CABINET_BACKUP_PASSPHRASE:-$(pass_get "cabinet.$slug.backup" || true)}"
[[ -n "$pass" ]] || { echo "no passphrase: set CABINET_BACKUP_PASSPHRASE or add cabinet.$slug.backup to the $PASS_STORE: $(pass_add_cmd "cabinet.$slug.backup")" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass fd:3 3<<<"$pass" < "$archive" | tar -C "$tmp" -xzf -
src="$(echo "$tmp"/"$slug"-*)"
# Nothing is created before the question: a folder is named as it will be (its deepest existing
# parent resolved, the rest as given), and a missing one reads as empty.
real() {
  local p=$1 out=/ c
  local parts
  [[ "$p" == /* ]] || p="$PWD/$p"
  IFS=/ read -r -a parts <<<"$p"
  for c in "${parts[@]}"; do
    case "$c" in
      "" | .) ;;
      ..) if [[ -d "$out" ]]; then out="$(cd "$out/.." && pwd -P)"; else out="${out%/*}"; out="${out:-/}"; fi ;;
      *) if [[ -d "${out%/}/$c" ]]; then out="$(cd "${out%/}/$c" && pwd -P)"; else out="${out%/}/$c"; fi ;;
    esac
  done
  printf '%s\n' "$out"
}
target="$(real "$target")"
kept="$target/recovered/$(basename "$src")"
stamp="${src##*/}"; stamp="${stamp#"$slug"-}"
echo "Restoring $slug from the backup of $(human_stamp "$stamp") into $target"

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

# Point HEAD at the archived branch, or at the archived commit when the repo was detached.
set_head() {  # set_head <repo> <bundle> <branch-ref or empty>
  if [[ -n "$3" ]]; then git -C "$1" symbolic-ref HEAD "$3"
  else git -C "$1" fetch -q "$2" HEAD && git -C "$1" update-ref --no-deref HEAD FETCH_HEAD; fi
}

# Every member name of a tar the archive holds, checked on the names before anything relies on tar's
# own handling (GNU tar and bsdtar differ): absolute, or with a .. part, and nothing is restored.
check_tar() {  # check_tar <tar> <what it is>
  local n m
  [[ -f "$1" ]] || return 0
  while IFS= read -r n; do
    m="$n"; while [[ "$m" == ./* ]]; do m="${m#./}"; done
    if [[ "$m" == /* || "/$m/" == */../* ]]; then
      echo "the archive's $2 holds a path outside its folder, so nothing was restored: $(printf '%s\n' "$n" | term_text)" >&2; exit 1
    fi
  done < <(tar -tf "$1")
}

# In the temporary folder only: a repo's archived commit (base) and that commit with the archive's
# uncommitted patch applied (tree), compared with what is in the folder; tree is empty when the patch
# does not apply.
prep() {  # prep <archived repo> <bare repo here>
  local o=$1 g=$2 head
  base="" tree=""
  [[ -f "$o/repo.bundle" ]] || return 0
  git init -q --bare "$g" && git -C "$g" fetch -q "$o/repo.bundle" '+refs/heads/*:refs/heads/*' 2>/dev/null || return 0
  head="$(branch_of "$o")"
  if [[ -n "$head" ]]; then base="$(git -C "$g" rev-parse -q --verify "$head^{commit}" || true)"
  else base="$(git -C "$g" fetch -q "$o/repo.bundle" HEAD && git -C "$g" rev-parse FETCH_HEAD || true)"; fi
  [[ -n "$base" ]] || return 0
  GIT_INDEX_FILE="$g/restore-index" git -C "$g" read-tree "$base"
  if [[ ! -s "$o/worktree.patch" ]] || GIT_INDEX_FILE="$g/restore-index" git -C "$g" apply --cached --binary "$o/worktree.patch" 2>/dev/null; then
    tree="$(GIT_INDEX_FILE="$g/restore-index" git -C "$g" write-tree)"
  fi
}

# Sessions (bin/session.sh) the archive holds for a repo. Restored as worktrees at sessions/<repo>/<name>/ on
# their branch, with their changes, into a repo restored fresh where that folder is missing; else their
# patch and files go to recovered/, and nothing that exists is changed.
restore_sessions() {  # restore_sessions <name> <archived repo> <the repo when restored fresh, else empty> <keep folder>
  local name=$1 o=$2 repo=$3 keep=$4 so s sb w
  for so in "$o"/sessions/*/; do
    [[ -d "$so" ]] || continue
    s="$(basename "$so")" sb="$(cat "$so/branch" 2>/dev/null || true)" w="$target/sessions/$name/$(basename "$so")"
    if [[ -n "$repo" && "$repo" != "$keep"/* && "$s" =~ ^[a-z0-9][a-z0-9-]{0,39}$ && "$sb" == "session/$s" && ! -e "$w" ]] \
      && mkdir -p "$target/sessions/$name" && { [[ -e "$target/sessions/.gitignore" ]] || printf '*\n' > "$target/sessions/.gitignore"; } \
      && git -C "$repo" worktree add -q "$w" "$sb" 2>/dev/null; then
      { [[ ! -s "$so/worktree.patch" ]] || git -C "$w" apply --binary "$so/worktree.patch"; } && { [[ ! -f "$so/untracked.tar" ]] || tar -C "$w" -xf "$so/untracked.tar"; } \
        && echo "    session $s restored at $w, on $sb" || echo "    session $s: restored at $w on $sb, but its uncommitted changes did not apply (they are in the archive's repos/$name/sessions/$s/)"
    else
      mkdir -p "$keep/sessions/$s"; cp -p "$so"/* "$keep/sessions/$s/" 2>/dev/null || true
      echo "    session $s: its uncommitted changes and untracked files are in $keep/sessions/$s"
    fi
  done
}

# The writes for one repo, after the one delete-plan call has moved aside what was in their way.
restore_one() {  # restore_one <name> <archived repo> <folder> <in place: 0 or 1> <keep folder>
  local name=$1 o=$2 repo=$3 inplace=$4 keep=$5 head f
  if [[ ! -f "$o/repo.bundle" ]]; then
    # A repo with no commits yet was archived as its files only.
    if [[ -f "$o/untracked.tar" ]]; then mkdir -p "$repo"; tar -C "$repo" -xf "$o/untracked.tar"; echo "  $name: files restored (it had no commits)"; fi
    return 0
  fi
  if [[ -e "$repo/.git" && ! -e "$repo/.git/cabinet-restore" ]]; then
    git -C "$repo" fetch -q "$o/repo.bundle" '+refs/heads/*:refs/remotes/backup/*'
    echo "  $name exists: archive branches fetched to refs/remotes/backup/*; compare and merge by hand"
    mkdir -p "$keep"; cp -p "$o"/*.patch "$o"/untracked.tar "$keep/" 2>/dev/null || true
    restore_sessions "$name" "$o" "" "$keep"
    return 0
  fi
  head="$(branch_of "$o")"
  if [[ -n "$(ls -A "$repo" 2>/dev/null)" ]]; then
    if ((inplace == 0)); then
      # A folder that holds files of its own is never turned into a repo.
      echo "  $name: $repo already holds files and is not a repo, so it is left alone; restored into $keep/repo instead"
      repo="$keep/repo"; mkdir -p "$(dirname "$repo")"
      git clone -q --no-checkout "$o/repo.bundle" "$repo"
      git -C "$repo" fetch -q --update-head-ok "$o/repo.bundle" '+refs/heads/*:refs/heads/*'
      set_head "$repo" "$o/repo.bundle" "$head"; git -C "$repo" reset -q --hard
    else
      # Check out in place: what was in the way is already moved aside. The marker makes a run stopped
      # from here on take this branch again, and finish.
      git -C "$repo" init -q
      : > "$repo/.git/cabinet-restore"
      git -C "$repo" fetch -q --update-head-ok "$o/repo.bundle" '+refs/heads/*:refs/heads/*'
      set_head "$repo" "$o/repo.bundle" "$head"
      git -C "$repo" read-tree HEAD
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
  [[ -f "$o/untracked.tar" ]] && tar -C "$repo" -xf "$o/untracked.tar"
  rm -f "$repo/.git/cabinet-restore"
  echo "  $name: restored with its uncommitted work"
  if ls "$o"/stash-*.patch >/dev/null 2>&1; then mkdir -p "$keep"; cp -p "$o"/stash-*.patch "$keep/"; echo "    stashes kept as patches in $keep"; fi
  restore_sessions "$name" "$o" "$repo" "$keep"
  if [[ -f "$o/env.tar" ]]; then
    while IFS= read -r f; do
      if [[ -e "$repo/$f" ]]; then echo "    ${f#./} exists, left as is"; else tar -C "$repo" -xf "$o/env.tar" "$f"; echo "    restored ${f#./}"; fi
    done < <(tar -tf "$o/env.tar")
  fi
}

# 1. Read everything, in the temporary folder only: each repo's folder (from the archived repos.tsv,
# never the target's, which is the one about to be replaced), its in-place choice on that folder as
# it is now, its keep folder, and what it would write over.
names=() outs=() dirs=() inplaces=() keeps=() plan=()
i=0
for o in "$src/workspace" "$src"/repos/*/; do
  o="${o%/}"; [[ -d "$o" ]] || continue
  if [[ "$o" == "$src/workspace" ]]; then name=workspace repo="$target" inplace=1
  else
    name="$(basename "$o")"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$name" != . && "$name" != .. ]] || { echo "  skipped an archived repo with an unusable name"; continue; }
    # Where the archived repos.tsv says the repo lives; default <workspace>/<name>.
    p="$(awk -F'\t' -v n="$name" '{ sub(/\r$/, "") } !/^#/ && $1 == n {print $5}' "$tmp/repos.tsv" 2>/dev/null)"; p="${p:-$name}"
    case "$p" in /*) repo="$p" ;; "~/"*) repo="$HOME/${p#"~/"}" ;; *) repo="$target/$p" ;; esac
    repo="$(real "$repo")"
    # In place only when the folder holds nothing but the workspace just restored (the project around
    # cabinet/), or a restore of it stopped half way.
    inplace=0
    others="$(ls -A "$repo" 2>/dev/null | { [[ "$target" == "$repo"/* ]] && grep -vxF "$(basename "$target")" || cat; } || true)"
    [[ -z "$others" || -e "$repo/.git/cabinet-restore" ]] && inplace=1
  fi
  check_tar "$o/untracked.tar" "untracked files of $name"
  check_tar "$o/env.tar" ".env files of $name"
  for so in "$o"/sessions/*/; do [[ ! -d "$so" ]] || check_tar "$so/untracked.tar" "untracked files of a session of $name"; done
  prep "$o" "$tmp/g/$i"
  if [[ "$name" == workspace && "$o" == "$src/workspace" ]]; then
    : > "$tmp/repos.tsv"
    [[ -z "$base" ]] || git -C "$tmp/g/$i" show "${tree:-$base}:repos.tsv" > "$tmp/repos.tsv" 2>/dev/null || true
    [[ -s "$tmp/repos.tsv" || ! -f "$o/untracked.tar" ]] || tar -xOf "$o/untracked.tar" repos.tsv > "$tmp/repos.tsv" 2>/dev/null || true
  fi
  # One keep folder per repo per run, never one that exists, so a second run never writes over the first's.
  keep="$kept/$name" n=2
  while [[ -e "$keep" || -L "$keep" ]]; do keep="$kept/$name-$n"; n=$((n + 1)); done
  # A folder restore writes over: a no-commit repo's (its files extracted whatever it holds), or one
  # checked out in place. Every other case writes into a new or empty folder, or into recovered/.
  if [[ -d "$repo" && -n "$(ls -A "$repo" 2>/dev/null)" ]]; then
    x="$tmp/x/$i"
    if [[ -f "$o/untracked.tar" ]]; then mkdir -p "$x"; tar -C "$x" -xf "$o/untracked.tar"; fi
    if [[ ! -f "$o/repo.bundle" ]]; then
      [[ ! -d "$x" ]] || plan+=(incoming "$repo" --from "$x" --keep "$keep")
    elif ((inplace)) && [[ ! -e "$repo/.git" || -e "$repo/.git/cabinet-restore" ]]; then
      [[ -n "$tree" ]] || { echo "the archive's uncommitted changes of $name do not apply to its commit, so nothing was restored" >&2; exit 1; }
      plan+=(incoming "$repo" --git "$tmp/g/$i" "$base" "$tree")
      [[ ! -d "$x" ]] || plan+=(--from "$x")
      plan+=(--keep "$keep")
    fi
  fi
  names+=("$name") outs+=("$o") dirs+=("$repo") inplaces+=("$inplace") keeps+=("$keep")
  i=$((i + 1))
done

# 2. One call for the whole restore: it lists every path in the way, asks the one --force question
# when given, and only then moves each aside (or deletes it). A refusal or a no changes nothing.
if ((${#plan[@]})); then
  ((force)) && plan+=(--force)
  node "$(dirname "$0")/lib.js" delete-plan "${plan[@]}" || exit 1
fi

# 3. Then the writes, repo by repo.
mkdir -p "$target"
for ((i = 0; i < ${#names[@]}; i++)); do
  repo="${dirs[i]}" inplace="${inplaces[i]}"
  if [[ "${names[i]}" != workspace || "${outs[i]}" != "$src/workspace" ]]; then
    # Made in place again now: the project around the workspace holds the workspace just restored.
    inplace=0
    others="$(ls -A "$repo" 2>/dev/null | { [[ "$target" == "$repo"/* ]] && grep -vxF "$(basename "$target")" || cat; } || true)"
    [[ -z "$others" || -e "$repo/.git/cabinet-restore" ]] && inplace=1
    mkdir -p "$repo"
  fi
  restore_one "${names[i]}" "${outs[i]}" "$repo" "$inplace" "${keeps[i]}"
done
# Claude Code memory and settings, only where missing.
if [[ -d "$src/claude" ]]; then
  cslug="$(node "$(dirname "$0")/lib.js" slug "$(cd "$target" && pwd)")"
  mem="$HOME/.claude/projects/$cslug/memory"
  if [[ -d "$src/claude/memory" && ! -d "$mem" ]]; then mkdir -p "$(dirname "$mem")"; cp -Rp "$src/claude/memory" "$mem"; echo "  Claude memory restored"; fi
  if [[ -f "$src/claude/settings.json" && ! -f "$HOME/.claude/settings.json" ]]; then mkdir -p "$HOME/.claude"; cp -p "$src/claude/settings.json" "$HOME/.claude/settings.json"; echo "  Claude settings restored"; fi
fi

echo "Done. Next: bin/bootstrap.sh (guardrails, links, schedules), then bin/doctor.sh."
}
# Restore needs no cabinet.env: it may run on a new machine, before the workspace exists.
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
pass="${CABINET_BACKUP_PASSPHRASE:-$(pass_get "$KEYCHAIN_ITEM" || true)}"
[[ -n "$pass" ]] || { echo "no passphrase: set CABINET_BACKUP_PASSPHRASE or add $KEYCHAIN_ITEM to the $PASS_STORE: $(pass_add_cmd "$KEYCHAIN_ITEM")" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# This workspace's archives only: <slug>-YYYYMMDD-HHMMSS.tar.gz.enc exactly, so app never takes app-web's.
# Newest first by the time in the name, never by modified time, which a synced drive or a copy changes.
mine() { ls -1 "$dest" 2>/dev/null | grep -E "^${CABINET_SLUG//./\\.}-[0-9]{8}-[0-9]{6}\.tar\.gz\.enc$" | LC_ALL=C sort -r || true; }
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
      # Each session it holds: its worktree on its branch, with its uncommitted changes and untracked files.
      for so in "$o"/sessions/*/; do
        [[ -d "$so" ]] || continue
        s="$(basename "$so")" sb="$(cat "$so/branch" 2>/dev/null || true)" sw="$tmp/check-sessions/$sub/$(basename "$so")"
        if [[ "$s" =~ ^[a-z0-9][a-z0-9-]{0,39}$ && "$sb" == "session/$s" ]] && git -C "$r" worktree add -q "$sw" "$sb" 2>/dev/null \
          && { [[ ! -s "$so/worktree.patch" ]] || git -C "$sw" apply --binary "$so/worktree.patch" 2>/dev/null; } \
          && { [[ ! -f "$so/untracked.tar" ]] || tar -C "$sw" -xf "$so/untracked.tar" 2>/dev/null; }; then
          say "$name session $s" ok "restores on $sb with its uncommitted changes"
        else problem "$name session $s" "its uncommitted changes do not restore"; fi
      done
    done < <(targets)
  fi
  # The doctor reads the date of the last good verify from here, never from the backup folder.
  ((problems)) || { mkdir -p -m 700 "$LOGDIR"; echo "$file" > "$LOGDIR/backup-verified"; }
  if ((json)); then
    json -R --arg a "$file" --arg at "$(sed -E 's/^(....)(..)(..)-(..)(..)(..)$/\1-\2-\3T\4:\5:\6/' <<<"$stamp")" --argjson p "$problems" \
      '({archive: $a, backed_up: $at, ok: $p == 0, problems: $p, results: $.map((l) => l.split("\t")).map((r) => ({repo: str(r[0]), result: r[1], text: r[2]}))})' "$tmp/results"
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

# Each session of a repo (bin/session.sh): its uncommitted changes and untracked files, as the main
# folder's, in repos/<name>/sessions/<session>/. Its commits are in the repo's bundle, on session/<session>.
save_sessions() {
  local name=$1 repo=$2 o="$out/$3/sessions" s f b
  while IFS=$'\t' read -r s f b; do
    if [[ ! -d "$f" ]]; then echo "  $name: the folder of session $s is gone ($f), so it is not in the backup (git -C $(printf '%q' "$repo") worktree prune)"; continue; fi
    mkdir -p "$o/$s"
    printf '%s\n' "$b" > "$o/$s/branch"
    git -C "$f" diff HEAD --binary > "$o/$s/worktree.patch"
    git -C "$f" ls-files --others --exclude-standard -z | (cd "$f" && tar --null -T - -cf "$o/$s/untracked.tar" 2>/dev/null) || true
    echo "  $name: session $s"
  done < <(sessions_of "$name" "$(abspath "$repo")")
}

echo "== Repos"
while IFS=$'\t' read -r name dir sub; do
  save_repo "$name" "$dir" "$sub"
  [[ "$sub" != repos/* || ! -e "$dir/.git" ]] || save_sessions "$name" "$dir" "$sub"
done < <(targets)

echo "== Claude Code"
mem="$HOME/.claude/projects/$CLAUDE_SLUG/memory"
[[ -d "$mem" ]] && mkdir -p "$out/claude" && cp -Rp "$mem" "$out/claude/memory" && echo "  memory"
[[ -f "$HOME/.claude/settings.json" ]] && mkdir -p "$out/claude" && cp -p "$HOME/.claude/settings.json" "$out/claude/settings.json" && echo "  settings"

file="$dest/$CABINET_SLUG-$stamp.tar.gz.enc"
tar -C "$tmp" -czf - "$CABINET_SLUG-$stamp" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass fd:3 3<<<"$pass" > "$file.part"
mv "$file.part" "$file"
echo "== Wrote $file ($(du -h "$file" | cut -f1))"

# Only this workspace's archives are removed, never another's in the same folder, and never the one
# just written (an archive named later, from a clock ahead, can outrank it).
mine | tail -n +$((CABINET_BACKUP_KEEP + 1)) | while IFS= read -r old; do [[ "$dest/$old" == "$file" ]] || rm -f "$dest/$old"; done
