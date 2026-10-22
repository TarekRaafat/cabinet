// Renders the promo film: every frame of video.html through headless Chromium (the DevTools protocol over
// Node's own WebSocket), then ffmpeg encodes it and puts music.m4a under it.
//   node brand/promo/render.js                  cabinet-promo.mp4 and .webm, ending on the repository's address
//   node brand/promo/render.js --end facts      cabinet-promo-facts.mp4 and .webm, ending on what Cabinet is
//   node brand/promo/render.js --stills 2000,9000   single frames to stills/<ms>.png, to check a change
// Needs ffmpeg and a Chromium headless shell; CHROME names the shell, or the one Playwright installs is used.
const { spawn, execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

const here = __dirname;
const args = process.argv.slice(2);
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const end = opt("--end") || "address", stills = opt("--stills"), fps = 30;
// The music: its first hit is 0.05 s late, so it starts 0.05 s in; it fades from 30 s and the film ends at 32 s.
const MUSIC_START = 0.05, FADE_AT = 30, FADE_FOR = 1.5;

function findChrome() {
  if (process.env.CHROME) return process.env.CHROME;
  const cache = path.join(os.homedir(), "Library/Caches/ms-playwright"), linux = path.join(os.homedir(), ".cache/ms-playwright");
  for (const root of [cache, linux]) {
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

async function capture(dir) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "cabinet-promo-"));
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
    await send("Page.navigate", { url: "file://" + path.join(here, "video.html") + (end === "facts" ? "?end=facts" : "") + "#capture" });
    for (let i = 0; i < 200 && !events.includes("Page.loadEventFired"); i++) await new Promise((r) => setTimeout(r, 50));
    await evaluate("document.fonts.ready.then(() => 1)");
    // The fonts come from Google Fonts: without them the film would render in a fallback face.
    if (!await evaluate(`document.fonts.check('700 84px "Schibsted Grotesk"') && document.fonts.check('400 34px "JetBrains Mono"')`)) throw new Error("the fonts did not load (no network?)");
    const shot = async (t, file) => {
      await evaluate(`render(${t}); 1`);
      fs.writeFileSync(file, Buffer.from((await send("Page.captureScreenshot", { format: "png" })).data, "base64"));
    };
    if (stills) {
      for (const t of stills.split(",").map(Number)) await shot(t, path.join(dir, t + ".png"));
    } else {
      const n = Math.round(await evaluate("END") / 1000 * fps);
      for (let f = 0; f < n; f++) {
        await shot(f * 1000 / fps, path.join(dir, String(f).padStart(5, "0") + ".png"));
        if (f % 120 === 0) process.stdout.write(`frame ${f} of ${n}\n`);
      }
    }
    ws.close();
  } finally {
    const exited = new Promise((r) => proc.once("exit", r));
    proc.kill();
    await exited;
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5 });
  }
}

async function main() {
  if (stills) {
    const dir = path.join(here, "stills"); fs.mkdirSync(dir, { recursive: true });
    await capture(dir);
    return console.log("stills in " + dir);
  }
  const frames = fs.mkdtempSync(path.join(os.tmpdir(), "cabinet-promo-frames-"));
  try {
    await capture(frames);
    const name = path.join(here, end === "facts" ? "cabinet-promo-facts" : "cabinet-promo");
    const ff = (...a) => execFileSync("ffmpeg", ["-v", "error", "-y", ...a], { stdio: "inherit" });
    ff("-framerate", String(fps), "-i", path.join(frames, "%05d.png"), "-ss", String(MUSIC_START), "-i", path.join(here, "music.m4a"),
      "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "slow", "-crf", "14", "-pix_fmt", "yuv420p",
      "-c:a", "aac", "-b:a", "256k", "-af", `loudnorm=I=-16:TP=-1.5:LRA=11,afade=t=out:st=${FADE_AT}:d=${FADE_FOR}:curve=qsin`,
      "-t", "32", "-movflags", "+faststart", name + ".mp4");
    ff("-i", name + ".mp4", "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "28", "-row-mt", "1", "-c:a", "libopus", "-b:a", "160k", name + ".webm");
    console.log("wrote " + name + ".mp4 and .webm");
  } finally {
    fs.rmSync(frames, { recursive: true, force: true });
  }
}
main().catch((e) => { console.error("render.js: " + e.message); process.exit(1); });
