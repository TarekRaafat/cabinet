// The workspace scripts' shared JavaScript, run with node (AGENTS.md, rule 3): what bash does badly,
// such as parsing Markdown and building a page. Only Node's own modules, so Bun can compile it later.
//
//   node lib.js <command> <args>...    (the scripts call it through js() in lib.sh)
//
// Commands: hard-write, handoff-entry, handoff-archive, readiness, push-check, model-check, version-newer, release-latest, version-check, latest-write, spec-check, spec-record, manual, json, changelog-render, and the line edits and helpers below.
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

// handoff-entry <HANDOFFS.md> <ID> info|evidence <links>|verdict <role> <line>|wayback <text>: read or
// change one open entry in place. info prints "<sender>\t<1 when it has evidence>\t<small>\t<1 when it
// has a way back>\t<addressee>".
// Exit 3 when the entry is not under "## Open".
function handoffEntry(file, hid, mode, ...args) {
  const lines = read(file).split("\n");
  const open = lines.indexOf("## Open");
  if (open < 0) die("", 3);
  let start = -1;
  for (let i = open + 1; i < lines.length; i++) {
    if (lines[i].startsWith("## ")) break;
    if (lines[i].startsWith("### " + hid + ":")) { start = i; break; }
  }
  if (start < 0) die("", 3);
  let end = start + 1;
  while (end < lines.length && !lines[end].startsWith("### ") && !lines[end].startsWith("## ")) end++;
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
// ID's month; prints how many moved. HANDOFFS.md is left untouched when none did.
function handoffArchive(ws) {
  const file = path.join(ws, "HANDOFFS.md");
  const text = read(file);
  const at = text.indexOf("\n## Open\n");
  if (at < 0) die("no '## Open' heading in HANDOFFS.md");
  const head = text.slice(0, at), sep = "\n## Open\n";
  // Entries start at '### H-'; the old '## Archive' heading is dropped and its entries sorted like the rest.
  const parts = text.slice(at + sep.length).split("\n## Archive\n").join("\n").split(/\n(?=### H-)/);
  const preamble = parts[0], keep = [], moved = {};
  for (let e of parts.slice(1)) {
    e = e.replace(/^\n+|\n+$/g, "");
    const st = e.match(/^- Status: (\S+)/m);
    const m = e.match(/^### H-(\d{4})(\d{2})/);
    if (st && m && /^(done|rejected)\b/.test(st[1])) (moved[m[1] + "-" + m[2]] = moved[m[1] + "-" + m[2]] || []).push(e);
    else keep.push(e);
  }
  fs.mkdirSync(path.join(ws, "handoffs"), { recursive: true });
  for (const month of Object.keys(moved).sort()) {
    const p = path.join(ws, "handoffs", "archive-" + month + ".md");
    let add = fs.existsSync(p) ? "" : "# Closed handoffs, IDs from " + month + "\n\nMoved from HANDOFFS.md by bin/handoff.sh archive. Read only.\n";
    for (const e of moved[month]) add += "\n" + e.split("](specs/").join("](../specs/") + "\n";  // links now read from handoffs/
    fs.appendFileSync(p, add, "utf8");
  }
  const n = Object.values(moved).reduce((a, es) => a + es.length, 0);
  if (n) write(file, head + sep + preamble.replace(/\n+$/, "") + "\n\n" + keep.join("\n\n") + "\n");  // untouched otherwise
  process.stdout.write(n + "\n");
}

// readiness <spend file> <HANDOFFS.md> [<archive>...]: {"<ID>": {verdicts, needs, missing, blocking,
// stale, ready, ...}} for every entry, from the environment lib.sh's readiness() sets (WSDIR, TEAM,
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
  let cur = null;
  files.forEach((file, n) => {  // HANDOFFS.md, then the archives (closed work a run may still need)
    let on = n > 0;
    for (const l of read(file).split("\n")) {
      if (l.startsWith("## ")) { on = l.startsWith("## Open") || l.startsWith("## Archive"); cur = null; }
      else if (on && l.startsWith("### H-")) { cur = { id: words(l)[1].replace(/:+$/, ""), lines: [], archived: n > 0 }; entries.push(cur); }
      else if (cur) cur.lines.push(l);
    }
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
    const st = field(e, "- Status:");
    for (const l of e.lines) addBlock(e.id, l);
    const blocks = {};
    for (const l of blockLines[e.id] || []) { const r = l.match(VER)[1]; blocks[r] = (blocks[r] || 0) + 1; }
    out[e.id] = {
      areas, archived: e.archived, depends_on: field(e, "- Depends on:"), status_now: st ? st.split(" ")[0] : "",
      small: e.lines.some((l) => l.trim() === "- Size: small"), spec: field(e, "- Spec:"),
      cost_usd: e.id in cost ? Math.round(cost[e.id] * 1e6) / 1e6 : null, verdicts: vs, blocks, needs, missing, blocking, stale,
      ready: needs.length ? !missing.length && !blocking.length && !stale.length : null, unread_verdicts: unread,
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
  // The repos, those with no plan yet, and the architect's review of the plan as it is now.
  const planState = (text) => {
    const [fm, secs] = parse(text);
    const rs = repos(fm), parts = plan(sec(secs, "Plan")), a = verdicts(sec(secs, "Reviews")).architect;
    const review = !a ? "none" : a[0] !== "PASS" ? a[0] : a[1] === fingerprint(sec(secs, "Plan")) ? "PASS" : "changed";
    return { repos: rs, missing_plans: rs.filter((r) => !(parts[r] && parts[r].length)), plan_review: review };
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
      if (rs.length > 1) p.push(review("architect"));
    }
    return [status, p.filter(Boolean)];
  };
  return { parse, fingerprint, planState, problems };
}

// spec-check <workspace> <spec>...: [{spec, status, problems, repos, missing_plans, plan_review}].
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
// secret-scan [--staged]: "<file>:<line>: <kind>" for each likely secret. Reads, on stdin, the staged
// diff (--staged) or the NUL-separated list of files to scan. A line with not-a-secret is skipped.
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
      if ((m = l.match(/^\+\+\+ b\/(.*)$/))) { f = m[1].replace(/\t$/, ""); continue; }  // git ends a name with a space by a tab
      if ((m = l.match(/^@{2} -\S+ \+(\d+)/))) { n = Number(m[1]); continue; }  // a hunk header
      if (l.startsWith("+") && f !== null) { scan(f, n, l.slice(1).replace(/\t/g, " ")); n++; }
    }
  } else {
    for (const f of input.split("\0")) {
      if (!f) continue;
      let st, buf;
      try { st = fs.statSync(f); } catch (e) { continue; }
      if (!st.isFile() || st.size > 2000000) continue;
      try { buf = fs.readFileSync(f); } catch (e) { continue; }
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
  const helpers = { num, str, sum, list, obj };
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
// HANDOFFS what handoff list --json gives. Local refs only: no fetch, nothing written.
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
    for (const l of (git(p, "log", "--format=%H%x09%h%x09%s", "@{u}..HEAD") || "").split("\n").filter(Boolean)) {
      const [full, hash, ...s] = l.split("\t");
      const handoffs = hs.filter((e) => e.verdicts.some((v) => v.commits.some((c) => c.length >= 7 && full.startsWith(c)))).map((e) => e.id);
      o.commits.push({ hash, subject: s.join("\t"), handoffs });
    }
    const st = git(p, "diff", "--shortstat", "@{u}..HEAD") || "";
    for (const [k, re] of [["files", /(\d+) files? changed/], ["insertions", /(\d+) insertions?/], ["deletions", /(\d+) deletions?/]]) o[k] = Number((st.match(re) || [0, 0])[1]);
    if (!o.commits.length) return { ...o, why: "nothing to push" };
    for (const c of o.commits) {
      if (!c.handoffs.length) { o.why = c.hash + " is on no handoff"; break; }
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
// model-check <runner> <model>...: one line per model, "<state>\t<model>\t<list command>": ok or missing
// when the runner's list was read; unlisted when the runner cannot list its models without a run;
// failed when its list command did not run, failed or printed no model. The list is read once.
function modelCheck(runner, ...models) {
  const l = MODEL_LISTS[runner];
  const say = (st, how) => { for (const m of models) process.stdout.write(st + "\t" + m + "\t" + how + "\n"); };
  if (!l) return say("unlisted", "");
  const bin = runner === "cursor" ? cursorBin() || l[0] : l[0];
  const how = path.basename(bin) + " " + l[1].join(" ");
  const r = spawnSync(bin, l[1], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 30000, maxBuffer: 64 * 1024 * 1024 });
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

const COMMANDS = {
  "hard-write": hardWrite, "handoff-entry": handoffEntry, "handoff-archive": handoffArchive, readiness,
  "spec-check": specCheck, "spec-record": specRecord, manual,
  sub, "sub-all": subAll, has, drop, "drop-text": dropText, "drop-line": dropLine, before, after, "replace-line": replaceLine,
  "after-last": afterLast, "credit-line": creditLine, "fill-template": fillTemplate, slug, watchdog, "run-limited": runLimited, "secret-scan": secretScan, json,
  closest, "changelog-render": changelogRender, "push-check": pushCheck, "model-check": modelCheck,
  "version-newer": versionNewer, "latest-write": latestWrite, "release-latest": releaseLatest, "version-check": versionCheck,
};
const [cmd, ...args] = process.argv.slice(2);
if (!COMMANDS[cmd]) die("usage: node lib.js " + Object.keys(COMMANDS).join("|") + " <args>...", 2);
COMMANDS[cmd](...args);
