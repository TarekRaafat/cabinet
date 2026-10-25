// The website's browser code: plain JavaScript, no library, no request to any other host, no cookie.
// Everything works without it; this adds search, copy buttons, the tour, the lookups and the pickers.
// localStorage keeps one flag, cabinet.intro (the logo animation has played), and nothing is sent anywhere.
(function () {
  "use strict";
  var UI = JSON.parse(document.getElementById("ui").textContent);
  var reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  var isMac = /Mac|iPhone|iPad/.test(navigator.platform || "");
  var OUT = "cubic-bezier(0.2, 0, 0, 1)", INOUT = "cubic-bezier(0.65, 0, 0.35, 1)";
  function $(s, r) { return (r || document).querySelector(s); }
  function $$(s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); }
  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;"); }
  function codeOf(s) { return esc(s).replace(/`([^`]+)`/g, "<code>$1</code>"); }
  var live = document.getElementById("live");
  function say(t) { live.textContent = ""; setTimeout(function () { live.textContent = t; }, 60); }

  // ---- Copy buttons: exactly the block's text ----
  function wireCopy(root) {
    $$(".copy", root).forEach(function (b) {
      if (b.dataset.wired) return;
      b.dataset.wired = "1"; b.hidden = false;
      b.addEventListener("click", function () {
        var box = b.closest("[data-copy]"), src = box && box.querySelector("pre, code");
        if (!src) return;
        var text = src.textContent, reset = function () { b.textContent = UI.copy.copy; };
        var ok = function () { b.textContent = UI.copy.copied; say(UI.copy.copied); setTimeout(reset, 2000); };
        var fail = function () { b.textContent = UI.copy.failed; say(UI.copy.failed); setTimeout(reset, 4000); };
        if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(ok, fail); else fail();
      });
    });
  }
  wireCopy(document);

  // ---- Header: the menu under 900 px, and the use cases menu ----
  var menuBtn = $(".menu-btn"), nav = $("#nav");
  if (menuBtn && nav) {
    menuBtn.hidden = false;
    var setMenu = function (open, focus) {
      nav.classList.toggle("open", open); menuBtn.setAttribute("aria-expanded", String(open));
      menuBtn.textContent = open ? UI.nav.close : UI.nav.menu;
      if (focus) menuBtn.focus();
    };
    menuBtn.addEventListener("click", function () { setMenu(!nav.classList.contains("open")); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && nav.classList.contains("open")) setMenu(false, true); });
  }
  var uses = $(".uses");
  if (uses) document.addEventListener("click", function (e) { if (uses.open && !uses.contains(e.target)) uses.open = false; });

  // ---- Search: a dialog on every page ----
  var dlg = $("#search"), q = $("#search-q"), results = $("#search-results"), status = $(".search-status", dlg);
  var index = null, doctor = null, loading = null, failedLoad = false, back = null, sel = -1;
  function getJson(u) { return fetch(UI.base + u).then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); }); }
  function load() {
    if (loading) return loading;
    failedLoad = false;
    var show = setTimeout(function () { status.hidden = false; }, MOTION.loading.show_after_ms);
    var done = function () { clearTimeout(show); var l = $(".loader", status); l.classList.add("done"); setTimeout(function () { status.hidden = true; l.classList.remove("done"); }, status.hidden ? 0 : MOTION.loading.done_ms); };
    loading = Promise.all([getJson("search.json"), getJson("doctor.json")]).then(function (r) {
      index = r[0]; doctor = r[1]; done(); render(); lookupRender();
    }, function () { done(); loading = null; failedLoad = true; render(); });
    return loading;
  }
  function plain(s) { return String(s).replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&amp;/g, "&").toLowerCase().replace(/\s+/g, " ").trim(); }
  function escRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }
  // A doctor line matches the row whose message it fits: <...> matches anything, the status word is ignored.
  function matchDoctor(v) {
    if (!doctor) return [];
    var x = plain(v).replace(/^(ok|note|fix) /, "");
    if (/^[a-z]+\.[a-z0-9.-]+$/.test(x)) { var byId = doctor.filter(function (r) { return r.i === x; }); if (byId.length) return byId; }
    return doctor.filter(function (r) {
      var parts = plain(r.m).replace(/^(ok|note|fix) /, "").split("<...>");
      if (parts.join("").replace(/\W/g, "").length < 8) return false;
      return new RegExp("^" + parts.map(escRe).join(".+?") + "$").test(x);
    });
  }
  function search(v) {
    var nv = plain(v), words = nv.split(" ");
    var found = [];
    index.forEach(function (e) {
      var h = plain(e.h), t = plain(e.t);
      if (!words.every(function (w) { return h.indexOf(w) >= 0 || t.indexOf(w) >= 0; })) return;
      var s = h === nv ? 300 : h.indexOf(nv) >= 0 ? 150 : 0;
      words.forEach(function (w) { if (h.indexOf(w) >= 0) s += 20; });
      if (t.indexOf(nv) >= 0) s += 10;
      found.push({ e: e, s: s });
    });
    var trouble = index.filter(function (e) { return /troubleshooting\/$/.test(e.u); })[0];
    matchDoctor(v).forEach(function (r) { found.push({ e: { u: UI.base + "docs/troubleshooting/", a: r.a, h: r.m, p: trouble ? trouble.p : "" }, s: 1000 }); });
    found.sort(function (a, b) { return b.s - a.s; });
    // Grouped by page, the page with the best match first.
    var pages = [], by = {};
    found.forEach(function (f) { if (!by[f.e.u]) { by[f.e.u] = []; pages.push(f.e.u); } if (by[f.e.u].length < 8) by[f.e.u].push(f.e); });
    return pages.map(function (u) { return by[u]; });
  }
  function note(html) { results.innerHTML = html; q.removeAttribute("aria-activedescendant"); sel = -1; }
  var browse = function () { return '<p><a href="' + UI.search.docs + '">' + esc(UI.search.browse) + "</a></p>"; };
  function render() {
    if (!dlg) return;
    var v = q.value.trim();
    if (!v) {
      // The hint is help text, outside the list: only the suggestions are options, reached with Up and Down.
      note('<p class="search-help">' + esc(UI.search.empty).replace("cabinet doctor", "<code>cabinet doctor</code>") + "</p>" + UI.search.quick.map(function (x, i) { return '<a href="' + x[1] + '" role="option" id="sq-' + i + '" aria-selected="false"><span class="h">' + esc(x[0]) + "</span></a>"; }).join(""));
      return;
    }
    if (failedLoad) { note("<p>" + esc(UI.search.failed) + "</p>" + browse()); return; }
    if (!index) return;
    var groups = search(v), n = 0, html = "";
    if (!groups.length) { note("<p>" + esc(UI.search.none.replace("<query>", function () { return v; })) + "</p>" + browse()); return; }
    groups.forEach(function (g) {
      html += '<div class="group">' + g[0].p + "</div>";
      g.forEach(function (e) { html += '<a href="' + e.u + (e.a ? "#" + e.a : "") + '" role="option" id="sr-' + n++ + '" aria-selected="false"><span class="h">' + e.h + '</span><span class="p">' + e.p + "</span></a>"; });
    });
    note(html); select(0);
  }
  function select(i) {
    var opts = $$("a[role=option]", results);
    if (!opts.length) return;
    sel = (i + opts.length) % opts.length;
    opts.forEach(function (o, n) { o.setAttribute("aria-selected", String(n === sel)); });
    if (opts[sel].id) q.setAttribute("aria-activedescendant", opts[sel].id);
    opts[sel].scrollIntoView({ block: "nearest" });
  }
  function openSearch(text) {
    if (!dlg || dlg.open) return;
    back = document.activeElement;
    dlg.showModal();
    if (typeof text === "string") q.value = text;
    q.focus();
    load(); render();
  }
  if (dlg) {
    q.addEventListener("input", render);
    q.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") { e.preventDefault(); select(sel + 1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); select(sel - 1); }
      else if (e.key === "Enter") {
        var o = $$("a[role=option]", results)[Math.max(sel, 0)];
        if (o) { e.preventDefault(); dlg.close(); location.href = o.href; }
      }
    });
    results.addEventListener("click", function (e) { if (e.target.closest("a")) dlg.close(); });
    $(".close", dlg).addEventListener("click", function () { dlg.close(); });
    dlg.addEventListener("click", function (e) { if (e.target === dlg) dlg.close(); });
    dlg.addEventListener("keydown", function (e) { if (e.key === "Escape") { e.preventDefault(); dlg.close(); } });
    dlg.addEventListener("close", function () { if (back && back.focus && document.contains(back)) back.focus(); });
    $$("[data-search]").forEach(function (a) { a.addEventListener("click", function (e) { e.preventDefault(); openSearch(); }); });
    document.addEventListener("keydown", function (e) {
      var t = e.target, typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
      if (e.key === "/" && !typing && !e.ctrlKey && !e.metaKey && !e.altKey) { e.preventDefault(); openSearch(); }
      else if ((e.key === "k" || e.key === "K") && !e.altKey && (e.ctrlKey || (isMac && e.metaKey))) { e.preventDefault(); openSearch(); }
    });
  }
  var nfs = $(".nf-search");
  if (nfs) { nfs.hidden = false; nfs.addEventListener("input", function () { var v = nfs.value; nfs.value = ""; openSearch(v); }); }

  // ---- Doctor message lookup (troubleshooting page) ----
  var lk = $(".lookup"), lkIn = lk && $(".lookup-q", lk), lkOut = lk && $(".lookup-out", lk);
  function lookupRender() {
    if (!lk || !doctor) return;
    var v = lkIn.value.trim();
    if (!v) { lkOut.innerHTML = ""; return; }
    var rows = matchDoctor(v);
    if (!rows.length) { lkOut.innerHTML = "<p>" + esc(UI.lookup.none) + "</p>"; return; }
    lkOut.innerHTML = rows.map(function (r) {
      var word = r.s === "fix" ? "FIX" : r.s, msg = word ? r.m.replace(/^(ok|note|FIX) /, "") : r.m;
      return '<div class="card"><p class="msg">' + (word ? '<span class="status ' + r.s + '">' + word + "</span> " : "") + msg + "</p><dl><dt>" + esc(UI.lookup.check) + "</dt><dd><code>" + (r.i || "-") + "</code></dd><dt>" + esc(UI.lookup.cause) + "</dt><dd>" + r.c + "</dd><dt>" + esc(UI.lookup.fix) + '</dt><dd class="fix">' + r.f + "</dd></dl></div>";
    }).join("");
    $$(".fix code", lkOut).forEach(function (c) {
      var box = document.createElement("span"); box.className = "cmd-inline"; box.setAttribute("data-copy", "");
      c.parentNode.insertBefore(box, c); box.appendChild(c);
      var b = document.createElement("button"); b.type = "button"; b.className = "copy"; b.textContent = UI.copy.copy; box.appendChild(b);
    });
    wireCopy(lkOut);
  }
  if (lk) { lk.hidden = false; lkIn.addEventListener("input", function () { if (!doctor) load(); lookupRender(); }); }

  // ---- Home: the logo animation once, then the terminal ----
  var intro = $(".hero-mark .intro"), first = false;
  if (intro) {
    // Played once, on the first visit: the flag is written as it starts. No storage, no animation.
    try { first = !localStorage.getItem("cabinet.intro"); if (first) localStorage.setItem("cabinet.intro", "1"); } catch (e) { first = false; }
  }
  document.documentElement.classList.remove("intro-wait");
  var introMs = 0;
  if (intro && first && !reduce) {
    var I = MOTION.intro, seatsEl = $$("circle[data-k]", intro), owner = $(".owner", intro);
    var pos = function (k) { var a = k * Math.PI / 4; return { x: 36 * Math.cos(a), y: -36 * Math.sin(a) }; };
    owner.animate([{ opacity: 0, transform: "translate(-36px, 0)" }, { opacity: 1, transform: "translate(-36px, 0)" }], { duration: 500, easing: INOUT, fill: "both" });
    seatsEl.forEach(function (s) {
      var k = +s.getAttribute("data-k"), p = pos(k); s.style.transformBox = "fill-box"; s.style.transformOrigin = "center";
      s.animate([{ opacity: 0, transform: "translate(" + -p.x + "px," + -p.y + "px) scale(" + I.seat_from_scale + ")" }, { opacity: 1, offset: 0.3 }, { opacity: 1, transform: "none" }],
        { delay: I.seats_from_ms + I.seat_stagger_ms * Math.abs(k - 4), duration: I.seat_ms, easing: OUT, fill: "both" });
    });
    owner.animate([{ transform: "translate(-36px, 0)" }, { transform: "none" }], { delay: I.owner_home_from_ms, duration: I.owner_home_ms, easing: INOUT, fill: "both", composite: "replace" });
    introMs = Math.max(I.owner_home_from_ms + I.owner_home_ms, I.seats_from_ms + I.seat_stagger_ms * 3 + I.seat_ms);
  }
  var term = $("#hero-term");
  if (term) {
    var out = $(".term-out", term), ctr = $(".term-controls"), pauseB = $(".pause", ctr), replayB = $(".replay", ctr);
    Array.prototype.slice.call(out.childNodes).forEach(function (n) { if (n.nodeType === 3) out.removeChild(n); });
    var lines = $$(".ln", out), typed = $(".typed", out), cmd = typed.textContent, caret = document.createElement("span");
    caret.className = "caret"; caret.setAttribute("aria-hidden", "true");
    var timer = null, paused = false, ch = 0, i = 1, follow = true, done = false;
    var setPause = function (p) { paused = p; pauseB.textContent = p ? UI.terminal.play : UI.terminal.pause; pauseB.setAttribute("aria-pressed", String(p)); };
    var all = function () { clearTimeout(timer); typed.textContent = cmd; lines.forEach(function (l) { l.hidden = false; }); caret.remove(); done = true; };
    var tick = function () {
      if (paused || done) return;
      if (ch < cmd.length) { typed.textContent = cmd.slice(0, ++ch); timer = setTimeout(tick, 35); return; }
      if (i < lines.length) { lines[i++].hidden = false; if (follow) out.scrollTop = out.scrollHeight; timer = setTimeout(tick, 40); return; }
      caret.remove(); done = true;
    };
    var start = function () {
      clearTimeout(timer); setPause(false); done = false; follow = true; out.scrollTop = 0;
      if (reduce) { all(); return; }
      ch = 0; i = 1; typed.textContent = ""; typed.parentNode.appendChild(caret);
      lines.forEach(function (l, n) { l.hidden = n > 0; });
      tick();
    };
    out.addEventListener("scroll", function () { follow = out.scrollTop + out.clientHeight >= out.scrollHeight - 8; });
    pauseB.addEventListener("click", function () { if (done) return; setPause(!paused); if (!paused) tick(); });
    replayB.addEventListener("click", start);
    ctr.hidden = false;
    if (reduce) { pauseB.hidden = true; all(); }
    else { lines.forEach(function (l, n) { l.hidden = n > 0; }); typed.textContent = ""; setTimeout(start, introMs); }
  }

  // ---- Tour: meet the team ----
  var ring = $(".chairs-ring");
  if (ring) {
    var roles = JSON.parse($("#roles").textContent), panel = $(".role-panel"), rName = $(".role-name", panel), rDesc = $(".role-desc", panel), ownerTpl = $("#owner-panel").content;
    var seats = $$(".seat", ring), chips = $$(".chip-btn[data-role]", panel);
    panel.hidden = false;
    var choose = function (btn) {
      seats.concat(chips).forEach(function (b) { b.setAttribute("aria-pressed", String(b === btn)); });
      var r = btn.getAttribute("data-role");
      if (r) { rName.textContent = r; rDesc.innerHTML = roles[r]; }
      else { rName.textContent = $(".role-name", ownerTpl).textContent; rDesc.textContent = $(".role-desc", ownerTpl).textContent; }
    };
    seats.forEach(function (b, n) {
      b.addEventListener("click", function () { choose(b); });
      b.addEventListener("keydown", function (e) {
        var d = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0;
        if (!d) return;
        e.preventDefault(); var to = seats[(n + d + seats.length) % seats.length]; to.focus(); choose(to);
      });
    });
    chips.forEach(function (b) { b.addEventListener("click", function () { choose(b); }); });
    $$(".chairs-pic [data-k]").forEach(function (g) {
      g.addEventListener("click", function () { var b = seats.filter(function (s) { return s.getAttribute("data-k") === g.getAttribute("data-k"); })[0]; if (b) choose(b); });
    });
    choose(seats[0]);
    // "Pull up a chair", once on a first visit, the first time half the picture is in view.
    if (first && !reduce && "IntersectionObserver" in window) {
      var anims = [], order = [2, 3, 4, 5, 6, 7, 1], step = MOTION.chair[0] + (MOTION.chair[1] - MOTION.chair[0]) / 2;
      var ownerChair = $(".chairs-pic .owner-chair", ring);
      anims.push(ownerChair.animate([{ opacity: 0, transform: "translate(-36px, 0)" }, { opacity: 1, transform: "translate(-36px, 0)" }], { duration: step, easing: INOUT, fill: "both" }));
      order.forEach(function (k, n) {
        var a = k * Math.PI / 4, g = $('.chairs-pic > g > [data-k="' + k + '"]', ring);
        anims.push(g.animate([{ opacity: 0, transform: "translate(" + 20 * Math.cos(a) + "px," + -20 * Math.sin(a) + "px)" }, { opacity: 1, transform: "none" }], { delay: step + 100 * n, duration: step, easing: INOUT, fill: "both" }));
      });
      anims.push(ownerChair.animate([{ transform: "translate(-36px, 0)" }, { transform: "none" }], { delay: step * 2 + 100 * 6, duration: step, easing: INOUT, fill: "both", composite: "replace" }));
      anims.push.apply(anims, seats.map(function (s) { return s.animate([{ opacity: 0 }, { opacity: 1 }], { delay: step * 3 + 600, duration: 150, fill: "both" }); }));
      anims.forEach(function (x) { x.pause(); });
      var seen = new IntersectionObserver(function (es) { if (es[0].isIntersecting) { seen.disconnect(); anims.forEach(function (x) { x.play(); }); } }, { threshold: 0.5 });
      seen.observe(ring);
    }
  }

  // ---- Tour: one piece of work, step by step ----
  var stepper = $(".stepper");
  if (stepper) {
    var stepEls = $$(".step", stepper), tabs = $$(".step-tab", stepper), sc = $(".step-controls", stepper);
    var backB = $(".back", sc), nextB = $(".next", sc), againB = $(".again", sc), of = $(".step-of", sc), cur = 0;
    $(".step-tabs", stepper).hidden = false; sc.hidden = false;
    var show = function (n) {
      cur = Math.max(0, Math.min(stepEls.length - 1, n));
      stepEls.forEach(function (s, i) { s.classList.toggle("on", i === cur); });
      tabs.forEach(function (t, i) { t.setAttribute("aria-pressed", String(i === cur)); });
      of.textContent = UI.step.replace("N", String(cur + 1));
      backB.disabled = cur === 0; nextB.hidden = cur === stepEls.length - 1; againB.hidden = !nextB.hidden;
    };
    tabs.forEach(function (t, i) { t.addEventListener("click", function () { show(i); }); });
    backB.addEventListener("click", function () { show(cur - 1); });
    nextB.addEventListener("click", function () { show(cur + 1); if (nextB.hidden) againB.focus(); });
    againB.addEventListener("click", function () { show(0); nextB.focus(); });
    stepper.addEventListener("keydown", function (e) {
      if (e.target !== stepper && !e.target.classList.contains("step-tab")) return;
      if (e.key === "ArrowRight") { e.preventDefault(); show(cur + 1); } else if (e.key === "ArrowLeft") { e.preventDefault(); show(cur - 1); }
    });
    show(0);
  }

  // ---- Film: loaded only when played ----
  var film = $(".film");
  if (film) {
    var video = $("video", film), playB = $(".play-film", film), filmErr = $(".film-error");
    // One play control before it starts: the button; the native controls come back once it plays.
    video.controls = false; playB.hidden = false;
    playB.addEventListener("click", function () { playB.hidden = true; video.controls = true; var p = video.play(); if (p && p.catch) p.catch(function () {}); video.focus(); });
    video.addEventListener("play", function () { playB.hidden = true; video.controls = true; });
    var srcs = $$("source", video), lastSrc = srcs[srcs.length - 1];
    var broken = function () { filmErr.hidden = false; playB.hidden = true; };
    if (lastSrc) lastSrc.addEventListener("error", broken);
    video.addEventListener("error", broken);
  }

  // ---- Tabs (install): the visitor's system first, from navigator.platform, sent nowhere ----
  $$("[data-tabs]").forEach(function (box) {
    var list = $(".tablist", box), ts = $$("[role=tab]", box), panels = $$("[role=tabpanel]", box);
    list.hidden = false;
    var pick = function (i, focus) {
      ts.forEach(function (t, n) { t.setAttribute("aria-selected", String(n === i)); t.tabIndex = n === i ? 0 : -1; panels[n].hidden = n !== i; });
      if (focus) ts[i].focus();
    };
    ts.forEach(function (t, i) {
      t.addEventListener("click", function () { pick(i); });
      t.addEventListener("keydown", function (e) {
        var n = e.key === "ArrowRight" ? i + 1 : e.key === "ArrowLeft" ? i - 1 : e.key === "Home" ? 0 : e.key === "End" ? ts.length - 1 : null;
        if (n === null) return;
        e.preventDefault(); pick((n + ts.length) % ts.length, true);
      });
    });
    pick(/Linux/.test(navigator.platform || "") && !/Android/.test(navigator.userAgent) ? 1 : 0);
  });

  // ---- FAQ: guardrails by agent tool ----
  var rg = $(".picker [role=radiogroup]");
  if (rg) {
    var radios = $$("[role=radio]", rg), toolGroups = $$(".tool-group");
    rg.hidden = false;
    var pickTool = function (i, focus) {
      radios.forEach(function (r, n) { r.setAttribute("aria-checked", String(n === i)); r.tabIndex = n === i ? 0 : -1; });
      var tool = radios[i].getAttribute("data-tool");
      toolGroups.forEach(function (g) { g.classList.toggle("on", JSON.parse(g.getAttribute("data-tools")).indexOf(tool) >= 0); });
      if (focus) radios[i].focus();
    };
    radios.forEach(function (r, i) {
      r.addEventListener("click", function () { pickTool(i); });
      r.addEventListener("keydown", function (e) {
        var d = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 0;
        if (!d) return;
        e.preventDefault(); pickTool((i + d + radios.length) % radios.length, true);
      });
    });
    pickTool(0);
  }

  // ---- Changelog: upgrade notes between two versions ----
  var up = $(".upgrade");
  if (up) {
    var fromS = $(".from", up), toS = $(".to", up), upOut = $(".upgrade-out", up), vers = $$(".ver"), C = UI.changelog;
    var cmp = function (a, b) { a = a.split(".").map(Number); b = b.split(".").map(Number); return a[0] - b[0] || a[1] - b[1] || a[2] - b[2]; };
    up.hidden = false;
    var apply = function () {
      if (cmp(fromS.value, toS.value) > 0) { var x = fromS.value; fromS.value = toS.value; toS.value = x; }
      var f = fromS.value, t = toS.value;
      if (f === t) { vers.forEach(function (v) { v.classList.add("out"); }); upOut.innerHTML = "<p>" + esc(C.same.replace("X.Y.Z", f)) + "</p>"; return; }
      var inRange = vers.filter(function (v) { var n = v.getAttribute("data-v"); return cmp(n, f) > 0 && cmp(n, t) <= 0; });
      vers.forEach(function (v) { v.classList.toggle("out", inRange.indexOf(v) < 0); });
      upOut.innerHTML = "<h3>" + esc(C.range.replace("X.Y.Z", f).replace("X.Y.Z", t)) + '</h3><div class="card"><p class="label">' + codeOf(C.byHand) + "</p>" +
        inRange.map(function (v) { return "<p><strong>" + esc(v.getAttribute("data-v")) + "</strong></p>" + $(".byhand", v).innerHTML; }).join("") + "</div>";
    };
    fromS.addEventListener("change", apply); toS.addEventListener("change", apply);
    $(".reset", up).addEventListener("click", function () { vers.forEach(function (v) { v.classList.remove("out"); }); upOut.innerHTML = ""; });
  }

  // ---- Cabinet words: Escape hides the card, a tap toggles it ----
  // The card is placed at the line of the term the pointer or focus is on (a term can wrap across lines), kept at
  // least 16 px inside the viewport, below the term or above it when there is no room below.
  var GAP = 6, EDGE = 16;
  function placeTip(t, x, y) {
    var tip = t.querySelector(".tip");
    if (!tip || getComputedStyle(tip).display === "none") return;
    var rects = Array.prototype.slice.call(t.getClientRects()), r = rects[0];
    if (typeof x === "number") rects.forEach(function (q) { if (y >= q.top && y <= q.bottom && x >= q.left - 1 && x <= q.right + 1) r = q; });
    else if (t._line) r = rects[Math.min(t._line, rects.length - 1)];
    if (!r) return;
    t._line = rects.indexOf(r);
    tip.style.maxWidth = Math.min(320, innerWidth - 2 * EDGE) + "px";
    var w = tip.offsetWidth, h = tip.offsetHeight;
    var left = Math.max(EDGE, Math.min(r.left, innerWidth - EDGE - w));
    var top = r.bottom + GAP + h <= innerHeight - EDGE || r.top - GAP - h < EDGE ? r.bottom + GAP : r.top - GAP - h;
    tip.style.left = left + "px"; tip.style.top = top + "px";
  }
  function placeOpen() { $$(".term:hover, .term:focus, .term.open").forEach(function (t) { placeTip(t); }); }
  addEventListener("scroll", placeOpen, { passive: true }); addEventListener("resize", placeOpen);
  $$(".term").forEach(function (t) {
    t.addEventListener("mouseenter", function (e) { t._line = 0; placeTip(t, e.clientX, e.clientY); });
    t.addEventListener("mousemove", function (e) { if (t._moved) return; t._moved = true; placeTip(t, e.clientX, e.clientY); });
    t.addEventListener("focus", function () { if (!t.matches(":hover")) { t._line = 0; placeTip(t); } });
    t.addEventListener("click", function (e) { t.classList.remove("closed"); t.classList.toggle("open"); placeTip(t, e.clientX, e.clientY); });
    t.addEventListener("blur", function () { t.classList.remove("open", "closed"); });
    t.addEventListener("mouseleave", function () { t.classList.remove("closed"); t._moved = false; });
  });
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Escape") return;
    $$(".term:hover, .term:focus, .term.open").forEach(function (t) { t.classList.remove("open"); t.classList.add("closed"); });
  });

  // ---- Docs: where you are in "On this page" ----
  var toc = $(".toc");
  if (toc) {
    var tl = $$("a", toc), heads = tl.map(function (a) { return document.getElementById(decodeURIComponent(a.hash.slice(1))); });
    var spy = function () {
      var c = 0;
      heads.forEach(function (h, i) { if (h && h.getBoundingClientRect().top < 120) c = i; });
      tl.forEach(function (a, i) { a.classList.toggle("here", i === c); if (i === c) a.setAttribute("aria-current", "location"); else a.removeAttribute("aria-current"); });
    };
    addEventListener("scroll", function () { requestAnimationFrame(spy); }, { passive: true });
    spy();
  }
})();
