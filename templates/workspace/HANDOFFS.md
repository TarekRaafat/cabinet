# HANDOFFS.md - @@PROJECT@@

The one channel between agents. Rules are in `CABINET.md` ("Handoffs"). Newest entries at the bottom of "Open". Closed entries move to `handoffs/archive-YYYY-MM.md` (`bin/archive-handoffs.sh`).

File an entry with `bin/handoff.sh` (it picks the next free ID and commits it), or by hand from the template below.

Status values: `open`, `acknowledged`, `done`, `rejected`. The addressee edits only the status line. Everyone else adds follow-up entries instead of rewriting.

## Template

```
### H-YYYYMMDD-NN: <short title>
- From: <repo or role> -> To: <repo, role or owner>
- Status: open (YYYY-MM-DD)
- Changed: <exactly what changed: endpoint, field, limit, status code, default, version, file>
- Needed: <what the addressee has to do>
- Depends on: <commit or branch on the sender's side, or "none">
```

## Open
