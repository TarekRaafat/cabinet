# AGENTS.md - working on the Cabinet kit

**Setting up or using Cabinet for a person or a project? This file is not for you:** follow [docs/agent-setup.md](docs/agent-setup.md), and never run `cabinet new` or `cabinet init` inside this repository.

Read this before changing anything in this repository. It is for agents (and people) improving the kit itself. The rules agents follow inside a workspace made by the kit are in `core/CABINET.md`, which becomes each workspace's `CABINET.md`.

## What is where

| Path | What it is | Ends up in a workspace as |
|---|---|---|
| `bin/cabinet` | The `cabinet` command: setup, settings, removal, updates, and every workspace script as a command run from anywhere inside the workspace | (runs from the installed package) |
| `scripts/*.sh` | The workspace scripts; `lib.sh` is shared and sourced by the rest, `when.sh` is the one parser for schedule times, and `platform.sh` is the one place that knows macOS from Linux (log folder, dates, the passphrase store, launchd, systemd or cron); both are sourced by `lib.sh` and by `bin/cabinet` | `bin/*.sh` |
| `core/CABINET.md` | How a workspace runs: handoffs, tiers, sign-off, seats, git rules | `CABINET.md` |
| `core/rules/*.md` | The rules only some roles or tasks need, named from `CABINET.md` with when to read each; keep `CABINET.md` to what every agent needs on every session | `.cabinet/rules/` |
| `roles/*.md` | The kit's roles | `.cabinet/roles/`, built into `agents/` and `.claude/agents/` |
| `guardrails/` | Deny rules for each agent tool, the push gate, the hook pass-through stub | `.cabinet/guardrails/`, installed machine-wide by bootstrap |
| `templates/workspace/` | Project files placed once by `new` and `init` | the workspace's own files |
| `docs/`, `README.md`, `llms.txt`, `llms-full.txt` | Documentation, shipped in the npm package. `llms-full.txt` is built from the pages `llms.txt` lists | (not copied) |
| `brand/` | The brand: `BRAND.md` (every rule with its status, the source of truth), `tokens.json` (the same as data), `assets/` (every logo file), `index.html` (the visual guide). Not shipped | |
| `tools/build-llms-full.js` | Builds `llms-full.txt` (`npm run docs`; not shipped) | |
| `tools/build-brand.js` | Builds `brand/assets/` and `docs/logo.svg` from `brand/tokens.json` (`npm run brand`; not shipped) | |
| `test/smoke.sh` | The whole test suite (not shipped) | |

Kit files are replaced on every `cabinet update` and must never be edited in a workspace; project files are the project's own after setup.

## Rules

1. **Never touch the real machine while testing.** Every test and experiment runs in a `mktemp -d` folder with `HOME` pointed inside it (git then reads that folder's `.gitconfig` as its global config), and fakes of `launchctl`, `systemctl`, `crontab`, `security`, `secret-tool` and the agent tools first on `PATH` from the very start, never added only by a later step. Never read or write the real `~/.claude`, `~/.qwen`, `~/.cursor`, `~/.config`, `~/Library/LaunchAgents`, `~/.local/state`, the crontab, the keychain, the secret store or the global git config. `test/smoke.sh` does this in its header for every section; follow its pattern. After an experiment, check that `launchctl list` shows no `ai.cabinet.` job you did not mean to load.
2. **Never weaken a guardrail, and never test one by trying a real push, merge or publish.** Test a rule with the tool's own matcher, or with a harmless command of the same shape (for example `git log` for `git push`). A new rule format is untested until shown to work, and the docs say so.
3. **bash 3.2.** macOS ships it, so the kit runs on it: no `mapfile`, no associative arrays, no `${var,,}`; guard empty arrays (`${a[@]+"${a[@]}"}`); declare an array on its own `local` line; no apostrophe inside `${x:+...}` in double quotes.
   **New logic is JavaScript, never TypeScript,** in `scripts/lib.js`, run with `node` (which the kit already needs). Only Node's own modules (`node:fs`, `node:path`, `node:crypto`, ...): no npm packages and no build step, so the same code can later be compiled with Bun into one file. JSON in a script is read and written with `json` (in `platform.sh`: `node lib.js json`, options for input and output and a JavaScript expression). This holds for the tests and the tools too. Do not add python3, perl, jq or another language or tool ([roadmap](ROADMAP.md#toward-a-single-download)). bash stays for the scripts' shell work until that code moves too. Existing bash moves to JavaScript one command at a time, when that command is slow (many `node` calls in a loop) or is being reworked anyway, never as a rewrite on its own.
4. **Untrusted values never reach a shell.** Anything from a cloned project (`package.json`, folder names, git remotes) is checked (`safe`, `url_ok`, `name_ok` in `bin/cabinet`) before it is written into `cabinet.env`, `repos.tsv` or a schedule. `cabinet.env` and job files are sourced as shell.
5. **Never lose a user's data.** A config file is changed only through `write_into` (written only when the result is valid and non-empty); an existing file is kept, never replaced; restore copies anything it would replace to `recovered/` first.
6. **Docs match the code.** A change to a command, option, file, message or behavior updates `docs/` (and `README.md` when it is user-facing) in the same change, then `npm run docs` rebuilds `llms-full.txt`. `npm test` fails when a command, option, script, doctor message or check ID is missing from the docs, a link or heading anchor is broken, or `llms-full.txt` is stale.
7. **One command table, one set of conventions.** Every `cabinet` command and option is a row in `commands_table` in `bin/cabinet`; help, `--help`, `help --json` and tab completion are made from it. A new command or option follows "Command conventions" below, starts in the table, then gets its parser and dispatcher line; the tests fail when they disagree or a convention is broken.
8. **Stable IDs for machines.** Each doctor check has an ID (`ok <id> "message"`), and each `cabinet next` step has one. A new check gets a new ID, listed in `docs/troubleshooting.md`; an ID or a JSON field is never renamed or removed without a changelog entry that says so.
9. **Every change has a test** in `test/smoke.sh`, and an entry in `CHANGELOG.md` under the next version.
10. **Writing.** ASCII punctuation only (no em or en dashes, no curly quotes). Dates people read as `18 Oct 2026`; machine formats stay ISO. No personal or project names, local paths, or comparisons with other products. Name third-party tools only as facts (which tools have guardrails).
11. **Never push, merge, publish or release.** Only the maintainer does. Commit finished, tested work locally, with no AI or tool attribution lines.

## Command conventions

Every command follows these, so a person or an agent who knows one command can guess the next. `test/docs-check.js` enforces the parts a script can check.

1. **Two shapes.** A one-word command acts on the workspace as a whole or on this machine: `new`, `init`, `next`, `brief`, `digest`, `list`, `doctor`, `bootstrap`, `config`, `update`, `status`, `outdated`, `changelog`, `move`, `remove`, `completion`, `version`, `help`. Anything a workspace holds is a noun, then a verb: `cabinet <noun> <verb>`, with the nouns `role`, `repo`, `handoff`, `spec`, `manual`, `job`, `backup` and `secret`. A new command is a new verb on an existing noun when one fits, a new noun only for a new kind of thing, and a new one-word command only for the workspace or the machine as a whole.
2. **Nouns are singular,** and no two commands differ only by a plural.
3. **Verbs come from one list, each with one meaning:**

   | Verb | Means |
   |---|---|
   | `add` | Put a new one in the workspace, or turn on one the kit has. |
   | `remove` | Take one out of the workspace. Never deletes what the project wrote unless its help says so. |
   | `list` | Show them. Changes nothing. |
   | `check` | Look for problems. Changes nothing; exit 1 when it finds one. |
   | `create` | Make a new artifact now (a backup archive). |
   | `verify` | Prove an artifact is sound by using it (restoring a backup). |
   | `restore` | Bring back what an artifact holds. |
   | `run` | Start it now. |
   | `build` | Make generated files from their sources. |
   | `draft` | Have an agent write it. |
   | `archive` | Move finished ones out of the working file. |
   | `snapshot` | Copy files that live only on this machine into the workspace. |
   | `attach` | Add a file or link to one that exists. |
   | `record` | Write a result onto one that exists. |

   A new verb is added to this list, with its meaning, in the same change.
4. **A noun alone shows its verbs** (`cabinet role` is `cabinet role --help`).
5. **Options mean the same everywhere.**
   - `--json`: every command that reports (`list`, `check`, `verify`, `next`, `doctor`, `digest`, `status`, `outdated`, `changelog`, `version`, `help`) prints JSON instead, on stdout. Its fields are never renamed without a changelog entry.
   - `--dry-run`: every command that changes the setup (settings, the team, repos, this machine) or deletes anything prints what it would do and changes nothing.
   - `--yes` (`-y`): every command that asks takes the defaults and asks nothing.
   - `-C <dir>`, before the command: run as if started in `<dir>`, as git does. Commands find the workspace from the current folder upward, so none takes a folder to act on as an argument; `new` and `init` take the folder they make or adopt, which is what they act on.
   - Names are lowercase words joined by dashes, and a setting's option is named for the setting (`--backup-dir`, `--brief-time`). A time or schedule takes a [schedule time](docs/commands.md#schedule-times) or `off`. A switch takes no value; a pair is `--<x>` and `--no-<x>`. A value follows its option after a space.
6. **Exit codes:** 0 done (or nothing found), 1 failed or found a problem, 2 wrong usage (an unknown command or option, a missing value).
7. **Scripts use the same words.** Each noun has one workspace script, `bin/<noun>.sh <verb>`, and a one-word command that has a script uses `bin/<command>.sh`, so agents, schedules and people use one vocabulary with or without the `cabinet` command.
8. **Messages** are plain words, go to stderr when they report an error (starting `cabinet:` from `bin/cabinet`), and end with the command that fixes the problem when there is one.

Known exceptions, each on the roadmap: `update` has no `--dry-run` yet (`cabinet update --dry-run`).

## Checks

```sh
npm test                                      # every section, about a minute; must end with PASS
npm test -- init config                       # only the sections whose name has a word, and what they need
npm run test:linux                            # the same suite on Linux, in a Debian container (starts and stops Colima if Docker is not running)
CABINET_PRIVATE_WORDS="word1 word2" npm test  # also fails on any private word in the kit
npm run docs                                  # rebuild llms-full.txt after changing a doc
npm run brand                                 # rebuild brand/assets/ and docs/logo.svg after changing brand/tokens.json (macOS)
npm pack --dry-run                            # what the package ships
```

A new test section is a `section "<name>" "<numbers of the sections it needs>"` line and an `sN()` function in `test/smoke.sh`, ending with `return 0`. Before finishing, run each section you touched alone (`npm test -- "<its name>"`): that proves its list of needs is complete.
