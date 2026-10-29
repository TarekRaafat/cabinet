# Troubleshooting

Every message `bin/doctor.sh` can print, what it means and how to fix it. `FIX` lines make the doctor exit 1; `note` lines are information. `<...>` stands for a name, path or number the doctor fills in. Run the doctor again after a fix. The ID names the check: `cabinet doctor --json` gives it with each result, and it stays the same when a message is reworded, so scripts and agents match on the ID, never on the text.

## Tools

| Message | ID | Cause | Fix |
|---|---|---|---|
| `ok the tools cabinet needs are here (<...>)` | `deps.required` | git, node and npm are all found. | Nothing. |
| `ok Node.js is 18 or newer` | `deps.node` | The Node.js found can run the scripts' JavaScript. | Nothing. |
| `FIX cabinet needs Node.js 18 or newer; this is <...> (<...>)` | `deps.node` | The Node.js found is too old for the scripts' JavaScript, so most commands stop with the same message. Ubuntu 22.04 and Debian 11 install an older one. | `brew upgrade node` on macOS; on Linux, a current Node.js from [nodejs.org](https://nodejs.org). `cabinet new`, `init` and `bootstrap` stop with this message before changing anything. |
| `FIX cabinet needs <...>, not found (<...>; cabinet doctor --fix runs it, asking first)` | `deps.required` | A tool Cabinet needs is missing. The message names the install command for this machine (`brew`, `apt-get`, `dnf` or `pacman`), or where to get a package manager. | `cabinet doctor --fix` in a terminal, or run the command yourself. |
| `FIX backups need <...>, not found (<...>; cabinet doctor --fix runs it, asking first)` | `deps.backups` | Backups are on, and openssl (or, on Linux, `secret-tool`, unless `CABINET_BACKUP_PASSPHRASE` is set) is missing. | The same. |

## Product repos

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX <...>: no repo at <...> (run bin/bootstrap.sh)` | `repos.present` | A repo in `repos.tsv` is not where its row says. | `bin/bootstrap.sh` clones it (it needs a clone URL in the row), or fix the path column. |
| `FIX <...>/<...> missing` | `repos.local-file` | A local-only file listed in `repos.tsv` is not in the repo. | `bin/bootstrap.sh` restores it from `local/<repo>/`. |
| `FIX <...>/<...> not in snapshot (run bin/repo.sh snapshot)` | `repos.snapshot` | A local-only file has no copy in `local/<repo>/`. | `bin/repo.sh snapshot`, then commit the workspace. |
| `note <...>/<...> changed since last snapshot` | `repos.snapshot` | A local-only file differs from its copy. | `bin/repo.sh snapshot` when the change is finished, then commit. |
| `FIX <...>/<...> is tracked in the product repo but listed as local-only` | `repos.local-file-tracked` | The file is committed in the product repo, but `repos.tsv` says it lives outside git there. | Remove it from that repo's git (`git rm --cached`), or from the row's local-only list. |
| `FIX <...>/CLAUDE.md is not a link to AGENTS.md` | `repos.claude-link` | A repo whose row says `yes` to the link has no `CLAUDE.md` link. | `bin/bootstrap.sh` creates it (when the repo has an `AGENTS.md` and no `CLAUDE.md`). |
| `FIX <...>: instruction files show as untracked (missing exclude entry)` | `repos.instructions-excluded` | A repo's local `AGENTS.md` or `CLAUDE.md` shows in its `git status`. | Add them to that repo's `.git/info/exclude` (keep the entries in `local/<repo>/git-info-exclude`). |
| `note <...>: the folder of session <...> is gone (<...>): git -C <...> worktree prune` | `sessions.gone` | A [session](concepts.md#sessions)'s folder was deleted by hand; git keeps it listed until a prune. Its branch and commits are kept. | Run the `git worktree prune` it names. |
| `repos.tsv: skipped the row named "<...>" (not a plain folder name)` | - | A row's name has spaces or other characters. | Rename it to letters, digits, `.`, `_` or `-`. |

## Kit and roles

| Message | ID | Cause | Fix |
|---|---|---|---|
| `note cabinet <...> is out; this workspace runs <...>. Run<...>: <...>` | `kit.newer` | A newer Cabinet is on the registry (the release notice, at most one check a day). A note, never a problem. | Run the command it gives when you choose; `cabinet config --update-check off` turns the notice off. |
| `FIX kit files edited here (an update will refuse them; move the change to a project file or into the kit): <...>` | `kit.unedited` | A file the kit owns (`CABINET.md`, `bin/`, `.cabinet/`) was changed in the workspace. | Move your change to a project file (`AGENTS.md`, `roles/`, `jobs/`), then `git checkout -- <file>`. |
| `FIX workspace CLAUDE.md link missing (run bin/bootstrap.sh)` | `kit.claude-link` | The workspace's `CLAUDE.md` link to `AGENTS.md` is gone. | `bin/bootstrap.sh`. |
| `FIX HANDOFFS.md missing` | `kit.handoffs-file` | The handoff log was deleted. | Restore it from git. |
| `note the <...> role is not drafted yet (cabinet role draft <...>, or ask your agent to draft the <...> role)` | `roles.drafted` | `cabinet role add` made the role from your brief, and no agent has drafted it yet. Until then it does only what the brief asks. | `cabinet role draft <role>`, or ask your agent to draft it ([recipes](recipes.md#add-a-role)). |
| `note project roles behind the workflow: <...> (redraft each: cabinet role draft <role>, which keeps what you confirmed)` | `roles.workflow` | A drafted role of the project's own misses part of the workflow its job touches, usually because it was drafted before the kit added it: it never sends the agent to `CABINET.md`; it talks of PASS, BLOCK or CHANGES without `bin/handoff.sh record`; it says nothing of how a disagreement with a neighbouring role is settled; or it owns a repo and says nothing of its plan or its evidence. Each role is named with what it misses. These are text checks for known gaps, not a judgment of the role. | `cabinet role draft <role>` redrafts it under the current rules, keeping your brief and what you confirmed; or add the missing part to `roles/<role>.md` yourself. |
| `note project roles that may write another role's area: <...> (narrow the role's "What you may write", or change the team table)` | `roles.writes` | A role of the project's own lists, under "What you may write", a path the team table gives another role (the most specific row decides). `HANDOFFS.md` and `specs/evidence/` are shared and never count. | Narrow the role's "What you may write" to its own areas (redraft it, or edit `roles/<role>.md`), or give it the area in the team table if that is what you want. |
| `note roles/<...>.md is a whole role and the kit also has a <...> role: yours is used, not the kit's (rename yours, or remove its frontmatter to add notes to the kit's role)` | `roles.shadows` | A role file of yours with frontmatter has a kit role's name, for example one a later kit added. Yours is built as it is; the two are never mixed. | Keep it if that is what you want. To use the kit's role, rename yours (and its name in `CABINET_ROLES`), or turn yours into notes by removing its frontmatter. |
| `FIX <...> (run bin/role.sh build)` | `kit.roles` | A built role is missing or out of date (for example after editing `roles/` or `CABINET_ROLES`). | `bin/role.sh build`. |

## Push guardrails

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX git push gate not installed (run bin/bootstrap.sh)` | `guardrails.push-gate` | No pre-push hook in the global hooks path. | `bin/bootstrap.sh`. |
| `note repos' own git hooks (pre-commit and others) do not run under the global hooks path: run bin/bootstrap.sh` | `guardrails.hook-passthrough` | The pass-through stubs are missing. | `bin/bootstrap.sh`. |
| `FIX <...> sets its own core.hooksPath (<...>), which bypasses the push gate` | `guardrails.repo-hookspath` | A repo sets its own hooks path (husky does), so the global gate is skipped there. | Remove it (`git config --unset core.hooksPath`), or add the gate to that repo's hooks folder yourself. |
| `ok Cabinet runs are refused an amend or a rebase (the kit's hooks in <...>)` | `guardrails.run-refusal` | The global hooks folder holds the kit's `prepare-commit-msg` and `pre-rebase`, which refuse an amend and a rebase in a Cabinet run ([guardrails](guardrails.md#runs-never-rewrite)). | Nothing. |
| `note the run refusal is not installed: <...> in <...> is missing or not the kit's, so a Cabinet run is not refused that (run bin/bootstrap.sh; it leaves a hook of your own as it is: move yours into each repo's own .git/hooks first)` | `guardrails.run-refusal` | A hook of your own (or an edited copy) is in the global hooks folder, or bootstrap has not run since the kit added the refusal. | `bin/bootstrap.sh`; for a hook of your own, move it into each repo's `.git/hooks` first (the kit's hook runs it from there). |
| `FIX Claude Code is missing <...> deny rule(s) (run bin/bootstrap.sh)` | `guardrails.claude` | `~/.claude/settings.json` lacks some of the kit's rules. | `bin/bootstrap.sh`. If it says the file is not plain JSON, fix the file first. |
| `FIX Codex push rule missing (run bin/bootstrap.sh)` | `guardrails.codex` | Codex does not forbid `git push`. | `bin/bootstrap.sh`; if `~/.codex/rules/default.rules` already exists, add the kit's rules (`.cabinet/guardrails/codex-default.rules`) to it. |
| `FIX agy push deny rule missing (run bin/bootstrap.sh)` | `guardrails.agy` | Antigravity's settings lack the push rule. | `bin/bootstrap.sh`. |
| `FIX Gemini CLI policy missing (run bin/bootstrap.sh)` | `guardrails.gemini` | No `~/.gemini/policies/owner-control.toml`. | `bin/bootstrap.sh`. |
| `FIX Qwen Code is missing <...> deny rule(s) (run bin/bootstrap.sh)` | `guardrails.qwen` | `~/.qwen/settings.json` lacks some of the kit's rules. | `bin/bootstrap.sh`. |
| `FIX Cursor CLI is missing <...> deny rule(s) in ~/.cursor/cli-config.json (run bin/bootstrap.sh)` | `guardrails.cursor` | The Cursor CLI's config lacks some of the kit's rules. | `bin/bootstrap.sh`. |
| `note the Cursor editor keeps its agent's command rules in its own settings, which the kit does not set: only the git push gate applies there` | `guardrails.cursor-editor` | Information: the kit cannot set the editor's rules. | Set its command denylist in the Cursor editor's settings if you want more than the push gate. |
| `FIX Grok does not load the rules in ~/.claude/settings.json (check: grok inspect)` | `guardrails.grok` | Grok is not reading the Claude Code rules (its Claude compatibility may be off). | Turn it on in Grok, or add the rules to `~/.grok/config.toml` by hand. |
| `FIX opencode does not deny: <...> (run bin/bootstrap.sh; a rule in opencode.jsonc comes last and wins)` | `guardrails.opencode` | On opencode 1.x, the resolved rules do not end with the kit's denies. | `bin/bootstrap.sh`; if it still fails, remove the overriding rule from `opencode.jsonc`. |
| `note [<version> of ]opencode cannot be checked from here: confirm its permission settings by hand (the kit's rules are in ~/.config/opencode/opencode.json)` | `guardrails.opencode` | opencode 2.x has no command to print its resolved rules. The version leads the note when `opencode --version` prints one. | Check in opencode that it refuses `git push`. |
| `note <...> is installed and cabinet has no guardrails for it: only the git push gate above applies` | `guardrails.unguarded-tool` | An agent tool the kit does not cover. | Use it for reading and local edits, or add its own deny rules by hand. |
| `FIX scheduled jobs cannot find the runner '<...>' (install it, or fix CABINET_RUNNER / CABINET_RUNNER_CMD, then run bin/bootstrap.sh)` | `runner.found` | The runner is not on the PATH scheduled jobs get. | Install it, or fix the setting; then `bin/bootstrap.sh` from a shell where it is on your PATH, so the schedule gets its folder. |
| `FIX scheduled jobs find <...> but not node, which it needs (run bin/bootstrap.sh after installing node)` | `runner.node` | The runner is a Node script and Node is not on the scheduled PATH. | Install Node, then `bin/bootstrap.sh`. |
| `ok scheduled jobs find node` | `schedules.node` | Node is on the PATH scheduled jobs get, so the workspace scripts' JavaScript (`bin/lib.js`) runs in them. | Nothing. |
| `FIX scheduled jobs cannot find node, which the workspace scripts need (install Node.js, then run bin/bootstrap.sh)` | `schedules.node` | Node is not on the PATH scheduled jobs get (the PATH found when `bin/bootstrap.sh` last ran), so the brief, handoff and spec steps of a job would fail. | Install Node.js where your shell finds it, then `bin/bootstrap.sh` saves the new PATH into the schedules. |
| `note the custom runner '<...>' has no cabinet guardrails: only the git push gate covers its scheduled runs` | `runner.custom-unguarded` | A custom runner the kit does not know. | Add its own deny rules by hand. |
| `FIX the model '<...>' in <...> is not a model name (letters, digits and . _ : / @ -, up to 100, not starting with -), so no run starts with it: fix it, or cabinet config --model off` | `model.name` | `CABINET_MODEL` in `cabinet.env`, or `MODEL` in a job file, holds something other than a model name (a space, a quote, `$`, `;`, a leading `-`). Every run with it is refused before the agent tool starts. | `cabinet config --model <name>\|off`, or fix the `MODEL` line in the job file. |
| `ok <...> (<...>) is one of <...>'s models` | `model.exists` | The agent tool lists the model, without a run. | Nothing. |
| `FIX <...> in <...> is not in <...>'s model list (<...>): fix the name (<...>)` | `model.exists` | The tool lists its models for free and this name is not among them: a run with it would likely fail. | Correct the name, or turn it off. It stays a problem until the tool lists it. |
| `note not checked: <...> cannot list its models without a run (<...>)` | `model.exists` | Claude Code and Qwen Code have no free model list, and Cabinet never pays for a run to check one. | Nothing; a mistyped model shows as a failed run. |
| `note not checked: <...>'s model list could not be read (<...>), for <...>` | `model.exists` | The tool's list command failed (no network, not logged in). | Run the command it names yourself to see why. |
| `note not checked: the custom runner cannot list its models without a run (<...>)` | `model.exists` | A custom runner has no known model list. | Nothing. |
| `FIX the light model '<...>' in <...> is not a model name (letters, digits and . _ : / @ -, up to 100, not starting with -), so no run starts with it: fix it, or cabinet config --model-light off` | `model-light.name` | `CABINET_MODEL_LIGHT` holds something other than a model name. Runs of the roles in `CABINET_LIGHT_ROLES` are refused before the agent tool starts; other roles run as before. | `cabinet config --model-light <name>\|off`. |
| Each `model.exists` message, for the light model | `model-light.exists` | The same check as `model.exists`, for `CABINET_MODEL_LIGHT`. | As for `model.exists`, with `cabinet config --model-light <name>\|off`. |
| `note CABINET_LIGHT_ROLES names <...>, not on the team, so it changes nothing: to drop it, cabinet config --light-roles "<...>"` | `model-light.roles` | A role in the list is not on the team (removed, or never added). Never a problem: the list is kept for when it comes back. | The command it gives, or nothing. |
| `ok the light model runs for: <...>` | `model-light.roles` | Every role in the list is on the team. | Nothing. |

## Credit roles

| Message | ID | Cause | Fix |
|---|---|---|---|
| `ok credit roles: <...>` | `credit.setting` | The setting is `on` or `off` ([credit roles](concepts.md#credit-roles)). | Nothing. |
| `FIX CABINET_CREDIT_ROLES is "<...>", not off or on, so no commit is credited (cabinet config --credit-roles on, or off)` | `credit.setting` | `cabinet.env` (or this machine's `cabinet.local.env`) holds another value, often edited by hand. Only an exact `on` turns credit on. | `cabinet config --credit-roles off` or `on`. |
| `note credit roles: off, because the project's setting is <...>: this machine says on, which counts only while the project's setting is on (cabinet config --credit-roles on)` | `credit.setting` | A shared `cabinet/` whose committed setting is off or not set: off for everyone wins, so this machine's on credits nothing. | Nothing, or `cabinet config --credit-roles on` to turn it on for everyone. |
| `note this machine has not answered whether its Cabinet runs credit their roles, so they do not yet (cabinet config --this-machine --credit-roles on, or off)` | `credit.setting` | A shared `cabinet/` cloned on this machine: each machine answers for itself. | `cabinet config --this-machine --credit-roles off` or `on`. |
| `note credit roles not set, so no commit is credited until you answer (cabinet config --credit-roles on, or off)` | `credit.setting` | A workspace from before credit roles. | `cabinet config --credit-roles off` or `on`. |
| `ok credit names the app of <...>` | `credit.email` | `CABINET_CREDIT_EMAIL` names your own GitHub App. | Nothing. |
| `FIX CABINET_CREDIT_EMAIL is not a GitHub App's bot noreply email, so no commit is credited (cabinet config --credit-email <email>, or off)` | `credit.email` | The email is not `<user ID>+<app>[bot]@users.noreply.github.com` exactly, in lower case. | `cabinet config --credit-email <email>`, or `off` for the Cabinet Team app. |
| `ok credit installed: the credit hook is at <...>` | `credit.hook` | The global hooks folder holds the kit's credit hook. | Nothing. |
| `note credit not installed: git has no global hooks path (run bin/bootstrap.sh)` | `credit.hook` | Bootstrap has not run on this machine. | `bin/bootstrap.sh`. |
| `note credit not installed: the global hooks path is <...>, which bootstrap leaves as it is, and it holds no credit hook` | `credit.hook` | Your global `core.hooksPath` points to a folder of your own. | Keep it (no credit on this machine), or copy `.cabinet/guardrails/prepare-commit-msg` into that folder yourself. |
| `note credit not installed: no prepare-commit-msg in <...> (run bin/bootstrap.sh)` | `credit.hook` | The hook is missing. | `bin/bootstrap.sh`. |
| `note credit hook out of date: <...> is an earlier version of the kit's (run bin/bootstrap.sh, which replaces it)` | `credit.hook` | The kit's credit hook changed since bootstrap last ran on this machine. | `bin/bootstrap.sh`. |
| `note credit not installed: <...> is not the kit's credit hook, and bootstrap leaves it as it is (to credit roles, move your hook into each repo's own .git/hooks and remove it from <...>, then run bin/bootstrap.sh)` | `credit.hook` | A `prepare-commit-msg` of your own, or an edited copy of the kit's, is in the global hooks folder. Bootstrap never replaces it. | Keep it (no credit on this machine), or move it as the message says and run `bin/bootstrap.sh`. |

## Skills and plugins

| Message | ID | Cause | Fix |
|---|---|---|---|
| `note skill '<...>' not installed` | `skills.skill` | A skill in `CABINET_SKILLS` is not in `~/.claude/skills/`. | Install it, or remove it from `CABINET_SKILLS`. |
| `note plugin '<...>' not installed` | `skills.plugin` | A plugin in `CABINET_PLUGINS` is not installed in Claude Code. | Install it, or remove it from `CABINET_PLUGINS`. |

## Guides

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX guides/<...> has no row in the Guides table of AGENTS.md, so agents never read it` | `guides.listed` | A file was added to `guides/` without a row in the "Guides" table. | Add a row: `` `guides/<file>` ``, what it covers, who follows it. See [recipes](recipes.md#add-your-own-rules-guidelines-and-business-documents). |
| `FIX AGENTS.md lists <...>, which does not exist` | `guides.exists` | A row in the "Guides" table names a file that is not in `guides/`. | Restore the file, fix the path, or delete the row. |

## Manual and handoffs

| Message | ID | Cause | Fix |
|---|---|---|---|
| `note OPERATIONS.html is older than OPERATIONS.md, or missing (cabinet manual build; the brief rebuilds it each morning)` | `manual.page` | `OPERATIONS.md` changed since the page was built (agents update the manual whenever they change a script, job or role), or the page was never built. | `cabinet manual build`, or wait for the next brief. |
| `FIX OPERATIONS.md does not mention: <...>` | `manual.complete` | The manual has fallen behind a script (the kit's in `bin/`, or the project's own in `tools/`), a job or a role. | Add it to `OPERATIONS.md` (`cabinet config --roles` adds role rows for you). |
| `FIX these handoff IDs are used more than once: <...>(file the next free number)` | `handoffs.unique-ids` | Two entries share an ID. | Give the later one the next free number, or mark it with a `- Note: duplicate ID` line. |
| `FIX verdicts not in the format, or naming a note that does not exist: <...> (rewrite each as - Verdict: <role> <verdict> <YYYY-MM-DD> <commits> <note under specs/>, and commit its note)` | `handoffs.verdicts` | An open entry has a `- Verdict:` line in another shape (the verdict is `PASS`, `BLOCK` or `CHANGES`), or its note is not in the workspace. Each entry is named by its ID. | Have the reviewer commit the note and record the verdict again with `cabinet handoff record`, which writes the [verdict format](concepts.md#the-builder-never-verifies). |
| `note PASS, BLOCK or CHANGES written outside a Verdict line, so not counted: <...> (the reviewer records it with bin/handoff.sh record)` | `handoffs.unread-verdicts` | An open entry has a verdict written in prose, usually on its status line ("qa PASS"), which readiness never reads, so that work does not show as ready. Each entry is named by its ID. | Have the reviewer record it with `cabinet handoff record`, and set the status line back to a status. |
| `FIX handoffs marked small that were not: <...> (route the work again from a spec)` | `handoffs.small` | A handoff filed with `--small` has a PASS, but its commits span more than one repo, are in no repo on this machine, or change a path `AGENTS.md` guards (a contract's files, "Hard to undo"). Each is named with the reason. | Route the work again from a spec ([ready to build](concepts.md#ready-to-build)); the reviewer records BLOCK meanwhile. A commit in no repo here: clone or fetch that repo. |
| `FIX qa PASS on handoffs with no evidence: <...> (the builder adds an Evidence line, or qa changes its verdict to BLOCK)` | `handoffs.evidence` | qa passed work whose entry has no `- Evidence:` line, so you would approve it without seeing it. | The builder adds evidence with `cabinet handoff attach <ID> <file or URL> --from <builder>`, or qa records BLOCK. |

## Critical areas

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX critical areas in AGENTS.md that cannot hold: <...> (fix its row)` | `areas.declared` | A row under "Critical areas" names no paths, a path in a repo not in `repos.tsv` or that does not exist there, no reviewer or one not on the team, or a check that is not a command in `tools/` that can run. Work in that area waits on a reviewer who cannot come, or a check that cannot run. Each problem is named. | Fix the row in `AGENTS.md`: the paths, the reviewers (or turn the role on), or the check (put it in `tools/`, `chmod +x`). |

## Specs

| Message | ID | Cause | Fix |
|---|---|---|---|
| `note AGENTS.md lists no paths that are hard to undo, so a small task is checked only for staying in one repo (cabinet config --hard-to-undo "<repo>/<path> ...", or off when there are none; cabinet config suggests some)` | `agents.hard-to-undo` | The workspace has repos, and the "Hard to undo" section of `AGENTS.md` is missing or still says `none yet`. | `cabinet config` asks, with suggestions from the repos; or `cabinet config --hard-to-undo "api/migrations/"`, or `off` when nothing is. |
| `FIX specs not ready for their status: <...> (fix each, or set it back to draft; cabinet spec check)` | `specs.ready` | A spec marked `ready` or `building` lacks what that status needs: testable criteria with a qa PASS, no `TBD` in "Rules", every decision answered, its repos, and for `building` a plan (with an architect PASS for more than one repo). A PASS no longer counts when the part it reviewed changed. Each spec is named with its problems. | Fix what is named and ask for the review again, or set the spec's `status` back to `draft` (or `ready`) until it is. See [ready to build](concepts.md#ready-to-build). |

## Secrets

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX possible secrets in the workspace's files (remove each and rotate any real key; a false alarm: add not-a-secret to its line): <...>` | `secrets.none` | A line looks like a key, token or password (file and line are named; the value never is). | Remove it, and rotate the key if it was real: it may already be in git history and backups. A false alarm: add `not-a-secret` to its line. |
| `note commits are not checked for secrets: the workspace has no pre-commit hook running bin/secret.sh (run bin/bootstrap.sh; a hook of your own can call bin/secret.sh check --staged)` | `secrets.hook` | Bootstrap has not run, or the workspace has its own `pre-commit` hook. | `bin/bootstrap.sh`, or call `bin/secret.sh check --staged` from your hook. |

## Team

| Message | ID | Cause | Fix |
|---|---|---|---|
| `note parts of a repo owned by another role than the repo's: <...> (the most specific row wins; if that is not meant, change the team table)` | `team.nested` | The team table gives a path inside a product repo (`api/docs/`) to a different role than the repo's own row. That is allowed, since the most specific row wins, but it splits a repo, so it is your call. | Keep it if it is meant. Otherwise remove the inner row, or give it to the repo's owner. |
| `FIX sub-team roles that do not fit the team: <...> (fix the Team section of each in roles/<role>.md)` | `team.reports-to` | A role's "## Team" section names a lead who is not on the team, leads back to itself through others, or covers something that is no builder or repo. Each is named. | Fix `- Reports to:` or `- Covers:` in `roles/<role>.md`, or turn the lead on (`cabinet config --roles`). |
| `FIX more than one owner in the team table of AGENTS.md: <...> (give each one owner)` | `team.single-owner` | The same repo or area has rows with different owning agents, so two roles would act on it. Each is named with its owners. | Keep one row per repo or area. Work the other role does there goes to the owner as handoffs. |
| `note open handoffs addressed to no role or repo on the team: <...> (readdress or close them)` | `handoffs.addressee` | An open entry's `To:` names something that is not a role on the team, a repo in `repos.tsv`, or the owner: a role turned off, a repo removed, or a typo. Each is named with its ID. | Readdress it to whoever owns the work now (a follow-up entry), or close it with a reason. |

## Uncommitted work

| Message | ID | Cause | Fix |
|---|---|---|---|
| `note the workspace has no commits yet: backups hold its files only (set the owner with cabinet config, then commit)` | `work.no-commits` | Setup did not commit (no owner identity). | `cabinet config --owner "..." --email ...`, then commit the workspace. |
| `note <...> has <...> uncommitted file(s): work in progress, or finished and not committed?` | `work.uncommitted` | A repo has uncommitted changes. | Commit finished work; leave work in progress. |

## Schedules

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX jobs/<...>.job has a WHEN bootstrap cannot schedule ('<...>'): use a time like 7 AM for every day, or days and a time like fri 4 PM or sun,mon,tue,wed,thu 8 AM` | `schedules.when` | A mistyped time or day. Bootstrap keeps the working schedule meanwhile. The forms are in [commands](commands.md#schedule-times). | Fix `WHEN`, then `bin/bootstrap.sh`. |
| `FIX <...>.<...> not scheduled (run bin/bootstrap.sh)` | `schedules.job` | A job has a time but no schedule. | `bin/bootstrap.sh`. |
| `note jobs are not scheduled on this machine (CABINET_SCHEDULES=off in cabinet.local.env): another machine runs them; cabinet bootstrap --schedules turns them on` | `schedules.off` | This machine was set up with `cabinet bootstrap --no-schedules`, so the job checks are skipped here. | Nothing, when another machine runs the jobs. To run them here: `cabinet bootstrap --schedules`. |
| `FIX <...>.<...> runs another workspace: give this one its own slug (cabinet config --slug)` | `schedules.job-owner` | Two workspaces share a slug. | `cabinet config --slug <new>` in one of them. |
| `FIX <...>.<...> is written but not loaded by <...> (run bin/bootstrap.sh)` | `schedules.job-loaded` | The schedule file exists, but the scheduler (launchd, systemd or cron) has not loaded it. | `bin/bootstrap.sh`. |
| `FIX <...> still runs this workspace under an old name (<...>)` | `schedules.old-slug` | A schedule left over from an earlier slug. | Run what it names: on macOS `launchctl bootout gui/$(id -u)/<label>`, with systemd `systemctl --user disable --now <label>.timer`; then delete the file it names. |
| `FIX no scheduler on this machine (a running systemd user session, or cron), so no job runs on its own: install cron, then run bin/bootstrap.sh` | `schedules.scheduler` | Linux without a systemd user session or `crontab`, as in many containers. Jobs only run by hand. | Install cron (or run under systemd), then `bin/bootstrap.sh`. |

## Spend

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX the scheduled runner is on with no cost limit, so it runs nothing (cabinet config --pipeline-limit <dollars>)` | `pipeline.ready` | `CABINET_PIPELINE` is `small` or `all`, and `CABINET_PIPELINE_LIMIT` is empty. The same ID reports a value other than off, small or all, a runner whose cost cannot be counted, or a missing `jobs/pipeline.job`. | `cabinet config --pipeline-limit <dollars>`, `--price` for a token runner, or `--pipeline off`. |
| `FIX CABINET_PIPELINE is '<...>', not off, small or all (cabinet config --pipeline small, all or off)` | `pipeline.ready` | `cabinet.env` was edited by hand to a value the runner does not know, so it runs nothing. | `cabinet config --pipeline small`, `all` or `off`. |
| `FIX the scheduled runner is on, but <...>'s cost cannot be counted, so it runs nothing (cabinet config --price, or another runner)` | `pipeline.ready` | The runner reports no dollars (a token runner with no price, or `custom`), so a cost limit could not hold. | `cabinet config --price "<input> <output> [<cached input>]"`, or `--runner` claude, grok or opencode. |
| `FIX the scheduled runner is on, but jobs/pipeline.job is missing (cabinet config --pipeline <...> adds it)` | `pipeline.ready` | The job file was deleted, so nothing runs it on a schedule. | `cabinet config --pipeline small` (or `all`) makes it again; then `cabinet bootstrap`. |
| `FIX agent runs cost $<...> this week, <...>% of the $<...> budget: cabinet job list shows what each job cost; raise it with cabinet config --budget <dollars>` | `spend.budget` | The agent runs Cabinet started this week cost 80% or more of `CABINET_BUDGET`, as the agent tool reported it. See [what agent runs cost](concepts.md#what-agent-runs-cost). | `cabinet job list` shows which job cost what. Raise the budget (`cabinet config --budget <dollars>`), run jobs less often (`WHEN`, `QUIET_DAYS`), or let the week end. |
| `FIX agent runs cost $<...> this week, over the $<...> budget: cabinet job list shows what each job cost; raise it with cabinet config --budget <dollars>` | `spend.budget` | The week's runs passed the budget. Nothing is stopped. | The same. |
| `note <...> reports tokens, not dollars, so the $<...> budget is not tracked: set its price with cabinet config --price "<input> <output> [<cached input>]" (dollars per million tokens)` | `spend.unreported` | A budget is set, and the runner (codex, cursor, qwen or antigravity) reports only tokens. | `cabinet config --price "<input> <output> [<cached input>]"`, from the model's price list. See [what agent runs cost](concepts.md#what-agent-runs-cost). |
| `note <...> does not report what a run costs, so the $<...> budget is not tracked (the built-in runners report it)` | `spend.unreported` | A budget is set, and the runner is `custom`. | Use a built-in runner to track it, or remove the budget: `cabinet config --budget off`. |

## Backups

| Message | ID | Cause | Fix |
|---|---|---|---|
| `note backups are off on this machine (cabinet.local.env; cabinet config --this-machine --backup-dir <folder> turns them on)` | `backups.enabled` | This machine turned backups off for itself (`cabinet config --this-machine --backup-dir off`). | Nothing, when another machine backs up. To back up here: `cabinet config --this-machine --backup-dir <folder> --apply`. |
| `note backups are off (set CABINET_BACKUP_DIR in cabinet.env, then run bin/bootstrap.sh)` | `backups.enabled` | No backup folder set. | `cabinet config --backup-dir <folder>`, then `bin/bootstrap.sh`. See [backups](backups.md). |
| `FIX CABINET_BACKUP_DIR must be an absolute path` | `backups.dir-absolute` | A relative backup folder. | `cabinet config --backup-dir <absolute folder>`. |
| `FIX the backup folder is inside <...>: a backup there is lost with it and can be committed (choose a folder outside, then cabinet config)` | `backups.dir-outside` | The backup folder is inside the workspace or one of its repos. | Choose a folder outside them with `cabinet config --backup-dir`. |
| `FIX no scheduled backup in <...>/backup.log yet (<...>)` | `backups.recent` | No scheduled backup has run yet. | Run what it names (`launchctl kickstart` on macOS, `systemctl --user start` with systemd, `cabinet backup create` with cron), or wait for the time set. |
| `FIX newest backup is <...>h old (<...>): <...>` | `backups.recent` | No scheduled backup in the last 36 hours (the machine was asleep or the job failed). | Read `backup.log` in the log folder (`~/Library/Logs/cabinet/<slug>/` on macOS, `~/.local/state/cabinet/<slug>/` on Linux). |
| `note no restore of a backup has been verified on this machine yet (cabinet backup verify)` | `backups.verified` | `cabinet backup verify` has not passed on this machine. | `cabinet backup verify` ([backups](backups.md#checking-it)). |
| `note the last verified restore was <...> days ago (<...>): verify again (cabinet backup verify)` | `backups.verified` | The last good verify is more than 92 days old. | `cabinet backup verify`. |
| `FIX backup passphrase missing from the <...> (<...>: <...>)` | `backups.passphrase` | No item `cabinet.<slug>.backup` in the keychain (macOS) or the secret store (Linux), or with cron no passphrase file (a cron run cannot reach the secret store), and `CABINET_BACKUP_PASSPHRASE` is not set. | Run the command it names, with the same passphrase as in your password manager: `security add-generic-password -a "$USER" -s cabinet.<slug>.backup -w` on macOS, `secret-tool store --label=cabinet.<slug>.backup service cabinet.<slug>.backup account "$USER"` on Linux, and with cron a command that writes `~/.config/cabinet/passphrases/cabinet.<slug>.backup` readable by you only ([macOS and Linux](concepts.md#macos-and-linux)). |
| `FIX the passphrase file <...> can be read by other users, so it is not used: chmod 600 <...>` | `backups.passphrase` | The passphrase file exists, but its permissions let others read it, so backups ignore it. | `chmod 600` on the file, as the message says. |

## Other commands

- **`cabinet: not inside a cabinet workspace, or a project with cabinet/ in it`:** a workspace command (`doctor`, `bootstrap`, `brief`, ...) ran outside any workspace. `cd` into the workspace or its project, or start one with `cabinet new` or `cabinet init`.
- **`cabinet: unknown command '<...>'`:** exit 2. A mistyped command gets one short answer: `Did you mean: cabinet <...>` when a command is near, then `Every command: cabinet help`. An unknown verb after a noun (`cabinet role <...>`) shows that noun's commands, and `cabinet help <...>` adds `(see: cabinet help)`.
- **`Not safe to delete: <...>`:** from `cabinet remove`, when the workspace has uncommitted changes or commits on no remote. Commit and push (or copy) that work first; `--force` deletes it anyway.
- **`--fix asks before each step: run it in a terminal, or add --yes`:** `cabinet doctor --fix` had no terminal to ask in.
- **`cabinet: the slug '<...>' is already used by the workspace at <...>`:** choose another with `--slug`. When it says that workspace no longer exists, it lists the steps to free the slug.
- **`cabinet: <...> already has a cabinet workspace: use cabinet update`:** `init` runs once per folder.
- **`cabinet: <...> is inside the repo <...>: run cabinet init at its top folder`:** run it there.
- **`cabinet: these files already exist at paths the kit uses: <...>`:** rename or move those files, then run `cabinet init` again.
- **`<...>: the merge did not produce a valid file (its shape is not what the kit expects), left as is`:** from bootstrap. The file is unchanged; add the kit's rules by hand, or fix the file's shape.
- **An update stops with "edited here, left as is"** or **"already here and not the kit's":** move your change to a project file, restore the kit's file, then `cabinet update` again.
