# Layouts

Where a workspace sits, and what that means for your project. `cabinet new` makes the first; `cabinet init` picks one of the other three from where you run it. The layout is recorded as `CABINET_LAYOUT` in `cabinet.env` and does not change later.

| Layout | Made by | The workspace is | Your project |
|---|---|---|---|
| `new` | `cabinet new <dir>` | a new folder; product repos are cloned into it | (cloned into the workspace) |
| `around` | `cabinet init` in a folder that is not a repo | that folder, around what is already in it | the repos in its subfolders, listed in `repos.tsv` |
| `inside` | `cabinet init --inside` in a project repo | `cabinet/` inside the project | unchanged files, plus what is listed below |
| `beside` | `cabinet init --beside` in a project repo | a folder next to the project (default `<project>-hq`) | not changed at all |

## new

The simplest: one folder holding the team's files and, under it, every product repo (cloned by `bin/bootstrap.sh` from `repos.tsv`). The workspace's `.gitignore` tracks only its own files, so the product repos stay out of its git.

## around

For a folder that already holds your repos side by side. `cabinet init` keeps everything there: existing files are never replaced, the folder's own `.gitignore` is kept, and only the files setup placed are committed (never a `.env` or other files that were already there). The repos it finds are listed in `repos.tsv`. If the folder already has a file at a path the kit uses, such as `bin/doctor.sh`, setup stops before writing anything: rename or move that file, then run `cabinet init` again.

## inside

For one project repo that should carry its team with it. The workspace is `<project>/cabinet/`. Agents usually start in the project's top folder, so setup points them at `cabinet/` with an "Agent team" section, and also writes the role definitions into the project's `.claude/agents/` (a file of the project's own with the same name is kept). Paths in `CABINET.md` and the roles are relative to `cabinet/`: run its scripts as `cabinet/bin/<script>`. `cabinet status`, `update` and `config` work from the project's top folder.

There are two kinds, set once as `CABINET_VISIBILITY`:

### Private (the default)

`cabinet/` has its own git, and the project's git never sees it. No tracked file of the project changes:

- the pointer goes only into files the project does not track: `CLAUDE.local.md` (read by Claude Code and Grok), `QWEN.local.md` (Qwen), and `AGENTS.md` only when the project has none;
- `cabinet/`, those pointer files and the role files are added to the project's `.git/info/exclude`;
- the version pin goes in `cabinet/package.json`;
- `bin/role.sh build` rebuilds the pointers on every update and after a restore.

When the project has its own `AGENTS.md`, it is left alone. Codex, opencode, Gemini and Cursor read only that file, so start them in `cabinet/`, or add the "Agent team" section to `AGENTS.md` yourself. If you later write a real `AGENTS.md` for a project that had none, remove `/AGENTS.md` from `.git/info/exclude` first, or git will ignore it.

Fits: solo work, open source projects, client repos.

### Shared

`cabinet/` is part of the project's repo, for everyone who clones it. Setup adds the "Agent team" section to the project's `AGENTS.md` (or `CLAUDE.md`, or a new `AGENTS.md`) and pins the kit in the project's `package.json` as a devDependency (with npm's own `npm pkg set`: formatting kept, no network, an existing entry left alone). Setup commits nothing in the project: review the new files and commit them yourself. Without a `package.json` in the project, the pin goes in `cabinet/package.json`.

Fits: a private repo whose teammates should see the team's handoffs and specs.

## beside

The project is not changed at all. The workspace is a folder next to it and points at it with a relative path (`../<project>`) in `repos.tsv`, so the project stays where it is and nothing is cloned again. Fits a product with several repos, or a project you would rather not touch.

## What lives where

| | What | Who changes it |
|---|---|---|
| **Kit files** | `CABINET.md`, `bin/*.sh`, `.cabinet/` (roles, rules read when a task needs them, guardrails, schedule template, version, manifest) | Only `cabinet update`. Never edit them in a workspace: an update stops at an edited one. |
| **Project files** | `AGENTS.md`, `cabinet.env`, `roles/`, `jobs/`, `HANDOFFS.md`, `OPERATIONS.md`, `repos.tsv`, `specs/`, `notes/`, `tools/` (the project's own scripts) | You and the agents. Placed once by `new` or `init`; afterwards `cabinet config` changes only the settings it manages in them. |
| **Built** | `agents/<role>.md`, `.claude/agents/<role>.md`: the kit's role plus your `roles/<role>.md` | `bin/role.sh build` |

Instructions layer from general to specific: `CABINET.md`, then the workspace's `AGENTS.md`, then each repo's own `AGENTS.md`.

## Switching layouts

Not supported: moving between layouts, or between private and shared, means moving files and changing git by hand. `bin/move.sh` moves a `new` or `around` workspace to another folder; it refuses the inside and beside layouts, whose relative paths would break.
