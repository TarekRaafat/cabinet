#!/usr/bin/env bash
# HANDOFFS.md, the one channel between agents (CABINET.md, "Handoffs").
#
#   bin/handoff.sh add --from <name> --to <name> --changed "..." --needed "..." [--depends-on "..."] [--spec <file> | --small] [--way-back "..."] [--evidence <file or URL>]... "<title>"
#       Append one entry to "## Open" with the next free ID for today (unique across HANDOFFS.md and
#       handoffs/archive-*.md), today's date and the template's lines, then commit it on its own.
#       Each --evidence file is copied to specs/evidence/<ID>/ and linked on the entry's Evidence line,
#       from the workspace root, so it opens from HANDOFFS.md and BRIEF.md; a URL is linked as it is.
#       --spec names the spec it builds, on a "- Spec:" line, and refuses unless bin/spec.sh check
#       finds the spec ready or building with nothing missing (.cabinet/rules/ready-to-build.md). --small
#       marks it a small task ("- Size: small"). Work for a repo, or for a role that builds one, needs
#       one of the two. --way-back says how to undo the change once pushed, released or published
#       (or why there is none), on a "- Way back:" line; one line, never empty.
#       Prints the new ID first. With someone else's uncommitted lines in HANDOFFS.md, the entry is
#       written but not committed, so their lines never go into its commit.
#   bin/handoff.sh attach <ID> [<file or URL>...] [--way-back "..."] --from <name>
#       The entry's sender adds evidence later (after a BLOCK, a fix, a missed screen): files copied
#       to specs/evidence/<ID>/ and every link added to the entry's Evidence line, then committed.
#       --way-back adds the entry's "- Way back:" line, or replaces it, before its first verdict.
#   bin/handoff.sh record <ID> --role <role> <PASS|BLOCK|CHANGES> --commits <hash,...>|none --note <file>
#       A reviewer's verdict: writes (or replaces) its "- Verdict:" line with today's date, then
#       commits. The note must be committed under specs/. Refuses a verdict by the entry's own
#       sender, a qa PASS on an entry with no evidence, and a PASS on a small task whose commits
#       span repos or change a path AGENTS.md guards (small_problems in lib.sh), and a PASS on commits
#       that change a path under "Hard to undo" in AGENTS.md while the entry has no "- Way back:"
#       line (hard_hit in lib.sh). A PASS from a
#       reviewer a critical area requires counts only when the area's check (a command in tools/)
#       passes at those commits; its output is kept as evidence on the entry. --commits none is for
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
#       check again, up to --retries rounds (default 2), and once one reviewer's BLOCK or CHANGES on
#       the work, counted over every run (blocks in list --json), pass --retries, it stops for the
#       owner before another round. It decides nothing: it reads the state
#       (handoff list --json) and stops when an agent fails, leaves no trace, or the work is ready.
#       Each run is limited like a job (CABINET_JOB_TIMEOUT), logged in the log folder as
#       run-<ID>.log, and its cost recorded under <ID>. --dry-run prints the next step only.
#   bin/handoff.sh run --scheduled
#       What the pipeline job runs: every piece of work CABINET_PIPELINE allows (small: handoffs filed
#       --small; all: those and every spec ready to build), oldest first, within CABINET_PIPELINE_LIMIT
#       dollars, writing what happened to PIPELINE.md. Runs nothing when the setting is off, when the
#       week's budget is spent, or when the agent tool's cost cannot be counted. Skips work whose last
#       run stopped for the owner, until the owner runs it by hand.
#   bin/handoff.sh archive
#       Move every committed closed entry (done or rejected) to handoffs/archive-YYYY-MM.md (month of
#       its ID) and commit the move; chief-of-staff runs it daily. Refuses while HANDOFFS.md has
#       uncommitted lines, so no agent's unsaved update is lost.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

lc() { printf %s "$1" | tr '[:upper:]' '[:lower:]'; }
# way_back <text>: the text of a "- Way back:" line, or exit 2: never empty, never more than one line.
way_back() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] || { echo "--way-back is one line: no line breaks. $usage" >&2; return 2; }
  local t; t="$(printf '%s' "$1" | tr '\t' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [[ -n "$t" ]] || { echo "--way-back needs how to undo the change, or why there is no way back. $usage" >&2; return 2; }
  printf '%s' "$t"
}
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
  node "$LIBJS" handoff-entry "$WS/HANDOFFS.md" "$@"
}

h_add() {
usage="usage: bin/handoff.sh add --from <name> --to <name> --changed \"...\" --needed \"...\" [--depends-on \"...\"] [--spec <file> | --small] [--way-back \"...\"] [--evidence <file or URL>]... \"<title>\""
from="" to="" changed="" needed="" depends="none" title="" spec="" small="" back=""
local -a ev
ev=()
while (($#)); do
  case "$1" in
    --evidence)
      (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }
      ev+=("$(ev_arg "$2")") || exit 2
      shift 2 ;;
    --small) small=1; shift ;;
    --way-back)
      (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }
      back="$(way_back "$2")" || exit 2
      shift 2 ;;
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
  st="$(json -r '$[0]?.status ?? ""' <<<"$sc" 2>/dev/null || true)" sp="$(json -r '($[0]?.problems ?? []).join("; ")' <<<"$sc" 2>/dev/null || true)"
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
- Size: small}${back:+
- Way back: $back}${evline:+
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
usage="usage: bin/handoff.sh attach <ID> [<file or URL>...] [--way-back \"...\"] --from <name>"
local id="" from="" evline="" e back=""
local -a ev
ev=()
while (($#)); do
  case "$1" in
    --from) (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }; from="$2"; shift 2 ;;
    --way-back) (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }; back="$(way_back "$2")" || exit 2; shift 2 ;;
    -*) echo "unknown option $1. $usage" >&2; exit 2 ;;
    *) if [[ -z "$id" ]]; then id="$1"; else ev+=("$(ev_arg "$1")") || exit 2; fi; shift ;;
  esac
done
[[ "$id" =~ ^H-[0-9]{8}-[0-9]+$ && -n "$from" && ( ${#ev[@]} -gt 0 || -n "$back" ) ]] || { echo "an entry ID, --from and at least one file or URL, or --way-back. $usage" >&2; exit 2; }
lock_handoffs
info="$(entry "$id" info)" || { echo "$id is not an open entry in HANDOFFS.md (bin/handoff.sh list)" >&2; exit 1; }
sender="${info%%$'\t'*}"
[[ "$(lc "$from")" == "$(lc "$sender")" ]] || { echo "$id was filed by $sender: only its sender adds evidence or a way back (a reviewer links its own in its note)" >&2; exit 1; }
for e in ${ev[@]+"${ev[@]}"}; do evline="${evline:+$evline, }$(ev_link "$id" "$e")"; done
[[ -z "$evline" ]] || entry "$id" evidence "$evline"
[[ -z "$back" ]] || entry "$id" wayback "$back"
paths=(HANDOFFS.md); [[ -d "specs/evidence/$id" ]] && paths+=("specs/evidence/$id")
if [[ -z "$evline" ]]; then save "$id: way back written" "handoffs: $id way back" "${paths[@]}"
elif [[ -z "$back" ]]; then save "$id: evidence attached" "handoffs: $id evidence" "${paths[@]}"
else save "$id: evidence and way back attached" "handoffs: $id evidence and way back" "${paths[@]}"; fi
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
# Critical areas (.cabinet/rules/reviews.md): a PASS from a reviewer an area requires counts only when
# the area's check passes at these commits. Run before the lock, since a check can take a while.
local -a checked
checked=()
run_check() {  # run_check <area> <command>
  local a=$1 cmd=$2 out="specs/evidence/$id/check-$1.txt" st=0
  local -a w
  [[ "$cmd" =~ ^tools/[A-Za-z0-9._/-]+( [A-Za-z0-9._/=:,-]+)*$ && "$cmd" != *..* ]] \
    || { echo "the $a check in AGENTS.md, '$cmd', is not a command in tools/ (letters, digits and . _ - / = : , only)" >&2; return 1; }
  set -f; w=($cmd); set +f
  [[ -f "$WS/${w[0]}" && -x "$WS/${w[0]}" ]] || { echo "the $a check, ${w[0]}, is missing or cannot run (chmod +x)" >&2; return 1; }
  mkdir -p "$WS/specs/evidence/$id"
  # No shell: the command and its words as they are, in the workspace, within the run's time limit.
  (cd "$WS" && CABINET_AREA="$a" CABINET_HANDOFF="$id" CABINET_COMMITS="${commits/none/}" \
    node "$LIBJS" run-limited "$((CABINET_JOB_TIMEOUT * 60))" "$WS/${w[0]}" "${w[@]:1}") > "$WS/$out" 2>&1 || st=$?
  if ((st)); then
    echo "the $a check failed (exit $st), so $role cannot pass $id; its last lines:" >&2; tail -5 "$WS/$out" >&2; rm -f "$WS/$out"; return 1
  fi
  checked+=("$out")
}
if [[ "$verdict" == PASS ]]; then
  local ar lead a p r e c
  lead="$(role_team "$role" "Reports to")"
  ar="$( { readiness | json -r --each --arg i "$id" '$[$i]?.areas ?? []'; [[ "$commits" == none ]] || areas_hit "$commits"; } | sort -u)"
  while IFS=$'\t' read -r a p r e c; do
    grep -qxF "$a" <<<"$ar" || continue
    has "$r" "$role" || { [[ -n "$lead" ]] && has "$r" "$lead"; } || continue
    [[ -z "$c" ]] || run_check "$a" "$c" || exit 1
  done < <(critical_areas)
fi
lock_handoffs
info="$(entry "$id" info)" || { echo "$id is not an open entry in HANDOFFS.md (bin/handoff.sh list)" >&2; exit 1; }
# Split by hand: read would merge the two tabs around an empty field.
sender="${info%%$'\t'*}" rest="${info#*$'\t'}"; hasev="${rest%%$'\t'*}" rest="${rest#*$'\t'}"; size="${rest%%$'\t'*}" rest="${rest#*$'\t'}"; hasback="${rest%%$'\t'*}" to="${rest#*$'\t'}"
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
# A change to a "Hard to undo" path says how to undo it before anyone passes it (.cabinet/rules/reviews.md).
if [[ "$verdict" == PASS && "$commits" != none && -z "$hasback" ]]; then
  why="$(hard_hit "$commits")"
  [[ -z "$why" ]] || { echo "$id changes $why, which \"Hard to undo\" in AGENTS.md names, and says no way back: record BLOCK; its sender adds one with bin/handoff.sh attach $id --way-back \"<how to undo it>\" --from $sender" >&2; exit 1; }
fi
entry "$id" verdict "$role" "- Verdict: $role $verdict $(date +%F) $commits $rel"
local -a paths
paths=(HANDOFFS.md)
for c in ${checked[@]+"${checked[@]}"}; do
  grep -qF "]($c)" HANDOFFS.md || entry "$id" evidence "[${c##*/}]($c)"
  paths+=("$c")
done
save "$id: $role $verdict recorded" "handoffs: $id $role $verdict" "${paths[@]}"
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
  # One record per entry under "## Open" (and a legacy "## Archive"); json picks the same
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
  ' "$WS/HANDOFFS.md" | json -R --arg who "$who" --argjson today "$today" --argjson r "$rd" --argjson only "$ready" '
    ((es) => ($who == "" ? es.sort((a, b) => (a.date ?? "9999-99-99").localeCompare(b.date ?? "9999-99-99", "en")).map(({text, ...e}) => e) : es)
      .map((e) => (({status_now, ...more}) => ({...e, ...more}))($r[e.id] ?? {}))
      .filter((e) => $only != 1 || e.ready === true))(
    $.map((l) => l.split("\t")).map((f) => ((date) => ({id: f[0], status_line: f[1], from: f[2], to: f[3], title: f[4], section: f[5],
        text: f[6].replaceAll("\u0001", "\n"), status: f[1].match(/^[a-z]+/)?.[0] ?? "", date,
        age_days: date ? Math.floor(($today - Date.parse(date) / 1000 + 43200) / 86400) : null}))(f[1].match(/[0-9]{4}-[0-9]{2}-[0-9]{2}/)?.[0] ?? null))
     .filter((e) => ($who == "" ? e.section == "open" && (e.status == "open" || e.status == "acknowledged")
       : new RegExp("(^|[^a-z-])(" + $who + ")([^a-z-]|$)").test(e.to) && !/^(done|rejected)/.test(e.status)))
     .map(({section, ...e}) => e))'
  exit 0
fi

if [[ $# -gt 0 ]]; then
  ((ready == 0)) || { echo "--ready lists every entry ready to push; it takes no name (or add --json)" >&2; exit 2; }
  # "owner" and "founder" name the same person.
  who="$1"; [[ "$who" == founder || "$who" == owner ]] && who="founder|owner"
  # Styled (platform.sh): on a Verdict line, PASS green, BLOCK and CHANGES red, after term_text.
  term_text < "$WS/HANDOFFS.md" | awk -v who="$who" -v g="$S_G" -v r="$S_R" -v z="$S_Z" '
  function flush() { if (e != "" && to ~ ("(^|[^a-z-])(" who ")([^a-z-]|$)") && st !~ /^(done|rejected)/) printf "%s\n", e; e=""; to=""; st="" }
  /^## / && $0 !~ /^## Open/ { flush(); on=0; if ($0 ~ /^## Archive/) on=1; next }
  /^## Open/ { flush(); on=1; next }
  !on { next }
  /^### H-/ { flush() }
  /^- From:/ && to == "" { to=$0; sub(/.*-> To: /, "", to) }
  /^- Status:/ && st == "" { st=$0; sub(/^- Status: /, "", st) }
  z != "" && /^- Verdict: / && $4 ~ /^(PASS|BLOCK|CHANGES)$/ && index($0, "- Verdict: " $3 " " $4) == 1 { p = length("- Verdict: " $3 " ")
    $0 = substr($0, 1, p) ($4 == "PASS" ? g : r) $4 z substr($0, p + length($4) + 1) }
  e != "" || /^### H-/ { e = e $0 "\n" }
  END { flush() }
  '
  exit 0
fi

term_text < "$WS/HANDOFFS.md" | awk '
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
' | sort | while IFS=$'\t' read -r d st id to title; do
  ((ready == 0)) || json -e --arg i "$id" '$[$i]?.ready === true' <<<"$rd" >/dev/null || continue
  if [[ "$d" == 9999-99-99 ]]; then age="?"
  else age=$(( (today - $(epoch "$d") + 43200) / 86400 )); fi  # rounded, so a DST day still counts as one
  # Styled (platform.sh): the age and ID dim, the owner yellow; padded from the plain text.
  printf -v pto '%-24s' "$to"
  [[ "$to" == owner || "$to" == founder ]] && pto="$S_Y$to$S_Z${pto:${#to}}"
  printf '%s%3sd%s  %-12s  %s%-14s%s  %s  %s\n' "$S_D" "$age" "$S_Z" "$st" "$S_D" "$id" "$S_Z" "$pto" "$title"
done | { out="$(cat)"; [[ -n "$out" ]] && printf '%s\n' "$out" || { ((ready)) && echo "No handoffs ready to push." || echo "No open handoffs."; }; }
# Passed work held only because its commits are on a session branch: said, with the command that shows the merge.
((ready == 0)) || json -r --each 'Object.entries($).filter(([i, e]) => e.session_branch && !e.archived && /^(open|acknowledged)$/.test(e.status_now))
  .map(([i, e]) => i + ": passed, but its commits are only on " + e.session_branch + ", not on the branch you push: cabinet session end " + e.session_branch.replace(/^session\//, "") + " shows how to merge it")' <<<"$rd"
}

h_archive() {
cd "$WS"
if [[ -n "$(git status --porcelain -- HANDOFFS.md)" ]]; then
  echo "HANDOFFS.md has uncommitted lines; commit them first (handoffs: commit pending lines from <agents>)." >&2
  exit 1
fi

n="$(node "$LIBJS" handoff-archive "$WS")"

if [[ "$n" == 0 ]]; then echo "nothing to archive"; exit 0; fi
git add -- HANDOFFS.md handoffs
git commit -q -m "handoffs: archive $n closed entries (bin/handoff.sh archive)" -- HANDOFFS.md handoffs
echo "archived $n closed entries"
}

h_scheduled() {
local out="$WS/PIPELINE.md" spent limit="$CABINET_PIPELINE_LIMIT" item key mark x last
local -a items cmd
items=()
report() { { echo "# Pipeline, $(LC_ALL=C date '+%-d %b %Y, %-I:%M %p')"; echo; printf '%s\n' "$@"; } > "$out"; printf '%s\n' "$@"; }
case "$CABINET_PIPELINE" in
  off) report "The pipeline is off: nothing runs on a schedule (cabinet config --pipeline small|all)."; exit 0 ;;
  small|all) ;;
  *) report "CABINET_PIPELINE is '$CABINET_PIPELINE', not off, small or all: nothing ran (cabinet config --pipeline)."; exit 1 ;;
esac
[[ "$limit" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] && awk -v l="$limit" 'BEGIN { exit !(l > 0) }' \
  || { report "No cost limit for a scheduled run (CABINET_PIPELINE_LIMIT), so nothing ran: cabinet config --pipeline-limit <dollars>."; exit 1; }
spend_counts || { report "$CABINET_RUNNER's cost cannot be counted, so the limit could not hold: nothing runs unattended (cabinet config --price, or another runner)."; exit 1; }
if [[ -n "$CABINET_BUDGET" ]] && awk -v s="$(spend_since "$(week_start)")" -v b="$CABINET_BUDGET" 'BEGIN { exit !(s + 0 >= b + 0) }'; then
  report "This week's budget (\$$CABINET_BUDGET) is spent, so nothing ran."; exit 0
fi
# The work, oldest first: specs ready to build (all), then handoffs filed --small that are still open
# or wait on their review; never one archived, sent back, or closed with nothing left to review.
if [[ "$CABINET_PIPELINE" == all ]]; then
  while IFS= read -r x; do items+=("spec $x"); done < <("$WS/bin/spec.sh" check --json 2>/dev/null | json -r --each '$.filter((s) => (s.status == "ready" || s.status == "building") && s.problems.length == 0).map((s) => s.spec)')
fi
while IFS= read -r x; do items+=("handoff $x"); done < <(readiness | json -r --each '
  Object.keys($).filter((i) => $[i].small && !$[i].archived && !/^rejected/.test($[i].status_now)).sort()
    .filter((i) => !/^done/.test($[i].status_now) || Object.values($).some((w) => !w.small && w.spec == "" && w.depends_on.includes(i) && !/^(done|rejected)/.test(w.status_now)))')
export CABINET_RUN_LIMIT="$limit" CABINET_RUN_SINCE="$(date +%s)" CABINET_RUN_SCHEDULED=1
local -a lines
lines=()
for item in ${items[@]+"${items[@]}"}; do
  key="${item#* }"
  case "$item" in spec*) x="${key#specs/}"; mark="$LOGDIR/run-spec-${x%.md}.stopped" ;; *) mark="$LOGDIR/run-$key.stopped" ;; esac
  if [[ -f "$mark" ]]; then lines+=("- $key: skipped, stopped on $(cut -d' ' -f1 "$mark") for you: $(cut -d' ' -f2- "$mark") Once settled, run it by hand: cabinet ${item%% *} run $key"); continue; fi
  # Chosen outside $( ): bash 3.2 ends a command substitution at a case pattern's ")".
  if [[ "$item" == spec* ]]; then cmd=("$WS/bin/spec.sh" run "$key"); else cmd=("$0" run "$key"); fi
  last="$("${cmd[@]}" 2>&1 | grep -E '^(Stopped|Paused|.* is ready to push)' | tail -1)" || true
  lines+=("- $key: ${last:-no result; see the log}")
  [[ "$last" != Paused* ]] || break
done
((${#items[@]})) || lines+=("- Nothing to move: no work the setting ($CABINET_PIPELINE) allows is waiting.")
spent="$(spend_since "$CABINET_RUN_SINCE")"
report ${lines[@]+"${lines[@]}"} "" "Spent \$$spent of the \$$limit limit for one run."
}

h_run() {
usage="usage: bin/handoff.sh run <ID> [--retries <n>] [--dry-run]"
[[ "${1:-}" != --scheduled ]] || { (($# == 1)) || { echo "--scheduled takes nothing else. usage: bin/handoff.sh run --scheduled" >&2; exit 2; }; h_scheduled; exit $?; }
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
w="$(json -c --arg i "$id" '$[$i] ?? undefined' <<<"$rd")"
[[ -n "$w" ]] || { echo "$id is not in HANDOFFS.md (bin/handoff.sh list)" >&2; exit 1; }
# One builder, and work that is ready to build: what the steps start from.
builder="$(sed -n "/^### $id:/,/^### /s/^- From: .* -> To: //p" HANDOFFS.md | head -1 | sed 's/([^)]*)//g; s/ and /,/g; s/&/,/g' | tr -d '\`' | tr ',' '\n' \
  | while IFS= read -r x; do x="$(lc "$(printf '%s' "$x" | sed 's/^ *//; s/ *$//')")"; [[ -n "$x" ]] && builds_repos "$x" && echo "$x"; done)"
[[ -n "$builder" && "$builder" != *$'\n'* ]] || { echo "$id is not work for one builder: run takes a handoff to one repo or builder" >&2; exit 1; }
has "$(team_roles)" "$builder" || builder="$(owner_of "$builder")"
[[ -n "$builder" ]] || { echo "$id: no role owns its repo in the team table of AGENTS.md" >&2; exit 1; }
[[ "$(json -r '$.small' <<<"$w")" == true || -n "$(json -r '$.spec' <<<"$w")" ]] || { echo "$id is neither --small nor --spec: only work that is ready to build is run (.cabinet/rules/ready-to-build.md)" >&2; exit 1; }
x="$(json -r '$.spec' <<<"$w")"
if [[ -n "$x" ]] && ! "$WS/bin/spec.sh" check "$x" >/dev/null 2>&1; then echo "$x is not ready to build (bin/spec.sh check $x)" >&2; exit 1; fi

mkdir -p -m 700 "$LOGDIR"
local lock="$K/run-$id.lock" log="$LOGDIR/run-$id.log"
if ((dry == 0)); then
  mkdir "$lock" 2>/dev/null || { echo "$id is already being run ($lock; remove the folder if no run is)" >&2; exit 1; }
  trap 'rmdir "$lock" 2>/dev/null || true' EXIT
fi
SPEND_LABEL="$id"
# A stop that needs the owner is remembered, so a scheduled run does not pay for it again; a run by
# hand clears it, the owner having settled it.
mark="$LOGDIR/run-$id.stopped"
((dry)) || [[ -n "${CABINET_RUN_SCHEDULED:-}" ]] || rm -f "$mark"
say() { echo "$*"; ((dry)) || echo "=== $(date '+%F %T') $*" >>"$log"; }
spent() { local c; c="$(json -r --arg i "$id" '$[$i]?.cost_usd ?? undefined' <<<"$(readiness)")"; [[ -n "$c" ]] && printf ', $%.2f so far' "$c"; return 0; }
stop() { say "Stopped: $1"; ((dry)) && exit 1; echo "Log: $log"; printf '%s %s\n' "$(date +%F)" "$1" > "$mark"; exit 1; }
agent() {  # agent <role> <what it does> <prompt>
  if run_over_limit; then say "Paused: this run's cost limit (\$$CABINET_RUN_LIMIT) is reached; the next run goes on from here"; exit 3; fi
  say "$1: $2"
  ((dry)) && exit 0
  AGENT=$1 PROMPT=$3
  run_limited "$CABINET_JOB_TIMEOUT" "the run's time limit (CABINET_JOB_TIMEOUT in cabinet.env)" >>"$log" 2>&1 || stop "$1 did not finish (exit $?): see the log"
}
while :; do
  step=$((step + 1)); ((step <= 30)) || stop "more steps than any piece of work takes; the owner looks at it"
  rd="$(readiness)"
  w="$(json -c --arg i "$id" '$[$i]' <<<"$rd")"
  v="$(json -r --arg i "$id" 'Object.keys($).find((k) => k != $i && !$[k].small && $[k].spec == "" && new RegExp("(^|[^0-9A-Za-z-])" + $i + "($|[^0-9])").test($[k].depends_on)
    && !/^(done|rejected)/.test($[k].status_now))' <<<"$rd")"
  if [[ -z "$v" ]]; then
    case "$(json -r '$.status_now' <<<"$w")" in
      rejected*) stop "$builder sent $id back (its status line says why)" ;;
      done*) stop "$id is done, but no review handoff depends on it: the builder hands on with --depends-on $id" ;;
    esac
    ((built == 0)) || stop "$builder ran but filed no review handoff for $id"
    agent "$builder" "builds $id" "Pick up handoff $id, addressed to you (bin/handoff.sh list $builder), and build it as .cabinet/rules/builders.md says. When its checks pass and it is committed, hand it on for review with bin/handoff.sh add --from $builder --to <every reviewer its subject needs> --depends-on $id, with its evidence, then set $id to done. If it is not ready to build, set $id to rejected with what is missing instead."
    built=1; continue
  fi
  r="$(json -c --arg v "$v" '$[$v]' <<<"$rd")"
  if [[ "$(json -r '$.ready' <<<"$r")" == true ]]; then
    say "$id is ready to push: every reviewer passed $v$(spent). Push it from your terminal; chief-of-staff closes $v once it is pushed."
    rm -f "$mark"; exit 0
  fi
  [[ "$(json -r '$.ready ?? null' <<<"$r")" != null ]] || stop "$v needs no review, so there is nothing to run"
  if [[ "$(json '$.blocking.length' <<<"$r")" != 0 ]] && ((fixed == 0)); then
    # The loop breaker: a reviewer's BLOCK or CHANGES are counted over every run (blocks, from git's
    # history of HANDOFFS.md), so one past --retries goes to the owner, though this run fixed nothing yet.
    rounds=$((rounds + 1))
    ((rounds <= retries)) || stop "$(json -r '$.blocking.join(", ")' <<<"$r") still block $v after $retries fix round(s): the owner decides (fix it, change the work, or override)"
    x="$(json -r --argjson n "$retries" '$.blocking.filter((b) => ($.blocks[b] ?? 0) > $n).map((b) => b + " has blocked it " + $.blocks[b] + " times").join(", ")' <<<"$r")"
    [[ -z "$x" ]] || stop "$x on $v, more than --retries allows ($retries): the owner decides (fix it another way, change the work, override the BLOCK, or drop it)"
    agent "$builder" "fixes what $(json -r '$.blocking.join(", ")' <<<"$r") blocked, round $rounds" "Handoff $v, your work for $id, has a BLOCK or CHANGES from $(json -r '$.blocking.join(", ")' <<<"$r"): their notes (the Verdict lines on $v) say what to fix. Fix it in your repo with a test, commit, and attach new evidence to $v (bin/handoff.sh attach $v <file or URL> --from $builder) when what people see changed. The reviewers check again after you."
    fixed=1; continue
  fi
  todo="$(json -r --each '[...new Set([...$.blocking, ...$.stale, ...$.missing])].sort()' <<<"$r")"
  [[ -n "$todo" ]] || stop "$v is not ready, and no reviewer is waiting: see bin/handoff.sh list --json"
  for x in $todo; do
    before="$(json -c --arg x "$x" '$.verdicts.filter((w) => w.role == $x)' <<<"$r")"
    agent "$x" "verifies $v" "Verify handoff $v as your role says, then record your verdict with bin/handoff.sh record $v --role $x PASS|BLOCK|CHANGES --commits <every commit of the work> --note <your note>."
    [[ "$(json -c --arg x "$x" --arg v "$v" '$[$v].verdicts.filter((w) => w.role == $x)' <<<"$(readiness)")" != "$before" ]] || stop "$x recorded no verdict on $v"
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
