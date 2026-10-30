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
# Started from a Cabinet run, the suite would inherit the credit hook's variables: no commit it makes is a run's.
unset CABINET_AGENT CABINET_CREDIT CABINET_CREDIT_ADDRESS CABINET_AMEND_AS
# No section reaches the registry: the release notice is off everywhere but its own section, which fakes npm.
export CABINET_UPDATE_CHECK=off
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
# A run in a terminal (in_tty) styles its output only when TERM is not dumb: give it one that does.
[[ -n "${TERM:-}" && "$TERM" != dumb ]] || export TERM=xterm
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
# Name, folder, owner, email, 6 roles (product-manager no, finance no), 4 optional roles (Enter: off), runner, model (Enter: the tool's),
# light model (Enter: none), brief,
# budget and price (antigravity reports only tokens), week, writing, credit roles (Enter: on), backup, one repo then done, create, no npm install,
# no machine setup.
printf '%s\n' "Acme Labs" "$T/acme" "" "" n "" "" "" "" n "" "" "" "" antigravity "" "" 5 "1  2" "8:30 am" sunday short "" off git@example.com:me/acme-app.git "" y n n > "$T/answers"
CABINET_TTY="$T/answers" "$F" new >/dev/null 2>&1 || fail "prompted setup failed"
A="$T/acme"
grep -q '^# AGENTS.md - Acme Labs$' "$A/AGENTS.md" && grep -qx 'CABINET_SLUG="acme"' "$A/cabinet.env" || fail "prompted name or folder"
grep -qx 'CABINET_ROLES="chief-of-staff architect qa security design-lead"' "$A/cabinet.env" || fail "prompted roles"
grep -qx 'CABINET_RUNNER="antigravity"' "$A/cabinet.env" && grep -qx 'WHEN="8:30 AM"' "$A/jobs/brief.job" || fail "prompted runner or brief"
grep -q $'^acme-app\t' "$A/repos.tsv" || fail "prompted repo"
grep -q '^- \*\*Writing to the owner:\*\* short\.' "$A/AGENTS.md" || fail "prompted writing"
# With claude (the fake comes first on PATH) setup asks for a budget, and no price: claude reports dollars.
printf '%s\n' "Budgeted" "$T/budgeted" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" 15 "" "" "" "" "" "" y n n > "$T/answers"
CABINET_TTY="$T/answers" "$F" new >/dev/null 2>&1 && grep -qx 'CABINET_BUDGET="15"' "$T/budgeted/cabinet.env" || fail "prompted budget with claude"
grep -qx 'CABINET_BUDGET="5"' "$A/cabinet.env" && grep -qx 'CABINET_PRICE="1 2"' "$A/cabinet.env" || fail "prompted budget and price with antigravity"
grep -qx 'CABINET_PRICE=""' "$T/budgeted/cabinet.env" || fail "a price was set with claude"
printf '%s\n' "Nope" "$T/nope" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" n > "$T/answers"
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
# Every role restates the real problem and names what it needs first; product-manager's spec does too.
grep -qxF 'Before acting on an owner request, say in one line the problem it solves, as you understand it. When a simpler way solves it, or the request would not solve it, say so with your recommendation and let the owner choose before you build either: in a session, ask; otherwise, a sign-off item. Name every tool, access, account or file the work needs before you start, not partway through.' "$W/CABINET.md" \
  && [[ "$(grep -n '^You work for the owner' "$W/CABINET.md" | cut -d: -f1)" == "$(( $(grep -n '^Before acting on an owner request' "$W/CABINET.md" | cut -d: -f1) - 2 ))" ]] || fail "CABINET.md does not restate the real problem right after 'You work for the owner'"
grep -qF 'Start the Problem from the real problem the request solves, not the request as worded; when a simpler option the owner did not ask for would solve it, name it under "Decisions" beside what was asked.' "$W/agents/product-manager.md" \
  || fail "product-manager's spec step 3 does not start from the real problem"
# How to call a role from a session: @agent-<role> in Claude Code, plain words in any other tool; the site says it too.
grep -qF '`@agent-<role>`, for example `@agent-product-manager`' "$KIT/docs/concepts.md" && grep -qF 'As product-manager, read agents/product-manager.md and ...' "$KIT/docs/concepts.md" \
  && grep -qF 'call: "Call a role from a session with `@agent-product-manager`' "$KIT/site/copy.js" && grep -qF '<p class="caption call">${codeInline(TO.team.call)}</p>' "$KIT/site/build.js" || fail "the concepts page or the site does not say how to call a role from a session (@agent-)"
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
# The agent sleeps for a time only this suite uses (its own PID in it), so another suite's sleep, like the
# decoy below, is never taken for one this run left; a decoy plain sleep 323 stands in for one.
SL="323.$$"; echo "CABINET_RUNNER_CMD='sleep $SL; :'" >> "$W/cabinet.env"
left() { pgrep -f "sleep 323\.$$([^0-9]|\$)" >/dev/null; }
sleep 323 & decoy=$!
cp "$W/jobs/brief.job" "$T/brief.bak"; sedi 's/^TIMEOUT=.*/TIMEOUT="2"/' "$W/jobs/brief.job"
s=$SECONDS; st=0; HOME="$H" CABINET_TEST_MINUTE=1 "$W/bin/job.sh" run brief >/dev/null 2>&1 || st=$?
((st == 1 && SECONDS - s < 10)) || fail "a run past its limit was not stopped (exit $st after $((SECONDS - s))s)"
! left || fail "a stopped run left what it started running"
grep -q "stopped after 2 min: the job's time limit" "$H/$LOGS/demo-co/brief.log" || fail "the log does not say why the run stopped"
# Stopping the job (launchd's stop, or Ctrl-C by hand) stops the agent too, though it runs in its own group.
HOME="$H" "$W/bin/job.sh" run brief >/dev/null 2>&1 & p=$!; sleep 1; kill -TERM "$p"; wait "$p" || true
! left || fail "stopping the job left the agent running"
sedi 's/^TIMEOUT=.*/TIMEOUT="08"/' "$W/jobs/brief.job"
st=0; HOME="$H" "$W/bin/job.sh" run brief >/dev/null 2>&1 || st=$?
((st == 2)) && ! left || fail "a TIMEOUT that is not whole minutes was not refused"
kill "$decoy" 2>/dev/null; wait "$decoy" 2>/dev/null || true
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
# A rename commits the titles in HANDOFFS.md, README.md and specs/ROADMAP.md too, rebuilds ORG.md's heading, and leaves nothing behind.
out="$(cd "$MC" && "$F" config --yes --name "Mid Renamed" 2>&1)" && echo "$out" | grep -qF "Committed in the workspace: cabinet config: project name" || fail "config --name did not commit: $out"
grep -qx '# Team: Mid Renamed' "$MC/ORG.md" || fail "a rename did not rebuild ORG.md: $(head -1 "$MC/ORG.md")"
for f in HANDOFFS.md README.md specs/ROADMAP.md ORG.md; do git -C "$MC" show --name-only --format= HEAD | grep -qxF "$f" || fail "a rename did not commit $f"; done
[[ -z "$(git -C "$MC" status --porcelain)" ]] || fail "a rename left changes uncommitted: $(git -C "$MC" status --porcelain)"
# A role note committed without a build: a rename rebuilds agents/ and .claude/agents/ as well, and commits them.
printf 'A note for qa.\n' > "$MC/roles/qa.md"; git -C "$MC" add roles/qa.md && git -C "$MC" commit -qm "a qa note, not built" -- roles/qa.md
out="$(cd "$MC" && "$F" config --yes --name "Mid Noted" 2>&1)" && grep -qx 'A note for qa.' "$MC/agents/qa.md" && [[ -z "$(git -C "$MC" status --porcelain)" ]] || fail "a rename left the rebuilt roles uncommitted: $out $(git -C "$MC" status --porcelain)"
# Only the role files the build changed: a new file another session writes under agents/ during a rename stays theirs.
out="$(cd "$MC" && MID_EDIT="$MC/agents/other.md" PATH="$T/gitmid:$PATH" "$F" config --yes --name "Mid Third" 2>&1)" && git -C "$MC" show --name-only --format= HEAD | grep -qxF ORG.md || fail "a rename did not commit ORG.md: $out"
[[ "$(git -C "$MC" status --porcelain)" == "?? agents/other.md" ]] || fail "a rename committed a role file another session wrote: $(git -C "$MC" show --name-only --format= HEAD)"
rm "$MC/agents/other.md"
# A role turned off: its role files go in as removals, and no other role file, so another session's edit to one stays theirs.
r="$(sed -n 's/^CABINET_ROLES="\(.*\)"$/\1/p' "$MC/cabinet.env")"; mid agents/qa.md --roles "${r/ finance/}"
[[ "$(git -C "$MC" show --name-status --format= HEAD -- agents .claude/agents)" == $'D\t.claude/agents/finance.md\nD\tagents/finance.md' ]] \
  || fail "turning a role off did not commit only its removal: $(git -C "$MC" show --name-status --format= HEAD)"
# A slug change commits only the job files its rewrite changed: brief.job names no slug, so another session's edit to it stays theirs.
os="$(sed -n 's/^CABINET_SLUG="\(.*\)"$/\1/p' "$MC/cabinet.env")"
printf '# Reads Logs/cabinet/%s/ and state/cabinet/%s/.\nCOMMAND="true"\nWHEN=""\n' "$os" "$os" > "$MC/jobs/logs.job"; git -C "$MC" add jobs/logs.job && git -C "$MC" commit -qm "a job that names the slug" -- jobs/logs.job
mid jobs/brief.job --slug "$os-2"
git -C "$MC" show --name-only --format= HEAD | grep -qxF jobs/logs.job && grep -qF "Logs/cabinet/$os-2/" "$MC/jobs/logs.job" || fail "a slug change did not commit the job it rewrote: $(git -C "$MC" show --name-only --format= HEAD)"
# A plain CLAUDE.md is not bootstrap's to commit: another session's edit to it while config runs bootstrap stays theirs.
rm "$MC/CLAUDE.md" && echo "# Plain notes" > "$MC/CLAUDE.md" && git -C "$MC" commit -qm "CLAUDE.md as a plain file" -- CLAUDE.md
mid CLAUDE.md --brief-time "7:30 AM" --apply
# bootstrap links CLAUDE.md again when it is missing, and config commits the link with the rest.
git -C "$MC" rm -q CLAUDE.md && git -C "$MC" commit -qm "CLAUDE.md removed"
out="$(cd "$MC" && "$F" config --yes --brief-time "7:45 AM" --apply 2>&1)" && [[ "$(readlink "$MC/CLAUDE.md")" == AGENTS.md && -z "$(git -C "$MC" status --porcelain)" ]] || fail "config left the CLAUDE.md bootstrap linked uncommitted: $out $(git -C "$MC" status --porcelain)"
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
# Name, slug, owner, email, 6 roles (all yes), 4 optional roles (Enter: off), runner (claude), model (Enter: the tool's), budget, scheduled runner (off), brief, week, writing,
# hard to undo (Enter: not set, no repos), backup, no repos, apply, no bootstrap.
printf '%s\n' "Acme Co" "" "" "" y y y y y y "" "" "" "" "" "" 25 "" off "" short "" "" off "" y n > "$T/answers"
(cd "$C" && HOME="$H" CABINET_TTY="$T/answers" "$F" config >/dev/null 2>&1) || fail "prompted config"
grep -qx 'CABINET_PROJECT="Acme Co"' "$C/cabinet.env" && grep -qx 'WHEN=""' "$C/jobs/brief.job" && grep -q 'design-lead' "$C/cabinet.env" || fail "prompted answers not written"
grep -q '^- \*\*Writing to the owner:\*\* short\.' "$C/AGENTS.md" && grep -qx 'CABINET_BUDGET="25"' "$C/cabinet.env" || fail "prompted writing or budget not written by config"
fake_sched "$LA/ai.cabinet.old-name.brief$SX" "$(cd "$C" && pwd -P)/bin/job.sh"
HOME="$H" "$C/bin/doctor.sh" 2>&1 | grep -q 'ai.cabinet.old-name.brief still runs this workspace under an old name' || fail "doctor missed a leftover schedule"
# Every value config writes back in double quotes is checked first, carried over or not: a single-quoted
# value holding a command, inert as written, would run on every later source once rewritten.
PW="$T/cfgpwned"; "$F" new "$PW" --yes --backup-dir off >/dev/null || fail "new for carried-over values"
cp "$PW/cabinet.env" "$T/pw.env"
for k in CABINET_PROJECT CABINET_SLUG CABINET_ROLES CABINET_RUNNER CABINET_BACKUP_DIR CABINET_BACKUP_TIME CABINET_BUDGET CABINET_PRICE \
  CABINET_PIPELINE CABINET_PIPELINE_LIMIT CABINET_CREDIT_ROLES CABINET_CREDIT_EMAIL; do
  v='$(touch pwned)'; [[ "$k" == CABINET_ROLES ]] && v='chief-of-staff $(touch pwned)'
  { grep -v "^$k=" "$T/pw.env"; printf "%s='%s'\n" "$k" "$v"; } > "$PW/cabinet.env"
  [[ "$k" == CABINET_ROLES ]] && printf -- '---\nname: x\ndescription: x\n---\n' > "$PW/roles/\$(touch pwned).md"
  cp "$PW/cabinet.env" "$T/pw.before"; st=0
  out="$(cd "$PW" && "$F" config --yes --week-start monday 2>&1)" || st=$?
  ((st != 0)) && grep -qF "$k is '" <<<"$out" && grep -qF "$v', which cannot be written back" <<<"$out" || fail "config wrote back $k='$v' (exit $st): $out"
  cmp -s "$PW/cabinet.env" "$T/pw.before" || fail "a refused config changed cabinet.env ($k): $(diff "$T/pw.before" "$PW/cabinet.env")"
  (cd "$PW" && "$F" doctor >/dev/null 2>&1) || true
  [[ -z "$(find "$PW" "$HOME" -name pwned 2>/dev/null)" ]] || fail "a carried-over $k ran: $(find "$PW" "$HOME" -name pwned)"
done
# A roles/ file whose name is not a role name is never a known role: config says so and leaves it out.
cp "$T/pw.env" "$PW/cabinet.env"
out="$(cd "$PW" && "$F" config --yes --roles "qa \$(touch" 2>&1)" && fail "a role named from a roles/ file name was accepted: $out"
out="$(cd "$PW" && "$F" config --yes --week-start monday 2>&1)" && grep -qF 'Note: roles/$(touch pwned).md is not a role' <<<"$out" \
  && ! grep -q touch "$PW/cabinet.env" || fail "a roles/ file with a bad name: $out $(grep ROLES "$PW/cabinet.env")"
rm -f "$PW/roles/\$(touch pwned).md"; [[ -z "$(find "$PW" "$HOME" -name pwned 2>/dev/null)" ]] || fail "a role file name ran"
# A legitimate single-quoted value (the custom runner's command) still carries over.
out="$(cd "$PW" && "$F" config --yes --runner custom --runner-cmd 'my-agent --prompt "$CABINET_PROMPT"' 2>&1)" && out="$(cd "$PW" && "$F" config --yes --week-start sunday 2>&1)" \
  && grep -qxF "CABINET_RUNNER_CMD='my-agent --prompt \"\$CABINET_PROMPT\"'" "$PW/cabinet.env" || fail "the custom runner command no longer carries over: $out"
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
"$I/cabinet/bin/doctor.sh" 2>&1 | grep -q "acme-app uses core.hooksPath .husky, set in .git/config, so the push gate does not run there" || fail "doctor missed the project's own hooks path"
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
# The brass token is approved (owner, 28 Oct 2026), and the guide's doctor sample shows headings as a terminal prints them: bold, no "== ".
j -e '$.color.brass.status == "approved" && $.color["brass-light"].status == "approved"' "$KIT/brand/tokens.json" >/dev/null || fail "brand/tokens.json: brass, on light and on dark, is not approved"
sed -n '/<div class="status-term">/,/<\/pre>/p' "$KIT/brand/index.html" | grep -q '^== ' && fail "the brand guide's doctor sample still shows == headings"
grep -qx '<b>Kit and roles</b>' "$KIT/brand/index.html" || fail "the brand guide's doctor sample has no bold heading"
repo="$(j -r '$.repository.url' "$KIT/package.json" | sed 's/^git+//')"
grep -qF "git clone $repo " "$KIT/README.md" || fail "the README's clone command does not match the repository in package.json"
# The package installs only where the README says the kit runs: macOS and Linux.
j -e '$.publishConfig.access == "public"' "$KIT/package.json" >/dev/null || fail "the scoped package would publish as private"
j -e 'JSON.stringify($.os) == "[\"darwin\",\"linux\"]"' "$KIT/package.json" >/dev/null && grep -q '^- \*\*Platform:\*\* macOS and Linux ' "$KIT/README.md" || fail "package.json os and the README's platform disagree"
for p in .DS_Store node_modules/ '*.tgz'; do grep -qxF "$p" "$KIT/.gitignore" || fail ".gitignore does not ignore $p"; done
# CABINET.md holds what every agent needs on every session; the rest is in core/rules/, each file named
# from it with when to read it, and every reference to one names a file that exists.
# 3460 since 0.2.0: the git actions rule and the amend rule are owner decisions, quoted word for word;
# 3503 since 0.3.0, with the amend guard's sentence.
w="$(wc -w < "$KIT/core/CABINET.md")"; ((w <= 3503)) || fail "CABINET.md has $w words, over its 3503: move what only some roles or tasks need to core/rules/"
for f in "$KIT"/core/rules/*.md; do
  grep -q "^   | \`.cabinet/rules/${f##*/}\` | " "$KIT/core/CABINET.md" || fail "CABINET.md does not say when to read .cabinet/rules/${f##*/}"
done
for r in $(grep -rhoE '\.cabinet/rules/[a-z-]+\.md' "$KIT/core" "$KIT/roles" "$KIT/scripts" "$KIT/bin" "$KIT/templates" "$KIT/docs" | sort -u); do
  [[ -f "$KIT/core/rules/${r##*/}" ]] || fail "$r is named, but the kit has no core/rules/${r##*/}"
done
# Handoff text in double quotes lets the shell run a command substitution first: the docs say to use single quotes.
qs='Text holding `$`, a backtick or a backslash goes in single quotes or a quoted here-document, never double quotes: the shell would run it first.'
grep -qF "$qs" "$KIT/core/CABINET.md" && grep -qF "$qs" "$KIT/docs/commands.md" || fail "CABINET.md or docs/commands.md does not say to put handoff text in single quotes"
sed -n '/^#   bin\/handoff.sh add /,/^#   bin\/handoff.sh attach /p' "$KIT/scripts/handoff.sh" | sed 's/^# *//' | tr '\n' ' ' | grep -qF "$qs" || fail "the usage of handoff add in scripts/handoff.sh does not say to put text in single quotes"
  return 0   # a last "check && fail" line must not end the run
}

section "no project data in the kit" ""
s24() {
# No local paths anywhere (the brand demo's made-up person, /Users/maya, is the one exception); and, when set,
# none of the owner's private words (CABINET_PRIVATE_WORDS="word1 word2", kept out of this file so it names none).
# A git worktree has a .git file, not a folder, naming the main repo by its path: skipped as the folder is.
paths() { grep -rIoh -E '/(Users|home)/[a-z][A-Za-z0-9_-]*' "$1" --exclude-dir=.git --exclude=.git --exclude-dir=node_modules --exclude=smoke.sh | sort -u | grep -vx '/Users/maya' || true; }
mkdir -p "$T/wt/docs" && echo "gitdir: /Users/someone/kit/.git/worktrees/wt" > "$T/wt/.git" && echo "see /home/someone/x" > "$T/wt/docs/a.md"
[[ "$(paths "$T/wt")" == /home/someone ]] || fail "the local path check in a worktree: $(paths "$T/wt")"
p="$(paths "$KIT")"
[[ -z "$p" ]] || fail "a local path in the kit: $p"
for w in ${CABINET_PRIVATE_WORDS:-}; do
  # Whole words, in any case: "nova" is caught in "Nova" and "nova.io", not in "supernova" or "novel".
  ! grep -rIilw -e "$w" "$KIT" --exclude-dir=.git --exclude=.git --exclude-dir=node_modules --exclude=LICENSE --exclude=package.json || fail "a private word in the kit: $w"
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
# An opencode whose rules cannot be read: the note names its version, and reads whole when the version is empty or fails.
mkdir -p "$T/oc"; for v in 'echo "opencode 9.9.9"' 'true' 'echo partial; exit 3'; do
  printf '#!/bin/sh\n[ "$1" = --version ] && { %s; exit 0; }\nexit 1\n' "$v" > "$T/oc/opencode"; chmod +x "$T/oc/opencode"
  m="$(cd "$W" && PATH="$T/oc:$PATH" "$F" doctor --json | j -r '$.results.find((r) => r.id == "guardrails.opencode")?.message')"
  case "$v" in echo\ \"*) w='9.9.9 of opencode cannot be checked from here' ;; *) w='opencode cannot be checked from here' ;; esac
  [[ "$m" == "$w: "* ]] || fail "doctor's opencode note with a version check that runs $v: $m"
done
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
[[ -f "$LA" ]] && ! grep -q '^CABINET_SCHEDULES=' "$P/cabinet/cabinet.local.env" || fail "--schedules"
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
! grep -q '^CABINET_BACKUP_' "$P/cabinet/cabinet.local.env" || { cat "$P/cabinet/cabinet.local.env"; fail "--clear left backup lines"; }
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
[[ "$(LC_ALL=C in_tty "$F" version | tr -d '\r')" == "$(printf '\n      o\n  o       o\n               cabinet %s\no              One person, a whole team.\n               Build anything with AI agents, and stay in charge.\n  o       o\n      o' "$v")" ]] || fail "version in a terminal should print the round mark"
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
# The week starts on the day AGENTS.md names, at midnight, in the last seven days; true at any time of day.
sedi "s/^- \*\*Week starts on:\*\* [A-Za-z]*\./- **Week starts on:** Wednesday./" "$S/AGENTS.md"
ws="$(bash -c 'cd "$1" && source bin/lib.sh && week_start' _ "$S")"; now="$(date +%s)"
(( ws <= now && now - ws < 7 * 86400 + 3600 )) && [[ "$(pf epoch_date "$ws" "+%A %H%M%S")" == "Wednesday 000000" ]] || fail "the week does not start on Wednesday at midnight: $ws"
# A fixed clock for a day the clock changes, in Cairo: the hour repeated just before midnight on 29 Oct
# 2026, and the midnight skipped on 24 Apr 2026, which starts that day at 1 AM.
wk() { TZ=Africa/Cairo node "$KIT/scripts/lib.js" week-start "$@"; }
[[ "$(wk 4 1793309400)" == 1793221200 && "$(wk 0 1793309400)" == 1792875600 && "$(wk 5 1777010400)" == 1776981600 && "$(TZ=UTC node "$KIT/scripts/lib.js" week-start 0 1793309400)" == 1792886400 ]] \
  || fail "week start on a day the clock changes: $(wk 4 1793309400) $(wk 0 1793309400) $(wk 5 1777010400)"
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
printf '%s\n' "$prompt" >> "$FS/prompts"
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
echo "$out" | grep -q "^web: fixes what qa blocked, round 1 (qa's last verdict covers [0-9a-f,]*, commits since: none)$" && [[ "$(echo "$out" | grep -c ': verifies ')" == 6 ]] && echo "$out" | tail -1 | grep -q "^$b is ready to push" || fail "run after a BLOCK: $out"
# Still blocked after the set rounds: it stops and asks.
c="$(work "Add a menu")"; echo 5 > "$FS/block-qa"
rc=0; out="$(run "$c" --retries 1)" || rc=$?
[[ $rc == 1 ]] && echo "$out" | grep -q "^Stopped: qa still block H-.* after 1 fix round(s): the owner decides" || fail "run past its retries: $out"
# The loop breaker: a reviewer's BLOCKs count over every run (blocks, from HANDOFFS.md's history), so a
# new run stops at the third before any fix round, and --dry-run says so.
x="$(work "Add a search")"; echo 9 > "$FS/block-qa"
rc=0; out="$(run "$x")" || rc=$?
[[ $rc == 1 ]] && echo "$out" | grep -q "^Stopped: qa still block H-.* after 2 fix round(s)" || fail "loop breaker setup: $out"
xv="$("$PW/bin/handoff.sh" list --json | j -r --arg i "$x" '$.find((h) => h.depends_on.includes($i)).id')"
"$PW/bin/handoff.sh" list --json | j -e --arg v "$xv" '((h) => h.blocks.qa == 3 && h.verdicts.filter((v) => v.role == "qa").length == 1 && !("security" in h.blocks))($.find((h) => h.id == $v))' >/dev/null \
  || fail "list --json blocks: $("$PW/bin/handoff.sh" list --json | j -c --arg v "$xv" '$.find((h) => h.id == $v)')"
"$PW/bin/handoff.sh" list --json | j -e '$.every((h) => typeof h.blocks == "object")' >/dev/null || fail "an entry without blocks"
# A dry run that stops leaves no stopped mark (a scheduled run would skip the work for it).
rm -f "$HOME/$LOGS/pipe/run-$x.stopped"
h="$(git -C "$PW" rev-parse HEAD)"; out="$(run "$x" --dry-run)" && fail "run --dry-run went on past the loop breaker: $out"
[[ ! -f "$HOME/$LOGS/pipe/run-$x.stopped" ]] || fail "a dry run's stop left the stopped mark"
[[ "$out" == "Stopped: qa has blocked it 3 times on $xv, more than --retries allows (2): the owner decides (fix it another way, change the work, override the BLOCK, or drop it)" && "$(git -C "$PW" rev-parse HEAD)" == "$h" ]] || fail "run --dry-run at the loop breaker: $out"
rc=0; out="$(run "$x")" || rc=$?
[[ $rc == 1 ]] && echo "$out" | grep -qF "Stopped: qa has blocked it 3 times on $xv, more than --retries allows (2)" && ! echo "$out" | grep -q 'fixes\|verifies' || fail "a new run past the loop breaker: $out"
out="$(run "$x" --retries 3)" || true
echo "$out" | grep -q "^web: fixes what qa blocked, round 1 (qa's last verdict covers [0-9a-f,]*, commits since: none)$" && echo "$out" | tail -2 | grep -qF "Stopped: qa has blocked it 4 times on $xv, more than --retries allows (3)" || fail "--retries 3: one more round, then the fourth BLOCK stops it: $out"
rm -f "$FS/block-qa"
# A re-review reads only what changed: a reviewer asked again is told its last verdict's commits and the
# ones since, in its step and its prompt; who runs next, and readiness, are as before.
grep -q "You are asked again: qa's last verdict covers [0-9a-f,]*, commits since: [0-9a-f,]*\. Read as .cabinet/rules/reviews.md says" "$FS/prompts" \
  || fail "a re-reviewer's prompt: $(grep 'asked again' "$FS/prompts")"
p="$(grep '^- \*\*A re-review reads only what changed\.\*\*' "$KIT/core/rules/reviews.md")"
for t in "its own last note, the commits after those its last verdict names" "runs only the test sections those files touch" "The builder still runs the full suite once per review round" "for each one, whether it is fixed" "Any reviewer may read more than the fix, up to the whole change"; do
  [[ "$p" == *"$t"* ]] || fail "reviews.md, a re-review: $t"
done
echo checked > "$PW/specs/rr.md" && git -C "$PW" add specs/rr.md && git -C "$PW" commit -qm note -- specs/rr.md
hs() { (cd "$PW" && bin/handoff.sh "$@"); }
cm() { echo "$1" >> "$PW/app/a.txt"; git -C "$PW/app" commit -qam "$1"; git -C "$PW/app" rev-parse --short HEAD; }
# Each work entry is set rejected at once, so the scheduled run below leaves it alone; run follows its review entry.
rv() { local i r; i="$(work "$1")"; sed -i.bak "/^### $i:/,/^### /s/^- Status: open/- Status: rejected/" "$PW/HANDOFFS.md" && rm "$PW/HANDOFFS.md.bak"; git -C "$PW" commit -qm rej -- HANDOFFS.md; r="$(hs add --from web --to "qa, security" --changed built --needed verify --depends-on "$i" --evidence https://example.com/p "Review $1")"; echo "$i ${r%% *}"; }
rec() { hs record "$1" --role "$2" "$3" --commits "$4" --note specs/rr.md >/dev/null || fail "record $*"; }
others() { hs list --json | j -r --arg v "$1" '$.find((h) => h.id == $v).needs.filter((n) => n != "qa").join(" ")'; }
read -r i v <<<"$(rv "Stale qa")"; A="$(cm s1)"; B="$(cm s2)"
for r in $(others "$v"); do rec "$v" "$r" PASS "$A,$B"; done; rec "$v" qa PASS "$A"
out="$(run "$i" --dry-run)"; [[ "$out" == "qa: verifies $v again (qa's last verdict covers $A, commits since: $B)" ]] || fail "re-review of a stale PASS: $out"
read -r i v <<<"$(rv "Blocked qa")"; A="$(cm b1)"
for r in $(others "$v"); do rec "$v" "$r" PASS "$A"; done; rec "$v" qa BLOCK "$A"; B="$(cm b2)"
out="$(run "$i" --dry-run)"; [[ "$out" == "web: fixes what qa blocked, round 1 (qa's last verdict covers $A, commits since: $B)" ]] || fail "re-review after a BLOCK: $out"
read -r i v <<<"$(rv "Reverted qa")"; A="$(cm r1)"; git -C "$PW/app" revert --no-edit "$A" >/dev/null; B="$(git -C "$PW/app" rev-parse --short HEAD)"
for r in $(others "$v"); do rec "$v" "$r" PASS "$A,$B"; done; rec "$v" qa PASS "$A"
out="$(run "$i" --dry-run)"; [[ "$out" == "qa: verifies $v again (qa's last verdict covers $A, commits since: $B)" ]] || fail "re-review of a revert: $out"
read -r i v <<<"$(rv "Missing qa")"; A="$(cm m1)"; for r in $(others "$v"); do rec "$v" "$r" PASS "$A"; done
out="$(run "$i" --dry-run)"; [[ "$out" == "qa: verifies $v" ]] || fail "a first review is not a re-review: $out"
# Work in two repos of one builder: each repo lists what is new after the commits it holds; a repo the
# verdict never named lists those after its newest commit; when it cannot tell, it never says none.
git init -q "$PW/app2" && echo x > "$PW/app2/a.txt" && git -C "$PW/app2" add -A && git -C "$PW/app2" commit -qm init
printf 'app2\t-\t-\tno\n' >> "$PW/repos.tsv"
L before "$PW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `app2` | The web app, part two | web |'
git -C "$PW" commit -qam "app2, built by web"
cm2() { echo "$1" >> "$PW/app2/a.txt"; git -C "$PW/app2" commit -qam "$1"; git -C "$PW/app2" rev-parse --short HEAD; }
blk() { for r in $(others "$v"); do rec "$v" "$r" PASS "$1"; done; rec "$v" qa BLOCK "$1"; run "$i" --dry-run; }
fx="web: fixes what qa blocked, round 1 (qa's last verdict covers"
read -r i v <<<"$(rv "Two repos")"; A="$(cm t1)"; A2="$(cm2 t2)"; B="$(cm t3)"; B2="$(cm2 t4)"
out="$(blk "$A,$A2")"; [[ "$out" == "$fx $A,$A2, commits since: $B,$B2)" ]] || fail "re-review of work in two repos: $out"
read -r i v <<<"$(rv "Fix in the other repo")"; n=$(($(date +%s) + 100))
A="$(GIT_COMMITTER_DATE="@$n +0000" cm o1)"; B2="$(GIT_COMMITTER_DATE="@$((n + 1)) +0000" cm2 o2)"
out="$(blk "$A")"; [[ "$out" == "$fx $A, commits since: $B2)" ]] || fail "a fix in a repo the verdict did not name: $out"
read -r i v <<<"$(rv "Unknown commit")"; A="$(cm u1)"
out="$(blk "$A,0123456789abc")"; [[ "$out" == "$fx $A,0123456789abc, commits since: unknown, read the whole change)" ]] || fail "a commit in no repo: $out"
read -r i v <<<"$(rv "Off HEAD")"; git -C "$PW/app" checkout -qb side; A="$(cm h1)"; git -C "$PW/app" checkout -q -; git -C "$PW/app" branch -qD side
out="$(blk "$A")"; [[ "$out" == "$fx $A, commits since: unknown, read the whole change)" ]] || fail "a commit not on its repo's HEAD: $out"
# Clock skew (H-20261030-16): a commit dated before the verdict's newest, above the fix in the builder's
# other repo, is listed with it and does not hide it.
read -r i v <<<"$(rv "Clock skew")"; n=$(($(date +%s) + 300))
A="$(GIT_COMMITTER_DATE="@$n +0000" cm k1)"; B2="$(GIT_COMMITTER_DATE="@$((n + 1)) +0000" cm2 k2)"; C2="$(GIT_COMMITTER_DATE="@$((n - 1000)) +0000" cm2 k3)"
out="$(blk "$A")"; [[ "$out" == "$fx $A, commits since: $B2,$C2)" ]] || fail "a commit dated earlier above the fix hid it: $out"
# qa N7: a fix in a product repo neither the builder's nor named in a verdict cannot be told: unknown.
git init -q "$PW/app3" && echo x > "$PW/app3/a.txt" && git -C "$PW/app3" add -A && git -C "$PW/app3" commit -qm init
printf 'app3\t-\t-\tno\n' >> "$PW/repos.tsv"
L before "$PW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `app3` | Another app | backend |'
git -C "$PW" commit -qam "app3, built by backend"
read -r i v <<<"$(rv "Fix in another builder's repo")"; n=$((n + 300))
A="$(GIT_COMMITTER_DATE="@$n +0000" cm n1)"; echo n2 >> "$PW/app3/a.txt"; GIT_COMMITTER_DATE="@$((n + 1)) +0000" git -C "$PW/app3" commit -qam n2
out="$(blk "$A")"; [[ "$out" == "$fx $A, commits since: unknown, read the whole change)" ]] || fail "a fix in a repo no verdict names, not the builder's: $out"
grep -v '^app3	' "$PW/repos.tsv" > "$T/rr-repos" && cp "$T/rr-repos" "$PW/repos.tsv"; git -C "$PW" commit -qm "app3 out" -- repos.tsv
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
y="$(work "Add a filter")"; echo 9 > "$FS/block-qa"; run "$y" >/dev/null || true; rm -f "$FS/block-qa" "$PL/run-$y.stopped"
sched || fail "the pipeline job: $(tail -5 "$PL/pipeline.log")"
grep -qF -- "- $y: Stopped: qa has blocked it 3 times on" "$PW/PIPELINE.md" || fail "a scheduled run past the loop breaker: $(cat "$PW/PIPELINE.md")"
grep -q "^- $k: $k is ready to push" "$PW/PIPELINE.md" && grep -q "^- $m: skipped, stopped on $(date +%F) for you: qa still blocks it. Once settled, run it by hand: cabinet handoff run $m" "$PW/PIPELINE.md" \
  && grep -q '^Spent \$0.04 of the \$1 limit for one run.$' "$PW/PIPELINE.md" || fail "PIPELINE.md: $(cat "$PW/PIPELINE.md")"
! git -C "$PW" status --porcelain | grep -q PIPELINE.md || fail "PIPELINE.md is tracked"
# The cost limit pauses a run before the next agent; the next run goes on from there.
rm -f "$PL/run-$m.stopped"; "$PW/bin/handoff.sh" run "$m" --dry-run >/dev/null
cfgp --pipeline-limit 0.02 >/dev/null; sched
grep -q "^- $m: Paused: this run's cost limit (\$0.02) is reached" "$PW/PIPELINE.md" && [[ ! -f "$PL/run-$m.stopped" ]] || fail "the cost limit: $(cat "$PW/PIPELINE.md")"
cfgp --pipeline all --pipeline-limit 1 >/dev/null; sched
grep -q "^- $m: $m is ready to push" "$PW/PIPELINE.md" && grep -q '^- specs/login.md: specs/login.md is ready to push' "$PW/PIPELINE.md" || fail "the next run, with specs: $(cat "$PW/PIPELINE.md")"
grep -qF -- "- $y: skipped, stopped on $(date +%F) for you: qa has blocked it 3 times on" "$PW/PIPELINE.md" || fail "a scheduled run did not skip work past the loop breaker: $(cat "$PW/PIPELINE.md")"
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
[[ -z "$(unpinned "$T/wf/none" 2>&1)" ]] || fail "the pin check found something, or failed, in a folder with no workflows: $(unpinned "$T/wf/none" 2>&1)"
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

section "website: built from the repo, served under /cabinet/, never shipped" ""
s60() {
# The site (site/build.js) is built from the repo's own docs, changelog, roles, captures and brand, into a folder
# it is given; test/site-check.js checks the result (links under /cabinet/, colors from tokens, no outside
# request, escaped Markdown, the search and lookup data, fonts with their licenses, the 404 page).
O="$T/web/cabinet"
node "$KIT/site/build.js" "$O" --ref v9.9.9 >/dev/null || fail "the site does not build (node site/build.js <folder>)"
node "$KIT/test/site-check.js" "$KIT" "$O" v9.9.9 || fail "the built site (see above)"
grep -qF 'node site/build.js' "$KIT/README.md" && grep -q '^| `site/` |' "$KIT/AGENTS.md" || fail "the README does not say how to build the site, or AGENTS.md does not list site/"
# Plain tools: the site's JavaScript loads only Node's own modules or files under site/; no dependencies.
for f in "$KIT"/site/*.js; do
  ! grep -oE 'require\([^)]*\)|import[^;]* from ' "$f" | grep -vE '^require\("(node:[a-z_/]+|\./[a-z.-]+)"\)$' || fail "${f#$KIT/} loads something other than node: modules or site/ files"
done
j -e '!$.dependencies && !$.devDependencies' "$KIT/package.json" >/dev/null || fail "package.json has dependencies"
# Never shipped: npm pack lists nothing under site/, and files (an allowlist) has no site/.
p="$(cd "$KIT" && npm pack --dry-run --json 2>/dev/null | j -r --each 'Object.values($)[0].files.map((f) => f.path)')"
[[ -n "$p" ]] && ! grep -qE '^(site/|_site/|\.github/)' <<<"$p" && j -e '!$.files.some((f) => /site/.test(f))' "$KIT/package.json" >/dev/null || fail "the package would ship the site or its source"
# Text written for the site holds no handoff ID and none of the owner's private words (CABINET_PRIVATE_WORDS, as
# "no project data in the kit" does, so this file names none); the check catches either placed there.
leaks() {
  local w
  grep -rIlE 'H-[0-9]{8}-[0-9]{2}' "$1/site" || true
  for w in ${CABINET_PRIVATE_WORDS:-}; do grep -rIilw -e "$w" "$1/site" || true; done
}
[[ -z "$(leaks "$KIT")" ]] || fail "site/ holds a handoff ID or a private word: $(leaks "$KIT")"
# The Pages workflow: a published release or a manual run only, deploying in the github-pages environment
# (the owner approves each run there), with no permission beyond these three. Its actions are pinned like
# every workflow's (the release workflow section checks the pins).
w="$KIT/.github/workflows/pages.yml"
[[ "$(sed -n '/^on:/,/^[a-z]/p' "$w" | grep -E '^  [a-z_]+:' | tr -d ' \n')" == "release:workflow_dispatch:" ]] && grep -qx '    types: \[published\]' "$w" || fail "the Pages workflow starts on something other than a published release and a manual run"
grep -A1 '^    environment:' "$w" | grep -qx '      name: github-pages' || fail "the Pages workflow does not deploy in the github-pages environment"
perms="$(grep -E '^ +(actions|attestations|checks|contents|deployments|discussions|id-token|issues|models|packages|pages|pull-requests|repository-projects|security-events|statuses): ' "$w" | sed 's/ *#.*//; s/^ *//' | sort -u | tr '\n' ';')"
[[ "$perms" == "contents: read;id-token: write;pages: write;" ]] && ! grep -qE 'permissions: *(write-all|read-all)' "$w" || fail "the Pages workflow asks for other permissions: $perms"
grep -q '^          persist-credentials: false' "$w" && ! grep -qE 'run:.*\$\{\{' "$w" || fail "the Pages workflow leaves its token on disk, or puts \${{ }} inside a script"

# In a copy of the kit: what changes in the repo changes on the rebuilt site.
C="$T/web-kit"; mkdir -p "$C"; (cd "$KIT" && tar cf - --exclude=./.git --exclude=./node_modules .) | (cd "$C" && tar xf -)
b() { node "$C/site/build.js" "$T/web2/cabinet" --ref v9.9.9 >/dev/null 2>"$T/web2.err"; }
sedi 's/^Each version says what changed/Each version says what drifted/' "$C/CHANGELOG.md"
sedi 's/^description: Quality lead\./description: Quality lead, drifted./' "$C/roles/qa.md"
sedi 's/^| Grok | yes, in folders you trust |/| Grokdrift | yes, in folders you trust |/' "$C/docs/guardrails.md"
sedi "s/^| Slug | The workspace's short name/| Slug | A drifted short name/" "$C/README.md"
sedi 's/^- macOS: `brew install node`/- macOS: `brew install node-drift`/; s/^- \*\*A secrets check\*\* before each commit/- **A secrets check** before each drifted commit/' "$C/README.md"
sedi 's/^- \*\*Gemini:\*\* delete/- **Gemini:** drift-delete/' "$C/docs/guardrails.md"
sedi 's/"Created acme-app at/"Created drift-app at/' "$C/brand/demo/captured.js"
printf '\n| Option | Values |\n|---|---|\n| `--x` | `a\\|b` |\n' >> "$C/docs/commands.md"
printf '\nA drifted doc line.\n\n<script>alert(1)</script>\n\nRun `cabinet role add` <role> here.\n\n| Name | What |\n|---|---|\n| <role> cell | y |\n\n## Twice\n\nOne.\n\n## Twice\n\nTwo: [first](#twice), [second](#twice-1).\n' >> "$C/docs/backups.md"
b || { cat "$T/web2.err"; fail "the copy of the kit does not build"; }
W2="$T/web2/cabinet"
node "$KIT/test/site-check.js" "$C" "$W2" v9.9.9 || fail "the site built from a changed kit (see above)"
grep -q 'A drifted doc line' "$W2/docs/backups/index.html" && grep -q 'what drifted' "$W2/changelog/index.html" || fail "a changed doc or changelog line is not on the rebuilt site"
grep -q 'Quality lead, drifted' "$W2/index.html" && grep -q 'Grokdrift' "$W2/faq/index.html" || fail "a changed role description or agent tool is not on the rebuilt site"
grep -q 'A drifted short name' "$W2/docs/commands/index.html" && grep -q 'drift-app at' "$W2/index.html" || fail "a changed glossary meaning or captured line is not on the rebuilt site"
grep -q 'brew install node-drift' "$W2/index.html" && grep -q 'before each drifted commit' "$W2/index.html" && grep -q 'drift-delete' "$W2/index.html" || fail "a changed install or setup line is not in the rebuilt install block"
grep -qF '&lt;script&gt;alert(1)&lt;/script&gt;' "$W2/docs/backups/index.html" && grep -qF '&lt;script&gt;alert(1)' "$W2/search.json" || fail "a script tag in a doc is not shown as text"
grep -qF '&lt;role&gt; here' "$W2/docs/backups/index.html" && grep -qF '<td>&lt;role&gt; cell</td>' "$W2/docs/backups/index.html" || fail "<role> in running text or a table cell is not shown as text"
grep -qF '<code><span class="nw">a|b</span></code>' "$W2/docs/commands/index.html" && ! grep -qF 'a\|b' "$W2/docs/commands/index.html" || fail "an escaped pipe in a table cell's code does not show as |"
grep -q 'id="twice"' "$W2/docs/backups/index.html" && grep -q 'id="twice-1"' "$W2/docs/backups/index.html" || fail "a repeated heading does not get GitHub's -1 anchor"
# A doc with no place in the sidebar, or a changelog with no released version, stops the build with a message.
echo '# New' > "$C/docs/new.md"; b && fail "a doc with no page built"; grep -q 'docs/new.md has no place' "$T/web2.err" || fail "no message for a doc with no page"
rm "$C/docs/new.md"
awk '/^## [0-9.]+ - Unreleased/{skip=1; next} /^## /{skip=0} !skip' "$KIT/CHANGELOG.md" > "$C/CHANGELOG.md"
b && node "$KIT/test/site-check.js" "$C" "$W2" v9.9.9 >/dev/null || fail "a changelog with no Unreleased section does not build or check"
awk '/^## /{exit} {print}' "$KIT/CHANGELOG.md" > "$C/CHANGELOG.md"; printf '## 0.9.0 - Unreleased\n\n- Next.\n' >> "$C/CHANGELOG.md"
b && fail "a changelog with no released version built"; grep -q 'no released version' "$T/web2.err" || fail "no message for a changelog with no released version"
# Never written into a path the package ships, and never over a folder of someone else's files.
node "$C/site/build.js" "$C/docs/web" >/dev/null 2>&1 && fail "the site was built into docs/, which the package ships"
[[ ! -e "$C/docs/web" ]] || fail "a refused build left files in docs/"
mkdir -p "$T/mine"; echo keep > "$T/mine/note.txt"
node "$C/site/build.js" "$T/mine" >/dev/null 2>&1 && fail "the site was built over a folder of other files"
[[ "$(cat "$T/mine/note.txt")" == keep ]] || fail "a refused build changed a folder of other files"
# GitHub's mark: the reference file comes with its source, and #000000 anywhere but on the mark fails the check.
[[ -s "$KIT/site/github-mark/GitHub_Invertocat_Black.svg" ]] && grep -q 'https://brand.github.com/GitHub_Logos.zip' "$KIT/site/github-mark/SOURCE.txt" || fail "site/github-mark/ lacks GitHub's mark or the note of where it came from"
cp "$KIT/CHANGELOG.md" "$C/CHANGELOG.md"; cp "$C/site/site.css" "$T/site.css"; printf '.x { color: #000000; }\n' >> "$C/site/site.css"
b && ! node "$KIT/test/site-check.js" "$C" "$W2" v9.9.9 >/dev/null || fail "#000000 outside GitHub's mark passed the color check"
cp "$T/site.css" "$C/site/site.css"; sedi 's/aria-label="\${NAV.github}"/aria-label="Git"/' "$C/site/build.js"
b && ! node "$KIT/test/site-check.js" "$C" "$W2" v9.9.9 >/dev/null || fail "a GitHub mark without the name GitHub passed the check"
cp "$KIT/site/build.js" "$C/site/build.js"
# The team picture is centred in the one-column layout (701 to 1099 px): without the rule the check fails.
sedi "/^  \\.chairs-ring { margin-inline: auto; }\$/d" "$C/site/site.css"
b && ! node "$KIT/test/site-check.js" "$C" "$W2" v9.9.9 >"$T/sc.out" && grep -q "not centred in the one-column layout" "$T/sc.out" || fail "a team picture left of the one-column layout passed the check"
cp "$T/site.css" "$C/site/site.css"
# A link with any scheme but https:, http: or mailto: stops the build, and so does an llms.txt link outside the kit.
cp "$KIT/CHANGELOG.md" "$C/CHANGELOG.md"; cp "$C/docs/backups.md" "$T/backups.md"
printf '\n[x](javascript:alert(1))\n' >> "$C/docs/backups.md"; b && fail "a javascript: link in a doc built"; grep -q 'only https:, http:, mailto: and # links' "$T/web2.err" || fail "no message for a javascript: link"
cp "$T/backups.md" "$C/docs/backups.md"; printf '\n[x](DATA:text/html,x)\n' >> "$C/docs/backups.md"; b && fail "a data: link in a doc built"
cp "$T/backups.md" "$C/docs/backups.md"; cp "$C/llms.txt" "$T/llms.txt"
printf -- '- [Out](../outside.md): no\n' >> "$C/llms.txt"; b && fail "an llms.txt link outside the kit built"; grep -q 'outside the kit' "$T/web2.err" || fail "no message for an llms.txt link outside the kit"
cp "$T/llms.txt" "$C/llms.txt"; b || fail "the copy does not build again once the bad links are gone"
# The leak check catches a handoff ID, or a private word, placed in the site's own text.
printf '// H-20261025-99\n' >> "$C/site/copy.js"; [[ -n "$(leaks "$C")" ]] || fail "the check misses a handoff ID in site/"
sedi '$d' "$C/site/copy.js"; [[ -z "$(leaks "$C")" ]] || fail "the leak check finds something in an unchanged site/"
printf '// Zyxwordq\n' >> "$C/site/copy.js"; [[ -n "$(CABINET_PRIVATE_WORDS="zyxwordq" leaks "$C")" ]] || fail "the check misses a private word in site/"
# The site's own words name only commands and options the docs have: an unknown one in copy.js, or a
# command whose section is gone from docs/commands.md, fails the check, naming it.
cp "$KIT/site/copy.js" "$C/site/copy.js"; b || fail "the copy does not build with the kit's copy.js"
sedi 's/run `cabinet bootstrap`, which/run `cabinet nosuchcommand`, which/' "$C/site/copy.js"
! node "$KIT/test/site-check.js" "$C" "$W2" v9.9.9 >"$T/sc.out" && grep -q 'cabinet nosuchcommand' "$T/sc.out" || fail "a command the docs lack in copy.js passed the check"
cp "$KIT/site/copy.js" "$C/site/copy.js"; sedi 's/run `cabinet bootstrap`, which/run `cabinet bootstrap --no-such-option`, which/' "$C/site/copy.js"
! node "$KIT/test/site-check.js" "$C" "$W2" v9.9.9 >"$T/sc.out" && grep -q -e '--no-such-option' "$T/sc.out" || fail "an option the docs lack in copy.js passed the check"
cp "$KIT/site/copy.js" "$C/site/copy.js"; awk '/^## cabinet bootstrap$/{skip=1; next} /^## /{skip=0} !skip' "$KIT/docs/commands.md" > "$C/docs/commands.md"
! node "$KIT/test/site-check.js" "$C" "$W2" v9.9.9 >"$T/sc.out" && grep -q 'cabinet bootstrap' "$T/sc.out" || fail "copy.js naming a command with no section in docs/commands.md passed the check"
rm -rf "$C" "$T/web" "$T/web2" "$T/mine" "$T/backups.md" "$T/llms.txt" "$T/site.css" "$T/sc.out"
  return 0   # a last "check && fail" line must not end the run
}

section "credit roles: a commit made in a Cabinet run credits its role" ""
s61() {
# Its own HOME and global git config, so the global hooks path, and the credit hook in it, are this
# section's only. Restored at the end.
local oh="$HOME" og="$GIT_CONFIG_GLOBAL"
CH="$T/credit-home"; mkdir -p "$CH"
export HOME="$CH" GIT_CONFIG_GLOBAL="$CH/.gitconfig"
printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$GIT_CONFIG_GLOBAL"
KM='347351783+cabinet-team[bot]@users.noreply.github.com' PM='123+my-app[bot]@users.noreply.github.com'
KH="$KIT/guardrails/prepare-commit-msg" HK="$CH/.config/git/hooks"
# A fake for each runner: in the scratch repo $CR_REPO it runs $CR_DO, a commit with git commit -m by default.
mkdir -p "$T/credit-shim"
for t in claude codex agy qwen grok opencode cursor-agent; do
  printf '#!/bin/sh\ncd "$CR_REPO" || exit 1\neval "${CR_DO:-echo x >> f && git add f && git commit -q -m work}"\n' > "$T/credit-shim/$t"; chmod +x "$T/credit-shim/$t"
done
CR="$T/credit-repo"; git init -q -b main "$CR"; echo a > "$CR/f"; git -C "$CR" add f; git -C "$CR" commit -qm "the owner's first"
# crun <workspace> <runner> <role> [prompt]: one run through run_agent, as a job or handoff run starts it.
crun() {
  (cd "$1" && PATH="$T/credit-shim:$PATH" CR_REPO="$CR" bash -c 'source bin/lib.sh
    CABINET_RUNNER="$1"; [[ "$1" == custom ]] && CABINET_RUNNER_CMD="$2/credit-shim/codex"
    AGENT="$3" PROMPT="${4:-work}" run_agent' _ "$2" "$T" "$3" "${4:-}") >/dev/null 2>&1 || true
}
msg() { git -C "$CR" log -1 --format=%B "${1:-HEAD}"; }
cab() { msg "${1:-HEAD}" | grep -c '^Co-authored-by: Cabinet ' || true; }
anyco() { msg "${1:-HEAD}" | grep -ci 'co-authored-by' || true; }
lastline() { msg "${1:-HEAD}" | sed '/^$/d' | tail -1; }

# Settings and setup (criteria 1 to 5).
CW="$T/credit-ws"; "$F" new "$CW" --yes >/dev/null || fail "new"
grep -qx 'CABINET_CREDIT_ROLES="on"' "$CW/cabinet.env" || fail "new does not write credit roles on by default"
mkdir -p "$T/credit-init"; "$F" init "$T/credit-init" --yes >/dev/null || fail "init"
grep -qx 'CABINET_CREDIT_ROLES="on"' "$T/credit-init/cabinet.env" || fail "init does not write credit roles on by default"
# Prompted: new with Enter keeps on; new answering off; init answering off; config with Enter keeps the value.
printf '%s\n' "Cr One" "$T/credit-p1" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" y n n > "$T/credit-answers"
CABINET_TTY="$T/credit-answers" "$F" new >/dev/null 2>&1 && grep -qx 'CABINET_CREDIT_ROLES="on"' "$T/credit-p1/cabinet.env" || fail "prompted new: Enter does not keep on"
printf '%s\n' "Cr Two" "$T/credit-p2" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" off "" "" y n n > "$T/credit-answers"
CABINET_TTY="$T/credit-answers" "$F" new >/dev/null 2>&1 && grep -qx 'CABINET_CREDIT_ROLES="off"' "$T/credit-p2/cabinet.env" || fail "prompted new: off not written"
mkdir -p "$T/credit-p3"
printf '%s\n' "Cr Three" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" off "" "" y n n > "$T/credit-answers"
CABINET_TTY="$T/credit-answers" "$F" init "$T/credit-p3" >/dev/null 2>&1 && grep -qx 'CABINET_CREDIT_ROLES="off"' "$T/credit-p3/cabinet.env" || fail "prompted init: off not written"
printf '\n%.0s' $(seq 40) > "$T/credit-answers"
(cd "$T/credit-p2" && CABINET_TTY="$T/credit-answers" "$F" config >/dev/null 2>&1); grep -qx 'CABINET_CREDIT_ROLES="off"' "$T/credit-p2/cabinet.env" || fail "prompted config: Enter did not keep off"
(cd "$T/credit-p1" && CABINET_TTY="$T/credit-answers" "$F" config >/dev/null 2>&1); grep -qx 'CABINET_CREDIT_ROLES="on"' "$T/credit-p1/cabinet.env" || fail "prompted config: Enter did not keep on"
cfg() { (cd "$CW" && "$F" config --yes "$@" 2>&1); }
cfg --credit-roles off >/dev/null && grep -qx 'CABINET_CREDIT_ROLES="off"' "$CW/cabinet.env" || fail "--credit-roles off"
cfg --credit-roles on >/dev/null && grep -qx 'CABINET_CREDIT_ROLES="on"' "$CW/cabinet.env" || fail "--credit-roles on"
cp "$CW/cabinet.env" "$T/credit-env"
refused() { local rc=0; cfg "$@" >/dev/null || rc=$?; ((rc)) && cmp -s "$T/credit-env" "$CW/cabinet.env" || fail "config $* was not refused, or changed cabinet.env"; }
for v in name app APP ON ""; do refused --credit-roles "$v"; done
cfg --credit-roles on --credit-email "$PM" >/dev/null && grep -qxF "CABINET_CREDIT_EMAIL=\"$PM\"" "$CW/cabinet.env" || fail "--credit-email not written"
cp "$CW/cabinet.env" "$T/credit-env"
for v in '123+my-app@users.noreply.github.com' 'abc+my-app[bot]@users.noreply.github.com' '123+my-app[bot]@example.com' \
  '123+My-App[bot]@users.noreply.github.com' '123+-app[bot]@users.noreply.github.com' '123+my-app[bot]@users.noreply. github.com' \
  "$PM"$'\nCo-authored-by: x <x@x.com>' "${PM}x" ""; do
  refused --credit-roles on --credit-email "$v"
done
refused --credit-roles off --credit-email "$PM"
cfg --credit-roles off >/dev/null; cp "$CW/cabinet.env" "$T/credit-env"
grep -qx 'CABINET_CREDIT_EMAIL=""' "$CW/cabinet.env" || fail "credit off kept an email it does not use"
refused --credit-email "$PM"
sedi '/^CABINET_CREDIT_ROLES=/d' "$CW/cabinet.env"; cp "$CW/cabinet.env" "$T/credit-env"
refused --credit-email "$PM"
cfg --credit-roles on --credit-email "$PM" >/dev/null || fail "on with an email"

# Credit on commits (criteria 6 to 15).
HOME="$CH" "$CW/bin/bootstrap.sh" >/dev/null 2>&1 || true
cmp -s "$KH" "$HK/prepare-commit-msg" || fail "bootstrap did not place the credit hook where none was"
for r in claude codex antigravity qwen grok opencode cursor custom; do
  h="$(git -C "$CR" rev-parse HEAD)"; crun "$CW" "$r" backend
  [[ "$(git -C "$CR" rev-parse HEAD)" != "$h" ]] || fail "the $r run made no commit"
  [[ "$(lastline)" == "Co-authored-by: Cabinet backend <$PM>" && "$(cab)" == 1 ]] || fail "$r: the commit does not end with one credit line for its own app: $(msg)"
done
cfg --credit-email off >/dev/null; grep -qx 'CABINET_CREDIT_EMAIL=""' "$CW/cabinet.env" || fail "--credit-email off did not remove it"
for r in claude codex antigravity qwen grok opencode cursor custom; do
  crun "$CW" "$r" backend
  [[ "$(lastline)" == "Co-authored-by: Cabinet backend <$KM>" && "$(cab)" == 1 ]] || fail "$r: the commit does not end with one credit line: $(msg)"
done
# The line that shows the Cabinet Team avatar, written out here byte for byte, as the commit object ends.
git -C "$CR" cat-file commit HEAD | tail -n 1 | cmp -s - <(printf '%s\n' 'Co-authored-by: Cabinet backend <347351783+cabinet-team[bot]@users.noreply.github.com>') \
  || fail "the default credit line is not exactly the Cabinet Team's: $(git -C "$CR" cat-file commit HEAD | tail -n 1 | od -c | head -5)"
on_ident="$(git -C "$CR" log -1 --format='%an %ae %cn %ce')"
cfg --credit-roles off >/dev/null; crun "$CW" codex backend
[[ "$(anyco)" == 0 ]] || fail "credit off still credited: $(msg)"
[[ "$(git -C "$CR" log -1 --format='%an %ae %cn %ce')" == "$on_ident" ]] || fail "credit changed the author or committer"
cfg --credit-roles on >/dev/null
CR_DO='echo x >> f && git add f && git commit -q --no-verify -m work' crun "$CW" codex backend
[[ "$(cab)" == 1 ]] || fail "--no-verify skipped the credit"
crun "$CW" codex backend "Build H-20261024-01 from specs/x.md for qa, security and product-manager"
[[ "$(cab)" == 1 && "$(lastline)" == "Co-authored-by: Cabinet backend <$KM>" ]] || fail "a run credited another role than its own"
CR_DO="echo x >> f && git add f && git commit -q -m 'work

Co-authored-by: Cabinet backend <$KM>'" crun "$CW" codex backend
[[ "$(cab)" == 1 ]] || fail "a credit line already there was added twice"
CR_DO="echo x >> f && git add f && git commit -q -m 'work

Co-authored-by: Tool <tool@example.com>'" crun "$CW" codex backend
msg | grep -qx 'Co-authored-by: Tool <tool@example.com>' && [[ "$(cab)" == 1 ]] || fail "another trailer was not kept, or the credit line not added once"
CR_DO='git checkout -q -b side && echo y >> f && git add f && git commit -q -m side && git checkout -q main && git merge -q --no-ff side -m merged && git branch -q -D side' crun "$CW" codex backend
[[ "$(msg)" == merged && "$(cab)" == 0 ]] || fail "a merge commit was credited: $(msg)"
h="$(git -C "$CR" rev-parse HEAD)"
CR_DO='echo x >> f && git add f && git commit -q -m ""' crun "$CW" codex backend
[[ "$(git -C "$CR" rev-parse HEAD)" == "$h" ]] || fail "an empty message made a commit"
git -C "$CR" checkout -q HEAD -- f

# The owner's own commits (criteria 16 to 19).
echo z >> "$CR/f"; git -C "$CR" commit -qam "the owner's"
[[ "$(anyco)" == 0 ]] || fail "a commit made outside a run was credited (on)"
cfg --credit-roles off >/dev/null; echo z >> "$CR/f"; git -C "$CR" commit -qam "the owner's, off"; [[ "$(anyco)" == 0 ]] || fail "a commit made outside a run was credited (off)"
cfg --credit-roles on >/dev/null
"$F" new "$T/credit-own" --yes >/dev/null; (cd "$T/credit-own" && "$F" config --yes --writing short >/dev/null)
"$T/credit-own/bin/handoff.sh" add --from qa --to owner --changed x --needed y "credit check" >/dev/null
[[ "$(git -C "$T/credit-own" log --format=%B | grep -ci co-authored-by)" == 0 && "$(git -C "$CW" log --format=%B | grep -ci co-authored-by)" == 0 ]] \
  || fail "a commit cabinet made outside a run was credited"
before="$(msg)"; CR_DO='git commit -q --amend --no-edit' crun "$CW" codex backend
[[ "$(msg)" == "$before" ]] || fail "an amend in a run credited the owner's commit"
# An amend that writes a new message (git gives it source "message", as a new commit) is refused in a run too.
CR_DO='git commit -q --amend -m amended' crun "$CW" codex backend
[[ "$(msg)" == "$before" ]] || fail "an amend with a new message in a run was not refused: $(msg)"
# A commit from a template (git gives it source "template") is credited once.
printf 'from a template\n' > "$T/credit-template"
CR_DO="echo x >> f && git add f && GIT_EDITOR='sed -i.bak 1s/^/edited\ /' git commit -q -t '$T/credit-template'" crun "$CW" codex backend
[[ "$(msg | head -1)" == "edited from a template" && "$(lastline)" == "Co-authored-by: Cabinet backend <$KM>" && "$(cab)" == 1 ]] || fail "a commit from a template in a run was not credited once: $(msg)"
CR_DO='git revert --no-edit HEAD >/dev/null' crun "$CW" codex backend
[[ "$(msg | head -1)" == 'Revert "edited from a template"' && "$(lastline)" == "Co-authored-by: Cabinet backend <$KM>" && "$(cab)" == 1 ]] || fail "a revert in a run was not credited: $(msg)"
git -C "$CR" checkout -q -b own; for i in 1 2; do echo "o$i" >> "$CR/o$i"; git -C "$CR" add "o$i"; git -C "$CR" commit -qm "owner $i"; done; git -C "$CR" checkout -q main
echo m >> "$CR/f"; git -C "$CR" commit -qam "main moves"
# A rebase in a run is refused (pre-rebase), so the owner's commits stay as they were, uncredited.
CR_DO='git checkout -q own && git rebase -q main; git checkout -q main' crun "$CW" codex backend
[[ "$(git -C "$CR" log --format=%B main..own | grep -c 'Co-authored-by')" == 0 && "$(git -C "$CR" rev-list --count main..own)" == 2 ]] || fail "a rebase in a run credited the owner's commits"
CR_DO='git cherry-pick own >/dev/null' crun "$CW" codex backend
[[ "$(msg)" == "owner 2" ]] || fail "a cherry-pick in a run credited the owner's commit: $(msg)"

# Untrusted values (criteria 20 to 22).
for a in 'back end' $'backend\nCo-authored-by: x <x@x.com>' '$(touch pwned)'; do
  crun "$CW" codex "$a"
  [[ "$(msg)" == work ]] || fail "an agent name that is not a role name added a line: $(msg)"
done
[[ ! -e "$CR/pwned" && ! -e "$CW/pwned" && ! -e pwned ]] || fail "an agent name ran"
for v in 'on; touch pwned' name ON app; do
  sedi "s/^CABINET_CREDIT_ROLES=.*/CABINET_CREDIT_ROLES=\"$v\"/" "$CW/cabinet.env"
  crun "$CW" codex backend; [[ "$(msg)" == work ]] || fail "CABINET_CREDIT_ROLES=$v credited a commit"
  (cd "$CW" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "credit.setting" && r.level == "fix" && r.message.includes("CABINET_CREDIT_ROLES"))' >/dev/null || fail "the doctor did not report CABINET_CREDIT_ROLES=$v"
  cfg | grep -qF "\"$v\"" || fail "config did not show the value it found: $v"
done
[[ ! -e "$CR/pwned" && ! -e "$CW/pwned" && ! -e pwned ]] || fail "a credit setting ran"
sedi 's/^CABINET_CREDIT_ROLES=.*/CABINET_CREDIT_ROLES="on"/' "$CW/cabinet.env"
for v in 'x@example.com' "$PM"$'\nCo-authored-by: x <x@x.com>'; do
  grep -v '^CABINET_CREDIT_EMAIL=' "$CW/cabinet.env" > "$T/credit-env"; printf 'CABINET_CREDIT_EMAIL="%s"\n' "$v" >> "$T/credit-env"; cp "$T/credit-env" "$CW/cabinet.env"
  crun "$CW" codex backend; [[ "$(cab)" == 0 ]] || fail "a bad CABINET_CREDIT_EMAIL credited a commit: $(msg)"
  (cd "$CW" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "credit.email" && r.level == "fix" && r.message.includes("CABINET_CREDIT_EMAIL"))' >/dev/null || fail "the doctor did not report a bad CABINET_CREDIT_EMAIL"
done
grep -v '^CABINET_CREDIT_EMAIL=\|^Co-authored-by' "$CW/cabinet.env" > "$T/credit-env"; echo 'CABINET_CREDIT_EMAIL=""' >> "$T/credit-env"; cp "$T/credit-env" "$CW/cabinet.env"
# Every Cabinet line any of these runs wrote carries the kit's email or the project's (criterion 8).
[[ -z "$(git -C "$CR" log --all --format=%B | grep '^Co-authored-by: Cabinet ' | grep -vF -e "<$KM>" -e "<$PM>")" ]] || fail "a credit line carries another email"

# The hook on the machine (criteria 23 to 26).
boot() { HOME="$CH" "$CW/bin/bootstrap.sh" >/dev/null 2>&1 || true; }
cp "$KIT/guardrails/hook-passthrough" "$HK/prepare-commit-msg"; boot
cmp -s "$KH" "$HK/prepare-commit-msg" || fail "bootstrap did not replace the pass-through stub with the credit hook"
touch -t 202001010000 "$HK/prepare-commit-msg"; boot
cmp -s "$KH" "$HK/prepare-commit-msg" && [[ "$(find "$HK/prepare-commit-msg" -newer "$CW/cabinet.env")" == "" ]] || fail "bootstrap rewrote the current credit hook"
(cd "$CW" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "credit.hook" && r.level == "ok" && r.message.includes("credit installed"))' >/dev/null || fail "the doctor does not report credit installed"
# The hook one version back, a comment apart, as a machine set up before this kit has it: no released copy, so
# an edited one. Bootstrap keeps it as prepare-commit-msg.cabinet-v<N>, then replaces it; with something
# else under that name, it leaves the hook as it is.
v="$(sed -n '2s/^# cabinet credit hook v//p' "$KH")"; ((v > 1)) || fail "the credit hook's version is not above 1: $v"
{ sed -n 1p "$KH"; echo "# cabinet credit hook v$((v - 1))"; echo "# an older comment"; sed 1,2d "$KH"; } > "$HK/prepare-commit-msg"
chmod +x "$HK/prepare-commit-msg"; cp "$HK/prepare-commit-msg" "$T/credit-older"; echo other > "$HK/prepare-commit-msg.cabinet-v$((v - 1))"; boot
cmp -s "$T/credit-older" "$HK/prepare-commit-msg" || fail "bootstrap replaced an edited earlier credit hook whose keep name was taken"
rm "$HK/prepare-commit-msg.cabinet-v$((v - 1))"; out="$(HOME="$CH" "$CW/bin/bootstrap.sh" 2>&1 || true)"
cmp -s "$KH" "$HK/prepare-commit-msg" || fail "bootstrap did not replace an earlier credit hook"
cmp -s "$T/credit-older" "$HK/prepare-commit-msg.cabinet-v$((v - 1))" && [[ -x "$HK/prepare-commit-msg.cabinet-v$((v - 1))" ]] || fail "bootstrap did not keep the edited earlier credit hook"
grep -qF "kept your edited copy of the earlier credit hook as $HK/prepare-commit-msg.cabinet-v$((v - 1))" <<<"$out" || fail "bootstrap did not say it kept the edited hook: $out"
rm "$HK/prepare-commit-msg.cabinet-v$((v - 1))"
(cd "$CW" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "credit.hook" && r.level == "ok" && r.message.includes("credit installed"))' >/dev/null || fail "the doctor does not report credit installed after the earlier hook was replaced"
printf '#!/bin/sh\n# mine\nexit 0\n' > "$HK/prepare-commit-msg"; cp "$HK/prepare-commit-msg" "$T/credit-mine"; boot
cmp -s "$T/credit-mine" "$HK/prepare-commit-msg" || fail "bootstrap replaced the owner's own prepare-commit-msg"
(cd "$CW" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "credit.hook" && r.level != "ok" && r.message.includes("not the kit"))' >/dev/null || fail "the doctor did not say why credit is not installed"
# A prepare-commit-msg that is a symlink to another file: bootstrap leaves the link and its target as they are.
printf '#!/bin/sh
# linked
exit 0
' > "$T/credit-link-target"; cp "$T/credit-link-target" "$T/credit-link-copy"
rm -f "$HK/prepare-commit-msg"; ln -s "$T/credit-link-target" "$HK/prepare-commit-msg"; boot
[[ -L "$HK/prepare-commit-msg" && "$(readlink "$HK/prepare-commit-msg")" == "$T/credit-link-target" ]] && cmp -s "$T/credit-link-target" "$T/credit-link-copy" \
  || fail "bootstrap changed a symlinked prepare-commit-msg or its target"
(cd "$CW" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "credit.hook" && r.level == "note" && r.message.includes("not the kit") && r.message.includes("bootstrap leaves it as it is"))' >/dev/null \
  || fail "the doctor did not say why credit is not installed with a symlinked hook: $( (cd "$CW" && "$F" doctor --json) | j -r '$.results.find((r) => r.id == "credit.hook")?.message')"
rm -f "$HK/prepare-commit-msg"
cp "$KH" "$HK/prepare-commit-msg"
git config --global core.hooksPath "$T/credit-other-hooks"; boot
[[ "$(git config --global core.hooksPath)" == "$T/credit-other-hooks" ]] || fail "bootstrap changed a global hooks path of the owner's"
(cd "$CW" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "credit.hook" && r.level != "ok" && r.message.includes("credit-other-hooks"))' >/dev/null || fail "the doctor did not name the other hooks path"
git config --global core.hooksPath "$HK"
printf '#!/bin/sh\necho "$@" >> "%s"\n[ -e "%s" ] && exit 1\nexit 0\n' "$T/credit-own-args" "$T/credit-own-fail" > "$CR/.git/hooks/prepare-commit-msg"; chmod +x "$CR/.git/hooks/prepare-commit-msg"
echo q >> "$CR/f"; git -C "$CR" commit -qam "with the repo's hook"
grep -qx '.git/COMMIT_EDITMSG message' "$T/credit-own-args" || fail "the repo's own prepare-commit-msg did not run with git's arguments: $(cat "$T/credit-own-args" 2>/dev/null)"
touch "$T/credit-own-fail"; h="$(git -C "$CR" rev-parse HEAD)"; echo q >> "$CR/f"
git -C "$CR" commit -qam "refused" 2>/dev/null && fail "the repo's own hook failing did not stop the commit"
[[ "$(git -C "$CR" rev-parse HEAD)" == "$h" ]] || fail "a commit went in though the repo's hook failed"
rm -f "$CR/.git/hooks/prepare-commit-msg"; git -C "$CR" checkout -q -- f

# The amend guard (specs/amend-guard.md): an agent amends as CABINET_AMEND_AS=<role>, and only a commit that
# ends with that role's one credit line. amfix sets HEAD's message in a fixture repo; am runs one git commit on
# a fresh copy of it, with the four variables unset but for the assignments before "--".
AQ="Co-authored-by: Cabinet qa <$KM>" FIX="Commit the fix as a new commit" MF="give the message with -F <file> instead of -m"
amfix() { rm -rf "$T/am-base"; git init -q -b main "$T/am-base"; echo a > "$T/am-base/f"; git -C "$T/am-base" add f
  printf '%s\n' "$1" > "$T/am-fixmsg"; env -u CABINET_AMEND_AS git -C "$T/am-base" commit -q --cleanup=verbatim -F "$T/am-fixmsg"
  bh="$(git -C "$T/am-base" rev-parse HEAD)" bm="$(git -C "$T/am-base" log -1 --format=%B)"; [[ "$bm" == "$1" ]] || fail "amend guard fixture: $bm"; }
amgo() { (cd "$T/am" && env -u CABINET_AGENT -u CABINET_CREDIT -u CABINET_CREDIT_ADDRESS -u CABINET_AMEND_AS "$@") 2>"$T/am-err" && ams=0 || ams=$?; }
am() { local e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift; rm -rf "$T/am"; cp -R "$T/am-base" "$T/am"; amgo ${e[@]+"${e[@]}"} git commit -q "$@"; }
amsg() { git -C "$T/am" log -1 --format=%B; }
amok() { [[ "$ams" == 0 && "$(amsg)" == "$1" ]] || fail "amend guard: not made with the message wanted ($ams): $(amsg) / $(cat "$T/am-err")"; }
amno() { local w; [[ "$ams" != 0 && "$(git -C "$T/am" rev-parse HEAD)" == "$bh" && "$(amsg)" == "$bm" ]] || fail "amend guard: not refused, or HEAD changed ($ams): $(amsg)"
  for w; do grep -qF -- "$w" "$T/am-err" || fail "amend guard: the refusal lacks '$w': $(cat "$T/am-err")"; done; }
printf 'x\n' > "$T/am-msg"; printf 'x\n\n%s\n' "$AQ" > "$T/am-msg2"
# 1. qa's commit: qa amends it, keeping its line; another role, or a prefix of qa, is refused in every form.
amfix $'work\n\n'"$AQ"
am CABINET_AMEND_AS=qa -- --amend -m x; amok $'x\n\n'"$AQ"
am CABINET_AMEND_AS=code-reviewer -- --amend -m x; amno "HEAD is qa's commit" code-reviewer "$FIX"
am CABINET_AMEND_AS=code-reviewer -- --amend -F "$T/am-msg"; amno "HEAD is qa's commit" code-reviewer "$FIX"
am CABINET_AMEND_AS=code-reviewer -- --amend --no-edit; amno "HEAD is qa's commit" code-reviewer "$FIX"
am CABINET_AMEND_AS=q -- --amend -m x; amno "HEAD is qa's commit" "no amend as q:" "$FIX" "$MF"
# With -c or -C, git gives the source commit, so it counts as an amend, as in v3.
am CABINET_AMEND_AS=code-reviewer -- --allow-empty -C HEAD; amno "HEAD is qa's commit" "$MF"
# A new commit whose -m mentions --amend: on Linux it commits; where ps joins the arguments, it is taken as
# an amend and the refusal says to use -F.
am CABINET_AMEND_AS=code-reviewer -- --allow-empty -m "fix the --amend doc"
if [[ -r /proc/self/cmdline ]]; then amok "fix the --amend doc"; else amno "HEAD is qa's commit" "$MF"; fi
# An editor amend that deletes the line makes the commit without it; then the role's next amend is refused.
am CABINET_AMEND_AS=qa "GIT_EDITOR=sed -i.b /^Co-authored-by/d" -- --amend; amok work
amgo CABINET_AMEND_AS=qa git commit -q --amend -m z; [[ "$ams" != 0 ]] && grep -qF "HEAD has no Cabinet credit line at the end" "$T/am-err" || fail "amend guard: an amend after the line was deleted: $(cat "$T/am-err")"
# 6. A value that is not a role name is refused, never repeated, never run.
for v in Qa "qa;touch $T/m1" "\$(touch $T/m2)" $'qa\nqa'; do
  am "CABINET_AMEND_AS=$v" -- --amend -m x; amno "CABINET_AMEND_AS is not a role name" "$FIX" "$MF"
  ! grep -q -e Qa -e touch -e m1 -e m2 "$T/am-err" || fail "amend guard: the refusal repeats the value: $(cat "$T/am-err")"
done
[[ ! -e "$T/m1" && ! -e "$T/m2" ]] || fail "amend guard: a CABINET_AMEND_AS value ran"
# 7. An allowed amend keeps the line, once, and the role can amend again; an empty message stays refused.
am CABINET_AMEND_AS=qa -- --amend --no-edit; amok "$bm"
am CABINET_AMEND_AS=qa -- --amend -F "$T/am-msg2"; amok $'x\n\n'"$AQ"
am CABINET_AMEND_AS=qa -- --amend -m x; amgo CABINET_AMEND_AS=qa git commit -q --amend -m z; amok $'z\n\n'"$AQ"
am CABINET_AMEND_AS=qa -- --amend -m ""; amno
# R3: a new message that already carries another role's line is taken as it is; qa's line follows it.
am CABINET_AMEND_AS=qa -- --amend -m $'x\n\nCo-authored-by: Cabinet web <'"$KM"'>'; amok $'x\n\nCo-authored-by: Cabinet web <'"$KM"$'>\n'"$AQ"
# 8. In a run, every amend is refused as v3 refuses it, whatever CABINET_AMEND_AS holds.
mkdir -p "$T/am-v3"; cp "$KIT/test/fixtures/def9076/prepare-commit-msg" "$T/am-v3/"; chmod +x "$T/am-v3/prepare-commit-msg"
for c in "-m x" --no-edit; do
  am CABINET_AGENT=qa CABINET_AMEND_AS=qa -- --amend $c; amno; cp "$T/am-err" "$T/am-err4"
  rm -rf "$T/am"; cp -R "$T/am-base" "$T/am"; amgo CABINET_AGENT=qa CABINET_AMEND_AS=qa git -c core.hooksPath="$T/am-v3" commit -q --amend $c
  [[ "$ams" != 0 && -s "$T/am-err4" ]] && cmp -s "$T/am-err" "$T/am-err4" || fail "amend guard: a run's refusal differs from v3's ($c): $(cat "$T/am-err4") / $(cat "$T/am-err")"
done
# 9. A new commit with CABINET_AMEND_AS set is made as before, with no credit line.
am CABINET_AMEND_AS=qa -- --allow-empty -m y; amok y
# 2. A role that starts with the amending one is another role.
amfix $'work\n\nCo-authored-by: Cabinet qa-lead <'"$KM"'>'
am CABINET_AMEND_AS=qa -- --amend -m x; amno "HEAD is qa-lead's commit" "no amend as qa:" "$FIX"
# 3. No credit line: refused to an agent; the owner (no variable, or an empty one) amends as before.
amfix work
am CABINET_AMEND_AS=qa -- --amend -m x; amno "HEAD has no Cabinet credit line at the end" "no amend as qa:" "$FIX"
am -- --amend -m x; amok x
am CABINET_AMEND_AS= -- --amend -m x; amok x
# 4. Two credit lines.
amfix $'work\n\n'"$AQ"$'\n'"$AQ"
am CABINET_AMEND_AS=qa -- --amend -m x; amno "HEAD has more than one Cabinet credit line" "no amend as qa:" "$FIX"
# 5 and R1: a trailer after the line. R2: two lines and a trailer after them give one reason, more than one.
amfix $'work\n\n'"$AQ"$'\nSigned-off-by: O <o@example.com>'
am CABINET_AMEND_AS=qa -- --amend -m x; amno "HEAD has no Cabinet credit line at the end" "no amend as qa:" "$FIX"
amfix $'work\n\n'"$AQ"$'\n'"$AQ"$'\nSigned-off-by: O <o@example.com>'
am CABINET_AMEND_AS=qa -- --amend -m x; amno "HEAD has more than one Cabinet credit line" "no amend as qa:" "$FIX"
! grep -q 'at the end' "$T/am-err" || fail "amend guard: more than one reason given: $(cat "$T/am-err")"
# The role is compared as written, so a control character inside it makes it another role's; the refusal
# shows it stripped.
amfix $'work\n\nCo-authored-by: Cabinet q\001a <'"$KM"'>'
am CABINET_AMEND_AS=qa -- --amend -m x; amno "HEAD is qa's commit" "no amend as qa:" "$FIX"
! grep -q $'\001' "$T/am-err" || fail "amend guard: the refusal holds a control character"
# 10. Bootstrap replaces the released v3 and v4 with the current hook byte for byte, keeping no copy of
# them, and leaves an edited copy of the current one as it is.
[[ "$(sed -n 2p "$KH")" == "# cabinet credit hook v5" ]] || fail "the credit hook is not v5"
for c in def9076 d2d3ceb; do
  cp "$KIT/test/fixtures/$c/prepare-commit-msg" "$HK/prepare-commit-msg"; boot
  cmp -s "$KH" "$HK/prepare-commit-msg" || fail "bootstrap did not replace the released credit hook of $c with v5"
done
[[ -z "$(ls "$HK" | grep cabinet-v)" ]] || fail "bootstrap kept a released credit hook: $(ls "$HK")"
sed '3s/.*/# edited by the owner/' "$KH" > "$HK/prepare-commit-msg"; chmod +x "$HK/prepare-commit-msg"; cp "$HK/prepare-commit-msg" "$T/am-edited"; boot
cmp -s "$T/am-edited" "$HK/prepare-commit-msg" || fail "bootstrap replaced an edited copy of v5"
cp "$KH" "$HK/prepare-commit-msg"; rm -rf "$T/am" "$T/am-base"

# Existing and shared workspaces (criteria 27 to 29).
OW="$T/credit-old"; "$F" new "$OW" --yes >/dev/null
sedi '/^CABINET_CREDIT_/d' "$OW/cabinet.env"; git -C "$OW" commit -qam "a workspace from before credit roles"
cp "$OW/cabinet.env" "$T/credit-env"; "$F" -C "$OW" update >/dev/null 2>&1 || true
cmp -s "$T/credit-env" "$OW/cabinet.env" || fail "update changed cabinet.env"
crun "$OW" codex backend; [[ "$(msg)" == work ]] || fail "a workspace from before credit roles credited a commit"
(cd "$OW" && "$F" next --json) | j -e '$.steps.some((s) => s.id == "credit-roles")' >/dev/null || fail "next does not ask the credit roles question"
(cd "$OW" && "$F" config --yes --credit-roles off) >/dev/null; "$F" -C "$OW" update >/dev/null 2>&1 || true
(cd "$OW" && "$F" next --json) | j -e '!$.steps.some((s) => s.id == "credit-roles")' >/dev/null || fail "next still asks once it is answered"
grep -q 'while `cabinet.env` has no `CABINET_CREDIT_ROLES` line' "$KIT/roles/chief-of-staff.md" && grep -q 'Once it has a value, never ask again' "$KIT/roles/chief-of-staff.md" || fail "the brief does not ask the credit roles question once"
SP="$T/credit-shared"; git init -q -b main "$SP"; echo x > "$SP/f"; git -C "$SP" add f; git -C "$SP" commit -qm init
(cd "$SP" && "$F" init --yes --inside --shared) >/dev/null; git -C "$SP" add -A; git -C "$SP" commit -qm cabinet
grep -qx 'CABINET_CREDIT_ROLES="on"' "$SP/cabinet/cabinet.local.env" || fail "shared init did not keep this machine's answer"
SC="$T/credit-clone"; git clone -q "$SP" "$SC"
grep -qx 'CABINET_CREDIT_ROLES="on"' "$SC/cabinet/cabinet.env" && [[ ! -e "$SC/cabinet/cabinet.local.env" ]] || fail "the clone is not as a teammate gets it"
crun "$SC/cabinet" codex backend; [[ "$(msg)" == work ]] || fail "a teammate's machine credited before it answered"
(cd "$SC" && "$F" next --json) | j -e '$.steps.some((s) => s.id == "credit-roles" && s.command.includes("--this-machine"))' >/dev/null || fail "next does not ask the teammate"
(cd "$SC" && "$F" config --this-machine --credit-roles on) >/dev/null || fail "config --this-machine --credit-roles"
grep -qx 'CABINET_CREDIT_ROLES="on"' "$SC/cabinet/cabinet.local.env" && [[ -z "$(git -C "$SC" status --porcelain)" ]] || fail "the answer is not in cabinet.local.env only"
crun "$SC/cabinet" codex backend; [[ "$(cab)" == 1 ]] || fail "the teammate's run was not credited after the answer"
(cd "$SC" && "$F" config --this-machine --credit-email "$PM") >/dev/null 2>&1 && fail "--this-machine took --credit-email"
cp "$SC/cabinet/cabinet.local.env" "$T/credit-local"
(cd "$SC" && "$F" config --yes --this-machine --credit-roles app) >/dev/null 2>&1 && fail "--this-machine took --credit-roles app"
cmp -s "$T/credit-local" "$SC/cabinet/cabinet.local.env" && [[ -z "$(git -C "$SC" status --porcelain)" ]] || fail "--this-machine --credit-roles app changed something"
# Off for everyone wins: while the committed setting is off or not set, this machine's on credits nothing.
cs() { (cd "$SC" && "$F" doctor --json) | j -r '$.results.find((r) => r.id == "credit.setting").level + " " + $.results.find((r) => r.id == "credit.setting").message'; }
for pv in off unset; do
  git -C "$SC" checkout -q -- cabinet/cabinet.env; if [[ "$pv" == off ]]; then sedi 's/^CABINET_CREDIT_ROLES=.*/CABINET_CREDIT_ROLES="off"/' "$SC/cabinet/cabinet.env"; else sedi '/^CABINET_CREDIT_ROLES=/d' "$SC/cabinet/cabinet.env"; fi
  grep -qx 'CABINET_CREDIT_ROLES="on"' "$SC/cabinet/cabinet.local.env" || fail "credit test setup: this machine does not say on"
  crun "$SC/cabinet" codex backend; [[ "$(msg)" == work ]] || fail "this machine's on credited while the project's setting is $pv: $(msg)"
  (cd "$SC" && "$F" next --json) | j -e '!$.steps.some((s) => s.id == "credit-roles" && s.command.includes("--this-machine"))' >/dev/null || fail "next asks this machine while the project's setting is $pv"
  [[ "$(cs)" == "note credit roles: off, because the project's setting is $([[ $pv == off ]] && echo off || echo "not set"): this machine says on"* ]] || fail "doctor's credit.setting with the project $pv: $(cs)"
done
(cd "$SC" && "$F" next --json) | j -e '$.steps.some((s) => s.id == "credit-roles" && s.command == "cabinet config --credit-roles on")' >/dev/null || fail "next does not ask the project's question when it is not set"
sedi '/^CABINET_CREDIT_ROLES=/d' "$SC/cabinet/cabinet.local.env"; o="$(cd "$SC" && "$F" config --this-machine --credit-roles on 2>&1)" && grep -qF "Note: the project's credit roles setting is not set, and off for everyone wins" <<<"$o" || fail "config --this-machine --credit-roles on did not say the project's setting wins: $o"
git -C "$SC" checkout -q -- cabinet/cabinet.env; sedi 's/^CABINET_CREDIT_ROLES=.*/CABINET_CREDIT_ROLES="off"/' "$SC/cabinet/cabinet.env"
(cd "$SC" && "$F" next --json) | j -e '!$.steps.some((s) => s.id == "credit-roles")' >/dev/null || fail "next asks about credit roles while the project's setting is off"
git -C "$SC" checkout -q -- cabinet/cabinet.env; crun "$SC/cabinet" codex backend; [[ "$(cab)" == 1 ]] || fail "both on: the run was not credited"
[[ "$(cs)" == "ok credit roles: on" ]] || fail "doctor's credit.setting with both on: $(cs)"
touch "$T/credit-mark"; "$F" new "$T/credit-app" --yes --credit-roles app >/dev/null 2>&1 && fail "new took --credit-roles app"
[[ ! -e "$T/credit-app" && -z "$(find "$T" -mindepth 1 -newer "$T/credit-mark" 2>/dev/null)" ]] || fail "new --credit-roles app changed something: $(find "$T" -mindepth 1 -newer "$T/credit-mark" 2>/dev/null | head -5)"

# House rules and docs (criteria 30 to 34).
cl() { grep '^- \*\*Commits\.\*\*' "$1/AGENTS.md"; }
at=@@; tl="$(sed -n 's/^- \*\*Commits\.\*\*/&/p' "$KIT/templates/workspace/AGENTS.md" | sed "s/${at}OWNER_NAME${at}/Test/; s/${at}OWNER_EMAIL${at}/test@example.com/")"
ON="No AI or tool attribution of any kind except Cabinet's role credit (one \`Co-authored-by: Cabinet <role>\` line, added by Cabinet to a commit made in a Cabinet run; no other \`Co-Authored-By\`, no \"Generated with\" line)."
cl "$CW" | grep -qF "$ON" || fail "credit on: the Commits line does not hold the credit sentence"
"$F" new "$T/credit-offws" --yes --credit-roles off >/dev/null
[[ "$(cl "$T/credit-offws")" == "$tl" ]] || fail "credit off: the Commits line is not the template's"
sedi 's/"Generated with" line)\./& Sign each commit./' "$T/credit-offws/AGENTS.md"; git -C "$T/credit-offws" commit -qam "the owner's words"
was="$(cl "$T/credit-offws")"
(cd "$T/credit-offws" && "$F" config --yes --credit-roles on >/dev/null && "$F" config --yes --credit-roles off >/dev/null)
[[ "$(cl "$T/credit-offws")" == "$was" ]] || fail "on then off did not give the line back: $(cl "$T/credit-offws")"
sedi 's/^- \*\*Commits\.\*\*.*/- **Commits.** Authored as Test <test@example.com>. Anything goes./' "$T/credit-offws/AGENTS.md"; git -C "$T/credit-offws" commit -qam "rewritten"
was="$(cl "$T/credit-offws")"
(cd "$T/credit-offws" && "$F" config --yes --credit-roles on) | grep -q 'needs your own edit' || fail "config did not say the rewritten house rule needs the owner's edit"
[[ "$(cl "$T/credit-offws")" == "$was" ]] || fail "config changed a Commits line it does not know"
grep -q 'no AI or tool attribution lines except Cabinet.s role credit' "$KIT/AGENTS.md" && grep -q 'No other `Co-Authored-By`, no "Generated with" line' "$KIT/AGENTS.md" || fail "the kit's rule 11 does not allow only the role credit"
for d in docs/commands.md README.md docs/concepts.md CHANGELOG.md; do grep -q 'credit-roles\|Credit roles' "$KIT/$d" || fail "$d does not describe credit roles"; done
grep -q 'CABINET_CREDIT_ROLES' "$KIT/docs/commands.md" && grep -q 'CABINET_CREDIT_EMAIL' "$KIT/docs/commands.md" || fail "the cabinet.env table lacks the credit settings"
# The demo's captures fake opencode too, so none shows the version of one installed on the machine that captures.
grep -qF 'claude opencode sudo; do [[ "$(command -v "$t")" == "$T/shim/$t" ]]' "$KIT/brand/demo/capture.sh" && grep -q '^for t in [^;]* opencode [^;]*; do$' "$KIT/brand/demo/capture.sh" || fail "brand/demo/capture.sh does not put a fake opencode first on PATH"
sec="$(awk '/^## Credit roles$/{on=1; next} /^## /{on=0} on' "$KIT/docs/concepts.md")"
! sed 's/\[bot\]//g' <<<"$sec" | grep -qiw 'bot' || fail "the credit roles docs call a role a bot"
for r in claude codex antigravity qwen grok opencode cursor; do grep -q "^| \`$r\` | not yet |\|^| \`$r\` | yes" <<<"$sec" || fail "the docs do not say whether $r was confirmed live"; done
export HOME="$oh" GIT_CONFIG_GLOBAL="$og"
  return 0   # a last "check && fail" line must not end the run
}

section "color in a terminal: styled for people only, plain text unchanged" ""
s62() {
# Its own HOME and global git config, so list and digest see only this section's workspaces. Restored at the end.
local oh="$HOME" og="$GIT_CONFIG_GLOBAL"
export HOME="$T/color-home" GIT_CONFIG_GLOBAL="$T/color-home/.gitconfig"
mkdir -p "$HOME"; printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$GIT_CONFIG_GLOBAL"
# tt: run it in a terminal (in_tty) with a TERM that styles (TT_TERM to choose), \r removed. nc: every code removed.
tt() { TERM="${TT_TERM:-xterm}" in_tty "$@" | tr -d '\r'; }
nc() { sed $'s/\033\\[[0-9;]*m//g'; }
E=$'\033[' ER=$'\033\\['   # ER in a regular expression
# A kit at 9.9.9 whose changelog holds what the renderer must show (criteria 10, 11 and 15).
CK="$T/color-kit"; cp -R "$KIT" "$CK"; rm -rf "$CK/.git"
j '({...$, version: "9.9.9"})' "$KIT/package.json" > "$CK/package.json"
LW="/a/path/that/is/much/longer/than/forty/characters/to/test.txt"
cat > "$CK/CHANGELOG.md" <<EOF
# Changelog

## 9.9.9 - 1 Jan 2030

### Docs

- Run \`cabinet next\` for **bold words** first.
- A list item with several lines' worth of words, and one long path, $LW, that stays whole on its own line however narrow the terminal is, and then more words after it, so this item still wraps past a hundred characters.
- Text is printed, never run: \$(touch pwned)

A plain paragraph longer than forty characters, wrapping at words.

## 0.0.1 - 1 Jan 2020

- The first one.
EOF
CC="$CK/bin/cabinet"
# Workspaces: one with handoffs, a brief and spend; one on an older kit with a problem and a stale brief;
# one with no brief; one whose folder is gone.
"$F" new "$T/color" --name "Color Co" --yes >/dev/null; CW="$T/color"
"$F" new "$T/color-old" --yes >/dev/null; CO="$T/color-old"
"$F" new "$T/color-nobrief" --yes >/dev/null
"$F" new "$T/color-gone" --yes >/dev/null; rm -rf "$T/color-gone"
echo 0.0.1 > "$CO/.cabinet/version"; rm "$CO/agents/qa.md"
printf '#!/bin/sh\necho "{\\"problems\\": 0}"\n' > "$T/color-nobrief/bin/doctor.sh"   # a doctor that finds nothing: list shows "all good"
printf '# Brief\n\nOld.\n' > "$CO/BRIEF.md"; touch -t 202001010700 "$CO/BRIEF.md"
printf '# Brief\n\n## Sign-off queue\n\n1. **Publish?** A. now. B. later. $(touch pwned)\n\n## Actions for the owner\n\n- Push api main.\n' > "$CW/BRIEF.md"
cat >> "$CW/HANDOFFS.md" <<'EOF'

### H-20260101-01: A decision for the owner
- From: qa -> To: owner
- Status: open (2026-01-01)
- Changed: x
- Needed: y

### H-20260101-02: Another for the founder
- From: qa -> To: founder
- Status: open (2026-01-01)
- Changed: x
- Needed: y

### H-20260101-03: Review of a change
- From: backend -> To: qa
- Status: open (2026-01-01)
- Changed: x
- Needed: y
- Verdict: security PASS 2026-01-02 abc1234 specs/security/n.md
- Verdict: code-reviewer BLOCK 2026-01-02 abc1234 specs/reviews/n.md
EOF
git -C "$CW" commit -qam "handoffs for the color test"
(cd "$CW" && "$F" config --yes --budget 4) >/dev/null
mkdir -p "$HOME/$LOGS/color"; printf '%s\tbrief\tclaude\t3.5\n' "$(date +%s)" > "$HOME/$LOGS/color/spend.tsv"
mkdir -p "$T/color-npm"; printf '#!/bin/sh\nexit 1\n' > "$T/color-npm/npm"; chmod +x "$T/color-npm/npm"   # outdated stays offline

# Criteria 1 and 2, and the same lines styled: piped has no code; NO_COLOR and TERM=dumb in a terminal print
# exactly the piped output; styled with codes removed is the piped output (headings without "== ").
: > "$T/color-styled"
for c in "next" "list" "digest" "status" "changelog" "doctor" "handoff list" "handoff list owner" "handoff list qa"; do
  # shellcheck disable=SC2086
  p="$(cd "$CW" && "$F" $c 2>&1 || true)"
  [[ -n "$p" && "$p" != *$'\033['* ]] || fail "piped $c is empty or styled: $p"
  o="$(cd "$CW" && NO_COLOR=1 tt "$F" $c)"; [[ "$o" == "$p" ]] || { diff <(echo "$p") <(echo "$o"); fail "$c in a terminal with NO_COLOR is not its piped output"; }
  o="$(cd "$CW" && TT_TERM=dumb tt "$F" $c)"; [[ "$o" == "$p" ]] || { diff <(echo "$p") <(echo "$o"); fail "$c in a terminal with TERM=dumb is not its piped output"; }
  s="$(cd "$CW" && tt "$F" $c)"
  [[ "$s" == *$'\033['* || "$c" == "handoff list owner" ]] || fail "$c in a terminal is not styled"   # the full form styles only verdicts
  printf '%s\n' "$s" >> "$T/color-styled"
  [[ "$c" == changelog ]] && continue
  [[ "$(nc <<<"$s")" == "$(sed 's/^== //' <<<"$p")" ]] || { diff <(nc <<<"$s") <(sed 's/^== //' <<<"$p"); fail "$c styled, with codes removed, is not its piped text"; }
done
"$F" changelog 0.1.0 | cmp -s - <(awk -v from=0.1.0 -v to="$(j -r '$.version' "$KIT/package.json")" '
  function newer(a, b,   x, y, i, n) { n = split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) if (x[i] + 0 != y[i] + 0) return x[i] + 0 > y[i] + 0; return 0 }
  /^## [0-9]+\.[0-9]+\.[0-9]+/ { v = $2; on = (from == "" || newer(v, from)) && !newer(v, to) }
  /^## / && !/^## [0-9]/ { on = 0 }
  on { print }' "$KIT/CHANGELOG.md") || fail "piped changelog is not the changelog's own lines"
for x in NO_COLOR=1 TERM=dumb; do
  o="$(if [[ $x == NO_COLOR=1 ]]; then NO_COLOR=1 tt "$CC" changelog; else TT_TERM=dumb tt "$CC" changelog; fi)"
  [[ "$o" == "$("$CC" changelog)" ]] && grep -q '^## 9.9.9' <<<"$o" && grep -q '^### Docs' <<<"$o" && grep -qF '`cabinet next`' <<<"$o" || fail "changelog with $x in a terminal is not the raw Markdown"
done
# Criterion 2 on update: a fresh copy of one workspace for each run, at the same path.
cp -R "$CW" "$T/color-base"; U="$T/color-up"
fresh() { rm -rf "$U"; cp -R "$T/color-base" "$U"; }
fresh; p="$("$CC" -C "$U" update 2>&1)"; [[ "$p" != *$'\033['* ]] || fail "piped update is styled"
fresh; [[ "$(NO_COLOR=1 tt "$CC" -C "$U" update)" == "$p" ]] || fail "update in a terminal with NO_COLOR is not its piped output"
fresh; [[ "$(TT_TERM=dumb tt "$CC" -C "$U" update)" == "$p" ]] || fail "update in a terminal with TERM=dumb is not its piped output"

# Criterion 3: --json in a terminal is plain JSON.
for c in "next --json" "list --json" "digest --json" "status --json" "handoff list --json" "changelog --json" "doctor --json" "version --json" "outdated --json"; do
  o="$(cd "$CW" && PATH="$T/color-npm:$PATH" tt "$F" $c)"
  [[ "$o" != *$'\033['* ]] && j -e 'true' <<<"$o" >/dev/null || fail "$c in a terminal is not plain JSON: $o"
done

# Criterion 5: errors, and each stream on its own.
tt "$F" nosuchcommand | grep -qF "${E}31mcabinet:" || fail "an error in a terminal does not start with a red cabinet:"
in_tty bash -c '"$0" nosuchcommand 2>"$1"' "$F" "$T/color-err" >/dev/null
grep -q 'cabinet:' "$T/color-err" && ! grep -qF "$E" "$T/color-err" || fail "an error to a file is styled"
o="$(tt bash -c 'cd "$1" && "$0" next | cat' "$F" "$CW")"; [[ -n "$o" && "$o" != *$'\033['* ]] || fail "next piped inside a terminal is styled"

# Criterion 6: next.
o="$(cd "$CW" && tt "$F" next)"
head -1 <<<"$o" | grep -q "^${ER}1mNext in Color Co" && head -1 <<<"$o" | grep -qF "${E}2m(" || fail "next: the first line bold, its folder dim"
grep -qF "  ${E}33m1.${E}0m " <<<"$o" && grep -qF "Run: ${E}1mcabinet bootstrap" <<<"$o" || fail "next: the step number yellow, the command bold"
grep -q 'Optional:' <<<"$o" && ! grep 'Optional:' <<<"$o" | grep -qF "${E}33m" && grep 'Optional:' <<<"$o" | grep -qF "Run: ${E}1m" || fail "next: the Optional line has yellow, or its command is not bold"

o="$(cd "$T" && tt "$F" next)"
head -1 <<<"$o" | grep -q "^${ER}1mNot inside a cabinet workspace.${ER}0m$" && grep -qF "  ${E}33m1.${E}0m Start one" <<<"$o" || fail "next outside a workspace: the first line bold, the step number yellow"
[[ "$(nc <<<"$o")" == "$(cd "$T" && "$F" next)" ]] || fail "next outside a workspace, styled with codes removed, is not its piped text"

# Criteria 7 and 19: digest.
o="$(cd "$CW" && tt "$F" digest)"
head -1 <<<"$o" | grep -q "^${ER}1m" || fail "digest: the first line is not bold"
grep -qF "${E}1mColor Co${E}0m ${E}2m(" <<<"$o" && ! nc <<<"$o" | grep -q '^== ' || fail "digest: the heading bold without ==, its folder dim"
grep -qF "Brief of ${E}2m" <<<"$o" && grep -qF "${E}33mSign-off queue:" <<<"$o" && grep -qF "${E}33mActions for you:" <<<"$o" || fail "digest: the date dim, the queue and actions yellow"
grep -qF "${E}33m2 handoff(s) wait on you${E}0m: cd" <<<"$o" || fail "digest: only the words of the waiting handoffs yellow"
grep -qF "${E}34mOlder than a day and a half" <<<"$o" && grep -qF "${E}34mNo brief yet" <<<"$o" || fail "digest: a stale or missing brief is not blue"
grep -qF "Agent runs this week: ${E}34m\$3.50 of the \$4 budget (87%)" <<<"$o" || fail "digest: a spend at 80% is not blue"
# Criterion 16.
tt "$F" digest --write "$T/color-digest.md" >/dev/null
grep -q 'Sign-off queue:' "$T/color-digest.md" && ! grep -qF "$E" "$T/color-digest.md" || fail "digest --write in a terminal wrote codes"

# Criterion 8: list.
o="$(cd "$CW" && tt "$F" list)"
head -1 <<<"$o" | grep -q "^${ER}1mWorkspaces on this machine" || fail "list: the first line is not bold"
grep -q "^  ${ER}2mSLUG " <<<"$o" || fail "list: the header row is not dim"
grep -E "^  color " <<<"$o" | grep -qF "${E}33m2 handoff(s)${E}0m" || fail "list: what waits on you is not yellow"
grep -E "^  color " <<<"$o" | grep -Eq "${ER}2m[0-9]{1,2} [A-Z][a-z]{2} [0-9]{4}, .*${ER}0m +${ER}2m/.*color${ER}0m$" || fail "list: LATEST BRIEF and FOLDER are not dim"
grep -E "^  color-old " <<<"$o" | grep -Eq "^  color-old +color-old +0\.0\.1\* " && grep -E "^  color-old " <<<"$o" | grep -Eq "${ER}31m[0-9]+ to fix${ER}0m" || fail "list: the KIT value styled, or the problem not red"
grep -E "^  color-gone " <<<"$o" | grep -qF "${E}31mfolder gone${E}0m" || fail "list: folder gone is not red"
grep -E "^  color-nobrief " <<<"$o" | grep -qF "${E}32mall good${E}0m" || fail "list: all good is not green"

# Criterion 9: handoff list.
o="$(cd "$CW" && tt "$F" handoff list)"
grep -qF "${E}33mowner${E}0m" <<<"$o" && grep -qF "${E}33mfounder${E}0m" <<<"$o" && grep -qF "${E}2mH-20260101-01" <<<"$o" && grep -Eq "^${ER}2m *[0-9?]+d${ER}0m" <<<"$o" || fail "handoff list: the owner yellow, IDs and ages dim"
o="$(cd "$CW" && tt "$F" handoff list qa)"
grep -qF -- "- Verdict: security ${E}32mPASS${E}0m 2026-01-02" <<<"$o" && grep -qF -- "- Verdict: code-reviewer ${E}31mBLOCK${E}0m" <<<"$o" || fail "handoff list qa: PASS green, BLOCK red"

# Criterion 19: status, the rest of update.
o="$(cd "$CW" && tt "$F" status)"; grep -qF "${E}32mno kit file edited" <<<"$o" || fail "status: no kit file edited is not green"
echo "# edit" >> "$CW/bin/handoff.sh"; o="$(cd "$CW" && tt "$F" status)"; git -C "$CW" checkout -q -- bin/handoff.sh
grep -qF "${E}34medited here${E}0m: bin/handoff.sh" <<<"$o" || fail "status: edited here is not blue"
fresh; o="$(tt "$CC" -C "$U" update)"; printf '%s\n' "$o" >> "$T/color-styled"
grep -q "^${ER}1mcabinet .* -> 9.9.9 in " <<<"$o" && grep -qF "${E}1mWhat changed since" <<<"$o" && ! nc <<<"$o" | grep -q '^== ' || fail "update: headings not bold, or == left"
grep -qF "${E}32mCommitted in the workspace${E}0m: cabinet: update to 9.9.9" <<<"$o" || fail "update: Committed in the workspace is not green"
grep -qF "${E}1m9.9.9${E}0m${E}2m - 1 Jan 2030${E}0m" <<<"$o" && ! nc <<<"$o" | grep -q '^#' || fail "update: the changelog is not rendered"
o="$(tt "$CC" -C "$U" update)"; grep -qF "${E}32mNothing changed${E}0m" <<<"$o" || fail "update: Nothing changed is not green"
fresh; echo "# edit" >> "$U/bin/handoff.sh"; o="$(tt "$CC" -C "$U" update)"
grep -qF "${E}31mSome kit files were edited here${E}0m" <<<"$o" || fail "update: an edited kit file is not red"
fresh; rm -rf "$U/.git"; o="$(tt "$CC" -C "$U" update)"; grep -qF "${E}32mUpdated to${E}0m 9.9.9" <<<"$o" || fail "update: Updated to is not green"

# Criterion 10: the changelog, rendered.
o="$(tt "$CC" changelog)"; printf '%s\n' "$o" >> "$T/color-styled"
! nc <<<"$o" | grep -q '^#' && ! nc <<<"$o" | grep -qF '`' && ! nc <<<"$o" | grep -qF '**' || fail "changelog: Markdown marks left"
grep -qF "${E}1m9.9.9${E}0m${E}2m - 1 Jan 2030" <<<"$o" && grep -qF "${E}1mDocs" <<<"$o" && grep -qF "${E}1mbold words" <<<"$o" && grep -qF "Run cabinet next for" <<<"$o" || fail "changelog: versions, headings, bold and code"
[[ "$(tt "$CC" changelog 9.9.9)" == "$("$CC" changelog 9.9.9)" ]] || fail "changelog with no sections in range differs in a terminal"
# Criterion 11: wrapping at words, at COLUMNS, the terminal's width, or 80.
words() { tr -s ' \n' '\n\n' | sed '/^$/d'; }
want="$("$CC" changelog | sed 's/^#* //; s/`//g; s/\*\*//g' | words)"
wrapped() {  # wrapped <output> <width>: every line fits but the long word alone, no word split, items indented
  local o; o="$(nc <<<"$1")"
  awk -v w="$2" -v lw="$LW" 'length($0) > w && !($0 ~ /^ *[^ ]+$/ && index($0, lw)) { print "too long: " $0; bad = 1 } END { exit bad }' <<<"$o" || return 1
  [[ "$(words <<<"$o")" == "$want" ]] || { echo "words differ"; return 1; }
  awk '/^- / { item = 1; next } /^$/ || /^[^ -]/ { item = 0 } item && !/^  [^ ]/ { print "not under the text: " $0; bad = 1 } END { exit bad }' <<<"$o"
}
o="$(COLUMNS=40 tt "$CC" changelog)"; wrapped "$o" 40 || fail "changelog at COLUMNS=40"
nc <<<"$o" | grep -qxF "  $LW," && nc <<<"$o" | grep -q '^A plain paragraph longer than forty$' || { nc <<<"$o"; fail "changelog at COLUMNS=40: the long word or the paragraph"; }
o="$(unset COLUMNS; tt bash -c 'stty cols 100 && exec "$0" changelog' "$CC")"; wrapped "$o" 100 && nc <<<"$o" | awk 'length($0) > 80 { f = 1 } END { exit !f }' || fail "changelog after stty cols 100 does not wrap at 100"
o="$(unset COLUMNS; tt bash -c 'stty cols 0 && exec "$0" changelog' "$CC")"; wrapped "$o" 80 && nc <<<"$o" | awk 'length($0) > 60 { f = 1 } END { exit !f }' || fail "changelog after stty cols 0 does not wrap at 80"

# Criterion 13: yellow keeps apart from the status colors, and is never bold.
for c in "next" "digest" "status" "handoff list"; do
  (cd "$CW" && tt "$F" $c) | grep -F "${E}33m" | grep -qE "${ER}3[124]m" && fail "$c: a line with yellow has a status color"
done
node -e 'const s = require("fs").readFileSync(process.argv[1], "utf8"); const E = "\x1b[";
  for (const [a, b] of [["1m", "33m"], ["33m", "1m"]]) { let i = -1; while ((i = s.indexOf(E + a, i + 1)) >= 0) {
    const r = s.indexOf(E + "0m", i), n = s.indexOf(E + b, i); if (n >= 0 && (r < 0 || n < r)) process.exit(1); } }
  if (s.includes(E + "1;33m")) process.exit(1)' "$T/color-styled" || fail "yellow is bold somewhere"
# Criterion 14: escape codes only in the shell helper and the renderer.
o="$(cd "$KIT" && grep -rlE '\\033\[|\\e\[|\\x1[bB]|\\u001[bB]|\\u\{1[bB]\}|fromCharCode\(27\)' bin/cabinet scripts/ | sort | tr '\n' ' ')"
[[ "$o" == "scripts/lib.js scripts/platform.sh " ]] || fail "escape codes outside the helper and the renderer: $o"
# Criterion 15: text is printed, never run.
(cd "$CW" && tt "$F" digest) | grep -qF '$(touch pwned)' && tt "$CC" changelog | grep -qF '$(touch pwned)' || fail "\$(touch pwned) is not printed as it is"
[[ ! -e "$CW/pwned" && ! -e "$T/pwned" && ! -e "$PWD/pwned" ]] || fail "text from a brief or the changelog was run"
# Criteria 17 and 18: the docs and the brand.
grep -q 'NO_COLOR=1' "$KIT/docs/commands.md" && awk '/^## 0\.2\.0 - /{on=1; next} /^## /{on=0} on' "$KIT/CHANGELOG.md" | grep -q 'NO_COLOR' || fail "the docs or the changelog do not describe color"
grep -qxF -- "- **(Approved)** In a terminal, what waits on the owner is the terminal's yellow, standing in for brass. It is the owner's color, not a status." "$KIT/brand/BRAND.md" \
  && j -e '$.color.brass.terminal == "yellow" && $.color.brass.use == "The owner'"'"'s open seat, on light backgrounds; in a terminal, yellow marks what waits on the owner. Nothing else."' "$KIT/brand/tokens.json" >/dev/null \
  && grep -qF "<li><b>In a terminal,</b> use the terminal's own red, green and blue, and never yellow for a status: yellow stands in for brass and marks only what waits on the owner. Color only when the output is a terminal, and none when <code>NO_COLOR</code> is set.</li>" "$KIT/brand/index.html" || fail "the brand does not hold the yellow rule word for word"
# A changelog line ending in \r, or holding U+2028, renders, and changelog in a terminal exits 0.
printf '\n- A line from another editor\r\n- A line with a separator\342\200\250in it\n' >> "$CK/CHANGELOG.md"
o="$(tt bash -c '"$0" changelog; echo "exit=$?"' "$CC")"
grep -qx 'exit=0' <<<"$o" && grep -qF "${E}1m9.9.9${E}0m" <<<"$o" && grep -q 'A line from another editor' <<<"$o" || fail "changelog with \\r or U+2028 in a terminal failed: $o"
# A renderer that fails leaves the changelog as written, and update goes on to its end.
CB="$T/color-kit-broken"; cp -R "$CK" "$CB"
sedi 's/^function changelogRender(width) {$/& throw new Error("broken");/' "$CB/scripts/lib.js"
grep -q 'throw new Error("broken")' "$CB/scripts/lib.js" || fail "color test setup: the renderer was not broken"
fresh; o="$(tt bash -c '"$0" -C "$1" update; echo "exit=$?"' "$CB/bin/cabinet" "$U")"
grep -qx 'exit=0' <<<"$o" && grep -q '^## 9.9.9 - 1 Jan 2030$' <<<"$o" && grep -qF "${E}32mCommitted in the workspace" <<<"$o" || fail "a failing renderer stopped update: $o"
rm -rf "$CB"
for x in "$CW" "$CO" "$T/color-nobrief" "$U" "$T/color-base"; do [[ -d "$x" ]] && "$F" -C "$x" remove --yes --force >/dev/null 2>&1; rm -rf "$x"; done
rm -rf "$HOME/$LOGS/color" "$HOME/$LOGS/color-gone" "$CK"
export HOME="$oh" GIT_CONFIG_GLOBAL="$og"
  return 0   # a last "check && fail" line must not end the run
}

section "control characters in project text show as ? in a terminal" ""
s63() {
# Its own HOME, so list and digest see only this section's workspace. Restored at the end.
local oh="$HOME" og="$GIT_CONFIG_GLOBAL"
export HOME="$T/ctl-home" GIT_CONFIG_GLOBAL="$T/ctl-home/.gitconfig"
mkdir -p "$HOME"; printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$GIT_CONFIG_GLOBAL"
tt() { TERM=xterm in_tty "$@" | tr -d '\r'; }
local ESC=$'\033' BEL=$'\007' CAFE=$'caf\xc3\xa9' C1=$'\xc2\x9b'
"$F" new "$T/ctl" --name "Ctl Co" --yes >/dev/null; CT="$T/ctl"
# A project name, a handoff title and a brief's sign-off queue line, each holding escape sequences, as a
# cloned project or a hand edit could write them; a C1 control (U+009B) too, and a UTF-8 word.
sedi "s/^CABINET_PROJECT=.*/CABINET_PROJECT=\"Ctl ${ESC}[2J${C1}1m Co\"/" "$CT/cabinet.env"
printf '\n### H-20260101-01: Red %s[31mtitle %s]0;x%s end\n- From: qa -> To: owner\n- Status: open (2026-01-01)\n- Changed: x\n- Needed: y\n' "$ESC" "$ESC" "$BEL" >> "$CT/HANDOFFS.md"
printf '\n### H-20260101-02: Lunch at the %s\n- From: qa -> To: owner\n- Status: open (2026-01-01)\n- Changed: x\n- Needed: y\n' "$CAFE" >> "$CT/HANDOFFS.md"
printf '# Brief\n\n## Sign-off queue\n\n1. **Clear?** %s[2J A. yes.\n' "$ESC" > "$CT/BRIEF.md"
raw() { grep -q "${ESC}\[2J\|${ESC}\]0\|${ESC}\[31mtitle\|$BEL\|$C1" <<<"$1"; }
local title="Red ?[31mtitle ?]0;x? end" o c
for c in "handoff list" "handoff list owner" digest next list; do
  o="$(cd "$CT" && tt "$F" $c)"
  raw "$o" && fail "$c in a terminal printed a control character from project text: $(printf '%s' "$o" | od -c | grep -m3 '033\|007')"
  case "$c" in
    handoff*) grep -qF "$title" <<<"$o" && grep -qF "Lunch at the $CAFE" <<<"$o" || fail "$c in a terminal: the title is not shown with '?' or the UTF-8 word changed: $o" ;;
    digest) grep -qF '1. **Clear?** ?[2J A. yes.' <<<"$o" && grep -qF 'Ctl ?[2J?1m Co' <<<"$o" || fail "digest in a terminal: $o" ;;
    *) grep -qF 'Ctl ?[2J?1m Co' <<<"$o" || fail "$c in a terminal: the project name is not shown with '?': $o" ;;
  esac
done
o="$(cd "$CT" && NO_COLOR=1 tt "$F" handoff list)"; ! raw "$o" && grep -qF "$title" <<<"$o" || fail "handoff list in a terminal with NO_COLOR printed a control character: $o"
# A file saved with CRLF line ends shows no '?' at each line's end; a \r inside a line still does.
cp "$CT/HANDOFFS.md" "$T/ctl-handoffs"; printf '\n### H-20260101-03: Windows line\r\n- From: qa -> To: owner\r\n- Status: open (2026-01-01)\r\n- Changed: a\rb\r\n' >> "$CT/HANDOFFS.md"
o="$(cd "$CT" && tt "$F" handoff list owner)"
grep -qx '### H-20260101-03: Windows line' <<<"$o" && grep -qx -- '- Changed: a?b' <<<"$o" || fail "handoff list owner with CRLF lines: $(grep -A4 'Windows' <<<"$o" | od -c | head)"
cp "$T/ctl-handoffs" "$CT/HANDOFFS.md"
# A refused config value is shown through the same filter (the project name above holds ESC [2J and a C1 control).
o="$(cd "$CT" && tt bash -c '"$0" config --yes --week-start monday' "$F")"
grep -qF "CABINET_PROJECT is 'Ctl ?[2J?1m Co', which cannot be written back" <<<"$o" && ! grep -q "$ESC\\[2J" <<<"$o" || fail "config printed a refused value's control characters: $o"
# Piped and --json, as written, byte for byte.
(cd "$CT" && "$F" handoff list) | grep -qF "Red ${ESC}[31mtitle ${ESC}]0;x${BEL} end" || fail "handoff list piped changed the title"
(cd "$CT" && "$F" handoff list owner) | grep -qF "Red ${ESC}[31mtitle ${ESC}]0;x${BEL} end" || fail "handoff list owner piped changed the title"
(cd "$CT" && "$F" handoff list --json) | j -e '$.some((e) => e.title == "Red \u001b[31mtitle \u001b]0;x\u0007 end")' >/dev/null || fail "handoff list --json changed the title"
(cd "$CT" && "$F" digest) | grep -qF "**Clear?** ${ESC}[2J A." || fail "digest piped changed the brief line"
(cd "$CT" && "$F" next --json) | j -e '$.project == "Ctl \u001b[2J\u009b1m Co"' >/dev/null || fail "next --json changed the project name"
(cd "$CT" && "$F" digest --json) | j -e '$[0].sign_off_queue.includes("\u001b[2J")' >/dev/null || fail "digest --json changed the brief line"
# The remaining commands: doctor (a cabinet.env value), role list (a role's title), repo list (a repo's
# folder, and a repo name, which is skipped), spec check (a spec's status) and status.
cp "$CT/cabinet.env" "$T/ctl-env"; sedi 's/^CABINET_CREDIT_ROLES=.*//' "$CT/cabinet.env"; printf 'CABINET_CREDIT_ROLES="o%s[2Jn"\n' "$ESC" >> "$CT/cabinet.env"
printf '\n## Team\n\n- Title: Head %s[31mof QA, %s\n' "$ESC" "$CAFE" >> "$CT/roles/qa.md"
printf 'ok\t-\t-\tno\tsub%s[2Jdir\nx%s[2Jy\t-\n' "$ESC" "$ESC" >> "$CT/repos.tsv"
printf -- '---\nfeature: x\nstatus: dr%s[2Jaft\n---\n\n# X\n' "$ESC" > "$CT/specs/x.md"
for c in doctor "role list" "repo list" "spec check" status; do
  o="$(cd "$CT" && tt "$F" $c)"
  grep -q "$ESC\[2J\|$ESC\[31mof" <<<"$o" && fail "$c in a terminal printed a control character from project text: $(printf '%s' "$o" | od -c | grep -m3 '033')"
  case "$c" in
    doctor) grep -qF 'CABINET_CREDIT_ROLES is "o?[2Jn", not off or on' <<<"$o" || fail "doctor in a terminal: $o" ;;
    "role list") grep -qF "Head ?[31mof QA, $CAFE" <<<"$o" || fail "role list in a terminal: $o" ;;
    "repo list") grep -qF 'sub?[2Jdir' <<<"$o" && grep -qF 'skipped the row named "x?[2Jy"' <<<"$o" || fail "repo list in a terminal: $o" ;;
    "spec check") grep -qF 'specs/x.md (dr?[2Jaft)' <<<"$o" || fail "spec check in a terminal: $o" ;;
    status) grep -q '^workspace .*: cabinet ' <<<"$o" || fail "status in a terminal: $o" ;;
  esac
done
(cd "$CT" && "$F" doctor 2>&1) | grep -qF "CABINET_CREDIT_ROLES is \"o${ESC}[2Jn\"" || fail "doctor piped changed the value"
(cd "$CT" && "$F" doctor --json 2>/dev/null) | j -e '$.results.some((r) => r.message.includes("o\u001b[2Jn"))' >/dev/null || fail "doctor --json changed the value"
(cd "$CT" && "$F" role list 2>/dev/null) | grep -qF "Head ${ESC}[31mof QA, $CAFE" || fail "role list piped changed the title"
(cd "$CT" && "$F" repo list 2>/dev/null) | grep -qF "sub${ESC}[2Jdir" || fail "repo list piped changed the folder"
(cd "$CT" && "$F" spec check 2>&1) | grep -qF "specs/x.md (dr${ESC}[2Jaft)" || fail "spec check piped changed the status"
cp "$T/ctl-env" "$CT/cabinet.env"
grep -q 'control characters from project text show as `?`' "$KIT/docs/commands.md" || fail "the commands page does not say control characters show as ?"
"$F" -C "$CT" remove --yes --force >/dev/null 2>&1 || true; rm -rf "$CT"
export HOME="$oh" GIT_CONFIG_GLOBAL="$og"
  return 0   # a last "check && fail" line must not end the run
}

section "push-check: what is ready to push, per repo" ""
s64() {
local PC="$T/pc" ESC=$'\033'
"$F" new "$PC" --yes --roles "qa security" >/dev/null || fail "new for push-check"
# app: cloned (so its main has an upstream) with four unpushed commits; good: one, on a ready handoff;
# same: nothing to push; det: detached; noup: no upstream; gone: not on this machine.
mkr() { mkdir -p "$1" && git -C "$1" init -q -b main && echo x > "$1/f" && git -C "$1" add -A && git -C "$1" commit -qm init; }
mkr "$T/pc-src"; git clone -q "$T/pc-src" "$PC/app"; git clone -q "$T/pc-src" "$PC/good"; git clone -q "$T/pc-src" "$PC/det"; git clone -q "$T/pc-src" "$PC/same"; mkr "$PC/noup"
git -C "$PC/det" checkout -q --detach
for n in 1 2 3 4; do echo "$n" >> "$PC/app/f"; git -C "$PC/app" commit -qam "app change $n"; eval "c$n=\$(git -C \"\$PC/app\" rev-parse --short HEAD)"; done
echo g >> "$PC/good/f"; git -C "$PC/good" commit -qam "good change"; g1="$(git -C "$PC/good" rev-parse --short HEAD)"
git -C "$PC/app" remote set-url origin https://example.invalid/app.git   # a fetch would fail: none is made
printf 'app\t-\t-\tno\ngood\t-\t-\tno\nsame\t-\t-\tno\ndet\t-\t-\tno\nnoup\t-\t-\tno\ngone\t-\t-\tno\n' >> "$PC/repos.tsv"
cat >> "$PC/HANDOFFS.md" <<HO

### H-20260101-01: Ready work
- From: backend -> To: qa, security
- Status: open (2026-01-01)
- Changed: x
- Needed: y
- Verdict: qa PASS 2026-01-02 $c1,$g1 specs/qa/a.md
- Verdict: security PASS 2026-01-02 $c1,$g1 specs/security/a.md

### H-20260101-02: Work with a stale PASS
- From: backend -> To: qa, security
- Status: open (2026-01-01)
- Changed: x
- Needed: y
- Verdict: qa PASS 2026-01-02 $c2 specs/qa/b.md
- Verdict: security PASS 2026-01-02 $c2,$c3 specs/security/b.md

### H-20260101-03: A verdict naming a hash too short to tell commits apart
- From: backend -> To: qa, security
- Status: open (2026-01-01)
- Changed: x
- Needed: y
- Verdict: qa PASS 2026-01-02 ${c4:0:6} specs/qa/c.md
- Verdict: security PASS 2026-01-02 ${c4:0:6} specs/security/c.md
HO
git -C "$PC" add -A && git -C "$PC" commit -qm "push-check setup"
snap() { local r; for r in "$PC" "$PC/app" "$PC/good"; do git -C "$r" for-each-ref; git -C "$r" status --porcelain; done; cksum < "$PC/HANDOFFS.md"; }
before="$(snap)"
out="$(cd "$PC/app" && "$F" push-check)" || fail "push-check: $out"
part() { awk -v n="$1" '$0 == n || index($0, n " (") == 1 { on = 1; print; next } /^[^ ]/ { on = 0 } on' <<<"$out"; }
for r in workspace app good same det noup gone; do [[ -n "$(part "$r")" ]] || fail "push-check has no part for $r: $out"; done
# Each state's whole part: no branch line for a detached HEAD or a missing repo, the branch alone
# without an upstream, the counts with one.
P="$(cd "$PC" && pwd -P)" wb="$(git -C "$PC" symbolic-ref --short HEAD)" nl=$'\n'
for x in "det ($P/det)$nl  not ready: detached HEAD" "gone ($P/gone)$nl  not ready: not on this machine" \
  "noup ($P/noup)$nl  Branch main$nl  not ready: no upstream: nothing to compare with" "workspace ($P)$nl  Branch $wb$nl  not ready: no upstream: nothing to compare with" \
  "same ($P/same)$nl  Branch main, upstream origin/main: 0 unpushed commit(s), 0 file(s) changed, 0 insertion(s), 0 deletion(s)$nl  not ready: nothing to push" \
  "good ($P/good)$nl  Branch main, upstream origin/main: 1 unpushed commit(s), 1 file(s) changed, 1 insertion(s), 0 deletion(s)$nl  $g1 good change (H-20260101-01)$nl  H-20260101-01: ready$nl  ready to push" \
  "app ($P/app)$nl  Branch main, upstream origin/main: 4 unpushed commit(s), 1 file(s) changed, 4 insertion(s), 0 deletion(s)$nl  $c4 app change 4 (no handoff)$nl  $c3 app change 3 (H-20260101-02)$nl  $c2 app change 2 (H-20260101-02)$nl  $c1 app change 1 (H-20260101-01)$nl  H-20260101-02: stale qa$nl  H-20260101-01: ready$nl  not ready: $c4 is on no handoff"; do
  [[ "$(part "${x%% *}")" == "$x" ]] || fail "push-check's part for ${x%% *}:$nl$(part "${x%% *}")$nl--- expected:$nl$x"
done
[[ "$(head -1 <<<"$out")" == "Ready to push, per repo ($P):" ]] || fail "push-check's first line: $(head -1 <<<"$out")"
a="$(part app)"
grep -qF "Branch main, upstream origin/main: 4 unpushed commit(s), 1 file(s) changed, 4 insertion(s), 0 deletion(s)" <<<"$a" || fail "push-check app's branch line: $a"
grep -qxF "  $c1 app change 1 (H-20260101-01)" <<<"$a" && grep -qxF "  $c2 app change 2 (H-20260101-02)" <<<"$a" && grep -qxF "  $c3 app change 3 (H-20260101-02)" <<<"$a" \
  && grep -qxF "  $c4 app change 4 (no handoff)" <<<"$a" || fail "push-check app's commits: $a"
grep -qxF "  H-20260101-01: ready" <<<"$a" && grep -qxF "  H-20260101-02: stale qa" <<<"$a" || fail "push-check app's handoffs: $a"
[[ "$(tail -1 <<<"$a")" == "  not ready: $c4 is on no handoff" ]] || fail "push-check app's end: $a"
[[ "$(tail -1 <<<"$(part good)")" == "  ready to push" ]] || fail "push-check good: $(part good)"
[[ "$(tail -1 <<<"$(part det)")" == "  not ready: detached HEAD" && "$(tail -1 <<<"$(part noup)")" == "  not ready: no upstream: nothing to compare with" \
  && "$(tail -1 <<<"$(part gone)")" == "  not ready: not on this machine" && "$(tail -1 <<<"$(part workspace)")" == "  not ready: no upstream: nothing to compare with" ]] || fail "push-check's other repos: $out"
# Once app's last commit is on the ready handoff too, its stale PASS is the first reason.
sedi "s/^- Verdict: \([a-z]*\) PASS 2026-01-02 $c1,$g1 /- Verdict: \1 PASS 2026-01-02 $c1,$g1,$c4 /" "$PC/HANDOFFS.md"
[[ "$(tail -1 <<<"$(cd "$PC" && "$F" push-check | awk '$0 ~ /^app / { on = 1 } /^[^ ]/ && $0 !~ /^app / { on = 0 } on')")" == "  not ready: $c3 is on H-20260101-02, stale qa" ]] || fail "push-check's first reason after $c4: $(cd "$PC" && "$F" push-check)"
git -C "$PC" checkout -q -- HANDOFFS.md
# JSON, the same, with the fields the docs give.
o="$(cd "$PC" && "$F" push-check --json)"
j -e --arg c1 "$c1" --arg c4 "$c4" '((a) => Object.keys(a).join() == "name,path,branch,upstream,commits,files,insertions,deletions,ready,why"
  && a.branch == "main" && a.upstream == "origin/main" && a.commits.length == 4 && a.commits[0].hash == $c4 && a.commits[0].handoffs.length == 0
  && a.commits[3].hash == $c1 && a.commits[3].handoffs[0] == "H-20260101-01" && a.commits[3].subject == "app change 1"
  && a.files == 1 && a.insertions == 4 && a.deletions == 0 && a.ready === false && a.why == $c4 + " is on no handoff")($.repos.find((r) => r.name == "app"))
  && $.repos[0].name == "workspace" && $.repos.find((r) => r.name == "good").ready === true && $.repos.find((r) => r.name == "good").why === null
  && $.repos.find((r) => r.name == "det").branch === null && $.repos.find((r) => r.name == "gone").why == "not on this machine"' <<<"$o" >/dev/null || fail "push-check --json: $o"
# Local refs only: nothing fetched, pushed or written.
[[ "$(snap)" == "$before" && ! -e "$PC/app/.git/FETCH_HEAD" ]] || fail "push-check changed refs, status or HANDOFFS.md"
# In a terminal: ready to push green, not ready red.
o="$(cd "$PC" && TERM=xterm in_tty "$F" push-check | tr -d '\r')"
grep -qF "  ${ESC}[32mready to push${ESC}[0m" <<<"$o" && grep -qF "  ${ESC}[31mnot ready${ESC}[0m: detached HEAD" <<<"$o" || fail "push-check's colors: $o"
"$F" -C "$PC" remove --yes --force >/dev/null 2>&1 || true
  return 0   # a last "check && fail" line must not end the run
}

section "way back: a change to a Hard to undo path says how to undo it before it passes" "0"
s65() {
local base id id2 id3 out r c1 c2 c3 h0 sum ent v
base="$(git -C "$W" rev-parse HEAD)"
git init -q "$W/app" && echo x > "$W/app/a.js" && git -C "$W/app" add -A && git -C "$W/app" commit -qm init
printf 'app\t-\t-\tno\n' >> "$W/repos.tsv"
# app/db/ is hard to undo; app/api/ a critical area with no check; app/api.json a contract's file.
L sub-all "$W/AGENTS.md" '/(## Hard to undo\n\n.*\n\n)- none yet/' '$1- `app/db/`'
L sub-all "$W/AGENTS.md" '/\| none yet \| \| \| \| \|/' '| api | `app/api/` | security | the requests | |'
L sub-all "$W/AGENTS.md" '/(\| Contract \| Repos that move together \| Source of truth \|\n\|---\|---\|---\|\n)\| TBD \| \| \|/' '$1| Items API | app | `app/api.json` |'
grep -qx -- '- `app/db/`' "$W/AGENTS.md" && grep -qF '| api | `app/api/` | security |' "$W/AGENTS.md" && grep -qF '| Items API | app | `app/api.json` |' "$W/AGENTS.md" || fail "test setup: way back fixture"
mkdir -p "$W/specs/qa" && echo ran > "$W/specs/qa/w.md" && git -C "$W" add -A && git -C "$W" commit -qm "way back setup"
c() { mkdir -p "$(dirname "$W/app/$2")"; echo "$1" > "$W/app/$2"; git -C "$W/app" add -A; git -C "$W/app" commit -qm "$1"; git -C "$W/app" rev-parse --short HEAD; }
c1="$(c one db/1.sql)" c2="$(c two api/x.js)" c3="$(c three api.json)"
id="$("$W/bin/handoff.sh" add --from backend --to "qa, security, code-reviewer" --changed x --needed y --evidence https://example.com/e "Migration")"; id="${id%% *}"
ent() { awk -v id="### $1:" 'index($0, id) == 1 { on = 1; print; next } /^##/ { on = 0 } on' "$W/HANDOFFS.md"; }
rec() { "$W/bin/handoff.sh" record "$1" --role "$2" "$3" --commits "$4" --note specs/qa/w.md 2>&1; }
# 1. No way back: a PASS from each reviewer is refused, naming the file and the option; nothing written.
sum="$(cksum < "$W/HANDOFFS.md")"
for r in qa security code-reviewer; do
  out="$(rec "$id" "$r" PASS "$c1")" && fail "$r passed a Hard to undo change with no way back"
  grep -q 'app/db/1.sql' <<<"$out" && grep -q -- '--way-back' <<<"$out" || fail "$r's refusal: $out"
done
[[ "$(cksum < "$W/HANDOFFS.md")" == "$sum" ]] || fail "a refused PASS changed HANDOFFS.md"
# 4. A BLOCK or CHANGES is recorded as today.
rec "$id" qa BLOCK "$c1" >/dev/null || fail "a BLOCK with no way back was refused"
rec "$id" code-reviewer CHANGES "$c1" >/dev/null || fail "a CHANGES with no way back was refused"
# 7. Only the sender adds it.
"$W/bin/handoff.sh" attach "$id" --way-back "x" --from qa >/dev/null 2>&1 && fail "attach --way-back by someone other than the sender"
# 6. Empty or more than one line: refused, nothing written, no commit.
h0="$(git -C "$W" rev-parse HEAD)" sum="$(cksum < "$W/HANDOFFS.md")"
for v in "" $'a\nb' $'a\rb' "   "; do
  "$W/bin/handoff.sh" add --from backend --to qa --changed x --needed y --way-back "$v" "Bad" >/dev/null 2>&1 && fail "add took the way back '$v'"
  "$W/bin/handoff.sh" attach "$id" --way-back "$v" --from backend >/dev/null 2>&1 && fail "attach took the way back '$v'"
done
[[ "$(cksum < "$W/HANDOFFS.md")" == "$sum" && "$(git -C "$W" rev-parse HEAD)" == "$h0" ]] || fail "a refused way back wrote or committed"
# 2. Added once, before the first verdict; the PASSes then succeed; a second replaces it.
dr() { "$W/bin/doctor.sh" 2>&1 | grep -F "$id" | grep -v 'addressed to no role' || true; }
local d0; d0="$(dr)"
"$W/bin/handoff.sh" attach "$id" --way-back "run app/db/1.down.sql" --from backend >/dev/null || fail "attach --way-back"
ent="$(ent "$id")"
[[ "$(grep -c '^- Way back:' <<<"$ent")" == 1 ]] && grep -qx -- '- Way back: run app/db/1.down.sql' <<<"$ent" \
  && (( $(grep -n '^- Way back:' <<<"$ent" | cut -d: -f1) < $(grep -n -m1 '^- Verdict:' <<<"$ent" | cut -d: -f1) )) || fail "the way back line: $ent"
for r in qa security code-reviewer; do out="$(rec "$id" "$r" PASS "$c1")" || fail "$r's PASS after the way back: $out"; done
"$W/bin/handoff.sh" attach "$id" --way-back "restore backup 42" --from backend >/dev/null || fail "attach --way-back again"
ent="$(ent "$id")"
[[ "$(grep -c '^- Way back:' <<<"$ent")" == 1 ]] && grep -qx -- '- Way back: restore backup 42' <<<"$ent" || fail "the second way back did not replace the first: $ent"
"$W/bin/handoff.sh" list --json | j -e --arg id "$id" '$.some((e) => e.id == $id && e.ready === true)' >/dev/null || fail "list --json lost the entry or its readiness: $("$W/bin/handoff.sh" list --json)"
[[ "$(dr)" == "$d0" ]] || fail "the doctor reports something new on the entry with a way back: $(dr)"
# 3. add --way-back.
id2="$("$W/bin/handoff.sh" add --from backend --to qa --changed x --needed y --way-back "restore backup 42" "Filed with one")"; id2="${id2%% *}"
[[ "$(ent "$id2" | grep -c '^- Way back:')" == 1 ]] && ent "$id2" | grep -qx -- '- Way back: restore backup 42' || fail "add --way-back: $(ent "$id2")"
# 5, 9, 10. No Hard to undo path: a PASS without the line, on a critical area's file, a contract's file, or --commits none.
id3="$("$W/bin/handoff.sh" add --from backend --to "qa, security" --changed x --needed y --evidence https://example.com/e "Api")"; id3="${id3%% *}"
out="$(rec "$id3" security PASS "$c2")" || fail "a PASS on a critical area's file needed a way back: $out"
out="$(rec "$id3" qa PASS "$c3")" || fail "a PASS on a contract's file needed a way back: $out"
id3="$("$W/bin/handoff.sh" add --from product-manager --to security --changed copy --needed y "Copy")"; id3="${id3%% *}"
out="$(rec "$id3" security PASS none)" || fail "a PASS with --commits none needed a way back: $out"
# 8. The rules and docs.
grep -q 'Way back:' "$KIT/roles/chief-of-staff.md" && grep -q -- '--way-back' "$KIT/core/rules/builders.md" && grep -q 'Way back:' "$KIT/core/rules/reviews.md" \
  && grep -q -- '--way-back' "$KIT/docs/commands.md" && grep -q -- '--way-back' "$KIT/CHANGELOG.md" || fail "a way-back rule or doc is missing"
git -C "$W" reset -q --hard "$base"; rm -rf "$W/app" "$W/specs/qa"
  return 0   # a last "check && fail" line must not end the run
}

section "model choice: a model for every run, checked first, never with a paid run" ""
s66() {
local MW="$T/model" MF="$T/mfakes" ML="$T/model-calls.log" ML2="$HOME/$LOGS/model" r mm P AS out st id n v f before
mkdir -p "$MF"
# One fake for every built-in tool: it logs each call as "<tool> [arg] [arg]...", prints its model list
# (m-1 and other, each in the tool's own format; exit 1 with MFAIL), and answers a run with {}.
cat > "$MF/fake" <<'FAKE'
#!/bin/bash
n="${0##*/}"
{ printf '%s' "$n"; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$MLOG"
case "$n $*" in
  "codex debug models"|"agy models"|"grok models"|"opencode models"|"cursor-agent models") pwd -P >> "$MLOG.cwd"; [[ -z "${MFAIL:-}" ]] || exit 1 ;;
esac
case "$n $*" in
  "codex debug models") echo '{"models":[{"slug":"m-1"},{"slug":"other"}]}' ;;
  "agy models") printf 'Fetching available models...\nm-1\tM One\nother\tOther\n' ;;
  "grok models") printf 'Default model: m-1\n\nAvailable models:\n  * m-1 (default)\n  - other\n' ;;
  "opencode models") printf 'm-1\nother\n' ;;
  "cursor-agent models") printf 'Available models\n\nm-1 - M One\nother - Other\n' ;;
  *" --version") echo "$n 1.0" ;;
  *) echo '{}' ;;
esac
FAKE
chmod +x "$MF/fake"
for r in claude codex agy qwen grok opencode cursor-agent; do ln -sf fake "$MF/$r"; done
m() { PATH="$MF:$PATH" MLOG="$ML" "$@"; }
# runs: the calls that are not a version or a model list (nor the doctor's guardrail reads); lists: model-list calls.
runs() { grep -v -e ' \[--version\]$' -e '^codex \[debug\] \[models\]$' -e '^\(agy\|grok\|opencode\|cursor-agent\) \[models\]$' -e '^codex \[execpolicy\]' -e '^opencode \[debug\] \[agent\] \[build\]$' -e '^grok \[inspect\] \[--json\]$' "$ML" 2>/dev/null || true; }
lists() { grep -c -e '^codex \[debug\] \[models\]$' -e '^\(agy\|grok\|opencode\|cursor-agent\) \[models\]$' "$ML" 2>/dev/null || true; }
envline() { { grep -v "^$1=" "$MW/cabinet.env"; printf '%s\n' "$2"; } > "$T/m.env"; mv "$T/m.env" "$MW/cabinet.env"; }
mres() { m "$F" -C "$MW" doctor --json | j -r --arg id "$1" '$.results.filter((r) => r.id == $id).map((r) => r.level + " " + r.message).join("\n")'; }
: > "$ML"
m "$F" new "$MW" --yes --runner claude >/dev/null || fail "new for model choice"
grep -qx 'CABINET_MODEL=""' "$MW/cabinet.env" || fail "new did not write an empty CABINET_MODEL"
[[ -z "$(runs)" && "$(lists)" == 0 ]] || fail "new with no model called a tool: $(cat "$ML")"
sedi 's/^QUIET_DAYS=.*/QUIET_DAYS="0"/' "$MW/jobs/brief.job"
P="$(PROMPT=""; source "$MW/jobs/brief.job"; printf '%s' "$PROMPT")"
AS="Act as the chief-of-staff role: read agents/chief-of-staff.md and follow it as your instructions. $P"
# exp <runner> <model>: the call run_agent makes; with no model, exactly the one it made before.
exp() {
  local mo=""; [[ -z "$2" ]] || mo=" [--model] [$2]"
  case "$1" in
    claude) echo "claude [-p] [--agent] [chief-of-staff] [--permission-mode] [auto] [--output-format] [json]$mo [$P]" ;;
    codex) echo "codex [exec] [--json]$mo [$AS]" ;;
    antigravity) echo "agy$mo [-p] [$AS] [--output-format] [json] [--dangerously-skip-permissions]" ;;
    qwen) echo "qwen [--approval-mode] [auto] [-o] [json]$mo [$AS]" ;;
    grok) echo "grok$mo [-p] [$AS] [--permission-mode] [auto] [--output-format] [json]" ;;
    opencode) echo "opencode [run] [--format] [json]$mo [$AS]" ;;
    cursor) echo "cursor-agent [-p] [--force] [--output-format] [json]$mo [$AS]" ;;
  esac
}
# 1, 4. Every built-in runner: today's call with no model, the model through --model with one.
for r in claude codex antigravity qwen grok opencode cursor; do
  envline CABINET_RUNNER "CABINET_RUNNER=\"$r\""
  for mm in "" m-1; do
    envline CABINET_MODEL "CABINET_MODEL=\"$mm\""; : > "$ML"
    m "$F" -C "$MW" job run brief >/dev/null 2>&1 || fail "job run brief with $r and the model '$mm'"
    [[ "$(runs)" == "$(exp "$r" "$mm")" ]] || fail "$r with the model '$mm' got: $(runs) -- expected: $(exp "$r" "$mm")"
  done
done
envline CABINET_RUNNER 'CABINET_RUNNER="custom"'; envline CABINET_RUNNER_CMD "CABINET_RUNNER_CMD='printf %s \"\$CABINET_MODEL\" > model.out'"
m "$F" -C "$MW" job run brief >/dev/null 2>&1 && [[ "$(cat "$MW/model.out")" == m-1 ]] || fail "custom did not get CABINET_MODEL=m-1: $(cat "$MW/model.out" 2>/dev/null)"
envline CABINET_RUNNER 'CABINET_RUNNER="claude"'; envline CABINET_RUNNER_CMD 'CABINET_RUNNER_CMD=""'
# 5. A job's MODEL wins for that job only.
printf 'AGENT=qa\nPROMPT="p"\nQUIET_DAYS="0"\nMODEL="m-2"\n' > "$MW/jobs/t.job"
: > "$ML"; m "$F" -C "$MW" job run t >/dev/null 2>&1; m "$F" -C "$MW" job run brief >/dev/null 2>&1
grep -q '^claude \[-p\] \[--agent\] \[qa\] .* \[--model\] \[m-2\] \[p\]$' <<<"$(runs)" && grep -q '^claude \[-p\] \[--agent\] \[chief-of-staff\] .* \[--model\] \[m-1\] ' <<<"$(runs)" || fail "a job's MODEL: $(runs)"
# 6. A bad MODEL in a job: no run, no file pwned, and the job log names the file and the value.
for v in "'x;touch pwned'" '"--yolo"'; do
  printf 'AGENT=qa\nPROMPT="p"\nQUIET_DAYS="0"\nMODEL=%s\n' "$v" > "$MW/jobs/t.job"; : > "$ML"; : > "$ML2/t.log"
  (cd "$T" && m "$F" -C "$MW" job run t >/dev/null 2>&1) && fail "job run took MODEL=$v"
  [[ -z "$(runs)" && ! -e "$MW/pwned" && ! -e "$T/pwned" ]] || fail "a bad MODEL=$v started a run or ran code: $(runs)"
  v="${v:1:${#v}-2}"; grep -qF "the model '$v' in jobs/t.job is not a model name" "$ML2/t.log" || fail "the job log does not name jobs/t.job and $v: $(tail -3 "$ML2/t.log")"
done
# 13 (a job). The doctor: model.name, no run, no list call for it (no other model is set).
envline CABINET_MODEL 'CABINET_MODEL=""'; envline CABINET_RUNNER 'CABINET_RUNNER="codex"'; : > "$ML"
out="$(mres model.name)"; grep -qF "fix the model '--yolo' in jobs/t.job is not a model name" <<<"$out" || fail "doctor model.name for a job: $out"
[[ -z "$(runs)" && "$(lists)" == 0 ]] || fail "the doctor ran a tool for a bad job MODEL: $(cat "$ML")"
printf 'AGENT=qa\nPROMPT="p"\nQUIET_DAYS="0"\n' > "$MW/jobs/t.job"
# 7, 18. A tool that lists its models: ok, a problem for one it does not list, a note when the list fails.
envline CABINET_MODEL 'CABINET_MODEL="m-1"'; : > "$ML"
grep -qx "ok m-1 (cabinet.env) is one of codex's models" <<<"$(mres model.exists)" || fail "model.exists ok: $(mres model.exists)"
envline CABINET_MODEL 'CABINET_MODEL="m-9"'
grep -qx "fix m-9 in cabinet.env is not in codex's model list (codex debug models): fix the name (cabinet config --model <name>|off)" <<<"$(mres model.exists)" || fail "model.exists for m-9: $(mres model.exists)"
out="$(MFAIL=1 mres model.exists)"; grep -q "^note not checked: codex's model list could not be read" <<<"$out" || fail "model.exists when the list fails: $out"
# 11. Only version and list calls, never a run.
[[ -z "$(runs)" ]] || fail "the doctor started a run: $(runs)"
# 8, 16. A tool with no free list, and custom: a note.
for r in claude qwen; do
  envline CABINET_RUNNER "CABINET_RUNNER=\"$r\""; : > "$ML"
  grep -qx "note not checked: $r cannot list its models without a run (m-9 in cabinet.env)" <<<"$(mres model.exists)" || fail "model.exists with $r: $(mres model.exists)"
  [[ -z "$(runs)" && "$(lists)" == 0 ]] || fail "the doctor called $r: $(cat "$ML")"
done
envline CABINET_RUNNER 'CABINET_RUNNER="custom"'; envline CABINET_RUNNER_CMD "CABINET_RUNNER_CMD='true'"
grep -q '^note not checked: the custom runner cannot list its models without a run' <<<"$(mres model.exists)" || fail "model.exists with custom: $(mres model.exists)"
envline CABINET_RUNNER 'CABINET_RUNNER="claude"'; envline CABINET_RUNNER_CMD 'CABINET_RUNNER_CMD=""'; envline CABINET_MODEL 'CABINET_MODEL=""'
printf 'model.out\n' >> "$MW/.git/info/exclude"; git -C "$MW" add -A && git -C "$MW" commit -qm "model test settings"
# 2, 3, 17. config --model: written, off, refused, and checked against the tool's list.
cfgm() { (cd "$MW" && m "$F" config --yes "$@" 2>&1); }
cfgm --model m-1 >/dev/null && grep -qx 'CABINET_MODEL="m-1"' "$MW/cabinet.env" || fail "config --model m-1"
cfgm --model off >/dev/null && grep -qx 'CABINET_MODEL=""' "$MW/cabinet.env" || fail "config --model off"
cp "$MW/cabinet.env" "$T/m.keep"
for v in 'a b' 'x;y' '$(id)' -x "$(printf 'a%.0s' $(seq 101))"; do
  st=0; cfgm --model "$v" >/dev/null || st=$?
  ((st)) && cmp -s "$T/m.keep" "$MW/cabinet.env" || fail "config took the model '$v'"
done
v="$(printf 'a%.0s' $(seq 100))"; cfgm --model "$v" >/dev/null && grep -qx "CABINET_MODEL=\"$v\"" "$MW/cabinet.env" || fail "config refused a 100-character model"
cfgm --runner codex --model off >/dev/null
: > "$ML"; out="$(cfgm --model m-9)" || fail "config --model m-9 with codex: $out"
grep -qx 'CABINET_MODEL="m-9"' "$MW/cabinet.env" && grep -qF "Model m-9: not in codex's model list (codex debug models)" <<<"$out" || fail "config --model m-9: $out"
cfgm --runner claude >/dev/null; out="$(cfgm --runner codex)"; grep -qF "Model m-9: not in codex's model list" <<<"$out" || fail "config --runner codex with m-9 set: $out"
[[ -z "$(runs)" ]] || fail "config started a run: $(runs)"
cfgm --runner claude --model off >/dev/null
# 19. A carried value is checked before config writes it back.
envline CABINET_MODEL "CABINET_MODEL='\$(touch pwned)'"; cp "$MW/cabinet.env" "$T/m.keep"
st=0; out="$(cfgm --runner codex)" || st=$?
((st)) && grep -qF "CABINET_MODEL is '\$(touch pwned)'" <<<"$out" && grep -qF 'cabinet config --model off' <<<"$out" && cmp -s "$T/m.keep" "$MW/cabinet.env" || fail "config wrote back a carried bad model (exit $st): $out"
m "$F" -C "$MW" doctor >/dev/null 2>&1 || true
[[ ! -e "$MW/pwned" && ! -e "$T/pwned" ]] || fail "a carried model ran as code"
# 9, 12. role draft, handoff run and spec run pass the model, and refuse a bad one before any run.
envline CABINET_MODEL 'CABINET_MODEL=""'
git init -q "$MW/app" && echo x > "$MW/app/a" && git -C "$MW/app" add -A && git -C "$MW/app" commit -qm init
printf 'app\t-\t-\tno\n' >> "$MW/repos.tsv"; L before "$MW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `app` | The API | backend |'
printf -- '---\nfeature: s\nstatus: ready\nrepos: [app]\n---\n\n# S\n\n## Rules\n\nOne.\n\n## Acceptance criteria\n\n- One works.\n\n## Decisions\n\n| # | Question | Options | Recommendation | Owner answer (date) |\n|---|---|---|---|---|\n\n## Plan\n\nLater.\n\n## Reviews\n' > "$MW/specs/s.md"
mkdir -p "$MW/specs/qa"; echo ok > "$MW/specs/qa/s.md"; git -C "$MW" add -A && git -C "$MW" commit -qm "a spec and a repo"
"$MW/bin/spec.sh" record specs/s.md --role qa PASS --note specs/qa/s.md >/dev/null && "$MW/bin/spec.sh" check specs/s.md >/dev/null || fail "test setup: a ready spec: $("$MW/bin/spec.sh" check specs/s.md)"
(cd "$MW" && "$F" role add growth --yes) >/dev/null || fail "test setup: role add"
id="$("$MW/bin/handoff.sh" add --from chief-of-staff --to app --small --changed x --needed y "Work")"; id="${id%% *}"
three() {   # role draft, handoff run and spec run, each started once
  (cd "$MW" && m "$F" role draft growth) >/dev/null 2>&1 || true; m "$F" -C "$MW" handoff run "$id" >/dev/null 2>&1 || true; m "$F" -C "$MW" spec run specs/s.md >/dev/null 2>&1 || true
}
envline CABINET_MODEL 'CABINET_MODEL="m-1"'; : > "$ML"; three
[[ "$(runs | grep -c '^claude .*\[--model\] \[m-1\] ')" == 3 && "$(runs | wc -l | tr -d ' ')" == 3 ]] || fail "role draft, handoff run, spec run with m-1: $(runs)"
for v in --yolo 'x;y'; do
  envline CABINET_MODEL "CABINET_MODEL=\"$v\""; : > "$ML"; : > "$ML2/run-$id.log"; : > "$ML2/run-s.log"; : > "$ML2/brief.log"
  out="$( (cd "$MW" && m "$F" role draft growth) 2>&1)" && fail "role draft took CABINET_MODEL=$v"
  st=0; m "$F" -C "$MW" handoff run "$id" >/dev/null 2>&1 || st=$?; ((st)) || fail "handoff run took CABINET_MODEL=$v"
  st=0; m "$F" -C "$MW" spec run specs/s.md >/dev/null 2>&1 || st=$?; ((st)) || fail "spec run took CABINET_MODEL=$v"
  st=0; m "$F" -C "$MW" job run brief >/dev/null 2>&1 || st=$?; ((st)) || fail "job run brief took CABINET_MODEL=$v"
  [[ -z "$(runs)" ]] || fail "CABINET_MODEL=$v started a run: $(runs)"
  for f in "$ML2/run-$id.log" "$ML2/run-s.log" "$ML2/brief.log"; do
    grep -qF "the model '$v' in cabinet.env is not a model name" "$f" || fail "$f does not name cabinet.env and $v: $(tail -3 "$f")"
  done
  grep -qF "the model '$v' in cabinet.env is not a model name" <<<"$out" || fail "role draft does not name cabinet.env and $v: $out"
  envline CABINET_RUNNER 'CABINET_RUNNER="custom"'; envline CABINET_RUNNER_CMD "CABINET_RUNNER_CMD='touch marker'"
  m "$F" -C "$MW" job run brief >/dev/null 2>&1 && fail "custom took CABINET_MODEL=$v"
  [[ ! -e "$MW/marker" ]] || fail "custom ran with CABINET_MODEL=$v"
  envline CABINET_RUNNER 'CABINET_RUNNER="claude"'; envline CABINET_RUNNER_CMD 'CABINET_RUNNER_CMD=""'
  # 13 (cabinet.env).
  : > "$ML"; grep -qF "fix the model '$v' in cabinet.env is not a model name" <<<"$(mres model.name)" && [[ "$(lists)" == 0 && -z "$(runs)" ]] || fail "doctor model.name for $v: $(mres model.name) $(cat "$ML")"
done
# 20. MODEL from the environment never applies, in any kind of run.
for mm in "" m-1; do
  envline CABINET_MODEL "CABINET_MODEL=\"$mm\""; : > "$ML"
  MODEL=-x three; MODEL=-x m "$F" -C "$MW" job run t >/dev/null 2>&1 || true
  n="$(runs | wc -l | tr -d ' ')"
  if [[ -z "$mm" ]]; then ((n == 4)) && ! runs | grep -q -- '--model' || fail "MODEL=-x from the environment reached a run: $(runs)"
  else ((n == 4)) && [[ "$(runs | grep -c '\[--model\] \[m-1\] ')" == 4 ]] && ! runs | grep -q -- '\[-x\]' || fail "MODEL=-x with m-1: $(runs)"; fi
done
printf 'COMMAND="true"\nMODEL="m-1"\n' > "$MW/jobs/c.job"
out="$(m "$F" -C "$MW" job run c 2>&1)" && fail "a COMMAND job with MODEL ran"
grep -qF 'jobs/c.job sets MODEL, but it runs COMMAND' <<<"$out" || fail "the COMMAND job's refusal: $out"
# 14. new and init.
m "$F" new "$T/model-n1" --yes --model m-1 >/dev/null && grep -qx 'CABINET_MODEL="m-1"' "$T/model-n1/cabinet.env" || fail "new --model m-1"
m "$F" new "$T/model-n2" --yes --model 'x;y' >/dev/null 2>&1 && fail "new took the model x;y"
[[ ! -e "$T/model-n2" ]] || fail "new with a bad model left a folder"
mkdir -p "$T/model-p"; echo x > "$T/model-p/f"; git -C "$T/model-p" init -q; before="$(ls -A "$T/model-p")"
(cd "$T/model-p" && m "$F" init --yes --model 'x;y') >/dev/null 2>&1 && fail "init took the model x;y"
[[ "$(ls -A "$T/model-p")" == "$before" ]] || fail "init with a bad model wrote files: $(ls -A "$T/model-p")"
# A model list runs in the log folder, never in the project just set up (security S1).
mkdir -p "$T/model-p2"; echo x > "$T/model-p2/f"; git -C "$T/model-p2" init -q; rm -f "$ML.cwd"
(cd "$T/model-p2" && m "$F" init --yes --runner codex --model m-1) >/dev/null 2>&1 || fail "init --model m-1"
[[ -s "$ML.cwd" ]] && ! grep -q "^$(cd "$T/model-p2" && pwd -P)" "$ML.cwd" || fail "a model list ran in the project: $(cat "$ML.cwd" 2>/dev/null)"
"$F" -C "$T/model-p2" remove --yes --force >/dev/null 2>&1 || true
# 15. The setup question, right after the runner's: Enter, a name, and a refused name then a good one.
q() { printf '%s\n' "Mq" "$T/$1" "" "" "" "" "" "" "" "" "" "" "" "" claude "${@:2}" "" "" "" "" "" "" "" "" y n n > "$T/m-answers"; CABINET_TTY="$T/m-answers" m "$F" new 2>&1; }
q model-q1 "" >/dev/null; grep -qx 'CABINET_MODEL=""' "$T/model-q1/cabinet.env" || fail "the model question: Enter"
q model-q2 m-1 >/dev/null; grep -qx 'CABINET_MODEL="m-1"' "$T/model-q2/cabinet.env" || fail "the model question: m-1"
out="$(q model-q3 'x;y' m-1)"; grep -qx 'CABINET_MODEL="m-1"' "$T/model-q3/cabinet.env" && grep -qF "'x;y' is not a model name" <<<"$out" || fail "the model question: x;y then m-1: $out"
# 10. The docs.
grep -q -- '--model' "$KIT/docs/commands.md" && grep -q 'MODEL=' "$KIT/docs/commands.md" && grep -q 'model\.exists' "$KIT/docs/troubleshooting.md" && grep -q 'model\.name' "$KIT/docs/troubleshooting.md" \
  && grep -q '^# MODEL:' "$KIT/templates/workspace/jobs/brief.job" && grep -q -- '--model' "$KIT/CHANGELOG.md" && grep -qF '| `codex` (Codex 0.165.0) | `--model` | `codex debug models`' "$KIT/docs/agent-setup.md" || fail "a model-choice doc is missing"
for f in "$MW" "$T/model-n1" "$T/model-q1" "$T/model-q2" "$T/model-q3"; do "$F" -C "$f" remove --yes --force >/dev/null 2>&1 || true; done
  return 0   # a last "check && fail" line must not end the run
}

section "release notice: a newer Cabinet is said in next, status and the doctor, asked once a day" ""
s67() {
# Its own HOME, the notice on (the rest of the suite runs with it off), and a fake npm first on PATH
# before the first command: no request ever reaches the registry. Restored at the end.
local oh="$HOME" og="$GIT_CONFIG_GLOBAL" NP="$T/rn-npm" NL="$T/rn-npm.log" RW="$T/rn-ws" LR V c i o p q st t0 off on pid ppid cmd SP SPH
export HOME="$T/rn-home" GIT_CONFIG_GLOBAL="$T/rn-home/.gitconfig"; unset CABINET_UPDATE_CHECK NO_UPDATE_NOTIFIER CI
mkdir -p "$HOME" "$NP"; printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$GIT_CONFIG_GLOBAL"
LR="$HOME/$LOGS"
# The fake npm: logs "<arguments>|<folder>", writes its PID and its parent's, sleeps $NP/sleep seconds,
# fails when $NP/fail exists, else prints $NP/answer as it is.
cat > "$NP/npm" <<'FAKE'
#!/bin/bash
d="$(dirname "$0")"
printf '%s|%s\n' "$*" "$(pwd -P)" >> "$d/../rn-npm.log"
echo "$$ $PPID" > "$d/pid"
[[ -s "$d/sleep" ]] && sleep "$(cat "$d/sleep")"
[[ -e "$d/fail" ]] && exit 1
cat "$d/answer"
FAKE
chmod +x "$NP/npm"; printf '9.9.9\n' > "$NP/answer"
export PATH="$NP:$KIT/bin:$PATH"   # the fake npm, and the kit as the cabinet command, for this section only
V="$(j -r '$.version' "$KIT/package.json")"
"$F" new "$RW" --yes >/dev/null || fail "new for the release notice"
RW="$(cd "$RW" && pwd -P)"; LR="$(cd "$LR" && pwd -P)"
calls() { if [[ -f "$NL" ]]; then wc -l < "$NL" | tr -d ' '; else echo 0; fi; }
clean() { rm -f "$LR/latest-version" "$NL" "$NP/pid"; rmdir "$LR/latest-version.lock" 2>/dev/null || true; }
put() { clean; printf '%s' "$1" > "$LR/latest-version"; }
# age <seconds> <file>: the file (not a link it is) last changed that long ago, counted in seconds, so a
# clock change, as on a night the clock goes back, moves nothing.
age() { node -e 'const t = Date.now() / 1000 - process.argv[1]; require("fs").lutimesSync(process.argv[2], t, t)' "$@"; }
stale() { age $((25 * 3600)) "$LR/latest-version"; }
# settled: the background check has started and ended (no lock), at most 10 seconds.
settle() { sleep 0.5; local n; for n in $(seq 36); do [[ -e "$LR/latest-version.lock" ]] || return 0; sleep 0.25; done; }
# out <command>: the output and exit code of next, status or bin/doctor.sh in the workspace.
out() { local st=0 o; if [[ "$1" == doctor ]]; then o="$(cd "$RW" && bin/doctor.sh 2>&1)" || st=$?; else o="$("$F" -C "$RW" $1 2>&1)" || st=$?; fi; printf '%s\nexit %s\n' "$o" "$st"; }
offout() { CABINET_UPDATE_CHECK=off out "$1"; }
# offx: the off exit codes of next, status and the doctor, read once for the workspace as it stands.
offx() { OX_next="$(offout next | tail -1)" OX_status="$(offout status | tail -1)" OX_doctor="$(offout doctor | tail -1)"; }
same() { local v="OX_$1"; [[ "$(tail -1 <<<"$2")" == "${!v}" ]]; }
notice() { grep -q 'is out\|^latest: cabinet' <<<"$1"; }
# 13. The suite runs with the notice off.
grep -qx 'export CABINET_UPDATE_CHECK=off' "$KIT/test/smoke.sh" || fail "the suite does not turn the release notice off"
# 1. The first check: one request, from Cabinet's own folder, one line written, nothing left behind.
clean; "$F" -C "$RW" next >/dev/null; settle
[[ "$(cat "$LR/latest-version")" == 9.9.9 ]] || fail "the first check did not write 9.9.9: $(cat "$LR/latest-version" 2>&1)"
[[ "$(cat "$NL")" == "view @tarekraafat/cabinet version --no-update-notifier|$LR" ]] || fail "the request: $(cat "$NL")"
[[ "$(cd "$LR" && find . -maxdepth 1 -type f)" == ./latest-version && ! -e "$LR/latest-version.lock" ]] || fail "the check left files: $(ls -A "$LR")"
# 2. The notice, and one command everywhere: pinned, no pin, only the workspace behind, a shared inside workspace.
four() {   # four <workspace> <command> [<folder named>]
  local w=$1 cmd=$2 at="${3:-}" o
  "$F" -C "$w" outdated --json | j -e --arg c "$cmd" '$.command == $c' >/dev/null || fail "outdated --json in $w: $("$F" -C "$w" outdated --json)"
  "$F" -C "$w" next --json | j -e --arg c "$cmd" '$.steps.some((s) => s.id == "update" && s.command == $c)' >/dev/null || fail "next --json in $w: $("$F" -C "$w" next --json)"
  o="$("$F" -C "$w" status)"; grep -qx "latest: cabinet $(cat "$LR/latest-version")" <<<"$o" && grep -qF "$cmd" <<<"$o" || fail "status in $w: $o"
  "$F" -C "$w" status --json | j -e --arg l "$(cat "$LR/latest-version")" '$.latest == $l' >/dev/null || fail "status --json in $w"
  st=0; o="$( (cd "$w" && bin/doctor.sh --json) )" || st=$?
  j -e --arg c "$cmd" --arg l "$(cat "$LR/latest-version")" --arg v "$(cat "$w/.cabinet/version")" \
    '$.results.some((r) => r.id == "kit.newer" && r.level == "note" && r.message.includes($l) && r.message.includes($v) && r.message.includes($c))' <<<"$o" >/dev/null || fail "doctor kit.newer in $w: $(j -r '$.results.filter((r) => r.id.startsWith("kit")).map((r) => r.message).join("; ")' <<<"$o")"
  [[ "$(j -r '$.problems' <<<"$o") $st" == "$( (cd "$w" && CABINET_UPDATE_CHECK=off bin/doctor.sh --json) | j -r '$.problems') $( (cd "$w" && CABINET_UPDATE_CHECK=off bin/doctor.sh --json >/dev/null); echo $?)" ]] || fail "the note changed the doctor's problems or exit code in $w"
  if [[ -n "$at" ]]; then
    "$F" -C "$w" next | grep -qF "Run it in $at." && (cd "$w" && bin/doctor.sh) | grep -qF "(in $at)" || fail "next or the doctor does not name $at"
  fi
}
put 9.9.9; four "$RW" "npm install @tarekraafat/cabinet@latest && cabinet update"
cp "$RW/package.json" "$T/rn-pkg"; j '({...$, devDependencies: {}})' "$T/rn-pkg" > "$RW/package.json"
four "$RW" "npm i -g @tarekraafat/cabinet@latest && cabinet update"
cp "$T/rn-pkg" "$RW/package.json"
put "$V"; printf '0.0.1\n' > "$RW/.cabinet/version"; printf '%s\n' "$V" > "$NP/answer"
four "$RW" "cabinet update"
printf '%s\n' "$V" > "$RW/.cabinet/version"; printf '9.9.9\n' > "$NP/answer"
SP="$T/rn-proj"; mkdir -p "$SP"; git -C "$SP" init -q; printf '{"name": "p", "devDependencies": {"@tarekraafat/cabinet": "^%s"}}\n' "$V" > "$SP/package.json"
(cd "$SP" && "$F" init --inside --shared --yes) >/dev/null 2>&1 || fail "init --inside --shared for the notice"
SPH="$(cd "$SP" && pwd -P)"; put 9.9.9
four "$SP/cabinet" "npm install @tarekraafat/cabinet@latest && cabinet update" "$SPH"
# 3. Never waits: with npm hanging, each command returns in its off time (plus 5 seconds), with its off output.
echo 60 > "$NP/sleep"
for c in next status doctor; do
  clean; t0=$SECONDS; off="$(offout $c)"; t0=$((SECONDS - t0))
  i=$SECONDS; on="$(out $c)"; i=$((SECONDS - i))
  [[ "$on" == "$off" ]] || fail "$c with a hanging check printed something else: $(diff <(echo "$off") <(echo "$on"))"
  ((i <= t0 + 5)) || fail "$c waited for the check: $i s against $t0 s"
  for q in $(seq 40); do [[ -s "$NP/pid" ]] && break; sleep 0.25; done
  read -r pid ppid < "$NP/pid"; kill -0 "$pid" 2>/dev/null || fail "$c: the check had ended when it returned"
  kill "$pid" 2>/dev/null; settle
done
# 4. The background check stops itself at 30 seconds and leaves nothing.
put 1.0.0; printf '\n' >> "$LR/latest-version"; stale; "$F" -C "$RW" next >/dev/null
for q in $(seq 40); do [[ -s "$NP/pid" ]] && break; sleep 0.25; done; read -r pid ppid < "$NP/pid"
for q in $(seq 160); do kill -0 "$pid" 2>/dev/null || kill -0 "$ppid" 2>/dev/null || [[ -n "$(pgrep -P "$ppid")" ]] || break; sleep 0.25; done
kill -0 "$pid" 2>/dev/null || kill -0 "$ppid" 2>/dev/null || [[ -n "$(pgrep -P "$ppid")" ]] && fail "the check or its npm still runs after 40 seconds"
[[ "$(cat "$LR/latest-version")" == 1.0.0 ]] && [[ -z "$(cd "$LR" && find . -maxdepth 1 -name '.latest-version.*')" && ! -e "$LR/latest-version.lock" ]] || fail "a stopped check left: $(ls -A "$LR")"
: > "$NP/sleep"
# 5. Offline: the off output; a seen version kept; and no npm at all.
touch "$NP/fail"
for c in next status doctor; do clean; [[ "$(out $c)" == "$(offout $c)" ]] || fail "$c offline differs from off"; done
put 9.9.9; stale; "$F" -C "$RW" next >/dev/null; settle; [[ "$(cat "$LR/latest-version")" == 9.9.9 ]] || fail "a failed check lost the version seen"
mkdir -p "$T/rn-nonpm"; for p in $(printf '%s' "$PATH" | tr ':' ' '); do [[ "$p" == "$NP" || ! -d "$p" ]] || ln -s "$p"/* "$T/rn-nonpm/" 2>/dev/null || true; done
rm -f "$T/rn-nonpm/npm" "$T/rn-nonpm/npx"
for c in next status doctor; do clean; [[ "$(PATH="$T/rn-nonpm" out $c)" == "$(PATH="$T/rn-nonpm" offout $c)" ]] || fail "$c with no npm differs from off"; done
rm -f "$NP/fail"
# 6. Once a day, one check at a time, a stale lock taken over.
put 9.9.9; stale; "$F" -C "$RW" next >/dev/null; "$F" -C "$RW" next >/dev/null; settle; [[ "$(calls)" == 1 ]] || fail "two runs with a stale file made $(calls) calls"
put 9.9.9; age $((23 * 3600)) "$LR/latest-version"; "$F" -C "$RW" next >/dev/null; settle; [[ "$(calls)" == 0 ]] || fail "a file 23 hours old was checked"
put 9.9.9; stale; "$F" -C "$RW" next >/dev/null; settle; [[ "$(calls)" == 1 ]] || fail "a stale file: $(calls) calls"
for i in 1 2 3 4 5; do
  clean; "$F" -C "$RW" next >/dev/null & p=$!; "$F" -C "$RW" next >/dev/null & q=$!; wait "$p" "$q" || true; settle
  [[ "$(calls)" == 1 ]] || fail "two commands at once, round $i: $(calls) calls"
done
put 9.9.9; stale; mkdir "$LR/latest-version.lock"
age 120 "$LR/latest-version.lock"
"$F" -C "$RW" next >/dev/null; settle; "$F" -C "$RW" next >/dev/null; settle
[[ "$(calls)" == 1 && ! -e "$LR/latest-version.lock" ]] || fail "a stale lock: $(calls) calls, $(ls -A "$LR")"
# 7. Not newer: nothing (the doctor's text holds kit.newer's message when it has one).
for v in "$V" 0.0.1; do
  put "$v"; for c in next status doctor; do notice "$(out $c)" && fail "$c named $v, which is not newer"; done
done
offx
# 8. Only a version is believed: in the file, from npm, in .cabinet/version; and a folder or a link in its place.
for v in '1.2.3; touch pwned' '$(touch pwned)' '' $'9.9.9\nx' 1.0.0-beta.1 08.0.0 12345678901234567890.0.0; do
  put "$v"
  for c in next status doctor; do o="$(out $c)"; notice "$o" && fail "$c believed '$v'"; same $c "$o" || fail "$c exit with '$v'"; done
  put 1.0.0; stale; printf '%s\n' "$v" > "$NP/answer"; "$F" -C "$RW" status >/dev/null; settle
  [[ "$(cat "$LR/latest-version")" == 1.0.0 ]] || fail "npm's '$v' was written: $(cat "$LR/latest-version")"
done
printf '9.9.9\n' > "$NP/answer"
for v in '0.1.0$(touch pwned)' $'0.1.0\033[31m'; do
  put 9.9.9; printf '%s\n' "$v" > "$RW/.cabinet/version"
  for c in next status doctor; do notice "$(out $c)" && fail "$c with the workspace version '$v'"; done
done
printf '%s\n' "$V" > "$RW/.cabinet/version"
mkdir -p "$T/rn-elsewhere"; printf '9.9.9\n' > "$T/rn-elsewhere/target"
touch "$NP/fail"
clean; mkdir "$LR/latest-version"
for c in next status doctor; do o="$(out $c)"; notice "$o" && fail "$c with a folder"; same $c "$o" || fail "$c exit with a folder"; done
rmdir "$LR/latest-version"; ln -s "$T/rn-elsewhere/target" "$LR/latest-version"
for c in next status doctor; do o="$(out $c)"; notice "$o" && fail "$c through a link"; same $c "$o" || fail "$c exit through a link"; done
settle; rm -f "$NP/fail"
clean; mkdir "$LR/latest-version"; age $((25 * 3600)) "$LR/latest-version"; "$F" -C "$RW" next >/dev/null; settle
[[ "$(calls)" == 0 && -z "$(ls -A "$LR/latest-version")" ]] || fail "a folder in its place was checked or written into"
rmdir "$LR/latest-version"
q="$(ls -lT "$T/rn-elsewhere/target" 2>/dev/null || ls -l --time-style=full-iso "$T/rn-elsewhere/target")"
clean; ln -s "$T/rn-elsewhere/target" "$LR/latest-version"; "$F" -C "$RW" next >/dev/null; settle
[[ "$(cat "$T/rn-elsewhere/target")" == 9.9.9 && "$(ls -A "$T/rn-elsewhere")" == target && "$q" == "$(ls -lT "$T/rn-elsewhere/target" 2>/dev/null || ls -l --time-style=full-iso "$T/rn-elsewhere/target")" ]] || fail "the link's target changed"
[[ -f "$LR/latest-version" && ! -L "$LR/latest-version" && "$(cat "$LR/latest-version")" == 9.9.9 ]] || fail "the link was not replaced by a file holding 9.9.9"
[[ -z "$(find "$T" -name pwned 2>/dev/null)" ]] || fail "a version ran as code"
# 9. Turned off, five ways; this machine's on wins over the workspace's off.
cp "$RW/cabinet.env" "$T/rn-env"
offnow() { put 9.9.9; stale; local c; for c in next status doctor; do notice "$(out $c)" && fail "$1: $c showed the notice"; done
  "$F" -C "$RW" status --json | j -e '$.latest === null' >/dev/null || fail "$1: status --json latest"; settle; [[ "$(calls)" == 0 ]] || fail "$1: a request was made"; }
CABINET_UPDATE_CHECK=off offnow "CABINET_UPDATE_CHECK=off"; NO_UPDATE_NOTIFIER=1 offnow "NO_UPDATE_NOTIFIER"; CI=true offnow "CI"
printf 'CABINET_UPDATE_CHECK="off"\n' >> "$RW/cabinet.env"; offnow "off in cabinet.env"
cp "$T/rn-env" "$RW/cabinet.env"; printf 'CABINET_UPDATE_CHECK="off"\n' >> "$RW/cabinet.local.env"; offnow "off in cabinet.local.env"
printf 'CABINET_UPDATE_CHECK="off"\n' >> "$RW/cabinet.env"; sedi '/^CABINET_UPDATE_CHECK=/d' "$RW/cabinet.local.env"; printf 'CABINET_UPDATE_CHECK="on"\n' >> "$RW/cabinet.local.env"
put 9.9.9; notice "$(out next)" || fail "on in cabinet.local.env did not win over off in cabinet.env"
cp "$T/rn-env" "$RW/cabinet.env"; sedi '/^CABINET_UPDATE_CHECK=/d' "$RW/cabinet.local.env"; settle
# 10. config --update-check.
git -C "$RW" add -A >/dev/null 2>&1; git -C "$RW" commit -qm "notice setup" >/dev/null 2>&1 || true
"$F" -C "$RW" config --yes --update-check off >/dev/null && grep -qx 'CABINET_UPDATE_CHECK="off"' "$RW/cabinet.env" && [[ -z "$(git -C "$RW" status --porcelain -- cabinet.env)" ]] || fail "config --update-check off"
"$F" -C "$RW" config --yes --update-check on >/dev/null && grep -qx 'CABINET_UPDATE_CHECK="on"' "$RW/cabinet.env" || fail "config --update-check on"
cp "$RW/cabinet.env" "$T/rn-env"
"$F" -C "$RW" config --this-machine --update-check off >/dev/null && grep -qx 'CABINET_UPDATE_CHECK="off"' "$RW/cabinet.local.env" && cmp -s "$RW/cabinet.env" "$T/rn-env" || fail "config --this-machine --update-check off"
"$F" -C "$RW" config --this-machine --clear >/dev/null && ! grep -q '^CABINET_UPDATE_CHECK=' "$RW/cabinet.local.env" 2>/dev/null || fail "config --this-machine --clear kept the update check"
p="$(git -C "$RW" rev-parse HEAD)"; cp "$RW/cabinet.local.env" "$T/rn-lenv" 2>/dev/null || : > "$T/rn-lenv"
for o in "--update-check maybe" "--update-check"; do
  st=0; "$F" -C "$RW" config --yes $o >/dev/null 2>&1 || st=$?
  [[ $st == 2 ]] && cmp -s "$RW/cabinet.env" "$T/rn-env" && [[ "$(git -C "$RW" rev-parse HEAD)" == "$p" ]] && { [[ ! -f "$RW/cabinet.local.env" ]] || cmp -s "$RW/cabinet.local.env" "$T/rn-lenv"; } || fail "config $o (exit $st)"
done
sedi '/^CABINET_UPDATE_CHECK=/d' "$RW/cabinet.env"; printf "CABINET_UPDATE_CHECK='\$(touch pwned)'\n" >> "$RW/cabinet.env"; cp "$RW/cabinet.env" "$T/rn-env"
st=0; (cd "$RW" && "$F" config --yes --writing short) >/dev/null 2>&1 || st=$?
{ grep -qxF "CABINET_UPDATE_CHECK='\$(touch pwned)'" "$RW/cabinet.env" || { ((st)) && cmp -s "$RW/cabinet.env" "$T/rn-env"; }; } || fail "config rewrote a hand-written update check"
(cd "$RW" && bin/doctor.sh) >/dev/null 2>&1 || true
sedi '/^CABINET_UPDATE_CHECK=/d' "$RW/cabinet.env"; printf "CABINET_UPDATE_CHECK='\$(touch pwned)'\n" >> "$RW/cabinet.local.env"
(cd "$RW" && "$F" config --this-machine --credit-roles off) >/dev/null 2>&1 || true
grep -qxF "CABINET_UPDATE_CHECK='\$(touch pwned)'" "$RW/cabinet.local.env" || fail "config --this-machine rewrote a hand-written update check"
(cd "$RW" && bin/doctor.sh) >/dev/null 2>&1 || true
[[ -z "$(find "$T" -name pwned 2>/dev/null)" ]] || fail "a hand-written update check ran as code"
sedi '/^CABINET_UPDATE_CHECK=/d' "$RW/cabinet.local.env"
# 11. outdated asks by hand, even with the check off, writes the file, and orders versions; a folder in the way.
put 1.0.0; age 3600 "$LR/latest-version"
CABINET_UPDATE_CHECK=off "$F" -C "$RW" outdated >/dev/null; [[ "$(calls)" == 1 && "$(cat "$LR/latest-version")" == 9.9.9 ]] || fail "outdated with the check off: $(calls) calls, $(cat "$LR/latest-version")"
printf '0.0.1\n' > "$NP/answer"; "$F" -C "$RW" outdated --json | j -e '$.update_available === false && $.command === null' >/dev/null || fail "outdated with a registry older than the kit"
printf '9.9.9\n' > "$NP/answer"; clean; mkdir "$LR/latest-version"; st=0; o="$("$F" -C "$RW" outdated)" || st=$?
grep -qx 'latest: cabinet 9.9.9' <<<"$o" && ((st == 0)) && [[ -z "$(cd "$LR" && find . -maxdepth 1 -name '.latest-version.*')" ]] || fail "outdated with a folder in the way: $o (exit $st)"
rmdir "$LR/latest-version"
# 12. It never updates: the workspace, its pin and its kit as they were.
clean; git -C "$RW" add -A >/dev/null 2>&1; git -C "$RW" commit -qm "before" >/dev/null 2>&1 || true
snap() { git -C "$RW" status --porcelain; git -C "$RW" rev-parse HEAD; cat "$RW/.cabinet/version" "$RW/package.json"; ls -A "$RW/node_modules" 2>/dev/null || true; }
q="$(snap)"; "$F" -C "$RW" next >/dev/null; settle
"$F" -C "$RW" next >/dev/null; "$F" -C "$RW" status >/dev/null; "$F" -C "$RW" outdated >/dev/null; (cd "$RW" && bin/doctor.sh) >/dev/null 2>&1 || true; settle
[[ "$(snap)" == "$q" ]] || fail "the notice changed the workspace"
! grep -v '^view @tarekraafat/cabinet version --no-update-notifier|' "$NL" || fail "npm was called for something else"
# 14. Outside a workspace: no notice.
put 9.9.9; (cd "$T" && "$F" next) | grep -q 'is out' && fail "next outside a workspace showed the notice"
# 15. The docs.
grep -q 'step `update`' "$KIT/docs/commands.md" && grep -q 'edited, latest}' "$KIT/docs/commands.md" && grep -q 'update_available, command}' "$KIT/docs/commands.md" \
  && grep -q -- '--update-check off|on' "$KIT/docs/commands.md" && grep -q '^| `CABINET_UPDATE_CHECK` | `off` turns' "$KIT/docs/commands.md" && grep -q '^| `CABINET_UPDATE_CHECK` | `off` or `on`: the release notice on this machine' "$KIT/docs/commands.md" \
  && grep -q '^| `NO_UPDATE_NOTIFIER` |' "$KIT/docs/commands.md" && grep -q '^| `CI` |' "$KIT/docs/commands.md" && grep -q 'your npm login' "$KIT/docs/commands.md" \
  && grep -q 'do not read your shell profile' "$KIT/docs/commands.md" && grep -q 'npm writes its own cache and logs' "$KIT/docs/commands.md" \
  && grep -q '`kit.newer`' "$KIT/docs/troubleshooting.md" && grep -q '`kit.newer`' "$KIT/roles/chief-of-staff.md" && grep -q 'npm install @tarekraafat/cabinet@latest && cabinet update' "$KIT/CHANGELOG.md" || fail "a release-notice doc is missing"
"$F" -C "$RW" remove --yes --force >/dev/null 2>&1 || true; "$F" -C "$SP/cabinet" remove --yes --force >/dev/null 2>&1 || true
export HOME="$oh" GIT_CONFIG_GLOBAL="$og" CABINET_UPDATE_CHECK=off PATH="${PATH#"$NP:$KIT/bin:"}"
  return 0   # a last "check && fail" line must not end the run
}

section "parallel sessions: a worktree per session, backed up, and runs that never rewrite" ""
s68() {
# Its own HOME and global git config, so the global hooks folder is this section's only. Restored at the end.
local oh="$HOME" og="$GIT_CONFIG_GLOBAL"
PH="$T/ps-home"; mkdir -p "$PH"; export HOME="$PH" GIT_CONFIG_GLOBAL="$PH/.gitconfig"
printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$GIT_CONFIG_GLOBAL"
mkr() { mkdir -p "$1" && git -C "$1" init -q -b main && echo x > "$1/f" && git -C "$1" add -A && git -C "$1" commit -qm init; }
PW="$T/ps-ws"; "$F" new "$PW" --yes >/dev/null || fail "new"
PW="$(cd "$PW" && pwd -P)"; S="$PW/sessions"
mkr "$PW/app"; printf 'app\t-\t-\tno\tapp\n' >> "$PW/repos.tsv"; git -C "$PW" commit -qam "one repo"
A="$PW/app"
ses() { (cd "$PW" && "$F" session "$@"); }
head_of() { git -C "$A" rev-parse "${1:-main}"; }

# Starting a session (criteria 1 to 10).
o="$(ses start feature-a)" || fail "session start feature-a: $o"
[[ -d "$S/app/feature-a" && "$(git -C "$S/app/feature-a" branch --show-current)" == session/feature-a && "$(head_of session/feature-a)" == "$(head_of)" ]] || fail "the session's worktree or branch: $o"
grep -qxF "  $S/app/feature-a" <<<"$o" || fail "session start did not print the folder: $o"
git -C "$PW" check-ignore -q sessions/ && git -C "$PW" check-ignore -q sessions/app/feature-a || fail "sessions/ is not ignored in the workspace"
[[ -z "$(git -C "$PW" status --porcelain)" ]] || fail "a session shows in the workspace's git status"
d="$(date +%Y-%m-%d)"
ses start >/dev/null && ses start >/dev/null && [[ -d "$S/app/$d-1" && -d "$S/app/$d-2" ]] || fail "names from the date and a number: $(ls "$S/app")"
mkr "$PW/web"; printf 'web\t-\t-\tno\tweb\n' >> "$PW/repos.tsv"
st=0; o="$(ses start two 2>&1)" || st=$?
((st)) && grep -q app <<<"$o" && grep -q web <<<"$o" && [[ ! -e "$S/app/two" && ! -e "$S/web/two" ]] && ! git -C "$A" rev-parse -q --verify refs/heads/session/two >/dev/null || fail "two repos without --repo: $o"
n40="$(printf 'a%.0s' $(seq 40))"
ses start "$n40" --repo app >/dev/null && [[ -d "$S/app/$n40" ]] || fail "a 40-character name was refused"
before="$(git -C "$A" for-each-ref --format='%(refname)' refs/heads | sort; ls -A "$S/app")"
for bad in feature-a Feature 'a b' a/b '$(x)' -b "${n40}a"; do
  ses start "$bad" --repo app >/dev/null 2>&1 && fail "the session name '$bad' was accepted"
done
ses start ok-name --repo nope >/dev/null 2>&1 && fail "a --repo not in repos.tsv was accepted"
[[ "$(git -C "$A" for-each-ref --format='%(refname)' refs/heads | sort; ls -A "$S/app")" == "$before" && ! -e "$S/nope" && ! -e "$PW/\$(x)" ]] || fail "a refused start created a branch or folder"
git -C "$A" branch session/left-over
st=0; o="$(ses start left-over --repo app 2>&1)" || st=$?
((st)) && [[ ! -e "$S/app/left-over" ]] && grep -q 'branch -d session/left-over' <<<"$o" && grep -q 'worktree add .* session/left-over' <<<"$o" || fail "an existing branch: $o"
echo dirty >> "$A/f"
o="$(ses start dirty-main --repo app)" && grep -q 'uncommitted change(s), which are not in the session' <<<"$o" && [[ "$(cat "$S/app/dirty-main/f")" == x ]] || fail "uncommitted changes in the main folder: $o"
printf '# web\n\n## Session setup\n\nRun npm install in the new folder.\n\n## Other\n\nnot this\n' > "$PW/web/AGENTS.md"; git -C "$PW/web" add AGENTS.md; git -C "$PW/web" commit -qm notes
o="$(ses start setup-note --repo web)" && grep -qx 'Run npm install in the new folder.' <<<"$o" && ! grep -q 'not this' <<<"$o" || fail "the repo's setup note: $o"
mkdir -p "$PW/notrepo"; printf 'notrepo\t-\t-\tno\tnotrepo\n' >> "$PW/repos.tsv"
ses start nr --repo notrepo >/dev/null 2>&1 && fail "a folder that is not a git repo got a session"
[[ ! -e "$S/notrepo" ]] || fail "a refused session in a folder that is not a repo left a folder"
echo s > "$S/app/feature-a/s"; git -C "$S/app/feature-a" add s; git -C "$S/app/feature-a" commit -qm "in the session"
[[ "$(git -C "$A" status --porcelain)" == " M f" ]] || fail "a session's commit changed the main folder's status: $(git -C "$A" status --porcelain)"
[[ -z "$(git -C "$S/app/feature-a" status --porcelain)" ]] || fail "the main folder's changes show in the session"
git -C "$A" checkout -q -- f

# Listing (criteria 11 and 12).
echo u > "$S/app/$d-1/u"
L1="$(ses list --json)"
j -e --arg d "$d" --arg s "$S" '((by) => by("feature-a").ahead == 1 && by("feature-a").uncommitted == 0 && by("feature-a").merged === false
  && by($d + "-1").ahead == 0 && by($d + "-1").uncommitted == 1 && by($d + "-1").merged === true
  && by($d + "-2").ahead == 0 && by($d + "-2").uncommitted == 0 && by("feature-a").repo == "app" && by("feature-a").branch == "session/feature-a"
  && by("feature-a").folder == $s + "/app/feature-a" && by("feature-a").gone === false)((n) => $.find((x) => x.name == n))' <<<"$L1" >/dev/null || fail "session list --json: $L1"
[[ "$(j -r '$.find((x) => x.name == "feature-a").started' <<<"$L1")" == "$(date +%F)" ]] || fail "the start date is not today's: $L1"
o="$(ses list)"; grep -q "^feature-a  (app, session/feature-a)  1 commit(s) ahead, 0 uncommitted, not merged, started $(LC_ALL=C date "+%-d %b %Y")" <<<"$o" || fail "session list: $o"
rm -rf "$S/app/$d-2"
o="$(ses list)"; grep -q "^$d-2 .*folder gone" <<<"$o" && grep -qF "git -C $A worktree prune" <<<"$o" || fail "a gone folder in session list: $o"
j -e --arg n "$d-2" '$.find((x) => x.name == $n).gone === true' <<<"$(ses list --json)" >/dev/null || fail "gone in --json"
(cd "$PW" && "$F" doctor --json) | j -e --arg n "$d-2" '$.results.some((r) => r.id == "sessions.gone" && r.message.includes($n) && r.message.includes("worktree prune"))' >/dev/null || fail "the doctor did not report the gone session"
git -C "$A" worktree prune

# Reviews (criteria 17 and 18).
sc="$(git -C "$S/app/feature-a" rev-parse HEAD)"
"$PW/bin/handoff.sh" add --from backend --to "qa, security" --changed "the session's work" --needed "review it" --evidence "$S/app/feature-a/s" "session work" >/dev/null || fail "handoff add"
hid="$(grep -o '^### H-[0-9]*-[0-9]*' "$PW/HANDOFFS.md" | tail -1 | cut -c5-)"
mkdir -p "$PW/specs/qa"; echo ok > "$PW/specs/qa/ps.md"; git -C "$PW" add specs/qa/ps.md; git -C "$PW" commit -qm note
for r in qa security code-reviewer; do (cd "$PW" && bin/handoff.sh record "$hid" --role "$r" PASS --commits "${sc:0:7}" --note specs/qa/ps.md) >/dev/null 2>&1 || fail "record $r of a session commit from the main folder"; done
grep -q "^- Verdict: qa PASS .* ${sc:0:7} " "$PW/HANDOFFS.md" || fail "the session commit's verdict"
o="$(cd "$PW" && bin/handoff.sh list --ready)"
grep -qF "$hid: passed, but its commits are only on session/feature-a" <<<"$o" && [[ "$(grep -c "$hid" <<<"$o")" == 1 ]] || fail "list --ready with the work only on a session branch: $o"
(cd "$PW" && bin/handoff.sh list --json) | j -e --arg i "$hid" '$.find((e) => e.id == $i).ready === false && $.find((e) => e.id == $i).session_branch == "session/feature-a"' >/dev/null || fail "list --json session_branch"
grep -q 'cabinet session list --json' "$KIT/roles/chief-of-staff.md" && grep -q 'merged: false' "$KIT/roles/chief-of-staff.md" || fail "the brief does not list unmerged sessions"

# Ending (criteria 13 to 16).
m="$(head_of)"
o="$(ses end feature-a 2>&1)" || fail "end feature-a: $o"
grep -q "${sc:0:7} in the session" <<<"$o" && grep -q "Handoffs that name them: $hid" <<<"$o" && grep -qxF "  git -C $A merge --ff-only session/feature-a" <<<"$o" && [[ "$(head_of)" == "$m" ]] || fail "session end with commits: $o"
[[ ! -e "$S/app/feature-a" && "$(head_of session/feature-a)" == "$sc" ]] || fail "end did not remove the clean folder, or lost the branch"
git -C "$A" merge -q --ff-only session/feature-a
o="$(cd "$PW" && bin/handoff.sh list --ready)"; grep -q "$hid" <<<"$o" && ! grep -q 'only on session' <<<"$o" || fail "merged work is not ready: $o"
ses start moved --repo app >/dev/null; echo m > "$S/app/moved/m"; git -C "$S/app/moved" add m; git -C "$S/app/moved" commit -qm moved
echo main >> "$A/f"; git -C "$A" commit -qam "main moves"; m="$(head_of)"
o="$(ses end moved)" && grep -qF "git -C $S/app/moved rebase main" <<<"$o" && grep -qxF "  git -C $A merge --ff-only session/moved" <<<"$o" && [[ "$(head_of)" == "$m" ]] || fail "end when main moved on: $o"
# A branch name holding shell characters is printed quoted in every command (security S1).
ses start odd --repo app >/dev/null; git -C "$S/app/odd" checkout -q -b 'session/odd;id'
L1="$(ses list --json)"; j -e --arg m "git -C $(printf %q "$A") merge --ff-only $(printf %q 'session/odd;id')" '$.find((x) => x.name == "odd").merge == $m' <<<"$L1" >/dev/null || fail "list --json with a branch holding shell characters: $L1"
# list --ready names such a branch, but prints no session end command with it (security S4).
echo o > "$S/app/odd/o"; git -C "$S/app/odd" add o; git -C "$S/app/odd" commit -qm "odd work"; oc="$(git -C "$S/app/odd" rev-parse --short HEAD)"
"$PW/bin/handoff.sh" add --from backend --to "qa, security" --changed 'odd work' --needed 'review it' --evidence "$S/app/odd/o" 'odd session work' >/dev/null || fail "handoff add"
oid="$(grep -o '^### H-[0-9]*-[0-9]*' "$PW/HANDOFFS.md" | tail -1 | cut -c5-)"
for r in qa security code-reviewer; do (cd "$PW" && bin/handoff.sh record "$oid" --role "$r" PASS --commits "$oc" --note specs/qa/ps.md) >/dev/null 2>&1 || fail "record $r of an odd session commit"; done
o="$(cd "$PW" && bin/handoff.sh list --ready)"
grep -qF "$oid: passed, but its commits are only on session/odd;id, not on the branch you push: its name is not a session name, so merge it with git yourself" <<<"$o" \
  && ! grep -q 'session end' <<<"$o" || fail "list --ready printed a session end command for a branch holding shell characters: $o"
git -C "$S/app/odd" checkout -q session/odd; git -C "$A" branch -q -D 'session/odd;id'
mb='m$(id);x'; git -C "$A" branch -m main "$mb"; echo odd >> "$A/f"; git -C "$A" commit -qam "odd moves"
o="$(ses end odd)" && grep -qF "rebase $(printf %q "$mb")" <<<"$o" && ! grep -qF "rebase $mb" <<<"$o" || fail "end with a main branch holding shell characters: $o"
git -C "$A" branch -m "$mb" main
ses start busy --repo app >/dev/null; echo b >> "$S/app/busy/f"; echo n > "$S/app/busy/new"
snap() { (cd "$S/app/busy" && find . -name .git -prune -o -type f -print | sort | xargs cksum); }
b4="$(snap)"; st=0; o="$(ses end busy 2>&1)" || st=$?
((st)) && grep -q 'uncommitted' <<<"$o" && [[ "$(snap)" == "$b4" ]] || fail "end with uncommitted changes: $o"
ses start envs --repo app >/dev/null; echo '.env' >> "$A/.git/info/exclude"; echo SECRET=1 > "$S/app/envs/.env"
st=0; o="$(ses end envs 2>&1)" || st=$?; ((st)) && [[ -f "$S/app/envs/.env" ]] || fail "end deleted an ignored .env: $o"
rm "$S/app/envs/.env"; ses end envs >/dev/null || fail "end of a clean session"
[[ ! -e "$S/app/envs" ]] && git -C "$A" rev-parse -q --verify refs/heads/session/envs >/dev/null || fail "end did not remove the folder, or deleted the branch"

# Inside a project (criterion 2), private and shared.
for vis in private shared; do
  P="$T/ps-proj-$vis"; mkr "$P"; P="$(cd "$P" && pwd -P)"
  (cd "$P" && "$F" init --yes --inside --$vis) >/dev/null || fail "init --inside --$vis"
  [[ "$vis" == shared ]] && { git -C "$P" add -A; git -C "$P" commit -qm cabinet; }
  pr="$(awk -F'\t' '$5 == ".." {print $1}' "$P/cabinet/repos.tsv")"; [[ -n "$pr" ]] || fail "no project row in repos.tsv ($vis)"
  (cd "$P" && "$F" session start feature-a) >/dev/null || fail "session start inside a project ($vis)"
  [[ -d "$P/cabinet/sessions/$pr/feature-a" ]] && git -C "$P" check-ignore -q "cabinet/sessions/$pr/feature-a" || fail "the inside session is not at cabinet/sessions/ or not ignored ($vis)"
  [[ -z "$(git -C "$P" status --porcelain)" ]] || fail "an inside session shows in the project's status ($vis): $(git -C "$P" status --porcelain)"
  # From the session's folder, the cabinet command means the main folder's workspace, whose HANDOFFS.md is the one channel.
  (cd "$P/cabinet/sessions/$pr/feature-a" && "$F" handoff add --from qa --to owner --changed x --needed y "from a session") >/dev/null || fail "handoff add from an inside session ($vis)"
  grep -q 'from a session' "$P/cabinet/HANDOFFS.md" || fail "a handoff from an inside session did not reach the main workspace ($vis)"
  ! grep -qs 'from a session' "$P/cabinet/sessions/$pr/feature-a/cabinet/HANDOFFS.md" || fail "the handoff went to the session's copy ($vis)"
done

# Backups (criteria 20 to 23).
BK="$T/ps-bk"; bk() { CABINET_BACKUP_PASSPHRASE=t "$PW/bin/backup.sh" "$@"; }
ses start kept --repo app >/dev/null; echo changed >> "$S/app/kept/f"; echo new > "$S/app/kept/untracked.txt"
rm -rf "$S/app/busy" "$S/app/dirty-main"
o="$(bk create "$BK" 2>&1)" || fail "backup with sessions: $o"
grep -q 'the folder of session busy is gone' <<<"$o" && grep -q 'app: session kept' <<<"$o" || fail "backup create did not say which sessions it saved and which are gone: $o"
o="$(bk verify "$BK" 2>&1)" && grep -q '^  app session kept: restores on session/kept' <<<"$o" || fail "verify did not check the session: $o"
arc="$(ls "$BK")"; x="$T/ps-x"; mkdir -p "$x" "$T/ps-bk2"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass pass:t < "$BK/$arc" | tar -C "$x" -xzf -
printf 'diff --git a/nothere b/nothere\n--- a/nothere\n+++ b/nothere\n@@ -1 +1 @@\n-a\n+b\n' > "$(echo "$x"/*/repos/app/sessions/kept)/worktree.patch"
tar -C "$x" -czf - "$(ls "$x")" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass pass:t > "$T/ps-bk2/$arc"
st=0; o="$(bk verify "$T/ps-bk2" 2>&1)" || st=$?; ((st)) && grep -q 'PROBLEM app session kept' <<<"$o" || fail "a damaged session patch verified: $o"
bk verify "$BK" >/dev/null 2>&1 || fail "the owner's archive was changed by the damage test"
R="$T/ps-restore"; o="$(bk restore "$BK/$arc" "$R" 2>&1)" || fail "restore: $o"
[[ "$(git -C "$R/sessions/app/kept" branch --show-current)" == session/kept && "$(tail -1 "$R/sessions/app/kept/f")" == changed && "$(cat "$R/sessions/app/kept/untracked.txt")" == new ]] || fail "restore did not recreate the session: $o"
git -C "$R" check-ignore -q sessions/app/kept || fail "the restored session is not ignored"
echo mine >> "$R/sessions/app/kept/f"; b4="$(cksum "$R/sessions/app/kept/f" "$R/sessions/app/kept/untracked.txt" "$R/app/f")"
o="$(bk restore "$BK/$arc" "$R" 2>&1)" || fail "restore over the existing repo: $o"
[[ "$(cksum "$R/sessions/app/kept/f" "$R/sessions/app/kept/untracked.txt" "$R/app/f")" == "$b4" ]] && ls "$R"/recovered/*/app/sessions/kept/worktree.patch "$R"/recovered/*/app/sessions/kept/untracked.tar >/dev/null 2>&1 || fail "restore over an existing repo did not keep the session in recovered/: $o"

# The git actions rule, word for word (criteria 26, 27 and 29).
c="$(tr '\n' ' ' < "$KIT/core/CABINET.md")"
for w in 'push, merge on a shared host (a pull request), deploy, publish, release' '**Never push, merge on a shared host, publish or release.**' 'may loosen "Never push, merge on a shared host, publish or release"' \
  '**Local git actions only, and only what can be undone.** Commit your own work locally.' 'compare `git status --short` with the files you changed: if any change is not yours, stop and tell the owner which files appear to be someone else'"'"'s.' \
  '`git reset --hard`, a checkout or restore of files, `git clean`, `git stash drop`, `git commit -a`, `git add -A`, `git add .`'; do
  grep -qF -- "$w" <<<"$c" || fail "core/CABINET.md lacks: $w"
done
# The amend rule (owner decision, 28 Oct 2026): one's own newest, unpushed, unnamed commit needs no ask; never in a run.
am='One amend needs no ask: your own commit, while it is the newest on the branch, is not pushed, and no handoff, verdict or note names its hash; check `git diff --cached` first, since the amend takes everything staged. Amend as `CABINET_AMEND_AS=<role> git commit --amend`: the hooks refuse it unless the commit ends with your role'"'"'s credit line.'
grep -qF "$am It never runs in an unattended run, where the hooks refuse it." <<<"$c" && grep -qF 'and an amend with anything staged that is not yours need the owner'"'"'s explicit ask' <<<"$c" \
  && grep -qF 'Once a handoff or verdict names a commit, a fix is a new commit: a commit that fails review is reverted, or fixed in a follow-up commit, never amended.' <<<"$c" \
  && grep -qF "$am Once a handoff or verdict names a commit, a fix is a new commit." "$KIT/AGENTS.md" || fail "the amend rule is not in core/CABINET.md and the kit's rule 12"
for f in docs/guardrails.md docs/concepts.md CHANGELOG.md; do grep -qF 'CABINET_AMEND_AS=<role> git commit --amend' "$KIT/$f" || fail "$f does not name CABINET_AMEND_AS"; done
grep -qxF '4. **You push** what has passed review, from your own terminal. No agent can push, merge on GitHub, release or publish.' "$KIT/README.md" || fail "README step 4 is not the owner's sentence"
n="$(tr '\n' ' ' < "$KIT/docs/concepts.md")"
grep -qF 'One exception: an agent may amend its own newest commit without asking, while it is not pushed and no handoff, verdict or note names it; once one does, a fix is a new commit.' <<<"$n" \
  && grep -qF 'an amend with anything staged that is not its own) needs your explicit ask' <<<"$n" && grep -qF 'refuse every amend and every rebase there' <<<"$n" || fail "docs/concepts.md does not carry the amend rule"
# Rule 15's snapshot step, in core/rules/builders.md, which core/CABINET.md points every agent to.
grep -qF '.cabinet/rules/builders.md` (rule 5)' <<<"$c" || fail "core/CABINET.md does not point to the snapshot step"
for w in 'git stash create' 'git stash store -m "cabinet: before <command>" <commit>' 'when it prints nothing, there is no tracked change to save, so go on without a snapshot' 'git clean -n'; do
  grep -qF -- "$w" "$KIT/core/rules/builders.md" || fail "core/rules/builders.md lacks: $w"
done
grep -qF 'never pushes, merges on a shared host, deploys or publishes; other git actions only as `CABINET.md` allows' "$KIT/core/rules/builders.md" && grep -qF 'no push, merge on a shared host, deploy, publish or spend' "$KIT/core/rules/seats.md" \
  && grep -qF 'merge on a shared host' "$KIT/roles/chief-of-staff.md" && grep -qF 'Never push, merge on a shared host, publish or release.' "$KIT/AGENTS.md" \
  && grep -qF 'Never push, merge on a shared host, publish or release' "$KIT/templates/workspace/guides/README.md" \
  && ! grep -rqF 'merge on GitHub' "$KIT/core" "$KIT/roles" "$KIT/AGENTS.md" && ! grep -qF 'merges on GitHub' "$KIT/core/rules/builders.md" \
  && grep -qF 'Run a recoverable git action (amend, rebase, reset without `--hard`, stash, a local merge) only when the maintainer asks for it in your session, and say how to undo it.' "$KIT/AGENTS.md" \
  && grep -qF 'Never sweep or drop changes you did not make: before `commit -a`, `add -A`, `add .`, `reset --hard`, a checkout or restore of files, or an amend, check that every uncommitted change is your own, and stop if it is not.' "$KIT/AGENTS.md" || fail "a Rule 17 or 18 wording is missing"
g="$(tr '\n' ' ' < "$KIT/docs/guardrails.md")"
grep -qF 'git rebase --no-verify' <<<"$g" && grep -qF 'Codex and Antigravity' <<<"$g" && grep -qF 'Claude Code, Grok, Qwen Code, opencode, Cursor CLI and Gemini CLI' <<<"$g" || fail "docs/guardrails.md does not say which tools refuse a rebase that skips its hook"
grep -qF 'except an amend of its own newest commit before it is pushed or named in a handoff or verdict' <<<"$g" && grep -qF 'give that message with `-F <file>`' <<<"$g" \
  && grep -qF 'setting `CABINET_AGENT` empty (`CABINET_AGENT= git commit --amend`), which no tool'"'"'s deny rules catch' <<<"$g" || fail "docs/guardrails.md: the amend exception, the -F hint or the empty CABINET_AGENT limit"
SR="$T/ps-stash"; mkr "$SR"; echo changed >> "$SR/f"; b4="$(cksum "$SR/f")"
sc="$(git -C "$SR" stash create)"; [[ -n "$sc" ]] && git -C "$SR" stash store -m "cabinet: before reset --hard" "$sc" || fail "stash create and store"
[[ "$(cksum "$SR/f")" == "$b4" ]] && git -C "$SR" stash list | grep -q 'cabinet: before reset --hard' || fail "the snapshot changed the working tree or is not listed"
git -C "$SR" reset -q --hard; git -C "$SR" stash apply -q; [[ "$(cksum "$SR/f")" == "$b4" ]] || fail "the snapshot did not bring the change back"
git -C "$SR" reset -q --hard; git -C "$SR" stash clear; b4="$(cksum "$SR/f")"
[[ -z "$(git -C "$SR" stash create)" && "$(cksum "$SR/f")" == "$b4" && -z "$(git -C "$SR" stash list)" ]] || fail "stash create with no tracked change"

# Runs never rewrite (criteria 28 and 30).
HK="$PH/.config/git/hooks"; boot() { "$PW/bin/bootstrap.sh" >/dev/null 2>&1 || true; }
boot; cmp -s "$KIT/guardrails/pre-rebase" "$HK/pre-rebase" && cmp -s "$KIT/guardrails/prepare-commit-msg" "$HK/prepare-commit-msg" || fail "bootstrap did not place the kit's hooks"
(cd "$PW" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "guardrails.run-refusal" && r.level == "ok")' >/dev/null || fail "the doctor does not report the run refusal"
mkdir -p "$T/ps-shim"
for t in claude codex agy qwen grok opencode cursor-agent; do
  printf '#!/bin/sh\ncd "$PS_REPO" || exit 1\nsh -c "$PS_DO"; echo $? > "$PS_REPO/../ps-status"\n' > "$T/ps-shim/$t"; chmod +x "$T/ps-shim/$t"
done
RR="$T/ps-run"; mkr "$RR"; git -C "$RR" checkout -q -b side; echo s > "$RR/s"; git -C "$RR" add s; git -C "$RR" commit -qm side; git -C "$RR" checkout -q main; echo m >> "$RR/f"; git -C "$RR" commit -qam "main moves"
prun() {  # prun <runner> <command>: the command in a fake run, through run_agent; prints its exit status
  rm -f "$T/ps-status"
  (cd "$PW" && PATH="$T/ps-shim:$PATH" PS_REPO="$RR" PS_DO="$2" bash -c 'source bin/lib.sh; CABINET_RUNNER="$1"; AGENT=backend PROMPT=work run_agent' _ "$1") >/dev/null 2>&1 || true
  cat "$T/ps-status" 2>/dev/null || echo "did not run"
}
for r in claude codex antigravity qwen grok opencode cursor; do
  h="$(git -C "$RR" rev-parse HEAD)" sh="$(git -C "$RR" rev-parse side)"
  for c in 'git commit -q --amend --no-edit' 'git commit -q --amend --no-edit --no-verify' 'git commit -q --amend -m other' 'git commit -q --amend --no-edit -n'; do
    s="$(prun "$r" "$c")"; [[ "$s" =~ ^[1-9] && "$(git -C "$RR" rev-parse HEAD)" == "$h" ]] || fail "$r: '$c' in a run was not refused ($s), or changed the commit"
  done
  s="$(prun "$r" 'git checkout -q side && git rebase -q main; s=$?; git checkout -q main; exit $s')"
  [[ "$s" =~ ^[1-9] && "$(git -C "$RR" rev-parse side)" == "$sh" && "$(git -C "$RR" branch --show-current)" == main ]] || fail "$r: a rebase in a run was not refused ($s), or moved the branch"
done
[[ "$(prun codex 'echo y >> f && git commit -qam new')" == 0 ]] || fail "a new commit in a run was refused"
# A new commit whose -m message mentions --amend: made where each argument can be read on its own (/proc,
# Linux), refused elsewhere with the -F hint; through -F it is made everywhere.
h="$(git -C "$RR" rev-parse HEAD)"; s="$(prun codex 'echo y2 >> f && git commit -qa -m "docs: say --amend is refused" 2>../ps-err')"
if [[ -r /proc/self/cmdline ]]; then [[ "$s" == 0 && "$(git -C "$RR" log -1 --format=%s)" == "docs: say --amend is refused" ]] || fail "a new commit whose message mentions --amend was refused on Linux ($s): $(cat "$T/ps-err")"
else [[ "$s" =~ ^[1-9] && "$(git -C "$RR" rev-parse HEAD)" == "$h" ]] && grep -qF 'give the message with -F <file> instead of -m' "$T/ps-err" || fail "a -m message mentioning --amend: not refused with the -F hint ($s): $(cat "$T/ps-err")"; fi
h="$(git -C "$RR" rev-parse HEAD)"; s="$(prun codex 'echo y3 >> f && printf "docs: say --amend is refused\n" > ../ps-msg && git commit -qa -F ../ps-msg')"
[[ "$s" == 0 && "$(git -C "$RR" rev-parse HEAD~1)" == "$h" && "$(git -C "$RR" log -1 --format=%s)" == "docs: say --amend is refused" ]] || fail "a new commit in a run with -F and a message mentioning --amend ($s)"
h="$(git -C "$RR" rev-parse HEAD)"
# Each amend with a change of its own: an amend that changes nothing, in the same second, makes the same commit.
echo a1 >> "$RR/f"; git -C "$RR" add f; git -C "$RR" commit -q --amend --no-edit || fail "an amend outside a run was refused"
h2="$(git -C "$RR" rev-parse HEAD)"; echo a2 >> "$RR/f"; git -C "$RR" add f
git -C "$RR" commit -q --amend --no-edit --no-verify && [[ "$(git -C "$RR" rev-parse HEAD)" != "$h" && "$(git -C "$RR" rev-parse HEAD)" != "$h2" ]] || fail "an amend outside a run (one that skips the hooks) was refused"
git -C "$RR" checkout -q side && git -C "$RR" rebase -q main && git -C "$RR" checkout -q main || fail "a rebase outside a run was refused"
# The owner's own pre-rebase is left as it is, and the doctor says why runs are not refused.
printf '#!/bin/sh\n# mine\nexit 0\n' > "$HK/pre-rebase"; cp "$HK/pre-rebase" "$T/ps-mine"; boot
cmp -s "$T/ps-mine" "$HK/pre-rebase" || fail "bootstrap replaced the owner's own pre-rebase"
(cd "$PW" && "$F" doctor --json) | j -e '$.results.some((r) => r.id == "guardrails.run-refusal" && r.level == "note" && r.message.includes("pre-rebase"))' >/dev/null || fail "the doctor did not say the run refusal is not installed"
cp "$KIT/guardrails/hook-passthrough" "$HK/pre-rebase"; boot; cmp -s "$KIT/guardrails/pre-rebase" "$HK/pre-rebase" || fail "bootstrap did not replace the pass-through stub with the kit's pre-rebase"
{ sed -n 1p "$KIT/guardrails/pre-rebase"; echo "# cabinet pre-rebase hook v0"; sed 1,2d "$KIT/guardrails/pre-rebase"; } > "$HK/pre-rebase"; boot
cmp -s "$KIT/guardrails/pre-rebase" "$HK/pre-rebase" || fail "bootstrap did not replace an earlier pre-rebase hook"
# With the kit's hook, a repo's own pre-rebase runs with the same arguments, and its exit 1 stops the rebase.
printf '#!/bin/sh\necho "$@" >> "%s"\n[ -e "%s" ] && exit 1\nexit 0\n' "$T/ps-own-args" "$T/ps-own-fail" > "$RR/.git/hooks/pre-rebase"; chmod +x "$RR/.git/hooks/pre-rebase"
echo m2 >> "$RR/f"; git -C "$RR" commit -qam "main again"
git -C "$RR" rebase -q main side >/dev/null 2>&1 && grep -qx 'main side' "$T/ps-own-args" || fail "the repo's own pre-rebase did not run with git's arguments: $(cat "$T/ps-own-args" 2>/dev/null)"
git -C "$RR" checkout -q main; echo m3 >> "$RR/f"; git -C "$RR" commit -qam "main once more"; touch "$T/ps-own-fail"; sh="$(git -C "$RR" rev-parse side)"
git -C "$RR" rebase -q main side >/dev/null 2>&1 && fail "the repo's own pre-rebase failing did not stop the rebase"
[[ "$(git -C "$RR" rev-parse side)" == "$sh" ]] || fail "the branch moved though the repo's pre-rebase failed"
git -C "$RR" checkout -q main 2>/dev/null || true

# Docs (criterion 31).
for f in docs/commands.md docs/concepts.md docs/guardrails.md docs/backups.md README.md CHANGELOG.md; do
  grep -qi 'session' "$KIT/$f" || fail "$f does not describe sessions"
  grep -qiE '(session|role)s? (merges|pushes)|merges on its own|pushes on its own' "$KIT/$f" && fail "$f says a session or role merges or pushes"
done
grep -q 'sessions.gone' "$KIT/docs/troubleshooting.md" && grep -q 'guardrails.run-refusal' "$KIT/docs/troubleshooting.md" || fail "a new doctor check is not in troubleshooting"
export HOME="$oh" GIT_CONFIG_GLOBAL="$og"
  return 0   # a last "check && fail" line must not end the run
}

section "light model: the light one only for the roles listed, every other role on the main model" ""
s69() {
# Token cost, Part 1 (criteria 1 to 11). The baseline is the kit at 4574648: its scripts/lib.sh and scripts/role.sh,
# kept in test/fixtures/4574648/ and run on the same inputs, and the output of role add it printed.
local LW="$T/light" LF="$T/lfakes" LL="$T/light-calls.log" FX="$KIT/test/fixtures/4574648" LP="$T/lightp" LI r mm ml lr st out v wq wd wr x d cur
mkdir -p "$LF"
# One fake for every built-in tool: it logs each call as "<tool> [arg] [arg]...", and codex's model list (the
# one the doctor reads here) holds the names in $LMODELS.
cat > "$LF/fake" <<'FAKE'
#!/bin/bash
n="${0##*/}"
{ printf '%s' "$n"; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$MLOG"
case "$n $*" in
  "codex debug models") printf '{"models":[%s]}\n' "$(for x in ${LMODELS:-m-main}; do printf '{"slug":"%s"},' "$x"; done | sed 's/,$//')" ;;
  *" --version") echo "$n 1.0" ;;
  *) echo '{}' ;;
esac
FAKE
chmod +x "$LF/fake"
for r in claude codex agy qwen grok opencode cursor-agent; do ln -sf fake "$LF/$r"; done
lm() { PATH="$LF:$PATH" MLOG="$LL" "$@"; }
runs() { grep -v -e ' \[--version\]$' -e '^codex \[debug\] \[models\]$' -e '^\(agy\|grok\|opencode\|cursor-agent\) \[models\]$' -e '^codex \[execpolicy\]' -e '^opencode \[debug\] \[agent\] \[build\]$' -e '^grok \[inspect\] \[--json\]$' "$LL" 2>/dev/null || true; }
# le <workspace> <key> [<line>]: the key's line in cabinet.env replaced by <line>, or removed when none is given.
le() { { grep -v "^$2=" "$1/cabinet.env" || true; [[ -z "${3+x}" ]] || printf '%s\n' "$3"; } > "$T/l.env"; mv "$T/l.env" "$1/cabinet.env"; }
lset() { le "$LW" CABINET_MODEL "CABINET_MODEL=\"$1\""; le "$LW" CABINET_MODEL_LIGHT "CABINET_MODEL_LIGHT=\"$2\""; le "$LW" CABINET_LIGHT_ROLES "CABINET_LIGHT_ROLES=\"$3\""; }
# mods <role>: the model each recorded claude run of the role passed ("none" for none, "many" for more than one).
mods() {
  runs | grep -F "[--agent] [$1] " | while IFS= read -r l; do
    case "$(grep -o '\[--model\]' <<<"$l" | wc -l | tr -d ' ')" in 0) echo none ;; 1) sed 's/.*\[--model\] \[\([^]]*\)\].*/\1/' <<<"$l" ;; *) echo many ;; esac
  done | paste -sd ' ' -
}
jr() { printf 'AGENT=%s\nPROMPT="p"\nQUIET_DAYS="0"\n' "$1" > "$LW/jobs/t.job"; : > "$LL"; lm "$LW/bin/job.sh" run t >/dev/null 2>&1 || true; mods "$1"; }
br() { : > "$LL"; lm "$LW/bin/job.sh" run brief >/dev/null 2>&1 || true; mods chief-of-staff; }
bj() { cp "$LW/jobs/brief.job" "$T/l-brief"; echo 'MODEL="m-job"' >> "$LW/jobs/brief.job"; br; cp "$T/l-brief" "$LW/jobs/brief.job"; }
hr() { : > "$LL"; lm "$LW/bin/handoff.sh" run "$1" >/dev/null 2>&1 || true; mods "$2"; }
sr() { : > "$LL"; lm "$LW/bin/spec.sh" run "$1" >/dev/null 2>&1 || true; mods "$2"; }
lc() { git -C "$LW" add -A >/dev/null 2>&1; git -C "$LW" commit -qm "$1" >/dev/null 2>&1 || true; }
lres() { lm "$F" -C "$LW" doctor --json | j -r --arg id "$1" '$.results.filter((r) => r.id == $id).map((r) => r.level + " " + r.message).join("\n")'; }
lfix() { lm "$F" -C "$LW" doctor --json | j -r '$.results.filter((r) => r.level == "fix" && r.id.startsWith("model-light")).map((r) => r.id).join(" ")'; }
: > "$LL"
lm "$F" new "$LW" --yes --runner claude --roles "chief-of-staff product-manager architect qa security design-lead" >/dev/null || fail "new for the light model"
! grep -q -e '^CABINET_MODEL_LIGHT=' -e '^CABINET_LIGHT_ROLES=' "$LW/cabinet.env" || fail "new --yes wrote a light model line"
# 8. bootstrap leaves a cabinet.env from before the light model as it is.
cp "$LW/cabinet.env" "$T/l-new.env"; lm "$LW/bin/bootstrap.sh" >/dev/null 2>&1 || true
cmp -s "$T/l-new.env" "$LW/cabinet.env" || fail "bootstrap changed cabinet.env: $(diff "$T/l-new.env" "$LW/cabinet.env")"
# A repo backend owns, two ready specs for it (s2 with its work routed, so its next step is backend's plan),
# and two pieces of work, each with a review handoff: one to qa (design-lead has passed it, so qa runs next)
# and one to design-lead.
sedi 's/^QUIET_DAYS=.*/QUIET_DAYS="0"/' "$LW/jobs/brief.job"
git init -q "$LW/app" && echo x > "$LW/app/a" && git -C "$LW/app" add -A && git -C "$LW/app" commit -qm init
printf 'app\t-\t-\tno\n' >> "$LW/repos.tsv"; L before "$LW/AGENTS.md" '/^\| workspace \(this folder\)/' '| `app` | The API | backend |'
for x in s1 s2; do
  printf -- '---\nfeature: %s\nstatus: ready\nrepos: [app]\n---\n\n# S\n\n## Rules\n\nOne.\n\n## Acceptance criteria\n\n- One works.\n\n## Decisions\n\n| # | Question | Options | Recommendation | Owner answer (date) |\n|---|---|---|---|---|\n\n## Plan\n\nLater.\n\n## Reviews\n' "$x" > "$LW/specs/$x.md"
done
mkdir -p "$LW/specs/qa"; echo ok > "$LW/specs/qa/n.md"; lc "specs and a repo"
for x in s1 s2; do "$LW/bin/spec.sh" record "specs/$x.md" --role qa PASS --note specs/qa/n.md >/dev/null || fail "test setup: $x ready"; done
"$LW/bin/handoff.sh" add --from chief-of-staff --to app --spec specs/s2.md --changed x --needed y "Plan it" >/dev/null || fail "test setup: s2's work"
work() { local i; i="$("$LW/bin/handoff.sh" add --from chief-of-staff --to app --small --changed x --needed y "$1")"; echo "${i%% *}"; }
review() { local i; i="$("$LW/bin/handoff.sh" add --from backend --to "$2" --changed x --needed y --depends-on "$1" --evidence https://example.com/e "Review $1")"; echo "${i%% *}"; }
wq="$(work "For qa")"; v="$(review "$wq" "qa, security")"
"$LW/bin/handoff.sh" record "$v" --role design-lead PASS --commits a1b2c3d --note specs/qa/n.md >/dev/null || fail "test setup: design-lead on $v"
wd="$(work "For design-lead")"; review "$wd" design-lead >/dev/null
lc "work"
[[ "$(hr "$wq" qa)" == none && "$(hr "$wd" design-lead)" == none && "$(sr specs/s1.md chief-of-staff)" == none && "$(sr specs/s2.md backend)" == none ]] \
  || fail "test setup: the steps: $(hr "$wq" qa) $(hr "$wd" design-lead) $(sr specs/s1.md chief-of-staff) $(sr specs/s2.md backend)"
# 7. No regression, run lines: the brief, a qa job, the brief with MODEL, the handoff run's qa step and the spec run's
# routing step, for every built-in runner, with CABINET_MODEL set and absent: 4574648's lib.sh first (the baseline),
# then today's with the light settings absent, empty and set, the light model never set.
seven() {
  : > "$LL"
  lm "$LW/bin/job.sh" run brief >/dev/null 2>&1 || true
  printf 'AGENT=qa\nPROMPT="p"\nQUIET_DAYS="0"\n' > "$LW/jobs/t.job"; lm "$LW/bin/job.sh" run t >/dev/null 2>&1 || true
  cp "$LW/jobs/brief.job" "$T/l-brief"; echo 'MODEL="m-job"' >> "$LW/jobs/brief.job"; lm "$LW/bin/job.sh" run brief >/dev/null 2>&1 || true; cp "$T/l-brief" "$LW/jobs/brief.job"
  lm "$LW/bin/handoff.sh" run "$wq" >/dev/null 2>&1 || true
  lm "$LW/bin/spec.sh" run specs/s1.md >/dev/null 2>&1 || true
  runs
}
cp "$LW/bin/lib.sh" "$T/l-lib.sh"; cp "$FX/lib.sh" "$LW/bin/lib.sh"
for r in claude codex antigravity qwen grok opencode cursor; do
  le "$LW" CABINET_RUNNER "CABINET_RUNNER=\"$r\""
  for mm in "" m-main; do
    if [[ -n "$mm" ]]; then le "$LW" CABINET_MODEL "CABINET_MODEL=\"$mm\""; else le "$LW" CABINET_MODEL; fi
    seven > "$T/l7-$r-$mm"; [[ "$(wc -l < "$T/l7-$r-$mm" | tr -d ' ')" == 5 ]] || fail "the baseline with $r: $(cat "$T/l7-$r-$mm")"
  done
done
cp "$T/l-lib.sh" "$LW/bin/lib.sh"
for r in claude codex antigravity qwen grok opencode cursor; do
  le "$LW" CABINET_RUNNER "CABINET_RUNNER=\"$r\""
  for mm in "" m-main; do
    if [[ -n "$mm" ]]; then le "$LW" CABINET_MODEL "CABINET_MODEL=\"$mm\""; else le "$LW" CABINET_MODEL; fi
    for ml in absent ""; do for lr in absent chief-of-staff; do
      if [[ "$ml" == absent ]]; then le "$LW" CABINET_MODEL_LIGHT; else le "$LW" CABINET_MODEL_LIGHT 'CABINET_MODEL_LIGHT=""'; fi
      if [[ "$lr" == absent ]]; then le "$LW" CABINET_LIGHT_ROLES; else le "$LW" CABINET_LIGHT_ROLES "CABINET_LIGHT_ROLES=\"$lr\""; fi
      seven > "$T/l7-now"; cmp -s "$T/l7-$r-$mm" "$T/l7-now" || fail "the run lines with $r, model '$mm', light model $ml, roles $lr: $(diff "$T/l7-$r-$mm" "$T/l7-now")"
    done; done
  done
done
le "$LW" CABINET_RUNNER 'CABINET_RUNNER="claude"'; le "$LW" CABINET_MODEL 'CABINET_MODEL=""'; le "$LW" CABINET_MODEL_LIGHT; le "$LW" CABINET_LIGHT_ROLES; lc "settings"
# 4 (the baseline). With no light model, role add prints what it printed at 4574648.
out="$(cd "$LW" && lm "$F" role add helper --does "test" 2>&1)" || fail "role add helper: $out"
[[ "$out" == "$(cat "$FX/role-add-helper.txt")" ]] || fail "role add with no light model: $out"
le "$LW" CABINET_MODEL_LIGHT 'CABINET_MODEL_LIGHT=""'; le "$LW" CABINET_LIGHT_ROLES 'CABINET_LIGHT_ROLES="chief-of-staff"'
(cd "$LW" && "$F" role remove helper) >/dev/null && rm "$LW/roles/helper.md" && lc "helper off"
out="$(cd "$LW" && lm "$F" role add helper --does "test" 2>&1)" && [[ "$out" == "$(cat "$FX/role-add-helper.txt")" ]] || fail "role add with an empty light model: $out"
(cd "$LW" && "$F" role remove helper) >/dev/null && rm "$LW/roles/helper.md"; le "$LW" CABINET_MODEL_LIGHT; le "$LW" CABINET_LIGHT_ROLES; lc "helper off"
# 1. The light model, with no list yet: the list of the four on the team (finance off). An existing list is kept.
cfl() { (cd "$LW" && lm "$F" config --yes "$@" 2>&1); }
cfl --model-light m-light >/dev/null || fail "config --model-light m-light"
grep -qx 'CABINET_MODEL_LIGHT="m-light"' "$LW/cabinet.env" && grep -qx 'CABINET_LIGHT_ROLES="chief-of-staff product-manager design-lead"' "$LW/cabinet.env" \
  && [[ "$(grep -c -e '^CABINET_MODEL_LIGHT=' -e '^CABINET_LIGHT_ROLES=' "$LW/cabinet.env")" == 2 ]] || fail "config --model-light: $(grep LIGHT "$LW/cabinet.env")"
cp "$LW/cabinet.env" "$T/l.keep"; st=0; out="$(cfl --model-light 'a$b')" || st=$?
((st)) && grep -qF 'CABINET_MODEL_LIGHT' <<<"$out" && cmp -s "$T/l.keep" "$LW/cabinet.env" || fail "config took the light model a\$b (exit $st): $out"
# 2. A role name that is not one.
st=0; out="$(cfl --light-roles "chief-of-staff Bad_Name")" || st=$?
((st)) && grep -qF 'Bad_Name' <<<"$out" && cmp -s "$T/l.keep" "$LW/cabinet.env" || fail "config took the role Bad_Name (exit $st): $out"
for v in 'qa;id' '$(id)' 'qa`id`' $'qa\nchief-of-staff'; do st=0; cfl --light-roles "$v" >/dev/null || st=$?; ((st)) && cmp -s "$T/l.keep" "$LW/cabinet.env" || fail "config took the roles '$v'"; done
st=0; out="$(cfl --light-roles $'qa\nchief-of-staff')" || st=$?; ((st)) && grep -qF CABINET_LIGHT_ROLES <<<"$out" || fail "a line break in --light-roles (exit $st): $out"
# 4a. A kit role turned on later: the main model, and a line saying how to move it.
cfl --model m-main >/dev/null; lc "main model"
out="$(cd "$LW" && lm "$F" role add finance 2>&1)" || fail "role add finance: $out"
[[ "$(grep -c finance <<<"$out")" -ge 1 && "$(grep -c 'main model' <<<"$out")" == 1 ]] \
  && grep 'main model' <<<"$out" | grep -qF -- '--light-roles "chief-of-staff product-manager design-lead finance"' && grep 'main model' <<<"$out" | grep -q '^finance ' \
  || fail "role add finance: $out"
grep -qx 'CABINET_LIGHT_ROLES="chief-of-staff product-manager design-lead"' "$LW/cabinet.env" || fail "role add finance changed the list"
[[ "$(jr finance)" == m-main ]] || fail "a finance job: $(runs)"
# 4b. A listed kit role turned back on: the light model.
(cd "$LW" && "$F" role remove design-lead) >/dev/null || fail "role remove design-lead"
out="$(cd "$LW" && lm "$F" role add design-lead 2>&1)" || fail "role add design-lead: $out"
[[ "$(grep -cx 'design-lead runs on the light model\.' <<<"$out")" == 1 ]] && ! grep -q 'main model' <<<"$out" || fail "role add design-lead: $out"
[[ "$(jr design-lead)" == m-light ]] || fail "a design-lead job: $(runs)"
# 1 (an existing list), set off then on again.
cfl --model-light off >/dev/null && grep -qx 'CABINET_MODEL_LIGHT=""' "$LW/cabinet.env" || fail "config --model-light off"
le "$LW" CABINET_LIGHT_ROLES 'CABINET_LIGHT_ROLES="qa"'; cfl --model-light m-light >/dev/null || fail "config --model-light again"
grep -qx 'CABINET_LIGHT_ROLES="qa"' "$LW/cabinet.env" && grep -qx 'CABINET_MODEL_LIGHT="m-light"' "$LW/cabinet.env" || fail "config replaced an existing list: $(grep LIGHT "$LW/cabinet.env")"
cfl --light-roles " chief-of-staff   design-lead " >/dev/null && grep -qx 'CABINET_LIGHT_ROLES="chief-of-staff design-lead"' "$LW/cabinet.env" || fail "config --light-roles"
cfl --light-roles "" >/dev/null && grep -qx 'CABINET_LIGHT_ROLES=""' "$LW/cabinet.env" || fail "config --light-roles \"\""
# 3. Which wins: a job's MODEL, then the light model for a listed role, then CABINET_MODEL.
lset m-main m-light chief-of-staff
[[ "$(br)" == m-light && "$(jr qa)" == m-main && "$(bj)" == m-job && "$(hr "$wq" qa)" == m-main ]] || fail "criterion 3: $(br) $(jr qa) $(bj) $(hr "$wq" qa)"
# 3a. Steps of handoff run and spec run.
lset m-main m-light "chief-of-staff design-lead"
[[ "$(hr "$wd" design-lead)" == m-light && "$(sr specs/s1.md chief-of-staff)" == m-light && "$(sr specs/s2.md backend)" == m-main ]] \
  || fail "criterion 3a: $(hr "$wd" design-lead) $(sr specs/s1.md chief-of-staff) $(sr specs/s2.md backend)"
# 3b. An empty list: every run on the main model, but for a job's own.
lset m-main m-light ""
[[ "$(br)" == m-main && "$(jr qa)" == m-main && "$(bj)" == m-job && "$(hr "$wq" qa)" == m-main && "$(hr "$wd" design-lead)" == m-main \
  && "$(sr specs/s1.md chief-of-staff)" == m-main && "$(sr specs/s2.md backend)" == m-main ]] || fail "criterion 3b: $(runs)"
# A light model that is not a model name starts no run, and names its own setting.
le "$LW" CABINET_MODEL_LIGHT "CABINET_MODEL_LIGHT='--yolo'"; le "$LW" CABINET_LIGHT_ROLES 'CABINET_LIGHT_ROLES="chief-of-staff"'
: > "$LL"; : > "$HOME/$LOGS/light/brief.log"; lm "$LW/bin/job.sh" run brief >/dev/null 2>&1 && fail "a run took the light model --yolo"
[[ -z "$(runs)" ]] && grep -qF "the model '--yolo' in cabinet.env is not a model name" "$HOME/$LOGS/light/brief.log" && grep -qF 'cabinet config --model-light off' "$HOME/$LOGS/light/brief.log" \
  || fail "a bad light model: $(runs) $(tail -2 "$HOME/$LOGS/light/brief.log")"
[[ "$(jr qa)" == m-main ]] || fail "a bad light model stopped a role not in the list"
# 4. A role of the project's own added later: the main model, the line, and its Claude Code file.
lset m-main m-light chief-of-staff; lc "light"
out="$(cd "$LW" && lm "$F" role add helper --does "test" 2>&1)" || fail "role add helper: $out"
[[ "$(grep -c helper <<<"$out")" -ge 1 && "$(grep -c 'main model' <<<"$out")" == 1 ]] && grep 'main model' <<<"$out" | grep -q '^helper ' \
  && grep 'main model' <<<"$out" | grep -qF -- '--light-roles "chief-of-staff helper"' || fail "role add helper with a light model: $out"
"$LW/bin/role.sh" build >/dev/null || fail "role build"
[[ "$(grep -c '^model:' "$LW/.claude/agents/helper.md")" == 1 ]] && grep -qx 'model: m-main' "$LW/.claude/agents/helper.md" || fail "helper's Claude Code file: $(grep '^model' "$LW/.claude/agents/helper.md")"
! grep -q '^model:' "$LW/agents/helper.md" || fail "agents/helper.md got a model line"
[[ "$(jr helper)" == m-main ]] || fail "a helper job: $(runs)"
# 10. A listed role removed: the list stays, a doctor note, and the brief still on the light model.
le "$LW" CABINET_LIGHT_ROLES 'CABINET_LIGHT_ROLES="chief-of-staff helper"'; lc "helper listed"
(cd "$LW" && "$F" role remove helper) >/dev/null || fail "role remove helper"
grep -qx 'CABINET_LIGHT_ROLES="chief-of-staff helper"' "$LW/cabinet.env" || fail "role remove changed the list"
out="$(lres model-light.roles)"; grep -q '^note .*helper' <<<"$out" && grep -qF -- '--light-roles "chief-of-staff"' <<<"$out" && [[ -z "$(lfix)" ]] || fail "doctor after helper left: $out $(lfix)"
[[ "$(br)" == m-light ]] || fail "the brief after helper left: $(runs)"
# 4c. A sub-team role: the main model in a job and in handoff run's steps (qa's first, then rev's).
le "$LW" CABINET_LIGHT_ROLES 'CABINET_LIGHT_ROLES="chief-of-staff"'; lc "list"
out="$(cd "$LW" && lm "$F" role add rev --reports-to qa --covers backend --does "test" 2>&1)" || fail "role add rev: $out"
[[ "$(grep -c 'main model' <<<"$out")" == 1 ]] && grep 'main model' <<<"$out" | grep -q '^rev ' && grep 'main model' <<<"$out" | grep -qF -- '--light-roles "chief-of-staff rev"' || fail "role add rev: $out"
[[ "$(jr rev)" == m-main ]] || fail "a rev job: $(runs)"
wr="$(work "For rev")"; v="$(review "$wr" qa)"
"$LW/bin/handoff.sh" record "$v" --role design-lead PASS --commits a1b2c3d --note specs/qa/n.md >/dev/null || fail "test setup: design-lead on $v"
[[ "$(hr "$wr" qa)" == m-main ]] || fail "handoff run's qa step for rev's work: $(runs)"
# After its trial, rev reviews in qa's place, so its step comes next.
L sub "$LW/roles/rev.md" -- '/^- Trial until: .*/' '- Trial until: 2020-01-01'
[[ "$(hr "$wr" rev)" == m-main ]] || fail "handoff run's rev step: $(runs)"
# 9. A listed name not on the team: a note, never a problem.
le "$LW" CABINET_LIGHT_ROLES 'CABINET_LIGHT_ROLES="nosuchrole"'
out="$(lres model-light.roles)"; grep -q '^note .*nosuchrole' <<<"$out" && grep -qF -- '--light-roles' <<<"$out" && [[ -z "$(lfix)" ]] || fail "doctor with nosuchrole: $out $(lfix)"
# 9a. The doctor checks the name as it does the main model's.
le "$LW" CABINET_MODEL_LIGHT "CABINET_MODEL_LIGHT='a\$b'"
grep -q '^fix ' <<<"$(lres model-light.name)" || fail "doctor model-light.name: $(lres model-light.name)"
le "$LW" CABINET_RUNNER 'CABINET_RUNNER="codex"'; lset m-main m-light chief-of-staff
out="$(LMODELS=m-main lres model-light.exists)"; grep -q '^fix .*m-light' <<<"$out" && grep -q '^ok ' <<<"$(LMODELS=m-main lres model.exists)" || fail "doctor model-light.exists: $out"
lset m-light "" chief-of-staff; grep -q '^fix ' <<<"$(LMODELS=m-main lres model.exists)" || fail "doctor model.exists with m-light"
lset m-main m-light chief-of-staff; grep -q '^ok ' <<<"$(LMODELS="m-main m-light" lres model-light.exists)" || fail "doctor model-light.exists listed: $(LMODELS="m-main m-light" lres model-light.exists)"
# config's note on a light model the runner does not list names the light model and its own option.
lset m-main "" chief-of-staff; out="$(cfl --model-light m-x)" || fail "config --model-light m-x with codex: $out"
grep -qxF "Light model m-x: not in codex's model list (codex debug models). It is written anyway; a run with it may fail. Change it with cabinet config --model-light <name>|off." <<<"$out" \
  && ! grep -q '^Model ' <<<"$out" || fail "config --model-light m-x note: $out"
le "$LW" CABINET_RUNNER 'CABINET_RUNNER="claude"'
# 1a, 8. The setup question: a light model writes the same two lines as config; Enter writes neither.
q1() {   # q1 <home> <light model answer>: setup in its own HOME, default team but finance
  mkdir -p "$1"; printf '%s\n' "Lq" "$1/p" "" "" "" "" "" "" "" n "" "" "" "" claude "" "$2" "" "" "" "" "" "" "" y n n > "$T/l-answers"
  HOME="$1" CABINET_TTY="$T/l-answers" lm "$F" new >/dev/null 2>&1 || fail "the light model question with '$2'"
}
q1 "$T/lh1" m-light; q1 "$T/lh2" ""
grep -qx 'CABINET_MODEL_LIGHT="m-light"' "$T/lh1/p/cabinet.env" && grep -qx 'CABINET_LIGHT_ROLES="chief-of-staff product-manager design-lead"' "$T/lh1/p/cabinet.env" || fail "setup with a light model: $(grep LIGHT "$T/lh1/p/cabinet.env")"
! grep -q -e '^CABINET_MODEL_LIGHT=' -e '^CABINET_LIGHT_ROLES=' "$T/lh2/p/cabinet.env" || fail "setup with Enter wrote a light model line"
[[ "$(grep -v -e '^CABINET_MODEL_LIGHT=' -e '^CABINET_LIGHT_ROLES=' "$T/lh1/p/cabinet.env")" == "$(grep -v -e '^CABINET_MODEL_LIGHT=' -e '^CABINET_LIGHT_ROLES=' "$T/lh2/p/cabinet.env")" ]] \
  || fail "setup with and without a light model differ: $(diff "$T/lh1/p/cabinet.env" "$T/lh2/p/cabinet.env")"
for x in lh1 lh2; do HOME="$T/$x" "$F" -C "$T/$x/p" remove --yes --force >/dev/null 2>&1 || true; done
# 5, 5a, 6, 8 (role files), in a workspace inside a project, so the project's .claude/agents/ is built too: the kit
# roles, helper, x (its own model: line) and y (frontmatter, no model: line).
mkdir -p "$LP"; git -C "$LP" init -q; echo x > "$LP/f"; git -C "$LP" add -A; git -C "$LP" commit -qm init
(cd "$LP" && lm "$F" init --yes --runner claude) >/dev/null || fail "init for the light model"
LI="$LP/cabinet"; [[ -f "$LI/cabinet.env" && -n "$(grep '^CABINET_LAYOUT="inside"' "$LI/cabinet.env")" ]] || fail "test setup: an inside workspace"
(cd "$LI" && "$F" role add helper --does "test") >/dev/null || fail "role add helper inside"
printf -- '---\nname: x\ndescription: X.\nmodel: own\n---\n\nYou are x.\n' > "$LI/roles/x.md"
printf -- '---\nname: y\ndescription: Y.\ntools: Read\n---\n\nYou are y.\n' > "$LI/roles/y.md"
cp "$LI/roles/x.md" "$T/l-x.md"; cp "$LI/roles/y.md" "$T/l-y.md"
cur="$(sed -n 's/^CABINET_ROLES="\(.*\)"$/\1/p' "$LI/cabinet.env")"
"$F" -C "$LI" config --yes --roles "$cur x y" >/dev/null || fail "test setup: x and y on the team"
snap() { rm -rf "$1"; mkdir -p "$1"; cp -R "$LI/agents" "$1/agents"; cp -R "$LI/.claude/agents" "$1/claude"; cp -R "$LP/.claude/agents" "$1/project"; }
cp "$LI/bin/lib.sh" "$T/l-lib.sh"; cp "$LI/bin/role.sh" "$T/l-role.sh"; cp "$FX/lib.sh" "$LI/bin/lib.sh"; cp "$FX/role.sh" "$LI/bin/role.sh"
"$LI/bin/role.sh" build >/dev/null || fail "4574648's role build"; snap "$T/lb-base"
cp "$T/l-lib.sh" "$LI/bin/lib.sh"; cp "$T/l-role.sh" "$LI/bin/role.sh"
[[ -f "$T/lb-base/project/x.md" && -f "$T/lb-base/claude/helper.md" && -f "$T/lb-base/agents/y.md" ]] || fail "test setup: the baseline: $(ls "$T/lb-base"/*)"
for r in claude codex antigravity qwen grok opencode cursor; do
  le "$LI" CABINET_RUNNER "CABINET_RUNNER=\"$r\""
  for mm in "" m-main; do
    if [[ -n "$mm" ]]; then le "$LI" CABINET_MODEL "CABINET_MODEL=\"$mm\""; else le "$LI" CABINET_MODEL; fi
    for ml in absent ""; do for lr in absent chief-of-staff; do
      if [[ "$ml" == absent ]]; then le "$LI" CABINET_MODEL_LIGHT; else le "$LI" CABINET_MODEL_LIGHT 'CABINET_MODEL_LIGHT=""'; fi
      if [[ "$lr" == absent ]]; then le "$LI" CABINET_LIGHT_ROLES; else le "$LI" CABINET_LIGHT_ROLES "CABINET_LIGHT_ROLES=\"$lr\""; fi
      "$LI/bin/role.sh" build >/dev/null || fail "role build with $r"; snap "$T/lb-now"
      diff -r "$T/lb-base" "$T/lb-now" >/dev/null || fail "role files with $r, model '$mm', light model $ml, roles $lr: $(diff -r "$T/lb-base" "$T/lb-now" | head -20)"
    done; done
  done
done
# 5. Claude Code and a light model: one model: line in .claude/agents/, none in agents/; x keeps its own.
le "$LI" CABINET_RUNNER 'CABINET_RUNNER="claude"'; le "$LI" CABINET_MODEL 'CABINET_MODEL="m-main"'
le "$LI" CABINET_MODEL_LIGHT 'CABINET_MODEL_LIGHT="m-light"'; le "$LI" CABINET_LIGHT_ROLES 'CABINET_LIGHT_ROLES="chief-of-staff"'
ml1() { [[ "$(grep '^model:' "$1" | paste -sd '|' -)" == "${2:-}" ]]; }   # ml1 <file> [<the model: lines, | between>]
"$LI/bin/role.sh" build >/dev/null || fail "role build with a light model"
for d in "$LI/.claude/agents" "$LP/.claude/agents"; do
  ml1 "$d/chief-of-staff.md" "model: m-light" && ml1 "$d/qa.md" "model: m-main" && ml1 "$d/x.md" "model: own" && ml1 "$d/y.md" "model: m-main" && ml1 "$d/helper.md" "model: m-main" \
    || fail "criterion 5 in $d: $(grep -H '^model:' "$d"/*.md)"
  awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { exit } f && /^model:/ { m = 1 } END { exit !m }' "$d/y.md" || fail "y's model line is not in its frontmatter: $(head -6 "$d/y.md")"
done
[[ "$(grep -l '^model:' "$LI/agents"/*.md)" == "$LI/agents/x.md" ]] || fail "agents/ got a model line: $(grep -H '^model:' "$LI/agents"/*.md)"
cmp -s "$T/l-x.md" "$LI/roles/x.md" && cmp -s "$T/l-y.md" "$LI/roles/y.md" || fail "role build changed roles/"
"$LI/bin/role.sh" build --check >/dev/null || fail "build --check after a build with model lines"
# 6. Another runner: the lines it added are gone; x's own stays.
le "$LI" CABINET_RUNNER 'CABINET_RUNNER="codex"'
"$LI/bin/role.sh" build >/dev/null || fail "role build with codex"
[[ "$(grep -l '^model:' "$LI/agents"/*.md "$LI/.claude/agents"/*.md "$LP/.claude/agents"/*.md | paste -sd ' ' -)" == "$LI/agents/x.md $LI/.claude/agents/x.md $LP/.claude/agents/x.md" ]] \
  && ml1 "$LI/.claude/agents/x.md" "model: own" || fail "criterion 6: $(grep -H '^model:' "$LI/agents"/*.md "$LI/.claude/agents"/*.md "$LP/.claude/agents"/*.md)"
cmp -s "$T/l-x.md" "$LI/roles/x.md" && cmp -s "$T/l-y.md" "$LI/roles/y.md" || fail "role build changed roles/ (codex)"
# 5a. No main model: only the listed role gets a line.
le "$LI" CABINET_RUNNER 'CABINET_RUNNER="claude"'; le "$LI" CABINET_MODEL
"$LI/bin/role.sh" build >/dev/null || fail "role build with no main model"
ml1 "$LI/.claude/agents/chief-of-staff.md" "model: m-light" && ml1 "$LI/.claude/agents/qa.md" && ml1 "$LI/.claude/agents/y.md" && ml1 "$LI/.claude/agents/x.md" "model: own" \
  || fail "criterion 5a: $(grep -H '^model:' "$LI/.claude/agents"/*.md)"
# 11. The docs.
grep -qF -- '--model-light' "$KIT/docs/commands.md" && grep -qF -- '--light-roles' "$KIT/docs/commands.md" && grep -qF 'runs on the main model. To put it on the light one' "$KIT/docs/commands.md" \
  && grep -qF 'runs on the light model.' "$KIT/docs/commands.md" && grep -qF -- '`--model-light' "$KIT/docs/agent-setup.md" && grep -qF 'CABINET_MODEL_LIGHT' "$KIT/docs/agent-setup.md" \
  && awk '/^## /{on = /^## 0\.3\.0 /} on' "$KIT/CHANGELOG.md" | grep -qF 'CABINET_MODEL_LIGHT' && awk '/^## /{on = /^## 0\.3\.0 /} on' "$KIT/CHANGELOG.md" | grep -qF 'CABINET_LIGHT_ROLES' \
  && grep -q 'model-light\.roles' "$KIT/docs/troubleshooting.md" && ! grep -qE 'model-light|light-roles' "$KIT/site/copy.js" || fail "a light model doc is missing"
for x in "$LW" "$LI"; do "$F" -C "$x" remove --yes --force >/dev/null 2>&1 || true; done
  return 0   # a last "check && fail" line must not end the run
}

section "guardrails scope: the gate asks only in Cabinet's repos, older rule files completed" ""
s70() {
# specs/guardrails-scope.md, criteria 1 to 18. Its own HOME, global git config and log folder, restored at the
# end; a local bare repo in the test folder is the only remote. Every push starts in a new session (setsid) with
# its input from /dev/null, so the gate can never open a terminal, and nothing reaches a real remote.
local oh="$HOME" og="$GIT_CONFIG_GLOBAL"
GH="$T/gs-home"; GS="$T/gs"; mkdir -p "$GH" "$GS"
export HOME="$GH" GIT_CONFIG_GLOBAL="$GH/.gitconfig"
printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$GIT_CONFIG_GLOBAL"
GK="$GH/.config/git/hooks" LG="$GH/$LOGS" GR="$GS/remote.git" NODE="$(command -v node)"
root=0; [[ "$(id -u)" == 0 ]] && root=1
git init -q --bare "$GR"
org() { git -C "$1" remote remove origin 2>/dev/null || true; git -C "$1" remote add origin "$GR"; }
grepo() { mkdir -p "$1" && git -C "$1" init -q -b main && echo x > "$1/f" && git -C "$1" add f && git -C "$1" commit -qm init && org "$1"; }
# gp <repo> [<source ref>] [VAR=value...]: one push with no terminal; prints asks, passes, or what happened.
gp() {
  local d=$1 src=HEAD b="b$RANDOM$RANDOM" out rc=0; shift; [[ $# -gt 0 && "$1" != *=* ]] && { src=$1; shift; }
  out="$(env "$@" "$NODE" -e '
    const c = require("node:child_process").spawn("git", ["-C", process.argv[1], "push", "-q", "origin", process.argv[2] + ":refs/heads/" + process.argv[3]],
      { detached: true, stdio: ["ignore", "pipe", "pipe"] });
    let o = ""; c.stdout.on("data", (d) => (o += d)); c.stderr.on("data", (d) => (o += d));
    c.on("error", (e) => { process.stdout.write(String(e)); process.exit(1); });
    c.on("close", (code) => { process.stdout.write(o); process.exit(code === null ? 1 : code); });' "$d" "$src" "$b" 2>&1)" || rc=$?
  if ((rc)) && [[ "$out" == *"push blocked"* ]] && ! git -C "$GR" rev-parse -q --verify "refs/heads/$b" >/dev/null; then echo asks
  elif ((rc == 0)) && git -C "$GR" rev-parse -q --verify "refs/heads/$b" >/dev/null; then echo passes
  else echo "other (exit $rc): $out"; fi
}
dj() { (cd "$1" && "$F" doctor --json 2>/dev/null) || true; }
# res <doctor json> <id>: "<level> <message>" for each result with that ID.
res() { j -r --arg i "$2" '$.results.filter((r) => r.id == $i).map((r) => r.level + " " + r.message).join("\n")' <<<"$1"; }
GW="$GS/ws"; "$F" new "$GW" --yes >/dev/null; RS="$(cd "$GS" && pwd -P)"
grepo "$GS/listed"; grepo "$GS/other"
printf 'listed\t-\t-\tno\t%s\n' "$GS/listed" >> "$GW/repos.tsv"
"$GW/bin/bootstrap.sh" > "$T/gs-boot.out" 2>&1 || true
cmp -s "$KIT/guardrails/pre-push" "$GK/pre-push" && cmp -s "$KIT/guardrails/cabinet-push-gate.js" "$GK/cabinet-push-gate.js" || fail "bootstrap did not place the push gate and its helper"
[[ -f "$LG/ws/workspace" ]] || fail "no claim for the test workspace in $LG"

# Part 1. Criteria 1 and 2.
[[ "$(gp "$GS/listed")" == asks ]] || fail "criterion 1: a push from a listed repo: $(gp "$GS/listed")"
[[ "$(gp "$GS/other")" == passes ]] || fail "criterion 2: a push from a repo in no workspace: $(gp "$GS/other")"
printf '#!/bin/sh\nexit 1\n' > "$GS/other/.git/hooks/pre-push"; chmod +x "$GS/other/.git/hooks/pre-push"
[[ "$(gp "$GS/other")" == "other (exit 1)"* ]] || fail "criterion 2: the repo's own pre-push failing did not stop the push"
printf '#!/bin/sh\necho "$@" > "%s"\ncat > "%s"\n' "$GS/args" "$GS/stdin" > "$GS/other/.git/hooks/pre-push"
[[ "$(gp "$GS/other" refs/heads/main)" == passes ]] || fail "criterion 2: a push with the repo's own pre-push"
[[ "$(cat "$GS/args")" == "origin $GR" ]] || fail "criterion 2: the repo's own pre-push got other arguments: $(cat "$GS/args")"
[[ "$(wc -l < "$GS/stdin" | tr -d ' ')" == 1 ]] && grep -qE "^refs/heads/main $(git -C "$GS/other" rev-parse HEAD) refs/heads/b[0-9]+ 0{40}\$" "$GS/stdin" \
  || fail "criterion 2: the repo's own pre-push got other input: $(cat "$GS/stdin")"
rm -f "$GS/other/.git/hooks/pre-push"
# 3(a) a session worktree of a listed repo; (b) the workspace itself; (c) a repo only the second workspace lists;
# (d) a second clone of a listed repo, elsewhere; (e) a repo inside a workspace folder, in no repos.tsv.
s="$("$GW/bin/session.sh" start gs1 --repo listed 2>/dev/null | tail -1)"; s="$GW/sessions/listed/gs1"
[[ -e "$s/.git" ]] || fail "criterion 3(a): no session worktree"
[[ "$(gp "$s")" == asks ]] || fail "criterion 3(a): a push from a session worktree: $(gp "$s")"
org "$GW"
[[ "$(gp "$GW")" == asks ]] || fail "criterion 3(b): a push from the workspace: $(gp "$GW")"
GW2="$GS/ws2"; "$F" new "$GW2" --yes >/dev/null; grepo "$GS/second"
printf 'second\t-\t-\tno\t%s\n' "$GS/second" >> "$GW2/repos.tsv"
[[ -f "$LG/ws2/workspace" ]] || fail "no claim for the second workspace"
[[ "$(gp "$GS/second")" == asks ]] || fail "criterion 3(c): a repo the second workspace lists: $(gp "$GS/second")"
git clone -q "$GS/listed" "$GS/clone2"; org "$GS/clone2"
[[ "$(gp "$GS/clone2")" == passes ]] || fail "criterion 3(d): a second clone of a listed repo: $(gp "$GS/clone2")"
grepo "$GW/inner"
[[ "$(gp "$GW/inner")" == asks ]] || fail "criterion 3(e): a repo inside a workspace: $(gp "$GW/inner")"
# 3(f) a row in another letter case, on a volume that ignores case; 3(g) a row for a folder not on this machine.
touch "$GS/CaseProbe"
if [[ "$(uname)" == Darwin && -e "$GS/caseprobe" ]]; then
  grepo "$GS/repo-a"; printf 'repo-a\t-\t-\tno\t%s\n' "$GS/Repo-A" >> "$GW/repos.tsv"
  [[ "$(gp "$GS/repo-a")" == asks ]] || fail "criterion 3(f): a row in another letter case: $(gp "$GS/repo-a")"
else echo "  note: criterion 3(f) skipped: this volume is case-sensitive (or this is Linux)"; fi
printf 'ghost\t-\t-\tno\t%s\n' "$GS/not-here" >> "$GW/repos.tsv"
[[ "$(gp "$GS/listed")" == asks && "$(gp "$GS/other")" == passes ]] || fail "criterion 3(g): a row for a folder not on this machine"

# Criterion 4: the gate fails closed; the push of criterion 2 asks in each case.
mv "$GW" "$GW-away"
[[ "$(gp "$GS/other")" == asks ]] || fail "criterion 4(a): a claimed workspace renamed away: $(gp "$GS/other")"
# Criterion 5: the doctor notes the claim, with the commands that free it.
out="$(dj "$GW2")"
res "$out" guardrails.stale-claim | grep -F "note the slug 'ws' is still held by a workspace at $(cd "$GS" && pwd -P)/ws, which no longer exists" | grep -F "$(pf sched_stop_cmd "ai.cabinet.ws.<job>")" \
  | grep -qF "then delete $(pf eval 'echo $LOGROOT_SHOWN')/ws/workspace" || fail "criterion 5: the doctor did not note the stale claim: $(res "$out" guardrails.stale-claim)"
mv "$GW-away" "$GW"
if ((root)); then echo "  note: criteria 4(b), 4(c), 4(d) unreadable and 4(h) EACCES skipped as root"; else
  chmod 000 "$LG"; r="$(gp "$GS/other")"; chmod 755 "$LG"
  [[ "$r" == asks ]] || fail "criterion 4(b): the log folder unreadable: $r"
  chmod 000 "$LG/ws2/workspace"; r="$(gp "$GS/other")"; chmod 644 "$LG/ws2/workspace"
  [[ "$r" == asks ]] || fail "criterion 4(c): one claim unreadable: $r"
fi
mv "$GW/repos.tsv" "$GS/repos.tsv.away"; r="$(gp "$GS/other")"; mv "$GS/repos.tsv.away" "$GW/repos.tsv"
[[ "$r" == asks ]] || fail "criterion 4(d): a workspace without repos.tsv: $r"
if ((root == 0)); then
  chmod 000 "$GW/repos.tsv"; r="$(gp "$GS/other")"; chmod 644 "$GW/repos.tsv"
  [[ "$r" == asks ]] || fail "criterion 4(d): repos.tsv unreadable: $r"
fi
# 4(e) the log folder empty, then absent: on Linux through XDG_STATE_HOME, on macOS through HOME.
if [[ "$(uname)" == Darwin ]]; then mkdir -p "$GS/eh/Library/Logs/cabinet"; e1=(HOME="$GS/eh"); e2=(HOME="$GS/ah")
else mkdir -p "$GS/es/cabinet"; e1=(XDG_STATE_HOME="$GS/es"); e2=(XDG_STATE_HOME="$GS/as"); fi
[[ "$(gp "$GS/other" HEAD "${e1[@]}")" == asks ]] || fail "criterion 4(e): an empty log folder: $(gp "$GS/other" HEAD "${e1[@]}")"
[[ "$(gp "$GS/other" HEAD "${e2[@]}")" == asks ]] || fail "criterion 4(e): no log folder: $(gp "$GS/other" HEAD "${e2[@]}")"
# 4(f) a bare repo has no top folder.
git clone -q --bare "$GS/other" "$GS/bare.git"; org "$GS/bare.git"
[[ "$(gp "$GS/bare.git")" == asks ]] || fail "criterion 4(f): a push from a bare repo: $(gp "$GS/bare.git")"
# 4(g) no node on PATH, then a node that fails.
mkdir -p "$GS/nonode" "$GS/badnode"
for t in git sh cat dirname; do ln -sf "$(command -v "$t")" "$GS/nonode/$t"; done
printf '#!/bin/sh\nexit 1\n' > "$GS/badnode/node"; chmod +x "$GS/badnode/node"
[[ "$(gp "$GS/other" HEAD PATH="$GS/nonode")" == asks ]] || fail "criterion 4(g): no node: $(gp "$GS/other" HEAD PATH="$GS/nonode")"
[[ "$(gp "$GS/other" HEAD PATH="$GS/badnode:$PATH")" == asks ]] || fail "criterion 4(g): a node that fails: $(gp "$GS/other" HEAD PATH="$GS/badnode:$PATH")"
# 4(h) a row that cannot be resolved for another reason than ENOENT: EACCES, then ELOOP.
cp "$GW/repos.tsv" "$GS/repos.tsv.before"
if ((root == 0)); then
  mkdir -p "$GS/locked"; chmod 000 "$GS/locked"; printf 'locked\t-\t-\tno\t%s\n' "$GS/locked/x" >> "$GW/repos.tsv"
  r="$(gp "$GS/other")"; chmod 755 "$GS/locked"; cp "$GS/repos.tsv.before" "$GW/repos.tsv"
  [[ "$r" == asks ]] || fail "criterion 4(h): a row in a folder no one can read: $r"
fi
ln -s loop "$GS/loop"; printf 'loop\t-\t-\tno\t%s\n' "$GS/loop" >> "$GW/repos.tsv"
r="$(gp "$GS/other")"; cp "$GS/repos.tsv.before" "$GW/repos.tsv"
[[ "$r" == asks ]] || fail "criterion 4(h): a row that is a symlink loop: $r"
[[ "$(gp "$GS/other")" == passes ]] || fail "the push of criterion 2 does not pass again after the fail-closed cases"
# The project around a workspace named cabinet, with no row for it (init --inside writes one with the path ..):
# the project asks, a repo beside it does not.
grepo "$GS/proj"; (cd "$GS/proj" && "$F" init --yes --inside) >/dev/null 2>&1 || fail "init --inside for the project case"
awk -F'\t' '$5 != ".."' "$GS/proj/cabinet/repos.tsv" > "$GS/proj.tsv" && cat "$GS/proj.tsv" > "$GS/proj/cabinet/repos.tsv"
! grep -q $'\t\\.\\.$' "$GS/proj/cabinet/repos.tsv" || fail "the project case: $(cat "$GS/proj/cabinet/repos.tsv")"
grepo "$GS/projsib"
[[ "$(gp "$GS/proj")" == asks ]] || fail "the project around a cabinet/ workspace, with no .. row: $(gp "$GS/proj")"
[[ "$(gp "$GS/projsib")" == passes ]] || fail "a repo beside the project around a cabinet/ workspace: $(gp "$GS/projsib")"
# A workspace with no claim: the doctor says so, and bootstrap with no scheduler writes it.
GW4="$GS/ws4"; "$F" new "$GW4" --yes >/dev/null; rm -f "$LG/ws4/workspace"; grepo "$GW4/inner"
res "$(dj "$GW4")" guardrails.claim | grep -qxF "fix no claim in $(pf eval 'echo $LOGROOT_SHOWN')/ws4 names this workspace, so the push gate does not ask in its repos (run bin/bootstrap.sh)" \
  || fail "the doctor on a workspace with no claim: $(res "$(dj "$GW4")" guardrails.claim)"
CABINET_SCHEDULER=none "$GW4/bin/bootstrap.sh" > "$GS/boot4.out" 2>&1 || true
grep -qF 'no scheduler found' "$GS/boot4.out" && [[ "$(cat "$LG/ws4/workspace" 2>/dev/null)" == "$RS/ws4" ]] || fail "bootstrap with no scheduler did not write the claim: $(cat "$LG/ws4/workspace" 2>&1)"
[[ "$(gp "$GW4/inner")" == asks ]] || fail "a repo in a workspace bootstrapped with no scheduler: $(gp "$GW4/inner")"
res "$(dj "$GW4")" guardrails.claim | grep -q '^ok ' || fail "the doctor after bootstrap wrote the claim: $(res "$(dj "$GW4")" guardrails.claim)"
# A claim naming this workspace through a link is its own, as the doctor reads it: bootstrap lists it nowhere else.
ln -s "$GW4" "$GS/ws4-link"; echo "$GS/ws4-link" > "$LG/ws4/workspace"; out="$("$GW4/bin/bootstrap.sh" 2>&1 || true)"
! grep -qF "belongs to" <<<"$out" && [[ ! -e "$LG/ws4/shared" && "$(cat "$LG/ws4/workspace")" == "$RS/ws4" ]] || fail "a claim through a link: $(grep -F "log folder" <<<"$out"); $(cat "$LG/ws4/shared" 2>&1)"
# A log folder that cannot be made: bootstrap says so and fails, and goes on with the rest.
if ((root == 0)); then
  mv "$LG/ws4" "$GS/ws4-logs"; chmod 555 "$LG"; out="$("$GW4/bin/bootstrap.sh" 2>&1)" && fail "bootstrap with no log folder succeeded"; chmod 755 "$LG"
  grep -qF "the log folder $LG/ws4 could not be made, so the push gate may not ask in this workspace's repos" <<<"$out" || fail "a log folder that cannot be made: $out"
  rm -rf "$LG/ws4"; mv "$GS/ws4-logs" "$LG/ws4"
fi
# A second workspace with the slug another holds: the doctor says so, and after bootstrap the gate asks in its repos.
GW3="$GS/ws3"; "$F" new "$GW3" --yes >/dev/null; rm -rf "$LG/ws3"; grepo "$GW3/inner"
sed 's/^CABINET_SLUG=.*/CABINET_SLUG="ws"/' "$GW3/cabinet.env" > "$GS/ws3.env" && cat "$GS/ws3.env" > "$GW3/cabinet.env"
res "$(dj "$GW3")" guardrails.claim | grep -qxF "fix the slug 'ws' is held by the workspace at $RS/ws and no claim in $(pf eval 'echo $LOGROOT_SHOWN')/ws names this one, so the push gate does not ask in its repos (run bin/bootstrap.sh, then give this one its own slug: cabinet config --slug <name>)" \
  || fail "the doctor on a workspace whose slug another holds: $(res "$(dj "$GW3")" guardrails.claim)"
out="$("$GW3/bin/bootstrap.sh" 2>&1 || true)"
grep -qF "until then the push gate still asks in this workspace's repos" <<<"$out" && grep -qxF "$RS/ws3" "$LG/ws/shared" && [[ "$(head -1 "$LG/ws/workspace")" == "$RS/ws" ]] \
  || fail "bootstrap of a workspace whose slug another holds: $(grep -F 'log folder' <<<"$out"); shared: $(cat "$LG/ws/shared" 2>&1)"
"$GW3/bin/bootstrap.sh" >/dev/null 2>&1 || true; [[ "$(grep -cxF "$RS/ws3" "$LG/ws/shared")" == 1 ]] || fail "a second bootstrap listed the workspace twice"
org "$GW3"
[[ "$(gp "$GW3/inner")" == asks && "$(gp "$GW3")" == asks ]] || fail "a workspace whose slug another holds, after bootstrap: $(gp "$GW3/inner"), $(gp "$GW3")"
res "$(dj "$GW3")" guardrails.claim | grep -qxF "fix the slug 'ws' is held by the workspace at $RS/ws: the push gate still asks in this workspace's repos, but its schedules and log folder are that workspace's (give this one its own slug: cabinet config --slug <name>)" \
  || fail "the doctor after bootstrap listed it: $(res "$(dj "$GW3")" guardrails.claim)"
res "$(dj "$GW")" guardrails.claim | grep -q '^ok ' || fail "the doctor of the slug's owner: $(res "$(dj "$GW")" guardrails.claim)"
# A listed workspace that is gone has nothing left to guard: it makes no other push ask.
mv "$GW3" "$GW3-away"; r="$(gp "$GS/other")"; mv "$GW3-away" "$GW3"
[[ "$r" == passes ]] || fail "a listed workspace that is gone: $r"
# Only gone workspaces claimed (the owner's claim deleted, every listed one gone): no workspace is left that the
# gate could know, so it asks, as with no claim at all; one live listed workspace, and it says outside.
I1="$GS/i1-home"; mkdir -p "$I1/$LOGS/x"; echo "$GS/gone" > "$I1/$LOGS/x/shared"
r="$(HOME="$I1" XDG_STATE_HOME= "$NODE" "$GK/cabinet-push-gate.js" "$GS/other" "$GS/other/.git" 2>/dev/null)" && fail "only gone workspaces claimed, the helper said: $r"
echo "$GW" >> "$I1/$LOGS/x/shared"; r="$(HOME="$I1" XDG_STATE_HOME= "$NODE" "$GK/cabinet-push-gate.js" "$GS/other" "$GS/other/.git" 2>&1)"
[[ "$r" == outside ]] || fail "a gone and a live workspace claimed: $r"

# Criterion 6(a): the gate and its helper read only HOME, XDG_STATE_HOME and PATH from the environment.
SCAN='
  const fs = require("node:fs"), ok = ["HOME", "XDG_STATE_HOME", "PATH"], bad = [];
  const sh = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");
  const set = new Set([...sh.matchAll(/(?:^|[;&|\s])([A-Za-z_][A-Za-z0-9_]*)=/g)].map((m) => m[1]).concat([...sh.matchAll(/\bread\s+(?:-r\s+)?([A-Za-z_][A-Za-z0-9_]*)/g)].map((m) => m[1])));
  for (const m of sh.matchAll(/\$\{?([A-Za-z_][A-Za-z0-9_]*)/g)) if (!set.has(m[1]) && !ok.includes(m[1])) bad.push("pre-push reads $" + m[1]);
  if (/\$\{!|\beval\b|\bprintenv\b|(^|[;&|\s(])env\b|\bexport\s+-p\b|(^|[;&|(]\s*)set\s*($|[;&|)])/m.test(sh)) bad.push("pre-push reads the environment another way");
  const js = fs.readFileSync(process.argv[2], "utf8");
  for (const m of js.matchAll(/\bprocess\.env\b(\s*\.\s*([A-Za-z_$][\w$]*)|\s*\[\s*("([^"]*)"|\x27([^\x27]*)\x27)\s*\])?/g)) {
    const name = m[2] ?? m[4] ?? m[5];
    if (name === undefined) bad.push("cabinet-push-gate.js uses process.env as a whole, or with a computed name: " + m[0]);
    else if (!ok.includes(name)) bad.push("cabinet-push-gate.js reads " + name);
  }
  if (/\{[^}]*\}\s*=\s*process\.env\b/.test(js)) bad.push("cabinet-push-gate.js destructures process.env");
  if (bad.length) { console.log(bad.join("; ")); process.exit(1); }'
node -e "$SCAN" "$KIT/guardrails/pre-push" "$KIT/guardrails/cabinet-push-gate.js" || fail "criterion 6(a): the gate reads more of the environment"
# The scan catches what it should: one more variable, eval, or process.env passed on.
{ cat "$KIT/guardrails/pre-push"; echo 'echo "${CABINET_AGENT:-}"'; } > "$GS/x1"; { cat "$KIT/guardrails/pre-push"; echo 'eval "$refs"'; } > "$GS/x2"
{ cat "$KIT/guardrails/cabinet-push-gate.js"; echo 'f(process.env);'; } > "$GS/x3.js"; { cat "$KIT/guardrails/cabinet-push-gate.js"; echo 'process.env["CABINET_AGENT"];'; } > "$GS/x4.js"
for x in "$GS/x1 $KIT/guardrails/cabinet-push-gate.js" "$GS/x2 $KIT/guardrails/cabinet-push-gate.js" "$KIT/guardrails/pre-push $GS/x3.js" "$KIT/guardrails/pre-push $GS/x4.js"; do
  ! node -e "$SCAN" $x >/dev/null || fail "criterion 6(a): the scan missed a reading in $x"
done
# Criterion 6(b): the variables of a Cabinet run change nothing.
[[ "$(gp "$GS/listed" HEAD CABINET_AGENT=backend CABINET_CREDIT=on)" == asks ]] || fail "criterion 6(b): a push in a Cabinet run"

# Criterion 7: bootstrap replaces only the kit's own gate.
boot() { "$GW/bin/bootstrap.sh" 2>&1 || true; }
cp "$KIT/test/fixtures/30017c9/pre-push" "$GK/pre-push"; boot >/dev/null
cmp -s "$KIT/guardrails/pre-push" "$GK/pre-push" || fail "criterion 7: the 0.1.0 gate was not replaced"
{ sed -n 1p "$KIT/test/fixtures/30017c9/pre-push"; echo "# cabinet push gate v1"; sed 1d "$KIT/test/fixtures/30017c9/pre-push"; } > "$GK/pre-push"; boot >/dev/null
cmp -s "$KIT/guardrails/pre-push" "$GK/pre-push" || fail "criterion 7: a v1 gate was not replaced"
sed 's/push cancelled/push canceled/' "$KIT/test/fixtures/30017c9/pre-push" > "$GK/pre-push"; cp "$GK/pre-push" "$GS/gate-mine"
out="$(boot)"; cmp -s "$GS/gate-mine" "$GK/pre-push" || fail "criterion 7: a changed gate was replaced"
grep -qF "differs, left as is: $GK/pre-push" <<<"$out" || fail "criterion 7: bootstrap did not say it left the gate: $(grep -F pre-push <<<"$out")"
out="$(dj "$GW")"
res "$out" guardrails.push-gate | grep -q '^ok ' && res "$out" guardrails.push-gate | grep '^note ' | grep -F 'asks before every push in every repo' | grep -qF 'move or delete that file, then run cabinet bootstrap' \
  || fail "criterion 7: the doctor on a changed gate: $(res "$out" guardrails.push-gate)"
rm -f "$GK/pre-push"; boot >/dev/null; out="$(dj "$GW")"
cmp -s "$KIT/guardrails/pre-push" "$GK/pre-push" && res "$out" guardrails.push-gate | grep -q '^ok ' && ! res "$out" guardrails.push-gate | grep -q '^note ' \
  || fail "criterion 7: the doctor on the kit's gate: $(res "$out" guardrails.push-gate)"

# Part 2. Criterion 8: a hooks folder set in any scope, in any of Cabinet's folders, is a FIX with both ways back.
OH="$GS/own-hooks"
hp() {  # hp <folder> <file that sets it> [VAR=value...]: the doctor's repo-hookspath FIX for that folder
  local d=$1 f=$2 out; shift 2
  out="$( (cd "$GW" && env "$@" "$F" doctor --json 2>/dev/null) || true)"
  res "$out" guardrails.repo-hookspath | grep -F "fix $d uses core.hooksPath $OH, set in $f" | grep -F "unset it (git -C $d config --file $f --unset core.hooksPath)" \
    | grep -qF "or add a pre-push in $OH that runs the global push gate" || { echo "$d: $(res "$out" guardrails.repo-hookspath)"; return 1; }
}
git -C "$GS/listed" config core.hooksPath "$OH"
hp "$RS/listed" .git/config || fail "criterion 8: local config"
git -C "$GS/listed" config --unset core.hooksPath
git -C "$GS/listed" config extensions.worktreeConfig true; git -C "$GS/listed" config --worktree core.hooksPath "$OH"
hp "$RS/listed" .git/config.worktree || fail "criterion 8: worktree config"
git -C "$GS/listed" config --worktree --unset core.hooksPath
printf '[core]\n\thooksPath = %s\n' "$OH" > "$GS/inc.gitconfig"; git -C "$GS/listed" config include.path "$GS/inc.gitconfig"
hp "$RS/listed" "$GS/inc.gitconfig" || fail "criterion 8: an included file"
git -C "$GS/listed" config --unset include.path
printf '[core]\n\thooksPath = %s\n' "$OH" > "$GS/system.gitconfig"
# Git reads the global config after the system one, so the system's value is the one git uses only while the global sets none.
printf '[user]\n\tname = Test\n' > "$GS/global-nohooks"
hp "$RS/listed" "$GS/system.gitconfig" -u GIT_CONFIG_NOSYSTEM GIT_CONFIG_SYSTEM="$GS/system.gitconfig" GIT_CONFIG_GLOBAL="$GS/global-nohooks" || fail "criterion 8: the system config"
hp "$RS/listed" .git/config >/dev/null 2>&1 && fail "criterion 8: a FIX with nothing set"
git -C "$GW" config core.hooksPath "$OH"
hp "$RS/ws" .git/config || fail "criterion 8: the workspace"
git -C "$GW" config --unset core.hooksPath
git -C "$s" config --worktree core.hooksPath "$OH"
hp "$RS/ws/sessions/listed/gs1" "$(git -C "$s" rev-parse --path-format=absolute --git-dir)/config.worktree" || hp "$RS/ws/sessions/listed/gs1" "$(cd "$(git -C "$s" rev-parse --git-dir)" && pwd -P)/config.worktree" \
  || fail "criterion 8: a session worktree"
git -C "$s" config --worktree --unset core.hooksPath; git -C "$GS/listed" config --unset extensions.worktreeConfig
# Criterion 9: the global folder set locally is fine; a repo that is not Cabinet's is never read.
git -C "$GS/listed" config core.hooksPath "$GK"; git -C "$GS/other" config core.hooksPath "$OH"
out="$(dj "$GW")"; [[ -z "$(res "$out" guardrails.repo-hookspath)" ]] || fail "criterion 9: $(res "$out" guardrails.repo-hookspath)"
git -C "$GS/listed" config --unset core.hooksPath; git -C "$GS/other" config --unset core.hooksPath

# Part 3. Codex, Gemini CLI and agy: a PATH without the real tools (node and git linked), and a fake codex.
mkdir -p "$GS/tools" "$GS/fake" "$GH/.codex/rules" "$GH/.gemini/policies" "$GH/.gemini/antigravity-cli"
ln -sf "$NODE" "$GS/tools/node"; ln -sf "$(command -v git)" "$GS/tools/git"
CP="$T/shim:$GS/tools:/usr/bin:/bin" FP="$GS/fake:$T/shim:$GS/tools:/usr/bin:/bin"
for t in codex gemini agy; do ! PATH="$CP" command -v "$t" >/dev/null || fail "$t is in /usr/bin or /bin: the Part 3 tests need it off PATH"; done
printf '#!/bin/sh\n[ "$1 $2" = "execpolicy check" ] || exit 1\nif [ -e "%s" ] && grep -qF %s "$4"; then echo %s; else echo %s; fi\n' \
  "$GS/codex-forbids" "'prefix_rule(pattern = [\"git\", \"push\"]'" "'{\"decision\":\"forbidden\"}'" "'{\"decision\":\"allow\"}'" > "$GS/fake/codex"; chmod +x "$GS/fake/codex"
CX="$GH/.codex/rules/default.rules" GM="$GH/.gemini/policies/owner-control.toml" AG="$GH/.gemini/antigravity-cli/settings.json" FX="$KIT/test/fixtures/30017c9"
dp() { local p=$1; shift; (cd "$GW" && PATH="$p" "$F" doctor "$@" 2>/dev/null) || true; }
three() { for i in guardrails.codex guardrails.gemini guardrails.agy; do res "$1" "$i"; done; }
# Criterion 10: all present.
cp "$KIT/guardrails/codex-default.rules" "$CX"; cp "$KIT/guardrails/gemini-owner-control.toml" "$GM"; cp "$KIT/guardrails/agy-permissions.json" "$AG"; touch "$GS/codex-forbids"
out="$(dp "$FP" --json)"
[[ "$(three "$out" | grep -c '^ok ')" == 3 && -z "$(three "$out" | grep -v '^ok ')" ]] || fail "criterion 10: $(three "$out")"
rm -f "$GS/codex-forbids"; out="$(dp "$FP" --json)"
res "$out" guardrails.codex | grep -q '^fix ' || fail "criterion 10: codex no longer forbidding git push: $(res "$out" guardrails.codex)"
# Criterion 11: older files, and the kit's files less one rule.
c11() {  # c11 <what>: each FIX names 1 missing rule and its file, and says run cabinet bootstrap
  local out; out="$(dp "$CP" --json)"
  res "$out" guardrails.codex | grep -qxF 'fix Codex is missing 1 kit rule(s) in ~/.codex/rules/default.rules (run cabinet bootstrap)' \
    && res "$out" guardrails.gemini | grep -qxF 'fix Gemini CLI is missing 1 kit rule(s) in ~/.gemini/policies/owner-control.toml (run cabinet bootstrap)' \
    && res "$out" guardrails.agy | grep -qxF 'fix agy is missing 1 deny rule(s) in ~/.gemini/antigravity-cli/settings.json (run cabinet bootstrap)' \
    && [[ "$(dp "$CP" | tail -1)" != "All good"* ]] || fail "criterion 11, $1: $(three "$out")"
}
j '({...$, permissions: {...$.permissions, deny: $.permissions.deny.slice(1)}})' "$KIT/guardrails/agy-permissions.json" > "$AG"
cp "$FX/codex-default.rules" "$CX"; cp "$FX/gemini-owner-control.toml" "$GM"; c11 "the 0.1.0 files"
grep -v 'gh", "release' "$KIT/guardrails/codex-default.rules" > "$CX"
awk 'BEGIN { RS = ""; ORS = "\n\n" } !/commandPrefix = "gh release"/' "$KIT/guardrails/gemini-owner-control.toml" > "$GM"; c11 "the kit's files less one rule"
cp "$KIT/guardrails/agy-permissions.json" "$AG"
# Criterion 12: bootstrap adds the missing rules after the owner's lines, with one backup, once.
own_c='prefix_rule(pattern = ["make", "deploy"], decision = "prompt")'
own_g=$'\n[[rule]]\ntoolName = "run_shell_command"\ncommandPrefix = "make deploy"\ndecision = "ask_user"\npriority = 500\n'
{ cat "$FX/codex-default.rules"; echo "$own_c"; } > "$GS/c12"; { cat "$FX/gemini-owner-control.toml"; printf '%s' "$own_g"; } > "$GS/g12"
bk() { ls "$(dirname "$1")" | grep -c "^$(basename "$1")\.bak\." || true; }
c12() {  # c12 <codex file> <gemini file>: the result of criterion 12 in each
  [[ "$(head -c "$(wc -c < "$GS/c12")" "$1")" == "$(cat "$GS/c12")" ]] && [[ "$(tail -n +"$(($(wc -l < "$GS/c12") + 1))" "$1")" == "$(printf '%s\n%s' '# Added by cabinet bootstrap: rules from a newer Cabinet kit' "$(grep secret-tool "$KIT/guardrails/codex-default.rules")")" ]] \
    && cmp -s <(head -c "$(wc -c < "$GS/g12")" "$2") "$GS/g12" && [[ "$(tail -n +"$(($(wc -l < "$GS/g12") + 1))" "$2" | head -1)" == '# Added by cabinet bootstrap: rules from a newer Cabinet kit' ]] \
    && tail -n +"$(($(wc -l < "$GS/g12") + 2))" "$2" | head -1 | grep -qx '\[\[rule\]\]' && tail -4 "$2" | grep -qF 'cabinet/passphrases'
}
cp "$GS/c12" "$CX"; cp "$GS/g12" "$GM"; rm -f "$CX".bak.* "$GM".bak.*
PATH="$CP" "$GW/bin/bootstrap.sh" > "$GS/boot12.out" 2>&1 || true
c12 "$CX" "$GM" || { cat "$CX" "$GM"; fail "criterion 12: the files are not the owner's bytes, a comment line, then the missing rule"; }
[[ "$(bk "$CX")" == 1 && "$(bk "$GM")" == 1 ]] && cmp -s "$CX".bak.* "$GS/c12" && cmp -s "$GM".bak.* "$GS/g12" || fail "criterion 12: not exactly one backup equal to the file before"
grep -qF "added 1 kit rule(s) to $CX" "$GS/boot12.out" && grep -qF "added 1 kit rule(s) to $GM" "$GS/boot12.out" || fail "criterion 12: bootstrap did not say what it added: $(cat "$GS/boot12.out")"
out="$(dp "$CP" --json)"; res "$out" guardrails.codex | grep -q '^ok ' && res "$out" guardrails.gemini | grep -q '^ok ' || fail "criterion 12: the doctor after bootstrap: $(three "$out")"
cp "$CX" "$GS/c12-after"; cp "$GM" "$GS/g12-after"
PATH="$CP" "$GW/bin/bootstrap.sh" >/dev/null 2>&1 || true
cmp -s "$CX" "$GS/c12-after" && cmp -s "$GM" "$GS/g12-after" && [[ "$(bk "$CX")" == 1 && "$(bk "$GM")" == 1 ]] || fail "criterion 12: a second bootstrap changed a file or made another backup"
# Criterion 13: a symlinked file stays a link, and its target holds the result.
mkdir -p "$GH/dotfiles"; cp "$GS/c12" "$GH/dotfiles/codex.rules"; cp "$GS/g12" "$GH/dotfiles/gemini.toml"
rm -f "$CX" "$GM" "$CX".bak.* "$GM".bak.*; ln -s "$GH/dotfiles/codex.rules" "$CX"; ln -s "$GH/dotfiles/gemini.toml" "$GM"
PATH="$CP" "$GW/bin/bootstrap.sh" >/dev/null 2>&1 || true
[[ -L "$CX" && "$(readlink "$CX")" == "$GH/dotfiles/codex.rules" && -L "$GM" && "$(readlink "$GM")" == "$GH/dotfiles/gemini.toml" ]] || fail "criterion 13: a symlink was replaced"
cmp -s "$GH/dotfiles/codex.rules" "$GS/c12-after" && cmp -s "$GH/dotfiles/gemini.toml" "$GS/g12-after" || fail "criterion 13: the target does not hold the result"
[[ "$(bk "$CX")" == 1 && ! -L "$(ls "$CX".bak.*)" ]] && cmp -s "$CX".bak.* "$GS/c12" || fail "criterion 13: the backup is not a copy beside the link"
rm -f "$CX" "$GM" "$CX".bak.* "$GM".bak.*
# Criterion 14: a backup that cannot be written leaves the file as it is.
if ((root)); then echo "  note: criterion 14 skipped as root"; else
  cp "$GS/c12" "$CX"; cp "$GS/g12" "$GM"; chmod 555 "$GH/.codex/rules" "$GH/.gemini/policies"
  out="$(PATH="$CP" "$GW/bin/bootstrap.sh" 2>&1 || true)"; chmod 755 "$GH/.codex/rules" "$GH/.gemini/policies"
  cmp -s "$CX" "$GS/c12" && cmp -s "$GM" "$GS/g12" && [[ "$(bk "$CX")" == 0 && "$(bk "$GM")" == 0 ]] || fail "criterion 14: a file changed, or a backup exists"
  grep -F "$CX was not changed: its backup could not be written beside it (" <<<"$out" | grep -qi 'permission denied' && grep -qF "$GM was not changed" <<<"$out" \
    || fail "criterion 14: bootstrap did not say why: $(grep -F 'not changed' <<<"$out")"
  # A rules file that cannot be written, in a folder that can: bootstrap says so and reports a failure, never "added".
  cp "$GS/c12" "$CX"; cp "$KIT/guardrails/gemini-owner-control.toml" "$GM"; chmod 444 "$CX"
  out="$(PATH="$CP" "$GW/bin/bootstrap.sh" 2>&1 || true)"; chmod 644 "$CX"
  grep -qF "$CX could not be written, so it may be cut short: restore it from its newest .bak copy beside it, then run cabinet bootstrap again" <<<"$out" \
    && ! grep -qF "added 1 kit rule(s) to $CX" <<<"$out" && grep -qF 'Some steps did not complete' <<<"$out" && cmp -s "$CX" "$GS/c12" \
    || fail "a rules file that cannot be written: $(grep -F "$CX" <<<"$out")"
  rm -f "$CX" "$GM" "$CX".bak.* "$GM".bak.*
fi
# Criterion 15: Codex names. (a) the owner's own forbidden_why, a codex that accepts the result.
mine() { sed 's/^forbidden_why = .*/forbidden_why = "Mine."/' "$KIT/guardrails/codex-default.rules" | grep -v 'gh", "release'; }
mine > "$CX"; touch "$GS/codex-forbids"; rm -f "$CX".bak.*
PATH="$FP" "$GW/bin/bootstrap.sh" >/dev/null 2>&1 || true
[[ "$(grep -c '^forbidden_why' "$CX")" == 1 ]] && grep -qx 'forbidden_why = "Mine."' "$CX" && [[ "$(tail -1 "$CX")" == "$(grep 'gh", "release' "$KIT/guardrails/codex-default.rules")" ]] \
  && tail -1 "$CX" | grep -qF 'justification = forbidden_why' || fail "criterion 15(a): $(tail -3 "$CX")"
# (b) a codex that no longer forbids git push on the result: left as is, the missing lines listed.
mine > "$CX"; rm -f "$GS/codex-forbids" "$CX".bak.*; mine > "$GS/c15"
out="$(PATH="$FP" "$GW/bin/bootstrap.sh" 2>&1 || true)"
cmp -s "$CX" "$GS/c15" && [[ "$(bk "$CX")" == 0 ]] || fail "criterion 15(b): the file changed or a backup was made"
grep -qF "$CX lacks 1 kit rule(s), and with them added it no longer checks out, so it is left as is. Add these lines by hand:" <<<"$out" \
  && grep -qxF "    $(grep 'gh", "release' "$KIT/guardrails/codex-default.rules")" <<<"$out" || fail "criterion 15(b): the lines to add were not listed: $out"
# (c) a file of the owner's own, with no forbidden_why, and no codex.
echo "$own_c" > "$CX"; rm -f "$CX".bak.*
PATH="$CP" "$GW/bin/bootstrap.sh" >/dev/null 2>&1 || true
[[ "$(head -1 "$CX")" == "$own_c" && "$(grep -c '^forbidden_why' "$CX")" == 1 ]] || fail "criterion 15(c): $(head -3 "$CX")"
while IFS= read -r l; do grep -qxF "$l" "$CX" || fail "criterion 15(c): missing $l"; done < <(grep '^prefix_rule' "$KIT/guardrails/codex-default.rules")
out="$(dp "$CP" --json)"; res "$out" guardrails.codex | grep -q '^ok ' || fail "criterion 15(c): the doctor: $(res "$out" guardrails.codex)"

# Part 4 and the docs. Criterion 16: the hard boundary, named once in bootstrap's output.
G="$KIT/docs/guardrails.md"
hb="$(awk '/^## /{on = ($0 == "## A hard boundary")} on' "$G")"
[[ -n "$hb" ]] && grep -qF 'ssh-add -c' <<<"$hb" && grep -qF -- '-sk' <<<"$hb" && grep -qi 'credential helper' <<<"$hb" && grep -qi 'login token' <<<"$hb" || fail "criterion 16: the section A hard boundary"
! grep -qiE 'yubi|titan|solokey|nitrokey|1password|bitwarden|secretive|keepass|google|apple|microsoft|openssh' <<<"$hb" || fail "criterion 16: the hard boundary names a product"
[[ "$(grep -c 'A hard boundary' "$T/gs-boot.out")" == 1 ]] && grep -qF '"A hard boundary" in the kit'"'"'s docs/guardrails.md' "$T/gs-boot.out" || fail "criterion 16: bootstrap does not name the section once"
# Criterion 17: the changelog's 0.3.0 entry says to run cabinet bootstrap (the docs check covers each doctor message).
awk '/^## /{on = /^## 0\.3\.0 /} on' "$KIT/CHANGELOG.md" | grep -qF 'run `cabinet bootstrap` after updating' || fail "criterion 17: the changelog"
for id in guardrails.stale-claim guardrails.repo-hookspath guardrails.push-gate guardrails.codex guardrails.gemini guardrails.agy; do grep -qF "\`$id\`" "$KIT/docs/troubleshooting.md" || fail "criterion 17: $id"; done
# Criterion 18: the old wording is gone; the new says where the gate asks, in words the site's visitors know.
! grep -qF 'A push gate for every repository' "$KIT/README.md" && ! grep -qF 'left as it is and checked, never replaced' "$G" \
  && ! grep -qF 'a push gate asks you at your own terminal' "$KIT/site/copy.js" && ! grep -qF 'The push gate asks you, at your own terminal.' "$KIT/site/copy.js" \
  && ! grep -qF 'a push gate asks you at your own terminal before any push' "$KIT/site/copy.js" || fail "criterion 18: old wording remains"
grep -qF "your Cabinet workspace and the repos it lists" "$KIT/README.md" && [[ "$(grep -cF "your Cabinet workspace and the repos it lists" "$KIT/site/copy.js")" -ge 3 ]] \
  && ! grep -qF "Cabinet's repos" "$KIT/site/copy.js" && grep -qF "Cabinet's repos" "$G" || fail "criterion 18: the new wording"

export HOME="$oh" GIT_CONFIG_GLOBAL="$og"
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
