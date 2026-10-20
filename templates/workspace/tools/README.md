# tools/

The project's own scripts: a report, a deploy helper, a data check, the check a critical area runs. Updates of the kit never touch this folder (the kit's scripts live in `bin/`, which they replace).

- **Name each one in `OPERATIONS.md`,** with what it does: `cabinet doctor` reports a script here that the manual does not name.
- **Call them from anywhere the project runs commands:** a job's `COMMAND` or `AFTER` (`jobs/<job>.job`), or the "Check" of a critical area in `AGENTS.md`, which `bin/handoff.sh record` runs before a reviewer's PASS counts.
- **A check** runs in the workspace with `CABINET_AREA`, `CABINET_HANDOFF` and `CABINET_COMMITS` (comma separated) set, and passes by exiting 0. What it prints is kept as evidence on the handoff.
- **Keep them safe to run unattended:** no secrets in them, nothing pushed or published.
