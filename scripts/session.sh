#!/usr/bin/env bash
# Sessions: a git worktree for each session, so several sessions (yours, a teammate's, a role's) work in
# the same repo at once, each with its own commits, index, uncommitted changes and test runs.
#
#   bin/session.sh start [name] [--repo <repo>]
#       A worktree of a repo in repos.tsv at sessions/<repo>/<name>/, on a new branch session/<name> from
#       the repo's current branch head; prints the folder to open the agent tool in. No name: today's date
#       and a number. --repo may be left out when the workspace has one repo.
#   bin/session.sh list [--json]
#       Every session: repo, name, branch, folder, commits ahead of the repo's current branch, uncommitted
#       files, whether it is merged into that branch, and the date it started. A folder that is gone shows
#       with the command that prunes it.
#   bin/session.sh end <name>
#       Its commits, the handoffs that name them, and the command for the owner to bring them into the
#       repo's current branch. Removes the folder only when it has no uncommitted changes; keeps the branch.
#
# No command here merges, rebases or pushes: the owner does, or asks an agent in a session to.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
usage="usage: bin/session.sh start [name] [--repo <repo>] | list [--json] | end <name>"

# A session name: 1 to 40 lower-case letters, digits and hyphens, starting with a letter or digit (never
# with -, which git would read as an option). It becomes a branch and a folder name.
name_ok() { local LC_ALL=C; [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; }
shown() { printf '%s' "$1" | term_text; }   # a value someone typed, printed safely
q() { printf '%q' "$1"; }                   # a path or branch as a command line takes it

# Every session in the workspace: "<repo>\t<name>\t<folder>\t<branch>\t<repo folder>".
all_sessions() {
  local name url files link path d s f b
  while IFS=$'\t' read -r name url files link path; do
    d="$(abspath "$(repo_dir "$path")")"
    while IFS=$'\t' read -r s f b; do printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$s" "$f" "$b" "$d"; done < <(sessions_of "$name" "$d")
  done < <(repos 2>/dev/null)
}
# The repo's current branch in its main folder, or the commit when it is detached.
current() { git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || git -C "$1" rev-parse --short HEAD; }
# When a session started, in seconds: the first entry of its branch's reflog; empty when there is none (a restore).
started() { git -C "$1" reflog show --date=unix --format=%gd "refs/heads/$2" -- 2>/dev/null | tail -1 | sed -n 's/.*@{\([0-9][0-9]*\)}$/\1/p'; }

s_start() {
  local name="" repo="" n url files link path d dir="" b ws_dirty
  local -a names
  names=()
  while (($#)); do
    case "$1" in
      --repo) (($# >= 2)) || { echo "--repo needs a repo name. $usage" >&2; exit 2; }; repo="$2"; shift 2 ;;
      -*) echo "unknown option $(shown "$1") (a session name never starts with -). $usage" >&2; exit 2 ;;
      *) [[ -z "$name" ]] || { echo "one name only. $usage" >&2; exit 2; }; name="$1"; shift ;;
    esac
  done
  if [[ -n "$name" ]] && ! name_ok "$name"; then
    echo "'$(shown "$name")' is not a session name: 1 to 40 lower-case letters, digits and hyphens, starting with a letter or digit" >&2; exit 2
  fi
  while IFS=$'\t' read -r n url files link path; do names+=("$n"); [[ "$n" == "$repo" ]] && dir="$(abspath "$(repo_dir "$path")")"; done < <(repos 2>/dev/null)
  if [[ -z "$repo" ]]; then
    case ${#names[@]} in
      0) echo "no repo in repos.tsv to start a session in: add one first (cabinet repo add <git url>)" >&2; exit 1 ;;
      1) repo="${names[0]}"; dir="$(abspath "$(repo_dir "$(repos | cut -f5)")")" ;;
      *) echo "this workspace has ${#names[@]} repos: say which with --repo ($(printf '%s ' "${names[@]}" | sed 's/ $//; s/ /, /g'))" >&2; exit 2 ;;
    esac
  elif [[ -z "$dir" ]]; then
    echo "'$(shown "$repo")' is not a repo in repos.tsv (cabinet repo list): ${names[*]+${names[*]}}" >&2; exit 1
  fi
  [[ -e "$dir/.git" ]] || { echo "$repo is not a git repo at $dir, so it cannot have sessions (cabinet bootstrap clones the repos in repos.tsv)" >&2; exit 1; }
  git -C "$dir" rev-parse -q --verify HEAD >/dev/null || { echo "$repo has no commit yet: commit once, then start a session" >&2; exit 1; }
  if [[ -z "$name" ]]; then
    n=1; while all_sessions | cut -f2 | grep -qx "$(date +%Y-%m-%d)-$n" || git -C "$dir" rev-parse -q --verify "refs/heads/session/$(date +%Y-%m-%d)-$n" >/dev/null; do n=$((n + 1)); done
    name="$(date +%Y-%m-%d)-$n"
  fi
  # One name, one session, across the workspace's repos.
  b="$(all_sessions | awk -F'\t' -v s="$name" '$2 == s && !n++ {print $1 "\t" $3}')"
  [[ -z "$b" ]] || { echo "a session named $name already exists, in ${b%%$'\t'*} at ${b#*$'\t'}: choose another name, or end it first (cabinet session end $name)" >&2; exit 1; }
  if git -C "$dir" rev-parse -q --verify "refs/heads/session/$name" >/dev/null; then
    { echo "the branch session/$name already exists in $repo, with no session. Either:"
      echo "  delete it (once merged):  git -C $(q "$dir") branch -d $(q "session/$name")"
      echo "  or reuse it in a session: git -C $(q "$dir") worktree add $(q "$SESSIONS/$repo/$name") $(q "session/$name")"; } >&2
    exit 1
  fi
  [[ ! -e "$SESSIONS/$repo/$name" ]] || { echo "$SESSIONS/$repo/$name already exists and is not a session: move it, then start again" >&2; exit 1; }
  ws_dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  mkdir -p "$SESSIONS/$repo"
  # Ignored by any git above it, whatever its .gitignore says (a workspace's, or a project's around cabinet/).
  [[ -e "$SESSIONS/.gitignore" ]] || printf '*\n' > "$SESSIONS/.gitignore"
  git -C "$dir" worktree add -q -b "session/$name" "$SESSIONS/$repo/$name" HEAD || { rmdir "$SESSIONS/$repo" 2>/dev/null || true; echo "git could not create the session (see above); nothing was started" >&2; exit 1; }
  echo "Session $name started: branch session/$name of $repo, from $(current "$dir") at $(git -C "$dir" rev-parse --short HEAD)."
  ((ws_dirty == 0)) || echo "The main folder has $ws_dirty uncommitted change(s), which are not in the session: it starts from the last commit."
  # The repo's own setup for a new folder (installing dependencies, for example): its AGENTS.md's "## Session setup".
  local setup; setup="$(awk '/^## / { if (on) exit; on = ($0 ~ /^## Session setup[[:space:]]*$/); next } on' "$dir/AGENTS.md" 2>/dev/null | sed '/./,$!d' || true)"
  [[ -z "$setup" ]] || { echo; echo "Setup, from $repo's AGENTS.md:"; printf '%s\n' "$setup" | term_text; echo; }
  echo "Open your agent tool in:"
  echo "  $SESSIONS/$repo/$name"
  echo "When it is done: cabinet session end $name"
}

s_list() {
  local json=0 a repo s f b d ahead dirty merged gone when e day rows
  for a in "$@"; do case "$a" in --json) json=1 ;; *) echo "$usage" >&2; exit 2 ;; esac; done
  rows="$(while IFS=$'\t' read -r repo s f b d; do
    ahead="$(git -C "$d" rev-list --count "HEAD..refs/heads/$b" 2>/dev/null || echo 0)"
    merged=false; git -C "$d" merge-base --is-ancestor "refs/heads/$b" HEAD 2>/dev/null && merged=true
    if [[ -d "$f" ]]; then gone=false dirty="$(git -C "$f" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"; else gone=true dirty=-; fi
    e="$(started "$d" "$b")" when=- day="on an unknown date"
    [[ -z "$e" ]] || { when="$(epoch_date "$e" +%F)"; day="$(epoch_date "$e" "+%-d %b %Y")"; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$s" "$b" "$f" "$ahead" "$dirty" "$merged" "$when" "$gone" "$(q "$d")" "$day" "$(q "$b")"
  done < <(all_sessions))"
  if ((json)); then
    printf '%s' "$rows" | json -R '$.filter((l) => l != "").map((l) => l.split("\t")).map((r) => ({repo: r[0], name: r[1], branch: r[2], folder: r[3], ahead: Number(r[4]),
      uncommitted: r[8] == "true" ? null : Number(r[5]), merged: r[6] == "true", started: r[7] == "-" ? null : r[7], gone: r[8] == "true",
      merge: "git -C " + r[9] + " merge --ff-only " + r[11], prune: r[8] == "true" ? "git -C " + r[9] + " worktree prune" : null}))'
    return 0
  fi
  [[ -n "$rows" ]] || { echo "No sessions. Start one: cabinet session start [name]"; return 0; }
  while IFS=$'\t' read -r repo s b f ahead dirty merged when gone d day _; do
    if [[ "$gone" == true ]]; then
      echo "$s  ($repo, $b)  folder gone: $f"
      echo "  git keeps it listed until a prune: git -C $d worktree prune"
    else
      echo "$s  ($repo, $b)  $ahead commit(s) ahead, $dirty uncommitted, $([[ "$merged" == true ]] && echo merged || echo "not merged"), started $day"
      echo "  $f"
    fi
  done <<<"$rows"
}

s_end() {
  local name="${1:-}" row repo s f b d main ids dirty envs
  (($# == 1)) || { echo "$usage" >&2; exit 2; }
  name_ok "$name" || { echo "'$(shown "$name")' is not a session name (cabinet session list)" >&2; exit 2; }
  row="$(all_sessions | awk -F'\t' -v s="$name" '$2 == s && !n++')"
  [[ -n "$row" ]] || { echo "no session named $name (cabinet session list)" >&2; exit 1; }
  IFS=$'\t' read -r repo s f b d <<<"$row"
  # Refused first, before anything is shown: uncommitted work stays where it is.
  if [[ -d "$f" ]]; then
    dirty="$(git -C "$f" status --porcelain 2>/dev/null)"
    [[ -z "$dirty" ]] || { echo "session $name has $(printf '%s\n' "$dirty" | wc -l | tr -d ' ') uncommitted change(s) in $f: commit them in the session (or ask for them to be dropped), then end it again. Nothing was removed." >&2; exit 1; }
    # .env files are ignored by git, and git worktree remove would delete them with the folder.
    envs="$(git -C "$f" ls-files -o -i --exclude-standard --directory 2>/dev/null | awk -F/ '{n = $NF == "" ? $(NF - 1) : $NF} n ~ /^\.env/ && n !~ /\.example$/' || true)"
    [[ -z "$envs" ]] || { echo "session $name holds ignored files git would delete with the folder: $(printf '%s ' $envs)- copy what you need, then end it again. Nothing was removed." >&2; exit 1; }
  fi
  main="$(current "$d")"
  echo "Session $name ($repo, $b):"
  local commits; commits="$(git -C "$d" rev-list --reverse "HEAD..refs/heads/$b")"
  if [[ -z "$commits" ]]; then echo "  no commits that $main does not have"
  else
    git -C "$d" log --reverse --format='  %h %s' "HEAD..refs/heads/$b" | term_text
    local -a hf; hf=("$WS/HANDOFFS.md"); for x in "$WS"/handoffs/archive-*.md; do [[ -f "$x" ]] && hf+=("$x"); done
    ids="$(awk -v cs="$(printf '%s ' $commits)" '
      BEGIN { n = split(cs, c, " ") }
      /^### H-[0-9]+-[0-9]+:/ { id = $2; sub(/:$/, "", id); next }
      id != "" { l = $0; while (match(l, /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+/)) { t = substr(l, RSTART, RLENGTH); l = substr(l, RSTART + RLENGTH)
          if (RLENGTH <= 40) for (i = 1; i <= n; i++) if (index(c[i], t) == 1 && !(id in seen)) { seen[id] = 1; print id } } }' "${hf[@]}" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')"
    echo "Handoffs that name them: ${ids:-none}"
  fi
  echo
  echo "To bring them into $main, from your terminal (no Cabinet command merges):"
  if ! git -C "$d" merge-base --is-ancestor HEAD "refs/heads/$b" 2>/dev/null; then
    echo "  $main has moved on since the session started. First, either rebase the session onto it:"
    echo "    git -C $(q "$f") rebase $(q "$main")"
    echo "  or merge it without a fast-forward instead of the line below: git -C $(q "$d") merge $(q "session/$name")"
  fi
  echo "  git -C $(q "$d") merge --ff-only $(q "session/$name")"
  echo
  if [[ -d "$f" ]]; then
    git -C "$d" worktree remove "$f" || { echo "git did not remove $f (see above); the session is as it was" >&2; exit 1; }
    rmdir "$SESSIONS/$repo" 2>/dev/null || true
    echo "Removed the folder $f. The branch session/$name stays; once it is merged: git -C $(q "$d") branch -d $(q "session/$name")"
  else
    echo "The folder $f is already gone. git keeps it listed until a prune: git -C $(q "$d") worktree prune"
  fi
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  start) s_start "$@" ;;
  list) s_list "$@" ;;
  end) s_end "$@" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
