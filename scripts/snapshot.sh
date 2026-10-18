#!/usr/bin/env bash
# Copy every repo's local-only files (repos.tsv) and its .git/info/exclude
# entries into local/<repo>/, so they can be reviewed and committed in the
# workspace. Reads only; it never changes a product repo.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

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
