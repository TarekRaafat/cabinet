# AGENTS.md - @@PROJECT@@

Read `CABINET.md` first: it says how this workspace runs (handoffs, decision tiers, the sign-off queue, seats, git rules). This file holds what is specific to @@PROJECT@@ and wins on anything project-specific. Each repo's own `AGENTS.md` wins on anything specific to that repo.

## What @@PROJECT@@ is

TBD: one paragraph, written by the owner. What the product is, who it is for, and the words every agent must use (and never use) for it.

## The team: repos and owners

Each agent owns its repos end to end, documentation included. No agent writes to a repo it does not own; reading any repo is always fine.

| Repo or area | What it is | Owning agent |
|---|---|---|
| workspace (this folder) | Coordination: `HANDOFFS.md`, the brief, routing owner tasks | chief-of-staff |
| `specs/` | One spec per feature and the ranked `specs/ROADMAP.md` | product-manager |
| `specs/adr/` | Cross-repo contracts and architecture decisions | architect |
| `specs/qa/` | Independent verification, PASS or BLOCK | qa |
| `specs/security/` | Security and privacy review, PASS or BLOCK | security |
| `specs/design/` | UX and visual consistency inside the brand guide | design-lead |
| `finance/` | Pricing and unit economics; decides no price | finance |
| `brand/` | The brand identity's files and the graphics made from it | brand-designer |
| `specs/db/` | The databases' health: migration reviews, performance, backups and access plans | dba |
| `specs/reviews/` | Code review of each change, PASS or CHANGES | code-reviewer |
| `specs/audits/` | Audits of what is in place: dependencies, access, personal data, configuration | auditor |

Add one row per product repo (and list it in `repos.tsv`). A repo whose owning agent is `TBD` gets a builder (`backend`, `web`, `mobile` or `infrastructure`, by what the repo holds) from `bin/bootstrap.sh` when it first arrives; change it to another builder, a project role, or `owner` for a repo only you change. Remove the rows of roles this project does not enable in `cabinet.env`.

## Contracts that cross repo lines

A change on one side is not done until every side agrees. The side that changes files the handoff.

| Contract | Repos that move together | Source of truth |
|---|---|---|
| TBD | | |

## House rules

The owner's defaults for every repo. Change them here. The kit changes this file only when you run `cabinet config` (the owner line, the week start and the titles).

- **Commits.** Authored as @@OWNER_NAME@@ <@@OWNER_EMAIL@@>. No AI or tool attribution of any kind (no `Co-Authored-By`, no "Generated with" line). Follow each repo's message style.
- **ASCII punctuation only.** No em or en dashes, no curly quotes, anywhere (code, docs, copy, commits).
- **Dates and times people read:** `10 Oct 2026`, `2:30 PM`, `10 Oct 2026, 2:30 PM`, ranges `10 to 14 Oct 2026`. Machine formats stay ISO 8601 (API fields, file names, database values, logs, code).
- **Week starts on:** Sunday. Weekly jobs and resets use it.
- **No internal references in public artifacts:** no roadmap items, planning notes, workspace paths or local file names in anything published.
- **Brand guide:** TBD (for example `guides/brand.md`, with a row under "Guides"). Canonical for voice and visual identity; changes go to the owner.

## Product rules

TBD: the rules every agent must follow for this product (what it must never do, what needs a stricter gate, what every feature must work for). Product-manager checks each spec against them.

## Guides

Standing documents every agent follows when its work touches their subject: brand, style, policies, business documents. Each lives in `guides/` (see `guides/README.md`); a row here is how agents know it exists. Read a guide before any work its row covers. A guide ranks with this file.

| Guide | What it covers | Who follows it |
|---|---|---|
| none yet | Add a file to `guides/`, then a row here: `` `guides/<file>` ``, its subject, and every agent or the roles that follow it. | |

## How to test

TBD: how qa runs the product locally (services, local database, test account), and what must never be touched (production, shared databases).

## Open items for the owner

Tracked in `HANDOFFS.md` as entries addressed to `owner`, and collected in the sign-off queue at the top of `BRIEF.md`.
