# This machine: the one place that knows macOS from Linux. Where logs go, how dates and a
# file's age are read, where the backup passphrase is kept, how a notification is shown, and
# how schedules are installed: launchd on macOS, systemd user timers on Linux, cron where the
# user's systemd is not running. Sourced after when.sh by lib.sh and by the cabinet command,
# never run.

LIBJS="${LIBJS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.js}"   # the JavaScript beside this file, run with node
json() { node "$LIBJS" json "$@"; }   # JSON in and out: jq's options with a JavaScript expression (lib.js, json)

USER="${USER:-$(id -un)}"   # cron and containers can leave it unset
if [[ "$(uname)" == Darwin ]]; then
  OS=mac LOGROOT="$HOME/Library/Logs/cabinet" PASS_STORE="keychain"
else
  OS=linux LOGROOT="${XDG_STATE_HOME:-$HOME/.local/state}/cabinet" PASS_STORE="secret store"
fi
TILDE="~"   # a path shown from the home folder: "${p/#$HOME/$TILDE}" (bash 5 would expand a bare ~)
LOGROOT_SHOWN="${LOGROOT/#$HOME/$TILDE}"

# Dates people read, in the house format (18 Oct 2026, 1:00 PM), English on every machine.
human_mtime() { LC_ALL=C date -r "$1" "+%-d %b %Y, %-I:%M %p" 2>/dev/null; }
mtime() { if [[ $OS == mac ]]; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }
# stamp_epoch <YYYYmmdd-HHMMSS>: the time in a backup archive's name, in seconds.
stamp_epoch() {
  if [[ $OS == mac ]]; then date -j -f %Y%m%d-%H%M%S "$1" +%s
  else date -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:9:2}:${1:11:2}:${1:13:2}" +%s; fi 2>/dev/null
}
# epoch_date <seconds> <format>: that time in a date(1) format.
epoch_date() { if [[ $OS == mac ]]; then LC_ALL=C date -r "$1" "$2"; else LC_ALL=C date -d "@$1" "$2"; fi; }
human_stamp() {
  local e; e="$(stamp_epoch "$1")" || { printf '%s' "$1"; return 0; }
  epoch_date "$e" "+%-d %b %Y, %-I:%M %p"
}
sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }

# The backup passphrase, by the item's name: the keychain on macOS, the secret store
# (secret-tool) on Linux, or a file only the user can read in PASS_DIR, which comes first
# when it exists. Where cron runs the schedules the file is the store: a cron run reaches
# neither the secret store's session nor systemd's environment. CABINET_BACKUP_PASSPHRASE,
# when set, comes first for the callers.
PASS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cabinet/passphrases"
pass_file() { printf '%s/%s' "$PASS_DIR" "$1"; }
pass_file_ok() {  # readable by its owner only
  local m; if [[ $OS == mac ]]; then m="$(stat -f %Lp "$1")"; else m="$(stat -c %a "$1")"; fi 2>/dev/null
  [[ "$m" == [46]00 ]]
}
pass_get() {
  local f; f="$(pass_file "$1")"
  if [[ -f "$f" ]]; then pass_file_ok "$f" && cat "$f"; return; fi   # never read one others can
  if [[ $OS == mac ]]; then security find-generic-password -a "$USER" -s "$1" -w
  else secret-tool lookup service "$1" account "$USER"; fi 2>/dev/null
}
# pass_has: a scheduled run can read it. It never reads the passphrase on macOS, so it never
# asks for keychain access; under cron only the file counts.
pass_has() {
  local f; f="$(pass_file "$1")"
  if [[ -f "$f" ]]; then pass_file_ok "$f"
  elif [[ "$SCHEDULER" == cron ]]; then return 1
  elif [[ $OS == mac ]]; then security find-generic-password -a "$USER" -s "$1" >/dev/null 2>&1
  else [[ -n "$(pass_get "$1")" ]]; fi
}
pass_del() {
  local f gone=1; f="$(pass_file "$1")"
  [[ -f "$f" ]] && rm -f "$f" && gone=0
  if [[ $OS == mac ]]; then security delete-generic-password -a "$USER" -s "$1" >/dev/null 2>&1 && gone=0
  elif [[ -n "$(secret-tool lookup service "$1" account "$USER" 2>/dev/null)" ]]; then secret-tool clear service "$1" account "$USER" 2>/dev/null && gone=0; fi
  return $gone
}
pass_add_cmd() {  # the command a person runs to store it
  if [[ "$SCHEDULER" == cron ]]; then
    printf "bash -c 'umask 077 && mkdir -p \"\${0%%/*}\" && read -rsp \"Passphrase: \" p && echo && printf \"%%s\\\\n\" \"\$p\" > \"\$0\"' %s" "$(sh_q "$(pass_file "$1")")"
  elif [[ $OS == mac ]]; then printf 'security add-generic-password -a "$USER" -s %s -w' "$1"
  else printf 'secret-tool store --label=%s service %s account "$USER"' "$1" "$1"; fi
}

# notify <text> <subtitle>: a desktop notification; the text is an argument, never code.
notify() {
  if [[ $OS == mac ]]; then
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "cabinet" subtitle (item 2 of argv)' -e 'end run' "$1" "$2"
  else notify-send cabinet "$1${2:+ ($2)}"; fi
}

# Schedules. CABINET_SCHEDULER names one (launchd, systemd, cron or none) where the guess is wrong.
# systemd when the machine booted with it, not when this shell reaches the user's session bus,
# so a shell without one (su, sudo -u, a container exec) still reads the same schedules.
SCHEDULER="${CABINET_SCHEDULER:-}"
if [[ -z "$SCHEDULER" ]]; then
  if [[ $OS == mac ]]; then SCHEDULER=launchd
  elif [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then SCHEDULER=systemd
  elif command -v crontab >/dev/null; then SCHEDULER=cron
  else SCHEDULER=none; fi
fi
# Under cron the backup passphrase lives in a file (pass_get).
if [[ "$SCHEDULER" == cron ]]; then PASS_STORE="passphrase file"; fi
# Each schedule is one file named for its label, so every caller finds them the same way.
case "$SCHEDULER" in
  launchd) SCHED_DIR="$HOME/Library/LaunchAgents" SCHED_EXT=.plist ;;
  systemd) SCHED_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" SCHED_EXT=.service
    # systemctl --user finds the user's manager through this; su and sudo -u leave it unset.
    [[ -n "${XDG_RUNTIME_DIR:-}" || ! -d "/run/user/$(id -u)" ]] || export XDG_RUNTIME_DIR="/run/user/$(id -u)" ;;
  *)       SCHED_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cabinet/cron" SCHED_EXT=.cron ;;
esac
sched_file() { printf '%s/%s%s' "$SCHED_DIR" "$1" "$SCHED_EXT"; }
sched_label() { local b="${1##*/}"; printf '%s' "${b%"$SCHED_EXT"}"; }

xml() { local s=$1; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }
sd_q() { local s=$1; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//%/%%}"; printf '"%s"' "$s"; }   # systemd, no $ expansion
sh_q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# sched_render <label> <when> <log> <path> <program> <arg>...: the schedule's file, as written.
# Returns 1 when <when> is not a schedule time.
sched_render() {
  local label=$1 when=$2 log=$3 path=$4 a; shift 4
  when_parse "$when" || return 1
  when="$(when_norm "$when")"
  case "$SCHEDULER" in
  launchd)
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0">' '<dict>' \
      "  <key>Label</key><string>$(xml "$label")</string>" \
      "  <key>CabinetWhen</key><string>$(xml "$when")</string>" \
      '  <key>ProgramArguments</key>' '  <array>'
    for a in "$@"; do printf '    <string>%s</string>\n' "$(xml "$a")"; done
    printf '%s\n' '  </array>' '  <key>EnvironmentVariables</key>' '  <dict>' \
      "    <key>PATH</key><string>$(xml "$path")</string>" '  </dict>' \
      '  <key>StartCalendarInterval</key>' "  <array>$(when_calendar "$when")</array>" \
      "  <key>StandardOutPath</key><string>$(xml "$log")</string>" \
      "  <key>StandardErrorPath</key><string>$(xml "$log")</string>" '</dict>' '</plist>'
    return 0 ;;
  esac
  # systemd and cron: what the doctor and the digest read back, as comments first.
  printf '# cabinet-when: %s\n# cabinet-path: %s\n# cabinet-command: %s\n' "$when" "$path" "$(json -n -c '$args' --args "$@")"
  if [[ "$SCHEDULER" == systemd ]]; then
    local cmd=""; for a in "$@"; do cmd+="${cmd:+ }$(sd_q "$a")"; done
    printf '%s\n' "[Unit]" "Description=cabinet $label" "" "[Service]" "Type=oneshot" \
      "Environment=$(sd_q "PATH=$path")" "ExecStart=${cmd//\$/\$\$}" \
      "StandardOutput=append:${log//%/%%}" "StandardError=append:${log//%/%%}"
  else
    local cmd="PATH=$(sh_q "$path")"; for a in "$@"; do cmd+=" $(sh_q "$a")"; done
    cmd+=" >>$(sh_q "$log") 2>&1"
    printf '%s %s\n' "$(when_cron "$when")" "${cmd//%/\\%}"   # cron reads a bare % as a line break
  fi
}

# sched_get <file> when|path|command: what a schedule runs (command as a JSON array).
sched_get() {
  if [[ "$SCHEDULER" == launchd ]]; then
    case "$2" in
      when) plutil -extract CabinetWhen raw "$1" ;;
      path) plutil -extract EnvironmentVariables.PATH raw "$1" ;;
      command) plutil -extract ProgramArguments json -o - "$1" ;;
    esac 2>/dev/null
  else sed -n "s/^# cabinet-$2: //p" "$1" 2>/dev/null | head -1; fi
}
# sched_ws <file>: the workspace whose script it runs, if any.
sched_ws() {
  local p
  if [[ "$SCHEDULER" == launchd ]]; then
    p="$(sed -n 's#.*<string>\(.*\)/bin/[a-z]*\.sh</string>.*#\1#p' "$1" 2>/dev/null | head -1)"
    p="${p//&lt;/<}"; p="${p//&gt;/>}"; p="${p//&amp;/&}"
  else
    p="$(sched_get "$1" command | json -r '$[0]' 2>/dev/null)"
    [[ "$p" == */bin/*.sh ]] && p="${p%/bin/*}" || p=""
  fi
  printf '%s' "$p"
}

# sched_load <label> <text>: write the schedule and start it; 1 (and nothing left installed) when it will not load.
sched_load() {
  local label=$1 f; f="$(sched_file "$1")"
  mkdir -p "$SCHED_DIR"
  [[ -f "$f" ]] && sched_stop "$label"
  printf '%s\n' "$2" > "$f"
  case "$SCHEDULER" in
    launchd) launchctl bootstrap "gui/$(id -u)" "$f" && return 0 ;;
    systemd)
      printf '%s\n' "[Unit]" "Description=cabinet $label" "" "[Timer]" \
        "OnCalendar=$(when_oncalendar "$(sched_get "$f" when)")" "Persistent=true" "" "[Install]" "WantedBy=timers.target" > "${f%.service}.timer"
      systemctl --user daemon-reload && systemctl --user --quiet enable --now "$label.timer" && return 0 ;;
    cron) cron_sync && return 0 ;;
  esac
  sched_unload "$label"; return 1
}
sched_stop() {
  case "$SCHEDULER" in
    launchd) launchctl bootout "gui/$(id -u)/$1" ;;
    systemd) systemctl --user disable --now "$1.timer" ;;
  esac >/dev/null 2>&1 || true
}
# sched_unload <label>: stop it and delete its files.
sched_unload() {
  local f; f="$(sched_file "$1")"
  sched_stop "$1"
  rm -f "$f"
  case "$SCHEDULER" in
    systemd) rm -f "${f%.service}.timer"; systemctl --user daemon-reload >/dev/null 2>&1 || true ;;
    cron) cron_sync || true ;;
  esac
}
sched_loaded() {
  case "$SCHEDULER" in
    launchd) launchctl print "gui/$(id -u)/$1" ;;
    systemd) systemctl --user is-active --quiet "$1.timer" ;;
    cron) crontab -l 2>/dev/null | grep -qxF "# cabinet schedule: $1" ;;
    *) false ;;
  esac >/dev/null 2>&1
}
# How a person runs one now, and stops one by hand.
sched_start_cmd() {
  case "$SCHEDULER" in
    launchd) printf 'launchctl kickstart -k gui/$(id -u)/%s' "$1" ;;
    systemd) printf 'systemctl --user start %s.service' "$1" ;;
    *) printf '%s' "$2" ;;
  esac
}
sched_stop_cmd() {
  case "$SCHEDULER" in
    launchd) printf 'launchctl bootout gui/$(id -u)/%s, then delete %s' "$1" "$(sched_file "$1")" ;;
    systemd) printf 'systemctl --user disable --now %s.timer, then delete %s and its .timer' "$1" "$(sched_file "$1")" ;;
    *) printf 'delete %s, then run cabinet bootstrap in any workspace (it rewrites the crontab)' "$(sched_file "$1")" ;;
  esac
}

# The crontab holds one block cabinet writes from SCHED_DIR's files; every other line is kept.
cron_sync() {
  local cur f
  cur="$(crontab -l 2>/dev/null || true)"
  {
    # Drop the old block; a BEGIN with no END keeps everything (a hand edit is never lost).
    printf '%s\n' "$cur" | awk '/^# BEGIN cabinet/ && !skip { skip = 1; held = $0 "\n"; next }
      skip && /^# END cabinet/ { skip = 0; next } skip { held = held $0 "\n"; next } { print }
      END { if (skip) printf "%s", held }' | sed '/./,$!d'
    local block=""
    for f in "$SCHED_DIR"/*.cron; do
      [[ -f "$f" ]] && block+="# cabinet schedule: $(sched_label "$f")"$'\n'"$(cat "$f")"$'\n'
    done
    [[ -z "$block" ]] || printf '%s\n%s%s\n' "# BEGIN cabinet: written by cabinet bootstrap from $SCHED_DIR; edits here are replaced" "$block" "# END cabinet"
  } | crontab -
}

# Tools cabinet needs, and how this machine installs them (brew, apt, dnf or pacman).
# Optional tools are checked where their feature is turned on: openssl and secret-tool for
# backups, notify-send for digest notifications.
DEPS_REQUIRED="git node npm"
# deps_missing [<tools>]: the ones not found (CABINET_TEST_MISSING makes the tests miss some).
deps_missing() {
  local t out=""
  for t in ${1:-$DEPS_REQUIRED}; do
    if ! command -v "$t" >/dev/null || [[ " ${CABINET_TEST_MISSING:-} " == *" $t "* ]]; then out+="${out:+ }$t"; fi
  done
  printf '%s' "$out"
}
# The backup tools this machine lacks: openssl, and on Linux secret-tool unless the passphrase comes from the environment or cron runs the schedules (a file then).
deps_backups() {
  local t="openssl"; [[ $OS == linux && $SCHEDULER != cron && -z "${CABINET_BACKUP_PASSPHRASE:-}" ]] && t+=" secret-tool"
  deps_missing "$t"
}
pkg_manager() {
  local m order="apt-get dnf pacman brew"; [[ $OS == mac ]] && order="brew"
  for m in $order; do command -v "$m" >/dev/null && { echo "$m"; return 0; }; done
  return 1
}
pkg_for() {  # pkg_for <manager> <tool>: the package that brings the tool
  case "$1:$2" in
    brew:node|brew:npm) echo node ;; brew:secret-tool) echo libsecret ;; brew:notify-send) echo libnotify ;;
    *:node) echo nodejs ;;
    apt-get:secret-tool) echo libsecret-tools ;; *:secret-tool) echo libsecret ;;
    apt-get:notify-send) echo libnotify-bin ;; *:notify-send) echo libnotify ;;
    *) echo "$2" ;;
  esac
}
# deps_cmd <tools>: the command that installs them here, as a person types it; 1 with no package manager.
deps_cmd() {
  local m t p pk="" su="sudo "; m="$(pkg_manager)" || return 1
  [[ "$(id -u)" == 0 ]] && su=""   # root (a container) needs no sudo, and often has none
  for t in $1; do p="$(pkg_for "$m" "$t")"; [[ " $pk " == *" $p "* ]] || pk+="${pk:+ }$p"; done
  case "$m" in
    brew) echo "brew install $pk" ;; apt-get) echo "${su}apt-get install -y $pk" ;;
    dnf) echo "${su}dnf install -y $pk" ;; pacman) echo "${su}pacman -S --needed $pk" ;;
  esac
}
deps_hint() {  # deps_hint <tools>: "install: <command>", or where to get a package manager
  local c; c="$(deps_cmd "$1")" && { printf 'install: %s' "$c"; return 0; }
  if [[ $OS == mac ]]; then printf 'install Homebrew (https://brew.sh), then: brew install %s' "$1"
  else printf "install %s with this system's package manager" "$1"; fi
}
# deps_install <tools>: run that command; sudo asks for the password in this terminal.
# The words come from DEPS_REQUIRED and pkg_for, never from a user, so they are split as written.
deps_install() {
  local c; c="$(deps_cmd "$1")" || return 1
  echo "== $c"
  # shellcheck disable=SC2086
  $c
}
