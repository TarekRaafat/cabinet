# Guardrails

How Cabinet keeps every push, merge, release and publish with you, what each agent tool's rules can and cannot block, and how to undo them.

## The two layers

1. **The push gate.** A global git pre-push hook asks for `yes` at your terminal for every `git push`, from any tool. Agents run without a terminal, so their pushes are refused.
2. **Deny rules in each agent tool.** They block push, merge, release and publish commands, and the known ways around the push gate (git can be told to skip hooks).

Together they are a strong speed bump, not a boundary. For a hard boundary, protect your branches on the server (GitHub branch protection).

## What bootstrap installs

`bin/bootstrap.sh` installs the guardrails machine-wide, for every tool it finds. It is safe with several workspaces: rules are only ever added, never removed; a config file that is not plain JSON, whose shape is unexpected, or that holds a value a rewrite would change (a number written as `1.0` or `1e3`, one too large to keep exactly, or a key that is a whole number), is left exactly as it was, with a message; files are written in place, so their permissions and symlinks stay; and a backup copy `<file>.bak.<timestamp>` is made before any change. A file that already exists (the push gate, the Codex rules, the Gemini policy) is left as it is and checked, never replaced.

| Tool | Reads `AGENTS.md` | Guardrails | Checked by `bin/doctor.sh` |
|---|---|---|---|
| Claude Code | through the `CLAUDE.md` link | `~/.claude/settings.json` `permissions.deny` / `ask` | yes |
| Grok | yes, in folders you trust | reads the Claude Code rules | yes, with `grok inspect` |
| Qwen Code | yes | `~/.qwen/settings.json`, the same rule list | yes |
| opencode | yes | `~/.config/opencode/opencode.json` `permission.bash`, placed last because its last matching rule wins. A commented `opencode.jsonc` is never rewritten; opencode reads it after the `.json`, so a rule there can still override | on opencode 1.x; on 2.x it cannot (its debug commands need a background service), so check by hand |
| Gemini CLI | bootstrap sets `context.fileName` in `~/.gemini/settings.json` | `~/.gemini/policies/owner-control.toml` | yes |
| Codex | yes | `~/.codex/rules/default.rules`; also `approval_policy = "on-request"` in `~/.codex/config.toml`, so Codex asks before anything its sandbox does not allow | yes |
| Antigravity CLI | yes | its `settings.json` | yes |
| Cursor CLI (`cursor-agent` / `agent`) | yes | `~/.cursor/cli-config.json` `permissions.deny` | yes (the file) |
| Cursor editor | yes | none: its agent's command rules live in the editor's own settings, which the kit does not change. The push gate applies | noted |
| Any other tool | point it at `AGENTS.md` | the push gate only | named, as a note |

Two more machine-wide settings come with the push gate:

- **`git config --global core.hooksPath ~/.config/git/hooks`**, where the gate lives. A global hooks path makes git skip every repo's own `.git/hooks`, so bootstrap also places a pass-through stub there for the other client hooks (pre-commit, commit-msg, post-checkout and the rest; not push-to-checkout or fsmonitor-watchman, which change git's behavior just by existing). A repo's own hooks, such as a secret scanner, keep running. A repo that sets its own `core.hooksPath` (husky does) bypasses the gate; the doctor names it.
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

**Codex and Antigravity** (rules match only how a command starts): push, `send-pack`, `env -i` and `env -u`, merge, release, publish and the terminal fakers are denied; `git -c ...` and `gh api` ask first. A bypass that does not start the command, such as `HOME=... git push` or `--no-verify` after other words, is not caught.

**Not caught by any tool's rules:** git config keys in unusual letter case (except in Gemini), an agent editing `.git/config` with its file tools (the doctor reports a repo's own `core.hooksPath` afterwards), and other ways of faking a terminal.

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
- **The push gate and hook stubs:** `git config --global --unset core.hooksPath`, then delete `~/.config/git/hooks/`.
- **Codex:** remove `approval_policy` from `~/.codex/config.toml` and the kit's rules from `~/.codex/rules/default.rules`.
- **Gemini:** delete `~/.gemini/policies/owner-control.toml` and remove `context.fileName` from `~/.gemini/settings.json`.
