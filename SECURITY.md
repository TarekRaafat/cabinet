# Security

## Report a vulnerability

Report it privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Please do not open a public issue, discussion or pull request for a security problem.

Include what you found, the steps to reproduce it, the Cabinet version (`cabinet version`), your operating system and the agent tool involved. The maintainer aims to reply within 3 days, works on a fix with you, and credits you in the advisory unless you would rather not be named.

## Supported versions

Only the latest released version receives security fixes.

## What counts

- A way around a guardrail: an agent that can push, merge, release or publish without the owner. A gap already listed in [docs/guardrails.md](docs/guardrails.md) is known; a better rule for it is welcome as an issue.
- A value from a cloned project (its `package.json`, folder names or git remotes) that reaches a shell.
- A backup archive readable without its passphrase, or a restore that replaces a file without first copying it to `recovered/`.
- A setup, update or schedule step that changes files beyond what the docs say it changes.
