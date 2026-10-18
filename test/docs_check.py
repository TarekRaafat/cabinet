"""Fails when the docs fall behind the code. Run by test/smoke.sh: python3 -I test/docs_check.py <kit>"""
import json, os, re, sys

kit = sys.argv[1]
read = lambda p: open(os.path.join(kit, p), encoding="utf-8").read()
problems = []

# The command table in bin/cabinet is the one list of commands and options. Check the
# option parsers and the dispatcher against it, then the docs against it.
cabinet, commands = read("bin/cabinet"), read("docs/commands.md")
table = cabinet[cabinet.index("<<'TABLE'\n") + 10:cabinet.index("\nTABLE\n")]
rows = [r.split("\t") for r in table.split("\n")]
cmds = [r[2] for r in rows if r[0] == "C"]
opts = {}
for r in rows:
    if r[0] == "O":
        for c in r[1].split():
            opts.setdefault(c, set()).add(r[2])
            if c not in cmds:
                problems.append(f"bin/cabinet table: option {r[2]} names the unknown command {c}")
dispatch = cabinet[cabinet.rindex('case "${1:-}" in'):]
dispatched = set(re.findall(r"^  ([a-z]+)[|)]", dispatch, re.M))
for c in sorted(dispatched ^ set(cmds)):
    problems.append(f"bin/cabinet: the command {c} is " + ("dispatched but not in the table" if c in dispatched else "in the table but not dispatched"))
# Every option a parser accepts is in the table, for that command.
parsers = {"setup": ["new", "init", "config"], "cmd_config": ["config"], "cmd_next": ["next"], "cmd_remove": ["remove"],
           "cmd_status": ["status"], "cmd_help": ["help"], "cmd_list": ["list"], "cmd_digest": ["digest"]}
sources = {fn: cabinet[cabinet.index(fn + "() {"):] for fn in parsers}
sources["doctor.sh"], parsers["doctor.sh"] = read("scripts/doctor.sh"), ["doctor"]
sources["handoffs.sh"], parsers["handoffs.sh"] = read("scripts/handoffs.sh"), ["handoffs"]
sources["bootstrap.sh"], parsers["bootstrap.sh"] = read("scripts/bootstrap.sh"), ["bootstrap"]
for fn, src in sources.items():
    body = src[:src.index("done")]
    for o in set(re.findall(r"(?<![\w-])(--[a-z][a-z-]*)(?=[|)\"])", body)) - {"--help"}:  # --help is every command's
        if not any(o in opts.get(c, ()) for c in parsers[fn]):
            problems.append(f"bin/cabinet table: {fn} accepts {o}, which the table does not list for {' or '.join(parsers[fn])}")
# Every command and option in the table is in docs/commands.md.
for c in cmds:
    if f"cabinet {c}" not in commands:
        problems.append(f"docs/commands.md does not mention the command cabinet {c}")
for o in sorted(set().union(*opts.values())):
    if "`" + o not in commands and " " + o not in commands:
        problems.append(f"docs/commands.md does not mention the option {o}")

# Every workspace script is in docs/commands.md.
for f in sorted(os.listdir(os.path.join(kit, "scripts"))):
    if f.endswith(".sh") and f not in ("lib.sh", "when.sh") and f"bin/{f}" not in commands:
        problems.append(f"docs/commands.md does not mention bin/{f}")

# Every doctor message, as its fixed pieces, is in docs/troubleshooting.md.
trouble = read("docs/troubleshooting.md")
expansion = r"\$\((?:[^()]|\([^()]*\))*\)|\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\\\$"
for kind, cid, msg in re.findall(r'\b(bad|note) ([a-z.-]+) "((?:[^"\\]|\\.)*)"', read("scripts/doctor.sh")):
    if f"`{cid}`" not in trouble:
        problems.append(f"docs/troubleshooting.md does not list the doctor check ID {cid}")
    for piece in re.split(expansion, msg):
        piece = piece.replace("\\", "").strip(" :,.'(/")
        if len(piece) >= 4 and piece not in trouble:
            problems.append(f"docs/troubleshooting.md lacks the doctor message piece: {piece!r}")

# Every docs page is in llms.txt; every relative link resolves; the package ships the docs.
llms = read("llms.txt")
for f in sorted(os.listdir(os.path.join(kit, "docs"))):
    if f.endswith(".md") and f"docs/{f}" not in llms:
        problems.append(f"llms.txt does not list docs/{f}")
pages = ["README.md", "llms.txt", "AGENTS.md", "core/CABINET.md"] + ["docs/" + f for f in os.listdir(os.path.join(kit, "docs")) if f.endswith(".md")]
# GitHub's heading anchors: lowercase, punctuation dropped, spaces to dashes.
def anchors(path):
    text = re.sub(r"```.*?```", "", open(path, encoding="utf-8").read(), flags=re.S)
    return {re.sub(r"[^\w\- ]", "", h.strip().lower()).replace(" ", "-") for h in re.findall(r"^#+ (.+)$", text, re.M)}
for page in pages:
    for link, anchor in re.findall(r"\]\(([^)#\s]*)(?:#([^)\s]*))?\)", read(page)):
        if re.match(r"[a-z]+://", link):
            continue
        target = os.path.normpath(os.path.join(kit, os.path.dirname(page), link)) if link else os.path.join(kit, page)
        if not os.path.exists(target):
            problems.append(f"{page} links to a missing file: {link}")
        elif anchor and target.endswith(".md") and anchor not in anchors(target):
            problems.append(f"{page} links to a missing heading: {link}#{anchor}")
files = json.loads(read("package.json"))["files"]
for need in ("docs", "llms.txt", "llms-full.txt", "ROADMAP.md", "AGENTS.md", "CHANGELOG.md"):
    if need not in files:
        problems.append(f"package.json files does not ship {need}")

for p in problems:
    print("FAIL: " + p)
sys.exit(1 if problems else 0)
