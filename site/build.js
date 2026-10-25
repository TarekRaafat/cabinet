#!/usr/bin/env node
// Builds the website from the repo's own files: node site/build.js <out> [--ref <git ref>]
// Docs pages from README.md and docs/, the changelog from CHANGELOG.md, the tour from roles/ and
// brand/demo/captured.js, colors and fonts from brand/tokens.json; the site's own wording is in
// site/copy.js. Node's own modules only. Every link and asset is under /cabinet/. Nothing it writes
// is shipped in the npm package; it never writes inside the repo's shipped paths or site/.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const copy = require("./copy.js");

const KIT = path.join(__dirname, "..");
const BASE = "/cabinet/";
const SITE = "https://tarekraafat.github.io/cabinet/";
const REPO = "https://github.com/TarekRaafat/cabinet";
const NPM = "https://www.npmjs.com/package/@tarekraafat/cabinet";

function die(msg) { process.stderr.write("site/build.js: " + msg + "\n"); process.exit(1); }
const read = (p) => fs.readFileSync(path.join(KIT, p), "utf8");
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const strip = (html) => html.replace(/<[^>]*>/g, "");
const fill = (s, ...v) => { let i = 0; return s.replace(/%s/g, () => v[i++]); };

// ---- Arguments and the output folder ----
const argv = process.argv.slice(2);
let outArg = "", ref = "";
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--ref") ref = argv[++i] || die("--ref needs a value");
  else if (argv[i].startsWith("-")) die("unknown option " + argv[i] + " (usage: node site/build.js <out> [--ref <git ref>])");
  else if (!outArg) outArg = argv[i];
  else die("one output folder only");
}
if (!outArg) die("usage: node site/build.js <out> [--ref <git ref>]");
const pkg = JSON.parse(read("package.json"));
const version = pkg.version;
ref = ref || "v" + version;
if (!/^[A-Za-z0-9._/-]+$/.test(ref)) die("--ref must be a git ref (letters, digits, . _ / -): " + ref);
const OUT = path.resolve(outArg);
// Compared with symlinks resolved (on macOS /var is /private/var), up to the part of the path that exists.
const real = (p) => { let tail = ""; while (!fs.existsSync(p)) { tail = path.join(path.basename(p), tail); p = path.dirname(p); } return path.join(fs.realpathSync(p), tail); };
const inKit = path.relative(fs.realpathSync(KIT), real(OUT));
if (!inKit.startsWith("..") && !path.isAbsolute(inKit)) {
  const top = inKit.split(path.sep)[0];
  if (!inKit || top === "site" || pkg.files.includes(top)) die("the output folder must not be the kit, site/ or a path the package ships: " + OUT);
}
const MARK = ".cabinet-site";
if (fs.existsSync(OUT)) {
  if (!fs.statSync(OUT).isDirectory()) die("not a folder: " + OUT);
  if (fs.readdirSync(OUT).length && !fs.existsSync(path.join(OUT, MARK))) die("the output folder holds files of its own; give an empty or new folder: " + OUT);
  fs.rmSync(OUT, { recursive: true });
}
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, MARK), "Written by site/build.js; rebuilt in place.\n");
const write = (rel, data) => { const f = path.join(OUT, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, data); };
const copyFile = (from, to) => { const f = path.join(OUT, to); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.copyFileSync(path.join(KIT, from), f); };

// ---- Sources ----
const tokens = JSON.parse(read("brand/tokens.json"));
const llms = read("llms.txt");
const llmsLinks = {};
for (const m of llms.matchAll(/^- \[([^\]]+)\]\(([^)]+)\): (.*)$/gm)) llmsLinks[m[2]] = { label: m[1], desc: m[3] };
const docFiles = fs.readdirSync(path.join(KIT, "docs")).filter((f) => f.endsWith(".md")).sort().map((f) => "docs/" + f);
const order = [...copy.docs.order, ...copy.docs.agents];
for (const f of docFiles) if (!order.includes(f)) die(`${f} has no place in the docs sidebar: add it to docs.order or docs.agents in site/copy.js`);
for (const f of order) if (f !== "README.md" && !docFiles.includes(f)) die(`site/copy.js lists ${f} in the docs sidebar, and there is no such doc`);
const capSrc = read("brand/demo/captured.js");
const CAP = JSON.parse(capSrc.slice(capSrc.indexOf("{"), capSrc.lastIndexOf("}") + 1));
for (const k of ["10-init", "03-roles", "08-handoff", "09-handoffs"]) if (!CAP[k]) die(`brand/demo/captured.js has no ${k} capture (brand/demo/capture.sh makes it)`);
const roles = {};
for (const f of fs.readdirSync(path.join(KIT, "roles")).filter((f) => f.endsWith(".md")).sort()) {
  const m = read("roles/" + f).match(/^---\n[\s\S]*?^description: (.*)$/m);
  if (m) roles[f.slice(0, -3)] = m[1].trim();
}

// ---- Markdown to HTML ----
// GitHub's heading anchors: lowercase, punctuation dropped, spaces to dashes; a repeat gets -1, -2.
function slugger() {
  const seen = {};
  return (text) => {
    const base = text.trim().toLowerCase().replace(/[^\p{L}\p{N}_\- ]/gu, "").replace(/ /g, "-");
    if (base in seen) return base + "-" + ++seen[base];
    seen[base] = 0; return base;
  };
}
function pageOf(target) {
  if (target === "README.md") return BASE + "docs/";
  if (docFiles.includes(target)) return BASE + "docs/" + path.posix.basename(target, ".md") + "/";
  if (target === "CHANGELOG.md") return BASE + "changelog/";
  return null;
}
function resolve(href, ctx) {
  // Only web and mail links leave the site; any other scheme (javascript:, data:, ...) stops the build.
  if (/^(https?|mailto):/i.test(href) || href.startsWith("#")) return href;
  if (/^[a-z][a-z0-9+.-]*:/i.test(href)) die(`${ctx.file} links ${href}: only https:, http:, mailto: and # links are allowed`);
  const hash = href.indexOf("#");
  const p = hash < 0 ? href : href.slice(0, hash), anchor = hash < 0 ? "" : href.slice(hash);
  const target = path.posix.normalize(path.posix.join(path.posix.dirname(ctx.file), p)).replace(/\/$/, "");
  return (pageOf(target) || `${REPO}/blob/${ref}/${target}`) + anchor;
}
function matchLink(s, i) {
  let depth = 0, j = i;
  for (; j < s.length; j++) {
    if (s[j] === "\\") { j++; continue; }
    if (s[j] === "`") { const e = s.indexOf("`", j + 1); if (e > 0) { j = e; continue; } }
    if (s[j] === "[") depth++;
    else if (s[j] === "]" && --depth === 0) break;
  }
  if (j >= s.length || s[j + 1] !== "(") return null;
  const close = s.indexOf(")", j + 2);
  if (close < 0 || /\s/.test(s.slice(j + 2, close))) return null;
  return { text: s.slice(i + 1, j), href: s.slice(j + 2, close), end: close + 1 };
}
function inline(s, ctx) {
  let out = "", i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === "\\" && /[\\`*_{}[\]()#+\-.!|<>]/.test(s[i + 1] || "")) { out += esc(s[i + 1]); i += 2; continue; }
    if (c === "`") {
      let n = 0; while (s[i + n] === "`") n++;
      let j = i + n, found = -1;
      while ((j = s.indexOf("`".repeat(n), j)) >= 0) {
        let k = 0; while (s[j + k] === "`") k++;
        if (k === n) { found = j; break; }
        j += k;
      }
      if (found < 0) { out += esc("`".repeat(n)); i += n; continue; }
      let code = s.slice(i + n, found);
      if (/^ .*[^ ].* $/.test(code)) code = code.slice(1, -1);
      out += "<code>" + esc(code) + "</code>"; i = found + n; continue;
    }
    if (c === "*" && s[i + 1] === "*") {
      const j = s.indexOf("**", i + 2);
      if (j > i + 2) { out += "<strong>" + inline(s.slice(i + 2, j), ctx) + "</strong>"; i = j + 2; continue; }
    }
    if (c === "[") {
      const m = matchLink(s, i);
      if (m) {
        out += ctx.noLinks ? inline(m.text, ctx) : `<a href="${esc(resolve(m.href, ctx))}">${inline(m.text, ctx)}</a>`;
        i = m.end; continue;
      }
    }
    out += esc(c); i++;
  }
  return out;
}
const RE = {
  fence: /^ {0,3}(`{3,}|~{3,})\s*([\w-]*)\s*$/, heading: /^(#{1,6})\s+(.*?)\s*#*\s*$/, list: /^( *)([-*+]|\d+[.)])( +)(.*)$/,
  quote: /^ {0,3}> ?/, table: /^ {0,3}\|/, sep: /^ {0,3}\|?\s*:?-{2,}/, hr: /^ {0,3}([-*_])( *\1){2,}\s*$/,
};
const startsBlock = (l) => RE.fence.test(l) || RE.heading.test(l) || RE.list.test(l) || RE.quote.test(l) || RE.table.test(l) || RE.hr.test(l);
const indentOf = (l) => l.match(/^ */)[0].length;
function codeBlock(text) {
  return `<div class="code" data-copy><pre tabindex="0"><code>${esc(text)}</code></pre><button type="button" class="copy" hidden>${copy.copyButton.copy}</button></div>`;
}
function splitRow(l) {
  const cells = []; let cur = "", code = false;
  const s = l.trim().replace(/^\|/, "").replace(/\|$/, "");
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "\\" && s[i + 1] === "|") { cur += "|"; i++; continue; } // GitHub unescapes \| in a cell, code included
    if (s[i] === "|") { cells.push(cur.trim()); cur = ""; continue; }
    cur += s[i];
  }
  cells.push(cur.trim());
  return cells;
}
function table(lines, ctx) {
  const head = splitRow(lines[0]), align = splitRow(lines[1]).map((c) => (/^:-+:$/.test(c) ? "center" : /-:$/.test(c) ? "right" : ""));
  // Code in a cell breaks only at its spaces: each word in a nowrap span (the copied text is the same).
  const words = (html) => html.replace(/<code>([^<]*)<\/code>/g, (m, code) => "<code>" + code.replace(/[^ ]+/g, '<span class="nw">$&</span>') + "</code>");
  const cell = (tag, c, i) => `<${tag}${align[i] ? ` style="text-align:${align[i]}"` : ""}>${words(inline(c, ctx))}</${tag}>`;
  let h = `<div class="table" role="region" tabindex="0" aria-label="${esc((ctx.lastHeading || ctx.title || "") + " table")}"><table><thead><tr>${head.map((c, i) => cell("th", c, i)).join("")}</tr></thead><tbody>`;
  for (const l of lines.slice(2)) h += `<tr>${splitRow(l).map((c, i) => cell("td", c, i)).join("")}</tr>`;
  return h + "</tbody></table></div>";
}
function list(lines, start, ctx) {
  const first = lines[start].match(RE.list), indent = first[1].length, ordered = /\d/.test(first[2]);
  const items = []; let i = start;
  while (i < lines.length) {
    const m = lines[i].match(RE.list);
    if (!m || m[1].length !== indent || /\d/.test(m[2]) !== ordered) break;
    const col = m[1].length + m[2].length + Math.min(m[3].length, 4);
    const body = [m[4]]; i++;
    while (i < lines.length) {
      const l = lines[i];
      if (!l.trim()) {
        let k = i; while (k < lines.length && !lines[k].trim()) k++;
        if (k < lines.length && indentOf(lines[k]) >= col) { while (i < k) { body.push(""); i++; } continue; }
        break;
      }
      if (indentOf(l) >= col) { body.push(l.slice(col)); i++; continue; }
      if (startsBlock(l)) break;
      body.push(l.trim()); i++;
    }
    items.push(body);
    let k = i; while (k < lines.length && !lines[k].trim()) k++;
    const n = k < lines.length && lines[k].match(RE.list);
    if (n && n[1].length === indent && /\d/.test(n[2]) === ordered) i = k;
  }
  const startNo = ordered ? parseInt(first[2], 10) : 1;
  const html = items.map((body) => {
    let j = 0; while (j < body.length && body[j].trim() && (j === 0 || !startsBlock(body[j]))) j++;
    return "<li>" + inline(body.slice(0, j).join("\n"), ctx) + blocks(body.slice(j), ctx) + "</li>";
  }).join("");
  return { html: ordered ? `<ol${startNo !== 1 ? ` start="${startNo}"` : ""}>${html}</ol>` : `<ul>${html}</ul>`, end: i };
}
function blocks(lines, ctx) {
  let out = "", i = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (!l.trim()) { i++; continue; }
    let m;
    if ((m = l.match(RE.fence))) {
      const body = []; i++;
      const close = new RegExp("^ {0,3}" + (m[1][0] === "~" ? "~" : "`") + "{" + m[1].length + ",}\\s*$");
      while (i < lines.length && !close.test(lines[i])) body.push(lines[i++]);
      i++; out += codeBlock(body.join("\n")); continue;
    }
    if ((m = l.match(RE.heading))) {
      const level = m[1].length, inner = inline(m[2], ctx), text = strip(inner).replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&amp;/g, "&");
      const id = ctx.slug(text);
      ctx.headings.push({ level, text, id });
      if (level <= 3) ctx.lastHeading = text;
      if (level === 1 && !ctx.title) ctx.title = text;
      out += `<h${level} id="${esc(id)}">${inner}<a class="anchor" href="#${esc(id)}" aria-label="${copy.docs.anchor}">#</a></h${level}>`;
      i++; continue;
    }
    if (RE.table.test(l) && i + 1 < lines.length && RE.sep.test(lines[i + 1])) {
      const t = []; while (i < lines.length && RE.table.test(lines[i])) t.push(lines[i++]);
      out += table(t, ctx); continue;
    }
    if (RE.quote.test(l)) {
      const q = []; while (i < lines.length && lines[i].trim() && RE.quote.test(lines[i])) q.push(lines[i++].replace(RE.quote, ""));
      out += "<blockquote>" + blocks(q, ctx) + "</blockquote>"; continue;
    }
    if (RE.hr.test(l)) { out += "<hr>"; i++; continue; }
    if (RE.list.test(l) && indentOf(l) < 4) { const r = list(lines, i, ctx); out += r.html; i = r.end; continue; }
    const p = [l.trim()]; i++;
    while (i < lines.length && lines[i].trim() && !startsBlock(lines[i])) p.push(lines[i++].trim());
    out += "<p>" + inline(p.join("\n"), ctx) + "</p>";
  }
  return out;
}
const newCtx = (file, extra) => Object.assign({ file, slug: slugger(), headings: [], title: "", lastHeading: "" }, extra);
const md = (text, file, extra) => { const ctx = newCtx(file, extra); return { html: blocks(text.split("\n"), ctx), ctx }; };
// The lines of a section: from its heading to the next heading of the same level or higher.
function section(text, heading) {
  const lines = text.split("\n"), at = lines.findIndex((l) => l.replace(/^#+ /, "") === heading && /^#+ /.test(l));
  if (at < 0) die(`no section "${heading}" to read`);
  const level = lines[at].match(/^#+/)[0].length;
  let end = at + 1, fence = false;
  for (; end < lines.length; end++) {
    if (/^```/.test(lines[end])) fence = !fence;
    const h = !fence && lines[end].match(/^(#+) /);
    if (h && h[1].length <= level) break;
  }
  return lines.slice(at + 1, end);
}

// ---- What the pages read from the repo ----
const README = read("README.md"), GUARD = read("docs/guardrails.md"), TROUBLE = read("docs/troubleshooting.md"), CHANGES = read("CHANGELOG.md");
const tableRows = (lines) => lines.filter((l) => RE.table.test(l)).slice(2).map(splitRow);
// "Words you will see": each term with its meaning, for the words marked on every page.
const glossary = tableRows(section(README, "Words you will see")).map(([term, meaning]) => ({
  term: strip(inline(term, newCtx("README.md"))), tip: inline(meaning, newCtx("README.md", { noLinks: true })),
}));
// The agent tools: the "Tool" column of the table under "What bootstrap installs".
const toolRows = tableRows(section(GUARD, "What bootstrap installs")).map((r) => r[0]);
const tools = toolRows.filter((t) => t !== "Any other tool");
if (tools.length === toolRows.length || !tools.length) die('docs/guardrails.md: the table under "What bootstrap installs" lost its tools or its "Any other tool" row');
// Each group of tools under "What each tool's rules block", with "Not caught" and "Known limits".
const blockSec = section(GUARD, "What each tool's rules block");
const groups = []; let notCaught = [];
for (let i = 0, cur = null; i < blockSec.length; i++) {
  const l = blockSec[i], g = l.match(/^\*\*([^*]+)\*\*/);
  if (g && g[1].startsWith("Not caught by any tool")) { notCaught = [l.replace(/^\*\*[^*]+\*\*\s*/, "")]; cur = notCaught; continue; }
  if (g) { cur = { names: g[1].split(/, | and /).map((s) => s.trim()), lines: [l] }; groups.push(cur); continue; }
  if (cur && cur !== notCaught) cur.lines.push(l); else if (cur === notCaught) notCaught.push(l);
}
if (!groups.length || !notCaught.length) die("docs/guardrails.md: \"What each tool's rules block\" has no tool groups, or no \"Not caught by any tool's rules\" line");
// A group that says "the same list" also shows the list it refers to: the first group's.
const firstList = groups[0].lines.filter((l) => RE.list.test(l) || /^ {2,}\S/.test(l));
for (const g of groups.slice(1)) if (/the same list/.test(g.lines[0])) g.lines = [g.lines[0], "", ...firstList, ...g.lines.slice(1)];
const limits = section(GUARD, "Known limits");
const undoList = section(GUARD, "Undoing the guardrails").filter((l) => RE.list.test(l) || /^ {2,}\S/.test(l));
const SETUP_H = "What setup changes on your machine", setupSec = section(README, SETUP_H);
const setupList = setupSec.filter((l) => RE.list.test(l));
const setupClose = setupSec.filter((l) => l.trim() && !RE.list.test(l)).pop();
const daySteps = section(README, "A day with Cabinet");
// "Install": the two tables, the npm block and the macOS and Debian or Ubuntu lines.
const installSec = section(README, "Install");
const tablesIn = (lines) => { const t = []; for (let i = 0; i < lines.length; i++) if (RE.table.test(lines[i]) && RE.sep.test(lines[i + 1] || "")) { const s = i; while (i < lines.length && RE.table.test(lines[i])) i++; t.push(lines.slice(s, i)); } return t; };
const installTables = tablesIn(installSec);
const required = installTables.find((t) => /^\|\s*Required/.test(t[0])), optional = installTables.find((t) => /^\|\s*Optional/.test(t[0]));
const macLine = installSec.find((l) => l.startsWith("- macOS:")), linuxLine = installSec.find((l) => l.startsWith("- Debian or Ubuntu:"));
const npmAt = installSec.findIndex((l, i) => /^```/.test(l) && /npm i -g/.test(installSec[i + 1] || ""));
if (!required || !optional || !macLine || !linuxLine || npmAt < 0) die('README.md "Install" lost its Required or Optional table, its macOS or Debian or Ubuntu line, or its npm i -g block');
const npmBlock = installSec.slice(npmAt, installSec.indexOf("```", npmAt + 1) + 1);

// ---- Shared page parts ----
const assetSvg = (f) => read("brand/assets/" + f);
const seatCircles = [...assetSvg("mark.svg").matchAll(/<circle [^>]*\/>/g)].map((m) => m[0]);
const lockupSrc = assetSvg("lockup.svg");
const lockupView = lockupSrc.match(/viewBox="([^"]+)"/)[1];
const lockupMark = lockupSrc.match(/<g transform="([^"]+)">/)[1];
const lockupName = lockupSrc.match(/<path [^>]*\/>/)[0].replace(/fill="[^"]*"/, 'fill="currentColor"');
const { ring_radius: R, outline } = tokens.mark;
const ownerOutline = (cls) => `<circle class="${cls}" cx="${R}" cy="0" r="${outline.radius}" fill="transparent" stroke-width="${outline.stroke}"/>`;
function lockup(height, hover) {
  const [, , w, h] = lockupView.split(" ").map(Number);
  return `<svg class="lockup" viewBox="${lockupView}" width="${Math.round((w / h) * height)}" height="${height}" aria-hidden="true" focusable="false"><g transform="${lockupMark}" fill="currentColor">${seatCircles.join("")}${hover ? ownerOutline("open") : ""}</g>${lockupName}</svg>`;
}
const mark = (size, cls, outlined) => `<svg class="${cls}" viewBox="-50 -50 100 100" width="${size}" height="${size}" aria-hidden="true" focusable="false"><g fill="currentColor">${seatCircles.map((c, k) => c.replace("<circle ", `<circle data-k="${k + 1}" `)).join("")}</g>${outlined ? ownerOutline("owner") : ""}</svg>`;
const loader = () => `<svg class="loader" viewBox="-50 -50 100 100" width="20" height="20" aria-hidden="true" focusable="false"><g fill="currentColor">${seatCircles.join("")}</g></svg>`;
// The chairs: the seven agents' chairs and the owner's chair in brass, read from the brand's own file.
const chairGroups = [...assetSvg("chairs-owner-light.svg").matchAll(/<g transform="(translate\([^)]*\) rotate\([^)]*\))"[^>]*>((?:<rect [^>]*\/>)+)<\/g>/g)].map((m) => ({ t: m[1], rects: m[2] }));
if (chairGroups.length !== 8) die("brand/assets/chairs-owner-light.svg: expected eight chairs");
const chairs = (size, cls) => `<svg class="${cls}" viewBox="-50 -50 100 100" width="${size}" height="${size}" aria-hidden="true" focusable="false"><g fill="currentColor">${chairGroups.slice(0, 7).map((c, k) => `<g data-k="${k + 1}"><g transform="${c.t}">${c.rects}</g></g>`).join("")}</g><g class="owner-chair" data-k="0" fill="transparent" stroke-width="${outline.stroke}"><g transform="${chairGroups[7].t}">${chairGroups[7].rects}</g></g></svg>`;
const icon = `<svg class="icon" viewBox="0 0 20 20" width="18" height="18" aria-hidden="true" focusable="false"><circle cx="8.5" cy="8.5" r="5.5" fill="transparent" stroke="currentColor" stroke-width="1.8"/><line x1="12.6" y1="12.6" x2="17" y2="17" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>`;
const copyBtn = `<button type="button" class="copy" hidden>${copy.copyButton.copy}</button>`;
const cmdChip = (text) => `<div class="cmd" data-copy><code>${esc(text)}</code>${copyBtn}</div>`;
const codeInline = (s) => inline(s, newCtx("README.md"));
const builtLine = copy.footer.built.replace("X.Y.Z", esc(version));
const kindUrl = (k) => BASE + "for/" + k + "/";
const NAV = copy.nav;

// GitHub's own mark (site/github-mark/, with its source): the path byte for byte, in GitHub's black or white.
const ghSrc = read("site/github-mark/GitHub_Invertocat_Black.svg");
const ghView = (ghSrc.match(/viewBox="([^"]+)"/) || die("site/github-mark: no viewBox"))[1], ghPath = (ghSrc.match(/<path d="([^"]+)"/) || die("site/github-mark: no path"))[1];
const ghMark = `<svg class="gh-mark" viewBox="${ghView}" width="20" height="20" aria-hidden="true" focusable="false"><path d="${ghPath}" fill="#000000"/></svg>`;
// cur: the page's own header item ("docs", "faq", "changelog" or "kind:<kind>"), marked aria-current.
function header(cur) {
  const at = (key) => (cur === key ? ' aria-current="page"' : "");
  const uses = copy.kinds.map(([k, name]) => `<li><a href="${kindUrl(k)}"${at("kind:" + k)}>${fill(copy.kindPage.link, name.toLowerCase())}</a></li>`).join("");
  return `<header class="top"><div class="bar">
<a class="brand" href="${BASE}" aria-label="Cabinet">${lockup(24, true)}</a>
<nav class="nav" id="nav" aria-label="Main"><a href="${BASE}#tour">${NAV.tour}</a><a href="${BASE}docs/"${at("docs")}>${NAV.docs}</a><details class="uses"><summary>${NAV.useCases}</summary><ul>${uses}</ul></details><a href="${BASE}faq/"${at("faq")}>${NAV.faq}</a><a href="${BASE}changelog/"${at("changelog")}>${NAV.changelog}</a><a class="gh-in-nav" href="${REPO}">${NAV.github}</a></nav>
<a class="search-btn" href="${BASE}docs/" data-search>${icon}<span class="search-label">${NAV.search}</span><kbd>/</kbd></a>
<a class="gh" href="${REPO}" aria-label="${NAV.github}">${ghMark}</a>
<button class="menu-btn" type="button" aria-expanded="false" aria-controls="nav" hidden>${NAV.menu}</button>
</div></header>`;
}
function footer() {
  const item = (href, label) => `<li><a href="${href}">${label}</a></li>`;
  // Two parts across the width (lockup and tagline; two unlabeled link columns), then one row: credits, version.
  return `<footer class="foot"><div class="wrap">
<div class="foot-top">
<div class="foot-brand">${lockup(20, false)}<p>${copy.tagline}</p></div>
<div class="foot-links"><ul>${item(BASE + "docs/", NAV.docs)}${item(BASE + "changelog/", NAV.changelog)}${item(BASE + "faq/", NAV.faq)}</ul><ul>${item(REPO, NAV.github)}${item(NPM, copy.footer.npm)}${item(BASE + "llms.txt", copy.footer.forAgents)}</ul></div>
</div>
<div class="foot-bottom"><p class="foot-credits">${copy.footer.license.replace("Apache 2.0 license", `<a href="${REPO}/blob/${esc(ref)}/LICENSE">Apache 2.0 license</a>`)}</p><p class="foot-version">${builtLine}</p></div>
</div></footer>`;
}
function searchDialog() {
  const S = copy.search;
  return `<dialog class="search" id="search" aria-label="${S.label}">
<div class="search-head">${icon}<input type="search" id="search-q" placeholder="${S.label}" aria-label="${S.label}" autocomplete="off" spellcheck="false" aria-controls="search-results"><button type="button" class="btn small close">${S.close}</button></div>
<div class="search-results" id="search-results" role="listbox" aria-label="${S.label}"></div>
<div class="search-status" hidden><span role="status" class="loading">${loader()}<span>${S.loading}</span></span></div>
<p class="search-hint">${S.hint}</p>
</dialog>`;
}
// Words the browser code shows, all from site/copy.js; its quick links as site addresses.
const quick = copy.search.quick.map(([label, file, a]) => [label, pageOf(file) + (a ? "#" + a : "")]);
const ui = JSON.stringify({ nav: copy.nav, copy: copy.copyButton, search: Object.assign({}, copy.search, { quick, docs: BASE + "docs/" }), terminal: copy.terminal, step: copy.tour.work.stepOf, changelog: copy.changelog, lookup: copy.docs.lookup, base: BASE }).replace(/</g, "\\u003c");

function layout({ title, desc, url, body, cls, cur }) {
  return `<!doctype html>
<html lang="en" class="no-js">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}">
<meta name="color-scheme" content="light dark">
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${SITE}${url.slice(BASE.length)}">
<meta property="og:image" content="${SITE}assets/social-preview.png">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="${BASE}assets/favicon.svg" type="image/svg+xml">
<link rel="icon" href="${BASE}assets/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="${BASE}assets/apple-touch-icon.png">
<link rel="stylesheet" href="${BASE}site.css">
<script>document.documentElement.className = "js"; try { if (!localStorage.getItem("cabinet.intro") && !matchMedia("(prefers-reduced-motion: reduce)").matches) document.documentElement.classList.add("intro-wait"); } catch (e) {}</script>
<script src="${BASE}site.js" defer></script>
</head>
<body class="${cls || ""}">
<a class="skip" href="#main">${NAV.skip}</a>
${header(cur)}
<main id="main" tabindex="-1">
${body}
</main>
${footer()}
${searchDialog()}
<p class="sr-only" aria-live="polite" id="live"></p>
<script type="application/json" id="ui">${ui}</script>
</body>
</html>
`;
}

// Cabinet words on hover: the first time each term from "Words you will see" appears in running text
// on a page, outside headings, code, links, buttons and labels, it gets its meaning as a tooltip.
const SKIP = new Set(["a", "code", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "button", "summary", "label", "option", "select", "textarea", "script", "style", "svg", "title", "kbd", "dialog"]);
// Whole words only: not part of a path, a name with dashes, or a placeholder such as <role>.
const termRe = new RegExp("(?<![\\w&;/.-])(" + glossary.map((g) => g.term.replace(/[.*+?^${}()|[\]\\-]/g, "\\$&")).sort((a, b) => b.length - a.length).join("|") + ")(s)?(?![\\w/-]|&gt;|\\.[a-z])", "gi");
function markTerms(html) {
  const done = new Set(); let skip = 0, n = 0;
  return html.replace(/(<[^>]+>)|([^<]+)/g, (all, tag, text) => {
    if (tag) {
      const t = tag.match(/^<(\/?)([a-z0-9]+)/i);
      if (t && SKIP.has(t[2].toLowerCase()) && !tag.endsWith("/>")) skip += t[1] ? -1 : 1;
      return tag;
    }
    if (skip) return text;
    return text.replace(termRe, (w, word) => {
      const g = glossary.find((x) => x.term.toLowerCase() === word.toLowerCase());
      if (!g || done.has(g.term)) return w;
      done.add(g.term); n++;
      return `<span class="term" tabindex="0" aria-describedby="tip-${n}">${w}<span class="tip" role="tooltip" id="tip-${n}"><strong>${esc(g.term)}</strong> ${g.tip}</span></span>`;
    });
  });
}
function markTermsSafe(html) {
  // Elements that hold no running text (chips, labels, the terminal) are taken out first and put back after.
  const kept = [];
  const masked = html.replace(/<(span|p|div|pre|ul|dl)( [^>]*class="[^"]*\b(?:chip|label|term-out|no-term)\b[^"]*"[^>]*)>[\s\S]*?<\/\1>/g, (m) => { kept.push(m); return `\u0000${kept.length - 1}\u0000`; });
  return markTerms(masked).replace(/\u0000(\d+)\u0000/g, (m, i) => kept[+i]);
}

// ---- Docs pages ----
const docs = order.map((file) => {
  let text = read(file);
  if (file === "README.md") text = text.replace(/^<img [^\n]*\n+/, "");
  const r = md(text, file);
  const name = file === "README.md" ? "" : path.posix.basename(file, ".md");
  const info = llmsLinks[file] || die(`llms.txt does not list ${file}`);
  return { file, name, url: name ? BASE + "docs/" + name + "/" : BASE + "docs/", label: file === "README.md" ? copy.docs.overview : info.label, desc: info.desc, title: r.ctx.title, html: r.html, headings: r.ctx.headings };
});
function sidebarList(current) {
  const item = (d) => `<li><a href="${d.url}"${d.file === current ? ' aria-current="page"' : ""}>${esc(d.label)}</a></li>`;
  return `<ul>${docs.filter((d) => copy.docs.order.includes(d.file)).map(item).join("")}</ul><p class="label">${copy.docs.forAgents}</p><ul>${docs.filter((d) => copy.docs.agents.includes(d.file)).map(item).join("")}</ul>`;
}
// Doctor message lookup (extra 2): every row of the troubleshooting tables.
const doctorRows = [];
{
  const lines = TROUBLE.split("\n"), ctx = newCtx("docs/troubleshooting.md"); let sec = "", anchor = "";
  for (let i = 0; i < lines.length; i++) {
    const h = lines[i].match(/^## (.*)$/);
    if (h) { sec = h[1]; anchor = ctx.slug(sec); continue; }
    if (/^\| Message \| ID \|/.test(lines[i])) {
      for (i += 2; i < lines.length && RE.table.test(lines[i]); i++) {
        const [m, id, cause, fix] = splitRow(lines[i]);
        const msg = m.replace(/^`|`$/g, ""), st = (msg.match(/^(ok|note|FIX) /) || ["", ""])[1].toLowerCase();
        doctorRows.push({ s: st, m: esc(msg), i: id.replace(/`/g, "") === "-" ? "" : esc(id.replace(/`/g, "")), c: inline(cause, ctx), f: inline(fix, ctx), h: esc(sec), a: anchor });
      }
    }
  }
}
if (!doctorRows.length) die("docs/troubleshooting.md has no message tables");
const L = copy.docs.lookup;
const lookupHtml = `<section class="lookup" hidden aria-labelledby="find-a-fix"><h2 id="find-a-fix">${L.h2}</h2><input type="search" class="lookup-q" placeholder="${esc(L.placeholder)}" aria-label="${esc(L.placeholder)}" autocomplete="off" spellcheck="false"><div class="lookup-out" aria-live="polite"></div></section>`;
docs.forEach((d, i) => {
  const toc = d.headings.filter((h) => h.level === 2 || h.level === 3).map((h) => `<li class="l${h.level}"><a href="#${esc(h.id)}">${esc(h.text)}</a></li>`).join("");
  let article = d.html;
  if (d.file === "docs/troubleshooting.md") article = article.replace(/<h2 /, lookupHtml + "<h2 ");
  const prev = docs[i - 1], next = docs[i + 1];
  const body = `<div class="docs wrap">
<aside class="sidebar" aria-label="${copy.docs.docs}">${sidebarList(d.file)}</aside>
<details class="docs-menu"><summary>${copy.docs.docs}</summary><nav aria-label="${copy.docs.docs}">${sidebarList(d.file)}</nav></details>
<article class="doc">${article}
<nav class="pager" aria-label="${copy.docs.previous} / ${copy.docs.next}">${prev ? `<a class="prev" href="${prev.url}"><span class="label">${copy.docs.previous}</span>${esc(prev.label)}</a>` : "<span></span>"}${next ? `<a class="next" href="${next.url}"><span class="label">${copy.docs.next}</span>${esc(next.label)}</a>` : ""}</nav>
<p class="built">${builtLine}</p></article>
${toc ? `<nav class="toc" aria-label="${copy.docs.onThisPage}"><p class="label">${copy.docs.onThisPage}</p><ul>${toc}</ul></nav>` : ""}
</div>`;
  const title = d.file === "README.md" ? copy.titles.docsOverview : fill(copy.titles.doc, d.title);
  write((d.name ? "docs/" + d.name + "/" : "docs/") + "index.html", layout({ title, desc: d.desc, url: d.url, body: markTermsSafe(body), cls: "page-docs", cur: "docs" }));
});
// The search index: every heading of every docs page, its page and anchor, and its text (escaped).
const index = [];
for (const d of docs) {
  const parts = d.html.split(/(?=<h[1-4] id=")/);
  for (const part of parts) {
    const m = part.match(/^<h([1-4]) id="([^"]+)">([\s\S]*?)<\/h\1>/);
    if (!m) continue;
    const h = strip(m[3].replace(/<a class="anchor"[\s\S]*?<\/a>/, ""));
    const t = strip(part.slice(m[0].length).replace(/<\/(p|li|td|th|pre|h\d)>/g, " ")).replace(/\s+/g, " ").trim();
    index.push({ p: esc(d.label), u: d.url, a: m[2], h, t });
  }
}
write("search.json", JSON.stringify(index));
write("doctor.json", JSON.stringify(doctorRows));

// ---- Home ----
const H = copy.hero, T = copy.terminal, TO = copy.tour, W = TO.work;
const capLine = (l) => l.replace(/<(?!\/?span\b)/g, "&lt;").replace(/<span(?! class="[a-z ]+">)/g, "&lt;span"); // only the capture's own spans
const capVersion = (CAP["10-init"].lines.join("\n").match(/cabinet (\d+\.\d+\.\d+)\)/) || [, version])[1];
const termLines = (c, prompt) => `<span class="ln cmdline"><span class="d">${esc(prompt || "$")} </span><span class="typed">${esc(c.cmd)}</span></span>\n` + c.lines.map((l) => `<span class="ln">${/^==/.test(strip(l)) ? `<span class="b">${capLine(l)}</span>` : capLine(l)}</span>`).join("\n");
const termText = (c) => "$ " + c.cmd + "\n" + c.lines.map((l) => strip(l).replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")).join("\n");
const chip = (t) => `<span class="chip">${t}</span>`;
const exampleCap = `<p class="caption">${TO.exampleCaption}</p>`;

const seven = CAP["03-roles"].lines.map((l) => strip(l).trim().split(/\s+/)).filter((c) => c[1] === "kit" && c[2] === "on").map((c) => c[0]);
if (seven.length !== 7) die("brand/demo/captured.js: the cabinet role list capture does not show seven roles turned on");
for (const r of seven) if (!roles[r]) die(`roles/${r}.md has no description:`);
const others = Object.keys(roles).filter((r) => !seven.includes(r));
const ringOrder = [2, 3, 4, 5, 6, 7, 1]; // counterclockwise from the top, as the brand's chairs come in
// The picture is 360 px across (100 units); each name sits outside its chair at one distance from the center, in px.
const LABEL_R = Math.round((tokens.mark.ring_radius + 18) * 3.6);
const seatPos = (k, r) => { const a = (k * Math.PI) / 4; return [r * Math.cos(a), -r * Math.sin(a)]; };
const roleData = JSON.stringify(Object.fromEntries(Object.entries(roles).map(([k, v]) => [k, esc(v)]))).replace(/</g, "\\u003c");
const chairButtons = seven.map((r, i) => {
  const k = ringOrder[i], [x, y] = seatPos(k, LABEL_R);
  return `<button type="button" class="seat at${k}" data-role="${r}" data-k="${k}" aria-pressed="${i === 0}" style="--x:${x.toFixed(1)}px;--y:${y.toFixed(1)}px">${r}</button>`;
}).join("") + `<button type="button" class="seat at0 you" data-role="" data-k="0" aria-pressed="false" style="--x:${LABEL_R}px;--y:0px">${TO.team.you}</button>`;
const prePush = read("guardrails/pre-push").match(/printf '([^']*Type yes to push: )'/);
if (!prePush) die("guardrails/pre-push: the prompt is not where the tour reads it");
const pushPrompt = prePush[1].replace(/\\n/g, "\n").replace("%s", W.pushRemote).replace("%s", W.pushRefs).replace(/^\n/, "");
const stepPanels = [
  [chip(TO.real), `<pre class="term-out panel-term">${termLines(CAP["08-handoff"])}\n${termLines(CAP["09-handoffs"])}</pre>`],
  [chip(TO.example), `<pre class="example">${W.verdicts.map(esc).join("\n")}</pre>${exampleCap}`],
  [chip(TO.example), `<div class="example brief">${W.brief.map((l) => (l.startsWith("## ") ? `<p class="brief-h">${l === "## Sign-off queue" ? mark(24, "mark-owner", true) : ""}<strong>${esc(l)}</strong></p>` : `<p>${esc(l)}</p>`)).join("")}</div>${exampleCap}`],
  [chip(TO.example), `<pre class="example">${esc(W.reply[0])}\n\n<strong>${esc(W.reply[1])}</strong>\n${esc(W.reply[2])}</pre>${exampleCap}`],
  [`${chip(TO.real)} ${chip(TO.example)}`, `<pre class="term-out panel-term"><span class="d">$</span> git push\n${esc(pushPrompt)}yes\n<span class="example-out">${W.pushed.map(esc).join("\n")}</span></pre>${exampleCap}`],
];
const steps = W.steps.map(([title, cap], i) => `<li class="step" id="step-${i + 1}" data-step="${i + 1}"><div class="step-head">${stepPanels[i][0]}<h4>${esc(title)}</h4><p>${esc(cap)}</p></div>${stepPanels[i][1]}</li>`).join("");
const filmPath = "brand/demo/cabinet-demo.mp4";
const P = copy.install;
const tabBody = (osLine) => blocks([osLine.replace(/^- /, ""), "", ...npmBlock, "", ...required, "", ...optional], newCtx("README.md"));

const home = `
<section class="hero wrap">
<div class="hero-text">
<div class="hero-mark">${mark(112, "intro", true)}</div>
<h1>${H.headline}</h1>
<p class="subline">${H.subline}</p>
<p class="lead">${H.lead}</p>
<div class="actions">${cmdChip(H.install)}<a class="btn primary" href="#tour">${H.tour}</a><a class="btn" href="${BASE}docs/">${H.docs}</a></div>
</div>
<div class="hero-term">
<div class="terminal" id="hero-term"><div class="term-bar"><span class="term-title">cabinet init</span>${chip(T.chip)}</div><pre class="term-out" aria-hidden="true">${termLines(CAP["10-init"])}</pre></div>
<pre class="sr-only">${esc(termText(CAP["10-init"]))}</pre>
<div class="term-controls" hidden><button type="button" class="btn small pause" aria-pressed="false">${T.pause}</button><button type="button" class="btn small replay">${T.replay}</button></div>
<p class="caption">${codeInline(T.caption.replace("X.Y.Z", capVersion))}</p>
<p class="caption nojs">${T.noJs}</p>
</div>
</section>

<section class="band wrap" id="what-it-is">
<h2>${copy.whatItIs.h2}</h2>
<p class="answer">${copy.whatItIs.answer}</p>
<h3>${copy.whatItIs.doesH3}</h3>
<ul class="cards three">${copy.whatItIs.does.map(([b, t]) => `<li class="card"><strong>${b}</strong> ${t}</li>`).join("")}</ul>
</section>

<section class="band wrap" id="tour">
<h2>${TO.h2}</h2>
<p class="answer">${TO.intro}</p>
<div class="team">
<h3>${TO.team.h3}</h3>
<p class="caption">${TO.team.caption}</p>
<div class="team-grid">
<div class="chairs-wrap"><div class="chairs-ring">${chairs(360, "chairs-pic")}<div class="seats">${chairButtons}</div></div><p class="caption nojs">${TO.team.noJs}</p></div>
<div class="role-panel card" hidden aria-live="polite"><p class="role-name"></p><p class="role-desc"></p>
<p class="caption more">${TO.team.more}</p><div class="chips">${others.map((r) => `<button type="button" class="chip-btn" data-role="${r}" aria-pressed="false">${r}</button>`).join("")}</div></div>
<dl class="role-list no-term">${[...seven, ...others].map((r) => `<dt>${r}</dt><dd>${esc(roles[r])}</dd>`).join("")}</dl>
</div>
<script type="application/json" id="roles">${roleData}</script>
<template id="owner-panel"><p class="role-name">${TO.team.ownerTitle}</p><p class="role-desc">${TO.team.ownerText}</p></template>
</div>
<div class="work">
<h3>${W.h3}</h3>
<div class="stepper" tabindex="0" aria-label="${esc(W.h3)}">
<div class="step-tabs" hidden>${W.steps.map(([t], i) => `<button type="button" class="step-tab" data-step="${i + 1}" aria-controls="step-${i + 1}" aria-pressed="${i === 0}">${esc(t)}</button>`).join("")}</div>
<ol class="steps">${steps}</ol>
<div class="step-controls" hidden><button type="button" class="btn small back">${W.back}</button><span class="step-of" aria-live="polite"></span><button type="button" class="btn small primary next">${W.next}</button><button type="button" class="btn small again" hidden>${W.again}</button></div>
</div>
</div>
<div class="demo">
<h3 id="demo-h">${TO.demo.h3}</h3>
<div class="film"><video controls preload="none" playsinline poster="${BASE}media/demo-poster.jpg" aria-labelledby="demo-h"><source src="${BASE}media/cabinet-demo.webm" type="video/webm"><source src="${BASE}media/cabinet-demo.mp4" type="video/mp4"></video>
<button type="button" class="btn primary play-film" hidden>${TO.demo.button}</button></div>
<p class="film-error" hidden>${TO.demo.error} <a href="${REPO}/blob/${esc(ref)}/${filmPath}">${TO.demo.github}</a></p>
<p class="caption">${TO.demo.caption}</p>
<p class="caption">${TO.demo.chapters}</p>
</div>
</section>

<section class="band wrap" id="use">
<h2>${copy.use.h2}</h2>
<p class="answer">${copy.use.answer}</p>
<ul class="cards three use-cards no-term">${copy.kinds.map(([k, name, line]) => `<li class="card use-card"><h3>${name}</h3><p>${line.split(/(?<=\.) /)[0]}</p><a class="card-link" href="${kindUrl(k)}">${fill(copy.kindPage.link, name.toLowerCase())}</a></li>`).join("")}</ul>
<h3>${copy.use.helpH3}</h3>
<p class="answer">${copy.use.help}</p>
<div class="story card"><p class="label">${copy.use.storyLabel}</p><h3>${copy.use.storyH3}</h3><p>${copy.use.story}</p></div>
</section>

<section class="band wrap" id="install">
<h2>${P.h2}</h2>
<div class="tabs" data-tabs>
<div class="tablist" role="tablist" hidden>${P.tabs.map((t, i) => `<button type="button" role="tab" id="tab-${i}" aria-controls="panel-${i}" aria-selected="${i === 0}" tabindex="${i === 0 ? 0 : -1}" data-os="${t}">${t}</button>`).join("")}</div>
<section class="tabpanel" role="tabpanel" id="panel-0" aria-labelledby="tab-0"><h3 class="tab-h">${P.tabs[0]}</h3>${tabBody(macLine)}</section>
<section class="tabpanel" role="tabpanel" id="panel-1" aria-labelledby="tab-1"><h3 class="tab-h">${P.tabs[1]}</h3>${tabBody(linuxLine)}</section>
<p><a href="${BASE}docs/#install">${H.docs}</a></p>
</div>
<div class="agent">
<h3>${P.agentH3}</h3>
<p class="caption">${P.agentCaption}</p>
${codeBlock(P.agentText)}
</div>
<details class="changes">
<summary>${esc(SETUP_H)}</summary>
<div class="two">
<div><h4>${P.changes}</h4>${blocks(setupList, newCtx("README.md"))}</div>
<div><h4>${P.undo}</h4>${blocks(undoList, newCtx("docs/guardrails.md"))}</div>
</div>
${blocks([setupClose], newCtx("README.md"))}
</details>
</section>

<section class="band wrap closing">
<h2>${copy.closing.h2}</h2>
<p class="actions"><a class="btn primary" href="${BASE}faq/">${copy.closing.faq}</a><a class="btn" href="${BASE}docs/">${copy.closing.docs}</a></p>
</section>`;
write("index.html", layout({ title: copy.titles.home, desc: copy.tagline, url: BASE, body: markTermsSafe(home), cls: "page-home" }));

// ---- Kind-of-work pages ----
const KP = copy.kindPage;
for (const [k, name, line] of copy.kinds) {
  const body = `<div class="wrap narrow kind">
<p class="label"><a class="crumb" href="${BASE}#use">${KP.label}</a></p>
<div class="kind-head"><div><h1>${fill(KP.link, name.toLowerCase())}</h1><p class="lead">${line}</p></div>${chairs(160, "kind-pic")}</div>
${k === "code" ? "" : `<aside class="today card" aria-label="${KP.todayLabel}"><p class="label">${KP.todayLabel}</p><p>${KP.today}</p></aside>`}
<h2>${KP.dayH2}</h2>
${blocks(daySteps, newCtx("README.md"))}
<h2>${KP.installH2}</h2>
${cmdChip(H.install)}
<h2>${KP.otherH2}</h2>
<ul class="others">${copy.kinds.filter((x) => x[0] !== k).map(([k2, n2]) => `<li><a href="${kindUrl(k2)}">${fill(KP.link, n2.toLowerCase())}</a></li>`).join("")}</ul>
</div>`;
  write(`for/${k}/index.html`, layout({ title: fill(copy.titles.kind, name.toLowerCase()), desc: copy.tagline, url: kindUrl(k), body: markTermsSafe(body), cls: "page-kind", cur: "kind:" + k }));
}

// ---- FAQ ----
const F = copy.faq, faqSlug = slugger();
const toolCtx = newCtx("docs/guardrails.md");
const groupHtml = groups.map((g, i) => {
  const r = blocks(g.lines.slice(1), toolCtx);
  return `<section class="tool-group" data-tools="${esc(JSON.stringify(g.names))}" id="tools-${i}"><h3>${inline(g.lines[0].match(/^\*\*[^*]+\*\*/)[0].slice(2, -2), toolCtx)}</h3><h4>${F.blocks}</h4>${blocks([g.lines[0].replace(/^\*\*[^*]+\*\*\s*/, "")], toolCtx)}${r}</section>`;
}).join("");
const allNames = groups.flatMap((g) => g.names);
const faqItems = F.items.map((it) => {
  const id = faqSlug(it.q);
  let a = (it.a || []).map((p) => `<p>${codeInline(p)}</p>`).join("");
  if (it.list) a += `<ul>${it.list.map((x) => `<li>${esc(x)}</li>`).join("")}</ul>`;
  if (it.tools) {
    a += `<ul class="tools">${tools.map((t) => `<li>${inline(t, toolCtx)}</li>`).join("")}<li>${codeInline(it.other)}</li></ul>`;
    a += `<div class="picker"><p class="label" id="picker-l">${F.picker}</p><div class="chips" role="radiogroup" aria-labelledby="picker-l" hidden>${allNames.map((n, i) => `<button type="button" role="radio" class="chip-btn" aria-checked="${i === 0}" tabindex="${i === 0 ? 0 : -1}" data-tool="${esc(n)}">${esc(n)}</button>`).join("")}</div>
${groupHtml}
<section class="tool-shared"><h4>${F.notCaught}</h4>${blocks(notCaught, toolCtx)}<h4>${F.limits}</h4>${blocks(limits, toolCtx)}</section></div>`;
  }
  if (it.setup) a += blocks(setupList, newCtx("README.md")) + blocks([setupClose], newCtx("README.md"));
  return { id, q: it.q, a };
});
const faqBody = `<div class="wrap faq">
<nav class="faq-list" aria-label="${F.h1}"><ul>${faqItems.map((x) => `<li><a href="#${x.id}">${esc(x.q)}</a></li>`).join("")}</ul></nav>
<div class="faq-main"><h1>${F.h1}</h1>${faqItems.map((x) => `<section class="qa"><h2 id="${x.id}">${esc(x.q)}</h2>${x.a}</section>`).join("")}</div>
</div>`;
write("faq/index.html", layout({ title: copy.titles.faq, desc: copy.tagline, url: BASE + "faq/", body: markTermsSafe(faqBody), cls: "page-faq", cur: "faq" }));

// ---- Changelog: released versions only, newest first ----
const C = copy.changelog, clLines = CHANGES.split("\n"), clCtx = newCtx("CHANGELOG.md");
const firstSec = clLines.findIndex((l) => /^## /.test(l));
const clHead = blocks(clLines.slice(0, firstSec < 0 ? clLines.length : firstSec), clCtx);
const versions = [];
for (let i = firstSec; i >= 0 && i < clLines.length; ) {
  let j = i + 1; while (j < clLines.length && !/^## /.test(clLines[j])) j++;
  const m = clLines[i].match(/^## (\d+\.\d+\.\d+) - (.+)$/);
  if (m && /^\d{1,2} [A-Z][a-z]{2} \d{4}$/.test(m[2].trim())) versions.push({ v: m[1], date: m[2].trim(), title: clLines[i].slice(3), body: clLines.slice(i + 1, j) });
  i = j;
}
if (!versions.length) die("CHANGELOG.md has no released version: no section headed ## X.Y.Z - <date> (an Unreleased section is not shown)");
const semver = (v) => v.split(".").map(Number);
versions.sort((a, b) => { const x = semver(a.v), y = semver(b.v); return y[0] - x[0] || y[1] - x[1] || y[2] - x[2]; });
const clBody = versions.map((v) => {
  const h3 = v.body.findIndex((l) => /^### /.test(l));
  const pre = h3 < 0 ? v.body : v.body.slice(0, h3), rest = h3 < 0 ? [] : v.body.slice(h3);
  return `<section class="ver" data-v="${v.v}"><h2 id="${esc(clCtx.slug(v.title))}">${v.v} <span class="date">${esc(v.date)}</span></h2><div class="byhand">${blocks(pre, clCtx)}</div>${blocks(rest, clCtx)}</section>`;
}).join("");
const opts = (sel) => versions.map((v, i) => `<option value="${v.v}"${i === sel ? " selected" : ""}>${v.v}</option>`).join("");
const picker = versions.length < 2 ? "" : `<section class="upgrade card" hidden><h2 id="upgrade-notes">${C.h2}</h2>
<div class="selects"><label>${C.from}<span class="select"><select class="from">${opts(1)}</select></span></label><label>${C.to}<span class="select"><select class="to">${opts(0)}</select></span></label><button type="button" class="btn small reset">${C.reset}</button></div>
<div class="upgrade-out" aria-live="polite"></div></section>`;
write("changelog/index.html", layout({ title: copy.titles.changelog, desc: copy.tagline, url: BASE + "changelog/", body: markTermsSafe(`<div class="wrap narrow changelog">${clHead}${picker}<div class="versions">${clBody}</div></div>`), cls: "page-changelog", cur: "changelog" }));

// ---- 404: every link rooted at /cabinet/, since it is served at any missing path ----
const NF = copy.notFound;
write("404.html", layout({ title: copy.titles.notFound, desc: copy.tagline, url: BASE + "404.html", cls: "page-404", body: `<div class="wrap narrow nf">${mark(64, "nf-mark", false)}<h1>${NF.h1}</h1><p>${NF.line}</p>
<input type="search" class="nf-search" placeholder="${copy.search.label}" aria-label="${copy.search.label}" hidden>
<p class="actions"><a class="btn primary" href="${BASE}docs/">${NF.docs}</a><a class="btn" href="${BASE}">${NF.home}</a></p></div>` }));

// ---- CSS: colors and fonts from brand/tokens.json ----
const col = tokens.color, st = tokens.status_color;
const rgba = (hex, a) => { const n = parseInt(hex.slice(1), 16); return `rgba(${n >> 16}, ${(n >> 8) & 255}, ${n & 255}, ${a})`; };
const mist = col.mist.value, night = col.night.value;
const fontFile = (family) => { const slug = family.toLowerCase().replace(/ /g, "-"), f = `site/fonts/${slug}/${slug}.woff2`; if (!fs.existsSync(path.join(KIT, f)) || !fs.existsSync(path.join(KIT, `site/fonts/${slug}/OFL.txt`))) die(`no font file and license for ${family}: ${f} and OFL.txt beside it`); return slug; };
const families = [...new Set([tokens.font.display.family, tokens.font.body.family, tokens.font.mono.family])];
const latin = "U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD";
const css = `/* Built by site/build.js: colors and fonts from brand/tokens.json, then site/site.css. */
${families.map((f) => { const s = fontFile(f); fs.mkdirSync(path.join(OUT, "fonts", s), { recursive: true }); copyFile(`site/fonts/${s}/${s}.woff2`, `fonts/${s}/${s}.woff2`); copyFile(`site/fonts/${s}/OFL.txt`, `fonts/${s}/OFL.txt`);
  return `@font-face { font-family: "${f}"; src: url("${BASE}fonts/${s}/${s}.woff2") format("woff2"); font-weight: 100 900; font-style: normal; font-display: swap; unicode-range: ${latin}; }`; }).join("\n")}
:root {
  --font-display: "${tokens.font.display.family}", "Helvetica Neue", Arial, sans-serif;
  --font-body: "${tokens.font.body.family}", "Helvetica Neue", Arial, sans-serif;
  --font-mono: "${tokens.font.mono.family}", ui-monospace, "SF Mono", Menlo, monospace;
  --bg: ${col.paper.value}; --card: ${col.white.value}; --card-border: ${col.line.value}; --text: ${col.ink.value}; --muted: ${col.slate.value};
  --divider: ${col.line.value}; --control: ${col.slate.value}; --focus: ${col.ink.value}; --btn-bg: ${col.ink.value}; --btn-fg: ${col.paper.value};
  --brass: ${col.brass.value}; --ok: ${st.ok.light}; --note: ${st.note.light}; --fix: ${st.fix.light};
  --term-bg: ${night}; --term-fg: ${mist}; --term-dim: ${rgba(mist, 0.6)}; --term-border: ${night}; --term-line: ${rgba(mist, 0.14)};
  --term-ok: ${st.ok.dark}; --term-note: ${st.note.dark}; --term-fix: ${st.fix.dark}; --term-brass: ${col["brass-light"].value};
  --backdrop: ${rgba(night, 0.4)}; --link-line: ${rgba(col.ink.value, 0.4)}; --tint: ${rgba(col.ink.value, 0.06)}; --btn-bg-hover: ${rgba(col.ink.value, 0.85)}; --play-hover: color-mix(in srgb, ${mist} 85%, ${night}); --copy-hover: color-mix(in srgb, ${col.ink.value} 6%, ${col.paper.value});
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: ${night}; --card: ${rgba(mist, 0.04)}; --card-border: ${rgba(mist, 0.14)}; --text: ${mist}; --muted: ${rgba(mist, 0.65)};
    --divider: ${rgba(mist, 0.14)}; --control: ${rgba(mist, 0.5)}; --focus: ${mist}; --btn-bg: ${mist}; --btn-fg: ${night};
    --brass: ${col["brass-light"].value}; --ok: ${st.ok.dark}; --note: ${st.note.dark}; --fix: ${st.fix.dark};
    --term-border: ${rgba(mist, 0.14)}; --backdrop: ${rgba(night, 0.6)}; --link-line: ${rgba(mist, 0.4)}; --tint: ${rgba(mist, 0.08)}; --btn-bg-hover: ${rgba(mist, 0.85)}; --copy-hover: color-mix(in srgb, ${mist} 8%, ${night});
    color-scheme: dark;
  }
}
dialog::backdrop { background: ${rgba(night, 0.4)}; }
/* GitHub's mark keeps GitHub's colors: black (in the HTML) on light, white on dark. */
@media (prefers-color-scheme: dark) { .gh-mark path { fill: ${col.white.value}; } }
@media (prefers-color-scheme: dark) { dialog::backdrop { background: ${rgba(night, 0.6)}; } }
:root { --hover-ms: ${tokens.motion.hover_reveal_ms}ms; --turn: ${tokens.motion.loading.beat_ms * tokens.motion.loading.beats}ms; }
${[2, 3, 4, 5, 6, 7, 1].map((k, j) => `.loader circle:nth-child(${k}) { animation-delay: -${(tokens.motion.loading.beats - j) * tokens.motion.loading.beat_ms}ms; }`).join("\n")}
${fs.readFileSync(path.join(__dirname, "site.css"), "utf8")}`;
write("site.css", css);
const m = tokens.motion;
write("site.js", `// Built by site/build.js: the brand's motion timings from brand/tokens.json, then site/site.js.\nvar MOTION = ${JSON.stringify({ hover: m.hover_reveal_ms, intro: m.intro, chair: m.chair_step_ms, loading: m.loading })};\n` + fs.readFileSync(path.join(__dirname, "site.js"), "utf8"));

// ---- Files served as they are ----
// llms.txt and llms-full.txt byte for byte, and every file llms.txt links, at its repo path.
copyFile("llms.txt", "llms.txt");
for (const m2 of llms.matchAll(/\]\(([^)#\s]+)\)/g)) {
  if (/^[a-z][a-z0-9+.-]*:/i.test(m2[1])) continue;
  const rel = path.posix.normalize(m2[1]);
  if (rel.startsWith("../") || rel === ".." || path.posix.isAbsolute(rel)) die(`llms.txt links ${m2[1]}, outside the kit: only files in the repo are served`);
  copyFile(rel, rel);
}
for (const f of ["favicon.svg", "favicon-32.png", "apple-touch-icon.png", "social-preview.png"]) copyFile("brand/assets/" + f, "assets/" + f);
copyFile("brand/demo/cabinet-demo.mp4", "media/cabinet-demo.mp4");
copyFile("brand/demo/cabinet-demo.webm", "media/cabinet-demo.webm");
copyFile("site/demo-poster.jpg", "media/demo-poster.jpg");
console.log(`Built the site from ${ref} (version ${version}) in ${OUT}`);
