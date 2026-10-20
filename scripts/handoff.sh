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
#   bin/handoff.sh list [name] [--ready] [--json]
#       No name: every open or acknowledged entry: age in days, ID, addressee, title, oldest first.
#       A repo or role name (api, qa, owner, ...): every entry addressed to it that is not done or
#       rejected, in full; the start-of-session read. --json: the same as JSON (id, status, date,
#       age_days, from, to, title; with a name, each entry's full text too), with its readiness:
#       verdicts, needs (the reviewers it needs), missing, blocking, stale (a PASS that does not
#       cover every commit a verdict names), ready (true, false, or null when it needs no review)
#       and unread_verdicts (PASS, BLOCK or CHANGES written outside a "- Verdict:" line, not read).
#       --ready: only the entries ready for the owner to push.
#   bin/handoff.sh run <ID> [--retries <n>] [--dry-run]
#       Move one piece of work (a handoff to one builder, filed --small or --spec) through the steps
#       the team already has, each an agent run, until it is ready to push or needs the owner: the
#       builder builds it and hands it on for review with --depends-on <ID>; each reviewer missing or
#       stale verifies and records; after a BLOCK the builder fixes it and the blocking reviewers
#       check again, up to --retries rounds (default 2). It decides nothing: it reads the state
#       (handoff list --json) and stops when an agent fails, leaves no trace, or the work is ready.
#       Each run is limited like a job (CABINET_JOB_TIMEOUT), logged in the log folder as
#       run-<ID>.log, and its cost recorded under <ID>. --dry-run prints the next step only.
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

# readiness: {"<ID>": {verdicts, needs, missing, blocking, stale, ready, unread_verdicts}} for every
# entry. Needed: each reviewer the entry is addressed to, and for code (from a builder, or a verdict
# that names commits) qa, security and code-reviewer, with design-lead for a web or mobile builder,
# each when on the team. The work's commits are every commit a verdict names; a PASS counts only when
# it covers them all, so a fix after a PASS needs that reviewer again.
readiness() {
  local names builds ui n o
  names="$(repos 2>/dev/null | cut -f1 | tr '\n' ' ')"
  builds="$names $BUILDERS" ui="web mobile"
  while IFS=$'\t' read -r n o; do
    has "$names" "$n" || continue
    builds+=" $o"; [[ "$o" == web || "$o" == mobile ]] && ui+=" $n"
  done < <(team_rows)
  TEAM="$(team_roles)" BUILDS="$builds" UI="$ui" python3 -I - "$WS/HANDOFFS.md" "$SPEND" <<'PY'
import json, os, re, sys
cost = {}
try:
    for row in open(sys.argv[2], encoding="utf-8"):
        f = row.rstrip("\n").split("\t")
        if len(f) >= 4 and f[3]:
            cost[f[1]] = cost.get(f[1], 0) + float(f[3])
except (OSError, ValueError):
    pass
team, builds, ui = (set(os.environ.get(k, "").split()) for k in ("TEAM", "BUILDS", "UI"))
VER = re.compile(r"- Verdict: ([a-z0-9-]+) (PASS|BLOCK|CHANGES) (\d{4}-\d{2}-\d{2}) ([0-9a-f]+(?:,[0-9a-f]+)*|none) (\S+)$")
def names(s):
    s = re.sub(r"\([^)]*\)", "", s).replace(" and ", ",").replace("&", ",").replace("`", "")
    return [n.strip().lower() for n in s.split(",") if n.strip()]
def covers(have, want):  # short and long hashes of one commit match
    return all(any(w.startswith(h) or h.startswith(w) for h in have) for w in want)
entries, cur, on = [], None, False
for l in open(sys.argv[1], encoding="utf-8").read().split("\n"):
    if l.startswith("## "):
        on, cur = l.startswith(("## Open", "## Archive")), None
    elif on and l.startswith("### H-"):
        cur = {"id": l.split()[1].rstrip(":"), "lines": []}
        entries.append(cur)
    elif cur is not None:
        cur["lines"].append(l)
out = {}
for e in entries:
    frm, to, vs, unread = "", "", [], []
    for l in e["lines"]:
        m = re.match(r"- From: (.*?) -> To: (.*)", l)
        if m and not frm:
            frm, to = m.group(1).strip().lower(), m.group(2)
        v = VER.match(l.strip())
        if v:
            vs.append({"role": v.group(1), "verdict": v.group(2), "date": v.group(3),
                       "commits": [] if v.group(4) == "none" else v.group(4).split(","), "note": v.group(5)})
        elif re.search(r"\b(PASS|BLOCK|CHANGES)\b", l):
            unread.append(l.strip())
    needs = []
    for n in names(to):
        if n in team and n not in builds and n != "chief-of-staff" and n not in needs:
            needs.append(n)
    if frm in builds or any(v["commits"] for v in vs):
        for r in ["qa", "security", "code-reviewer"] + (["design-lead"] if frm in ui else []):
            if r in team and r not in needs:
                needs.append(r)
    work = []
    for c in (c for v in vs for c in v["commits"]):
        if not covers(work, [c]):
            work.append(c)
    last = {v["role"]: v for v in vs}
    blocking = [r for r, v in last.items() if v["verdict"] != "PASS"]
    stale = [r for r, v in last.items() if v["verdict"] == "PASS" and not covers(v["commits"], work)]
    missing = [r for r in needs if r not in last]
    dep = next((l[len("- Depends on:"):].strip() for l in e["lines"] if l.startswith("- Depends on:")), "")
    st = next((l[len("- Status:"):].strip() for l in e["lines"] if l.startswith("- Status:")), "")
    out[e["id"]] = {"depends_on": dep, "status_now": st.split(" ")[0] if st else "", "small": any(l.strip() == "- Size: small" for l in e["lines"]),
                    "spec": next((l[len("- Spec:"):].strip() for l in e["lines"] if l.startswith("- Spec:")), ""),
                    "cost_usd": round(cost[e["id"]], 6) if e["id"] in cost else None, "verdicts": vs, "needs": needs, "missing": missing, "blocking": blocking, "stale": stale,
                    "ready": (not missing and not blocking and not stale) if needs else None, "unread_verdicts": unread}
print(json.dumps(out))
PY
}

h_list() {
# --json (anywhere in the arguments): the same entries as JSON, for agents and scripts.
# --ready: only the entries every reviewer they need has passed, at the latest commits.
json=0 ready=0; args=()
for a in "$@"; do case "$a" in --json) json=1 ;; --ready) ready=1 ;; *) args+=("$a") ;; esac; done
set -- ${args[@]+"${args[@]}"}
local rd; rd="$(readiness)"

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
    | if $who == "" then sort_by(.date // "9999-99-99") | map(del(.text)) else . end' \
  | jq --argjson r "$rd" --argjson only "$ready" 'map(. + (($r[.id] // {}) | del(.status_now))) | if $only == 1 then map(select(.ready == true)) else . end'
  exit 0
fi

if [[ $# -gt 0 ]]; then
  ((ready == 0)) || { echo "--ready lists every entry ready to push; it takes no name (or add --json)" >&2; exit 2; }
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
  ((ready == 0)) || jq -e --arg i "$id" '.[$i].ready == true' <<<"$rd" >/dev/null || continue
  if [[ "$d" == 9999-99-99 ]]; then age="?"
  else age=$(( (today - $(epoch "$d") + 43200) / 86400 )); fi  # rounded, so a DST day still counts as one
  printf '%3sd  %-12s  %-14s  %-24s  %s\n' "$age" "$st" "$id" "$to" "$title"
done | { out="$(cat)"; [[ -n "$out" ]] && printf '%s\n' "$out" || { ((ready)) && echo "No handoffs ready to push." || echo "No open handoffs."; }; }
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

h_run() {
usage="usage: bin/handoff.sh run <ID> [--retries <n>] [--dry-run]"
local id="" retries=2 dry=0 builder rounds=0 fixed=0 built=0 step=0 rd w v r todo x before
while (($#)); do
  case "$1" in
    --retries) (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }; retries="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*) echo "unknown option $1. $usage" >&2; exit 2 ;;
    *) [[ -z "$id" ]] || { echo "one handoff at a time. $usage" >&2; exit 2; }; id="$1"; shift ;;
  esac
done
[[ "$id" =~ ^H-[0-9]{8}-[0-9]+$ ]] || { echo "a handoff ID (H-YYYYMMDD-NN). $usage" >&2; exit 2; }
[[ "$retries" =~ ^[0-9]+$ ]] || { echo "--retries is a number of fix rounds, like 2. $usage" >&2; exit 2; }
cd "$WS"
rd="$(readiness)"
w="$(jq -c --arg i "$id" '.[$i] // empty' <<<"$rd")"
[[ -n "$w" ]] || { echo "$id is not in HANDOFFS.md (bin/handoff.sh list)" >&2; exit 1; }
# One builder, and work that is ready to build: what the steps start from.
builder="$(sed -n "/^### $id:/,/^### /s/^- From: .* -> To: //p" HANDOFFS.md | head -1 | sed 's/([^)]*)//g; s/ and /,/g; s/&/,/g' | tr -d '\`' | tr ',' '\n' \
  | while IFS= read -r x; do x="$(lc "$(printf '%s' "$x" | sed 's/^ *//; s/ *$//')")"; [[ -n "$x" ]] && builds_repos "$x" && echo "$x"; done)"
[[ -n "$builder" && "$builder" != *$'\n'* ]] || { echo "$id is not work for one builder: run takes a handoff to one repo or builder" >&2; exit 1; }
has "$(team_roles)" "$builder" || builder="$(owner_of "$builder")"
[[ -n "$builder" ]] || { echo "$id: no role owns its repo in the team table of AGENTS.md" >&2; exit 1; }
[[ "$(jq -r '.small' <<<"$w")" == true || -n "$(jq -r '.spec' <<<"$w")" ]] || { echo "$id is neither --small nor --spec: only work that is ready to build is run (.cabinet/rules/ready-to-build.md)" >&2; exit 1; }
x="$(jq -r '.spec' <<<"$w")"
if [[ -n "$x" ]] && ! "$WS/bin/spec.sh" check "$x" >/dev/null 2>&1; then echo "$x is not ready to build (bin/spec.sh check $x)" >&2; exit 1; fi

mkdir -p -m 700 "$LOGDIR"
local lock="$K/run-$id.lock" log="$LOGDIR/run-$id.log"
if ((dry == 0)); then
  mkdir "$lock" 2>/dev/null || { echo "$id is already being run ($lock; remove the folder if no run is)" >&2; exit 1; }
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
fi
SPEND_LABEL="$id"
say() { echo "$*"; ((dry)) || echo "=== $(date '+%F %T') $*" >>"$log"; }
spent() { local c; c="$(jq -r --arg i "$id" '.[$i].cost_usd // empty' <<<"$(readiness)")"; [[ -n "$c" ]] && printf ', $%.2f so far' "$c"; return 0; }
stop() { say "Stopped: $1"; echo "Log: $log"; exit 1; }
agent() {  # agent <role> <what it does> <prompt>
  say "$1: $2"
  ((dry)) && exit 0
  AGENT=$1 PROMPT=$3
  run_limited "$CABINET_JOB_TIMEOUT" "the run's time limit (CABINET_JOB_TIMEOUT in cabinet.env)" >>"$log" 2>&1 || stop "$1 did not finish (exit $?): see the log"
}
while :; do
  step=$((step + 1)); ((step <= 30)) || stop "more steps than any piece of work takes; the owner looks at it"
  rd="$(readiness)"
  w="$(jq -c --arg i "$id" '.[$i]' <<<"$rd")"
  v="$(jq -r --arg i "$id" 'to_entries | map(select(.key != $i and (.value.depends_on | test("(^|[^0-9A-Za-z-])" + $i + "($|[^0-9])")) and (.value.status_now | test("^(done|rejected)") | not))) | .[0].key // empty' <<<"$rd")"
  if [[ -z "$v" ]]; then
    case "$(jq -r .status_now <<<"$w")" in
      rejected*) stop "$builder sent $id back (its status line says why)" ;;
      done*) stop "$id is done, but no review handoff depends on it: the builder hands on with --depends-on $id" ;;
    esac
    ((built == 0)) || stop "$builder ran but filed no review handoff for $id"
    agent "$builder" "builds $id" "Pick up handoff $id, addressed to you (bin/handoff.sh list $builder), and build it as .cabinet/rules/builders.md says. When its checks pass and it is committed, hand it on for review with bin/handoff.sh add --from $builder --to <every reviewer its subject needs> --depends-on $id, with its evidence, then set $id to done. If it is not ready to build, set $id to rejected with what is missing instead."
    built=1; continue
  fi
  r="$(jq -c --arg v "$v" '.[$v]' <<<"$rd")"
  if [[ "$(jq -r .ready <<<"$r")" == true ]]; then
    say "$id is ready to push: every reviewer passed $v$(spent). Push it from your terminal; chief-of-staff closes $v once it is pushed."
    exit 0
  fi
  [[ "$(jq -r .ready <<<"$r")" != null ]] || stop "$v needs no review, so there is nothing to run"
  if [[ "$(jq '.blocking | length' <<<"$r")" != 0 ]] && ((fixed == 0)); then
    rounds=$((rounds + 1))
    ((rounds <= retries)) || stop "$(jq -r '.blocking | join(", ")' <<<"$r") still block $v after $retries fix round(s): the owner decides (fix it, change the work, or override)"
    agent "$builder" "fixes what $(jq -r '.blocking | join(", ")' <<<"$r") blocked, round $rounds" "Handoff $v, your work for $id, has a BLOCK or CHANGES from $(jq -r '.blocking | join(", ")' <<<"$r"): their notes (the Verdict lines on $v) say what to fix. Fix it in your repo with a test, commit, and attach new evidence to $v (bin/handoff.sh attach $v <file or URL> --from $builder) when what people see changed. The reviewers check again after you."
    fixed=1; continue
  fi
  todo="$(jq -r '(.blocking + .stale + .missing) | unique | .[]' <<<"$r")"
  [[ -n "$todo" ]] || stop "$v is not ready, and no reviewer is waiting: see bin/handoff.sh list --json"
  for x in $todo; do
    before="$(jq -c --arg x "$x" '[.verdicts[] | select(.role == $x)]' <<<"$r")"
    agent "$x" "verifies $v" "Verify handoff $v as your role says, then record your verdict with bin/handoff.sh record $v --role $x PASS|BLOCK|CHANGES --commits <every commit of the work> --note <your note>."
    [[ "$(jq -c --arg x "$x" --arg v "$v" '[.[$v].verdicts[] | select(.role == $x)]' <<<"$(readiness)")" != "$before" ]] || stop "$x recorded no verdict on $v"
  done
  fixed=0
done
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  add) h_add "$@" ;;
  attach) h_attach "$@" ;;
  record) h_record "$@" ;;
  run) h_run "$@" ;;
  list) h_list "$@" ;;
  archive) h_archive "$@" ;;
  *) echo "usage: bin/handoff.sh add|attach|record|list|run|archive (see the top of this file)" >&2; exit 2 ;;
esac
