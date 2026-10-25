// Checks a built website against the repo it was built from. Run by test/smoke.sh:
//   node test/site-check.js <kit> <built site folder> <ref>
// The site is served under /cabinet/: every link and asset must resolve to a file in the folder.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

const [kit, out, ref] = process.argv.slice(2);
const problems = [];
const fail = (p) => problems.push(p);
const read = (p) => fs.readFileSync(path.join(kit, p), "utf8");
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
const files = walk(out).map((f) => path.relative(out, f).split(path.sep).join("/"));
const html = files.filter((f) => f.endsWith(".html"));
const text = (f) => fs.readFileSync(path.join(out, f), "utf8");
const BASE = "/cabinet/", REPO = "https://github.com/TarekRaafat/cabinet";
const decode = (s) => s.replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
// GitHub's mark as the header must draw it: the reference file's path byte for byte (criterion 63).
const ghSvg = read("site/github-mark/GitHub_Invertocat_Black.svg"), ghRef = ghSvg.match(/<path d="([^"]+)"/)[1];
const ghMarkHtml = `<svg class="gh-mark" viewBox="${ghSvg.match(/viewBox="([^"]+)"/)[1]}" width="20" height="20" aria-hidden="true" focusable="false"><path d="${ghRef}" fill="#000000"/></svg>`;

// 3. A page for README.md and each doc.
const docs = fs.readdirSync(path.join(kit, "docs")).filter((f) => f.endsWith(".md"));
if (!files.includes("docs/index.html")) fail("no page for README.md (docs/index.html)");
for (const d of docs) if (!files.includes(`docs/${d.slice(0, -3)}/index.html`)) fail(`no page for docs/${d}`);

// 4. llms.txt and llms-full.txt byte for byte; every relative link in llms.txt is in the output.
for (const f of ["llms.txt", "llms-full.txt"])
  if (!files.includes(f) || !fs.readFileSync(path.join(out, f)).equals(fs.readFileSync(path.join(kit, f)))) fail(`${f} is not the repo's, byte for byte`);
for (const m of read("llms.txt").matchAll(/\]\(([^)#\s]+)/g))
  if (!/^[a-z]+:/.test(m[1]) && !files.includes(m[1])) fail(`llms.txt links ${m[1]}, which the site does not serve`);

// 5 and 6. Every href and src that is not a full URL resolves under /cabinet/, anchors included.
const ids = {};
const idsOf = (f) => (ids[f] = ids[f] || new Set([...text(f).matchAll(/\sid="([^"]+)"/g)].map((m) => decode(m[1]))));
const target = (url) => {
  const p = url.slice(BASE.length).split("#")[0];
  if (p === "" || p.endsWith("/")) return p + "index.html";
  return p;
};
for (const f of html) {
  const page = text(f);
  for (const m of page.matchAll(/\s(href|src|poster)="([^"]*)"/g)) {
    const url = decode(m[2]);
    if (/^(https?:|mailto:)/.test(url)) continue;
    if (url.startsWith("#")) { if (url.length > 1 && !idsOf(f).has(url.slice(1))) fail(`${f}: ${url} lands on no element`); continue; }
    if (!url.startsWith(BASE)) { fail(`${f}: ${m[1]}="${url}" is not under ${BASE}`); continue; }
    const t = target(url);
    if (!files.includes(t)) { fail(`${f}: ${url} names no file in the site`); continue; }
    const a = url.split("#")[1];
    if (a && t.endsWith(".html") && !idsOf(t).has(a)) fail(`${f}: ${url} lands on no element with that id`);
  }
  for (const m of page.matchAll(/url\(["']?([^"')]+)/g)) if (!m[1].startsWith(BASE) || !files.includes(target(m[1]))) fail(`${f}: url(${m[1]}) does not resolve`);
}
for (const m of text("site.css").matchAll(/url\(["']?([^"')]+)/g)) if (!m[1].startsWith(BASE) || !files.includes(target(m[1]))) fail(`site.css: url(${m[1]}) does not resolve`);

// 7. A doc's link to a repo file that is not a page goes to GitHub at the built ref.
for (const d of ["README.md", ...docs.map((x) => "docs/" + x)]) {
  for (const m of read(d).matchAll(/\]\(([^)#\s]+)/g)) {
    const t = path.posix.normalize(path.posix.join(path.posix.dirname(d), m[1])).replace(/\/$/, "");
    if (/^[a-z]+:/.test(m[1]) || t === "README.md" || t === "CHANGELOG.md" || (t.startsWith("docs/") && t.endsWith(".md"))) continue;
    const page = d === "README.md" ? "docs/index.html" : `docs/${path.basename(d, ".md")}/index.html`;
    if (!text(page).includes(`href="${REPO}/blob/${ref}/${t}`)) fail(`${page}: the link to ${t} does not go to ${REPO}/blob/${ref}/${t}`);
  }
}

// 8. The changelog page: every dated version, newest first, nothing Unreleased.
const cl = text("changelog/index.html");
const dated = [...read("CHANGELOG.md").matchAll(/^## (\d+\.\d+\.\d+) - (\d{1,2} [A-Z][a-z]{2} \d{4})$/gm)].map((m) => m[1]);
const shown = [...cl.matchAll(/<section class="ver" data-v="([^"]+)"/g)].map((m) => m[1]);
const newest = [...dated].sort((a, b) => { const x = a.split(".").map(Number), y = b.split(".").map(Number); return y[0] - x[0] || y[1] - x[1] || y[2] - x[2]; });
if (shown.join() !== newest.join()) fail(`the changelog page shows ${shown.join(", ")}, not ${newest.join(", ")} (every released version, newest first)`);
if (/Unreleased/.test(cl)) fail("the changelog page shows an Unreleased section");

// 10. The hero terminal's lines are the cabinet init capture, line for line.
const capSrc = read("brand/demo/captured.js"), cap = JSON.parse(capSrc.slice(capSrc.indexOf("{"), capSrc.lastIndexOf("}") + 1))["10-init"];
const term = (text("index.html").match(/<div class="terminal" id="hero-term">[\s\S]*?<pre class="term-out"[^>]*>([\s\S]*?)<\/pre>/) || ["", ""])[1];
const heroLines = [...term.matchAll(/<span class="ln">([\s\S]*?)<\/span>(?=\n|$)/g)].map((m) => decode(m[1].replace(/<[^>]*>/g, "")));
const capLines = cap.lines.map((l) => decode(l.replace(/<[^>]*>/g, "")));
if (heroLines.join("\n") !== capLines.join("\n")) fail("the hero terminal's lines are not the cabinet init capture, line for line");
if (!term.includes(`<span class="typed">${cap.cmd}</span>`)) fail("the hero terminal does not type the captured command");

// 32. The hero terminal's == section lines are bold.
for (const m of term.matchAll(/<span class="ln">([\s\S]*?)<\/span>(?=\n|$)/g))
  if (/^==/.test(decode(m[1].replace(/<[^>]*>/g, ""))) && !m[1].startsWith('<span class="b">')) fail("a == line in the hero terminal is not bold");
// 27 and 32. Mono text has no ligatures, and no control loses its focus ring.
if (!/code, kbd, pre, samp, \.term-out[^{]*\{ font-variant-ligatures: none; \}/.test(text("site.css"))) fail("site.css does not turn off ligatures in mono text");
for (const m of text("site.css").matchAll(/([^{}]+)\{[^}]*outline: *none/g)) if (m[1].trim() !== "main:focus") fail(`site.css removes the focus ring from ${m[1].trim()}`);

// Code in a table cell breaks only at spaces: every word of it is in a nowrap span.
for (const f of html.filter((f) => f.startsWith("docs/"))) {
  for (const m of text(f).matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g))
    for (const c of m[1].replace(/<span class="tip"[^>]*>[\s\S]*?<\/span>/g, "").matchAll(/<code>([\s\S]*?)<\/code>/g))
      if (c[1].replace(/<span class="nw">[^< ]+<\/span>/g, "").replace(/ /g, "")) { fail(`${f}: code in a table cell is not wrapped word by word: ${c[1].slice(0, 60)}`); break; }
}
if (!/\.table code \.nw \{ white-space: nowrap; \}/.test(text("site.css"))) fail("site.css does not keep table code words whole");
// The film's play button reads just its label, no length or size (Decision 12).
if ((text("index.html").match(/<button[^>]*class="[^"]*\bplay-film\b[^"]*"[^>]*>([\s\S]*?)<\/button>/) || [])[1] !== "Play the demo") fail('the film\'s play button does not read exactly "Play the demo"');
// The film's play button keeps the dark style on the night frame in both themes (it must outrank .btn.primary).
if (!/\.btn\.play-film \{[^}]*background: var\(--term-fg\)/.test(text("site.css")) || !/\.btn\.play-film:hover \{ background-color: var\(--play-hover\)/.test(text("site.css"))) fail("the film's play button is not styled as .btn.play-film on the night frame");

// 58 to 63: links and the GitHub mark.
const css = text("site.css").replace(/\/\*[\s\S]*?\*\//g, "");
const ruleSel = (re) => [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)].filter((m) => re.test(m[2])).flatMap((m) => m[1].split(",").map((x) => x.trim()));
const plain = ruleSel(/text-decoration: none/);
for (const s of [".nav a", ".uses a", ".uses > summary", ".foot-links a", ".sidebar a", ".docs-menu a", ".toc a", ".faq-list a", ".pager a", ".search-results a", ".card-link", ".others a", ".crumb", ".gh", ".btn",
  ".nav a:hover", ".uses a:hover", ".foot-links a:hover", ".sidebar a:hover", ".toc a:hover", ".faq-list a:hover", ".pager a:hover", ".search-results a:hover", ".card-link:hover", ".others a:hover", ".crumb:hover", ".gh:hover"])
  if (!plain.includes(s)) fail(`site.css: ${s} is not set to no underline (criterion 58)`);
if (!/(^|\n)a \{[^}]*text-decoration: underline; text-decoration-thickness: 1px;[^}]*text-decoration-color: var\(--link-line\)/.test(css)) fail("site.css: links in running text lose their 1 px underline (criterion 60)");
if (!/a\[aria-current\] \{ font-weight: 700; \}/.test(css)) fail("site.css: the current page is not weight 700 (criterion 61)");
const navOf = (f) => (text(f).match(/<nav class="nav"[\s\S]*?<\/nav>/) || [""])[0];
const currents = (f) => [...navOf(f).matchAll(/<a href="([^"]+)" aria-current="page">/g)].map((m) => m[1]);
for (const f of html) {
  const want = f.startsWith("docs/") ? [BASE + "docs/"] : f === "faq/index.html" ? [BASE + "faq/"] : f === "changelog/index.html" ? [BASE + "changelog/"] : f.startsWith("for/") ? [BASE + f.replace(/index\.html$/, "")] : [];
  if (currents(f).join() !== want.join()) fail(`${f}: the header marks ${currents(f).join(", ") || "nothing"} as the current page, not ${want.join(", ") || "nothing"} (criterion 61)`);
}
for (const [k] of [["code"], ["design"], ["writing"], ["marketing"], ["music"], ["finance"]])
  if (!new RegExp(`<li class="card use-card">[\\s\\S]*?<a class="card-link" href="${BASE}for/${k}/">Cabinet for ${k}</a></li>`).test(text("index.html"))) fail(`the use-case card for ${k} is not one link named Cabinet for ${k} (criterion 62)`);
if (!/\.card-link::after \{ content: ""; position: absolute; inset: 0;/.test(css)) fail("site.css: a use-case card's link does not cover the card (criterion 62)");
for (const f of html) {
  const p = text(f);
  if (!p.includes(`<a class="gh" href="${REPO}" aria-label="GitHub">${ghMarkHtml}</a>`)) fail(`${f}: the header's GitHub link is not GitHub's mark, unaltered, named GitHub (criterion 63)`);
  if (!p.includes(`<a class="gh-in-nav" href="${REPO}">GitHub</a>`)) fail(`${f}: the menu has no GitHub text link (criterion 63)`);
}
if (!/\.gh-mark path \{ fill: #FFFFFF; \}/.test(css) || !/\.gh \{[^}]*width: 40px; height: 40px;/.test(css) || !/\(pointer: coarse\) \{ \.gh \{ width: 44px; height: 44px; \}/.test(css)) fail("site.css: GitHub's mark is not white on dark, or its hit area is under 40 px (44 px on touch) (criterion 63)");
if (/#000000/i.test(css)) fail("site.css uses #000000, which is allowed only on GitHub's mark");

// The Use cases label on a kind-of-work page is a navigation link (criterion 58).
for (const f of html.filter((f) => f.startsWith("for/"))) if (!text(f).includes(`<a class="crumb" href="${BASE}#use">`)) fail(`${f}: the Use cases label is not a navigation link`);
// The docs sidebar's scroll box leaves the links' tint 8 px left of their text; menu-sheet Use cases items are 44 px tall.
if (!/\.sidebar, \.toc \{ padding-left: 8px; margin-left: -8px; \}/.test(css) || !/\.sidebar a, \.docs-menu a \{[^}]*padding: 5px 8px; margin-left: -8px;/.test(css)) fail("site.css: the docs sidebar's hover tint has no room left of the text");
if (!/@media \(max-width: 899px\) \{[\s\S]*?\.js \.uses li a \{[^}]*min-height: 44px;/.test(css)) fail("site.css: Use cases items in the menu sheet are under 44 px");
// Every select is native, wrapped for the one CSS chevron, with the browser's arrow off (owner finding: arrows misaligned).
for (const f of html) {
  const p = text(f);
  if ((p.match(/<select/g) || []).length !== (p.match(/<span class="select"><select /g) || []).length) fail(`${f}: a select is not wrapped for its chevron`);
}
if (!/\.selects select \{[^}]*appearance: none;/.test(css) || !/\.select::after \{ content: ""; position: absolute; right: 16px; top: 50%;/.test(css)) fail("site.css: the selects keep the browser's own arrow, or the chevron is not at one inset, centred");

// Use-case cards share one structure: title, description, link pinned to the bottom; no glossary term inside a card (one link).
{
  const ul = (text("index.html").match(/<ul class="cards three use-cards no-term">([\s\S]*?)<\/ul>/) || ["", ""])[1];
  const cards = ul.match(/<li class="card use-card">[\s\S]*?<\/li>/g) || [];
  if (cards.length !== 6) fail(`the home page has ${cards.length} use-case cards, not six`);
  for (const c of cards) if (!/^<li class="card use-card"><h3>[^<]+<\/h3><p>[\s\S]*?<\/p><a class="card-link" href="[^"]+">[^<]+<\/a><\/li>$/.test(c) || /class="term"/.test(c)) fail(`a use-case card is not title, description and link, or holds a glossary term: ${c.slice(0, 80)}`);
  if (!/\.use-card \{ position: relative; display: flex; flex-direction: column; \}/.test(css) || !/\.card-link \{[^}]*margin-top: auto;/.test(css)) fail("site.css: use-case cards do not pin their link to the bottom");
}

// The Use cases toggle shows a CSS chevron (down closed, up open), never + or - (owner finding).
if (/\.uses[^{]*summary::after \{[^}]*content: " ?[+-]"/.test(css) || !/\.uses > summary::after \{ content: ""; [^}]*border-right: 1\.5px solid currentColor; border-bottom: 1\.5px solid currentColor; transform: rotate\(45deg\);/.test(css) || !/\.uses\[open\] > summary::after \{[^}]*transform: rotate\(-135deg\);/.test(css)) fail("site.css: the Use cases toggle is not a chevron, down when closed and up when open");

// Glossary cards are placed in the viewport by site.js, at the term's own line (owner finding: a card ran off the page).
// The browser check of positions is in the review evidence; this keeps the parts a file can show.
{
  const js = text("site.js");
  if (!/\.no-js \.tip \{ position: fixed; left: 16px; right: 16px; bottom: 16px; top: auto; width: auto;/.test(css)) fail("site.css: without JavaScript a glossary card can run past the window");
  if (!/\.js \.tip \{ position: fixed;/.test(css) || !/function placeTip\(/.test(js) || !/getClientRects\(\)/.test(js) || !/EDGE = 16/.test(js) || !/innerWidth - 2 \* EDGE/.test(js)) fail("the glossary cards are not placed inside the viewport at the term's line (site.js placeTip)");
}

// 64. The footer: two parts across the width, two unlabeled link columns, then one row of credits and version.
{
  // The wording is the site's own, read from site/copy.js (the signed-off words).
  const ver = JSON.parse(read("package.json")).version, words = require(path.join(path.resolve(kit), "site/copy.js"));
  const want = [[words.nav.docs, words.nav.changelog, words.nav.faq], [words.nav.github, words.footer.npm, words.footer.forAgents]];
  for (const f of html) {
    const foot = (text(f).match(/<footer class="foot">[\s\S]*?<\/footer>/) || [""])[0];
    const cols = [...((foot.match(/<div class="foot-links">([\s\S]*?)<\/div>/) || ["", ""])[1]).matchAll(/<ul>([\s\S]*?)<\/ul>/g)].map((u) => [...u[1].matchAll(/<a [^>]*>([^<]+)<\/a>/g)].map((x) => x[1]));
    if (JSON.stringify(cols) !== JSON.stringify(want)) { fail(`${f}: the footer's link columns are ${JSON.stringify(cols)}`); continue; }
    const credits = decode(((foot.match(/<p class="foot-credits">([\s\S]*?)<\/p>/) || ["", ""])[1]).replace(/<[^>]*>/g, ""));
    if (credits !== words.footer.license || !/<a href="[^"]+\/LICENSE">Apache 2\.0 license<\/a>/.test(foot)) fail(`${f}: the footer's credits read "${credits}"`);
    if (!foot.includes(`<p class="foot-version">${words.footer.built.replace("X.Y.Z", ver)}</p>`) || !/<div class="foot-brand"><svg class="lockup"/.test(foot) || !foot.includes(`<p>${words.tagline}</p></div>`)) fail(`${f}: the footer lacks its version line, or its lockup and tagline`);
  }
  if (!/\.foot-top \{ display: grid; grid-template-columns: 1fr auto;/.test(css) || !/\.foot-bottom \{ display: flex; justify-content: space-between;/.test(css) || !/@media \(max-width: 419px\) \{[^@]*\.foot-links a \{ padding: 10px 0; \}/.test(css)) fail("site.css: the footer is not the two-part layout with a credits row and 44 px links under 420 px");
}

// Search's empty-state hint is help text: small, secondary, outside the options, with cabinet doctor in mono.
if (!/\.search-results \.search-help \{[^}]*margin: 0 0 16px; font-size: 14px; color: var\(--muted\);/.test(css) || !/'<p class="search-help">' \+ esc\(UI\.search\.empty\)\.replace\("cabinet doctor", "<code>cabinet doctor<\/code>"\)/.test(text("site.js"))) fail("search: the empty-state hint is not styled as help text apart from the suggestions");

// No site-written text puts a period right after a version number (owner: it reads as part of the version).
// Checked in site/copy.js's words and in the lines the site writes around a version (not docs prose or captured output).
{
  const words = require(path.join(path.resolve(kit), "site/copy.js"));
  const strings = []; (function walk(o) { for (const v of Object.values(o)) typeof v === "string" ? strings.push(v) : v && typeof v === "object" && walk(v); })(words);
  for (const s of strings) if (/(X\.Y\.Z|\d+\.\d+\.\d+)\.(\s|$)/.test(s)) fail(`site/copy.js: a version is followed by a period: "${s}"`);
  for (const f of html) for (const m of text(f).matchAll(/<p class="(?:foot-version|built)">([^<]*)<\/p>/g)) if (/\d+\.\d+\.\d+\./.test(m[1])) fail(`${f}: "${m[1]}" puts a period after the version`);
}

// The current item in "On this page" and the docs sidebar: text color, weight 700, a 2 px bar in the text color; nested items 16 px in.
if (!/\.toc a\.here \{ color: var\(--text\); font-weight: 700; \}/.test(css) || !/\.toc a\.here::before, \.sidebar a\[aria-current\]::before, \.docs-menu a\[aria-current\]::before \{[^}]*width: 2px;[^}]*background: var\(--text\);/.test(css) || !/\.toc \.l3 a \{ padding-left: 24px; \}/.test(css) || !/a\.setAttribute\("aria-current", "location"\)/.test(text("site.js"))) fail("docs: the current item in On this page or the sidebar is not marked by color, weight and a bar, or nested items are not indented");

// Hover on every control: each has a hover rule, only inside @media (hover: hover), a pointer cursor and the color transition.
{
  const media = [], outside = [];
  let rest = css, i;
  while ((i = rest.indexOf("@media (hover: hover) {")) >= 0) {
    let d = 0, j = i + "@media (hover: hover) ".length;
    for (; j < rest.length; j++) { if (rest[j] === "{") d++; else if (rest[j] === "}" && --d === 0) break; }
    media.push(rest.slice(i, j + 1)); outside.push(rest.slice(0, i)); rest = rest.slice(j + 1);
  }
  outside.push(rest);
  const sels = (s) => [...s.matchAll(/([^{}]+)\{[^{}]*\}/g)].flatMap((m) => m[1].split(",").map((x) => x.trim().replace(/^@media[^{]*\{\s*/, "")));
  const base = (x) => x.replace(/:not\([^)]*\)/g, "").replace(/:hover/g, "").trim();
  const hoverIn = sels(media.join("\n")).filter((x) => x.includes(":hover")).map(base);
  const hoverOut = sels(outside.join("\n")).filter((x) => x.includes(":hover")).map(base);
  const controls = [".btn", ".btn.primary", ".btn.play-film", ".chip-btn", '.chip-btn[aria-pressed="true"]', '.chip-btn[aria-checked="true"]', ".step-tab", '.step-tab[aria-pressed="true"]', '[role="tab"]', '[role="tab"][aria-selected="true"]', ".seat", '.seat[aria-pressed="true"]', ".code .copy", ".cmd .copy", ".cmd-inline .copy", ".search-btn", ".menu-btn", ".selects select", ".changes > summary", ".docs-menu > summary", ".uses > summary"];
  const all = sels(css);
  const ruleOf = (prop) => [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].filter((m) => prop.test(m[2])).flatMap((m) => m[1].split(",").map((x) => x.trim()));
  const pointer = ruleOf(/cursor: pointer/), fade = ruleOf(/transition: background-color 150ms ease-out, border-color 150ms ease-out, color 150ms ease-out/);
  for (const c of controls) {
    if (!hoverIn.includes(c)) fail(`site.css: ${c} has no hover rule inside @media (hover: hover)`);
    if (hoverOut.includes(c)) fail(`site.css: a hover rule for ${c} sits outside @media (hover: hover)`);
    // Cursor and transition sit on the control's base rule (.btn covers primary and the play button; a selected state shares its control's).
    const b = c.replace(/\[aria-[a-z]+="true"\]$/, "").replace(/^\.btn\.(primary|play-film)$/, ".btn");
    if (!pointer.includes(b)) fail(`site.css: ${b} has no cursor: pointer`);
    if (!fade.includes(b)) fail(`site.css: ${b} has no 150 ms color transition`);
  }
  if (!/\.btn:disabled \{ cursor: default; \}/.test(css)) fail("site.css: a disabled button keeps a pointer cursor");
}

// Under 700 px the team picture and its row of names share one centred axis (owner finding).
if (!/@media \(max-width: 700px\) \{[^@]*\.chairs-ring \{ width: 300px; height: auto; margin-inline: auto; \}[^@]*\.seats \{[^}]*justify-content: center;/.test(css)) fail("site.css: the team picture is not centred under 700 px");

// The menu sheet's separators: straight (no radius) and full width on every row (owner finding).
if (!/\.js \.nav > a, \.js \.uses > summary \{[^}]*border-top: 1px solid var\(--divider\);[^}]*border-radius: 0; \}/.test(css) || !/\.js \.uses, \.js \.uses > summary \{ display: flex; width: 100%; \}/.test(css)) fail("site.css: the menu sheet's row separators are rounded or not full width");

// Controls on top of content (a code block's copy button, the film's play button) stay opaque on hover: a color-mix, never a see-through value.
if (!/--play-hover: color-mix\(in srgb, #E8EAEE 85%, #101216\);/i.test(css) || !/--copy-hover: color-mix\(in srgb, #15181E 6%, #F3F4F6\);/i.test(css) || !/--copy-hover: color-mix\(in srgb, #E8EAEE 8%, #101216\);/i.test(css)
  || !/\.code \.copy:hover \{ background-color: var\(--copy-hover\);/.test(css) || !/\.btn\.primary:not\(\.play-film\):not\(:disabled\):hover/.test(css)) fail("site.css: a control on top of content (code copy, film play) is not opaque on hover");

// The install chip's copy button fills the chip's height to its right edge, with the chip's rounding (owner finding).
if (!/\.cmd \{[^}]*padding: 0 0 0 14px;/.test(css) || !/\.cmd \.copy \{ align-self: stretch;[^}]*border-radius: 0 7px 7px 0;/.test(css)) fail("site.css: the install chip's copy button does not fill the chip to its rounded right edge");

// 11. Every <pre> on a docs page has a copy button.
for (const f of html.filter((f) => f.startsWith("docs/"))) {
  const pres = (text(f).match(/<pre/g) || []).length, btns = (text(f).match(/<pre[^>]*>[\s\S]*?<\/pre><button type="button" class="copy"/g) || []).length;
  if (pres !== btns) fail(`${f}: ${pres - btns} of ${pres} code blocks have no copy button`);
}

// 12. The search index has every heading of every docs page, with its page and anchor.
const index = JSON.parse(text("search.json"));
for (const f of html.filter((f) => f.startsWith("docs/"))) {
  const url = BASE + f.replace(/index\.html$/, "");
  const art = text(f).split('<article class="doc">')[1].split("</article>")[0];
  for (const m of art.matchAll(/<h([1-4]) id="([^"]+)"/g)) {
    if (m[2] === "find-a-fix") continue;
    if (!index.some((e) => e.u === url && e.a === decode(m[2]) && e.p)) fail(`search.json lacks the heading #${m[2]} of ${url}`);
  }
}

// 13. Every color is a token from brand/tokens.json, or one at an opacity, or a color keyword.
const tokens = JSON.parse(read("brand/tokens.json"));
const hexes = new Set([...JSON.stringify(tokens).matchAll(/#[0-9A-Fa-f]{6}\b/g)].map((m) => m[0].toUpperCase()));
const rgbs = new Set([...hexes].map((h) => { const n = parseInt(h.slice(1), 16); return `${n >> 16},${(n >> 8) & 255},${n & 255}`; }));
const NAMED = /^(aliceblue|antiquewhite|aqua|aquamarine|azure|beige|bisque|black|blanchedalmond|blue|blueviolet|brown|burlywood|cadetblue|chartreuse|chocolate|coral|cornflowerblue|cornsilk|crimson|cyan|darkblue|darkgray|darkgreen|darkgrey|darkred|gold|gray|green|grey|indigo|ivory|khaki|lavender|lime|magenta|maroon|navy|olive|orange|orchid|pink|plum|purple|red|salmon|silver|tan|teal|tomato|turquoise|violet|wheat|white|whitesmoke|yellow|yellowgreen)$/i;
const checkColors = (where, css) => {
  for (const m of css.matchAll(/#[0-9A-Fa-f]{3,8}\b/g)) if (!hexes.has(m[0].toUpperCase())) fail(`${where}: the color ${m[0]} is not a token`);
  for (const m of css.matchAll(/rgba?\(([^)]*)\)/g)) {
    const p = m[1].split(/[\s,/]+/).filter(Boolean);
    if (!rgbs.has(p.slice(0, 3).join(","))) fail(`${where}: the color ${m[0]} is not a token at an opacity`);
  }
  for (const m of css.matchAll(/\b(hsla?|hwb|lab|lch|oklab|oklch|color)\(/g)) fail(`${where}: a color function ${m[1]}() is not a token`);
  for (const m of css.matchAll(/(?:^|[;{\s])(color|background(?:-color)?|border(?:-[a-z]+)*|outline(?:-color)?|fill|stroke|text-decoration(?:-color)?|caret-color)\s*:\s*([^;}]+)/g))
    for (const w of m[2].split(/[\s,]+/)) if (NAMED.test(w)) fail(`${where}: the color ${w} is not a token`);
};
checkColors("site.css", text("site.css"));
// The one exception: GitHub's mark keeps GitHub's #000000, only on the mark itself (criterion 63).
for (const f of html) {
  const page = text(f).split(ghMarkHtml).join("");
  for (const m of page.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/g)) checkColors(f + " <style>", m[1]);
  for (const m of page.matchAll(/\sstyle="([^"]*)"/g)) checkColors(f + " style", m[1]);
  for (const m of page.matchAll(/\s(fill|stroke)="([^"]*)"/g))
    if (!/^(transparent|currentColor|inherit)$/.test(m[2]) && !hexes.has(m[2].toUpperCase())) fail(`${f}: ${m[1]}="${m[2]}" is not a token or transparent, currentColor or inherit`);
}

// 14. No HTML page or data file the browser reads holds a tag from Markdown text.
for (const f of [...html, "search.json", "doctor.json"]) {
  const s = text(f).replace(/<script>document\.documentElement\.className = "js";[^<]*<\/script>|<script src="\/cabinet\/site\.js" defer><\/script>|<script type="application\/json" id="(ui|roles)">/g, "");
  if (/<script/i.test(s)) fail(`${f} holds a <script tag that is not the site's own`);
  if (/<(img|iframe|object|embed|style)\b/i.test(s)) fail(`${f} holds a tag that markdown text could have brought in`);
}

// 15. No request to another site, no cookie; links outside go only where they may.
const allowedLinks = new Set([...["README.md", "CHANGELOG.md", ...docs.map((x) => "docs/" + x)].flatMap((d) => [...read(d).matchAll(/\]\((https?:\/\/[^)\s]+)\)/g)].map((m) => m[1]))]);
for (const f of [...html, "site.css", "site.js"]) {
  const s = text(f);
  for (const m of s.matchAll(/\ssrc="(https?:[^"]*)"|url\(["']?(https?:[^"')]*)|@import\s+["']?(https?:[^"';]*)|fetch\(\s*["'](https?:[^"']*)/g)) fail(`${f} requests another site: ${m.slice(1).find(Boolean)}`);
  for (const m of s.matchAll(/<link [^>]*rel="(?:stylesheet|preload|preconnect|modulepreload|prefetch|dns-prefetch)"[^>]*>/g)) if (/href="https?:/.test(m[0])) fail(`${f} loads from another site: ${m[0]}`);
  if (/document\.cookie/.test(s)) fail(`${f} uses document.cookie`);
  if (!f.endsWith(".html")) continue;
  for (const m of s.matchAll(/<a [^>]*href="(https?:[^"]*)"/g)) {
    const u = decode(m[1]);
    if (u === REPO || u.startsWith(REPO + "/") || u === "https://www.npmjs.com/package/@tarekraafat/cabinet" || allowedLinks.has(u)) continue;
    fail(`${f} links another site the docs do not link: ${u}`);
  }
}

// 16. The pages and data files have no local path (but the capture's /Users/maya) and no handoff ID of the workspace's.
for (const f of [...html, "search.json", "doctor.json"]) {
  for (const m of text(f).matchAll(/\/(Users|home)\/[a-z][A-Za-z0-9_-]*/g)) if (m[0] !== "/Users/maya") fail(`${f} names a local path: ${m[0]}`);
  for (const w of (process.env.CABINET_PRIVATE_WORDS || "").split(/\s+/).filter(Boolean))
    if (new RegExp(`\\b${w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i").test(text(f))) fail(`${f} holds a private word`);
}

// 42. Each font file with its SIL Open Font License beside it, and no font from another host.
const fonts = files.filter((f) => /\.(woff2?|ttf|otf)$/.test(f));
if (!fonts.length) fail("the site serves no font file");
for (const f of fonts) if (!files.includes(path.posix.join(path.posix.dirname(f), "OFL.txt")) || !/SIL Open Font License/.test(text(path.posix.join(path.posix.dirname(f), "OFL.txt")))) fail(`${f} has no OFL.txt beside it`);

// 46. Every check ID in docs/troubleshooting.md is in the lookup data.
const doctor = JSON.parse(text("doctor.json"));
for (const m of read("docs/troubleshooting.md").matchAll(/^\| [^|]+ \| `([a-z][a-z0-9.-]*)` \|/gm))
  if (!doctor.some((r) => r.i === m[1])) fail(`doctor.json lacks the check ID ${m[1]}`);

// 53. 404.html at the root, every link and asset in it rooted at /cabinet/.
if (!files.includes("404.html")) fail("no 404.html at the root");
else for (const m of text("404.html").matchAll(/\s(href|src)="([^"]*)"/g)) if (!/^(https?:|#)/.test(m[2]) && !m[2].startsWith(BASE)) fail(`404.html: ${m[1]}="${m[2]}" is not rooted at ${BASE}`);

for (const p of problems) console.log("FAIL: " + p);
process.exit(problems.length ? 1 : 0);
