#!/usr/bin/env bash
# Move every closed HANDOFFS.md entry (Status: done or rejected) to
# handoffs/archive-YYYY-MM.md (month of its ID) and commit the move.
# chief-of-staff runs it daily.
# Refuses while HANDOFFS.md has uncommitted lines, so only committed
# closings move and no agent's unsaved update is lost.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
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
            f.write(f"# Closed handoffs, IDs from {month}\n\nMoved from HANDOFFS.md by bin/archive-handoffs.sh. Read only.\n")
        for e in es:
            f.write("\n" + e + "\n")
if moved:  # untouched otherwise, or the next run refuses on its own rewrite
    out = head + sep + preamble.rstrip("\n") + "\n\n" + "\n\n".join(keep) + "\n"
    open(path, "w", encoding="utf-8").write(out)
print(sum(map(len, moved.values())))
EOF
)"

if [[ "$n" == 0 ]]; then echo "nothing to archive"; exit 0; fi
git add -- HANDOFFS.md handoffs
git commit -q -m "handoffs: archive $n closed entries (bin/archive-handoffs.sh)" -- HANDOFFS.md handoffs
echo "archived $n closed entries"
