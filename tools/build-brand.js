// Build the brand files in brand/assets/ (and docs/logo.svg) from brand/tokens.json.
//
//   node tools/build-brand.js           write every SVG
//   node tools/build-brand.js --check   exit 1 when a file is missing or out of date (npm test runs this)
//   node tools/build-brand.js --png     also render the PNGs (macOS: uses sips)
//
// The name and the tagline are outlines from brand/text-paths.json, not text, so they look the same
// without the font installed.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const KIT = path.dirname(__dirname);
const BRAND = path.join(KIT, "brand");
const ASSETS = path.join(BRAND, "assets");
const TOKENS = JSON.parse(fs.readFileSync(path.join(BRAND, "tokens.json"), "utf8"));
const C = Object.fromEntries(Object.entries(TOKENS.color).map(([k, v]) => [k, v.value]));
const M = TOKENS.mark;

// A number as the files have always written it: 3 decimals at most, no trailing zeros.
function n(x) {
  const v = Number(x.toFixed(3));
  return Object.is(v, -0) ? "-0" : String(Number(v.toPrecision(6)));
}

// ---- the mark ----------------------------------------------------------------

// Every place but the open one: [x, y, degrees], counterclockwise from the open place.
function places() {
  const k = M.places, out = [];
  for (let i = 1; i < k; i++) {
    const a = 2 * Math.PI * i / k;
    out.push([M.ring_radius * Math.cos(a), -M.ring_radius * Math.sin(a), 360 * i / k]);
  }
  return out;
}

function chair(x, y, deg, attrs = "") {
  const w = TOKENS.chairs.seat;
  return `<g transform="translate(${n(x)} ${n(y)}) rotate(${n(-deg)})"${attrs}>` +
    `<rect x="${n(-w / 2 - 1)}" y="${n(-w / 2)}" width="${n(w)}" height="${n(w)}" rx="${n(w * 0.28)}"/>` +
    `<rect x="${n(w / 2 + 0.6)}" y="${n(-w * 0.62)}" width="${n(w * 0.26)}" height="${n(w * 1.24)}" rx="${n(w * 0.13)}"/></g>`;
}

// The mark's drawing on the 100 unit grid, centered on 0,0.
function mark({ fill, outline = null, seat = "dot", tile = null, tile_radius = null }) {
  let body = seat === "chair" ? places().map(([x, y, d]) => chair(x, y, d)).join("")
    : places().map(([x, y]) => `<circle cx="${n(x)}" cy="${n(y)}" r="${n(M.seat_diameter / 2)}"/>`).join("");
  body = `<g fill="${fill}">${body}</g>`;
  if (outline) {
    const attrs = ` fill="none" stroke="${outline}" stroke-width="${n(M.outline.stroke)}"`;
    body += seat === "chair" ? chair(M.ring_radius, 0, 0, attrs) : `<circle cx="${n(M.ring_radius)}" cy="0" r="${n(M.outline.radius)}"${attrs}/>`;
  }
  if (tile) {
    const r = tile_radius === null ? M.tile.radius : tile_radius;
    body = `<rect x="-50" y="-50" width="100" height="100" rx="${n(r)}" fill="${tile}"/><g transform="scale(${n(M.tile.mark_scale)})">${body}</g>`;
  }
  return body;
}

const svg = (body, box, w, h, label, note) =>
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${box}" width="${n(w)}" height="${n(h)}" role="img" aria-label="${label}">\n` +
  `  <!-- ${note} Built by tools/build-brand.js from brand/tokens.json; do not edit by hand. -->\n  ${body}\n</svg>\n`;

const markSvg = (note, size, kw) => svg(mark(kw), "-50 -50 100 100", size, size, "cabinet", note);

// ---- the name: outlines from brand/text-paths.json -----------------------------

const textPaths = () => JSON.parse(fs.readFileSync(path.join(BRAND, "text-paths.json"), "utf8"));

// Text `key` at `size` px with its left edge at x and its baseline at `baseline`.
const text = (t, key, size, x, baseline, fill) =>
  `<path transform="translate(${n(x)} ${n(baseline)}) scale(${n(size / t.upm)})" fill="${fill}" d="${t[key].d}"/>`;

// The name's box at `size` px: [x0, y0, x1, y1], from its bbox in font units (y up).
const box = (t, size) => t.wordmark.bbox.map((v) => v * size / t.upm);

function wordmarkSvg(fill, note) {
  const t = textPaths(), [x0, y0, x1, y1] = box(t, 64);
  return svg(text(t, "wordmark", 64, -x0, y1, fill), `0 0 ${n(x1 - x0)} ${n(y1 - y0)}`, x1 - x0, y1 - y0, "cabinet", note);
}

function lockupSvg(fill, note) {
  // Horizontal: the mark 1.1em, a gap of 0.32em, the name; the mark centered on the name's height.
  const t = textPaths(), size = 64, [x0, y0, x1, y1] = box(t, size);
  const m = 1.1 * size, gap = 0.32 * size, h = Math.max(m, y1 - y0), cy = h / 2;
  let body = `<g transform="translate(${n(m / 2)} ${n(cy)}) scale(${n(m / 100)})">${mark({ fill })}</g>`;
  body += text(t, "wordmark", size, m + gap - x0, cy + (y1 + y0) / 2, fill);
  return svg(body, `0 0 ${n(m + gap + x1 - x0)} ${n(h)}`, m + gap + x1 - x0, h, "cabinet", note);
}

function lockupStackedSvg(fill, note) {
  // Stacked: the mark 2.25em over the name, 0.44em apart, both centered.
  const t = textPaths(), size = 64, [x0, y0, x1, y1] = box(t, size);
  const m = 2.25 * size, gap = 0.44 * size, tw = x1 - x0, width = Math.max(m, tw), h = m + gap + (y1 - y0);
  let body = `<g transform="translate(${n(width / 2)} ${n(m / 2)}) scale(${n(m / 100)})">${mark({ fill })}</g>`;
  body += text(t, "wordmark", size, (width - tw) / 2 - x0, m + gap + y1, fill);
  return svg(body, `0 0 ${n(width)} ${n(h)}`, width, h, "cabinet", note);
}

function socialSvg(note) {
  // 1280 x 640, paper: the mark 260px at the left margin, the name and the tagline's lines beside it.
  const t = textPaths(), W = 1280, H = 640, pad = 96, m = 260, gap = 64;
  let body = `<rect width="${W}" height="${H}" fill="${C.paper}"/>`;
  body += `<g transform="translate(${n(pad + m / 2)} ${n(H / 2)}) scale(${n(m / 100)})">${mark({ fill: C.ink })}</g>`;
  const lines = Object.keys(t).filter((k) => /^tagline[0-9]+$/.test(k)).sort();
  const ws = 132, ts = 34, lh = 51, between = 18, wb = box(t, ws);
  const top = (H - (wb[3] + between + lh * lines.length)) / 2, x = pad + m + gap;
  body += text(t, "wordmark", ws, x - wb[0], top + wb[3], C.ink);
  lines.forEach((k, i) => { body += text(t, k, ts, x, top + wb[3] + between + lh * (i + 0.8), C.slate); });
  const label = "Cabinet: " + lines.map((k) => t[k].text).join(" ");
  return svg(body, `0 0 ${W} ${H}`, W, H, label, note);
}

function faviconSvg() {
  let body = `<style>circle{fill:${C.ink}}@media (prefers-color-scheme:dark){circle{fill:${C.mist}}}</style>`;
  body += places().map(([x, y]) => `<circle cx="${n(x)}" cy="${n(y)}" r="${n(M.seat_diameter / 2)}"/>`).join("");
  return svg(body, "-50 -50 100 100", 32, 32, "cabinet", "The favicon: the plain mark, light seats when the browser is dark.");
}

// ---- every file ----------------------------------------------------------------

function files() {
  const { ink, mist, paper, night } = C;
  const out = {
    "mark.svg": markSvg("The mark: dark seats, for light backgrounds.", 96, { fill: ink }),
    "mark-light.svg": markSvg("The mark: light seats, for dark backgrounds.", 96, { fill: mist }),
    "mark-outlined.svg": markSvg("The mark with the owner's open seat in brass, for light backgrounds.", 96, { fill: ink, outline: C.brass }),
    "mark-outlined-light.svg": markSvg("The mark with the owner's open seat in brass, for dark backgrounds.", 96, { fill: mist, outline: C["brass-light"] }),
    "logo.svg": markSvg("The mark on its own light tile: reads the same on light and dark pages.", 96, { fill: ink, tile: paper }),
    "app-icon.svg": markSvg("The dark app icon and avatar, with the owner's open seat.", 512, { fill: mist, outline: C["brass-light"], tile: night }),
    "app-icon-light.svg": markSvg("The light app icon and avatar, plain.", 512, { fill: ink, tile: paper }),
    "apple-touch-icon.svg": markSvg("The dark app icon, square: the system rounds the corners.", 180, { fill: mist, outline: C["brass-light"], tile: night, tile_radius: 0 }),
    "favicon.svg": faviconSvg(),
    "chairs.svg": markSvg("The chairs: an illustration of the mark, 96px or more, never the logo.", 192, { fill: ink, seat: "chair" }),
    "chairs-light.svg": markSvg("The chairs, light, for dark backgrounds and video.", 192, { fill: mist, seat: "chair" }),
    "chairs-owner-light.svg": markSvg("The chairs with the owner's empty chair in brass, for dark backgrounds.", 192, { fill: mist, seat: "chair", outline: C["brass-light"] }),
    "wordmark.svg": wordmarkSvg(ink, "The name, as outlines: dark, for light backgrounds."),
    "wordmark-light.svg": wordmarkSvg(mist, "The name, as outlines: light, for dark backgrounds."),
    "lockup.svg": lockupSvg(ink, "The mark and the name side by side: dark, for light backgrounds."),
    "lockup-light.svg": lockupSvg(mist, "The mark and the name side by side: light, for dark backgrounds."),
    "lockup-stacked.svg": lockupStackedSvg(ink, "The mark over the name: dark, for light backgrounds."),
    "lockup-stacked-light.svg": lockupStackedSvg(mist, "The mark over the name: light, for dark backgrounds."),
    "social-preview.svg": socialSvg("The social preview, 1280 x 640, for the repository's link preview."),
  };
  return Object.fromEntries(Object.entries(out).map(([k, v]) => [path.join(ASSETS, k), v]));
}

// PNG: [file, from, size]. sips renders SVG on macOS.
const PNGS = [
  ["favicon-16.png", "logo.svg", 16], ["favicon-32.png", "logo.svg", 32], ["favicon-48.png", "logo.svg", 48],
  ["apple-touch-icon.png", "apple-touch-icon.svg", 180],
  ["app-icon-192.png", "app-icon.svg", 192], ["app-icon-512.png", "app-icon.svg", 512],
  ["social-preview.png", "social-preview.svg", 1280],
];

function pngWidth(p) {
  if (!fs.existsSync(p)) return null;
  const head = fs.readFileSync(p).subarray(0, 24);
  return head.subarray(0, 8).equals(Buffer.from("\x89PNG\r\n\x1a\n", "latin1")) ? head.readUInt32BE(16) : null;
}

function main(argv) {
  const want = files();
  want[path.join(KIT, "docs", "logo.svg")] = want[path.join(ASSETS, "logo.svg")];
  const rel = (p) => path.relative(KIT, p);
  if (argv.includes("--check")) {
    const bad = Object.entries(want).filter(([p, s]) => !fs.existsSync(p) || fs.readFileSync(p, "utf8") !== s).map(([p]) => rel(p));
    for (const [name, , size] of PNGS) if (pngWidth(path.join(ASSETS, name)) !== size) bad.push(rel(path.join(ASSETS, name)));
    const html = fs.readFileSync(path.join(BRAND, "index.html"), "utf8");
    for (const [k, v] of Object.entries(C)) if (!html.toUpperCase().includes(v.toUpperCase())) bad.push(`brand/index.html: color ${k} ${v}`);
    for (const a of new Set([...html.matchAll(/assets\/([a-z0-9.-]+)/g)].map((m) => m[1])))
      if (!fs.existsSync(path.join(ASSETS, a))) bad.push(`brand/index.html links a missing assets/${a}`);
    if (bad.length) {
      process.stderr.write("out of date (npm run brand):\n  " + bad.sort().join("\n  ") + "\n");
      return 1;
    }
    return 0;
  }
  fs.mkdirSync(ASSETS, { recursive: true });
  for (const [p, s] of Object.entries(want)) fs.writeFileSync(p, s);
  if (argv.includes("--png"))
    for (const [name, src, size] of PNGS)
      execFileSync("sips", ["-s", "format", "png", "-Z", String(size), path.join(ASSETS, src), "--out", path.join(ASSETS, name)], { stdio: "ignore" });
  return 0;
}

process.exit(main(process.argv.slice(2)));
