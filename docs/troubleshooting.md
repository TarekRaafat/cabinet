# Troubleshooting

Every message `bin/doctor.sh` can print, what it means and how to fix it. `FIX` lines make the doctor exit 1; `note` lines are information. `<...>` stands for a name, path or number the doctor fills in. Run the doctor again after a fix. The ID names the check: `cabinet doctor --json` gives it with each result, and it stays the same when a message is reworded, so scripts and agents match on the ID, never on the text.

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
| `repos.tsv: skipped the row named "<...>" (not a plain folder name)` | - | A row's name has spaces or other characters. | Rename it to letters, digits, `.`, `_` or `-`. |

## Kit and roles

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX kit files edited here (an update will refuse them; move the change to a project file or into the kit): <...>` | `kit.unedited` | A file the kit owns (`CABINET.md`, `bin/`, `.cabinet/`) was changed in the workspace. | Move your change to a project file (`AGENTS.md`, `roles/`, `jobs/`), then `git checkout -- <file>`. |
| `FIX workspace CLAUDE.md link missing (run bin/bootstrap.sh)` | `kit.claude-link` | The workspace's `CLAUDE.md` link to `AGENTS.md` is gone. | `bin/bootstrap.sh`. |
| `FIX HANDOFFS.md missing` | `kit.handoffs-file` | The handoff log was deleted. | Restore it from git. |
| `note the <...> role is not drafted yet (cabinet role draft <...>, or ask your agent to draft the <...> role)` | `roles.drafted` | `cabinet role add` made the role from your brief, and no agent has drafted it yet. Until then it does only what the brief asks. | `cabinet role draft <role>`, or ask your agent to draft it ([recipes](recipes.md#add-a-role)). |
| `note roles/<...>.md is a whole role and the kit also has a <...> role: yours is used, not the kit's (rename yours, or remove its frontmatter to add notes to the kit's role)` | `roles.shadows` | A role file of yours with frontmatter has a kit role's name, for example one a later kit added. Yours is built as it is; the two are never mixed. | Keep it if that is what you want. To use the kit's role, rename yours (and its name in `CABINET_ROLES`), or turn yours into notes by removing its frontmatter. |
| `FIX <...> (run bin/role.sh build)` | `kit.roles` | A built role is missing or out of date (for example after editing `roles/` or `CABINET_ROLES`). | `bin/role.sh build`. |

## Push guardrails

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX git push gate not installed (run bin/bootstrap.sh)` | `guardrails.push-gate` | No pre-push hook in the global hooks path. | `bin/bootstrap.sh`. |
| `note repos' own git hooks (pre-commit and others) do not run under the global hooks path: run bin/bootstrap.sh` | `guardrails.hook-passthrough` | The pass-through stubs are missing. | `bin/bootstrap.sh`. |
| `FIX <...> sets its own core.hooksPath (<...>), which bypasses the push gate` | `guardrails.repo-hookspath` | A repo sets its own hooks path (husky does), so the global gate is skipped there. | Remove it (`git config --unset core.hooksPath`), or add the gate to that repo's hooks folder yourself. |
| `FIX Claude Code is missing <...> deny rule(s) (run bin/bootstrap.sh)` | `guardrails.claude` | `~/.claude/settings.json` lacks some of the kit's rules. | `bin/bootstrap.sh`. If it says the file is not plain JSON, fix the file first. |
| `FIX Codex push rule missing (run bin/bootstrap.sh)` | `guardrails.codex` | Codex does not forbid `git push`. | `bin/bootstrap.sh`; if `~/.codex/rules/default.rules` already exists, add the kit's rules (`.cabinet/guardrails/codex-default.rules`) to it. |
| `FIX agy push deny rule missing (run bin/bootstrap.sh)` | `guardrails.agy` | Antigravity's settings lack the push rule. | `bin/bootstrap.sh`. |
| `FIX Gemini CLI policy missing (run bin/bootstrap.sh)` | `guardrails.gemini` | No `~/.gemini/policies/owner-control.toml`. | `bin/bootstrap.sh`. |
| `FIX Qwen Code is missing <...> deny rule(s) (run bin/bootstrap.sh)` | `guardrails.qwen` | `~/.qwen/settings.json` lacks some of the kit's rules. | `bin/bootstrap.sh`. |
| `FIX Cursor CLI is missing <...> deny rule(s) in ~/.cursor/cli-config.json (run bin/bootstrap.sh)` | `guardrails.cursor` | The Cursor CLI's config lacks some of the kit's rules. | `bin/bootstrap.sh`. |
| `note the Cursor editor keeps its agent's command rules in its own settings, which the kit does not set: only the git push gate applies there` | `guardrails.cursor-editor` | Information: the kit cannot set the editor's rules. | Set its command denylist in the Cursor editor's settings if you want more than the push gate. |
| `FIX Grok does not load the rules in ~/.claude/settings.json (check: grok inspect)` | `guardrails.grok` | Grok is not reading the Claude Code rules (its Claude compatibility may be off). | Turn it on in Grok, or add the rules to `~/.grok/config.toml` by hand. |
| `FIX opencode does not deny: <...> (run bin/bootstrap.sh; a rule in opencode.jsonc comes last and wins)` | `guardrails.opencode` | On opencode 1.x, the resolved rules do not end with the kit's denies. | `bin/bootstrap.sh`; if it still fails, remove the overriding rule from `opencode.jsonc`. |
| `note <...> of opencode cannot be checked from here: confirm its permission settings by hand (the kit's rules are in ~/.config/opencode/opencode.json)` | `guardrails.opencode` | opencode 2.x has no command to print its resolved rules. | Check in opencode that it refuses `git push`. |
| `note <...> is installed and cabinet has no guardrails for it: only the git push gate above applies` | `guardrails.unguarded-tool` | An agent tool the kit does not cover. | Use it for reading and local edits, or add its own deny rules by hand. |
| `FIX scheduled jobs cannot find the runner '<...>' (install it, or fix CABINET_RUNNER / CABINET_RUNNER_CMD, then run bin/bootstrap.sh)` | `runner.found` | The runner is not on the PATH scheduled jobs get. | Install it, or fix the setting; then `bin/bootstrap.sh` from a shell where it is on your PATH, so the schedule gets its folder. |
| `FIX scheduled jobs find <...> but not node, which it needs (run bin/bootstrap.sh after installing node)` | `runner.node` | The runner is a Node script and Node is not on the scheduled PATH. | Install Node, then `bin/bootstrap.sh`. |
| `note the custom runner '<...>' has no cabinet guardrails: only the git push gate covers its scheduled runs` | `runner.custom-unguarded` | A custom runner the kit does not know. | Add its own deny rules by hand. |

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
| `FIX OPERATIONS.md does not mention: <...>` | `manual.complete` | The manual has fallen behind a script, job or role. | Add it to `OPERATIONS.md` (`cabinet config --roles` adds role rows for you). |
| `FIX these handoff IDs are used more than once: <...>(file the next free number)` | `handoffs.unique-ids` | Two entries share an ID. | Give the later one the next free number, or mark it with a `- Note: duplicate ID` line. |

## Secrets

| Message | ID | Cause | Fix |
|---|---|---|---|
| `FIX possible secrets in the workspace's files (remove each and rotate any real key; a false alarm: add not-a-secret to its line): <...>` | `secrets.none` | A line looks like a key, token or password (file and line are named; the value never is). | Remove it, and rotate the key if it was real: it may already be in git history and backups. A false alarm: add `not-a-secret` to its line. |
| `note commits are not checked for secrets: the workspace has no pre-commit hook running bin/secret.sh (run bin/bootstrap.sh; a hook of your own can call bin/secret.sh check --staged)` | `secrets.hook` | Bootstrap has not run, or the workspace has its own `pre-commit` hook. | `bin/bootstrap.sh`, or call `bin/secret.sh check --staged` from your hook. |

## Team

| Message | ID | Cause | Fix |
|---|---|---|---|
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
| `note jobs are not scheduled on this Mac (CABINET_SCHEDULES=off in cabinet.local.env): another Mac runs them; cabinet bootstrap --schedules turns them on` | `schedules.off` | This Mac was set up with `cabinet bootstrap --no-schedules`, so the job checks are skipped here. | Nothing, when another Mac runs the jobs. To run them here: `cabinet bootstrap --schedules`. |
| `FIX <...>.<...> runs another workspace: give this one its own slug (cabinet config --slug)` | `schedules.job-owner` | Two workspaces share a slug. | `cabinet config --slug <new>` in one of them. |
| `FIX <...>.<...> is written but not loaded by <...> (run bin/bootstrap.sh)` | `schedules.job-loaded` | The schedule file exists, but the scheduler (launchd, systemd or cron) has not loaded it. | `bin/bootstrap.sh`. |
| `FIX <...> still runs this workspace under an old name (<...>)` | `schedules.old-slug` | A schedule left over from an earlier slug. | Run what it names: on macOS `launchctl bootout gui/$(id -u)/<label>`, with systemd `systemctl --user disable --now <label>.timer`; then delete the file it names. |
| `FIX no scheduler on this machine (a running systemd user session, or cron), so no job runs on its own: install cron, then run bin/bootstrap.sh` | `schedules.scheduler` | Linux without a systemd user session or `crontab`, as in many containers. Jobs only run by hand. | Install cron (or run under systemd), then `bin/bootstrap.sh`. |

## Backups

| Message | ID | Cause | Fix |
|---|---|---|---|
| `note backups are off on this Mac (cabinet.local.env; cabinet config --this-mac --backup-dir <folder> turns them on)` | `backups.enabled` | This Mac turned backups off for itself (`cabinet config --this-mac --backup-dir off`). | Nothing, when another Mac backs up. To back up here: `cabinet config --this-mac --backup-dir <folder> --apply`. |
| `note backups are off (set CABINET_BACKUP_DIR in cabinet.env, then run bin/bootstrap.sh)` | `backups.enabled` | No backup folder set. | `cabinet config --backup-dir <folder>`, then `bin/bootstrap.sh`. See [backups](backups.md). |
| `FIX CABINET_BACKUP_DIR must be an absolute path` | `backups.dir-absolute` | A relative backup folder. | `cabinet config --backup-dir <absolute folder>`. |
| `FIX the backup folder is inside <...>: a backup there is lost with it and can be committed (choose a folder outside, then cabinet config)` | `backups.dir-outside` | The backup folder is inside the workspace or one of its repos. | Choose a folder outside them with `cabinet config --backup-dir`. |
| `FIX no scheduled backup in <...>/backup.log yet (<...>)` | `backups.recent` | No scheduled backup has run yet. | Run what it names (`launchctl kickstart` on macOS, `systemctl --user start` with systemd, `cabinet backup create` with cron), or wait for the time set. |
| `FIX newest backup is <...>h old (<...>): <...>` | `backups.recent` | No scheduled backup in the last 36 hours (the Mac was asleep or the job failed). | Read `~/Library/Logs/cabinet/<slug>/backup.log`. |
| `note no restore of a backup has been verified on this Mac yet (cabinet backup verify)` | `backups.verified` | `cabinet backup verify` has not passed on this Mac. | `cabinet backup verify` ([backups](backups.md#checking-it)). |
| `note the last verified restore was <...> days ago (<...>): verify again (cabinet backup verify)` | `backups.verified` | The last good verify is more than 92 days old. | `cabinet backup verify`. |
| `FIX backup passphrase missing from the <...> (<...>: <...>)` | `backups.passphrase` | No item `cabinet.<slug>.backup` in the keychain (macOS) or the secret store (Linux), and `CABINET_BACKUP_PASSPHRASE` is not set. | Run the command it names, with the same passphrase as in your password manager: `security add-generic-password -a "$USER" -s cabinet.<slug>.backup -w` on macOS, `secret-tool store --label=cabinet.<slug>.backup service cabinet.<slug>.backup account "$USER"` on Linux. |

## Other commands

- **`cabinet: not inside a cabinet workspace, or a project with cabinet/ in it`:** a workspace command (`doctor`, `bootstrap`, `brief`, ...) ran outside any workspace. `cd` into the workspace or its project, or start one with `cabinet new` or `cabinet init`.
- **`cabinet: unknown command '<...>'`:** exit 2, with the list of commands.
- **`Not safe to delete: <...>`:** from `cabinet remove`, when the workspace has uncommitted changes or commits on no remote. Commit and push (or copy) that work first; `--force` deletes it anyway.
- **`--fix asks before each step: run it in a terminal, or add --yes`:** `cabinet doctor --fix` had no terminal to ask in.
- **`cabinet: the slug '<...>' is already used by the workspace at <...>`:** choose another with `--slug`. When it says that workspace no longer exists, it lists the steps to free the slug.
- **`cabinet: <...> already has a cabinet workspace: use cabinet update`:** `init` runs once per folder.
- **`cabinet: <...> is inside the repo <...>: run cabinet init at its top folder`:** run it there.
- **`cabinet: these files already exist at paths the kit uses: <...>`:** rename or move those files, then run `cabinet init` again.
- **`<...>: the merge did not produce a valid file (its shape is not what the kit expects), left as is`:** from bootstrap. The file is unchanged; add the kit's rules by hand, or fix the file's shape.
- **An update stops with "edited here, left as is"** or **"already here and not the kit's":** move your change to a project file, restore the kit's file, then `cabinet update` again.
