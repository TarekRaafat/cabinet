#!/usr/bin/env bash
# Specs, one per feature in specs/ (CABINET.md, "Ready to build").
#
#   bin/spec.sh check [spec] [--json]
#       Every spec (or one) against what its status needs. ready: acceptance criteria, no TBD in
#       Rules, every decision answered, its repos named, and a qa PASS on the acceptance criteria as
#       they are now. building: also a plan for each repo ("### <repo>" under "## Plan"), and, for
#       more than one repo, an architect PASS on the plan as it is now. draft, shipped and dropped
#       need nothing. Prints each spec with its problems; exit 1 when any has one.
#       --json: [{spec, status, problems}].
#   bin/spec.sh record <spec> --role qa|architect <PASS|BLOCK> --note <file>
#       A review of a spec: qa of its acceptance criteria (can each be tested?), architect of its
#       plan. Writes, or replaces, the role's "- Verdict:" line under "## Reviews" with today's date
#       and a fingerprint of the part reviewed, so a later change to it needs a new review, and
#       commits the spec. The spec and the note must be committed.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# spec_py check <spec>... | record <spec> <role> <verdict> <date> <note>: reads and writes specs.
spec_py() {
  python3 -I - "$WS" "$@" <<'PY'
import hashlib, json, os, re, sys
ws, mode, args = sys.argv[1], sys.argv[2], sys.argv[3:]
PART = {"qa": "Acceptance criteria", "architect": "Plan"}
# Guidance copied from the template is not content: "Anything not decided is TBD ..." is no TBD.
try:
    PLACEHOLDERS = {l.strip() for l in open(os.path.join(ws, "specs", "_template.md"), encoding="utf-8")
                    if l.strip() and not l.startswith(("#", "|", "---"))}
except OSError:
    PLACEHOLDERS = set()

def parse(text):
    fm, body = {}, text
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if m:
        for l in m.group(1).split("\n"):
            k, _, v = l.partition(":")
            fm[k.strip()] = re.sub(r"\s+#.*$", "", v).strip()
        body = text[m.end():]
    secs, cur = {}, None
    for l in body.split("\n"):
        if l.startswith("## "):
            cur = l[3:].strip()
            secs[cur] = []
        elif cur is not None:
            secs[cur].append(l)
    return fm, secs

def content(lines):
    return [l.strip() for l in lines if l.strip() and l.strip() not in PLACEHOLDERS]

def fingerprint(lines):
    return hashlib.sha256("\n".join(content(lines)).encode()).hexdigest()[:8]

def repos(fm):
    m = re.match(r"\[(.*)\]$", fm.get("repos", ""))
    return [r.strip().strip("'\"") for r in m.group(1).split(",") if r.strip()] if m else []

def decisions(lines):
    rows = [[c.strip() for c in l.strip().strip("|").split("|")] for l in lines if l.strip().startswith("|")]
    return [r for r in rows[1:] if any(r) and not all(re.fullmatch(r":?-+:?", c) for c in r)]

def plan(lines):
    parts, cur = {}, None
    for l in lines:
        if l.startswith("### "):
            cur = l[4:].strip()
            parts[cur] = []
        elif cur is not None and l.strip():
            parts[cur].append(l)
    return parts

def verdicts(lines):
    v = {}
    for l in lines:
        m = re.match(r"- Verdict: (\S+) (PASS|BLOCK) \d{4}-\d{2}-\d{2} ([0-9a-f]{8}) \S+$", l.strip())
        if m:
            v[m.group(1)] = (m.group(2), m.group(3))
    return v

def problems(text):
    fm, secs = parse(text)
    status, p = fm.get("status", ""), []
    if status not in ("ready", "building"):
        return status, p
    if not content(secs.get("Acceptance criteria", [])):
        p.append("no acceptance criteria")
    if re.search(r"\bTBD\b", "\n".join(content(secs.get("Rules", [])))):
        p.append("TBD left in Rules")
    left = [r for r in decisions(secs.get("Decisions", [])) if not r[-1]]
    if left:
        p.append("%d decision(s) not answered" % len(left))
    rs = repos(fm)
    if not rs:
        p.append("no repos named")
    v = verdicts(secs.get("Reviews", []))
    def review(role):
        part = PART[role]
        if role not in v:
            return "no %s review of the %s" % (role, part.lower())
        if v[role][0] != "PASS":
            return "%s BLOCK on the %s" % (role, part.lower())
        if v[role][1] != fingerprint(secs.get(part, [])):
            return "the %s changed since %s passed it" % (part.lower(), role)
    p.append(review("qa"))
    if status == "building":
        parts = plan(secs.get("Plan", []))
        missing = [r for r in rs if not parts.get(r)]
        if missing:
            p.append("no plan for " + ", ".join(missing))
        if len(rs) > 1:
            p.append(review("architect"))
    return status, [x for x in p if x]

if mode == "check":
    out = []
    for f in args:
        status, p = problems(open(os.path.join(ws, f), encoding="utf-8").read())
        out.append({"spec": f, "status": status, "problems": p})
    print(json.dumps(out))
elif mode == "record":
    f, role, verdict, date, note = args
    path = os.path.join(ws, f)
    text = open(path, encoding="utf-8").read()
    fm, secs = parse(text)
    line = "- Verdict: %s %s %s %s %s" % (role, verdict, date, fingerprint(secs.get(PART[role], [])), note)
    lines = text.rstrip("\n").split("\n")
    if "## Reviews" not in lines:
        lines += ["", "## Reviews", ""]
    i = lines.index("## Reviews") + 1
    end = next((j for j in range(i, len(lines)) if lines[j].startswith("## ")), len(lines))
    part = [l for l in lines[i:end] if not l.startswith("- Verdict: %s " % role)]
    while part and not part[-1].strip():
        part.pop()
    part = (part or [""]) + [line] + ([""] if end < len(lines) else [])
    lines[i:end] = part
    open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
}

s_check() {
local json=0 one="" f
local -a files
files=()
while (($#)); do
  case "$1" in
    --json) json=1; shift ;;
    -*) echo "unknown option $1. usage: bin/spec.sh check [spec] [--json]" >&2; exit 2 ;;
    *) [[ -z "$one" ]] || { echo "one spec at a time. usage: bin/spec.sh check [spec] [--json]" >&2; exit 2; }; one="$1"; shift ;;
  esac
done
if [[ -n "$one" ]]; then
  if [[ -f "$one" ]]; then one="$(cd "$(dirname "$one")" && pwd -P)/$(basename "$one")"; one="${one#"$WS"/}"; fi
  [[ "$one" =~ ^specs/[^/]+\.md$ && -f "$WS/$one" ]] || { echo "no spec $one (a file specs/<feature>.md in the workspace)" >&2; exit 2; }
  files=("$one")
else
  for f in "$WS"/specs/*.md; do
    [[ -f "$f" ]] || continue
    case "${f##*/}" in _template.md|ROADMAP.md) continue ;; esac
    files+=("specs/${f##*/}")
  done
fi
local out='[]'
((${#files[@]})) && out="$(spec_py check "${files[@]}")"
if ((json)); then jq . <<<"$out"
else
  jq -r '.[] | "\(.spec) (\(.status | if . == "" then "no status" else . end)): \(if (.problems | length) == 0 then "ok" else (.problems | join("; ")) end)"' <<<"$out"
  [[ "$(jq '[.[] | select(.problems | length > 0)] | length' <<<"$out")" == 0 ]] && echo "Every spec has what its status needs." \
    || echo "Not ready for their status: fix each problem, or set the spec's status back (draft)."
fi
[[ "$(jq '[.[] | select(.problems | length > 0)] | length' <<<"$out")" == 0 ]]
}

s_record() {
usage="usage: bin/spec.sh record <spec> --role qa|architect <PASS|BLOCK> --note <file>"
local spec="" role="" verdict="" note="" rel
while (($#)); do
  case "$1" in
    --role|--note)
      (($# >= 2)) || { echo "$1 needs a value. $usage" >&2; exit 2; }
      [[ "$1" == --role ]] && role="$(printf %s "$2" | tr '[:upper:]' '[:lower:]')" || note="$2"
      shift 2 ;;
    -*) echo "unknown option $1. $usage" >&2; exit 2 ;;
    *) if [[ -z "$spec" ]]; then spec="$1"; elif [[ -z "$verdict" ]]; then verdict="$(printf %s "$1" | tr '[:lower:]' '[:upper:]')"; else echo "one verdict only. $usage" >&2; exit 2; fi; shift ;;
  esac
done
[[ -n "$spec" ]] || { echo "the spec first. $usage" >&2; exit 2; }
[[ "$role" =~ ^(qa|architect)$ ]] || { echo "--role is qa (the acceptance criteria) or architect (the plan). $usage" >&2; exit 2; }
[[ "$verdict" =~ ^(PASS|BLOCK)$ ]] || { echo "the verdict is PASS or BLOCK. $usage" >&2; exit 2; }
[[ -n "$note" ]] || { echo "--note needs the file that holds the details. $usage" >&2; exit 2; }
spec="$(ws_md "the spec" "$spec")" || exit 1
[[ "$spec" =~ ^specs/[^/]+\.md$ && "$spec" != specs/_template.md && "$spec" != specs/ROADMAP.md ]] || { echo "$spec is not a spec (specs/<feature>.md)" >&2; exit 1; }
rel="$(ws_md --note "$note")" || exit 1
[[ "$rel" != "$spec" ]] || { echo "the note is the review's own file, not the spec" >&2; exit 1; }
spec_py record "$spec" "$role" "$verdict" "$(date +%F)" "$rel"
git -C "$WS" commit -q -m "specs: ${spec#specs/} $role $verdict" -- "$spec" || { echo "recorded on $spec, but the commit failed (see above): commit it yourself" >&2; exit 1; }
echo "$spec: $role $verdict recorded and committed"
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  check) s_check "$@" ;;
  record) s_record "$@" ;;
  *) echo "usage: bin/spec.sh check|record (see the top of this file)" >&2; exit 2 ;;
esac
