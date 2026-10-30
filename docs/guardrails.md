# Guardrails

How Cabinet keeps every push, merge, release and publish with you, what each agent tool's rules can and cannot block, and how to undo them.

## The two layers

1. **The push gate.** A global git pre-push hook asks for `yes` at your terminal before a `git push` in Cabinet's repos, from any tool: each workspace on this machine and everything inside it (session worktrees too), every repo a workspace lists in `repos.tsv`, and the project around a `cabinet/` folder. Agents run without a terminal, so their pushes there are refused. In any other repo it asks nothing and runs that repo's own `pre-push`, if any. It reads the workspaces Cabinet records on this machine (in the log folder) at each push, so a repo added today counts at once; whenever it cannot tell (`node` not on the `PATH`, as under some GUI git clients, a workspace or its `repos.tsv` it cannot read, a recorded workspace that is gone, no recorded workspace still there, a bare repo), it asks. Bootstrap records each workspace, with or without a scheduler; a second workspace with a slug another one holds is recorded beside it, and the doctor reports a workspace no record names (`guardrails.claim`). It has no off switch of its own: no setting of the kit's makes it pass. The ways around any git hook, and which tools' rules catch them, are listed below.
2. **Deny rules in each agent tool.** They block push, merge, release and publish commands, and the known ways around the push gate (git can be told to skip hooks).

Together they are a strong speed bump, not a boundary. For a hard boundary, protect your branches on the server (GitHub branch protection), and use [a credential that needs you on every push](#a-hard-boundary).

## A hard boundary

The push gate and the deny rules guard against mistakes; a process set on getting round them could still push with your credentials. A credential that needs your confirmation each time it is used closes that: no push reaches the remote without you, even if every rule on this page were bypassed. Two kinds, both from the ssh tools' own documentation:

- **A key the ssh agent confirms on each use.** `ssh-add -c <key>` adds a key to the agent so that every use of it is confirmed first, in a dialog shown by an askpass program (`ssh-askpass`, or the program `SSH_ASKPASS` names where the agent starts). With no askpass program, every use of that key is refused. macOS ships none, so one must be installed and named in `SSH_ASKPASS`; on Linux it is a package of its own (`ssh-askpass` on Debian).
- **A hardware security key that needs a touch.** A key of an `-sk` type (`ssh-keygen -t ed25519-sk`, or `ecdsa-sk`) lives on a FIDO security key, and each use needs a touch on it. On Linux the system ssh supports it (`ssh -Q key` lists the `sk-` types). The ssh that comes with macOS lists the types but cannot reach a security key by itself (`ssh-keygen` says "No FIDO SecurityKeyProvider specified"): use an ssh built with security key support, or set `SecurityKeyProvider` to a provider library.

Its limits:

- It covers a push only while the remote is reached over ssh with that key, and no other stored credential reaches the same host. A token in a git credential helper (for an HTTPS remote), or another key in the agent or in `~/.ssh` that the host accepts, pushes without asking. `git remote -v` shows how each repo reaches its remote; `ssh-add -l` lists the keys the agent holds.
- It does not cover what goes through the GitHub login token (`gh`: merges, releases, repository settings). Branch protection and the deny rules cover those.

`cabinet bootstrap` points here once, at the end of its push gate section; it detects and changes nothing.

## What bootstrap installs

`bin/bootstrap.sh` installs the guardrails machine-wide, for every tool it finds. It is safe with several workspaces: rules are only ever added, never removed; a config file that is not plain JSON, whose shape is unexpected, or that holds a value a rewrite would change (a number written as `1.0` or `1e3`, one too large to keep exactly, or a key that is a whole number), is left exactly as it was, with a message; files are written in place, so their permissions and symlinks stay; and a backup copy `<file>.bak.<timestamp>` is made before any change. The push gate is replaced only where it is the kit's own earlier copy; a `pre-push` of yours there is left as it is, and then asks before every push in every repo, as the doctor says. An older copy of the Codex rules or the Gemini policy, missing rules a newer kit added, gets the missing rules at its end, after a comment line and a backup copy beside it; no line already there is removed or changed, a symlink stays a link (its target gets the rules), and the result is written only when it checks out: for Gemini, when it holds every kit rule; for Codex, when it defines no name twice and, with `codex` installed, `codex execpolicy check` still forbids `git push`. Otherwise, or when the backup cannot be written, the file is left as it is and bootstrap says why, with the lines to add by hand. Run `cabinet bootstrap` after each kit update.

| Tool | Reads `AGENTS.md` | Guardrails | Checked by `bin/doctor.sh` |
|---|---|---|---|
| Claude Code | through the `CLAUDE.md` link | `~/.claude/settings.json` `permissions.deny` / `ask` | yes |
| Grok | yes, in folders you trust | reads the Claude Code rules | yes, with `grok inspect` |
| Qwen Code | yes | `~/.qwen/settings.json`, the same rule list | yes |
| opencode | yes | `~/.config/opencode/opencode.json` `permission.bash`, placed last because its last matching rule wins. A commented `opencode.jsonc` is never rewritten; opencode reads it after the `.json`, so a rule there can still override | on opencode 1.x; on 2.x it cannot (its debug commands need a background service), so check by hand |
| Gemini CLI | bootstrap sets `context.fileName` in `~/.gemini/settings.json` | `~/.gemini/policies/owner-control.toml` | yes, every kit rule |
| Codex | yes | `~/.codex/rules/default.rules`; also `approval_policy = "on-request"` in `~/.codex/config.toml`, so Codex asks before anything its sandbox does not allow | yes, every kit rule, and `codex execpolicy check` |
| Antigravity CLI | yes | its `settings.json` | yes, every kit deny rule |
| Cursor CLI (`cursor-agent` / `agent`) | yes | `~/.cursor/cli-config.json` `permissions.deny` | yes (the file) |
| Cursor editor | yes | none: its agent's command rules live in the editor's own settings, which the kit does not change. The push gate applies | noted |
| Any other tool | point it at `AGENTS.md` | the push gate only | named, as a note |

Two more machine-wide settings come with the push gate:

- **`git config --global core.hooksPath ~/.config/git/hooks`**, where the gate lives, with its helper `cabinet-push-gate.js`, which finds Cabinet's repos. A global hooks path makes git skip every repo's own `.git/hooks`, so bootstrap also places a pass-through stub there for the other client hooks (pre-commit, commit-msg, post-checkout and the rest; not push-to-checkout or fsmonitor-watchman, which change git's behavior just by existing). A repo's own hooks, such as a secret scanner, keep running. `prepare-commit-msg` is the credit hook instead ([credit roles](concepts.md#credit-roles)): it runs the repo's own `prepare-commit-msg` in the same way, whose failure still stops the commit, then adds the role's line to a commit made in a Cabinet run. It also refuses an amend in a Cabinet run, and `pre-rebase` is the kit's too, refusing a rebase there ([runs never rewrite](#runs-never-rewrite)). Bootstrap places each where there is no hook, or where the stub or an earlier version of the same hook is, and never replaces a hook of yours; `--no-verify` does not skip `prepare-commit-msg`. A Cabinet repo where git uses another hooks folder skips the gate: its own `core.hooksPath` (husky sets one), set in the repo, a worktree, a file its config includes, or the system config. The doctor reads the value git really uses in the workspace, each repo it lists and each session worktree, and names the folder, the value and the file that sets it; it never reads other repos.
- **The workspace's secrets check,** a `pre-commit` hook in the workspace's own `.git/hooks` (bootstrap runs it through the pass-through stub). It runs `bin/secret.sh check --staged` and refuses a commit that adds a likely key, token or password, naming the file and line, never the value. A false alarm passes once its line has `not-a-secret` on it. An existing `pre-commit` hook is left as it is (the doctor notes it; your hook can call `bin/secret.sh check --staged` itself). A shared `cabinet/` inside a project gets none, since the project's own hooks run there; `bin/doctor.sh` still scans its files. It is a safety net, not a guarantee: it knows common key formats, not every secret.
- **Gemini CLI's `context.fileName`** is set to read `AGENTS.md` everywhere, so Gemini also loads `AGENTS.md` in folders that are not Cabinet workspaces.

## What each tool's rules block

The rule formats differ, so the coverage does too.

**Claude Code, Grok, Qwen Code, opencode** (one rule list, matched anywhere in a command, so also inside wrappers such as `env`, `bash -c` or `nohup`):

- push, `git send-pack` (which pushes without hooks), merge, release, `gh api` writes, publishing (npm, npx, bun, pnpm, yarn, also with options before `publish`);
- the ways around the gate: `-c core.hooksPath` in common spellings, `GIT_CONFIG_*` variables, `env -i` and `env -u`, a push behind a `HOME=` override (caught because `git push` is matched anywhere), `--no-verify` and its abbreviations, faking a terminal (`script`, `expect`, `unbuffer`, Python's `pty.spawn`);
- printing the GitHub token, and reading the keychain, the Linux secret store (`secret-tool lookup` and `search`) or the backup passphrase file (any command naming `cabinet/passphrases`).

Side effects: some harmless commands are refused too, such as an npm script named like `publish-docs`, or any command that mentions `git push` (for example in an `echo`).

**Gemini CLI** (regular expressions): the same list, with the hooks path matched in any letter case and `git push` matched anywhere in a command.

**Cursor CLI** (the command's first word plus an arguments pattern): push, `send-pack`, hook-path and `--no-verify` arguments to git, the terminal fakers, merges, releases, `gh api` writes, publishing, the GitHub token and the keychain. Probed live on Cursor CLI 2026.10.16 with harmless stand-ins:

- argument patterns match at the start and in the middle; first-word rules match;
- chained commands (`a && b`) are checked;
- a leading variable (`HOME=... git push`) is dropped before matching, so the git rules still catch it;
- wrappers are not looked through, so the kit denies `env`, `bash -c`, `sh -c`, `zsh -c`, `nohup`, `xargs`, `sudo`, `exec`, `command`, `nice` and `stdbuf` outright, and `timeout` or `time` with push, publish or `send-pack`. Any other wrapper is not caught.

**Codex and Antigravity** (rules match only how a command starts): push, `send-pack`, `env -i` and `env -u`, merge, release, publish and the terminal fakers are denied; `git -c ...` and `gh api` ask first. A bypass that does not start the command, such as `HOME=... git push` or `--no-verify` after other words, is not caught; nor is a push with `PATH=` pointing at a fake `node`, `NODE_OPTIONS=--require <file>`, or, on Linux, `XDG_STATE_HOME=` pointing at a made-up log folder, each of which can make the gate's helper say a repo is not Cabinet's. Tools that match `git push` anywhere in a command catch all of these.

**Not caught by any tool's rules:** git config keys in unusual letter case (except in Gemini), an agent editing `.git/config` with its file tools (the doctor reports a repo's own `core.hooksPath` afterwards), an agent removing a repo's row from `repos.tsv` or deleting a workspace's record in the log folder, which takes that repo out of the gate (the workspace's git history shows a `repos.tsv` change; the doctor's `guardrails.claim` shows a missing record), and other ways of faking a terminal.

## Runs never rewrite

An agent may run a rebase, a local merge or another git action that can be undone only when you ask for it in its session, except an amend of its own newest commit before it is pushed or named in a handoff or verdict ([git actions](concepts.md#git-actions)). In a Cabinet run (a scheduled job, `cabinet handoff run`, `cabinet spec run` or the pipeline, where `CABINET_AGENT` is set) no one is there to ask, so two of the kit's global hooks refuse them:

- **`prepare-commit-msg`** (the credit hook) refuses `git commit --amend`, in every form: with `-m` or `-F` git calls the hook as it does for a new commit, so the hook also reads the git command's own arguments for `--amend` (or an abbreviation of it). `git commit -c` and `-C` are refused in a run too, since git calls the hook the same way for them. `--no-verify` does not skip this hook.
- **`pre-rebase`** refuses `git rebase` (and `git pull --rebase`).

Each runs the repo's own hook of the same name first, with the same arguments, and its failure still stops the commit or rebase. Outside a run, in your terminal or an interactive session, they change nothing. `cabinet doctor` says whether both are installed (`guardrails.run-refusal`); a hook of your own in the global hooks folder is left as it is, and then runs are not refused on that machine.

### An agent's own amend

Outside a run, an agent amends its own newest commit as `CABINET_AMEND_AS=<role> git commit --amend`. The credit hook then refuses the amend unless the newest commit's message holds exactly one Cabinet credit line, as its last line, naming that role: so an agent that skipped its check cannot rewrite another role's commit, or yours, that landed after its own. The refusal gives the reason (`HEAD is <role>'s commit`, `HEAD has no Cabinet credit line at the end`, `HEAD has more than one Cabinet credit line` or `CABINET_AMEND_AS is not a role name`) and says to commit the fix as a new commit. An allowed amend keeps the role's line, also with a new `-m` or `-F` message, unless you delete it in the editor. A new commit made with `-c` or `-C <commit>` is checked as an amend too. A commit with no credit line (credit roles off, or made where none is added) cannot be amended this way: the fix is a new commit. With `CABINET_AMEND_AS` unset, as in your own terminal, nothing is checked; in a run, every amend is refused as before.

Limits: `git rebase --no-verify` skips `pre-rebase`. In a run it is refused only by the tools whose deny rules match `--no-v`: Claude Code, Grok, Qwen Code, opencode, Cursor CLI and Gemini CLI. Codex and Antigravity are not covered (their rules match only how a command starts; both ask before any `git rebase`, which a run cannot answer), nor are the Cursor editor and a custom runner. An amend through a git alias of your own (`git config alias.fix "commit --amend"`) is not seen. On macOS a new commit whose `-m` message mentions `--amend` is refused too in a run, and checked as an amend with `CABINET_AMEND_AS` set, since `ps` joins the arguments with spaces; give that message with `-F <file>` (on Linux each argument is read on its own, so it commits). A run can turn both refusals off by setting `CABINET_AGENT` empty (`CABINET_AGENT= git commit --amend`), which no tool's deny rules catch, and an agent outside a run can leave `CABINET_AMEND_AS` unset: the hooks guard against a mistake, not an agent set on getting round them. Git has no hook for `reset` or `stash`, so those stay rules for the agents.

## Known limits

These are on the [roadmap](../ROADMAP.md):

- archives are encrypted with AES-256-CBC and no separate integrity check, so tampering shows only as an unreadable archive;
- any process of your user can read the backup passphrase from the keychain or secret store without a prompt (the deny rules stop agents in the tools above);
- the backup passphrase file, used where cron runs the schedules, is denied only to shell commands that name its folder, in Claude Code, Grok, Qwen Code, opencode and Gemini CLI: a tool's own file reader, a command that reaches it another way, and the other tools can still read it;
- opencode agent-level and project-level configs, and Qwen workspace settings, can loosen the global rules, and the doctor checks only the global result;
- on opencode 2.x the doctor cannot read the resolved rules.

## Undoing the guardrails

The guardrails are shared by every workspace on the machine, so removing a workspace leaves them. To remove them:

- **Rules in a tool's settings:** restore the `.bak.<timestamp>` copy bootstrap made next to the file, or delete the rules you no longer want (the kit's list is in each workspace's `.cabinet/guardrails/`).
- **The push gate, its helper, the hook stubs, the credit hook and `pre-rebase`:** `git config --global --unset core.hooksPath`, then delete `~/.config/git/hooks/`.
- **Codex:** remove `approval_policy` from `~/.codex/config.toml` and the kit's rules from `~/.codex/rules/default.rules` (rules bootstrap added later follow the line `# Added by cabinet bootstrap: rules from a newer Cabinet kit`).
- **Gemini:** delete `~/.gemini/policies/owner-control.toml` and remove `context.fileName` from `~/.gemini/settings.json`.
