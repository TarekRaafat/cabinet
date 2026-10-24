// Fails when the docs fall behind the code. Run by test/smoke.sh: node test/docs-check.js <kit>
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const kit = process.argv[2];
const read = (p) => fs.readFileSync(path.join(kit, p), "utf8");
const exists = (p) => fs.existsSync(path.join(kit, p));
const ls = (d) => fs.readdirSync(path.join(kit, d)).sort();
const all = (re, s) => [...s.matchAll(re)];
const problems = [];
const fail = (p) => problems.push(p);

// The command table in bin/cabinet is the one list of commands and options. Check the
// option parsers and the dispatcher against it, then the conventions (AGENTS.md, "Command
// conventions"), then the docs against it.
const cabinet = read("bin/cabinet"), commands = read("docs/commands.md"), agents = read("AGENTS.md");
const table = cabinet.slice(cabinet.indexOf("<<'TABLE'\n") + 10, cabinet.indexOf("\nTABLE\n"));
const rows = table.split("\n").map((r) => r.split("\t"));
const cmds = rows.filter((r) => r[0] === "C").map((r) => r[2]);
const opts = {};
for (const r of rows) {
  if (r[0] !== "O") continue;
  for (const c of r[1].split(",")) {
    (opts[c] = opts[c] || new Set()).add(r[2]);
    if (!cmds.includes(c)) fail(`bin/cabinet table: option ${r[2]} names the unknown command ${c}`);
  }
}
const optsOf = (c) => opts[c] || new Set();
const nouns = [...new Set(cmds.filter((c) => c.includes(" ")).map((c) => c.split(" ")[0]))].sort();
const words = cmds.filter((c) => !c.includes(" "));
const dispatch = cabinet.slice(cabinet.lastIndexOf('case "${1:-}" in'));
const dispatched = new Set(all(/^  ([a-z]+)[|)]/gm, dispatch).map((m) => m[1]));
const known = new Set([...words, ...nouns]);
for (const c of [...new Set([...dispatched, ...known])].filter((c) => dispatched.has(c) !== known.has(c)).sort())
  fail(`bin/cabinet: the command ${c} is ` + (dispatched.has(c) ? "dispatched but not in the table" : "in the table but not dispatched"));

// Every option a parser accepts is in the table, for one of its commands. A script serves a
// noun (bin/<noun>.sh <verb>) or a one-word command (bin/<command>.sh).
const fnOf = (fn) => { const s = cabinet.indexOf(fn + "() {"); return cabinet.slice(s, cabinet.indexOf("\n}\n", s)); };
const sources = { setup: [fnOf("setup"), ["new", "init", "config"]], cmd_config: [fnOf("cmd_config"), ["config"]] };
for (const [fn, c] of [["cmd_next", "next"], ["cmd_remove", "remove"], ["cmd_status", "status"], ["cmd_help", "help"], ["cmd_list", "list"],
  ["cmd_digest", "digest"], ["cmd_outdated", "outdated"], ["cmd_version", "version"], ["cmd_changelog", "changelog"]])
  sources[fn] = [fnOf(fn), [c]];
sources.cmd_role = [fnOf("cmd_role"), cmds.filter((c) => c.startsWith("role "))];
sources.cmd_repo = [fnOf("cmd_repo"), cmds.filter((c) => c.startsWith("repo "))];
for (const f of ls("scripts")) {
  const name = f.slice(0, -3);
  if (!f.endsWith(".sh") || ["lib", "when", "platform"].includes(name)) continue;
  if (nouns.includes(name)) sources[f] = [read("scripts/" + f), cmds.filter((c) => c.startsWith(name + " "))];
  else if (words.includes(name)) sources[f] = [read("scripts/" + f), [name]];
  else fail(`scripts/${f} is neither a noun's script nor a one-word command's (AGENTS.md, "Command conventions" 7)`);
}
for (const n of nouns)
  if (!exists(`scripts/${n}.sh`) && !["role", "repo"].includes(n)) fail(`the noun ${n} has no script scripts/${n}.sh (AGENTS.md, "Command conventions" 7)`);
for (const [fn, [src, owners]] of Object.entries(sources)) {
  // Options as a parser reads them: case labels ("--x)", "-y|--yes)", "--a|--b)") and [[ $a == --x ]] tests.
  const found = new Set(all(/\[\[ "\$\{?\w+(?::-)?\}?" == (--[a-z][a-z-]*) \]\]/g, src).map((m) => m[1]));
  for (const m of all(/(?:^|\bin |;; |\( )\s*((?:-[a-zA-Z]\|)?--[a-z][a-z-]*(?:\|--?[a-z][a-z-]*)*)\)/gm, src))
    for (const o of m[1].split("|")) if (o.startsWith("--")) found.add(o);
  found.delete("--help");  // --help is every command's
  for (const o of found)
    if (!owners.some((c) => optsOf(c).has(o))) fail(`bin/cabinet table: ${fn} accepts ${o}, which the table does not list for ${owners.join(" or ")}`);
}

// The conventions a script can check.
const verbs = all(/^   \| `([a-z]+)` \|/gm, agents.slice(agents.indexOf("3. **Verbs come from one list"))).map((m) => m[1]);
for (const c of cmds)
  if (c.includes(" ") && !verbs.includes(c.split(" ")[1])) fail(`bin/cabinet table: '${c}' uses a verb that is not in AGENTS.md, "Command conventions" 3`);
for (const n of nouns) if (n.endsWith("s")) fail(`bin/cabinet table: the noun '${n}' is plural (AGENTS.md, "Command conventions" 2)`);
for (const c of cmds)
  if (cmds.includes(c + "s") || cmds.includes(c + "es")) fail(`bin/cabinet table: '${c}' and its plural are both commands (AGENTS.md, "Command conventions" 2)`);
const reports = ["next", "digest", "list", "doctor", "status", "outdated", "changelog", "version", "help",
  ...cmds.filter((c) => ["list", "check", "verify"].includes(c.split(" ").pop()))];
for (const c of reports)
  if (!optsOf(c).has("--json")) fail(`bin/cabinet table: '${c}' reports but has no --json (AGENTS.md, "Command conventions" 5)`);
const exceptions = agents.match(/Known exceptions, each on the roadmap: (.*)/)[1];
for (const c of ["new", "init", "config", "bootstrap", "move", "remove", "update",
  ...cmds.filter((c) => ["role", "repo"].includes(c.split(" ")[0]) && ["add", "remove"].includes(c.split(" ")[1]))])
  if (!optsOf(c).has("--dry-run") && !exceptions.includes(`\`${c}\` has no \`--dry-run\``))
    fail(`bin/cabinet table: '${c}' changes the setup but has no --dry-run (AGENTS.md, "Command conventions" 5)`);
for (const [c, os] of Object.entries(opts))
  for (const o of os) if (!/^--[a-z]+(-[a-z]+)*$/.test(o)) fail(`bin/cabinet table: option ${o} of ${c} is not lowercase words joined by dashes`);
// Usage errors exit 2: no "unknown option" is reported through die (exit 1).
if (/\bdie "unknown (option|command)/.test(cabinet)) fail("bin/cabinet: an unknown option or command exits through die (1), not bad_usage (2)");

// Every command and option in the table is in docs/commands.md.
for (const c of cmds) if (!commands.includes(`cabinet ${c}`)) fail(`docs/commands.md does not mention the command cabinet ${c}`);
for (const o of [...new Set(Object.values(opts).flatMap((s) => [...s]))].sort())
  if (!commands.includes("`" + o) && !commands.includes(" " + o)) fail(`docs/commands.md does not mention the option ${o}`);
if (!commands.includes("cabinet -C <dir>")) fail("docs/commands.md does not explain -C <dir>");

// The agent setup guide uses only options that exist (on lines about cabinet, not git or node).
const allOpts = new Set(Object.values(opts).flatMap((s) => [...s]));
const guide = read("docs/agent-setup.md").split("\n").filter((l) => l.includes("cabinet ") || l.startsWith("|")).join("\n");
for (const o of new Set(all(/(?<![\w-])--[a-z][a-z-]*/g, guide).map((m) => m[0])))
  if (!allOpts.has(o)) fail(`docs/agent-setup.md uses the option ${o}, which no command has`);

// The "Agent team" section the guide offers is the one init writes.
const pointer = (cabinet.match(/local pointer="([^"]*)"/) || ["", ""])[1].replace(/\\`/g, "`");
if (!pointer || !read("docs/agent-setup.md").includes(pointer)) fail("docs/agent-setup.md does not hold the Agent team section init writes (bin/cabinet, pointer=)");

// Every step cabinet next can give (step <id> in bin/cabinet) is in its list of step IDs.
const stepIds = (commands.match(/Step IDs: ([^;]*);/) || ["", ""])[1];
for (const id of new Set(all(/\bstep ([a-z-]+) "/g, cabinet).map((m) => m[1])))
  if (!stepIds.includes("`" + id + "`")) fail(`docs/commands.md does not list the cabinet next step ID ${id}`);

// Every workspace script is in docs/commands.md.
for (const f of ls("scripts"))
  if (f.endsWith(".sh") && !["lib.sh", "when.sh", "platform.sh"].includes(f) && !commands.includes(`bin/${f}`)) fail(`docs/commands.md does not mention bin/${f}`);

// Every doctor message, as its fixed pieces, is in docs/troubleshooting.md.
const trouble = read("docs/troubleshooting.md");
const expansion = /\$\((?:[^()]|\([^()]*\))*\)|\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\\\$/;
for (const [, , cid, msg] of all(/\b(bad|note) ([a-z.-]+) "((?:[^"\\]|\\.)*)"/g, read("scripts/doctor.sh"))) {
  if (!trouble.includes(`\`${cid}\``)) fail(`docs/troubleshooting.md does not list the doctor check ID ${cid}`);
  for (let piece of msg.split(expansion)) {
    piece = piece.replace(/\\/g, "").replace(/^[ :,.'(/]+|[ :,.'(/]+$/g, "");
    if (piece.length >= 4 && !trouble.includes(piece)) fail(`docs/troubleshooting.md lacks the doctor message piece: '${piece}'`);
  }
}

// Every docs page is in llms.txt; every relative link resolves; the package ships the docs.
const llms = read("llms.txt");
const docs = ls("docs").filter((f) => f.endsWith(".md"));
for (const f of docs) if (!llms.includes(`docs/${f}`)) fail(`llms.txt does not list docs/${f}`);
// Its line for the commands page names every command and noun, in its list of commands.
const llmsCmds = ((llms.split("\n").find((l) => l.includes("(docs/commands.md)")) || "").match(/every `cabinet` command \(([^)]*)\)/) || ["", ""])[1];
for (const c of known) if (!new RegExp(`\\b${c}\\b`).test(llmsCmds)) fail(`llms.txt: the line for docs/commands.md does not name the command ${c}`);
const pages = ["README.md", "llms.txt", "AGENTS.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md", "core/CABINET.md", ...docs.map((f) => "docs/" + f)];
// GitHub's heading anchors: lowercase, punctuation dropped, spaces to dashes.
const anchors = (file) => {
  const text = fs.readFileSync(file, "utf8").replace(/```[\s\S]*?```/g, "");
  return new Set(all(/^#+ (.+)$/gm, text).map((m) => m[1].trim().toLowerCase().replace(/[^\p{L}\p{N}_\- ]/gu, "").replace(/ /g, "-")));
};
for (const page of pages) {
  for (const [, link, anchor] of all(/\]\(([^)#\s]*)(?:#([^)\s]*))?\)/g, read(page))) {
    if (/^[a-z]+:\/\//.test(link)) continue;
    const target = link ? path.normalize(path.join(kit, path.dirname(page), link)) : path.join(kit, page);
    if (!fs.existsSync(target)) fail(`${page} links to a missing file: ${link}`);
    else if (anchor && target.endsWith(".md") && !anchors(target).has(anchor)) fail(`${page} links to a missing heading: ${link}#${anchor}`);
  }
}
const files = JSON.parse(read("package.json")).files;
for (const need of ["docs", "llms.txt", "llms-full.txt", "ROADMAP.md", "AGENTS.md", "CHANGELOG.md"])
  if (!files.includes(need)) fail(`package.json files does not ship ${need}`);

for (const p of problems) console.log("FAIL: " + p);
process.exit(problems.length ? 1 : 0);
