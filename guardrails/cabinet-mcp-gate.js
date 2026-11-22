// cabinet mcp gate v2
// The verb hook: a PreToolUse hook that refuses an MCP tool whose name could write outside this machine.
//   node cabinet-mcp-gate.js claude|agy < hook input (JSON)
// The tool name is the whole name, server part included (mcp__pushover__list_items holds "push"), matched in any
// case. A name holding a verb is refused, a read such as list_releases too. Input that is empty, not JSON or has no
// tool name is refused: the gate fails closed. Antigravity sends every MCP call as the tool call_mcp_tool, with the
// server in args.ServerName and the tool in args.ToolName (owner probe f5, Antigravity 1.5.14): the whole name is
// those two together, and a call_mcp_tool whose ToolName is not a string is refused. Any other Antigravity tool is
// not an MCP tool, and is let through. Claude Code's refusal is exit 2 with the reason on stderr.
// Antigravity's is {"decision": "deny"} on stdout and exit 0, the command bootstrap writes adding the same JSON when
// node or this file fails. A name it lets through gets no output and exit 0, so the tool's own rules decide as
// before; the gate never allows anything. The input is only parsed and matched,
// never run or written anywhere. Bootstrap places this file beside the push gate, in the global hooks folder.
"use strict";
const fs = require("node:fs");

const VERBS = ["merge", "push", "create_or_update", "delete", "release", "publish", "deploy", "send"];
const kind = process.argv[2];

function refuse(why) {
  process.stderr.write(why + "\n");
  if (kind !== "agy") process.exit(2);
  process.stdout.write(JSON.stringify({ decision: "deny", reason: why }) + "\n");
  process.exit(0);
}

if (kind !== "claude" && kind !== "agy") refuse("cabinet: the MCP gate was run without its tool (claude or agy), so it refuses");
let input;
try { input = JSON.parse(fs.readFileSync(0, "utf8")); } catch (e) { refuse("cabinet: the MCP gate could not read the tool call, so it refuses"); }
const isObj = (x) => x !== null && typeof x === "object";
let name = !isObj(input) ? undefined : kind === "claude" ? input.tool_name : isObj(input.toolCall) ? input.toolCall.name : undefined;
if (typeof name !== "string" || name === "") refuse("cabinet: the MCP gate found no tool name in the call, so it refuses");
if (kind === "agy") {
  if (name !== "call_mcp_tool") process.exit(0);
  const a = input.toolCall.args, server = isObj(a) ? a.ServerName : undefined, tool = isObj(a) ? a.ToolName : undefined;
  if (typeof tool !== "string" || tool === "" || (server !== undefined && typeof server !== "string")) refuse("cabinet: the MCP gate found no MCP tool name in the call, so it refuses");
  name = server ? server + "/" + tool : tool;
}
const verb = VERBS.find((v) => name.toLowerCase().includes(v));
if (verb) refuse(`cabinet: ${name} holds "${verb}", so it may write outside this machine: only the owner does that. Hand it to the owner`);
