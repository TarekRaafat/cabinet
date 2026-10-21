#!/usr/bin/env bash
# Look for keys, tokens and passwords in the workspace's own files (tracked, and new files
# git does not ignore), so none is committed and copied into every backup. Prints
# file:line and the kind of secret, never the secret itself.
#
#   bin/secret.sh check [--json]   every file of the workspace
#   bin/secret.sh check --staged   only the lines staged for the next commit (the pre-commit hook)
#
# A false alarm: put not-a-secret anywhere on its line. Exit 0 when nothing is found, 1 when
# something is. Product repos are not scanned: they have their own git and their own hooks.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

usage="usage: bin/secret.sh check [--staged] [--json]"
[[ "${1:-}" == check ]] || { echo "$usage" >&2; exit 2; }
shift
staged=0 json=0
for a in "$@"; do
  case "$a" in --staged) staged=1 ;; --json) json=1 ;; *) echo "$usage" >&2; exit 2 ;; esac
done
cd "$WS"
found="$(mktemp)"; trap 'rm -f "$found"' EXIT

if ((staged)); then
  # The added lines of the staged diff (bin/lib.js secret-scan: the patterns, and how a file is read).
  git diff --cached -U0 --no-color --no-ext-diff --diff-filter=ACMR -- . | node "$LIBJS" secret-scan --staged > "$found" || true
else
  # Every file git tracks or would add: text files up to 2 MB.
  git ls-files -z -co --exclude-standard -- . | node "$LIBJS" secret-scan > "$found" || true
fi

if ((json)); then
  # file:line: kind, one finding per line; the value itself is never printed.
  sed -E 's/^(.*):([0-9]+): (.*)$/\1\t\2\t\3/' "$found" | json -R '$.map((l) => l.split("\t")).map((r) => ({file: r[0], line: Number(r[1]), kind: r[2]}))'
  [[ -s "$found" ]] && exit 1
  exit 0
fi
if [[ -s "$found" ]]; then
  echo "Possible secrets (remove each, and rotate any real key; a false alarm: add not-a-secret to its line):" >&2
  sed 's/^/  /' "$found" >&2
  ((staged)) && echo "Commit refused." >&2
  exit 1
fi
((staged)) || echo "No likely secret in the workspace's files."
