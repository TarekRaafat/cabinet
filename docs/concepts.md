# Concepts

The ideas cabinet is built on. The rules themselves are in `CABINET.md`, which every workspace gets and every agent reads first; this page explains them for people.

## The team

A workspace runs a product with AI agents, each in a role, and one owner (you) who signs off. The kit's roles:

| Role | Owns | Decides | Brings to you |
|---|---|---|---|
| chief-of-staff | the brief, the sign-off queue, routing tasks, seats | how work is routed | every decision in one queue |
| product-manager | one spec per feature, the roadmap | nothing you have not decided | product decisions, framed with a recommendation |
| architect | contracts between repos, architecture decision records | reversible technical questions across repos | vendors, data handling, public API shapes |
| qa | independent verification | PASS or BLOCK | overrides of a block |
| security | security and privacy review of unpushed work | PASS or BLOCK | legal and disclosure questions |
| design-lead | UX and visual consistency inside the brand guide | layout and interaction choices | any brand change |
| finance | cost and pricing models | how to model | every price, plan and spend |
| brand-designer (optional) | brand files and the graphics made from them | choices inside the approved brand | any change to the brand, licenses |
| dba (optional) | database health; reviews migrations | PASS or BLOCK on data changes | anything run on a live database |
| code-reviewer (optional) | code review of each change | PASS or CHANGES | overrides of CHANGES |
| auditor (optional) | audits of what is in place | severity of findings | critical findings |
| backend, web, mobile, infrastructure | the product repos the team table assigns each (the builders) | how to build inside a repo, following its own conventions | changes to a repo's stack or tools; applying infrastructure |

Each role's file says what it owns, decides, escalates and may write. A project turns roles on or off (`CABINET_ROLES`; the optional ones are off until turned on), adds notes to one in `roles/<role>.md`, or adds a role of its own: `cabinet role add <role>` takes as little as a name, and an agent drafts the whole role for the project from what the owner said and what the project shows, listing its assumptions for the owner to confirm ([recipes](recipes.md#add-a-role)).

**Builders** are the roles that write the product's code. They are not in `CABINET_ROLES`: a builder is built when it owns a repo in the team table of `AGENTS.md`. When a repo whose owner is `TBD` first arrives on a machine, `bin/bootstrap.sh` gives it the builder it most looks like: `mobile` for an `ios/` or `android/` folder, a `pubspec.yaml`, an Xcode project, or React Native or Expo; `infrastructure` for Terraform, Pulumi, Helm or CDK files; `web` for React, Next, Vue, Svelte, Angular, Astro or Nuxt, or an `index.html`; otherwise `backend`. Change the row to choose another builder, a project role, or `owner`, then `bin/role.sh build`. In a repo that already exists a builder learns how it is built (its `AGENTS.md`, scripts, CI, lint and style) and follows it; only a new, empty repo gets defaults (`CABINET.md`, "Builders").

## Rules, guides and notes

What the agents follow, from the most general to the most specific:

1. `CABINET.md`: how every cabinet workspace runs. From the kit; never edited in a workspace.
2. `AGENTS.md` in the workspace: this project's team, contracts, house rules and product rules, and the "Guides" table.
3. `guides/`: standing documents, such as a brand guide, style guide, policy or business document. Agents read a guide before any work its row in `AGENTS.md` covers. A guide ranks with `AGENTS.md`.
4. `roles/<role>.md`: what this project adds for one role, built into that role's definition.
5. A repo's own `AGENTS.md`: rules for work in that repo.

On a conflict the more specific wins: a repo's `AGENTS.md` over the workspace's `AGENTS.md` and guides, over `CABINET.md`. Nothing can loosen "Never push, merge, publish or release" or "The builder never verifies". `notes/` is different: thinking and decisions on the record, read when relevant, not rules in force. How to add each: [recipes](recipes.md#add-your-own-rules-guidelines-and-business-documents).

## Repo ownership

Each repo has one owning agent, listed in the team table in `AGENTS.md`. No agent writes to a repo it does not own. When a change affects another repo, the agent files a handoff instead of editing it.

## Handoffs

`HANDOFFS.md` is the one channel between agents. Each entry has an ID (`H-20261018-01`), who it is from and to, a status (`open`, `acknowledged`, `done`, `rejected`), what changed, what is needed, and what it depends on. The addressee edits only the status line; everyone else adds a follow-up entry. Closed entries move to `handoffs/archive-YYYY-MM.md` daily. `bin/handoff.sh add` files an entry with the next free ID and commits it; `bin/handoff.sh list <name>` shows an agent its open entries.

## Decision tiers

Every decision belongs to exactly one tier:

1. **The agent:** reversible and inside its own files, following existing rules.
2. **The function's lead:** reversible, crosses repos or sets direction, costs nothing.
3. **You:** irreversible, public, or costs money. Pushes, deploys, publishing, prices, spend, brand, legal, and adding or changing an agent.

An agent unsure of the tier treats it as the higher one. A reversible tier 3 item marked "default" may go ahead as local commits after 72 hours without an objection, but nothing is ever pushed, published or spent on silence.

## The brief and the sign-off queue

The chief-of-staff writes `BRIEF.md` on a schedule (`jobs/brief.job`). It verifies handoffs against git, checks the repos and the doctor, and puts every decision waiting on you at the top. Each decision has a plain question, lettered options with their consequences, each expert's recommendation, one overall recommendation, and whether it can be undone. You answer in one message; the agents apply your answers. Its parts sit under fixed headings (`## Sign-off queue`, `## Actions for the owner`, ...), so with several projects `cabinet digest` gathers every queue into one read. On a day when nothing changed (no commit, no new doctor problem, no answer, no work left uncommitted, no reversible item waiting for its 72 hours), the scheduled brief starts no agent and the last brief stands, for up to six days in a row ([quiet days](commands.md#jobsltjobgtjob)).



## Writing to the owner

How agents write to you is a house rule in `AGENTS.md`, asked at setup and by `cabinet config`, or set with `--writing` on `cabinet new`, `init` or `config`. `standard` is the sign-off format in plain words. `short` is for an owner with little time to read, or who reads best in small pieces (for example with ADHD): the same facts and decisions in fewer words.

- The answer, or what is needed from you, comes first, in one sentence.
- One point per line, with the word that matters in bold; three points at most, then "N more: ask".
- A decision in three lines: the question, the options on one line, the recommendation with whether it can be undone.
- No background unless you ask; plain words; how long an action takes, when known.
- The brief opens with what waits today ("Today: 2 decisions, 1 action, about 5 min."). The sign-off queue stays complete, and no warning about anything irreversible, money, security or data loss is ever cut.

The rules are in `CABINET.md`, "Writing to the owner", which every agent reads. Ask any agent for details on a point and it gives them.
## What agent runs cost

Every agent run costs money, as API spend or against a subscription's limits. Cabinet counts what its own runs cost (scheduled jobs and `cabinet role draft`), as the agent tool reports it, in `spend.tsv` in the workspace's log folder, on this machine only. Of the runners, `claude` reports it (the cost Claude Code gives for each headless run, which on a subscription is what the run would cost through the API); the others do not yet, and the doctor says so when a budget is set (`spend.unreported`). Sessions you or a teammate run in an agent tool are not counted, nor is a run stopped by its time limit.

- Each job's log ends a run with its cost and the week's.
- `cabinet job list` shows what each job cost this week, and the week's total.
- `cabinet digest` shows each project's week against its budget, and the total across every project on this machine.
- Setup asks for a weekly budget in US dollars when the runner is `claude`; `cabinet config --budget 20` sets or changes it. From 80% of it, the doctor reports `spend.budget`, so the brief lists it under "Actions for the owner"; past it, the doctor says so. Nothing is stopped: you decide whether to raise the budget, run jobs less often, or let the week end. The week starts on the day `AGENTS.md` names (Sunday by default).

Two settings keep the cost down: a brief that skips its agent on [quiet days](commands.md#jobsltjobgtjob), and fewer scheduled jobs.
## The builder never verifies

Work is ready for you to push only when qa and security have each recorded PASS on its handoff, and so has every other reviewer you enabled whose subject it touches (design-lead for anything people see, code-reviewer for code, dba for the database). A BLOCK, or a code-reviewer's CHANGES, holds the push until it is fixed or you override it.

## Seats

A seat is a role filled by an agent or a person. The chief-of-staff flags signs that a seat is needed (recurring work no seat owns, a function falling behind) with evidence only, and every new seat is your decision, with its cost and the alternatives. Each new seat goes through an onboarding checklist and a review after a month.

## Slugs and isolation

Every workspace has a slug. Everything it puts on the machine is named by it: schedules `ai.cabinet.<slug>.<job>`, its log folder `<slug>/` (below), the backup key `cabinet.<slug>.backup`, archives `<slug>-<YYYYMMDD>-<HHMMSS>.tar.gz.enc`. The log folder holds a `workspace` file naming its owner. Setup and `cabinet config` refuse a slug another workspace holds, bootstrap never replaces or removes a schedule that runs another workspace, and backup cleanup removes only the slug's own archives. Paths are compared with symlinks resolved, so a workspace reached through a link is still the same one.

## macOS and Linux

cabinet works the same on both. Only where it keeps things on the machine differs, and one file, `bin/platform.sh`, decides it:

| | macOS | Linux |
|---|---|---|
| Schedules | launchd: `~/Library/LaunchAgents/ai.cabinet.<slug>.<job>.plist` | systemd user timers: `~/.config/systemd/user/ai.cabinet.<slug>.<job>.service` and `.timer`. On a machine that did not boot with systemd (many containers, older WSL): cron, as one block cabinet writes into your crontab from `~/.config/cabinet/cron/`, keeping every line of your own. |
| Log folder | `~/Library/Logs/cabinet/<slug>/` | `~/.local/state/cabinet/<slug>/` (under `$XDG_STATE_HOME` when set) |
| Backup passphrase | the login keychain | the secret store, through `secret-tool` (`libsecret-tools` on Debian and Ubuntu); with cron, a file only you can read: `~/.config/cabinet/passphrases/cabinet.<slug>.backup` |
| Notifications | Notification Center | `notify-send` |

`CABINET_SCHEDULER` (`launchd`, `systemd`, `cron` or `none`) overrides the choice. On Linux:

- systemd runs a user's timers only while that user is logged in, unless lingering is on: `loginctl enable-linger "$USER"` once, on a server or a machine you leave logged out. A timer missed while the machine was off runs when it starts again, as launchd does after sleep.
- The secret store needs a desktop session. Without one, give scheduled backups the passphrase through systemd instead: `read -rs CABINET_BACKUP_PASSPHRASE; export CABINET_BACKUP_PASSPHRASE; systemctl --user import-environment CABINET_BACKUP_PASSPHRASE` (until the user's systemd stops; run it again after a restart). Cron jobs reach neither, so with cron the passphrase is kept in a file only you can read, `~/.config/cabinet/passphrases/cabinet.<slug>.backup` (under `$XDG_CONFIG_HOME` when set; `bin/bootstrap.sh` prints the command that writes it). On any machine that file, when it exists, comes before the keychain or secret store, and one that other users can read is never used.
- Run `cabinet bootstrap` as yourself, not through `sudo`: schedules are per user.

## Agent tools and models

cabinet works through agent tools, so it works with any model they offer. Everything is plain files: any tool that reads `AGENTS.md` can run the team, and acting as a role means reading `agents/<role>.md`. Scheduled jobs run with the tool in `CABINET_RUNNER`. Which tools have guardrails, and their limits: [guardrails](guardrails.md).

| Runner | Runs a job as |
|---|---|
| `claude` | `claude -p --agent <role> --permission-mode auto` (tested with real scheduled jobs) |
| `codex` | `codex exec "<role instruction> <prompt>"` |
| `gemini` | `gemini -p "<role instruction> <prompt>"` |
| `qwen` | `qwen --approval-mode auto "<role instruction> <prompt>"` |
| `grok` | `grok -p "<role instruction> <prompt>" --permission-mode auto` |
| `opencode` | `opencode run "<role instruction> <prompt>"` |
| `cursor` | `cursor-agent -p --force "<role instruction> <prompt>"` (run live) |
| `custom` | `CABINET_RUNNER_CMD`, with the prompt in `$CABINET_PROMPT` and the role in `$CABINET_AGENT` |

The role instruction is "Act as the <role> role: read agents/<role>.md and follow it as your instructions". Runners other than `claude` and `cursor` follow each tool's documented headless mode and are untested end to end; Codex's default sandbox and Gemini's default approvals may not let a scheduled brief write its file. Scheduled jobs get a PATH with the runner's and Node's folders.
