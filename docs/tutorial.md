# Tutorial: your first day with cabinet

About 15 minutes. You create a workspace for a made-up product, Acme, set up your machine, give the team its first task, and read the first brief. The output shown is what cabinet prints, shortened where it says `...`.

You need macOS or Linux, git, jq, perl, python3, Node.js and at least one agent tool (Claude Code, Codex, Gemini CLI, Qwen Code, Grok, opencode or the Cursor CLI). See [Install](../README.md#install).

## 1. Create the workspace

```sh
cd ~/dev
cabinet new acme --name "Acme"
```

In a terminal, `cabinet new` asks a few questions, each with a default you keep by pressing Enter: the owner, which roles to enable, the agent tool that runs scheduled jobs, the brief time, how agents write to you (standard, or short for little time to read), backups and the product repos. Here we keep every default (`--yes` does the same without asking):

```
== Project files
  placed: 14 files
== Kit files
roles: chief-of-staff product-manager architect qa security design-lead finance
== Committed the new workspace as Ann Owner

Created Acme at ~/dev/acme (slug acme, cabinet 0.1.0).
Next:
  - Fill the TBDs in AGENTS.md: what Acme is, its product rules, how to test, the repo rows.
  ...
```

The workspace is a git repo of plain files: `AGENTS.md` (the project's rules), `HANDOFFS.md` (how agents pass work), `roles/`, `specs/`, `notes/`, `jobs/` and the kit's own `CABINET.md` and `bin/`. [Concepts](concepts.md) explains each.

## 2. Ask what is next

From anywhere inside the workspace:

```sh
cd acme
cabinet next
```

```
Next in Acme (~/dev/acme):
  1. Fill the TBDs in AGENTS.md: What Acme is, Contracts that cross repo lines, House rules, Product rules, How to test.
  2. Download the pinned kit (in ~/dev/acme). Run: npm install
  3. Set up this machine: guardrails and schedules (add --dry-run to see the changes first). Run: cabinet bootstrap
  4. The first brief comes at 7:00 AM (or write it now). Run: cabinet brief
  5. The doctor found 9 thing(s) to fix (cabinet doctor --fix runs the ones it can). Run: cabinet doctor
  Optional: Daily encrypted backups. Run: cabinet config --backup-dir <a folder outside the workspace>
```

`cabinet next` changes nothing. Come back to it whenever you are unsure what to do.

## 3. Tell the team about the product

Open `AGENTS.md` and replace each `TBD` with a few plain sentences: what Acme is, the rules every agent follows (for example "prices are the owner's decision"), and how to test. The agents read this file at the start of every session, so short and exact beats long. Longer documents the team must follow, such as a brand guide or a support policy, go in `guides/` with a row in the "Guides" table ([recipes](recipes.md#add-your-own-rules-guidelines-and-business-documents)).

Then download the pinned kit, so the workspace keeps its own version, and commit:

```sh
npm install                # skip until the package is published to npm
git add -A && git commit -m "Describe Acme"
```

## 4. Set up this machine

See first, then apply:

```sh
cabinet bootstrap --dry-run
cabinet bootstrap
```

```
== Git push gate
  placed ~/.config/git/hooks/pre-push
  ...
== Claude Code
  added 61 permission rule(s) to ~/.claude/settings.json
== Codex
  placed ~/.codex/rules/default.rules
...
== Schedules (launchd)
  installed ai.cabinet.acme.brief (7:00 AM)
```

Bootstrap installs the guardrails: every push now asks you at your own terminal, and each agent tool on this machine denies push, merge, release and publish ([guardrails](guardrails.md)). It also schedules the daily brief. It saves a `.bak` copy of every settings file it changes, and running it again is safe.

## 5. Check everything

```sh
cabinet doctor
```

```
All good. 3 note(s) below.

== Product repos
  ok    product repos checked
== Kit and roles
  ok    cabinet 0.1.0
...
```

When something needs you, the doctor starts with the list, and `cabinet doctor --fix` runs the fixes it knows. Every message is in [troubleshooting](troubleshooting.md).

## 6. Give the team its first task

Open your agent tool in the workspace and describe a feature, for example:

> We want a public pricing page. Spec it.

The product-manager agent writes the spec in `specs/`, with any decision only you can make framed as a question. When work moves from one agent to another, it goes through `HANDOFFS.md`:

```sh
cabinet handoff list          # every open handoff, oldest first
cabinet handoff list owner    # everything waiting on you, in full
```

## 7. Read the brief

Each morning at the time you chose, the chief-of-staff agent writes `BRIEF.md`. To get one now:

```sh
cabinet brief
```

The brief starts with the sign-off queue: each decision only you can make, as a plain question with lettered options, the experts' recommendations, and whether it can be undone. Answer them all in one message to your agent, for example "approve 1 and 3; 2: no; 4: wait until Friday". The agents apply your answers.

## 8. Ship

When qa and security have recorded PASS on a piece of work, you push it from your own terminal. The push gate asks you to confirm. No agent can push, merge, release or publish.

## Where next

- [Recipes](recipes.md): add a role or a job, switch agent tools, move to a new machine, add a teammate.
- [Commands](commands.md): every command and option. `cabinet <command> --help` shows them too.
- [Layouts](layouts.md): add cabinet to an existing project instead.
