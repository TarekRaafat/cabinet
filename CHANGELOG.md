# Changelog

Each version says what changed and anything a workspace must do by hand after `npx cabinet update`, which prints these entries.

## 0.1.0 - Unreleased

First version.

### Setup and settings

- Installed per workspace as the dev dependency `@tarekraafat/cabinet`; the package names its repository, home page and issue tracker on GitHub, publishes as public, and installs on macOS only until Linux support ships.
- `cabinet new` asks its setup questions in a terminal (name, folder, owner, roles, agent tool, brief time, week start, backups, repos); each is also an option, and `--yes` skips them for scripts.
- `cabinet init` adds cabinet to an existing project: inside it as `cabinet/`, private or shared, or beside it; or makes an existing folder of repos the workspace. Nothing existing is replaced. It fills the project name, description, test commands, repository URL and owner from the project's `package.json` and git, each marked with its source.
- `cabinet config` changes settings after setup: the same questions with the current answers as defaults. It keeps the team tables, roles and schedules in step, and moves schedules on a slug change. `cabinet config --this-mac --backup-dir <folder>|off [--backup-time <time>]` sets backups for one Mac only, in `cabinet.local.env`, so each teammate in a shared workspace picks their own folder or none; `--clear` follows `cabinet.env` again.
- `cabinet update` applies the installed kit and shows the changelog since the workspace's version; `cabinet changelog`, `status`, `version` and `outdated`.
- `cabinet remove` removes a workspace (its schedules, logs and folder, and inside a project what setup added), refusing work that exists nowhere else unless `--force`.
- `--dry-run` for `new`, `init` and `config`. `repos.tsv` takes an optional path column for a repo that lives outside the workspace.

### The team

- Core rules (`CABINET.md`): workspace layout, handoffs, three decision tiers, the sign-off queue, silence, the builder never verifies, seats and onboarding, git and release rules.
- Roles: chief-of-staff, product-manager, architect, qa, security, design-lead, finance. Project notes and project-only roles through `roles/`.
- `guides/` for the project's standing documents (brand, style, policies, business documents), listed in a "Guides" table in `AGENTS.md` that every agent reads; `CABINET.md` ranks guides with `AGENTS.md`, and `bin/doctor.sh` reports a guide with no row and a row with no file. A recipe and a concepts section say where each kind of rule goes and which wins.

### Commands

- One command for everything: `cabinet doctor`, `bootstrap`, `brief`, `run <job>`, `handoffs`, `archive`, `roles`, `backup`, `restore`, `snapshot` and `move` run the workspace's scripts (handoffs, archive-handoffs, roles, scheduled, bootstrap, doctor, snapshot, backup, restore, move) from any folder inside the workspace or its project. `cabinet next` says what to do next.
- `cabinet digest`: one morning read with the sign-off queue and the owner's actions from the latest brief of every workspace on this Mac. `--write <file>` writes it to a file, `--notify` sends a macOS notification with the counts, and `--schedule [<when>]` (default every day at 10:00 AM; or another time, or chosen days and a time; `off` to stop) runs it as one launchd job for the whole Mac. The chief-of-staff role writes the brief's parts under fixed `## ` headings so the digest can find them.
- `cabinet list`: every workspace on this Mac in one table (kit version, what waits on the owner, the doctor's count, the latest brief).
- `bin/doctor.sh` leads with a summary of what needs attention, and `--fix` runs the fixes it knows (asking first).
- One command table in `bin/cabinet` drives `cabinet help`, `cabinet <command> --help`, `cabinet help --json` (every command and option, for agents) and tab completion (`cabinet completion bash|zsh`: commands, options, and job names for `cabinet run`).
- JSON for agents and scripts: `--json` for `status`, `doctor`, `next`, `handoffs [name]`, `digest` and `list`; every doctor result carries a stable check ID, listed in the troubleshooting docs.
- Dates people read (backup age, brief time, restore) are written as `18 Oct 2026, 2:30 PM`.

### Schedules

- Jobs as `jobs/<job>.job`, scheduled daily or weekly by launchd. `bin/bootstrap.sh` adds, updates or removes each schedule to match `jobs/` and the backup setting.
- One form for every schedule (the brief, any job, the backup time, the digest): 12-hour times (`7 AM`, `4:30 PM`), every day or on days, one or several (`fri 4 PM`, `sun,mon,tue,wed,thu 8 AM`), with days by short or full name in any case. Times are stored and shown as `4:00 PM`; 24-hour times are still read.
- Scheduled runners: claude, codex, gemini, qwen, grok, opencode, cursor, and `custom` for any other tool (`CABINET_RUNNER_CMD`).
- `cabinet bootstrap --no-schedules` (and `--schedules` to undo it): a Mac that should not run the workspace's jobs, such as a teammate's in a shared workspace, skips their schedules from then on; the choice is saved in `cabinet.local.env`, which git never tracks.

### Guardrails and safety

- Guardrails for Claude Code, Codex, Antigravity, Gemini CLI, Qwen Code, opencode and the Cursor CLI (Grok reads the Claude Code rules; the Cursor rule shapes were probed live on Cursor CLI 2026.10.16), checked by `bin/doctor.sh` (opencode on 1.x only), which also names installed tools it cannot guard; and the owner's pre-push gate for every tool.
- Values from a cloned project's `package.json` never reach a shell (only plain values are used, the description is quoted as data); clone URLs and repo names are checked; a slug another workspace uses is refused.
- Backups must live outside the workspace and its repos, clean up only their own archives, and restore never loses a file.
- Config files keep their permissions and symlinks, and a file that is not plain JSON is left alone; every git hook passes through to the repo's own under the global hooks path.

### Docs

- For people: a short README with a quick start, the daily loop and a glossary; a tutorial for the first day and a recipes page for common tasks; `docs/` with the full command reference, layouts, concepts, guardrails, backups and every doctor message.
- For agents: `llms.txt`, `llms-full.txt` with every page in one file, and `AGENTS.md` for working on the kit.
- The tests fail when the docs fall behind the code, a link or heading anchor is broken, `llms-full.txt` is stale, or the README's clone command does not match the repository in `package.json`.
