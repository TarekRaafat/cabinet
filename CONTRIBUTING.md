# Contributing to Cabinet

Thank you for helping. Cabinet is plain Markdown, bash and JavaScript run with Node, so most changes need only a clone and a terminal.

## Before you start

- **A question or an idea:** start a thread in [GitHub Discussions](https://github.com/TarekRaafat/cabinet/discussions).
- **A bug:** open an issue with the bug form.
- **A security problem:** never in a public issue. Follow [SECURITY.md](SECURITY.md).
- **A large change** (a new command, a new noun, a new kind of role): open an issue or a discussion first, so the shape is agreed before you build it.
- **A first change:** issues labelled "good first issue" name the files to change.

## The rules

Read [AGENTS.md](AGENTS.md) before changing anything: it holds every rule for working on the kit. What reviews check most:

- Every change has a test in `test/smoke.sh` and an entry in `CHANGELOG.md` under the next version.
- The docs match the code: a change to a command, option, file, message or behavior updates `docs/` (and `README.md` when people see it) in the same change, then `npm run docs` rebuilds `llms-full.txt`.
- Commands follow the conventions in `AGENTS.md`: one command table in `bin/cabinet`, one list of verbs, the same options everywhere.
- Scripts run on bash 3.2. New logic is JavaScript in `scripts/lib.js`, never TypeScript, with Node's own modules only: no npm packages and no build step.
- Tests never touch your real machine: they run in a scratch home folder, with fakes of the schedulers, the keychain and the agent tools.
- A guardrail is never weakened, and never tested with a real push, merge or publish: use the tool's own matcher, or a harmless command of the same shape.
- ASCII punctuation only, and dates people read written as `18 Oct 2026`.

## Run the checks

```sh
npm test                 # every section, about a minute; must end with PASS
npm test -- init         # only the sections whose name has a word, and what they need
npm run test:linux       # the same suite on Linux, in a Debian container (needs Docker or Colima)
```

## Working with an agent

Agent tools load `AGENTS.md` at the root of this repository first, and it sends them through the same rules. Agents never push, so your agent commits on your machine, and you push to your fork and open the pull request yourself.

## Pull requests

- One change per pull request, titled with what it does.
- Fill in the template: what changed, why, and how you tested it.
- `npm test` passes on macOS or Linux.
- Support for a new agent tool: its deny rules in `guardrails/`, its setup in `scripts/bootstrap.sh`, what its rule format can and cannot block in `docs/guardrails.md`, and a test that checks each rule with the tool's own matcher.

## License and conduct

By contributing, you agree that your work is licensed under the [Apache License 2.0](LICENSE), the project's license. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
