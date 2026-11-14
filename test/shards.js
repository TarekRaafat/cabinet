#!/usr/bin/env node
// node test/shards.js <suite>: the whole suite in parallel shards (test/smoke.sh with no words hands it here).
// Each shard is a separate run of <suite> with CABINET_TEST_SHARD set to the section numbers it owns: its own
// mktemp -d, HOME and fakes, from the suite's own header; it also runs the sections those need, marked "(needed)".
// Shards are balanced longest first by each section's last measured time (test/.times, written after each run;
// equal counts with none). Each shard's output is printed whole when it ends, then one summary. The run passes
// only when every shard passed and every section ran exactly once as its own shard's.
// CABINET_TEST_JOBS: the number of shards (default: the CPUs, at most 8); 1 is the serial run.
"use strict";
const fs = require("node:fs"), path = require("node:path"), os = require("node:os"), cp = require("node:child_process");

const suite = process.argv[2];
const timesFile = path.join(path.dirname(suite), ".times");
const say = (s) => process.stdout.write(s + "\n");
const fmt = (s) => (s >= 60 ? Math.floor(s / 60) + "m " : "") + (s % 60) + "s";

let jobs = process.env.CABINET_TEST_JOBS;
if (jobs === undefined || jobs === "") jobs = Math.min(8, os.availableParallelism ? os.availableParallelism() : os.cpus().length);
else if (!/^[1-9][0-9]*$/.test(jobs)) { process.stderr.write(`FAIL: CABINET_TEST_JOBS is not a whole number above 0: ${jobs}\n`); process.exit(2); }
jobs = Number(jobs);
if (jobs === 1) {   // the serial run, as it always was
  const r = cp.spawnSync("bash", [suite], { stdio: "inherit", env: { ...process.env, CABINET_TEST_JOBS: "1" } });
  process.exit(r.status === null ? 1 : r.status);
}

// The section list: "<name>\t<needs>" per line, from the suite itself.
const listed = cp.spawnSync("bash", [suite], { encoding: "utf8", env: { ...process.env, CABINET_TEST_LIST: "1" } });
if (listed.status !== 0) { process.stderr.write(`FAIL: the suite did not list its sections\n${listed.stdout}${listed.stderr}`); process.exit(1); }
const names = [], needs = [];
for (const l of listed.stdout.split("\n").filter(Boolean)) { const [n, d = ""] = l.split("\t"); names.push(n); needs.push(d.split(" ").filter(Boolean).map(Number)); }
const closure = names.map((_, i) => {   // what a section needs, all the way down
  const seen = new Set(), todo = [...needs[i]];
  while (todo.length) { const d = todo.pop(); if (!seen.has(d)) { seen.add(d); todo.push(...needs[d]); } }
  return seen;
});

// Last measured times, by name; a section with none takes the mean of the rest (1 with none at all).
const known = new Map();
try { for (const l of fs.readFileSync(timesFile, "utf8").split("\n")) { const m = /^(\d+)\t(.+)$/.exec(l); if (m) known.set(m[2], Number(m[1])); } } catch {}
const have = names.filter((n) => known.has(n)).map((n) => known.get(n));
const mean = have.length ? have.reduce((a, b) => a + b, 0) / have.length : 1;
const t = names.map((n) => Math.max(known.has(n) ? known.get(n) : mean, 0.5));

// Longest first, each to the shard it adds least to (with the sections it needs that shard does not run yet).
const shards = Array.from({ length: Math.min(jobs, names.length) }, () => ({ own: [], runs: new Set(), load: 0 }));
for (const i of names.map((_, i) => i).sort((a, b) => t[b] - t[a] || a - b)) {
  let best = null, bestLoad = Infinity;
  for (const s of shards) {
    let l = s.load;
    for (const k of [i, ...closure[i]]) if (!s.runs.has(k)) l += t[k];
    if (l < bestLoad) { best = s; bestLoad = l; }
  }
  best.own.push(i); best.load = bestLoad;
  for (const k of [i, ...closure[i]]) best.runs.add(k);
}
const plan = shards.filter((s) => s.own.length).sort((a, b) => b.load - a.load).map((s) => (s.own.sort((a, b) => a - b), s));

const began = Date.now(), children = new Map();
// Stopped (Ctrl-C, a time limit): each unfinished shard's lines so far, so a section that hangs is seen.
const stop = () => {
  for (const [c, r] of children) {
    try { c.kill("SIGTERM"); } catch {}
    process.stdout.write(`\n### shard ${r.k + 1} of ${plan.length}: stopped while running\n${Buffer.concat(r.out).toString("utf8")}\n`);
  }
  process.exit(130);
};
process.on("SIGINT", stop); process.on("SIGTERM", stop);
say(`== ${names.length} sections in ${plan.length} shards (CABINET_TEST_JOBS=1 runs them one after another)`);

const results = plan.map((s, k) => new Promise((done) => {
  const c = cp.spawn("bash", ["-c", 'exec bash "$0" 2>&1', suite], { stdio: ["ignore", "pipe", "inherit"], env: { ...process.env, CABINET_TEST_SHARD: s.own.join(" ") } });
  const out = [], start = Date.now();
  children.set(c, { k, out });
  c.stdout.on("data", (b) => out.push(b));
  c.on("close", (code) => {
    children.delete(c);
    const text = Buffer.concat(out).toString("utf8"), took = Math.round((Date.now() - start) / 1000);
    say(`\n### shard ${k + 1} of ${plan.length}: ${s.own.length} sections, ${fmt(took)}, exit ${code}`);
    process.stdout.write(text.endsWith("\n") || !text ? text : text + "\n");
    done({ k, s, code, text });
  });
}));

Promise.all(results).then((rs) => {
  const ranAs = names.map(() => []), problems = [], measured = new Map(known);
  for (const r of rs) {
    for (const l of r.text.split("\n")) {
      const m = /^-- (\d+)s (.+?)( \(needed\))?$/.exec(l);
      if (!m) continue;
      measured.set(m[2], Number(m[1]));
      const i = names.indexOf(m[2]);
      if (!m[3] && i >= 0) ranAs[i].push(r.k + 1);
    }
    const lines = r.text.split("\n").filter(Boolean);
    if (r.code !== 0 || lines[lines.length - 1] !== "PASS")
      problems.push(`FAIL: shard ${r.k + 1} (exit ${r.code}), its sections: ${r.s.own.map((i) => names[i]).join("; ")}`);
  }
  const missing = names.filter((_, i) => !ranAs[i].length), twice = names.filter((_, i) => ranAs[i].length > 1);
  if (missing.length) problems.push(`FAIL: ${missing.length} of ${names.length} sections did not run: ${missing.join("; ")}`);
  if (twice.length) problems.push(`FAIL: ran more than once: ${twice.map((n) => `${n} (shards ${ranAs[names.indexOf(n)].join(", ")})`).join("; ")}`);
  try {   // the times for the next run's balance; a read-only kit (the Linux container) keeps the old ones
    fs.writeFileSync(timesFile + ".new", [...measured].map(([n, s]) => `${s}\t${n}`).join("\n") + "\n");
    fs.renameSync(timesFile + ".new", timesFile);
  } catch {}
  const ran = names.length - missing.length, sum = names.reduce((a, n) => a + (measured.get(n) || 0), 0);
  say(`\n== ${ran} of ${names.length} sections ran in ${plan.length} shards; took ${fmt(Math.round((Date.now() - began) / 1000))} (the sections' own times add up to ${fmt(sum)})`);
  if (problems.length) { for (const p of problems) process.stderr.write(p + "\n"); process.exit(1); }
  say("PASS");
});
