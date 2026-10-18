# notes/

The owner's notes: thinking, decisions, customer conversations and research that agents should be able to read. Plain markdown, edited in any editor.

## What goes here

- Decisions and the reasoning behind them ("why we chose X over Y").
- Customer and dogfooding notes (calls, feedback, what we learned).
- Strategy, pricing and positioning thinking before it is final.
- Research and reading notes worth keeping.
- Meeting notes with outcomes.

## What does not go here

- Work for an agent. That is a `HANDOFFS.md` entry, so it gets tracked to done. A note can link to the entry.
- Rules every agent must follow. Once a decision becomes a rule, it goes into `AGENTS.md` (or a repo's `AGENTS.md`), or into a guide in `guides/` when it is a whole document, and the note gets `status: superseded` or stays as the record of why.
- Brand content. The brand guide `AGENTS.md` names is canonical; brand thinking can start here, then goes to the owner as a change to it.
- Secrets, keys, passwords.

## How to write one

1. Copy `_template.md` to `YYYY-MM-DD-short-topic.md` (for example `2026-10-05-pricing-tiers.md`). One topic per file.
2. Fill the frontmatter. `status` matters most: agents treat `draft` as thinking, `decided` as settled, `superseded` as history only.
3. Write freely. Short and messy is fine; the "Decision" and "Open questions" sections are what agents look for.
4. Link related notes by file name, and handoffs by ID (`H-20261003-05`).

## How agents use it

Agents do not read this folder every session. They read a note when you point them at it ("read notes/2026-10-05-pricing-tiers.md") or when their task touches a topic listed in a note's `repos` or `topic`. They search with plain grep, so clear titles and topics make notes findable. Agents edit notes only when you ask them to.

Useful asks:

- "Read notes/ and tell me what I decided about X."
- "Summarize this call into a new note."
- "Which `draft` notes are older than a month?"
- "Turn the decision in notes/<file> into handoffs."
