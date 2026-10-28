# Seats

Read with `CABINET.md`, which every rule here builds on. For chief-of-staff, every lead, and any agent that proposes, onboards, reviews or drafts a role.

A seat is an agent or a person; the rules are the same for both.

**Spotting the need.** chief-of-staff owns it; any lead may propose a seat at any time.

- Daily, the brief flags signs that a seat may be needed, from the work and from the project itself: recurring work no seat owns; a function falling behind (stale handoffs or a growing backlog for one seat); a planned stage reached; and what the project has that no seat looks after: a surface (a public website, an app, an API others use), an audience or channel (users who need support, search traffic, a mailing list, paid plans), or a goal the owner stated in `AGENTS.md`, the specs or the roadmap. Each with the evidence that shows it (the repo, file, spec or goal; the handoffs and dates), never an invented threshold. One gap needs no other evidence: product repos with no code-reviewer on the team, since nothing else reviews the code itself and an owner who does not read code would never see it. A seat the owner declined is recorded in `notes/seats.md` with its date and proposed again only with new evidence.
- The kit keeps a small core of roles and ships none for each specialty: a seat the project needs is proposed from this evidence and drafted for this project ("Drafting a role"), so the team grows with the project instead of being defined in advance.
- Monthly, on the first day of the week that `AGENTS.md` names (Monday when it names none) in the first week of the month, a short org review by chief-of-staff with finance: whether every seat still earns its place (keep, change its authority, or retire it), and the gaps from the daily signals.

**Proposal.** Every new seat reaches the owner as one decision in the sign-off queue format: the need, the evidence, agent or person, the cost (from finance, `TBD` until priced), the alternatives (absorb the work into an existing seat, wait, or hire a person), the expert recommendations, and whether it can be undone. If `AGENTS.md` sets an affordability rule, the proposal shows that check. Every seat is the owner's sign-off.

**Onboarding.** The lead the seat reports to owns its onboarding and first month; security sets up and limits its access to what the seat needs; chief-of-staff tracks each new seat through its checklist in the brief until the one-month review.

Agent seat:
1. Definition and limits written: what it owns, decides, escalates and may write. A kit role may already fit (`cabinet config --roles`, including the optional brand-designer, dba, code-reviewer and auditor); otherwise `cabinet role add <role>` creates and registers it, and it is drafted as "Drafting a role" says.
2. Registered: `roles/<role>.md` (and the role name in `CABINET_ROLES`, then `bin/role.sh build`), the team table in `AGENTS.md`, and `OPERATIONS.md`.
3. Access limited to its own files and repos (security).
4. The push and publish guardrails confirmed for the tool it runs in (`bin/doctor.sh`, "Push guardrails").
5. Trial task, reviewed by its lead.
6. The lead's written corrections recorded into its definition.
7. Review after a month: keep, change or retire.

Person:
1. Contract and accounts as the owner sets them; access set up and limited by security.
2. The push and publish rules (`CABINET.md`, "Rules for every repo"), the brand guide, and the house rules in `AGENTS.md`.
3. Their lead as manager; a first task, reviewed by the lead; the lead's corrections recorded in their role notes.
4. Review after a month: keep, change or retire.

## Sub-teams

A function grows by giving its lead a sub-team: roles that report to the lead and take on part of its work, so no lead becomes the bottleneck as the project grows.

- **When.** The same signals as any seat, for one function: its lead falls behind (stale handoffs, a growing backlog), part of its work needs a specialty the lead lacks, or a new surface arrives (a mobile app for a qa that knows the web). Absorbing the work, waiting, or a person are the alternatives the proposal weighs.
- **How.** A sub-team role is a seat like any other, proposed and approved the same way, then added with `cabinet role add <role> --reports-to <lead> [--covers "<builders or repos>"]` and drafted. Its role file says so under "## Team": `- Reports to: <lead>`, and, for a role that reviews, `- Covers: <builders or repos>` and `- Trial until: <date>` (30 days from when it is added).
- **Reporting.** Its lead owns its onboarding, its corrections and its monthly review, settles its disagreements as the function's lead, and decides its tier 2 questions. The owner still approves any change to its authority.
- **Reviews it covers.** Its verdict counts for its lead's on the work it covers: a handoff from a covered builder or repo needs its PASS where it would need the lead's, and `bin/handoff.sh run` runs it, not the lead. The lead's own PASS always counts too, and until the trial ends the lead's PASS is needed as well. After that, the lead spot-checks its work and records BLOCK where it disagrees; a BLOCK from either holds the push. The lead may extend a trial; ending one early is the owner's call.
- **Work it builds.** A builder's sub-team owns a narrower repo or area in the team table; the most specific row wins (`CABINET.md`, "Ownership"), so routing reaches it with no other change.
- **Passing work down.** A lead given work its sub-team covers files a follow-up handoff to that role instead of doing it, naming the original entry.
- **Shape.** Keep it shallow: a sub-team role may lead its own only when the evidence calls for it, and no role reports to itself through others (`bin/doctor.sh`, `team.reports-to`).

## Drafting a role

A role the owner adds (`cabinet role add <role>`) starts as `roles/<role>.md` with the owner's brief: as much or as little as the owner knew, even only its name. Drafting turns it into a whole role, tailored to this project, without asking the owner for what the project already shows. The agent that drafts it (chief-of-staff through `cabinet role draft <role>`, or the agent the owner asks):

1. **Starts from the owner's brief,** the "The owner's brief" section, and keeps it word for word, with its "## Team" section, if any. What they say wins over everything below. A sub-team role names its lead as the neighbour that settles its disagreements, and says what it covers for the lead ("Sub-teams").
2. **Learns the project first:** `AGENTS.md` (what the project is, its product rules, the team table, the guides), `specs/ROADMAP.md` and the specs, `notes/`, each repo's `README` and `AGENTS.md`, and the roles already on the team in `agents/`.
3. **Writes the role a strong specialist in it would hold on this product,** in the format of the kit's roles (`.cabinet/roles/`): frontmatter (`name`; `description` saying what it does and when to use it; `tools`), "Read `CABINET.md`, then `AGENTS.md`", then the files in `.cabinet/rules/` its job needs (`CABINET.md`, "Start of every session"), then what it owns (paths, repos, areas), what it decides alone (tiers 1 and 2), what it brings to the owner (tier 3), how its work is checked and by whom, what it may write (only what the team table gives it, or areas no row holds), where its work ends and each neighbouring role's begins, naming them, with how a disagreement with each is settled (`CABINET.md`, "When roles disagree"), and the line every reply ends with.
4. **Fits the workflow its job touches,** in the role's own words, so they never contradict `CABINET.md` or these files: every role files handoffs only with `bin/handoff.sh add`. A role that reviews others' work records each verdict with `bin/handoff.sh record <ID> --role <role> ...`, its notes in its own folder under `specs/` (a row in the team table), and qa's evidence rule where it passes what the owner will see. A role that owns a repo is a builder (`.cabinet/rules/builders.md`): it works only from work that is ready (`.cabinet/rules/ready-to-build.md`), writes its plan in a spec routed to it, attaches evidence (`--evidence`, `bin/handoff.sh attach`), sends back what is not ready, and files work for other builders with `--small` or `--spec`. The kit's roles show each in practice. `bin/doctor.sh` notes a drafted role that misses one (`roles.workflow`).
5. **Never widens the kit's limits:** no push, merge on a shared host, deploy, publish or spend, tier 3 to the owner, and the builder never verifies its own work.
6. **Lists every choice the brief did not make** under "## Assumed, for the owner to confirm", one plain line each. chief-of-staff carries them in the sign-off queue; once the owner answers, each line moves into the role (or out of it).
7. **Fills the role's rows** in the team tables of `AGENTS.md` (what it owns) and `OPERATIONS.md` (what it does), runs `bin/role.sh build`, and commits those files alone (`roles: draft <role>`).

The owner can add to the brief at any time and redraft (`cabinet role draft <role>`); a redraft keeps what the owner has confirmed.
