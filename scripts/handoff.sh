#!/usr/bin/env bash
# HANDOFFS.md, the one channel between agents (CABINET.md, "Handoffs").
#
#   bin/handoff.sh add --from <name> --to <name> --changed "..." --needed "..." [--depends-on "..."] [--spec <file> | --small] [--evidence <file or URL>]... "<title>"
#       Append one entry to "## Open" with the next free ID for today (unique across HANDOFFS.md and
#       handoffs/archive-*.md), today's date and the template's lines, then commit it on its own.
#       Each --evidence file is copied to specs/evidence/<ID>/ and linked on the entry's Evidence line,
#       from the workspace root, so it opens from HANDOFFS.md and BRIEF.md; a URL is linked as it is.
#       --spec names the spec it builds, on a "- Spec:" line, and refuses unless bin/spec.sh check
#       finds the spec ready or building with nothing missing (.cabinet/rules/ready-to-build.md). --small
#       marks it a small task ("- Size: small"). Work for a repo, or for a role that builds one, needs
#       one of the two.
#       Prints the new ID first. With someone else's uncommitted lines in HANDOFFS.md, the entry is
#       written but not committed, so their lines never go into its commit.
#   bin/handoff.sh attach <ID> <file or URL>... --from <name>
#       The entry's sender adds evidence later (after a BLOCK, a fix, a missed screen): files copied
#       to specs/evidence/<ID>/ and every link added to the entry's Evidence line, then committed.
#   bin/handoff.sh record <ID> --role <role> <PASS|BLOCK|CHANGES> --commits <hash,...>|none --note <file>
#       A reviewer's verdict: writes (or replaces) its "- Verdict:" line with today's date, then
#       commits. The note must be committed under specs/. Refuses a verdict by the entry's own
#       sender, a qa PASS on an entry with no evidence, and a PASS on a small task whose commits
#       span repos or change a path AGENTS.md guards (small_problems in lib.sh). --commits none is for
#       work that changes no repo (copy, research, a campaign), so not for work addressed to a builder.
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

lc() { printf %s "$1" | tr '[:upper:]' '[:lower:]'; }
# ev_arg <value>: a link as it is, or a file as an absolute path. Read before the script moves to
# the workspace: a path is from the caller's folder, else from the workspace.
ev_arg() {
  if [[ "$1" =~ ^https?://[^[:space:]\<\>]+$ ]]; then printf '%s\n' "$1"
  elif [[ -f "$1" ]]; then printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
  elif [[ "$1" != /* && -f "$WS/$1" ]]; then printf '%s/%s\n' "$(cd "$(dirname "$WS/$1")" && pwd -P)" "$(basename "$1")"
  else echo "evidence $1: no such file, and not an http(s) link. $usage" >&2; exit 2; fi
}
# ev_link <ID> <link or file>: a file is copied to specs/evidence/<ID>/ under a name safe in a
# Markdown link; prints the link, from the workspace root. Run in the workspace.
ev_link() {
  local dir="specs/evidence/$1" name
  [[ "$2" == http* ]] && { printf '<%s>' "$2"; return; }
  name="$(basename "$2")"; name="$(printf %s "$name" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.-]*//')"
  while [[ -e "$dir/$name" ]]; do name="1-$name"; done
  mkdir -p "$dir" && cp "$2" "$dir/$name" || { echo "could not copy $2 to $dir" >&2; exit 1; }
  printf '[%s](%s/%s)' "$name" "$dir" "$name"
}
# One writer at a time, or two agents filing at once could take the same number or lose a line.
lock_handoffs() {
  cd "$WS"
  grep -q '^## Open$' HANDOFFS.md || { echo "no '## Open' heading in HANDOFFS.md" >&2; exit 1; }
  lock="$K/handoff.lock"
  # A write takes under a second: a lock older than a minute was left by a writer that was stopped.
  # Renamed away, not removed, so of several waiters only one breaks it.
  # ponytail: a waiter that saw it stale just as another took it over could move the new lock; the doctor's unique-ids check is the backstop.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    mkdir "$lock" 2>/dev/null && break
    if (( $(date +%s) - $(mtime "$lock" 2>/dev/null || date +%s) > 60 )) && mv "$lock" "$lock.stale.$$" 2>/dev/null; then
      rm -rf "$lock.stale.$$"; continue
    fi
    sleep 1
  done
  [[ -d "$lock" ]] || { echo "another handoff is being written ($lock); try again, or remove the folder if none is" >&2; exit 1; }
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
  dirty=""; [[ -z "$(git status --porcelain -- HANDOFFS.md)" ]] || dirty=1
}
# save <what was done> <commit message> <path>...: commit, or with someone else's uncommitted lines
# in HANDOFFS.md, leave it written but uncommitted so their lines never go into this commit.
save() {
  local did=$1 msg=$2; shift 2
  if [[ -n "$dirty" ]]; then
    echo "$did, not committed: HANDOFFS.md had other uncommitted lines. Commit only yours (git add -p HANDOFFS.md$( (($# > 1)) && echo ", and ${2}"))."
    exit 0
  fi
  git add -- "$@"
  git commit -q -m "$msg" -- "$@" || { echo "$did, but the commit failed (see above): commit $* yourself" >&2; exit 1; }
  echo "$did and committed"
}
# entry <ID> info|evidence <links>|verdict <role> <line>: read or change one open entry in place.
# info prints "<sender>\t<1 when it has evidence>\t<small when it is a small task>\t<addressee>". Exit 3 when the entry is not under "## Open".
entry() {
  python3 -I - "$WS/HANDOFFS.md" "$@" <<'PY'
import re, sys
path, hid, mode, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
lines = open(path, encoding="utf-8").read().split("\n")
if "## Open" not in lines:
    sys.exit(3)
start = None
for i in range(lines.index("## Open") + 1, len(lines)):
    if lines[i].startswith("## "):
        break
    if lines[i].startswith("### " + hid + ":"):
        start = i
        break
if start is None:
    sys.exit(3)
end = start + 1
while end < len(lines) and not lines[end].startswith(("### ", "## ")):
    end += 1
last = end - 1
while last > start and not lines[last].strip():
    last -= 1
body = lines[start + 1:last + 1]
has_ev = lambda l: l.startswith("- Evidence:") and re.search(r"\]\(|<https?:", l)
if mode == "info":
    sender = next((m.group(1).strip() for m in (re.match(r"- From: (.*?) ->", l) for l in body) if m), "")
    small = "small" if any(re.match(r"- Size: small\s*$", l) for l in body) else ""
    to = next((m.group(1).strip() for m in (re.match(r"- From: .*? -> To: (.*)", l) for l in body) if m), "")
    print(sender + "\t" + ("1" if any(has_ev(l) for l in body) else "") + "\t" + small + "\t" + to)
    sys.exit(0)
if mode == "evidence":
    links = args[0]
    at = next((i for i, l in enumerate(body) if l.startswith("- Evidence:")), None)
    if at is None:
        v = next((i for i, l in enumerate(body) if l.startswith("- Verdict:")), len(body))
        body.insert(v, "- Evidence: " + links)
    elif has_ev(body[at]):
        body[at] = body[at].rstrip() + ", " + links
    else:
        body[at] = "- Evidence: " + links
elif mode == "verdict":
    role, line = args
    body = [l for l in body if not l.startswith("- Verdict: " + role + " ")] + [line]
lines[start + 1:last + 1] = body
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
}

h_add() {
usage="usage: bin/handoff.sh add --from <name> --to <name> --changed \"...\" --needed \"...\" [--depends-on \"...\"] [--spec <file> | --small] [--evidence <file or URL>]... \"<title>\""
from="" to="" changed="" needed="" depends="none" title="" spec="" small=""
local -a ev
ev=()
while (($#)); do
  case "$1" in
    --evidence)
      (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }
      ev+=("$(ev_arg "$2")") || exit 2
      shift 2 ;;
    --small) small=1; shift ;;
    --spec)
      (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }
      spec="$(ws_md --spec "$2")" || exit 1
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
# Work that gets built is either a small task or from a spec ready to build (.cabinet/rules/ready-to-build.md).
[[ -z "$spec" || -z "$small" ]] || { echo "--spec or --small, not both: a task with a spec is not small. $usage" >&2; exit 2; }
if [[ -z "$spec$small" ]]; then
  while IFS= read -r n; do
    n="$(lc "$(printf '%s' "$n" | sed 's/^ *//; s/ *$//')")"
    [[ -n "$n" ]] && builds_repos "$n" && { echo "$n builds: say what this is, --spec specs/<feature>.md for work from a ready spec, or --small for a small task (one repo, no contract change, no decision for the owner, easy to undo). $usage" >&2; exit 2; }
  done < <(printf '%s\n' "$to" | sed 's/([^)]*)//g; s/ and /,/g; s/&/,/g' | tr -d '`' | tr ',' '\n')
fi
if [[ -n "$spec" ]]; then
  sc="$("$(dirname "$0")/spec.sh" check "$spec" --json 2>/dev/null || true)"
  st="$(jq -r '.[0].status // ""' <<<"$sc" 2>/dev/null || true)" sp="$(jq -r '.[0].problems // [] | join("; ")' <<<"$sc" 2>/dev/null || true)"
  [[ "$st" =~ ^(ready|building)$ ]] || { echo "$spec is ${st:-without a status}, not ready: product-manager sets it ready once bin/spec.sh check $spec passes" >&2; exit 1; }
  [[ -z "$sp" ]] || { echo "$spec is not ready to build: $sp (bin/spec.sh check $spec)" >&2; exit 1; }
fi

lock_handoffs

day="$(date +%Y%m%d)"
files=(HANDOFFS.md); for f in handoffs/archive-*.md; do [[ -f "$f" ]] && files+=("$f"); done
last="$(grep -ho "^### H-$day-[0-9]*" "${files[@]}" | sed 's/.*-0*//' | sort -n | tail -1 || true)"
id="$(printf 'H-%s-%02d' "$day" $((${last:-0} + 1)))"

evline=""
for e in ${ev[@]+"${ev[@]}"}; do evline="${evline:+$evline, }$(ev_link "$id" "$e")"; done

# Newest at the bottom of "## Open": before the next "## " heading, or at the end.
entry="### $id: $title
- From: $from -> To: $to
- Status: open ($(date +%F))
- Changed: $changed
- Needed: $needed
- Depends on: $depends${spec:+
- Spec: $spec}${small:+
- Size: small}${evline:+
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

paths=(HANDOFFS.md); [[ -d "specs/evidence/$id" ]] && paths+=("specs/evidence/$id")
save "$id filed for $to" "handoffs: $id $title" "${paths[@]}"
}

h_attach() {
usage="usage: bin/handoff.sh attach <ID> <file or URL>... --from <name>"
local id="" from="" evline="" e
local -a ev
ev=()
while (($#)); do
  case "$1" in
    --from) (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }; from="$2"; shift 2 ;;
    -*) echo "unknown option $1. $usage" >&2; exit 2 ;;
    *) if [[ -z "$id" ]]; then id="$1"; else ev+=("$(ev_arg "$1")") || exit 2; fi; shift ;;
  esac
done
[[ "$id" =~ ^H-[0-9]{8}-[0-9]+$ && -n "$from" && ${#ev[@]} -gt 0 ]] || { echo "an entry ID, --from and at least one file or URL. $usage" >&2; exit 2; }
lock_handoffs
info="$(entry "$id" info)" || { echo "$id is not an open entry in HANDOFFS.md (bin/handoff.sh list)" >&2; exit 1; }
sender="${info%%$'\t'*}"
[[ "$(lc "$from")" == "$(lc "$sender")" ]] || { echo "$id was filed by $sender: only its sender adds evidence (a reviewer links its own in its note)" >&2; exit 1; }
for e in "${ev[@]}"; do evline="${evline:+$evline, }$(ev_link "$id" "$e")"; done
entry "$id" evidence "$evline"
paths=(HANDOFFS.md); [[ -d "specs/evidence/$id" ]] && paths+=("specs/evidence/$id")
save "$id: evidence attached" "handoffs: $id evidence" "${paths[@]}"
}

h_record() {
usage="usage: bin/handoff.sh record <ID> --role <role> <PASS|BLOCK|CHANGES> --commits <hash,...>|none --note <file>"
local id="" role="" verdict="" commits="" note="" rel
while (($#)); do
  case "$1" in
    --role|--commits|--note)
      (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }
      case "$1" in --role) role="$(lc "$2")" ;; --commits) commits="$2" ;; --note) note="$2" ;; esac
      shift 2 ;;
    -*) echo "unknown option $1. $usage" >&2; exit 2 ;;
    *) if [[ -z "$id" ]]; then id="$1"; elif [[ -z "$verdict" ]]; then verdict="$(printf %s "$1" | tr '[:lower:]' '[:upper:]')"; else echo "one verdict only. $usage" >&2; exit 2; fi; shift ;;
  esac
done
# Commits as one token: "a1b2c3d, e4f5a6b" is read as "a1b2c3d,e4f5a6b".
commits="$(lc "$commits" | tr -s ' ,' ',,' | sed 's/^,//; s/,$//')"
[[ "$id" =~ ^H-[0-9]{8}-[0-9]+$ ]] || { echo "an entry ID first (H-YYYYMMDD-NN). $usage" >&2; exit 2; }
[[ "$role" =~ ^[a-z0-9-]+$ ]] || { echo "--role needs a role name. $usage" >&2; exit 2; }
[[ "$verdict" =~ ^(PASS|BLOCK|CHANGES)$ ]] || { echo "the verdict is PASS, BLOCK or CHANGES. $usage" >&2; exit 2; }
[[ "$commits" =~ ^[0-9a-f]{7,40}(,[0-9a-f]{7,40})*$ || "$commits" == none ]] || { echo "--commits needs commit hashes (7 to 40 hex digits, joined by commas), or none for work that changes no repo. $usage" >&2; exit 2; }
[[ -n "$note" ]] || { echo "--note needs the file that holds the details. $usage" >&2; exit 2; }
rel="$(ws_md --note "$note")" || exit 1
lock_handoffs
info="$(entry "$id" info)" || { echo "$id is not an open entry in HANDOFFS.md (bin/handoff.sh list)" >&2; exit 1; }
# Split by hand: read would merge the two tabs around an empty field.
sender="${info%%$'\t'*}" rest="${info#*$'\t'}"; hasev="${rest%%$'\t'*}" rest="${rest#*$'\t'}"; size="${rest%%$'\t'*}" to="${rest#*$'\t'}"
# Work for a repo or a builder has commits: none is only for work that changes no repo.
if [[ "$commits" == none ]]; then
  while IFS= read -r n; do
    n="$(lc "$(printf '%s' "$n" | sed 's/^ *//; s/ *$//')")"
    [[ -n "$n" ]] && builds_repos "$n" && { echo "$id is work for $n, which builds: name its commits (--commits <hash,...>)" >&2; exit 1; }
  done < <(printf '%s\n' "$to" | sed 's/([^)]*)//g; s/ and /,/g; s/&/,/g' | tr -d '`' | tr ',' '\n')
fi
[[ "$role" != "$(lc "$sender")" ]] || { echo "$id was filed by $role: the builder never verifies its own work (CABINET.md, \"The builder never verifies\")" >&2; exit 1; }
if [[ "$role" == qa && "$verdict" == PASS && -z "$hasev" ]]; then
  echo "$id has no evidence, so qa cannot pass it: record BLOCK naming what is missing; its sender adds it with bin/handoff.sh attach $id <file or URL> --from $sender" >&2; exit 1
fi
if [[ "$size" == small && "$verdict" == PASS && "$commits" != none ]]; then
  why="$(small_problems "$commits")"
  [[ -z "$why" ]] || { echo "$id is marked small, but $why: it needs a spec. Record BLOCK; chief-of-staff routes it again from a spec (CABINET.md, \"Ready to build\")" >&2; exit 1; }
fi
entry "$id" verdict "$role" "- Verdict: $role $verdict $(date +%F) $commits $rel"
save "$id: $role $verdict recorded" "handoffs: $id $role $verdict" HANDOFFS.md
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
  attach) h_attach "$@" ;;
  record) h_record "$@" ;;
  list) h_list "$@" ;;
  archive) h_archive "$@" ;;
  *) echo "usage: bin/handoff.sh add|attach|record|list|archive (see the top of this file)" >&2; exit 2 ;;
esac
