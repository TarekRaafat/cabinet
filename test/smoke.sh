#!/usr/bin/env bash
# End-to-end check of the kit in a throwaway folder: every command and layout,
# roles, handoffs, schedules, guardrail merges, backups and restores, and the
# fixes from reviews. Touches nothing outside the temp folder: HOME and git's
# global config point inside it, and launchctl is a fake that only logs.
#
#   test/smoke.sh
# No pipefail: "cmd | grep -q" checks would fail at random when grep exits early.
set -eu
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F="$KIT/bin/cabinet"
fail() { echo "FAIL: $*" >&2; exit 1; }
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
# The real home folder, git config and agent tool settings are never read or written.
export HOME="$T/user" GIT_CONFIG_GLOBAL="$T/user/.gitconfig" GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$T/user/.config"
mkdir -p "$HOME"; printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$GIT_CONFIG_GLOBAL"
# The real launchd is never reached: a fake launchctl that only logs is first on PATH for the
# whole run, before any section, so even one section run alone cannot load a real schedule.
mkdir -p "$T/shim"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/launchctl.log" > "$T/shim/launchctl"; chmod +x "$T/shim/launchctl"
export PATH="$T/shim:$PATH"
[[ "$(command -v launchctl)" == "$T/shim/launchctl" ]] || fail "the fake launchctl is not first on PATH"


# Sections build on each other's workspaces. `test/smoke.sh <word>...` (npm test -- <word>) runs
# only the sections whose name contains a word, plus the sections they need; no word runs all.
_names=(); _needs=()
section() { _names+=("$1"); _needs+=("$2"); }

section "new" ""
s0() {
"$F" new "$T/Demo Co" --name "Demo Co" --yes >/dev/null
W="$T/Demo Co"
grep -q 'CABINET_SLUG="demo-co"' "$W/cabinet.env" && grep -qx 'CABINET_LAYOUT="new"' "$W/cabinet.env" || fail "slug or layout not set"
grep -q '^# AGENTS.md - Demo Co$' "$W/AGENTS.md" || fail "project name not filled in"
! grep -rq '@@' "$W" --exclude-dir=.git --exclude-dir=.cabinet || fail "placeholder left in a project file"
[[ -L "$W/CLAUDE.md" ]] || fail "CLAUDE.md link missing"
[[ "$(cat "$W/.cabinet/version")" == "$(jq -r .version "$KIT/package.json")" ]] || fail "version not recorded"
git -C "$W" log --oneline | grep -q 'create from cabinet' || fail "workspace not committed"
[[ "$("$W/bin/handoffs.sh")" == "No open handoffs." && "$("$W/bin/handoffs.sh" --json)" == "[]" ]] || fail "handoffs with none open"
  return 0   # a last "check && fail" line must not end the run
}

section "new with options" ""
s1() {
env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL "$F" new "$T/opt" --yes --roles "qa security" --runner codex --brief off --week-start Monday \
  --backup-dir "$T/bk" --repo git@example.com:me/opt-api.git --owner "Ann Owner" --email ann@example.com >/dev/null
O="$T/opt"
grep -qx 'CABINET_ROLES="chief-of-staff qa security"' "$O/cabinet.env" || fail "roles option"
grep -qx 'CABINET_RUNNER="codex"' "$O/cabinet.env" && grep -qx "CABINET_BACKUP_DIR=\"$(cd "$T" && pwd -P)/bk\"" "$O/cabinet.env" || fail "runner or backup option"
grep -qx 'WHEN=""' "$O/jobs/brief.job" || fail "brief off"
grep -q 'Week starts on:\*\* Monday\.' "$O/AGENTS.md" || fail "week start"
grep -q '| finance |' "$O/AGENTS.md" "$O/OPERATIONS.md" && fail "disabled role still in a team table"
grep -q '| `opt-api` |' "$O/AGENTS.md" && grep -q $'^opt-api\tgit@example.com:me/opt-api.git' "$O/repos.tsv" || fail "repo option"
grep -q 'Ann Owner <ann@example.com>' "$O/AGENTS.md" && [[ "$(git -C "$O" log -1 --format=%an)" == "Ann Owner" ]] || fail "owner option"
[[ "$(ls "$O/agents")" == "$(printf '%s\n' chief-of-staff.md qa.md security.md)" ]] || fail "only the chosen roles are built"
out="$("$O/bin/doctor.sh" 2>&1 || true)"; echo "$out" | grep -q 'ok    manual names every script, job and role' || fail "doctor: manual after dropping roles"
"$F" new "$T/bad" --yes --brief lunchtime >/dev/null 2>&1 && fail "bad brief time accepted"
[[ ! -e "$T/bad" ]] || fail "a refused setup left files behind"
  return 0   # a last "check && fail" line must not end the run
}

section "new, answered at the prompts" ""
s2() {
# Name, folder, owner, email, 6 roles (product-manager no, finance no), runner, brief,
# week, backup, one repo then done, create, no npm install, no machine setup.
printf '%s\n' "Acme Labs" "$T/acme" "" "" n "" "" "" "" n gemini "8:30 am" sunday off git@example.com:me/acme-app.git "" y n n > "$T/answers"
CABINET_TTY="$T/answers" "$F" new >/dev/null 2>&1 || fail "prompted setup failed"
A="$T/acme"
grep -q '^# AGENTS.md - Acme Labs$' "$A/AGENTS.md" && grep -qx 'CABINET_SLUG="acme"' "$A/cabinet.env" || fail "prompted name or folder"
grep -qx 'CABINET_ROLES="chief-of-staff architect qa security design-lead"' "$A/cabinet.env" || fail "prompted roles"
grep -qx 'CABINET_RUNNER="gemini"' "$A/cabinet.env" && grep -qx 'WHEN="8:30 AM"' "$A/jobs/brief.job" || fail "prompted runner or brief"
grep -q $'^acme-app\t' "$A/repos.tsv" || fail "prompted repo"
printf '%s\n' "Nope" "$T/nope" "" "" "" "" "" "" "" "" "" "" "" "" "" n > "$T/answers"
CABINET_TTY="$T/answers" "$F" new >/dev/null 2>&1 && fail "declined setup reported success"
[[ ! -e "$T/nope" ]] || fail "declined setup created files"

# A small project repo with one commit.
mkrepo() { mkdir -p "$1" && git -C "$1" init -q -b main && echo x > "$1/f" && git -C "$1" add -A && git -C "$1" commit -qm init; }
  return 0   # a last "check && fail" line must not end the run
}

section "init inside a project, private" "2"
s3() {
I="$T/acme-app"; mkrepo "$I"
mkdir -p "$I/.claude/agents"; echo '# Acme rules' > "$I/AGENTS.md"; echo mine > "$I/.claude/agents/security.md"
echo '{"name":"acme-app","devDependencies":{"@tarekraafat/cabinet":"^0.1.0"}}' > "$I/package.json"
git -C "$I" add -A && git -C "$I" commit -qm setup && git -C "$I" remote add origin git@example.com:acme/app.git
(cd "$I" && "$F" init --yes --inside) >/dev/null || fail "init inside failed"
grep -qx 'CABINET_LAYOUT="inside"' "$I/cabinet/cabinet.env" && grep -qx 'CABINET_VISIBILITY="private"' "$I/cabinet/cabinet.env" || fail "inside private settings"
[[ -d "$I/cabinet/.git" ]] && git -C "$I/cabinet" log --oneline | grep -q 'create from cabinet' || fail "private workspace has no git of its own"
# Private changes no tracked file of the project, and nothing setup added shows in its git.
[[ -z "$(git -C "$I" status --porcelain)" ]] || { git -C "$I" status --porcelain; fail "private workspace showed up in the project's git"; }
[[ "$(cat "$I/AGENTS.md")" == '# Acme rules' ]] || fail "private changed the project's tracked AGENTS.md"
grep -q 'cabinet/CABINET.md' "$I/CLAUDE.local.md" && grep -q 'cabinet/CABINET.md' "$I/QWEN.local.md" || fail "private pointer not in the local instruction files"
[[ "$(cat "$I/.claude/agents/security.md")" == mine ]] || fail "a hand-made project agent was replaced"
[[ -f "$I/.claude/agents/qa.md" ]] && jq -e '.devDependencies["@tarekraafat/cabinet"]' "$I/cabinet/package.json" >/dev/null || fail "roles not in the project, or the private pin not in cabinet/package.json"
grep -q $'^acme-app\tgit@example.com:acme/app.git\t-\tno\t..$' "$I/cabinet/repos.tsv" || fail "project row"
(cd "$I" && "$F" status) | grep -q 'no kit file edited' && (cd "$I" && "$F" update >/dev/null) || fail "status or update from the project top"
out="$("$I/cabinet/bin/doctor.sh" 2>&1 || true)"
echo "$out" | grep -q 'ok    roles built' && echo "$out" | grep -q 'ok    product repos checked' && ! echo "$out" | grep -q 'no repo at' || { echo "$out" | grep FIX; fail "doctor inside a project"; }
(cd "$I" && "$F" init --yes) >/dev/null 2>&1 && fail "a second init was accepted"
  return 0   # a last "check && fail" line must not end the run
}

section "init reads what the project says about itself" "2"
s4() {
G="$T/shop"; mkrepo "$G"
git -C "$G" config user.name "Shop Owner"; git -C "$G" config user.email shop@example.com
echo "# Shop" > "$G/README.md"; touch "$G/bun.lock"
echo '{"name":"@acme/shop","description":"Online shop for handmade goods","repository":{"url":"git+https://github.com/acme/shop.git"},"scripts":{"dev":"vite","test":"bun test","deploy":"x"}}' > "$G/package.json"
(cd "$G" && "$F" init --yes --beside) >/dev/null || fail "init on a described project"
GA="$T/shop-hq/AGENTS.md"
grep -qx '# AGENTS.md - shop' "$GA" || fail "name not taken from package.json"
grep -qxF 'From `../shop/package.json`, as written there: "Online shop for handmade goods"' "$GA" || fail "description not quoted with its source"
grep -qxF 'The project'"'"'s own rules and setup: `../shop/README.md`.' "$GA" || fail "the project's own files not named"
grep -qxF -- '- `bun run test`' "$GA" && grep -qxF -- '- `bun run dev`' "$GA" && ! grep -q 'run deploy' "$GA" || fail "scripts not listed, or a non-test script listed"
grep -q '^TBD: what else qa needs' "$GA" && grep -q '^TBD: who it is for' "$GA" || fail "the parts nothing can tell were not left TBD"
grep -q $'^shop\thttps://github.com/acme/shop.git\t' "$T/shop-hq/repos.tsv" || fail "repository URL not taken from package.json"
grep -q 'Authored as Shop Owner <shop@example.com>' "$GA" || fail "the repo's own git identity not used"
! grep -q 'TBD: one paragraph\|TBD: how qa runs' "$GA" || fail "answered TBDs left in place"
! grep -q 'tarekraafat/cabinet' "$G/package.json" && jq -e '.devDependencies["@tarekraafat/cabinet"]' "$T/shop-hq/package.json" >/dev/null || fail "beside put the pin in the project instead of the workspace"
  return 0   # a last "check && fail" line must not end the run
}

section "init inside a project, shared" "2 3"
s5() {
S="$T/shared-app"; mkrepo "$S"
printf '{\n\t"name": "shared-app"\n}\n' > "$S/package.json"; git -C "$S" add -A; git -C "$S" commit -qm pkg
(cd "$S" && "$F" init --yes --inside --shared) >/dev/null || fail "init shared failed"
grep -qx 'CABINET_VISIBILITY="shared"' "$S/cabinet/cabinet.env" || fail "shared setting"
[[ ! -e "$S/cabinet/.git" ]] && git -C "$S" status --porcelain | grep -q '^?? cabinet/$' || fail "shared workspace is not part of the project"
git -C "$S" log --oneline | grep -q 'create from cabinet' && fail "shared init committed in the project"
v="$(jq -r .version "$KIT/package.json")"
[[ "$(jq -r '.devDependencies["@tarekraafat/cabinet"]' "$S/package.json")" == "^$v" ]] || fail "pin not added to the project's package.json under --yes"
grep -q $'^\t"name"' "$S/package.json" && [[ ! -f "$S/cabinet/package.json" ]] || fail "package.json formatting lost, or a second one placed"
[[ "$(jq -r '.devDependencies["@tarekraafat/cabinet"]' "$I/package.json")" == "^0.1.0" && -z "$(git -C "$I" diff --stat -- package.json)" ]] || fail "an existing pin was touched"
  return 0   # a last "check && fail" line must not end the run
}

section "init beside a project" "2"
s6() {
B="$T/side"; mkrepo "$B"
(cd "$B" && "$F" init --yes --beside) >/dev/null || fail "init beside failed"
[[ -z "$(git -C "$B" status --porcelain)" ]] || fail "beside changed the project"
grep -q $'^side\t-\t-\tno\t../side$' "$T/side-hq/repos.tsv" || fail "beside row"
grep -qx 'CABINET_LAYOUT="beside"' "$T/side-hq/cabinet.env" && grep -qx 'CABINET_VISIBILITY=""' "$T/side-hq/cabinet.env" || fail "beside settings"
"$T/side-hq/bin/doctor.sh" 2>&1 | grep -q 'ok    product repos checked' || fail "doctor beside"
  return 0   # a last "check && fail" line must not end the run
}

section "init around a folder of repos" "2 3"
s7() {
R="$T/around"; mkrepo "$R/api"; mkrepo "$R/web"; mkdir -p "$R/bin"
echo "# mine" > "$R/README.md"; echo "#!/bin/sh" > "$R/bin/handoffs.sh"
# A file of the folder's own at a kit path would be run as the kit's: init refuses, and creates nothing.
out="$("$F" init "$R" --yes 2>&1)" && fail "init accepted a file of its own at a kit path"
echo "$out" | grep -q 'already exist at paths the kit uses: bin/handoffs.sh' && [[ ! -e "$R/.cabinet" && "$(cat "$R/bin/handoffs.sh")" == "#!/bin/sh" ]] || fail "refused init still wrote files"
mv "$R/bin/handoffs.sh" "$R/my-handoffs.sh"; rmdir "$R/bin"
# Its own .gitignore is kept, and only setup's files are committed: never its .env or other files.
printf 'node_modules\n' > "$R/.gitignore"; echo SECRET=1 > "$R/.env"; echo a,b > "$R/data.csv"
out="$("$F" init "$R" --yes 2>&1)" || { echo "$out"; fail "init around failed"; }
echo "$out" | grep -q 'kept your own.*README.md' && [[ "$(cat "$R/README.md")" == "# mine" ]] || fail "an existing file was replaced"
! git -C "$R" ls-files | grep -qx -e .env -e data.csv -e my-handoffs.sh -e api -e web || fail "init committed files that were already in the folder"
git -C "$R" ls-files | grep -qx CABINET.md || fail "the workspace's own files were not committed"
[[ "$(grep -v '^#' "$R/repos.tsv" | cut -f1 | tr '\n' ' ')" == "api web " ]] || fail "found repos not listed"
grep -qx 'CABINET_LAYOUT="around"' "$R/cabinet.env" || fail "around setting"
[[ -z "$(git -C "$R" ls-files api web)" ]] || fail "repos were added to the workspace's git"
mkdir -p "$T/plain"; echo x > "$T/plain/x"
"$F" init "$T/plain" --yes --inside >/dev/null 2>&1 && fail "--inside accepted outside a repo"
mkdir -p "$I/sub"; (cd "$I/sub" && "$F" init --yes) >/dev/null 2>&1 && fail "init accepted in a subfolder of a repo"
  return 0   # a last "check && fail" line must not end the run
}

section "backup and restore, inside a project" "3"
s8() {
BK="$T/bk"; mkdir -p "$T/bkhome"
HOME="$T/bkhome" CABINET_BACKUP_PASSPHRASE=t "$I/cabinet/bin/backup.sh" "$BK" >/dev/null || fail "backup inside a project"
HOME="$T/bkhome" CABINET_BACKUP_PASSPHRASE=t "$I/cabinet/bin/restore.sh" "$(ls "$BK"/*.enc)" "$T/r/cabinet" > "$T/rout" || fail "restore inside a project"
grep -Eq '^Restoring acme-app from the backup of [0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}, [0-9]{1,2}:[0-9]{2} [AP]M into ' "$T/rout" || { cat "$T/rout"; fail "restore did not name the backup date in words"; }
[[ -f "$T/r/cabinet/HANDOFFS.md" && -f "$T/r/f" ]] || fail "restore did not rebuild the project around its workspace"
# The private pointers are ignored by the project's git, so not in the archive: rebuilding the roles brings them back.
"$T/r/cabinet/bin/roles.sh" >/dev/null
grep -q 'cabinet/CABINET.md' "$T/r/CLAUDE.local.md" && [[ -z "$(git -C "$T/r" status --porcelain)" ]] || fail "pointers not rebuilt after restore, or the project's git not clean"
[[ "$(git -C "$T/r" log -1 --format=%s)" == setup && "$(git -C "$T/r" branch --show-current)" == main ]] || fail "restored project history"
# Restored into a folder whose parent holds files of its own (like a home folder), the parent never becomes a repo.
mkdir -p "$T/busy"; echo mine > "$T/busy/README.md"
HOME="$T/bkhome" CABINET_BACKUP_PASSPHRASE=t "$I/cabinet/bin/restore.sh" "$(ls "$BK"/*.enc)" "$T/busy/cabinet" >/dev/null || fail "restore beside other files"
[[ ! -e "$T/busy/.git" && "$(cat "$T/busy/README.md")" == mine && -e "$T/busy/cabinet/recovered" ]] && ls -d "$T"/busy/cabinet/recovered/*/acme-app/repo/.git >/dev/null 2>&1 || fail "restore turned a folder with its own files into a repo"
  return 0   # a last "check && fail" line must not end the run
}

section "roles" "0"
s9() {
for r in chief-of-staff product-manager architect qa security design-lead finance; do
  [[ -f "$W/agents/$r.md" && -f "$W/.claude/agents/$r.md" ]] || fail "role $r not built"
  head -1 "$W/agents/$r.md" | grep -qx -- '---' || fail "role $r frontmatter not first"
done
printf 'Run the api with `bun test`.\n' > "$W/roles/qa.md"
printf -- '---\nname: growth\ndescription: Growth.\n---\n\nYou are growth.\n' > "$W/roles/growth.md"
sed -i '' 's/^CABINET_ROLES="\(.*\)"/CABINET_ROLES="\1 growth"/' "$W/cabinet.env"
sed -i '' 's/finance |/finance, growth |/' "$W/OPERATIONS.md"
"$W/bin/roles.sh" --check >/dev/null 2>&1 && fail "check missed stale roles"
"$W/bin/roles.sh" >/dev/null
grep -q '## Project notes' "$W/agents/qa.md" && grep -q 'bun test' "$W/agents/qa.md" || fail "project note not appended"
[[ -f "$W/.claude/agents/growth.md" ]] || fail "project-only role not built"
"$W/bin/roles.sh" --check || fail "check fails on fresh roles"
sed -i '' 's/ growth"/"/' "$W/cabinet.env"; "$W/bin/roles.sh" >/dev/null
[[ ! -f "$W/agents/growth.md" ]] || fail "dropped role not removed"
  return 0   # a last "check && fail" line must not end the run
}

section "handoffs" "0"
s10() {
cat >> "$W/HANDOFFS.md" <<'EOF'

### H-20260101-01: first
- From: architect -> To: qa
- Status: open (2026-01-01)
- Changed: x
- Needed: y
- Depends on: none

### H-20260101-02: second
- From: qa -> To: owner
- Status: done (2026-01-02, abc123)
- Changed: x
- Needed: y
- Depends on: none
EOF
"$W/bin/handoffs.sh" | grep -q 'H-20260101-01' || fail "open entry not listed"
"$W/bin/handoffs.sh" qa | grep -q 'first' || fail "entry for qa not printed"
"$W/bin/handoffs.sh" founder | grep -q 'second' && fail "done entry printed as open"
"$W/bin/handoffs.sh" --json | jq -e 'length == 1 and .[0].id == "H-20260101-01" and .[0].from == "architect" and .[0].to == "qa"
  and .[0].status == "open" and .[0].date == "2026-01-01" and .[0].age_days > 200 and .[0].title == "first" and (.[0] | has("text") | not)' >/dev/null || fail "handoffs --json"
"$W/bin/handoffs.sh" qa --json | jq -e '.[0].text | contains("- Needed: y")' >/dev/null && (cd "$W/specs" && "$F" handoffs owner --json) | jq -e 'length == 0' >/dev/null || fail "handoffs <name> --json"
git -C "$W" add -A && git -C "$W" commit -qm handoffs
"$W/bin/archive-handoffs.sh" | grep -q 'archived 1' || fail "archive did not move the done entry"
grep -q 'H-20260101-02' "$W/handoffs/archive-2026-01.md" || fail "archive file missing the entry"
# cabinet handoff: the next free ID for today across HANDOFFS.md and the archives, the template's
# lines, and a commit of only that entry; never someone else's uncommitted lines.
d="$(date +%Y%m%d)"
printf '\n### H-%s-07: archived today\n- From: qa -> To: api\n- Status: done (%s)\n' "$d" "$(date +%F)" >> "$W/handoffs/archive-2026-01.md"
git -C "$W" add -A && git -C "$W" commit -qm "archived today"
out="$(cd "$W/specs" && "$F" handoff --from architect --to "api, qa" --changed "GET /items: limit 50 -> 100" --needed "page by 100
in the client" "Raise the list limit")" || fail "handoff failed: $out"
[[ "$out" == "H-$d-08 filed for api, qa and committed" ]] || fail "handoff did not take the next free ID across the archives: $out"
git -C "$W" show --stat HEAD | grep -q "handoffs: H-$d-08 Raise the list limit" && [[ -z "$(git -C "$W" status --porcelain)" ]] || fail "handoff not committed alone"
"$W/bin/handoffs.sh" qa --json | jq -e --arg id "H-$d-08" '[.[] | select(.id == $id)][0] | .from == "architect" and .status == "open"
  and (.text | contains("- Needed: page by 100 in the client\n- Depends on: none"))' >/dev/null || fail "the filed handoff is not in the format the handoff tools read"
"$W/bin/handoffs.sh" | grep -q "H-$d-01" && fail "an ID was reused"
echo "- leftover line" >> "$W/HANDOFFS.md"
out="$("$W/bin/handoff.sh" --from qa --to architect --changed x --needed y "Second")"
[[ "$out" == "H-$d-09 filed for architect, not committed"* ]] && git -C "$W" log -1 --format=%s | grep -q "H-$d-08" || fail "handoff committed someone else's uncommitted lines"
"$W/bin/doctor.sh" 2>&1 | grep -q 'ok    every handoff ID is unique' || fail "handoff made a duplicate ID"
git -C "$W" checkout -q -- HANDOFFS.md
"$W/bin/handoff.sh" --from qa --to api "No details" >/dev/null 2>&1 && fail "a handoff without --changed and --needed was filed"
[[ -z "$(git -C "$W" status --porcelain)" ]] || fail "a refused handoff changed a file"
"$W/bin/handoff.sh" --from qa --to api --changed x --needed y "At once A" > "$T/ha" & "$W/bin/handoff.sh" --from qa --to api --changed x --needed y "At once B" > "$T/hb"; wait
[[ "$(cut -d' ' -f1 "$T/ha")" != "$(cut -d' ' -f1 "$T/hb")" ]] && grep -q committed "$T/ha" && grep -q committed "$T/hb" || fail "two handoffs filed at once: $(cat "$T/ha" "$T/hb")"
  return 0   # a last "check && fail" line must not end the run
}

section "update" "0"
s11() {
"$F" update "$W" >/dev/null || fail "clean update failed"
echo "# local edit" >> "$W/bin/handoffs.sh"
"$F" update "$W" >/dev/null 2>&1 && fail "update replaced an edited kit file"
grep -q '# local edit' "$W/bin/handoffs.sh" || fail "edited kit file was overwritten"
"$F" status "$W" | grep -q 'edited here: bin/handoffs.sh' || fail "status missed the edit"
git -C "$W" checkout -q -- bin/handoffs.sh
"$F" update "$W" >/dev/null || fail "update after restore failed"
  return 0   # a last "check && fail" line must not end the run
}

section "update to a newer kit shows its changelog" "0"
s12() {
K2="$T/kit2"; cp -R "$KIT" "$K2"; rm -rf "$K2/.git"
jq '.version = "0.1.1"' "$KIT/package.json" > "$K2/package.json"
{ echo "# Changelog"; echo; echo "## 0.1.1 - test"; echo; echo "- smoke change"; echo; tail -n +2 "$KIT/CHANGELOG.md"; } > "$K2/CHANGELOG.md"
echo "# 0.1.1" >> "$K2/core/CABINET.md"
out="$("$K2/bin/cabinet" update "$W")"
echo "$out" | grep -q 'What changed since 0.1.0' && echo "$out" | grep -q 'smoke change' || fail "update did not show the changelog"
echo "$out" | grep -q '^## 0.1.0' && fail "changelog showed the version already installed"
[[ "$(cat "$W/.cabinet/version")" == 0.1.1 ]] && tail -1 "$W/CABINET.md" | grep -q '0.1.1' || fail "newer kit not applied"
"$KIT/bin/cabinet" update "$W" >/dev/null || fail "could not go back to the current kit"
  return 0   # a last "check && fail" line must not end the run
}

section "installed as a package" "0 12"
s13() {
(cd "$T" && npm pack "$KIT" --silent >/dev/null) || fail "npm pack failed"
tgz="$(ls "$T"/tarekraafat-cabinet-*.tgz)"
tar -tzf "$tgz" | grep -q 'package/test/' && fail "tests shipped in the package"
(cd "$W" && npm install -D "$tgz" --no-audit --no-fund --silent) || fail "install from the package failed"
(cd "$W" && npx --no cabinet status) | grep -q 'no kit file edited' || fail "installed command does not work"
git -C "$W" status --porcelain | grep -q node_modules && fail "node_modules not ignored"
# A "global" newer kit run inside the workspace must defer to the pinned copy.
out="$(cd "$W" && "$K2/bin/cabinet" status)"
echo "$out" | grep -q "node_modules/@tarekraafat/cabinet: $(jq -r .version "$KIT/package.json")" || fail "global command did not defer to the pinned copy"
"$K2/bin/cabinet" version | grep -q 0.1.1 || fail "outside a workspace the global command should run itself"
  return 0   # a last "check && fail" line must not end the run
}

section "schedules follow jobs/ and cabinet.env" "0"
s14() {
# A scratch HOME and a fake launchctl: nothing reaches the real machine.
H="$T/home"; mkdir -p "$H/Library/LaunchAgents" "$T/shim"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/launchctl.log" > "$T/shim/launchctl"; chmod +x "$T/shim/launchctl"
boot() { HOME="$H" PATH="$T/shim:$PATH" "$W/bin/bootstrap.sh" "$@" 2>&1; }
LA="$H/Library/LaunchAgents"; P="$LA/ai.cabinet.demo-co"
touch "$LA/ai.cabinet.other.brief.plist"
boot >/dev/null
grep -q '<key>Hour</key><integer>7</integer>' "$P.brief.plist" || fail "brief not scheduled at 07:00"
[[ -z "$(boot | grep -E 'installed|updated|removed')" ]] || fail "a rerun with no change touched a schedule"
sed -i '' 's/^WHEN=.*/WHEN="08:15"/' "$W/jobs/brief.job"
boot | grep -q 'updated ai.cabinet.demo-co.brief' || fail "changed time not reported"
grep -q '<integer>8</integer><key>Minute</key><integer>15</integer>' "$P.brief.plist" || fail "changed time not applied"
sed -i '' "s|^CABINET_BACKUP_DIR=.*|CABINET_BACKUP_DIR=\"$T/bk\"|" "$W/cabinet.env"
boot >/dev/null; [[ -f "$P.backup.plist" ]] || fail "backup not scheduled"
sed -i '' 's|^CABINET_BACKUP_DIR=.*|CABINET_BACKUP_DIR=""|' "$W/cabinet.env"
sed -i '' 's/^WHEN=.*/WHEN=""/' "$W/jobs/brief.job"
boot --dry-run | grep -q 'would remove ai.cabinet.demo-co.brief' && [[ -f "$P.brief.plist" ]] || fail "dry run removed or did not report"
boot | grep -q 'removed ai.cabinet.demo-co.backup' || fail "backup off not removed"
[[ ! -e "$P.brief.plist" && ! -e "$P.backup.plist" ]] || fail "turned-off schedules left behind"
[[ -f "$LA/ai.cabinet.other.brief.plist" ]] || fail "another workspace's schedule was touched"
grep -q 'bootout gui/[0-9]*/ai.cabinet.demo-co.brief' "$T/launchctl.log" || fail "removed schedule not unloaded"
git -C "$W" checkout -q -- jobs/brief.job cabinet.env
  return 0   # a last "check && fail" line must not end the run
}

section "guardrails for Qwen Code and opencode" "14"
s15() {
mkdir -p "$H/.qwen" "$H/.config/opencode"
echo '{"ui":{"theme":"x"}}' > "$H/.qwen/settings.json"
# The worst case for "last match wins": an explicit allow and catch-alls that would override rules placed first.
echo '{"permission":{"bash":{"git push*":"allow","*":"allow"},"*":"ask"},"mcp":{"x":{"enabled":false}}}' > "$H/.config/opencode/opencode.json"
boot >/dev/null
kd="$(jq -c '.permissions.deny' "$KIT/guardrails/claude-permissions.json")"
jq -e --argjson d "$kd" '(($d - .permissions.deny) | length) == 0 and .ui.theme == "x"' "$H/.qwen/settings.json" >/dev/null || fail "Qwen rules not merged or settings lost"
oc="$H/.config/opencode/opencode.json"
jq -e '(.permission | keys_unsorted) == ["*","bash"] and (.permission.bash | keys_unsorted | first) == "*" and .permission.bash["git push*"] == "deny" and .mcp.x.enabled == false' "$oc" >/dev/null || fail "opencode rules not last, or settings lost"
jq -e --argjson n "$(jq '.permissions.deny + .permissions.ask | length' "$KIT/guardrails/claude-permissions.json")" '(.permission.bash | keys_unsorted | .[1:] | length) == $n' "$oc" >/dev/null || fail "opencode did not get every rule"
[[ -z "$(boot | grep -E 'added')" ]] || fail "a second run changed the guardrails again"
# opencode reads opencode.json and then opencode.jsonc: the rules go in the .json, the commented .jsonc is never rewritten.
rm "$oc"; printf '{ // my comment\n}\n' > "${oc}c"; cp "${oc}c" "$T/jsonc.before"
boot >/dev/null
cmp -s "${oc}c" "$T/jsonc.before" && jq -e '.permission.bash["git push*"] == "deny"' "$oc" >/dev/null || fail "rules not placed beside a commented opencode.jsonc"
# A config jq cannot read is never rewritten, and the merge says so instead of claiming success.
printf '{"a": 1,}\n' > "$H/.qwen/settings.json"
out="$(boot || true)"; echo "$out" | grep -q 'settings.json is not plain JSON, left as is' && ! echo "$out" | grep -q 'added .* rule(s) to .*qwen' || fail "an unreadable config was reported as merged"
[[ "$(cat "$H/.qwen/settings.json")" == '{"a": 1,}' && ! -e "$H/.qwen/settings.json.tmp" ]] || fail "an unreadable config was changed"
# Permissions and symlinks of a config survive the merge.
printf '{"k": 1}\n' > "$T/real-settings.json"; chmod 600 "$T/real-settings.json"; rm "$H/.qwen/settings.json"; ln -s "$T/real-settings.json" "$H/.qwen/settings.json"
boot >/dev/null
[[ -L "$H/.qwen/settings.json" && "$(stat -f %Lp "$T/real-settings.json")" == 600 ]] && jq -e '.k == 1 and (.permissions.deny | length > 0)' "$T/real-settings.json" >/dev/null || fail "merge lost a symlink or loosened permissions"
  return 0   # a last "check && fail" line must not end the run
}

section "custom runner" "0 14"
s16() {
cp "$W/cabinet.env" "$T/env.bak"
cat >> "$W/cabinet.env" <<'EOF'
CABINET_RUNNER="custom"
CABINET_RUNNER_CMD='printf "%s|%s" "$CABINET_AGENT" "$CABINET_PROMPT" > runner.out'
EOF
HOME="$H" "$W/bin/scheduled.sh" brief >/dev/null 2>&1 || fail "custom runner failed"
grep -q '^chief-of-staff|Act as the chief-of-staff role: read agents/chief-of-staff.md' "$W/runner.out" || fail "custom runner did not get the role and prompt"
rm -f "$W/runner.out"
# A run past its time limit is stopped with everything it started, and the log says why
# (CABINET_TEST_MINUTE makes a minute one second). A limit that is not a number never runs.
echo "CABINET_RUNNER_CMD='sleep 323; :'" >> "$W/cabinet.env"
cp "$W/jobs/brief.job" "$T/brief.bak"; sed -i '' 's/^TIMEOUT=.*/TIMEOUT="2"/' "$W/jobs/brief.job"
s=$SECONDS; st=0; HOME="$H" CABINET_TEST_MINUTE=1 "$W/bin/scheduled.sh" brief >/dev/null 2>&1 || st=$?
((st == 1 && SECONDS - s < 10)) || fail "a run past its limit was not stopped (exit $st after $((SECONDS - s))s)"
! pgrep -f 'sleep 323' >/dev/null || fail "a stopped run left what it started running"
grep -q "stopped after 2 min: the job's time limit" "$H/Library/Logs/cabinet/demo-co/brief.log" || fail "the log does not say why the run stopped"
# Stopping the job (launchd's stop, or Ctrl-C by hand) stops the agent too, though it runs in its own group.
HOME="$H" "$W/bin/scheduled.sh" brief >/dev/null 2>&1 & p=$!; sleep 1; kill -TERM "$p"; wait "$p" || true
! pgrep -f 'sleep 323' >/dev/null || fail "stopping the job left the agent running"
sed -i '' 's/^TIMEOUT=.*/TIMEOUT="08"/' "$W/jobs/brief.job"
st=0; HOME="$H" "$W/bin/scheduled.sh" brief >/dev/null 2>&1 || st=$?
((st == 2)) && ! pgrep -f 'sleep 323' >/dev/null || fail "a TIMEOUT that is not whole minutes was not refused"
cp "$T/brief.bak" "$W/jobs/brief.job"; cp "$T/env.bak" "$W/cabinet.env"
"$F" new "$T/c1" --yes --runner custom >/dev/null 2>&1 && fail "custom runner without a command accepted"
"$F" new "$T/c2" --yes --runner custom --runner-cmd 'mytool --run "$CABINET_PROMPT"' >/dev/null || fail "custom runner option"
grep -qx "CABINET_RUNNER_CMD='mytool --run \"\$CABINET_PROMPT\"'" "$T/c2/cabinet.env" || fail "runner command not written"
  return 0   # a last "check && fail" line must not end the run
}

section "config changes settings after setup" "14"
s17() {
C="$T/cfg"; "$F" new "$C" --name Acme --yes >/dev/null
cfg() { (cd "$C" && HOME="$H" PATH="$T/shim:$PATH" "$F" config "$@" 2>&1); }
HOME="$H" PATH="$T/shim:$PATH" "$C/bin/bootstrap.sh" >/dev/null 2>&1
[[ -f "$LA/ai.cabinet.cfg.brief.plist" ]] || fail "config test setup: no schedule"
out="$(cfg --yes --name "Acme Labs" --slug acme-labs --owner Ann --email ann@example.com --roles "qa security" \
  --brief 06:30 --week-start Monday --repo git@example.invalid:acme/api.git --apply)" || { echo "$out"; fail "config with options"; }
echo "$out" | grep -q 'api: clone failed (see above); everything else continues' || fail "a failed clone stopped the setup"
grep -qx 'CABINET_PROJECT="Acme Labs"' "$C/cabinet.env" && grep -qx 'CABINET_SLUG="acme-labs"' "$C/cabinet.env" || fail "name or slug not written"
grep -qx '# AGENTS.md - Acme Labs' "$C/AGENTS.md" && grep -qx '# Acme Labs operations manual' "$C/OPERATIONS.md" || fail "titles not renamed"
grep -q 'Authored as Ann <ann@example.com>\.' "$C/AGENTS.md" && grep -q 'Week starts on:\*\* Monday\.' "$C/AGENTS.md" || fail "owner or week not written"
grep -q '| finance |' "$C/AGENTS.md" "$C/OPERATIONS.md" && fail "a dropped role is still in a team table"
[[ "$(ls "$C/agents" | tr '\n' ' ')" == "chief-of-staff.md qa.md security.md " ]] || fail "roles not rebuilt"
grep -qx 'WHEN="6:30 AM"' "$C/jobs/brief.job" && grep -q $'^api\tgit@example.invalid:acme/api.git' "$C/repos.tsv" && grep -qF '| `api` |' "$C/AGENTS.md" || fail "brief or repo not written"
[[ ! -e "$LA/ai.cabinet.cfg.brief.plist" ]] && grep -q '<integer>6</integer><key>Minute</key><integer>30</integer>' "$LA/ai.cabinet.acme-labs.brief.plist" || fail "schedule not moved to the new slug"
grep -q 'ai.cabinet.acme-labs.brief' "$C/OPERATIONS.md" && ! grep -q 'ai\.cabinet\.cfg\.' "$C/OPERATIONS.md" || fail "manual still names the old slug"
cfg --yes --roles "qa security finance" >/dev/null
[[ "$(grep -c '| finance |' "$C/AGENTS.md")" == 1 && "$(grep -c '| finance |' "$C/OPERATIONS.md")" == 1 && -f "$C/agents/finance.md" ]] || fail "a returning role did not come back"
cfg --yes | grep -qx 'Nothing to change.' || fail "no-op config changed something"
cp "$C/cabinet.env" "$T/cfg.env"; cfg --yes --slug "Bad Slug" >/dev/null && fail "a bad slug was accepted"
cmp -s "$C/cabinet.env" "$T/cfg.env" || fail "a refused config wrote files"
# Name, slug, owner, email, 6 roles (all yes), runner, brief, week, backup, no repos, apply, no bootstrap.
printf '%s\n' "Acme Co" "" "" "" y y y y y y "" off "" off "" y n > "$T/answers"
(cd "$C" && HOME="$H" CABINET_TTY="$T/answers" "$F" config >/dev/null 2>&1) || fail "prompted config"
grep -qx 'CABINET_PROJECT="Acme Co"' "$C/cabinet.env" && grep -qx 'WHEN=""' "$C/jobs/brief.job" && grep -q 'design-lead' "$C/cabinet.env" || fail "prompted answers not written"
printf '<plist><string>%s/bin/scheduled.sh</string></plist>\n' "$(cd "$C" && pwd -P)" > "$LA/ai.cabinet.old-name.brief.plist"
HOME="$H" "$C/bin/doctor.sh" 2>&1 | grep -q 'ai.cabinet.old-name.brief still runs this workspace under an old name' || fail "doctor missed a leftover schedule"
  return 0   # a last "check && fail" line must not end the run
}

section "fixes from the pre-push review" "0 2 3 14 17"
s18() {
# A cloned project's package.json can never run code or add repo rows.
X="$T/evil"; mkrepo "$X"
printf '{"name":"Evil$(touch %s/PWNED)","repository":"https://x.example/a.git\\nevil\\thttps://evil.example/t.git\\t-\\tno\\t~/.local/bin"}\n' "$T" > "$X/package.json"
(cd "$X" && "$F" init --yes --beside) >/dev/null 2>&1 || fail "init on a hostile package.json failed outright"
[[ ! -e "$T/PWNED" ]] || fail "package.json name ran as code"
grep -qx 'CABINET_PROJECT="evil"' "$T/evil-hq/cabinet.env" || fail "unsafe name not replaced by the folder name"
! grep -q evil.example "$T/evil-hq/repos.tsv" || fail "package.json repository added a repo row"
"$F" new "$T/bad2" --name 'R$D Labs' --yes >/dev/null 2>&1 && fail "a name with \$ was accepted"
[[ ! -e "$T/bad2" ]] || fail "a refused setup left its folder behind"
# A slug another workspace uses is refused; --slug picks another.
mkdir -p "$H/Library/LaunchAgents"
printf '<plist><string>/elsewhere/taken/bin/scheduled.sh</string></plist>\n' > "$H/Library/LaunchAgents/ai.cabinet.taken.brief.plist"
HOME="$H" "$F" new "$T/taken" --yes >/dev/null 2>&1 && fail "a slug used by another workspace was accepted"
HOME="$H" "$F" new "$T/taken" --slug taken-2 --yes >/dev/null && grep -qx 'CABINET_SLUG="taken-2"' "$T/taken/cabinet.env" || fail "--slug"
# Bootstrap never takes over or removes another workspace's schedule.
cp "$H/Library/LaunchAgents/ai.cabinet.taken.brief.plist" "$T/taken.plist"
sed -i '' 's/^CABINET_SLUG=.*/CABINET_SLUG="taken"/' "$T/taken/cabinet.env"
out="$(HOME="$H" PATH="$T/shim:$PATH" "$T/taken/bin/bootstrap.sh" 2>&1 || true)"
echo "$out" | grep -q 'ai.cabinet.taken.brief already runs another workspace' && cmp -s "$T/taken.plist" "$H/Library/LaunchAgents/ai.cabinet.taken.brief.plist" || fail "bootstrap touched another workspace's schedule"
# The backup folder must be outside the workspace and its repos: setup, config and backup.sh all refuse.
"$F" new "$T/bk1" --backup-dir "$T/bk1/backups" --yes >/dev/null 2>&1 && fail "setup accepted a backup folder inside the workspace"
(cd "$I" && "$F" config --yes --backup-dir "$I/backups") >/dev/null 2>&1 && fail "config accepted a backup folder inside the project"
CABINET_BACKUP_PASSPHRASE=t "$I/cabinet/bin/backup.sh" "$I/backups" >/dev/null 2>&1 && fail "backup.sh wrote into the project"
[[ ! -e "$I/backups" ]] || fail "a refused backup created its folder"
(cd "$T" && "$F" new "$T/rel" --backup-dir relbk --yes >/dev/null) && grep -qx "CABINET_BACKUP_DIR=\"$(cd "$T" && pwd -P)/relbk\"" "$T/rel/cabinet.env" || fail "relative backup folder not made absolute"
# Cleanup keeps only this workspace's archives, never another's with a longer slug; keep 0 is refused.
"$F" new "$T/app" --yes >/dev/null; BD="$T/shared-bk"; mkdir -p "$BD"
touch "$BD/app-web-20260101-000000.tar.gz.enc" "$BD/app-web-20260102-000000.tar.gz.enc"
sed -i '' 's/^CABINET_BACKUP_KEEP=.*/CABINET_BACKUP_KEEP=1/' "$T/app/cabinet.env"
for i in 1 2; do CABINET_BACKUP_PASSPHRASE=t "$T/app/bin/backup.sh" "$BD" >/dev/null; sleep 1; done
[[ "$(ls "$BD" | grep -c '^app-web-')" == 2 && "$(ls "$BD" | grep -cE '^app-[0-9]{8}-[0-9]{6}\.tar\.gz\.enc$')" == 1 ]] || { ls "$BD"; fail "cleanup removed another workspace's archives, or kept too many"; }
sed -i '' 's/^CABINET_BACKUP_KEEP=.*/CABINET_BACKUP_KEEP=0/' "$T/app/cabinet.env"
CABINET_BACKUP_PASSPHRASE=t "$T/app/bin/backup.sh" "$BD" >/dev/null 2>&1 && fail "keep 0 was accepted"
sed -i '' 's/^CABINET_BACKUP_KEEP=.*/CABINET_BACKUP_KEEP=14/' "$T/app/cabinet.env"
# Restore never replaces a file without keeping a copy.
mkdir -p "$T/rr"; echo MINE > "$T/rr/AGENTS.md"
CABINET_BACKUP_PASSPHRASE=t "$T/app/bin/restore.sh" "$BD/$(ls "$BD" | grep -E '^app-[0-9]')" "$T/rr" >/dev/null || fail "restore into a folder with files"
[[ "$(cat "$T/rr/recovered/"*/workspace/AGENTS.md)" == MINE ]] && grep -q '^# AGENTS.md - app' "$T/rr/AGENTS.md" || fail "restore replaced a file without keeping a copy"
# A mistyped WHEN keeps the working schedule; an & in the path still gives a valid schedule.
A2="$T/R&D"; "$F" new "$A2" --slug rnd --yes >/dev/null
HOME="$H" PATH="$T/shim:$PATH" "$A2/bin/bootstrap.sh" >/dev/null 2>&1 || true
plutil -lint "$H/Library/LaunchAgents/ai.cabinet.rnd.brief.plist" >/dev/null || fail "a path with & gave an invalid schedule"
sed -i '' 's/^WHEN=.*/WHEN="7 oclock"/' "$A2/jobs/brief.job"
out="$(HOME="$H" PATH="$T/shim:$PATH" "$A2/bin/bootstrap.sh" 2>&1 || true)"
echo "$out" | grep -q "bad schedule '7 oclock'" && [[ -f "$H/Library/LaunchAgents/ai.cabinet.rnd.brief.plist" ]] || fail "a mistyped WHEN removed the working schedule"
# Scheduled jobs get a PATH with node's folder.
grep -qF "$(dirname "$(command -v node)")" "$H/Library/LaunchAgents/ai.cabinet.rnd.brief.plist" || fail "node's folder not on the scheduled PATH"
# The pass-through stub runs a repo's own pre-commit hook under the global hooks path.
HK="$T/hooks"; mkdir -p "$HK"; cp "$KIT/guardrails/hook-passthrough" "$HK/pre-commit"
mkrepo "$T/hooked"; printf '#!/bin/sh\ntouch "%s/own-hook-ran"\n' "$T" > "$T/hooked/.git/hooks/pre-commit"; chmod +x "$T/hooked/.git/hooks/pre-commit"
echo y > "$T/hooked/g"; git -C "$T/hooked" add g; git -C "$T/hooked" -c core.hooksPath="$HK" commit -qm g
[[ -f "$T/own-hook-ran" ]] || fail "a repo's own pre-commit hook did not run under the global hooks path"
# config keeps a project's own role and accepts a weekly brief.
printf -- '---\nname: growth\ndescription: Growth.\n---\n\nYou are growth.\n' > "$C/roles/growth.md"
(cd "$C" && "$F" config --yes --roles "qa security growth") >/dev/null || fail "config refused a project role"
(cd "$C" && "$F" config --yes --brief "Sun 8 AM") >/dev/null || fail "config refused a weekly brief"
grep -q 'growth' "$C/cabinet.env" && [[ -f "$C/agents/growth.md" ]] && grep -qx 'WHEN="sun 8:00 AM"' "$C/jobs/brief.job" || fail "project role dropped or weekly brief not written"
(cd "$C" && "$F" config --yes --name "Acme Co 2") >/dev/null || fail "config refused to run with a weekly brief"
# Handoffs without an ISO date still show in the overview.
printf '\n### H-20260101-09: undated\n- From: qa -> To: architect\n- Status: acknowledged (3 Oct 2026)\n' >> "$W/HANDOFFS.md"
"$W/bin/handoffs.sh" | grep -q '?d  acknowledged  H-20260101-09' || fail "an undated open handoff is hidden"
git -C "$W" checkout -q -- HANDOFFS.md
# With no git identity, setup does not commit as TBD.
env GIT_CONFIG_GLOBAL="$T/empty-config" "$F" new "$T/noid" --yes >/dev/null
! git -C "$T/noid" log >/dev/null 2>&1 || fail "committed without an owner identity"
# update names only paths that exist; doctor sees a hooks path set in the project around cabinet/.
(cd "$I" && "$F" update) | grep 'then commit' | grep -qv 'package-lock' || fail "update names a path that does not exist"
git -C "$I" config core.hooksPath .husky
"$I/cabinet/bin/doctor.sh" 2>&1 | grep -q "acme-app sets its own core.hooksPath (.husky)" || fail "doctor missed the project's own hooks path"
git -C "$I" config --unset core.hooksPath
# The guardrails close the known ways around the push gate and to credentials.
for r in 'Bash(*core.hooksPath*)' 'Bash(*GIT_CONFIG_*)' 'Bash(* --no-v*)' 'Bash(script *)' 'Bash(pnpm publish*)' 'Bash(yarn publish*)' 'Bash(gh auth token*)' 'Bash(security find-generic-password*)'; do
  jq -e --arg r "$r" '.permissions.deny | index($r)' "$KIT/guardrails/claude-permissions.json" >/dev/null || fail "missing guardrail $r"
done
  return 0   # a last "check && fail" line must not end the run
}

section "fixes from the second review" "0 2"
s19() {
boot2() { HOME="$1" PATH="$T/shim:$PATH" "$2/bin/bootstrap.sh" 2>&1 || true; }
# A merge that fails on a valid but unexpected config never empties it.
H2="$T/home2"; mkdir -p "$H2/.claude"
printf '{"model":"x","permissions":{"deny":"Bash(rm)"}}\n' > "$H2/.claude/settings.json"; cp "$H2/.claude/settings.json" "$T/odd.json"
out="$(boot2 "$H2" "$W")"
cmp -s "$H2/.claude/settings.json" "$T/odd.json" || { cat "$H2/.claude/settings.json"; fail "a failed merge changed or emptied the config"; }
echo "$out" | grep -q 'settings.json: the merge did not produce a valid file' || fail "a failed merge was not reported"
# init around a folder whose .gitignore covers kit paths still finishes and commits.
G2="$T/ignoring"; mkdir -p "$G2"; printf '.claude/\nagents/\n' > "$G2/.gitignore"
"$F" init "$G2" --yes >/dev/null 2>&1 || fail "init failed when the folder's .gitignore covers kit paths"
git -C "$G2" ls-files | grep -q '^agents/qa.md$' || fail "setup's own files were not committed"
# A fresh workspace lists no handoffs (the template's example is not one).
[[ "$("$G2/bin/handoffs.sh")" == "No open handoffs." ]] || fail "the handoff template is listed as an entry"
# A workspace reached through a symlink is the same workspace.
mkdir -p "$T/realdir"; ln -s "$T/realdir" "$T/linkdir"
"$F" new "$T/linkdir/sym" --yes >/dev/null
boot2 "$H2" "$T/linkdir/sym" >/dev/null
out="$(boot2 "$H2" "$T/realdir/sym")"
! echo "$out" | grep -q 'already runs another workspace' || fail "the same workspace through a symlink was treated as another"
# The slug is held from setup on, before any bootstrap; a removed workspace's slug says how to free it.
"$F" new "$T/first/dup" --yes >/dev/null
out="$("$F" new "$T/second/dup" --yes 2>&1)" && fail "a slug held by a workspace that never ran bootstrap was accepted"
echo "$out" | grep -q "already used by the workspace at" || fail "slug message"
rm -rf "$T/first/dup"
out="$("$F" new "$T/second/dup" --yes 2>&1)" && fail "a removed workspace's slug was silently reused"
echo "$out" | grep -q 'no longer exists. To free it' || fail "no cleanup steps for a removed workspace's slug"
# config with a project role keeps the manual check passing; it renames the workspace's package.json.
printf -- '---\nname: ops\ndescription: Ops.\n---\n\nYou are ops.\n' > "$G2/roles/ops.md"
(cd "$G2" && "$F" config --yes --roles "qa ops" --name "Ignoring Two" --slug ignoring-two) >/dev/null || fail "config with a project role"
"$G2/bin/doctor.sh" 2>&1 | grep -q 'ok    manual names every script, job and role' || fail "manual check after adding a project role"
jq -e '.name == "ignoring-two-workspace" and (.description | startswith("Ignoring Two "))' "$G2/package.json" >/dev/null || fail "workspace package.json not renamed"
# Restore keeps a differing untracked file, and never turns a folder with files of its own into a repo.
R2="$T/rest"; "$F" new "$R2" --yes >/dev/null; echo "draft v1" > "$R2/notes/draft.md"
mkrepo "$R2/api"; printf 'api\t-\t-\tno\n' >> "$R2/repos.tsv"; git -C "$R2" add repos.tsv; git -C "$R2" commit -qm repos
git -C "$R2/api" checkout -q --detach; echo d > "$R2/api/d"; git -C "$R2/api" add d; git -C "$R2/api" commit -qm detached-only
CABINET_BACKUP_PASSPHRASE=t "$R2/bin/backup.sh" "$T/bk2" >/dev/null || fail "backup for restore tests"
mkdir -p "$T/rr2/api"; echo "draft v2" > "$T/rr2/notes-draft.tmp"; mkdir -p "$T/rr2/notes"; mv "$T/rr2/notes-draft.tmp" "$T/rr2/notes/draft.md"; echo mine > "$T/rr2/api/own.txt"
CABINET_BACKUP_PASSPHRASE=t "$R2/bin/restore.sh" "$(ls "$T"/bk2/*.enc)" "$T/rr2" >/dev/null || fail "restore with existing files and a detached repo"
[[ "$(cat "$T/rr2/notes/draft.md")" == "draft v1" && "$(cat "$T/rr2/recovered/"*/workspace/notes/draft.md)" == "draft v2" ]] || fail "an untracked file was replaced without a copy"
[[ ! -e "$T/rr2/api/.git" && "$(cat "$T/rr2/api/own.txt")" == mine ]] || fail "a folder with files of its own was turned into a repo"
[[ -n "$(git -C "$T/rr2/recovered/"*/api/repo rev-parse HEAD)" ]] && ! git -C "$T/rr2/recovered/"*/api/repo symbolic-ref -q HEAD >/dev/null || fail "the detached repo was not restored detached into recovered/"
# A workspace with no commits is backed up as its files and restored.
env GIT_CONFIG_GLOBAL="$T/empty-config" "$F" new "$T/nocommit" --yes >/dev/null
CABINET_BACKUP_PASSPHRASE=t "$T/nocommit/bin/backup.sh" "$T/bk3" >/dev/null || fail "backup of a workspace with no commits"
CABINET_BACKUP_PASSPHRASE=t "$T/nocommit/bin/restore.sh" "$(ls "$T"/bk3/*.enc)" "$T/rr3" >/dev/null || fail "restore of a workspace with no commits"
[[ -f "$T/rr3/CABINET.md" && -f "$T/rr3/AGENTS.md" ]] || fail "a workspace with no commits was not in its backup"
# A relative clone URL in repos.tsv is cloned relative to the workspace.
mkrepo "$T/srcrepo"; "$F" new "$T/relws" --yes >/dev/null; printf 'src\t../srcrepo\t-\tno\n' >> "$T/relws/repos.tsv"
boot2 "$H2" "$T/relws" >/dev/null
[[ -e "$T/relws/src/.git" ]] || fail "a relative clone URL was not cloned"
  return 0   # a last "check && fail" line must not end the run
}

section "fixes from the third review" "19"
s20() {
# A slug change releases the old slug, and through a symlinked path still stops the old schedule.
mkdir -p "$T/real3"; ln -s "$T/real3" "$T/link3"
"$F" new "$T/link3/pk" --yes >/dev/null
boot2 "$H2" "$T/link3/pk" >/dev/null
(cd "$T/link3/pk" && HOME="$H2" PATH="$T/shim:$PATH" "$F" config --yes --slug pk2 --apply) >/dev/null 2>&1 || true
[[ ! -e "$H2/Library/LaunchAgents/ai.cabinet.pk.brief.plist" && -f "$H2/Library/LaunchAgents/ai.cabinet.pk2.brief.plist" ]] || fail "a slug change through a symlinked path left the old schedule"
HOME="$H2" "$F" new "$T/elsewhere3/pk" --yes >/dev/null 2>&1 || fail "the old slug was not released after a slug change"
# Relative repo URLs work in new and config, as in repos.tsv.
(cd "$T" && "$F" new "$T/relnew" --repo ../srcrepo --yes >/dev/null) || fail "a relative --repo was refused"
# A repos.tsv row with an unusable name is skipped with a message, not silently.
printf 'bad name\t-\t-\tno\n' >> "$T/relnew/repos.tsv"
"$T/relnew/bin/doctor.sh" 2>&1 | grep -q 'skipped the row named "bad name"' || fail "an unusable repos.tsv row was skipped without a message"
# The guardrails also deny pushing without hooks and dropping the environment.
for r in 'Bash(*send-pack*)' 'Bash(env -i*)' 'Bash(env -u*)'; do
  jq -e --arg r "$r" '.permissions.deny | index($r)' "$KIT/guardrails/claude-permissions.json" >/dev/null || fail "missing guardrail $r"
done
  return 0   # a last "check && fail" line must not end the run
}

section "Cursor" "0 19"
s21() {
# The Cursor CLI's rules merge into its config and keep the user's own settings.
H3="$T/home3"; mkdir -p "$H3/.cursor"
printf '{"version":1,"editor":{"vimMode":true},"permissions":{"allow":["Shell(ls)"],"deny":["Shell(rm)"]}}\n' > "$H3/.cursor/cli-config.json"
boot2 "$H3" "$W" >/dev/null
jq -e --slurpfile k "$KIT/guardrails/cursor-permissions.json" \
  '(($k[0].permissions.deny - .permissions.deny) | length) == 0 and .editor.vimMode == true and .permissions.allow == ["Shell(ls)"] and (.permissions.deny | index("Shell(rm)"))' \
  "$H3/.cursor/cli-config.json" >/dev/null || { cat "$H3/.cursor/cli-config.json"; fail "Cursor rules not merged, or the user's settings lost"; }
# The cursor runner calls the CLI in print mode, with the role as its first instruction.
CB="$T/cursorbin"; mkdir -p "$CB"
printf '#!/bin/sh\nprintf "%%s|" "$@" > "%s/cursor-args"\n' "$T" > "$CB/cursor-agent"; chmod +x "$CB/cursor-agent"
cp "$W/cabinet.env" "$T/env.bak2"; echo 'CABINET_RUNNER="cursor"' >> "$W/cabinet.env"
HOME="$H3" PATH="$CB:$PATH" "$W/bin/scheduled.sh" brief >/dev/null 2>&1 || fail "the cursor runner failed"
grep -q '^-p|--force|Act as the chief-of-staff role: read agents/chief-of-staff.md' "$T/cursor-args" || { cat "$T/cursor-args"; fail "the cursor runner did not call the CLI in print mode with the role"; }
cp "$T/env.bak2" "$W/cabinet.env"
# doctor checks the Cursor CLI's config, and a generic `agent` command is not taken for Cursor.
out="$(HOME="$H3" PATH="$CB:$PATH" "$W/bin/doctor.sh" 2>&1 || true)"
echo "$out" | grep -q 'ok    Cursor CLI config holds the deny rules' || fail "doctor did not check the Cursor CLI"
OB="$T/otheragent"; mkdir -p "$OB"; printf '#!/bin/sh\n' > "$OB/agent"; chmod +x "$OB/agent"
# Any real Cursor install on this machine is kept off the PATH for this check.
NOCURSOR="$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do [[ -x "$d/cursor-agent" ]] || [[ "$(readlink -f "$d/agent" 2>/dev/null)" == *[Cc]ursor* ]] || printf '%s:' "$d"; done)"
out="$(HOME="$T/home4" PATH="$OB:${NOCURSOR%:}" "$W/bin/doctor.sh" 2>&1 || true)"
! echo "$out" | grep -q 'Cursor CLI' || fail "a generic agent command was taken for the Cursor CLI"
"$F" new "$T/cur" --runner cursor --yes >/dev/null && grep -qx 'CABINET_RUNNER="cursor"' "$T/cur/cabinet.env" || fail "--runner cursor"
  return 0   # a last "check && fail" line must not end the run
}

section "doctor (kit checks only)" "0"
s22() {
out="$("$W/bin/doctor.sh" 2>&1 || true)"
echo "$out" | grep -q 'ok    kit files unedited' || fail "doctor: kit files"
echo "$out" | grep -q 'ok    roles built' || fail "doctor: roles"
echo "$out" | grep -q 'ok    manual names every script, job and role' || { echo "$out" | grep OPERATIONS; fail "doctor: manual"; }
echo "$out" | grep -q 'ok    every handoff ID is unique' || fail "doctor: handoff IDs"
  return 0   # a last "check && fail" line must not end the run
}

section "docs match the code" ""
s23() {
python3 -I "$KIT/test/docs_check.py" "$KIT" || fail "the docs fell behind the code (see above)"
python3 -I "$KIT/tools/build-llms-full.py" --check || fail "llms-full.txt is out of date (npm run docs)"
repo="$(jq -r .repository.url "$KIT/package.json" | sed 's/^git+//')"
grep -qF "git clone $repo " "$KIT/README.md" || fail "the README's clone command does not match the repository in package.json"
# The package installs only where the README says the kit runs: macOS, until Linux ships.
jq -e '.publishConfig.access == "public"' "$KIT/package.json" >/dev/null || fail "the scoped package would publish as private"
jq -e '.os == ["darwin"]' "$KIT/package.json" >/dev/null && grep -q '^- \*\*Platform:\*\* macOS\.' "$KIT/README.md" || fail "package.json os and the README's platform disagree"
for p in .DS_Store node_modules/ '*.tgz'; do grep -qxF "$p" "$KIT/.gitignore" || fail ".gitignore does not ignore $p"; done
  return 0   # a last "check && fail" line must not end the run
}

section "no project data in the kit" ""
s24() {
# No local paths anywhere; and, when set, none of the owner's private words
# (CABINET_PRIVATE_WORDS="word1 word2", kept out of this file so it names none).
! grep -rIln -e '/Users/[a-z]' -e '/home/[a-z]' "$KIT" --exclude-dir=.git --exclude-dir=node_modules --exclude=smoke.sh || fail "a local path in the kit"
for w in ${CABINET_PRIVATE_WORDS:-}; do
  ! grep -rIil -e "$w" "$KIT" --exclude-dir=.git --exclude-dir=node_modules --exclude=LICENSE --exclude=package.json || fail "a private word in the kit: $w"
done
  return 0   # a last "check && fail" line must not end the run
}


section "commands from anywhere in a workspace or its project" "0 3"
s25() {
mkdir -p "$W/specs/deep" "$I/src/deep" "$T/nowhere"
(cd "$W/specs/deep" && "$F" handoffs) >/dev/null || fail "handoffs from a workspace subfolder"
(cd "$I/src/deep" && "$F" doctor --json) | jq -e '.workspace | endswith("/acme-app/cabinet")' >/dev/null || fail "doctor from deep inside the project"
(cd "$I/src/deep" && "$F" status) | grep -q 'no kit file edited' || fail "status from deep inside the project"
out="$(cd "$T/nowhere" && "$F" doctor 2>&1)" && fail "doctor outside any workspace succeeded"
echo "$out" | grep -q 'not inside a cabinet workspace' || fail "unclear error outside a workspace: $out"
"$F" help | grep -q '^  next ' || fail "help"
rc=0; "$F" bogus >/dev/null 2>&1 || rc=$?; [[ $rc == 2 ]] || fail "an unknown command exits $rc, not 2"
  return 0   # a last "check && fail" line must not end the run
}

section "next" "0"
s26() {
before="$(git -C "$W" status --porcelain)"
out="$(cd "$W" && "$F" next)"
echo "$out" | grep -q '^Next in Demo Co' && echo "$out" | grep -q 'Fill the TBDs in AGENTS.md' && echo "$out" | grep -q 'cabinet bootstrap' || { echo "$out"; fail "next"; }
(cd "$T" && "$F" next) | grep -q 'Not inside a cabinet workspace' || fail "next outside a workspace"
(cd "$W/specs" && "$F" next --json) | jq -e '.project == "Demo Co" and ([.steps[].id] | index("tbd") and index("bootstrap")) and (.steps[] | select(.id == "bootstrap") | .command == "cabinet bootstrap")' >/dev/null || fail "next --json"
(cd "$T" && "$F" next --json) | jq -e '.workspace == null and .steps[0].id == "start"' >/dev/null || fail "next --json outside a workspace"
[[ "$(git -C "$W" status --porcelain)" == "$before" ]] || fail "next changed the workspace"
  return 0   # a last "check && fail" line must not end the run
}

section "doctor summary, json and fix" "0"
s27() {
rm "$W/agents/qa.md"
out="$(cd "$W" && "$F" doctor 2>&1)" && fail "doctor passed with a role missing"
echo "$out" | head -1 | grep -Eq '^[0-9]+ thing\(s\) need attention:' && echo "$out" | grep -q 'cabinet doctor --fix can run:.*roles' || { echo "$out"; fail "doctor summary"; }
(cd "$W" && "$F" doctor --json) | jq -e '.problems > 0 and (.can_fix | index("roles")) and (.results | length > 3)
  and all(.results[]; .id | test("^[a-z]+\\.[a-z-]+$")) and (.results[] | select(.id == "kit.roles") | .level == "fix")' >/dev/null || fail "doctor --json IDs"
(cd "$W" && "$F" doctor --fix 2>&1 </dev/null) | grep -q 'run it in a terminal, or add --yes' || fail "doctor --fix ran without asking"
(cd "$W" && "$F" doctor --fix --yes) >/dev/null 2>&1 || true
[[ -f "$W/agents/qa.md" ]] || fail "doctor --fix --yes did not rebuild the roles"
  return 0   # a last "check && fail" line must not end the run
}

section "remove" "2"
s28() {
"$F" new "$T/gone" --yes >/dev/null; G="$(cd "$T/gone" && pwd -P)"
mkdir -p "$HOME/Library/LaunchAgents"; echo "<string>$G/bin/scheduled.sh</string>" > "$HOME/Library/LaunchAgents/ai.cabinet.gone.brief.plist"
echo "<string>/elsewhere/bin/scheduled.sh</string>" > "$HOME/Library/LaunchAgents/ai.cabinet.gone.other.plist"
"$F" remove "$G" --dry-run | grep -q 'ai.cabinet.gone.brief.plist' && [[ -d "$G" ]] || fail "remove --dry-run"
"$F" remove "$G" --yes >/dev/null 2>&1 && fail "remove deleted commits that exist on no remote"
[[ -d "$G" ]] || fail "a refused remove deleted the workspace"
printf 'nope\n' > "$T/typed"; CABINET_TTY="$T/typed" "$F" remove "$G" --force >/dev/null 2>&1 && fail "remove went ahead with the wrong slug typed"
printf 'gone\n' > "$T/typed"; CABINET_TTY="$T/typed" "$F" remove "$G" --force >/dev/null || fail "remove"
[[ ! -e "$G" && ! -e "$HOME/Library/LaunchAgents/ai.cabinet.gone.brief.plist" && -e "$HOME/Library/LaunchAgents/ai.cabinet.gone.other.plist" ]] || fail "remove: folder, own schedule, or another's schedule"
rm "$HOME/Library/LaunchAgents/ai.cabinet.gone.other.plist"
# Inside a project, private: the project is left exactly as it was before init.
P="$T/rm-app"; mkrepo "$P"; echo '# rules' > "$P/AGENTS.md"; git -C "$P" add -A; git -C "$P" commit -qm rules
(cd "$P" && "$F" init --yes --inside) >/dev/null
(cd "$P/src" 2>/dev/null || cd "$P"; "$F" remove --yes --force) >/dev/null || fail "remove inside a project"
[[ ! -e "$P/cabinet" && ! -e "$P/CLAUDE.local.md" && ! -e "$P/QWEN.local.md" && ! -e "$P/.claude" ]] || { ls -a "$P"; fail "remove left setup's files in the project"; }
[[ "$(cat "$P/AGENTS.md")" == '# rules' && -z "$(git -C "$P" status --porcelain --ignored)" ]] || { git -C "$P" status --porcelain --ignored; fail "remove left the project changed"; }
! grep -q cabinet "$P/.git/info/exclude" || fail "remove left exclude lines"
  return 0   # a last "check && fail" line must not end the run
}

section "dry runs write nothing" "0"
s29() {
"$F" new "$T/dry" --yes --dry-run | grep -q 'Nothing was written' && [[ ! -e "$T/dry" ]] || fail "new --dry-run"
P="$T/dry-app"; mkdir -p "$P"; git -C "$P" init -q; (cd "$P" && "$F" init --yes --inside --dry-run) >/dev/null; [[ ! -e "$P/cabinet" && -z "$(git -C "$P" status --porcelain)" ]] || fail "init --dry-run"
before="$(cat "$W/cabinet.env")"; st="$(git -C "$W" status --porcelain)"
(cd "$W" && "$F" config --yes --runner codex --dry-run) | grep -q 'dry run: nothing written' || fail "config --dry-run output"
[[ "$(cat "$W/cabinet.env")" == "$before" && "$(git -C "$W" status --porcelain)" == "$st" ]] || fail "config --dry-run wrote"
  return 0   # a last "check && fail" line must not end the run
}

section "completion, outdated and status --json" "0"
s30() {
bash -c 'eval "$("$1" completion bash)" && type _cabinet' _ "$F" >/dev/null || fail "bash completion"
mkdir -p "$T/zdot"; ZDOTDIR="$T/zdot" zsh -c 'eval "$("$1" completion zsh)" && type _cabinet' _ "$F" >/dev/null 2>&1 || fail "zsh completion (a zsh without compinit in its .zshrc)"
mkdir -p "$W/specs/deep"; printf 'WHEN=""\n' > "$W/jobs/weekly-review.job"
jobs="$(cd "$W/specs/deep" && bash -c 'eval "$("$1" completion bash)"; COMP_WORDS=(cabinet run ""); COMP_CWORD=2; _cabinet; echo "${COMPREPLY[*]}"' _ "$F")"
[[ " $jobs " == *" brief "* && " $jobs " == *" weekly-review "* ]] || fail "completion of job names for cabinet run: $jobs"
rm "$W/jobs/weekly-review.job"
mkdir -p "$T/npmshim"; printf '#!/bin/sh\necho 9.9.9\n' > "$T/npmshim/npm"; chmod +x "$T/npmshim/npm"
PATH="$T/npmshim:$PATH" "$F" outdated "$W" | grep -q 'latest: cabinet 9.9.9' || fail "outdated"
printf '#!/bin/sh\nexit 1\n' > "$T/npmshim/npm"; PATH="$T/npmshim:$PATH" "$F" outdated "$W" | grep -q 'latest: unknown' || fail "outdated offline"
"$F" status "$W" --json | jq -e '.version == .kit_version and (.edited | length == 0)' >/dev/null || fail "status --json"
  return 0   # a last "check && fail" line must not end the run
}


section "help, --help and help --json come from one command table" ""
s31() {
mkdir -p "$T/plain"
(cd "$T/plain" && "$F" doctor --help) | grep -q -- '--fix' || fail "doctor --help outside a workspace"
"$F" remove -h | grep -q '^Usage: cabinet remove \[dir\] \[options\]' || fail "remove -h"
"$F" help config | grep -q -- '--backup-time <time>' || fail "help <command>"
"$F" help --json | jq -e '.name == "cabinet" and (.commands | length > 20) and (.commands | map(.name) | index("remove"))' >/dev/null || fail "help --json"
"$F" help remove --json | jq -e '.commands | length == 1 and (.[0].options | map(.name) | index("--force"))' >/dev/null || fail "help <command> --json"
"$F" help nope >/dev/null 2>&1 && fail "help for an unknown command succeeded"
# Completion offers the table's options for each command.
w="$(bash -c 'eval "$("$1" completion bash)"; COMP_WORDS=(cabinet remove --d); COMP_CWORD=2; _cabinet; echo "${COMPREPLY[*]}"' _ "$F")"
[[ " $w " == *" --delete-key "* && " $w " == *" --dry-run "* ]] || fail "completion of options from the table: $w"
  return 0   # a last "check && fail" line must not end the run
}


section "a teammate's Mac: no schedules, its own backups" "2"
s32() {
P="$T/team-app"; mkrepo "$P"; echo '{"name":"team-app"}' > "$P/package.json"; git -C "$P" add -A; git -C "$P" commit -qm pkg
(cd "$P" && "$F" init --yes --inside --shared) >/dev/null; git -C "$P" add -A; git -C "$P" commit -qm cabinet
LA="$HOME/Library/LaunchAgents/ai.cabinet.team-app.brief.plist"; mkdir -p "$P/src"
(cd "$P/src" && "$F" bootstrap) >/dev/null 2>&1; [[ -f "$LA" ]] || fail "bootstrap did not schedule the brief"
(cd "$P/src" && "$F" bootstrap --no-schedules) >/dev/null 2>&1 || true
[[ ! -f "$LA" ]] && grep -qx 'CABINET_SCHEDULES="off"' "$P/cabinet/cabinet.local.env" || fail "--no-schedules"
[[ -z "$(git -C "$P" status --porcelain --untracked-files=all)" ]] || { git -C "$P" status --porcelain; fail "cabinet.local.env shows in the project's git"; }
(cd "$P" && "$F" bootstrap) >/dev/null 2>&1 || true; [[ ! -f "$LA" ]] || fail "a plain bootstrap forgot --no-schedules"
(cd "$P" && "$F" doctor --json) | jq -e '([.results[] | select(.id == "schedules.off")] | length == 1) and ([.results[] | select(.id == "schedules.job")] | length == 0)' >/dev/null || fail "doctor with schedules off"
(cd "$P" && "$F" next --json) | jq -e '[.steps[].id] | index("bootstrap") | not' >/dev/null || fail "next asks for bootstrap on a Mac that schedules nothing"
(cd "$P" && "$F" bootstrap --schedules) >/dev/null 2>&1 || true
[[ -f "$LA" && ! -e "$P/cabinet/cabinet.local.env" ]] || fail "--schedules"
rc=0; (cd "$P" && "$F" bootstrap --nope) >/dev/null 2>&1 || rc=$?; [[ $rc == 2 ]] || fail "bootstrap with an unknown option exits $rc, not 2"
# Backups for this Mac only: cabinet.local.env, never cabinet.env, never in git.
BL="$HOME/Library/LaunchAgents/ai.cabinet.team-app.backup.plist"
(cd "$P/src" && "$F" config --this-mac --backup-dir "$T/team-bk" --apply) >/dev/null 2>&1 || true
grep -q '^CABINET_BACKUP_DIR=".*/team-bk"$' "$P/cabinet/cabinet.local.env" && grep -qx 'CABINET_BACKUP_DIR=""' "$P/cabinet/cabinet.env" || fail "--this-mac --backup-dir"
[[ -f "$BL" ]] && grep -q 'team-bk' "$BL" || fail "--this-mac --apply did not schedule this Mac's backup"
[[ -z "$(git -C "$P" status --porcelain --untracked-files=all)" ]] || { git -C "$P" status --porcelain; fail "a per-Mac backup setting shows in git"; }
(cd "$P" && "$F" config --this-mac --name Other) >/dev/null 2>&1 && fail "--this-mac changed a shared setting"
(cd "$P" && "$F" config --this-mac --backup-dir "$P/cabinet/bk") >/dev/null 2>&1 && fail "--this-mac accepted a backup folder inside the workspace"
(cd "$P" && "$F" config --yes --dry-run --backup-dir "$T/shared-bk") | grep -q 'this Mac keeps its own folder' || fail "config did not say this Mac keeps its own folder"
(cd "$P" && "$F" config --this-mac --backup-dir off --apply) >/dev/null 2>&1 || true
[[ ! -f "$BL" ]] || fail "--this-mac --backup-dir off kept the backup schedule"
(cd "$P" && "$F" doctor --json) | jq -e '.results[] | select(.id == "backups.enabled") | .message | contains("on this Mac")' >/dev/null || fail "doctor with backups off on this Mac"
(cd "$P" && "$F" config --this-mac --clear) >/dev/null 2>&1 || true
[[ ! -e "$P/cabinet/cabinet.local.env" ]] || { cat "$P/cabinet/cabinet.local.env"; fail "--clear left backup lines"; }
(cd "$P" && "$F" config --this-mac --clear) | grep -q 'already follows cabinet.env' || fail "a second --clear"
  return 0   # a last "check && fail" line must not end the run
}


section "guides: the project's own standing documents" "0"
s33() {
git -C "$W" ls-files --error-unmatch guides/README.md >/dev/null 2>&1 || fail "guides/ is not placed and tracked"
grep -q '^## Guides$' "$W/AGENTS.md" && grep -q 'Guides' "$W/CABINET.md" || fail "the Guides table or its rule is missing"
(cd "$W" && "$F" doctor --json) | jq -e '[.results[] | select(.section == "Guides")] == [{"level": "ok", "section": "Guides", "id": "guides.listed", "message": "every guide is listed in AGENTS.md"}]' >/dev/null || fail "doctor flags a fresh workspace's guides"
mkdir -p "$W/guides/legal"; echo "Voice: plain." > "$W/guides/brand.md"; echo terms > "$W/guides/legal/terms.md"
[[ -n "$(git -C "$W" status --porcelain -- guides/brand.md)" ]] || fail "a new guide is not seen by git"
j="$(cd "$W" && "$F" doctor --json || true)"
jq -e '[.results[] | select(.id == "guides.listed" and .level == "fix") | .message] | length == 2' <<<"$j" >/dev/null || fail "doctor missed an unlisted guide"
perl -i -pe 's/^\| none yet \|.*\n/| `guides\/brand.md` | voice | every agent |\n| `guides\/legal\/terms.md` | terms | qa |\n| `guides\/gone.md` | old | qa |\n/' "$W/AGENTS.md"
j="$(cd "$W" && "$F" doctor --json || true)"
jq -e '([.results[] | select(.id == "guides.listed" and .level == "fix")] | length == 0) and ([.results[] | select(.id == "guides.exists") | .message] == ["AGENTS.md lists guides/gone.md, which does not exist"])' <<<"$j" >/dev/null || { jq -c '.results[] | select(.section == "Guides")' <<<"$j"; fail "doctor on listed and missing guides"; }
perl -i -ne 'print unless /guides\/gone\.md/' "$W/AGENTS.md"; rm -rf "$W/guides/brand.md" "$W/guides/legal"
perl -i -pe 's/^\| `guides\/brand.md` \|.*\n/| none yet | x | |\n/; $_ = "" if /guides\/legal/' "$W/AGENTS.md"
  return 0   # a last "check && fail" line must not end the run
}


section "list every workspace on this Mac" "0"
s34() {
"$F" new "$T/listed-old" --yes >/dev/null; echo 0.0.1 > "$T/listed-old/.cabinet/version"
"$F" new "$T/listed-gone" --yes >/dev/null; rm -rf "$T/listed-gone"
mkdir -p "$T/away"; out="$(cd "$T/away" && "$F" list)"
echo "$out" | grep -Eq '^  demo-co +Demo Co +[0-9.]+ ' || { echo "$out"; fail "list: the workspace row"; }
echo "$out" | grep -Eq '^  listed-old +listed-old +0\.0\.1\* ' && echo "$out" | grep -q '^\* not the installed kit' || { echo "$out"; fail "list: an older kit"; }
echo "$out" | grep -Eq '^  listed-gone +- .*folder gone' && echo "$out" | grep -q 'Folder gone for listed-gone: .*rm -r ~/Library/Logs/cabinet/listed-gone' || { echo "$out"; fail "list: a deleted workspace"; }
j="$(cd "$T/away" && "$F" list --json)"
jq -e 'map(select(.slug == "demo-co"))[0] | .project == "Demo Co" and .exists and (.doctor_problems | type == "number") and (.waiting_on_owner | type == "number")' <<<"$j" >/dev/null || fail "list --json: a workspace"
jq -e '(map(select(.slug == "listed-gone"))[0] | .exists == false and .doctor_problems == null) and (map(select(.slug == "listed-old"))[0].update_available)' <<<"$j" >/dev/null || fail "list --json: gone and older"
(cd "$T/away" && "$F" next) | grep -q 'cabinet list shows them' || fail "next outside a workspace does not point at list"
rm -rf "$HOME/Library/Logs/cabinet/listed-gone"; "$F" remove "$T/listed-old" --yes --force >/dev/null
"$F" list --json | jq -e 'map(.slug) | (index("listed-old") or index("listed-gone")) | not' >/dev/null || fail "a removed workspace is still listed"
  return 0   # a last "check && fail" line must not end the run
}


section "digest gathers every sign-off queue" "0"
s35() {
"$F" new "$T/dg-a" --name "Digest A" --yes >/dev/null; "$F" new "$T/dg-b" --yes >/dev/null; "$F" new "$T/dg-c" --yes >/dev/null
printf '# Brief\n\n## Sign-off queue\n\n1. **Publish the page?** A. now. B. later.\n\n2. **Spend $20?**\n\n## Verification\n\nNone.\n\n## Actions for the owner\n\n- Push api main (abc1234).\n\n## Per agent queue\n\nqa: 1\n' > "$T/dg-a/BRIEF.md"
printf '# Brief\n\nNo headings here.\n' > "$T/dg-b/BRIEF.md"; touch -t 202001010700 "$T/dg-b/BRIEF.md"
out="$(cd "$T" && "$F" digest)"
echo "$out" | grep -q '^== Digest A' && echo "$out" | grep -q '^  1\. \*\*Publish the page?\*\*' && echo "$out" | grep -q '^  2\. \*\*Spend \$20?\*\*' || { echo "$out"; fail "digest: the queue"; }
echo "$out" | grep -q '^  - Push api main' && ! echo "$out" | grep -q 'qa: 1' && ! echo "$out" | grep -q '^  None\.' || { echo "$out"; fail "digest: only the queue and the actions"; }
echo "$out" | grep -q 'Older than a day and a half' && echo "$out" | grep -q 'no "## Sign-off queue" heading' && echo "$out" | grep -q 'No brief yet. Write one: cd .*dg-c && cabinet brief' || { echo "$out"; fail "digest: stale, headless or missing briefs"; }
! echo "$out" | grep -q ' $' || fail "digest prints trailing spaces"
j="$("$F" digest --json)"
jq -e 'map(select(.slug == "dg-a"))[0] | .project == "Digest A" and (.sign_off_queue | startswith("1. **Publish") and contains("2. **Spend")) and .actions_for_owner == "- Push api main (abc1234)." and .brief_stale == false' <<<"$j" >/dev/null || fail "digest --json: a full brief"
jq -e '(map(select(.slug == "dg-b"))[0] | .brief_stale and .queue_heading_found == false) and (map(select(.slug == "dg-c"))[0] | .brief_written == null and .queue_heading_found == null)' <<<"$j" >/dev/null || fail "digest --json: stale and missing"
grep -q '^Write `BRIEF.md` in this order, short, each part under a `## ` heading' "$KIT/roles/chief-of-staff.md" || fail "the brief headings rule left the chief-of-staff role"
# Written to a file, with a notification (a fake osascript that only logs), and on a schedule.
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/osascript.log" > "$T/shim/osascript"; chmod +x "$T/shim/osascript"
"$F" digest --write "$T/dg/out.md" --notify >/dev/null || fail "digest --write"
head -1 "$T/dg/out.md" | grep -Eq '^# cabinet digest, [0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}, ' && grep -q '^  1\. \*\*Publish the page?\*\*' "$T/dg/out.md" || fail "the written digest"
grep -Eq '[0-9]+ decision\(s\), [0-9]+ action\(s\) and [0-9]+ handoff\(s\) wait on you in [0-9]+ of [0-9]+ project\(s\)\. [0-9]+ brief\(s\) late' "$T/dg/out.md" || { head -3 "$T/dg/out.md"; fail "the digest's counts line"; }
grep -q 'wait on you in' "$T/osascript.log" && grep -q "Open .*/dg/out.md" "$T/osascript.log" || { cat "$T/osascript.log"; fail "the notification"; }
PL="$HOME/Library/LaunchAgents/ai.cabinet-digest.plist"
"$F" digest --schedule "Sun,mon 8:30 AM" --notify >/dev/null || fail "digest --schedule on days"
plutil -lint -s "$PL" && [[ "$(plutil -extract StartCalendarInterval json -o - "$PL" | jq -c '[.[] | [.Weekday, .Hour, .Minute]]')" == '[[0,8,30],[1,8,30]]' ]] || fail "the digest schedule's days and time"
plutil -extract ProgramArguments json -o - "$PL" | jq -e '.[1:3] == ["digest", "--write"] and (.[3] | endswith("/Library/Logs/cabinet/digest.md")) and .[4] == "--notify"' >/dev/null || fail "the digest schedule's command"
"$F" digest --schedule "7:15 am" --file "$T/dg/sched.md" >/dev/null || fail "digest --schedule daily"
[[ "$(plutil -extract StartCalendarInterval json -o - "$PL" | jq -c '.')" == '[{"Hour":7,"Minute":15}]' ]] && plutil -extract ProgramArguments json -o - "$PL" | jq -e '.[-1] | endswith("/dg/sched.md")' >/dev/null || fail "changing the digest schedule"
"$F" digest | grep -q '^Scheduled, every day at 7:15 AM: cabinet digest --write .*sched.md' || fail "digest does not say it is scheduled"
"$F" digest --schedule --notify >/dev/null || fail "digest --schedule with no time"
[[ "$(plutil -extract StartCalendarInterval json -o - "$PL" | jq -c '.')" == '[{"Hour":10,"Minute":0}]' ]] && plutil -extract ProgramArguments json -o - "$PL" | jq -e '.[-1] == "--notify"' >/dev/null || fail "the default digest schedule is not every day at 10:00 AM"
"$F" digest --schedule >/dev/null && [[ "$(plutil -extract CabinetWhen raw "$PL")" == "10:00 AM" ]] || fail "digest --schedule as the last argument"
for bad in 25:00 "fun 08:00" "mon"; do "$F" digest --schedule "$bad" >/dev/null 2>&1 && fail "digest accepted the schedule '$bad'"; done
"$F" digest --file x.md >/dev/null 2>&1 && fail "--file without --schedule was accepted"
"$F" digest --schedule off | grep -q 'Stopped the scheduled digest' && [[ ! -f "$PL" ]] || fail "digest --schedule off"
"$F" digest | grep -q '^Not scheduled' || fail "digest after the schedule stopped"
for x in dg-a dg-b dg-c; do "$F" remove "$T/$x" --yes --force >/dev/null; done
  return 0   # a last "check && fail" line must not end the run
}


section "schedule times: 12-hour, days by name, one or several" "0 1 14"
s36() {
# The parser itself.
r="$(/bin/bash -c 'source "$1"; for w in "7 AM" "7:05pm" "daily 7 a.m." "Friday 4 PM" "fri,SAT 10:30 am" "sun, mon ,tue 9:30 AM" "sun,mon,tue,wed,thu,fri,sat 8 am" "12 am" "12:15 PM" "16:00" "07:00"; do printf "%s|" "$(when_norm "$w")"; done; for w in "funday 10 AM" "mon" "10" "13 PM" "0 am" "24:00" "fri 7:60 pm" "fri,,sat 10 AM" "fri am"; do when_norm "$w" >/dev/null && printf "ACCEPTED %s|" "$w"; done; printf "%s" "$(when_human "fri,sat 16:00")"' _ "$KIT/scripts/when.sh")"
[[ "$r" == "7:00 AM|7:05 PM|7:00 AM|fri 4:00 PM|fri,sat 10:30 AM|sun,mon,tue 9:30 AM|8:00 AM|12:00 AM|12:15 PM|4:00 PM|7:00 AM|Fri, Sat at 4:00 PM" ]] || fail "when_norm: $r"
# The backup time takes a time and no day.
(cd "$O" && "$F" config --yes --backup-time "2:30 pm") >/dev/null && grep -qx 'CABINET_BACKUP_TIME="2:30 PM"' "$O/cabinet.env" || fail "--backup-time in 12-hour form"
(cd "$O" && "$F" config --yes --backup-time "fri 2 PM") >/dev/null 2>&1 && fail "a backup time with a day was accepted"
(cd "$O" && "$F" config --yes --backup-time "1 PM") >/dev/null
# The brief, through config and bootstrap; the doctor agrees.
(cd "$W" && "$F" config --yes --brief "Friday,saturday 9 am") >/dev/null || fail "config --brief with day names"
grep -qx 'WHEN="fri,sat 9:00 AM"' "$W/jobs/brief.job" || { grep WHEN "$W/jobs/brief.job"; fail "the brief time is not stored in its short form"; }
"$W/bin/bootstrap.sh" >/dev/null 2>&1 || true
PB="$HOME/Library/LaunchAgents/ai.cabinet.demo-co.brief.plist"
[[ "$(plutil -extract StartCalendarInterval json -o - "$PB" | jq -c '[.[] | [.Weekday, .Hour, .Minute]]')" == '[[5,9,0],[6,9,0]]' ]] || fail "the brief schedule on Friday and Saturday"
(cd "$W" && "$F" doctor --json || true) | jq -e '.results[] | select(.id == "schedules.job" and (.message | contains("brief"))) | .level == "ok" and (.message | contains("Fri, Sat at 9:00 AM"))' >/dev/null || fail "doctor on a two-day brief"
(cd "$W" && "$F" config --yes --brief "funday 9:00") >/dev/null 2>&1 && fail "config accepted an unknown day"
# A job written by hand, with a full day name and a one-digit hour.
printf 'AGENT=qa\nWHEN="Saturday 7:30 PM"\nPROMPT="x"\n' > "$W/jobs/sat.job"
"$W/bin/bootstrap.sh" >/dev/null 2>&1 || true
[[ "$(plutil -extract StartCalendarInterval json -o - "$HOME/Library/LaunchAgents/ai.cabinet.demo-co.sat.plist" | jq -c '.')" == '[{"Weekday":6,"Hour":19,"Minute":30}]' ]] || fail "a hand-written job with a full day name"
rm "$W/jobs/sat.job"; (cd "$W" && "$F" config --yes --brief "7 AM") >/dev/null; "$W/bin/bootstrap.sh" >/dev/null 2>&1 || true
[[ "$(plutil -extract StartCalendarInterval json -o - "$PB" | jq -c '.')" == '[{"Hour":7,"Minute":0}]' && ! -e "$HOME/Library/LaunchAgents/ai.cabinet.demo-co.sat.plist" ]] || fail "back to every day"
# The digest takes the same forms.
"$F" digest --schedule "Saturday 10 AM" | grep -q 'Scheduled the digest, Sat at 10:00 AM' || fail "digest --schedule with a full day name"
[[ "$(plutil -extract StartCalendarInterval json -o - "$HOME/Library/LaunchAgents/ai.cabinet-digest.plist" | jq -c '.')" == '[{"Weekday":6,"Hour":10,"Minute":0}]' ]] || fail "the digest on Saturdays"
"$F" digest --schedule off >/dev/null
  return 0   # a last "check && fail" line must not end the run
}

section "secrets: caught before a commit, a marked false alarm passes" "0 5 14"
s37() {
# Fake values are built from pieces, so no key-shaped text is ever in the kit itself.
"$W/bin/secrets.sh" >/dev/null 2>&1 || fail "a fresh workspace has a false alarm: $("$W/bin/secrets.sh" 2>&1)"
grep -q 'bin/secrets.sh --staged' "$W/.git/hooks/pre-commit" && [[ -x "$W/.git/hooks/pre-commit" ]] || fail "bootstrap did not place the secrets hook"
key="AKIA""QWERTYUIOPASDFGH"
printf '# Keys\n\nThe deploy key: %s\n' "$key" > "$W/guides/keys.md"
git -C "$W" add guides/keys.md
out="$(git -C "$W" commit -qm "keys" 2>&1)" && fail "a commit with a key in a guide was not refused"
echo "$out" | grep -q 'guides/keys.md:3: an AWS access key' && ! echo "$out" | grep -q "$key" || fail "the refusal does not name the file and line, or shows the key: $out"
out="$("$W/bin/doctor.sh" 2>&1 || true)"   # cabinet secrets and the doctor see it before it is staged, too
echo "$out" | grep -q "FIX   possible secrets in the workspace's files.*guides/keys.md:3: an AWS access key" && ! echo "$out" | grep -q "$key" || fail "the doctor missed the key, or showed it"
(cd "$W/specs" && "$F" secrets >/dev/null 2>&1) && fail "cabinet secrets missed the key"
printf 'DB_PASSWORD=%s\n' "hunter2""hunter2" >> "$W/guides/keys.md"; git -C "$W" add guides/keys.md
git -C "$W" commit -qm "keys" >/dev/null 2>&1 && fail "a commit setting a password was refused only for the key"
sed -i '' 's/$/ not-a-secret/' "$W/guides/keys.md"; git -C "$W" add guides/keys.md
git -C "$W" commit -qm "a marked false alarm" >/dev/null 2>&1 || fail "a marked false alarm was refused"
"$W/bin/secrets.sh" >/dev/null 2>&1 || fail "a marked false alarm is still reported"
git -C "$W" rm -q guides/keys.md && git -C "$W" commit -qm "drop keys" || fail "cleanup"
# A shared cabinet/ is committed with the project: no hook of its own, its files still scanned.
"$S/cabinet/bin/doctor.sh" 2>&1 | grep -q 'ok    the workspace is committed with the project, whose own hooks run' || fail "shared layout: secrets hook check"
[[ ! -e "$S/.git/hooks/pre-commit" ]] || fail "a hook was placed in the project's own git"
  return 0   # a last "check && fail" line must not end the run
}


# Which sections to run: the matches, then everything they need, in suite order.
_want=()
if (($#)); then
  for ((_i = 0; _i < ${#_names[@]}; _i++)); do
    for _w in "$@"; do [[ "$(printf %s "${_names[$_i]}" | tr '[:upper:]' '[:lower:]')" == *"$(printf %s "$_w" | tr '[:upper:]' '[:lower:]')"* ]] && _want[$_i]=1; done
  done
  ((${#_want[@]})) || fail "no section matches: $* (sections: $(printf '%s; ' "${_names[@]}"))"
  _changed=1
  while ((_changed)); do
    _changed=0
    for _i in "${!_want[@]}"; do for _d in ${_needs[$_i]}; do [[ -n "${_want[$_d]:-}" ]] || { _want[$_d]=1; _changed=1; }; done; done
  done
else
  for ((_i = 0; _i < ${#_names[@]}; _i++)); do _want[$_i]=1; done
fi
for ((_i = 0; _i < ${#_names[@]}; _i++)); do
  [[ -n "${_want[$_i]:-}" ]] || continue
  echo "== ${_names[$_i]}"
  "s$_i"
done
echo "PASS"
