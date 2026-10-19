# Commands

Every command cabinet has, its options and defaults, what it changes, and its exit codes. Two kinds:

- **`cabinet ...`**: the kit's command, installed globally or run with `npx`. It creates, changes and updates workspaces.
- **`bin/*.sh`**: scripts copied into every workspace. They run the workspace on this Mac. Each is also a `cabinet` command (`cabinet doctor` runs `bin/doctor.sh`) that works from any folder inside the workspace, or inside the project around a `cabinet/` workspace. Inside a project, the scripts themselves are `cabinet/bin/*.sh`.

`cabinet help` (or `cabinet` alone) lists every command; `cabinet <command> --help` (or `cabinet help <command>`) shows one command's usage and options. An unknown command exits 2. Agents and scripts: `cabinet help --json` gives every command and option, and several commands print JSON (see [Output for agents and scripts](#output-for-agents-and-scripts)).

## Contents

- [cabinet new](#cabinet-new)
- [cabinet init](#cabinet-init)
- [cabinet next](#cabinet-next)
- [cabinet list](#cabinet-list)
- [cabinet digest](#cabinet-digest)
- [cabinet config](#cabinet-config)
- [cabinet remove](#cabinet-remove)
- [cabinet update](#cabinet-update), [cabinet status](#cabinet-status), [cabinet outdated](#cabinet-outdated), [cabinet changelog](#cabinet-changelog), [cabinet completion](#cabinet-completion), [cabinet version](#cabinet-version)
- [Which copy of cabinet runs](#which-copy-of-cabinet-runs)
- [Workspace scripts](#workspace-scripts): bootstrap, doctor, handoffs, handoff, archive-handoffs, secrets, roles, scheduled, backup, restore, snapshot, move
- [Output for agents and scripts](#output-for-agents-and-scripts): `--json`
- [Files you can edit](#files-you-can-edit): `cabinet.env`, `jobs/<job>.job`, `cabinet.local.env`, `repos.tsv`
- [Environment variables](#environment-variables)
- [Removing a workspace](#removing-a-workspace)

## cabinet new

```sh
cabinet new [dir] [options]
```

Creates a workspace in an empty or missing folder. In a terminal it asks a question for each setting; options set the defaults, and `--yes` skips the questions.

| Option | Default | Notes |
|---|---|---|
| `[dir]` | asked (`~/dev/<name>`) | Must not exist, or be empty. |
| `--name "Name"` | the folder name | The project's display name. |
| `--slug <slug>` | the folder name, made lowercase with dashes | Lowercase letters, digits and dashes. Refused when another workspace on this Mac holds it. |
| `--owner "Name"`, `--email you@example.com` | `git config --global user.name` / `user.email` | The commit author written into `AGENTS.md`. With no identity, setup does not commit. |
| `--roles "qa security ..."` | all seven | `chief-of-staff` is always added. |
| `--runner <tool>` | the first installed of `claude`, `codex`, `gemini`, `qwen`, `grok`, `opencode`, `cursor`, else `claude` | The agent tool for scheduled jobs. `cursor` means the Cursor CLI, never the editor's `cursor` command. `custom` needs `--runner-cmd`. |
| `--runner-cmd '<command>'` | none | With `--runner custom`: the command to run, using `"$CABINET_PROMPT"` (and `$CABINET_AGENT`). No single quotes. |
| `--brief <when>` | `7:00 AM` | When the brief is written: a time every day (`"7 AM"`), or days and a time, one day (`"fri 4 PM"`) or several (`"sun,mon,tue,wed,thu 8 AM"`), or `off`. See [Schedule times](#schedule-times). |
| `--week-start <day>` | `sunday` | Written into `AGENTS.md` house rules. |
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

Says what to do next in the workspace you are in, as a numbered list, and changes nothing: the `TBD` headings left in `AGENTS.md`, a workspace with no commits, a pinned kit not yet downloaded, a Mac without the push gate or schedules (`cabinet bootstrap`), handoffs waiting on the owner, today's brief (with when it was written) or when the first one comes, and how many problems the doctor finds. Outside a workspace it says how to start one. When nothing waits: `Nothing waits on you.` Each step ends with the command that does it, when there is one.

## cabinet list

```sh
cabinet list [--json]
```

Every workspace on this Mac, from anywhere: its slug, project name, kit version (marked `*` when it is not the installed kit), how many handoffs wait on you, what the doctor finds, when the latest brief was written, and its folder. The doctors run side by side, each with its workspace's own scripts, so it takes about as long as one doctor run. A workspace is listed once setup or bootstrap has claimed its slug on this Mac; `cabinet remove` takes it off the list. A workspace whose folder is gone shows as `folder gone`, with how to free its slug. Changes nothing. Exit 0.

## cabinet digest

```sh
cabinet digest [--json]
cabinet digest --write <file> [--notify]
cabinet digest --schedule [<when>|off] [--file <file>] [--notify]
```

One morning read for every workspace on this Mac: from each one's latest `BRIEF.md`, the "Sign-off queue" and "Actions for the owner" parts, by their `## ` headings (the chief-of-staff role writes them with these names), and how many handoffs wait on you. It flags a brief older than a day and a half (is the brief job running?), a workspace with no brief yet, and a brief without the "## Sign-off queue" heading. It reads only: you still answer each queue in its own workspace, to that workspace's agent. It starts with one line of counts (decisions, actions and handoffs waiting, and briefs late, missing or unreadable), and ends by saying whether it is scheduled.

| Option | Notes |
|---|---|
| `--write <file>` | Write the digest to that file (replaced each time) instead of the screen. |
| `--notify` | Also show a macOS notification with the counts line. |
| `--schedule [<when>]` | Write it on a schedule. With no time: every day at 10:00 AM. Or any [schedule time](#schedule-times): `"8 AM"`, `"fri 10 AM"`, `"sun,mon,tue,wed,thu 8 AM"`. Run again to change it. `--schedule off` stops it and keeps the last file. |
| `--file <file>` | With `--schedule`: where it is written. Default `~/Library/Logs/cabinet/digest.md`, which a scheduled job can always write. macOS may block a scheduled job from writing to Documents, Desktop, Downloads or iCloud Drive until you allow it (System Settings > Privacy & Security > Files and Folders); cabinet says so when you choose one. |
| `--json` | The digest as JSON (below). |

The schedule is one launchd job for the whole Mac, `ai.cabinet-digest`, apart from every workspace's `ai.cabinet.<slug>.*` jobs; it runs this `cabinet` (so install it globally, not only through npx, whose cache can be cleared) and logs to `~/Library/Logs/cabinet/digest.log`. The first notification may need you to allow notifications for Script Editor, which macOS uses to show them. Exit 0, or 1 for a bad time or a schedule launchd would not load.

## cabinet config

```sh
cabinet config [dir] [options]
```

Changes a workspace's settings after setup. Run it in the workspace, or in the project's top folder when the workspace is `cabinet/` inside it. In a terminal it asks the setup questions again with the current answers as defaults, lists the changes, and asks before writing.

Options: `--name`, `--slug`, `--owner`, `--email`, `--roles`, `--runner`, `--runner-cmd`, `--brief`, `--week-start`, `--backup-dir`, `--backup-time <time>` (like `"1 PM"`), `--repo` (adds a repo; to remove one, edit `repos.tsv`), `--apply` (run `bin/bootstrap.sh` without asking), `--dry-run` (list the changes and write nothing), `--yes`.

**For this Mac only:** `cabinet config --this-mac --backup-dir <folder>|off [--backup-time <time>]` writes the backup settings into `cabinet.local.env` instead of `cabinet.env`, so they apply on this Mac and are never committed. In a shared workspace, each teammate picks their own backup folder, or none. `cabinet config --this-mac --clear` makes this Mac follow `cabinet.env` again. With `--this-mac`, no other setting can be changed (they are shared by every Mac), and nothing is asked.

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
| Backups | `CABINET_BACKUP_DIR`, `CABINET_BACKUP_TIME` |
| Repos | new rows in `repos.tsv` and the team table in `AGENTS.md` |

Roles the project defines itself (`roles/<role>.md` with frontmatter) are accepted and asked about. Layout and visibility (inside, beside, private, shared) are not changed by `config`. When nothing changes, it prints `Nothing to change.` and writes nothing.

## cabinet remove

```sh
cabinet remove [dir] [--dry-run] [--yes] [--force] [--delete-key]
```

Removes a workspace from this Mac. It first prints the plan:

- stop and delete the workspace's own schedules (a plist is its own when it runs this workspace's `bin/`; another workspace's are never touched);
- delete its log folder `~/Library/Logs/cabinet/<slug>/`, which frees the slug;
- the backup passphrase and archives stay, unless `--delete-key` (archives always stay);
- inside a project, private: remove the pointers in `CLAUDE.local.md`, `QWEN.local.md` and an untracked `AGENTS.md` (a file left empty is deleted), the role files setup built in `.claude/agents/`, and their `.git/info/exclude` lines, so the project is as it was before `init`;
- inside a project, shared: remove the "Agent team" section from `AGENTS.md` and `CLAUDE.md` and the `@tarekraafat/cabinet` devDependency; you commit that change;
- delete the workspace folder.

| Option | Notes |
|---|---|
| `[dir]` | Default: the workspace you are in. |
| `--dry-run` | Print the plan only. |
| `--yes`, `-y` | Do not ask. Without it you type the slug to confirm. |
| `--force` | Go ahead even when the workspace has uncommitted changes or commits on no remote. Without it, those stop the removal (`Not safe to delete`). |
| `--delete-key` | Also delete the keychain item `cabinet.<slug>.backup`. |

The guardrails in your agent tools stay, since other workspaces use them. Exit codes: 0, or 1 when refused or not confirmed.

## cabinet update

```sh
cabinet update [dir]
```

Copies the installed kit's files into the workspace, rebuilds the roles, and prints every changelog section between the workspace's old version and the new one. It never replaces a kit file that was edited in the workspace: it stops, names the file, and keeps the old version (exit 1). It ends with the exact `git add` and `git commit` to run.

## cabinet status

```sh
cabinet status [dir] [--json]
```

Prints the workspace's kit version, the installed kit's version, and every kit file edited in the workspace. `--json` prints `{workspace, version, kit_version, kit, edited}`.

## cabinet outdated

```sh
cabinet outdated [dir]
```

Compares the workspace's kit version, the installed kit and the newest version on the npm registry, and says what to run. Without the registry it says the newest is unknown. Exit 0.

## cabinet changelog

```sh
cabinet changelog [from-version]
```

Prints the changelog sections newer than `from-version` (all of them when it is left out).

## cabinet completion

```sh
eval "$(cabinet completion zsh)"     # in ~/.zshrc
eval "$(cabinet completion bash)"    # in ~/.bashrc
```

Tab completion for commands, their options, and the job names of the nearest workspace after `cabinet run`.

## cabinet version

Prints the installed kit's version.

## Which copy of cabinet runs

`cabinet update`, `status` and `config` hand off to the workspace's own pinned copy when it exists (`<workspace>/node_modules/@tarekraafat/cabinet`, or the project's `node_modules` above a shared `cabinet/`), so they always act with the project's version. They do this only in a cabinet workspace: the folder named, or the nearest workspace from the current folder upward. `new`, `init`, `changelog` and `version` always run the copy you called.

## Workspace scripts

All of them read `cabinet.env`. Run each as its `cabinet` command from anywhere in the workspace or its project, or as the script itself (`cabinet/bin/<script>` inside a project).

| Command | Script |
|---|---|
| `cabinet doctor` | `bin/doctor.sh` |
| `cabinet bootstrap` | `bin/bootstrap.sh` |
| `cabinet brief` | `bin/scheduled.sh brief` |
| `cabinet run <job>` | `bin/scheduled.sh <job>` |
| `cabinet handoffs` | `bin/handoffs.sh` |
| `cabinet handoff` | `bin/handoff.sh` |
| `cabinet archive` | `bin/archive-handoffs.sh` |
| `cabinet secrets` | `bin/secrets.sh` |
| `cabinet roles` | `bin/roles.sh` |
| `cabinet backup` | `bin/backup.sh` |
| `cabinet restore` | `bin/restore.sh` (outside any workspace, the installed kit's copy: a new Mac has no workspace yet) |
| `cabinet snapshot` | `bin/snapshot.sh` |
| `cabinet move` | `bin/move.sh` |

| Script | What it does | Exit codes |
|---|---|---|
| `bin/bootstrap.sh [--dry-run] [--no-schedules \| --schedules]` | Sets up this Mac for the workspace: clones missing repos, restores local-only files, links `CLAUDE.md`, gives each repo whose owner is `TBD` a builder ([concepts](concepts.md#the-team)), builds the roles, installs the guardrails ([guardrails](guardrails.md)) and the workspace's secrets check before each commit, and adds, updates or removes the schedules to match `jobs/` and the backup setting. `--dry-run` only prints. `--no-schedules` stops and from then on skips the jobs' schedules on this Mac, for a workspace whose jobs another Mac runs (a teammate's, in a shared workspace); `--schedules` undoes it. Both are saved in `cabinet.local.env`. The backup schedule is not affected. Safe to rerun. | 0, or 1 when any step did not complete (each one says why) |
| `bin/doctor.sh [--fix [--yes]] [--json]` | Checks everything: repos, kit files, roles, guardrails for every installed tool, the manual, handoff IDs, secrets in the workspace's files, uncommitted work, schedules, backups. It starts with a summary (`N thing(s) need attention:` and the list, or `All good.`), then the full report. Changes nothing in the workspace or your settings (it runs `opencode debug` and `grok inspect`, which may write their own caches). `--fix` then runs the fixes it knows (`bin/bootstrap.sh`, `bin/roles.sh`, `bin/snapshot.sh`), asking before each unless `--yes`, and checks again. `--json` prints the results for scripts (see [Output for agents and scripts](#output-for-agents-and-scripts)). Every message is explained in [troubleshooting](troubleshooting.md). | 0, or 1 when anything says FIX |
| `bin/handoffs.sh [name] [--json]` | Without a name: every open handoff with its age in days, oldest first (`?` when it has no date). With a repo or role name (`qa`, `owner`): every entry addressed to it, in full. | 0 |
| `bin/handoff.sh --from <name> --to <name> --changed "..." --needed "..." [--depends-on "..."] "<title>"` | Files one handoff: appends the entry at the bottom of "Open" in `HANDOFFS.md` with the next free ID for today (`H-20261019-01`, unique across `HANDOFFS.md` and the archives), today's date, status `open` and the template's lines, then commits it on its own (`handoffs: <ID> <title>`). `--depends-on` defaults to `none`. Each value is kept on one line. It prints the new ID first. When `HANDOFFS.md` already has someone else's uncommitted lines, it writes the entry but does not commit, so their lines never go into its commit. Two agents filing at once get different IDs. | 0, 1 when the commit failed (the entry is written) or `HANDOFFS.md` has no "## Open" heading, 2 for a missing value or unknown option |
| `bin/archive-handoffs.sh` | Moves every committed `done` or `rejected` handoff to `handoffs/archive-YYYY-MM.md` and commits the move. | 0, or 1 when `HANDOFFS.md` has uncommitted lines |
| `bin/secrets.sh [--staged]` | Looks for keys, tokens and passwords in the workspace's own files (tracked, and new files git does not ignore; not the product repos, which have their own git): private key blocks; AWS, GitHub, Slack, Stripe live, Anthropic, OpenAI, Google API and npm keys; and lines that set a password, secret, token or API key to a value that is not a placeholder (`<...>`) or a variable (`$X`). It prints each file and line with the kind of secret, never the value. A false alarm: add `not-a-secret` anywhere on its line. `--staged` checks only the lines staged for the next commit; the workspace's pre-commit hook runs it ([guardrails](guardrails.md#what-bootstrap-installs)). | 0, or 1 when something is found (with `--staged`, the commit is refused) |
| `bin/roles.sh [--check]` | Builds `agents/<role>.md` and `.claude/agents/<role>.md` (and, inside a project, the project's `.claude/agents/` and pointer files). `--check` only reports. | 0, or 1 when a role is missing or out of date |
| `bin/scheduled.sh <job>` | Runs `jobs/<job>.job` now with the configured runner, logging to `~/Library/Logs/cabinet/<slug>/<job>.log`. | 0, 1 when the run failed, 2 for an unknown or incomplete job |
| `bin/backup.sh [--verify] [folder]` | One encrypted backup now ([backups](backups.md)). Default folder: `CABINET_BACKUP_DIR`. `--verify` writes nothing there: it restores the newest archive into a temporary folder, checks each repo against the workspace, and deletes the copy ([backups](backups.md#checking-it)). | 0, 1 with no passphrase (or, with `--verify`, no archive or a problem found), 2 for a missing, relative or inside folder, or a keep count under 1 |
| `bin/restore.sh <archive> [folder]` | Rebuilds the workspace and its repos from an archive, never losing a file ([backups](backups.md)). It starts by naming the backup's date. | 0, or 1 with no passphrase |
| `bin/snapshot.sh` | Copies each repo's local-only files and `.git/info/exclude` entries into `local/<repo>/`. The backup runs it first. | 0 |
| `bin/move.sh <new-path> [--dry-run]` | Moves a workspace folder and updates what remembers its path: Claude Code's memory and trusted folders, Codex's trusted folders, the schedules. Refused for the inside and beside layouts. | 0, or 1 when refused |

## Output for agents and scripts

Text output is for people and may be reworded at any time. For a script or an agent, use JSON: a field or ID is never renamed or removed without a changelog entry that says so.

| Command | Prints |
|---|---|
| `cabinet help --json`, `cabinet help <command> --json` | `{name, version, docs, commands: [{name, group, usage, summary, options: [{name, value, text}]}]}` |
| `cabinet next --json` | `{workspace, project, steps: [{id, text, command}], optional: [...]}`. Step IDs: `tbd`, `commit`, `install`, `bootstrap`, `handoffs`, `brief`, `doctor`; `command` is empty when the step is not a command. Outside a workspace, `workspace` is `null` and the one step is `start`. |
| `cabinet doctor --json` | `{workspace, problems, notes, can_fix, results: [{level, section, id, message}]}`. `level` is `ok`, `fix` or `note`; `id` names the check (every ID is in [troubleshooting](troubleshooting.md)) and does not change when its message is reworded. Exit 1 when `problems` is above 0. |
| `cabinet handoffs --json` | The open and acknowledged entries, oldest first: `[{id, status, status_line, date, age_days, from, to, title}]`. `date` and `age_days` are `null` when the status line has no date. |
| `cabinet handoffs <name> --json` | Every entry addressed to that repo or role and not closed, with its full `text`. `owner` and `founder` are the same person. |
| `cabinet status --json` | `{workspace, version, kit_version, kit, edited}` |
| `cabinet digest --json` | `[{slug, project, path, exists, brief_written, brief_stale, sign_off_queue, queue_heading_found, actions_for_owner, waiting_on_owner}]`. The two parts are the Markdown under their headings, or `null`; `queue_heading_found` is `null` with no brief. |
| `cabinet list --json` | `[{slug, project, path, exists, version, update_available, waiting_on_owner, doctor_problems, brief_written}]`. `brief_written` is ISO 8601 UTC, or `null`; the counts are `null` for a workspace whose folder is gone. |

## Files you can edit

### cabinet.env

| Key | Meaning |
|---|---|
| `CABINET_PROJECT` | Display name. |
| `CABINET_SLUG` | Short name for everything machine-wide. Change it with `cabinet config --slug`. |
| `CABINET_ROLES` | Roles to build, space separated. |
| `CABINET_RUNNER` | `claude`, `codex`, `gemini`, `qwen`, `grok`, `opencode`, `cursor` or `custom`. |
| `CABINET_RUNNER_CMD` | With `custom`: the command, single-quoted. |
| `CABINET_LAYOUT` | `new`, `around`, `inside` or `beside`. Set by setup; not changed by `config`. |
| `CABINET_VISIBILITY` | Inside only: `private` or `shared`. |
| `CABINET_BACKUP_DIR` | Absolute folder for archives, outside the workspace and its repos; empty turns backups off. |
| `CABINET_BACKUP_TIME` | Time of the daily backup, like `1:00 PM` (default). |
| `CABINET_BACKUP_KEEP` | How many of this workspace's archives to keep (default 14, at least 1). |
| `CABINET_JOB_TIMEOUT` | Minutes a job may run before it is stopped, for jobs without their own `TIMEOUT` (default 60; `0` for no limit). |
| `CABINET_SKILLS`, `CABINET_PLUGINS` | Claude Code skills and plugins the doctor expects (a missing one is a note). |

### jobs/&lt;job&gt;.job

One scheduled agent run each. Keys: `AGENT` (the role), `PROMPT`, `WHEN` (a [schedule time](#schedule-times), or empty for by hand only), `MINUTES` and `RESULT` (shown when run by hand), `TIMEOUT` (whole minutes before the run is stopped, with everything it started, and the reason written to its log; empty uses `CABINET_JOB_TIMEOUT`, `0` means no limit), `AFTER` (an optional shell command run in the workspace after a successful run). After a change, run `bin/bootstrap.sh`.

### cabinet.local.env

Settings for this Mac only. Git never tracks it (the workspace's `.gitignore` tracks only its own files), so in a shared workspace each teammate's Mac keeps its own. It is read, never run as shell. Its keys:

| Key | Meaning |
|---|---|
| `CABINET_SCHEDULES` | `off`: this Mac schedules none of the jobs in `jobs/` (another Mac runs them). Set and cleared with `cabinet bootstrap --no-schedules` and `--schedules`. Jobs still run by hand with `cabinet run <job>`. |
| `CABINET_BACKUP_DIR`, `CABINET_BACKUP_TIME` | When present, they replace `cabinet.env`'s on this Mac; an empty `CABINET_BACKUP_DIR` turns backups off here. Set with `cabinet config --this-mac`, removed with `cabinet config --this-mac --clear`. |

### Schedule times

Every schedule takes the same forms: the brief (`--brief`), any job (`WHEN` in `jobs/<job>.job`) and the digest (`cabinet digest --schedule`).

| Form | Means |
|---|---|
| `7 AM`, `7:00 AM`, `7am`, `daily 7 AM` | Every day at 7:00 AM. |
| `fri 4 PM`, `Friday 4:00 PM` | Every Friday at 4:00 PM. |
| `fri,sat 10:30 AM` | Every Friday and Saturday at 10:30 AM. |
| `sun,mon,tue,wed,thu 8 AM` | Sunday to Thursday at 8:00 AM. |
| `12 PM`, `12 AM` | Noon, midnight. |

Times are 12-hour, with `AM` or `PM` in any case (`pm`, `p.m.` too); the minutes can be left out (`4 PM`). A time without AM or PM is read as 24-hour (`16:00` is 4:00 PM, `7:00` is 7:00 AM), so files and scripts written that way keep working; a bare hour (`10`) is refused, since it could be either. Put a time with a space in quotes on the command line: `--brief "fri 4 PM"`.

Days are `sun`, `mon`, `tue`, `wed`, `thu`, `fri`, `sat`, or their full names, in any case, separated by commas. All the days named share one time. Naming all seven is the same as every day. Setup and config store one form, `fri,sat 10:30 AM`, and every message shows times as `4:00 PM`.

### repos.tsv

Tab separated, one row per repo: name, clone URL (`-` for none), local-only files (space separated, `-` for none), `CLAUDE.md` link (`yes` or `no`), and an optional path where the repo lives (absolute, `~/...`, or relative to the workspace; default `<workspace>/<name>`). Windows line endings are fine. A row whose name is not a plain folder name is skipped with a message.

## Environment variables

| Variable | Used by | Meaning |
|---|---|---|
| `CABINET_BACKUP_PASSPHRASE` | backup, restore | The archive passphrase, instead of the keychain item `cabinet.<slug>.backup`. Never put it in `cabinet.env`, which git tracks. |
| `CABINET_PROMPT`, `CABINET_AGENT` | the `custom` runner | The prompt and role, for `CABINET_RUNNER_CMD`. |
| `CABINET_TTY` | setup, config, remove | Read answers from this file instead of the terminal (the tests use it). |
| `CABINET_PRIVATE_WORDS` | `npm test` | Words that must not appear in the kit. |

## Removing a workspace

`cabinet remove` does all of this (see [cabinet remove](#cabinet-remove)). By hand:

1. Stop its schedules: `launchctl bootout gui/$(id -u)/ai.cabinet.<slug>.<job>` for each, then delete `~/Library/LaunchAgents/ai.cabinet.<slug>.*.plist`.
2. Delete its log folder `~/Library/Logs/cabinet/<slug>/`, which also frees the slug.
3. If it had backups: `security delete-generic-password -a "$USER" -s cabinet.<slug>.backup`, and delete its archives if you no longer want them.
4. Delete the workspace folder.
5. Inside a project: for private, remove the `/cabinet/`, `/CLAUDE.local.md`, `/QWEN.local.md`, `/AGENTS.md` (if setup created it) and `/.claude/agents/<role>.md` lines from the project's `.git/info/exclude`, and the files they name if setup made them; for shared, remove the "Agent team" section and the `@tarekraafat/cabinet` devDependency from the project.

The guardrails stay; see [guardrails](guardrails.md#undoing-the-guardrails).
