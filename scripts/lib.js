// The workspace scripts' shared JavaScript, run with node (AGENTS.md, rule 3): what bash does badly,
// such as parsing Markdown and building a page. Only Node's own modules, so Bun can compile it later.
//
//   node lib.js <command> <args>...    (the scripts call it through js() in lib.sh)
//
// Commands: delete-plan, verdict-origin, hard-write, handoff-entry, handoff-archive, handoff-rows, owner-case, readiness, push-check, model-check, version-newer, release-latest, version-check, latest-write, spec-check, spec-record, manual, json, changelog-render, and the line edits and helpers below.
"use strict";
// Node 18 or newer (package.json, engines): an older Node cannot run the scripts' expressions, so
// say so plainly instead of failing on a syntax error. CABINET_TEST_NODE_VERSION stands in for the
// version in the tests.
const NODE_MIN = 18;
const nodeVersion = process.env.CABINET_TEST_NODE_VERSION || process.versions.node;
if (parseInt(nodeVersion, 10) < NODE_MIN) {
  process.stderr.write("cabinet needs Node.js " + NODE_MIN + " or newer; this is " + nodeVersion + " (" +
    (process.platform === "darwin" ? "brew upgrade node" : "install a current Node.js from https://nodejs.org, since the system's package can be older") + ")\n");
  process.exit(1);
}
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");
// A reader that stops early (head -1, grep -q) closes the pipe: that is not a failure, so exit 0 quietly.
process.stdout.on("error", (e) => { if (e.code === "EPIPE") process.exit(0); throw e; });

// Read text as the scripts always have: UTF-8, with \r\n and \r read as \n.
const read = (p) => fs.readFileSync(p, "utf8").replace(/\r\n?/g, "\n");
const write = (p, s) => fs.writeFileSync(p, s, "utf8");
const die = (msg, code = 1) => { if (msg) process.stderr.write(msg + "\n"); process.exit(code); };
const env = (k) => process.env[k] || "";
const words = (s) => s.split(/\s+/).filter(Boolean);

// hard-write <AGENTS.md> [<path>|off]...: set the list under "Hard to undo", keeping the section's other
// lines; a missing section is added before "House rules". Written only when the result is whole.
function hardWrite(file, ...given) {
  const items = given.filter((i) => i !== "off");
  const text = read(file);
  const lines = text.split("\n");
  const add = items.length ? items.map((i) => "- `" + i + "`") : ["- none"];
  const at = lines.indexOf("## Hard to undo");
  if (at >= 0) {
    const s = at + 1;
    let e = lines.findIndex((l, j) => j >= s && l.startsWith("## "));
    if (e < 0) e = lines.length;
    const keep = lines.slice(s, e).filter((l) => !l.startsWith("- "));
    while (keep.length && !keep[keep.length - 1].trim()) keep.pop();
    lines.splice(s, e - s, ...keep, "", ...add, ...(e < lines.length ? [""] : []));
  } else {
    const intro = "Paths where a change is hard to undo (migrations, public files, anything released): a small task never " +
      "touches them (`CABINET.md`, \"Ready to build\"), and `bin/handoff.sh record` refuses a PASS on one that does. " +
      "Set with `cabinet config --hard-to-undo`, or one per line as `` `<repo>/<path>` ``; a path ending in `/` covers its folder.";
    let h = lines.indexOf("## House rules");
    if (h < 0) h = lines.length;
    lines.splice(h, 0, "## Hard to undo", "", intro, "", ...add, "");
  }
  const out = lines.join("\n").replace(/\n+$/, "") + "\n";
  if (!out.includes("## Hard to undo") || out.length < Math.floor(text.length / 2)) {
    die("AGENTS.md: the new Hard to undo section did not come out whole; nothing written");
  }
  write(file + ".new", out);
  fs.renameSync(file + ".new", file);
}

// The handoff reader (one place for what an entry is): where an entry starts and ends, its status word,
// whether an addressee is the owner, and the order of two IDs. Every command that reads HANDOFFS.md uses
// these, from here, through handoff-rows or through json's helpers.
// handoffEntries(lines, whole): [{id, title, section, start, end, lines}]: an entry starts at a "### H-"
// line under "## Open" or a legacy "## Archive" (anywhere when whole: an archive file) and ends before the
// next line starting "### " or "## ", or at the end. start is its heading's index, end the index after
// it, lines its body; section is "open" or "archive". A "## " section after "## Open" is no entry's.
function handoffEntries(lines, whole) {
  const out = [];
  let on = !!whole, section = "archive", cur = null;
  lines.forEach((l, i) => {
    const h2 = l.startsWith("## ");
    if (!h2 && !l.startsWith("### ")) { if (cur) cur.lines.push(l); return; }
    if (cur) { cur.end = i; cur = null; }
    if (h2) { section = l.startsWith("## Open") ? "open" : "archive"; on = !!whole || section === "open" || l.startsWith("## Archive"); return; }
    if (on && l.startsWith("### H-")) {
      cur = { id: words(l)[1].replace(/:+$/, ""), title: l.replace(/^### [^:]+: /, ""), section, start: i, end: lines.length, lines: [] };
      out.push(cur);
    }
  });
  return out;
}
// statusOf(body): the first "- Status:" line's text after "- Status: " (rest), its word (up to the first
// space or "(", or the end), whether the word is known (exactly open, acknowledged, done or rejected), and
// the line as written, or "no status line" (said).
const STATUS_WORDS = ["open", "acknowledged", "done", "rejected"];
function statusOf(body) {
  const l = body.find((x) => x.startsWith("- Status:"));
  const rest = l === undefined ? "" : l.replace(/^- Status: ?/, "");
  const word = rest.match(/^[^ (]*/)[0];
  return { rest, word, known: STATUS_WORDS.includes(word), said: l === undefined ? "no status line" : l };
}
const statusKnown = (w) => STATUS_WORDS.includes(w);
const statusClosed = (w) => w === "done" || w === "rejected";
// The owner: "owner" or "founder" as a whole word of the addressee, in any case ("Owner and qa" too,
// never "owners" or "co-owner"). ownerCase writes those words in lower case, and nothing else.
const OWNER_RE = /(^|[^a-z-])(owner|founder)(?![a-z-])/gi;
const ownerIn = (to) => new RegExp(OWNER_RE.source, "i").test(to || "");
const ownerCase = (to) => to.replace(OWNER_RE, (m, a, b) => a + b.toLowerCase());
// idOrder(a, b): IDs by their date (the eight digits), then their number as a number: H-20261107-100
// after H-20261107-99. Anything else by its text.
function idOrder(a, b) {
  const p = (x) => /^H-(\d{8})-(\d+)/.exec(x), x = p(a), y = p(b);
  const text = a < b ? -1 : a > b ? 1 : 0;
  if (!x || !y) return text;
  return x[1] < y[1] ? -1 : x[1] > y[1] ? 1 : Number(x[2]) - Number(y[2]) || text;
}
// handoff-rows <HANDOFFS.md>: every entry as JSON, in file order: id, title, section, status_line (the
// text after "- Status: "), status (its word), known, status_said, from, to, owner, text (in full).
function handoffRows(file) {
  // CRLF line ends end lines; a lone \r stays in its line, so a terminal shows it as ? (term_text).
  const lines = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n").split("\n");
  const rows = handoffEntries(lines).map((e) => {
    const s = statusOf(e.lines);
    const fl = e.lines.find((l) => l.startsWith("- From:")) || "";
    const m = fl.match(/^- From: ?(.*?) -> To: (.*)$/);
    const from = m ? m[1] : fl.replace(/^- From: ?/, ""), to = m ? m[2] : "";
    const text = lines.slice(e.start, e.end).join("\n").replace(/\n+$/, "") + "\n";
    return { id: e.id, title: e.title, section: e.section, status_line: s.rest, status: s.word, known: s.known, status_said: s.said,
      from, to, owner: ownerIn(to), text };
  });
  process.stdout.write(JSON.stringify(rows) + "\n");
}

// handoff-entry <HANDOFFS.md> <ID> info|evidence <links>|verdict <role> <line>|wayback <text>: read or
// change one open entry in place. info prints "<sender>\t<1 when it has evidence>\t<small>\t<1 when it
// has a way back>\t<addressee>".
// Exit 3 when the entry is not under "## Open".
function handoffEntry(file, hid, mode, ...args) {
  const lines = read(file).split("\n");
  const e = handoffEntries(lines).find((x) => x.section === "open" && x.id === hid && lines[x.start].startsWith("### " + hid + ":"));
  if (!e) die("", 3);
  const start = e.start, end = e.end;
  let last = end - 1;
  while (last > start && !lines[last].trim()) last--;
  let body = lines.slice(start + 1, last + 1);
  const hasEv = (l) => l.startsWith("- Evidence:") && /\]\(|<https?:/.test(l);
  if (mode === "info") {
    const first = (re) => { for (const l of body) { const m = l.match(re); if (m) return m[1].trim(); } return ""; };
    const sender = first(/^- From: (.*?) ->/);
    const small = body.some((l) => /^- Size: small\s*$/.test(l)) ? "small" : "";
    const to = first(/^- From: .*? -> To: (.*)/);
    const back = body.some((l) => /^- Way back: \S/.test(l)) ? "1" : "";
    process.stdout.write(sender + "\t" + (body.some(hasEv) ? "1" : "") + "\t" + small + "\t" + back + "\t" + to + "\n");
    return;
  }
  if (mode === "wayback") {
    // One line, before the first verdict: a new one replaces the old.
    body = body.filter((l) => !l.startsWith("- Way back:"));
    let v = body.findIndex((l) => l.startsWith("- Verdict:"));
    if (v < 0) v = body.length;
    body.splice(v, 0, "- Way back: " + args[0]);
  }
  if (mode === "evidence") {
    const links = args[0];
    const at = body.findIndex((l) => l.startsWith("- Evidence:"));
    if (at < 0) {
      let v = body.findIndex((l) => l.startsWith("- Verdict:"));
      if (v < 0) v = body.length;
      body.splice(v, 0, "- Evidence: " + links);
    } else if (hasEv(body[at])) {
      body[at] = body[at].replace(/\s+$/, "") + ", " + links;
    } else {
      body[at] = "- Evidence: " + links;
    }
  } else if (mode === "verdict") {
    const [role, line] = args;
    body = body.filter((l) => !l.startsWith("- Verdict: " + role + " ")).concat([line]);
  }
  lines.splice(start + 1, last - start, ...body);
  write(file, lines.join("\n"));
}

// handoff-archive <workspace>: move done and rejected entries to handoffs/archive-<YYYY-MM>.md by their
// ID's month (only a known done or rejected: handoffEntries, statusOf); prints how many moved, then each
// archive file it wrote, from the workspace. HANDOFFS.md is left untouched when none did. A "## " section
// after "## Open" (other than a legacy "## Archive", whose heading is dropped and its entries sorted like
// the rest) stays where it is, byte for byte.
function handoffArchive(ws) {
  const file = path.join(ws, "HANDOFFS.md");
  const lines = read(file).split("\n");
  const open = lines.indexOf("## Open");
  if (open < 0) die("no '## Open' heading in HANDOFFS.md");
  let tail = lines.findIndex((l, i) => i > open && l.startsWith("## ") && !l.startsWith("## Archive"));
  if (tail < 0) tail = lines.length;
  const es = handoffEntries(lines.slice(0, tail)).filter((e) => e.start > open);
  const text = (a, b) => lines.slice(a, b).filter((l) => !l.startsWith("## Archive")).join("\n").replace(/^\n+|\n+$/g, "");
  const keep = [], moved = {};
  es.forEach((e, k) => {
    const t = text(e.start, e.end), m = e.id.match(/^H-(\d{4})(\d{2})/), st = statusOf(e.lines).word;
    if (m && statusClosed(st)) (moved[m[1] + "-" + m[2]] = moved[m[1] + "-" + m[2]] || []).push(t);
    else keep.push(t);
    const gap = text(e.end, k + 1 < es.length ? es[k + 1].start : tail);  // a "### " block that is no entry stays
    if (gap) keep.push(gap);
  });
  const written = [];
  for (const month of Object.keys(moved).sort()) {
    fs.mkdirSync(path.join(ws, "handoffs"), { recursive: true });
    const rel = "handoffs/archive-" + month + ".md", p = path.join(ws, rel);
    let add = fs.existsSync(p) ? "" : "# Closed handoffs, IDs from " + month + "\n\nMoved from HANDOFFS.md by bin/handoff.sh archive. Read only.\n";
    for (const e of moved[month]) add += "\n" + e.split("](specs/").join("](../specs/") + "\n";  // links now read from handoffs/
    fs.appendFileSync(p, add, "utf8");
    written.push(rel);
  }
  const n = Object.values(moved).reduce((a, x) => a + x.length, 0);
  if (n) {  // untouched otherwise
    const preamble = lines.slice(open + 1, es[0].start).filter((l) => !l.startsWith("## Archive")).join("\n").replace(/\n+$/, "");
    const body = keep.length ? preamble + "\n\n" + keep.join("\n\n") + "\n" : preamble ? preamble + "\n" : "";
    write(file, lines.slice(0, open + 1).join("\n") + "\n" + body + (tail < lines.length ? "\n" + lines.slice(tail).join("\n") : ""));
  }
  process.stdout.write([n, ...written].join("\n") + "\n");
}

// readiness <spend file> <HANDOFFS.md> [<archive>...]: {"<ID>": {verdicts, needs, missing, blocking,
// stale, ready, ...}} for every entry, from the environment lib.sh's readiness() sets (WSDIR, REPODIRS, TEAM,
// BUILDS, UI, DELEGATES, AREAS, TOUCH, SAREAS). See readiness() in lib.sh for the rules.
function readiness(spend, ...files) {
  const inWs = {};
  const workspaceCommit = (c) => {  // the workspace's own files (a guide, a spec) are not code
    if (!(c in inWs)) inWs[c] = spawnSync("git", ["-C", env("WSDIR"), "cat-file", "-e", c + "^{commit}"], { stdio: "ignore" }).status === 0;
    return inWs[c];
  };
  const d = new Date(), pad = (n) => String(n).padStart(2, "0");
  const today = d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
  const rows = (k) => env(k).split("\n").filter((l) => l.includes("\t")).map((l) => l.split("\t"));
  // A role that reports to a lead and covers some work reviews it for the lead (its verdict counts),
  // with the lead's PASS needed too until its trial ends.
  const dl = env("DELEGATES").split("\n").filter((l) => l.split("\t").length === 4).map((l) => l.split("\t"));
  const areaReviewers = {};
  for (const r of rows("AREAS")) areaReviewers[r[0]] = words(r[2] || "");
  const touch = rows("TOUCH");
  const specAreas = {};
  for (const [s, a] of rows("SAREAS")) (specAreas[s] = specAreas[s] || new Set()).add(a);
  const cost = {};
  try {
    for (const row of read(spend).split("\n")) {
      const f = row.split("\t");
      if (f.length >= 4 && f[3]) {
        const v = Number(f[3]);
        if (f[3].trim() === "" || Number.isNaN(v)) break;  // a row that is no number ends the count
        cost[f[1]] = (cost[f[1]] || 0) + v;
      }
    }
  } catch (e) { /* no spend file yet */ }
  const team = new Set(words(env("TEAM"))), builds = new Set(words(env("BUILDS"))), ui = new Set(words(env("UI")));
  const VER = /^- Verdict: ([a-z0-9-]+) (PASS|BLOCK|CHANGES) (\d{4}-\d{2}-\d{2}) ([0-9a-f]+(?:,[0-9a-f]+)*|none) (\S+)$/;
  const names = (s) => s.replace(/\([^)]*\)/g, "").split(" and ").join(",").split("&").join(",").split("`").join("")
    .split(",").map((n) => n.trim()).filter(Boolean).map((n) => n.toLowerCase());
  const covers = (have, want) => want.every((w) => have.some((h) => w.startsWith(h) || h.startsWith(w)));  // short and long hashes match
  const entries = [];
  files.forEach((file, n) => {  // HANDOFFS.md, then the archives (closed work a run may still need)
    for (const e of handoffEntries(read(file).split("\n"), n > 0)) entries.push({ id: e.id, lines: e.lines, archived: n > 0 });
  });
  const field = (e, k) => { const l = e.lines.find((x) => x.startsWith(k)); return l ? l.slice(k.length).trim() : ""; };
  // Every BLOCK or CHANGES a reviewer ever recorded on an entry, though a later Verdict line replaced it:
  // the lines HANDOFFS.md's git history added, each under the entry it sits in (git names the entry
  // above each change, as a diff names a function), with the file as it is now.
  const blockLines = {};
  const addBlock = (id, l) => { const v = id && l.trim().match(VER); if (v && v[2] !== "PASS") (blockLines[id] = blockLines[id] || new Set()).add(l.trim()); };
  let attrs = "";
  try {
    attrs = path.join(fs.mkdtempSync(path.join(require("node:os").tmpdir(), "cabinet-")), "attributes");
    fs.writeFileSync(attrs, "HANDOFFS.md diff=cabinet-handoffs\n");
    const log = spawnSync("git", ["-C", env("WSDIR"), "-c", "core.attributesFile=" + attrs, "-c", "diff.cabinet-handoffs.xfuncname=^### H-[0-9]+-[0-9]+:.*$",
      "log", "-p", "-U0", "--no-color", "--no-ext-diff", "--no-renames", "--format=", "--", "HANDOFFS.md"], { encoding: "utf8", maxBuffer: 1 << 30 });
    let at = "";
    for (const l of (log.status === 0 ? log.stdout : "").split("\n")) {
      if (/^@{2} /.test(l)) at = (l.match(/^@{2} [^@]* @{2} ### (H-\d{8}-\d+):/) || [])[1] || "";   // a hunk header (@{2}: setup's placeholders are two @)
      else if (l.startsWith("+### H-")) at = words(l)[1].replace(/:+$/, "");
      else if (l.startsWith("+- Verdict: ")) addBlock(at, l.slice(1));
    }
  } catch (e) { /* no git history: the file alone */ }
  finally { if (attrs) fs.rmSync(path.dirname(attrs), { recursive: true, force: true }); }
  const specOf = {};
  for (const e of entries) specOf[e.id] = field(e, "- Spec:");
  const repoDirs = env("REPODIRS").split("\n").filter(Boolean);
  const git = (d, ...a) => spawnSync("git", ["-C", d, ...a], { encoding: "utf8" });
  const onlyOnSession = (commits) => {  // the session branch of the first commit found only there, or null
    for (const c of commits) for (const d of repoDirs) {
      if (git(d, "cat-file", "-e", c + "^{commit}").status !== 0) continue;
      if (git(d, "merge-base", "--is-ancestor", c, "HEAD").status === 0) break;
      const b = git(d, "for-each-ref", "--contains", c, "--format=%(refname:short)", "refs/heads/session/").stdout.split("\n").filter(Boolean)[0];
      if (b) return b;
      break;
    }
    return null;
  };
  const out = {};
  for (const e of entries) {
    let frm = "", to = "";
    const vs = [], unread = [];
    for (const l of e.lines) {
      const m = l.match(/^- From: (.*?) -> To: (.*)/);
      if (m && !frm) { frm = m[1].trim().toLowerCase(); to = m[2]; }
      const v = l.trim().match(VER);
      if (v) vs.push({ role: v[1], verdict: v[2], date: v[3], commits: v[4] === "none" ? [] : v[4].split(","), note: v[5] });
      else if (/\b(PASS|BLOCK|CHANGES)\b/.test(l)) unread.push(l.trim());
    }
    let needs = [];
    for (const n of names(to)) if (team.has(n) && !builds.has(n) && n !== "chief-of-staff" && !needs.includes(n)) needs.push(n);
    if (builds.has(frm) || vs.some((v) => v.commits.some((c) => !workspaceCommit(c)))) {
      for (const r of ["qa", "security", "code-reviewer"].concat(ui.has(frm) ? ["design-lead"] : [])) if (team.has(r) && !needs.includes(r)) needs.push(r);
    }
    const work = [];
    for (const v of vs) for (const c of v.commits) if (!covers(work, [c])) work.push(c);
    // The critical areas it touches: by its commits, by its spec, or by the spec of the work it reviews.
    const depLine = e.lines.find((l) => l.startsWith("- Depends on:")) || "";
    const depIds = depLine.match(/H-\d{8}-\d+/g) || [];
    let areas = new Set(touch.filter(([c]) => covers(work, [c])).map((t) => t[1]));
    for (const sp of [specOf[e.id] || ""].concat(depIds.map((x) => specOf[x] || ""))) for (const a of specAreas[sp] || []) areas.add(a);
    areas = [...areas].filter((a) => a in areaReviewers).sort();
    for (const a of areas) for (const r of areaReviewers[a]) if (!needs.includes(r)) needs.push(r);  // even off the team: the doctor says why
    const last = {};
    for (const v of vs) last[v.role] = v;
    const blocking = Object.keys(last).filter((r) => last[r].verdict !== "PASS");
    // Who does each review: the role that covers this sender's work for the lead, else the lead; the
    // lead's own PASS always counts.
    const who = [];
    for (const r of needs) {
      const dd = dl.find((x) => x[1] === r && x[2].split(",").includes(frm));
      if (dd) { who.push([dd[0], [dd[0], r]]); if (dd[3] && dd[3] >= today) who.push([r, [r]]); }
      else who.push([r, [r]]);
    }
    needs = [];
    const stale = [], missing = [];
    for (const [w, ok] of who) {
      needs.push(w);
      const passed = ok.filter((o) => o in last && last[o].verdict === "PASS").map((o) => last[o]);
      if (passed.some((p) => covers(p.commits, work)) || ok.some((o) => blocking.includes(o))) continue;  // passed, or blocking
      (passed.length ? stale : missing).push(w);
    }
    for (const l of e.lines) addBlock(e.id, l);
    const blocks = {};
    for (const l of blockLines[e.id] || []) { const r = l.match(VER)[1]; blocks[r] = (blocks[r] || 0) + 1; }
    // Passed work is ready only on the branch the owner pushes: a commit its repo's main folder does not
    // have, on a session branch (cabinet session), holds it until the session is merged.
    let ready = needs.length ? !missing.length && !blocking.length && !stale.length : null, sessionBranch = null;
    if (ready) sessionBranch = onlyOnSession(work);
    if (sessionBranch) ready = false;
    // The one addressee that builds (a repo, or a role that builds one), else null: work for one builder,
    // as spec run and handoff run count it (ADR-006).
    const bs = [...new Set(names(to).filter((n) => builds.has(n)))];
    out[e.id] = {
      builder: bs.length === 1 ? bs[0] : null, session_branch: sessionBranch, areas, archived: e.archived, depends_on: field(e, "- Depends on:"), status_now: statusOf(e.lines).word,
      small: e.lines.some((l) => l.trim() === "- Size: small"), spec: field(e, "- Spec:"),
      cost_usd: e.id in cost ? Math.round(cost[e.id] * 1e6) / 1e6 : null, verdicts: vs, blocks, needs, missing, blocking, stale,
      ready, unread_verdicts: unread,
    };
  }
  process.stdout.write(JSON.stringify(out) + "\n");
}

// Specs (bin/spec.sh): parsing, checks against their status, and review fingerprints.
const PART = { qa: "Acceptance criteria", architect: "Plan", "design-lead": "Design" };
function specTools(ws) {
  // Guidance copied from the template is not content: "Anything not decided is TBD ..." is no TBD.
  let placeholders = new Set();
  try {
    placeholders = new Set(read(path.join(ws, "specs", "_template.md")).split("\n")
      .filter((l) => l.trim() && !l.startsWith("#") && !l.startsWith("|") && !l.startsWith("---")).map((l) => l.trim()));
  } catch (e) { /* no template */ }
  const parse = (text) => {
    const fm = {};
    let body = text;
    const m = text.match(/^---\n([\s\S]*?)\n---\n/);
    if (m) {
      for (const l of m[1].split("\n")) {
        const i = l.indexOf(":");
        const k = i < 0 ? l : l.slice(0, i), v = i < 0 ? "" : l.slice(i + 1);
        fm[k.trim()] = v.replace(/\s+#.*$/, "").trim();
      }
      body = text.slice(m[0].length);
    }
    const secs = {};
    let cur = null;
    for (const l of body.split("\n")) {
      if (l.startsWith("## ")) { cur = l.slice(3).trim(); secs[cur] = []; }
      else if (cur !== null) secs[cur].push(l);
    }
    return [fm, secs];
  };
  const content = (lines) => lines.map((l) => l.trim()).filter((l) => l && !placeholders.has(l));
  const fingerprint = (lines) => crypto.createHash("sha256").update(content(lines).join("\n"), "utf8").digest("hex").slice(0, 8);
  const list = (s) => { const m = (s || "").match(/^\[(.*)\]$/); return m ? m[1].split(",").map((x) => x.trim()).filter(Boolean) : null; };
  const repos = (fm) => (list(fm.repos) || []).map((r) => r.replace(/^['"]+|['"]+$/g, ""));
  // Architect reviews the plan of a spec built in more than one repo or touching a critical area.
  const needsArchitect = (fm) => repos(fm).length > 1 || (list(fm.areas || "[]") || []).length > 0;
  const decisions = (lines) => {
    const rows = lines.filter((l) => l.trim().startsWith("|")).map((l) => l.trim().replace(/^\|+|\|+$/g, "").split("|").map((c) => c.trim()));
    return rows.slice(1).filter((r) => r.some(Boolean) && !r.every((c) => /^:?-+:?$/.test(c)));
  };
  const plan = (lines) => {
    const parts = {};
    let cur = null;
    for (const l of lines) {
      if (l.startsWith("### ")) { cur = l.slice(4).trim(); parts[cur] = []; }
      else if (cur !== null && l.trim()) parts[cur].push(l);
    }
    return parts;
  };
  const verdicts = (lines) => {
    const v = {};
    for (const l of lines) {
      const m = l.trim().match(/^- Verdict: (\S+) (PASS|BLOCK) \d{4}-\d{2}-\d{2} ([0-9a-f]{8}) \S+$/);
      if (m) v[m[1]] = [m[2], m[3]];
    }
    return v;
  };
  const sec = (secs, k) => secs[k] || [];
  // The repos, those with no plan yet, whether the plan needs the architect, and its review as it is now.
  const planState = (text) => {
    const [fm, secs] = parse(text);
    const rs = repos(fm), parts = plan(sec(secs, "Plan")), a = verdicts(sec(secs, "Reviews")).architect;
    const review = !a ? "none" : a[0] !== "PASS" ? a[0] : a[1] === fingerprint(sec(secs, "Plan")) ? "PASS" : "changed";
    return { repos: rs, missing_plans: rs.filter((r) => !(parts[r] && parts[r].length)), plan_review_needed: needsArchitect(fm), plan_review: review };
  };
  const problems = (text) => {
    const [fm, secs] = parse(text);
    const status = fm.status || "", p = [];
    if (status !== "ready" && status !== "building") return [status, p];
    if (!content(sec(secs, "Acceptance criteria")).length) p.push("no acceptance criteria");
    if (/\bTBD\b/.test(content(sec(secs, "Rules")).join("\n"))) p.push("TBD left in Rules");
    const left = decisions(sec(secs, "Decisions")).filter((r) => !r[r.length - 1]);
    if (left.length) p.push(left.length + " decision(s) not answered");
    const rs = repos(fm);
    if (!rs.length) p.push("no repos or areas named");
    const known = new Set(env("AREAS").split("\n").map((s) => s.trim()).filter(Boolean));  // one name per line: a name can have spaces
    for (const a of (list(fm.areas || "[]") || []).map((x) => x.toLowerCase())) {
      if (!known.has(a)) p.push("areas names " + a + ", which is no critical area in AGENTS.md");
    }
    const v = verdicts(sec(secs, "Reviews"));
    const review = (role) => {
      const part = PART[role];
      if (!(role in v)) return "no " + role + " review of the " + part.toLowerCase();
      if (v[role][0] !== "PASS") return role + " BLOCK on the " + part.toLowerCase();
      if (v[role][1] !== fingerprint(sec(secs, part))) return "the " + part.toLowerCase() + " changed since " + role + " passed it";
      return null;
    };
    p.push(review("qa"));
    const uiRepos = new Set(words(env("UI_REPOS")));
    if (rs.some((r) => uiRepos.has(r))) {
      if (!content(sec(secs, "Design")).length) p.push("no design for what people see");
      p.push(review("design-lead"));
    }
    if (status === "building") {
      const parts = plan(sec(secs, "Plan"));
      const missing = rs.filter((r) => !(parts[r] && parts[r].length));
      if (missing.length) p.push("no plan for " + missing.join(", "));
      if (needsArchitect(fm)) p.push(review("architect"));
    }
    return [status, p.filter(Boolean)];
  };
  return { parse, fingerprint, planState, problems };
}

// spec-check <workspace> <spec>...: [{spec, status, problems, repos, missing_plans, plan_review_needed, plan_review}].
function specCheck(ws, ...specs) {
  const t = specTools(ws);
  const out = specs.map((f) => {
    const text = read(path.join(ws, f));
    const [status, p] = t.problems(text);
    return Object.assign({ spec: f, status, problems: p }, t.planState(text));
  });
  process.stdout.write(JSON.stringify(out) + "\n");
}

// spec-record <workspace> <spec> <role> <verdict> <date> <note>: write, or replace, the role's verdict
// line under "## Reviews", with a fingerprint of the part it reviewed.
function specRecord(ws, f, role, verdict, date, note) {
  const t = specTools(ws), file = path.join(ws, f), text = read(file);
  const [, secs] = t.parse(text);
  const line = "- Verdict: " + [role, verdict, date, t.fingerprint(secs[PART[role]] || []), note].join(" ");
  const lines = text.replace(/\n+$/, "").split("\n");
  if (!lines.includes("## Reviews")) lines.push("", "## Reviews", "");
  const i = lines.indexOf("## Reviews") + 1;
  let end = lines.findIndex((l, j) => j >= i && l.startsWith("## "));
  if (end < 0) end = lines.length;
  let part = lines.slice(i, end).filter((l) => !l.startsWith("- Verdict: " + role + " "));
  while (part.length && !part[part.length - 1].trim()) part.pop();
  part = (part.length ? part : [""]).concat([line], end < lines.length ? [""] : []);
  lines.splice(i, end - i, ...part);
  write(file, lines.join("\n") + "\n");
}

// manual <OPERATIONS.md>: OPERATIONS.html on stdout (bin/manual.sh build), from PROJECT and SUM in the
// environment. The Markdown is escaped, so nothing in it runs; only http(s), mailto, # and relative links link.
function manual(src) {
  const text = read(src);
  const e = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#x27;");
  const NAMED = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'" };
  const unescape = (s) => s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, n) =>
    n[0] === "#" ? String.fromCodePoint(n[1] === "x" || n[1] === "X" ? parseInt(n.slice(2), 16) : parseInt(n.slice(1), 10))
      : (n.toLowerCase() in NAMED ? NAMED[n.toLowerCase()] : m));
  const safeUrl = (u) => {
    u = u.trim();
    if (/^(https?:|mailto:|#)/i.test(u) || !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(u)) return u;  // never javascript: or data:
    return null;
  };
  const inline = (s) => {  // escape, then mark up code, links, bold and italics
    const codes = [];
    s = s.replace(/``\s?(.+?)\s?``|`([^`]+)`/g, (m, a, b) => { codes.push("<code>" + e(a !== undefined ? a : b) + "</code>"); return "\0" + (codes.length - 1) + "\0"; });
    s = e(s);
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, label, href) => { const u = safeUrl(unescape(href)); return u !== null ? '<a href="' + e(u) + '">' + label + "</a>" : label; });
    s = s.replace(/&lt;(https?:\/\/[^\s&]+)&gt;/g, (m, u) => '<a href="' + u + '">' + u + "</a>");
    s = s.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/(?<![\p{L}\p{N}_*])\*(?!\s)(.+?)(?<!\s)\*(?![\p{L}\p{N}_*])/gu, "<em>$1</em>");
    return s.replace(/\0(\d+)\0/g, (m, n) => codes[Number(n)]);
  };
  const seen = new Set();
  const slug = (t) => {
    let s = t.replace(/<[^>]+>/g, "").toLowerCase().replace(/[^a-z0-9 -]/g, "").trim().split(" ").join("-") || "section";
    const base = s;
    let n = 1;
    while (seen.has(s)) { n++; s = base + "-" + n; }
    seen.add(s);
    return s;
  };
  const cells = (row) => {
    row = row.trim();
    if (row.startsWith("|")) row = row.slice(1);
    if (row.endsWith("|") && !row.endsWith("\\|")) row = row.slice(0, -1);
    return row.split(/(?<!\\)\|/).map((c) => c.trim().split("\\|").join("|"));
  };
  const lines = text.split("\n"), out = [], toc = [], para = [];
  let i = 0, title = "", box = 0;
  const flush = () => { if (para.length) { out.push("<p>" + inline(para.join(" ")) + "</p>"); para.length = 0; } };
  while (i < lines.length) {
    const l = lines[i];
    if (!l.trim()) { flush(); i++; continue; }
    let m = l.match(/^(#{1,4})\s+(.*)$/);
    if (m) {
      flush();
      const n = m[1].length, t = inline(m[2].trim());
      if (n === 1 && !title) { title = t.replace(/<[^>]+>/g, ""); out.push("<h1>" + t + "</h1>"); }
      else {
        const sid = slug(t);
        out.push("<h" + n + ' id="' + sid + '">' + t + "</h" + n + ">");
        if (n === 2 || n === 3) toc.push([n, sid, t]);
      }
      i++; continue;
    }
    if (l.startsWith("```")) {
      flush(); i++;
      const code = [];
      while (i < lines.length && !lines[i].startsWith("```")) code.push(lines[i++]);
      out.push("<pre><code>" + e(code.join("\n")) + "</code></pre>");
      i++; continue;
    }
    if (l.trimStart().startsWith("|") && i + 1 < lines.length && /^\s*\|?\s*:?-{3,}/.test(lines[i + 1])) {
      flush();
      const head = cells(l); i += 2;
      const rows = [];
      while (i < lines.length && lines[i].trimStart().startsWith("|")) rows.push(cells(lines[i++]));
      out.push('<div class="table"><table><thead><tr>' + head.map((c) => "<th>" + inline(c) + "</th>").join("") + "</tr></thead><tbody>" +
        rows.map((r) => "<tr>" + r.map((c) => "<td>" + inline(c) + "</td>").join("") + "</tr>").join("") + "</tbody></table></div>");
      continue;
    }
    if (l.startsWith(">")) {
      flush();
      const q = [];
      while (i < lines.length && lines[i].startsWith(">")) q.push(lines[i++].slice(1).trim());
      out.push("<blockquote><p>" + inline(q.join(" ")) + "</p></blockquote>");
      continue;
    }
    if (/^\s*([-*]|\d+\.)\s+/.test(l)) {
      flush();
      const stack = [];  // [indent, tag]
      while (i < lines.length) {
        m = lines[i].match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
        if (!m) {
          if (lines[i].trim() && lines[i].startsWith("  ") && stack.length) {  // a wrapped line of the item
            out[out.length - 1] = out[out.length - 1].slice(0, -5) + " " + inline(lines[i].trim()) + "</li>"; i++; continue;
          }
          break;
        }
        const ind = m[1].split("\t").join("    ").length, tag = /\d/.test(m[2][0]) ? "ol" : "ul", body = m[3];
        while (stack.length && ind < stack[stack.length - 1][0]) out.push("</" + stack.pop()[1] + ">");
        if (!stack.length || ind > stack[stack.length - 1][0]) { stack.push([ind, tag]); out.push("<" + tag + ">"); }
        const t = body.match(/^\[( |x|X)\]\s+(.*)$/);
        if (t) {
          box++;
          out.push('<li class="task"><label><input type="checkbox" data-box="' + box + '"' + (t[1] !== " " ? " checked" : "") + "> " + inline(t[2]) + "</label></li>");
        } else out.push("<li>" + inline(body) + "</li>");
        i++;
      }
      while (stack.length) out.push("</" + stack.pop()[1] + ">");
      continue;
    }
    para.push(l.trim()); i++;
  }
  flush();
  title = title || "Operations manual";
  const nav = toc.map(([n, sid, t]) => '<li class="l' + n + '"><a href="#' + sid + '">' + t.replace(/<a [^>]*>|<\/a>/g, "") + "</a></li>").join("");
  // Sections for search: each h2 and what follows it.
  const body = "<section>" + out.join("\n").replace(/(<h2 id=)/g, "</section><section>$1") + "</section>";
  const project = env("PROJECT");
  const full = e(title + (project && !title.includes(project) ? " - " + project : ""));
  process.stdout.write(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<!-- cabinet manual: ${env("SUM")} -->
<title>${full}</title>
<style>
:root{--bg:#fbfaf7;--fg:#1d1d1b;--muted:#6b6a65;--line:#e4e1d9;--accent:#2f5d8a;--code:#f1eee7}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#e8e6e1;--muted:#a19f99;--line:#33322f;--accent:#8db7e0;--code:#22211f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.wrap{display:grid;grid-template-columns:16rem minmax(0,1fr);gap:2.5rem;max-width:72rem;margin:0 auto;padding:2rem 1rem}
nav{position:sticky;top:1rem;align-self:start;max-height:calc(100vh - 2rem);overflow:auto;font-size:.9rem}
nav ul{list-style:none;padding:0;margin:.5rem 0 0}nav li.l3{padding-left:.9rem}nav a{color:var(--muted);text-decoration:none}nav a:hover{color:var(--accent)}
input[type=search]{width:100%;padding:.45rem .6rem;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg);font:inherit}
main{min-width:0}h1{font-size:1.9rem;line-height:1.2;margin:0 0 1rem}h2{margin-top:2.4rem;padding-top:.4rem;border-top:1px solid var(--line)}h3{margin-top:1.6rem}
a{color:var(--accent)}code{background:var(--code);padding:.05rem .3rem;border-radius:4px;font-size:.9em}
pre{background:var(--code);padding:.8rem;border-radius:6px;overflow:auto}pre code{padding:0}
.table{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:.93rem}th,td{border-bottom:1px solid var(--line);padding:.4rem .5rem;text-align:left;vertical-align:top}
blockquote{margin:1rem 0;padding:.2rem 1rem;border-left:3px solid var(--line);color:var(--muted)}
li.task{list-style:none;margin-left:-1.2rem}li.task input{margin-right:.4rem}
.hidden{display:none}.note{color:var(--muted);font-size:.85rem}
@media (max-width:52rem){.wrap{grid-template-columns:1fr}nav{position:static;max-height:none}}
@media print{nav{display:none}.wrap{display:block}}
</style></head><body><div class="wrap">
<nav><input type="search" id="q" placeholder="Search the manual" aria-label="Search the manual"><ul>${nav}</ul>
<p class="note">Built from OPERATIONS.md by <code>bin/manual.sh build</code>. Tick boxes are remembered in this browser, for today.</p></nav>
<main>${body}</main></div>
<script>
(function(){
  var day = new Date().toISOString().slice(0, 10), key = "cabinet-manual-" + location.pathname + "-" + day;
  var ticked = {}; try { ticked = JSON.parse(localStorage.getItem(key) || "{}"); } catch (e) {}
  document.querySelectorAll("input[data-box]").forEach(function (b) {
    if (b.dataset.box in ticked) b.checked = ticked[b.dataset.box];
    b.addEventListener("change", function () { ticked[b.dataset.box] = b.checked; try { localStorage.setItem(key, JSON.stringify(ticked)); } catch (e) {} });
  });
  var q = document.getElementById("q");
  q.addEventListener("input", function () {
    var t = q.value.trim().toLowerCase();
    document.querySelectorAll("main section").forEach(function (s) { s.classList.toggle("hidden", t !== "" && s.textContent.toLowerCase().indexOf(t) < 0); });
  });
})();
</script></body></html>
`);
}

// ---- Editing files line by line, in place ---------------------------------------------------------
// A pattern is "/source/flags". In the source, ${NAME} is the environment variable NAME as literal
// text, never as a pattern. In a replacement, $1..$9 are the groups, ${NAME} is the variable's
// value as it is, and $$ is a $. Each rule applies to each line without its newline, so ^ and $ are
// the line's start and end.
// The edits work on bytes (latin1 text, one character per byte), so nothing in a file is
// ever re-encoded; the environment's values and the arguments are turned into the same bytes.
const envBytes = (k) => Buffer.from(env(k), "utf8").toString("latin1");
const bytes = (s) => Buffer.from(s, "utf8").toString("latin1");
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\\/]/g, "\\$&");
function pattern(p) {
  const at = p.lastIndexOf("/");
  if (p[0] !== "/" || at < 1) die("lib.js: a pattern is /source/flags, not " + p, 2);
  return new RegExp(p.slice(1, at).replace(/\$\{([A-Z_][A-Z0-9_]*)\}/g, (m, k) => escapeRe(envBytes(k))), p.slice(at + 1));
}
const fill = (tpl, groups) => tpl.replace(/\$(\$|\d|\{([A-Z_][A-Z0-9_]*)\})/g, (m, x, k) =>
  x === "$" ? "$" : k ? envBytes(k) : (groups[Number(x)] !== undefined ? groups[Number(x)] : ""));
// The file's lines, and whether it ended with a newline; written back the same way, through a
// temporary file renamed over it, so a failed write never leaves half a file.
function lines(file) {
  const t = fs.readFileSync(file, "latin1");
  const end = t.endsWith("\n");
  return { list: (end ? t.slice(0, -1) : t).split("\n"), end };
}
function replaceFile(file, text) {  // keeping the file's own permissions
  const mode = fs.statSync(file).mode & 0o7777;
  fs.writeFileSync(file + ".tmp", text, { encoding: "latin1", mode });
  fs.chmodSync(file + ".tmp", mode);
  fs.renameSync(file + ".tmp", file);
}
function save(file, list, end) { replaceFile(file, list.join("\n") + (end && list.length ? "\n" : "")); }
function eachFile(files, fn) {
  for (const f of files) { const l = lines(f); save(f, fn(l.list), l.end); }
}

// sub <file>... -- </pattern/flags> <replacement> [...]: replace in every line, rule by rule.
function sub(...args) {
  const cut = args.indexOf("--");
  if (cut < 0 || (args.length - cut - 1) % 2) die("usage: node lib.js sub <file>... -- </pattern/flags> <replacement>...", 2);
  const rules = [];
  for (let i = cut + 1; i < args.length; i += 2) rules.push([pattern(args[i]), args[i + 1]]);
  eachFile(args.slice(0, cut), (list) => list.map((l) => rules.reduce((s, [re, tpl]) => s.replace(re, (...g) => fill(tpl, g)), l)));
}
// sub-all <file> </pattern/flags> <replacement>: replace in the whole text at once, so a pattern can span lines.
function subAll(file, p, tpl) { replaceFile(file, fs.readFileSync(file, "latin1").replace(pattern(p), (...g) => fill(tpl, g))); }
// has <file> </pattern/flags>: exit 0 when a line matches, 1 when none does (or there is no file).
function has(file, p) {
  const re = pattern(p);
  let l;
  try { l = lines(file).list; } catch (e) { process.exit(1); }
  process.exit(l.some((x) => re.test(x)) ? 0 : 1);
}
// drop <file> </pattern/flags>: remove every line that matches.
function drop(file, p) { const re = pattern(p); eachFile([file], (list) => list.filter((l) => !re.test(l))); }
// drop-text <file> <text>: remove every line that contains the text. drop-line: every line that is it.
function dropText(file, text) { text = bytes(text); eachFile([file], (list) => list.filter((l) => !l.includes(text))); }
function dropLine(file, text) { text = bytes(text); eachFile([file], (list) => list.filter((l) => l !== text)); }
// before <file> </pattern/flags> <line>: put the line before every line that matches. after: after it.
function before(file, p, add) { const re = pattern(p); add = bytes(add); eachFile([file], (list) => list.flatMap((l) => (re.test(l) ? [add, l] : [l]))); }
function after(file, p, add) { const re = pattern(p); add = bytes(add); eachFile([file], (list) => list.flatMap((l) => (re.test(l) ? [l, add] : [l]))); }
// replace-line <file> <start> <text>: every line that starts with <start> becomes <text> (which may
// hold several lines). Nothing changes when <text> is empty.
function replaceLine(file, start, text) {
  if (!text) return;
  start = bytes(start); text = bytes(text);
  eachFile([file], (list) => list.flatMap((l) => (l.startsWith(start) ? text.split("\n") : [l])));
}
// after-last <file> <line> <name>...: put the line after the last line that holds "| <name> |" for
// any of the names (a team table's last role row); nothing changes when none does.
function afterLast(file, add, ...names) {
  add = bytes(add); names = names.map(bytes);
  eachFile([file], (list) => {
    let last = -1;
    list.forEach((l, i) => { if (names.some((n) => n && l.includes("| " + n + " |"))) last = i; });
    if (last >= 0) list.splice(last + 1, 0, add);
    return list;
  });
}
// credit-line <file> on|off: the "- **Commits.**" house rule follows credit roles. One sentence of it
// changes, to the other, and nothing else on the line. Exit 0 when the line says it now (changed or
// already so), 3 when it holds neither sentence (the owner rewrote it: theirs to edit).
const CREDIT_OFF = "No AI or tool attribution of any kind (no `Co-Authored-By`, no \"Generated with\" line).";
const CREDIT_ON = "No AI or tool attribution of any kind except Cabinet's role credit (one `Co-authored-by: Cabinet <role>` line, added by Cabinet to a commit made in a Cabinet run; no other `Co-Authored-By`, no \"Generated with\" line).";
function creditLine(file, mode) {
  if (mode !== "on" && mode !== "off") die("usage: node lib.js credit-line <file> on|off", 2);
  const [want, other] = mode === "on" ? [CREDIT_ON, CREDIT_OFF] : [CREDIT_OFF, CREDIT_ON];
  const l = lines(file), i = l.list.findIndex((x) => x.startsWith("- **Commits.**"));
  if (i < 0) process.exit(3);
  if (l.list[i].includes(want)) return;
  if (!l.list[i].includes(other)) process.exit(3);
  l.list[i] = l.list[i].replace(other, () => want);
  save(file, l.list, l.end);
}
// fill-template <file>: the template with its markers (PROJECT, SLUG, OWNER_NAME, OWNER_EMAIL and
// KIT_VERSION, each between two pairs of at signs) replaced by P, S, O, E and V from the environment,
// on stdout. The marker is built, not written out, so a workspace's copy of this file holds none.
function fillTemplate(file) {
  let t = fs.readFileSync(file, "latin1");
  const at = "@".repeat(2);
  for (const [k, v] of [["PROJECT", "P"], ["SLUG", "S"], ["OWNER_NAME", "O"], ["OWNER_EMAIL", "E"], ["KIT_VERSION", "V"]]) {
    t = t.split(at + k + at).join(envBytes(v));
  }
  process.stdout.write(Buffer.from(t, "latin1"));
}
// slug <text>: one "-" for each character that is not a letter or digit (Claude Code's folder names).
function slug(text) { process.stdout.write(text.replace(/[^A-Za-z0-9]/gu, "-")); }

// ---- Time limits ----------------------------------------------------------------------------
// watchdog <seconds> <pid> [<mark file>]: after the seconds, write "stopped" to the mark file, TERM
// the process group of <pid>, then KILL it 10 seconds later. Stopping this process stops the watch.
// Its timer counts only time the machine is awake, so a run is never stopped for a sleep, and the
// mark, not the clock on the wall, tells the caller whether the run was stopped.
function watchdog(secs, pid, mark) {
  const group = -Number(pid);
  setTimeout(() => {
    if (mark) { try { fs.writeFileSync(mark, "stopped\n"); } catch (e) { /* the caller then sees no stop */ } }
    try { process.kill(group, "SIGTERM"); } catch (e) { /* already gone */ }
    setTimeout(() => { try { process.kill(group, "SIGKILL"); } catch (e) { /* gone */ } }, 10000);
  }, Number(secs) * 1000);
}
// run-limited <seconds, 0 for none> <command> [<word>...]: run it with no shell; at the limit it gets
// SIGALRM. Exits with its status, or 128 plus the signal that stopped it.
function runLimited(secs, cmd, ...words_) {
  const ms = Number(secs) * 1000;
  const r = spawnSync(cmd, words_, { stdio: "inherit", timeout: ms > 0 ? ms : undefined, killSignal: "SIGALRM" });
  if (r.error && r.error.code !== "ETIMEDOUT") die("cannot run " + cmd + ": " + r.error.message);
  if (r.signal) process.exit(128 + (require("node:os").constants.signals[r.signal] || 0));
  process.exit(r.status === null ? 1 : r.status);
}

// ---- Secrets (bin/secret.sh) ----------------------------------------------------------------
// Files and diffs are read byte by byte (latin1), as the scan always has, so a pattern counts bytes.
const SP = "[\\t\\n\\v\\f\\r ]";
const SECRETS = [
  ["a private key", /-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/],
  ["an AWS access key", /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
  ["a GitHub token", /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})/],
  ["a Slack token", /\bxox[abposr]-[A-Za-z0-9-]{10,}/],
  ["a Stripe live key", /\b[rs]k_live_[A-Za-z0-9]{16,}/],
  ["an Anthropic key", /\bsk-ant-[A-Za-z0-9_-]{20,}/],
  ["an OpenAI key", /\bsk-(?:proj-)?[A-Za-z0-9]{20,}/],
  ["a Google API key", /\bAIza[0-9A-Za-z_-]{35}/],
  ["an npm token", /\bnpm_[A-Za-z0-9]{36}\b/],
  // A line that sets one: a name like password or api_key, then : or =, then a value of 8 or more
  // characters that is not a placeholder (<...>), a variable ($X, ${X}) or a template.
  ["a password or token", new RegExp("(?<![a-z])(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret)(?:_\\w*)?(?![a-z])[\"']?" +
    SP + "*[:=]" + SP + "*[\"']?(?![$<{%(\\[])[^\\t\\n\\v\\f\\r \"'<>`,;]{8,}", "i")],
];
// A file is binary when the first 512 bytes hold a NUL, or (when they are not UTF-8 with non-ASCII in
// them) more than a third are odd: control codes other than tab, newline, CR, BS, FF and ESC, or
// bytes with the high bit set. An empty file counts as binary; it has no lines anyway.
function isBinary(buf) {
  const b = buf.subarray(0, 512);
  if (!b.length || b.includes(0)) return true;
  const hi = b.some((x) => x > 127);
  if (hi) { try { new TextDecoder("utf-8", { fatal: true }).decode(b); return false; } catch (e) { /* not UTF-8 */ } }
  let odd = 0;
  for (const x of b) if (x > 127 || (x < 32 && ![8, 9, 10, 12, 13, 27].includes(x))) odd++;
  return odd * 3 > b.length;
}
// A name as git quotes it in a diff ("b/caf\303\251.md"): C escapes, octal ones one byte each.
const CQ = { a: "\x07", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t", v: "\v" };
const unquote = (s) => s.replace(/\\([0-7]{3}|.)/g, (_, e) => e.length === 3 ? String.fromCharCode(parseInt(e, 8) & 255) : CQ[e] || e);
// secret-scan [--staged]: "<file>:<line>: <kind>" for each likely secret. Reads, on stdin, the staged
// diff (--staged) or the NUL-separated list of files to scan. A line with not-a-secret is skipped.
// Names stay bytes (latin1) from input to output, so a UTF-8 name is printed as it is. A file the
// full scan cannot read is reported as "<file>:0: a file the check could not read", never skipped.
function secretScan(mode) {
  const input = fs.readFileSync(0).toString("latin1");
  let out = "";
  const scan = (f, n, t) => {
    if (t.includes("not-a-secret")) return;
    const hit = SECRETS.find(([, re]) => re.test(t));
    if (hit) out += f + ":" + n + ": " + hit[0] + "\n";
  };
  if (mode === "--staged") {
    let f = null, n = 0;
    for (const l of input.split("\n")) {
      let m;
      // git ends a name with a space by a tab, and quotes one with a ", a \ or a byte above 127.
      if ((m = l.replace(/\t$/, "").match(/^\+\+\+ (?:b\/(.*)|"b\/(.*)")$/))) { f = m[1] !== undefined ? m[1] : unquote(m[2]); continue; }
      if ((m = l.match(/^@{2} -\S+ \+(\d+)/))) { n = Number(m[1]); continue; }  // a hunk header
      if (l.startsWith("+") && f !== null) { scan(f, n, l.slice(1).replace(/\t/g, " ")); n++; }
    }
  } else {
    for (const f of input.split("\0")) {
      if (!f) continue;
      const p = Buffer.from(f, "latin1");  // the name's own bytes
      let st, buf;
      try { st = fs.statSync(p); } catch (e) { if (e.code !== "ENOENT") out += f + ":0: a file the check could not read\n"; continue; }  // ENOENT: deleted, not yet staged
      if (!st.isFile() || st.size > 2000000) continue;
      try { buf = fs.readFileSync(p); } catch (e) { out += f + ":0: a file the check could not read\n"; continue; }
      if (isBinary(buf)) continue;
      const text = buf.toString("latin1");
      const ls = text.split("\n");
      if (text.endsWith("\n")) ls.pop();
      ls.forEach((l, i) => scan(f, i + 1, l.replace(/\t/g, " ")));
    }
  }
  process.stdout.write(Buffer.from(out, "latin1"));
}

// inexact <JSON text>: what JSON.parse and JSON.stringify would not give back as written, or null: a
// number written another way (1.0, 1e3, -0, or beyond what a double holds) or an object key that is
// a whole number (JavaScript moves those first).
function inexact(t) {
  const num = /-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?/y;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (c === '"') {
      let j = i + 1;
      while (j < t.length && t[j] !== '"') j += t[j] === "\\" ? 2 : 1;
      const raw = t.slice(i, j + 1);
      let k = j + 1;
      while (/\s/.test(t[k] || "")) k++;
      if (t[k] === ":" && /^(0|[1-9][0-9]*)$/.test(JSON.parse(raw))) return "the key " + raw;
      i = j;
    } else if (c === "-" || (c >= "0" && c <= "9")) {
      num.lastIndex = i;
      const m = num.exec(t);
      if (!m) continue;
      if (JSON.stringify(Number(m[0])) !== m[0]) return "the number " + m[0];
      i += m[0].length - 1;
    }
  }
  return null;
}

// json [-n] [-R] [-s] [-r] [-c] [-e] [--each] [--exact] [--arg name text]... [--argjson name json]... <expression> [file]... [--args word...]
// Reads and writes JSON for the scripts, with a JavaScript expression: $ is the input,
// --arg x and --argjson x are $x, --args words are $args. Input is each JSON value in the files (or on
// stdin; a file of JSON lines is one value per line), all of them as one array with -s, its lines as
// an array with -R, nothing with -n. The result is printed as JSON (one line with -c), a string as it
// is with -r, each item of an array on its own with --each; undefined prints nothing. -e: exit 1 when
// the last result is null, false or undefined. A byte-order mark before a JSON value is skipped.
// --exact: exit 3 on input that would not be written back as it is (inexact), so a file that is
// rewritten keeps every value. Exit 2 on input that is not JSON, 5 on an error.
function json(...argv) {
  const o = { names: [], vals: [], files: [] };
  let expr = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--arg" || a === "--argjson") {
      o.names.push("$" + argv[i + 1]);
      o.vals.push(a === "--arg" ? argv[i + 2] : JSON.parse(argv[i + 2]));
      i += 2;
    } else if (a === "--args") { o.names.push("$args"); o.vals.push(argv.slice(i + 1)); break; }
    else if (a === "--each") o.each = true;
    else if (a === "--exact") o.exact = true;
    else if (/^-[nRsrce]+$/.test(a)) for (const f of a.slice(1)) o[f] = true;
    else if (expr === null) expr = a;
    else o.files.push(a);
  }
  const text = () => (o.files.length ? o.files.map((f) => fs.readFileSync(f, "utf8")) : [fs.readFileSync(0, "utf8")]);
  const values = (t) => {
    t = t.replace(/^﻿/, "");
    if (!t.trim()) return [];
    const bad = o.exact && inexact(t);
    if (bad) die("json: " + bad + " would be written differently", 3);
    try { return [JSON.parse(t)]; } catch (e) { return t.split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l)); }
  };
  let inputs;
  try {
    if (o.n) inputs = [undefined];
    else if (o.R) { const t = text().join(""); inputs = [t === "" ? [] : t.replace(/\n$/, "").split("\n")]; }
    else { inputs = text().flatMap(values); if (o.s) inputs = [inputs]; }
  } catch (e) { die("json: " + e.message, 2); }
  let fn, last;
  // Helpers for the expression: num("12") is 12 and num("") or num("x") null; str("") is null;
  // sum([1, 2]) is 3 and sum([]) null. list(x) and obj(x) are x, [] or {} for a missing one, and an
  // error (so nothing is written) for any other kind: a file of another shape is never reshaped.
  const num = (x) => (String(x).trim() !== "" && isFinite(x) ? Number(x) : null);
  const str = (x) => (x === "" ? null : x);
  const sum = (a) => (a.length ? a.reduce((x, y) => x + y, 0) : null);
  const list = (x) => { if (x == null) return []; if (!Array.isArray(x)) throw new Error("not a list"); return x; };
  const obj = (x) => { if (x == null) return {}; if (typeof x != "object" || Array.isArray(x)) throw new Error("not an object"); return x; };
  // And the handoff reader's: idOrder (a sort's compare), statusKnown, statusClosed and ownerIn.
  const helpers = { num, str, sum, list, obj, idOrder, statusKnown, statusClosed, ownerIn };
  try { fn = new Function("$", ...Object.keys(helpers), ...o.names, "return (" + expr + ");"); } catch (e) { die("json: " + e.message, 5); }
  let out = "";
  const put = (v) => {
    last = v;
    if (v !== undefined) out += (o.r && typeof v === "string" ? v : JSON.stringify(v, null, o.c ? 0 : 2)) + "\n";
  };
  for (const input of inputs) {
    let v;
    try { v = fn(input, ...Object.values(helpers), ...o.vals); }
 catch (e) { die("json: " + e.message, 5); }
    if (o.each && Array.isArray(v)) v.forEach(put); else put(v);
  }
  process.stdout.write(out);
  if (o.e && (last === undefined || last === null || last === false)) process.exit(1);
}

// closest <word> <candidate>...: the candidate nearest the word, printed: within two edits (a typo), or
// else one the word begins or that begins with the word. Nothing when none is near.
function closest(word, ...cands) {
  const dist = (a, b) => {
    const row = Array.from({length: b.length + 1}, (_, j) => j);
    for (let i = 1; i <= a.length; i++) {
      let prev = row[0]; row[0] = i;
      for (let j = 1; j <= b.length; j++) {
        const t = row[j];
        row[j] = Math.min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] === b[j - 1] ? 0 : 1));
        prev = t;
      }
    }
    return row[b.length];
  };
  let best = "", bestd = 3;
  if (word.length >= 2) for (const c of cands) { const d = dist(word, c); if (d < bestd) { bestd = d; best = c; } }
  if (!best && word.length >= 2) best = cands.find((c) => c.startsWith(word) || word.startsWith(c)) || "";
  if (best) process.stdout.write(best + "\n");
}

// changelog-render <width>: changelog Markdown on stdin, for a terminal. The shell calls it only when its
// output is styled (styled in platform.sh) and passes the width. A "## <version> - <date>" heading shows
// the version bold and the date dim, other headings bold; code shows without its backticks in the normal
// weight, **text** bold without its asterisks; list items keep their "- " and wrap at words under their
// text, paragraphs wrap the same way, and a word longer than the width stays whole on its own line. Every
// line in is one or more lines out: none is added or removed. The text is only printed, never run.
const STYLE = { bold: "\x1b[1m", dim: "\x1b[2m", reset: "\x1b[0m" };   // the only codes here (Rule 3)
function changelogRender(width) {
  const w = parseInt(width, 10) > 0 ? parseInt(width, 10) : 80;
  const paint = (t, st) => (t ? STYLE[st] + t + STYLE.reset : "");
  // Runs of text, bold or not: code spans first, so ** inside code stays as it is.
  const runs = (t) => t.split(/(`[^`]*`)/).flatMap((part, i) => (i % 2 ? [{ text: part.slice(1, -1), bold: false }]
    : part.split(/\*\*(?=\S)(.+?)(?<=\S)\*\*/).map((p, j) => ({ text: p, bold: j % 2 === 1 }))));
  // Words, each a list of runs, split at spaces.
  const wordsIn = (rs) => {
    const out = []; let cur = [];
    for (const r of rs) r.text.split(/ +/).forEach((p, k) => {
      if (k > 0 && cur.length) { out.push(cur); cur = []; }
      if (p) cur.push({ text: p, bold: r.bold });
    });
    if (cur.length) out.push(cur);
    return out;
  };
  // A line's runs, neighbours of one weight joined, so a bold phrase is one styled span on each line.
  const show = (rs) => rs.reduce((a, r) => (a.length && a[a.length - 1].bold === r.bold
    ? (a[a.length - 1] = { text: a[a.length - 1].text + r.text, bold: r.bold }, a) : [...a, r]), [])
    .map((r) => (r.bold ? paint(r.text, "bold") : r.text)).join("");
  const wrap = (first, rest, ws) => {
    const lines = []; let line = [{ text: first, bold: false }], len = [...first].length, empty = true;
    for (const word of ws) {
      const n = word.reduce((a, r) => a + [...r.text].length, 0);
      if (!empty && len + 1 + n > w) { lines.push(show(line)); line = [{ text: rest, bold: false }]; len = [...rest].length; empty = true; }
      if (!empty) line.push({ text: " ", bold: line[line.length - 1].bold && word[0].bold });
      line.push(...word); len += (empty ? 0 : 1) + n; empty = false;
    }
    lines.push(show(line));
    return lines.join("\n");
  };
  const out = fs.readFileSync(0, "utf8").split("\n").map((l) => {
    let m;
    // [\s\S], not ".": a line holding \r, U+2028 or U+2029 still matches, so the last one always does.
    if ((m = /^## (\S+)( - [\s\S]*)?$/.exec(l))) return paint(m[1], "bold") + paint(m[2] || "", "dim");
    if ((m = /^#+ ([\s\S]*)$/.exec(l))) return runs(m[1]).map((r) => paint(r.text, "bold")).join("");
    if ((m = /^(\s*)(- |\d+\. )([\s\S]*)$/.exec(l))) return wrap(m[1] + m[2], " ".repeat([...m[1] + m[2]].length), wordsIn(runs(m[3])));
    m = /^(\s*)([\s\S]*)$/.exec(l);
    return m[2] ? wrap(m[1], m[1], wordsIn(runs(m[2]))) : l;
  });
  process.stdout.write(out.join("\n"));
}

// push-check: what is ready to push, per repo (cabinet push-check). REPOS holds "<name>\t<path>" lines,
// HANDOFFS what handoff list --json gives, WS the workspace's folder. Local refs only: no fetch, nothing written.
// In the workspace's row, a coordination commit (not a merge, and every path it changes, at least one,
// is HANDOFFS.md, BRIEF.md or under one of COORD's folders) needs no handoff; a verdict naming it still counts.
const COORD = ["handoffs/", "notes/", "specs/evidence/", "specs/qa/", "specs/security/", "specs/reviews/", "specs/design/", "specs/adr/"];
function pushCheck() {
  const hs = JSON.parse(env("HANDOFFS") || "[]");
  const git = (dir, ...a) => { const r = spawnSync("git", ["-C", dir, ...a], { encoding: "utf8" }); return r.status === 0 ? r.stdout.replace(/\n$/, "") : null; };
  const real = (p) => { try { return fs.realpathSync(p); } catch (e) { return null; } };
  const state = (e) => [["missing", e.missing], ["blocking", e.blocking], ["stale", e.stale]].filter(([, r]) => r.length).map(([k, r]) => k + " " + r.join(", ")).join("; ")
    || (e.ready === null ? "needs no review" : "not ready");
  const repos = env("REPOS").split("\n").filter(Boolean).map((l) => l.split("\t")).map(([name, p]) => {
    const o = { name, path: p, branch: null, upstream: null, commits: [], files: 0, insertions: 0, deletions: 0, ready: false, why: null };
    // Its own repo, not a folder inside another (a repo not cloned yet, inside the workspace's own git).
    if (!real(p) || git(p, "rev-parse", "--show-toplevel") === null || real(git(p, "rev-parse", "--show-toplevel")) !== real(p)) return { ...o, why: "not on this machine" };
    o.branch = git(p, "symbolic-ref", "--short", "-q", "HEAD");
    if (!o.branch) return { ...o, branch: null, why: "detached HEAD" };
    o.upstream = git(p, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}");
    if (!o.upstream) return { ...o, upstream: null, why: "no upstream: nothing to compare with" };
    // --no-renames lists both paths of a rename; -z keeps each path as git stores it.
    const coord = (full, parents) => {
      if (p !== env("WS") || parents.split(" ").filter(Boolean).length > 1) return false;
      const ps = (git(p, "diff-tree", "--root", "--no-commit-id", "--no-renames", "-r", "-z", "--name-only", full) || "").split("\0").filter(Boolean);
      return ps.length > 0 && ps.every((f) => f === "HANDOFFS.md" || f === "BRIEF.md" || COORD.some((d) => f.startsWith(d)));
    };
    for (const l of (git(p, "log", "--format=%H%x09%P%x09%h%x09%s", "@{u}..HEAD") || "").split("\n").filter(Boolean)) {
      const [full, parents, hash, ...s] = l.split("\t");
      const handoffs = hs.filter((e) => e.verdicts.some((v) => v.commits.some((c) => c.length >= 7 && full.startsWith(c)))).map((e) => e.id);
      o.commits.push({ hash, subject: s.join("\t"), handoffs, coordination: coord(full, parents) });
    }
    const st = git(p, "diff", "--shortstat", "@{u}..HEAD") || "";
    for (const [k, re] of [["files", /(\d+) files? changed/], ["insertions", /(\d+) insertions?/], ["deletions", /(\d+) deletions?/]]) o[k] = Number((st.match(re) || [0, 0])[1]);
    if (!o.commits.length) return { ...o, why: "nothing to push" };
    for (const c of o.commits) {
      if (!c.handoffs.length) { if (c.coordination) continue; o.why = c.hash + " is on no handoff"; break; }
      const e = c.handoffs.map((i) => hs.find((h) => h.id === i)).find((h) => h.ready !== true);
      if (e) { o.why = c.hash + " is on " + e.id + ", " + state(e); break; }
    }
    o.ready = !o.why;
    return o;
  });
  process.stdout.write(JSON.stringify({ repos }) + "\n");
}

// ---- Models (doctor, config, setup) -----------------------------------------------------------
// How each built-in runner lists its models without a run, as seen on the installed tools (Codex
// 0.165.0, Antigravity CLI 1.4.8, Grok 1.0.70, opencode 2.2.0, Cursor 2026.10.22): fixed arguments,
// never the model, and a parser for what it prints. Claude Code (2.1.312) and Qwen Code (0.26.2) have
// no such command, so their models are not checked; custom is not either.
const MODEL_LISTS = {
  codex: ["codex", ["debug", "models"], (o) => JSON.parse(o).models.map((m) => m.slug)],
  antigravity: ["agy", ["models"], (o) => o.split("\n").filter((l) => l.includes("\t")).map((l) => l.split("\t")[0].trim())],
  grok: ["grok", ["models"], (o) => o.split("\n").map((l) => (l.match(/^\s*[*-]\s+(\S+)/) || [])[1])],
  opencode: ["opencode", ["models"], (o) => o.split("\n").map((l) => l.trim().split(/\s+/)[0])],
  cursor: ["cursor-agent", ["models"], (o) => o.split("\n").map((l) => (l.match(/^(\S+) - /) || [])[1])],
};
// The Cursor CLI: cursor-agent, or an agent that really is Cursor's (the name is generic), as cursor_bin.
function cursorBin() {
  for (const d of env("PATH").split(":")) {
    if (d && fs.existsSync(path.join(d, "cursor-agent"))) return path.join(d, "cursor-agent");
  }
  for (const d of env("PATH").split(":")) {
    const p = d && path.join(d, "agent");
    if (p && fs.existsSync(p)) { try { if (/cursor/i.test(fs.realpathSync(p))) return p; } catch (e) { /* none */ } return ""; }
  }
  return "";
}
// model-check <logroot> <runner> <model>...: one line per model, "<state>\t<model>\t<list command>": ok
// or missing when the runner's list was read; unlisted when the runner cannot list its models without a
// run; failed when its list command did not run, failed or printed no model. The list is read once, in
// <logroot> (the system's temporary folder until it exists), so the tool reads no project's settings.
function modelCheck(root, runner, ...models) {
  const l = MODEL_LISTS[runner];
  const say = (st, how) => { for (const m of models) process.stdout.write(st + "\t" + m + "\t" + how + "\n"); };
  if (!l) return say("unlisted", "");
  const bin = runner === "cursor" ? cursorBin() || l[0] : l[0];
  const how = path.basename(bin) + " " + l[1].join(" ");
  let cwd = require("node:os").tmpdir();
  try { if (fs.statSync(root).isDirectory()) cwd = root; } catch (e) { /* not made yet */ }
  const r = spawnSync(bin, l[1], { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 30000, maxBuffer: 64 * 1024 * 1024 });
  let names = [];
  try { if (r.status === 0) names = l[2](r.stdout).filter(Boolean); } catch (e) { names = []; }
  if (!names.length) return say("failed", how);
  for (const m of models) process.stdout.write((names.includes(m) ? "ok" : "missing") + "\t" + m + "\t" + how + "\n");
}

// ---- The release notice (cabinet next, status, outdated, doctor) -----------------------------------
// Only a version is believed (x.y.z, no leading zero, at most 9 digits a part), and only here is one
// ordered. The newest version seen on the registry is <logroot>/latest-version, one line, refreshed at
// most once a day per machine by a background check that holds <logroot>/latest-version.lock.
const VERSION_RE = /^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$/;
const DAY_MS = 24 * 3600 * 1000;
const vparts = (v) => { const m = VERSION_RE.exec(v); return m ? m.slice(1).map(Number) : null; };
function vnewer(a, b) {
  const x = vparts(a), y = vparts(b);
  if (!x || !y) return false;
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i];
  return false;
}
// version-newer <a> <b>: exit 0 when both are versions and a is newer.
function versionNewer(a, b) { process.exit(vnewer(a || "", b || "") ? 0 : 1); }
// The version a regular file holds (never through a link), from at most its first 64 bytes: exactly one
// line holding one version, else "".
function versionIn(file) {
  try {
    if (!fs.lstatSync(file).isFile()) return "";
    const fd = fs.openSync(file, "r"), b = Buffer.alloc(64);
    const n = fs.readSync(fd, b, 0, 64, 0); fs.closeSync(fd);
    const m = /^([^\n]*)\n?$/.exec(b.subarray(0, n).toString("latin1"));
    return m && VERSION_RE.test(m[1]) ? m[1] : "";
  } catch (e) { return ""; }
}
// writeLatest: write latest-version whole: a new file of its own in <logroot>, renamed over it (never
// through a link, never into a folder). False, leaving nothing behind, when it cannot.
function writeLatest(root, v) {
  if (!VERSION_RE.test(v || "")) return false;
  const tmp = path.join(root, ".latest-version." + crypto.randomBytes(8).toString("hex"));
  try {
    fs.writeFileSync(tmp, v + "\n", { flag: "wx", mode: 0o600 });
    fs.renameSync(tmp, path.join(root, "latest-version"));
    return true;
  } catch (e) { try { fs.unlinkSync(tmp); } catch (e2) { /* never made */ } return false; }
}
// latest-write <logroot> <version>: the same for cabinet outdated; exit 1 when it could not.
function latestWrite(root, v) { process.exit(writeLatest(root, v) ? 0 : 1); }
// release-latest <logroot> <workspace version file>: print the latest version seen when it is newer than
// the workspace's; first, when the file is missing, a day old or a link, start the day's check in the
// background (detached, its output nowhere) and go on without waiting. A folder in its place starts none.
function releaseLatest(root, vfile) {
  const file = path.join(root, "latest-version");
  let st = null;
  try { st = fs.lstatSync(file); } catch (e) { /* missing */ }
  if (!st || st.isSymbolicLink() || (st.isFile() && Date.now() - st.mtimeMs >= DAY_MS)) {
    spawn(process.execPath, [__filename, "version-check", root], { cwd: root, detached: true, stdio: "ignore" }).unref();
  }
  const latest = versionIn(file);
  if (latest && vnewer(latest, versionIn(vfile))) process.stdout.write(latest + "\n");
}
// version-check <logroot>: the background check. At most one at a time (the lock) and one a day (the
// file's time, set before npm starts). A stale lock (over 60 seconds) is removed, and nothing else is done
// in that run. npm runs in <logroot>, so it reads no project's files, with no shell, stopped at 30 seconds.
// ponytail: two checks racing within a few system calls can still make one extra request; the day's bound is best effort.
function versionCheck(root) {
  const file = path.join(root, "latest-version"), lock = file + ".lock";
  const age = (p) => { try { return Date.now() - fs.lstatSync(p).mtimeMs; } catch (e) { return -1; } };
  const fresh = () => { try { const s = fs.lstatSync(file); return s.isFile() && Date.now() - s.mtimeMs < DAY_MS; } catch (e) { return false; } };
  // A lock held: leave it, or, when stale, remove it (its age read just before) and do nothing more now.
  if (age(lock) >= 0) { if (age(lock) > 60000) { try { fs.rmdirSync(lock); } catch (e) { /* taken or gone */ } } return; }
  try { fs.mkdirSync(lock); } catch (e) { return; }
  try {
    if (fresh()) return;
    let st = null;
    try { st = fs.lstatSync(file); } catch (e) { /* missing */ }
    if (st && st.isDirectory()) return;
    if (st && st.isSymbolicLink()) { fs.unlinkSync(file); st = null; }
    if (st) { const now = new Date(); fs.utimesSync(file, now, now); } else fs.writeFileSync(file, "", { flag: "wx", mode: 0o600 });
    const r = spawnSync("npm", ["view", "@tarekraafat/cabinet", "version", "--no-update-notifier"],
      { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 30000, killSignal: "SIGKILL" });
    const m = r.status === 0 && /^([^\n]*)\n?$/.exec(r.stdout || "");
    if (m) writeLatest(root, m[1]);
  } catch (e) { /* the file stays as it was */ } finally { try { fs.rmdirSync(lock); } catch (e) { /* gone */ } }
}

// The kit's rules in a Codex rules file or a Gemini CLI policy, and the ones a live copy lacks, for the
// doctor and bootstrap (docs/guardrails.md). Codex: each prefix_rule(...) line, compared with the
// surrounding spaces trimmed. Gemini: each [[rule]] table, present when the live file has a rule with the
// same toolName, decision, and commandPrefix or commandRegex. A live file that does not exist lacks all.
const RULES_NOTE = "# Added by cabinet bootstrap: rules from a newer Cabinet kit";
function kitRules(kind, file) {
  const ls = read(file).split("\n");
  if (kind === "codex") return ls.filter((l) => l.trim().startsWith("prefix_rule(")).map((l) => ({ key: l.trim(), text: l.trim() }));
  // Gemini: a table's text runs from [[rule]] to the first blank, comment or table line.
  const val = (v) => {
    const m = /^"((?:[^"\\]|\\.)*)"/.exec(v) || /^'([^']*)'/.exec(v);
    if (!m) return v.replace(/\s+#.*$/, "").trim();
    return v[0] === "'" ? m[1] : JSON.parse('"' + m[1] + '"');
  };
  const rules = [];
  let cur = null;
  for (const l of ls) {
    const t = l.trim();
    if (t === "[[rule]]") { cur = { f: {}, text: [t] }; rules.push(cur); continue; }
    if (!cur) continue;
    if (t === "" || t.startsWith("#") || t.startsWith("[")) { cur = null; continue; }
    const m = /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(t);
    if (m) cur.f[m[1]] = val(m[2]);
    cur.text.push(l);
  }
  return rules.map((r) => ({ key: JSON.stringify([r.f.toolName, r.f.decision, "commandPrefix" in r.f ? "p" : "r", r.f.commandPrefix ?? r.f.commandRegex]), text: r.text.join("\n") }));
}
function rulesMissing(kind, live, kit) {
  let have = [];
  try { have = kind === "codex" ? read(live).split("\n").map((l) => l.trim()) : kitRules(kind, live).map((r) => r.key); }
  catch (e) { if (e.code !== "ENOENT") throw e; }
  return kitRules(kind, kit).filter((r) => !have.includes(r.key));
}
// rules-missing <codex|gemini> <live> <kit> [--list]: how many kit rules the live file lacks, or (--list) their text.
function rulesMissingCmd(kind, live, kit, list) {
  const miss = rulesMissing(kind, live, kit);
  process.stdout.write(list === "--list" ? miss.map((r) => r.text + "\n").join("") : miss.length + "\n");
}
// rules-add <codex|gemini> <live> <kit>: the live file's bytes, then a comment line and the rules it lacks. For
// Codex, the kit's definitions (name = ...) those rules use and the file does not define come first, so the file
// never defines a name twice nor uses one it does not define. Prints nothing when no rule is missing.
function rulesAdd(kind, live, kit) {
  const miss = rulesMissing(kind, live, kit);
  if (!miss.length) return;
  const text = fs.readFileSync(live, "latin1");
  const add = [RULES_NOTE];
  if (kind === "codex") {
    for (const l of read(kit).split("\n")) {
      const m = /^([A-Za-z_][A-Za-z0-9_]*)\s*=/.exec(l.trim());
      const used = m && miss.some((r) => new RegExp("=\\s*" + m[1] + "\\b").test(r.text));
      if (used && !new RegExp("^\\s*" + m[1] + "\\s*=", "m").test(text)) add.push(l.trim());
    }
    add.push(...miss.map((r) => r.text));
  } else add.push(miss.map((r) => r.text).join("\n\n"));
  process.stdout.write(Buffer.concat([Buffer.from(text, "latin1"), Buffer.from((text === "" || text.endsWith("\n") ? "" : "\n") + add.join("\n") + "\n")]));
}

// verdict-origin <workspace>: each verdict line not added by a commit of bin/handoff.sh record or bin/spec.sh
// record, by one git blame --porcelain per file that holds one: in HANDOFFS.md, a "- Verdict:" line (not in a
// fenced example) whose commit's summary is not "handoffs: <its entry's ID> <role> <VERDICT>"; in a spec, a
// line under "## Reviews" whose summary is not "specs: <file> <role> <VERDICT>". One line each,
// "<file>\t<entry ID or spec>\t<role> <VERDICT>"; "nohistory" when the workspace has no git history. A line not
// committed yet is left for its commit. A summary can be copied, so this finds mistakes and casual edits, not
// forgeries. The archives are history and are never read.
function verdictOrigin(ws) {
  const git = (...a) => spawnSync("git", ["-C", ws, ...a], { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  if (git("rev-parse", "--verify", "-q", "HEAD").status !== 0) { process.stdout.write("nohistory\n"); return; }
  // blame <file>: [{text, summary}] per line, or null when git cannot read it (not tracked).
  const blame = (f) => {
    const r = git("blame", "--porcelain", "--", f);
    if (r.status !== 0) return null;
    const sums = new Map(), out = [];
    let sha = "";
    for (const l of r.stdout.split("\n")) {
      const h = /^([0-9a-f]{40}) \d+ \d+/.exec(l);
      if (h) { sha = h[1]; continue; }
      if (l.startsWith("summary ")) { sums.set(sha, l.slice(8)); continue; }
      if (l.startsWith("\t")) { const at = sha; out.push({ text: l.slice(1), sha: at, summary: () => sums.get(at) }); }
    }
    return out;
  };
  const uncommitted = (x) => /^0{40}$/.test(x.sha);
  const verdict = (t) => /^- Verdict: (\S+) (\S+) /.exec(t);
  const bad = [];
  if (/^- Verdict: /m.test(fs.existsSync(path.join(ws, "HANDOFFS.md")) ? read(path.join(ws, "HANDOFFS.md")) : "")) {
    let fenced = false;
    const b = blame("HANDOFFS.md") || [], of = [];  // the entry each line is in (handoffEntries), or none
    for (const e of handoffEntries(b.map((x) => x.text))) for (let i = e.start + 1; i < e.end; i++) of[i] = e.id;
    for (const [i, x] of b.entries()) {
      if (/^\s*```/.test(x.text)) { fenced = !fenced; continue; }
      if (fenced) continue;
      const id = of[i];
      const v = id && verdict(x.text);
      if (!v || uncommitted(x)) continue;
      if (x.summary() !== "handoffs: " + id + " " + v[1] + " " + v[2]) bad.push(["HANDOFFS.md", id, v[1] + " " + v[2]]);
    }
  }
  let specs = [];
  try { specs = fs.readdirSync(path.join(ws, "specs")).filter((f) => f.endsWith(".md")).sort(); } catch (e) { /* none */ }
  for (const f of specs) {
    const rel = "specs/" + f;
    if (!/^## Reviews$[\s\S]*^- Verdict: /m.test(read(path.join(ws, rel)))) continue;
    let on = false;
    for (const x of blame(rel) || []) {
      if (x.text.startsWith("## ")) { on = x.text === "## Reviews"; continue; }
      const v = on && verdict(x.text);
      if (!v || uncommitted(x)) continue;
      if (x.summary() !== "specs: " + f + " " + v[1] + " " + v[2]) bad.push([rel, rel, v[1] + " " + v[2]]);
    }
  }
  for (const b of bad) process.stdout.write(b.join("\t") + "\n");
}

// week-start <first day, 0 Sunday to 6 Saturday> [now, in seconds]: the local midnight this week began,
// in seconds. Date keeps a day with a clock change whole, and a midnight the clock skips becomes the
// first time that day has. "now" is for the tests.
function weekStart(first, now) {
  const n = now ? new Date(now * 1000) : new Date();
  process.stdout.write(new Date(n.getFullYear(), n.getMonth(), n.getDate() - (n.getDay() - first + 7) % 7).getTime() / 1000 + "\n");
}

// kit-map <kit>: every kit file as "<kit path> <workspace path>", from core/kit-files, the one list of what
// the kit ships (never globbed, so a stray file in the kit is never placed). The list itself is never placed.
function kitList(kit) {
  const out = [];
  for (const p of read(path.join(kit, "core/kit-files")).split("\n")) {
    const to = p === "core/CABINET.md" ? "CABINET.md" : p.startsWith("core/rules/") ? ".cabinet/rules/" + p.slice(11)
      : p.startsWith("scripts/") ? "bin/" + p.slice(8) : p.startsWith("roles/") ? ".cabinet/roles/" + p.slice(6)
      : p.startsWith("guardrails/") ? ".cabinet/guardrails/" + p.slice(11) : "";
    if (to && to !== "bin/" && !to.endsWith("/")) out.push([p, to]);
  }
  return out;
}
const kitMap = (kit) => put(1, kitList(kit).map((x) => x.join(" ") + "\n").join(""));

// The kit source (ADR-009 section 4, ADR-010 C7 and C8): every kit file update, setup or the doctor would
// add, replace or remove in <ws>, classed before anything is written. ok: missing, the kit's bytes already,
// or unedited since the manifest; keep: edited (differs from its manifest line), not-kit (there, but the
// kit never placed it, or a link or under a linked folder), file-in-way, folder-in-way. A file that left the
// kit is removed when unedited, else it stays and leaves the manifest (not a refusal). Then, unless refused
// or --dry-run, each file is written to <path>.cabinet-new beside it and renamed over the old (a new inode,
// so a running script keeps the one it opened), then the manifest the same way. A manifest path that is
// absolute or holds .. is never acted on. kit "-": the doctor's form, the manifest only: each file there
// that differs from its line (missing files are the doctor's own check), no format check.
const sha256 = (p) => crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex");
function kitPlan(ws, kit, kitFormat, force, dry) {
  try { ws = fs.realpathSync(ws); if (!fs.statSync(ws).isDirectory()) throw new Error(); } catch (e) { die("delete-plan: not a folder: " + escapePath(ws), 1); }
  const man = path.join(ws, ".cabinet/manifest"), had = new Map(), lines = [];
  let text = "";
  try { text = read(man); } catch (e) { if (e.code !== "ENOENT") die("delete-plan: could not read " + escapePath(man) + "; nothing was changed", 1); }
  for (const l of text.split("\n")) {
    const i = l.indexOf(" "), p = l.slice(i + 1);
    if (i > 0 && p && !p.startsWith("/") && !p.split("/").includes("..")) had.set(p, l.slice(0, i));
  }
  const hashOr = (p) => { try { return sha256(p); } catch (e) { return ""; } };   // unreadable: counts as edited
  if (kit === "-") {
    for (const [p, h] of had) { const s = lst(path.join(ws, p)); if (s && s.isFile() && hashOr(path.join(ws, p)) !== h) lines.push(["keep", "edited", p]); }
    return decideKit(lines, [], [], [], force, true, false);
  }
  // The workspace's format (none is 0). Newer than the kit's: refused. Older: the steps from it to the
  // kit's run here, before any write; 0 to 1 needs none (files that left the kit go below, as before).
  const ff = path.join(ws, ".cabinet/format");
  if (lst(ff)) {
    let f = null;
    try { const b = Buffer.alloc(32), fd = fs.openSync(ff, "r"); f = b.toString("utf8", 0, fs.readSync(fd, b, 0, 32, 0)); fs.closeSync(fd); } catch (e) { /* unreadable */ }
    f = f === null ? "" : f.replace(/\n+$/, "");
    if (!/^[0-9]{1,9}$/.test(f)) die("cabinet: " + escapePath(ff) + " is not a format number (one whole number), so nothing was changed: restore it (git -C \"" + escapePath(ws) + "\" checkout -- .cabinet/format), then run cabinet update again", 1);
    if (Number(f) > Number(kitFormat)) die("cabinet: this workspace was set up by a newer Cabinet (format " + Number(f) + "); update the kit first", 1);
  }
  const linkedUp = (abs) => { for (let p = path.dirname(abs); p.startsWith(ws + path.sep); p = path.dirname(p)) { const s = lst(p); if (s && s.isSymbolicLink()) return true; } return false; };
  const inWay = (abs) => { for (let p = path.dirname(abs); p.startsWith(ws + path.sep); p = path.dirname(p)) { const s = lst(p); if (s && !s.isDirectory()) return p; } return ""; };
  const writes = [], removes = [], next = new Map(), notes = [];
  for (const [src, dst] of kitList(kit)) {
    const abs = path.join(ws, dst), s = lst(abs), h = had.get(dst), want = sha256(path.join(kit, src));
    const w = { src, dst, abs, want, rm: "", why: "", linked: false };
    if (linkedUp(abs) || (s && s.isSymbolicLink())) { w.why = "not-kit"; w.linked = linkedUp(abs); }
    else if (inWay(abs)) { w.why = "file-in-way"; w.rm = inWay(abs); }
    else if (s && !s.isFile()) { w.why = "folder-in-way"; w.rm = abs; }
    else if (s) {
      const cur = hashOr(abs);
      if (cur === want) { next.set(dst, want); lines.push(["ok", "", dst]); continue; }
      if (cur !== h) w.why = !h || h === "-" ? "not-kit" : "edited";
    }
    lines.push([w.why ? "keep" : "ok", w.why, dst]);
    next.set(dst, w.why ? h || "-" : want);
    w.verb = s ? "updated" : "added";
    writes.push(w);
  }
  for (const [p, h] of had) {
    if (next.has(p)) continue;
    const abs = path.join(ws, p), s = lst(abs);
    if (linkedUp(abs) || (s && s.isSymbolicLink())) notes.push("  left the kit but a link here, left as is: " + escapePath(p));
    else if (s && (!s.isFile() || hashOr(abs) !== h)) notes.push("  left the kit but edited here, left as is: " + escapePath(p));
    else if (s) removes.push(p);
  }
  return decideKit(lines, writes, removes, notes, force, dry, text !== "", { ws, kit, man, next });
}
function decideKit(lines, writes, removes, notes, force, dry, hadManifest, w) {
  put(1, lines.filter((l) => dry || l[0] === "keep").map((l) => l[0] + "\t" + l[1] + "\t" + escapePath(l[2]) + "\n").join(""));
  const keep = lines.filter((l) => l[0] === "keep");
  if (dry) process.exit(keep.length ? 3 : 0);
  const list = keep.map((l) => "  " + escapePath(l[2]) + "  (" + l[1] + ")").join("\n");
  if (keep.length && !force) { err("Kit files edited here, or not the kit's, so nothing was changed:\n" + list); process.exit(3); }
  if (keep.length) {
    // A path under a linked folder is never written, --force or not: the rename would land outside.
    const out = writes.filter((x) => x.why && x.linked);
    if (out.length) die("cabinet: under a linked folder, so never written, and nothing was changed:\n" + out.map((x) => "  " + escapePath(x.dst)).join("\n"), 1);
    const a = askForce(list, "Kit files edited here, or not the kit's, and with --force they are replaced:");
    if (a !== 0) process.exit(a);
    for (const x of writes) if (x.why) w.next.set(x.dst, x.want);
  }
  const say = [];
  const swap = (abs, fill, mode) => { const t = abs + ".cabinet-new"; fs.rmSync(t, { force: true, recursive: true }); fill(t); fs.chmodSync(t, mode); fs.renameSync(t, abs); };
  try {
    for (const x of writes) {
      if (x.rm) fs.rmSync(x.rm, { recursive: true, force: true });
      fs.mkdirSync(path.dirname(x.abs), { recursive: true });
      const k = path.join(w.kit, x.src), m = fs.statSync(k).mode & 0o777;
      swap(x.abs, (t) => fs.copyFileSync(k, t), m | (x.dst.startsWith("bin/") && x.dst.endsWith(".sh") ? 0o111 : 0));
      if (x.verb === "updated" || hadManifest) say.push("  " + x.verb + " " + escapePath(x.dst));
    }
    for (const p of removes) { fs.rmSync(path.join(w.ws, p), { force: true }); say.push("  removed " + escapePath(p) + " (no longer in the kit)"); }
    fs.mkdirSync(path.dirname(w.man), { recursive: true });
    const body = [...w.next].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)).map(([p, h]) => h + " " + p + "\n").join("");
    swap(w.man, (t) => fs.writeFileSync(t, body), 0o644);
  } catch (e) { die("cabinet: could not write the kit files: " + escapePath(String(e.message || e)) + "; half updated: run cabinet update again", 1); }
  for (const s of [...say, ...notes]) err(s);
  process.exit(0);
}

// delete-plan <source> ... [--force] [--dry-run]: the one check before a command deletes or overwrites
// (kit rule 5; ADR-009). It lists everything the command would lose, decides, and says why.
//   folder <dir> [--repos <repos.tsv>]: what deleting <dir> loses (session end, remove). The helper
//   never deletes here: the caller deletes the folder only on exit 0.
//   incoming <target> [--git <repo> <base> <tree>] [--from <dir>] --keep <dir>, one group per folder,
//   repeated in one call (restore): every path in <target> the restore would replace or delete. The
//   helper acts here: it moves each to its --keep (restore picks a folder that does not exist), or with
//   --force deletes it, before the caller writes anything.
//   kit <ws> <kit> <format>: every kit file update or setup would add, replace or remove (kitPlan above).
//   The helper acts here: it writes them, then the manifest. kit <ws> - --dry-run: the doctor's form.
// stdout: one line per path, "<verdict>\t<why>\t<path>", verdict ok or keep, the path relative to the
// source's root (a folder with a trailing /, the root itself ./), escaped so no name can split a line;
// ok lines only with --dry-run. For display and tests: no caller reads a path back. stderr: the one
// message, every name escaped. Exit 0 go ahead, 3 refused (something kept, nothing changed), 1 could
// not decide (or --force with no terminal, or in a scheduled run), 2 usage.
// ponytail: names are read as UTF-8; a name that is not valid UTF-8 is kept (never deleted) but may
// show changed, and a repo inside a folder so named is not found. Read names as buffers if that matters.
// why, a closed set (stable; the tests use it): uncommitted, unpushed (commits on no remote), stash,
// ignored, no-git (in no repo), edited, not-kit, differs, file-in-way, folder-in-way.
// The files the kit writes untracked in a workspace, rebuildable there: manual.sh, session.sh, the
// pin's install, and this machine's settings (bootstrap.sh, config --this-machine).
const KIT_UNTRACKED = ["BRIEF.md", "PIPELINE.md", "OPERATIONS.html", "sessions/.gitignore", "node_modules/", "cabinet.local.env"];
// A path as one field of one line: \\, \t, \n, \r and \xNN for every other control byte (C1 included).
const escapePath = (s) => s.replace(/[\\\x00-\x1f\x7f\u0080-\u009f]/g, (c) =>
  ({ "\\": "\\\\", "\t": "\\t", "\n": "\\n", "\r": "\\r" })[c] || "\\x" + c.charCodeAt(0).toString(16).padStart(2, "0"));
const isEnvName = (n) => n.startsWith(".env") && !n.endsWith(".example");
const scheduled = () => !!(env("CABINET_AGENT") || env("CABINET_JOB"));

// The "## Safe to delete" section of <file>: { paths, unread }. Read as session.sh reads "## Session
// setup": from the heading to the next "## ". An entry is "- `<path>`"; one that is absolute, holds ..
// or a wildcard is not read.
function safeList(file) {
  let text = "";
  try { text = read(file); } catch (e) { return { paths: [], unread: [] }; }
  const paths = [], unread = [];
  let on = false;
  for (const l of text.split("\n")) {
    if (l.startsWith("## ")) { on = /^## Safe to delete\s*$/.test(l); continue; }
    const m = on && /^\s*[-*]\s+`([^`]+)`\s*$/.exec(l);
    if (!m) continue;
    const p = m[1];
    if (p.startsWith("/") || p.startsWith("~") || p.split("/").includes("..") || /[*?[]/.test(p)) unread.push(p);
    else paths.push(p.replace(/^(\.\/)+/, ""));
  }
  return { paths, unread };
}

function deletePlan(...argv) {
  const usage = "usage: node lib.js delete-plan folder <dir> [--repos <repos.tsv>] [--force] [--dry-run]\n" +
    "       node lib.js delete-plan incoming <target> [--git <repo> <base> <tree>] [--from <dir>] --keep <dir> [incoming ...] [--force] [--dry-run]\n" +
    "       node lib.js delete-plan kit <ws> <kit> <format> [--force] [--dry-run] | kit <ws> - --dry-run";
  const [source, ...rest] = argv;
  let force = false, dry = false, reposTsv = "";
  const pos = [], groups = [];
  if (source === "incoming") rest.unshift("incoming");
  for (let i = 0; i < rest.length; i++) {
    const g = groups[groups.length - 1], more = (n) => { if (i + n >= rest.length) die(usage, 2); };
    if (rest[i] === "--force") force = true;
    else if (rest[i] === "--dry-run") dry = true;
    else if (source === "folder" && rest[i] === "--repos" && i + 1 < rest.length) reposTsv = rest[++i];
    else if (source === "incoming" && rest[i] === "incoming") { more(1); groups.push({ target: rest[++i], git: null, from: "", keep: "" }); }
    else if (g && rest[i] === "--git") { more(3); g.git = rest.slice(i + 1, i + 4); i += 3; }
    else if (g && rest[i] === "--from") { more(1); g.from = rest[++i]; }
    else if (g && rest[i] === "--keep") { more(1); g.keep = rest[++i]; }
    else if (rest[i].startsWith("--") || (source !== "folder" && source !== "kit")) die(usage, 2);
    else pos.push(rest[i]);
  }
  if (source === "incoming") {
    if (!groups.every((g) => g.keep && (g.git || g.from))) die(usage, 2);
    return incoming(groups, force, dry);
  }
  if (source === "kit") {
    if (pos[1] === "-" ? pos.length !== 2 || !dry : pos.length !== 3 || !/^[0-9]+$/.test(pos[2])) die(usage, 2);
    return kitPlan(pos[0], pos[1], pos[2], force, dry);
  }
  if (source !== "folder" || pos.length !== 1) die(usage, 2);
  let root;
  try { root = fs.realpathSync(pos[0]); if (!fs.statSync(root).isDirectory()) throw new Error(); } catch (e) { die("delete-plan: not a folder: " + escapePath(pos[0]), 1); }
  const lines = [], unread = [];
  try { folderPlan(root, reposTsv, lines, unread); } catch (e) { die("delete-plan: could not check " + escapePath(root) + ": " + escapePath(String(e.message || e)) + "; nothing was changed", 1); }
  decide(lines, unread, force, dry);
}

// git in <dir>: its output, or null when git fails; gitZ splits -z output into fields. <dir> can be a
// repo found inside the folder, whose own config anyone could have written: the -c options (which
// reach every git it starts) stop that config running a program, and no optional lock writes its index.
// Its own filters never run either: check() skips git status in such a repo (ownFilter).
const gitRun = (dir, a) => spawnSync("git", ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "log.showSignature=false",
  "-c", "core.hooksPath=/dev/null", "-C", dir, ...a], { encoding: "utf8", maxBuffer: 1024 * 1024 * 1024 });
const gitOut = (dir, ...a) => { const r = gitRun(dir, a); return r.status === 0 ? r.stdout.trim() : null; };
const gitZ = (dir, ...a) => { const r = gitRun(dir, a); return r.status === 0 ? r.stdout.split("\0").filter((x) => x !== "") : null; };
const lst = (p) => { try { return fs.lstatSync(p); } catch (e) { return null; } };
const isRepoDir = (p) => !!lst(path.join(p, ".git"));

// The folder source (ADR-009 section 2, with Decisions 8 B, 9 B and 10 A).
function folderPlan(root, reposTsv, lines, unread) {
  // Repos repos.tsv lists, resolved as bin/cabinet's hard_dirs does: column 5, else 1; / as is, ~/ under
  // HOME, else under the workspace (the folder of repos.tsv). Only compared, never run.
  const listed = new Set();
  if (reposTsv) {
    const ws = path.dirname(path.resolve(reposTsv));
    let t = "";
    try { t = read(reposTsv); } catch (e) { /* none */ }
    for (const l of t.split("\n")) {
      if (!l.trim() || l.startsWith("#")) continue;
      const c = l.split("\t");
      let p = c[4] || c[0];
      if (p.startsWith("~/")) p = path.join(env("HOME"), p.slice(2));
      try { listed.add(fs.realpathSync(path.resolve(ws, p))); } catch (e) { /* not on this machine */ }
    }
  }
  // A listed repo, or a linked worktree (a session) of one: its common git folder is that repo's .git.
  const isListed = (abs) => {
    if (listed.has(abs)) return true;
    const c = gitOut(abs, "rev-parse", "--git-common-dir");
    if (!c) return false;
    try { return listed.has(fs.realpathSync(path.dirname(path.resolve(abs, c)))); } catch (e) { return false; }
  };
  const emit = (verdict, why, rel) => lines.push([verdict, why, rel]);
  check(root, "", true);

  // Does the repo at <abs> define a filter in its own config (local or worktree, its includes too)? git
  // status would run it on a file whose stat changed. Reading config runs nothing; a failed read is a yes.
  function ownFilter(abs) {
    const r = gitRun(abs, ["config", "--show-scope", "-z", "--get-regexp", "^filter\\."]);
    if (r.status === 1 && !r.stderr) return false;   // no filter anywhere
    if (r.status !== 0) return true;
    const f = r.stdout.split("\0");
    for (let i = 0; i + 1 < f.length; i += 2) if (f[i] === "local" || f[i] === "worktree") return true;
    return false;
  }

  // check <abs> <prefix> <isRoot> <found>: the lines deleting <abs> loses, each path <prefix> + its path
  // under <abs>. <found>: a repo found inside, neither the folder itself nor one repos.tsv lists.
  function check(abs, prefix, isRoot, found) {
    const here = (p) => (p === "./" ? prefix || "./" : prefix + p);
    const toplevel = gitOut(abs, "rev-parse", "--show-toplevel");
    const repoTop = toplevel ? fs.realpathSync(toplevel) : "";
    const dotGit = lst(path.join(abs, ".git"));
    // A repo with its own history: its git folder is its common one (a main checkout, a submodule); a
    // linked worktree's history is its main repo's. Which AGENTS.md names what is safe: a linked
    // worktree's main checkout's, so a session cannot widen its own list; else the folder's own.
    let main = abs, own = false;
    if (repoTop === abs && dotGit) {
      const g = (gitOut(abs, "rev-parse", "--absolute-git-dir", "--git-common-dir") || "").split("\n");
      const [gd, cd] = g.map((x) => { try { return fs.realpathSync(path.resolve(abs, x)); } catch (e) { return ""; } });
      own = !!gd && gd === cd;
      if (!own && cd) main = path.dirname(cd);
    }
    const sl = safeList(path.join(main, "AGENTS.md"));
    for (const u of sl.unread) unread.push([path.join(main, "AGENTS.md"), u]);
    const safe = sl.paths.slice();
    if (isRoot && lst(path.join(abs, ".cabinet", "version"))) safe.push(...KIT_UNTRACKED);   // a workspace
    // An entry names <p> exactly, or a folder entry covers it (never a repo or a .env: Decision 8 B).
    const exact = (p) => safe.some((s) => s === p || (p.endsWith("/") && s + "/" === p));
    const covered = (p, exactOnly) => exact(p) || (!exactOnly && safe.some((s) => s.endsWith("/") && p.startsWith(s)));
    const safeBelow = (d) => safe.some((s) => s.startsWith(d) && s !== d);   // d ends with /

    if (!repoTop) { walk("", "no-git"); return; }
    if (own) {   // HEAD too: a submodule's commits are on no branch
      if (gitOut(abs, "log", "--ignore-missing", "--branches", "HEAD", "--not", "--remotes", "--format=%h", "-1")) emit("keep", "unpushed", here("./"));
      if (gitOut(abs, "stash", "list")) emit("keep", "stash", here("./"));
    }
    // A submodule checked out under <abs> is a repo inside it (git's paths here are <abs>'s own).
    const ls = gitZ(abs, "ls-files", "-s", "-z", "--", ".");
    if (ls === null) throw new Error("git ls-files failed");
    const subs = new Set();
    for (const l of ls) {
      const t = l.indexOf("\t"), p = l.slice(t + 1), s = lst(path.join(abs, p));
      if (l.startsWith("160000 ") && s && s.isDirectory() && isRepoDir(path.join(abs, p))) subs.add(p);
    }
    for (const p of subs) repo(p);
    // Uncommitted: git status, whose paths are the repo's; only those under <abs> count (a shared
    // cabinet/ inside a project: never the project's other work). The options win over the person's
    // config, which could hide untracked files or a submodule's new commit. A submodule's own changes are
    // its repo() check's, so status never runs inside it (dirty). A found repo with its own filter is not
    // asked at all: it is kept as uncommitted.
    const under = repoTop === abs ? "" : path.relative(repoTop, abs) + "/";
    const skip = found && ownFilter(abs);
    if (skip) emit("keep", "uncommitted", here("./"));
    const st = skip ? [] : gitZ(abs, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=dirty", "--", ".");
    if (st === null) throw new Error("git status failed");
    for (let i = 0; i < st.length; i++) {
      const code = st[i].slice(0, 2), p = st[i].slice(3);
      if (code[0] === "R" || code[0] === "C") i++;   // the next field is the old name
      if (p.startsWith(under)) { if (!subs.has(p.slice(under.length))) emit("keep", "uncommitted", here(p.slice(under.length) || "./")); }
      else if (under.startsWith(p)) emit("keep", "uncommitted", here("./"));   // <abs> is inside an untracked folder
    }
    // A file marked skip-worktree or assume-unchanged hides its edits from status: kept while it is there.
    const tags = gitZ(abs, "ls-files", "-v", "-z", "--", ".");
    if (tags === null) throw new Error("git ls-files failed");
    for (const l of tags) {
      const p = l.slice(2);
      if ((l[0] === "S" || /[a-z]/.test(l[0])) && !subs.has(p) && lst(path.join(abs, p))) emit("keep", "uncommitted", here(p));
    }
    // Ignored: git's collapsed list, each entry walked (lstat only) for repos, .env files and safe entries.
    const ig = gitZ(abs, "ls-files", "-o", "-i", "--exclude-standard", "--directory", "-z");
    if (ig === null) throw new Error("git ls-files failed");
    // With --directory, git also names a folder that is not ignored but holds only ignored files, beside
    // those files (config/ and config/master.key): such a folder is left to its parts.
    for (const p of ig) if (!(p.endsWith("/") && ig.some((q) => q !== p && q.startsWith(p)))) entry(p.replace(/\/$/, ""), "ignored");

    // walk <rel> <why>: every entry of the folder <rel> ("" for <abs>), .git left out.
    function walk(rel, why) {
      let names = [];
      try { names = fs.readdirSync(path.join(abs, rel)); } catch (e) { return; }
      for (const n of names.sort()) if (n !== ".git") entry(rel ? rel + "/" + n : n, why);
    }
    // entry <rel> <why>: one path git does not track, and everything in it. A folder is named alone
    // when nothing in it needs a line of its own: a repo, a safe entry below it, and in a safe folder a
    // .env file (kept unless named exactly).
    function entry(rel, why) {
      const p = path.join(abs, rel);
      if (path.relative(abs, p).split(path.sep)[0] === "..") throw new Error("a path outside the folder: " + rel);
      const s = lst(p);
      if (s && s.isDirectory()) {
        if (isRepoDir(p)) return repo(rel);
        const d = rel + "/";
        if (covered(d)) { if (!hasInside(p, true)) return emit("ok", "", here(d)); }
        else if (!safeBelow(d) && !hasInside(p, false)) return emit("keep", why, here(d));
        return walk(rel, why);
      }
      emit(covered(rel, isEnvName(path.basename(rel))) ? "ok" : "keep", covered(rel, isEnvName(path.basename(rel))) ? "" : why, here(rel));
    }
    // A repo found inside: ok when an entry names it exactly; its own check when it is a repo
    // repos.tsv lists or a session of one (remove only); else kept whole, with the first word its own
    // check finds in the order unpushed, stash, uncommitted, else ignored (Decisions 8 B, 9 B, 10 A).
    function repo(rel) {
      const d = rel + "/", real = fs.realpathSync(path.join(abs, rel));
      if (exact(d)) return emit("ok", "", here(d));
      if (listed.size && isListed(real)) return check(real, here(d), false);
      const at = lines.length, un = unread.length;
      check(real, here(d), false, true);
      const sub = lines.splice(at);
      unread.splice(un);
      const w = ["unpushed", "stash", "uncommitted"].find((o) => sub.some((x) => x[0] === "keep" && x[1] === o)) || "ignored";
      emit("keep", w, here(d));
    }
  }
}
// Does the folder hold a repo (or, with envs, a .env file) anywhere under it? lstat only, links never followed.
function hasInside(dir, envs) {
  let names = [];
  try { names = fs.readdirSync(dir); } catch (e) { return false; }
  for (const n of names) {
    const p = path.join(dir, n), s = lst(p);
    if (!s) continue;
    if (n === ".git" || (envs && isEnvName(n) && !s.isDirectory())) return true;
    if (s.isDirectory() && hasInside(p, envs)) return true;
  }
  return false;
}

// The policy (ADR-009 section 1): print, then go ahead, refuse, or ask the one --force question.
// Written with writeSync, since process.exit can cut an asynchronous pipe write short.
const put = (fd, s) => { try { fs.writeSync(fd, s); } catch (e) { /* a closed pipe */ } };
const err = (s) => put(2, s + "\n");
function decide(lines, unread, force, dry) {
  put(1, lines.filter((l) => dry || l[0] === "keep").map((l) => l[0] + "\t" + l[1] + "\t" + escapePath(l[2]) + "\n").join(""));
  for (const [f, u] of unread) err("not read: `" + escapePath(u) + "` in the \"## Safe to delete\" section of " + escapePath(f) + " (an absolute path, .. or a wildcard): name each path exactly, relative to the repo");
  const keep = lines.filter((l) => l[0] === "keep");
  if (!keep.length) process.exit(0);
  const list = keep.map((l) => "  " + escapePath(l[2]) + "  (" + l[1] + ")").join("\n");
  if (dry || !force) {
    err("Not safe to delete, so nothing was changed:\n" + list + "\nKeep what you need somewhere else, or name what can be rebuilt in a \"## Safe to delete\" section of the repo's AGENTS.md, then run it again. To delete them anyway, run it again yourself with --force, at a terminal.");
    process.exit(3);
  }
  process.exit(askForce(list, "Not safe to delete, and found nowhere else:"));
}

// The one --force question (Rule 9): asked of a person at /dev/tty only, never in a scheduled run.
// 0 when yes is typed; 1 when it cannot be asked; 3 for any other answer. Nothing is changed here.
function askForce(list, header) {
  if (scheduled()) { err("--force is never used in a scheduled run, so nothing was changed. Not safe to delete:\n" + list); return 1; }
  let fd;
  try { fd = fs.openSync("/dev/tty", "r+"); } catch (e) {
    err("--force asks a person at a terminal, and there is no terminal here, so nothing was changed. Not safe to delete:\n" + list + "\nRun the command yourself, in a terminal.");
    return 1;
  }
  put(fd, header + "\n" + list + "\nType yes to delete them: ");
  const buf = Buffer.alloc(256);
  let answer = "";
  for (;;) {
    let n = 0;
    try { n = fs.readSync(fd, buf, 0, buf.length, null); } catch (e) {
      if (e.code === "EAGAIN") { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50); continue; }
      break;
    }
    if (n <= 0) break;
    answer += buf.toString("utf8", 0, n);
    if (answer.includes("\n") || answer.length > 64) break;
  }
  fs.closeSync(fd);
  if (answer.split("\n")[0].replace(/\r$/, "").trim() === "yes") return 0;
  err("Not yes, so nothing was changed.");
  return 3;
}

// The incoming source (ADR-009 section 3, ADR-010 C3 and C4): for each group, every path in <target> the
// restore would replace or delete, all planned before the first move. Per incoming path p, parents first:
// a parent that is a file or link in <target> is file-in-way; p a folder or link where a file goes is
// folder-in-way; a file with other bytes, or a link to another target, differs (by git blob id with --git,
// computed here, so nothing is checked out to compare). A submodule (mode 160000) expects a folder and is
// never walked. With --git, each path <base> has and <tree> does not that exists in <target> differs too.
// Anything inside a path already listed goes with it. Exit 1, nothing moved: an incoming path at or under
// --keep, --keep under a listed path, a destination that exists, or a name that is absolute or holds ..
function incoming(groups, force, dry) {
  const lines = [], moves = [];
  try {
    for (const g of groups) planIncoming(g, groups[0], lines, moves);
  } catch (e) { die("delete-plan: " + escapePath(String(e.message || e)) + "; nothing was changed", 1); }
  put(1, lines.map((l) => l[0] + "\t" + l[1] + "\t" + escapePath(l[2]) + "\n").join(""));
  if (!moves.length || dry) process.exit(0);
  const list = moves.map((m) => "  " + escapePath(m.show) + "  (" + m.why + ")").join("\n");
  if (force) {
    const a = askForce(list, "The archive replaces or deletes these, and with --force they are not kept:");
    if (a !== 0) process.exit(a);
  }
  const done = [];
  try {
    for (const m of moves) {
      if (force) fs.rmSync(m.abs, { recursive: true, force: true });
      else { fs.mkdirSync(path.dirname(m.dest), { recursive: true }); moveAside(m.abs, m.dest); }
      done.push(m);
    }
  } catch (e) {
    die("delete-plan: could not " + (force ? "delete " : "move aside ") + escapePath(String(e.message || e)) + "; done before it: " +
      (done.map((m) => escapePath(m.show)).join(", ") || "nothing"), 1);
  }
  if (force) { err("Deleted, as you confirmed:\n" + list); process.exit(0); }
  for (const g of groups) {
    const mine = moves.filter((m) => m.g === g);
    if (mine.length) err("  " + mine.length + " path(s) in the way of the archive, kept aside in " + escapePath(g.keep) + ":\n" +
      mine.map((m) => "    " + escapePath(m.rel) + "  (" + m.why + ")").join("\n"));
  }
  process.exit(0);
}

// A folder that does not exist yet, as it will be: its deepest existing parent resolved, the rest as given.
function resolveMissing(p) {
  p = path.resolve(p);
  const rest = [];
  for (;;) {
    try { return path.join(fs.realpathSync(p), ...rest.reverse()); } catch (e) {
      if (path.dirname(p) === p) throw e;
      rest.push(path.basename(p)); p = path.dirname(p);
    }
  }
}

function planIncoming(g, first, lines, moves) {
  let target;
  try { target = fs.realpathSync(g.target); if (!fs.statSync(target).isDirectory()) throw new Error(); } catch (e) { throw new Error("not a folder: " + g.target); }
  g.keep = resolveMissing(g.keep);
  const within = (a, b) => a === b || a.startsWith(b + path.sep);
  const show = (abs) => within(abs, first.realTarget || (first.realTarget = target)) ? path.relative(first.realTarget, abs) || "./" : abs;
  const ents = new Map(), add = (rel, e) => {
    if (path.isAbsolute(rel) || rel.split("/").some((c) => c === ".." || c === "." || c === "")) throw new Error("a path outside its folder: " + rel);
    if (!ents.has(rel)) ents.set(rel, []);
    ents.get(rel).push(e);
    const parts = rel.split("/");
    for (let i = 1; i < parts.length; i++) { const d = parts.slice(0, i).join("/"); if (!ents.has(d)) ents.set(d, []); if (!ents.get(d).some((x) => x.kind === "dir")) ents.get(d).push({ kind: "dir" }); }
  };
  if (g.git) {
    const [repo, base, tree] = g.git;
    const ls = gitZ(repo, "ls-tree", "-r", "-z", "--full-tree", tree), del = gitZ(repo, "diff", "--no-renames", "--name-only", "--diff-filter=D", "-z", base, tree);
    if (!ls || !del) throw new Error("could not read the archive's tree in " + repo);
    for (const e of ls) {
      const tab = e.indexOf("\t"), [mode, , sha] = e.slice(0, tab).split(" ");
      add(e.slice(tab + 1), { kind: mode === "160000" ? "gitlink" : mode === "120000" ? "link" : "file", sha });
    }
    for (const rel of del) add(rel, { kind: "del" });
  }
  if (g.from) {
    (function walk(d, rel) {
      for (const n of fs.readdirSync(d).sort()) {
        const p = path.join(d, n), r = rel ? rel + "/" + n : n, s = fs.lstatSync(p);
        if (s.isSymbolicLink()) add(r, { kind: "link", to: fs.readlinkSync(p) });
        else if (s.isDirectory()) { add(r, { kind: "dir" }); walk(p, r); }
        else add(r, { kind: "file", src: p, size: s.size });
      }
    })(g.from, "");
  }
  const blob = (sha, bytes) => crypto.createHash(sha.length === 64 ? "sha256" : "sha1").update("blob " + bytes.length + "\0").update(bytes).digest("hex");
  const listed = new Set();
  const rels = [...ents.keys()].sort((a, b) => a.split("/").length - b.split("/").length || (a < b ? -1 : 1));
  for (const rel of rels) {
    const abs = path.join(target, rel);
    if (within(abs, g.keep)) throw new Error("an incoming path is inside the keep folder: " + abs);
    const parts = rel.split("/");
    if (parts.some((_, i) => listed.has(parts.slice(0, i).join("/")))) continue;   // goes aside with its parent
    const st = lst(abs);
    if (!st) continue;
    let why = "";
    for (const e of ents.get(rel)) {
      if (why) break;
      if (e.kind === "dir" || e.kind === "gitlink") { if (!st.isDirectory()) why = "file-in-way"; }
      else if (e.kind === "link") {
        const same = st.isSymbolicLink() && (e.sha ? blob(e.sha, Buffer.from(fs.readlinkSync(abs))) === e.sha : fs.readlinkSync(abs) === e.to);
        if (!same) why = "differs";
      } else if (st.isDirectory() || st.isSymbolicLink()) why = "folder-in-way";
      else if (e.kind === "del") why = "differs";
      else if (e.sha ? blob(e.sha, fs.readFileSync(abs)) !== e.sha : st.size !== e.size || !fs.readFileSync(abs).equals(fs.readFileSync(e.src))) why = "differs";
    }
    if (!why) continue;
    listed.add(rel);
    const dest = path.join(g.keep, rel);
    if (within(g.keep, abs)) throw new Error("the keep folder is inside a path the archive replaces: " + abs);
    if (lst(dest)) throw new Error("already exists, never written over: " + dest);
    for (let d = path.dirname(dest); ; d = path.dirname(d)) { const s = lst(d); if (s) { if (!s.isDirectory()) throw new Error("not a folder: " + d); break; } }
    const shown = show(abs) + (st.isDirectory() ? "/" : "");
    lines.push(["keep", why, shown]);
    moves.push({ g, abs, rel, dest, why, show: shown });
  }
}

// Move a path aside: a rename, or across devices a copy (modes, links as links) and then a delete.
function moveAside(from, to) {
  try { fs.renameSync(from, to); return; } catch (e) { if (e.code !== "EXDEV") throw e; }
  (function copy(a, b) {
    const s = fs.lstatSync(a);
    if (s.isSymbolicLink()) fs.symlinkSync(fs.readlinkSync(a), b);
    else if (s.isDirectory()) { fs.mkdirSync(b); for (const n of fs.readdirSync(a)) copy(path.join(a, n), path.join(b, n)); fs.chmodSync(b, s.mode & 0o7777); }
    else { fs.copyFileSync(a, b); fs.chmodSync(b, s.mode & 0o7777); fs.utimesSync(b, s.atime, s.mtime); }
  })(from, to);
  fs.rmSync(from, { recursive: true, force: true });
}

const COMMANDS = {
  "delete-plan": deletePlan,
  "kit-map": kitMap,
  "rules-missing": rulesMissingCmd, "rules-add": rulesAdd, "verdict-origin": verdictOrigin,
  "hard-write": hardWrite, "handoff-entry": handoffEntry, "handoff-archive": handoffArchive, "handoff-rows": handoffRows, "owner-case": (to) => process.stdout.write(ownerCase(to || "") + "\n"), readiness,
  "spec-check": specCheck, "spec-record": specRecord, manual,
  sub, "sub-all": subAll, has, drop, "drop-text": dropText, "drop-line": dropLine, before, after, "replace-line": replaceLine,
  "after-last": afterLast, "credit-line": creditLine, "fill-template": fillTemplate, slug, watchdog, "run-limited": runLimited, "secret-scan": secretScan, json,
  closest, "changelog-render": changelogRender, "push-check": pushCheck, "model-check": modelCheck,
  "version-newer": versionNewer, "latest-write": latestWrite, "release-latest": releaseLatest, "version-check": versionCheck, "week-start": weekStart,
};
const [cmd, ...args] = process.argv.slice(2);
if (!COMMANDS[cmd]) die("usage: node lib.js " + Object.keys(COMMANDS).join("|") + " <args>...", 2);
COMMANDS[cmd](...args);
