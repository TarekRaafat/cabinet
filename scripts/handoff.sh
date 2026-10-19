#!/usr/bin/env bash
# File one handoff: append the entry to "## Open" in HANDOFFS.md with the next free ID
# for today (unique across HANDOFFS.md and handoffs/archive-*.md), today's date and the
# template's lines, then commit it on its own. Prints the new ID first.
#
#   bin/handoff.sh --from <repo or role> --to <repo, role or owner> --changed "..." --needed "..." [--depends-on "..."] "<title>"
#
# When HANDOFFS.md already has someone else's uncommitted lines, the entry is written but
# not committed, so their lines are never committed under this entry (CABINET.md, "Handoffs").
set -euo pipefail

source "$(dirname "$0")/lib.sh"

usage="usage: bin/handoff.sh --from <name> --to <name> --changed \"...\" --needed \"...\" [--depends-on \"...\"] \"<title>\""
from="" to="" changed="" needed="" depends="none" title=""
while (($#)); do
  case "$1" in
    --from|--to|--changed|--needed|--depends-on)
      (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }
      case "$1" in
        --from) from="$2" ;;
        --to) to="$2" ;;
        --changed) changed="$2" ;;
        --needed) needed="$2" ;;
        --depends-on) depends="$2" ;;
      esac
      shift 2 ;;
    -*) echo "unknown option $1. $usage" >&2; exit 2 ;;
    *) [[ -z "$title" ]] || { echo "one title only (quote it). $usage" >&2; exit 2; }; title="$1"; shift ;;
  esac
done
# One line each: a line break would end the entry's field, or start a heading.
one() { printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }
from="$(one "$from")" to="$(one "$to")" changed="$(one "$changed")" needed="$(one "$needed")" depends="$(one "$depends")" title="$(one "$title")"
missing=""
for v in from to changed needed title; do [[ -n "${!v}" ]] || missing="$missing ${v/title/a title}"; done
[[ -z "$missing" ]] || { echo "missing:$missing. $usage" >&2; exit 2; }

cd "$WS"
grep -q '^## Open$' HANDOFFS.md || { echo "no '## Open' heading in HANDOFFS.md" >&2; exit 1; }
# One writer at a time, or two agents filing at once could take the same number.
lock="$K/handoff.lock"
for _ in 1 2 3 4 5 6 7 8 9 10; do mkdir "$lock" 2>/dev/null && break; sleep 1; done
[[ -d "$lock" ]] || { echo "another handoff is being filed ($lock); try again, or remove the folder if none is" >&2; exit 1; }
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

day="$(date +%Y%m%d)"
files=(HANDOFFS.md); for f in handoffs/archive-*.md; do [[ -f "$f" ]] && files+=("$f"); done
last="$(grep -ho "^### H-$day-[0-9]*" "${files[@]}" | sed 's/.*-0*//' | sort -n | tail -1 || true)"
id="$(printf 'H-%s-%02d' "$day" $((${last:-0} + 1)))"
dirty=""; [[ -z "$(git status --porcelain -- HANDOFFS.md)" ]] || dirty=1

# Newest at the bottom of "## Open": before the next "## " heading, or at the end.
entry="### $id: $title
- From: $from -> To: $to
- Status: open ($(date +%F))
- Changed: $changed
- Needed: $needed
- Depends on: $depends"
ENTRY="$entry" awk '
  function put() { if (!done) { sub(/\n+$/, "", buf); printf "%s\n\n%s\n", buf, ENVIRON["ENTRY"]; buf = ""; done = 1 } }
  /^## / && open && !done { put(); print ""; open = 0 }
  /^## Open$/ { open = 1 }
  open && !done { buf = buf $0 "\n"; next }
  { print }
  END { if (open) put() }
' HANDOFFS.md > "$K/handoffs.new"
mv "$K/handoffs.new" HANDOFFS.md

if [[ -n "$dirty" ]]; then
  echo "$id filed for $to, not committed: HANDOFFS.md had other uncommitted lines. Commit only yours (git add -p HANDOFFS.md)."
  exit 0
fi
git commit -q -m "handoffs: $id $title" -- HANDOFFS.md || { echo "$id filed for $to, but the commit failed (see above): commit HANDOFFS.md yourself" >&2; exit 1; }
echo "$id filed for $to and committed"
