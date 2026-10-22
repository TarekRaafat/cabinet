<img src="docs/logo.svg" width="96" height="96" alt="The Cabinet mark: seven seats around a table, one place left open for the owner">

# Cabinet

One person, a whole team. Build anything with AI agents, and stay in charge.

Cabinet is a productivity kit that makes one person a whole team. It does not replace you; it multiplies you. Agents fill every seat your work needs (architecture, design, writing, review, finance, and any specialty you lack), and you stay the one who decides. Alone, you work like a full company. In a team, every member does.

In practice, Cabinet gives a project a small company: roles with clear authority (chief of staff, product manager, architect, qa, security, design lead, finance, builders that write the code in each repo the way it is already built, optional specialists, and any role your project needs, drafted for it from a one-line brief), one place where agents hand work to each other, a daily brief that puts every decision you must make in one queue, independent review before anything ships, and guardrails that keep every push, merge and publish with you. It is plain Markdown and shell scripts, so any agent tool can run it.

Cabinet is for one person or a team of any size, and for anything agents can build: code, apps and websites, design, writing, marketing, music, finance. Beyond the core roles, every seat a project needs is drafted for it. Today its defaults are made for code (builders in repos, guardrails on push); other work runs through roles drafted for it and specs on workspace areas, and making that path as complete is on the [roadmap](ROADMAP.md).

- **Platform:** macOS and Linux ([what differs](docs/concepts.md#macos-and-linux)). Windows through WSL is on the [roadmap](ROADMAP.md).
- **Status:** version 0.1.0, not yet published to npm. Until it is, install from a clone (see [Install](#install)).
- **Works with:** Claude Code, Codex, Gemini CLI, Antigravity, Qwen Code, Grok, opencode, the Cursor CLI, and any other tool that reads `AGENTS.md`.

## Contents

- [Why Cabinet](#why-cabinet)
- [Quick start](#quick-start)
- [A day with Cabinet](#a-day-with-cabinet)
- [Words you will see](#words-you-will-see)
- [Install](#install)
- [Start a new project](#start-a-new-project)
- [Add Cabinet to an existing project](#add-cabinet-to-an-existing-project)
- [Change settings later](#change-settings-later)
- [Update the kit](#update-the-kit)
- [Remove Cabinet](#remove-cabinet)
- [Develop the kit](#develop-the-kit)
- Learn: [tutorial](docs/tutorial.md) (your first day, about 15 minutes), [recipes](docs/recipes.md) (common tasks)
- Reference: [commands](docs/commands.md), [layouts](docs/layouts.md), [concepts](docs/concepts.md), [guardrails](docs/guardrails.md), [backups](docs/backups.md), [troubleshooting](docs/troubleshooting.md)

## Why Cabinet

Cabinet started as one person's own setup: a product manager, UX/UI designer and developer, with more than ten years in each. For a year and a half, on small, medium and large products in production, it has been how he works. Alone, the agents do most of the work across product, design, development and writing, while he brings the vision and signs off; his output grew about tenfold. With a team of five on a project that needed three times as many people, it gave each person two more teammates, all following the same guidelines, design system, workflow and process toward one goal. A few colleagues who saw the results tried it and found the same. It became this kit so anyone can start with it instead of rebuilding it. It is open source.

What it believes:

- **People amplified, not replaced.** Every person becomes a whole team, or a whole company. Agents bring the skills and the hours; the person brings vision, judgment, and the final say.
- **More output per person, not more headcount.**
- **A small company, not a corporate org chart.** Every repo and area has exactly one owner, and nothing is done twice.
- **People decide, agents do the work.** Agents recommend; you sign off on anything irreversible, public or costly, and you always know what is happening.
- **For anyone.** One person or a team of any size, building anything, working their own way.

## Quick start

```sh
npm i -g @tarekraafat/cabinet     # once published; until then see Install
cabinet new                       # answers a few questions, creates and commits the workspace
cd <your new workspace>
cabinet next                      # what to do next, in order
cabinet bootstrap --dry-run       # see what it would change on this machine
cabinet bootstrap                 # guardrails for your agent tools, and the daily brief schedule
cabinet doctor                    # everything that needs attention; --fix runs the fixes it knows
```

New to Cabinet? The [tutorial](docs/tutorial.md) walks through the first day. Then fill the `TBD` lines in `AGENTS.md`: what the product is, its rules, and how to test it. Every command works from any folder inside the workspace or its project, and all of them follow one pattern: one word for the workspace as a whole (`cabinet doctor`), a noun then a verb for what it holds (`cabinet role add`, `cabinet repo list`); `cabinet help` lists them ([how commands are named](docs/commands.md#how-commands-are-named)). Several projects? One workspace each; `cabinet list` shows them all, and `cabinet digest` gathers every sign-off queue into one morning read.

## A day with Cabinet

1. **Morning.** At the time you chose, the chief-of-staff agent writes `BRIEF.md`. It starts with the sign-off queue: every decision only you can make, each as a plain question with lettered options, the experts' recommendations and whether it can be undone.
2. **You answer in one message**, for example "approve 1 and 3; 2: no; 4: wait until Friday". The agents write your answers into the right specs and handoffs.
3. **The agents work.** Each owns its repos and passes work to the others through `HANDOFFS.md`. The agent that built something never verifies it: qa and security do, and either can block it. Screenshots and recordings of the work are links in the brief, one click to open. `cabinet spec run <spec>` runs those steps for a whole feature, start to ready, so you start no agent by hand.
4. **You push** what has passed review, from your own terminal. No agent can push, merge, release or publish.

## Words you will see

| Word | Meaning |
|---|---|
| Workspace | The folder that holds the team's files (`CABINET.md`, `AGENTS.md`, `HANDOFFS.md`, roles, specs, notes) and usually the product repos. It is its own private git repo. |
| Layout | Where the workspace sits: a new folder, around an existing folder of repos, inside a project as `cabinet/`, or beside a project. See [layouts](docs/layouts.md). |
| Slug | The workspace's short name (`acme`). It names its schedules, logs, backups and backup key, so projects on one machine never collide. |
| Guide | A standing document the agents follow, such as a brand guide, style guide, policy or business document. It lives in `guides/`, with a row in `AGENTS.md`. |
| Role | An agent's job description: what it owns, decides, escalates and may write. Kit roles live in `.cabinet/roles/`; a project adds notes in `roles/`. |
| Spec | One file per feature in `specs/`: the problem, the rules, testable acceptance criteria, your decisions, and the builders' plan. Work bigger than a small task is built only from a spec that is ready. |
| Handoff | One entry in `HANDOFFS.md`: who it is for, what changed, what they need to do. The only channel between agents. |
| Sign-off queue | The top of `BRIEF.md`: every decision waiting on you. |
| Tiers | Who decides what: the agent (reversible, in its own files), its lead (reversible, across repos), or you (irreversible, public, or costs money). |
| Guardrails | Rules installed in each agent tool, plus a git hook, that keep push, merge, release and publish with you. See [guardrails](docs/guardrails.md). |

More in [concepts](docs/concepts.md).

## Install

You need macOS or Linux, and:

| Required | For |
|---|---|
| git | Every command, handoffs and the guardrails |
| Node.js 18 or newer, and npm | Installing Cabinet and pinning its version in each workspace; the scripts' shared logic runs with Node |
| At least one agent tool | Running the team and its scheduled jobs: Claude Code, Codex, Antigravity, Qwen Code, Grok, opencode, the Cursor CLI, or your own command (Gemini CLI for interactive sessions only) |
| A scheduler | launchd on macOS (built in); systemd user timers on Linux, or cron where the machine did not boot with systemd |

| Optional | For | Without it |
|---|---|---|
| openssl | Encrypted backups (built into macOS) | No backups; everything else works |
| `secret-tool` (Linux) | Keeping the backup passphrase in the secret store, as the keychain does on macOS | Not needed with cron, which reads a passphrase file; or set `CABINET_BACKUP_PASSPHRASE` ([macOS and Linux](docs/concepts.md#macos-and-linux)) |
| `notify-send` (Linux) | `cabinet digest --notify` | The digest is still written, with no notification |
| lsof | `cabinet move` checking that no agent session still has the folder open | The move skips that check |

`cabinet new`, `init` and `bootstrap` check for the required tools first and, in a terminal, offer to install the missing ones with your package manager; `cabinet doctor --fix` does the same later, and asks first for openssl or `secret-tool` when backups are on. Node.js and npm come first by hand, since npm installs cabinet:

- macOS: `brew install node` (git and openssl come with macOS and its command line tools).
- Debian or Ubuntu: `sudo apt install git nodejs npm`, and for the optional ones `openssl libsecret-tools libnotify-bin lsof`. Ubuntu 22.04 and Debian 11 install a Node.js older than 18; there, install a current one from [nodejs.org](https://nodejs.org).

```sh
npm i -g @tarekraafat/cabinet     # the short `cabinet` command everywhere
npx @tarekraafat/cabinet new      # or no install: run it through npx when you need it
```

Until the package is published, clone the repository and link the command (any folder on your PATH works):

```sh
git clone https://github.com/TarekRaafat/cabinet.git && cd cabinet
ln -s "$PWD/bin/cabinet" ~/.local/bin/cabinet
```

Tab completion: add `eval "$(cabinet completion zsh)"` to `~/.zshrc` (or `bash` to `~/.bashrc`).

Every workspace also pins its own copy as a dev dependency. Inside a workspace, the global `cabinet` hands off to that pinned copy, so it always acts with the project's version.

## Start a new project

```sh
cabinet new
```

It asks, each with a default you keep by pressing Enter:

- the project name, folder, and owner name and email (defaults from your git config);
- which roles to enable (chief-of-staff is always on: it writes the brief and routes work);
- the agent tool that runs scheduled jobs, the brief time (`7 AM`, days and a time like `fri 4 PM`, or `off`), and the first day of the week;
- a folder for the encrypted daily backup, outside the workspace (or `off`);
- the product repos, as git URLs.

It shows a summary, creates and commits the workspace, then offers to pin the kit (`npm install`) and to set up the machine (`bin/bootstrap.sh`, shown as a dry run first).

Every answer is also an option, and `--yes` skips the questions:

```sh
cabinet new ~/dev/acme --name "Acme" --roles "qa security" --runner claude \
  --brief-time "7 AM" --week-start sunday --writing standard --backup-dir off --repo git@github.com:acme/api.git --yes
```

All options: [commands](docs/commands.md#cabinet-new).

## Add Cabinet to an existing project

```sh
cd ~/dev/acme-app
npm i -D @tarekraafat/cabinet
npx cabinet init
```

In a project repo, `cabinet init` asks where the team's files go:

| Choice | What happens |
|---|---|
| **Inside, private** (default) | `cabinet/` inside the project, with its own git. The project's git ignores it, and no tracked file of the project changes. |
| **Inside, shared** | `cabinet/` inside the project, committed with it, for teammates who clone it. |
| **Beside** | A workspace folder next to the project, pointing at it. The project does not change. |

In a folder that is not a repo (one already holding your repos, for example), `init` makes that folder the workspace. In every layout, files that already exist are kept, never replaced.

Setup also reads what the project says about itself: its name, description, scripts and repository from `package.json`, and its own git identity. It copies them as facts, each marked with its source, and leaves `TBD` what no file can tell.

Details: [layouts](docs/layouts.md).

## Change settings later

```sh
cabinet config        # in the workspace, or the project's top folder when cabinet/ is inside it
```

It asks the setup questions again with your current answers as defaults, lists the changes, writes them (settings, team tables, roles), and offers to update schedules and clone new repos. Options, `--dry-run` and `--yes` work as in `new`; `cabinet config --budget 20` sets a weekly budget for the agent runs Cabinet starts ([what they cost](docs/concepts.md#what-agent-runs-cost)). `cabinet config --writing short` makes every brief, question and answer as short as it can be, for when you have little time to read ([writing to the owner](docs/concepts.md#writing-to-the-owner)). `cabinet config --hard-to-undo "api/migrations/"` names what a small task must never touch ([ready to build](docs/concepts.md#ready-to-build)). Details: [commands](docs/commands.md#cabinet-config).

## Update the kit

Each workspace pins its kit version, so projects update independently.

```sh
cabinet status        # this workspace's version, and any kit file edited here
cabinet outdated      # is a newer version published?
npm update            # take a newer version
cabinet update        # apply it: replace kit files, rebuild roles, print the changelog since your version
git diff              # review, then commit
```

An update never overwrites a kit file you edited in the workspace: it stops and names it. Without a global install, use `npx cabinet` in place of `cabinet`.

## Remove Cabinet

- **A workspace:** `cabinet remove` (`--dry-run` shows the plan first). It stops the workspace's schedules, deletes its folder, and inside a project removes what setup added there. It refuses work that exists nowhere else unless `--force`. Details: [commands](docs/commands.md#cabinet-remove).
- **The guardrails:** they stay in your agent tools' settings, since other workspaces may rely on them. Bootstrap saved a `.bak` copy of every file it changed; see [guardrails](docs/guardrails.md#undoing-the-guardrails).
- **The command:** `npm rm -g @tarekraafat/cabinet`.

## Develop the kit

```sh
npm test                                        # the whole kit in a scratch home folder, about a minute
npm test -- init                                # only the sections about init, and what they need
CABINET_PRIVATE_WORDS="word1 word2" npm test    # also checks that none of your private words is in the kit
```

Agents working on the kit: read [AGENTS.md](AGENTS.md) first.

A release: add its section at the top of `CHANGELOG.md` (`## X.Y.Z - D Mon YYYY`, with anything a workspace must do by hand), set `version` in `package.json`, run `npm test`, then `npm publish`. The package is scoped, which npm would publish as private; `publishConfig` in `package.json` makes it public.

## License

Apache-2.0
