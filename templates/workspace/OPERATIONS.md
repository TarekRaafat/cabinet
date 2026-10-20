# @@PROJECT@@ operations manual

The owner's handbook: how to run @@PROJECT@@ day to day with the agent team. The rules agents follow live in `CABINET.md` and `AGENTS.md`; this file is for you. Keep it current: any change to `bin/`, `jobs/` or the roles updates this file in the same commit, and `bin/doctor.sh` checks that every script, job and role is named here.

`$WS` below means the workspace: the folder holding this file.

## 1. How the organization works

You sign off; the team runs the rest. Every decision belongs to one of three tiers (`CABINET.md`, "Decision rights and sign-off").

| Tier | Who decides | What |
|---|---|---|
| Agent | The agent itself | Reversible and inside its own repo or files, following existing rules. |
| Lead | The function's lead | Reversible, crosses repos or sets direction, costs nothing. Logged in a spec, an ADR or a verdict. |
| You | Owner sign-off | Irreversible, public or costs money: pushes, deploys, publishing, prices, spend, brand, positioning, legal, and adding or changing an agent. |

- **One queue.** Everything waiting on you is at the top of `$WS/BRIEF.md`, written by chief-of-staff each morning (`jobs/brief.job`).
- **Nothing ships unverified.** Work is ready to push only when qa and security have both passed it, and every other reviewer you enabled whose subject it touches (design-lead for UI, code-reviewer for code, dba for the database).
- **Silence.** A reversible item marked "default" may go ahead as local commits after 72 hours. Never a push.

### The team

| Role | What it does |
|---|---|
| chief-of-staff | The daily brief, your sign-off queue, routing tasks, seats and onboarding |
| product-manager | Feature specs and the roadmap |
| architect | Contracts between repos, ADRs, technical direction |
| design-lead | UX and visual consistency inside the brand guide |
| qa | Verifies finished work; can block a push |
| security | Security and privacy review before a push; can block it |
| finance | Pricing and unit economics; proposes prices, decides none |
| brand-designer | Logos, graphics and templates inside the brand; drafts the brand guide for you to decide |
| dba | Reviews every migration; database performance, backups and access plans |
| code-reviewer | Reviews each change's code before a push; can hold it |
| auditor | Audits dependencies, access, personal data and configuration; changes nothing |

**Builders.** Each product repo is built by a builder role: backend (servers and APIs), web (what runs in a browser), mobile (iOS and Android apps) or infrastructure (CI, deploys, infrastructure as code; it plans, and applying is yours). `bin/bootstrap.sh` picks one for each repo whose owner is `TBD` in the team table of `AGENTS.md`, from what the repo holds; change the row to choose another, then `bin/role.sh build`. Builders follow the way each repo is already built, commit locally, and hand finished work to qa; they never verify their own work and never push.

To call one, start an agent session in `$WS` and name it ("use the qa agent to ..."), or `claude --agent qa`. In another tool: "act as the qa role in agents/qa.md".

## 2. Daily (5 to 10 minutes)

- [ ] **Read the queue.** Open `$WS/BRIEF.md`. The sign-off queue is first, numbered.
- [ ] **Answer in one message** in a session in `$WS`, for example: "chief-of-staff: approve 1, 3. 2: no. 4: hold until Friday."
- [ ] **Push what is ready** (section 3), if the brief lists anything with qa and security PASS.

> **No brief this morning?** Read `brief.log` in the log folder (`~/Library/Logs/cabinet/@@SLUG@@/` on macOS, `~/.local/state/cabinet/@@SLUG@@/` on Linux), or run it now: `$WS/bin/job.sh run brief`.

## 3. Releasing (pushing)

Only you push. Every push asks you to type `yes` at the terminal; agents cannot push at all.

```sh
git -C <repo> log --oneline @{u}..
git -C <repo> push
```

## 4. Weekly

- [ ] Clear the whole sign-off queue.
- [ ] Spot-check one lead's reasoning: a spec's Decisions table, an ADR, or a verdict.
- [ ] Run `$WS/bin/doctor.sh` and fix every FIX line.
- [ ] Push the workspace, if it has its own remote: `git -C $WS push`. (A shared `cabinet/` inside a project is pushed with the project.)

## 5. Commands

| Command | What it does |
|---|---|
| `bin/doctor.sh` | Checks everything: repos, roles, kit files, guardrails, the manual, schedules, backups. Start here when something feels off. |
| `bin/handoff.sh list [name]` | Every open handoff with its age; with a repo or role name, every entry addressed to it, in full. |
| `bin/handoff.sh add --from <name> --to <name> --changed "..." --needed "..." "<title>"` | Files a handoff with the next free ID and today's date, and commits it. |
| `bin/spec.sh check [spec]` | Checks each spec against its status: ready needs testable criteria qa passed, no `TBD`, every decision answered; building also a plan. |
| `bin/spec.sh record <spec> --role qa\|architect PASS\|BLOCK --note <file>` | Records qa's review of a spec's acceptance criteria, or architect's of its plan. |
| `bin/handoff.sh archive` | Moves closed handoffs to `handoffs/archive-YYYY-MM.md` and commits the move. |
| `bin/role.sh draft <role>` | Drafts a role you added with `cabinet role add`, from your brief and the project (it runs the agent tool). |
| `bin/role.sh build [--check]` | Builds `agents/` and `.claude/agents/` from the kit's roles and `roles/`. |
| `bin/job.sh run <job>` | Runs a job from `jobs/` now (for example `brief`). |
| `bin/role.sh list`, `bin/repo.sh list`, `bin/job.sh list` | The team, the repos, the jobs. |
| `bin/bootstrap.sh [--dry-run]` | Sets up a machine: clones repos, restores local-only files, installs guardrails and schedules. Safe to rerun. |
| `bin/secret.sh check [--staged]` | Looks for keys, tokens and passwords in the workspace's files; the pre-commit hook refuses a commit that adds one. A false alarm: add `not-a-secret` to its line. |
| `bin/repo.sh snapshot` | Copies each repo's local-only files into `local/`. The backup runs it for you. |
| `bin/backup.sh create [dir]` | One encrypted backup now. |
| `bin/backup.sh verify [dir]` | Checks that the newest backup restores (once a quarter). |
| `bin/backup.sh restore <archive> [dir]` | Rebuilds everything from a backup. Never loses a file: anything it would replace with different content is copied to `recovered/` first. |
| `bin/move.sh <new-path> [--dry-run]` | Moves the workspace and updates everything that remembers its path. |
| `cabinet config` | Changes settings after setup: the same questions, current answers as defaults; then updates schedules and repos. |
| `cabinet update` | Updates this workspace to the installed kit's version (run from `$WS`; see the kit's README). |

### Schedules

| Job | When | Log |
|---|---|---|
| `ai.cabinet.@@SLUG@@.brief`: chief-of-staff brief | `WHEN` in `jobs/brief.job` | `brief.log` in the log folder |
| `ai.cabinet.@@SLUG@@.backup`: encrypted backup, when `CABINET_BACKUP_DIR` is set | `CABINET_BACKUP_TIME` in `cabinet.env` | `backup.log` in the log folder |

Schedules are launchd jobs on macOS and systemd user timers (or cron) on Linux; the log folder is `~/Library/Logs/cabinet/@@SLUG@@/` on macOS and `~/.local/state/cabinet/@@SLUG@@/` on Linux.

```sh
bin/job.sh list          # each job and its schedule
bin/job.sh run brief     # run one now
bin/doctor.sh            # is each one scheduled and loaded
```

### Secrets

- Backup passphrase: the item `cabinet.@@SLUG@@.backup` in the keychain (macOS) or the secret store (Linux), and your password manager.
- Production secrets: your password manager only. Never in a repo, a note or a handoff.

## 6. When something goes wrong

| Situation | Do this |
|---|---|
| Lost or broken machine | Passphrase into the keychain or secret store, `bin/backup.sh restore` the newest archive, `bin/bootstrap.sh`, `bin/doctor.sh`. |
| A secret leaked | Rotate it at the provider first, then tell security to find every place it appeared. Never push a commit containing it. |
| An agent did something wrong | It is a local commit until you push: `git -C <repo> revert <commit>`. Then narrow its authority in `roles/<role>.md`. |
| A schedule stopped | `bin/doctor.sh`, then the job's log in the log folder (section 5, Schedules). |
