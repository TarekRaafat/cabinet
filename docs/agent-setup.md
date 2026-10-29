# Set up Cabinet for someone

For an AI agent that a person asked to set up Cabinet for them, from this repository or its link. Follow these steps in order. You are setting Cabinet up, not changing it: the `AGENTS.md` at the root of this repository is for people and agents who develop the kit, and does not apply to this job.

## Ground rules

- **The person decides; you prepare and explain.** Ask before anything that changes their machine outside the new workspace, and show what will change first.
- **Your shell is not a terminal,** so Cabinet's commands ask no questions there. Ask the person yourself, then pass every answer as an option with `--yes`. Run each command with `--dry-run` first and show the person what it would do.
- **Never install system packages yourself** (git, Node.js, a package manager's packages). Give the person the command; `cabinet doctor --json` names it (check `deps.required`).
- **Never run `cabinet new` or `cabinet init` inside this repository.** The workspace is a folder of its own, or a folder inside the person's project.
- **Never push, merge, release or publish.** The person does.

## 1. Check the machine

Cabinet runs on macOS and Linux (Windows only through WSL). It needs git, Node.js 18 or newer and npm, and at least one agent tool the person uses (Claude Code, Codex, Antigravity, Qwen Code, Grok, opencode or the Cursor CLI; Gemini CLI for interactive sessions only, not scheduled runs).

```sh
git --version && node -v && npm -v
git config --global user.name; git config --global user.email   # empty: ask for them (step 3)
```

If a tool is missing, tell the person how to install it (the README's [Install](../README.md#install) has the commands) and wait.

## 2. Get the `cabinet` command

Install the package:

```sh
npm i -g @tarekraafat/cabinet
```

Only if the person wants the newest code from GitHub instead, from a clone they keep: it is what runs, so ask where it should live, and reuse the clone you already have if you cloned the repository to read it. Update it later with `git -C <clone> pull`. Linking the command changes the person's machine, so ask first:

```sh
git clone https://github.com/TarekRaafat/cabinet.git ~/cabinet-kit   # or reuse your clone
mkdir -p ~/.local/bin && ln -s ~/cabinet-kit/bin/cabinet ~/.local/bin/cabinet
export PATH="$HOME/.local/bin:$PATH"   # for your own shell, which reads no rc file
command -v cabinet
```

If `~/.local/bin` is not on the person's own PATH, ask, then add that `export` line to their `~/.zshrc` or `~/.bashrc`.

## 3. Ask the person

Ask the first three, then propose the rest as defaults in one message and let the person change any of them.

| Ask, in plain words | Option | Default |
|---|---|---|
| What is the project called? | `--name "Name"` | the folder name |
| Is it a new project, or one that exists already (a folder or a code repository)? | `cabinet new` or `cabinet init` | |
| Which AI tool do you use? | `--runner claude\|codex\|antigravity\|qwen\|grok\|opencode\|cursor` | the first one installed |
| Which model should its runs use? Only ask when the person names one. | `--model <name>` ([models](#models)) | the tool's own default |
| A lighter model for the roles that plan and route? Only ask when the person names one. | `--model-light <name>`, with `cabinet config` after setup ([models](#models)) | none |
| Where should its folder go? (new projects) | `[dir]` | `~/dev/<name>`; suggest a folder they know, such as `~/Documents/<name>`, to someone who is not a developer |
| What kind of work is it: code, or something else such as design, writing or music? | `--roles "..."` | the seven core roles: chief-of-staff, product-manager, architect, qa, security, design-lead, finance |
| Any code repositories to include? (new projects) | `--repo <url>`, repeatable | none |
| Your name and email, for the record of changes? | `--owner "Name" --email you@example.com` | git's global identity; when it is empty, pass both, or setup creates the workspace without saving it (no commit) |
| When should the daily brief with your decisions arrive? | `--brief-time "7 AM"`, or `off` | 7:00 AM every day |
| Which day does your week start? | `--week-start sunday` | `sunday` |
| Short or standard messages from the team? | `--writing short\|standard` | `standard` |
| Should each commit a role makes in a Cabinet run credit that role beside them, with the Cabinet Team avatar on GitHub? | `--credit-roles on\|off` | `on` |
| A weekly spending limit for the agents' runs? Scheduled runs use the person's own agent tool account and its plan or usage costs. | `--budget <dollars>\|off` (and `--price "<in> <out>"` for codex, cursor, qwen or antigravity) | off |
| Encrypted daily backups, and to which folder (outside the project)? | `--backup-dir <folder>\|off` | off |

**Work that is not code** (design, writing, marketing, music, finance): pick roles that fit, for example `--roles "product-manager design-lead brand-designer qa"` for brand and design work (`chief-of-staff` is always on). Leave out `--repo`. Later the team works in folders of the workspace, each with one owning role in the team table of `AGENTS.md` (the template has `brand/` for brand-designer), and its standing documents (a brand guide, a style guide) go in `guides/`. Tell the person that Cabinet's defaults are still made for code first ([roadmap](../ROADMAP.md)), and that agents can only make what their tools can make: text, SVG and HTML well; files in a design or audio app only with a tool connected for it.

A website that is only designed (mockups) is design work: HTML and SVG pages in a workspace folder such as `website/`, with its own row in the team table. A website that is built and published is code: it needs a repository, which gets a builder (below).

**No repository yet:** leave out `--repo`. Builders, the roles that write code, come with repositories, so tell the person that coding starts once one exists: create it (an empty folder with `git init` is enough), then `cabinet repo add <url-or-path> --apply`.

**An existing folder of files that is not a repository** (design files, documents): `cabinet init` in that folder makes it the workspace and keeps every file in it.

### Models

`--model` (`CABINET_MODEL`, or `MODEL` in one job file) goes to the tool through its own option, as its own argument before the prompt. The doctor (`model.exists`), setup and `config` check the name against the tool's model list when the tool can list its models without a run; Cabinet never makes a paid run to check one. Seen on these versions:

| Runner | Model option | Free model list | Checked |
|---|---|---|---|
| `claude` (Claude Code 2.1.312) | `--model` | none | not checked (a note) |
| `codex` (Codex 0.165.0) | `--model` | `codex debug models` (JSON, each `slug`) | yes |
| `antigravity` (`agy` 1.4.8) | `--model` | `agy models` (the name before each tab) | yes |
| `qwen` (Qwen Code 0.26.2) | `--model` (a string: an all-digit name stays text) | none | not checked (a note) |
| `grok` (Grok 1.0.70) | `--model` | `grok models` (each `*` or `-` line) | yes |
| `opencode` (opencode 2.2.0) | `--model`, as `provider/model` | `opencode models` | yes |
| `cursor` (Cursor CLI 2026.10.22) | `--model` | `cursor-agent models` (the name before ` - `) | yes |
| `custom` | `$CABINET_MODEL` in its environment | none | not checked (a note) |

A list that needs the network or a login and cannot be read gives a note, never a problem.

A second, lighter model, `CABINET_MODEL_LIGHT` (`cabinet config --model-light <name>`), runs the roles in `CABINET_LIGHT_ROLES` (by default chief-of-staff, product-manager, design-lead and finance, those on the team); every other role keeps `--model`. It reaches the tool the same way, and with Claude Code also as a `model:` line in each role's file in `.claude/agents/`. The doctor checks it as `model-light.exists` ([a light model for some roles](commands.md#a-light-model-for-some-roles)).

## 4. Create the workspace

A new project:

```sh
cabinet new ~/dev/taskly --name "Taskly" --runner claude --yes --dry-run   # show the person
cabinet new ~/dev/taskly --name "Taskly" --runner claude --yes
```

An existing project, from its top folder. Choose the layout with the person ([layouts](layouts.md)):

| Layout | Options | When |
|---|---|---|
| Inside, private (the default) | `--inside --private` | One person's team. A `cabinet/` folder with its own git; no tracked file of the project changes. |
| Inside, shared | `--inside --shared` | The team is part of the project for everyone who clones it. Nothing is committed; the person reviews and commits. |
| Beside | `--beside [--workspace <folder>]` | A separate folder next to the project (default `<project>-hq`). |
| Around | (run in a folder that is not a repo) | A folder holding several repos becomes the workspace. |

```sh
cd ~/code/shopfront
cabinet init --inside --private --runner codex --yes --dry-run   # show the person
cabinet init --inside --private --runner codex --yes
```

When the project already has its own `AGENTS.md`, the private layout leaves it alone and says so. Codex, opencode, Gemini and Cursor read only that file, so without a pointer they never meet the team. Offer the person to add this section to the end of their `AGENTS.md` (it is the one the shared layout adds by itself):

```markdown
## Agent team

The agent team for this project works from `cabinet/`. Before any task that involves handoffs, specs, verdicts or the team's roles, read `cabinet/CABINET.md`, then `cabinet/AGENTS.md`. Their paths are relative to `cabinet/`.
```

Prefer it to starting those tools in `cabinet/`: Codex, for one, may write only inside the folder it starts in, so started in `cabinet/` it could not change the project's code. For the same reason Codex's default sandbox may not let a scheduled brief write its file; if `BRIEF.md` stays empty after the first scheduled run, tell the person ([agent tools](concepts.md#agent-tools-and-models)).

## 5. Set up the machine, only after a yes

`cabinet bootstrap` changes this machine for every project on it, so show the dry run and explain it first:

```sh
cabinet -C ~/dev/taskly bootstrap --dry-run
```

What to tell the person it does ([guardrails](guardrails.md)):

- **A push gate for every repository on this machine:** a global git pre-push hook (through `core.hooksPath`) that asks for `yes` at their terminal for every `git push`. Agents have no terminal, so their pushes are refused. A repository's own hooks still run.
- **Deny rules in each agent tool it finds** (for example `~/.claude/settings.json`, `~/.codex/rules/default.rules`): push, merge, release and publish commands are blocked. Rules are only added, and a backup copy of each file is made first.
- **Schedules:** the daily brief (and backups when they are on), through launchd on macOS or systemd or cron on Linux.
- **A secrets check** before each commit in the workspace.

Then, if the person says yes:

```sh
cabinet -C ~/dev/taskly bootstrap
```

For a machine that should not run the workspace's jobs (a teammate's), add `--no-schedules`. To undo: [Undoing the guardrails](guardrails.md#undoing-the-guardrails), or `cabinet remove` for the whole workspace.

Tell the person two more things before they answer:

- **It changes your own rules too.** The deny rules apply to you, the agent running the setup, from then on: you can no longer push, merge or publish, as intended.
- **It can wait.** Without `bootstrap` the workspace still works when they work with the team in person, but nothing runs on its own (no daily brief, no backups) and nothing guards a push. Work without code has nothing to push, so the brief schedule is the main thing it brings there. They can run it any time later.

## 6. Check the result

```sh
cabinet -C ~/dev/taskly doctor --json   # "problems": 0, or each problem with its fix
cabinet -C ~/dev/taskly next --json     # the steps left, in order
```

`-C` takes the workspace, or for an inside layout the project's top folder (commands find the workspace from there). Fix what you may (a step with a command that changes only the workspace); bring the rest to the person.

## 7. Tell the person

- Where the workspace is, and that it is saved (committed; or, without a name and email, how to commit it).
- **Fill the `TBD` lines in `AGENTS.md`:** what the project is, its rules, and how it is checked. Offer to draft them together.
- **How to work with the team:** open the agent tool in the workspace (for an inside layout, in the project, once the tool can find the team there: see step 4) and give it a task in plain words; each morning, read `BRIEF.md` and answer its sign-off queue in one message.
- They push and publish themselves; agents cannot.
- What `bootstrap` changed on the machine, and how to undo it.
- `cabinet next` always says what to do next.

More: [recipes](recipes.md) for everyday tasks, and [Use Cabinet from a script or an agent](recipes.md#use-cabinet-from-a-script-or-an-agent) for the JSON every command gives.
