#!/usr/bin/env bash
# Runs the demo's commands for real in a throwaway sandbox and saves each one's terminal output to out/;
# node brand/render-film.js demo --capture runs it and turns out/ into captured.js. macOS (script's options).
# The sandbox is the test suite's: HOME and git's config inside a temp folder, fakes for the
# schedulers, secret stores, notifications, package managers and the agent tool first on PATH.
set -eu
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(cd "$(dirname "$0")" && pwd)/out"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rm -rf "$OUT"; mkdir -p "$OUT"
export GIT_AUTHOR_NAME="Maya" GIT_AUTHOR_EMAIL=maya@example.com GIT_COMMITTER_NAME="Maya" GIT_COMMITTER_EMAIL=maya@example.com
export HOME="$T/user" GIT_CONFIG_GLOBAL="$T/user/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME XDG_STATE_HOME
mkdir -p "$HOME"; printf '[user]\n\tname = Maya\n\temail = maya@example.com\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
mkdir -p "$T/shim"
for t in launchctl systemctl security secret-tool osascript notify-send claude brew apt-get dnf pacman sudo; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\ncase "$1" in find-generic-password|lookup) exit 44 ;; esac\n' "$t" "$T/fake.log" > "$T/shim/$t"; chmod +x "$T/shim/$t"
done
printf '#!/bin/sh\ncase "$1" in -l) cat "%s" 2>/dev/null ;; -) cat > "%s" ;; *) exit 1 ;; esac\n' "$T/crontab" "$T/crontab" > "$T/shim/crontab"; chmod +x "$T/shim/crontab"
mkdir -p "$T/bin"; ln -s "$KIT/bin/cabinet" "$T/bin/cabinet"
export PATH="$T/shim:$T/bin:$PATH"
for t in launchctl systemctl crontab security secret-tool claude sudo; do [[ "$(command -v "$t")" == "$T/shim/$t" ]] || { echo "the fake $t is not first on PATH" >&2; exit 1; }; done
export LANG=en_US.UTF-8 COLUMNS=100 LINES=40

# rec <name> <command>...: run it on a terminal (colors as a person sees them) and save what it printed.
rec() {
  local name="$1"; shift
  printf '%s\n' "$*" > "$OUT/$name.cmd"
  script -q "$OUT/$name.raw" "$@" < /dev/null > /dev/null 2>&1 || true
}

cd "$HOME"
rec 01-new cabinet new acme --name Acme --yes
W="$HOME/acme"; cd "$W"
ls -1 > "$OUT/02-ls.txt"
rec 03-roles cabinet role list
rec 04-next cabinet next
rec 05-bootstrap cabinet bootstrap
rec 06-doctor cabinet doctor
rec 07-version cabinet version
rec 08-handoff cabinet handoff add --from design-lead --to qa --changed "Checkout screens: cart, address, payment" --needed "Verify against the spec's acceptance criteria" "Checkout screens ready"
rec 09-handoffs cabinet handoff list
cp "$W/AGENTS.md" "$OUT/AGENTS.md"; cp "$W/OPERATIONS.md" "$OUT/OPERATIONS.md" 2>/dev/null || true
ls "$W/.cabinet/rules" > "$OUT/rules.txt" 2>/dev/null || true
find "$W" -maxdepth 2 -not -path '*/.git*' | sed "s|$W|acme|" | sort > "$OUT/tree.txt"
cp "$T/fake.log" "$OUT/fake.log" 2>/dev/null || true
# Paths as a person sees them: the sandbox's home is shown as /Users/maya.
for f in "$OUT"/*.raw; do L="$(printf '%s' "$HOME" | sed 's/[.[\*^$/]/\\&/g')"; sed -i.bak -e "s/\/private$L/\/Users\/maya/g" -e "s/$L/\/Users\/maya/g" -e "s/\/private\/var\/folders\/[^ ]*\/T\/tmp\.[A-Za-z0-9]*\/shim/\/opt\/homebrew\/bin/g" -e "s/\/var\/folders\/[^ ]*\/T\/tmp\.[A-Za-z0-9]*\/shim/\/opt\/homebrew\/bin/g" "$f"; rm -f "$f.bak"; done
echo "captured in $OUT"
