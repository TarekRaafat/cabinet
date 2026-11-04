// The suite's rule matchers (not shipped): read each agent tool's rule file as bootstrap wrote it, and say
// which of its deny rules match a command, as docs/guardrails.md describes each tool's matching. Used by
// test/smoke.sh, section "guardrail self-protection".
//
//   node test/rule-match.js rules <tool> <file>            {"deny": [...], "ask": [...]} as the file holds them
//   node test/rule-match.js match <tool> <rules.json> [<command>...]
//                                                          "<command>\t<rule>" for each command a rule matches
//                                                          (commands from standard input, one a line, when none given)
//
// Tools: claude and qwen (Bash(...) globs: * is any text, over the whole command), opencode (the same globs,
// as permission.bash keys), gemini (each commandRegex run as written, in Node; commandPrefix at the start),
// cursor (split on && || ; |, leading NAME=value words dropped, Shell(<word>) when the first word is <word>,
// Shell(<word>:<pattern>) when the rest also matches the glob), codex (prefix_rule patterns, word by word at
// the start), agy (command(<words>) at the start). File rules (Read, Edit, Write) are not matched here: no
// tool's kit file holds one until a probe confirms the shape.
"use strict";
const fs = require("node:fs");

const glob = (p) => new RegExp("^" + p.split("*").map((x) => x.replace(/[.+?^${}()|[\]\\\/]/g, "\\$&")).join("[\\s\\S]*") + "$");
const words = (s) => s.trim().split(/\s+/).filter(Boolean);

function rules(tool, file) {
  const text = fs.readFileSync(file, "utf8");
  if (tool === "codex") {
    const ls = text.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("prefix_rule("));
    return { deny: ls.filter((l) => /decision = "forbidden"/.test(l)), ask: ls.filter((l) => /decision = "prompt"/.test(l)) };
  }
  if (tool === "gemini") {
    const out = { deny: [], ask: [] };
    for (const t of text.split(/^\[\[rule\]\]\s*$/m).slice(1)) {
      const f = {};
      for (const l of t.split("\n")) {
        const m = /^([A-Za-z_]+)\s*=\s*(".*")\s*$/.exec(l.trim());
        if (m) f[m[1]] = JSON.parse(m[2]);
      }
      const key = f.commandRegex !== undefined ? "re:" + f.commandRegex : "prefix:" + f.commandPrefix;
      if (f.decision === "deny") out.deny.push(key); else if (f.decision === "ask_user") out.ask.push(key);
      if (f.toolName !== "run_shell_command") out.deny.push("tool:" + f.toolName);
    }
    return out;
  }
  const j = JSON.parse(text);
  if (tool === "opencode") {
    const b = (j.permission && j.permission.bash) || {};
    const other = Object.keys(j.permission || {}).filter((k) => k !== "bash").map((k) => "tool:" + k);
    return { deny: Object.keys(b).filter((k) => b[k] === "deny").concat(other), ask: Object.keys(b).filter((k) => b[k] === "ask") };
  }
  const p = j.permissions || {};
  return { deny: p.deny || [], ask: p.ask || [] };
}

// Does one rule, in the tool's form, match the command?
function matches(tool, rule, cmd) {
  if (tool === "claude" || tool === "qwen") { const m = /^Bash\(([\s\S]*)\)$/.exec(rule); return !!m && glob(m[1]).test(cmd); }
  if (tool === "opencode") return !rule.startsWith("tool:") && glob(rule).test(cmd);
  if (tool === "gemini") {
    if (rule.startsWith("re:")) return new RegExp(rule.slice(3)).test(cmd);
    return rule.startsWith("prefix:") && (cmd === rule.slice(7) || cmd.startsWith(rule.slice(7) + " "));
  }
  if (tool === "cursor") {
    const m = /^Shell\(([^:)]+)(?::([\s\S]*))?\)$/.exec(rule);
    if (!m) return false;
    return cmd.split(/&&|\|\||;|\|/).some((part) => {
      const w = words(part);
      while (w.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(w[0])) w.shift();
      if (w[0] !== m[1]) return false;
      return m[2] === undefined || glob(m[2]).test(w.slice(1).join(" "));
    });
  }
  const w = words(cmd);
  if (tool === "agy") { const m = /^command\(([\s\S]*)\)$/.exec(rule); return !!m && words(m[1]).every((x, i) => w[i] === x); }
  if (tool === "codex") {
    const m = /pattern = (\[[\s\S]*?\]\]?)\s*,\s*decision/.exec(rule);
    if (!m) return false;
    return JSON.parse(m[1]).every((x, i) => (Array.isArray(x) ? x.includes(w[i]) : w[i] === x));
  }
  throw new Error("no matcher for " + tool);
}

const [cmd, tool, file, ...rest] = process.argv.slice(2);
if (cmd === "rules") process.stdout.write(JSON.stringify(rules(tool, file)) + "\n");
else if (cmd === "match") {
  const list = JSON.parse(fs.readFileSync(file, "utf8"));
  const cmds = rest.length ? rest : fs.readFileSync(0, "utf8").split("\n").filter(Boolean);
  for (const c of cmds) { const r = list.find((x) => matches(tool, x, c)); if (r) process.stdout.write(c + "\t" + r + "\n"); }
} else { process.stderr.write("usage: node test/rule-match.js rules|match <tool> <file> [<command>...]\n"); process.exit(2); }
