#!/usr/bin/env bash
# Look for keys, tokens and passwords in the workspace's own files (tracked, and new files
# git does not ignore), so none is committed and copied into every backup. Prints
# file:line and the kind of secret, never the secret itself.
#
#   bin/secrets.sh            every file of the workspace
#   bin/secrets.sh --staged   only the lines staged for the next commit (the pre-commit hook)
#
# A false alarm: put not-a-secret anywhere on its line. Exit 0 when nothing is found, 1 when
# something is. Product repos are not scanned: they have their own git and their own hooks.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

staged=0
for a in "$@"; do
  case "$a" in --staged) staged=1 ;; *) echo "usage: secrets.sh [--staged]" >&2; exit 2 ;; esac
done
cd "$WS"
found="$(mktemp)"; trap 'rm -f "$found"' EXIT

# Reads "file<TAB>line<TAB>text" and prints "file:line: kind" for each likely secret.
scan() {
  perl -ne '
    BEGIN { @p = (
      ["a private key", qr/-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/],
      ["an AWS access key", qr/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
      ["a GitHub token", qr/\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})/],
      ["a Slack token", qr/\bxox[abposr]-[A-Za-z0-9-]{10,}/],
      ["a Stripe live key", qr/\b[rs]k_live_[A-Za-z0-9]{16,}/],
      ["an Anthropic key", qr/\bsk-ant-[A-Za-z0-9_-]{20,}/],
      ["an OpenAI key", qr/\bsk-(?:proj-)?[A-Za-z0-9]{20,}/],
      ["a Google API key", qr/\bAIza[0-9A-Za-z_-]{35}/],
      ["an npm token", qr/\bnpm_[A-Za-z0-9]{36}\b/],
      # A line that sets one: a name like password or api_key, then : or =, then a value of
      # 8 or more characters that is not a placeholder (<...>), a variable ($X, ${X}) or a template.
      ["a password or token", qr/(?i)(?<![a-z])(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret)(?:_\w*)?(?![a-z])["\x27]?\s*[:=]\s*["\x27]?(?![\$<{%(\[])[^\s"\x27<>`,;]{8,}/],
    ) }
    chomp; my ($f, $n, $t) = split /\t/, $_, 3;
    next if !defined $t || $t =~ /not-a-secret/;
    for (@p) { if ($t =~ $_->[1]) { print "$f:$n: $_->[0]\n"; last } }
  '
}

if ((staged)); then
  # The added lines of the staged diff, with their file and line number.
  git diff --cached -U0 --no-color --no-ext-diff --diff-filter=ACMR -- . | perl -ne '
    if (/^\+\+\+ b\/(.*)$/) { $f = $1; next }
    if (/^\@\@ -\S+ \+(\d+)/) { $n = $1; next }
    if (/^\+/ && defined $f) { s/^\+//; s/\t/ /g; print "$f\t$n\t$_"; $n++ }
  ' | scan > "$found" || true
else
  git ls-files -z -co --exclude-standard -- . | perl -0 -ne '
    chomp; my $f = $_; next if !-f $f || -B $f || -s $f > 2_000_000;
    open my $h, "<", $f or next; local $/ = "\n";
    while (my $l = <$h>) { $l =~ s/\t/ /g; print "$f\t$.\t$l" }
  ' | scan > "$found" || true
fi

if [[ -s "$found" ]]; then
  echo "Possible secrets (remove each, and rotate any real key; a false alarm: add not-a-secret to its line):" >&2
  sed 's/^/  /' "$found" >&2
  ((staged)) && echo "Commit refused." >&2
  exit 1
fi
((staged)) || echo "No likely secret in the workspace's files."
