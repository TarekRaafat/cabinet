# @@PROJECT@@ workspace

The folder that holds the files that tie the @@PROJECT@@ repos together, and usually the repos themselves: the agent rules, the handoff log, each repo's local-only files, and the guardrails that keep the owner in control of anything that leaves the machine. Built on the cabinet kit (version in `.cabinet/version`).

This repo is private and tracks only its own files. Each product repo has its own `.git`: one inside this folder is ignored here, and one elsewhere is listed in `repos.tsv` with its path.

| Start with | |
|---|---|
| `OPERATIONS.md` | The owner's manual |
| `CABINET.md` | How any cabinet workspace runs (from the kit) |
| `AGENTS.md` | What is specific to @@PROJECT@@ |

## New machine

```sh
git clone <this repo> @@SLUG@@ && cd @@SLUG@@
bin/bootstrap.sh --dry-run
bin/bootstrap.sh
bin/doctor.sh
```
