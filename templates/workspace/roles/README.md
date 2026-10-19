# roles/

This project's notes for each role. `bin/roles.sh` appends `roles/<role>.md` to the kit's definition of that role under "Project notes", and writes the result to `agents/<role>.md` and `.claude/agents/<role>.md`. Never edit those two: they are rebuilt.

- **A note for a kit role** (`roles/qa.md`): plain markdown, no frontmatter. What this project adds: paths, duties, limits.
- **A role the kit does not have** (`roles/growth.md`): a whole definition with frontmatter (`name`, `description`, `tools`), like the kit's roles in `.cabinet/roles/`. `cabinet role new <role>` makes and registers one from a short brief. A whole role always wins: if a later kit adds a role with the same name, yours is still used as it is, and `bin/doctor.sh` says so.
- **Turning a role on or off:** `cabinet config --roles "..."` does it all; by hand, edit `CABINET_ROLES`, run `bin/roles.sh`, and update the team tables in `AGENTS.md` and `OPERATIONS.md`.

Adding, changing or removing a role or its authority is the owner's decision (`CABINET.md`, "Seats").
