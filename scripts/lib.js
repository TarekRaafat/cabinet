// The workspace scripts' shared JavaScript, run with node (AGENTS.md, rule 3): what bash does badly,
// such as parsing Markdown and building a page. Only Node's own modules, so Bun can compile it later.
//
//   node lib.js <command> <args>...    (the scripts call it through js() in lib.sh)
//
// Commands: hard-write, handoff-entry, handoff-archive, readiness, spec-check, spec-record, manual.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");

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

// handoff-entry <HANDOFFS.md> <ID> info|evidence <links>|verdict <role> <line>: read or change one
// open entry in place. info prints "<sender>\t<1 when it has evidence>\t<small>\t<addressee>".
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
    process.stdout.write(sender + "\t" + (body.some(hasEv) ? "1" : "") + "\t" + small + "\t" + to + "\n");
    return;
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
    out[e.id] = {
      areas, archived: e.archived, depends_on: field(e, "- Depends on:"), status_now: st ? st.split(" ")[0] : "",
      small: e.lines.some((l) => l.trim() === "- Size: small"), spec: field(e, "- Spec:"),
      cost_usd: e.id in cost ? Math.round(cost[e.id] * 1e6) / 1e6 : null, verdicts: vs, needs, missing, blocking, stale,
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
    const known = new Set(words(env("AREAS")));
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

// ---- Editing files line by line (what perl -i -pe did) ----------------------------------------
// A pattern is "/source/flags". In the source, ${NAME} is the environment variable NAME as literal
// text (perl's \Q$ENV{NAME}\E). In a replacement, $1..$9 are the groups, ${NAME} is the variable's
// value as it is, and $$ is a $. Each rule applies to each line without its newline, so ^ and $ are
// the line's start and end.
// Like perl, the edits work on bytes (latin1 text, one character per byte), so nothing in a file is
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
function replaceFile(file, text) {  // with the file's own permissions, as perl -i kept them
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
// sub-all <file> </pattern/flags> <replacement>: replace in the whole text at once (perl -0777).
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
// watchdog <seconds> <pid>: after the seconds, TERM the process group of <pid>, then KILL it 10
// seconds later. Stopping this process stops the watch.
function watchdog(secs, pid) {
  const group = -Number(pid);
  setTimeout(() => {
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
// Like perl's -B: the first 512 bytes hold a NUL, or (when they are not UTF-8 with non-ASCII in
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

const COMMANDS = {
  "hard-write": hardWrite, "handoff-entry": handoffEntry, "handoff-archive": handoffArchive, readiness,
  "spec-check": specCheck, "spec-record": specRecord, manual,
  sub, "sub-all": subAll, has, drop, "drop-text": dropText, "drop-line": dropLine, before, after, "replace-line": replaceLine,
  "after-last": afterLast, "fill-template": fillTemplate, slug, watchdog, "run-limited": runLimited, "secret-scan": secretScan,
};
const [cmd, ...args] = process.argv.slice(2);
if (!COMMANDS[cmd]) die("usage: node lib.js " + Object.keys(COMMANDS).join("|") + " <args>...", 2);
COMMANDS[cmd](...args);
