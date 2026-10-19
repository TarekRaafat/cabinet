"""Fails when the docs fall behind the code. Run by test/smoke.sh: python3 -I test/docs_check.py <kit>"""
import json, os, re, sys

kit = sys.argv[1]
read = lambda p: open(os.path.join(kit, p), encoding="utf-8").read()
problems = []

# The command table in bin/cabinet is the one list of commands and options. Check the
# option parsers and the dispatcher against it, then the conventions (AGENTS.md, "Command
# conventions"), then the docs against it.
cabinet, commands, agents = read("bin/cabinet"), read("docs/commands.md"), read("AGENTS.md")
table = cabinet[cabinet.index("<<'TABLE'\n") + 10:cabinet.index("\nTABLE\n")]
rows = [r.split("\t") for r in table.split("\n")]
cmds = [r[2] for r in rows if r[0] == "C"]
opts = {}
for r in rows:
    if r[0] == "O":
        for c in r[1].split(","):
            opts.setdefault(c, set()).add(r[2])
            if c not in cmds:
                problems.append(f"bin/cabinet table: option {r[2]} names the unknown command {c}")
nouns = sorted({c.split(" ")[0] for c in cmds if " " in c})
words = [c for c in cmds if " " not in c]
dispatch = cabinet[cabinet.rindex('case "${1:-}" in'):]
dispatched = set(re.findall(r"^  ([a-z]+)[|)]", dispatch, re.M))
for c in sorted(dispatched ^ (set(words) | set(nouns))):
    problems.append(f"bin/cabinet: the command {c} is " + ("dispatched but not in the table" if c in dispatched else "in the table but not dispatched"))

# Every option a parser accepts is in the table, for one of its commands. A script serves a
# noun (bin/<noun>.sh <verb>) or a one-word command (bin/<command>.sh).
fn_of = lambda fn: cabinet[cabinet.index(fn + "() {"):cabinet.index("\n}\n", cabinet.index(fn + "() {"))]
sources = {"setup": (fn_of("setup"), ["new", "init", "config"]), "cmd_config": (fn_of("cmd_config"), ["config"])}
for fn, c in [("cmd_next", "next"), ("cmd_remove", "remove"), ("cmd_status", "status"), ("cmd_help", "help"), ("cmd_list", "list"),
              ("cmd_digest", "digest"), ("cmd_outdated", "outdated"), ("cmd_version", "version"), ("cmd_changelog", "changelog")]:
    sources[fn] = (fn_of(fn), [c])
sources["cmd_role"] = (fn_of("cmd_role"), [c for c in cmds if c.startswith("role ")])
sources["cmd_repo"] = (fn_of("cmd_repo"), [c for c in cmds if c.startswith("repo ")])
for f in sorted(os.listdir(os.path.join(kit, "scripts"))):
    name = f[:-3]
    if not f.endswith(".sh") or name in ("lib", "when", "platform"):
        continue
    if name in nouns:
        sources[f] = (read("scripts/" + f), [c for c in cmds if c.startswith(name + " ")])
    elif name in words:
        sources[f] = (read("scripts/" + f), [name])
    else:
        problems.append(f"scripts/{f} is neither a noun's script nor a one-word command's (AGENTS.md, \"Command conventions\" 7)")
for n in nouns:
    if not os.path.exists(os.path.join(kit, "scripts", n + ".sh")) and n not in ("role", "repo"):
        problems.append(f"the noun {n} has no script scripts/{n}.sh (AGENTS.md, \"Command conventions\" 7)")
for fn, (src, owners) in sources.items():
    # Options as a parser reads them: case labels ("--x)", "-y|--yes)", "--a|--b)") and [[ $a == --x ]] tests.
    found = set(re.findall(r"\[\[ \"\$\{?\w+(?::-)?\}?\" == (--[a-z][a-z-]*) \]\]", src))
    for label in re.findall(r"(?:^|\bin |;; |\( )\s*((?:-[a-zA-Z]\|)?--[a-z][a-z-]*(?:\|--?[a-z][a-z-]*)*)\)", src, re.M):
        found |= {o for o in label.split("|") if o.startswith("--")}
    for o in found - {"--help"}:  # --help is every command's
        if not any(o in opts.get(c, ()) for c in owners):
            problems.append(f"bin/cabinet table: {fn} accepts {o}, which the table does not list for {' or '.join(owners)}")

# The conventions a script can check.
verbs = re.findall(r"^   \| `([a-z]+)` \|", agents[agents.index("3. **Verbs come from one list"):], re.M)
for c in cmds:
    if " " in c and c.split(" ")[1] not in verbs:
        problems.append(f"bin/cabinet table: '{c}' uses a verb that is not in AGENTS.md, \"Command conventions\" 3")
for n in nouns:
    if n.endswith("s"):
        problems.append(f"bin/cabinet table: the noun '{n}' is plural (AGENTS.md, \"Command conventions\" 2)")
for c in cmds:
    if c + "s" in cmds or c + "es" in cmds:
        problems.append(f"bin/cabinet table: '{c}' and its plural are both commands (AGENTS.md, \"Command conventions\" 2)")
reports = ["next", "digest", "list", "doctor", "status", "outdated", "changelog", "version", "help"] + \
          [c for c in cmds if c.split(" ")[-1] in ("list", "check", "verify")]
for c in reports:
    if "--json" not in opts.get(c, ()):
        problems.append(f"bin/cabinet table: '{c}' reports but has no --json (AGENTS.md, \"Command conventions\" 5)")
exceptions = re.search(r"Known exceptions, each on the roadmap: (.*)", agents).group(1)
for c in ["new", "init", "config", "bootstrap", "move", "remove", "update"] + [c for c in cmds if c.split(" ")[0] in ("role", "repo") and c.split(" ")[1] in ("add", "remove")]:
    if "--dry-run" not in opts.get(c, ()) and f"`{c}` has no `--dry-run`" not in exceptions:
        problems.append(f"bin/cabinet table: '{c}' changes the setup but has no --dry-run (AGENTS.md, \"Command conventions\" 5)")
for c, os_ in opts.items():
    for o in os_:
        if not re.fullmatch(r"--[a-z]+(-[a-z]+)*", o):
            problems.append(f"bin/cabinet table: option {o} of {c} is not lowercase words joined by dashes")
# Usage errors exit 2: no "unknown option" is reported through die (exit 1).
if re.search(r'\bdie "unknown (option|command)', cabinet):
    problems.append("bin/cabinet: an unknown option or command exits through die (1), not bad_usage (2)")

# Every command and option in the table is in docs/commands.md.
for c in cmds:
    if f"cabinet {c}" not in commands:
        problems.append(f"docs/commands.md does not mention the command cabinet {c}")
for o in sorted(set().union(*opts.values())):
    if "`" + o not in commands and " " + o not in commands:
        problems.append(f"docs/commands.md does not mention the option {o}")
if "cabinet -C <dir>" not in commands:
    problems.append("docs/commands.md does not explain -C <dir>")

# Every workspace script is in docs/commands.md.
for f in sorted(os.listdir(os.path.join(kit, "scripts"))):
    if f.endswith(".sh") and f not in ("lib.sh", "when.sh", "platform.sh") and f"bin/{f}" not in commands:
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
