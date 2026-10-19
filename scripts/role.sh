#!/usr/bin/env bash
# Draft, or redraft, a role this project added (roles/<role>.md, made by cabinet role new) with
# the configured agent tool. chief-of-staff starts from the owner's brief in the file, learns the
# project, and writes the whole role as CABINET.md, "Drafting a role", says. It runs the agent
# tool, which may cost money; in an agent session, asking the agent to draft the role does the same.
#
#   bin/role.sh <role>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

role="${1:-}"
[[ "$role" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "usage: role.sh <role>" >&2; exit 2; }
f="roles/$role.md"
[[ -f "$WS/$f" ]] || { echo "no $f: cabinet role new $role makes it" >&2; exit 2; }
head -1 "$WS/$f" | grep -qx -- '---' || { echo "$f is notes for a kit role, not a role of its own" >&2; exit 2; }

cd "$WS"
AGENT=chief-of-staff
PROMPT="Draft the role in $f, as CABINET.md, \"Drafting a role\", says: keep its \"The owner's brief\" section word for word, learn the project, write the whole role in that file, list what you assumed under \"Assumed, for the owner to confirm\", fill its rows in the team tables of AGENTS.md and OPERATIONS.md, run bin/roles.sh, and commit those files alone (roles: draft $role). Change nothing else."
mkdir -p -m 700 "$LOGDIR"; log="$LOGDIR/role-$role.log"
echo "=== $(date '+%F %T') draft $role ($CABINET_RUNNER)" >> "$log"
echo "Drafting $role with $CABINET_RUNNER, as chief-of-staff. It takes a few minutes and prints nothing until it finishes."
run_agent </dev/null 2>&1 | tee -a "$log" || { echo "The draft did not finish: see $log" >&2; exit 1; }
grep -q '^description: TBD' "$f" && { echo "$f is still not drafted (its description is TBD): see $log" >&2; exit 1; }
"$WS/bin/roles.sh" >/dev/null
echo
echo "Drafted $f. Read it, and answer what it lists under \"Assumed, for the owner to confirm\" (the brief carries them too)."
