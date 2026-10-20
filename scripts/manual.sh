#!/usr/bin/env bash
# The owner's manual as a page: OPERATIONS.html, built from OPERATIONS.md.
#
#   bin/manual.sh build [--check]
#       Write OPERATIONS.html: one self-contained page (styles and a little script inside it, nothing
#       fetched), with a table of contents, a search that narrows the page to matching sections, light
#       and dark themes, and each "- [ ]" line as a tick box remembered per viewer and per day. The
#       Markdown is escaped, so nothing in it runs; only http(s), mailto, relative and # links link.
#       The page records a fingerprint of the Markdown it was built from. --check: exit 1 when the
#       page is missing or older than OPERATIONS.md, changing nothing. Untracked, like BRIEF.md: setup,
#       cabinet update and the brief job (its AFTER) rebuild it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

m_build() {
local check=0 a src="$WS/OPERATIONS.md" out="$WS/OPERATIONS.html" sum
for a in "$@"; do case "$a" in --check) check=1 ;; *) echo "usage: bin/manual.sh build [--check]" >&2; exit 2 ;; esac; done
[[ -f "$src" ]] || { echo "no OPERATIONS.md to build the page from" >&2; exit 1; }
sum="$(sha256 "$src")"
if ((check)); then
  grep -qF "<!-- cabinet manual: $sum -->" "$out" 2>/dev/null || { echo "OPERATIONS.html is older than OPERATIONS.md (run bin/manual.sh build)"; exit 1; }
  exit 0
fi
PROJECT="$CABINET_PROJECT" SUM="$sum" python3 -I - "$src" > "$out.new" <<'PY' && [[ -s "$out.new" ]] && mv "$out.new" "$out" || { rm -f "$out.new"; echo "could not build OPERATIONS.html" >&2; exit 1; }
import html, os, re, sys

text = open(sys.argv[1], encoding="utf-8").read().replace("\r\n", "\n")
e = lambda s: html.escape(s, quote=True)

def safe_url(u):
    u = u.strip()
    if re.match(r"(?i)^(https?:|mailto:|#)", u) or not re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", u):
        return u  # web, mail, anchors and relative paths; never javascript: or data:
    return None

def inline(s):
    """Escape, then mark up code, links, bold and italics."""
    codes = []
    def keep_code(m):  # `code`, or ``code with a ` in it``
        codes.append("<code>" + e(m.group(1) or m.group(2)) + "</code>")
        return "\0%d\0" % (len(codes) - 1)
    s = re.sub(r"``\s?(.+?)\s?``|`([^`]+)`", keep_code, s)
    s = e(s)
    def link(m):
        u = safe_url(html.unescape(m.group(2)))
        return '<a href="%s">%s</a>' % (e(u), m.group(1)) if u is not None else m.group(1)
    s = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, s)
    s = re.sub(r"&lt;(https?://[^\s&]+)&gt;", lambda m: '<a href="%s">%s</a>' % (m.group(1), m.group(1)), s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", s)
    return re.sub(r"\0(\d+)\0", lambda m: codes[int(m.group(1))], s)

def slug(t, seen):
    s = re.sub(r"[^a-z0-9 -]", "", re.sub(r"<[^>]+>", "", t).lower()).strip().replace(" ", "-") or "section"
    base, n = s, 1
    while s in seen:
        n += 1
        s = "%s-%d" % (base, n)
    seen.add(s)
    return s

lines = text.split("\n")
out, toc, seen, para, i, title = [], [], set(), [], 0, ""
def flush():
    if para:
        out.append("<p>" + inline(" ".join(para)) + "</p>")
        para.clear()
def cells(row):
    row = row.strip()
    row = row[1:] if row.startswith("|") else row
    row = row[:-1] if row.endswith("|") and not row.endswith("\\|") else row
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", row)]

box = 0
while i < len(lines):
    l = lines[i]
    if not l.strip():
        flush(); i += 1; continue
    m = re.match(r"^(#{1,4})\s+(.*)$", l)
    if m:
        flush()
        n, t = len(m.group(1)), inline(m.group(2).strip())
        if n == 1 and not title:
            title = re.sub(r"<[^>]+>", "", t)
            out.append("<h1>%s</h1>" % t)
        else:
            sid = slug(t, seen)
            out.append('<h%d id="%s">%s</h%d>' % (n, sid, t, n))
            if n in (2, 3):
                toc.append((n, sid, t))
        i += 1; continue
    if l.startswith("```"):
        flush(); i += 1; code = []
        while i < len(lines) and not lines[i].startswith("```"):
            code.append(lines[i]); i += 1
        out.append("<pre><code>" + e("\n".join(code)) + "</code></pre>")
        i += 1; continue
    if l.lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{3,}", lines[i + 1]):
        flush()
        head = cells(l); i += 2
        rows = []
        while i < len(lines) and lines[i].lstrip().startswith("|"):
            rows.append(cells(lines[i])); i += 1
        out.append('<div class="table"><table><thead><tr>' + "".join("<th>%s</th>" % inline(c) for c in head) + "</tr></thead><tbody>"
                   + "".join("<tr>" + "".join("<td>%s</td>" % inline(c) for c in r) + "</tr>" for r in rows) + "</tbody></table></div>")
        continue
    if l.startswith(">"):
        flush(); q = []
        while i < len(lines) and lines[i].startswith(">"):
            q.append(lines[i][1:].strip()); i += 1
        out.append("<blockquote><p>" + inline(" ".join(q)) + "</p></blockquote>")
        continue
    if re.match(r"^\s*([-*]|\d+\.)\s+", l):
        flush()
        stack = []  # (indent, tag)
        while i < len(lines):
            m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", lines[i])
            if not m:
                if lines[i].strip() and lines[i].startswith("  ") and stack:  # a wrapped line of the item
                    out[-1] = out[-1][:-5] + " " + inline(lines[i].strip()) + "</li>"; i += 1; continue
                break
            ind, tag, body = len(m.group(1).replace("\t", "    ")), "ol" if m.group(2)[0].isdigit() else "ul", m.group(3)
            while stack and ind < stack[-1][0]:
                out.append("</%s>" % stack.pop()[1])
            if not stack or ind > stack[-1][0]:
                stack.append((ind, tag)); out.append("<%s>" % tag)
            t = re.match(r"^\[( |x|X)\]\s+(.*)$", body)
            if t:
                box += 1
                out.append('<li class="task"><label><input type="checkbox" data-box="%d"%s> %s</label></li>'
                           % (box, " checked" if t.group(1) != " " else "", inline(t.group(2))))
            else:
                out.append("<li>" + inline(body) + "</li>")
            i += 1
        while stack:
            out.append("</%s>" % stack.pop()[1])
        continue
    para.append(l.strip()); i += 1
flush()

title = title or "Operations manual"
nav = "".join('<li class="l%d"><a href="#%s">%s</a></li>' % (n, sid, re.sub(r"<a [^>]*>|</a>", "", t)) for n, sid, t in toc)
body = "\n".join(out)
# Sections for search: each h2 and what follows it.
body = re.sub(r'(<h2 id=)', r'</section><section>\1', body, count=0)
body = "<section>" + body + "</section>"
print("""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<!-- cabinet manual: %s -->
<title>%s</title>
<style>
:root{--bg:#fbfaf7;--fg:#1d1d1b;--muted:#6b6a65;--line:#e4e1d9;--accent:#2f5d8a;--code:#f1eee7}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#e8e6e1;--muted:#a19f99;--line:#33322f;--accent:#8db7e0;--code:#22211f}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.wrap{display:grid;grid-template-columns:16rem minmax(0,1fr);gap:2.5rem;max-width:72rem;margin:0 auto;padding:2rem 1rem}
nav{position:sticky;top:1rem;align-self:start;max-height:calc(100vh - 2rem);overflow:auto;font-size:.9rem}
nav ul{list-style:none;padding:0;margin:.5rem 0 0}nav li.l3{padding-left:.9rem}nav a{color:var(--muted);text-decoration:none}nav a:hover{color:var(--accent)}
input[type=search]{width:100%%;padding:.45rem .6rem;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg);font:inherit}
main{min-width:0}h1{font-size:1.9rem;line-height:1.2;margin:0 0 1rem}h2{margin-top:2.4rem;padding-top:.4rem;border-top:1px solid var(--line)}h3{margin-top:1.6rem}
a{color:var(--accent)}code{background:var(--code);padding:.05rem .3rem;border-radius:4px;font-size:.9em}
pre{background:var(--code);padding:.8rem;border-radius:6px;overflow:auto}pre code{padding:0}
.table{overflow-x:auto}table{border-collapse:collapse;width:100%%;font-size:.93rem}th,td{border-bottom:1px solid var(--line);padding:.4rem .5rem;text-align:left;vertical-align:top}
blockquote{margin:1rem 0;padding:.2rem 1rem;border-left:3px solid var(--line);color:var(--muted)}
li.task{list-style:none;margin-left:-1.2rem}li.task input{margin-right:.4rem}
.hidden{display:none}.note{color:var(--muted);font-size:.85rem}
@media (max-width:52rem){.wrap{grid-template-columns:1fr}nav{position:static;max-height:none}}
@media print{nav{display:none}.wrap{display:block}}
</style></head><body><div class="wrap">
<nav><input type="search" id="q" placeholder="Search the manual" aria-label="Search the manual"><ul>%s</ul>
<p class="note">Built from OPERATIONS.md by <code>bin/manual.sh build</code>. Tick boxes are remembered in this browser, for today.</p></nav>
<main>%s</main></div>
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
</script></body></html>""" % (os.environ["SUM"], e(title + (" - " + os.environ.get("PROJECT", "") if os.environ.get("PROJECT") and os.environ["PROJECT"] not in title else "")), nav, body))
PY
echo "Wrote OPERATIONS.html from OPERATIONS.md."
}

verb="${1:-}"; (($#)) && shift
case "$verb" in
  build) m_build "$@" ;;
  *) echo "usage: bin/manual.sh build [--check] (see the top of this file)" >&2; exit 2 ;;
esac
