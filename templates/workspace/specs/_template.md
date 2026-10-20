---
feature: short name
status: draft # draft | ready | building | shipped | dropped (.cabinet/rules/ready-to-build.md; check: bin/spec.sh check)
owner_decisions_open: 0
repos: [] # repos (or workspace areas, for work with no code) that build it, e.g. [api, app]
areas: [] # critical areas it touches, from "Critical areas" in AGENTS.md, e.g. [billing]
handoffs: [] # entry IDs that route or track it
updated: YYYY-MM-DD
---

# Feature name

## Problem

Who has it, and what they cannot do today.

## What exists today

Code, endpoints and screens that already cover part of it, with paths.

## Rules

What the feature does, as the owner decided it. Anything not decided is TBD and listed under Decisions.

## Design

For anything people see, written by design-lead before the spec is ready: the flows, each screen and its states (empty, loading, error, long text), and how it follows the brand guide.

## Product fit

How the feature meets each product rule in `AGENTS.md`.

## Edge cases

## Acceptance criteria

Testable statements, one per line.

## Out of scope

## Decisions

| # | Question | Options | Recommendation | Owner answer (date) |
|---|---|---|---|---|

## Plan

How it will be built, written by each owning builder before its first change: one `### <repo>` part per repo in `repos`, with the files it changes, the tests it adds, the order across repos, and the risks. For more than one repo, architect reviews the plan before building starts.

## Reviews

Written only by `bin/spec.sh record`: qa on the acceptance criteria, design-lead on the design, architect on the plan.
