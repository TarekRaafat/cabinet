#!/usr/bin/env bash
# Check that this machine matches the workspace: repos present, local-only
# files and links in place, roles built, kit files unedited, every push
# guardrail on, the manual current, schedules and backups running.
# Changes nothing in the workspace, the repos or your settings; to check
# opencode and Grok it runs `opencode debug` and `grok inspect`, which may
# write their own caches. Exits non-zero when something needs attention.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
#
#   bin/doctor.sh                  a summary of what needs you, then the full report
#   bin/doctor.sh --fix [--yes]    also run the fixes it knows (bootstrap, roles, snapshot, deps), asking first;
#                                  installing tools (deps) always asks, even with --yes
#   bin/doctor.sh --json           the results as JSON, for agents and scripts
JSON=0 FIX=0 YES=0
for a in "$@"; do
  case "$a" in --json) JSON=1 ;; --fix) FIX=1 ;; -y|--yes) YES=1 ;; *) echo "usage: doctor.sh [--fix [--yes]] [--json]" >&2; exit 2 ;; esac
done
problems=0 cur=""
REC="$(mktemp)"; trap 'rm -f "$REC"' EXIT
section() { cur="$1"; }
# One line per result: level, section, check ID, message. The ID names the check and never
# changes when its message is reworded (docs/troubleshooting.md lists them). A message that
# spans lines (a script's output) is joined with "; ".
rec()  { local m="$3"; m="${m//$'\t'/ }"; printf '%s\t%s\t%s\t%s\n' "$1" "$cur" "$2" "${m//$'\n'/; }" >> "$REC"; }
ok()   { local id="$1"; shift; rec ok "$id" "$*"; }
bad()  { local id="$1"; shift; rec fix "$id" "$*"; problems=$((problems + 1)); }
note() { local id="$1"; shift; rec note "$id" "$*"; }

section "Tools"
miss="$(deps_missing)"
if [[ -z "$miss" ]]; then ok deps.required "the tools cabinet needs are here (${DEPS_REQUIRED// /, })"
else h="$(deps_hint "$miss")"; bad deps.required "cabinet needs ${miss// /, }, not found ($h; cabinet doctor --fix runs it, asking first)"; fi

section "Product repos"
before=$problems
while IFS=$'\t' read -r name url files link path; do
  repo="$(repo_dir "$path")"
  [[ -e "$repo/.git" ]] || { bad repos.present "$name: no repo at $repo (run bin/bootstrap.sh)"; continue; }
  if [[ "${files:--}" != "-" ]]; then
    for f in $files; do
      live="$repo/$f" snap="$WS/local/$name/$f"
      if [[ ! -f "$live" ]]; then bad repos.local-file "$name/$f missing"
      elif [[ ! -f "$snap" ]]; then bad repos.snapshot "$name/$f not in snapshot (run bin/repo.sh snapshot)"
      elif ! cmp -s "$live" "$snap"; then note repos.snapshot "$name/$f changed since last snapshot"
      fi
      git -C "$repo" ls-files --error-unmatch "$f" >/dev/null 2>&1 && bad repos.local-file-tracked "$name/$f is tracked in the product repo but listed as local-only"
    done
  fi
  if [[ "${link:-}" == "yes" ]]; then
    [[ -L "$repo/CLAUDE.md" && "$(readlink "$repo/CLAUDE.md")" == "AGENTS.md" ]] || bad repos.claude-link "$name/CLAUDE.md is not a link to AGENTS.md"
  fi
  # Only repos whose instruction files the workspace manages (link yes) must keep them out of git.
  if [[ "${link:-}" == "yes" ]]; then
    st="$(git -C "$repo" status --porcelain -- AGENTS.md CLAUDE.md 2>/dev/null | grep '^??' || true)"
    [[ -n "$st" ]] && bad repos.instructions-excluded "$name: instruction files show as untracked (missing exclude entry)"
  fi
done < <(repos)
((problems == before)) && ok repos.all "product repos checked"

section "Kit and roles"
kv="$(cat "$K/version" 2>/dev/null || echo none)"
ok kit.version "cabinet $kv"
edited=()
while read -r h p; do
  [[ -z "${p:-}" ]] && continue
  if [[ ! -f "$WS/$p" ]]; then edited+=("$p (missing)")
  elif [[ "$(sha256 "$WS/$p")" != "$h" ]]; then edited+=("$p"); fi
done < "$K/manifest"
((${#edited[@]})) && bad kit.unedited "kit files edited here (an update will refuse them; move the change to a project file or into the kit): ${edited[*]}" || ok kit.unedited "kit files unedited"
[[ -L "$WS/CLAUDE.md" ]] && ok kit.claude-link "CLAUDE.md links to AGENTS.md" || bad kit.claude-link "workspace CLAUDE.md link missing (run bin/bootstrap.sh)"
[[ -f "$WS/HANDOFFS.md" ]] && ok kit.handoffs-file "HANDOFFS.md present" || bad kit.handoffs-file "HANDOFFS.md missing"
# A role the owner added (cabinet role add) works only once an agent has drafted it. A whole role
# of the project's own with a kit role's name is used instead of the kit's: say so. A drafted one
# follows the workflow its job touches (CABINET.md, "Drafting a role"): text checks for the gaps a
# role written before the workflow has, not a judgment of the role.
behind="" clash=""
for f in "$WS"/roles/*.md; do
  [[ -f "$f" ]] && head -1 "$f" | grep -qx -- '---' || continue
  r="$(basename "$f" .md)"
  grep -q '^description: TBD' "$f" && { note roles.drafted "the $r role is not drafted yet (cabinet role draft $r, or ask your agent to draft the $r role)"; continue; }
  [[ -f "$K/roles/$r.md" ]] && note roles.shadows "roles/$r.md is a whole role and the kit also has a $r role: yours is used, not the kit's (rename yours, or remove its frontmatter to add notes to the kit's role)"
  why=""
  grep -q 'CABINET\.md' "$f" || why+=", never sends it to CABINET.md"
  grep -qwE 'PASS|BLOCK|CHANGES' "$f" && ! grep -q 'handoff.sh record' "$f" && why+=", gives verdicts without bin/handoff.sh record"
  grep -qi 'disagree' "$f" || why+=", says nothing of settling a disagreement with a neighbouring role"
  if builds_repos "$r"; then
    grep -qi 'plan' "$f" || why+=", owns a repo but writes no plan"
    grep -qi 'evidence' "$f" || why+=", owns a repo but attaches no evidence"
  fi
  [[ -z "$why" ]] || behind="${behind:+$behind; }$r (${why#, })"
  # What it may write, against the team table: an area another role owns is not its to write.
  while IFS= read -r p; do
    case "$p" in HANDOFFS.md|specs/evidence|specs/evidence/*) continue ;; esac
    o="$(owner_of "$p")"
    [[ -z "$o" || "$o" == "$r" ]] || clash="${clash:+$clash; }$r may write $p, which the team table gives to $o"
  done < <(awk '/^## / {w = ($0 ~ /^## What you may write/); next} w' "$f" | grep -o '`[^`[:space:]]*`' | tr -d '`' | sort -u)
done
[[ -z "${clash:-}" ]] && ok roles.writes "every project role writes only what the team table gives it" \
  || note roles.writes "project roles that may write another role's area: $clash (narrow the role's \"What you may write\", or change the team table)"
[[ -z "$behind" ]] && ok roles.workflow "every drafted project role follows the workflow its job touches" \
  || note roles.workflow "project roles behind the workflow: $behind (redraft each: cabinet role draft <role>, which keeps what you confirmed)"
out="$("$WS/bin/role.sh" build --check 2>&1)" && ok kit.roles "roles built: $(team_roles)" || bad kit.roles "$out (run bin/role.sh build)"

section "Push guardrails"
hooks="$(git config --global core.hooksPath || true)"
if [[ -n "$hooks" && -x "$hooks/pre-push" ]] && grep -q 'dev/tty' "$hooks/pre-push"; then ok guardrails.push-gate "git push gate at $hooks"
else bad guardrails.push-gate "git push gate not installed (run bin/bootstrap.sh)"; fi
[[ -n "$hooks" && -x "$hooks/pre-commit" ]] && ok guardrails.hook-passthrough "repos' own hooks still run (pass-through stubs)" \
  || note guardrails.hook-passthrough "repos' own git hooks (pre-commit and others) do not run under the global hooks path: run bin/bootstrap.sh"
while IFS= read -r d; do
  [[ -e "$d/.git" ]] || continue
  lh="$(git -C "$d" config --local core.hooksPath 2>/dev/null || true)"
  [[ -n "$lh" ]] && bad guardrails.repo-hookspath "$d sets its own core.hooksPath ($lh), which bypasses the push gate"
done < <(data_dirs | awk '!seen[$0]++')
# Every deny rule the kit ships must be live; extra live rules are fine.
missing="$(jq -s '(.[1].permissions.deny - (.[0].permissions.deny // [])) | length' ~/.claude/settings.json "$K/guardrails/claude-permissions.json" 2>/dev/null || echo all)"
[[ "$missing" == 0 ]] && ok guardrails.claude "Claude Code denies push and publish" || bad guardrails.claude "Claude Code is missing $missing deny rule(s) (run bin/bootstrap.sh)"
if command -v codex >/dev/null; then
  [[ "$(codex execpolicy check --rules ~/.codex/rules/default.rules git push origin main 2>/dev/null | jq -r .decision)" == "forbidden" ]] \
    && ok guardrails.codex "Codex forbids git push" || bad guardrails.codex "Codex push rule missing (run bin/bootstrap.sh)"
fi
if command -v agy >/dev/null; then
  jq -e '.permissions.deny | index("command(git push)")' ~/.gemini/antigravity-cli/settings.json >/dev/null 2>&1 \
    && ok guardrails.agy "agy denies git push" || bad guardrails.agy "agy push deny rule missing (run bin/bootstrap.sh)"
fi
if command -v gemini >/dev/null; then
  [[ -f ~/.gemini/policies/owner-control.toml ]] && ok guardrails.gemini "Gemini CLI policy present" || bad guardrails.gemini "Gemini CLI policy missing (run bin/bootstrap.sh)"
fi
kit_deny="$(jq -c '.permissions.deny' "$K/guardrails/claude-permissions.json")"
if command -v qwen >/dev/null; then
  missing="$(jq --argjson d "$kit_deny" '($d - (.permissions.deny // [])) | length' ~/.qwen/settings.json 2>/dev/null || echo all)"
  [[ "$missing" == 0 ]] && ok guardrails.qwen "Qwen Code denies push and publish" || bad guardrails.qwen "Qwen Code is missing $missing deny rule(s) (run bin/bootstrap.sh)"
fi
if cb="$(cursor_bin)"; then
  # Checked against the file only: the rule format is Cursor's documented one, untested here.
  missing="$(jq -s '(.[1].permissions.deny - (.[0].permissions.deny // [])) | length' ~/.cursor/cli-config.json "$K/guardrails/cursor-permissions.json" 2>/dev/null || echo all)"
  [[ "$missing" == 0 ]] && ok guardrails.cursor "Cursor CLI config holds the deny rules (rule shapes probed live on Cursor CLI 2026.10.16)" || bad guardrails.cursor "Cursor CLI is missing $missing deny rule(s) in ~/.cursor/cli-config.json (run bin/bootstrap.sh)"
fi
if [[ -d /Applications/Cursor.app || -d "$HOME/Applications/Cursor.app" ]]; then
  note guardrails.cursor-editor "the Cursor editor keeps its agent's command rules in its own settings, which the kit does not set: only the git push gate applies there"
fi
if command -v grok >/dev/null; then
  # Grok takes its rules from ~/.claude/settings.json; ask Grok itself what it loaded.
  gi="$(cd "$WS" && grok inspect --json 2>/dev/null)"
  if jq -e --arg f "$HOME/.claude/settings.json" '.permissions.sources | any(startswith($f))' <<<"$gi" >/dev/null 2>&1 \
     && jq -e '.permissions.skipped | length == 0' <<<"$gi" >/dev/null 2>&1; then ok guardrails.grok "Grok loads the Claude Code rules"
  else bad guardrails.grok "Grok does not load the rules in ~/.claude/settings.json (check: grok inspect)"; fi
fi
if command -v opencode >/dev/null; then
  # The last matching rule wins: each kit pattern must be the last bash rule that names it or "*".
  # opencode 1.x prints the rules it resolved; opencode 2.x has no such command (its
  # debug commands go through a background service), so there it is a note, not a FIX.
  if rs="$(cd "$WS" && opencode debug agent build 2>/dev/null)" && jq -e '.permission | type == "array"' <<<"$rs" >/dev/null 2>&1; then
    open_rules="$(jq --argjson d "$kit_deny" -r '[.permission[] | select(.permission == "bash" or .permission == "*")] as $rs
      | [$d[] | sub("^Bash\\((?<p>.*)\\)$"; "\(.p)") as $p
        | ([$rs[] | select(.pattern == $p or .pattern == "*")] | last) as $l
        | select($l.pattern != $p or $l.action != "deny") | $p] | join(", ")' <<<"$rs")"
    [[ -z "$open_rules" ]] && ok guardrails.opencode "opencode denies push and publish" || bad guardrails.opencode "opencode does not deny: $open_rules (run bin/bootstrap.sh; a rule in opencode.jsonc comes last and wins)"
  else
    note guardrails.opencode "$(opencode --version 2>/dev/null | sed 's/^opencode //') of opencode cannot be checked from here: confirm its permission settings by hand (the kit's rules are in ~/.config/opencode/opencode.json)"
  fi
fi
# Agent tools cabinet installs no guardrails for: only the git push gate covers them.
for t in aider goose amp crush; do
  command -v "$t" >/dev/null && note guardrails.unguarded-tool "$t is installed and cabinet has no guardrails for it: only the git push gate above applies"
done
# The runner must be found with the PATH scheduled jobs really get: the one written
# into an installed schedule when there is one, else the one bootstrap would write.
c="$CABINET_RUNNER"; [[ "$c" == custom ]] && c="${CABINET_RUNNER_CMD%% *}"
[[ "$c" == cursor ]] && c="$(basename "$(cursor_bin || echo cursor-agent)")"
[[ "$c" == antigravity ]] && c=agy
jp=""
for pl in "$SCHED_DIR/$LABEL".*"$SCHED_EXT"; do
  [[ -f "$pl" ]] && mine "$pl" && [[ "$pl" != *".backup$SCHED_EXT" ]] || continue
  jp="$(sched_get "$pl" path || true)"; [[ -n "$jp" ]] && break
done
[[ -n "$jp" ]] || jp="$(job_path)"
rp="$(env -i HOME="$HOME" PATH="$jp" /bin/sh -c 'command -v "$0"' "$c" 2>/dev/null || true)"
if [[ -z "$c" || -z "$rp" ]]; then bad runner.found "scheduled jobs cannot find the runner '${c:-none}' (install it, or fix CABINET_RUNNER / CABINET_RUNNER_CMD, then run bin/bootstrap.sh)"
elif head -1 "$rp" 2>/dev/null | grep -q 'node' && ! env -i PATH="$jp" /bin/sh -c 'command -v node' >/dev/null; then
  bad runner.node "scheduled jobs find $c but not node, which it needs (run bin/bootstrap.sh after installing node)"
else ok runner.found "scheduled jobs run with $c ($rp)"; fi
if [[ "$CABINET_RUNNER" == custom ]] && ! has "claude codex gemini qwen grok opencode agy cursor-agent agent" "$c"; then
  note runner.custom-unguarded "the custom runner '$c' has no cabinet guardrails: only the git push gate covers its scheduled runs"
fi

section "Skills and plugins"
for s in ${CABINET_SKILLS:-}; do [[ -e ~/.claude/skills/$s ]] || note skills.skill "skill '$s' not installed"; done
for p in ${CABINET_PLUGINS:-}; do grep -q "\"$p@" ~/.claude/plugins/installed_plugins.json 2>/dev/null || note skills.plugin "plugin '$p' not installed"; done
ok skills.checked "skills and plugins checked"

section "Operations manual"
# The manual must name every script, job and role, or it has fallen behind.
missing=()
for f in "$WS"/bin/*.sh; do case "$(basename "$f")" in lib.sh|when.sh|platform.sh) continue ;; esac; grep -qF "bin/$(basename "$f")" "$WS/OPERATIONS.md" || missing+=("bin/$(basename "$f")"); done
for f in "$WS"/jobs/*.job; do [[ -f "$f" ]] || continue; grep -qF "$(basename "$f" .job)" "$WS/OPERATIONS.md" || missing+=("job $(basename "$f" .job)"); done
for r in $(team_roles); do grep -qF "$r" "$WS/OPERATIONS.md" || missing+=("role $r"); done
((${#missing[@]})) && bad manual.complete "OPERATIONS.md does not mention: ${missing[*]}" || ok manual.complete "manual names every script, job and role"

section "Guides"
# Agents find guides through the "Guides" table in AGENTS.md: every file needs a row, every row a file.
if [[ -d "$WS/guides" ]]; then
  gbefore=$problems
  # Only the "## Guides" section counts: a path mentioned elsewhere is not a listing.
  gtable="$(awk '/^## / {on = ($0 == "## Guides")} on' "$WS/AGENTS.md" 2>/dev/null)"
  while IFS= read -r g; do
    grep -qF "\`guides/$g\`" <<<"$gtable" || bad guides.listed "guides/$g has no row in the Guides table of AGENTS.md, so agents never read it"
  done < <(cd "$WS/guides" && find . -type f ! -name README.md ! -name .DS_Store | sed 's#^\./##' | sort)
  while IFS= read -r g; do
    [[ -e "$WS/$g" ]] || bad guides.exists "AGENTS.md lists $g, which does not exist"
  done < <(grep -o '`guides/[^`[:space:]|<>]\{1,\}`' <<<"$gtable" | tr -d '`' | sort -u)
  ((problems == gbefore)) && ok guides.listed "every guide is listed in AGENTS.md"
fi

section "Handoff IDs"
# Each entry ID is used once. A known duplicate carries "Note: duplicate ID; cite as ...b" and is skipped.
hfiles=("$WS/HANDOFFS.md"); for f in "$WS"/handoffs/archive-*.md; do [[ -f "$f" ]] && hfiles+=("$f"); done
dups="$(awk '/^### H-/ {n++; id[n]=$2} /^- Note: duplicate ID/ {skip[n]=1}
  END {for (i=1;i<=n;i++) if (!skip[i]) c[id[i]]++; for (k in c) if (c[k]>1) print k}' "${hfiles[@]}" | sed 's/:$//' | sort | tr '\n' ' ')"
[[ -z "$dups" ]] && ok handoffs.unique-ids "every handoff ID is unique" || bad handoffs.unique-ids "these handoff IDs are used more than once: $dups(file the next free number)"
# Verdicts in the one format (CABINET.md, "Handoffs"), each with its note; a qa PASS needs evidence.
# Open entries only: the archives are history, written before the format. The note's path is
# checked by the shell only after the pattern limits it to safe characters.
vcheck="$(cd "$WS" && awk '
  function end() { if (id != "" && pass && !ev) nev = nev " " id; id = ""; pass = 0; ev = 0 }
  /^## / { end(); open = ($0 == "## Open"); next }
  /^### H-/ { end(); if (open) { id = $2; sub(/:$/, "", id) }; next }
  id == "" { next }
  /^- Evidence:.*(\]\(|<https?:)/ { ev = 1 }
  /^- Verdict:/ {
    if ($0 !~ /^- Verdict: [a-z0-9-]+ (PASS|BLOCK|CHANGES) [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ([0-9a-f]+(,[0-9a-f]+)*|none) specs\/[A-Za-z0-9._\/-]+\.md$/ \
        || (system("test -f \"" $NF "\"") != 0)) bad = bad " " id
    else if ($3 == "qa" && $4 == "PASS") pass = 1
  }
  END { end(); print substr(bad, 2) "|" substr(nev, 2) }
' HANDOFFS.md 2>/dev/null)"
vbad="${vcheck%%|*}" vnev="${vcheck#*|}"
[[ -z "$vbad" ]] && ok handoffs.verdicts "every verdict is in the verdict format, with its note" \
  || bad handoffs.verdicts "verdicts not in the format, or naming a note that does not exist: $vbad (rewrite each as - Verdict: <role> <verdict> <YYYY-MM-DD> <commits> <note under specs/>, and commit its note)"
# A small task that passed stays small: its commits in one repo, touching no path AGENTS.md guards.
notsmall=""
while IFS=$'\t' read -r sid scommits; do
  [[ -n "$scommits" ]] || continue
  why="$(small_problems "$scommits")"; [[ -z "$why" ]] || notsmall="${notsmall:+$notsmall; }$sid ($why)"
done < <(cd "$WS" && awk '
  function end() { if (id != "" && small && c != "") print id "\t" substr(c, 2); id = ""; small = 0; c = "" }
  /^## / { end(); open = ($0 == "## Open"); next }
  /^### H-/ { end(); if (open) { id = $2; sub(/:$/, "", id) }; next }
  id != "" && /^- Size: small *$/ { small = 1 }
  id != "" && /^- Verdict: [a-z0-9-]+ PASS [0-9-]+ [0-9a-f]+(,[0-9a-f]+)* / { c = c "," $6 }   # hex only: it reaches git
  END { end() }
' HANDOFFS.md 2>/dev/null)
[[ -z "$notsmall" ]] && ok handoffs.small "every small task that passed stayed small" \
  || bad handoffs.small "handoffs marked small that were not: $notsmall (route the work again from a spec)"
[[ -z "$vnev" ]] && ok handoffs.evidence "every qa PASS has evidence" \
  || bad handoffs.evidence "qa PASS on handoffs with no evidence: $vnev (the builder adds an Evidence line, or qa changes its verdict to BLOCK)"

# With repos, say what is hard to undo, or a small task is checked only for staying in one repo.
if [[ -n "$(repos 2>/dev/null)" ]]; then
  hl="$(awk '/^## / {h = ($0 == "## Hard to undo"); next} h && /^- /' "$WS/AGENTS.md" 2>/dev/null)"
  if grep -q '`' <<<"$hl" || grep -qx -- '- none' <<<"$hl"; then ok agents.hard-to-undo "AGENTS.md says which paths are hard to undo"
  else note agents.hard-to-undo "AGENTS.md lists no paths that are hard to undo, so a small task is checked only for staying in one repo (cabinet config --hard-to-undo \"<repo>/<path> ...\", or off when there are none; cabinet config suggests some)"; fi
fi

section "Specs"
# A spec marked ready or building has what that status needs (bin/spec.sh check).
if [[ -x "$WS/bin/spec.sh" ]]; then
  sc="$("$WS/bin/spec.sh" check --json 2>/dev/null || true)"
  notready="$(jq -r '[.[] | select(.problems | length > 0) | "\(.spec) (\(.problems | join(", ")))"] | join("; ")' <<<"${sc:-[]}" 2>/dev/null || true)"
  [[ -z "$notready" ]] && ok specs.ready "every spec marked ready or building has what its status needs" \
    || bad specs.ready "specs not ready for their status: $notready (fix each, or set it back to draft; cabinet spec check)"
fi

section "Secrets"
# Keys, tokens and passwords in the workspace's files (bin/secret.sh names the file and line,
# never the value), and the pre-commit hook that refuses new ones.
if out="$("$WS/bin/secret.sh" check 2>&1)"; then ok secrets.none "no likely secret in the workspace's files"
else found="$(grep '^  ' <<<"$out" | sed 's/^  //')"
  bad secrets.none "possible secrets in the workspace's files (remove each and rotate any real key; a false alarm: add not-a-secret to its line): $found"; fi
sh_hook="$(secrets_hook)"
if [[ "$sh_hook" == none ]]; then ok secrets.hook "the workspace is committed with the project, whose own hooks run"
elif [[ -x "$sh_hook" ]] && grep -q 'bin/secret.sh' "$sh_hook"; then ok secrets.hook "commits are checked for secrets"
else note secrets.hook "commits are not checked for secrets: the workspace has no pre-commit hook running bin/secret.sh (run bin/bootstrap.sh; a hook of your own can call bin/secret.sh check --staged)"; fi

section "Team"
# A part of a product repo given to another role than the repo's owner: allowed (the most specific
# row wins), but the owner's call, so say so.
nested=""
while IFS=$'\t' read -r a o; do
  rn="${a%%/*}"; [[ "$a" == */* ]] || continue
  has " $(repos 2>/dev/null | cut -f1 | tr '\n' ' ') " "$rn" || continue
  ro="$(team_rows | awk -F'\t' -v n="$rn" '$1 == n { print $2; exit }')"
  [[ -n "$ro" && "$ro" != "$o" ]] && nested="${nested:+$nested; }$a ($o) inside $rn ($ro)"
done < <(team_rows)
[[ -z "$nested" ]] && ok team.nested "no part of a repo is given to another role than the repo's owner" \
  || note team.nested "parts of a repo owned by another role than the repo's: $nested (the most specific row wins; if that is not meant, change the team table)"
# Each repo or area has one owner in the team table, or two roles would act on it.
dup="$(awk -F'|' '/^## / {on = ($0 ~ /^## The team/)} on && NF >= 4 {
    a = $2; o = $4; gsub(/^ +| +$/, "", a); gsub(/^ +| +$/, "", o)
    if (a == "" || a == "TBD" || a == "Repo or area" || a ~ /^-+$/ || o == "" || o == "TBD") next
    if ((a in own) && own[a] != o) print a " (" own[a] " and " o ")"; else own[a] = o
  }' "$WS/AGENTS.md" 2>/dev/null | sort -u | paste -sd ';' - | sed 's/;/; /g')"
[[ -z "$dup" ]] && ok team.single-owner "each repo and area in the team table has one owner" \
  || bad team.single-owner "more than one owner in the team table of AGENTS.md: $dup (give each one owner)"
# Open handoffs reach someone: a role, a repo, or the owner. A removed role or repo strands them.
known=" owner founder $(team_roles) $(repos 2>/dev/null | cut -f1 | tr '\n' ' ') "
stranded="$("$WS/bin/handoff.sh" list --json 2>/dev/null | jq -r '.[] | [.id, .to] | @tsv' 2>/dev/null | while IFS=$'\t' read -r id to; do
    printf '%s\n' "$to" | sed 's/([^)]*)//g; s/ and /,/g; s/&/,/g' | tr -d '`' | tr ',' '\n' | while IFS= read -r n; do
      n="$(printf '%s' "$n" | sed 's/^ *//; s/ *$//' | tr '[:upper:]' '[:lower:]')"
      [[ -z "$n" ]] || has "$known" "$n" || printf '%s (%s)\n' "$id" "$n"
    done
  done | paste -sd ';' - | sed 's/;/; /g')"
[[ -z "$stranded" ]] && ok handoffs.addressee "every open handoff is addressed to a role, a repo or the owner" \
  || note handoffs.addressee "open handoffs addressed to no role or repo on the team: $stranded (readdress or close them)"

section "Uncommitted work"
git -C "$WS" rev-parse -q --verify HEAD >/dev/null 2>&1 || ! [[ -e "$WS/.git" ]] || note work.no-commits "the workspace has no commits yet: backups hold its files only (set the owner with cabinet config, then commit)"
pending=0
while IFS=$'\t' read -r label r; do
  [[ -e "$r/.git" ]] || continue
  n="$(git -C "$r" status --porcelain | wc -l | tr -d ' ')"
  ((n)) && { note work.uncommitted "$label has $n uncommitted file(s): work in progress, or finished and not committed?"; pending=1; }
done < <({ printf 'the workspace\t%s\n' "$WS"; while IFS=$'\t' read -r name url files link path; do printf '%s\t%s\n' "$name" "$(repo_dir "$path")"; done < <(repos); } | awk -F'\t' '!seen[$2]++')
((pending)) || ok work.uncommitted "nothing uncommitted"

section "Schedules"
if [[ "$SCHEDULER" != none && "$CABINET_SCHEDULES" == off ]]; then
  note schedules.off "jobs are not scheduled on this machine (CABINET_SCHEDULES=off in cabinet.local.env): another machine runs them; cabinet bootstrap --schedules turns them on"
fi
if [[ "$SCHEDULER" == none ]]; then
  grep -qs '^WHEN="\{0,1\}[^"]' "$WS"/jobs/*.job && bad schedules.scheduler "no scheduler on this machine (a running systemd user session, or cron), so no job runs on its own: install cron, then run bin/bootstrap.sh"
else
  for jf in "$WS"/jobs/*.job; do
    [[ -f "$jf" && "$CABINET_SCHEDULES" != off ]] || continue
    j="$(basename "$jf" .job)"
    WHEN="$(WHEN=""; source "$jf"; echo "$WHEN")"
    [[ -z "$WHEN" ]] && continue
    pl="$(sched_file "$LABEL.$j")"
    if ! when_norm "$WHEN" >/dev/null; then
      bad schedules.when "jobs/$j.job has a WHEN bootstrap cannot schedule ('$WHEN'): use a time like 7 AM for every day, or days and a time like fri 4 PM or sun,mon,tue,wed,thu 8 AM"
    elif [[ ! -f "$pl" ]]; then bad schedules.job "$LABEL.$j not scheduled (run bin/bootstrap.sh)"
    elif ! mine "$pl"; then bad schedules.job-owner "$LABEL.$j runs another workspace: give this one its own slug (cabinet config --slug)"
    elif ! sched_loaded "$LABEL.$j"; then bad schedules.job-loaded "$LABEL.$j is written but not loaded by $SCHEDULER (run bin/bootstrap.sh)"
    else ok schedules.job "$LABEL.$j scheduled ($(when_human "$WHEN"))"; fi
  done
  # A schedule that runs this workspace under another name is left over from an old slug.
  for live in "$SCHED_DIR"/ai.cabinet.*"$SCHED_EXT"; do
    [[ -f "$live" ]] || continue
    l="$(sched_label "$live")"; [[ "$l" == "$LABEL".* ]] && continue
    mine "$live" || continue
    h="$(sched_stop_cmd "$l")"; bad schedules.old-slug "$l still runs this workspace under an old name ($h)"
  done
fi

section "Spend"
# What the agent runs cabinet started cost this week, as the tool reports it; a warning from 80% of the budget.
if ! spend_counts; then
  if [[ -z "$CABINET_BUDGET" ]]; then :
  elif has "$SPEND_TOKENS" "$CABINET_RUNNER"; then note spend.unreported "$CABINET_RUNNER reports tokens, not dollars, so the \$$CABINET_BUDGET budget is not tracked: set its price with cabinet config --price \"<input> <output> [<cached input>]\" (dollars per million tokens)"
  else note spend.unreported "$CABINET_RUNNER does not report what a run costs, so the \$$CABINET_BUDGET budget is not tracked (the built-in runners report it)"; fi
else
  w="$(spend_since "$(week_start)")"
  if [[ -z "$CABINET_BUDGET" ]]; then ok spend.budget "agent runs cost \$$w this week, $(spend_source); no budget set (cabinet config --budget <dollars>)"
  else
    pct="$(awk -v w="$w" -v b="$CABINET_BUDGET" 'BEGIN { printf "%d", (b > 0 ? w * 100 / b : 100) }')"
    if ((pct >= 100)); then bad spend.budget "agent runs cost \$$w this week, over the \$$CABINET_BUDGET budget: cabinet job list shows what each job cost; raise it with cabinet config --budget <dollars>"
    elif ((pct >= 80)); then bad spend.budget "agent runs cost \$$w this week, $pct% of the \$$CABINET_BUDGET budget: cabinet job list shows what each job cost; raise it with cabinet config --budget <dollars>"
    else ok spend.budget "agent runs cost \$$w this week, $pct% of the \$$CABINET_BUDGET budget"; fi
  fi
fi

section "Backups"
if [[ -z "$CABINET_BACKUP_DIR" ]] && ((BACKUP_DIR_LOCAL)); then
  note backups.enabled "backups are off on this machine (cabinet.local.env; cabinet config --this-machine --backup-dir <folder> turns them on)"
elif [[ -z "$CABINET_BACKUP_DIR" ]]; then
  note backups.enabled "backups are off (set CABINET_BACKUP_DIR in cabinet.env, then run bin/bootstrap.sh)"
else
  if [[ "$CABINET_BACKUP_DIR" != /* && "$CABINET_BACKUP_DIR" != "~/"* ]]; then bad backups.dir-absolute "CABINET_BACKUP_DIR must be an absolute path"; fi
  while IFS= read -r d; do
    within "$CABINET_BACKUP_DIR" "$d" && bad backups.dir-outside "the backup folder is inside $d: a backup there is lost with it and can be committed (choose a folder outside, then cabinet config)"
  done < <(data_dirs | awk '!seen[$0]++')
  # Read the backup log, not the backup folder: listing a synced folder can trigger
  # a macOS access prompt that hangs a scheduled run.
  newest="$(grep -o "$CABINET_SLUG-[0-9]\{8\}-[0-9]\{6\}\.tar\.gz\.enc" "$LOGDIR/backup.log" 2>/dev/null | tail -1)"
  h="$(sched_start_cmd "$LABEL.backup" "cabinet backup create")"
  if [[ -z "$newest" ]]; then bad backups.recent "no scheduled backup in $LOGDIR/backup.log yet ($h)"
  else
    stamp="${newest#"$CABINET_SLUG"-}"; stamp="${stamp%.tar.gz.enc}"
    age=$(( ($(date +%s) - $(stamp_epoch "$stamp")) / 3600 ))
    when="$(human_stamp "$stamp")"
    ((age <= 36)) && ok backups.recent "newest backup ${age}h old ($when): $newest" || bad backups.recent "newest backup is ${age}h old ($when): $newest"
  fi
  # A backup counts once a restore of it has been checked (cabinet backup verify), once a quarter.
  vf="$LOGDIR/backup-verified"
  if [[ ! -f "$vf" ]]; then note backups.verified "no restore of a backup has been verified on this machine yet (cabinet backup verify)"
  else
    vdays=$(( ($(date +%s) - $(mtime "$vf")) / 86400 )) vwhen="$(human_mtime "$vf")"
    ((vdays <= 92)) && ok backups.verified "a restore was verified $vdays day(s) ago ($vwhen): $(cat "$vf")" \
      || note backups.verified "the last verified restore was $vdays days ago ($vwhen): verify again (cabinet backup verify)"
  fi
  pf="$(pass_file "$KEYCHAIN_ITEM")"
  if [[ -f "$pf" ]] && ! pass_file_ok "$pf"; then bad backups.passphrase "the passphrase file $pf can be read by other users, so it is not used: chmod 600 $pf"
  elif [[ -f "$pf" ]]; then ok backups.passphrase "backup passphrase in $pf"
  elif pass_has "$KEYCHAIN_ITEM"; then ok backups.passphrase "backup passphrase in the $PASS_STORE"
  elif [[ -n "${CABINET_BACKUP_PASSPHRASE:-}" ]]; then ok backups.passphrase "backup passphrase from CABINET_BACKUP_PASSPHRASE (scheduled backups need it set where they run, or in the $PASS_STORE)"
  else h="$(pass_add_cmd "$KEYCHAIN_ITEM")"; bad backups.passphrase "backup passphrase missing from the $PASS_STORE ($KEYCHAIN_ITEM: $h)"; fi
  miss="$(deps_backups)"
  if [[ -n "$miss" ]]; then h="$(deps_hint "$miss")"; bad deps.backups "backups need ${miss// /, }, not found ($h; cabinet doctor --fix runs it, asking first)"; fi
fi

# Counted from the record, so a check run in a pipe or subshell still counts.
problems="$(grep -c $'^fix\t' "$REC" || true)"
# The fixes the doctor can run itself, named in its own messages.
actions=""
grep -q $'^fix\t.*run bin/bootstrap.sh' "$REC" && actions+=" bootstrap"
grep -q $'^fix\t.*run bin/role.sh build' "$REC" && actions+=" roles"
grep -q $'^fix\t.*run bin/repo.sh snapshot' "$REC" && actions+=" snapshot"
grep -qE $'^fix\t[^\t]*\tdeps\.' "$REC" && actions+=" deps"
actions="${actions# }"

if ((JSON)); then
  jq -Rn --arg ws "$WS" --arg fixes "$actions" '[inputs | split("\t") | {level: .[0], section: .[1], id: .[2], message: .[3]}] as $r
    | {workspace: $ws, problems: ([$r[] | select(.level == "fix")] | length), notes: ([$r[] | select(.level == "note")] | length),
       can_fix: ($fixes | split(" ") | map(select(length > 0))), results: $r}' < "$REC"
  ((problems)) && exit 1; exit 0
fi

# The fixes by the commands people know (bash 3.2 cannot parse a case inside "$(...)").
fix_names() {
  local a out=""
  for a in $actions; do case "$a" in roles) out+="role build, " ;; snapshot) out+="repo snapshot, " ;; deps) out+="install tools, " ;; *) out+="$a, " ;; esac; done
  printf '%s' "${out%, }"
}
# Summary first: what needs you, and what --fix can do; then the full report.
if ((problems)); then
  echo "$problems thing(s) need attention:"
  awk -F'\t' '$1 == "fix" {print "  - " $4}' "$REC"
  [[ -n "$actions" ]] && echo "cabinet doctor --fix can run: $(fix_names) (it shows each and asks first)"
else
  n="$(grep -c $'^note\t' "$REC")"
  echo "All good.$( ((n)) && echo " $n note(s) below.")"
fi
echo
awk -F'\t' '$2 != last {print "== " $2; last = $2}
  {printf "  %-5s %s\n", ($1 == "fix" ? "FIX" : $1), $4}' "$REC"

if ((FIX)); then
  echo
  if [[ -z "$actions" ]]; then echo "Nothing here that --fix can do: each item above needs you."
  else
    for act in $actions; do
      # Installing changes the machine and may need sudo: it always asks, in a terminal, even with --yes.
      if [[ "$act" == deps ]]; then
        miss="$(deps_missing) $([[ -n "$CABINET_BACKUP_DIR" ]] && deps_backups)"; miss="$(echo $miss)"
        if ! cmd="$(deps_cmd "$miss")"; then echo "  $(deps_hint "$miss")"; continue; fi
        if ((YES)) || ! { exec 3</dev/tty; } 2>/dev/null; then echo "  installing tools always asks: run cabinet doctor --fix in a terminal (without --yes), or yourself: $cmd"; continue; fi
        read -r -u 3 -p "Install now with: $cmd? [Y/n]: " ans || true
        [[ "${ans:-y}" == [Yy]* ]] && { deps_install "$miss" || echo "  the install reported a problem: see above"; } || echo "  skipped: $cmd"
        continue
      fi
      # The action names are stable (can_fix in --json); each runs its command.
      case "$act" in bootstrap) cmd="bin/bootstrap.sh" ;; roles) cmd="bin/role.sh build" ;; snapshot) cmd="bin/repo.sh snapshot" ;; esac
      if ((YES == 0)); then
        { exec 3</dev/tty; } 2>/dev/null || { echo "--fix asks before each step: run it in a terminal, or add --yes"; exit 1; }
        read -r -u 3 -p "Run $cmd now? [Y/n]: " ans || true
        [[ "${ans:-y}" == [Yy]* ]] || { echo "  skipped $cmd"; continue; }
      fi
      # shellcheck disable=SC2086
      echo "== $cmd"; "$WS/"$cmd || echo "  $cmd reported a problem: see above"
    done
    echo; echo "== After the fixes"
    "$WS/bin/doctor.sh" | sed -n '1,/^$/p'
  fi
fi
((problems)) && exit 1
exit 0
