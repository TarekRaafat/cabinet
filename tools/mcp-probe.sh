#!/usr/bin/env bash
# The MCP probe: checks, with each real agent tool, the lines the kit's MCP rules rely on ("Outside the shell" in
# docs/guardrails.md): which flag keeps a run's MCP servers out, which variable moves a tool's settings folder, and
# which file holds a tool's server list. Run by the maintainer, never by the suite; not shipped (package.json
# "files" leaves tools/ out).
#
#   tools/mcp-probe.sh <out folder> [claude|qwen|codex|gemini|opencode|cursor|grok|agy]...   (default: each installed)
#   tools/mcp-probe.sh --part2 <out folder> [claude|grok|qwen|opencode|cursor|agy|github]...
#
# --part2 checks the lines part 2 relies on (specs/guardrails-outside-the-shell-2.md, Rule 1): MCP tool denies, the
# kit's verb hook (guardrails/cabinet-mcp-gate.js), file-tool and read denies, Antigravity's rule forms, hooks file,
# server list and --settings, and the GitHub MCP server's tool names. Each row asks the tool to do one harmless thing
# (call an echo-only stand-in tool, write a stand-in file, read a stand-in secret, touch a mark file) with the kit's
# rule in place, and its control asks the same without it. Results come from the marks, the file and the secret's
# random token, never from what a model says. CABINET_PROBE_HOME=<folder> keeps that folder as HOME (made if
# missing, never removed), so each tool can be logged in there first; every settings file a row changes there is
# put back as it was when the probe ends. CABINET_PROBE_PASS="<VAR> ..." passes those variables (probe-only keys)
# to the tools; they are never written or printed.
#
# Safety, both parts:
# - HOME, GIT_CONFIG_GLOBAL, TMPDIR and every XDG folder are probe folders, and fakes of security, secret-tool,
#   launchctl, systemctl, crontab and gh come first on PATH: nothing reaches the real keychain through security, the
#   schedules, the GitHub login or your own tool settings. The fake security writes only what it was asked for (its
#   subcommand and the -s service name, never a value) to <out>/keychain-asks.log: a tool named there keeps its
#   login in the keychain, which the probe cannot reach, so it needs a probe-only key.
# - git in the probe reads no system config, has no credential helper, never prompts, and its pre-push hook refuses
#   every push; the probe checks that no helper runs before it starts any tool.
# - The only MCP server anywhere is a stand-in (standin.js), a few lines of Node whose tools only echo and write a
#   mark file. Whether a tool loaded a server, or called a tool, is read from that mark, not from what a model says.
#   No push, merge, publish or network write is ever asked for.
# - Each tool runs in an empty folder with no git remote. Ctrl-C stops the whole probe and puts every file back.
# - A command that fails (for want of a login, say) is recorded as unclear, never as a pass.
# Part 1: a new mktemp HOME; at most 120 seconds per command; no tool gets a login except Claude Code, through
# CABINET_PROBE_KEY, which reaches only its process, as ANTHROPIC_API_KEY, and is never written or printed.
# --part2: HOME is a new mktemp folder, or CABINET_PROBE_HOME, a folder you keep and log each tool in first (so it
# holds those logins); at most 180 seconds per command. CABINET_PROBE_KEY reaches only Claude Code's rows. Every
# variable CABINET_PROBE_PASS names reaches every tool probed and the commands it runs (probe one tool at a time to
# keep a key to its tool); none is written or printed. Every settings file a row changes in that HOME, and Grok's
# server list, is put back when the probe ends; the stand-in files stay in <HOME>/probe/ (a random token, no secret).
# Results in <out>: probe.tsv (row, tool version, command, result) and one log per command. Two steps need your own
# account and are printed at the end instead: account connectors, and Cursor's approved servers.
set -u
part=1; [[ "${1:-}" != --part2 ]] || { part=2; shift; }
out="${1:?usage: tools/mcp-probe.sh [--part2] <out folder> [tool]...}"; shift
mkdir -p "$out" && out="$(cd "$out" && pwd -P)" || exit 2
case "$out" in *[\'\"\\\$\`]*) echo "the out folder's path cannot hold a quote, a backslash, \$ or a backtick" >&2; exit 2 ;; esac
KIT="$(cd "$(dirname "$0")/.." && pwd -P)"
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
# sig <status>: a command stopped by Ctrl-C (or TERM, HUP) stops the probe, and the EXIT trap puts every file back.
sig() { case "$1" in 129|130|143) echo "stopped (exit $1)" >&2; exit "$1" ;; esac; }
H="$R/home" W="$R/work" M="$R/marks" O="$R/other"
[[ -z "${CABINET_PROBE_HOME:-}" ]] || { mkdir -p "$CABINET_PROBE_HOME" && H="$(cd "$CABINET_PROBE_HOME" && pwd -P)" || exit 2; }
mkdir -p "$H" "$W" "$M" "$O" "$R/tmp" "$R/fakes"
git init -q "$W"
for t in security secret-tool launchctl systemctl crontab gh osascript notify-send; do
  printf '#!/bin/sh\necho "fake %s: refused in the probe" >&2\nexit 1\n' "$t" > "$R/fakes/$t"; chmod +x "$R/fakes/$t"
done
# The fake security also notes what it was asked for: the subcommand and the service name, never a value.
cat > "$R/fakes/security" <<FAKE
#!/bin/sh
c="\$1"; s=""; while [ \$# -gt 0 ]; do [ "\$1" = -s ] && s="\$2"; shift; done
printf '%s %s\n' "\$c" "\$s" >> "$out/keychain-asks.log"
echo "fake security: refused in the probe" >&2
exit 1
FAKE
mkdir -p "$R/git-hooks"; printf '#!/bin/sh\necho "the probe refuses every push" >&2\nexit 1\n' > "$R/git-hooks/pre-push"; chmod +x "$R/git-hooks/pre-push"
pass=(); for v in ${CABINET_PROBE_PASS:-}; do [[ "$v" =~ ^[A-Z_][A-Z0-9_]*$ && -n "${!v:-}" ]] && pass+=("$v=${!v}"); done
key="${CABINET_PROBE_KEY:-}"; unset CABINET_PROBE_KEY ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN NPM_TOKEN NODE_AUTH_TOKEN
for v in $(compgen -e); do case "$v" in GIT_*|XDG_*|npm_config_*|NPM_CONFIG_*|CLAUDE_CONFIG_DIR|CODEX_HOME|OPENCODE_CONFIG) unset "$v" ;; esac; done
export HOME="$H" GIT_CONFIG_GLOBAL="$H/.gitconfig" TMPDIR="$R/tmp" PATH="$R/fakes:$PATH"
# git: no system config, no credential helper (an empty value clears every one set before it), no prompt, no push.
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
  GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1="$R/git-hooks"
if printf 'protocol=https\nhost=example.invalid\n\n' | GIT_TRACE=1 git credential fill 2>&1 | grep -q 'credential-'; then
  echo "git in the probe still runs a credential helper: stopping before any tool runs" >&2; exit 2
fi

# The stand-in server: one read-only tool. Its first argument names it; it writes $M/<name> when started.
cat > "$R/standin.js" <<'JS'
const fs = require("node:fs"), name = process.argv[2], marks = process.argv[3];
fs.writeFileSync(marks + "/" + name, "started\n");
let buf = "";
const send = (o) => process.stdout.write(JSON.stringify(o) + "\n");
process.stdin.on("data", (d) => {
  buf += d; let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    let m; try { m = JSON.parse(line); } catch (e) { continue; }
    if (m.id === undefined) continue;
    if (m.method === "initialize") send({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: m.params?.protocolVersion || "2024-11-05", capabilities: { tools: {} }, serverInfo: { name, version: "1.0.0" } } });
    else if (m.method === "tools/list") send({ jsonrpc: "2.0", id: m.id, result: { tools: ["probe_echo", "merge_probe", "push_probe", "list_probe"].map((t) => ({ name: t, description: "Echo the text back (reads nothing, writes nothing beyond a mark that it was called)", inputSchema: { type: "object", properties: { text: { type: "string" } } } })) } });
    else if (m.method === "tools/call") { fs.writeFileSync(marks + "/call-" + String(m.params?.name).replace(/[^A-Za-z0-9_-]/g, "_"), "called\n"); send({ jsonrpc: "2.0", id: m.id, result: { content: [{ type: "text", text: String(m.params?.arguments?.text ?? "") }] } }); }
    else send({ jsonrpc: "2.0", id: m.id, result: {} });
  }
});
JS
srv() { printf '{"command": "node", "args": ["%s", "%s", "%s"]}' "$R/standin.js" "$1" "$M"; }   # srv <name>: a JSON definition
printf '%s\t%s\t%s\t%s\n' row version command result > "$out/probe.tsv"
n=0
# run <row> <tool> <marks wanted, space separated, or -> <command>...: the command in $W, then which stand-ins started.
run() {
  local row=$1 tool=$2 want=$3 got="" s st=0 ver; shift 3; n=$((n + 1))
  rm -f "$M"/*
  ver="$("$tool" --version 2>/dev/null | head -1)"
  (cd "$W" && node "$KIT/scripts/lib.js" run-limited 120 "$@") > "$out/$n-$row.log" 2>&1 || st=$?
  sig "$st"
  for s in "$M"/*; do [[ -e "$s" ]] && got+="${got:+ }${s##*/}"; done
  local res="started: ${got:-none} (exit $st)"
  # A tool that exits non-zero or prints an error may have stopped before it loaded anything: never a pass.
  if [[ "$want" == - ]]; then :
  elif ((st)) || grep -qiE '^(error|fatal)' "$out/$n-$row.log"; then res+="; unclear (the tool failed: see $n-$row.log)"
  elif [[ "$got" == "$want" ]]; then res+="; as expected"
  else res+="; NOT as expected (wanted ${want// /, })"; fi
  printf '%s\t%s\t%s\t%s\n' "$row" "${ver:-unknown}" "$(said "$*")" "$res" >> "$out/probe.tsv"
}
# said <command>: the command as written to the results, the key replaced by <key>.
said() { local c="$1"; [[ -z "$key" ]] || c="${c//"$key"/<key>}"; printf '%s' "$c"; }
# lists <row> <tool> <name that must show> <name that must not> <command>...: a tool's own server list.
lists() {
  local row=$1 tool=$2 yes=$3 no=$4 st=0 ver res; shift 4; n=$((n + 1))
  ver="$("$tool" --version 2>/dev/null | head -1)"
  (cd "$W" && node "$KIT/scripts/lib.js" run-limited 120 "$@") > "$out/$n-$row.log" 2>&1 || st=$?
  sig "$st"; res="exit $st"
  if grep -q "$yes" "$out/$n-$row.log"; then res+="; lists $yes"; else res+="; does not list $yes"; fi
  if [[ "$no" != - ]]; then if grep -q "$no" "$out/$n-$row.log"; then res+="; lists $no"; else res+="; does not list $no"; fi; fi
  printf '%s\t%s\t%s\t%s\n' "$row" "${ver:-unknown}" "$*" "$res" >> "$out/probe.tsv"
}
P="Reply with the single word OK."
if ((part == 2)); then
  # Files a row changes: each kept as it was, once, and put back when the probe ends (or removed if it was not there).
  saved=()
  keep() { local f s; for f in "$@"; do for s in ${saved[@]+"${saved[@]}"}; do [[ "$s" != "$f" ]] || continue 2; done
    saved+=("$f"); if [[ -e "$f" ]]; then cp -p "$f" "$R/saved.${#saved[@]}"; fi; done; }
  # Grok writes its own server list (grok mcp add), so the stand-in comes out with grok mcp remove, at the end or on a stop.
  grok_added=0
  grok_remove() { ((grok_added)) || return 0; grok_added=0
    (cd "$W" && node "$KIT/scripts/lib.js" run-limited 60 grok mcp remove standin) >> "$out/grok-mcp-add.log" 2>&1; }
  restore() { local i f; for ((i = 0; i < ${#saved[@]}; i++)); do f="${saved[$i]}"
    if [[ -e "$R/saved.$((i + 1))" ]]; then cp -p "$R/saved.$((i + 1))" "$f"; else rm -f "$f"; fi; done; grok_remove; }
  trap 'restore; rm -rf "$R"' EXIT
  # orig <file>: the saved copy of a kept file (absent when it was not there).
  orig() { local i; for i in "${!saved[@]}"; do [[ "${saved[$i]}" != "$1" ]] || { echo "$R/saved.$((i + 1))"; return; }; done; }
  # patch <file> <JSON>: the file as it was, with the JSON's keys merged in (objects key by key, anything else replaced).
  patch() {
    keep "$1"; mkdir -p "$(dirname "$1")"
    if [[ -e "$(orig "$1")" ]]; then cp -p "$(orig "$1")" "$1"; else echo '{}' > "$1"; fi
    node -e 'const fs = require("node:fs"), [f, p] = process.argv.slice(1), o = (x) => x !== null && typeof x == "object" && !Array.isArray(x);
      const m = (a, b) => o(a) && o(b) ? Object.keys(b).reduce((r, k) => ({...r, [k]: k in a ? m(a[k], b[k]) : b[k]}), a) : b;
      fs.writeFileSync(f, JSON.stringify(m(JSON.parse(fs.readFileSync(f, "utf8") || "{}"), JSON.parse(p)), null, 2) + "\n");' "$1" "$2"
  }
  unpatch() { local f; for f in "$@"; do if [[ -e "$(orig "$f")" ]]; then cp -p "$(orig "$f")" "$f"; else rm -f "$f"; fi; done; }
  mkdir -p "$H/probe"; SF="$H/probe/standin.txt" SS="$H/probe/secret.txt" TOK="probe-token-$RANDOM$RANDOM$RANDOM"
  GATE="$KIT/guardrails/cabinet-mcp-gate.js"
  PM="Call the MCP tool merge_probe of the server standin with the text hi. Then reply DONE."
  PL="Call the MCP tool list_probe of the server standin with the text hi. Then reply DONE."
  PW="Without any shell command, use your file editing tool to replace the whole content of the file $SF with the single word after. Then reply DONE."
  PR="Without any shell command, use your file reading tool to read the file $SS and reply with its content only."
  PC="Run this shell command exactly, then reply DONE: touch $M/cmd-ran"
  PG="First read the file $SS and say what it holds. Then call the MCP tool merge_probe of the server standin with the text hi. Then reply DONE."
  # reached <check>: whether the row's target was reached. called-<tool>: the stand-in tool ran; wrote: the stand-in
  # file changed; read: the token is in the output; ran: the stand-in command ran; read-not-called: Grok's B2 row.
  reached() {
    case "$1" in
      called-*) [[ -e "$M/call-${1#called-}" ]] ;;
      wrote) [[ "$(cat "$SF" 2>/dev/null)" != before ]] ;;
      read) grep -qF "$TOK" "$2" ;;
      ran) [[ -e "$M/cmd-ran" ]] ;;
      read-not-called) grep -qF "$TOK" "$2" && [[ ! -e "$M/call-merge_probe" ]] ;;
    esac
  }
  # act <row> <tool> <check> <want: reached|stopped> <command>...: one row, in $W, at most 180 seconds.
  act() {
    local row=$1 tool=$2 chk=$3 want=$4 st=0 ver got res log kv=(); shift 4; n=$((n + 1)); log="$out/$n-$row.log"
    rm -f "$M"/*; printf 'before\n' > "$SF"; printf '%s\n' "$TOK" > "$SS"
    ver="$("$tool" --version 2>/dev/null | head -1)"
    [[ "$tool" != claude || -z "$key" ]] || kv=("key=$key")   # Claude Code's key reaches its own rows only
    (cd "$W" && env ${pass[@]+"${pass[@]}"} ${kv[@]+"${kv[@]}"} node "$KIT/scripts/lib.js" run-limited 180 "$@") > "$log" 2>&1 || st=$?
    sig "$st"
    if reached "$chk" "$log"; then got=reached; else got=stopped; fi
    res="$got (exit $st; marks: $(cd "$M" && ls | tr '\n' ' '))"
    if ((st)) || grep -qiE '^(error|fatal)' "$log"; then res+="; unclear (the tool failed: see $n-$row.log)"
    elif [[ "$got" == "$want" ]]; then res+="; as expected"
    else res+="; NOT as expected (wanted $want)"; fi
    printf '%s\t%s\t%s\t%s\n' "$row" "${ver:-unknown}" "$(said "$*")" "$res" >> "$out/probe.tsv"
  }
  CS="$H/.claude/settings.json" QS="$H/.qwen/settings.json" OC="$H/.config/opencode/opencode.json" CC="$H/.cursor/cli-config.json" CM="$H/.cursor/mcp.json"
  AS="$H/.gemini/antigravity-cli/settings.json" AM="$H/.gemini/config/mcp_config.json" AH="$H/.gemini/config/hooks.json"
  printf '{"mcpServers": {"standin": %s}}\n' "$(srv standin)" > "$R/mcp-standin.json"
  allow='"mcp__standin__merge_probe", "mcp__standin__list_probe"'
  hook() { node "$KIT/scripts/lib.js" hook-merge "$1" "$2" "$3" "$GATE" > "$R/hooked.json" && cp "$R/hooked.json" "$2"; }
  claude_run() { env ${key:+ANTHROPIC_API_KEY="$key"} claude -p --permission-mode auto --output-format json "$1" --strict-mcp-config --mcp-config "$R/mcp-standin.json"; }
  grok_run() { grok -p "$1" --permission-mode auto --output-format json; }
  qwen_run() { qwen --approval-mode auto -o json --allowed-mcp-server-names standin "$1"; }
  oc_run() { opencode run --format json "$1"; }
  cursor_run() { cursor-agent -p --force --approve-mcps --output-format json "$1"; }   # the probe approves the stand-in; the kit never does
  agy_run() { agy -p "$1" --output-format json --dangerously-skip-permissions "${@:2}"; }
  # file_rows <row prefix> <tool> <run function> <settings file> <JSON write deny> <JSON read deny> <JSON control>: the
  # write and read rows and their controls, each JSON merged into the file as it was.
  file_rows() {
    local pre=$1 tool=$2 runf=$3 file=$4 w=$5 r=$6 base=$7
    patch "$file" "$w"; act "$pre-write" "$tool" wrote stopped bash -c "$runf"' "$0"' "$PW"
    patch "$file" "$base"; act "$pre-write-control" "$tool" wrote reached bash -c "$runf"' "$0"' "$PW"
    patch "$file" "$r"; act "$pre-read" "$tool" read stopped bash -c "$runf"' "$0"' "$PR"
    patch "$file" "$base"; act "$pre-read-control" "$tool" read reached bash -c "$runf"' "$0"' "$PR"
    unpatch "$file"
  }
  export -f claude_run grok_run qwen_run oc_run cursor_run agy_run
  tools=("$@"); ((${#tools[@]})) || for t in claude grok qwen opencode cursor-agent agy github; do
    case "$t" in github) tools+=(github) ;; *) command -v "$t" >/dev/null && tools+=("$t") ;; esac; done
  for t in "${tools[@]}"; do
    case "$t" in
      claude)
        patch "$CS" "{\"permissions\": {\"allow\": [$allow], \"deny\": [\"mcp__standin__merge_probe\"]}}"; act claude-a claude called-merge_probe stopped bash -c 'claude_run "$0"' "$PM"
        unpatch "$CS"; patch "$CS" "{\"permissions\": {\"allow\": [$allow]}}"; act claude-a-control claude called-merge_probe reached bash -c 'claude_run "$0"' "$PM"
        hook claude "$CS" 'mcp__.*'; act claude-b claude called-merge_probe stopped bash -c 'claude_run "$0"' "$PM"
        act claude-b-read claude called-list_probe reached bash -c 'claude_run "$0"' "$PL"
        unpatch "$CS"
        file_rows claude-c claude 'claude_run' "$CS" '{"permissions": {"deny": ["Bash", "Edit(~/probe/standin.txt)", "Write(~/probe/standin.txt)"]}}' \
          '{"permissions": {"deny": ["Bash", "Read(~/probe/secret.txt)"]}}' '{"permissions": {"deny": ["Bash"]}}'
        patch "$CS" "{\"permissions\": {\"deny\": [\"Bash\", \"Edit(/$SF)\", \"Write(/$SF)\"]}}"; act claude-c-write-abs claude wrote stopped bash -c 'claude_run "$0"' "$PW"
        unpatch "$CS" ;;
      grok)
        grok_added=1; st=0; (cd "$W" && node "$KIT/scripts/lib.js" run-limited 60 grok mcp add standin node "$R/standin.js" standin "$M") > "$out/grok-mcp-add.log" 2>&1 || st=$?; sig "$st"
        patch "$CS" "{\"permissions\": {\"allow\": [$allow], \"deny\": [\"mcp__standin__merge_probe\"]}}"; act grok-a grok called-merge_probe stopped bash -c 'grok_run "$0"' "$PM"
        unpatch "$CS"; patch "$CS" "{\"permissions\": {\"allow\": [$allow]}}"; act grok-a-control grok called-merge_probe reached bash -c 'grok_run "$0"' "$PM"
        hook claude "$CS" 'mcp__.*'; act grok-b grok read-not-called reached bash -c 'grok_run "$0"' "$PG"
        unpatch "$CS"; patch "$CS" "{\"permissions\": {\"allow\": [$allow]}}"; act grok-b-control grok called-merge_probe reached bash -c 'grok_run "$0"' "$PG"
        unpatch "$CS"
        file_rows grok-c grok 'grok_run' "$CS" '{"permissions": {"deny": ["Bash", "Edit(~/probe/standin.txt)", "Write(~/probe/standin.txt)"]}}' \
          '{"permissions": {"deny": ["Bash", "Read(~/probe/secret.txt)"]}}' '{"permissions": {"deny": ["Bash"]}}'
        grok_remove ;;
      qwen)
        q="{\"mcpServers\": {\"standin\": $(srv standin)}"
        patch "$QS" "$q, \"permissions\": {\"deny\": [\"mcp__standin__merge_probe\"]}}"; act qwen-a qwen called-merge_probe stopped bash -c 'qwen_run "$0"' "$PM"
        unpatch "$QS"; patch "$QS" "$q}"; act qwen-a-control qwen called-merge_probe reached bash -c 'qwen_run "$0"' "$PM"
        file_rows qwen-c qwen 'qwen_run' "$QS" '{"permissions": {"deny": ["Bash", "Edit(~/probe/standin.txt)", "Write(~/probe/standin.txt)"]}}' \
          '{"permissions": {"deny": ["Bash", "Read(~/probe/secret.txt)"]}}' "$q, \"permissions\": {\"deny\": [\"Bash\"]}}" ;;
      opencode)
        o="{\"mcp\": {\"standin\": {\"type\": \"local\", \"command\": [\"node\", \"$R/standin.js\", \"standin\", \"$M\"]}}"
        patch "$OC" "$o, \"permission\": {\"standin_merge_probe\": \"deny\"}}"; act opencode-a opencode called-merge_probe stopped bash -c 'oc_run "$0"' "$PM"
        unpatch "$OC"; patch "$OC" "$o}"; act opencode-a-control opencode called-merge_probe reached bash -c 'oc_run "$0"' "$PM"
        file_rows opencode-c opencode 'oc_run' "$OC" "{\"permission\": {\"bash\": \"deny\", \"edit\": {\"$SF\": \"deny\"}}}" \
          "{\"permission\": {\"bash\": \"deny\", \"read\": {\"$SS\": \"deny\"}}}" "$o, \"permission\": {\"bash\": \"deny\"}}" ;;
      cursor-agent|cursor)
        patch "$CM" "{\"mcpServers\": {\"standin\": $(srv standin)}}"
        patch "$CC" '{"permissions": {"deny": ["Mcp(standin:merge_probe)"]}}'; act cursor-e1 cursor-agent called-merge_probe stopped bash -c 'cursor_run "$0"' "$PM"
        unpatch "$CC"; act cursor-e1-control cursor-agent called-merge_probe reached bash -c 'cursor_run "$0"' "$PM"
        file_rows cursor-e2 cursor-agent 'cursor_run' "$CC" "{\"permissions\": {\"deny\": [\"Shell(*)\", \"Write($SF)\"]}}" \
          "{\"permissions\": {\"deny\": [\"Shell(*)\", \"Read($SS)\"]}}" '{"permissions": {"deny": ["Shell(*)"]}}'
        unpatch "$CM" ;;
      agy)
        patch "$AM" "{\"mcpServers\": {\"standin\": $(srv standin)}}"
        mkdir -p "$H/.gemini/config"; printf '{"mcpServers": {"decoy": %s}}\n' "$(srv decoy)" > "$R/decoy.json"; keep "$H/.gemini/config/decoy.json"; cp "$R/decoy.json" "$H/.gemini/config/decoy.json"
        lists agy-f6-list agy standin decoy agy mcp list
        act agy-f6-run agy called-list_probe reached bash -c 'agy_run "$0"' "$PL"
        patch "$AS" "{\"permissions\": {\"deny\": [\"command(regex:^touch\\\\s+.*cmd-ran)\"]}}"; act agy-f1 agy ran stopped bash -c 'agy_run "$0"' "$PC"
        unpatch "$AS"; act agy-f1-control agy ran reached bash -c 'agy_run "$0"' "$PC"
        patch "$AS" '{"permissions": {"deny": ["mcp(standin/merge_probe)"]}}'; act agy-f2 agy called-merge_probe stopped bash -c 'agy_run "$0"' "$PM"
        unpatch "$AS"; act agy-f2-control agy called-merge_probe reached bash -c 'agy_run "$0"' "$PM"
        patch "$AS" "{\"permissions\": {\"deny\": [\"command(*)\", \"write_file($SF)\"]}}"; act agy-f3 agy wrote stopped bash -c 'agy_run "$0"' "$PW"
        patch "$AS" "{\"permissions\": {\"deny\": [\"command(*)\", \"read_file($SS)\"]}}"; act agy-f4 agy read stopped bash -c 'agy_run "$0"' "$PR"
        unpatch "$AS"; patch "$AS" '{"permissions": {"deny": ["command(*)"]}}'; act agy-f3-control agy wrote reached bash -c 'agy_run "$0"' "$PW"
        act agy-f4-control agy read reached bash -c 'agy_run "$0"' "$PR"; unpatch "$AS"
        # f5: first a hook that only records what it is given, then the kit's gate.
        patch "$AH" "{\"probe-shape\": {\"PreToolUse\": [{\"matcher\": \"\", \"hooks\": [{\"type\": \"command\", \"command\": \"cat >> '$out/agy-hook-input.jsonl'; echo >> '$out/agy-hook-input.jsonl'\"}]}]}}"
        act agy-f5-shape agy called-merge_probe reached bash -c 'agy_run "$0"' "$PM"
        unpatch "$AH"; hook agy "$AH" ''; act agy-f5 agy called-merge_probe stopped bash -c 'agy_run "$0"' "$PM"
        act agy-f5-read agy called-list_probe reached bash -c 'agy_run "$0"' "$PL"; unpatch "$AH"
        # f7: a session file denying the stand-in's tools; then (B1) a deny in the user file still holds beside it.
        printf '{"permissions": {"deny": ["mcp(standin/*)"]}}\n' > "$R/agy-session.json"
        act agy-f7 agy called-merge_probe stopped bash -c 'agy_run "$0" --settings "$1"' "$PM" "$R/agy-session.json"
        patch "$AS" '{"permissions": {"deny": ["command(touch)"]}}'
        act agy-f7-kept agy ran stopped bash -c 'agy_run "$0" --settings "$1"' "$PC" "$R/agy-session.json"
        unpatch "$AS" "$AM" "$H/.gemini/config/decoy.json" ;;
      github)
        # The GitHub MCP server's own tool list, with a dummy token: initialize and tools/list only.
        if command -v github-mcp-server >/dev/null; then gh_cmd=(github-mcp-server stdio)
        elif command -v docker >/dev/null; then gh_cmd=(docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server)
        else echo "github: neither github-mcp-server nor docker is installed, so line g is not probed" >&2; continue; fi
        GITHUB_PERSONAL_ACCESS_TOKEN=dummy-not-a-token node -e '
          const { spawn } = require("node:child_process"), p = spawn(process.argv[1], process.argv.slice(2), { stdio: ["pipe", "pipe", "inherit"] });
          let buf = "", info = null; const send = (o) => p.stdin.write(JSON.stringify(o) + "\n");
          const stop = setTimeout(() => { console.error("no tool list within 120 seconds"); p.kill(); process.exit(1); }, 120000);
          p.stdout.on("data", (d) => { buf += d; let i; while ((i = buf.indexOf("\n")) >= 0) { const l = buf.slice(0, i); buf = buf.slice(i + 1); let m; try { m = JSON.parse(l); } catch (e) { continue; }
            if (m.id === 1) { info = m.result && m.result.serverInfo; send({ jsonrpc: "2.0", method: "notifications/initialized" }); send({ jsonrpc: "2.0", id: 2, method: "tools/list" }); }
            else if (m.id === 2) { console.log("server " + JSON.stringify(info)); for (const t of (m.result && m.result.tools) || []) console.log(t.name); clearTimeout(stop); p.kill(); process.exit(0); } } });
          send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "cabinet-probe", version: "1" } } });' \
          "${gh_cmd[@]}" > "$out/github-tools.txt" 2> "$out/github-tools.log" \
          && printf '%s\t%s\t%s\t%s\n' github-tools "$(head -1 "$out/github-tools.txt")" "${gh_cmd[*]}" "$(($(wc -l < "$out/github-tools.txt") - 1)) tools, in github-tools.txt" >> "$out/probe.tsv" \
          || printf '%s\t%s\t%s\t%s\n' github-tools unknown "${gh_cmd[*]}" "unclear (see github-tools.log)" >> "$out/probe.tsv" ;;
      *) echo "unknown tool: $t" >&2 ;;
    esac
  done
  cat <<EOF2
Results: $out/probe.tsv (one log per command beside it; Antigravity's hook input in agy-hook-input.jsonl).

Five steps this script cannot run. Each touches only stand-ins:
1. Claude Code's hook in a session (line b): this script puts every file back when it ends, so in the HOME you kept
   (CABINET_PROBE_HOME), print the settings with the kit's entry added and save them as <folder>/.claude/settings.json:
     node scripts/lib.js hook-merge claude <folder>/.claude/settings.json 'mcp__.*' "\$PWD/guardrails/cabinet-mcp-gate.js"
   then HOME=<folder> claude, add an echo-only stand-in server (claude mcp add), ask it to call a tool named
   merge_probe, and note whether the hook refused it. Take the entry out of that file afterwards.
2. Antigravity in a session (f1 to f5): the same, with HOME=<folder> agy, for each of the rules in the rows agy-f1 to agy-f5.
3. Claude Code's admin file (h1), on a test account or in a container: put a managed-settings.json holding the kit's
   denies, a deny of the stand-in "Bash(*cabinet-probe-h1*)", and "disableBypassPermissionsMode": "disable" under
   "permissions", at /Library/Application Support/ClaudeCode/ (macOS) or /etc/claude-code/ (Linux), then
     claude -p --permission-mode auto "Run this shell command exactly, then reply DONE: touch /tmp/cabinet-probe-h1"
   The run should start and /tmp/cabinet-probe-h1 should not exist. Control: the same without the file: it exists.
4. Codex's admin file (h2), the same way: a requirements.toml with allowed_approval_policies = ["on-request", "untrusted"]
   and allowed_sandbox_modes = ["read-only", "workspace-write"] at /etc/codex/, and the kit's guardrails/codex-default.rules
   as ~/.codex/rules/default.rules with one more line, prefix_rule(pattern = ["touch"], decision = "forbidden"), then
     codex exec "Run this shell command exactly, then reply DONE: touch /tmp/cabinet-probe-h2"
   The run should start and /tmp/cabinet-probe-h2 should not exist. Control: the same with neither file: it exists.
5. Antigravity's admin layer (f8): if its docs or settings name a system-wide settings file, note its name and path.
EOF2
  exit 0
fi
[[ -z "${CABINET_PROBE_HOME:-}" ]] || { echo "CABINET_PROBE_HOME is for --part2 only: part 1 writes ~/.claude.json, which holds a login" >&2; exit 2; }
tools=("$@"); ((${#tools[@]})) || for t in claude qwen codex gemini opencode cursor-agent grok agy; do command -v "$t" >/dev/null && tools+=("$t"); done
for t in "${tools[@]}"; do
  case "$t" in
    claude)
      printf '{"mcpServers": {"standin": %s}}\n' "$(srv standin)" > "$H/.claude.json"
      printf '{"mcpServers": {}}\n' > "$R/empty.json"; mkdir -p "$H/.claude"; printf '{"mcpServers": {"decoy": %s}}\n' "$(srv decoy)" > "$H/.claude/decoy.json"
      ANTHROPIC_API_KEY="$key" run claude-flag-control claude standin claude -p "$P"
      ANTHROPIC_API_KEY="$key" run claude-flag claude "" claude -p "$P" --strict-mcp-config --mcp-config "$R/empty.json"
      ANTHROPIC_API_KEY="$key" run claude-config-dir claude "" env CLAUDE_CONFIG_DIR="$O" claude -p "$P"
      lists claude-list claude standin decoy claude mcp list ;;
    qwen)
      mkdir -p "$H/.qwen"; printf '{"mcpServers": {"a": %s, "b": %s, "c": %s}}\n' "$(srv a)" "$(srv b)" "$(srv c)" > "$H/.qwen/settings.json"
      printf '{"mcpServers": {"decoy": %s}}\n' "$(srv decoy)" > "$H/.qwen/decoy.json"
      run qwen-flag-control qwen "a b c" qwen -p "$P"
      run qwen-flag-empty qwen "" qwen --allowed-mcp-server-names "" -p "$P"
      run qwen-flag-list qwen "a b" qwen --allowed-mcp-server-names a,b -p "$P"
      lists qwen-list qwen a decoy qwen mcp list ;;
    codex)
      mkdir -p "$H/.codex"; printf '[mcp_servers.standin]\ncommand = "node"\nargs = ["%s", "standin", "%s"]\n' "$R/standin.js" "$M" > "$H/.codex/config.toml"
      printf '[mcp_servers.decoy]\ncommand = "node"\n' > "$H/.codex/decoy.toml"
      lists codex-list codex standin decoy codex mcp list
      lists codex-home codex standin - env CODEX_HOME="$O" codex mcp list ;;
    gemini)
      mkdir -p "$H/.gemini"; printf '{"mcpServers": {"standin": %s}}\n' "$(srv standin)" > "$H/.gemini/settings.json"
      printf '{"mcpServers": {"decoy": %s}}\n' "$(srv decoy)" > "$H/.gemini/decoy.json"
      lists gemini-list gemini standin decoy gemini mcp list ;;
    opencode)
      mkdir -p "$H/.config/opencode"
      printf '{"mcp": {"standin": {"type": "local", "command": ["node", "%s", "standin", "%s"]}}}\n' "$R/standin.js" "$M" > "$H/.config/opencode/opencode.json"
      printf '{"mcp": {"decoy": {"type": "local", "command": ["node"]}}}\n' > "$H/.config/opencode/decoy.json"
      printf '{}\n' > "$O/opencode.json"
      lists opencode-list opencode standin decoy opencode mcp list
      lists opencode-config opencode standin - env OPENCODE_CONFIG="$O/opencode.json" opencode mcp list
      lists opencode-xdg opencode standin - env XDG_CONFIG_HOME="$O" opencode mcp list ;;
    cursor-agent|cursor)
      mkdir -p "$H/.cursor"; printf '{"mcpServers": {"standin": %s}}\n' "$(srv standin)" > "$H/.cursor/mcp.json"
      printf '{"mcpServers": {"decoy": %s}}\n' "$(srv decoy)" > "$H/.cursor/decoy.json"
      lists cursor-list cursor-agent standin decoy cursor-agent mcp list ;;
    grok) lists grok-list grok standin - grok mcp list ;;
    agy) lists agy-list agy standin - agy mcp list ;;
    *) echo "unknown tool: $t" >&2 ;;
  esac
done
cat <<EOF
Results: $out/probe.tsv (one log per command beside it).

Two steps need your own account, so this script does not run them. Each only reads:
1. Account connectors (Claude Code): in your own terminal, in an empty folder,
   claude -p "Name every MCP tool you can call, or say NONE." --strict-mcp-config --mcp-config '{"mcpServers":{}}'
   and the same without the two flags (the prompt first: Claude Code reads every word after --mcp-config as a
   config file). The first should name none of your account's connectors.
2. Cursor: approve the stand-in (or any read-only server) in your own Cursor session, then in an empty folder
   cursor-agent -p --force "Name every MCP tool you can call, or say NONE."
   It should name none of them, since the kit never passes --approve-mcps.
EOF
