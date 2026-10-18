#!/usr/bin/env bash
# No argument: list every open or acknowledged HANDOFFS.md entry: age in
# days, ID, addressee, title. Oldest first.
# With a repo or role name (api, qa, owner, ...): print in full every
# entry addressed to it that is not done or rejected. This is the
# start-of-session read (CABINET.md). Read-only.
# --json: the same entries as a JSON array (id, status, date, age_days, from, to,
# title; with a name, also each entry's full text).
set -euo pipefail

source "$(dirname "$0")/lib.sh"

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
