#!/usr/bin/env bash
# HANDOFFS.md, the one channel between agents (CABINET.md, "Handoffs").
#
#   bin/handoff.sh add --from <name> --to <name> --changed "..." --needed "..." [--depends-on "..."] [--evidence <file or URL>]... "<title>"
#       Append one entry to "## Open" with the next free ID for today (unique across HANDOFFS.md and
#       handoffs/archive-*.md), today's date and the template's lines, then commit it on its own.
#       Each --evidence file is copied to specs/evidence/<ID>/ and linked on the entry's Evidence line,
#       from the workspace root, so it opens from HANDOFFS.md and BRIEF.md; a URL is linked as it is.
#       Prints the new ID first. With someone else's uncommitted lines in HANDOFFS.md, the entry is
#       written but not committed, so their lines never go into its commit.
#   bin/handoff.sh list [name] [--json]
#       No name: every open or acknowledged entry: age in days, ID, addressee, title, oldest first.
#       A repo or role name (api, qa, owner, ...): every entry addressed to it that is not done or
#       rejected, in full; the start-of-session read. --json: the same as JSON (id, status, date,
#       age_days, from, to, title; with a name, each entry's full text too).
#   bin/handoff.sh archive
#       Move every committed closed entry (done or rejected) to handoffs/archive-YYYY-MM.md (month of
#       its ID) and commit the move; chief-of-staff runs it daily. Refuses while HANDOFFS.md has
#       uncommitted lines, so no agent's unsaved update is lost.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

h_add() {
usage="usage: bin/handoff.sh add --from <name> --to <name> --changed \"...\" --needed \"...\" [--depends-on \"...\"] [--evidence <file or URL>]... \"<title>\""
from="" to="" changed="" needed="" depends="none" title=""
local -a ev
ev=()
while (($#)); do
  case "$1" in
    --evidence)
      (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }
      # Read now: a file's path is from the caller's folder, and the script moves to the workspace.
      if [[ "$2" =~ ^https?://[^[:space:]\<\>]+$ ]]; then ev+=("$2")
      elif [[ -f "$2" ]]; then ev+=("$(cd "$(dirname "$2")" && pwd)/$(basename "$2")")
      else echo "--evidence $2: no such file, and not an http(s) link. $usage" >&2; exit 2; fi
      shift 2 ;;
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

# Evidence: files copied under this ID with names safe in a Markdown link, then one line of links.
evline="" n=0
for e in ${ev[@]+"${ev[@]}"}; do
  if [[ "$e" == http* ]]; then link="<$e>"
  else
    n=$((n + 1)) dir="specs/evidence/$id"
    name="$(basename "$e")"; name="$(printf %s "$name" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.-]*//')"
    [[ ! -e "$dir/$name" ]] || name="$n-$name"
    mkdir -p "$dir" && cp "$e" "$dir/$name" || { echo "could not copy $e to $dir" >&2; exit 1; }
    link="[$name]($dir/$name)"
  fi
  evline="${evline:+$evline, }$link"
done

# Newest at the bottom of "## Open": before the next "## " heading, or at the end.
entry="### $id: $title
- From: $from -> To: $to
- Status: open ($(date +%F))
- Changed: $changed
- Needed: $needed
- Depends on: $depends${evline:+
- Evidence: $evline}"
ENTRY="$entry" awk '
  function put() { if (!done) { sub(/\n+$/, "", buf); printf "%s\n\n%s\n", buf, ENVIRON["ENTRY"]; buf = ""; done = 1 } }
  /^## / && open && !done { put(); print ""; open = 0 }
  /^## Open$/ { open = 1 }
  open && !done { buf = buf $0 "\n"; next }
  { print }
  END { if (open) put() }
' HANDOFFS.md > "$K/handoffs.new"
mv "$K/handoffs.new" HANDOFFS.md

paths=(HANDOFFS.md); ((n)) && paths+=("specs/evidence/$id")
if [[ -n "$dirty" ]]; then
  echo "$id filed for $to, not committed: HANDOFFS.md had other uncommitted lines. Commit only yours (git add -p HANDOFFS.md$( ((n)) && echo ", and specs/evidence/$id"))."
  exit 0
fi
((n)) && git add -- "specs/evidence/$id"
git commit -q -m "handoffs: $id $title" -- "${paths[@]}" || { echo "$id filed for $to, but the commit failed (see above): commit HANDOFFS.md yourself" >&2; exit 1; }
echo "$id filed for $to and committed"
}

h_list() {
# --json (anywhere in the arguments): the same entries as JSON, for agents and scripts.
json=0; args=()
for a in "$@"; do [[ "$a" == --json ]] && json=1 || args+=("$a"); done
set -- ${args[@]+"${args[@]}"}

# Epoch seconds for a YYYY-MM-DD date: GNU date, then BSD/macOS.
epoch() { date -d "$1" +%s 2>/dev/null || date -j -f %Y-%m-%d "$1" +%s; }
today=$(epoch "$(date +%F)")

if ((json)); then
  # One record per entry under "## Open" (and a legacy "## Archive"); jq picks the same
  # entries as the text output: open and acknowledged, or with a name, all not closed.
  who="${1:-}"; [[ "$who" == founder || "$who" == owner ]] && who="founder|owner"
  awk '
  function flush() { if (id != "") printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, st, from, to, title, sec, body; id=""; body="" }
  /^## / { flush(); on = ($0 ~ /^## (Open|Archive)/); sec = ($0 ~ /^## Open/) ? "open" : "archive"; next }
  !on { next }
  /^### H-/ { flush(); id=$2; sub(/:$/, "", id); title=$0; sub(/^### [^:]+: /, "", title); st=""; from=""; to="" }
  /^- From:/ && from == "" { from=$0; sub(/^- From: /, "", from); sub(/ -> To: .*/, "", from); to=$0; sub(/.*-> To: /, "", to) }
  /^- Status:/ && st == "" { st=$0; sub(/^- Status: /, "", st) }
  id != "" { gsub(/\t/, " "); body = body $0 "\001" }
  END { flush() }
  ' "$WS/HANDOFFS.md" | jq -Rn --arg who "$who" --argjson today "$today" '
    [inputs | split("\t") | {id: .[0], status_line: .[1], from: .[2], to: .[3], title: .[4], section: .[5], text: (.[6] | gsub("\u0001"; "\n"))}
     | .status = (.status_line | capture("^(?<s>[a-z]+)").s // "")
     | .date = (.status_line | capture("(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})").d // null)
     | .age_days = (if .date then (($today - (.date | strptime("%Y-%m-%d") | mktime) + 43200) / 86400 | floor) else null end)
     | select(if $who == "" then .section == "open" and (.status == "open" or .status == "acknowledged")
              else (.to | test("(^|[^a-z-])(" + $who + ")([^a-z-]|$)")) and (.status | test("^(done|rejected)") | not) end)
     | del(.section)]
    | if $who == "" then sort_by(.date // "9999-99-99") | map(del(.text)) else . end'
  exit 0
fi

if [[ $# -gt 0 ]]; then
  # "owner" and "founder" name the same person.
  who="$1"; [[ "$who" == founder || "$who" == owner ]] && who="founder|owner"
  awk -v who="$who" '
  function flush() { if (e != "" && to ~ ("(^|[^a-z-])(" who ")([^a-z-]|$)") && st !~ /^(done|rejected)/) printf "%s\n", e; e=""; to=""; st="" }
  /^## / && $0 !~ /^## Open/ { flush(); on=0; if ($0 ~ /^## Archive/) on=1; next }
  /^## Open/ { flush(); on=1; next }
  !on { next }
  /^### H-/ { flush() }
  /^- From:/ && to == "" { to=$0; sub(/.*-> To: /, "", to) }
  /^- Status:/ && st == "" { st=$0; sub(/^- Status: /, "", st) }
  e != "" || /^### H-/ { e = e $0 "\n" }
  END { flush() }
  ' "$WS/HANDOFFS.md"
  exit 0
fi

awk '
# Entries live under "## Open"; the template above it is not one.
/^## / { on = ($0 ~ /^## Open/); next }
!on { next }
/^### H-/ { id=$2; sub(/:$/, "", id); title=$0; sub(/^### [^:]+: /, "", title); to=""; next }
/^- From:/ { to=$0; sub(/.*-> To: /, "", to); next }
/^- Status: (open|acknowledged)/ && id {
  # An entry without an ISO date still shows, with its age unknown ("?"), after the dated ones.
  d = match($0, /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) ? substr($0, RSTART, RLENGTH) : "9999-99-99"
  st=$3; sub(/[^a-z].*/, "", st); print d "\t" st "\t" id "\t" to "\t" title; id=""
}
' "$WS/HANDOFFS.md" | sort | while IFS=$'\t' read -r d st id to title; do
  if [[ "$d" == 9999-99-99 ]]; then age="?"
  else age=$(( (today - $(epoch "$d") + 43200) / 86400 )); fi  # rounded, so a DST day still counts as one
  printf '%3sd  %-12s  %-14s  %-24s  %s\n' "$age" "$st" "$id" "$to" "$title"
done | { out="$(cat)"; [[ -n "$out" ]] && printf '%s\n' "$out" || echo "No open handoffs."; }
}

h_archive() {
cd "$WS"
if [[ -n "$(git status --porcelain -- HANDOFFS.md)" ]]; then
  echo "HANDOFFS.md has uncommitted lines; commit them first (handoffs: commit pending lines from <agents>)." >&2
  exit 1
fi

n="$(python3 -I - "$WS" <<'EOF'
import os, re, sys
ws = sys.argv[1]
path = os.path.join(ws, "HANDOFFS.md")
text = open(path, encoding="utf-8").read()
head, sep, body = text.partition("\n## Open\n")
if not sep:
    sys.exit("no '## Open' heading in HANDOFFS.md")
# Entries start at '### H-'; the old '## Archive' heading is dropped and its entries sorted like the rest.
body = body.replace("\n## Archive\n", "\n")
parts = re.split(r"\n(?=### H-)", body)
preamble, entries = parts[0], parts[1:]
keep, moved = [], {}
for e in entries:
    e = e.strip("\n")
    st = re.search(r"^- Status: (\S+)", e, re.M)
    m = re.match(r"### H-(\d{4})(\d{2})", e)
    if st and m and re.match(r"(done|rejected)\b", st.group(1)):
        moved.setdefault(f"{m.group(1)}-{m.group(2)}", []).append(e)
    else:
        keep.append(e)
os.makedirs(os.path.join(ws, "handoffs"), exist_ok=True)
for month, es in sorted(moved.items()):
    p = os.path.join(ws, "handoffs", f"archive-{month}.md")
    new = not os.path.exists(p)
    with open(p, "a", encoding="utf-8") as f:
        if new:
            f.write(f"# Closed handoffs, IDs from {month}\n\nMoved from HANDOFFS.md by bin/handoff.sh archive. Read only.\n")
        for e in es:  # links from the workspace root, now read from handoffs/
            f.write("\n" + e.replace("](specs/", "](../specs/") + "\n")
if moved:  # untouched otherwise, or the next run refuses on its own rewrite
    out = head + sep + preamble.rstrip("\n") + "\n\n" + "\n\n".join(keep) + "\n"
    open(path, "w", encoding="utf-8").write(out)
print(sum(map(len, moved.values())))
EOF
)"

if [[ "$n" == 0 ]]; then echo "nothing to archive"; exit 0; fi
git add -- HANDOFFS.md handoffs
git commit -q -m "handoffs: archive $n closed entries (bin/handoff.sh archive)" -- HANDOFFS.md handoffs
echo "archived $n closed entries"
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  add) h_add "$@" ;;
  list) h_list "$@" ;;
  archive) h_archive "$@" ;;
  *) echo "usage: bin/handoff.sh add|list|archive (see the top of this file)" >&2; exit 2 ;;
esac
