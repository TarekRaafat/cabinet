#!/usr/bin/env bash
# End-to-end check of the kit in a throwaway folder: every command and layout,
# roles, handoffs, schedules, guardrail merges, backups and restores, and the
# fixes from reviews. Touches nothing outside the temp folder: HOME and git's
# global config point inside it, and the schedulers (launchctl, systemctl, crontab), the
# passphrase stores and notifications are fakes that only log.
#
#   test/smoke.sh
# No pipefail: "cmd | grep -q" checks would fail at random when grep exits early.
set -eu
# A syntax error further down would end the run through the EXIT trap, with success.
bash -n "$0" || { echo "FAIL: $0 does not parse"; exit 1; }
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
F="$KIT/bin/cabinet"
fail() { echo "FAIL: $*" >&2; exit 1; }
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
# The real home folder, git config and agent tool settings are never read or written.
export HOME="$T/user" GIT_CONFIG_GLOBAL="$T/user/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME XDG_STATE_HOME   # their defaults follow HOME into the temp folder
mkdir -p "$HOME"; printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$GIT_CONFIG_GLOBAL"
# The real launchd, systemd, crontab, keychain and secret store are never reached: fakes that
# only log are first on PATH for the whole run, before any section, so even one section run
# alone cannot load a real schedule, read a real secret, install a package or start a real agent (claude is a
# fake too). The fake crontab keeps its table in $T.
mkdir -p "$T/shim"
for t in launchctl systemctl security secret-tool osascript notify-send claude brew apt-get dnf pacman sudo; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\ncase "$1" in find-generic-password|lookup) exit 44 ;; esac\n' "$t" "$T/fake.log" > "$T/shim/$t"; chmod +x "$T/shim/$t"
done
printf '#!/bin/sh\ncase "$1" in -l) cat "%s" 2>/dev/null ;; -) cat > "%s" ;; *) exit 1 ;; esac\n' "$T/crontab" "$T/crontab" > "$T/shim/crontab"; chmod +x "$T/shim/crontab"
export PATH="$T/shim:$PATH"
for t in launchctl systemctl crontab security secret-tool brew apt-get sudo; do [[ "$(command -v "$t")" == "$T/shim/$t" ]] || fail "the fake $t is not first on PATH"; done
sedi() { if [[ "$(uname)" == Darwin ]]; then sed -i "" "$@"; else sed -i "$@"; fi; }
perm() { if [[ "$(uname)" == Darwin ]]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
# The kit's JavaScript (scripts/lib.js): L runs one of its commands, such as the line edits; j reads
# JSON (json: options for input and output, and a JavaScript expression).
L() { node "$KIT/scripts/lib.js" "$@"; }
j() { L json "$@"; }
# in_tty <command>...: run it with its output on a terminal and print what it wrote, with script (in
# macOS and in Linux's util-linux; their options differ), stopped after 60 seconds. script's input
# never ends while the command runs: at its end, script would type ^D, which the terminal can echo.
in_tty() {
  if [[ "$(uname)" == Darwin ]]; then L run-limited 60 script -q /dev/null "$@" < <(sleep 60) || true
  else L run-limited 60 script -qfec "$(printf '%q ' "$@")" /dev/null < <(sleep 60) || true; fi
}
# Where this machine keeps logs and schedules, under a HOME (bin/platform.sh): $H/$LOGS, $H/$SD/<label>$SX.
pf() { bash -c 'source "$0/scripts/when.sh"; source "$0/scripts/platform.sh"; "$@"' "$KIT" "$@"; }
SCH="$(pf eval 'echo $SCHEDULER')"
if [[ "$(uname)" == Darwin ]]; then LOGS="Library/Logs/cabinet"; else LOGS=".local/state/cabinet"; fi
case "$SCH" in launchd) SD="Library/LaunchAgents" SX=.plist ;; systemd) SD=".config/systemd/user" SX=.service ;; *) SD=".config/cabinet/cron" SX=.cron ;; esac
# A schedule's days and times as "<weekday or *>:<hour>:<minute> ...", its stored time and its command (JSON).
cal() {
  case "$SCH" in
    launchd) plutil -extract StartCalendarInterval json -o - "$1" | j -r '$.map((c) => (c.Weekday ?? "*") + ":" + c.Hour + ":" + c.Minute).join(" ")' ;;
    systemd) sed -n 's/^OnCalendar=//p' "${1%.service}.timer" | awk '{ n = split($1, d, ","); split($3, t, ":"); if (NF == 2) { n = 1; d[1] = "*"; split($2, t, ":") }
      for (i = 1; i <= n; i++) { w = index("SunMonTueWedThuFriSat", d[i]); printf "%s%s:%d:%d", (i > 1 ? " " : ""), (d[i] == "*" ? "*" : (w - 1) / 3), t[1], t[2] } }' ;;
    *) grep -v '^#' "$1" | awk '{ n = split($5, d, ","); for (i = 1; i <= n; i++) printf "%s%s:%d:%d", (i > 1 ? " " : ""), d[i], $2, $1 }' ;;
  esac
}
when_of() { pf sched_get "$1" when; }
cmd_of() { pf sched_get "$1" command; }
# fake_sched <file> <program>: a schedule another workspace (or this one, under an old name) left.
fake_sched() {
  mkdir -p "$(dirname "$1")"
  if [[ "$SCH" == launchd ]]; then printf '<plist><string>%s</string></plist>\n' "$2" > "$1"; else printf '# cabinet-command: ["%s"]\n' "$2" > "$1"; fi
}


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
[[ "$(cat "$W/.cabinet/version")" == "$(j -r '$.version' "$KIT/package.json")" ]] || fail "version not recorded"
git -C "$W" log --oneline | grep -q 'create from cabinet' || fail "workspace not committed"
[[ -z "$(git -C "$W" status --porcelain)" ]] || { git -C "$W" status --porcelain; fail "setup left files uncommitted"; }
[[ "$("$W/bin/handoff.sh" list)" == "No open handoffs." && "$("$W/bin/handoff.sh" list --json)" == "[]" ]] || fail "handoffs with none open"
  return 0   # a last "check && fail" line must not end the run
}

section "new with options" ""
s1() {
env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL "$F" new "$T/opt" --yes --roles "qa security" --runner codex --brief-time off --week-start Monday \
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
"$F" new "$T/bad" --yes --brief-time lunchtime >/dev/null 2>&1 && fail "bad brief time accepted"
[[ ! -e "$T/bad" ]] || fail "a refused setup left files behind"
  return 0   # a last "check && fail" line must not end the run
}

section "new, answered at the prompts" ""
s2() {
# Name, folder, owner, email, 6 roles (product-manager no, finance no), 4 optional roles (Enter: off), runner, brief,
# budget and price (antigravity reports only tokens), week, writing, backup, one repo then done, create, no npm install,
# no machine setup.
printf '%s\n' "Acme Labs" "$T/acme" "" "" n "" "" "" "" n "" "" "" "" antigravity 5 "1  2" "8:30 am" sunday short off git@example.com:me/acme-app.git "" y n n > "$T/answers"
CABINET_TTY="$T/answers" "$F" new >/dev/null 2>&1 || fail "prompted setup failed"
A="$T/acme"
grep -q '^# AGENTS.md - Acme Labs$' "$A/AGENTS.md" && grep -qx 'CABINET_SLUG="acme"' "$A/cabinet.env" || fail "prompted name or folder"
grep -qx 'CABINET_ROLES="chief-of-staff architect qa security design-lead"' "$A/cabinet.env" || fail "prompted roles"
grep -qx 'CABINET_RUNNER="antigravity"' "$A/cabinet.env" && grep -qx 'WHEN="8:30 AM"' "$A/jobs/brief.job" || fail "prompted runner or brief"
grep -q $'^acme-app\t' "$A/repos.tsv" || fail "prompted repo"
grep -q '^- \*\*Writing to the owner:\*\* short\.' "$A/AGENTS.md" || fail "prompted writing"
# With claude (the fake comes first on PATH) setup asks for a budget, and no price: claude reports dollars.
printf '%s\n' "Budgeted" "$T/budgeted" "" "" "" "" "" "" "" "" "" "" "" "" "" 15 "" "" "" "" "" y n n > "$T/answers"
CABINET_TTY="$T/answers" "$F" new >/dev/null 2>&1 && grep -qx 'CABINET_BUDGET="15"' "$T/budgeted/cabinet.env" || fail "prompted budget with claude"
grep -qx 'CABINET_BUDGET="5"' "$A/cabinet.env" && grep -qx 'CABINET_PRICE="1 2"' "$A/cabinet.env" || fail "prompted budget and price with antigravity"
grep -qx 'CABINET_PRICE=""' "$T/budgeted/cabinet.env" || fail "a price was set with claude"
printf '%s\n' "Nope" "$T/nope" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" n > "$T/answers"
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
[[ -f "$I/.claude/agents/qa.md" ]] && j -e '$.devDependencies?.["@tarekraafat/cabinet"]' "$I/cabinet/package.json" >/dev/null || fail "roles not in the project, or the private pin not in cabinet/package.json"
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
! grep -q 'tarekraafat/cabinet' "$G/package.json" && j -e '$.devDependencies?.["@tarekraafat/cabinet"]' "$T/shop-hq/package.json" >/dev/null || fail "beside put the pin in the project instead of the workspace"
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
v="$(j -r '$.version' "$KIT/package.json")"
[[ "$(j -r '$.devDependencies["@tarekraafat/cabinet"]' "$S/package.json")" == "^$v" ]] || fail "pin not added to the project's package.json under --yes"
grep -q $'^\t"name"' "$S/package.json" && [[ ! -f "$S/cabinet/package.json" ]] || fail "package.json formatting lost, or a second one placed"
[[ "$(j -r '$.devDependencies["@tarekraafat/cabinet"]' "$I/package.json")" == "^0.1.0" && -z "$(git -C "$I" diff --stat -- package.json)" ]] || fail "an existing pin was touched"
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
echo "# mine" > "$R/README.md"; echo "#!/bin/sh" > "$R/bin/handoff.sh"
# A file of the folder's own at a kit path would be run as the kit's: init refuses, and creates nothing.
out="$("$F" init "$R" --yes 2>&1)" && fail "init accepted a file of its own at a kit path"
echo "$out" | grep -q 'already exist at paths the kit uses: bin/handoff.sh' && [[ ! -e "$R/.cabinet" && "$(cat "$R/bin/handoff.sh")" == "#!/bin/sh" ]] || fail "refused init still wrote files"
mv "$R/bin/handoff.sh" "$R/my-handoffs.sh"; rmdir "$R/bin"
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
HOME="$T/bkhome" CABINET_BACKUP_PASSPHRASE=t "$I/cabinet/bin/backup.sh" create "$BK" >/dev/null || fail "backup inside a project"
HOME="$T/bkhome" CABINET_BACKUP_PASSPHRASE=t "$I/cabinet/bin/backup.sh" restore "$(ls "$BK"/*.enc)" "$T/r/cabinet" > "$T/rout" || fail "restore inside a project"
grep -Eq '^Restoring acme-app from the backup of [0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}, [0-9]{1,2}:[0-9]{2} [AP]M into ' "$T/rout" || { cat "$T/rout"; fail "restore did not name the backup date in words"; }
[[ -f "$T/r/cabinet/HANDOFFS.md" && -f "$T/r/f" ]] || fail "restore did not rebuild the project around its workspace"
# The private pointers are ignored by the project's git, so not in the archive: rebuilding the roles brings them back.
"$T/r/cabinet/bin/role.sh" build >/dev/null
grep -q 'cabinet/CABINET.md' "$T/r/CLAUDE.local.md" && [[ -z "$(git -C "$T/r" status --porcelain)" ]] || fail "pointers not rebuilt after restore, or the project's git not clean"
[[ "$(git -C "$T/r" log -1 --format=%s)" == setup && "$(git -C "$T/r" branch --show-current)" == main ]] || fail "restored project history"
# Restored into a folder whose parent holds files of its own (like a home folder), the parent never becomes a repo.
mkdir -p "$T/busy"; echo mine > "$T/busy/README.md"
HOME="$T/bkhome" CABINET_BACKUP_PASSPHRASE=t "$I/cabinet/bin/backup.sh" restore "$(ls "$BK"/*.enc)" "$T/busy/cabinet" >/dev/null || fail "restore beside other files"
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
sedi 's/^CABINET_ROLES="\(.*\)"/CABINET_ROLES="\1 growth"/' "$W/cabinet.env"
sedi 's/finance |/finance, growth |/' "$W/OPERATIONS.md"
"$W/bin/role.sh" build --check >/dev/null 2>&1 && fail "check missed stale roles"
"$W/bin/role.sh" build >/dev/null
grep -q '## Project notes' "$W/agents/qa.md" && grep -q 'bun test' "$W/agents/qa.md" || fail "project note not appended"
[[ -f "$W/.claude/agents/growth.md" ]] || fail "project-only role not built"
"$W/bin/role.sh" build --check || fail "check fails on fresh roles"
sedi 's/ growth"/"/' "$W/cabinet.env"; "$W/bin/role.sh" build >/dev/null
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
"$W/bin/handoff.sh" list | grep -q 'H-20260101-01' || fail "open entry not listed"
"$W/bin/handoff.sh" list qa | grep -q 'first' || fail "entry for qa not printed"
"$W/bin/handoff.sh" list founder | grep -q 'second' && fail "done entry printed as open"
"$W/bin/handoff.sh" list --json | j -e '$.length == 1 && $[0].id == "H-20260101-01" && $[0].from == "architect" && $[0].to == "qa"
  && $[0].status == "open" && $[0].date == "2026-01-01" && $[0].age_days > 200 && $[0].title == "first" && !("text" in $[0])' >/dev/null || fail "handoffs --json"
"$W/bin/handoff.sh" list qa --json | j -e '$[0].text.includes("- Needed: y")' >/dev/null && (cd "$W/specs" && "$F" handoff list owner --json) | j -e '$.length == 0' >/dev/null || fail "handoffs <name> --json"
git -C "$W" add -A && git -C "$W" commit -qm handoffs
"$W/bin/handoff.sh" archive | grep -q 'archived 1' || fail "archive did not move the done entry"
grep -q 'H-20260101-02' "$W/handoffs/archive-2026-01.md" || fail "archive file missing the entry"
# cabinet handoff: the next free ID for today across HANDOFFS.md and the archives, the template's
# lines, and a commit of only that entry; never someone else's uncommitted lines.
d="$(date +%Y%m%d)"
printf '\n### H-%s-07: archived today\n- From: qa -> To: api\n- Status: done (%s)\n' "$d" "$(date +%F)" >> "$W/handoffs/archive-2026-01.md"
git -C "$W" add -A && git -C "$W" commit -qm "archived today"
out="$(cd "$W/specs" && "$F" handoff add --from architect --to "api, qa" --changed "GET /items: limit 50 -> 100" --needed "page by 100
in the client" "Raise the list limit")" || fail "handoff failed: $out"
[[ "$out" == "H-$d-08 filed for api, qa and committed" ]] || fail "handoff did not take the next free ID across the archives: $out"
git -C "$W" show --stat HEAD | grep -q "handoffs: H-$d-08 Raise the list limit" && [[ -z "$(git -C "$W" status --porcelain)" ]] || fail "handoff not committed alone"
"$W/bin/handoff.sh" list qa --json | j -e --arg id "H-$d-08" '((h) => h.from == "architect" && h.status == "open"
  && h.text.includes("- Needed: page by 100 in the client\n- Depends on: none"))($.find((h) => h.id == $id))' >/dev/null || fail "the filed handoff is not in the format the handoff tools read"
"$W/bin/handoff.sh" list | grep -q "H-$d-01" && fail "an ID was reused"
echo "- leftover line" >> "$W/HANDOFFS.md"
out="$("$W/bin/handoff.sh" add --from qa --to architect --changed x --needed y "Second")"
[[ "$out" == "H-$d-09 filed for architect, not committed"* ]] && git -C "$W" log -1 --format=%s | grep -q "H-$d-08" || fail "handoff committed someone else's uncommitted lines"
"$W/bin/doctor.sh" 2>&1 | grep -q 'ok    every handoff ID is unique' || fail "handoff made a duplicate ID"
git -C "$W" checkout -q -- HANDOFFS.md
"$W/bin/handoff.sh" add --from qa --to api "No details" >/dev/null 2>&1 && fail "a handoff without --changed and --needed was filed"
[[ -z "$(git -C "$W" status --porcelain)" ]] || fail "a refused handoff changed a file"
"$W/bin/handoff.sh" add --from qa --to api --changed x --needed y "At once A" > "$T/ha" & "$W/bin/handoff.sh" add --from qa --to api --changed x --needed y "At once B" > "$T/hb"; wait
[[ "$(cut -d' ' -f1 "$T/ha")" != "$(cut -d' ' -f1 "$T/hb")" ]] && grep -q committed "$T/ha" && grep -q committed "$T/hb" || fail "two handoffs filed at once: $(cat "$T/ha" "$T/hb")"
# A lock left by a writer that was stopped is taken over after a minute, not waited on.
mkdir "$W/.cabinet/handoff.lock" && touch -t 202001010000 "$W/.cabinet/handoff.lock"
out="$("$W/bin/handoff.sh" add --from qa --to api --changed x --needed y "After a stale lock")" && [[ "$out" == *committed && ! -d "$W/.cabinet/handoff.lock" ]] || fail "a stale handoff lock was not taken over: $out"
grep -q 'never by hand' "$KIT/templates/workspace/HANDOFFS.md" && grep -q 'never by hand, since a hand-numbered entry' "$KIT/core/CABINET.md" || fail "the rule to file handoffs only with handoff add left the template or CABINET.md"
grep -q '^- \*\*A verdict is one line' "$KIT/core/CABINET.md" || fail "the verdict rule is not its own bullet in CABINET.md"
# Evidence: files copied under the entry's ID and linked from the workspace root, links kept, both committed.
printf 'png' > "$T/login page.png"; printf 'log' > "$T/run.txt"
out="$(cd "$W/specs" && "$F" handoff add --from web --to qa --changed x --needed y --evidence "../../login page.png" --evidence "$T/run.txt" --evidence https://example.com/try "Shown")" || fail "handoff with evidence: $out"
id="${out%% *}"
grep -qxF -- "- Evidence: [login-page.png](specs/evidence/$id/login-page.png), [run.txt](specs/evidence/$id/run.txt), <https://example.com/try>" "$W/HANDOFFS.md" || fail "the evidence line"
[[ "$(cat "$W/specs/evidence/$id/login-page.png")" == png && -z "$(git -C "$W" status --porcelain)" ]] || fail "evidence not copied and committed with its entry"
"$W/bin/handoff.sh" add --from web --to qa --changed x --needed y --evidence "$T/none.png" "Missing" >/dev/null 2>&1 && rc=0 || rc=$?; [[ $rc == 2 ]] || fail "a missing evidence file was accepted"
"$W/bin/handoff.sh" add --from web --to qa --changed x --needed y --evidence "ftp://x" "Bad link" >/dev/null 2>&1 && fail "a link that is not http(s) was accepted"
[[ -z "$(git -C "$W" status --porcelain)" ]] || fail "refused evidence changed a file"
sed -i.bak "/^### $id:/,/^- Status:/s/^- Status: open/- Status: done/" "$W/HANDOFFS.md" && rm "$W/HANDOFFS.md.bak" && git -C "$W" commit -qam "done" && "$W/bin/handoff.sh" archive >/dev/null
grep -q '^\*\*No evidence, no PASS\.\*\*' "$KIT/roles/qa.md" && grep -q 'qa never records PASS on a handoff without evidence' "$KIT/core/CABINET.md" \
  && grep -q 'A qa PASS on a handoff with no evidence does not count' "$KIT/roles/chief-of-staff.md" || fail "the no-evidence-no-PASS rule left qa, CABINET.md or the brief"
grep -qF "[run.txt](../specs/evidence/$id/run.txt)" "$W/handoffs/archive-${id:2:4}-${id:6:2}.md" || fail "archived evidence links do not open from handoffs/"
# Verdicts: one format the doctor reads; its note must exist; a qa PASS needs evidence; a crafted note path never runs.
base="$(git -C "$W" rev-parse HEAD)"
verdict() { awk -v id="$1" -v l="$2" '{print} index($0, "### " id ":") == 1 {on = 1} on && /^- Status:/ {print l; on = 0}' "$W/HANDOFFS.md" > "$T/hv" && mv "$T/hv" "$W/HANDOFFS.md"; }
e1="$("$W/bin/handoff.sh" add --from web --to qa --changed x --needed y --evidence "$T/run.txt" "With evidence")"; e1="${e1%% *}"
e2="$("$W/bin/handoff.sh" add --from web --to qa --changed x --needed y "Without evidence")"; e2="${e2%% *}"
mkdir -p "$W/specs/qa" && echo "ran it" > "$W/specs/qa/n.md"
verdict "$e1" "- Verdict: qa PASS $(date +%F) a1b2c3d,e4f5a6b specs/qa/n.md"; verdict "$e2" "- Verdict: qa PASS $(date +%F) a1b2c3d specs/qa/n.md"
out="$("$W/bin/doctor.sh" 2>&1 || true)"
echo "$out" | grep -q 'every verdict is in the verdict format' && echo "$out" | grep -q "qa PASS on handoffs with no evidence: $e2 (" || { echo "$out" | grep -i 'verdict\|evidence'; fail "doctor: a qa PASS without evidence"; }
verdict "$e1" "- Verdict: security PASS $(date +%F) a1b2c3d specs/security/none.md"
verdict "$e2" '- Verdict: qa PASS 2026-10-20 a1b2c3d specs/qa/$(touch${IFS}pwned).md'
out="$("$W/bin/doctor.sh" 2>&1 || true)"
echo "$out" | grep -q "verdicts not in the format, or naming a note that does not exist: $e1 $e2 (" && [[ ! -e "$W/pwned" ]] || { echo "$out" | grep -i 'verdict'; fail "doctor: a missing note, or a crafted path"; }
verdict "$e1" "- Verdict: qa passed it"
"$W/bin/doctor.sh" 2>&1 | grep -q "verdicts not in the format.*$e1" || fail "doctor: a verdict in another shape"
git -C "$W" reset -q --hard "$base" && rm -rf "$W/specs/qa"
# record writes the verdict and attach adds evidence, each committed; both refuse what the rules forbid.
v="$(cd "$W/specs" && "$F" handoff add --from web --to qa --changed x --needed y "Recorded")"; v="${v%% *}"
mkdir -p "$W/specs/qa" && echo "ran it" > "$W/specs/qa/r.md"
rc=0; "$W/bin/handoff.sh" record "$v" --role qa pass --commits a1b2c3d --note specs/qa/r.md >/dev/null 2>&1 || rc=$?
[[ $rc == 1 ]] || fail "record took a note that is not committed"
git -C "$W" add specs/qa/r.md && git -C "$W" commit -qm "qa: note"
out="$(cd "$W/specs/qa" && "$F" handoff record "$v" --role qa pass --commits a1b2c3d --note r.md 2>&1)" && fail "record let qa pass work with no evidence"
echo "$out" | grep -q "bin/handoff.sh attach $v <file or URL> --from web" || fail "the no-evidence refusal does not say how to add it: $out"
out="$("$W/bin/handoff.sh" record "$v" --role qa block --commits "A1B2C3D, e4f5a6b" --note specs/qa/r.md)" && [[ "$out" == "$v: qa BLOCK recorded and committed" ]] || fail "record BLOCK: $out"
grep -qxF -- "- Verdict: qa BLOCK $(date +%F) a1b2c3d,e4f5a6b specs/qa/r.md" "$W/HANDOFFS.md" && [[ -z "$(git -C "$W" status --porcelain)" ]] || fail "the recorded verdict line, or its commit"
"$W/bin/handoff.sh" attach "$v" "$T/run.txt" --from qa >/dev/null 2>&1 && fail "attach let someone other than the sender add evidence"
(cd "$T" && "$F" -C "$W" handoff attach "$v" "$T/run.txt" https://example.com/v --from Web) | grep -q "$v: evidence attached and committed" || fail "attach"
"$W/bin/handoff.sh" list qa --json | j -e --arg id "$v" '$.find((h) => h.id == $id).text.includes("- Evidence: [run.txt](specs/evidence/" + $id + "/run.txt), <https://example.com/v>\n- Verdict: qa BLOCK")' >/dev/null \
  && [[ -f "$W/specs/evidence/$v/run.txt" && -z "$(git -C "$W" status --porcelain)" ]] || fail "attached evidence: not before the verdicts, or not committed"
"$W/bin/handoff.sh" record "$v" --role qa PASS --commits a1b2c3d --note specs/qa/r.md >/dev/null || fail "record PASS once there is evidence"
[[ "$(grep -c '^- Verdict: qa ' "$W/HANDOFFS.md")" == 1 ]] && grep -q "^- Verdict: qa PASS " "$W/HANDOFFS.md" || fail "a new verdict did not replace the role's earlier one"
"$W/bin/doctor.sh" 2>&1 | grep -q 'every qa PASS has evidence' || fail "doctor disagrees with record"
"$W/bin/handoff.sh" record "$v" --role web PASS --commits a1b2c3d --note specs/qa/r.md >/dev/null 2>&1 && fail "record let the builder verify its own work"
rc=0; "$W/bin/handoff.sh" record "$v" --role qa PASS --commits xyz --note specs/qa/r.md >/dev/null 2>&1 || rc=$?; [[ $rc == 2 ]] || fail "record took commits that are not hashes"
"$W/bin/handoff.sh" record H-20200101-01 --role qa PASS --commits a1b2c3d --note specs/qa/r.md >/dev/null 2>&1 && fail "record wrote on an entry that does not exist"
echo n > "$W/README-note.md"; "$W/bin/handoff.sh" record "$v" --role qa PASS --commits a1b2c3d --note README-note.md >/dev/null 2>&1 && fail "record took a note outside specs/"
rm "$W/README-note.md"; [[ -z "$(git -C "$W" status --porcelain)" ]] || fail "a refused record or attach changed a file"
# Readiness, computed: the reviewers an entry needs, at the latest commits, and only that work is ready.
rj() { "$W/bin/handoff.sh" list --json | j -c --arg i "$1" "((\$) => $2)(\$.find((h) => h.id == \$i))"; }   # rj <id> <expression on the entry, $>
r="$("$W/bin/handoff.sh" add --from web --to "qa, security" --changed "Login screen" --needed "Verify it" --evidence https://example.com/l "Login UI")"; r="${r%% *}"
[[ "$(rj "$r" '[$.needs, $.missing, $.ready]')" == '[["qa","security","design-lead"],["qa","security","design-lead"],false]' ]] || fail "readiness of new work from the web builder: $(rj "$r" '$')"
for x in qa security design-lead; do "$W/bin/handoff.sh" record "$r" --role "$x" PASS --commits a1b2c3d --note specs/qa/r.md >/dev/null || fail "record $x for readiness"; done
[[ "$(rj "$r" '$.ready')" == true ]] && "$W/bin/handoff.sh" list --ready | grep -q "$r" && "$F" -C "$W" handoff list --ready --json | j -e --arg i "$r" '$.length == 1 && $[0].id == $i' >/dev/null || fail "work every reviewer passed is not ready: $(rj "$r" '$')"
"$W/bin/handoff.sh" record "$r" --role qa PASS --commits a1b2c3d,e4f5a6b7 --note specs/qa/r.md >/dev/null
[[ "$(rj "$r" '[$.stale, $.ready]')" == '[["security","design-lead"],false]' ]] || fail "a fix did not make the earlier passes stale: $(rj "$r" '$')"
! "$W/bin/handoff.sh" list --ready | grep -q "$r" || fail "stale work listed as ready"
"$W/bin/handoff.sh" record "$r" --role security PASS --commits a1b2c3d4,e4f5a6b --note specs/qa/r.md >/dev/null
"$W/bin/handoff.sh" record "$r" --role design-lead BLOCK --commits a1b2c3d,e4f5a6b --note specs/qa/r.md >/dev/null
[[ "$(rj "$r" '[$.stale, $.blocking, $.missing, $.ready]')" == '[[],["design-lead"],[],false]' ]] || fail "a BLOCK, or hashes of two lengths: $(rj "$r" '$')"
[[ "$(rj "$r" '$.verdicts.map((v) => v.role + " " + v.verdict).join(",")')" == '"qa PASS,security PASS,design-lead BLOCK"' ]] || fail "the verdicts in list --json"
sedi "/^### $r:/,/^### /s/^\(- Status: open ([0-9-]*)\)\$/\1 qa PASS, looks fine/" "$W/HANDOFFS.md"
[[ "$(rj "$r" '$.unread_verdicts.length')" == 1 ]] && "$W/bin/doctor.sh" 2>&1 | grep -q "written outside a Verdict line, so not counted: $r" || fail "a verdict in prose was not reported: $(rj "$r" '$.unread_verdicts')"
git -C "$W" checkout -q -- HANDOFFS.md
o="$("$W/bin/handoff.sh" add --from chief-of-staff --to owner --changed x --needed "Decide" "Pricing")"; o="${o%% *}"
[[ "$(rj "$o" '[$.needs, $.ready]')" == '[[],null]' ]] || fail "a decision for the owner needs a review: $(rj "$o" '$')"
rc=0; "$W/bin/handoff.sh" list qa --ready >/dev/null 2>&1 || rc=$?; [[ $rc == 2 ]] || fail "list --ready with a name, in text, was not refused"
grep -q '^- \*\*Readiness is computed\.\*\*' "$KIT/core/rules/reviews.md" && grep -q 'never judge readiness yourself' "$KIT/roles/chief-of-staff.md" || fail "the readiness rules left reviews.md or the chief-of-staff"
# Work that changes no repo: a verdict with no commits, never for work addressed to a builder.
w="$("$W/bin/handoff.sh" add --from product-manager --to qa --changed "Landing copy drafted" --needed "Check it" --evidence https://example.com/copy "Copy")"; w="${w%% *}"
out="$("$W/bin/handoff.sh" record "$w" --role qa PASS --commits none --note specs/qa/r.md)" || fail "a verdict on work with no commits: $out"
grep -qxF -- "- Verdict: qa PASS $(date +%F) none specs/qa/r.md" "$W/HANDOFFS.md" && "$W/bin/doctor.sh" 2>&1 | grep -q 'every verdict is in the verdict format' || fail "a verdict with no commits is not in the format"
b="$("$W/bin/handoff.sh" add --from qa --to web --changed x --needed y --small "Button")"; b="${b%% *}"
out="$("$W/bin/handoff.sh" record "$b" --role code-reviewer PASS --commits none --note specs/qa/r.md 2>&1)" && fail "a builder's work passed with no commits"
echo "$out" | grep -q "is work for web, which builds: name its commits" || fail "no commits for a builder: $out"
git -C "$W" reset -q --hard "$base"; rm -rf "$W/specs/qa"
  return 0   # a last "check && fail" line must not end the run
}

section "update" "0"
s11() {
"$F" -C "$W" update >/dev/null || fail "clean update failed"
echo "# local edit" >> "$W/bin/handoff.sh"
"$F" -C "$W" update >/dev/null 2>&1 && fail "update replaced an edited kit file"
grep -q '# local edit' "$W/bin/handoff.sh" || fail "edited kit file was overwritten"
"$F" -C "$W" status | grep -q 'edited here: bin/handoff.sh' || fail "status missed the edit"
git -C "$W" checkout -q -- bin/handoff.sh
"$F" -C "$W" update >/dev/null || fail "update after restore failed"
  return 0   # a last "check && fail" line must not end the run
}

section "update to a newer kit shows its changelog" "0"
s12() {
# The kit as it is (V), then a copy one patch version ahead (N): works whatever version the kit is at.
V="$(j -r '$.version' "$KIT/package.json")"
N="$(node -e 'const v = process.argv[1].split(".").map(Number); v[2]++; console.log(v.join("."))' "$V")"
K2="$T/kit2"; cp -R "$KIT" "$K2"; rm -rf "$K2/.git"
N="$N" j '({...$, version: process.env.N})' "$KIT/package.json" > "$K2/package.json"
{ echo "# Changelog"; echo; echo "## $N - test"; echo; echo "- smoke change"; echo; tail -n +2 "$KIT/CHANGELOG.md"; } > "$K2/CHANGELOG.md"
echo "# $N" >> "$K2/core/CABINET.md"
out="$("$K2/bin/cabinet" -C "$W" update)"
echo "$out" | grep -qF "What changed since $V" && echo "$out" | grep -q 'smoke change' || fail "update did not show the changelog"
echo "$out" | grep -qF "## $V " && fail "changelog showed the version already installed"
[[ "$(cat "$W/.cabinet/version")" == "$N" ]] && tail -1 "$W/CABINET.md" | grep -qF "$N" || fail "newer kit not applied"
# It commits the update itself, and leaves the owner's own uncommitted edits to the owner.
echo "$out" | grep -qF "Committed in the workspace: cabinet: update to $N" && git -C "$W" log -1 --format=%s | grep -qxF "cabinet: update to $N" && [[ -z "$(git -C "$W" status --porcelain -- .cabinet CABINET.md bin agents .claude/agents ORG.md)" ]] || fail "update did not commit itself: $out"
echo "owner note" > "$W/.cabinet/owner-note"; before="$(git -C "$W" rev-parse HEAD)"
out="$("$KIT/bin/cabinet" -C "$W" update)" || fail "could not go back to the current kit"
echo "$out" | grep -q 'then commit: git -C' && [[ "$(git -C "$W" rev-parse HEAD)" == "$before" ]] || fail "update committed over the owner's own uncommitted change: $out"
rm -f "$W/.cabinet/owner-note"; git -C "$W" add -A -- .cabinet CABINET.md bin agents .claude/agents && { git -C "$W" diff --cached --quiet || git -C "$W" commit -qm "back to the current kit"; }
# With no git of its own, a real update does not end with "Nothing changed".
cp -R "$W" "$T/nogit"; rm -rf "$T/nogit/.git"
out="$("$K2/bin/cabinet" -C "$T/nogit" update)" || fail "update failed in a workspace with no git"
echo "$out" | tail -1 | grep -qxF "Updated to $N. Anything to do by hand is in the changelog above." || fail "update did not say it updated: $out"
rm -rf "$T/nogit"
# package.json goes into the update's commit only when the pin is its one change.
pkg() { P="$1" X="$2" node -e 'const o = {name: "w", devDependencies: {"@tarekraafat/cabinet": "^" + process.env.P}}; if (process.env.X) o.private = true; console.log(JSON.stringify(o, null, 2))' > "$W/package.json"; }
pkg "$V" ""; git -C "$W" add package.json && git -C "$W" commit -qm "pin"
pkg "$N" yes; out="$("$K2/bin/cabinet" -C "$W" update)"; WP="$(cd "$W" && pwd -P)"
git -C "$W" status --porcelain -- package.json | grep -q package.json && echo "$out" | grep -qxF "package.json has edits of yours besides the pin, so it was left out: git -C \"$WP\" commit -- package.json" || fail "update committed the owner's own edit in package.json, or its hint names a file that is not there: $out"
pkg 9.9.9 ""; "$KIT/bin/cabinet" -C "$W" update >/dev/null || fail "could not go back to the current kit"
[[ -z "$(git -C "$W" status --porcelain)" ]] || fail "update left the pin alone uncommitted: $(git -C "$W" status --porcelain)"
# A lockfile git does not track stays out of the hint, which would fail on it.
echo '{}' > "$W/package-lock.json"; pkg "$N" yes; out="$("$K2/bin/cabinet" -C "$W" update)"
echo "$out" | grep -qxF "package.json has edits of yours besides the pin, so it was left out: git -C \"$WP\" commit -- package.json" || fail "the update hint names a lockfile git does not track: $out"
rm -f "$W/package-lock.json"; pkg 9.9.9 ""; "$KIT/bin/cabinet" -C "$W" update >/dev/null || fail "could not go back to the current kit"
# With a lockfile, the hint names it too.
echo '{}' > "$W/package-lock.json"; pkg "$V" ""; git -C "$W" add package.json package-lock.json && git -C "$W" commit -qm "pin and lockfile"
pkg "$N" yes; out="$("$K2/bin/cabinet" -C "$W" update)"
echo "$out" | grep -qxF "package.json has edits of yours besides the pin, so it was left out: git -C \"$WP\" commit -- package.json package-lock.json" || fail "the update hint did not name the lockfile: $out"
pkg 9.9.9 ""; "$KIT/bin/cabinet" -C "$W" update >/dev/null || fail "could not go back to the current kit"
git -C "$W" rm -q package.json package-lock.json && git -C "$W" commit -qm "no pin"
  return 0   # a last "check && fail" line must not end the run
}

section "installed as a package" "0 12"
s13() {
(cd "$T" && npm pack "$KIT" --silent >/dev/null) || fail "npm pack failed"
tgz="$(ls "$T"/tarekraafat-cabinet-*.tgz)"
tar -tzf "$tgz" | grep -q 'package/test/' && fail "tests shipped in the package"
grep -q '"docs/logo.svg"' "$KIT/README.md" && tar -tzf "$tgz" | grep -qx 'package/docs/logo.svg' || fail "the README's logo is not shipped in the package"
grep -q 'id="status"' "$KIT/brand/index.html" && grep -q 'id="chairs"' "$KIT/brand/index.html" && grep -q 'id="hover"' "$KIT/brand/index.html" && grep -q 'id="loading"' "$KIT/brand/index.html" && grep -q 'id="intro"' "$KIT/brand/index.html" && grep -q 'href="motion.html"' "$KIT/brand/index.html" && [[ -f "$KIT/brand/motion.html" ]] && [[ -f "$KIT/brand/promo/video.html" && -s "$KIT/brand/promo/cabinet-promo.mp4" && -s "$KIT/brand/promo/music.m4a" && -f "$KIT/brand/demo/demo.html" && -s "$KIT/brand/demo/captured.js" && -s "$KIT/brand/demo/cabinet-demo.mp4" ]] && grep -q 'id="table-rule"' "$KIT/brand/index.html" && ! tar -tzf "$tgz" | grep -q 'package/brand/' || fail "the brand guide should be in the repository and not shipped in the package"
(cd "$W" && npm install -D "$tgz" --no-audit --no-fund --silent) || fail "install from the package failed"
(cd "$W" && npx --no cabinet status) | grep -q 'no kit file edited' || fail "installed command does not work"
git -C "$W" status --porcelain | grep -q node_modules && fail "node_modules not ignored"
# A "global" newer kit run inside the workspace must defer to the pinned copy.
out="$(cd "$W" && "$K2/bin/cabinet" status)"
echo "$out" | grep -q "node_modules/@tarekraafat/cabinet: $(j -r '$.version' "$KIT/package.json")" || fail "global command did not defer to the pinned copy"
"$K2/bin/cabinet" version | grep -qF "$N" || fail "outside a workspace the global command should run itself"
  return 0   # a last "check && fail" line must not end the run
}

section "schedules follow jobs/ and cabinet.env" "0"
s14() {
# A scratch HOME and the fake schedulers: nothing reaches the real machine.
H="$T/home"; mkdir -p "$H/$SD"
boot() { HOME="$H" PATH="$T/shim:$PATH" "$W/bin/bootstrap.sh" "$@" 2>&1; }
LA="$H/$SD"; P="$LA/ai.cabinet.demo-co"
touch "$LA/ai.cabinet.other.brief$SX"
boot >/dev/null
[[ "$(cal "$P.brief$SX")" == "*:7:0" ]] || fail "brief not scheduled at 07:00"
[[ -z "$(boot | grep -E 'installed|updated|removed')" ]] || fail "a rerun with no change touched a schedule"
sedi 's/^WHEN=.*/WHEN="08:15"/' "$W/jobs/brief.job"
boot | grep -q 'updated ai.cabinet.demo-co.brief' || fail "changed time not reported"
[[ "$(cal "$P.brief$SX")" == "*:8:15" ]] || fail "changed time not applied"
sedi "s|^CABINET_BACKUP_DIR=.*|CABINET_BACKUP_DIR=\"$T/bk\"|" "$W/cabinet.env"
boot >/dev/null; [[ -f "$P.backup$SX" ]] || fail "backup not scheduled"
sedi 's|^CABINET_BACKUP_DIR=.*|CABINET_BACKUP_DIR=""|' "$W/cabinet.env"
sedi 's/^WHEN=.*/WHEN=""/' "$W/jobs/brief.job"
boot --dry-run | grep -q 'would remove ai.cabinet.demo-co.brief' && [[ -f "$P.brief$SX" ]] || fail "dry run removed or did not report"
boot | grep -q 'removed ai.cabinet.demo-co.backup' || fail "backup off not removed"
[[ ! -e "$P.brief$SX" && ! -e "$P.backup$SX" ]] || fail "turned-off schedules left behind"
[[ -f "$LA/ai.cabinet.other.brief$SX" ]] || fail "another workspace's schedule was touched"
grep -Eq '(launchctl bootout gui/[0-9]*/|systemctl --user disable --now )ai.cabinet.demo-co.brief' "$T/fake.log" || [[ "$SCH" == cron ]] || fail "removed schedule not unloaded"
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
kd="$(j -c '$.permissions.deny' "$KIT/guardrails/claude-permissions.json")"
j -e --argjson d "$kd" '$d.every((r) => $.permissions.deny.includes(r)) && $.ui.theme == "x"' "$H/.qwen/settings.json" >/dev/null || fail "Qwen rules not merged or settings lost"
oc="$H/.config/opencode/opencode.json"
j -e 'Object.keys($.permission).join() == "*,bash" && Object.keys($.permission.bash)[0] == "*" && $.permission.bash["git push*"] == "deny" && $.mcp.x.enabled === false' "$oc" >/dev/null || fail "opencode rules not last, or settings lost"
j -e --argjson n "$(j '$.permissions.deny.length + $.permissions.ask.length' "$KIT/guardrails/claude-permissions.json")" 'Object.keys($.permission.bash).length - 1 == $n' "$oc" >/dev/null || fail "opencode did not get every rule"
[[ -z "$(boot | grep -E 'added')" ]] || fail "a second run changed the guardrails again"
# A settings file holding a value a rewrite would change (here 1.0) is left exactly as it is, with a message.
cp "$H/.qwen/settings.json" "$T/qwen.keep"; echo '{"ui":{"scale":1.0}}' > "$H/.qwen/settings.json"; cp "$H/.qwen/settings.json" "$T/qwen.inexact"
out="$(boot || true)"
cmp -s "$H/.qwen/settings.json" "$T/qwen.inexact" && echo "$out" | grep -q 'settings.json is not plain JSON, or a rewrite would change one of its values, left as is' \
  || { echo "$out"; fail "a settings file a rewrite would change was rewritten"; }
cp "$T/qwen.keep" "$H/.qwen/settings.json"
# opencode reads opencode.json and then opencode.jsonc: the rules go in the .json, the commented .jsonc is never rewritten.
rm "$oc"; printf '{ // my comment\n}\n' > "${oc}c"; cp "${oc}c" "$T/jsonc.before"
boot >/dev/null
cmp -s "${oc}c" "$T/jsonc.before" && j -e '$.permission.bash["git push*"] == "deny"' "$oc" >/dev/null || fail "rules not placed beside a commented opencode.jsonc"
# A config that is not plain JSON is never rewritten, and the merge says so instead of claiming success.
printf '{"a": 1,}\n' > "$H/.qwen/settings.json"
out="$(boot || true)"; echo "$out" | grep -q 'settings.json is not plain JSON, or a rewrite would change one of its values, left as is' && ! echo "$out" | grep -q 'added .* rule(s) to .*qwen' || fail "an unreadable config was reported as merged"
[[ "$(cat "$H/.qwen/settings.json")" == '{"a": 1,}' && ! -e "$H/.qwen/settings.json.tmp" ]] || fail "an unreadable config was changed"
# Permissions and symlinks of a config survive the merge.
printf '{"k": 1}\n' > "$T/real-settings.json"; chmod 600 "$T/real-settings.json"; rm "$H/.qwen/settings.json"; ln -s "$T/real-settings.json" "$H/.qwen/settings.json"
boot >/dev/null
[[ -L "$H/.qwen/settings.json" && "$(perm "$T/real-settings.json")" == 600 ]] && j -e '$.k == 1 && $.permissions.deny.length > 0' "$T/real-settings.json" >/dev/null || fail "merge lost a symlink or loosened permissions"
  return 0   # a last "check && fail" line must not end the run
}

section "custom runner" "0 14"
s16() {
cp "$W/cabinet.env" "$T/env.bak"
cat >> "$W/cabinet.env" <<'EOF'
CABINET_RUNNER="custom"
CABINET_RUNNER_CMD='printf "%s|%s" "$CABINET_AGENT" "$CABINET_PROMPT" > runner.out'
EOF
HOME="$H" "$W/bin/job.sh" run brief >/dev/null 2>&1 || fail "custom runner failed"
grep -q '^chief-of-staff|Act as the chief-of-staff role: read agents/chief-of-staff.md' "$W/runner.out" || fail "custom runner did not get the role and prompt"
rm -f "$W/runner.out"
# A run past its time limit is stopped with everything it started, and the log says why
# (CABINET_TEST_MINUTE makes a minute one second). A limit that is not a number never runs.
echo "CABINET_RUNNER_CMD='sleep 323; :'" >> "$W/cabinet.env"
cp "$W/jobs/brief.job" "$T/brief.bak"; sedi 's/^TIMEOUT=.*/TIMEOUT="2"/' "$W/jobs/brief.job"
s=$SECONDS; st=0; HOME="$H" CABINET_TEST_MINUTE=1 "$W/bin/job.sh" run brief >/dev/null 2>&1 || st=$?
((st == 1 && SECONDS - s < 10)) || fail "a run past its limit was not stopped (exit $st after $((SECONDS - s))s)"
! pgrep -f 'sleep 323' >/dev/null || fail "a stopped run left what it started running"
grep -q "stopped after 2 min: the job's time limit" "$H/$LOGS/demo-co/brief.log" || fail "the log does not say why the run stopped"
# Stopping the job (launchd's stop, or Ctrl-C by hand) stops the agent too, though it runs in its own group.
HOME="$H" "$W/bin/job.sh" run brief >/dev/null 2>&1 & p=$!; sleep 1; kill -TERM "$p"; wait "$p" || true
! pgrep -f 'sleep 323' >/dev/null || fail "stopping the job left the agent running"
sedi 's/^TIMEOUT=.*/TIMEOUT="08"/' "$W/jobs/brief.job"
st=0; HOME="$H" "$W/bin/job.sh" run brief >/dev/null 2>&1 || st=$?
((st == 2)) && ! pgrep -f 'sleep 323' >/dev/null || fail "a TIMEOUT that is not whole minutes was not refused"
cp "$T/brief.bak" "$W/jobs/brief.job"; cp "$T/env.bak" "$W/cabinet.env"
# A run that ends on its own is never reported as stopped, even when the clock passed its limit while
# the machine slept: the watchdog's timer counts only time awake. A watchdog that never fires stands
# in for a sleeping machine; the run then outlasts its limit on the clock, and finishes.
printf '%s\n' 'CABINET_RUNNER="custom"' "CABINET_RUNNER_CMD='sleep 4; :'" >> "$W/cabinet.env"
sedi 's/^TIMEOUT=.*/TIMEOUT="2"/' "$W/jobs/brief.job"
HOME="$H" CABINET_TEST_MINUTE=1 "$W/bin/job.sh" run brief >/dev/null 2>&1 & p=$!
dog=""; for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do dog="$(pgrep -f "lib.js watchdog 2 " | head -1)"; [[ -n "$dog" ]] && break; sleep 0.2; done
[[ -n "$dog" ]] && kill -KILL "$dog" || fail "the run's watchdog did not start"
st=0; wait "$p" || st=$?
last="$(awk '/^=== / { b = "" } { b = b $0 "\n" } END { printf "%s", b }' "$H/$LOGS/demo-co/brief.log")"
((st == 0)) && ! grep -q 'stopped after' <<<"$last" || fail "a run that finished on its own was reported as stopped (exit $st): $last"
cp "$T/brief.bak" "$W/jobs/brief.job"; cp "$T/env.bak" "$W/cabinet.env"
"$F" new "$T/c1" --yes --runner custom >/dev/null 2>&1 && fail "custom runner without a command accepted"
"$F" new "$T/c2" --yes --runner custom --runner-cmd 'mytool --run "$CABINET_PROMPT"' >/dev/null || fail "custom runner option"
grep -qx "CABINET_RUNNER_CMD='mytool --run \"\$CABINET_PROMPT\"'" "$T/c2/cabinet.env" || fail "runner command not written"
  return 0   # a last "check && fail" line must not end the run
}

section "config changes settings after setup" "14"
s17() {
# config commits its own change in a clean workspace, and leaves the owner's uncommitted changes alone.
CC="$T/cfgcommit"; "$F" new "$CC" --yes --backup-dir off >/dev/null || fail "new for config commits"
out="$(cd "$CC" && "$F" config --yes --writing short 2>&1)" && echo "$out" | grep -qF "Committed in the workspace: cabinet config: writing to the owner" && [[ -z "$(git -C "$CC" status --porcelain)" ]] || fail "config left its change uncommitted: $out"
# Backups turned on in a workspace with no cabinet.local.env line for them (any new one) are written and committed.
BC="$T/cfgbackup"; "$F" new "$BC" --yes --backup-dir off >/dev/null || fail "new for config backups"
bk="$(cd "$T" && pwd -P)/bk-out"; st=0; out="$(cd "$BC" && "$F" config --yes --backup-dir "$bk" 2>&1)" || st=$?
((st == 0)) && echo "$out" | grep -qxF "  - backups: off -> $bk" && grep -qxF "CABINET_BACKUP_DIR=\"$bk\"" "$BC/cabinet.env" \
  && echo "$out" | grep -qF "Committed in the workspace: cabinet config: backups" && [[ -z "$(git -C "$BC" status --porcelain)" ]] || fail "config --backup-dir in a new workspace (exit $st): $out"
echo "owner note" >> "$CC/README.md"; before="$(git -C "$CC" rev-parse HEAD)"
out="$(cd "$CC" && "$F" config --yes --writing standard 2>&1)" && echo "$out" | grep -q "Review with git -C" && [[ "$(git -C "$CC" rev-parse HEAD)" == "$before" ]] && grep -qx "owner note" "$CC/README.md" || fail "config committed over the owner's own change: $out"
# It commits only the files it writes: a file someone else writes while it runs stays theirs.
git -C "$CC" checkout -q -- README.md; mv "$CC/bin/role.sh" "$CC/bin/role.real"
printf '#!/bin/bash\nmkdir -p "%s/notes"; echo meanwhile > "%s/notes/meanwhile.md"; echo "### H-other: written by another session" >> "%s/HANDOFFS.md"\nexec "%s/bin/role.real" "$@"\n' "$CC" "$CC" "$CC" "$CC" > "$CC/bin/role.sh"; chmod +x "$CC/bin/role.sh"
git -C "$CC" add -A && git -C "$CC" commit -qm "role.sh that writes meanwhile"
out="$(cd "$CC" && "$F" config --yes --roles "qa security" 2>&1)" && echo "$out" | grep -qF "Committed in the workspace: cabinet config: roles" || fail "config with a role change did not commit: $out"
git -C "$CC" status --porcelain | grep -qxF "?? notes/meanwhile.md" && ! git -C "$CC" show --stat HEAD | grep -q meanwhile || fail "config committed a file it did not write: $(git -C "$CC" status --porcelain)"
git -C "$CC" status --porcelain | grep -qxF " M HANDOFFS.md" && ! git -C "$CC" show --name-only --format= HEAD | grep -qxF HANDOFFS.md || fail "config committed a handoff another session wrote while it ran: $(git -C "$CC" status --porcelain)"
# Each file goes in only for the settings that change it: a git that edits a file just before config
# lists what to commit stands in for another session editing it while config runs.
MC="$T/cfgmid"; "$F" new "$MC" --yes --backup-dir off >/dev/null || fail "new for config mid-run edits"
mkdir -p "$T/gitmid"; printf '#!/bin/bash\ncase " $* " in *" --porcelain -uall "*) [[ -z "${MID_EDIT:-}" ]] || echo "edit by another session" >> "$MID_EDIT" ;; esac\nexec %q "$@"\n' "$(command -v git)" > "$T/gitmid/git"; chmod +x "$T/gitmid/git"
mid() {  # mid <file another session edits> <config options>
  local f="$1"; shift
  out="$(cd "$MC" && MID_EDIT="$MC/$f" PATH="$T/gitmid:$PATH" "$F" config --yes "$@" 2>&1)" && echo "$out" | grep -qF "Committed in the workspace: cabinet config:" || fail "config $1 did not commit: $out"
  git -C "$MC" status --porcelain | grep -qxF " M $f" && ! git -C "$MC" show --name-only --format= HEAD | grep -qxF "$f" || fail "config $1 committed an edit another session made to $f: $(git -C "$MC" show --name-only --format= HEAD)"
  git -C "$MC" checkout -q -- "$f"
}
mid AGENTS.md --brief-time "8:15 AM"; mid AGENTS.md --budget 20
mid ORG.md --brief-time "9:15 AM"   # schedules change, but bootstrap does not run, so the roles are not rebuilt
# jobs/ goes in only for the job files that run wrote: the first turn-on commits pipeline.job, a mode change alone writes none.
mid jobs/brief.job --pipeline small --pipeline-limit 5
git -C "$MC" show --name-only --format= HEAD | grep -qxF jobs/pipeline.job || fail "turning the runner on did not commit jobs/pipeline.job"
mid jobs/brief.job --pipeline all; mid jobs/brief.job --pipeline off; mid jobs/brief.job --pipeline small
# A pipeline.job deleted by hand is made again by the next run, and committed.
git -C "$MC" rm -q jobs/pipeline.job && git -C "$MC" commit -qm "pipeline.job deleted by hand"
out="$(cd "$MC" && "$F" config --yes --budget 30 2>&1)" && [[ -f "$MC/jobs/pipeline.job" && -z "$(git -C "$MC" status --porcelain)" ]] || fail "a recreated pipeline.job was left uncommitted: $out $(git -C "$MC" status --porcelain)"
# package.json goes in only when this run wrote it: a rename writes only the workspace's own.
sedi 's/"private": true/"private": false/' "$MC/package.json"; git -C "$MC" commit -qm "a project's package.json" -- package.json
mid package.json --name "Mid Other"
# A rename commits the titles in HANDOFFS.md, README.md and specs/ROADMAP.md too, and leaves nothing behind.
out="$(cd "$MC" && "$F" config --yes --name "Mid Renamed" 2>&1)" && echo "$out" | grep -qF "Committed in the workspace: cabinet config: project name" || fail "config --name did not commit: $out"
for f in HANDOFFS.md README.md specs/ROADMAP.md; do git -C "$MC" show --name-only --format= HEAD | grep -qxF "$f" || fail "a rename did not commit $f"; done
[[ -z "$(git -C "$MC" status --porcelain)" ]] || fail "a rename left changes uncommitted: $(git -C "$MC" status --porcelain)"
C="$T/cfg"; "$F" new "$C" --name Acme --yes >/dev/null
cfg() { (cd "$C" && HOME="$H" PATH="$T/shim:$PATH" "$F" config "$@" 2>&1); }
HOME="$H" PATH="$T/shim:$PATH" "$C/bin/bootstrap.sh" >/dev/null 2>&1
[[ -f "$LA/ai.cabinet.cfg.brief$SX" ]] || fail "config test setup: no schedule"
out="$(cfg --yes --name "Acme Labs" --slug acme-labs --owner Ann --email ann@example.com --roles "qa security" \
  --brief-time 06:30 --week-start Monday --repo git@example.invalid:acme/api.git --apply)" || { echo "$out"; fail "config with options"; }
echo "$out" | grep -q 'api: clone failed (see above); everything else continues' || fail "a failed clone stopped the setup"
grep -qx 'CABINET_PROJECT="Acme Labs"' "$C/cabinet.env" && grep -qx 'CABINET_SLUG="acme-labs"' "$C/cabinet.env" || fail "name or slug not written"
grep -qx '# AGENTS.md - Acme Labs' "$C/AGENTS.md" && grep -qx '# Acme Labs operations manual' "$C/OPERATIONS.md" || fail "titles not renamed"
grep -q 'Authored as Ann <ann@example.com>\.' "$C/AGENTS.md" && grep -q 'Week starts on:\*\* Monday\.' "$C/AGENTS.md" || fail "owner or week not written"
grep -q '| finance |' "$C/AGENTS.md" "$C/OPERATIONS.md" && fail "a dropped role is still in a team table"
[[ "$(ls "$C/agents" | tr '\n' ' ')" == "chief-of-staff.md qa.md security.md " ]] || fail "roles not rebuilt"
grep -qx 'WHEN="6:30 AM"' "$C/jobs/brief.job" && grep -q $'^api\tgit@example.invalid:acme/api.git' "$C/repos.tsv" && grep -qF '| `api` |' "$C/AGENTS.md" || fail "brief or repo not written"
[[ ! -e "$LA/ai.cabinet.cfg.brief$SX" ]] && [[ "$(cal "$LA/ai.cabinet.acme-labs.brief$SX")" == "*:6:30" ]] || fail "schedule not moved to the new slug"
grep -q 'ai.cabinet.acme-labs.brief' "$C/OPERATIONS.md" && ! grep -q 'ai\.cabinet\.cfg\.' "$C/OPERATIONS.md" || fail "manual still names the old slug"
cfg --yes --roles "qa security finance" >/dev/null
[[ "$(grep -c '| finance |' "$C/AGENTS.md")" == 1 && "$(grep -c '| finance |' "$C/OPERATIONS.md")" == 1 && -f "$C/agents/finance.md" ]] || fail "a returning role did not come back"
cfg --yes | grep -qx 'Nothing to change.' || fail "no-op config changed something"
cp "$C/cabinet.env" "$T/cfg.env"; cfg --yes --slug "Bad Slug" >/dev/null && fail "a bad slug was accepted"
cmp -s "$C/cabinet.env" "$T/cfg.env" || fail "a refused config wrote files"
# Name, slug, owner, email, 6 roles (all yes), 4 optional roles (Enter: off), runner (claude), budget, scheduled runner (off), brief, week, writing,
# hard to undo (Enter: not set, no repos), backup, no repos, apply, no bootstrap.
printf '%s\n' "Acme Co" "" "" "" y y y y y y "" "" "" "" "" 25 "" off "" short "" off "" y n > "$T/answers"
(cd "$C" && HOME="$H" CABINET_TTY="$T/answers" "$F" config >/dev/null 2>&1) || fail "prompted config"
grep -qx 'CABINET_PROJECT="Acme Co"' "$C/cabinet.env" && grep -qx 'WHEN=""' "$C/jobs/brief.job" && grep -q 'design-lead' "$C/cabinet.env" || fail "prompted answers not written"
grep -q '^- \*\*Writing to the owner:\*\* short\.' "$C/AGENTS.md" && grep -qx 'CABINET_BUDGET="25"' "$C/cabinet.env" || fail "prompted writing or budget not written by config"
fake_sched "$LA/ai.cabinet.old-name.brief$SX" "$(cd "$C" && pwd -P)/bin/job.sh"
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
fake_sched "$H/$SD/ai.cabinet.taken.brief$SX" /elsewhere/taken/bin/job.sh
HOME="$H" "$F" new "$T/taken" --yes >/dev/null 2>&1 && fail "a slug used by another workspace was accepted"
HOME="$H" "$F" new "$T/taken" --slug taken-2 --yes >/dev/null && grep -qx 'CABINET_SLUG="taken-2"' "$T/taken/cabinet.env" || fail "--slug"
# Bootstrap never takes over or removes another workspace's schedule.
cp "$H/$SD/ai.cabinet.taken.brief$SX" "$T/taken.plist"
sedi 's/^CABINET_SLUG=.*/CABINET_SLUG="taken"/' "$T/taken/cabinet.env"
out="$(HOME="$H" PATH="$T/shim:$PATH" "$T/taken/bin/bootstrap.sh" 2>&1 || true)"
echo "$out" | grep -q 'ai.cabinet.taken.brief already runs another workspace' && cmp -s "$T/taken.plist" "$H/$SD/ai.cabinet.taken.brief$SX" || fail "bootstrap touched another workspace's schedule"
# The backup folder must be outside the workspace and its repos: setup, config and backup.sh all refuse.
"$F" new "$T/bk1" --backup-dir "$T/bk1/backups" --yes >/dev/null 2>&1 && fail "setup accepted a backup folder inside the workspace"
(cd "$I" && "$F" config --yes --backup-dir "$I/backups") >/dev/null 2>&1 && fail "config accepted a backup folder inside the project"
CABINET_BACKUP_PASSPHRASE=t "$I/cabinet/bin/backup.sh" create "$I/backups" >/dev/null 2>&1 && fail "backup.sh wrote into the project"
[[ ! -e "$I/backups" ]] || fail "a refused backup created its folder"
(cd "$T" && "$F" new "$T/rel" --backup-dir relbk --yes >/dev/null) && grep -qx "CABINET_BACKUP_DIR=\"$(cd "$T" && pwd -P)/relbk\"" "$T/rel/cabinet.env" || fail "relative backup folder not made absolute"
# Cleanup keeps only this workspace's archives, never another's with a longer slug; keep 0 is refused.
"$F" new "$T/app" --yes >/dev/null; BD="$T/shared-bk"; mkdir -p "$BD"
touch "$BD/app-web-20260101-000000.tar.gz.enc" "$BD/app-web-20260102-000000.tar.gz.enc"
sedi 's/^CABINET_BACKUP_KEEP=.*/CABINET_BACKUP_KEEP=1/' "$T/app/cabinet.env"
for i in 1 2; do CABINET_BACKUP_PASSPHRASE=t "$T/app/bin/backup.sh" create "$BD" >/dev/null; sleep 1; done
[[ "$(ls "$BD" | grep -c '^app-web-')" == 2 && "$(ls "$BD" | grep -cE '^app-[0-9]{8}-[0-9]{6}\.tar\.gz\.enc$')" == 1 ]] || { ls "$BD"; fail "cleanup removed another workspace's archives, or kept too many"; }
sedi 's/^CABINET_BACKUP_KEEP=.*/CABINET_BACKUP_KEEP=0/' "$T/app/cabinet.env"
CABINET_BACKUP_PASSPHRASE=t "$T/app/bin/backup.sh" create "$BD" >/dev/null 2>&1 && fail "keep 0 was accepted"
sedi 's/^CABINET_BACKUP_KEEP=.*/CABINET_BACKUP_KEEP=14/' "$T/app/cabinet.env"
# Restore never replaces a file without keeping a copy.
mkdir -p "$T/rr"; echo MINE > "$T/rr/AGENTS.md"
CABINET_BACKUP_PASSPHRASE=t "$T/app/bin/backup.sh" restore "$BD/$(ls "$BD" | grep -E '^app-[0-9]')" "$T/rr" >/dev/null || fail "restore into a folder with files"
[[ "$(cat "$T/rr/recovered/"*/workspace/AGENTS.md)" == MINE ]] && grep -q '^# AGENTS.md - app' "$T/rr/AGENTS.md" || fail "restore replaced a file without keeping a copy"
# A mistyped WHEN keeps the working schedule; an & in the path still gives a valid schedule.
A2="$T/R&D"; "$F" new "$A2" --slug rnd --yes >/dev/null
HOME="$H" PATH="$T/shim:$PATH" "$A2/bin/bootstrap.sh" >/dev/null 2>&1 || true
[[ "$(pf sched_ws "$H/$SD/ai.cabinet.rnd.brief$SX")" == "$(cd "$A2" && pwd -P)" ]] && { [[ "$SCH" != launchd ]] || plutil -lint "$H/$SD/ai.cabinet.rnd.brief$SX" >/dev/null; } || fail "a path with & gave an invalid schedule"
sedi 's/^WHEN=.*/WHEN="7 oclock"/' "$A2/jobs/brief.job"
out="$(HOME="$H" PATH="$T/shim:$PATH" "$A2/bin/bootstrap.sh" 2>&1 || true)"
echo "$out" | grep -q "bad schedule '7 oclock'" && [[ -f "$H/$SD/ai.cabinet.rnd.brief$SX" ]] || fail "a mistyped WHEN removed the working schedule"
# Scheduled jobs get a PATH with node's folder.
grep -qF "$(dirname "$(command -v node)")" "$H/$SD/ai.cabinet.rnd.brief$SX" || fail "node's folder not on the scheduled PATH"
# The pass-through stub runs a repo's own pre-commit hook under the global hooks path.
HK="$T/hooks"; mkdir -p "$HK"; cp "$KIT/guardrails/hook-passthrough" "$HK/pre-commit"
mkrepo "$T/hooked"; printf '#!/bin/sh\ntouch "%s/own-hook-ran"\n' "$T" > "$T/hooked/.git/hooks/pre-commit"; chmod +x "$T/hooked/.git/hooks/pre-commit"
echo y > "$T/hooked/g"; git -C "$T/hooked" add g; git -C "$T/hooked" -c core.hooksPath="$HK" commit -qm g
[[ -f "$T/own-hook-ran" ]] || fail "a repo's own pre-commit hook did not run under the global hooks path"
# config keeps a project's own role and accepts a weekly brief.
printf -- '---\nname: growth\ndescription: Growth.\n---\n\nYou are growth.\n' > "$C/roles/growth.md"
(cd "$C" && "$F" config --yes --roles "qa security growth") >/dev/null || fail "config refused a project role"
(cd "$C" && "$F" config --yes --brief-time "Sun 8 AM") >/dev/null || fail "config refused a weekly brief"
grep -q 'growth' "$C/cabinet.env" && [[ -f "$C/agents/growth.md" ]] && grep -qx 'WHEN="sun 8:00 AM"' "$C/jobs/brief.job" || fail "project role dropped or weekly brief not written"
(cd "$C" && "$F" config --yes --name "Acme Co 2") >/dev/null || fail "config refused to run with a weekly brief"
# Handoffs without an ISO date still show in the overview.
printf '\n### H-20260101-09: undated\n- From: qa -> To: architect\n- Status: acknowledged (3 Oct 2026)\n' >> "$W/HANDOFFS.md"
"$W/bin/handoff.sh" list | grep -q '?d  acknowledged  H-20260101-09' || fail "an undated open handoff is hidden"
git -C "$W" checkout -q -- HANDOFFS.md
# With no git identity, setup does not commit as TBD.
env GIT_CONFIG_GLOBAL="$T/empty-config" "$F" new "$T/noid" --yes >/dev/null
! git -C "$T/noid" log >/dev/null 2>&1 || fail "committed without an owner identity"
# update names only paths that exist; doctor sees a hooks path set in the project around cabinet/.
# (An uncommitted change of the owner's makes update show the commit instead of making it.)
touch "$I/cabinet/.cabinet/owner-note"
(cd "$I" && "$F" update) | grep 'then commit' | grep -qv 'package-lock' || fail "update names a path that does not exist"
rm -f "$I/cabinet/.cabinet/owner-note"
git -C "$I" config core.hooksPath .husky
"$I/cabinet/bin/doctor.sh" 2>&1 | grep -q "acme-app sets its own core.hooksPath (.husky)" || fail "doctor missed the project's own hooks path"
git -C "$I" config --unset core.hooksPath
# The guardrails close the known ways around the push gate and to credentials.
for r in 'Bash(*core.hooksPath*)' 'Bash(*GIT_CONFIG_*)' 'Bash(* --no-v*)' 'Bash(script *)' 'Bash(pnpm publish*)' 'Bash(yarn publish*)' 'Bash(gh auth token*)' 'Bash(security find-generic-password*)' 'Bash(secret-tool lookup*)' 'Bash(*cabinet/passphrases*)'; do
  j -e --arg r "$r" '$.permissions.deny.includes($r)' "$KIT/guardrails/claude-permissions.json" >/dev/null || fail "missing guardrail $r"
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
[[ "$("$G2/bin/handoff.sh" list)" == "No open handoffs." ]] || fail "the handoff template is listed as an entry"
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
j -e '$.name == "ignoring-two-workspace" && $.description.startsWith("Ignoring Two ")' "$G2/package.json" >/dev/null || fail "workspace package.json not renamed"
# Restore keeps a differing untracked file, and never turns a folder with files of its own into a repo.
R2="$T/rest"; "$F" new "$R2" --yes >/dev/null; echo "draft v1" > "$R2/notes/draft.md"
mkrepo "$R2/api"; printf 'api\t-\t-\tno\n' >> "$R2/repos.tsv"; git -C "$R2" add repos.tsv; git -C "$R2" commit -qm repos
git -C "$R2/api" checkout -q --detach; echo d > "$R2/api/d"; git -C "$R2/api" add d; git -C "$R2/api" commit -qm detached-only
CABINET_BACKUP_PASSPHRASE=t "$R2/bin/backup.sh" create "$T/bk2" >/dev/null || fail "backup for restore tests"
mkdir -p "$T/rr2/api"; echo "draft v2" > "$T/rr2/notes-draft.tmp"; mkdir -p "$T/rr2/notes"; mv "$T/rr2/notes-draft.tmp" "$T/rr2/notes/draft.md"; echo mine > "$T/rr2/api/own.txt"
CABINET_BACKUP_PASSPHRASE=t "$R2/bin/backup.sh" restore "$(ls "$T"/bk2/*.enc)" "$T/rr2" >/dev/null || fail "restore with existing files and a detached repo"
[[ "$(cat "$T/rr2/notes/draft.md")" == "draft v1" && "$(cat "$T/rr2/recovered/"*/workspace/notes/draft.md)" == "draft v2" ]] || fail "an untracked file was replaced without a copy"
[[ ! -e "$T/rr2/api/.git" && "$(cat "$T/rr2/api/own.txt")" == mine ]] || fail "a folder with files of its own was turned into a repo"
[[ -n "$(git -C "$T/rr2/recovered/"*/api/repo rev-parse HEAD)" ]] && ! git -C "$T/rr2/recovered/"*/api/repo symbolic-ref -q HEAD >/dev/null || fail "the detached repo was not restored detached into recovered/"
# A workspace with no commits is backed up as its files and restored.
env GIT_CONFIG_GLOBAL="$T/empty-config" "$F" new "$T/nocommit" --yes >/dev/null
CABINET_BACKUP_PASSPHRASE=t "$T/nocommit/bin/backup.sh" create "$T/bk3" >/dev/null || fail "backup of a workspace with no commits"
CABINET_BACKUP_PASSPHRASE=t "$T/nocommit/bin/backup.sh" restore "$(ls "$T"/bk3/*.enc)" "$T/rr3" >/dev/null || fail "restore of a workspace with no commits"
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
[[ ! -e "$H2/$SD/ai.cabinet.pk.brief$SX" && -f "$H2/$SD/ai.cabinet.pk2.brief$SX" ]] || fail "a slug change through a symlinked path left the old schedule"
HOME="$H2" "$F" new "$T/elsewhere3/pk" --yes >/dev/null 2>&1 || fail "the old slug was not released after a slug change"
# Relative repo URLs work in new and config, as in repos.tsv.
(cd "$T" && "$F" new "$T/relnew" --repo ../srcrepo --yes >/dev/null) || fail "a relative --repo was refused"
# A repos.tsv row with an unusable name is skipped with a message, not silently.
printf 'bad name\t-\t-\tno\n' >> "$T/relnew/repos.tsv"
"$T/relnew/bin/doctor.sh" 2>&1 | grep -q 'skipped the row named "bad name"' || fail "an unusable repos.tsv row was skipped without a message"
# The guardrails also deny pushing without hooks and dropping the environment.
for r in 'Bash(*send-pack*)' 'Bash(env -i*)' 'Bash(env -u*)'; do
  j -e --arg r "$r" '$.permissions.deny.includes($r)' "$KIT/guardrails/claude-permissions.json" >/dev/null || fail "missing guardrail $r"
done
  return 0   # a last "check && fail" line must not end the run
}

section "Cursor" "0 19"
s21() {
# The Cursor CLI's rules merge into its config and keep the user's own settings.
H3="$T/home3"; mkdir -p "$H3/.cursor"
printf '{"version":1,"editor":{"vimMode":true},"permissions":{"allow":["Shell(ls)"],"deny":["Shell(rm)"]}}\n' > "$H3/.cursor/cli-config.json"
boot2 "$H3" "$W" >/dev/null
j -e --argjson k "$(cat "$KIT/guardrails/cursor-permissions.json")" \
  '$k.permissions.deny.every((r) => $.permissions.deny.includes(r)) && $.editor.vimMode === true && JSON.stringify($.permissions.allow) == "[\"Shell(ls)\"]" && $.permissions.deny.includes("Shell(rm)")' \
  "$H3/.cursor/cli-config.json" >/dev/null || { cat "$H3/.cursor/cli-config.json"; fail "Cursor rules not merged, or the user's settings lost"; }
# The cursor runner calls the CLI in print mode, with the role as its first instruction.
CB="$T/cursorbin"; mkdir -p "$CB"
printf '#!/bin/sh\nprintf "%%s|" "$@" > "%s/cursor-args"\n' "$T" > "$CB/cursor-agent"; chmod +x "$CB/cursor-agent"
cp "$W/cabinet.env" "$T/env.bak2"; echo 'CABINET_RUNNER="cursor"' >> "$W/cabinet.env"
HOME="$H3" PATH="$CB:$PATH" "$W/bin/job.sh" run brief >/dev/null 2>&1 || fail "the cursor runner failed"
grep -q '^-p|--force|--output-format|json|Act as the chief-of-staff role: read agents/chief-of-staff.md' "$T/cursor-args" || { cat "$T/cursor-args"; fail "the cursor runner did not call the CLI in print mode with the role"; }
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
node "$KIT/test/docs-check.js" "$KIT" || fail "the docs fell behind the code (see above)"
node "$KIT/tools/build-llms-full.js" --check || fail "llms-full.txt is out of date (npm run docs)"
# What version, update and the recipes say matches what they do: the tagline beside the mark, "Nothing
# changed" with git or without, and the commands that commit themselves.
grep -qF "In a terminal it prints the Cabinet mark with the version and the tagline beside it" "$KIT/docs/commands.md" || fail "docs/commands.md does not say cabinet version shows the tagline"
grep -qF "already on that version and nothing changed, it ends with \`Nothing changed: the workspace was already on <version>.\`, git or not." "$KIT/docs/commands.md" || fail "docs/commands.md does not say when update ends with Nothing changed"
sed -n 3p "$KIT/docs/recipes.md" | grep -qF "\`cabinet config\`, \`role add\`, \`role remove\` and \`update\` commit their own change" || fail "docs/recipes.md does not say which commands commit themselves"
# An agent asked to set Cabinet up finds its guide from every way in: the root AGENTS.md (which agent
# tools load first) says so before anything else, and so do the README and llms.txt.
[[ -f "$KIT/docs/agent-setup.md" ]] && head -3 "$KIT/AGENTS.md" | grep -q '(docs/agent-setup.md)' && grep -q '(docs/agent-setup.md)' "$KIT/README.md" \
  && grep -m1 '^- \[' "$KIT/llms.txt" | grep -q 'docs/agent-setup.md' || fail "the agent setup guide is not where an agent looks first"
# Nothing in the kit, its tests or its tools runs python3, perl or jq (AGENTS.md, rule 3); its JavaScript parses.
[[ -z "$(find "$KIT" -name node_modules -prune -o \( -name '*.py' -o -name '*.pl' \) -print)" ]] || fail "a Python or perl file is in the kit; write it in JavaScript"
! grep -rnE "(^|[^a-z.])(python3|perl) +-" --exclude=smoke.sh "$KIT/bin" "$KIT/scripts" "$KIT/test" "$KIT/tools" "$KIT/package.json" || fail "the kit runs python3 or perl; move it to scripts/lib.js"
! grep -rnE "(^|[^a-z.-])jq( |$)" --exclude=smoke.sh "$KIT/bin" "$KIT/scripts" "$KIT/test" "$KIT/tools" "$KIT/package.json" || fail "the kit runs jq; use json (scripts/platform.sh)"
[[ "$(grep -cE "^[^#]*([^a-z.](python3|perl) +-|[^a-z.-]jq +['-])" "$KIT/test/smoke.sh")" == 0 ]] || fail "the tests run python3, perl or jq; use L or j (test/smoke.sh)"
for f in scripts/lib.js test/docs-check.js tools/build-llms-full.js tools/build-brand.js brand/render-film.js brand/demo/captured.js; do node --check "$KIT/$f" || fail "$f does not parse"; done
# json: options for input and output, and a JavaScript expression.
[[ "$(printf '{"a":[1,2]}\n' | j -c '$.a')" == "[1,2]" && "$(printf '{"x":1}\n{"x":2}\n' | j -s -c '$.map((v) => v.x)')" == "[1,2]" \
  && "$(printf 'a\tb\n\n' | j -R -c '$')" == '["a\tb",""]' && "$(j -n -c '$args' --args "a b" "")" == '["a b",""]' \
  && "$(j -n -r --arg v 'x"y' --argjson n 2 '$v + $n')" == 'x"y2' && "$(j -n -r --each '["a", 1]')" == $'a\n1' \
  && "$(j -n -c '[num("12"), num(""), str(""), sum([]), sum([1, 2])]')" == "[12,null,null,null,3]" && -z "$(j -n 'undefined')" ]] || fail "json: input and output"
j -n -e 'false' >/dev/null && fail "json -e: false is a failure"
j -n -e '0' >/dev/null || fail "json -e: only null, false and nothing fail"
rc=0; printf 'nope' | j '$' 2>/dev/null || rc=$?; [[ $rc == 2 ]] || fail "json: input that is not JSON exits 2"
rc=0; j -n 'obj([1])' 2>/dev/null || rc=$?
[[ $rc == 5 && "$(j -n -c '[obj(null), list(undefined)]')" == "[{},[]]" ]] || fail "json: obj and list refuse another shape"
[[ "$(printf '\357\273\277{"a":1}' | j -c '$')" == '{"a":1}' ]] || fail "json: a byte-order mark before the JSON"
# --exact: refuse (3) what would be written back differently, take what would not.
for x in '{"a":1.0}' '{"a":1e3}' '{"a":12345678901234567890}' '{"a":-0}' '{"2":1}'; do
  rc=0; printf '%s' "$x" | j --exact '$' >/dev/null 2>&1 || rc=$?; [[ $rc == 3 ]] || fail "json --exact took $x"
done
x='{"a":[1,2.5,-3,"1.0"],"k\"2":0.1,"b":1e-7,"3x":0}'
[[ "$(printf '%s' "$x" | j --exact -c '$')" == "$x" ]] || fail "json --exact refused what it writes as it is"
node "$KIT/tools/build-brand.js" --check || fail "brand/assets/ or docs/logo.svg is out of date with brand/tokens.json (npm run brand)"
for f in BRAND.md tokens.json text-paths.json; do [[ -f "$KIT/brand/$f" ]] || fail "brand/$f is missing"; done
j -e '!!$.color.ink.value && !!$.status_color.fix.light && $.mark.places == 8' "$KIT/brand/tokens.json" >/dev/null || fail "brand/tokens.json"
repo="$(j -r '$.repository.url' "$KIT/package.json" | sed 's/^git+//')"
grep -qF "git clone $repo " "$KIT/README.md" || fail "the README's clone command does not match the repository in package.json"
# The package installs only where the README says the kit runs: macOS and Linux.
j -e '$.publishConfig.access == "public"' "$KIT/package.json" >/dev/null || fail "the scoped package would publish as private"
j -e 'JSON.stringify($.os) == "[\"darwin\",\"linux\"]"' "$KIT/package.json" >/dev/null && grep -q '^- \*\*Platform:\*\* macOS and Linux ' "$KIT/README.md" || fail "package.json os and the README's platform disagree"
for p in .DS_Store node_modules/ '*.tgz'; do grep -qxF "$p" "$KIT/.gitignore" || fail ".gitignore does not ignore $p"; done
# CABINET.md holds what every agent needs on every session; the rest is in core/rules/, each file named
# from it with when to read it, and every reference to one names a file that exists.
w="$(wc -w < "$KIT/core/CABINET.md")"; ((w <= 3400)) || fail "CABINET.md has $w words, over its 3400: move what only some roles or tasks need to core/rules/"
for f in "$KIT"/core/rules/*.md; do
  grep -q "^   | \`.cabinet/rules/${f##*/}\` | " "$KIT/core/CABINET.md" || fail "CABINET.md does not say when to read .cabinet/rules/${f##*/}"
done
for r in $(grep -rhoE '\.cabinet/rules/[a-z-]+\.md' "$KIT/core" "$KIT/roles" "$KIT/scripts" "$KIT/bin" "$KIT/templates" "$KIT/docs" | sort -u); do
  [[ -f "$KIT/core/rules/${r##*/}" ]] || fail "$r is named, but the kit has no core/rules/${r##*/}"
done
  return 0   # a last "check && fail" line must not end the run
}

section "no project data in the kit" ""
s24() {
# No local paths anywhere (the brand demo's made-up person, /Users/maya, is the one exception); and, when set,
# none of the owner's private words (CABINET_PRIVATE_WORDS="word1 word2", kept out of this file so it names none).
p="$(grep -rIoh -E '/(Users|home)/[a-z][A-Za-z0-9_-]*' "$KIT" --exclude-dir=.git --exclude-dir=node_modules --exclude=smoke.sh | sort -u | grep -vx '/Users/maya' || true)"
[[ -z "$p" ]] || fail "a local path in the kit: $p"
for w in ${CABINET_PRIVATE_WORDS:-}; do
  # Whole words, in any case: "nova" is caught in "Nova" and "nova.io", not in "supernova" or "novel".
  ! grep -rIilw -e "$w" "$KIT" --exclude-dir=.git --exclude-dir=node_modules --exclude=LICENSE --exclude=package.json || fail "a private word in the kit: $w"
done
  return 0   # a last "check && fail" line must not end the run
}


section "commands from anywhere in a workspace or its project" "0 3"
s25() {
mkdir -p "$W/specs/deep" "$I/src/deep" "$T/nowhere"
(cd "$W/specs/deep" && "$F" handoff list) >/dev/null || fail "handoffs from a workspace subfolder"
(cd "$I/src/deep" && "$F" doctor --json) | j -e '$.workspace.endsWith("/acme-app/cabinet")' >/dev/null || fail "doctor from deep inside the project"
(cd "$I/src/deep" && "$F" status) | grep -q 'no kit file edited' || fail "status from deep inside the project"
out="$(cd "$T/nowhere" && "$F" doctor 2>&1)" && fail "doctor outside any workspace succeeded"
echo "$out" | grep -q 'not inside a cabinet workspace' || fail "unclear error outside a workspace: $out"
"$F" help | grep -q '^  next ' || fail "help"
rc=0; "$F" bogus >/dev/null 2>&1 || rc=$?; [[ $rc == 2 ]] || fail "an unknown command exits $rc, not 2"
# An unknown command gets a short answer, never the whole help: the closest command when one is near.
out="$("$F" docter 2>&1 || true)"
[[ "$(wc -l <<<"$out" | tr -d ' ')" -le 3 ]] && grep -qx "Did you mean: cabinet doctor" <<<"$out" && grep -qx "Every command: cabinet help" <<<"$out" || fail "a mistyped command: $out"
out="$("$F" 'handoff list' 2>&1 || true)"; grep -qx "Did you mean: cabinet handoff list" <<<"$out" || fail "two words typed as one: $out"
out="$("$F" zzzzzz 2>&1 || true)"; ! grep -q 'Did you mean' <<<"$out" && [[ "$(wc -l <<<"$out" | tr -d ' ')" -le 2 ]] || fail "a word near no command: $out"
  return 0   # a last "check && fail" line must not end the run
}

section "next" "0"
s26() {
before="$(git -C "$W" status --porcelain)"
out="$(cd "$W" && "$F" next)"
echo "$out" | grep -q '^Next in Demo Co' && echo "$out" | grep -q 'Fill the TBDs in AGENTS.md' && echo "$out" | grep -q 'cabinet bootstrap' || { echo "$out"; fail "next"; }
(cd "$T" && "$F" next) | grep -q 'Not inside a cabinet workspace' || fail "next outside a workspace"
(cd "$W/specs" && "$F" next --json) | j -e '$.project == "Demo Co" && $.steps.some((s) => s.id == "tbd") && $.steps.find((s) => s.id == "bootstrap")?.command == "cabinet bootstrap"' >/dev/null || fail "next --json"
# Once every TBD is filled, the template's own instructions, which quote `TBD` as code, ask for nothing.
cp "$W/AGENTS.md" "$T/agents-tbd.bak"
node -e 'const fs = require("fs"); const f = process.argv[1]; fs.writeFileSync(f, fs.readFileSync(f, "utf8").split("\n").map((l) => l.split(/(`[^`]*`)/).map((p) => p.startsWith("`") ? p : p.replaceAll("TBD", "filled")).join("")).join("\n"))' "$W/AGENTS.md"
grep -qF '`TBD`' "$W/AGENTS.md" || fail "next test setup: the template no longer quotes TBD"
(cd "$W" && "$F" next --json) | j -e '!$.steps.some((s) => s.id == "tbd")' >/dev/null || fail "next asks to fill TBDs that are only quoted in the template's instructions"
cp "$T/agents-tbd.bak" "$W/AGENTS.md"
(cd "$T" && "$F" next --json) | j -e '$.workspace == null && $.steps[0].id == "start"' >/dev/null || fail "next --json outside a workspace"
[[ "$(git -C "$W" status --porcelain)" == "$before" ]] || fail "next changed the workspace"
  return 0   # a last "check && fail" line must not end the run
}

section "doctor summary, json and fix" "0"
s27() {
rm "$W/agents/qa.md"
out="$(cd "$W" && "$F" doctor 2>&1)" && fail "doctor passed with a role missing"
echo "$out" | head -1 | grep -Eq '^[0-9]+ thing\(s\) need attention:' && echo "$out" | grep -q 'cabinet doctor --fix can run:.*role build' || { echo "$out"; fail "doctor summary"; }
# Status colors only in a terminal, and none with NO_COLOR or when the output is not a terminal.
[[ "$out" != *$'\033['* ]] || fail "doctor colored output that is not a terminal"
out="$(cd "$W" && in_tty "$F" doctor)"
[[ "$out" == *$'\033[31mFIX'* && "$out" == *$'\033[32mok'* ]] || fail "doctor in a terminal should color FIX red and ok green"
out="$(cd "$W" && NO_COLOR=1 in_tty "$F" doctor)"
[[ "$out" != *$'\033['* ]] || fail "doctor colored its output with NO_COLOR set"
(cd "$W" && "$F" doctor --json) | j -e '$.problems > 0 && $.can_fix.includes("roles") && $.results.length > 3
  && $.results.every((r) => /^[a-z]+\.[a-z-]+$/.test(r.id)) && $.results.findLast((r) => r.id == "kit.roles")?.level == "fix"' >/dev/null || fail "doctor --json IDs"
(cd "$W" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "schedules.node" && r.level == "ok")' >/dev/null || fail "doctor: scheduled jobs should find node"
(cd "$W" && "$F" doctor --fix 2>&1 </dev/null) | grep -q 'run it in a terminal, or add --yes' || fail "doctor --fix ran without asking"
(cd "$W" && "$F" doctor --fix --yes) >/dev/null 2>&1 || true
[[ -f "$W/agents/qa.md" ]] || fail "doctor --fix --yes did not rebuild the roles"
  return 0   # a last "check && fail" line must not end the run
}

section "remove" "2"
s28() {
"$F" new "$T/gone" --yes >/dev/null; G="$(cd "$T/gone" && pwd -P)"
fake_sched "$HOME/$SD/ai.cabinet.gone.brief$SX" "$G/bin/job.sh"
fake_sched "$HOME/$SD/ai.cabinet.gone.other$SX" /elsewhere/bin/job.sh
"$F" -C "$G" remove --dry-run | grep -q 'schedule ai.cabinet.gone.brief$' && [[ -d "$G" ]] || fail "remove --dry-run"
"$F" -C "$G" remove --yes >/dev/null 2>&1 && fail "remove deleted commits that exist on no remote"
[[ -d "$G" ]] || fail "a refused remove deleted the workspace"
printf 'nope\n' > "$T/typed"; CABINET_TTY="$T/typed" "$F" -C "$G" remove --force >/dev/null 2>&1 && fail "remove went ahead with the wrong slug typed"
printf 'gone\n' > "$T/typed"; CABINET_TTY="$T/typed" "$F" -C "$G" remove --force >/dev/null || fail "remove"
[[ ! -e "$G" && ! -e "$HOME/$SD/ai.cabinet.gone.brief$SX" && -e "$HOME/$SD/ai.cabinet.gone.other$SX" ]] || fail "remove: folder, own schedule, or another's schedule"
rm "$HOME/$SD/ai.cabinet.gone.other$SX"
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
jobs="$(cd "$W/specs/deep" && bash -c 'eval "$("$1" completion bash)"; COMP_WORDS=(cabinet job run ""); COMP_CWORD=3; _cabinet; echo "${COMPREPLY[*]}"' _ "$F")"
[[ " $jobs " == *" brief "* && " $jobs " == *" weekly-review "* ]] || fail "completion of job names for cabinet job run: $jobs"
rm "$W/jobs/weekly-review.job"
mkdir -p "$T/npmshim"; printf '#!/bin/sh\necho 9.9.9\n' > "$T/npmshim/npm"; chmod +x "$T/npmshim/npm"
PATH="$T/npmshim:$PATH" "$F" -C "$W" outdated | grep -q 'latest: cabinet 9.9.9' || fail "outdated"
printf '#!/bin/sh\nexit 1\n' > "$T/npmshim/npm"; PATH="$T/npmshim:$PATH" "$F" -C "$W" outdated | grep -q 'latest: unknown' || fail "outdated offline"
"$F" -C "$W" status --json | j -e '$.version == $.kit_version && $.edited.length == 0' >/dev/null || fail "status --json"
  return 0   # a last "check && fail" line must not end the run
}


section "help, --help and help --json come from one command table" ""
s31() {
# The full help shows each group once, every command under its own group.
heads="$("$F" help | grep -E '^[A-Z][a-z]+$')"
[[ "$(sort <<<"$heads" | uniq -d)" == "" ]] || fail "help shows a group twice: $(tr '\n' ' ' <<<"$heads")"
[[ "$(wc -l <<<"$heads" | tr -d ' ')" == "$(commands_table_groups="$(sed -n '/^commands_table() {/,/^TABLE$/p' "$KIT/bin/cabinet" | awk -F'\t' '$1 == "C" {print $2}' | sort -u)"; wc -l <<<"$commands_table_groups" | tr -d ' ')" ]] || fail "help leaves a group out"
mkdir -p "$T/plain"
(cd "$T/plain" && "$F" doctor --help) | grep -q -- '--fix' || fail "doctor --help outside a workspace"
"$F" remove -h | grep -q '^Usage: cabinet remove \[options\]' || fail "remove -h"
"$F" help config | grep -q -- '--backup-time <time>' || fail "help <command>"
"$F" help --json | j -e '$.name == "cabinet" && $.commands.length > 20 && $.commands.some((c) => c.name == "remove")' >/dev/null || fail "help --json"
"$F" help remove --json | j -e '$.commands.length == 1 && $.commands[0].options.some((o) => o.name == "--force")' >/dev/null || fail "help <command> --json"
"$F" help nope >/dev/null 2>&1 && fail "help for an unknown command succeeded"
# Completion offers the table's options for each command.
w="$(bash -c 'eval "$("$1" completion bash)"; COMP_WORDS=(cabinet remove --d); COMP_CWORD=2; _cabinet; echo "${COMPREPLY[*]}"' _ "$F")"
[[ " $w " == *" --delete-key "* && " $w " == *" --dry-run "* ]] || fail "completion of options from the table: $w"
  return 0   # a last "check && fail" line must not end the run
}


section "a teammate's machine: no schedules, its own backups" "2"
s32() {
P="$T/team-app"; mkrepo "$P"; echo '{"name":"team-app"}' > "$P/package.json"; git -C "$P" add -A; git -C "$P" commit -qm pkg
(cd "$P" && "$F" init --yes --inside --shared) >/dev/null; git -C "$P" add -A; git -C "$P" commit -qm cabinet
LA="$HOME/$SD/ai.cabinet.team-app.brief$SX"; mkdir -p "$P/src"
(cd "$P/src" && "$F" bootstrap) >/dev/null 2>&1; [[ -f "$LA" ]] || fail "bootstrap did not schedule the brief"
git -C "$P" add -A; git -C "$P" commit -qm "the project's builder"   # the first bootstrap gives the project its builder
(cd "$P/src" && "$F" bootstrap --no-schedules) >/dev/null 2>&1 || true
[[ ! -f "$LA" ]] && grep -qx 'CABINET_SCHEDULES="off"' "$P/cabinet/cabinet.local.env" || fail "--no-schedules"
[[ -z "$(git -C "$P" status --porcelain --untracked-files=all)" ]] || { git -C "$P" status --porcelain; fail "cabinet.local.env shows in the project's git"; }
(cd "$P" && "$F" bootstrap) >/dev/null 2>&1 || true; [[ ! -f "$LA" ]] || fail "a plain bootstrap forgot --no-schedules"
(cd "$P" && "$F" doctor --json) | j -e '$.results.filter((r) => r.id == "schedules.off").length == 1 && !$.results.some((r) => r.id == "schedules.job")' >/dev/null || fail "doctor with schedules off"
(cd "$P" && "$F" next --json) | j -e '!$.steps.some((s) => s.id == "bootstrap")' >/dev/null || fail "next asks for bootstrap on a machine that schedules nothing"
(cd "$P" && "$F" bootstrap --schedules) >/dev/null 2>&1 || true
[[ -f "$LA" && ! -e "$P/cabinet/cabinet.local.env" ]] || fail "--schedules"
rc=0; (cd "$P" && "$F" bootstrap --nope) >/dev/null 2>&1 || rc=$?; [[ $rc == 2 ]] || fail "bootstrap with an unknown option exits $rc, not 2"
# Backups for this machine only: cabinet.local.env, never cabinet.env, never in git.
BL="$HOME/$SD/ai.cabinet.team-app.backup$SX"
(cd "$P/src" && "$F" config --this-machine --backup-dir "$T/team-bk" --apply) >/dev/null 2>&1 || true
grep -q '^CABINET_BACKUP_DIR=".*/team-bk"$' "$P/cabinet/cabinet.local.env" && grep -qx 'CABINET_BACKUP_DIR=""' "$P/cabinet/cabinet.env" || fail "--this-machine --backup-dir"
[[ -f "$BL" ]] && grep -q 'team-bk' "$BL" || fail "--this-machine --apply did not schedule this machine's backup"
[[ -z "$(git -C "$P" status --porcelain --untracked-files=all)" ]] || { git -C "$P" status --porcelain; fail "a per-machine backup setting shows in git"; }
(cd "$P" && "$F" config --this-machine --name Other) >/dev/null 2>&1 && fail "--this-machine changed a shared setting"
(cd "$P" && "$F" config --this-machine --backup-dir "$P/cabinet/bk") >/dev/null 2>&1 && fail "--this-machine accepted a backup folder inside the workspace"
(cd "$P" && "$F" config --yes --dry-run --backup-dir "$T/shared-bk") | grep -q 'this machine keeps its own folder' || fail "config did not say this machine keeps its own folder"
(cd "$P" && "$F" config --this-machine --backup-dir off --apply) >/dev/null 2>&1 || true
[[ ! -f "$BL" ]] || fail "--this-machine --backup-dir off kept the backup schedule"
(cd "$P" && "$F" doctor --json) | j -e '$.results.findLast((r) => r.id == "backups.enabled")?.message.includes("on this machine")' >/dev/null || fail "doctor with backups off on this machine"
(cd "$P" && "$F" config --this-machine --clear) >/dev/null 2>&1 || true
[[ ! -e "$P/cabinet/cabinet.local.env" ]] || { cat "$P/cabinet/cabinet.local.env"; fail "--clear left backup lines"; }
(cd "$P" && "$F" config --this-machine --clear) | grep -q 'already follows cabinet.env' || fail "a second --clear"
  return 0   # a last "check && fail" line must not end the run
}


section "guides: the project's own standing documents" "0"
s33() {
git -C "$W" ls-files --error-unmatch guides/README.md >/dev/null 2>&1 || fail "guides/ is not placed and tracked"
grep -q '^## Guides$' "$W/AGENTS.md" && grep -q 'Guides' "$W/CABINET.md" || fail "the Guides table or its rule is missing"
(cd "$W" && "$F" doctor --json) | j -e 'JSON.stringify($.results.filter((r) => r.section == "Guides")) == JSON.stringify([{level: "ok", section: "Guides", id: "guides.listed", message: "every guide is listed in AGENTS.md"}])' >/dev/null || fail "doctor flags a fresh workspace's guides"
mkdir -p "$W/guides/legal"; echo "Voice: plain." > "$W/guides/brand.md"; echo terms > "$W/guides/legal/terms.md"
[[ -n "$(git -C "$W" status --porcelain -- guides/brand.md)" ]] || fail "a new guide is not seen by git"
j="$(cd "$W" && "$F" doctor --json || true)"
j -e '$.results.filter((r) => r.id == "guides.listed" && r.level == "fix").length == 2' <<<"$j" >/dev/null || fail "doctor missed an unlisted guide"
L replace-line "$W/AGENTS.md" "| none yet |" $'| `guides/brand.md` | voice | every agent |\n| `guides/legal/terms.md` | terms | qa |\n| `guides/gone.md` | old | qa |'
j="$(cd "$W" && "$F" doctor --json || true)"
j -e '!$.results.some((r) => r.id == "guides.listed" && r.level == "fix") && JSON.stringify($.results.filter((r) => r.id == "guides.exists").map((r) => r.message)) == JSON.stringify(["AGENTS.md lists guides/gone.md, which does not exist"])' <<<"$j" >/dev/null || { j -c --each '$.results.filter((r) => r.section == "Guides")' <<<"$j"; fail "doctor on listed and missing guides"; }
L drop-text "$W/AGENTS.md" "guides/gone.md"; rm -rf "$W/guides/brand.md" "$W/guides/legal"
L replace-line "$W/AGENTS.md" '| `guides/brand.md` |' "| none yet | x | |"; L drop-text "$W/AGENTS.md" "guides/legal"
  return 0   # a last "check && fail" line must not end the run
}


section "list every workspace on this machine" "0"
s34() {
"$F" new "$T/listed-old" --yes >/dev/null; echo 0.0.1 > "$T/listed-old/.cabinet/version"
"$F" new "$T/listed-gone" --yes >/dev/null; rm -rf "$T/listed-gone"
mkdir -p "$T/away"; out="$(cd "$T/away" && "$F" list)"
echo "$out" | grep -Eq '^  demo-co +Demo Co +[0-9.]+ ' || { echo "$out"; fail "list: the workspace row"; }
echo "$out" | grep -Eq '^  listed-old +listed-old +0\.0\.1\* ' && echo "$out" | grep -q '^\* not the installed kit' || { echo "$out"; fail "list: an older kit"; }
echo "$out" | grep -Eq '^  listed-gone +- .*folder gone' && echo "$out" | grep -q "Folder gone for listed-gone: .*rm -r ~/$LOGS/listed-gone" || { echo "$out"; fail "list: a deleted workspace"; }
j="$(cd "$T/away" && "$F" list --json)"
j -e '((w) => w.project == "Demo Co" && w.exists === true && typeof w.doctor_problems == "number" && typeof w.waiting_on_owner == "number")($.find((w) => w.slug == "demo-co"))' <<<"$j" >/dev/null || fail "list --json: a workspace"
j -e '((g, o) => g.exists === false && g.doctor_problems == null && !!o.update_available)($.find((w) => w.slug == "listed-gone"), $.find((w) => w.slug == "listed-old"))' <<<"$j" >/dev/null || fail "list --json: gone and older"
(cd "$T/away" && "$F" next) | grep -q 'cabinet list shows them' || fail "next outside a workspace does not point at list"
rm -rf "$HOME/$LOGS/listed-gone"; "$F" -C "$T/listed-old" remove --yes --force >/dev/null
"$F" list --json | j -e '!$.some((w) => w.slug == "listed-old" || w.slug == "listed-gone")' >/dev/null || fail "a removed workspace is still listed"
  return 0   # a last "check && fail" line must not end the run
}


section "digest gathers every sign-off queue" "0"
s35() {
"$F" new "$T/dg-a" --name "Digest A" --yes >/dev/null; "$F" new "$T/dg-b" --yes >/dev/null; "$F" new "$T/dg-c" --yes >/dev/null
printf '# Brief\n\n## Sign-off queue\n\n1. **Publish the page?** A. now. B. later. [page.png](specs/evidence/H-1/page.png)\n\n2. **Spend $20?**\n\n## Verification\n\nNone.\n\n## Actions for the owner\n\n- Push api main (abc1234).\n\n## Per agent queue\n\nqa: 1\n' > "$T/dg-a/BRIEF.md"
printf '# Brief\n\nNo headings here.\n' > "$T/dg-b/BRIEF.md"; touch -t 202001010700 "$T/dg-b/BRIEF.md"
out="$(cd "$T" && "$F" digest)"
echo "$out" | grep -q '^== Digest A' && echo "$out" | grep -q '^  1\. \*\*Publish the page?\*\*' && echo "$out" | grep -q '^  2\. \*\*Spend \$20?\*\*' || { echo "$out"; fail "digest: the queue"; }
echo "$out" | grep -q '^  - Push api main' && ! echo "$out" | grep -q 'qa: 1' && ! echo "$out" | grep -q '^  None\.' || { echo "$out"; fail "digest: only the queue and the actions"; }
echo "$out" | grep -q 'Older than a day and a half' && echo "$out" | grep -q 'no "## Sign-off queue" heading' && echo "$out" | grep -q 'No brief yet. Write one: cd .*dg-c && cabinet brief' || { echo "$out"; fail "digest: stale, headless or missing briefs"; }
! echo "$out" | grep -q ' $' || fail "digest prints trailing spaces"
echo "$out" | grep -q '](/.*/dg-a/specs/evidence/H-1/page.png)$' || { echo "$out"; fail "digest: evidence links do not open from outside the workspace"; }
j="$("$F" digest --json)"
j -e '((d) => d.project == "Digest A" && d.sign_off_queue.startsWith("1. **Publish") && d.sign_off_queue.includes("2. **Spend") && d.actions_for_owner == "- Push api main (abc1234)." && d.brief_stale === false)($.find((w) => w.slug == "dg-a"))' <<<"$j" >/dev/null || fail "digest --json: a full brief"
j -e '((b, c) => b.brief_stale === true && b.queue_heading_found === false && c.brief_written == null && c.queue_heading_found == null)($.find((w) => w.slug == "dg-b"), $.find((w) => w.slug == "dg-c"))' <<<"$j" >/dev/null || fail "digest --json: stale and missing"
grep -q '^Write `BRIEF.md` as .* in this order, short, each part under a `## ` heading' "$KIT/roles/chief-of-staff.md" || fail "the brief headings rule left the chief-of-staff role"
# What each project's agent runs cost this week, against its budget, and the total.
(cd "$T/dg-a" && "$F" config --yes --budget 4) >/dev/null && (cd "$T/dg-b" && "$F" config --yes --runner codex) >/dev/null || fail "digest test setup: budget or runner"
mkdir -p "$HOME/$LOGS/dg-a"; printf '%s\tbrief\tclaude\t3.5\n' "$(date +%s)" > "$HOME/$LOGS/dg-a/spend.tsv"
out="$(cd "$T" && "$F" digest)"
echo "$out" | grep -q '^Agent runs this week: \$3.50 of the \$4 budget (87%). What each job cost: cd .*dg-a && cabinet job list$' \
  && echo "$out" | grep -q '^Agent runs this week: \$0.00, no budget set.$' && ! echo "$out" | awk '/^== / { b = ($2 == "dg-b") } b' | grep -q '^Agent runs' || { echo "$out"; fail "digest: each project's spend"; }
echo "$out" | head -1 | grep -q ' 1 project(s) at 80% of their budget or more. Agent runs cost \$3.50 this week in all.$' || { echo "$out" | head -1; fail "digest: the spend in the summary"; }
j -e '((a, b) => a.spend_this_week_usd == 3.5 && a.budget_usd == 4 && b.spend_this_week_usd == null && b.budget_usd == null)($.find((w) => w.slug == "dg-a"), $.find((w) => w.slug == "dg-b"))' <<<"$("$F" digest --json)" >/dev/null || fail "digest --json: spend and budget"
# Written to a file, with a notification (a fake osascript or notify-send that only logs), and on a schedule.
"$F" digest --write "$T/dg/out.md" --notify >/dev/null || fail "digest --write"
head -1 "$T/dg/out.md" | grep -Eq '^# cabinet digest, [0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}, ' && grep -q '^  1\. \*\*Publish the page?\*\*' "$T/dg/out.md" || fail "the written digest"
grep -Eq '[0-9]+ decision\(s\), [0-9]+ action\(s\) and [0-9]+ handoff\(s\) wait on you in [0-9]+ of [0-9]+ project\(s\)\. [0-9]+ brief\(s\) late' "$T/dg/out.md" || { head -3 "$T/dg/out.md"; fail "the digest's counts line"; }
grep -E '^(osascript|notify-send) ' "$T/fake.log" > "$T/notify.log" || true
grep -q 'wait on you in' "$T/notify.log" && grep -q "Open .*/dg/out.md" "$T/notify.log" || { cat "$T/notify.log"; fail "the notification"; }
PL="$HOME/$SD/ai.cabinet-digest$SX"
"$F" digest --schedule "Sun,mon 8:30 AM" --notify >/dev/null || fail "digest --schedule on days"
{ [[ "$SCH" != launchd ]] || plutil -lint -s "$PL"; } && [[ "$(cal "$PL")" == "0:8:30 1:8:30" ]] || fail "the digest schedule's days and time"
cmd_of "$PL" | j -e --arg l "/$LOGS/digest.md" '$[1] == "digest" && $[2] == "--write" && $[3].endsWith($l) && $[4] == "--notify"' >/dev/null || fail "the digest schedule's command"
"$F" digest --schedule "7:15 am" --file "$T/dg/sched.md" >/dev/null || fail "digest --schedule daily"
[[ "$(cal "$PL")" == "*:7:15" ]] && cmd_of "$PL" | j -e '$.at(-1).endsWith("/dg/sched.md")' >/dev/null || fail "changing the digest schedule"
"$F" digest | grep -q '^Scheduled, every day at 7:15 AM: cabinet digest --write .*sched.md' || fail "digest does not say it is scheduled"
"$F" digest --schedule --notify >/dev/null || fail "digest --schedule with no time"
[[ "$(cal "$PL")" == "*:10:0" ]] && cmd_of "$PL" | j -e '$.at(-1) == "--notify"' >/dev/null || fail "the default digest schedule is not every day at 10:00 AM"
"$F" digest --schedule >/dev/null && [[ "$(when_of "$PL")" == "10:00 AM" ]] || fail "digest --schedule as the last argument"
for bad in 25:00 "fun 08:00" "mon"; do "$F" digest --schedule "$bad" >/dev/null 2>&1 && fail "digest accepted the schedule '$bad'"; done
"$F" digest --file x.md >/dev/null 2>&1 && fail "--file without --schedule was accepted"
"$F" digest --schedule off | grep -q 'Stopped the scheduled digest' && [[ ! -f "$PL" ]] || fail "digest --schedule off"
"$F" digest | grep -q '^Not scheduled' || fail "digest after the schedule stopped"
for x in dg-a dg-b dg-c; do "$F" -C "$T/$x" remove --yes --force >/dev/null; done
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
(cd "$W" && "$F" config --yes --brief-time "Friday,saturday 9 am") >/dev/null || fail "config --brief-time with day names"
grep -qx 'WHEN="fri,sat 9:00 AM"' "$W/jobs/brief.job" || { grep WHEN "$W/jobs/brief.job"; fail "the brief time is not stored in its short form"; }
"$W/bin/bootstrap.sh" >/dev/null 2>&1 || true
PB="$HOME/$SD/ai.cabinet.demo-co.brief$SX"
[[ "$(cal "$PB")" == "5:9:0 6:9:0" ]] || fail "the brief schedule on Friday and Saturday"
(cd "$W" && "$F" doctor --json || true) | j -e '((r) => r.level == "ok" && r.message.includes("Fri, Sat at 9:00 AM"))($.results.findLast((r) => r.id == "schedules.job" && r.message.includes("brief")))' >/dev/null || fail "doctor on a two-day brief"
(cd "$W" && "$F" config --yes --brief-time "funday 9:00") >/dev/null 2>&1 && fail "config accepted an unknown day"
# A job written by hand, with a full day name and a one-digit hour.
printf 'AGENT=qa\nWHEN="Saturday 7:30 PM"\nPROMPT="x"\n' > "$W/jobs/sat.job"
"$W/bin/bootstrap.sh" >/dev/null 2>&1 || true
[[ "$(cal "$HOME/$SD/ai.cabinet.demo-co.sat$SX")" == "6:19:30" ]] || fail "a hand-written job with a full day name"
rm "$W/jobs/sat.job"; (cd "$W" && "$F" config --yes --brief-time "7 AM") >/dev/null; "$W/bin/bootstrap.sh" >/dev/null 2>&1 || true
[[ "$(cal "$PB")" == "*:7:0" && ! -e "$HOME/$SD/ai.cabinet.demo-co.sat$SX" ]] || fail "back to every day"
# The digest takes the same forms.
"$F" digest --schedule "Saturday 10 AM" | grep -q 'Scheduled the digest, Sat at 10:00 AM' || fail "digest --schedule with a full day name"
[[ "$(cal "$HOME/$SD/ai.cabinet-digest$SX")" == "6:10:0" ]] || fail "the digest on Saturdays"
"$F" digest --schedule off >/dev/null
  return 0   # a last "check && fail" line must not end the run
}

section "secret check: caught before a commit, a marked false alarm passes" "0 5 14"
s37() {
# Fake values are built from pieces, so no key-shaped text is ever in the kit itself.
"$W/bin/secret.sh" check >/dev/null 2>&1 || fail "a fresh workspace has a false alarm: $("$W/bin/secret.sh" check 2>&1)"
grep -q 'bin/secret.sh check --staged' "$W/.git/hooks/pre-commit" && [[ -x "$W/.git/hooks/pre-commit" ]] || fail "bootstrap did not place the secrets hook"
key="AKIA""QWERTYUIOPASDFGH"
printf '# Keys\n\nThe deploy key: %s\n' "$key" > "$W/guides/keys.md"
git -C "$W" add guides/keys.md
out="$(git -C "$W" commit -qm "keys" 2>&1)" && fail "a commit with a key in a guide was not refused"
echo "$out" | grep -q 'guides/keys.md:3: an AWS access key' && ! echo "$out" | grep -q "$key" || fail "the refusal does not name the file and line, or shows the key: $out"
out="$("$W/bin/doctor.sh" 2>&1 || true)"   # cabinet secret check and the doctor see it before it is staged, too
echo "$out" | grep -q "FIX   possible secrets in the workspace's files.*guides/keys.md:3: an AWS access key" && ! echo "$out" | grep -q "$key" || fail "the doctor missed the key, or showed it"
(cd "$W/specs" && "$F" secret check >/dev/null 2>&1) && fail "cabinet secret check missed the key"
printf 'DB_PASSWORD=%s\n' "hunter2""hunter2" >> "$W/guides/keys.md"; git -C "$W" add guides/keys.md
git -C "$W" commit -qm "keys" >/dev/null 2>&1 && fail "a commit setting a password was refused only for the key"
sedi 's/$/ not-a-secret/' "$W/guides/keys.md"; git -C "$W" add guides/keys.md
git -C "$W" commit -qm "a marked false alarm" >/dev/null 2>&1 || fail "a marked false alarm was refused"
"$W/bin/secret.sh" check >/dev/null 2>&1 || fail "a marked false alarm is still reported"
git -C "$W" rm -q guides/keys.md && git -C "$W" commit -qm "drop keys" || fail "cleanup"
# A file with no newline at its end does not hide the next file's key, and a name with a space keeps its line number.
printf 'last line with no newline' > "$W/guides/a-nonl.md"; printf 'x\n%s\n' "$key" > "$W/guides/b key.md"
out="$("$W/bin/secret.sh" check 2>&1)" && fail "the key after a file with no last newline was missed"
echo "$out" | grep -qF 'guides/b key.md:2: an AWS access key' && ! echo "$out" | grep -q 'a-nonl.md' || fail "the wrong file or line was named: $out"
git -C "$W" add guides; out="$(git -C "$W" commit -qm "keys" 2>&1)" && fail "a staged key in a file named with a space was not refused"
echo "$out" | grep -qF 'guides/b key.md:2: an AWS access key' || fail "the staged scan lost the line number of a file named with a space: $out"
git -C "$W" rm -qf "guides/a-nonl.md" "guides/b key.md" >/dev/null || fail "cleanup"
# A shared cabinet/ is committed with the project: no hook of its own, its files still scanned.
"$S/cabinet/bin/doctor.sh" 2>&1 | grep -q 'ok    the workspace is committed with the project, whose own hooks run' || fail "shared layout: secrets hook check"
[[ ! -e "$S/.git/hooks/pre-commit" ]] || fail "a hook was placed in the project's own git"
  return 0   # a last "check && fail" line must not end the run
}

section "backup verify: a good archive passes, a damaged or incomplete one fails" "3"
s38() {
VH="$T/vhome" VB="$T/vbk" C="$I/cabinet"; mkdir -p "$VH"
bk() { HOME="$VH" CABINET_BACKUP_PASSPHRASE="${PW:-t}" "$C/bin/backup.sh" "${@:-create}" "$VB" 2>&1; }
bk >/dev/null || fail "backup for verify"
out="$(bk verify)" || fail "a good archive failed to verify: $out"
echo "$out" | grep -q '^  workspace: restores exactly as it is now' && echo "$out" | grep -q '^  acme-app: restores exactly as it is now' || fail "verify did not check each repo: $out"
[[ "$(ls "$VB" | wc -l | tr -d ' ')" == 1 ]] && [[ -f "$VH/$LOGS/acme-app/backup-verified" ]] || fail "verify changed the backup folder, or did not record the good result"
bk verify --json | j -e '$.ok === true && $.problems == 0 && $.results.some((r) => r.repo == "acme-app") && /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/.test($.backed_up)' >/dev/null || fail "backup verify --json"
# Work done since the backup is reported, not a problem.
echo change >> "$I/f"; git -C "$I" commit -qam "after the backup"; echo draft > "$C/specs/draft.md"
out="$(bk verify)" && echo "$out" | grep -q 'acme-app: restores ([0-9]* commits); 1 commit(s) since the backup' \
  && echo "$out" | grep -q 'workspace: restores ([0-9]* commits); 1 file(s) changed since the backup' || fail "work since the backup: $out"
rm "$C/specs/draft.md"
out="$(PW=wrong bk verify)" && fail "a wrong passphrase verified"
echo "$out" | grep -q 'PROBLEM the archive does not open' || fail "a wrong passphrase was not named: $out"
# A damaged archive: some bytes in the middle overwritten.
a="$VB/$(ls "$VB")"; cp -p "$a" "$T/good.enc"
printf 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' | dd of="$a" bs=1 seek=$(( $(wc -c < "$a") / 2 )) conv=notrunc 2>/dev/null
out="$(bk verify)" && fail "a damaged archive verified"
echo "$out" | grep -q "^  PROBLEM " || fail "the damage was not named: $out"
cp -p "$T/good.enc" "$a"
# An incomplete archive: a repo the workspace lists now that the archive does not hold.
mkrepo "$T/later"; cp "$C/repos.tsv" "$T/repos.bak"; printf 'later\t-\t-\tno\t%s\n' "$T/later" >> "$C/repos.tsv"
out="$(bk verify)" && fail "an incomplete archive verified"
echo "$out" | grep -q 'PROBLEM later: not in the archive' || fail "the missing repo was not named: $out"
cp "$T/repos.bak" "$C/repos.tsv"
# The doctor notes a verify that is missing or old.
cp "$C/cabinet.env" "$T/env.bak"; sedi "s|^CABINET_BACKUP_DIR=.*|CABINET_BACKUP_DIR=\"$VB\"|" "$C/cabinet.env"
HOME="$VH" "$C/bin/doctor.sh" 2>&1 | grep -q 'ok    a restore was verified 0 day(s) ago' || fail "the doctor missed a fresh verify"
touch -t 202601010000 "$VH/$LOGS/acme-app/backup-verified"
HOME="$VH" "$C/bin/doctor.sh" 2>&1 | grep -q 'note  the last verified restore was [0-9]* days ago' || fail "the doctor missed an old verify"
rm "$VH/$LOGS/acme-app/backup-verified"
HOME="$VH" "$C/bin/doctor.sh" 2>&1 | grep -q 'note  no restore of a backup has been verified on this machine yet' || fail "the doctor missed a missing verify"
cp "$T/env.bak" "$C/cabinet.env"
  return 0   # a last "check && fail" line must not end the run
}

section "builders: each repo gets the builder it looks like, and the team table decides" "2"
s39() {
# One repo of each kind, the way an existing project would look.
mkrepo "$T/kind-web"; echo '{"dependencies":{"react":"^19.0.0"}}' > "$T/kind-web/package.json"
mkrepo "$T/kind-app"; mkdir -p "$T/kind-app/ios"; touch "$T/kind-app/ios/App.swift"
mkrepo "$T/kind-infra"; echo 'resource "x" "y" {}' > "$T/kind-infra/main.tf"
mkrepo "$T/kind-api"
for r in kind-web kind-app kind-infra; do git -C "$T/$r" add -A && git -C "$T/$r" commit -qm kind; done
B="$T/kinds"; BH="$T/bhome"; mkdir -p "$BH"
"$F" new "$B" --yes --backup-dir off --repo "$T/kind-web" --repo "$T/kind-app" --repo "$T/kind-infra" --repo "$T/kind-api" >/dev/null || fail "new with four repos"
[[ ! -e "$B/agents/backend.md" ]] || fail "a builder was built before it owned a repo"
out="$(HOME="$BH" "$B/bin/bootstrap.sh" 2>&1)" || true
for kv in kind-web:web kind-app:mobile kind-infra:infrastructure kind-api:backend; do
  echo "$out" | grep -q "${kv%%:*}: owned by the ${kv#*:} builder" && grep -q "^| \`${kv%%:*}\` | TBD | ${kv#*:} |$" "$B/AGENTS.md" || fail "${kv%%:*} was not given the ${kv#*:} builder: $out"
done
[[ -z "$(git -C "$B" status --porcelain -- AGENTS.md ORG.md agents .claude/agents)" ]] && echo "$out" | grep -q "committed the new builders" || fail "bootstrap left the new builders uncommitted: $(git -C "$B" status --porcelain)"
for r in backend web mobile infrastructure; do
  grep -q "^name: $r$" "$B/agents/$r.md" && [[ -f "$B/.claude/agents/$r.md" ]] || fail "the $r builder was not built"
done
grep -q '`.cabinet/rules/builders.md`' "$B/agents/web.md" && grep -q '^## Builders$' "$B/CABINET.md" && grep -q '^1\. \*\*Learns the repo before its first change' "$B/.cabinet/rules/builders.md" || fail "builders do not point at the shared rules, or they are not installed"
out="$(HOME="$BH" "$B/bin/doctor.sh" 2>&1 || true)"
echo "$out" | grep -q 'ok    manual names every script, job and role' && echo "$out" | grep -q 'ok    roles built: .*backend' || fail "doctor after builders: $(echo "$out" | grep -E 'manual|roles')"
# A row that is not TBD is never changed; the team table decides which builders are built.
git -C "$B" add -A && { git -C "$B" diff --cached --quiet || git -C "$B" commit -qm builders; }
HOME="$BH" "$B/bin/bootstrap.sh" 2>&1 | grep -q 'owned by the' && fail "bootstrap reassigned a repo that has an owner"
sedi 's/^| `kind-api` | TBD | backend |$/| `kind-api` | TBD | owner |/' "$B/AGENTS.md"
"$B/bin/role.sh" build >/dev/null && [[ ! -e "$B/agents/backend.md" ]] || fail "a builder that owns no repo is still built"
(cd "$B" && "$F" config --yes --roles "qa") >/dev/null 2>&1 || fail "config --roles with builders"
[[ -f "$B/agents/web.md" && -f "$B/agents/qa.md" && ! -e "$B/agents/finance.md" ]] || fail "config --roles dropped a builder that owns a repo"
sedi 's/^| `kind-api` | TBD | owner |$/| `kind-api` | TBD | TBD |/' "$B/AGENTS.md"; cp "$B/AGENTS.md" "$T/agents.bak"
HOME="$BH" "$B/bin/bootstrap.sh" --dry-run 2>&1 | grep -q 'would make backend the owner of kind-api' && cmp -s "$B/AGENTS.md" "$T/agents.bak" || fail "dry run: builder not shown, or AGENTS.md changed"
# The owner's own uncommitted edit in AGENTS.md is never swept into bootstrap's commit.
echo "owner note" >> "$B/AGENTS.md"; before="$(git -C "$B" rev-parse HEAD)"
HOME="$BH" "$B/bin/bootstrap.sh" 2>&1 | grep -q "review and commit AGENTS.md, ORG.md" && [[ "$(git -C "$B" rev-parse HEAD)" == "$before" ]] && grep -q "^owner note$" "$B/AGENTS.md" || fail "bootstrap committed over the owner's own edit"
# The guess reads only the files at the repo's top.
( WS="$B"; source "$B/bin/lib.sh"
  mkdir -p "$T/k1/android" "$T/k2/terraform" "$T/k3"; echo '<html></html>' > "$T/k3/index.html"
  echo '{"dependencies":{"react":"1","react-native":"1"}}' > "$T/k4.json"; mkdir -p "$T/k4"; cp "$T/k4.json" "$T/k4/package.json"
  [[ "$(builder_for "$T/k1") $(builder_for "$T/k2") $(builder_for "$T/k3") $(builder_for "$T/k4") $(builder_for "$T/kind-api")" == "mobile infrastructure web mobile backend" ]] ) || fail "builder_for guessed wrong"
  return 0   # a last "check && fail" line must not end the run
}

section "roles a project needs: optional kit roles, and its own from a brief" "0"
s40() {
# Optional kit roles are off by default and turned on like any role.
! grep -q '| brand-designer |\|| code-reviewer |' "$W/AGENTS.md" "$W/OPERATIONS.md" || fail "an optional role is on by default"
"$F" new "$T/optroles" --yes --roles "qa dba code-reviewer" >/dev/null || fail "new with optional roles"
for r in dba code-reviewer; do
  [[ -f "$T/optroles/agents/$r.md" ]] && grep -q "| $r |" "$T/optroles/AGENTS.md" && grep -q "| $r |" "$T/optroles/OPERATIONS.md" || fail "optional role $r not built or not in the team tables"
done
! grep -q '| auditor |' "$T/optroles/AGENTS.md" && "$T/optroles/bin/doctor.sh" 2>&1 | grep -q 'ok    manual names every script, job and role' || fail "an optional role left on, or the manual check"
# A role of the project's own from one line; the rest is left to the draft.
RW="$T/optroles"
(cd "$RW/specs" && "$F" role add brand-strategist --does "Positioning and naming for a reading app, for parents") >/dev/null || fail "role add"
f="$RW/roles/brand-strategist.md"
grep -qx -- '- What it should do: Positioning and naming for a reading app, for parents' "$f" && grep -qx -- '- What it owns: not said yet' "$f" || fail "the brief was not kept word for word"
grep -q '^CABINET_ROLES=".* brand-strategist"' "$RW/cabinet.env" && grep -q '^name: brand-strategist$' "$RW/agents/brand-strategist.md" \
  && grep -q '| TBD | TBD | brand-strategist |' "$RW/AGENTS.md" && grep -q '| brand-strategist |' "$RW/OPERATIONS.md" || fail "the new role was not registered and built"
"$RW/bin/doctor.sh" 2>&1 | grep -q 'note  the brand-strategist role is not drafted yet' || fail "the doctor did not note the undrafted role"
# In a terminal: four questions, Enter skips, then whether to draft now.
printf 'Weekly growth experiments\n\nWhich experiment runs next\nAny spend\nn\n' > "$T/role-answers"
(cd "$RW" && CABINET_TTY="$T/role-answers" "$F" role add growth) >/dev/null || fail "role add in a terminal"
grep -qx -- '- What it owns: not said yet' "$RW/roles/growth.md" && grep -qx -- '- What it must bring to the owner: Any spend' "$RW/roles/growth.md" || fail "terminal answers not kept"
for bad in qa web Bad_Name brand-strategist; do (cd "$RW" && "$F" role add "$bad" --yes) >/dev/null 2>&1 && fail "role add accepted '$bad'"; done
# A role change commits itself in a workspace with its own git, and never sweeps in the owner's own edits.
"$F" new "$T/rolecommit" --yes --backup-dir off >/dev/null || fail "new for role commits"
out="$(cd "$T/rolecommit" && "$F" role add dba)" && echo "$out" | grep -q "Committed in the workspace: roles: dba on" && [[ -z "$(git -C "$T/rolecommit" status --porcelain)" ]] && git -C "$T/rolecommit" log -1 --format=%s | grep -qx "roles: dba on" || fail "role add left its change uncommitted: $out $(git -C "$T/rolecommit" status --porcelain)"
echo "owner note" >> "$T/rolecommit/AGENTS.md"; before="$(git -C "$T/rolecommit" rev-parse HEAD)"
out="$(cd "$T/rolecommit" && "$F" role remove dba)" && echo "$out" | grep -q "Review with git -C" && [[ "$(git -C "$T/rolecommit" rev-parse HEAD)" == "$before" ]] && grep -qx "owner note" "$T/rolecommit/AGENTS.md" || fail "role remove committed over the owner's own edit: $out"
# Drafting: the agent tool runs as chief-of-staff on the drafting method; a run that leaves it TBD fails.
cp "$RW/cabinet.env" "$T/optroles-env.bak"
printf '%s\n' 'CABINET_RUNNER="custom"' "CABINET_RUNNER_CMD='printf \"%s\" \"\$CABINET_PROMPT\" > prompt.out'" >> "$RW/cabinet.env"
(cd "$RW" && "$F" role draft brand-strategist) >/dev/null 2>&1 && fail "a draft that left the role TBD passed"
grep -q 'Act as the chief-of-staff role' "$RW/prompt.out" && grep -q 'as .cabinet/rules/seats.md, "Drafting a role", says' "$RW/prompt.out" && grep -q 'roles/brand-strategist.md' "$RW/prompt.out" || fail "the draft prompt: $(cat "$RW/prompt.out")"
printf '%s\n' "CABINET_RUNNER_CMD='sed -i.bak \"s/^description: TBD.*/description: Brand strategist. Positioning and naming./\" roles/brand-strategist.md && rm roles/brand-strategist.md.bak'" >> "$RW/cabinet.env"
(cd "$RW" && "$F" role draft brand-strategist) | grep -q 'Drafted roles/brand-strategist.md' || fail "a finished draft was not reported"
grep -q '^description: Brand strategist' "$RW/agents/brand-strategist.md" && ! "$RW/bin/doctor.sh" 2>&1 | grep -q 'brand-strategist role is not drafted' || fail "the drafted role was not rebuilt, or still noted"
(cd "$RW" && "$F" role draft qa) >/dev/null 2>&1 && fail "role draft took a kit role"
# A drafted role follows the workflow its job touches: the doctor notes what one written before it misses.
bs="$RW/roles/brand-strategist.md"; cp "$bs" "$T/bs.keep"; cp "$RW/AGENTS.md" "$T/bs-agents.keep"; cp "$RW/repos.tsv" "$T/bs-repos.keep"
"$RW/bin/doctor.sh" 2>&1 | grep -q 'brand-strategist (says nothing of settling a disagreement with a neighbouring role)' || fail "doctor: a fresh draft without a tie-break"
echo "Record PASS or BLOCK on the handoff." >> "$bs"
printf 'site\t-\t-\tno\n' >> "$RW/repos.tsv"; L sub-all "$RW/AGENTS.md" '/(\| Repo or area \| What it is \| Owning agent \|\n\|---\|---\|---\|\n)/' $'$1| `site` | The website | brand-strategist |\n'
grep -q '^| `site` |' "$RW/AGENTS.md" || fail "test setup: the site row"
L drop "$bs" '/^Read `CABINET.md`, then `AGENTS.md`/'
out="$("$RW/bin/doctor.sh" 2>&1 || true)"
echo "$out" | grep -q 'project roles behind the workflow: brand-strategist (never sends it to CABINET.md, gives verdicts without bin/handoff.sh record, says nothing of settling a disagreement with a neighbouring role, owns a repo but writes no plan, owns a repo but attaches no evidence) (redraft each' \
  || { echo "$out" | grep -i 'project role\|brand'; fail "doctor: roles.workflow"; }
printf '%s\n' 'Read `CABINET.md`, then `AGENTS.md`.' 'Record each verdict with bin/handoff.sh record.' 'Write your plan in the spec; attach evidence.' 'A disagreement with design-lead goes to the owner.' >> "$bs"
"$RW/bin/doctor.sh" 2>&1 | grep -q 'every drafted project role follows the workflow its job touches' || fail "doctor: a role that follows the workflow is still noted"
grep -q '^4\. \*\*Fits the workflow its job touches' "$KIT/core/rules/seats.md" || fail "the drafting rule for the workflow left seats.md"
cp "$T/bs.keep" "$bs"; cp "$T/bs-agents.keep" "$RW/AGENTS.md"; cp "$T/bs-repos.keep" "$RW/repos.tsv"
cp "$T/optroles-env.bak" "$RW/cabinet.env"; rm -f "$RW/prompt.out"
  return 0   # a last "check && fail" line must not end the run
}

section "a changing team stays consistent: name clashes, two owners, stranded handoffs" "0"
s41() {
TW="$T/teamchange"; "$F" new "$TW" --yes >/dev/null || fail "new for team checks"
dr() { "$TW/bin/doctor.sh" 2>&1 || true; }
# A whole role of the project's own with a kit role's name (as when a later kit adds one) wins, unmixed.
printf -- '---\nname: qa\ndescription: Our own qa.\ntools: Read\n---\n\nOur qa checks only the docs.\n' > "$TW/roles/qa.md"
"$TW/bin/role.sh" build >/dev/null || fail "roles with a clashing name"
grep -q 'Our qa checks only the docs.' "$TW/agents/qa.md" && ! grep -q 'Project notes\|You are the quality lead' "$TW/agents/qa.md" || fail "a project role was mixed into the kit's role of the same name"
dr | grep -q 'note  roles/qa.md is a whole role and the kit also has a qa role: yours is used' || fail "the doctor did not name the clash"
printf 'qa tests on the staging account.\n' > "$TW/roles/qa.md"; "$TW/bin/role.sh" build >/dev/null
grep -q 'You are the quality lead' "$TW/agents/qa.md" && grep -q 'qa tests on the staging account.' "$TW/agents/qa.md" || fail "notes for a kit role no longer appended"
rm "$TW/roles/qa.md"; "$TW/bin/role.sh" build >/dev/null
# One owner per repo or area.
dr | grep -q 'ok    each repo and area in the team table has one owner' || fail "a fresh team table has two owners"
L before "$TW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `specs/` | Specs, again | architect |'
dr | grep -q "FIX   more than one owner in the team table of AGENTS.md: \`specs/\` (.*architect.*)" || fail "two owners of specs/ not flagged: $(dr | grep -i owner)"
git -C "$TW" checkout -q -- AGENTS.md
# A part of a product repo given to another role than the repo's owner: allowed, noted.
printf 'api\t-\t-\tno\n' >> "$TW/repos.tsv"
L before "$TW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `api` | The API | backend |'; L before "$TW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `api/docs/` | API docs | tech-writer |'
dr | grep -q 'note  parts of a repo owned by another role than the repo.s: api/docs (tech-writer) inside api (backend)' || fail "a nested owner in a repo was not noted: $(dr | grep -i nested)"
dr | grep -q 'ok    each repo and area in the team table has one owner' || fail "a nested owner was taken for two owners"
# role add --owns: an area another role holds is refused, the most specific row deciding.
for o in 'api' '`specs/`' 'the api/docs/ pages' 'specs/qa'; do
  out="$(cd "$TW" && "$F" role add seo --owns "$o" --dry-run 2>&1)" && fail "role add took --owns '$o'"
  echo "$out" | grep -q 'the team table of AGENTS.md gives .* to another role' || fail "role add --owns '$o': $out"
done
out="$(cd "$TW" && "$F" role add seo --owns "search ranking, specs/seo/, specs/qa/seo" --dry-run 2>&1)" || fail "role add refused a path inside another role's area: $out"
echo "$out" | grep -q 'Note: specs/seo (inside specs, product-manager); specs/qa/seo (inside specs/qa, qa): drafting gives seo its own row' || fail "role add did not say a path sits inside another's area, by the most specific row: $out"
# What a project role may write, against the team table.
printf -- '---\nname: seo\ndescription: Search.\ntools: Read\n---\n\nRead `CABINET.md`.\n\n## What you may write\n\n`specs/seo/`, `HANDOFFS.md` entries, and `specs/qa/` notes.\n\n## Next\n\n`api/x`\n' > "$TW/roles/seo.md"
L before "$TW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `specs/seo/` | Search notes | seo |'
dr | grep -q 'note  project roles that may write another role.s area: seo may write specs/qa/, which the team table gives to qa (narrow' || fail "roles.writes: $(dr | grep -i 'may write')"
L sub "$TW/roles/seo.md" -- '/, and `specs\/qa\/` notes/' ''
dr | grep -q 'ok    every project role writes only what the team table gives it' || fail "roles.writes flagged a role writing its own area or HANDOFFS.md"
rm "$TW/roles/seo.md"; git -C "$TW" checkout -q -- AGENTS.md repos.tsv
grep -q '^\*\*When roles disagree,\*\*' "$KIT/core/CABINET.md" && grep -q 'the most specific row wins' "$KIT/core/CABINET.md" || fail "the ownership or disagreement rule left CABINET.md"
# A handoff to a role that is turned off, or to no one on the team, is noted with its ID.
id="$("$TW/bin/handoff.sh" add --from qa --to finance --changed x --needed y "Price check" | cut -d' ' -f1)"
"$TW/bin/handoff.sh" add --from qa --to "owner (via chief-of-staff)" --changed x --needed y "For the owner" >/dev/null
dr | grep -q 'ok    every open handoff is addressed to a role, a repo or the owner' || fail "a handoff to a role on the team, or the owner, was flagged"
(cd "$TW" && "$F" config --yes --roles "qa security") >/dev/null || fail "turning roles off"
dr | grep -q "note  open handoffs addressed to no role or repo on the team: $id (finance)" || fail "a handoff to a role turned off was not noted: $(dr | grep -i addressed)"
  return 0   # a last "check && fail" line must not end the run
}

section "commands follow one set of conventions" "0 2"
s42() {
CW="$T/conv"; "$F" new "$CW" --yes >/dev/null || fail "new for conventions"
mkdir -p "$T/plain"
# A noun alone shows its verbs; a noun and a verb has its own --help.
"$F" role | grep -q '^  role add <name>' && "$F" role >/dev/null || fail "a noun alone does not show its verbs"
"$F" role add --help | grep -q '^Usage: cabinet role add <name>' && "$F" help role add | grep -q -- '--does' || fail "noun and verb --help"
"$F" help role --json | j -e '$.commands.length == 5 && $.commands.every((c) => c.name.startsWith("role "))' >/dev/null || fail "help <noun> --json"
# Wrong usage exits 2: an unknown command, verb or option, a missing value, a folder where -C belongs.
for args in "nope" "role nope" "handoff nope" "next --bogus" "new $T/x --name" "-C" "-C $T/no-such-folder status"; do
  st=0; (cd "$CW" && "$F" $args) >/dev/null 2>&1 || st=$?
  ((st == 2)) || fail "'cabinet $args' exited $st, not 2"
done
st=0; "$F" status "$CW" >/dev/null 2>&1 || st=$?; ((st == 2)) || fail "a folder argument was taken (exit $st), not refused for -C"
st=0; "$CW/bin/handoff.sh" >/dev/null 2>&1 || st=$?; ((st == 2)) || fail "a script without its verb exited $st, not 2"
# -C runs a command as if started in that folder.
(cd "$T/plain" && "$F" -C "$CW" status --json) | j -e --arg w "$(cd "$CW" && pwd -P)" '$.workspace == $w' >/dev/null || fail "-C"
bash -c 'eval "$("$1" completion bash)"; COMP_WORDS=(cabinet -C x role ""); COMP_CWORD=4; _cabinet; echo "${COMPREPLY[*]}"' _ "$F" | grep -q 'add.*remove.*list' || fail "completion of verbs after -C"
# Every command that reports prints JSON.
# version: one line for a script, the mark in a terminal (ASCII without a UTF-8 locale).
[[ "$("$F" version)" == "cabinet $(j -r '$.version' "$KIT/package.json")" ]] || fail "version piped should print one line"
v="$(j -r '$.version' "$KIT/package.json")"
[[ "$(LC_ALL=C in_tty "$F" version | tr -d '\r')" == "$(printf '\n      o\n  o       o\n\no               cabinet %s\n                One person, a whole team.\n  o       o     Build anything with AI agents, and stay in charge.\n      o' "$v")" ]] || fail "version in a terminal should print the round mark"
# The banner and the brand guide's sample of it carry the tagline BRAND.md approves.
tag="$(sed -n 's/^The tagline: \*\*\(.*\)\*\* (Approved)$/\1/p' "$KIT/brand/BRAND.md")"
[[ "$tag" == "One person, a whole team. Build anything with AI agents, and stay in charge." ]] || fail "BRAND.md's approved tagline changed: update the version banner and its sample with it ($tag)"
grep -qF 'One person, a whole team.' "$KIT/brand/index.html" && grep -qF 'Build anything with AI agents, and stay in charge.' "$KIT/brand/index.html" && ! grep -qF 'You stay in charge.' "$KIT/brand/index.html" || fail "the brand guide's terminal sample does not show the approved tagline"
LC_ALL=en_US.UTF-8 in_tty "$F" version | grep -q '⬤' || fail "the mark in a UTF-8 terminal should use large dots"
"$F" version --json | j -e '$.version' >/dev/null && "$F" changelog --json | j -e '!!$[0].version && !!$[0].text' >/dev/null || fail "version or changelog --json"
mkdir -p "$T/npmoff"; printf '#!/bin/sh\nexit 1\n' > "$T/npmoff/npm"; chmod +x "$T/npmoff/npm"
(cd "$CW" && PATH="$T/npmoff:$PATH" "$F" outdated --json) | j -e '$.latest == null && !!$.kit_version' >/dev/null || fail "outdated --json"
(cd "$CW" && "$F" role list --json) | j -e '$.some((r) => r.name == "qa" && r.kind == "kit" && r.on === true) && $.some((r) => r.name == "dba" && r.on === false)' >/dev/null || fail "role list --json"
(cd "$CW" && "$F" job list --json) | j -e '$[0].name == "brief" && $[0].role == "chief-of-staff" && $[0].timeout_minutes == 60' >/dev/null || fail "job list --json"
(cd "$CW" && "$F" secret check --json) | j -e '$.length == 0' >/dev/null || fail "secret check --json"
# role add and remove: a kit role on and off, with --dry-run writing nothing.
cp "$CW/cabinet.env" "$T/conv.env"
(cd "$CW" && "$F" role add dba --dry-run) | grep -q 'would turn on the kit role dba' && cmp -s "$CW/cabinet.env" "$T/conv.env" || fail "role add --dry-run"
(cd "$CW" && "$F" role add dba) >/dev/null && grep -q '| dba |' "$CW/AGENTS.md" && [[ -f "$CW/agents/dba.md" ]] || fail "role add of a kit role"
(cd "$CW" && "$F" role add dba) >/dev/null 2>&1 && fail "a role already on was added again"
(cd "$CW" && "$F" role remove dba) >/dev/null && ! grep -q '| dba |' "$CW/AGENTS.md" && [[ ! -e "$CW/agents/dba.md" ]] || fail "role remove"
(cd "$CW" && "$F" role remove chief-of-staff) >/dev/null 2>&1 && fail "chief-of-staff was turned off"
# repo add, list and remove.
mkrepo "$T/conv-api"
(cd "$CW" && "$F" repo add "$T/conv-api" --dry-run) >/dev/null && ! grep -q conv-api "$CW/repos.tsv" || fail "repo add --dry-run wrote"
git -C "$CW" add -A && { git -C "$CW" diff --cached --quiet || git -C "$CW" commit -qm "before repo add"; }
(cd "$CW" && "$F" repo add "$T/conv-api") >/dev/null && grep -q $'^conv-api\t' "$CW/repos.tsv" && grep -q '| `conv-api` |' "$CW/AGENTS.md" || fail "repo add"
[[ -z "$(git -C "$CW" status --porcelain)" ]] && git -C "$CW" log -1 --format=%s | grep -qxF "cabinet config: add repo" || fail "repo add did not commit its change in a clean workspace"
(cd "$CW" && "$F" repo list --json) | j -e '((r) => r.present === false && r.owner == null)($.findLast((r) => r.name == "conv-api"))' >/dev/null || fail "repo list --json"
(cd "$CW" && "$F" repo remove conv-api) >/dev/null && ! grep -q conv-api "$CW/repos.tsv" "$CW/AGENTS.md" || fail "repo remove"
(cd "$CW" && "$F" repo remove conv-api) >/dev/null 2>&1 && fail "removing a repo that is not there succeeded"
# The tests fail when a command breaks a convention: a plural noun, a verb not in the list.
mkdir -p "$T/kitcopy"; (cd "$KIT" && tar --exclude .git --exclude node_modules -cf - .) | tar -C "$T/kitcopy" -xf -
L before "$T/kitcopy/bin/cabinet" '/^C\tTeam\trole list\t/' $'C\tTeam\troles show\t\tShow roles.'
out="$(node "$KIT/test/docs-check.js" "$T/kitcopy" 2>&1)" && fail "the docs check passed a plural noun"
echo "$out" | grep -q "the noun 'roles' is plural" && echo "$out" | grep -q "'roles show' uses a verb that is not in AGENTS.md" || fail "the docs check did not name the broken conventions: $out"
# ...a cabinet next step missing from the docs, and an option the agent setup guide uses that no command has.
L sub "$T/kitcopy/docs/commands.md" -- '/Step IDs: `deps`, /' 'Step IDs: '; L sub "$T/kitcopy/docs/agent-setup.md" -- '/--week-start sunday/' '--week-starts sunday'
out="$(node "$KIT/test/docs-check.js" "$T/kitcopy" 2>&1)" && fail "the docs check passed a missing step ID"
echo "$out" | grep -q "does not list the cabinet next step ID deps" && echo "$out" | grep -q "uses the option --week-starts, which no command has" || fail "the docs check missed a step ID or a guide option: $out"
  return 0   # a last "check && fail" line must not end the run
}


section "Linux: systemd timers, cron, dates and no scheduler" "0"
s43() {
# Each scheduler is written and read the same way on any machine: CABINET_SCHEDULER picks one.
[[ "$(pf when_oncalendar "fri,sat 4 PM")" == "Fri,Sat *-*-* 16:00:00" && "$(pf when_oncalendar "7:05 am")" == "*-*-* 07:05:00" ]] || fail "systemd times"
[[ "$(pf when_cron "fri,sat 4 PM")" == "0 16 * * 5,6" && "$(pf when_cron "7:05 am")" == "5 7 * * *" ]] || fail "cron times"
# Dates read the same with BSD and GNU tools.
touch -t 202601010000 "$T/old"
[[ "$(pf human_stamp 20261018-130500)" == "18 Oct 2026, 1:05 PM" && "$(pf mtime "$T/old")" == "$(pf stamp_epoch 20260101-000000)" ]] || fail "dates"
# A path with a space and a %, which systemd and cron both treat specially.
OW="$T/sd 50% off"; "$F" new "$OW" --slug sd --yes >/dev/null; OP="$(cd "$OW" && pwd -P)"
SH="$T/sd-home"; mkdir -p "$SH"
HOME="$SH" CABINET_SCHEDULER=systemd "$OW/bin/bootstrap.sh" >/dev/null 2>&1 || true
U="$SH/.config/systemd/user/ai.cabinet.sd.brief"
grep -qxF "ExecStart=\"${OP//%/%%}/bin/job.sh\" \"run\" \"brief\"" "$U.service" && grep -qxF "StandardOutput=append:$SH/$LOGS/sd/brief.log" "$U.service" \
  && grep -qx 'OnCalendar=\*-\*-\* 07:00:00' "$U.timer" || { cat "$U.service" "$U.timer"; fail "systemd units"; }
[[ "$(CABINET_SCHEDULER=systemd pf sched_ws "$U.service")" == "$OP" ]] && grep -q 'systemctl --user --quiet enable --now ai.cabinet.sd.brief.timer' "$T/fake.log" || fail "systemd: whose schedule, or not started"
(cd "$OW" && HOME="$SH" CABINET_SCHEDULER=systemd "$F" doctor --json) | j -e '$.results.findLast((r) => r.id == "schedules.job")?.level == "ok"' >/dev/null || fail "doctor with systemd"
# cron: one block of cabinet's lines; the owner's own lines stay, whatever happens to the block.
CH="$T/cron-home"; mkdir -p "$CH"; printf '%s\n' "MAILTO=me" "0 1 * * * /bin/true # mine" > "$T/crontab"
HOME="$CH" CABINET_SCHEDULER=cron "$OW/bin/bootstrap.sh" >/dev/null 2>&1 || true
grep -qx 'MAILTO=me' "$T/crontab" && grep -qxF '0 1 * * * /bin/true # mine' "$T/crontab" && grep -qx '# cabinet schedule: ai.cabinet.sd.brief' "$T/crontab" || { cat "$T/crontab"; fail "cron block"; }
# The line runs as written (cron turns \% back into %): the job starts the (fake) agent and logs.
line="$(grep '^0 7 \* \* \* ' "$T/crontab")" || fail "the brief at 7:00 AM in the crontab"
: > "$T/fake.log"; HOME="$CH" sh -c "$(printf '%s' "${line#0 7 \* \* \* }" | sed 's/\\%/%/g')" || true
grep -q '^claude -p --agent chief-of-staff' "$T/fake.log" && [[ -s "$CH/$LOGS/sd/brief.log" ]] || fail "the cron line does not run the job"
(cd "$OW" && HOME="$CH" CABINET_SCHEDULER=cron "$F" doctor --json) | j -e '$.results.findLast((r) => r.id == "schedules.job")?.level == "ok"' >/dev/null || fail "doctor with cron"
sedi 's/^WHEN=.*/WHEN=""/' "$OW/jobs/brief.job"
HOME="$CH" CABINET_SCHEDULER=cron "$OW/bin/bootstrap.sh" >/dev/null 2>&1 || true
[[ "$(cat "$T/crontab")" == "$(printf '%s\n' "MAILTO=me" "0 1 * * * /bin/true # mine")" ]] || { cat "$T/crontab"; fail "cron: the block not removed cleanly"; }
printf '%s\n' "# BEGIN cabinet" "my own line" > "$T/crontab"; HOME="$CH" CABINET_SCHEDULER=cron pf cron_sync
grep -qx 'my own line' "$T/crontab" || fail "cron: a block with no end lost the lines after it"
# A cron backup reads its passphrase from a file only the user can read, and runs unattended.
BW="$T/cron-bk-ws"; "$F" new "$BW" --slug cbk --yes --backup-dir "$T/cron-bk" >/dev/null; : > "$T/crontab"
HOME="$CH" CABINET_SCHEDULER=cron "$BW/bin/bootstrap.sh" 2>&1 | grep -qF 'passphrases/cabinet.cbk.backup' || fail "bootstrap with cron: the passphrase file command"
(cd "$BW" && HOME="$CH" CABINET_SCHEDULER=cron "$F" doctor --json) | j -e '$.results.findLast((r) => r.id == "backups.passphrase")?.level == "fix"' >/dev/null || fail "doctor with cron and no passphrase file"
[[ "$(HOME="$CH" CABINET_SCHEDULER=cron pf deps_backups)" != *secret-tool* ]] || fail "cron backups asked for secret-tool"
printf 'cron pass\n' | HOME="$CH" bash -c "$(HOME="$CH" CABINET_SCHEDULER=cron pf pass_add_cmd cabinet.cbk.backup)" >/dev/null
PFILE="$CH/.config/cabinet/passphrases/cabinet.cbk.backup"
[[ "$(perm "$PFILE")" == 600 && "$(cat "$PFILE")" == "cron pass" ]] || fail "the passphrase file command"
line="$(grep 'bin/job.sh.*backup\|bin/backup.sh' "$T/crontab")" || { cat "$T/crontab"; fail "the backup in the crontab"; }
env -i HOME="$CH" sh -c "$(printf '%s' "$line" | cut -d' ' -f6- | sed 's/\\%/%/g')" || true
ls "$T/cron-bk"/cbk-*.tar.gz.enc >/dev/null 2>&1 || { cat "$CH/$LOGS/cbk/backup.log"; fail "a cron backup did not run unattended"; }
(cd "$BW" && HOME="$CH" CABINET_SCHEDULER=cron "$F" doctor --json) | j -e '$.results.findLast((r) => r.id == "backups.passphrase")?.level == "ok"' >/dev/null || fail "doctor with the passphrase file"
chmod 644 "$PFILE"
(cd "$BW" && HOME="$CH" CABINET_SCHEDULER=cron "$F" doctor --json) | j -e '((r) => r.level == "fix" && r.message.includes("chmod 600"))($.results.findLast((r) => r.id == "backups.passphrase"))' >/dev/null || fail "doctor with a passphrase file others can read"
[[ -z "$(HOME="$CH" pf pass_get cabinet.cbk.backup)" ]] || fail "a passphrase file others can read was used"
HOME="$CH" pf pass_del cabinet.cbk.backup && [[ ! -e "$PFILE" ]] || fail "pass_del kept the passphrase file"
# No scheduler at all (a container without cron): said plainly by bootstrap and the doctor.
git -C "$OW" checkout -q -- jobs/brief.job
HOME="$CH" CABINET_SCHEDULER=none "$OW/bin/bootstrap.sh" 2>&1 | grep -q 'no scheduler found' || fail "bootstrap with no scheduler"
(cd "$OW" && HOME="$CH" CABINET_SCHEDULER=none "$F" doctor --json) | j -e '$.results.findLast((r) => r.id == "schedules.scheduler")?.level == "fix"' >/dev/null || fail "doctor with no scheduler"
rm -f "$T/crontab"
  return 0   # a last "check && fail" line must not end the run
}

section "tools: checked first, installed only when the owner says yes" "0"
s44() {
# The command for this machine (the fake brew on macOS, the fake apt-get on Linux), and package names per manager.
c="$(pf deps_cmd "git node")"
case "$c" in "brew install git node"|"sudo apt-get install -y git nodejs") ;; *) fail "the install command: $c" ;; esac
[[ "$(pf pkg_for apt-get node) $(pf pkg_for brew npm) $(pf pkg_for pacman node) $(pf pkg_for dnf secret-tool) $(pf pkg_for apt-get notify-send)" == "nodejs node nodejs libsecret libnotify-bin" ]] || fail "package names"
installs() { grep -cE '^(brew install|sudo (apt-get|dnf|pacman) )' "$T/fake.log" || true; }
# With --yes (scripts, agents): no install, a stop with the command, and nothing made.
: > "$T/fake.log"
out="$(CABINET_TEST_MISSING="git node" "$F" new "$T/nodeps" --yes 2>&1)" && fail "setup went ahead without its tools"
echo "$out" | grep -q 'cabinet needs git, node, not found' && echo "$out" | grep -qF "run this again: $c" && [[ ! -e "$T/nodeps" && "$(installs)" == 0 ]] || { echo "$out"; fail "--yes with missing tools"; }
CABINET_TEST_MISSING=git "$F" new "$T/nodeps" --dry-run >/dev/null 2>&1 && fail "a dry run went ahead without its tools"
[[ "$(installs)" == 0 ]] || fail "a dry run installed something"
"$F" new --help >/dev/null || fail "--help needs the tools"
# In a terminal: no installs nothing; yes runs the command (the fakes only log it, so git stays missing and setup still stops).
printf 'n\n' > "$T/answers"; CABINET_TTY="$T/answers" CABINET_TEST_MISSING=git "$F" new "$T/nodeps" >/dev/null 2>&1 && fail "setup went ahead after no"
[[ "$(installs)" == 0 ]] || fail "no still installed"
printf 'y\n' > "$T/answers"; CABINET_TTY="$T/answers" CABINET_TEST_MISSING=git "$F" new "$T/nodeps" >/dev/null 2>&1 && fail "setup went ahead with git still missing"
grep -qxE '(brew install git|sudo apt-get install -y git)' "$T/fake.log" && [[ ! -e "$T/nodeps" ]] || fail "yes did not run the install"
# The doctor and next tell the owner, and any agent reading the JSON, what is missing and the command.
"$F" new "$T/deps-ws" --yes --backup-dir "$T/deps-bk" >/dev/null; D="$T/deps-ws"
(cd "$D" && CABINET_TEST_MISSING=git "$F" doctor --json) | j -e --arg c "$(pf deps_cmd git)" '((r) => r.level == "fix" && r.message.includes($c))($.results.find((r) => r.id == "deps.required")) && $.can_fix.includes("deps")' >/dev/null || fail "doctor: a missing tool"
(cd "$D" && CABINET_TEST_MISSING=openssl "$F" doctor --json) | j -e --arg c "$(pf deps_cmd openssl)" '((r) => r.level == "fix" && r.message.includes($c))($.results.find((r) => r.id == "deps.backups"))' >/dev/null || fail "doctor: a tool backups need"
(cd "$D" && "$F" doctor --json) | j -e '$.results.find((r) => r.id == "deps.required").level == "ok" && !$.results.some((r) => r.id == "deps.backups")' >/dev/null || fail "doctor with every tool"
(cd "$D" && CABINET_TEST_MISSING=git "$F" next --json) | j -e --arg c "$(pf deps_cmd git)" '$.steps[0].id == "deps" && $.steps[0].command == $c' >/dev/null || fail "next: the deps step first"
# --fix --yes never installs: it says so and gives the command.
: > "$T/fake.log"
out="$(cd "$D" && CABINET_TEST_MISSING=git "$D/bin/doctor.sh" --fix --yes 2>&1 || true)"
echo "$out" | grep -q 'installing tools always asks' && [[ "$(installs)" == 0 ]] || { echo "$out"; fail "doctor --fix --yes installed a tool"; }
# A Node.js older than 18: setup stops before making anything, the doctor says so, and the scripts'
# JavaScript stops with the same message instead of a syntax error.
out="$(CABINET_TEST_NODE_VERSION=12.22.9 "$F" new "$T/oldnode" --yes 2>&1)" && fail "setup went ahead with an old Node.js"
echo "$out" | grep -q 'cabinet needs Node.js 18 or newer; this is 12.22.9' && [[ ! -e "$T/oldnode" ]] || { echo "$out"; fail "setup with an old Node.js"; }
out="$(cd "$D" && CABINET_TEST_NODE_VERSION=12.22.9 "$D/bin/doctor.sh" 2>&1 || true)"
echo "$out" | grep -q 'FIX.*cabinet needs Node.js 18 or newer; this is 12.22.9' || { echo "$out"; fail "doctor: an old Node.js"; }
(cd "$D" && "$F" doctor --json) | j -e '$.results.find((r) => r.id == "deps.node")?.level == "ok"' >/dev/null || fail "doctor: a new enough Node.js"
rc=0; out="$(CABINET_TEST_NODE_VERSION=16.20.2 L json -n 1 2>&1)" || rc=$?
[[ $rc == 1 && "$out" == *"cabinet needs Node.js 18 or newer; this is 16.20.2"* ]] || fail "lib.js on an old Node.js: $out"
  return 0   # a last "check && fail" line must not end the run
}

section "quiet days: a scheduled brief skips its agent when nothing changed" ""
s45() {
"$F" new "$T/quiet" --yes >/dev/null
Q="$T/quiet"
# The runner counts its runs and writes the brief from $T/qbrief.
printf '# Brief\n\n## Sign-off queue\n\nNone.\n' > "$T/qbrief"
printf '%s\n' 'CABINET_RUNNER="custom"' "CABINET_RUNNER_CMD='echo run >> \"$T/qruns\"; cp \"$T/qbrief\" BRIEF.md'" >> "$Q/cabinet.env"
qc() { git -C "$Q" add -A && git -C "$Q" commit -qm "$1"; }
qc "custom runner"
r() { "$Q/bin/job.sh" run brief 2>&1; }   # stdout is not a terminal: run as the scheduler runs it
runs() { [[ "$(wc -l < "$T/qruns" | tr -d ' ')" == "$1" ]]; }
r >/dev/null; runs 1 || fail "the first run did not run"
touch -t 202601010000 "$Q/BRIEF.md"
r | grep -q 'brief skipped: nothing changed since the full run of' && runs 1 || fail "a run with nothing new was not skipped"
grep -q 'brief skipped: nothing changed' "$HOME/$LOGS/quiet/brief.log" || fail "the skip is not in the log"
[[ -n "$(find "$Q/BRIEF.md" -newer "$Q/cabinet.env")" ]] || fail "a skipped run left BRIEF.md looking late"
# A commit, uncommitted work (every time: it is asked about after a day) and an edited brief each run it.
echo x > "$Q/notes/q.md"; qc "a note"; r >/dev/null; runs 2 && r >/dev/null && runs 2 || fail "a commit did not run the brief, or the next run did not skip"
echo y >> "$Q/notes/q.md"; r >/dev/null; r >/dev/null; runs 4 || fail "uncommitted work did not run the brief every time"
git -C "$Q" checkout -q -- notes/q.md; r >/dev/null; r >/dev/null; runs 5 || fail "back to clean: not one run, then a skip"
echo "1. answered: a" >> "$Q/BRIEF.md"; r >/dev/null; r >/dev/null; runs 6 || fail "an edited brief did not run it once"
# A reversible item waiting for its 72 hours runs it every time.
printf '# Brief\n\n## Sign-off queue\n\n1. Rename the page. Reversible: default.\n' > "$T/qbrief"
echo "2. b" >> "$Q/BRIEF.md"; r >/dev/null; r >/dev/null; runs 8 || fail "a default item in the queue was skipped"
printf '# Brief\n\n## Sign-off queue\n\nNone.\n' > "$T/qbrief"; r >/dev/null; r >/dev/null; runs 9 || fail "no skip after the default item went"
# At most QUIET_DAYS days after the last full run.
st="$HOME/$LOGS/quiet/brief.quiet"; { echo $(( $(date +%s) - 6 * 86400 - 60 )); tail -1 "$st"; } > "$T/q.state"; cp "$T/q.state" "$st"
r >/dev/null; r >/dev/null; runs 10 || fail "a run past QUIET_DAYS was skipped"
# 0 runs every time; anything but whole days is refused.
sedi 's/^QUIET_DAYS=.*/QUIET_DAYS="0"/' "$Q/jobs/brief.job"; qc "never quiet"; r >/dev/null; r >/dev/null; runs 12 || fail "QUIET_DAYS=0 skipped"
sedi 's/^QUIET_DAYS=.*/QUIET_DAYS="a week"/' "$Q/jobs/brief.job"; st=0; r >/dev/null || st=$?
((st == 2)) && runs 12 || fail "a QUIET_DAYS that is not whole days was not refused"
  return 0   # a last "check && fail" line must not end the run
}

section "spend: what agent runs cost this week, and a budget the doctor warns about" ""
s46() {
"$F" new "$T/spend" --yes >/dev/null
S="$T/spend"
sedi 's/^QUIET_DAYS=.*/QUIET_DAYS="0"/' "$S/jobs/brief.job"; { git -C "$S" diff --quiet || git -C "$S" commit -qam "run every time"; }
# A fake claude that answers as claude -p --output-format json does, at $1.50 a run.
mkdir -p "$T/fakeclaude"
printf '#!/bin/sh\necho "$*" >> "%s"\nprintf %s > BRIEF.md\nprintf %s\n' "$T/claude.args" "'# Brief\n'" \
  "'{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"brief written\",\"total_cost_usd\":1.5}'" > "$T/fakeclaude/claude"
chmod +x "$T/fakeclaude/claude"
r() { PATH="$T/fakeclaude:$PATH" "$S/bin/job.sh" run brief >/dev/null 2>&1; }
dr() { "$S/bin/doctor.sh" --json | j -r --each '$.results.filter((r) => r.id == "spend.budget").map((r) => r.level + " " + r.message)'; }
r || fail "a run with the claude runner failed"
grep -q -- '--output-format json' "$T/claude.args" || fail "claude not asked for JSON"
grep -qx 'brief written' "$HOME/$LOGS/spend/brief.log" || fail "the reply did not reach the log"
grep -q 'cost \$1.50, as claude reports it; this week \$1.50$' "$HOME/$LOGS/spend/brief.log" || fail "the run's cost is not in the log"
"$S/bin/job.sh" list | grep -E '^brief .* \$1\.50$' >/dev/null || fail "job list does not show the job's cost"
"$S/bin/job.sh" list | grep -q 'This week: \$1.50 in all, as claude reports it, no budget set' || fail "job list total"
"$S/bin/job.sh" list --json | j -e '$[0].cost_this_week_usd == 1.5' >/dev/null || fail "job list --json cost"
dr | grep -q '^ok agent runs cost \$1.50 this week, as claude reports it; no budget set' || fail "doctor without a budget"
# Runs from before this week do not count.
printf '%s\tbrief\tclaude\t9\n' "$(( $(bash -c 'cd "$1" && source bin/lib.sh && week_start' _ "$S") - 1 ))" >> "$HOME/$LOGS/spend/spend.tsv"
dr | grep -q 'cost \$1.50 this week' || fail "a run from last week was counted"
# The week starts on the day AGENTS.md names: today, so it began at midnight.
sedi "s/^- \*\*Week starts on:\*\* [A-Za-z]*\./- **Week starts on:** $(LC_ALL=C date +%A)./" "$S/AGENTS.md"
ws="$(bash -c 'cd "$1" && source bin/lib.sh && week_start' _ "$S")"; now="$(date +%s)"
(( now - ws >= 0 && now - ws < 86400 )) && [[ "$(pf epoch_date "$ws" +%H%M%S)" == 000000 ]] || fail "the week does not start today at midnight"
git -C "$S" checkout -q -- AGENTS.md
# A budget: warned from 80%, and when passed.
(cd "$S" && "$F" config --yes --budget 1.8) >/dev/null || fail "config --budget"
grep -qx 'CABINET_BUDGET="1.8"' "$S/cabinet.env" || fail "budget not written"
dr | grep -q '^fix agent runs cost \$1.50 this week, 83% of the \$1.8 budget' || fail "no warning at 83%"
{ git -C "$S" diff --quiet || git -C "$S" commit -qam budget; }; r
dr | grep -q '^fix agent runs cost \$3.00 this week, over the \$1.8 budget' || fail "no warning over the budget"
grep -q 'this week \$3.00 of the \$1.8 budget$' "$HOME/$LOGS/spend/brief.log" || fail "the log does not name the budget"
(cd "$S" && "$F" config --yes --budget 20) >/dev/null; dr | grep -q '^ok agent runs cost \$3.00 this week, 15% of the \$20 budget' || fail "under the budget"
(cd "$S" && "$F" config --yes --budget 1.234) >/dev/null 2>&1 && fail "a budget with three decimals accepted"
(cd "$S" && "$F" config --yes --budget 0) >/dev/null 2>&1 && fail "a zero budget accepted"
(cd "$S" && "$F" config --yes --this-machine --budget 5) >/dev/null 2>&1 && fail "--this-machine accepted --budget"
(cd "$S" && "$F" config --yes --budget off) >/dev/null && grep -qx 'CABINET_BUDGET=""' "$S/cabinet.env" || fail "budget off"
# A runner that does not report its cost: no column, and a set budget is named as untracked.
(cd "$S" && "$F" config --yes --runner codex --budget 20) >/dev/null
"$S/bin/job.sh" list | grep -q 'codex reports tokens, not dollars: set its price' && "$S/bin/job.sh" list | grep -E '^brief .* min  -$' >/dev/null || fail "job list with codex and no price"
"$S/bin/doctor.sh" --json | j -e '$.results.findLast((r) => r.id == "spend.unreported")?.message.includes("cabinet config --price")' >/dev/null || fail "an unpriced budget not noted"
for bad in abc "1" "1 2 3 4" "1 -2"; do (cd "$S" && "$F" config --yes --price "$bad") >/dev/null 2>&1 && fail "the price '$bad' was accepted"; done
(cd "$S" && "$F" config --yes --price "2 10 0.5") >/dev/null && grep -qx 'CABINET_PRICE="2 10 0.5"' "$S/cabinet.env" || fail "config --price"
{ git -C "$S" diff --quiet || git -C "$S" commit -qam "codex, priced"; }
# Each runner's JSON, as seen live (documented, for claude): the reply reaches the log, and the
# run is recorded in dollars, reported or priced at 2, 10 and 0.5 dollars per million tokens.
mkdir -p "$T/fakes"
fk() { printf '#!/bin/sh\ncat <<"EOF"\n%s\nEOF\n' "$2" > "$T/fakes/$1"; chmod +x "$T/fakes/$1"; }
fk grok '{"text":"brief written","stopReason":"end_turn","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":100},"total_cost_usd":0.015}'
fk opencode '{"type":"step_start","part":{"type":"step-start"}}
{"type":"text","part":{"type":"text","text":"brief written"}}
{"type":"step_finish","part":{"type":"step-finish","reason":"stop","cost":0,"tokens":{"input":1000,"output":100,"reasoning":0,"cache":{"read":0,"write":0}}}}'
fk codex '{"type":"thread.started","thread_id":"x"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"brief written"}}
{"type":"turn.completed","usage":{"input_tokens":3000,"cached_input_tokens":1000,"output_tokens":100}}'
fk cursor-agent '{"type":"result","subtype":"success","is_error":false,"result":"brief written","usage":{"inputTokens":1000,"outputTokens":100,"cacheReadTokens":1000,"cacheWriteTokens":0}}'
fk qwen '[{"type":"result","subtype":"success","is_error":false,"result":"brief written","usage":{"input_tokens":1000,"output_tokens":100}}]'
fk agy '{"conversation_id":"x","status":"SUCCESS","response":"brief written","num_turns":1,"usage":{"input_tokens":2000,"output_tokens":80,"thinking_tokens":20,"cache_read_tokens":1000,"total_tokens":2100}}'
for want in grok:0.015 opencode:0.003000 codex:0.005500 cursor:0.003500 qwen:0.003000 antigravity:0.003500; do
  rn="${want%%:*}"; sedi "s/^CABINET_RUNNER=.*/CABINET_RUNNER=\"$rn\"/" "$S/cabinet.env"; git -C "$S" commit -qam "$rn"
  : > "$HOME/$LOGS/spend/brief.log"
  PATH="$T/fakes:$PATH" "$S/bin/job.sh" run brief >/dev/null 2>&1 || fail "the $rn runner failed"
  grep -qx 'brief written' "$HOME/$LOGS/spend/brief.log" || { cat "$HOME/$LOGS/spend/brief.log"; fail "the $rn reply did not reach the log"; }
  tail -1 "$HOME/$LOGS/spend/spend.tsv" | awk -F'\t' -v r="$rn" -v d="${want#*:}" '$3 == r && $4 == d { ok = 1 } END { exit !ok }' || { tail -1 "$HOME/$LOGS/spend/spend.tsv"; fail "the $rn run was not recorded as \$${want#*:}"; }
done
grep -q 'priced from antigravity.s token counts' "$HOME/$LOGS/spend/brief.log" || fail "the log does not say the cost was priced from tokens"
# A run alone that costs under half a cent still says what it cost.
: > "$HOME/$LOGS/spend/brief.log"; mv "$HOME/$LOGS/spend/spend.tsv" "$T/spend.keep"
PATH="$T/fakes:$PATH" "$S/bin/job.sh" run brief >/dev/null 2>&1; cat "$HOME/$LOGS/spend/spend.tsv" >> "$T/spend.keep"; mv "$T/spend.keep" "$HOME/$LOGS/spend/spend.tsv"
grep -q 'cost under \$0.01, priced from' "$HOME/$LOGS/spend/brief.log" || { cat "$HOME/$LOGS/spend/brief.log"; fail "a run under half a cent logged no cost"; }
printf '#!/bin/sh\necho "$*" > "%s"\n' "$T/agy.args" > "$T/fakes/agy"; PATH="$T/fakes:$PATH" "$S/bin/job.sh" run brief >/dev/null 2>&1
grep -q '^-p Act as the chief-of-staff role: read agents/chief-of-staff.md.* --output-format json --dangerously-skip-permissions$' "$T/agy.args" || { cat "$T/agy.args"; fail "the antigravity runner's arguments"; }
# gemini was a runner: it says what to use instead.
sedi 's/^CABINET_RUNNER=.*/CABINET_RUNNER="gemini"/' "$S/cabinet.env"; git -C "$S" commit -qam gemini
"$S/bin/job.sh" run brief >/dev/null 2>&1 && fail "the gemini runner still runs"
grep -q 'CABINET_RUNNER=gemini is no longer a runner .*cabinet config --runner antigravity' "$HOME/$LOGS/spend/brief.log" || fail "the gemini runner does not say what to use"
(cd "$S" && "$F" config --yes --runner gemini) 2>&1 | grep -q 'use --runner antigravity' || fail "config --runner gemini does not say what to use"
# A runner that is not that JSON (an error, an older version): its output reaches the log as it is.
fk qwen 'No auth type is selected.'; sedi 's/^CABINET_RUNNER=.*/CABINET_RUNNER="qwen"/' "$S/cabinet.env"; git -C "$S" commit -qam qwen2
PATH="$T/fakes:$PATH" "$S/bin/job.sh" run brief >/dev/null 2>&1; grep -qx 'No auth type is selected.' "$HOME/$LOGS/spend/brief.log" || fail "output that is not JSON was lost"
(cd "$S" && "$F" config --yes --runner custom --runner-cmd 'true') >/dev/null
"$S/bin/doctor.sh" --json | j -e '$.results.findLast((r) => r.id == "spend.unreported")?.message.includes("does not report what a run costs")' >/dev/null || fail "a custom runner's budget not noted"
  return 0   # a last "check && fail" line must not end the run
}

section "writing to the owner: short or standard" ""
s47() {
wl() { grep '^- \*\*Writing to the owner:\*\*' "$1/AGENTS.md"; }
"$F" new "$T/wr-s" --yes --writing Short >/dev/null && wl "$T/wr-s" | grep -q '^- \*\*Writing to the owner:\*\* short\. ' || fail "new --writing short"
"$F" new "$T/wr-d" --yes >/dev/null && wl "$T/wr-d" | grep -q '^- \*\*Writing to the owner:\*\* standard\. ' || fail "writing is not standard by default"
"$F" new "$T/wr-x" --yes --writing terse >/dev/null 2>&1 && fail "--writing terse accepted"
"$F" new "$T/wr-n" --yes --writing short --dry-run | grep -q 'writing short' || fail "new --dry-run does not show writing"
(cd "$T/wr-s" && "$F" config --yes --writing standard --dry-run) | grep -q 'writing to the owner: short -> standard' && wl "$T/wr-s" | grep -q 'short\.' || fail "config --dry-run"
(cd "$T/wr-s" && "$F" config --yes --writing standard) >/dev/null && wl "$T/wr-s" | grep -q 'standard\.' || fail "config --writing standard"
(cd "$T/wr-s" && "$F" config --yes --writing standard) | grep -q 'Nothing to change' || fail "the same writing again is a change"
# An AGENTS.md from before the setting gets the line, once, after the week start.
sedi '/^- \*\*Writing to the owner:\*\*/d' "$T/wr-d/AGENTS.md"
(cd "$T/wr-d" && "$F" config --yes --writing short) >/dev/null || fail "config --writing on an older AGENTS.md"
[[ "$(wl "$T/wr-d" | wc -l | tr -d ' ')" == 1 ]] && grep -A1 '^- \*\*Week starts on:\*\*' "$T/wr-d/AGENTS.md" | grep -q '^- \*\*Writing to the owner:\*\* short\.' || fail "the line not added once after the week start"
(cd "$T/wr-d" && "$F" config --yes --this-machine --writing short) >/dev/null 2>&1 && fail "--this-machine accepted --writing"
# What short means is in the rules every agent reads, and the brief follows it.
grep -q '^## Writing to the owner$' "$KIT/core/CABINET.md" && grep -q '^\*\*short\*\*: ' "$KIT/core/CABINET.md" || fail "CABINET.md has no short writing rules"
grep -q 'Write `BRIEF.md` as "Writing to the owner" in `AGENTS.md` sets' "$KIT/roles/chief-of-staff.md" || fail "the brief does not follow the setting"
  return 0   # a last "check && fail" line must not end the run
}

section "ready to build: specs checked against their status, reviewed, and routed only when ready" "0"
s48() {
local sp="$W/specs/login.md" c out rc base
base="$(git -C "$W" rev-parse HEAD)"
spc() { "$W/bin/spec.sh" check specs/login.md --json | j -r '$[0].problems.join("; ")'; }
put() { while (($#)); do L sub-all "$sp" "$1" "$2"; shift 2; done; git -C "$W" commit -qm "spec" -- specs/login.md; }   # put </pattern/flags> <replacement>...
# A fresh copy of the template, as draft: nothing needed, and the template's own "TBD" guidance is no TBD.
sed 's/^status: draft.*/status: draft/' "$W/specs/_template.md" > "$sp"; git -C "$W" add specs/login.md; git -C "$W" commit -qm "spec: login"
"$F" -C "$W" spec check >/dev/null || fail "a draft spec failed the check"
put '/^status: draft/m' 'status: ready'
c="$(spc)"; [[ "$c" == "no acceptance criteria; no repos or areas named; no qa review of the acceptance criteria" ]] || fail "an empty ready spec: $c"
put '/^repos: \[\]/m' 'repos: [api]' '/(## Acceptance criteria\n\n)/' $'$1- GET /login returns 200 with a session for a valid password\n' '/(## Rules\n\n)/' $'$1Sessions last TBD days.\n' \
  '/(\|---\|---\|---\|---\|---\|\n)/' $'$1| 1 | Session length? | A. 7 days. B. 30 days. | A | A (20 Oct 2026) |\n| 2 | Remember me? | A. yes. B. no. | B | |\n'
c="$(spc)"; [[ "$c" == "TBD left in Rules; 1 decision(s) not answered; no qa review of the acceptance criteria" ]] || fail "a ready spec with open questions: $c"
rc=0; "$W/bin/handoff.sh" add --from chief-of-staff --to api --changed x --needed y --spec specs/login.md "Login" >/dev/null 2>&1 || rc=$?
[[ $rc == 1 ]] || fail "handoff add routed a spec that is not ready"
put '/Sessions last TBD days/' 'Sessions last 7 days' '/\| B \| \|/' '| B | B (20 Oct 2026) |'
mkdir -p "$W/specs/qa" "$W/specs/adr" && echo "testable" > "$W/specs/qa/login.md" && echo "plan ok" > "$W/specs/adr/login.md"
git -C "$W" add specs/qa specs/adr && git -C "$W" commit -qm "notes"
"$W/bin/spec.sh" record specs/login.md --role web PASS --note specs/qa/login.md >/dev/null 2>&1 && fail "spec record took a role other than qa or architect"
out="$(cd "$W/specs" && "$F" spec record login.md --role qa block --note qa/login.md)" && [[ "$out" == "specs/login.md: qa BLOCK recorded and committed" ]] || fail "spec record BLOCK: $out"
c="$(spc)"; [[ "$c" == "qa BLOCK on the acceptance criteria" ]] || fail "a qa BLOCK: $c"
"$W/bin/spec.sh" record specs/login.md --role qa PASS --note specs/qa/login.md >/dev/null || fail "spec record PASS"
[[ "$(grep -c '^- Verdict: qa ' "$sp")" == 1 && -z "$(spc)" && -z "$(git -C "$W" status --porcelain -- specs/login.md)" ]] || fail "the qa review did not replace the BLOCK, pass the check and commit: $(spc)"
grep -Eq '^- Verdict: qa PASS [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9a-f]{8} specs/qa/login.md$' "$sp" || fail "the spec review line"
out="$("$W/bin/handoff.sh" add --from chief-of-staff --to api --changed "Nothing yet." --needed "Build login" --spec specs/login.md "Login")" || fail "a ready spec was not routed: $out"
grep -qx -- "- Spec: specs/login.md" "$W/HANDOFFS.md" || fail "the routed handoff does not name its spec"
# A change to the criteria after the PASS needs a new review; a spec not committed is not reviewed.
put '/(valid password\n)/' $'$1- A wrong password returns 401\n'
c="$(spc)"; [[ "$c" == "the acceptance criteria changed since qa passed it" ]] || fail "a changed criterion kept its review: $c"
echo "- draft line" >> "$sp"
"$W/bin/spec.sh" record specs/login.md --role qa PASS --note specs/qa/login.md >/dev/null 2>&1 && fail "spec record reviewed a spec that is not committed"
git -C "$W" checkout -q -- specs/login.md
"$W/bin/spec.sh" record specs/login.md --role qa PASS --note specs/qa/login.md >/dev/null && [[ -z "$(spc)" ]] || fail "a new review did not clear the change"
# building: each repo's plan, and for more than one repo an architect PASS on the plan as it is.
put '/^status: ready/m' 'status: building' '/^repos: \[api\]/m' 'repos: [api, app]' '/(## Plan\n\n.*\n)/' $'$1\n### api\n\n- routes/login.ts, with tests\n'
c="$(spc)"; [[ "$c" == "no plan for app; no architect review of the plan" ]] || fail "building without every plan: $c"
"$W/bin/doctor.sh" 2>&1 | grep -q "specs not ready for their status: specs/login.md (no plan for app, no architect review of the plan)" || fail "doctor: specs.ready"
put '/(### api\n\n.*\n)/' $'$1\n### app\n\n- the login screen, after api\n'
"$W/bin/spec.sh" record specs/login.md --role architect PASS --note specs/adr/login.md >/dev/null && [[ -z "$(spc)" ]] || fail "building with every plan and the architect: $(spc)"
"$W/bin/doctor.sh" 2>&1 | grep -q 'every spec marked ready or building has what its status needs' || fail "doctor after the plan"
"$F" -C "$W" spec check | grep -q '^specs/login.md (building): ok$' || fail "spec check text"
grep -q '^## Ready to build' "$KIT/core/CABINET.md" && grep -q 'route nothing from the owner.s words' "$KIT/roles/chief-of-staff.md" && grep -q '^## Reviewing a spec' "$KIT/roles/qa.md" \
  && grep -q 'Review the plan of every spec built in more than one repo' "$KIT/roles/architect.md" && grep -q 'your plan in a spec routed to you' "$KIT/roles/web.md" || fail "a ready-to-build rule left CABINET.md or a role"
# What people see is designed first: a spec built in a repo the web builder owns needs design-lead's design.
printf 'app\t-\t-\tno\n' >> "$W/repos.tsv"; L before "$W/AGENTS.md" '/^\| workspace \(this folder\)/' '| `app` | The web app | web |'
git -C "$W" commit -qam "app, built by web"
c="$(spc)"; [[ "$c" == "no design for what people see; no design-lead review of the design" ]] || fail "a UI spec without a design: $c"
put '/(## Design\n\n.*\n)/' $'$1\n- Login: email and password, then the dashboard; states: empty, wrong password, locked.\n'
mkdir -p "$W/specs/design" && echo "flows ok" > "$W/specs/design/login.md" && git -C "$W" add specs/design && git -C "$W" commit -qm "design note"
"$W/bin/spec.sh" record specs/login.md --role design-lead PASS --note specs/design/login.md >/dev/null && [[ -z "$(spc)" ]] || fail "a designed UI spec: $(spc)"
put '/(states: empty, wrong password, locked\.)/' '$1 Remember me, off by default.'
c="$(spc)"; [[ "$c" == "the design changed since design-lead passed it" ]] || fail "a changed design kept its review: $c"
grep -q '^## Designing a feature' "$KIT/roles/design-lead.md" && grep -q '^## Design$' "$KIT/templates/workspace/specs/_template.md" \
  && grep -q 'notes/seats.md' "$KIT/core/rules/seats.md" && grep -q 'Look at the project as well as the backlog' "$KIT/roles/chief-of-staff.md" \
  && grep -q 'ships none for each specialty' "$KIT/core/rules/seats.md" && grep -q '^- \*\*Work that changes no repo\*\*' "$KIT/core/rules/ready-to-build.md" || fail "an adaptive-team rule left CABINET.md, the template or a role"
git -C "$W" reset -q --hard "$base"; rm -rf "$W/specs/qa" "$W/specs/adr" "$W/specs/design"
  return 0   # a last "check && fail" line must not end the run
}

section "small tasks: marked when filed, checked against their commits" "0"
s49() {
local base id out rc c1 c2 c3 c4 r
base="$(git -C "$W" rev-parse HEAD)"
for r in api app; do
  git init -q "$W/$r" && echo x > "$W/$r/a.js" && git -C "$W/$r" add -A && git -C "$W/$r" commit -qm init
  printf '%s\t-\t-\tno\n' "$r" >> "$W/repos.tsv"
done
L sub-all "$W/AGENTS.md" '/(\| Contract \| Repos that move together \| Source of truth \|\n\|---\|---\|---\|\n)/' $'$1| Items API | api, app | `api/openapi.yaml` |\n'
L sub-all "$W/AGENTS.md" '/(## Hard to undo\n\n.*\n\n)- none yet/' '$1- `api/migrations/`'
git -C "$W" commit -qam "repos and guarded paths"
grep -q '`api/migrations/`' "$W/AGENTS.md" && grep -q '`api/openapi.yaml` |' "$W/AGENTS.md" || fail "test setup: guarded paths"
# Work for a repo or a builder says what it is: --small or --spec, not neither, not both.
for to in api backend "qa, app"; do
  rc=0; "$W/bin/handoff.sh" add --from chief-of-staff --to "$to" --changed x --needed y "Unsized" >/dev/null 2>&1 || rc=$?
  [[ $rc == 2 ]] || fail "a handoff to $to was filed without --small or --spec"
done
"$W/bin/handoff.sh" add --from api --to qa --changed x --needed y "For qa" >/dev/null || fail "a handoff to qa needed a size"
rc=0; "$W/bin/handoff.sh" add --from chief-of-staff --to api --changed x --needed y --small --spec specs/x.md "Both" >/dev/null 2>&1 || rc=$?; [[ $rc != 0 ]] || fail "--small with --spec was accepted"
id="$("$W/bin/handoff.sh" add --from chief-of-staff --to api --changed x --needed "Fix the label" --small --evidence https://example.com/s "Label")"; id="${id%% *}"
grep -qx -- "- Size: small" "$W/HANDOFFS.md" || fail "the small handoff has no Size line"
mkdir -p "$W/specs/qa" && echo ran > "$W/specs/qa/s.md" && git -C "$W" add specs/qa && git -C "$W" commit -qm note
c() { mkdir -p "$(dirname "$W/$1/$3")"; echo "$2" > "$W/$1/$3"; git -C "$W/$1" add -A; git -C "$W/$1" commit -qm "$2"; git -C "$W/$1" rev-parse --short HEAD; }
c1="$(c api one src/label.js)" c2="$(c app two src/label.js)" c3="$(c api three migrations/001.sql)" c4="$(c api four openapi.yaml)"
rec() { "$W/bin/handoff.sh" record "$id" --role qa PASS --commits "$1" --note specs/qa/s.md 2>&1; }
out="$(rec "$c1,$c2")" && fail "a small task spanning two repos passed"; echo "$out" | grep -q 'span more than one repo (api app): it needs a spec' || fail "two repos: $out"
out="$(rec "$c3")" && fail "a small task changing a migration passed"; echo "$out" | grep -q 'changes api/migrations/001.sql' || fail "hard to undo: $out"
out="$(rec "$c4")" && fail "a small task changing a contract file passed"; echo "$out" | grep -q 'changes api/openapi.yaml' || fail "contract: $out"
out="$(rec deadbee)" && fail "a small task with an unknown commit passed"; echo "$out" | grep -q 'commit deadbee is in no repo on this machine' || fail "unknown commit: $out"
"$W/bin/handoff.sh" record "$id" --role qa BLOCK --commits "$c3" --note specs/qa/s.md >/dev/null || fail "a BLOCK on a small task that grew was refused"
out="$(rec "$c1")" || fail "a small task that stayed small did not pass: $out"
"$W/bin/doctor.sh" 2>&1 | grep -q 'every small task that passed stayed small' || fail "doctor: a small task that stayed small"
# A PASS written by hand on work that grew: the doctor flags it.
L sub "$W/HANDOFFS.md" -- '/^- Verdict: qa PASS (\S+) \S+ /' "- Verdict: qa PASS \$1 $c3 "
"$W/bin/doctor.sh" 2>&1 | grep -q "handoffs marked small that were not: $id (it changes api/migrations/001.sql" || { "$W/bin/doctor.sh" 2>&1 | grep -i small; fail "doctor: handoffs.small"; }
# cabinet config --hard-to-undo: checked against the repos, written into AGENTS.md (the section added to an older one).
L sub-all "$W/AGENTS.md" '/## Hard to undo\n.*?(?=## )/s' ''; git -C "$W" commit -qam "an AGENTS.md from before the section"
"$W/bin/doctor.sh" 2>&1 | grep -q 'AGENTS.md lists no paths that are hard to undo' || fail "doctor: agents.hard-to-undo"
cp "$W/AGENTS.md" "$T/agents.keep"
out="$(printf '\n%.0s' $(seq 60) | CABINET_TTY=/dev/stdin "$F" -C "$W" config --dry-run 2>&1)" || true
echo "$out" | grep -q 'Found in the repos: api/migrations/ api/openapi.yaml' && echo "$out" | grep -q 'hard to undo: not set -> api/migrations/ api/openapi.yaml' || { echo "$out" | tail -8; fail "config: suggestions from the repos"; }
for bad in api/nope/ web/x "api/../etc" 'api/$(x)'; do "$F" -C "$W" config --yes --hard-to-undo "$bad" >/dev/null 2>&1 && fail "config took the hard-to-undo path $bad"; done
cmp -s "$W/AGENTS.md" "$T/agents.keep" || fail "a dry run or a refused hard-to-undo path changed AGENTS.md"
"$F" -C "$W" config --yes --hard-to-undo "api/migrations/" >/dev/null || fail "config --hard-to-undo"
awk '/^## Hard to undo/ {h = NR} /^## House rules/ {r = NR} END {exit !(h && r && h < r)}' "$W/AGENTS.md" && grep -qx -- '- `api/migrations/`' "$W/AGENTS.md" || fail "the Hard to undo section was not added before House rules"
L before "$W/AGENTS.md" '/^- `api\/migrations\/`$/' 'Our own note.'; L before "$W/AGENTS.md" '/^- `api\/migrations\/`$/' ''
"$F" -C "$W" config --yes --hard-to-undo "api/migrations/  api/openapi.yaml" >/dev/null || fail "config --hard-to-undo, changed"
[[ "$(grep -c '^## Hard to undo' "$W/AGENTS.md")" == 1 ]] && grep -qx 'Our own note.' "$W/AGENTS.md" && grep -qx -- '- `api/openapi.yaml`' "$W/AGENTS.md" || fail "changing the list lost the section's text or doubled it"
"$F" -C "$W" config --yes --hard-to-undo OFF >/dev/null && grep -qx -- '- none' "$W/AGENTS.md" && ! grep -q -- '- `api/' "$W/AGENTS.md" || fail "config --hard-to-undo off"
"$F" -C "$W" config --yes --hard-to-undo off | grep -qx 'Nothing to change.' || fail "the same list again changed something"
"$W/bin/doctor.sh" 2>&1 | grep -q 'AGENTS.md says which paths are hard to undo' || fail "doctor after config --hard-to-undo off"
grep -q '^## Hard to undo' "$KIT/templates/workspace/AGENTS.md" && grep -q '^\*\*Small means small\.\*\*' "$KIT/roles/qa.md" && grep -q 'filed with `--small`' "$KIT/roles/chief-of-staff.md" || fail "a small-task rule left the AGENTS.md template, qa or chief-of-staff"
git -C "$W" reset -q --hard "$base"; rm -rf "$W/api" "$W/app" "$W/specs/qa"
  return 0   # a last "check && fail" line must not end the run
}

section "code-reviewer on by default when setup starts with repos" ""
s50() {
git init -q "$T/cr-src" && git -C "$T/cr-src" commit -q --allow-empty -m init
"$F" new "$T/cr-code" --repo "$T/cr-src" --yes --dry-run >/dev/null || fail "new with a repo, dry run"
"$F" new "$T/cr-code" --repo "$T/cr-src" --yes >/dev/null && grep -q '^CABINET_ROLES=".*code-reviewer' "$T/cr-code/cabinet.env" || fail "a workspace that starts with a repo has no code-reviewer"
"$F" new "$T/cr-none" --yes >/dev/null && ! grep -q 'code-reviewer' "$T/cr-none/cabinet.env" || fail "a workspace with no repos got code-reviewer"
"$F" new "$T/cr-chosen" --repo "$T/cr-src" --roles "qa security" --yes >/dev/null && ! grep -q 'code-reviewer' "$T/cr-chosen/cabinet.env" || fail "--roles did not win over the default"
grep -q 'product repos with no code-reviewer on the team' "$KIT/core/rules/seats.md" || fail "the code-reviewer seat signal left seats.md"
for x in cr-code cr-none cr-chosen; do "$F" -C "$T/$x" remove --yes --force >/dev/null; done
  return 0   # a last "check && fail" line must not end the run
}

section "pipeline runner: one piece of work from build to ready to push" ""
s51() {
PW="$T/pipe"; FS="$T/pipe-state"; mkdir -p "$FS" "$T/pfakes"
"$F" new "$PW" --yes >/dev/null || fail "new for the runner"
git init -q "$PW/app" && echo x > "$PW/app/a.txt" && git -C "$PW/app" add -A && git -C "$PW/app" commit -qm init
printf 'app\t-\t-\tno\n' >> "$PW/repos.tsv"
L before "$PW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `app` | The web app | web |'
git -C "$PW" commit -qam "app, built by web"
# A fake claude that acts as each role: the builder commits, hands on with --depends-on and closes the
# work; a reviewer writes a note and records PASS, or BLOCK while $FS/block-<role> counts down.
cat > "$T/pfakes/claude" <<'FAKE'
#!/bin/bash
agent="" prompt=""
while (($#)); do case "$1" in --agent) agent="$2"; shift 2 ;; --permission-mode|--output-format) shift 2 ;; -p) shift ;; *) prompt="$1"; shift ;; esac; done
id="$(printf '%s' "$prompt" | grep -oE 'H-[0-9]{8}-[0-9]+' | head -1)"
repo=app; [[ "$agent" == backend ]] && repo=api
spec="$(printf '%s' "$prompt" | grep -oE 'specs/[a-z-]+\.md' | head -1)"
if [[ "$agent" == chief-of-staff && "$prompt" == "Route "* ]]; then
  a="$(bin/handoff.sh add --from chief-of-staff --to app --spec "$spec" --changed "Nothing yet." --needed "Build the screen" "Login screen")"
  bin/handoff.sh add --from chief-of-staff --to api --spec "$spec" --changed "Nothing yet." --needed "Build the endpoint" --depends-on "${a%% *}" "Login endpoint" >/dev/null
elif [[ "$prompt" == "Write your plan for "* ]]; then
  r="$(printf '%s' "$prompt" | sed 's/^Write your plan for \([a-z]*\) .*/\1/')"
  node bin/lib.js sub-all "$spec" '/(## Plan\n\n.*?\n)(\n## Reviews)/s' "\$1"$'\n'"### $r"$'\n\n'"- the $r change, with tests"$'\n'"\$2"; git commit -qm "plan $r" -- "$spec"
elif [[ "$agent" == architect ]]; then
  mkdir -p specs/adr; echo ok > specs/adr/plan.md; git add specs/adr/plan.md; git commit -qm note -- specs/adr/plan.md
  bin/spec.sh record "$spec" --role architect PASS --note specs/adr/plan.md >/dev/null
elif [[ ( "$agent" == web || "$agent" == backend ) && "$prompt" == "Pick up handoff"* ]]; then
  if [[ -f "$FS/reject" ]]; then sed -i.bak "/^### $id:/,/^### /s/^- Status: open/- Status: rejected/" HANDOFFS.md && rm HANDOFFS.md.bak; git commit -qm rej -- HANDOFFS.md
  elif [[ ! -f "$FS/lazy" ]]; then
    echo "$id" >> $repo/a.txt; git -C $repo commit -qam "build $id"; git -C $repo rev-parse --short HEAD > "$FS/commits-$id"
    bin/handoff.sh add --from $agent --to "qa, security" --changed "built" --needed "verify" --depends-on "$id" --evidence https://example.com/p "Review $id" >/dev/null
    sed -i.bak "/^### $id:/,/^### /s/^- Status: open/- Status: done/" HANDOFFS.md && rm HANDOFFS.md.bak; git commit -qm done -- HANDOFFS.md
  fi
elif [[ "$agent" == web || "$agent" == backend ]]; then
  w="$(printf '%s' "$prompt" | grep -oE 'for H-[0-9]{8}-[0-9]+' | cut -c5-)"
  echo fix >> $repo/a.txt; git -C $repo commit -qam "fix $w"; git -C $repo rev-parse --short HEAD >> "$FS/commits-$w"
elif [[ ! -f "$FS/silent-$agent" ]]; then
  w="$(sed -n "/^### $id:/,/^### /s/^- Depends on: //p" HANDOFFS.md | head -1)"
  v=PASS; n="$(cat "$FS/block-$agent" 2>/dev/null || echo 0)"; ((n > 0)) && { v=BLOCK; echo $((n - 1)) > "$FS/block-$agent"; }
  mkdir -p "specs/$agent"; echo "checked" > "specs/$agent/$id.md"; git add "specs/$agent/$id.md"; git commit -qm note -- "specs/$agent/$id.md"
  bin/handoff.sh record "$id" --role "$agent" "$v" --commits "$(paste -sd, "$FS/commits-$w")" --note "specs/$agent/$id.md" >/dev/null
fi
echo '{"type":"result","result":"done","total_cost_usd":0.01}'
FAKE
chmod +x "$T/pfakes/claude"
run() { FS="$FS" PATH="$T/pfakes:$PATH" "$F" -C "$PW" handoff run "$@" 2>&1; }
work() { local i; i="$("$PW/bin/handoff.sh" add --from chief-of-staff --to app --changed "Nothing yet." --needed "$1" --small "$1")"; echo "${i%% *}"; }
# Work that is not ready to build, or not for one builder, is not run.
n="$("$PW/bin/handoff.sh" add --from chief-of-staff --to qa --changed x --needed y "Not work")"; n="${n%% *}"
run "$n" >/dev/null && fail "run took a handoff that is no builder's work"
rc=0; run H-1 >/dev/null || rc=$?; [[ $rc == 2 ]] || fail "run took a bad ID"
# A dry run says the next step and changes nothing.
a="$(work "Add a footer")"; h="$(git -C "$PW" rev-parse HEAD)"
out="$(run "$a" --dry-run)" && [[ "$out" == "web: builds $a" && "$(git -C "$PW" rev-parse HEAD)" == "$h" ]] || fail "run --dry-run: $out"
# From the work to ready to push: the builder, then every reviewer it needs, with what it cost.
out="$(run "$a")" || fail "run: $out"
echo "$out" | grep -q "^web: builds $a$" && echo "$out" | grep -qE '^(qa|security|design-lead): verifies H-' \
  && echo "$out" | tail -1 | grep -q "^$a is ready to push: every reviewer passed H-.*, \$0.04 so far\. Push it" || fail "run to ready: $out"
"$PW/bin/handoff.sh" list --json | j -e --arg i "$a" '!$.some((h) => h.id == $i)' >/dev/null \
  && "$PW/bin/handoff.sh" list --ready | grep -q "Review $a" || fail "the run's work is not ready by list --ready"
grep -q "builds $a" "$HOME/$LOGS/pipe/run-$a.log" || fail "the run's log"
# A BLOCK: the builder fixes it, the blocker checks again, and earlier passes now stale are run again.
b="$(work "Add a header")"; echo 1 > "$FS/block-qa"
out="$(run "$b")" || fail "run with a BLOCK: $out"
echo "$out" | grep -q "^web: fixes what qa blocked, round 1$" && [[ "$(echo "$out" | grep -c ': verifies ')" == 6 ]] && echo "$out" | tail -1 | grep -q "^$b is ready to push" || fail "run after a BLOCK: $out"
# Still blocked after the set rounds: it stops and asks.
c="$(work "Add a menu")"; echo 5 > "$FS/block-qa"
rc=0; out="$(run "$c" --retries 1)" || rc=$?
[[ $rc == 1 ]] && echo "$out" | grep -q "^Stopped: qa still block H-.* after 1 fix round(s): the owner decides" || fail "run past its retries: $out"
rm -f "$FS/block-qa"
# An agent that leaves no trace, or work sent back: it stops, naming what happened.
d="$(work "Add a logo")"; touch "$FS/silent-security"
out="$(run "$d")" && fail "run went on past a reviewer that recorded nothing"; echo "$out" | grep -q "^Stopped: security recorded no verdict on H-" || fail "a silent reviewer: $out"
rm -f "$FS/silent-security"
e="$(work "Add a map")"; touch "$FS/lazy"
out="$(run "$e")" && fail "run went on past a builder that filed nothing"; echo "$out" | grep -q "^Stopped: web ran but filed no review handoff for $e" || fail "a builder that filed nothing: $out"
rm -f "$FS/lazy"
g="$(work "Add a chart")"; touch "$FS/reject"
out="$(run "$g")" && fail "run went on past work sent back"; echo "$out" | grep -q "^Stopped: web sent $g back" || fail "work sent back: $out"
rm -f "$FS/reject"
# One run at a time for a piece of work.
mkdir "$PW/.cabinet/run-$g.lock"; out="$(run "$g")" && fail "two runs of one piece of work"; echo "$out" | grep -q 'is already being run' || fail "the run lock: $out"
rmdir "$PW/.cabinet/run-$g.lock"
# From a ready spec to ready to push: routing, each builder's plan, the architect's review of it, then
# each of its handoffs in order. Two repos, two builders.
git init -q "$PW/api" && echo x > "$PW/api/a.txt" && git -C "$PW/api" add -A && git -C "$PW/api" commit -qm init
printf 'api\t-\t-\tno\n' >> "$PW/repos.tsv"
L before "$PW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `api` | The API | backend |'
cat > "$PW/specs/login.md" <<'SPEC'
---
feature: login
status: ready
repos: [app, api]
---

# Login

## Rules

Email and password.

## Design

- One screen: email, password, a button; states: empty, wrong password.

## Acceptance criteria

- A valid password signs in.

## Decisions

| # | Question | Options | Recommendation | Owner answer (date) |
|---|---|---|---|---|

## Plan

How it will be built.

## Reviews

SPEC
mkdir -p "$PW/specs/qa" "$PW/specs/design"; echo ok > "$PW/specs/qa/login.md"; echo ok > "$PW/specs/design/login.md"
git -C "$PW" add -A && git -C "$PW" commit -qm "login spec"
"$PW/bin/spec.sh" record specs/login.md --role qa PASS --note specs/qa/login.md >/dev/null && "$PW/bin/spec.sh" record specs/login.md --role design-lead PASS --note specs/design/login.md >/dev/null \
  && "$PW/bin/spec.sh" check specs/login.md >/dev/null || fail "test setup: a ready spec: $("$PW/bin/spec.sh" check specs/login.md)"
srun() { FS="$FS" PATH="$T/pfakes:$PATH" "$F" -C "$PW" spec run "$@" 2>&1; }
out="$(srun specs/login.md --dry-run)" && [[ "$out" == "chief-of-staff: routes specs/login.md" ]] || fail "spec run --dry-run: $out"
out="$(srun specs/login.md)" || fail "spec run: $out"
echo "$out" | grep -q '^chief-of-staff: routes specs/login.md$' && echo "$out" | grep -q '^web: plans app$' && echo "$out" | grep -q '^backend: plans api$' \
  && echo "$out" | grep -q '^architect: reviews the plan in specs/login.md$' && echo "$out" | grep -q '^web: builds H-' && echo "$out" | grep -q '^backend: builds H-' \
  && echo "$out" | tail -1 | grep -qE '^specs/login.md is ready to push: all its work \(H-[0-9]+-[0-9]+, H-[0-9]+-[0-9]+\) passed review, \$0\.11 in all\. Push it' || fail "spec run to ready: $out"
[[ "$(echo "$out" | grep -n 'web: builds' | cut -d: -f1)" -lt "$(echo "$out" | grep -n 'backend: builds' | cut -d: -f1)" ]] || fail "spec run did not run the work in the order routing set"
out="$(srun specs/login.md)" && echo "$out" | tail -1 | grep -q 'is ready to push' && ! echo "$out" | grep -q ': builds ' || fail "a second spec run started agents for work already ready: $out"
# The scheduled runner: off by default, never on without a cost limit it can hold, and it writes PIPELINE.md.
cfgp() { "$F" -C "$PW" config --yes "$@" 2>&1; }
sched() { FS="$FS" PATH="$T/pfakes:$PATH" "$PW/bin/job.sh" run pipeline >/dev/null 2>&1; }
PL="$HOME/$LOGS/pipe"
"$PW/bin/doctor.sh" 2>&1 | grep -q 'ok    the scheduled runner is off' || fail "doctor: the runner off"
cfgp --pipeline small >/dev/null && fail "the runner was turned on with no cost limit"
cfgp --pipeline small --pipeline-limit 5 --runner custom --runner-cmd 'true' >/dev/null && fail "the runner was turned on with a runner whose cost cannot be counted"
cfgp --pipeline small --pipeline-limit 0 >/dev/null && fail "a cost limit of 0 was taken"
cfgp --pipeline small --pipeline-limit 1 --dry-run | grep -q 'scheduled runner: off -> small' && [[ ! -f "$PW/jobs/pipeline.job" ]] || fail "config --pipeline --dry-run"
out="$(cfgp --pipeline small --pipeline-limit 1)" || fail "config --pipeline: $out"
grep -qx 'CABINET_PIPELINE="small"' "$PW/cabinet.env" && grep -qx 'CABINET_PIPELINE_LIMIT="1"' "$PW/cabinet.env" && grep -qx 'WHEN="10:00 PM"' "$PW/jobs/pipeline.job" \
  && grep -qx 'COMMAND="bin/handoff.sh run --scheduled"' "$PW/jobs/pipeline.job" || fail "the runner's settings or job"
"$PW/bin/doctor.sh" 2>&1 | grep -q 'ok    the scheduled runner moves small work, up to \$1 a run' || fail "doctor: the runner on"
"$PW/bin/job.sh" list | grep -q '^pipeline  *command  *every day at 10:00 PM' || fail "job list: the pipeline job"
mv "$PW/jobs/pipeline.job" "$T/pipeline.job.keep"; "$PW/bin/doctor.sh" 2>&1 | grep -q 'jobs/pipeline.job is missing' || fail "doctor: the pipeline job missing"
cfgp --pipeline small >/dev/null && [[ -f "$PW/jobs/pipeline.job" ]] || fail "config did not make the missing pipeline job again"; rm -f "$T/pipeline.job.keep"
# Work stopped for the owner is skipped until the owner runs it; the rest runs, oldest first.
k="$(work "Fix a typo")"; m="$(work "Fix a label")"
printf '%s %s\n' "$(date +%F)" "qa still blocks it." > "$PL/run-$m.stopped"
sched || fail "the pipeline job: $(tail -5 "$PL/pipeline.log")"
grep -q "^- $k: $k is ready to push" "$PW/PIPELINE.md" && grep -q "^- $m: skipped, stopped on $(date +%F) for you: qa still blocks it. Once settled, run it by hand: cabinet handoff run $m" "$PW/PIPELINE.md" \
  && grep -q '^Spent \$0.04 of the \$1 limit for one run.$' "$PW/PIPELINE.md" || fail "PIPELINE.md: $(cat "$PW/PIPELINE.md")"
! git -C "$PW" status --porcelain | grep -q PIPELINE.md || fail "PIPELINE.md is tracked"
# The cost limit pauses a run before the next agent; the next run goes on from there.
rm -f "$PL/run-$m.stopped"; "$PW/bin/handoff.sh" run "$m" --dry-run >/dev/null
cfgp --pipeline-limit 0.02 >/dev/null; sched
grep -q "^- $m: Paused: this run's cost limit (\$0.02) is reached" "$PW/PIPELINE.md" && [[ ! -f "$PL/run-$m.stopped" ]] || fail "the cost limit: $(cat "$PW/PIPELINE.md")"
cfgp --pipeline all --pipeline-limit 1 >/dev/null; sched
grep -q "^- $m: $m is ready to push" "$PW/PIPELINE.md" && grep -q '^- specs/login.md: specs/login.md is ready to push' "$PW/PIPELINE.md" || fail "the next run, with specs: $(cat "$PW/PIPELINE.md")"
# A spent week, or the runner off: nothing runs.
cfgp --budget 0.01 >/dev/null; sched; grep -q "budget (\$0.01) is spent, so nothing ran" "$PW/PIPELINE.md" || fail "the runner past the week's budget: $(cat "$PW/PIPELINE.md")"
cfgp --budget off --pipeline off >/dev/null; sched; grep -q 'The pipeline is off' "$PW/PIPELINE.md" && [[ -f "$PW/jobs/pipeline.job" ]] || fail "the runner off: $(cat "$PW/PIPELINE.md")"
sed -i.bak 's/^status: ready/status: draft/' "$PW/specs/login.md" && rm "$PW/specs/login.md.bak" && git -C "$PW" commit -qam draft
srun specs/login.md >/dev/null && fail "spec run took a draft spec"
"$F" -C "$PW" remove --yes --force >/dev/null
  return 0   # a last "check && fail" line must not end the run
}

section "sub-teams: roles that report to a lead and cover part of its work" ""
s52() {
SW="$T/sub"; "$F" new "$SW" --yes >/dev/null || fail "new for sub-teams"
ra() { "$F" -C "$SW" role add "$@" --yes 2>&1; }
# role add --reports-to and --covers: the lead on the team, covers builders or repos, a 30-day trial.
ra qa-web --covers web >/dev/null && fail "--covers without --reports-to was taken"
ra qa-web --reports-to nobody >/dev/null && fail "a lead not on the team was taken"
ra qa-web --reports-to qa --covers copy >/dev/null && fail "--covers took something that is no builder or repo"
ra qa-web --reports-to qa-web >/dev/null && fail "a role reporting to itself was taken"
out="$(ra qa-mobile --reports-to qa --covers mobile)" || fail "role add --reports-to: $out"
t="$(sed -n 's/^- Trial until: //p' "$SW/roles/qa-mobile.md")"
grep -qx -- '- Reports to: qa' "$SW/roles/qa-mobile.md" && grep -qx -- '- Covers: mobile' "$SW/roles/qa-mobile.md" && [[ "$t" > "$(date +%F)" ]] || fail "the Team section: $(cat "$SW/roles/qa-mobile.md")"
"$F" -C "$SW" role list | grep -q "^qa-mobile  *project  *on, not drafted, reports to qa, covers mobile, on trial until $t$" || fail "role list: $("$F" -C "$SW" role list | grep qa-mobile)"
"$F" -C "$SW" role list --json | j -e '((r) => r.reports_to == "qa" && JSON.stringify(r.covers) == "[\"mobile\"]")($.findLast((r) => r.name == "qa-mobile"))' >/dev/null || fail "role list --json: the sub-team"
"$SW/bin/doctor.sh" 2>&1 | grep -q 'ok    every sub-team role reports to a lead on the team' || fail "doctor: a sound sub-team"
# Titles, names and functions, for any role, and the org page built from them.
ra growth --title 'Head of $(x)' >/dev/null && fail "a title with shell characters was taken"
out="$(ra growth --title "Head of Growth" --name "Growth Agent" --function Business)" || fail "role add --title: $out"
grep -qx -- '- Title: Head of Growth' "$SW/roles/growth.md" && grep -qx -- '- Function: Business' "$SW/roles/growth.md" || fail "the title in the Team section"
out="$(ra brand-designer --title "Brand Designer")" || fail "a kit role turned on with a title: $out"
grep -qx -- '- Title: Brand Designer' "$SW/roles/brand-designer.md" && grep -q '^- Title: Brand Designer$' "$SW/agents/brand-designer.md" || fail "a kit role's title"
"$F" -C "$SW" role list | grep -q '^growth  *project  *on, not drafted, Head of Growth, Growth Agent$' && "$F" -C "$SW" role list --json | j -e '((r) => r.title == "Head of Growth" && r.display_name == "Growth Agent" && r.function == "Business")($.findLast((r) => r.name == "growth"))' >/dev/null || fail "role list: titles"
o="$SW/ORG.md"
[[ -f "$o" ]] && git -C "$SW" check-ignore -q ORG.md && fail "ORG.md is ignored by git"
grep -q '^| Quality and trust | `qa` | `security`, `qa-mobile` |$' "$o" && grep -q '^| Business | `finance` | Head of Growth, Growth Agent (`growth`) |$' "$o" \
  && grep -q '^| Product | `product-manager` | `design-lead`, Brand Designer (`brand-designer`) |$' "$o" || fail "the org page's table: $(sed -n '1,14p' "$o")"
awk '/^### `qa-mobile`$/ { f = 1 } f && /^- Reports to: `qa`$/ { r = 1 } f && /^- Covers, for its lead: mobile$/ { c = 1 } END { exit !(r && c) }' "$o" \
  && grep -q '^### Head of Growth, Growth Agent (`growth`)$' "$o" && awk '/^## Business$/ { b = 1 } b && /^### Head of Growth/ { g = 1 } END { exit !g }' "$o" || fail "the org page's roles: $(cat "$o")"
"$SW/bin/role.sh" build --check >/dev/null || fail "a fresh org page is out of date"
L sub "$SW/roles/growth.md" -- '/^- Title: Head of Growth$/' '- Title: Growth Lead'
"$SW/bin/role.sh" build --check 2>&1 | grep -q 'ORG.md is out of date' || fail "build --check missed a stale org page"
"$SW/bin/role.sh" build >/dev/null && grep -q '^### Growth Lead, Growth Agent (`growth`)$' "$o" || fail "build did not rebuild the org page"
grep -q 'named by its title where it has one' "$KIT/core/CABINET.md" || fail "the sign-off rule on titles left CABINET.md"
# Its verdict counts for its lead's on the work it covers; during its trial, the lead's too.
mkdir -p "$SW/specs/qa"; echo ok > "$SW/specs/qa/n.md"; git -C "$SW" add -A; git -C "$SW" commit -qm note
sj() { "$SW/bin/handoff.sh" list --json | j -c --arg i "$1" "((\$) => $2)(\$.find((h) => h.id == \$i))"; }
rec() { "$SW/bin/handoff.sh" record "$1" --role "$2" PASS --commits a1b2c3d --note specs/qa/n.md >/dev/null || fail "record $2 on $1"; }
m="$("$SW/bin/handoff.sh" add --from mobile --to "qa, security" --changed x --needed y --evidence https://example.com/m "App screen")"; m="${m%% *}"
w="$("$SW/bin/handoff.sh" add --from web --to "qa, security" --changed x --needed y --evidence https://example.com/w "Web screen")"; w="${w%% *}"
[[ "$(sj "$m" '$.needs')" == '["qa-mobile","qa","security","design-lead"]' && "$(sj "$w" '$.needs')" == '["qa","security","design-lead"]' ]] || fail "who reviews: $(sj "$m" '$.needs') $(sj "$w" '$.needs')"
for r in qa-mobile security design-lead; do rec "$m" "$r"; done
[[ "$(sj "$m" '[$.missing, $.ready]')" == '[["qa"],false]' ]] || fail "a sub-team role on trial passed without its lead: $(sj "$m" '$')"
L sub "$SW/roles/qa-mobile.md" -- '/^- Trial until: .*/' '- Trial until: 2020-01-01'
[[ "$(sj "$m" '[$.needs, $.ready]')" == '[["qa-mobile","security","design-lead"],true]' ]] || fail "after its trial, the sub-team role's PASS did not count for its lead's: $(sj "$m" '$')"
for r in qa security design-lead; do rec "$w" "$r"; done; [[ "$(sj "$w" '$.ready')" == true ]] || fail "the lead's own review of work its sub-team does not cover"
n="$("$SW/bin/handoff.sh" add --from mobile --to "qa, security" --changed x --needed y --evidence https://example.com/n "App menu")"; n="${n%% *}"
for r in qa security design-lead; do rec "$n" "$r"; done; [[ "$(sj "$n" '$.ready')" == true ]] || fail "the lead's own PASS did not count for work its sub-team covers"
# The doctor: a lead not on the team, and a loop.
L sub "$SW/roles/qa-mobile.md" -- '/^- Reports to: qa$/' '- Reports to: nobody'
"$SW/bin/doctor.sh" 2>&1 | grep -q 'sub-team roles that do not fit the team: qa-mobile reports to nobody, who is not on the team' || fail "doctor: a lead not on the team"
ra qa-lead --reports-to qa-mobile >/dev/null || fail "role add for a loop"
L sub "$SW/roles/qa-mobile.md" -- '/^- Reports to: nobody$/' '- Reports to: qa-lead'
"$SW/bin/doctor.sh" 2>&1 | grep -q 'qa-mobile reports to itself through qa-lead' || fail "doctor: a loop"
grep -q '^## Sub-teams$' "$KIT/core/rules/seats.md" && grep -q 'A lead can grow a sub-team' "$KIT/core/CABINET.md" || fail "the sub-team rules left seats.md or CABINET.md"
"$F" -C "$SW" remove --yes --force >/dev/null
  return 0   # a last "check && fail" line must not end the run
}

section "critical areas and tools/: what a project declares, the kit applies" ""
s53() {
CW="$T/crit"; "$F" new "$CW" --yes >/dev/null || fail "new for critical areas"
[[ -f "$CW/tools/README.md" ]] && git -C "$CW" ls-files --error-unmatch tools/README.md >/dev/null 2>&1 || fail "tools/ is not placed and tracked"
git init -q "$CW/api" && mkdir -p "$CW/api/billing" "$CW/api/search" && echo x > "$CW/api/billing/charge.js" && echo x > "$CW/api/search/q.js" && git -C "$CW/api" add -A && git -C "$CW/api" commit -qm init
printf 'api\t-\t-\tno\n' >> "$CW/repos.tsv"
L before "$CW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `api` | The API | backend |'
mkdir -p "$CW/guides" && echo "Plans and prices." > "$CW/guides/pricing.md"
git -C "$CW" add -A && git -C "$CW" commit -qm "api and a pricing guide"
dr() { "$CW/bin/doctor.sh" 2>&1 || true; }
dr | grep -q 'ok    no critical areas declared' || fail "doctor: no critical areas"
# Two areas of a made-up project: code with a check, and a workspace file with none.
L sub "$CW/AGENTS.md" -- '/^\| none yet \| \| \| \| \|$/' $'| billing | `api/billing/` | security, finance | a test charge in the sandbox | `tools/check-billing.sh --fast` |\n| pricing | `workspace/guides/pricing.md` | finance | old and new prices side by side | none |'
grep -q '^| billing |' "$CW/AGENTS.md" || fail "test setup: the areas"
dr | grep -q 'critical areas in AGENTS.md that cannot hold: billing: its check is not a command in tools/ that can run' || fail "doctor: a check that cannot run: $(dr | grep -i 'critical')"
cat > "$CW/tools/check-billing.sh" <<'CHECK'
#!/bin/sh
echo "area=$CABINET_AREA handoff=$CABINET_HANDOFF commits=$CABINET_COMMITS args=$*"
[ ! -f "$CHECK_FAIL" ] || { echo "charge declined"; exit 3; }
CHECK
chmod +x "$CW/tools/check-billing.sh"
dr | grep -q 'ok    every critical area names paths, reviewers on the team and a check that can run' || fail "doctor: sound areas: $(dr | grep -i 'critical')"
dr | grep -q 'OPERATIONS.md does not mention: tools/check-billing.sh' || fail "doctor: a tool the manual does not name"
echo '- `tools/check-billing.sh`: charges the sandbox card.' >> "$CW/OPERATIONS.md"
git -C "$CW" add -A && git -C "$CW" commit -qm "areas, a check, the manual"
# The areas work touches, from its commits, and their reviewers added to what it needs.
mkdir -p "$CW/specs/qa" && echo ok > "$CW/specs/qa/n.md" && git -C "$CW" add -A && git -C "$CW" commit -qm note
cj() { "$CW/bin/handoff.sh" list --json | j -c --arg i "$1" "((\$) => $2)(\$.find((h) => h.id == \$i))"; }
rec() { CHECK_FAIL="$T/check-fails" "$CW/bin/handoff.sh" record "$1" --role "$2" "${4:-PASS}" --commits "$3" --note specs/qa/n.md 2>&1; }
echo y >> "$CW/api/billing/charge.js"; git -C "$CW/api" commit -qam bill; cb="$(git -C "$CW/api" rev-parse --short HEAD)"
echo y >> "$CW/api/search/q.js"; git -C "$CW/api" commit -qam search; cs="$(git -C "$CW/api" rev-parse --short HEAD)"
b="$("$CW/bin/handoff.sh" add --from backend --to "qa, security" --changed x --needed y --evidence https://example.com/b "Charge")"; b="${b%% *}"
o="$("$CW/bin/handoff.sh" add --from backend --to "qa, security" --changed x --needed y --evidence https://example.com/o "Search")"; o="${o%% *}"
out="$(rec "$b" qa "$cb")" && out="$(rec "$o" qa "$cs")" || fail "qa PASS: $out"
[[ "$(cj "$b" '[$.areas, $.needs]')" == '[["billing"],["qa","security","finance"]]' && "$(cj "$o" '[$.areas, $.needs]')" == '[[],["qa","security"]]' ]] || fail "areas from commits: $(cj "$b" '[$.areas, $.needs]') $(cj "$o" '[$.areas, $.needs]')"
# A reviewer the area names passes only when its check passes; the output is kept as evidence.
touch "$T/check-fails"; out="$(rec "$b" security "$cb")" && fail "a PASS went through a failing check"
echo "$out" | grep -q 'the billing check failed (exit 3)' && echo "$out" | grep -q 'charge declined' && ! grep -q '^- Verdict: security' "$CW/HANDOFFS.md" && [[ ! -f "$CW/specs/evidence/$b/check-billing.txt" ]] || fail "a failing check: $out"
rm "$T/check-fails"; out="$(rec "$b" security "$cb")" || fail "security PASS with a passing check: $out"
grep -q "^area=billing handoff=$b commits=$cb args=--fast$" "$CW/specs/evidence/$b/check-billing.txt" && grep -qF "[check-billing.txt](specs/evidence/$b/check-billing.txt)" "$CW/HANDOFFS.md" \
  && [[ -z "$(git -C "$CW" status --porcelain -- specs HANDOFFS.md)" ]] || fail "the check's output as evidence"
rec "$b" finance "$cb" >/dev/null || fail "finance PASS"; [[ "$(cj "$b" '$.ready')" == true ]] || fail "work through a critical area is not ready: $(cj "$b" '$')"
rec "$o" security "$cs" >/dev/null && [[ "$(cj "$o" '$.ready')" == true ]] || fail "work outside the areas needed more"
# A workspace file as an area, for work with no code; and a spec that names an area before any commit.
echo "Pro: 12 dollars" >> "$CW/guides/pricing.md"; git -C "$CW" commit -qm price -- guides/pricing.md; cp="$(git -C "$CW" rev-parse --short HEAD)"
q="$("$CW/bin/handoff.sh" add --from product-manager --to qa --changed x --needed y --evidence https://example.com/p "Prices")"; q="${q%% *}"
out="$(rec "$q" qa "$cp")" || fail "qa PASS on a workspace area: $out"; [[ "$(cj "$q" '[$.areas, $.needs]')" == '[["pricing"],["qa","finance"]]' ]] || fail "a workspace area: $(cj "$q" '[$.areas, $.needs]')"
printf -- '---\nfeature: pay\nstatus: draft\nrepos: [api]\nareas: [billing]\n---\n\n# Pay\n' > "$CW/specs/pay.md"; git -C "$CW" add -A && git -C "$CW" commit -qm spec
s="$("$CW/bin/handoff.sh" add --from chief-of-staff --to qa --changed x --needed y "Pay")"; s="${s%% *}"
L sub-all "$CW/HANDOFFS.md" "/(### $s:(?:(?!\n### )[\s\S])*?\n)(- Depends on:)/" $'$1- Spec: specs/pay.md\n$2'
[[ "$(cj "$s" '$.areas')" == '["billing"]' ]] || fail "areas from a spec, before any commit: $(cj "$s" '$')"
sed -i.bak 's/^areas: \[billing\]/areas: [billing, nope]/; s/^status: draft/status: ready/' "$CW/specs/pay.md" && rm "$CW/specs/pay.md.bak"
"$CW/bin/spec.sh" check specs/pay.md | grep -q 'areas names nope, which is no critical area in AGENTS.md' || fail "spec check: an unknown area"
# An area whose name has spaces stays whole: in the spec check and in what the entry needs.
L before "$CW/AGENTS.md" '/^\| pricing \|/' '| card data | `api/cards/` | security | a card number masked | none |'
printf -- '---\nfeature: cards\nstatus: ready\nrepos: [api]\nareas: [billing, Card Data]\n---\n\n# Cards\n' > "$CW/specs/cards.md"
printf -- '---\nfeature: half\nstatus: ready\nrepos: [api]\nareas: [card]\n---\n\n# Half\n' > "$CW/specs/half.md"; git -C "$CW" add -A && git -C "$CW" commit -qm "cards"
out="$("$CW/bin/spec.sh" check specs/cards.md)" || true; ! echo "$out" | grep -q 'areas names' || fail "spec check: an area with spaces: $out"
"$CW/bin/spec.sh" check specs/half.md | grep -q 'areas names card, which is no critical area in AGENTS.md' || fail "spec check: one word of an area with spaces"
k="$("$CW/bin/handoff.sh" add --from chief-of-staff --to qa --changed x --needed y "Cards")"; k="${k%% *}"
L sub-all "$CW/HANDOFFS.md" "/(### $k:(?:(?!\n### )[\s\S])*?\n)(- Depends on:)/" $'$1- Spec: specs/cards.md\n$2'
[[ "$(cj "$k" '[$.areas, $.needs]')" == '[["billing","card data"],["qa","security","finance"]]' ]] || fail "areas with spaces from a spec: $(cj "$k" '[$.areas, $.needs]')"
# Only a command in tools/ runs, never through a shell.
git -C "$CW" checkout -q -- HANDOFFS.md specs 2>/dev/null || true
L sub "$CW/AGENTS.md" -- '/`tools\/check-billing.sh --fast`/' '`sh -c "touch pwned"`'
dr | grep -q "billing: its check is not a command in tools/ that can run" || fail "doctor: a check outside tools/"
w2="$("$CW/bin/handoff.sh" add --from backend --to "qa, security" --changed x --needed y --evidence https://example.com/w "Refund")"; w2="${w2%% *}"
rec "$w2" qa "$cb" >/dev/null || true; out="$(rec "$w2" security "$cb")" && fail "record ran a check outside tools/"
echo "$out" | grep -q 'is not a command in tools/' && [[ ! -e "$CW/pwned" ]] || fail "a check outside tools/: $out"
grep -q '^## Critical areas$' "$KIT/core/rules/reviews.md" && grep -q '^## Critical areas$' "$KIT/templates/workspace/AGENTS.md" || fail "the critical areas rules left reviews.md or the AGENTS.md template"
"$F" -C "$CW" remove --yes --force >/dev/null
  return 0   # a last "check && fail" line must not end the run
}

section "the manual as a page: built from OPERATIONS.md, safe, never silently behind" ""
s54() {
MW="$T/man"; "$F" new "$MW" --yes --name "Manual Co" >/dev/null || fail "new for the manual page"
h="$MW/OPERATIONS.html"
[[ -f "$h" ]] && git -C "$MW" check-ignore -q OPERATIONS.html || fail "setup did not build the page, or it is tracked"
grep -q '<title>.*Manual Co' "$h" && grep -q '<nav>' "$h" && grep -q '<li class="l2"><a href="#' "$h" && grep -q '<table>' "$h" && grep -q 'type="checkbox" data-box="1"' "$h" || fail "the page's parts"
! grep -qE '<link |<script src=|src="https?:|url\(https?:' "$h" || fail "the page fetches something"
"$MW/bin/manual.sh" build --check || fail "a fresh page is called older"
grep -qx 'AFTER="bin/manual.sh build"' "$MW/jobs/brief.job" || fail "the brief does not rebuild the page"
# The Markdown is escaped: nothing in it runs, and only safe links link.
cat >> "$MW/OPERATIONS.md" <<'MD'

## Page test

A <script>alert(1)</script> line, a [bad](javascript:alert(1)) link, a [good](https://example.com/x) one, **bold**, *slant* and `a<b`.

<img src=x onerror=alert(1)>

| a | b \| c |
|---|---|
| `x|y` | [doc](docs/a.md) |

- [ ] Check the brief
  - nested
1. first
MD
rc=0; "$MW/bin/manual.sh" build --check >/dev/null || rc=$?; [[ $rc == 1 ]] || fail "a page older than the Markdown passed the check"
"$MW/bin/doctor.sh" 2>&1 | grep -q 'note  OPERATIONS.html is older than OPERATIONS.md' || fail "doctor: a page behind"
"$F" -C "$MW" manual build | grep -q 'Wrote OPERATIONS.html' || fail "cabinet manual build"
! grep -q '<script>alert' "$h" && ! grep -q 'href="javascript' "$h" && ! grep -q '<img' "$h" && grep -q '&lt;script&gt;alert(1)&lt;/script&gt;' "$h" \
  && grep -q '<a href="https://example.com/x">good</a>' "$h" && grep -q '<a href="docs/a.md">doc</a>' "$h" && grep -q '<strong>bold</strong>' "$h" \
  && grep -q '<em>slant</em>' "$h" && grep -q '<code>a&lt;b</code>' "$h" && grep -q '<th>b | c</th>' "$h" || fail "the page's escaping and markup: $(grep -n 'Page test' -A12 "$h")"
grep -q '<h2 id="page-test">Page test</h2>' "$h" && "$MW/bin/doctor.sh" 2>&1 | grep -q 'ok    OPERATIONS.html matches OPERATIONS.md' || fail "the rebuilt page"
"$F" -C "$MW" remove --yes --force >/dev/null
  return 0   # a last "check && fail" line must not end the run
}

section "contributor files: guide, security, conduct, issue forms" ""
s55() {
# Where contributions, security reports and conduct reports go; kept in the repository, never shipped.
repo="$(j -r '$.repository.url' "$KIT/package.json" | sed 's/^git+//; s/\.git$//')"
for f in CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md .github/PULL_REQUEST_TEMPLATE.md; do [[ -s "$KIT/$f" ]] || fail "$f is missing"; done
grep -qF '(AGENTS.md)' "$KIT/CONTRIBUTING.md" && grep -qF '(SECURITY.md)' "$KIT/CONTRIBUTING.md" || fail "CONTRIBUTING.md does not send people to AGENTS.md and SECURITY.md"
grep -q 'Report a vulnerability' "$KIT/SECURITY.md" || fail "SECURITY.md does not say how to report privately"
for f in bug feature agent-tool; do
  y="$KIT/.github/ISSUE_TEMPLATE/$f.yml"
  grep -q '^name: ' "$y" && grep -q '^description: ' "$y" && grep -q '^body:' "$y" || fail "issue form $f.yml lacks name, description or body"
done
c="$KIT/.github/ISSUE_TEMPLATE/config.yml"
grep -qx 'blank_issues_enabled: false' "$c" && grep -qF "url: $repo/security/advisories/new" "$c" && grep -qF "url: $repo/discussions" "$c" || fail "issue config does not match the repository in package.json"
j -e '!$.files.some((f) => /CONTRIBUTING|SECURITY|CODE_OF_CONDUCT|\.github/.test(f))' "$KIT/package.json" >/dev/null || fail "the package ships contributor files"
  return 0   # a last "check && fail" line must not end the run
}

section "credit and rights: notice, brand license" ""
s56() {
# The NOTICE names the copyright holder of LICENSE and ships in the package; the brand keeps its own terms.
holder="$(sed -n "s/^ *Copyright \([0-9]* .*\)$/\1/p" "$KIT/LICENSE" | tail -1)"
[[ -n "$holder" ]] && grep -qF "Copyright $holder" "$KIT/NOTICE" || fail "NOTICE does not carry the copyright line of LICENSE"
grep -qF "brand/LICENSE.md" "$KIT/NOTICE" && [[ -s "$KIT/brand/LICENSE.md" ]] || fail "the brand license is missing or not named in NOTICE"
j -e '$.files.includes("NOTICE")' "$KIT/package.json" >/dev/null || fail "the package does not ship NOTICE"
grep -qF "(NOTICE)" "$KIT/README.md" && grep -qF "(brand/LICENSE.md)" "$KIT/README.md" || fail "the README License section does not link NOTICE and the brand license"
  return 0   # a last "check && fail" line must not end the run
}

section "changelog: after a release, the next version" ""
s57() {
# A released version is closed: once its tag exists, changes since it need an unreleased section above it.
top="$(sed -n 's/^## \([0-9][0-9.]*\) - \(.*\)$/\1 \2/p' "$KIT/CHANGELOG.md" | head -1)"
ver="${top%% *}"; when="${top#* }"
[[ -n "$ver" ]] || fail "CHANGELOG.md has no version section"
if [[ "$when" != Unreleased ]] && git -C "$KIT" rev-parse -q --verify "refs/tags/v$ver" >/dev/null 2>&1; then
  since="$(git -C "$KIT" diff --name-only "v$ver" -- . 2>/dev/null | head -3 | tr '\n' ' ')"
  [[ -z "$since" ]] || fail "changes since the released $ver ($since) need a ## <next version> - Unreleased section at the top of CHANGELOG.md"
fi
grep -q '^7\. \*\*Keeps the changelog by its releases' "$KIT/core/rules/builders.md" && grep -qF 'A released version (its section dated' "$KIT/AGENTS.md" || fail "the rule for changes after a release is missing from AGENTS.md or the builders' rules"
  return 0   # a last "check && fail" line must not end the run
}

section "release workflow: publish from a GitHub release, with provenance" ""
s58() {
# Only a published GitHub release starts it; it tests before publishing, with provenance and no stored token.
w="$KIT/.github/workflows/release.yml"
[[ -s "$w" ]] || fail "the release workflow is missing"
grep -qx '  release:' "$w" && grep -qx '    types: \[published\]' "$w" && ! grep -qE '^  (push|pull_request|schedule|workflow_dispatch):' "$w" || fail "the release workflow starts on something other than a published release"
grep -q '^  id-token: write' "$w" && grep -q -- '--provenance --access public' "$w" || fail "the release workflow does not publish with provenance"
[[ "$(grep -n 'run: npm test' "$w" | cut -d: -f1)" -lt "$(grep -n -- '--provenance' "$w" | cut -d: -f1)" ]] && grep -q 'GITHUB_REF_NAME' "$w" || fail "the release workflow publishes before testing, or without checking the tag"
! grep -qi 'secrets\.' "$w" || fail "the release workflow uses a stored secret instead of trusted publishing"
# The checkout brings the release tags, without which the check on changes after a release passes unseen.
grep -q '^          fetch-depth: 0' "$w" || fail "the release workflow checks out without the release tags (fetch-depth: 0)"
# The tests the release runs fail, not pass, when the test file does not parse.
mkdir -p "$T/broken/test"; awk '{ print } /^T=.*trap/ { print "f() {"; print "if then"; print "}" }' "$KIT/test/smoke.sh" > "$T/broken/test/smoke.sh"
bash "$T/broken/test/smoke.sh" >/dev/null 2>&1 && fail "a test file that does not parse passed"
rm -rf "$T/broken"
# The runner gets every tool the Linux test image installs that a test needs (zsh, for the completion test).
grep -q 'apt-get install .*zsh' "$w" && [[ "$(grep -n 'apt-get install' "$w" | cut -d: -f1)" -lt "$(grep -n 'run: npm test' "$w" | cut -d: -f1)" ]] || fail "the release workflow runs the tests without zsh"
grep -qF '.github/workflows/release.yml' "$KIT/README.md" || fail "the README's release steps do not name the workflow"
# Code the publish identity runs is pinned: every action to a full commit hash, npm to an exact version.
# unpinned <folder>: every line of its workflows (*.yml and *.yaml) that is not; a folder with none has none.
unpinned() {
  local f
  for f in "$1"/*.yml "$1"/*.yaml; do
    [[ -f "$f" ]] || continue
    grep -E '^[[:space:]-]*uses:' "$f" | grep -vE '^[[:space:]-]*uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}( +# v[0-9][0-9.]*)?$'
    grep -E 'npm@' "$f" | grep -vE 'npm@[0-9]+\.[0-9]+\.[0-9]+([[:space:]]|$)'
    grep -E 'npm +(install|i)( +-[-a-z]+)* +npm([[:space:]]|$)' "$f"
  done
  return 0
}
[[ -z "$(unpinned "$KIT/.github/workflows")" ]] || fail "a workflow uses an action not pinned to a full commit hash, or npm not at an exact version: $(unpinned "$KIT/.github/workflows" | head -1)"
mkdir -p "$T/wf/tag" "$T/wf/latest" "$T/wf/bare" "$T/wf/none"
sed 's/@[0-9a-f]\{40\}.*/@v4/' "$w" > "$T/wf/tag/release.yaml"; sed 's/npm@[0-9.]*/npm@latest/' "$w" > "$T/wf/latest/release.yml"
printf '      - run: npm install -g npm\n      - run: npm i -g npm\n      - run: npm install -g npm@12.2.1\n' > "$T/wf/bare/npm.yml"
[[ -n "$(unpinned "$T/wf/tag")" && -n "$(unpinned "$T/wf/latest")" ]] || fail "the pin check passes an action by tag (in a .yaml workflow) or npm@latest"
[[ "$(unpinned "$T/wf/bare" | wc -l | tr -d ' ')" == 2 ]] || fail "the pin check passes npm installed with no version: $(unpinned "$T/wf/bare")"
[[ -z "$(unpinned "$T/wf/none")" ]] || fail "the pin check found something in a folder with no workflows"
rm -rf "$T/wf"
grep -q '^          persist-credentials: false' "$w" || fail "the release workflow's checkout leaves its token on disk (persist-credentials: false)"
  return 0   # a last "check && fail" line must not end the run
}

section "docs name the current version" ""
s59() {
# A doc that shows a Cabinet version shows the one in package.json, so a release cannot leave docs behind.
# The demo film's captured output (brand/demo/) is a recording and keeps the version it was captured with.
v="$(j -r '$.version' "$KIT/package.json")"
# The whole version must match: cabinet 0.1.10 is not the current one on 0.1.1.
not_current() { grep -vE ":cabinet ${v//./\\.}\$" || true; }
[[ -n "$(echo "README.md:1:cabinet ${v}0" | not_current)" ]] || fail "the version check takes cabinet ${v}0 for cabinet $v"
stale="$(cd "$KIT" && grep -rnoE 'cabinet [0-9]+\.[0-9]+\.[0-9]+' README.md llms.txt docs brand/index.html 2>/dev/null | not_current)"
[[ -z "$stale" ]] || fail "docs name an old version (package.json says $v): $stale"
! grep -qE 'version [0-9]+\.[0-9]+\.[0-9]+' "$KIT/README.md" || fail "the README names a version number: point to the changelog instead"
# The README keeps saying, near the top, that Cabinet is built with Cabinet.
grep -n '^- \*\*Built with Cabinet:\*\*' "$KIT/README.md" | cut -d: -f1 | awk '{ exit !($1 <= 20) }' || fail "the README's 'Built with Cabinet' line is gone, or no longer near the top"
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
