# AGENTS.md - working on the cabinet kit

Read this before changing anything in this repository. It is for agents (and people) improving the kit itself. The rules agents follow inside a workspace made by the kit are in `core/CABINET.md`, which becomes each workspace's `CABINET.md`.

## What is where

| Path | What it is | Ends up in a workspace as |
|---|---|---|
| `bin/cabinet` | The `cabinet` command: setup, settings, removal, updates, and every workspace script as a command run from anywhere inside the workspace | (runs from the installed package) |
| `scripts/*.sh` | The workspace scripts; `lib.sh` is shared and sourced by the rest, and `when.sh` is the one parser for schedule times, sourced by `lib.sh` and by `bin/cabinet` | `bin/*.sh` |
| `core/CABINET.md` | How a workspace runs: handoffs, tiers, sign-off, seats, git rules | `CABINET.md` |
| `roles/*.md` | The kit's roles | `.cabinet/roles/`, built into `agents/` and `.claude/agents/` |
| `guardrails/` | Deny rules for each agent tool, the push gate, the hook pass-through stub | `.cabinet/guardrails/`, installed machine-wide by bootstrap |
| `launchd/job.plist` | The schedule template | `.cabinet/launchd/` |
| `templates/workspace/` | Project files placed once by `new` and `init` | the workspace's own files |
| `docs/`, `README.md`, `llms.txt`, `llms-full.txt` | Documentation, shipped in the npm package. `llms-full.txt` is built from the pages `llms.txt` lists | (not copied) |
| `tools/build-llms-full.py` | Builds `llms-full.txt` (`npm run docs`; not shipped) | |
| `test/smoke.sh` | The whole test suite (not shipped) | |

Kit files are replaced on every `cabinet update` and must never be edited in a workspace; project files are the project's own after setup.

## Rules

1. **Never touch the real machine while testing.** Every test and experiment runs in a `mktemp -d` folder with `HOME` pointed inside it (git then reads that folder's `.gitconfig` as its global config), and a fake `launchctl` first on `PATH` from the very start, never added only by a later step. Never read or write the real `~/.claude`, `~/.qwen`, `~/.cursor`, `~/.config`, `~/Library/LaunchAgents`, the keychain or the global git config. `test/smoke.sh` does this in its header for every section; follow its pattern. After an experiment, check that `launchctl list` shows no `ai.cabinet.` job you did not mean to load.
2. **Never weaken a guardrail, and never test one by trying a real push, merge or publish.** Test a rule with the tool's own matcher, or with a harmless command of the same shape (for example `git log` for `git push`). A new rule format is untested until shown to work, and the docs say so.
3. **bash 3.2.** macOS ships it, so the kit runs on it: no `mapfile`, no associative arrays, no `${var,,}`; guard empty arrays (`${a[@]+"${a[@]}"}`); declare an array on its own `local` line; no apostrophe inside `${x:+...}` in double quotes.
4. **Untrusted values never reach a shell.** Anything from a cloned project (`package.json`, folder names, git remotes) is checked (`safe`, `url_ok`, `name_ok` in `bin/cabinet`) before it is written into `cabinet.env`, `repos.tsv` or a schedule. `cabinet.env` and job files are sourced as shell.
5. **Never lose a user's data.** A config file is changed only through `write_into` (written only when the result is valid and non-empty); an existing file is kept, never replaced; restore copies anything it would replace to `recovered/` first.
6. **Docs match the code.** A change to a command, option, file, message or behavior updates `docs/` (and `README.md` when it is user-facing) in the same change, then `npm run docs` rebuilds `llms-full.txt`. `npm test` fails when a command, option, script, doctor message or check ID is missing from the docs, a link or heading anchor is broken, or `llms-full.txt` is stale.
7. **One command table.** Every `cabinet` command and option is a row in `commands_table` in `bin/cabinet`; help, `--help`, `help --json` and tab completion are made from it. A new command or option starts there, then its parser and dispatcher line; the tests fail when the three disagree.
8. **Stable IDs for machines.** Each doctor check has an ID (`ok <id> "message"`), and each `cabinet next` step has one. A new check gets a new ID, listed in `docs/troubleshooting.md`; an ID or a JSON field is never renamed or removed without a changelog entry that says so.
9. **Every change has a test** in `test/smoke.sh`, and an entry in `CHANGELOG.md` under the next version.
10. **Writing.** ASCII punctuation only (no em or en dashes, no curly quotes). Dates people read as `18 Oct 2026`; machine formats stay ISO. No personal or project names, local paths, or comparisons with other products. Name third-party tools only as facts (which tools have guardrails).
11. **Never push, merge, publish or release.** Only the maintainer does. Commit finished, tested work locally, with no AI or tool attribution lines.

## Checks

```sh
npm test                                      # every section, about a minute; must end with PASS
npm test -- init config                       # only the sections whose name has a word, and what they need
CABINET_PRIVATE_WORDS="word1 word2" npm test  # also fails on any private word in the kit
npm run docs                                  # rebuild llms-full.txt after changing a doc
npm pack --dry-run                            # what the package ships
```

A new test section is a `section "<name>" "<numbers of the sections it needs>"` line and an `sN()` function in `test/smoke.sh`, ending with `return 0`. Before finishing, run each section you touched alone (`npm test -- "<its name>"`): that proves its list of needs is complete.
