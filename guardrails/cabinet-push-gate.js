// cabinet push gate helper v1
// Run by the push gate (pre-push, beside this file): node cabinet-push-gate.js <top folder> <common git folder>.
// Prints "cabinet" when the repo is one of Cabinet's on this machine, "outside" when the check completes and
// finds it in no workspace; any failure throws, exits 1, and the gate asks. Reads only HOME and
// XDG_STATE_HOME, the log folder and its claims, each claimed workspace's repos.tsv, and the folders it resolves.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const [top, common] = process.argv.slice(2);
const home = process.env.HOME;
if (!top || !home || !path.isAbsolute(home)) throw new Error("no repo folder or HOME");
// The log folder, as scripts/platform.sh defines it.
const state = process.env.XDG_STATE_HOME;
const logs = process.platform === "darwin" ? path.join(home, "Library/Logs/cabinet") : path.join(state || path.join(home, ".local/state"), "cabinet");
// Real paths, as the file system stores them: symlinks resolved, each name in its letter case on disk.
const real = (p) => fs.realpathSync.native(p);
const mine = [real(top)];
if (common && path.basename(common) === ".git") mine.push(real(path.dirname(common)));
const is = (dir) => mine.some((m) => m === dir);
const within = (dir) => mine.some((m) => m === dir || m.startsWith(dir + "/"));

let claims = 0;
for (const slug of fs.readdirSync(logs)) {
  const d = path.join(logs, slug);
  if (!fs.statSync(d).isDirectory()) continue;
  let ws;
  try { ws = fs.readFileSync(path.join(d, "workspace"), "utf8"); } catch (e) { if (e.code === "ENOENT") continue; throw e; }
  claims++;
  ws = ws.split("\n")[0];
  if (!path.isAbsolute(ws)) throw new Error("a claim that is not a folder");
  const wr = real(ws);
  if (within(wr)) out("cabinet");
  // The project around a workspace inside it: init --inside always names that folder cabinet.
  if (path.basename(wr) === "cabinet" && is(path.dirname(wr))) out("cabinet");
  // Rows as repos in lib.sh reads them, folders as repo_dir gives them.
  for (const line of fs.readFileSync(path.join(wr, "repos.tsv"), "utf8").split("\n")) {
    const f = line.replace(/\r$/, "").split("\t");
    if (line.startsWith("#") || f.length < 2 || !/^[A-Za-z0-9._-]+$/.test(f[0]) || f[0] === "." || f[0] === "..") continue;
    const p = f[4] || f[0];
    const dir = p.startsWith("/") ? p : p.startsWith("~/") ? home + "/" + p.slice(2) : wr + "/" + p;
    let r;
    try { r = real(dir); } catch (e) { if (e.code === "ENOENT") continue; throw e; }
    if (is(r)) out("cabinet");
  }
}
if (!claims) throw new Error("no workspace claimed on this machine");
out("outside");

function out(word) { process.stdout.write(word + "\n"); process.exit(0); }
