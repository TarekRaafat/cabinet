#!/usr/bin/env bash
# The MCP probe: checks, with each real agent tool, the lines the kit's MCP rules rely on ("Outside the shell" in
# docs/guardrails.md): which flag keeps a run's MCP servers out, which variable moves a tool's settings folder, and
# which file holds a tool's server list. Run by the maintainer, never by the suite; not shipped (package.json
# "files" leaves tools/ out).
#
#   tools/mcp-probe.sh <out folder> [claude|qwen|codex|gemini|opencode|cursor|grok|agy]...   (default: each installed)
#
# Safety:
# - A new mktemp HOME, with GIT_CONFIG_GLOBAL, TMPDIR and every XDG folder inside it, and fakes of security,
#   secret-tool, launchctl, systemctl, crontab and gh first on PATH: nothing reaches the real keychain, schedules,
#   GitHub login or the real tool settings.
# - The only MCP server anywhere is a stand-in (standin.js), a few lines of Node that offer one read-only tool,
#   probe_echo, and write a mark file when a tool starts it. Whether a tool loaded a server is read from that mark,
#   not from what a model says. No push, merge, publish or network write is ever asked for.
# - Each tool runs in an empty folder with no git remote, at most 120 seconds per command.
# - A tool that needs a login gets none here, except Claude Code: CABINET_PROBE_KEY, when set, reaches only its
#   process, as ANTHROPIC_API_KEY, and is never written or printed. A command that fails for want of a login is
#   recorded as unclear, never as a pass.
# Results in <out>: probe.tsv (row, tool version, command, result) and one log per command. Two steps need your own
# account and are printed at the end instead: account connectors, and Cursor's approved servers.
set -u
out="${1:?usage: tools/mcp-probe.sh <out folder> [tool]...}"; shift
mkdir -p "$out" && out="$(cd "$out" && pwd -P)" || exit 2
KIT="$(cd "$(dirname "$0")/.." && pwd -P)"
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
H="$R/home" W="$R/work" M="$R/marks" O="$R/other"
mkdir -p "$H" "$W" "$M" "$O" "$R/tmp" "$R/fakes"
git init -q "$W"
for t in security secret-tool launchctl systemctl crontab gh osascript notify-send; do
  printf '#!/bin/sh\necho "fake %s: refused in the probe" >&2\nexit 1\n' "$t" > "$R/fakes/$t"; chmod +x "$R/fakes/$t"
done
key="${CABINET_PROBE_KEY:-}"; unset CABINET_PROBE_KEY ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN NPM_TOKEN NODE_AUTH_TOKEN
for v in $(compgen -e); do case "$v" in GIT_*|XDG_*|npm_config_*|NPM_CONFIG_*|CLAUDE_CONFIG_DIR|CODEX_HOME|OPENCODE_CONFIG) unset "$v" ;; esac; done
export HOME="$H" GIT_CONFIG_GLOBAL="$H/.gitconfig" TMPDIR="$R/tmp" PATH="$R/fakes:$PATH"

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
    else if (m.method === "tools/list") send({ jsonrpc: "2.0", id: m.id, result: { tools: [{ name: "probe_echo", description: "Echo the text back (reads nothing, writes nothing)", inputSchema: { type: "object", properties: { text: { type: "string" } } } }] } });
    else if (m.method === "tools/call") send({ jsonrpc: "2.0", id: m.id, result: { content: [{ type: "text", text: String(m.params?.arguments?.text ?? "") }] } });
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
  res="exit $st"
  if grep -q "$yes" "$out/$n-$row.log"; then res+="; lists $yes"; else res+="; does not list $yes"; fi
  if [[ "$no" != - ]]; then if grep -q "$no" "$out/$n-$row.log"; then res+="; lists $no"; else res+="; does not list $no"; fi; fi
  printf '%s\t%s\t%s\t%s\n' "$row" "${ver:-unknown}" "$*" "$res" >> "$out/probe.tsv"
}
P="Reply with the single word OK."
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
