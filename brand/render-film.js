// Renders a brand film: every frame of its page through headless Chromium (the DevTools protocol over
// Node's own WebSocket), then ffmpeg encodes it and puts its music under it.
//   node brand/render-film.js promo                  promo/cabinet-promo.mp4 and .webm, ending on the repository's address
//   node brand/render-film.js promo --end facts      promo/cabinet-promo-facts.mp4 and .webm, ending on what Cabinet is
//   node brand/render-film.js demo                   demo/cabinet-demo.mp4 and .webm
//   node brand/render-film.js demo --capture         first run the demo's commands again (demo/capture.sh), then render
//   node brand/render-film.js <film> --stills 2000,9000   single frames to <film>/stills/<ms>.png, to check a change
// Needs ffmpeg and a Chromium headless shell (CHROME names one; otherwise the one Playwright installs is used).
const { spawn, execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

const here = __dirname;
const args = process.argv.slice(2);
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const end = opt("--end") || "address", stills = opt("--stills"), fps = 30;
// Each film: its page, its music (where the music starts, when it fades) and where it is written.
const FILMS = {
  // The promo's first hit is 0.05 s late in its track; the track fades from 30 s.
  promo: { page: "promo/video.html", query: end === "facts" ? "?end=facts" : "", music: "promo/music.m4a", start: 0.05, fadeAt: 30, fadeFor: 1.5,
    out: end === "facts" ? "promo/cabinet-promo-facts" : "promo/cabinet-promo", crf: 14 },
  // The demo's track ends on its own final chord; a short fade only keeps its last frame clean.
  demo: { page: "demo/demo.html", query: "", music: "demo/music.m4a", start: 0, fadeAt: 93.6, fadeFor: 0.7, out: "demo/cabinet-demo", crf: 16 }
};
const name = args[0], film = FILMS[name];

function findChrome() {
  if (process.env.CHROME) return process.env.CHROME;
  for (const root of [path.join(os.homedir(), "Library/Caches/ms-playwright"), path.join(os.homedir(), ".cache/ms-playwright")]) {
    if (!fs.existsSync(root)) continue;
    for (const d of fs.readdirSync(root).filter((x) => x.startsWith("chromium_headless_shell-")).sort().reverse()) {
      for (const sub of fs.readdirSync(path.join(root, d))) {
        const bin = path.join(root, d, sub, "chrome-headless-shell");
        if (fs.existsSync(bin)) return bin;
      }
    }
  }
  throw new Error("no Chromium headless shell: set CHROME, or run npx playwright install chromium-headless-shell");
}

// The demo's commands, run for real in a sandbox (demo/capture.sh), become demo/captured.js: each command's
// lines as HTML, with the terminal's bold, dim and status colors kept.
function capture() {
  execFileSync("bash", [path.join(here, "demo/capture.sh")], { stdio: "inherit" });
  const dir = path.join(here, "demo/out"), data = {};
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const CLASS = { 1: "b", 2: "d", 31: "red", 32: "green", 33: "yellow", 34: "blue" };
  const html = (line) => {
    let out = "", open = false;
    for (const part of line.split(/(\x1b\[[0-9;]*m)/)) {
      const m = part.match(/^\x1b\[([0-9;]*)m$/);
      if (!m) { out += esc(part); continue; }
      if (open) { out += "</span>"; open = false; }
      const cls = m[1].split(";").filter(Boolean).map((c) => CLASS[c]).filter(Boolean);
      if (cls.length) { out += '<span class="' + cls.join(" ") + '">'; open = true; }
    }
    return out + (open ? "</span>" : "");
  };
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith(".raw"))) {
    const key = f.replace(".raw", "");
    // script writes a ^D when the command's input ends; it is not part of the output.
    const text = fs.readFileSync(path.join(dir, f), "utf8").replace(/\r/g, "").replace(/^\^D/, "").replace(/\x08+/g, "");
    data[key] = { cmd: fs.readFileSync(path.join(dir, key + ".cmd"), "utf8").trim(), lines: text.replace(/\n+$/, "").split("\n").map(html) };
  }
  fs.writeFileSync(path.join(here, "demo/captured.js"), "// Real output of each command, captured in a sandbox by capture.sh (node brand/render-film.js demo --capture).\nvar CAPTURED = " + JSON.stringify(data, null, 1) + ";\n");
}

async function frames(dir) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "cabinet-film-"));
  const proc = spawn(findChrome(), ["--headless", "--remote-debugging-port=9333", "--window-size=1920,1080", "--hide-scrollbars",
    "--force-device-scale-factor=1", "--user-data-dir=" + profile, "about:blank"], { stdio: "ignore" });
  try {
    let target;
    for (let i = 0; i < 100 && !target; i++) {
      try { target = (await (await fetch("http://127.0.0.1:9333/json/list")).json()).find((x) => x.type === "page"); }
      catch { await new Promise((r) => setTimeout(r, 100)); }
    }
    if (!target) throw new Error("Chromium did not start");
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
    let id = 0; const waiting = new Map(), events = [];
    ws.onmessage = (m) => {
      const msg = JSON.parse(m.data);
      if (msg.id && waiting.has(msg.id)) { const w = waiting.get(msg.id); waiting.delete(msg.id); msg.error ? w.j(new Error(msg.error.message)) : w.r(msg.result); }
      else if (msg.method) events.push(msg.method);
    };
    const send = (method, params = {}) => new Promise((r, j) => { const n = ++id; waiting.set(n, { r, j }); ws.send(JSON.stringify({ id: n, method, params })); });
    const evaluate = async (expression) => {
      const res = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
      if (res.exceptionDetails) throw new Error(res.exceptionDetails.text);
      return res.result.value;
    };
    await send("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
    await send("Page.enable");
    await send("Page.navigate", { url: "file://" + path.join(here, film.page) + film.query + "#capture" });
    for (let i = 0; i < 200 && !events.includes("Page.loadEventFired"); i++) await new Promise((r) => setTimeout(r, 50));
    await evaluate("document.fonts.ready.then(() => 1)");
    // The fonts come from Google Fonts: without them the film would render in a fallback face.
    if (!await evaluate(`document.fonts.check('700 84px "Schibsted Grotesk"') && document.fonts.check('400 34px "JetBrains Mono"')`)) throw new Error("the fonts did not load (no network?)");
    const shot = async (t, file) => {
      await evaluate(`render(${t}); 1`);
      fs.writeFileSync(file, Buffer.from((await send("Page.captureScreenshot", { format: "png" })).data, "base64"));
    };
    const length = await evaluate("END");
    if (stills) for (const t of stills.split(",").map(Number)) await shot(t, path.join(dir, t + ".png"));
    else {
      const n = Math.round(length / 1000 * fps);
      for (let f = 0; f < n; f++) {
        await shot(f * 1000 / fps, path.join(dir, String(f).padStart(5, "0") + ".png"));
        if (f % 300 === 0) process.stdout.write(`frame ${f} of ${n}\n`);
      }
    }
    ws.close();
    return length;
  } finally {
    const exited = new Promise((r) => proc.once("exit", r));
    proc.kill();
    await exited;
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5 });
  }
}

async function main() {
  if (!film) throw new Error("which film: node brand/render-film.js " + Object.keys(FILMS).join("|"));
  if (args.includes("--capture")) capture();
  if (stills) {
    const dir = path.join(here, name, "stills"); fs.mkdirSync(dir, { recursive: true });
    await frames(dir);
    return console.log("stills in " + dir);
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cabinet-film-frames-"));
  try {
    const length = await frames(dir), out = path.join(here, film.out);
    const ff = (...a) => execFileSync("ffmpeg", ["-v", "error", "-y", ...a], { stdio: "inherit" });
    ff("-framerate", String(fps), "-i", path.join(dir, "%05d.png"), "-ss", String(film.start), "-i", path.join(here, film.music),
      "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "slow", "-crf", String(film.crf), "-pix_fmt", "yuv420p",
      "-c:a", "aac", "-b:a", "256k", "-af", `loudnorm=I=-16:TP=-1.5:LRA=11,afade=t=out:st=${film.fadeAt}:d=${film.fadeFor}:curve=qsin`,
      "-t", String(length / 1000), "-movflags", "+faststart", out + ".mp4");
    ff("-i", out + ".mp4", "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "28", "-row-mt", "1", "-c:a", "libopus", "-b:a", "160k", out + ".webm");
    console.log("wrote " + out + ".mp4 and .webm");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}
main().catch((e) => { console.error("render-film.js: " + e.message); process.exit(1); });
