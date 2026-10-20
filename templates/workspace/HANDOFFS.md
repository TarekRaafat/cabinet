# HANDOFFS.md - @@PROJECT@@

The one channel between agents. Rules are in `CABINET.md` ("Handoffs"). Newest entries at the bottom of "Open". Closed entries move to `handoffs/archive-YYYY-MM.md` (`bin/handoff.sh archive`).

File an entry only with `bin/handoff.sh add` (it picks the next free ID and commits it), never by hand: two agents numbering by hand can take the same ID. The template below shows what an entry looks like.

Status values: `open`, `acknowledged`, `done`, `rejected`. The addressee edits only the status line. Everyone else adds follow-up entries instead of rewriting.

## Template

```
### H-YYYYMMDD-NN: <short title>
- From: <repo or role> -> To: <repo, role or owner>
- Status: open (YYYY-MM-DD)
- Changed: <exactly what changed: endpoint, field, limit, status code, default, version, file>
- Needed: <what the addressee has to do>
- Depends on: <commit or branch on the sender's side, or "none">
- Spec: <specs/<feature>.md it builds (--spec), or instead:>
- Size: small   (--small: one repo, no contract change, no decision for the owner, easy to undo)
- Evidence: <links to what shows the work, from the workspace root (--evidence, later bin/handoff.sh attach); omit the line when there is none>
- Verdict: <role> <PASS|BLOCK|CHANGES> <YYYY-MM-DD> <commits> <note under specs/>   (one per reviewer: bin/handoff.sh record)
```

## Open
