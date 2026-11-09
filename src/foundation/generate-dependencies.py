#!/usr/bin/env python3
"""Regenerate PROGRAMS.csv, DEPENDENCIES.csv and DEPENDENCIES.md for src/foundation/.

    python3 src/foundation/generate-dependencies.py            # writes the three files
    python3 src/foundation/generate-dependencies.py --check    # exit 1 when they are stale

Programs come from what the code installs, never from a site:
  * tappaas-cicd/scripts/*.sh and lib/*.sh, each linked into ~/bin by tappaas-cicd/install.sh
    (a script when git tracks it executable, else a sourced library);
  * every control-plane component in tappaas-cicd/components.json: TypeScript bins from its
    package.json (plus its aliases), Python bins from its pyproject.toml [project.scripts],
    bash entry programs as link_component_executables links them, plus the install.sh's
    explicit `ln -sfn "${here}/<file>" "${bin}/<name>"` aliases;
  * cluster/Create-TAPPaaS-VM.sh, installed on every node, and backup's tappaas-fs-backup.sh,
    copied to each guest that has backup:filesystem.

Dependencies are read from the code of every file under src/foundation/ that is not a test
(a module's own test.sh is kept), in .sh, extensionless bash, .py, .ts/.tsx and .nix (the
systemd units that run a program):
  * a bash `source`/`.` of a file (recorded by its name);
  * a TAPPaaS program named in the code, comments left out (a one-word name like `console`
    or `cmdb` only where it is run: as a shell command, or first in a spawn call);
  * a config file named in the code: site.json, zones.json, environments/, network.json,
    channels.json, components.json, control-plane.json, module-catalog.json.
A program never depends on itself, nor a file on the program built from it.
"""
import argparse, collections, datetime, json, os, re, subprocess, sys, tomllib

ROOT = os.path.dirname(os.path.abspath(__file__))           # src/foundation
REPO = os.path.dirname(os.path.dirname(ROOT))
CICD = os.path.join(ROOT, "tappaas-cicd")
CONFIGS = ["site.json", "zones.json", "environments/", "network.json", "channels.json",
           "components.json", "control-plane.json", "module-catalog.json"]
SKIP_DIR = re.compile(r"(^|/)(node_modules|dist|web/dist|__pycache__|Deprecated|Attic|fixtures|result)(/|$)")
TEST = re.compile(r"(^|/)(tests?|test-[^/]*)/|(^|/)test[-_][^/]*$|\.(test|spec)\.tsx?$|/test[^/]*\.sh$")
CODE_EXT = {".sh": "bash", ".py": "python", ".ts": "typescript", ".tsx": "typescript", ".nix": "nix"}


def rel(p):
    return os.path.relpath(p, ROOT)


def tracked_exec(path):
    out = subprocess.run(["git", "-C", REPO, "ls-files", "-s", "--", os.path.relpath(path, REPO)],
                         capture_output=True, text=True).stdout
    return out.startswith("100755")


# ── programs ─────────────────────────────────────────────────────────────────
def programs():
    """[(name, install location, source path, type, group)]"""
    rows = []
    for d, kind in (("lib", None), ("scripts", None)):
        for f in sorted(os.listdir(os.path.join(CICD, d))):
            p = os.path.join(CICD, d, f)
            if f.endswith(".sh") and os.path.isfile(p):
                rows.append((f, f"/home/tappaas/bin/{f}", rel(p),
                             "script" if tracked_exec(p) else "library", f"tappaas-cicd/{d}"))
    comps = json.load(open(os.path.join(CICD, "components.json")))["components"]
    for c in comps:
        path = os.path.join(CICD, c["path"]); grp = f"{c['kind']}: {c['name']}"
        names = {}
        if c["language"] == "typescript":
            pkg = json.load(open(os.path.join(path, "package.json")))
            for b in (pkg.get("bin") or {c["name"]: ""}):
                names[b] = rel(os.path.join(path, "src")) + "/"
            for a in c.get("aliases") or []:
                names[a] = rel(os.path.join(path, "src")) + "/"
            if c["name"] == "console":
                names["tappaas"] = rel(os.path.join(path, "src", "ask.ts"))
        elif c["language"] == "python":
            pp = next((os.path.join(dp, "pyproject.toml") for dp, _, fs in os.walk(path)
                       if "pyproject.toml" in fs and not SKIP_DIR.search(dp)), None)
            scripts = tomllib.load(open(pp, "rb")).get("project", {}).get("scripts", {}) if pp else {}
            for b, target in scripts.items():
                mod = target.split(":")[0].replace(".", "/") + ".py"
                src = os.path.join(os.path.dirname(pp), mod)
                names[b] = rel(src) if os.path.exists(src) else rel(os.path.dirname(pp)) + "/"
        inst = open(os.path.join(path, "install.sh")).read() if os.path.exists(os.path.join(path, "install.sh")) else ""
        inst = "\n".join(l for l in inst.split("\n") if not l.lstrip().startswith("#"))
        if c["language"] == "bash":
            if "link_component_executables" in inst:
                for f in sorted(os.listdir(path)):
                    p = os.path.join(path, f)
                    if not os.path.isfile(p) or f in ("install.sh", "update.sh", "test.sh", "validate.sh") \
                            or f.endswith((".md", ".jq")) or f.startswith("test-"):
                        continue
                    names[f] = rel(p)
        if re.search(r'for f in "\$\{here\}"/\*\.sh', inst):     # a manager's verb scripts
            for f in sorted(os.listdir(path)):
                if f.endswith(".sh") and f not in ("install.sh", "update.sh", "test.sh", "validate.sh"):
                    names[f] = rel(os.path.join(path, f))
        for src, b in (re.findall(r'ln -sfn "\$\{here\}/([^"]+)" "\$\{bin\}/([^"]+)"', inst)
                       + re.findall(r'link_bash\s+"\$\{here\}/([^"]+)"\s+(\S+)', inst)
                       + re.findall(r'^\s*link_as\s+(\S+)\s+(\S+)', inst, re.M)):
            names[b] = rel(os.path.join(path, src))
        for tool, b in re.findall(r'ln -sfn "\$\{gcroots\}/[^/"]+/bin/([^"]+)" "\$\{bin\}/([^"]+)"', inst):
            if tool in names:                            # an old name for a built bin
                names[b] = names[tool]
        for b, src in names.items():
            rows.append((b, f"/home/tappaas/bin/{b}", src, "program", grp))
    vm = os.path.join(ROOT, "cluster", "Create-TAPPaaS-VM.sh")
    if os.path.exists(vm):
        rows.append(("Create-TAPPaaS-VM.sh", "/root/tappaas/Create-TAPPaaS-VM.sh (every node)", rel(vm), "script", "cluster"))
    fsb = os.path.join(ROOT, "backup", "services", "filesystem", "tappaas-fs-backup.sh")
    if os.path.exists(fsb):
        rows.append(("tappaas-fs-backup.sh", "/home/tappaas/bin/tappaas-fs-backup.sh (each guest with backup:filesystem)",
                     rel(fsb), "script", "backup"))
    seen, out = set(), []
    for r in rows:
        if r[0] not in seen:
            seen.add(r[0]); out.append(r)
    return out


# ── dependencies ─────────────────────────────────────────────────────────────
def code_files():
    for dp, dns, fs in os.walk(ROOT):
        r = rel(dp)
        dns[:] = sorted(d for d in dns if not SKIP_DIR.search((r + "/" + d).lstrip("./")))
        for f in sorted(fs):
            p = os.path.join(dp, f); rp = rel(p)
            if TEST.search("/" + rp) and f != "test.sh":
                continue
            e = os.path.splitext(f)[1]
            lang = CODE_EXT.get(e)
            if lang is None and e == "":
                try:
                    with open(p, "rb") as h:
                        first = h.readline()
                    lang = "bash" if first.startswith(b"#!") and b"bash" in first else None
                except OSError:
                    lang = None
            if lang:
                yield rp, lang


def strip_comments(text, lang):
    if lang == "typescript":
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("//"))
    lines = []
    for l in text.split("\n"):
        s = l.lstrip()
        if s.startswith("#") and not s.startswith("#!"):
            continue
        lines.append(l)
    text = "\n".join(lines)
    if lang == "python":
        text = re.sub(r'^\s*("""|\'\'\').*?\1', "", text, flags=re.S | re.M)
    return text


def deps(progs):
    names = {p[0] for p in progs}
    own = collections.defaultdict(set)               # file -> program names built from it
    for name, _, src, _, _ in progs:
        own[src].add(name)
    multi = sorted((n for n in names if "-" in n or n.endswith(".sh")), key=len, reverse=True)
    single = sorted(n for n in names if n not in multi)
    pat_multi = re.compile(r"(?<![\w./-])(" + "|".join(map(re.escape, multi)) + r")(?![\w-])")
    # A one-word name (console, cmdb, tappaas) is also an everyday word: only as a command
    # (line start, after $( | ; && or a backtick, followed by an argument) or as the first
    # element of a spawn call ("cmdb", ...).
    alt = "|".join(map(re.escape, single))
    pat_single = re.compile(r"(?:^\s*|\$\(\s*|[|;&]\s*|`)(" + alt + r")\s+[a-z-]|[\[(]\s*[\"'](" + alt + r")[\"']\s*,", re.M)
    pat_src = re.compile(r"""^\s*(?:source|\.)\s+["']?([^"'\s;]+)""", re.M)
    out = {}
    for rp, lang in code_files():
        try:
            text = strip_comments(open(os.path.join(ROOT, rp), errors="replace").read(), lang)
        except OSError:
            continue
        base = os.path.basename(rp)
        mine = set(own.get(rp, ())) | {base}
        for src, ns in own.items():                  # a file inside a program's source tree
            if src.endswith("/") and rp.startswith(src):
                mine |= ns
        d = []
        if lang == "bash":
            for m in pat_src.findall(text):
                n = os.path.basename(m.replace("}", ""))
                if n and n not in mine and n.endswith((".sh", "rc", ".env")):
                    d.append(n)
        d += [n for n in pat_multi.findall(text) if n not in mine]
        d += [n for m in pat_single.findall(text) for n in m if n and n not in mine]
        d += [c for c in CONFIGS if c in text]
        out[rp] = (lang, list(dict.fromkeys(d)))
    return out


# ── writers ──────────────────────────────────────────────────────────────────
def head(title, lines):
    bar = "# " + "=" * 90
    return [bar, f"# TAPPaaS Foundation Layer - {title}",
            f"# Generated: {datetime.date.today()} by src/foundation/generate-dependencies.py — do not edit by hand",
            bar] + [f"# {l}" if l else "#" for l in lines]


def programs_csv(progs):
    o = ["Program,Install Location,Source Path,Type"]
    o += head("Executable Programs and Scripts", [
        "Source paths are relative to src/foundation/. A path ending in / is a built package's",
        "source tree (TypeScript under src/, Python under its package). Type: program (a built",
        "or bash CLI), script (an executable bash script), library (a sourced bash file)."])
    grp = None
    for name, loc, src, typ, g in sorted(progs, key=lambda r: (group_order(r[4]), r[4], r[0])):
        if g != grp:
            o += ["#", f"# --- {g} ---"]; grp = g
        o.append(f"{name},{loc},{src},{typ}")
    return "\n".join(o) + "\n"


def group_order(g):
    return 0 if g.startswith("manager") else 1 if g.startswith("controller") else 2 if g.startswith("service") \
        else 3 if g.startswith("tappaas-cicd") else 4


def deps_csv(dd):
    o = ["File,Location,Direct Dependencies"]
    o += head("Direct Dependencies", [
        "One row per non-test code file (.sh, extensionless bash, .py, .ts/.tsx, .nix); a module's own",
        "test.sh is kept. Direct dependencies, semicolon-separated: bash files sourced, TAPPaaS",
        "programs named in the code (PROGRAMS.csv), and the config files it names."])
    cur = None
    for rp in sorted(dd, key=lambda p: (os.path.dirname(p), os.path.basename(p))):
        dirn = os.path.dirname(rp) or "."
        if dirn != cur:
            o += ["#", f"# === {dirn} ==="]; cur = dirn
        o.append(f"{os.path.basename(rp)},{dirn}/,{'; '.join(dd[rp][1])}")
    return "\n".join(o) + "\n"


def area(rp):
    p = rp.split("/")
    if p[0] == "tappaas-cicd" and len(p) > 2:
        return "/".join(p[:3]) if p[1] in ("manager", "controller") and len(p) > 3 else "/".join(p[:2])
    return p[0] if len(p) > 1 else "(top level)"


def mermaid(name, edges, progs_by_name):
    ids = {}
    def nid(n):
        return ids.setdefault(n, f"n{len(ids)}")
    o = ["```mermaid", "graph LR", f'    {nid(name)}["{name}"]']
    for t in edges:
        o.append(f'    {nid(name)} --> {nid(t)}["{t}"]')
    o.append("```")
    return "\n".join(o)


def deps_md(progs, dd):
    pn = {p[0]: p for p in progs}
    agg = collections.defaultdict(list)                # program -> deps over its source
    for name, _, src, _, _ in progs:
        files = [rp for rp in dd if (rp.startswith(src) if src.endswith("/") else rp == src)]
        for rp in files:
            agg[name] += dd[rp][1]
        agg[name] = [d for d in dict.fromkeys(agg[name]) if d != name]
    incoming = collections.Counter(d for _, ds in dd.values() for d in set(ds))
    langs = collections.Counter(l for l, _ in dd.values())
    by_area = collections.defaultdict(lambda: collections.Counter())
    for rp, (l, ds) in dd.items():
        by_area[area(rp)][l] += 1
    edges = sum(len(ds) for _, ds in dd.values())
    o = ["# TAPPaaS Foundation Layer - Dependency Documentation", "",
         f"Generated: {datetime.date.today()} by `src/foundation/generate-dependencies.py`, with "
         "[PROGRAMS.csv](PROGRAMS.csv) and [DEPENDENCIES.csv](DEPENDENCIES.csv). Do not edit by hand: "
         "change the generator and run it again.", "",
         "What a foundation program is, and what each code file under `src/foundation/` depends on: "
         "the bash files it sources, the TAPPaaS programs its code names, and the site config files it "
         "reads. Read from the code, so a program called through a variable is missed and a name that "
         "only appears in a message counts; the generator's docstring has the exact rules.", "",
         "## Summary", "",
         f"{len(progs)} programs, {len(dd)} code files read "
         f"({', '.join(f'{n} {l}' for l, n in langs.most_common())}), {edges} direct dependencies.", "",
         "| Area | Bash | Python | TypeScript | Nix | Files |", "|------|-----:|-------:|-----------:|----:|------:|"]
    for a in sorted(by_area, key=lambda a: (-sum(by_area[a].values()), a)):
        c = by_area[a]
        o.append(f"| `{a}` | {c['bash']} | {c['python']} | {c['typescript']} | {c['nix']} | {sum(c.values())} |")
    kinds = collections.Counter(p[3] for p in progs)
    o += ["", "## Programs", "",
          f"{kinds['program']} programs, {kinds['script']} scripts and {kinds['library']} sourced libraries "
          "(PROGRAMS.csv lists each with its source). The front doors are the managers; controllers plug "
          "into them; the services run beside them.", "",
          "| Component | Kind | Programs |", "|-----------|------|----------|"]
    comps = json.load(open(os.path.join(CICD, "components.json")))["components"]
    for c in comps:
        bins = [p[0] for p in progs if p[4] == f"{c['kind']}: {c['name']}"]
        o.append(f"| `{c['name']}` | {c['kind']} | {', '.join(f'`{b}`' for b in bins)} |")
    o += ["", "## Most depended upon", "", "| File or program | Files that name it | What it is |",
          "|-----------------|------------------:|------------|"]
    for n, k in incoming.most_common(30):
        what = (pn[n][3] + " — " + pn[n][4]) if n in pn else "config file" if n in CONFIGS else "sourced file"
        o.append(f"| `{n}` | {k} | {what} |")
    used = set(incoming)
    entry = [p for p in progs if p[0] not in used and p[3] != "library"]
    o += ["", "## Entry points", "",
          "Programs and scripts no other foundation code names: what an operator, a timer, a node or "
          "another repository runs.", ""]
    groups = collections.defaultdict(list)
    for p in entry:
        groups[p[4]].append(p[0])
    for g in sorted(groups, key=lambda g: (group_order(g), g)):
        o.append(f"- **{g}:** " + ", ".join(f"`{n}`" for n in sorted(groups[g])))
    o += ["", "## What each front door calls", "",
          "Each manager, controller and service, with the programs, sourced files and config files its "
          "source names directly.", ""]
    for c in comps:
        progs_c = [p for p in progs if p[4] == f"{c['kind']}: {c['name']}"]
        if not progs_c:
            continue
        main = c["name"] if c["name"] in agg else progs_c[0][0]
        ds = agg.get(main, [])
        o += [f"### `{c['name']}` ({c['kind']})", ""]
        if not ds:
            o += ["Names no other program or config file.", ""]
            continue
        o += [mermaid(main, ds, pn), ""]
    return "\n".join(o).rstrip() + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true", help="exit 1 when a file differs (ignores the date)")
    a = ap.parse_args()
    progs = programs()
    dd = deps(progs)
    files = {"PROGRAMS.csv": programs_csv(progs), "DEPENDENCIES.csv": deps_csv(dd), "DEPENDENCIES.md": deps_md(progs, dd)}
    stale = []
    for f, body in files.items():
        p = os.path.join(ROOT, f)
        if a.check:
            old = open(p).read() if os.path.exists(p) else ""
            norm = lambda s: re.sub(r"Generated: \d{4}-\d{2}-\d{2}", "", s)
            if norm(old) != norm(body):
                stale.append(f)
        else:
            open(p, "w").write(body)
    if a.check:
        print("stale: " + ", ".join(stale) if stale else "up to date")
        return 1 if stale else 0
    print(f"wrote PROGRAMS.csv ({len(progs)} programs), DEPENDENCIES.csv ({len(dd)} files), DEPENDENCIES.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
