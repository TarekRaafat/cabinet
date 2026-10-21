#!/usr/bin/env bash
# The owner's manual as a page: OPERATIONS.html, built from OPERATIONS.md.
#
#   bin/manual.sh build [--check]
#       Write OPERATIONS.html: one self-contained page (styles and a little script inside it, nothing
#       fetched), with a table of contents, a search that narrows the page to matching sections, light
#       and dark themes, and each "- [ ]" line as a tick box remembered per viewer and per day. The
#       Markdown is escaped, so nothing in it runs; only http(s), mailto, relative and # links link.
#       The page records a fingerprint of the Markdown it was built from. --check: exit 1 when the
#       page is missing or older than OPERATIONS.md, changing nothing. Untracked, like BRIEF.md: setup,
#       cabinet update and the brief job (its AFTER) rebuild it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

m_build() {
local check=0 a src="$WS/OPERATIONS.md" out="$WS/OPERATIONS.html" sum
for a in "$@"; do case "$a" in --check) check=1 ;; *) echo "usage: bin/manual.sh build [--check]" >&2; exit 2 ;; esac; done
[[ -f "$src" ]] || { echo "no OPERATIONS.md to build the page from" >&2; exit 1; }
sum="$(sha256 "$src")"
if ((check)); then
  grep -qF "<!-- cabinet manual: $sum -->" "$out" 2>/dev/null || { echo "OPERATIONS.html is older than OPERATIONS.md (run bin/manual.sh build)"; exit 1; }
  exit 0
fi
PROJECT="$CABINET_PROJECT" SUM="$sum" node "$LIBJS" manual "$src" > "$out.new" && [[ -s "$out.new" ]] && mv "$out.new" "$out" || { rm -f "$out.new"; echo "could not build OPERATIONS.html" >&2; exit 1; }
echo "Wrote OPERATIONS.html from OPERATIONS.md."
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  build) m_build "$@" ;;
  *) echo "usage: bin/manual.sh build [--check] (see the top of this file)" >&2; exit 2 ;;
esac
