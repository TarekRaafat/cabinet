# Recipes

Short answers to common tasks. Every command runs from anywhere inside the workspace, or the project around a `cabinet/` workspace. Commit the workspace after each change.

## Contents

- [Add your own rules, guidelines and business documents](#add-your-own-rules-guidelines-and-business-documents)
- [Add a role](#add-a-role)
- [Turn a role off, or back on](#turn-a-role-off-or-back-on)
- [Give a kit role project notes](#give-a-kit-role-project-notes)
- [Add a scheduled job](#add-a-scheduled-job)
- [Change the brief time, or turn it off](#change-the-brief-time-or-turn-it-off)
- [Switch the agent tool for scheduled jobs](#switch-the-agent-tool-for-scheduled-jobs)
- [Add a product repo](#add-a-product-repo)
- [Turn on backups](#turn-on-backups)
- [Move to a new Mac](#move-to-a-new-mac)
- [Add a teammate to a shared workspace](#add-a-teammate-to-a-shared-workspace)
- [Run several projects](#run-several-projects)
- [Update the kit](#update-the-kit)
- [Use cabinet from a script or an agent](#use-cabinet-from-a-script-or-an-agent)

## Add your own rules, guidelines and business documents

Pick the place by what it is:

| You have | Put it in | Followed by |
|---|---|---|
| A rule that fits in a line or two ("prices are the owner's decision", "every page works on a phone") | `AGENTS.md`: "House rules" for how the team works, "Product rules" for what the product must and must not do | every agent, every session |
| A whole document: brand guide, writing or code style guide, security or privacy policy, pricing rules, support promises, any business document | `guides/<file>`, plus a row in the "Guides" table of `AGENTS.md` | every agent, or the roles its row names, before any work it covers |
| Duties, paths or limits for one role ("qa tests on the staging account") | `roles/<role>.md`, plain Markdown, then `cabinet roles` | that role |
| Rules for one repo | that repo's own `AGENTS.md` | agents working in that repo |
| How to test, and what must never be touched | "How to test" in `AGENTS.md` | qa, and every agent that runs the product |
| Thinking, research or a decision with its reasons | `notes/`, with `status: draft` or `decided` | agents whose task touches its topic |

**Add a guide in three steps:**

1. Put the file in `guides/`: `guides/brand.md`. Markdown or plain text works with every agent tool; a PDF works with the tools that read PDFs.
2. Add its row to the "Guides" table in `AGENTS.md`:

   ```markdown
   | Guide | What it covers | Who follows it |
   |---|---|---|
   | `guides/brand.md` | Voice, names, colors and logo use in anything people see | every agent |
   | `guides/refunds.md` | What support may promise a customer | product-manager, qa |
   ```

3. Commit the workspace. `cabinet doctor` reports a guide with no row (agents would never read it) and a row whose file is missing.

**Or ask an agent:** "Add this as a guide every agent follows: <paste or file>". It saves the file, adds the row and commits, as `guides/README.md` says.

**What wins:** a repo's `AGENTS.md` over the workspace's `AGENTS.md` and its guides, over the kit's `CABINET.md`. No rule or guide can loosen "Never push, merge, publish or release" or "The builder never verifies"; the guardrails enforce the first anyway. Never edit `CABINET.md`: it is the kit's, and `cabinet update` stops on an edited kit file.

**Folders:** the workspace's git tracks only the folders its `.gitignore` lists (`guides/`, `notes/`, `specs/`, `roles/` and the rest). A new top-level folder of your own is not committed until you add a `!/<folder>/` line to `.gitignore`; prefer `guides/` for documents agents follow.

## Add a role

First, check whether a kit role fits. Besides the seven on by default and the four builders, the kit has four optional roles, off until you turn them on:

| Role | For |
|---|---|
| brand-designer | logos, graphics and templates inside the brand, and a draft brand guide for you to decide |
| dba | reviewing every migration, database performance, backups and access plans |
| code-reviewer | reviewing each change's code before a push (PASS or CHANGES) |
| auditor | audits of dependencies, access, personal data and configuration |

Turn one on with the other roles you keep: `cabinet config --roles "qa security dba"`.

For anything else, make a role of the project's own. You need only its name:

```sh
cabinet role new brand-strategist
```

In a terminal it asks four questions: what it should do, what it owns, what it may decide on its own, and what it must bring to you. Answer what you know and press Enter for the rest; `--does`, `--owns`, `--decides` and `--escalates` give the answers as options, and `--yes` asks nothing. It writes `roles/<role>.md` with your words under "The owner's brief", turns the role on, adds its rows to the team tables, and builds it.

Then have it drafted, in one of two ways:

- **In your agent session:** "draft the brand-strategist role". Any agent tool follows `CABINET.md`, "Drafting a role".
- **From the terminal:** `cabinet role draft brand-strategist` (or `--draft` on `role new`) runs your configured agent tool as chief-of-staff. It may cost money.

The draft starts from your brief, which wins, and learns the rest from the project: `AGENTS.md`, the specs and roadmap, the notes, the repos and the roles already on the team. It writes the role a strong specialist would hold on this product: what it owns, decides, brings to you, how its work is checked, and where it stops and its neighbours start. Every choice your brief did not make is listed under "Assumed, for the owner to confirm", and chief-of-staff puts those in your sign-off queue until you answer.

Know more later? Add it to "The owner's brief" in `roles/<role>.md` and run `cabinet role draft <role>` again. Until a role is drafted, the doctor reminds you, and the role does only what your brief asks.

By hand instead: write `roles/<role>.md` with frontmatter (`name`, `description`, `tools`) like the kit's roles in `.cabinet/roles/`, then `cabinet config --roles "<the roles you keep> <role>"`.

A new role is your decision (`CABINET.md`, "Seats").

## Turn a role off, or back on

`cabinet config --roles "<every role you want>"`. The list replaces the old one; chief-of-staff is always on. A role you turn off leaves the team tables, and a kit role you turn back on returns with its row.

## Give a kit role project notes

Write `roles/<role>.md` (for example `roles/qa.md`) as plain Markdown, no frontmatter: the paths, duties and limits this project adds. Then `cabinet roles`. The notes are added to the kit's definition under "Project notes".

## Add a scheduled job

1. Write `jobs/<job>.job`:

   ```sh
   AGENT=growth
   WHEN="sun 9:00 AM"        # a time every day ("9 AM"), days and a time ("fri,sat 10 AM"), or "" for by hand only
   MINUTES="5"
   TIMEOUT="30"              # stop it after 30 minutes; "" uses CABINET_JOB_TIMEOUT (60), "0" for no limit
   RESULT="specs/weekly.md"
   PROMPT="Write this week's numbers."
   AFTER=""
   ```

2. Name the job in `OPERATIONS.md` (the doctor checks that the manual names every job).
3. `cabinet bootstrap` schedules it. `cabinet run <job>` runs it now.

Remove a job by deleting its file and running `cabinet bootstrap`.

## Change the brief time, or turn it off

`cabinet config --brief "8:30 AM" --apply` (or `--brief off`, `--brief "fri 4 PM"` for Fridays only, or `--brief "sun,mon,tue,wed,thu 8 AM"` for chosen days; full day names work too). `--apply` updates the schedule right away.

## Switch the agent tool for scheduled jobs

`cabinet config --runner codex --apply`. Install that tool first: the doctor checks that scheduled jobs can find it. For any other tool, `--runner custom --runner-cmd '<command using "$CABINET_PROMPT">'`.

## Add a product repo

`cabinet config --repo git@example.com:acme/web.git`, then let it run bootstrap (or `cabinet bootstrap`), which clones it. To remove a repo, delete its row from `repos.tsv`.

## Turn on backups

1. `cabinet config --backup-dir ~/Backups/cabinet --apply`. The folder must be outside the workspace and its repos.
2. Choose a passphrase, keep it in your password manager, and put it in the keychain: `security add-generic-password -a "$USER" -s cabinet.<slug>.backup -w`.
3. `cabinet backup` makes one now; the schedule makes one daily. See [backups](backups.md).

## Move to a new Mac

1. Install cabinet and its needs ([Install](../README.md#install)).
2. Put the backup passphrase in the keychain, as in step 2 of [Turn on backups](#turn-on-backups).
3. `cabinet restore <newest archive> ~/dev/acme`. It works before the workspace exists, and never loses a file ([backups](backups.md#restoring)).
4. `cd ~/dev/acme`, then `cabinet bootstrap` and `cabinet doctor`.

Without a backup, clone the workspace's own repo instead, then `cabinet bootstrap`.

To move a workspace to another folder on the same Mac: `cabinet move <new-path>`.

## Add a teammate to a shared workspace

A shared workspace (`cabinet init --inside --shared`) is committed with the project, so a teammate gets it by cloning:

1. The teammate clones the project and runs `npm install`, which installs the pinned kit.
2. They run `cabinet bootstrap --no-schedules` on their Mac, then `cabinet doctor`. This installs the push gate and their agent tools' guardrails, but no schedules: one Mac, usually the owner's, runs the brief and the other jobs, so it is written once. The choice is saved for that Mac only (`cabinet.local.env`, which git does not track).

3. Backups follow the workspace's `CABINET_BACKUP_DIR`, which is shared. Each teammate sets their own folder for their Mac, or none: `cabinet config --this-mac --backup-dir ~/Backups/cabinet --apply` (or `--backup-dir off`). That also lives in `cabinet.local.env`.

Any teammate can still run a job by hand (`cabinet run <job>`). To make another Mac the one that runs the jobs: `cabinet bootstrap --no-schedules` on the old one, `cabinet bootstrap --schedules` on the new one.

## Run several projects

One workspace per project: `cabinet new` (or `cabinet init`) for each. Each has its own slug, so its own schedules, logs, backups and brief; the guardrails are shared by the whole Mac. One project with several repos or products is one workspace, with every repo in `repos.tsv`.

`cabinet list` shows them all in one table: what waits on you, what the doctor finds, the latest brief. Each morning, `cabinet digest` gathers every project's sign-off queue and your actions into one read (`cabinet digest --schedule --notify` writes it to `~/Library/Logs/cabinet/digest.md` every day at 10:00 AM and tells you; `--schedule "8 AM"` for another time, `--schedule "sun,mon,tue,wed,thu 8 AM"` for chosen days); answer each queue in its own workspace (`cd` there and tell its agent). Then `cabinet next` inside any of them.

## Update the kit

```sh
cabinet outdated      # is a newer version published?
npm update            # take it
cabinet update        # apply it, and read the changelog since your version
git diff              # review, then commit
```

An update never overwrites a kit file you edited: it stops and names it.

## Use cabinet from a script or an agent

Read JSON, never the text output, which may be reworded:

```sh
cabinet help --json              # every command and option
cabinet next --json              # the next steps, each with a stable id and its command
cabinet doctor --json            # every check, each with a stable id
cabinet handoffs owner --json    # what waits on the owner, in full
```

The fields are in [commands](commands.md#output-for-agents-and-scripts). For the whole manual in one file, read `llms-full.txt` in the kit.
