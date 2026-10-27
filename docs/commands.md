# Commands

Every command Cabinet has, its options and defaults, what it changes, and its exit codes. `cabinet help` (or `cabinet` alone) lists them; `cabinet <command> --help` (or `cabinet help <command>`) shows one command's usage and options, and a noun alone (`cabinet role`) shows its verbs. Agents and scripts: `cabinet help --json` gives every command and option, and every command that reports prints JSON (see [Output for agents and scripts](#output-for-agents-and-scripts)).

## Contents

- [How commands are named](#how-commands-are-named)
- Start: [cabinet new](#cabinet-new), [cabinet init](#cabinet-init)
- Daily: [cabinet next](#cabinet-next), [cabinet brief](#cabinet-brief), [cabinet digest](#cabinet-digest), [cabinet list](#cabinet-list), [cabinet doctor](#cabinet-doctor)
- Team: [cabinet role](#cabinet-role), [cabinet handoff](#cabinet-handoff)
- Work: [cabinet repo](#cabinet-repo), [cabinet job](#cabinet-job)
- Safety: [cabinet secret](#cabinet-secret), [cabinet backup](#cabinet-backup)
- Setup: [cabinet bootstrap](#cabinet-bootstrap), [cabinet config](#cabinet-config), [cabinet move](#cabinet-move), [cabinet remove](#cabinet-remove)
- Kit: [cabinet update](#cabinet-update), [cabinet status](#cabinet-status), [cabinet outdated](#cabinet-outdated), [cabinet changelog](#cabinet-changelog), [cabinet completion](#cabinet-completion), [cabinet version](#cabinet-version)
- [Which copy of Cabinet runs](#which-copy-of-cabinet-runs)
- [Workspace scripts](#workspace-scripts): the same commands without the `cabinet` command
- [Output for agents and scripts](#output-for-agents-and-scripts): `--json`
- [Files you can edit](#files-you-can-edit): `cabinet.env`, `jobs/<job>.job`, `cabinet.local.env`, `repos.tsv`
- [Environment variables](#environment-variables)
- [Removing a workspace](#removing-a-workspace)

## How commands are named

Once you know one command, you can guess the next:

- **One word** acts on the workspace as a whole, or on this machine: `cabinet doctor`, `cabinet update`.
- **A noun, then a verb** acts on something the workspace holds: `cabinet role add`, `cabinet repo list`, `cabinet handoff archive`. The nouns are `role`, `handoff`, `spec`, `manual`, `repo`, `job`, `secret` and `backup`, always singular.
- **The verbs** mean the same on every noun: `add` (put one in, or turn on one the kit has), `remove` (take one out), `list` (show them), `check` (look for problems), and a few a noun needs: `role draft`, `role build`, `handoff attach`, `handoff record`, `spec record`, `handoff archive`, `repo snapshot`, `job run`, `backup create`, `backup verify`, `backup restore`.
- **The same options everywhere:** `--json` on every command that reports, `--dry-run` on every command that changes the setup or deletes anything, `--yes` (`-y`) on every command that asks.
- **Any workspace, from anywhere:** every command finds the workspace from the folder you are in, upward, so it works anywhere inside the workspace or the project around a `cabinet/` workspace. `cabinet -C <dir> <command>` runs it as if started in `<dir>`, as git does.
- **Exit codes:** 0 done (or nothing found), 1 failed or found a problem, 2 wrong usage (an unknown command or option, a missing value). An unknown command gets one short answer, with the closest command when one is near, never the whole help.
- **The same words without the `cabinet` command:** every workspace has its scripts in `bin/`, named the same way (`bin/role.sh build`, `bin/handoff.sh list qa`), for agents, schedules and machines without the command ([Workspace scripts](#workspace-scripts)).

## cabinet new

```sh
cabinet new [dir] [options]
```

Creates a workspace in an empty or missing folder. In a terminal it asks a question for each setting; options set the defaults, and `--yes` skips the questions.

**Tools first.** `new`, `init` and `bootstrap` first check for the tools Cabinet needs (git, node, npm). When one is missing, they name it and the command that installs it here (`brew install`, or `sudo apt-get`, `dnf` or `pacman` on Linux). In a terminal they offer to run it and go on once it worked; with `--yes` or `--dry-run` they never install, and stop with that command (exit 1).

| Option | Default | Notes |
|---|---|---|
| `[dir]` | asked (`~/dev/<name>`) | Must not exist, or be empty. |
| `--name "Name"` | the folder name | The project's display name. |
| `--slug <slug>` | the folder name, made lowercase with dashes | Lowercase letters, digits and dashes. Refused when another workspace on this machine holds it. |
| `--owner "Name"`, `--email you@example.com` | `git config --global user.name` / `user.email` | The commit author written into `AGENTS.md`. With no identity, setup does not commit. |
| `--roles "qa security ..."` | the seven core roles, and `code-reviewer` when the workspace starts with repos | `chief-of-staff` is always added. `code-reviewer` is on by default when setup starts with product repos (`--repo`, `init` in a project, or a folder of repos), since nothing else reviews the code itself; the chief-of-staff proposes it later for a workspace that gains repos without it. The other optional kit roles, `brand-designer`, `dba` and `auditor`, are off unless named. Builders are never listed here: they come with the repos they own. |
| `--runner <tool>` | the first installed of `claude`, `codex`, `antigravity` (`agy`), `qwen`, `grok`, `opencode`, `cursor`, else `claude` | The agent tool for scheduled jobs. `cursor` means the Cursor CLI, never the editor's `cursor` command. `custom` needs `--runner-cmd`. |
| `--runner-cmd '<command>'` | none | With `--runner custom`: the command to run, using `"$CABINET_PROMPT"` (and `$CABINET_AGENT`). No single quotes. |
| `--brief-time <when>` | `7:00 AM` | When the brief is written: a time every day (`"7 AM"`), or days and a time, one day (`"fri 4 PM"`) or several (`"sun,mon,tue,wed,thu 8 AM"`), or `off`. See [Schedule times](#schedule-times). |
| `--week-start <day>` | `sunday` | Written into `AGENTS.md` house rules. |
| `--budget <dollars>\|off` | off | A weekly budget in US dollars for the agent runs Cabinet starts, in `cabinet.env`. Asked for every built-in runner ([what agent runs cost](concepts.md#what-agent-runs-cost)). |
| `--price "<input> <output> [<cached>]"\|off` | off | Dollars per million tokens, for a runner that reports only tokens (`codex`, `cursor`, `qwen`, `antigravity`), in `cabinet.env`. Asked after the budget for those runners. |
| `--writing short\|standard` | `standard` | How agents write to you, written into `AGENTS.md` house rules. `short` gives the shortest briefs, questions and answers: answer first, one point per line, three points at most, a decision in three lines. See [writing to the owner](concepts.md#writing-to-the-owner). |
| `--credit-roles off\|on` | `on` | [Credit roles](concepts.md#credit-roles): each commit a role makes in a Cabinet run ends with one line crediting that role beside you, `Co-authored-by: Cabinet <role> <email>`, which shows the Cabinet Team avatar on GitHub. Exactly `off` or `on`. Written into `cabinet.env`; the "Commits." house rule in `AGENTS.md` follows it. |
| `--credit-email <email>\|off` | none | With `--credit-roles on`: your own GitHub App's bot noreply email (`<user ID>+<app>[bot]@users.noreply.github.com`, lower case) in place of the Cabinet Team app's; `off` goes back to it. Refused with credit off. |
| `--backup-dir <folder>` | `off` | Made absolute. Refused when it is inside the workspace or any repo it lists. |
| `--repo <git url>` | none | Repeatable. `https://`, `http://`, `ssh://`, `git://`, `file://`, `git@host:path`, an absolute path, or `./` / `../` (relative to the workspace). Two repos with the same name are refused. |
| `--dry-run` | | Prints everything setup would write and change, then stops: `Nothing was written.` |
| `--yes`, `-y` | | No questions: defaults and options only. |

In a shared `cabinet/` (`init --inside --shared`), the credit roles answer is also kept in this machine's `cabinet.local.env`: each teammate answers for their own machine.

Values written into `cabinet.env` (name, owner, email, backup folder) cannot contain `$`, a backtick, a backslash, a double quote or a line break.

**What it writes:** the project files from the kit's templates (`AGENTS.md`, `cabinet.env`, `HANDOFFS.md`, `OPERATIONS.md`, `README.md`, `repos.tsv`, `jobs/brief.job`, `roles/`, `guides/`, `specs/`, `notes/`, `package.json`, `.gitignore`), the kit files (`CABINET.md`, `bin/`, `.cabinet/`), the built roles (`agents/`, `.claude/agents/`), and `CLAUDE.md` as a link to `AGENTS.md`. Then `git init` and one commit of those files. It records the slug in `~/Library/Logs/cabinet/<slug>/workspace`.

**In a terminal, afterwards:** it offers `npm install` (to download the pinned kit) and `bin/bootstrap.sh` (shown as a dry run first, and applied only when you say yes).

**If it fails part way:** it removes the folder it created, or empties the empty folder it was given, and nothing else.

## cabinet init

```sh
cabinet init [dir] [options]
```

Adds Cabinet to an existing folder (default: the current one). It takes every option of `cabinet new`, and these:

| Option | Notes |
|---|---|
| `--inside` | In a project repo: the workspace is `cabinet/` inside it (the default there). |
| `--private` | With `--inside` (the default): `cabinet/` has its own git; the project's git ignores it and no tracked project file changes. |
| `--shared` | With `--inside`: `cabinet/` is part of the project's repo. Nothing is committed in the project; you review and commit. |
| `--beside` | In a project repo: the workspace is a folder next to it (default `<project>-hq`). |
| `--workspace <folder>` | With `--beside`: where that folder goes. |

What it does depends on where it runs (see [layouts](layouts.md)):

| Run in | Result |
|---|---|
| The top folder of a project repo | Inside (private or shared) or beside, asked or from the options. |
| A subfolder of a repo | Refused: run it at the repo's top folder. |
| A folder that is not a repo | The folder becomes the workspace, "around" what is there. The repos it finds in subfolders are listed in `repos.tsv`. |
| A folder that already has a workspace | Refused: use `cabinet update`. |

In every case, existing files are kept and reported, never replaced. Around a folder, a file of its own at a path the kit uses (such as `bin/doctor.sh`) stops setup before anything is written.

**What it reads from a project** (as defaults you can change):

- From `package.json`: the name (scope dropped: `@acme/shop` becomes `shop`), the description (quoted as the project's own words), the repository URL (when the repo has no `origin`), and the `test`, `dev`, `start`, `build`, `lint` and `typecheck` scripts (run with bun, pnpm or yarn when their lockfile is there). A value with shell characters, or a URL that is not a plain git URL, is not used.
- The project's own `AGENTS.md`, `CLAUDE.md` and `README.md`, named as where its rules live.
- The repo's own git `user.name` and `user.email` as the owner.

## cabinet next

```sh
cabinet next [--json]
```

Says what to do next in the workspace you are in, as a numbered list, and changes nothing: missing tools Cabinet needs (step `deps`, with the install command), the `TBD` headings left in `AGENTS.md`, a workspace with no commits, a pinned kit not yet downloaded, a machine without the push gate or schedules (`cabinet bootstrap`), the credit roles question while it is not answered (`cabinet config --credit-roles`), handoffs waiting on the owner, today's brief (with when it was written) or when the first one comes, and how many problems the doctor finds. Outside a workspace it says how to start one. When nothing waits: `Nothing waits on you.` Each step ends with the command that does it, when there is one.

## cabinet brief

```sh
cabinet brief
```

Writes the brief now: the same as `cabinet job run brief`, which runs `jobs/brief.job` as chief-of-staff and writes `BRIEF.md`, the sign-off queue first. It prints nothing until the agent tool finishes.

## cabinet digest

```sh
cabinet digest [--json]
cabinet digest --write <file> [--notify]
cabinet digest --schedule [<when>|off] [--file <file>] [--notify]
```

One morning read for every workspace on this machine: from each one's latest `BRIEF.md`, the "Sign-off queue" and "Actions for the owner" parts, by their `## ` headings (the chief-of-staff role writes them with these names), and how many handoffs wait on you. It flags a brief older than a day and a half (is the brief job running?), a workspace with no brief yet, and a brief without the "## Sign-off queue" heading. It also shows what each workspace's agent runs cost this week against its budget ([what agent runs cost](concepts.md#what-agent-runs-cost)), each by its own week start, with no line for a workspace whose runner does not report cost. It reads only: you still answer each queue in its own workspace, to that workspace's agent. It starts with one line of counts (decisions, actions and handoffs waiting, briefs late, missing or unreadable, and projects at 80% of their budget or more) and the week's total cost across them, and ends by saying whether it is scheduled.

| Option | Notes |
|---|---|
| `--write <file>` | Write the digest to that file (replaced each time) instead of the screen. |
| `--notify` | Also show a desktop notification with the counts line (`notify-send` on Linux). |
| `--schedule [<when>]` | Write it on a schedule. With no time: every day at 10:00 AM. Or any [schedule time](#schedule-times): `"8 AM"`, `"fri 10 AM"`, `"sun,mon,tue,wed,thu 8 AM"`. Run again to change it. `--schedule off` stops it and keeps the last file. |
| `--file <file>` | With `--schedule`: where it is written. Default `digest.md` in the log folder (`~/Library/Logs/cabinet/` on macOS, `~/.local/state/cabinet/` on Linux), which a scheduled job can always write. macOS may block a scheduled job from writing to Documents, Desktop, Downloads or iCloud Drive until you allow it (System Settings > Privacy & Security > Files and Folders); Cabinet says so when you choose one. |
| `--json` | The digest as JSON (below). |

The schedule is one job for the whole machine, `ai.cabinet-digest` ([launchd, systemd or cron](concepts.md#macos-and-linux)), apart from every workspace's `ai.cabinet.<slug>.*` jobs; it runs this `cabinet` (so install it globally, not only through npx, whose cache can be cleared) and logs to `digest.log` in the log folder. On macOS the first notification may need you to allow notifications for Script Editor, which macOS uses to show them. Exit 0, or 1 for a bad time, no scheduler, or a schedule the scheduler would not load.

## cabinet list

```sh
cabinet list [--json]
```

Every workspace on this machine, from anywhere: its slug, project name, kit version (marked `*` when it is not the installed kit), how many handoffs wait on you, what the doctor finds, when the latest brief was written, and its folder. The doctors run side by side, each with its workspace's own scripts, so it takes about as long as one doctor run. A workspace is listed once setup or bootstrap has claimed its slug on this machine; `cabinet remove` takes it off the list. A workspace whose folder is gone shows as `folder gone`, with how to free its slug. Changes nothing. Exit 0.

## cabinet doctor

```sh
cabinet doctor [--fix [--yes]] [--json]
```

Checks everything: repos, kit files, roles, guardrails for every installed tool, the manual, handoff IDs, secrets in the workspace's files, uncommitted work, schedules, backups. It starts with a summary (`N thing(s) need attention:` and the list, or `All good.`), then the full report. In a terminal the report colors each result's label: `ok` green, `note` blue, `FIX` red. Output to a script or a file has no colors, and none are printed when `NO_COLOR` is set or `TERM` is `dumb` ([color in a terminal](#output-for-agents-and-scripts)); section headings show in bold. Changes nothing in the workspace or your settings (it runs `opencode debug` and `grok inspect`, which may write their own caches). `--fix` then runs the fixes it knows (`bin/bootstrap.sh`, `bin/role.sh build`, `bin/repo.sh snapshot`, and installing missing tools), asking before each unless `--yes`, and checks again. Installing tools always asks in a terminal, even with `--yes`: it changes the machine and can need your password. `--json` prints the results for scripts (see [Output for agents and scripts](#output-for-agents-and-scripts)). Every message is explained in [troubleshooting](troubleshooting.md). Exit 0, or 1 when anything says FIX.

## cabinet role

```sh
cabinet role add <name> [--does "..."] [--owns "..."] [--decides "..."] [--escalates "..."] [--reports-to <role> [--covers "<builders or repos>"]] [--title "..."] [--name "..."] [--function "..."] [--draft] [--dry-run] [--yes]
cabinet role remove <name> [--dry-run]
cabinet role list [--json]
cabinet role draft <name>
cabinet role build [--check]
```

**`add`** turns on a kit role (`cabinet role add dba`), or adds a role of the project's own from as little as its name (lowercase letters, digits and dashes, not a builder's name). For a role of its own, in a terminal with no option given, it asks what the role should do, what it owns, what it may decide on its own and what it must bring to you; Enter skips any of them, and `--does`, `--owns`, `--decides` and `--escalates` give those answers instead. It writes `roles/<name>.md` with your answers word for word under "The owner's brief" (`not said yet` for the rest) and a `TBD` description. Either way the role is turned on through `cabinet config --roles`, which adds its rows to the team tables and builds it. `--owns` (or the answer to "What does it own") is checked against the team table: a repo or path that is already another role's row is refused (exit 1), naming who owns it; a path inside another role's area (`specs/seo/` inside `specs/`) is accepted with a note, since drafting gives the new role its own row there and the most specific row wins. A new role does only what the brief asks until it is drafted. `--draft`, or yes to the question that follows in a terminal, drafts it at once; `--yes` asks nothing; `--dry-run` says what it would do.

**`remove`** turns a role off: its built files and its rows in the team tables go. A role of the project's own keeps `roles/<name>.md`; delete it to drop the role for good. chief-of-staff is always on. Builders come and go with the repos they own in the team table, not through `role add` or `remove`.

**Committing a role change.** In a workspace with its own git, `add` and `remove` commit what they changed (`roles: <name> on`, `off`, or `added from the owner's brief`), unless the files they touch (`AGENTS.md`, `OPERATIONS.md`, `ORG.md`, `cabinet.env`, `roles/`, `agents/`, `.claude/agents/`) held uncommitted edits of yours: then, and in a shared `cabinet/`, they leave the change for you to review and commit, and say so.

**Sub-teams.** `--reports-to <lead>` adds a role to a lead's sub-team ([concepts](concepts.md#sub-teams)): its lead, on the team, owns its onboarding and settles its disagreements. `--covers "<builders or repos>"` names whose work it reviews for its lead: on a handoff from one of them, its verdict counts for its lead's, and `cabinet handoff run` runs it instead of the lead. It starts with a 30-day trial, during which the lead's PASS is needed too. Both go into a "## Team" section of `roles/<name>.md` (`- Reports to:`, `- Covers:`, `- Trial until:`), kept when the role is drafted; edit it there later. Refused (exit 1): a lead not on the team, the role itself as its lead, `--covers` without `--reports-to`, or a name in `--covers` that is no builder or repo.

**Titles.** `--title "Head of Product"` and `--name "Product Agent"` give a role the title and display name decisions name it by (the sign-off format names each expert by its title where it has one) and the org page shows; `--function "Growth"` places a role in a function of its own on the org page (by default, its lead's, or a kit role's own, or Other). They go into the role's "## Team" section, and they work when turning on a kit role too, written to its notes in `roles/<name>.md`. Plain words only. Edit them there later, then `cabinet role build`.

**`list`** shows every role on the team (kit, optional, builder or project; a project role not yet drafted is marked; its title and display name; for a sub-team role, its lead, what it covers and its trial) and the optional kit roles that are off.

**`draft`** has an agent write the whole role for this project, as `.cabinet/rules/seats.md`, "Drafting a role", says: it keeps your brief, learns the rest from the project, writes the role, lists what it assumed for you to confirm, fills the team table rows and commits. It runs the configured agent tool as chief-of-staff (a few minutes; it may cost money), logging to `~/Library/Logs/cabinet/<slug>/role-<name>.log`. In an agent session, asking the agent to draft the role does the same. Add to the brief at any time and draft again.

**`build`** writes `ORG.md`, the org page (each function with its lead and members; each role's title, what it does, what it owns in the team table, who it reports to, what it covers and its trial), and builds `agents/<role>.md` and `.claude/agents/<role>.md` for every role (and, inside a project, the project's `.claude/agents/` and pointer files); `--check` only reports. Setup, config, update and bootstrap run it for you.

Exit 0; 1 when the role could not be added, removed or drafted, or `build --check` finds a role missing or out of date; 2 for a name that is not valid.

## cabinet handoff

```sh
cabinet handoff add --from <name> --to <name> --changed "..." --needed "..." [--depends-on "..."] [--spec <file> | --small] [--evidence <file or URL>]... "<title>"
cabinet handoff attach <ID> <file or URL>... --from <name>
cabinet handoff record <ID> --role <role> <PASS|BLOCK|CHANGES> --commits <hash,...>|none --note <file>
cabinet handoff list [name] [--ready] [--json]
cabinet handoff run <ID> [--retries <n>] [--dry-run]
cabinet handoff run --scheduled
cabinet handoff archive
```

**`add`** files one handoff: appends the entry at the bottom of "Open" in `HANDOFFS.md` with the next free ID for today (`H-20261019-01`, unique across `HANDOFFS.md` and the archives), today's date, status `open` and the template's lines, then commits it on its own (`handoffs: <ID> <title>`). `--depends-on` defaults to `none`. Each value is kept on one line. It prints the new ID first. When `HANDOFFS.md` already has someone else's uncommitted lines, it writes the entry but does not commit, so their lines never go into its commit. Two agents filing at once get different IDs: each write takes a lock (`.cabinet/handoff.lock`), and a lock left for more than a minute by a writer that was stopped is taken over. Entries are filed only this way, never by hand, so no two take the same ID. Two copies of a workspace (a teammate's clone) do not share the lock; `cabinet doctor` flags an ID used twice after they are merged (`handoffs.unique-ids`).

`--spec specs/<feature>.md` names the spec the handoff builds, on a `Spec:` line, and refuses (exit 1) unless the spec is committed, `ready` or `building`, and passes `cabinet spec check`: work bigger than a small task is routed only from a spec that is ready to build ([concepts](concepts.md#ready-to-build)). `--small` instead marks a small task (one repo, no contract change, no decision for you, easy to undo) with a `Size: small` line. A handoff to a repo, a kit builder, or a role that owns a repo in the team table needs one of the two (exit 2 with neither, or both).

`--evidence`, once for each, attaches what shows the work, so you can check it without reading code: a file (a screenshot, a short recording, saved command output) is copied to `specs/evidence/<ID>/` with a name safe in a link and committed with the entry; an `http` or `https` link is kept as it is. The entry gets an `Evidence:` line of links from the workspace root, which open with a click from `HANDOFFS.md` and `BRIEF.md` in an editor or on GitHub. `archive` rewrites them to open from `handoffs/`, and `cabinet digest` to full paths. A file path is read from the folder you run it in, else from the workspace.

**`attach`** adds evidence to an open handoff after it was filed (after a BLOCK, a fix, a missed screen), the same way `--evidence` does: files copied to `specs/evidence/<ID>/`, every link added to the entry's `Evidence:` line, committed. Only the entry's sender may: `--from` must match its `From:`.

**`record`** writes a reviewer's verdict on an open handoff as one line, `- Verdict: <role> <PASS|BLOCK|CHANGES> <YYYY-MM-DD> <commits> <note>`, with today's date, replacing that role's earlier verdict, and commits it (`handoffs: <ID> <role> <verdict>`). The verdict may be in any case; commits may be joined by commas or spaces. `--commits none` is for work that changes no repo (copy, research, a campaign), and is refused when the handoff is addressed to a repo or a role that builds one. For a reviewer a [critical area](concepts.md#critical-areas) the work touches names, a PASS first runs that area's check, a command in `tools/`, in the workspace with `CABINET_AREA`, `CABINET_HANDOFF` and `CABINET_COMMITS` set and the run's time limit, never through a shell; a failing check refuses the PASS (exit 1, with its last lines), and a passing one's output is saved as `specs/evidence/<ID>/check-<area>.txt`, linked on the entry and committed with the verdict. It refuses when the note is not a committed `.md` file under `specs/` (read from the folder you run it in, else from the workspace), when the role is the entry's sender (the builder never verifies its own work), and a qa PASS on an entry with no evidence: qa records BLOCK instead, and the sender runs `attach`. On a small task, it refuses a PASS whose commits are in more than one repo (or in none on this machine), or change a path `AGENTS.md` guards: a contract's files, written as `` `<repo>/<path>` `` under "Source of truth" in the contracts table, or a path under "Hard to undo". The work goes back to be routed from a spec.

**`list`**, without a name: every open handoff with its age in days, oldest first (`?` when it has no date). With a repo or role name (`qa`, `owner`): every entry addressed to it, in full; this is the start-of-session read. `--ready`: only the work ready for you to push (`No handoffs ready to push.` when there is none; with a name, only with `--json`).

**Readiness** is computed from the verdicts. An entry needs a verdict from each reviewer it is addressed to, from every reviewer of a critical area it touches, and, for code (sent by a builder, or with a verdict that names commits in a product repo), from qa, security and code-reviewer, and design-lead when a web or mobile builder sent it, each only when on the team; a builder addresses dba (or any other reviewer) when the change touches its subject. The work's commits are every commit any verdict on the entry names (short and full hashes match), and a PASS counts only when it covers them all: after a fix, a reviewer whose PASS names only the earlier commits is `stale` until it records again. An entry is ready when every reviewer it needs has a PASS that counts and none has BLOCK or CHANGES. An entry that needs no review (a decision for you, say) is neither ready nor waiting. PASS, BLOCK or CHANGES written outside a `- Verdict:` line is reported as unread and never counted.

**`run`** moves one piece of work through the steps the team already has, each an agent run with the configured agent tool, so you start no agent by hand. It takes a handoff to one builder (a repo, or the role that owns it), filed with `--small` or with `--spec` for a spec that still passes `cabinet spec check`. It reads the state (`handoff list --json`) and runs whoever is next:

1. No review handoff for the work yet: the builder builds it and hands it on for review with `--depends-on <ID>`, then closes the work entry.
2. Reviewers missing, or stale after a fix: each verifies and records its verdict.
3. A BLOCK or CHANGES: the builder fixes it, then the blocking reviewers check again. After `--retries` fix rounds (default 2) it stops and leaves it to you.
4. Ready (as `handoff list --ready` says): it stops and tells you to push, with what the runs cost.

It decides nothing itself: it also stops when an agent fails or hits its time limit (`CABINET_JOB_TIMEOUT`), when a builder files no review handoff or sends the work back, or when a reviewer records no verdict. Each run is logged in `run-<ID>.log` in the workspace's log folder and recorded in the spend file under the work's ID, so `handoff list --json` gives its `cost_usd`. One run at a time per piece of work. `--dry-run` prints the next step and runs nothing. It may cost money, like any agent run.

**`run --scheduled`** is what the pipeline job runs (see `cabinet config --pipeline`). It takes the work `CABINET_PIPELINE` allows, oldest first: with `all`, each spec ready to build (as `spec run`), then each handoff filed `--small` that is open or waiting on its review (as `handoff run`). It writes what happened to `PIPELINE.md` in the workspace (untracked, like `BRIEF.md`; the brief reports it): each piece of work and how it ended, then what the run spent of its limit. Before each agent it checks the limit, `CABINET_PIPELINE_LIMIT` dollars: once reached, the work is paused, not stopped, and the next run goes on from there. Work whose last run stopped for you (still blocked after its fix rounds, sent back, an agent that left no trace) is skipped, so a run never pays for the same stop twice, until you run it by hand (`cabinet handoff run <ID>`, or `spec run`), which clears it. It runs nothing when the runner is off, when it has no limit, when this week's budget (`CABINET_BUDGET`) is spent, or when the agent tool's cost cannot be counted.

**`archive`** moves every committed `done` or `rejected` handoff to `handoffs/archive-YYYY-MM.md` and commits the move; chief-of-staff runs it daily. It refuses while `HANDOFFS.md` has uncommitted lines.

`add`, `attach` and `record` write one at a time, and with someone else's uncommitted lines in `HANDOFFS.md` they write but do not commit.

Exit 0 (for `run`: the work is ready to push); 3 when `run` pauses at a scheduled run's cost limit; 1 when `run` stops before that, `add` could not commit (the entry is written), `attach` or `record` refuses (no such open entry, not its sender, a note not committed, the builder's own verdict, a qa PASS with no evidence, a PASS on a small task that was not), or `archive` meets uncommitted lines; 2 for a missing value, an unknown option, a value in the wrong form, or evidence that is neither a file nor an `http(s)` link.

## cabinet manual

```sh
cabinet manual build [--check]
```

**`build`** writes `OPERATIONS.html`, the owner's manual (`OPERATIONS.md`) as one page you open in a browser: a table of contents, a search box that narrows the page to the sections that match, light and dark themes, and each `- [ ]` line as a tick box, remembered in that browser for the day, so a daily list starts fresh. The page holds everything it needs (no fonts, scripts or styles fetched) and works offline. Nothing in the Markdown runs: it is all escaped, and only `http(s)`, `mailto`, relative and `#` links become links. Like `BRIEF.md` it is untracked: setup, `cabinet update` and the brief job (its `AFTER`) rebuild it, and the doctor notes when it is older than `OPERATIONS.md` (`manual.page`). `--check` only reports (exit 1 when it is behind).

## cabinet spec

```sh
cabinet spec check [spec] [--json]
cabinet spec record <spec> --role <qa|architect|design-lead> <PASS|BLOCK> --note <file>
cabinet spec run <spec> [--retries <n>] [--dry-run]
```

**`check`** holds every spec in `specs/` (or the one named) to what its status needs (`--json` adds `repos`, `missing_plans` and `plan_review`, the architect's review of the plan as it is now: `PASS`, `BLOCK`, `changed` or `none`) ([concepts](concepts.md#ready-to-build)). `draft`, `shipped` and `dropped` need nothing. `ready` needs acceptance criteria, no `TBD` in "Rules", every row of the Decisions table answered, at least one repo in `repos` (or a workspace area, for work with no code), only declared critical areas in `areas`, and a qa PASS on the acceptance criteria as they are now. A spec built in a repo whose owner in the team table is the web or mobile builder also needs, while design-lead is on the team, a "Design" section and a design-lead PASS on it as it is now. `building` also needs a plan for each repo (a `### <repo>` part under "## Plan" with something in it) and, for more than one repo, an architect PASS on the plan as it is now. It prints each spec, its status and its problems (or `ok`). `--json`: `[{spec, status, problems}]`. The doctor runs it (`specs.ready`).

**`record`** records a review of a spec under its "## Reviews" heading: qa's of the acceptance criteria (can each be tested as written?), design-lead's of the design, or architect's of the plan. It writes `- Verdict: <role> <PASS|BLOCK> <YYYY-MM-DD> <fingerprint> <note>`, replacing that role's earlier review, and commits the spec (`specs: <feature>.md <role> <verdict>`). The fingerprint is of the part reviewed, so a later change to it shows as unreviewed in `check`. The spec and the note must be committed, the note a `.md` file under `specs/`; both are read from the folder you run it in, else from the workspace.

**`run`** moves a spec that passes `check` (`ready` or `building`) until all its work is ready to push, an agent run per step, so you start no agent by hand: chief-of-staff routes it (one handoff per owning builder, filed `--spec`), each builder writes its plan for its repo, and, for more than one repo, architect reviews the plan; then each of its handoffs runs in the order routing set, as `cabinet handoff run` runs one (`--retries` is passed on). It stops at the first step that does not finish: an agent that fails or leaves no trace, a plan the architect blocks, or a handoff that does not reach ready. Run again after you settle it: work already done is not redone. It ends with what all its runs cost. Logged in `run-<feature>.log` in the log folder; one run at a time per spec; `--dry-run` prints the next step. It may cost money.

Exit 0; 1 when `check` finds a spec not ready for its status, `run` stops before all its work is ready, or `record` refuses (a file not committed, not a spec, or the spec given as its own note); 2 for a missing value, an unknown option, a role other than qa, architect or design-lead, or a verdict other than PASS or BLOCK.

## cabinet repo

```sh
cabinet repo add <git url> [--apply] [--dry-run]
cabinet repo remove <name> [--dry-run]
cabinet repo list [--json]
cabinet repo snapshot
```

**`add`** adds a product repo: a row in `repos.tsv` and in the team table of `AGENTS.md`, through `cabinet config --repo`, with the same checks as setup. Like `config`, it commits the change (`cabinet config: add repo`) in a workspace with its own git that had no uncommitted changes. `cabinet bootstrap` then clones it and gives it a builder; `--apply` runs bootstrap right away.

**`remove`** takes a repo out of the workspace: its row in `repos.tsv` and in the team table. Its folder, its history and `local/<name>/` are left as they are. `bin/doctor.sh` then notes any open handoff still addressed to it.

**`list`** shows every repo: its owner in the team table, whether it is on this machine, and where it lives.

**`snapshot`** copies each repo's local-only files and `.git/info/exclude` entries into `local/<repo>/`, so they can be reviewed and committed in the workspace. The backup runs it first.

Exit 0; 1 for a repo that is not in `repos.tsv`, or a URL setup refuses; 2 for wrong usage.

## cabinet job

```sh
cabinet job run <job>
cabinet job list [--json]
```

**`run`** runs `jobs/<job>.job` now with the configured agent tool, logging to `<job>.log` in the workspace's log folder (`~/Library/Logs/cabinet/<slug>/` on macOS, `~/.local/state/cabinet/<slug>/` on Linux), and stops it after its time limit (`TIMEOUT`, or `CABINET_JOB_TIMEOUT`). The limit counts only time the machine is awake: a run the machine slept through is not stopped for it, and a run that ends on its own is never reported as stopped. By hand it shows the result too; the scheduler runs the same on the job's schedule, except that a scheduled run of a job with `QUIET_DAYS` is skipped when nothing changed since its last full run (see below). **`list`** shows each job's role, schedule, time limit and [what it cost this week](concepts.md#what-agent-runs-cost), then the week's total and the budget.

Exit 0; 1 when the run failed; 124 when it was stopped by its time limit; 2 for an unknown or incomplete job.

## cabinet secret

```sh
cabinet secret check [--staged] [--json]
```

Looks for keys, tokens and passwords in the workspace's own files (tracked, and new files git does not ignore; not the product repos, which have their own git): private key blocks; AWS, GitHub, Slack, Stripe live, Anthropic, OpenAI, Google API and npm keys; and lines that set a password, secret, token or API key to a value that is not a placeholder (`<...>`) or a variable (`$X`). It prints each file and line with the kind of secret, never the value. A false alarm: add `not-a-secret` anywhere on its line. `--staged` checks only the lines staged for the next commit; the workspace's pre-commit hook runs it ([guardrails](guardrails.md#what-bootstrap-installs)). Exit 0, or 1 when something is found (with `--staged`, the commit is refused).

## cabinet backup

```sh
cabinet backup create [folder]
cabinet backup verify [folder] [--json]
cabinet backup restore <archive> [dir]
```

**`create`** writes one encrypted archive now ([backups](backups.md)); the default folder is `CABINET_BACKUP_DIR`, and the schedule runs the same. **`verify`** writes nothing there: it restores the newest archive into a temporary folder, checks each repo against the workspace, and deletes the copy ([backups](backups.md#checking-it)). **`restore`** rebuilds the workspace and its repos from an archive, never losing a file; outside any workspace it runs the installed kit's copy, since a new machine has no workspace yet. It starts by naming the backup's date.

Exit 0; 1 with no passphrase, no archive, or (for `verify`) a problem found; 2 for a missing, relative or inside folder, or a keep count under 1.

## cabinet bootstrap

```sh
cabinet bootstrap [--dry-run] [--no-schedules | --schedules]
```

Sets up this machine for the workspace: clones missing repos, restores local-only files, links `CLAUDE.md`, gives each repo whose owner is `TBD` a builder ([concepts](concepts.md#the-team)), builds the roles, installs the guardrails ([guardrails](guardrails.md)) and the workspace's secrets check before each commit, and adds, updates or removes the schedules to match `jobs/` and the backup setting. `--dry-run` only prints. `--no-schedules` stops and from then on skips the jobs' schedules on this machine, for a workspace whose jobs another machine runs (a teammate's, in a shared workspace); `--schedules` undoes it. Both are saved in `cabinet.local.env`. The backup schedule is not affected. Safe to rerun. Exit 0, or 1 when any step did not complete (each one says why).

## cabinet config

```sh
cabinet config [options]
```

Changes a workspace's settings after setup: the whole setup at once. To change one thing, the noun commands are shorter (`cabinet role add`, `cabinet repo add`). Run it in the workspace, or in the project's top folder when the workspace is `cabinet/` inside it (or name it: `cabinet -C <dir> config`). In a terminal it asks the setup questions again with the current answers as defaults, lists the changes, and asks before writing.

Options: `--name`, `--slug`, `--owner`, `--email`, `--roles`, `--runner`, `--runner-cmd`, `--brief-time`, `--week-start`, `--writing`, `--credit-roles off|on` and `--credit-email <email>|off` ([credit roles](concepts.md#credit-roles); with `--yes`, a workspace from before the setting keeps it unset until you give one), `--hard-to-undo "<repo>/<path> ..."|off` (paths a small task never touches, see below), `--pipeline off|small|all`, `--pipeline-limit <dollars>` and `--pipeline-time <when>|off` (the scheduled runner, see below), `--backup-dir`, `--backup-time <time>` (like `"1 PM"`), `--budget <dollars>|off` (a weekly budget for the agent runs Cabinet starts, like `20` or `12.50`), `--price "<input> <output> [<cached>]"|off` (dollars per million tokens, for a runner that reports only tokens), `--repo` (adds a repo, as `cabinet repo add` does), `--apply` (run `bin/bootstrap.sh` without asking), `--dry-run` (list the changes and write nothing), `--yes`.

**Committing the change.** In a workspace with its own git that had no uncommitted changes before, `config` commits what it changed (`cabinet config: <the settings changed>`): only the files that run wrote, each for the settings that change it. `cabinet.env` always; `AGENTS.md` for the project name, the owner, the week start, writing to the owner, credit roles (when its house rule changes), hard to undo, the roles or a new repo; `OPERATIONS.md` for the name, the slug or the roles; `package.json` for the name or the slug, when it is the workspace's own (`private`, named `<slug>-workspace`); under `jobs/`, the job files it wrote: `brief.job` for the brief time, `pipeline.job` when the scheduled runner is first turned on, when its time changes or when it was deleted (a mode change alone writes none), and for the slug each job that names it (the rewrite changes no other); `HANDOFFS.md`, `README.md` and `specs/ROADMAP.md` for the name (`README.md` for the slug too); `repos.tsv` for a new repo; the role files under `ORG.md`, `agents/` and `.claude/agents/` that the role build changed, added or removed, for the roles or the name, or when `bootstrap` ran; and `CLAUDE.md` only when that `bootstrap` linked it because it was missing (a `CLAUDE.md` that was already there, a plain file included, is left alone). A change someone else makes while it runs, in one of the files that run wrote, goes into that commit; a change anywhere else stays theirs to commit. When the workspace already held uncommitted changes, or the workspace is committed with a project (a shared `cabinet/`), it leaves the change for you: review with `git diff`, then commit.

**For this machine only:** `cabinet config --this-machine --backup-dir <folder>|off [--backup-time <time>]` writes the backup settings into `cabinet.local.env` instead of `cabinet.env`, so they apply on this machine and are never committed. In a shared workspace, each teammate picks their own backup folder, or none. `cabinet config --this-machine --credit-roles off|on` answers the credit roles question for this machine; in a shared workspace a machine credits nothing until it has answered. `cabinet config --this-machine --clear` makes this machine follow `cabinet.env` again. With `--this-machine`, no other setting can be changed (they are shared by every machine), and nothing is asked.

**What it changes:**

| Setting | Where |
|---|---|
| Name | `CABINET_PROJECT`, and the titles setup wrote in `AGENTS.md`, `HANDOFFS.md`, `OPERATIONS.md`, `README.md`, `specs/ROADMAP.md`, plus the workspace's own `package.json`; rebuilds the roles, so the heading of `ORG.md` names the project |
| Slug | `CABINET_SLUG`; stops the old schedules, renames them in `OPERATIONS.md`, `README.md` and `jobs/*.job`, claims the new slug and releases the old one, and says how to move the backup passphrase in the keychain |
| Owner and email | the "Commits" line in `AGENTS.md` |
| Roles | `CABINET_ROLES`, the team tables in `AGENTS.md` and `OPERATIONS.md` (a dropped role's row leaves; a returning kit role's row comes back; a project role gets a `TBD` row), and the built roles |
| Runner | `CABINET_RUNNER`, `CABINET_RUNNER_CMD` |
| Brief | `WHEN` in `jobs/brief.job` |
| Week start | the house rule in `AGENTS.md` |
| Writing | the "Writing to the owner" house rule in `AGENTS.md` (added after the week start when an older `AGENTS.md` lacks it) |
| Credit roles | `CABINET_CREDIT_ROLES`, `CABINET_CREDIT_EMAIL` (dropped when credit turns off), this machine's answer in `cabinet.local.env` when it keeps one (always, in a shared workspace), and one sentence of the "Commits." house rule in `AGENTS.md`: the kit's two wordings swap, and the rest of the line stays. A line that holds neither is left as it is, with a message: it needs your own edit |
| Hard to undo | the list under "Hard to undo" in `AGENTS.md`, keeping the section's other text (the section is added before "House rules" when an older `AGENTS.md` lacks it); `off` writes `- none` |
| Backups | `CABINET_BACKUP_DIR`, `CABINET_BACKUP_TIME` |
| Budget and price | `CABINET_BUDGET`, `CABINET_PRICE` |
| Scheduled runner | `CABINET_PIPELINE`, `CABINET_PIPELINE_LIMIT`, and `WHEN` in `jobs/pipeline.job` (made the first time it is turned on; turning it off leaves it, doing nothing) |
| Repos | new rows in `repos.tsv` and the team table in `AGENTS.md` |

**The scheduled runner** moves ready work through build and review while no one watches: each run is `bin/handoff.sh run --scheduled`, from `jobs/pipeline.job`. It is off until you turn it on. `small` lets it move handoffs filed `--small`; `all` adds every spec that `cabinet spec check` finds ready or building. Turning it on needs `--pipeline-limit`, what one run may spend, and a runner whose cost Cabinet counts (claude, grok or opencode, or a token runner with `--price`), or the limit could not hold. `--pipeline-time` sets when it runs (default `10:00 PM`; `off` runs it only by hand: `cabinet job run pipeline`). In a terminal, `config` asks for all three.

**Hard to undo** is the list of paths where a change is hard to undo, such as migrations and public API files: a handoff marked small never touches them ([ready to build](concepts.md#ready-to-build)). Each is `<repo>/<path>`, for a repo in `repos.tsv`; a path ending in `/` covers its folder. It is refused when the repo is unknown, the path has characters other than letters, digits, `.`, `_`, `-` and `/`, or the repo is on this machine and the path is not in it. In a terminal, the question shows what the repos on this machine hold that looks hard to undo (`migrations/`, `db/migrate/`, `prisma/migrations/`, `supabase/migrations/`, `alembic/versions/`, an `openapi` file), as the default when nothing is set yet; nothing is written until you answer, and `--yes` keeps the current list. Editing the section by hand works too.

Roles the project defines itself (`roles/<role>.md` with frontmatter) are accepted and asked about. Layout and visibility (inside, beside, private, shared) are not changed by `config`. When nothing changes, it prints `Nothing to change.` and writes nothing.

## cabinet move

```sh
cabinet move <new-path> [--dry-run]
```

Moves a workspace folder and updates what remembers its path: Claude Code's memory and trusted folders, Codex's trusted folders, the schedules. Refused for the inside and beside layouts. Exit 0, or 1 when refused.

## cabinet remove

```sh
cabinet remove [--dry-run] [--yes] [--force] [--delete-key]
```

Removes the workspace you are in from this machine (another one: `cabinet -C <dir> remove`). It first prints the plan:

- stop and delete the workspace's own schedules (a schedule is its own when it runs this workspace's `bin/`; another workspace's are never touched);
- delete its log folder (`~/Library/Logs/cabinet/<slug>/` on macOS, `~/.local/state/cabinet/<slug>/` on Linux), which frees the slug;
- the backup passphrase and archives stay, unless `--delete-key` (archives always stay);
- inside a project, private: remove the pointers in `CLAUDE.local.md`, `QWEN.local.md` and an untracked `AGENTS.md` (a file left empty is deleted), the role files setup built in `.claude/agents/`, and their `.git/info/exclude` lines, so the project is as it was before `init`;
- inside a project, shared: remove the "Agent team" section from `AGENTS.md` and `CLAUDE.md` and the `@tarekraafat/cabinet` devDependency; you commit that change;
- delete the workspace folder.

| Option | Notes |
|---|---|
| `--dry-run` | Print the plan only. |
| `--yes`, `-y` | Do not ask. Without it you type the slug to confirm. |
| `--force` | Go ahead even when the workspace has uncommitted changes or commits on no remote. Without it, those stop the removal (`Not safe to delete`). |
| `--delete-key` | Also delete the backup passphrase `cabinet.<slug>.backup` from the keychain or secret store, and its passphrase file if there is one. |

The guardrails in your agent tools stay, since other workspaces use them. Exit codes: 0, or 1 when refused or not confirmed.

## cabinet update

```sh
cabinet update
```

Copies the installed kit's files into the workspace, rebuilds the roles, and prints every changelog section between the workspace's old version and the new one. It never replaces a kit file that was edited in the workspace: it stops, names the file, and keeps the old version (exit 1). In a workspace with its own git it then commits the update (`cabinet: update to <version>`, with the pin in `package.json` and its lockfile; when `package.json` holds other edits of yours, it leaves `package.json` and its lockfile out and prints the commit for them, naming `package-lock.json` only when git tracks it), unless the files it rewrites (`.cabinet/`, `CABINET.md`, `bin/`, `agents/`, `.claude/agents/`, `ORG.md`) held uncommitted edits of yours: then, and in a shared `cabinet/`, it ends with the exact `git add` and `git commit` to run. When the workspace was already on that version and nothing changed, it ends with `Nothing changed: the workspace was already on <version>.`, git or not. Otherwise, with nothing to commit (no git of its own, or a private `cabinet/` the project ignores), it ends with `Updated to <version>.`

## cabinet status

```sh
cabinet status [--json]
```

Prints the workspace's kit version, the installed kit's version, and every kit file edited in the workspace. `--json` prints `{workspace, version, kit_version, kit, edited}`.

## cabinet outdated

```sh
cabinet outdated [--json]
```

Compares the workspace's kit version, the installed kit and the newest version on the npm registry, and says what to run. Without the registry it says the newest is unknown. Exit 0.

## cabinet changelog

```sh
cabinet changelog [from-version] [--json]
```

Prints the changelog sections newer than `from-version` (all of them when it is left out). In a terminal it shows them for reading, as `cabinet update` does: versions and headings in bold, without the Markdown marks, wrapped at words to the terminal's width; piped, or with `NO_COLOR` set, it prints the Markdown as written.

## cabinet completion

```sh
eval "$(cabinet completion zsh)"     # in ~/.zshrc
eval "$(cabinet completion bash)"    # in ~/.bashrc
```

Tab completion for commands, their verbs and options, and the job names of the nearest workspace after `cabinet job run`.

## cabinet version

```sh
cabinet version [--json]
```

Prints the installed kit's version. In a terminal it prints the Cabinet mark with the version and the tagline beside it ("One person, a whole team. Build anything with AI agents, and stay in charge."): seven seats around a table, with the eighth left open for the owner. It draws the seats as dots when the terminal's locale is UTF-8, and as the letter `o` otherwise. When the output goes to a script or a file, it prints only `cabinet <version>`.

## Which copy of Cabinet runs

`cabinet update`, `status` and `config` hand off to the workspace's own pinned copy when it exists (`<workspace>/node_modules/@tarekraafat/cabinet`, or the project's `node_modules` above a shared `cabinet/`), so they always act with the project's version. They do this only in a Cabinet workspace: the nearest from the current folder upward (after `-C`). `new`, `init`, `changelog` and `version` always run the copy you called.

## Workspace scripts

Every workspace has its own scripts in `bin/` (`cabinet/bin/` inside a project), named like the commands: one script per noun, taking the verb, and one per one-word command that has a script. Agents, the schedules and a machine without the `cabinet` command use them; all of them read `cabinet.env`, and their options and exit codes are the commands'.

| Command | Script |
|---|---|
| `cabinet doctor` | `bin/doctor.sh` |
| `cabinet bootstrap` | `bin/bootstrap.sh` |
| `cabinet move` | `bin/move.sh` |
| `cabinet brief` | `bin/job.sh run brief` |
| `cabinet job run`, `job list` | `bin/job.sh run <job>`, `bin/job.sh list` |
| `cabinet handoff add`, `attach`, `record`, `list`, `run`, `archive` | `bin/handoff.sh add`, `attach`, `record`, `list`, `run`, `archive` |
| `cabinet spec check`, `record`, `run` | `bin/spec.sh check`, `record`, `run` |
| `cabinet manual build` | `bin/manual.sh build` |
| `cabinet role list`, `draft`, `build` | `bin/role.sh list`, `draft <role>`, `build` (`role add` and `remove` need the `cabinet` command: they change settings) |
| `cabinet repo list`, `remove`, `snapshot` | `bin/repo.sh list`, `remove <name>`, `snapshot` (`repo add` needs the `cabinet` command) |
| `cabinet secret check` | `bin/secret.sh check` |
| `cabinet backup create`, `verify`, `restore` | `bin/backup.sh create`, `verify`, `restore` |

## Output for agents and scripts

Text output is for people and may be reworded at any time. For a script or an agent, use JSON: a field or ID is never renamed or removed without a changelog entry that says so.

In a terminal, text output is styled for people, in the terminal's own colors: headings, first lines and the command to run next in bold; folders, dates and handoff IDs dim; `ok` green, notes blue, problems and errors (`cabinet:`) red; and what waits on you in yellow, never as a status. `cabinet update` and `cabinet changelog` show the changelog without its Markdown marks, wrapped at words to the terminal's width (`COLUMNS` when set, else 80 when the width is unknown). Output is styled only when it goes to a terminal, `NO_COLOR` is unset or empty and `TERM` is not `dumb`. Piped, written to a file, with `--json`, or with color turned off, it is plain text with no escape codes. To turn it off: `NO_COLOR=1 cabinet next` for one command, or `export NO_COLOR=1` in your shell's profile for all of them.

| Command | Prints |
|---|---|
| `cabinet help --json`, `cabinet help <command> --json` | `{name, version, docs, commands: [{name, group, usage, summary, options: [{name, value, text}]}]}` |
| `cabinet next --json` | `{workspace, project, steps: [{id, text, command}], optional: [...]}`. Step IDs: `deps`, `tbd`, `commit`, `install`, `bootstrap`, `credit-roles`, `handoffs`, `brief`, `doctor`; `command` is empty when the step is not a command. Outside a workspace, `workspace` is `null` and the one step is `start`. |
| `cabinet doctor --json` | `{workspace, problems, notes, can_fix, results: [{level, section, id, message}]}`. `level` is `ok`, `fix` or `note`; `id` names the check (every ID is in [troubleshooting](troubleshooting.md)) and does not change when its message is reworded. Exit 1 when `problems` is above 0. |
| `cabinet handoff list --json` | The open and acknowledged entries, oldest first: `[{id, status, status_line, date, age_days, from, to, title, verdicts, needs, missing, blocking, stale, ready, unread_verdicts}]`. `date` and `age_days` are `null` when the status line has no date. `verdicts` is `[{role, verdict, date, commits, note}]` (`commits` empty for `none`); `needs`, `missing`, `blocking` and `stale` are role names (where a sub-team role covers the sender's work, it is named in place of its lead, and both during its trial); `ready` is `true`, `false`, or `null` when the entry needs no review; `unread_verdicts` lists lines with PASS, BLOCK or CHANGES outside a Verdict line. `areas` are the critical areas it touches, by its commits or its spec; `depends_on` is the entry's "Depends on" line, `small` and `spec` say how it was filed, and `cost_usd` is what the agent runs recorded under its ID cost (`handoff run`), or `null`. `--ready` keeps only the entries with `ready` true. |
| `cabinet handoff list <name> --json` | Every entry addressed to that repo or role and not closed, with its full `text`. `owner` and `founder` are the same person. |
| `cabinet status --json` | `{workspace, version, kit_version, kit, edited}` |
| `cabinet digest --json` | `[{slug, project, path, exists, brief_written, brief_stale, sign_off_queue, queue_heading_found, actions_for_owner, waiting_on_owner, spend_this_week_usd, budget_usd}]`. The two parts are the Markdown under their headings, or `null`; `queue_heading_found` is `null` with no brief; `spend_this_week_usd` is `null` when the runner does not report cost, `budget_usd` when no budget is set. |
| `cabinet list --json` | `[{slug, project, path, exists, version, update_available, waiting_on_owner, doctor_problems, brief_written}]`. `brief_written` is ISO 8601 UTC, or `null`; the counts are `null` for a workspace whose folder is gone. |
| `cabinet role list --json` | `[{name, kind, on, drafted, reports_to, covers, trial_until, title, display_name, function}]`; `title` and `display_name` are `null` when not set; `reports_to` and `trial_until` are `null`, and `covers` empty, for a role in no sub-team. `kind` is `kit`, `optional`, `builder` or `project`; an optional kit role that is off is listed with `on: false`. |
| `cabinet repo list --json` | `[{name, path, present, owner, url}]`. `owner` is `null` while the team table says `TBD`; `url` is `null` for a repo with no clone URL. |
| `cabinet job list --json` | `[{name, role, when, timeout_minutes, cost_this_week_usd}]`. `when` is the schedule as people read it, or `by hand only`. `cost_this_week_usd` is `null` when the runner's runs are not counted in dollars (a token-only runner with no price, or `custom`). |
| `cabinet secret check --json` | `[{file, line, kind}]`, never the value. Exit 1 when the list is not empty. |
| `cabinet backup verify --json` | `{archive, backed_up, ok, problems, results: [{repo, result, text}]}`. `result` is `ok`, `skipped` or `problem`; `repo` is `null` for the archive as a whole. Exit 1 when `ok` is false. |
| `cabinet outdated --json` | `{workspace_version, kit_version, latest, update_available}`. `latest` and `update_available` are `null` when the registry cannot be reached. |
| `cabinet changelog --json` | `[{version, date, text}]`, newest first. `date` is as written (`Unreleased` until a release). |
| `cabinet version --json` | `{name, version}` |

## Files you can edit

### cabinet.env

| Key | Meaning |
|---|---|
| `CABINET_PROJECT` | Display name. |
| `CABINET_SLUG` | Short name for everything machine-wide. Change it with `cabinet config --slug`. |
| `CABINET_ROLES` | Roles to build, space separated. |
| `CABINET_RUNNER` | `claude`, `codex`, `antigravity`, `qwen`, `grok`, `opencode`, `cursor` or `custom`. |
| `CABINET_RUNNER_CMD` | With `custom`: the command, single-quoted. |
| `CABINET_LAYOUT` | `new`, `around`, `inside` or `beside`. Set by setup; not changed by `config`. |
| `CABINET_VISIBILITY` | Inside only: `private` or `shared`. |
| `CABINET_BACKUP_DIR` | Absolute folder for archives, outside the workspace and its repos; empty turns backups off. |
| `CABINET_BACKUP_TIME` | Time of the daily backup, like `1:00 PM` (default). |
| `CABINET_BACKUP_KEEP` | How many of this workspace's archives to keep (default 14, at least 1). |
| `CABINET_JOB_TIMEOUT` | Minutes a job may run before it is stopped, for jobs without their own `TIMEOUT` (default 60; `0` for no limit). |
| `CABINET_BUDGET` | A weekly budget in US dollars for the agent runs Cabinet starts; empty for none. The doctor warns from 80% (`spend.budget`). See [what agent runs cost](concepts.md#what-agent-runs-cost). |
| `CABINET_PRICE` | Dollars per million tokens, `"<input> <output> [<cached input>]"`, to count runs of a runner that reports only tokens; empty for none. |
| `CABINET_CREDIT_ROLES` | [Credit roles](concepts.md#credit-roles): `on` or `off`. Missing (a workspace from before it): off, and `cabinet next` and the brief ask once. Any other value is off, and the doctor reports it (`credit.setting`). |
| `CABINET_CREDIT_EMAIL` | With `on`: your own GitHub App's bot noreply email; empty for the Cabinet Team app's. A value that is not that format credits nothing, and the doctor reports it (`credit.email`). |
| `CABINET_SKILLS`, `CABINET_PLUGINS` | Claude Code skills and plugins the doctor expects (a missing one is a note). |

### jobs/&lt;job&gt;.job

One scheduled agent run each. Keys: `AGENT` (the role), `PROMPT` (or, instead of both, `COMMAND`: a command run in the workspace that starts and limits its own agent runs, as `jobs/pipeline.job` runs `bin/handoff.sh run --scheduled`), `WHEN` (a [schedule time](#schedule-times), or empty for by hand only), `MINUTES` and `RESULT` (shown when run by hand), `TIMEOUT` (whole minutes before the run is stopped, with everything it started, and the reason written to its log; empty uses `CABINET_JOB_TIMEOUT`, `0` means no limit), `AFTER` (an optional shell command run in the workspace after a successful run), `QUIET_DAYS` (whole days; empty or `0` runs every time). After a change, run `bin/bootstrap.sh`.

**Quiet days.** With `QUIET_DAYS`, a scheduled run starts no agent when nothing changed since the job's last full run: no commit, branch or fetch in the workspace, the project around it or any repo, no new doctor problem (by check ID), and the `RESULT` file as that run left it (an answer written into `BRIEF.md` counts as a change). It logs `<job> skipped: nothing changed since the full run of <time>` and touches the `RESULT` file, so `cabinet digest` and `cabinet next` see the brief as current. It never skips when any of those folders has uncommitted changes (the brief asks about work pending for more than a day), when the sign-off queue in the `RESULT` file holds a `default` item (it goes ahead after 72 hours of silence, and only a run says so), after a failed run, or once `QUIET_DAYS` days have passed since the last full run. A run by hand always runs. The brief has `QUIET_DAYS="6"`: on a quiet week, one full run a week. The state is `<job>.quiet` in the log folder, on this machine only.

### cabinet.local.env

Settings for this machine only. Git never tracks it (the workspace's `.gitignore` tracks only its own files), so in a shared workspace each teammate's machine keeps its own. It is read, never run as shell. Its keys:

| Key | Meaning |
|---|---|
| `CABINET_SCHEDULES` | `off`: this machine schedules none of the jobs in `jobs/` (another machine runs them). Set and cleared with `cabinet bootstrap --no-schedules` and `--schedules`. Jobs still run by hand with `cabinet job run <job>`. |
| `CABINET_BACKUP_DIR`, `CABINET_BACKUP_TIME` | When present, they replace `cabinet.env`'s on this machine; an empty `CABINET_BACKUP_DIR` turns backups off here. Set with `cabinet config --this-machine`, removed with `cabinet config --this-machine --clear`. |
| `CABINET_CREDIT_ROLES` | This machine's credit roles answer, `on` or `off`, in place of `cabinet.env`'s. In a shared workspace it is the only answer that counts: until it is there, this machine credits nothing. Set with `cabinet config --this-machine --credit-roles off\|on`, and by `config --credit-roles` and `init` in a shared workspace. |

### Schedule times

Every schedule takes the same forms: the brief (`--brief-time`), any job (`WHEN` in `jobs/<job>.job`) and the digest (`cabinet digest --schedule`).

| Form | Means |
|---|---|
| `7 AM`, `7:00 AM`, `7am`, `daily 7 AM` | Every day at 7:00 AM. |
| `fri 4 PM`, `Friday 4:00 PM` | Every Friday at 4:00 PM. |
| `fri,sat 10:30 AM` | Every Friday and Saturday at 10:30 AM. |
| `sun,mon,tue,wed,thu 8 AM` | Sunday to Thursday at 8:00 AM. |
| `12 PM`, `12 AM` | Noon, midnight. |

Times are 12-hour, with `AM` or `PM` in any case (`pm`, `p.m.` too); the minutes can be left out (`4 PM`). A time without AM or PM is read as 24-hour (`16:00` is 4:00 PM, `7:00` is 7:00 AM), so files and scripts written that way keep working; a bare hour (`10`) is refused, since it could be either. Put a time with a space in quotes on the command line: `--brief-time "fri 4 PM"`.

Days are `sun`, `mon`, `tue`, `wed`, `thu`, `fri`, `sat`, or their full names, in any case, separated by commas. All the days named share one time. Naming all seven is the same as every day. Setup and config store one form, `fri,sat 10:30 AM`, and every message shows times as `4:00 PM`.

### repos.tsv

Tab separated, one row per repo: name, clone URL (`-` for none), local-only files (space separated, `-` for none), `CLAUDE.md` link (`yes` or `no`), and an optional path where the repo lives (absolute, `~/...`, or relative to the workspace; default `<workspace>/<name>`). Windows line endings are fine. A row whose name is not a plain folder name is skipped with a message.

## Environment variables

| Variable | Used by | Meaning |
|---|---|---|
| `CABINET_BACKUP_PASSPHRASE` | backup, restore, doctor | The archive passphrase, instead of the item `cabinet.<slug>.backup` in the keychain, the secret store or the passphrase file. Never put it in `cabinet.env`, which git tracks. |
| `CABINET_SCHEDULER` | bootstrap, doctor, digest, config, remove, move | `launchd`, `systemd`, `cron` or `none`: the scheduler to use instead of the one Cabinet finds ([macOS and Linux](concepts.md#macos-and-linux)). |
| `CABINET_PROMPT` | the `custom` runner | The prompt, for `CABINET_RUNNER_CMD`. |
| `CABINET_AGENT` | every runner | The role of the run, set for the agent tool and everything it starts; the credit hook reads it. |
| `CABINET_CREDIT`, `CABINET_CREDIT_ADDRESS` | every runner | Set by a run for the credit hook: `on` or `off`, and the email its line carries ([credit roles](concepts.md#credit-roles)). |
| `CABINET_TTY` | setup, config, remove | Read answers from this file instead of the terminal (the tests use it). |
| `CABINET_PRIVATE_WORDS` | `npm test` | Words that must not appear in the kit. |
| `NO_COLOR` | every command | Set to anything but empty: plain text with no color, bold or dim, even in a terminal ([output](#output-for-agents-and-scripts)). |
| `TERM` | every command | `dumb`: the same as `NO_COLOR`. |
| `COLUMNS` | update, changelog | The width the changelog wraps at in a terminal; default: the terminal's own width, else 80. |

## Removing a workspace

`cabinet remove` does all of this (see [cabinet remove](#cabinet-remove)). By hand:

1. Stop its schedules. On macOS: `launchctl bootout gui/$(id -u)/ai.cabinet.<slug>.<job>` for each, then delete `~/Library/LaunchAgents/ai.cabinet.<slug>.*.plist`. With systemd: `systemctl --user disable --now ai.cabinet.<slug>.<job>.timer` for each, then delete `~/.config/systemd/user/ai.cabinet.<slug>.*.service` and `.timer`. With cron: delete `~/.config/cabinet/cron/ai.cabinet.<slug>.*.cron`, then run `cabinet bootstrap` in any other workspace, which rewrites Cabinet's block of the crontab (or delete its lines from `crontab -e` by hand).
2. Delete its log folder (`~/Library/Logs/cabinet/<slug>/` on macOS, `~/.local/state/cabinet/<slug>/` on Linux), which also frees the slug.
3. If it had backups: `security delete-generic-password -a "$USER" -s cabinet.<slug>.backup` (on Linux: `secret-tool clear service cabinet.<slug>.backup account "$USER"`, or delete `~/.config/cabinet/passphrases/cabinet.<slug>.backup`), and delete its archives if you no longer want them.
4. Delete the workspace folder.
5. Inside a project: for private, remove the `/cabinet/`, `/CLAUDE.local.md`, `/QWEN.local.md`, `/AGENTS.md` (if setup created it) and `/.claude/agents/<role>.md` lines from the project's `.git/info/exclude`, and the files they name if setup made them; for shared, remove the "Agent team" section and the `@tarekraafat/cabinet` devDependency from the project.

The guardrails stay; see [guardrails](guardrails.md#undoing-the-guardrails).
