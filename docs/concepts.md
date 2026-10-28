# Concepts

The ideas Cabinet is built on. The rules themselves are in `CABINET.md`, which every workspace gets and every agent reads first; this page explains them for people.

Cabinet is a productivity kit that makes one person a whole team. It amplifies people and never replaces them: agents bring the skills and the hours, and the owner brings the vision, the judgment and the final say. Alone, you work like a full company; in a team, every member does.

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

**Calling a role from a session.** Scheduled jobs and `cabinet handoff run` start each role for you; in a session of your own, you call one by name. In Claude Code, write `@agent-<role>`, for example `@agent-product-manager`. In every other tool, say it in plain words, such as "As product-manager, read agents/product-manager.md and ...", which runs the role inside the current session.

**Builders** are the roles that write the product's code. They are not in `CABINET_ROLES`: a builder is built when it owns a repo in the team table of `AGENTS.md`. When a repo whose owner is `TBD` first arrives on a machine, `bin/bootstrap.sh` gives it the builder it most looks like: `mobile` for an `ios/` or `android/` folder, a `pubspec.yaml`, an Xcode project, or React Native or Expo; `infrastructure` for Terraform, Pulumi, Helm or CDK files; `web` for React, Next, Vue, Svelte, Angular, Astro or Nuxt, or an `index.html`; otherwise `backend`. In a workspace with its own git, bootstrap commits that change (the team table, `ORG.md`, the built roles) unless those files held uncommitted edits of yours; then, and in a shared `cabinet/`, it leaves them for you to review and commit. Change the row to choose another builder, a project role, or `owner`, then `bin/role.sh build`. In a repo that already exists a builder learns how it is built (its `AGENTS.md`, scripts, CI, lint and style) and follows it; only a new, empty repo gets defaults (the kit's `core/rules/builders.md`, installed as `.cabinet/rules/builders.md`).

## Rules, guides and notes

What the agents follow, from the most general to the most specific:

1. `CABINET.md`: how every Cabinet workspace runs. From the kit; never edited in a workspace. It holds what every agent needs on every session; the detail only some roles or tasks need is in `.cabinet/rules/` (`builders.md`, `ready-to-build.md`, `reviews.md`, `seats.md`), which `CABINET.md` names with when to read each, and each role names the ones its job needs. Every session reads less, and nothing is lost.
2. `AGENTS.md` in the workspace: this project's team, contracts, house rules and product rules, and the "Guides" table.
3. `guides/`: standing documents, such as a brand guide, style guide, policy or business document. Agents read a guide before any work its row in `AGENTS.md` covers. A guide ranks with `AGENTS.md`.
4. `roles/<role>.md`: what this project adds for one role, built into that role's definition.
5. A repo's own `AGENTS.md`: rules for work in that repo.

On a conflict the more specific wins: a repo's `AGENTS.md` over the workspace's `AGENTS.md` and guides, over `CABINET.md`. Nothing can loosen "Never push, merge on a shared host, publish or release" or "The builder never verifies". `notes/` is different: thinking and decisions on the record, read when relevant, not rules in force. How to add each: [recipes](recipes.md#add-your-own-rules-guidelines-and-business-documents).

## Repo ownership

Each repo has one owning agent, listed in the team table in `AGENTS.md`, and so does each workspace area (`specs/`, `specs/qa/`, ...). An area inside another belongs to its own row: the most specific row wins. No agent writes to a repo it does not own. When a change affects another repo, the agent files a handoff instead of editing it. The doctor flags an area with two owners (`team.single-owner`), notes a part of a repo given to another role than the repo's (`team.nested`) and a project role whose "What you may write" reaches another role's area (`roles.writes`), and `cabinet role add --owns` refuses an area that is already another role's.

## Critical areas

Some parts of a project cost more when they go wrong: payments, personal data, a public API, data imports, a store listing, a pricing page. The kit does not know which; you declare them under "Critical areas" in `AGENTS.md`, each with its paths, the reviewers it needs as well as the usual ones, the evidence they must see, and optionally a check, a script of your own in `tools/` that proves what a script can (a replay of saved inputs, an API comparison, a load test). Work touching an area, by its commits or by its spec's `areas`, is not ready to push until those reviewers pass, and a reviewer's PASS counts only when the check passes; its output is kept as evidence. Nothing changes for a project that declares none.

| Project | Area | Also reviewed by | Evidence | Check |
|---|---|---|---|---|
| SaaS with payments | billing | security, finance | a test payment in the sandbox | a sandbox script |
| Data or analytics product | importers | architect | results compared | replay saved inputs |
| Mobile app | store listing, permissions | design-lead, security | real-device screenshots | none |
| Library | public API | architect | the API diff and version bump | an API diff tool |
| Client work | the deliverable | owner | a preview link | a link checker |
| Business with little code | pricing page | finance | old and new prices side by side | none |

`OPERATIONS.md`, the owner's manual, is also a page: `cabinet manual build` writes `OPERATIONS.html`, with contents, search and tick boxes for the daily and weekly lists, rebuilt after each brief.

`tools/` is the project's own scripts: updates never touch it, the manual names each one (the doctor checks), and jobs and checks call them.

## Ready to build

Nothing is built before it is defined. A small task (one repo, no contract change, no decision for you, easy to undo) goes straight to a handoff that says what done looks like, marked small (`cabinet handoff add --small`). The claim is checked against what was built: a PASS is refused when the commits span repos or change a file a contract lives in or a path listed as hard to undo in `AGENTS.md`, and the doctor flags one already passed (`handoffs.small`). Whether a decision should have been yours, no script can tell: qa blocks that. `cabinet config --hard-to-undo` sets the list, checking each path against the repos and suggesting what looks hard to undo in them. Anything bigger is built from a spec in `specs/`, which the product-manager writes, and a spec moves through statuses that `cabinet spec check` holds to what each needs:

- **draft** while it is written and its decisions wait on you.
- **ready** once it has testable acceptance criteria, nothing `TBD` in its rules, every decision answered, and the repos that build it, and qa has passed the criteria as testable (`cabinet spec record`). For anything people see, the design lead first designs it in the spec (the flows, screens and states) and passes that design. Only a ready spec is routed to builders (`cabinet handoff add --spec`).
- **building** once each builder has written its part of the plan (files, tests, order, risks) and, for work in more than one repo, the architect has passed the plan.
- **shipped** or **dropped** at the end.

Work that changes no repo (copy, research, a campaign) goes the same way with the checks that fit it: what done looks like, evidence of the result, and a verdict with no commits; the checks built on commits apply only to work that has them. A review counts only for what it reviewed: a change to the criteria or the plan after a PASS needs a new one. A builder given work that is not ready sends it back instead of guessing. The doctor flags a spec marked ready or building that lacks what its status needs (`specs.ready`).

## Handoffs

`HANDOFFS.md` is the one channel between agents. Each entry has an ID (`H-20261018-01`), who it is from and to, a status (`open`, `acknowledged`, `done`, `rejected`), what changed, what is needed, what it depends on, and its evidence: links to screenshots, recordings or output that show the work, which the brief carries to you. The addressee edits only the status line; everyone else adds a follow-up entry. Closed entries move to `handoffs/archive-YYYY-MM.md` daily. `bin/handoff.sh add` files an entry with the next free ID and commits it; `bin/handoff.sh list <name>` shows an agent its open entries.

## Decision tiers

Every decision belongs to exactly one tier:

1. **The agent:** reversible and inside its own files, following existing rules.
2. **The function's lead:** reversible, crosses repos or sets direction, costs nothing.
3. **You:** irreversible, public, or costs money. Pushes, deploys, publishing, prices, spend, brand, legal, and adding or changing an agent.

An agent unsure of the tier treats it as the higher one. When two roles disagree, or both think a decision is theirs, the function's lead settles it; across functions, or when whose call it is is unclear, it comes to you as one sign-off item with both views, and neither acts on it meanwhile. A reversible tier 3 item marked "default" may go ahead as local commits after 72 hours without an objection, but nothing is ever pushed, published or spent on silence.

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

## Credit roles

A commit a role makes in a Cabinet run can credit that role beside you. Its message then ends with one line:

```
Co-authored-by: Cabinet backend <347351783+cabinet-team[bot]@users.noreply.github.com>
```

GitHub links that email to the Cabinet Team app, so the commit shows you and `cabinet-team[bot]` with the Cabinet Team avatar; the role's name is in the message. You stay the author and the committer, and you still push. Nothing is set up on GitHub, and nothing is paid for.

- **On for a new workspace** (`on`), asked at setup; `cabinet config --credit-roles off|on` changes it. A workspace from before it stays off: `cabinet next` and the brief ask once, and nothing changes until you answer. In a shared `cabinet/`, each machine answers for itself (`cabinet config --this-machine --credit-roles off|on`), so a teammate's runs credit nothing until they say so; and off for everyone wins: while the project's setting (`cabinet config --credit-roles`) is off or not set, no machine's runs credit, and a machine's on counts only while the project's setting is on.
- **Only commits made in a Cabinet run:** scheduled jobs, `cabinet handoff run`, `cabinet spec run` and `cabinet role draft`, which tell the agent tool the role (`CABINET_AGENT`). Your own commits, and the ones `cabinet` makes for you, get nothing. A session you open in an agent tool yourself is not credited yet.
- **Only new commits:** never an amend (a run is refused one: [git actions](#git-actions)), a merge or a squash, nor a commit that a rebase or cherry-pick replays. One line per commit, for the role that made it, never added twice. An empty message stays empty, so git still refuses it.
- **Your own app:** `--credit-email <user ID>+<app>[bot]@users.noreply.github.com` shows your GitHub App instead; `off` goes back to the Cabinet Team.
- **The house rule follows it:** the "Commits." line in `AGENTS.md` allows this one line while credit is on, and no other attribution.

The line is added by the credit hook, `prepare-commit-msg` in the global hooks folder ([guardrails](guardrails.md#what-bootstrap-installs)), which `cabinet bootstrap` places. It needs git 2.15 or later. A `prepare-commit-msg` of your own there is left as it is, and then nothing is credited on that machine: `cabinet doctor` says so and why (`credit.hook`).

Each runner must pass the role on to the commands its agent runs. Whether each does is confirmed by a run on the real tool, as the guardrails are:

| Runner | Credit confirmed live |
|---|---|
| `claude` | not yet |
| `codex` | not yet |
| `antigravity` | not yet |
| `qwen` | not yet |
| `grok` | not yet |
| `opencode` | not yet |
| `cursor` | not yet |
| `custom` | depends on your command; Cabinet sets the variables for it |

## What agent runs cost

Every agent run costs money, as API spend or against a subscription's limits. Cabinet counts what its own runs cost (scheduled jobs and `cabinet role draft`), from what the agent tool reports, in `spend.tsv` in the workspace's log folder (time, job, runner, dollars, then uncached input, cached input and output tokens), on this machine only. Each built-in runner prints JSON for this; the reply still goes to the job's log, and output that is not that JSON (an error, a different version) goes there as it is.

| Runner | Reports | Seen on |
|---|---|---|
| `claude` | dollars | Claude Code's documented JSON |
| `grok` | dollars and tokens | Grok 1.0.62 |
| `opencode` | dollars and tokens; 0 dollars for a model it has no price for | opencode 2.0.32 |
| `codex` | tokens | Codex 0.163.0 |
| `cursor` | tokens | Cursor CLI 2026.10.16 |
| `qwen` | tokens | Qwen Code 0.25.3 (the shape of its result; no successful run yet) |
| `antigravity` | tokens | Antigravity CLI 1.4.2 |
| `custom` | nothing | |

Dollars a tool reports are what it says the run cost; on a subscription, that is what the run would cost through the API. For a runner that reports only tokens, set its price, in dollars per million tokens, as input, output and optionally cached input (cached input costs the input price when left out): `cabinet config --price "1.25 10 0.125"`, from the model's price list. Setup asks for it after the budget. With `opencode`, a price also counts runs of a model it reports at 0 dollars. Without a price, those runs are recorded in tokens only, and the doctor says so when a budget is set (`spend.unreported`). Sessions you or a teammate run in an agent tool are not counted, nor is a run stopped by its time limit.

- Each job's log ends a run with its cost and the week's.
- `cabinet job list` shows what each job cost this week, and the week's total.
- `cabinet digest` shows each project's week against its budget, and the total across every project on this machine.
- Setup asks for a weekly budget in US dollars, and a price for a runner that reports only tokens; `cabinet config --budget 20` sets or changes it. From 80% of it, the doctor reports `spend.budget`, so the brief lists it under "Actions for the owner"; past it, the doctor says so. Nothing is stopped: you decide whether to raise the budget, run jobs less often, or let the week end. The week starts on the day `AGENTS.md` names (Sunday by default).

Two settings keep the cost down: a brief that skips its agent on [quiet days](commands.md#jobsltjobgtjob), and fewer scheduled jobs.
## Sessions

Several sessions often work in the same repo at once: yours, a teammate's, the team's roles. In one folder they share one working tree and one index, so each sees the others' unfinished changes, and one careless git command can sweep them into its own commit. `cabinet session start [name]` gives a session a folder of its own: a git worktree of the repo at `sessions/<repo>/<name>/`, on a branch `session/<name>`, from the repo's current branch. Its commits, index, uncommitted changes and test runs are its own. Open your agent tool in that folder; run the repo's own setup there when it needs one per folder (installing dependencies), which `start` prints from a `## Session setup` section in the repo's `AGENTS.md`. Sessions are optional: with one session at a time, nothing changes.

Reviews work on session commits as on any other: every worktree shares the repo's history, so `cabinet handoff record` and the reviewers see the same commits from any folder. Work is ready for you to push only once its commits are on the branch you push. `cabinet session end <name>` shows the session's commits, the handoffs that name them and the command that brings them in (`git -C <repo> merge --ff-only session/<name>`), and removes its folder when nothing in it is uncommitted; it keeps the branch. No Cabinet command merges, rebases or pushes: you run the merge, or ask an agent in a session to. Until then the brief lists every session not merged under "Actions for the owner", and backups keep each session's uncommitted changes ([backups](backups.md)).

## Git actions

Some git actions can be undone through git's reflog: an amend, a rebase, a reset without `--hard`, a local merge, a cherry-pick, a revert, a branch, a stash. An agent runs one only when you ask for it in that session, never on its own initiative or because a handoff, a job or a page it read says so, and then tells you how to undo it (the reflog entry and the command). One exception: an agent may amend its own newest commit without asking, while it is not pushed and no handoff, verdict or note names it; once one does, a fix is a new commit. What cannot be undone or is public stays with you exactly as before: push, a merge on GitHub, releases, publishing, and any force. Uncommitted work is protected: in a folder other sessions also use, a command that drops or sweeps uncommitted changes (`reset --hard`, a checkout or restore of files, `clean`, `stash drop`, `commit -a`, `add -A`, `add .`, an amend with anything staged that is not its own) needs your explicit ask, and before running it the agent checks that every uncommitted change is its own, and stops, naming the files, when one is not. Before dropping changes it saves a snapshot (`git stash create`, then `git stash store`), which changes no file and is listed by `git stash list`. In a scheduled or handoff run no one is there to ask, so the kit's git hooks refuse every amend and every rebase there ([guardrails](guardrails.md#runs-never-rewrite)). Nothing here binds you: in your own terminal, any git command is yours to run.

## The builder never verifies

Work is ready for you to push only when qa and security have each recorded PASS on its handoff, and so has every other reviewer you enabled whose subject it touches (design-lead for anything people see, code-reviewer for code, dba for the database). A BLOCK, or a code-reviewer's CHANGES, holds the push until it is fixed or you override it. Whether work is ready is computed, not judged: `cabinet handoff list --ready` lists the work every reviewer it needs has passed at its latest commits, and the brief asks you to push only that. Turned on with `cabinet config --pipeline small|all --pipeline-limit <dollars>`, the same runs happen on a schedule while you are away, never past that much a run or your weekly budget, and the brief tells you what reached ready to push and what stopped. `cabinet spec run <spec>` does the same for a whole ready spec (routing, each builder's plan, the architect's review of it, then each piece of work in order), and `cabinet handoff run <ID>` moves one piece of work through those steps for you: the builder, each reviewer, the fixes after a BLOCK and the checks again, until it is ready to push or needs you, deciding nothing on its own. qa never passes work without evidence you can check without reading code (screenshots, a recording, a link to try it, or command output), and the brief links it. Each reviewer records its verdict with `cabinet handoff record`, as one line on the handoff, `- Verdict: qa PASS 2026-10-20 a1b2c3d specs/qa/2026-10-20-login.md` (role, PASS, BLOCK or CHANGES, date, commits, its note), and `cabinet doctor` flags a verdict in any other shape and a qa PASS with no evidence.

## Seats

A seat is a role filled by an agent or a person. The kit ships a small core of roles and none for each specialty: the team grows with the project. The chief-of-staff flags signs that a seat is needed, from the work (recurring work no seat owns, a function falling behind) and from the project itself (a website no one looks after for search, users with no one answering them, a goal you stated with no seat working on it), with evidence only, and every new seat is your decision, with its cost and the alternatives. A seat you decline is recorded in `notes/seats.md` and proposed again only with new evidence. A new seat is drafted for this project (`cabinet role add`).

## Titles and the org page

A role can carry a title and a display name ("Head of Product", "Product Agent"), set with `cabinet role add --title --name` or in its "## Team" section. Every decision brought to you names each expert by its title where it has one, so you read "Head of Engineering recommends B", not a file name. `ORG.md`, rebuilt with the roles whenever the team changes, shows each function with its lead and members, and for each role its title, what it does, what it owns, who it reports to and what it covers: a page for you, for someone joining, or the source for a public team page you approve. The kit ships no titles: a project that sets none gets the role names.

## Sub-teams

As a project grows, one role per function becomes a bottleneck. A lead can then grow a sub-team: roles that report to it and take on part of its work, such as `qa-mobile` reporting to qa and covering the mobile builder's work (`cabinet role add qa-mobile --reports-to qa --covers mobile`). It is proposed and approved like any seat, from the same evidence (the lead falling behind, a specialty it lacks, a new surface). Its lead onboards it, corrects it and settles its disagreements. On the work it covers, its review counts for its lead's, so the runner sends that work to it; for its first 30 days the lead must pass that work too, and after that the lead spot-checks, and either one's BLOCK holds the push. A builder's sub-team is a role owning a narrower repo or area, which the most specific row of the team table gives it. `cabinet role list` shows who reports to whom, and the doctor checks every lead is on the team and no role leads itself round a loop (`team.reports-to`). Each new seat goes through an onboarding checklist and a review after a month.

## Slugs and isolation

Every workspace has a slug. Everything it puts on the machine is named by it: schedules `ai.cabinet.<slug>.<job>`, its log folder `<slug>/` (below), the backup key `cabinet.<slug>.backup`, archives `<slug>-<YYYYMMDD>-<HHMMSS>.tar.gz.enc`. The log folder holds a `workspace` file naming its owner. Setup and `cabinet config` refuse a slug another workspace holds, bootstrap never replaces or removes a schedule that runs another workspace, and backup cleanup removes only the slug's own archives. Paths are compared with symlinks resolved, so a workspace reached through a link is still the same one.

## macOS and Linux

Cabinet works the same on both. Only where it keeps things on the machine differs, and one file, `bin/platform.sh`, decides it:

| | macOS | Linux |
|---|---|---|
| Schedules | launchd: `~/Library/LaunchAgents/ai.cabinet.<slug>.<job>.plist` | systemd user timers: `~/.config/systemd/user/ai.cabinet.<slug>.<job>.service` and `.timer`. On a machine that did not boot with systemd (many containers, older WSL): cron, as one block Cabinet writes into your crontab from `~/.config/cabinet/cron/`, keeping every line of your own. |
| Log folder | `~/Library/Logs/cabinet/<slug>/` | `~/.local/state/cabinet/<slug>/` (under `$XDG_STATE_HOME` when set) |
| Backup passphrase | the login keychain | the secret store, through `secret-tool` (`libsecret-tools` on Debian and Ubuntu); with cron, a file only you can read: `~/.config/cabinet/passphrases/cabinet.<slug>.backup` |
| Notifications | Notification Center | `notify-send` |

`CABINET_SCHEDULER` (`launchd`, `systemd`, `cron` or `none`) overrides the choice. On Linux:

- systemd runs a user's timers only while that user is logged in, unless lingering is on: `loginctl enable-linger "$USER"` once, on a server or a machine you leave logged out. A timer missed while the machine was off runs when it starts again, as launchd does after sleep.
- The secret store needs a desktop session. Without one, give scheduled backups the passphrase through systemd instead: `read -rs CABINET_BACKUP_PASSPHRASE; export CABINET_BACKUP_PASSPHRASE; systemctl --user import-environment CABINET_BACKUP_PASSPHRASE` (until the user's systemd stops; run it again after a restart). Cron jobs reach neither, so with cron the passphrase is kept in a file only you can read, `~/.config/cabinet/passphrases/cabinet.<slug>.backup` (under `$XDG_CONFIG_HOME` when set; `bin/bootstrap.sh` prints the command that writes it). On any machine that file, when it exists, comes before the keychain or secret store, and one that other users can read is never used.
- Run `cabinet bootstrap` as yourself, not through `sudo`: schedules are per user.

## Agent tools and models

Cabinet works through agent tools, so it works with any model they offer. Everything is plain files: any tool that reads `AGENTS.md` can run the team, and acting as a role means reading `agents/<role>.md`. Scheduled jobs run with the tool in `CABINET_RUNNER`. Which tools have guardrails, and their limits: [guardrails](guardrails.md).

| Runner | Runs a job as |
|---|---|
| `claude` | `claude -p --agent <role> --permission-mode auto --output-format json` (tested with real scheduled jobs) |
| `codex` | `codex exec --json "<role instruction> <prompt>"` |
| `antigravity` | `agy -p "<role instruction> <prompt>" --output-format json --dangerously-skip-permissions` |
| `qwen` | `qwen --approval-mode auto -o json "<role instruction> <prompt>"` |
| `grok` | `grok -p "<role instruction> <prompt>" --permission-mode auto --output-format json` |
| `opencode` | `opencode run --format json "<role instruction> <prompt>"` |
| `cursor` | `cursor-agent -p --force --output-format json "<role instruction> <prompt>"` (run live) |
| `custom` | `CABINET_RUNNER_CMD`, with the prompt in `$CABINET_PROMPT` and the role in `$CABINET_AGENT` (every runner gets `CABINET_AGENT`, for [credit roles](#credit-roles)) |

The role instruction is "Act as the <role> role: read agents/<role>.md and follow it as your instructions". Runners other than `claude` and `cursor` follow each tool's documented headless mode and are untested end to end as scheduled jobs (`grok`, `opencode`, `codex` and `antigravity` answered a one-line prompt in that mode; `qwen` needs an auth type set in its settings); Codex's default sandbox may not let a scheduled brief write its file. Headless Antigravity denies any tool it would ask about, and `--mode auto` is not open to every plan, so its runner skips the prompts: its deny rules are then the guardrail ([guardrails](guardrails.md)). Gemini CLI is no longer a runner: Google moved its users to Antigravity. A workspace still set to `gemini` is told to run `cabinet config --runner antigravity`; Gemini CLI keeps its guardrails for interactive use. Scheduled jobs get a PATH with the runner's and Node's folders.
