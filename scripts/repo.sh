#!/usr/bin/env bash
# The product repos in repos.tsv (name, clone URL, local-only files, CLAUDE.md link, path).
# cabinet repo add <url> adds one through cabinet config; bootstrap clones it.
#
#   bin/repo.sh list [--json]
#       Every repo: its name, where it lives, whether it is there, its owner in the team table, and
#       its clone URL.
#   bin/repo.sh remove <name> [--dry-run]
#       Take a repo out of the workspace: its row in repos.tsv and in the team table of AGENTS.md.
#       Its folder, its history and local/<name>/ are left as they are.
#   bin/repo.sh snapshot
#       Copy every repo's local-only files and its .git/info/exclude entries into local/<repo>/, so
#       they can be reviewed and committed in the workspace. Reads repos; never changes them.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# The owning agent of a repo in the team table of AGENTS.md, or TBD.
owner_of() { awk -F'|' -v n="\`$1\`" '/^## / {on = ($0 ~ /^## The team/)} on && NF >= 4 {a = $2; gsub(/^ +| +$/, "", a); if (a == n) {o = $4; gsub(/^ +| +$/, "", o); print o; exit}}' "$WS/AGENTS.md" 2>/dev/null; }

p_list() {
  local json=0 a name url files link path dir
  for a in "$@"; do case "$a" in --json) json=1 ;; *) echo "usage: bin/repo.sh list [--json]" >&2; exit 2 ;; esac; done
  while IFS=$'\t' read -r name url files link path; do
    dir="$(repo_dir "$path")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$dir" "$([[ -e "$dir/.git" ]] && echo yes || echo no)" "$(owner_of "$name" || true)" "$url"
  done < <(repos) | if ((json)); then
    jq -Rn '[inputs | split("\t") | {name: .[0], path: .[1], present: (.[2] == "yes"), owner: (if .[3] == "" or .[3] == "TBD" then null else .[3] end), url: (if .[4] == "-" then null else .[4] end)}]'
  else
    awk -F'\t' 'BEGIN {n = 0} {n++; printf "%-20s %-16s %-8s %s\n", $1, ($4 == "" ? "TBD" : $4), ($3 == "yes" ? "here" : "missing"), $2} END {if (!n) print "No repos in repos.tsv. Add one: cabinet repo add <git url>"}'
  fi
}

p_remove() {
  local dry=0 name="" a
  for a in "$@"; do case "$a" in --dry-run) dry=1 ;; -*) echo "usage: bin/repo.sh remove <name> [--dry-run]" >&2; exit 2 ;; *) name="$a" ;; esac; done
  [[ -n "$name" ]] || { echo "usage: bin/repo.sh remove <name> [--dry-run]" >&2; exit 2; }
  repos | cut -f1 | grep -qxF "$name" || { echo "no repo named $name in repos.tsv (bin/repo.sh list)" >&2; exit 1; }
  if ((dry)); then echo "would remove $name from repos.tsv and the team table of AGENTS.md; its folder is left as is"; return 0; fi
  N="$name" node "$LIBJS" drop "$WS/repos.tsv" '/^${N}\t/'
  N="$name" node "$LIBJS" drop "$WS/AGENTS.md" '/^\| `${N}` \|/'
  echo "Removed $name from repos.tsv and the team table of AGENTS.md. Its folder, history and local/$name/ are left as they are."
  echo "Open handoffs addressed to it are reported by bin/doctor.sh. Commit: git -C \"$WS\" commit -am \"repos: remove $name\""
}

p_snapshot() {
# Copy a file if it exists, otherwise warn. Symlinks are skipped: bootstrap recreates them.
copy_if() {
  local src=$1 dst=$2
  if [[ -f "$src" && ! -L "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
  else
    echo "warn: missing $src"
  fi
}

while IFS=$'\t' read -r name url files link path; do
  repo="$(repo_dir "$path")"
  [[ -e "$repo/.git" ]] || { echo "skip $name: not at $repo"; continue; }
  dest="$WS/local/$name"
  if [[ "${files:--}" != "-" ]]; then
    for f in $files; do copy_if "$repo/$f" "$dest/$f"; done
  fi
  ex="$repo/.git/info/exclude"
  if [[ -f "$ex" ]] && grep -qvE '^#|^$' "$ex"; then
    mkdir -p "$dest"
    grep -vE '^#|^$' "$ex" > "$dest/git-info-exclude"
  fi
done < <(repos)

echo "Snapshot done. Review and commit: git -C \"$WS\" status"
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  list) p_list "$@" ;;
  remove) p_remove "$@" ;;
  snapshot) p_snapshot "$@" ;;
  *) echo "usage: bin/repo.sh list [--json] | remove <name> [--dry-run] | snapshot" >&2; exit 2 ;;
esac
