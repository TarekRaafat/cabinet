// cabinet mcp gate v1
// The verb hook: a PreToolUse hook that refuses an MCP tool whose name could write outside this machine.
//   node cabinet-mcp-gate.js claude|agy < hook input (JSON)
// The tool name is the whole name, server part included (mcp__pushover__list_items holds "push"), matched in any
// case. A name holding a verb is refused, a read such as list_releases too. Input that is empty, not JSON or has no
// tool name is refused: the gate fails closed. Claude Code's refusal is exit 2 with the reason on stderr.
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
const name = input === null || typeof input !== "object" ? undefined
  : kind === "claude" ? input.tool_name : input.toolCall !== null && typeof input.toolCall === "object" ? input.toolCall.name : undefined;
if (typeof name !== "string" || name === "") refuse("cabinet: the MCP gate found no tool name in the call, so it refuses");
const verb = VERBS.find((v) => name.toLowerCase().includes(v));
if (verb) refuse(`cabinet: ${name} holds "${verb}", so it may write outside this machine: only the owner does that. Hand it to the owner`);
