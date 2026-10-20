# Commands

Every command cabinet has, its options and defaults, what it changes, and its exit codes. `cabinet help` (or `cabinet` alone) lists them; `cabinet <command> --help` (or `cabinet help <command>`) shows one command's usage and options, and a noun alone (`cabinet role`) shows its verbs. Agents and scripts: `cabinet help --json` gives every command and option, and every command that reports prints JSON (see [Output for agents and scripts](#output-for-agents-and-scripts)).

## Contents

- [How commands are named](#how-commands-are-named)
- Start: [cabinet new](#cabinet-new), [cabinet init](#cabinet-init)
- Daily: [cabinet next](#cabinet-next), [cabinet brief](#cabinet-brief), [cabinet digest](#cabinet-digest), [cabinet list](#cabinet-list), [cabinet doctor](#cabinet-doctor)
- Team: [cabinet role](#cabinet-role), [cabinet handoff](#cabinet-handoff)
- Work: [cabinet repo](#cabinet-repo), [cabinet job](#cabinet-job)
- Safety: [cabinet secret](#cabinet-secret), [cabinet backup](#cabinet-backup)
- Setup: [cabinet bootstrap](#cabinet-bootstrap), [cabinet config](#cabinet-config), [cabinet move](#cabinet-move), [cabinet remove](#cabinet-remove)
- Kit: [cabinet update](#cabinet-update), [cabinet status](#cabinet-status), [cabinet outdated](#cabinet-outdated), [cabinet changelog](#cabinet-changelog), [cabinet completion](#cabinet-completion), [cabinet version](#cabinet-version)
- [Which copy of cabinet runs](#which-copy-of-cabinet-runs)
- [Workspace scripts](#workspace-scripts): the same commands without the `cabinet` command
- [Output for agents and scripts](#output-for-agents-and-scripts): `--json`
- [Files you can edit](#files-you-can-edit): `cabinet.env`, `jobs/<job>.job`, `cabinet.local.env`, `repos.tsv`
- [Environment variables](#environment-variables)
- [Removing a workspace](#removing-a-workspace)

## How commands are named

Once you know one command, you can guess the next:

- **One word** acts on the workspace as a whole, or on this machine: `cabinet doctor`, `cabinet update`.
- **A noun, then a verb** acts on something the workspace holds: `cabinet role add`, `cabinet repo list`, `cabinet handoff archive`. The nouns are `role`, `handoff`, `repo`, `job`, `secret` and `backup`, always singular.
- **The verbs** mean the same on every noun: `add` (put one in, or turn on one the kit has), `remove` (take one out), `list` (show them), `check` (look for problems), and a few a noun needs: `role draft`, `role build`, `handoff attach`, `handoff record`, `handoff archive`, `repo snapshot`, `job run`, `backup create`, `backup verify`, `backup restore`.
- **The same options everywhere:** `--json` on every command that reports, `--dry-run` on every command that changes the setup or deletes anything, `--yes` (`-y`) on every command that asks.
- **Any workspace, from anywhere:** every command finds the workspace from the folder you are in, upward, so it works anywhere inside the workspace or the project around a `cabinet/` workspace. `cabinet -C <dir> <command>` runs it as if started in `<dir>`, as git does.
- **Exit codes:** 0 done (or nothing found), 1 failed or found a problem, 2 wrong usage (an unknown command or option, a missing value).
- **The same words without the `cabinet` command:** every workspace has its scripts in `bin/`, named the same way (`bin/role.sh build`, `bin/handoff.sh list qa`), for agents, schedules and machines without the command ([Workspace scripts](#workspace-scripts)).

## cabinet new

```sh
cabinet new [dir] [options]
```

Creates a workspace in an empty or missing folder. In a terminal it asks a question for each setting; options set the defaults, and `--yes` skips the questions.

**Tools first.** `new`, `init` and `bootstrap` first check for the tools cabinet needs (git, jq, perl, python3, node, npm). When one is missing, they name it and the command that installs it here (`brew install`, or `sudo apt-get`, `dnf` or `pacman` on Linux). In a terminal they offer to run it and go on once it worked; with `--yes` or `--dry-run` they never install, and stop with that command (exit 1).

| Option | Default | Notes |
|---|---|---|
| `[dir]` | asked (`~/dev/<name>`) | Must not exist, or be empty. |
| `--name "Name"` | the folder name | The project's display name. |
| `--slug <slug>` | the folder name, made lowercase with dashes | Lowercase letters, digits and dashes. Refused when another workspace on this machine holds it. |
| `--owner "Name"`, `--email you@example.com` | `git config --global user.name` / `user.email` | The commit author written into `AGENTS.md`. With no identity, setup does not commit. |
| `--roles "qa security ..."` | all seven | `chief-of-staff` is always added. The optional kit roles `brand-designer`, `dba`, `code-reviewer` and `auditor` are off unless named. Builders are never listed here: they come with the repos they own. |
| `--runner <tool>` | the first installed of `claude`, `codex`, `antigravity` (`agy`), `qwen`, `grok`, `opencode`, `cursor`, else `claude` | The agent tool for scheduled jobs. `cursor` means the Cursor CLI, never the editor's `cursor` command. `custom` needs `--runner-cmd`. |
| `--runner-cmd '<command>'` | none | With `--runner custom`: the command to run, using `"$CABINET_PROMPT"` (and `$CABINET_AGENT`). No single quotes. |
| `--brief-time <when>` | `7:00 AM` | When the brief is written: a time every day (`"7 AM"`), or days and a time, one day (`"fri 4 PM"`) or several (`"sun,mon,tue,wed,thu 8 AM"`), or `off`. See [Schedule times](#schedule-times). |
| `--week-start <day>` | `sunday` | Written into `AGENTS.md` house rules. |
| `--budget <dollars>\|off` | off | A weekly budget in US dollars for the agent runs cabinet starts, in `cabinet.env`. Asked for every built-in runner ([what agent runs cost](concepts.md#what-agent-runs-cost)). |
| `--price "<input> <output> [<cached>]"\|off` | off | Dollars per million tokens, for a runner that reports only tokens (`codex`, `cursor`, `qwen`, `antigravity`), in `cabinet.env`. Asked after the budget for those runners. |
| `--writing short\|standard` | `standard` | How agents write to you, written into `AGENTS.md` house rules. `short` gives the shortest briefs, questions and answers: answer first, one point per line, three points at most, a decision in three lines. See [writing to the owner](concepts.md#writing-to-the-owner). |
| `--backup-dir <folder>` | `off` | Made absolute. Refused when it is inside the workspace or any repo it lists. |
| `--repo <git url>` | none | Repeatable. `https://`, `http://`, `ssh://`, `git://`, `file://`, `git@host:path`, an absolute path, or `./` / `../` (relative to the workspace). Two repos with the same name are refused. |
| `--dry-run` | | Prints everything setup would write and change, then stops: `Nothing was written.` |
| `--yes`, `-y` | | No questions: defaults and options only. |

Values written into `cabinet.env` (name, owner, email, backup folder) cannot contain `$`, a backtick, a backslash, a double quote or a line break.

**What it writes:** the project files from the kit's templates (`AGENTS.md`, `cabinet.env`, `HANDOFFS.md`, `OPERATIONS.md`, `README.md`, `repos.tsv`, `jobs/brief.job`, `roles/`, `guides/`, `specs/`, `notes/`, `package.json`, `.gitignore`), the kit files (`CABINET.md`, `bin/`, `.cabinet/`), the built roles (`agents/`, `.claude/agents/`), and `CLAUDE.md` as a link to `AGENTS.md`. Then `git init` and one commit of those files. It records the slug in `~/Library/Logs/cabinet/<slug>/workspace`.

**In a terminal, afterwards:** it offers `npm install` (to download the pinned kit) and `bin/bootstrap.sh` (shown as a dry run first, and applied only when you say yes).

**If it fails part way:** it removes the folder it created, or empties the empty folder it was given, and nothing else.

## cabinet init

```sh
cabinet init [dir] [options]
```

Adds cabinet to an existing folder (default: the current one). It takes every option of `cabinet new`, and these:

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

Says what to do next in the workspace you are in, as a numbered list, and changes nothing: missing tools cabinet needs (step `deps`, with the install command), the `TBD` headings left in `AGENTS.md`, a workspace with no commits, a pinned kit not yet downloaded, a machine without the push gate or schedules (`cabinet bootstrap`), handoffs waiting on the owner, today's brief (with when it was written) or when the first one comes, and how many problems the doctor finds. Outside a workspace it says how to start one. When nothing waits: `Nothing waits on you.` Each step ends with the command that does it, when there is one.

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
| `--file <file>` | With `--schedule`: where it is written. Default `digest.md` in the log folder (`~/Library/Logs/cabinet/` on macOS, `~/.local/state/cabinet/` on Linux), which a scheduled job can always write. macOS may block a scheduled job from writing to Documents, Desktop, Downloads or iCloud Drive until you allow it (System Settings > Privacy & Security > Files and Folders); cabinet says so when you choose one. |
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

Checks everything: repos, kit files, roles, guardrails for every installed tool, the manual, handoff IDs, secrets in the workspace's files, uncommitted work, schedules, backups. It starts with a summary (`N thing(s) need attention:` and the list, or `All good.`), then the full report. Changes nothing in the workspace or your settings (it runs `opencode debug` and `grok inspect`, which may write their own caches). `--fix` then runs the fixes it knows (`bin/bootstrap.sh`, `bin/role.sh build`, `bin/repo.sh snapshot`, and installing missing tools), asking before each unless `--yes`, and checks again. Installing tools always asks in a terminal, even with `--yes`: it changes the machine and can need your password. `--json` prints the results for scripts (see [Output for agents and scripts](#output-for-agents-and-scripts)). Every message is explained in [troubleshooting](troubleshooting.md). Exit 0, or 1 when anything says FIX.

## cabinet role

```sh
cabinet role add <name> [--does "..."] [--owns "..."] [--decides "..."] [--escalates "..."] [--draft] [--dry-run] [--yes]
cabinet role remove <name> [--dry-run]
cabinet role list [--json]
cabinet role draft <name>
cabinet role build [--check]
```

**`add`** turns on a kit role (`cabinet role add dba`), or adds a role of the project's own from as little as its name (lowercase letters, digits and dashes, not a builder's name). For a role of its own, in a terminal with no option given, it asks what the role should do, what it owns, what it may decide on its own and what it must bring to you; Enter skips any of them, and `--does`, `--owns`, `--decides` and `--escalates` give those answers instead. It writes `roles/<name>.md` with your answers word for word under "The owner's brief" (`not said yet` for the rest) and a `TBD` description. Either way the role is turned on through `cabinet config --roles`, which adds its rows to the team tables and builds it. A new role does only what the brief asks until it is drafted. `--draft`, or yes to the question that follows in a terminal, drafts it at once; `--yes` asks nothing; `--dry-run` says what it would do.

**`remove`** turns a role off: its built files and its rows in the team tables go. A role of the project's own keeps `roles/<name>.md`; delete it to drop the role for good. chief-of-staff is always on. Builders come and go with the repos they own in the team table, not through `role add` or `remove`.

**`list`** shows every role on the team (kit, optional, builder or project; a project role not yet drafted is marked) and the optional kit roles that are off.

**`draft`** has an agent write the whole role for this project, as `CABINET.md`, "Drafting a role", says: it keeps your brief, learns the rest from the project, writes the role, lists what it assumed for you to confirm, fills the team table rows and commits. It runs the configured agent tool as chief-of-staff (a few minutes; it may cost money), logging to `~/Library/Logs/cabinet/<slug>/role-<name>.log`. In an agent session, asking the agent to draft the role does the same. Add to the brief at any time and draft again.

**`build`** builds `agents/<role>.md` and `.claude/agents/<role>.md` for every role (and, inside a project, the project's `.claude/agents/` and pointer files); `--check` only reports. Setup, config, update and bootstrap run it for you.

Exit 0; 1 when the role could not be added, removed or drafted, or `build --check` finds a role missing or out of date; 2 for a name that is not valid.

## cabinet handoff

```sh
cabinet handoff add --from <name> --to <name> --changed "..." --needed "..." [--depends-on "..."] [--evidence <file or URL>]... "<title>"
cabinet handoff attach <ID> <file or URL>... --from <name>
cabinet handoff record <ID> --role <role> <PASS|BLOCK|CHANGES> --commits <hash,...> --note <file>
cabinet handoff list [name] [--json]
cabinet handoff archive
```

**`add`** files one handoff: appends the entry at the bottom of "Open" in `HANDOFFS.md` with the next free ID for today (`H-20261019-01`, unique across `HANDOFFS.md` and the archives), today's date, status `open` and the template's lines, then commits it on its own (`handoffs: <ID> <title>`). `--depends-on` defaults to `none`. Each value is kept on one line. It prints the new ID first. When `HANDOFFS.md` already has someone else's uncommitted lines, it writes the entry but does not commit, so their lines never go into its commit. Two agents filing at once get different IDs: each write takes a lock (`.cabinet/handoff.lock`), and a lock left for more than a minute by a writer that was stopped is taken over. Entries are filed only this way, never by hand, so no two take the same ID. Two copies of a workspace (a teammate's clone) do not share the lock; `cabinet doctor` flags an ID used twice after they are merged (`handoffs.unique-ids`).

`--evidence`, once for each, attaches what shows the work, so you can check it without reading code: a file (a screenshot, a short recording, saved command output) is copied to `specs/evidence/<ID>/` with a name safe in a link and committed with the entry; an `http` or `https` link is kept as it is. The entry gets an `Evidence:` line of links from the workspace root, which open with a click from `HANDOFFS.md` and `BRIEF.md` in an editor or on GitHub. `archive` rewrites them to open from `handoffs/`, and `cabinet digest` to full paths. A file path is read from the folder you run it in, else from the workspace.

**`attach`** adds evidence to an open handoff after it was filed (after a BLOCK, a fix, a missed screen), the same way `--evidence` does: files copied to `specs/evidence/<ID>/`, every link added to the entry's `Evidence:` line, committed. Only the entry's sender may: `--from` must match its `From:`.

**`record`** writes a reviewer's verdict on an open handoff as one line, `- Verdict: <role> <PASS|BLOCK|CHANGES> <YYYY-MM-DD> <commits> <note>`, with today's date, replacing that role's earlier verdict, and commits it (`handoffs: <ID> <role> <verdict>`). The verdict may be in any case; commits may be joined by commas or spaces. It refuses when the note is not a committed `.md` file under `specs/` (read from the folder you run it in, else from the workspace), when the role is the entry's sender (the builder never verifies its own work), and a qa PASS on an entry with no evidence: qa records BLOCK instead, and the sender runs `attach`.

**`list`**, without a name: every open handoff with its age in days, oldest first (`?` when it has no date). With a repo or role name (`qa`, `owner`): every entry addressed to it, in full; this is the start-of-session read.

**`archive`** moves every committed `done` or `rejected` handoff to `handoffs/archive-YYYY-MM.md` and commits the move; chief-of-staff runs it daily. It refuses while `HANDOFFS.md` has uncommitted lines.

`add`, `attach` and `record` write one at a time, and with someone else's uncommitted lines in `HANDOFFS.md` they write but do not commit.

Exit 0; 1 when `add` could not commit (the entry is written), `attach` or `record` refuses (no such open entry, not its sender, a note not committed, the builder's own verdict, a qa PASS with no evidence), or `archive` meets uncommitted lines; 2 for a missing value, an unknown option, a value in the wrong form, or evidence that is neither a file nor an `http(s)` link.

## cabinet repo

```sh
cabinet repo add <git url> [--apply] [--dry-run]
cabinet repo remove <name> [--dry-run]
cabinet repo list [--json]
cabinet repo snapshot
```

**`add`** adds a product repo: a row in `repos.tsv` and in the team table of `AGENTS.md`, through `cabinet config --repo`, with the same checks as setup. `cabinet bootstrap` then clones it and gives it a builder; `--apply` runs bootstrap right away.

**`remove`** takes a repo out of the workspace: its row in `repos.tsv` and in the team table. Its folder, its history and `local/<name>/` are left as they are. `bin/doctor.sh` then notes any open handoff still addressed to it.

**`list`** shows every repo: its owner in the team table, whether it is on this machine, and where it lives.

**`snapshot`** copies each repo's local-only files and `.git/info/exclude` entries into `local/<repo>/`, so they can be reviewed and committed in the workspace. The backup runs it first.

Exit 0; 1 for a repo that is not in `repos.tsv`, or a URL setup refuses; 2 for wrong usage.

## cabinet job

```sh
cabinet job run <job>
cabinet job list [--json]
```

**`run`** runs `jobs/<job>.job` now with the configured agent tool, logging to `<job>.log` in the workspace's log folder (`~/Library/Logs/cabinet/<slug>/` on macOS, `~/.local/state/cabinet/<slug>/` on Linux), and stops it after its time limit (`TIMEOUT`, or `CABINET_JOB_TIMEOUT`). By hand it shows the result too; the scheduler runs the same on the job's schedule, except that a scheduled run of a job with `QUIET_DAYS` is skipped when nothing changed since its last full run (see below). **`list`** shows each job's role, schedule, time limit and [what it cost this week](concepts.md#what-agent-runs-cost), then the week's total and the budget.

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

Options: `--name`, `--slug`, `--owner`, `--email`, `--roles`, `--runner`, `--runner-cmd`, `--brief-time`, `--week-start`, `--writing`, `--backup-dir`, `--backup-time <time>` (like `"1 PM"`), `--budget <dollars>|off` (a weekly budget for the agent runs cabinet starts, like `20` or `12.50`), `--price "<input> <output> [<cached>]"|off` (dollars per million tokens, for a runner that reports only tokens), `--repo` (adds a repo, as `cabinet repo add` does), `--apply` (run `bin/bootstrap.sh` without asking), `--dry-run` (list the changes and write nothing), `--yes`.

**For this machine only:** `cabinet config --this-machine --backup-dir <folder>|off [--backup-time <time>]` writes the backup settings into `cabinet.local.env` instead of `cabinet.env`, so they apply on this machine and are never committed. In a shared workspace, each teammate picks their own backup folder, or none. `cabinet config --this-machine --clear` makes this machine follow `cabinet.env` again. With `--this-machine`, no other setting can be changed (they are shared by every machine), and nothing is asked.

**What it changes:**

| Setting | Where |
|---|---|
| Name | `CABINET_PROJECT`, and the titles setup wrote in `AGENTS.md`, `HANDOFFS.md`, `OPERATIONS.md`, `README.md`, `specs/ROADMAP.md`, plus the workspace's own `package.json` |
| Slug | `CABINET_SLUG`; stops the old schedules, renames them in `OPERATIONS.md`, `README.md` and `jobs/*.job`, claims the new slug and releases the old one, and says how to move the backup passphrase in the keychain |
| Owner and email | the "Commits" line in `AGENTS.md` |
| Roles | `CABINET_ROLES`, the team tables in `AGENTS.md` and `OPERATIONS.md` (a dropped role's row leaves; a returning kit role's row comes back; a project role gets a `TBD` row), and the built roles |
| Runner | `CABINET_RUNNER`, `CABINET_RUNNER_CMD` |
| Brief | `WHEN` in `jobs/brief.job` |
| Week start | the house rule in `AGENTS.md` |
| Writing | the "Writing to the owner" house rule in `AGENTS.md` (added after the week start when an older `AGENTS.md` lacks it) |
| Backups | `CABINET_BACKUP_DIR`, `CABINET_BACKUP_TIME` |
| Budget and price | `CABINET_BUDGET`, `CABINET_PRICE` |
| Repos | new rows in `repos.tsv` and the team table in `AGENTS.md` |

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

Copies the installed kit's files into the workspace, rebuilds the roles, and prints every changelog section between the workspace's old version and the new one. It never replaces a kit file that was edited in the workspace: it stops, names the file, and keeps the old version (exit 1). It ends with the exact `git add` and `git commit` to run.

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

Prints the changelog sections newer than `from-version` (all of them when it is left out).

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

Prints the installed kit's version.

## Which copy of cabinet runs

`cabinet update`, `status` and `config` hand off to the workspace's own pinned copy when it exists (`<workspace>/node_modules/@tarekraafat/cabinet`, or the project's `node_modules` above a shared `cabinet/`), so they always act with the project's version. They do this only in a cabinet workspace: the nearest from the current folder upward (after `-C`). `new`, `init`, `changelog` and `version` always run the copy you called.

## Workspace scripts

Every workspace has its own scripts in `bin/` (`cabinet/bin/` inside a project), named like the commands: one script per noun, taking the verb, and one per one-word command that has a script. Agents, the schedules and a machine without the `cabinet` command use them; all of them read `cabinet.env`, and their options and exit codes are the commands'.

| Command | Script |
|---|---|
| `cabinet doctor` | `bin/doctor.sh` |
| `cabinet bootstrap` | `bin/bootstrap.sh` |
| `cabinet move` | `bin/move.sh` |
| `cabinet brief` | `bin/job.sh run brief` |
| `cabinet job run`, `job list` | `bin/job.sh run <job>`, `bin/job.sh list` |
| `cabinet handoff add`, `attach`, `record`, `list`, `archive` | `bin/handoff.sh add`, `attach`, `record`, `list`, `archive` |
| `cabinet role list`, `draft`, `build` | `bin/role.sh list`, `draft <role>`, `build` (`role add` and `remove` need the `cabinet` command: they change settings) |
| `cabinet repo list`, `remove`, `snapshot` | `bin/repo.sh list`, `remove <name>`, `snapshot` (`repo add` needs the `cabinet` command) |
| `cabinet secret check` | `bin/secret.sh check` |
| `cabinet backup create`, `verify`, `restore` | `bin/backup.sh create`, `verify`, `restore` |

## Output for agents and scripts

Text output is for people and may be reworded at any time. For a script or an agent, use JSON: a field or ID is never renamed or removed without a changelog entry that says so.

| Command | Prints |
|---|---|
| `cabinet help --json`, `cabinet help <command> --json` | `{name, version, docs, commands: [{name, group, usage, summary, options: [{name, value, text}]}]}` |
| `cabinet next --json` | `{workspace, project, steps: [{id, text, command}], optional: [...]}`. Step IDs: `tbd`, `commit`, `install`, `bootstrap`, `handoffs`, `brief`, `doctor`; `command` is empty when the step is not a command. Outside a workspace, `workspace` is `null` and the one step is `start`. |
| `cabinet doctor --json` | `{workspace, problems, notes, can_fix, results: [{level, section, id, message}]}`. `level` is `ok`, `fix` or `note`; `id` names the check (every ID is in [troubleshooting](troubleshooting.md)) and does not change when its message is reworded. Exit 1 when `problems` is above 0. |
| `cabinet handoff list --json` | The open and acknowledged entries, oldest first: `[{id, status, status_line, date, age_days, from, to, title}]`. `date` and `age_days` are `null` when the status line has no date. |
| `cabinet handoff list <name> --json` | Every entry addressed to that repo or role and not closed, with its full `text`. `owner` and `founder` are the same person. |
| `cabinet status --json` | `{workspace, version, kit_version, kit, edited}` |
| `cabinet digest --json` | `[{slug, project, path, exists, brief_written, brief_stale, sign_off_queue, queue_heading_found, actions_for_owner, waiting_on_owner, spend_this_week_usd, budget_usd}]`. The two parts are the Markdown under their headings, or `null`; `queue_heading_found` is `null` with no brief; `spend_this_week_usd` is `null` when the runner does not report cost, `budget_usd` when no budget is set. |
| `cabinet list --json` | `[{slug, project, path, exists, version, update_available, waiting_on_owner, doctor_problems, brief_written}]`. `brief_written` is ISO 8601 UTC, or `null`; the counts are `null` for a workspace whose folder is gone. |
| `cabinet role list --json` | `[{name, kind, on, drafted}]`. `kind` is `kit`, `optional`, `builder` or `project`; an optional kit role that is off is listed with `on: false`. |
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
| `CABINET_BUDGET` | A weekly budget in US dollars for the agent runs cabinet starts; empty for none. The doctor warns from 80% (`spend.budget`). See [what agent runs cost](concepts.md#what-agent-runs-cost). |
| `CABINET_PRICE` | Dollars per million tokens, `"<input> <output> [<cached input>]"`, to count runs of a runner that reports only tokens; empty for none. |
| `CABINET_SKILLS`, `CABINET_PLUGINS` | Claude Code skills and plugins the doctor expects (a missing one is a note). |

### jobs/&lt;job&gt;.job

One scheduled agent run each. Keys: `AGENT` (the role), `PROMPT`, `WHEN` (a [schedule time](#schedule-times), or empty for by hand only), `MINUTES` and `RESULT` (shown when run by hand), `TIMEOUT` (whole minutes before the run is stopped, with everything it started, and the reason written to its log; empty uses `CABINET_JOB_TIMEOUT`, `0` means no limit), `AFTER` (an optional shell command run in the workspace after a successful run), `QUIET_DAYS` (whole days; empty or `0` runs every time). After a change, run `bin/bootstrap.sh`.

**Quiet days.** With `QUIET_DAYS`, a scheduled run starts no agent when nothing changed since the job's last full run: no commit, branch or fetch in the workspace, the project around it or any repo, no new doctor problem (by check ID), and the `RESULT` file as that run left it (an answer written into `BRIEF.md` counts as a change). It logs `<job> skipped: nothing changed since the full run of <time>` and touches the `RESULT` file, so `cabinet digest` and `cabinet next` see the brief as current. It never skips when any of those folders has uncommitted changes (the brief asks about work pending for more than a day), when the sign-off queue in the `RESULT` file holds a `default` item (it goes ahead after 72 hours of silence, and only a run says so), after a failed run, or once `QUIET_DAYS` days have passed since the last full run. A run by hand always runs. The brief has `QUIET_DAYS="6"`: on a quiet week, one full run a week. The state is `<job>.quiet` in the log folder, on this machine only.

### cabinet.local.env

Settings for this machine only. Git never tracks it (the workspace's `.gitignore` tracks only its own files), so in a shared workspace each teammate's machine keeps its own. It is read, never run as shell. Its keys:

| Key | Meaning |
|---|---|
| `CABINET_SCHEDULES` | `off`: this machine schedules none of the jobs in `jobs/` (another machine runs them). Set and cleared with `cabinet bootstrap --no-schedules` and `--schedules`. Jobs still run by hand with `cabinet job run <job>`. |
| `CABINET_BACKUP_DIR`, `CABINET_BACKUP_TIME` | When present, they replace `cabinet.env`'s on this machine; an empty `CABINET_BACKUP_DIR` turns backups off here. Set with `cabinet config --this-machine`, removed with `cabinet config --this-machine --clear`. |

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
| `CABINET_SCHEDULER` | bootstrap, doctor, digest, config, remove, move | `launchd`, `systemd`, `cron` or `none`: the scheduler to use instead of the one cabinet finds ([macOS and Linux](concepts.md#macos-and-linux)). |
| `CABINET_PROMPT`, `CABINET_AGENT` | the `custom` runner | The prompt and role, for `CABINET_RUNNER_CMD`. |
| `CABINET_TTY` | setup, config, remove | Read answers from this file instead of the terminal (the tests use it). |
| `CABINET_PRIVATE_WORDS` | `npm test` | Words that must not appear in the kit. |

## Removing a workspace

`cabinet remove` does all of this (see [cabinet remove](#cabinet-remove)). By hand:

1. Stop its schedules. On macOS: `launchctl bootout gui/$(id -u)/ai.cabinet.<slug>.<job>` for each, then delete `~/Library/LaunchAgents/ai.cabinet.<slug>.*.plist`. With systemd: `systemctl --user disable --now ai.cabinet.<slug>.<job>.timer` for each, then delete `~/.config/systemd/user/ai.cabinet.<slug>.*.service` and `.timer`. With cron: delete `~/.config/cabinet/cron/ai.cabinet.<slug>.*.cron`, then run `cabinet bootstrap` in any other workspace, which rewrites cabinet's block of the crontab (or delete its lines from `crontab -e` by hand).
2. Delete its log folder (`~/Library/Logs/cabinet/<slug>/` on macOS, `~/.local/state/cabinet/<slug>/` on Linux), which also frees the slug.
3. If it had backups: `security delete-generic-password -a "$USER" -s cabinet.<slug>.backup` (on Linux: `secret-tool clear service cabinet.<slug>.backup account "$USER"`, or delete `~/.config/cabinet/passphrases/cabinet.<slug>.backup`), and delete its archives if you no longer want them.
4. Delete the workspace folder.
5. Inside a project: for private, remove the `/cabinet/`, `/CLAUDE.local.md`, `/QWEN.local.md`, `/AGENTS.md` (if setup created it) and `/.claude/agents/<role>.md` lines from the project's `.git/info/exclude`, and the files they name if setup made them; for shared, remove the "Agent team" section and the `@tarekraafat/cabinet` devDependency from the project.

The guardrails stay; see [guardrails](guardrails.md#undoing-the-guardrails).
