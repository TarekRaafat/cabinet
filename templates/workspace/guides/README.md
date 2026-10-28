# guides/

Standing documents every agent follows when its work touches their subject: the brand guide, a writing or code style guide, a security or privacy policy, pricing rules, a customer promise, any business document the team must respect. Unlike `notes/`, which is thinking and decisions on the record, a guide is in force.

## Add a guide

1. Put the file here: `guides/brand.md`, `guides/support-policy.md`. Markdown or plain text works with every agent tool; a PDF works with the tools that read PDFs. Folders are fine (`guides/legal/terms.md`).
2. Add a row for it to the "Guides" table in `AGENTS.md`: the path, what it covers, and who follows it (every agent, or named roles). Agents find guides through that table, so a guide without a row is never read. `cabinet doctor` reports a guide with no row, and a row whose file is missing.
3. Commit the workspace.

To retire a guide, delete the file and its row. To change one, edit it and commit: agents read the current version.

## How agents use them

Agents read the "Guides" table in `AGENTS.md` at the start of every session, and read a guide before any work its row covers. A guide ranks with `AGENTS.md`: it adds to and tightens the kit's rules in `CABINET.md`, a repo's own `AGENTS.md` still wins inside that repo, and no guide can loosen "Never push, merge on a shared host, publish or release" or "The builder never verifies".

Agents edit a guide only when the owner asks: a change to one is the owner's decision.

## What does not go here

- Rules short enough for one line: put them straight into `AGENTS.md` ("House rules", "Product rules").
- Notes for one role: `roles/<role>.md`.
- Thinking that is not settled yet: `notes/`, with `status: draft`.
- Secrets, keys, passwords.
