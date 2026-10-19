# Backups

An encrypted daily archive of everything a lost machine would take with it, and a restore that never loses a file.

## What a backup holds

`cabinet backup create` (`bin/backup.sh create`, which the schedule runs) writes one archive with, for the workspace and every repo in `repos.tsv`:

- the full git history: every branch and unpushed commit;
- uncommitted changes, untracked files and stashes;
- `.env` files (git ignores them, so nothing else keeps them);
- the branch it was on, or that HEAD was detached.

It also includes Claude Code's memory for the workspace and `~/.claude/settings.json`. A repo with no commits yet (for example a workspace made without an owner identity) is kept as its files.

Archives are named `<slug>-<YYYYMMDD>-<HHMMSS>.tar.gz.enc`, encrypted with AES-256-CBC (PBKDF2, 200000 iterations), readable only by you (mode 600). The newest `CABINET_BACKUP_KEEP` (default 14) of this workspace's archives are kept; another workspace's archives in the same folder are never touched.

## Setting it up

1. Choose a folder **outside** the workspace and every repo it lists: a synced drive or an external disk. Setup, `cabinet config` and the backup itself refuse a folder inside them, because a backup there is lost with what it protects, copies itself into every later archive, and can be committed.
2. Set it with `cabinet config --backup-dir <folder>` (and `--backup-time "<time>"`, default 1:00 PM), then `bin/bootstrap.sh` to schedule it.
3. Put the passphrase in the keychain (macOS), the secret store (Linux) or, where cron runs the schedules, a file only you can read, and keep the same one in your password manager: without it no archive opens. `bin/bootstrap.sh` prints the command for your system; on Linux without a desktop session see [macOS and Linux](concepts.md#macos-and-linux).

```sh
security add-generic-password -a "$USER" -s cabinet.<slug>.backup -w
```

Or set `CABINET_BACKUP_PASSPHRASE` in the environment. Never put it in `cabinet.env`, which git tracks.

## Restoring

```sh
bin/backup.sh restore <archive> [folder]     # folder: where the workspace goes (default: this workspace)
bin/bootstrap.sh                      # then guardrails, links and schedules
bin/doctor.sh
```

On a new machine, put the passphrase in the keychain or secret store first, then run `backup.sh restore` from a copy of the kit (or a clone of the workspace's repo). Restore never loses a file:

- **A repo that already exists** gets the archive's branches under `refs/remotes/backup/*`, to compare and merge by hand. Its patches are copied to `recovered/`.
- **A missing repo, or an empty folder,** is restored with its uncommitted work, on the branch it was on (or detached, as it was).
- **The workspace folder itself, or a project folder holding nothing but the workspace being restored** (the inside layout), is checked out in place. Any file the archive would replace with different content, tracked or untracked, is first copied to `recovered/<archive>/`.
- **Any other folder that already holds files of its own** is left alone, and the repo is restored into `recovered/<archive>/<name>/repo` instead. A folder such as your home folder is never turned into a repo.
- `.env` files are restored only where missing. Stashes are kept as patches in `recovered/`.
- Claude Code memory and settings are restored only where missing.

Inside a project with the private layout, the pointer files (`CLAUDE.local.md` and the others) are ignored by the project's git and so not in the archive: `bin/role.sh build`, run by bootstrap, rebuilds them.

## Checking it

`bin/doctor.sh` reports the newest scheduled backup's age (from `backup.log` in the log folder, never by listing the backup folder, which can trigger a macOS access prompt), whether the passphrase is in the keychain or secret store (or in `CABINET_BACKUP_PASSPHRASE`), and a backup folder in the wrong place. Once a quarter, check that the newest archive really restores:

```sh
cabinet backup verify      # or bin/backup.sh verify [folder]
```

It restores the newest archive of this workspace into a temporary folder, as `backup.sh restore` would, and deletes that copy when it is done (it holds your secrets). For the workspace and each repo it prints one line: restores exactly as it is now, restores with so many files or commits changed since the backup (work done after it), or a problem. A problem is an archive that does not open (a wrong passphrase, or a damaged file), a history that does not rebuild, uncommitted changes that do not apply, files that do not unpack, or a repo that is not in the archive. Any problem makes it exit 1: back up again, then verify that archive. It never touches the workspace, its repos or your settings, and does not check Claude Code's memory or settings. A good result is recorded in `~/Library/Logs/cabinet/<slug>/backup-verified`, and `bin/doctor.sh` notes when none is recorded or the last is older than 92 days.
