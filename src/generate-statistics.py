#!/usr/bin/env python3
"""Source statistics for src/: the current revision against the last release.

    python3 src/generate-statistics.py --last v2.4 --current HEAD --current-label 2.5 > src/STATISTICS.md

Both sides are counted from git (no checkout), by the same rules, so the delta is
the release's: physical lines (newlines) per file, over src/.

Counted: .sh (and extensionless files with a bash shebang), .ts/.tsx, .py, .nix,
.md, .php. Reported apart, not in the totals: .json, .xml, .template, .yaml/.yml,
.toml, .csv, .txt, LICENSE. Excluded: foundation/Deprecated|Attic, any
00-Template, __pycache__, node_modules, the console's built web/dist, the
STATISTICS*.md files, .lock and package-lock.json, binaries.

Areas: src/foundation/, the stack modules (src/<stack>/<module>/; before the
stacks, src/apps/<module>/), and the files at the top of src/.
"""
import argparse, collections, datetime, re, subprocess, sys

SRC_TYPES = {".sh": "Bash (.sh)", ".ts": "TypeScript (.ts/.tsx)", ".tsx": "TypeScript (.ts/.tsx)",
             ".py": "Python (.py)", ".nix": "NixOS (.nix)", ".md": "Documentation (.md)", ".php": "PHP (.php)"}
TYPE_ORDER = ["Bash (.sh)", "TypeScript (.ts/.tsx)", "Python (.py)", "Documentation (.md)", "NixOS (.nix)", "PHP (.php)"]
DATA_TYPES = {".json": "JSON", ".xml": "XML", ".template": ".template", ".yaml": "YAML/YML", ".yml": "YAML/YML",
              ".toml": "TOML", ".csv": "CSV", ".txt": "TXT"}
EXCLUDE = re.compile(r"(^src/foundation/(Deprecated|Attic)/|/00-Template/|/__pycache__/|/node_modules/"
                     r"|/ui/web/dist/|^src/STATISTICS[^/]*\.md$|\.lock$|/package-lock\.json$)")
TEST = re.compile(r"(/tests?/|/test-[^/]*$|/test_[^/]*\.py$|/test[^/]*\.sh$|\.(test|spec)\.tsx?$)")


def git(*a, inp=None):
    return subprocess.run(["git", *a], input=inp, capture_output=True, check=True).stdout


def ext(path):
    name = path.rsplit("/", 1)[-1]
    if name == "LICENSE":
        return "LICENSE"
    return "." + name.rsplit(".", 1)[1] if "." in name else ""


def count(ref):
    """{path: (kind, type, lines)} for every file under src/ at <ref>; kind src|data|excluded."""
    rows = [l.split(b"\t", 1) for l in git("ls-tree", "-r", "-z", ref, "--", "src").split(b"\0") if l]
    blobs = [(meta.split()[2].decode(), p.decode()) for meta, p in rows if meta.split()[1] == b"blob"]
    out = git("cat-file", "--batch", inp=b"".join(s.encode() + b"\n" for s, _ in blobs))
    files, i = {}, 0
    for sha, path in blobs:
        nl = out.index(b"\n", i)
        size = int(out[i:nl].split()[2]); body = out[nl + 1:nl + 1 + size]; i = nl + 1 + size + 1
        e = ext(path)
        lines = body.count(b"\n")
        if EXCLUDE.search(path):
            files[path] = ("excluded", e, lines); continue
        if e == "" and body[:2] == b"#!" and b"bash" in body.split(b"\n", 1)[0]:
            e = ".sh"
        if e in SRC_TYPES:
            files[path] = ("src", SRC_TYPES[e], lines)
        elif e in DATA_TYPES or e == "LICENSE":
            files[path] = ("data", DATA_TYPES.get(e, "LICENSE"), lines)
    return files


def area(path):
    p = path.split("/")
    if len(p) == 2:
        return "top", None
    if p[1] == "foundation":
        return "foundation", None
    return "stacks", (p[1], p[2] if len(p) > 3 else "(stack README)")


def summarize(files):
    s = collections.defaultdict(lambda: [0, 0])
    def add(key, n):
        s[key][0] += 1; s[key][1] += n
    for path, (kind, typ, n) in files.items():
        a, mod = area(path)
        p = path.split("/")
        if kind == "excluded":
            add(("excluded", "/".join(p[1:3]) + "/" if "Template" in path or "Deprecated" in path or "Attic" in path
                 else "`web/dist/` (built console)" if "/web/dist/" in path
                 else "`node_modules/`, `__pycache__/`" if "/node_modules/" in path or "/__pycache__/" in path
                 else "`STATISTICS*.md`, lock files"), n)
            continue
        if kind == "data":
            if typ == "JSON":
                typ = ("JSON, VEX statements" if path.endswith("-vex.json") else
                       "JSON, test fixtures" if TEST.search(path) else "JSON, config and data")
            add(("data", "foundation" if a == "foundation" else "stacks", typ), n); continue
        add(("area", a), n); add(("type", typ), n); add(("area-type", a, typ), n)
        add(("test" if TEST.search(path) else "prod", typ), n)
        if a == "foundation":
            sub = p[2] if len(p) > 3 else "(top-level docs & installers)"
            add(("sub", sub), n)
            if sub == "tappaas-cicd":
                add(("cicd", p[3] if len(p) > 4 else "(top-level)"), n)
        elif a == "stacks":
            add(("module", mod[1], mod[0] if mod[1] != "(stack README)" else mod[0]), n)
        if typ.startswith("TypeScript"):
            q = p[2:]
            key = "/".join(q[:3] if q[:2] in (["tappaas-cicd", "manager"], ["tappaas-cicd", "controller"]) else
                           q[:2] if q[:2] == ["tappaas-cicd", "ui"] else q[:3] if q[:3] == ["tappaas-cicd", "lib", "ts"] else q[:-1])
            add(("ts", key), n)
    return s


def fmt(n):
    return f"{n:,}"


def cell(s, key):
    f, l = s.get(key, (0, 0))
    return f, l


def delta(a, b):
    d = b - a
    return "—" if d == 0 else f"{'+' if d > 0 else '−'}{fmt(abs(d))}"


def table(title_col, keys, L, C, labels, total=True, label=lambda k: f"`{k[-1]}`"):
    lab_l, lab_c = labels
    out = [f"| {title_col} | Files {lab_l} | Files {lab_c} | Lines {lab_l} | Lines {lab_c} | Δ lines |",
           "|---|---:|---:|---:|---:|---:|"]
    tf = [0, 0, 0, 0]
    for k in keys:
        fl, ll = cell(L, k); fc, lc = cell(C, k)
        if not (fl or fc):
            continue
        tf = [tf[0] + fl, tf[1] + fc, tf[2] + ll, tf[3] + lc]
        out.append(f"| {label(k)} | {fl} | {fc} | {fmt(ll)} | {fmt(lc)} | {delta(ll, lc)} |")
    if total:
        out.append(f"| **Total** | **{tf[0]}** | **{tf[1]}** | **{fmt(tf[2])}** | **{fmt(tf[3])}** | **{delta(tf[2], tf[3])}** |")
    return "\n".join(out)


def by_size(prefix, L, C):
    keys = {k for k in list(L) + list(C) if k[0] == prefix}
    return sorted(keys, key=lambda k: (-C.get(k, (0, 0))[1], -L.get(k, (0, 0))[1], k))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--last", required=True, help="the last release's ref (a tag, or a commit)")
    ap.add_argument("--last-label", help="its name in the tables (default: the ref)")
    ap.add_argument("--current", default="HEAD", help="the revision counted now (default HEAD)")
    ap.add_argument("--current-label", help="its name in the tables (default: the ref)")
    a = ap.parse_args()
    ll, cl = a.last_label or a.last, a.current_label or a.current
    L, C = summarize(count(a.last)), summarize(count(a.current))
    lab = (ll, cl)
    sha = lambda r: git("rev-parse", "--short=8", r + "^{commit}").decode().strip()
    when = lambda r: git("log", "-1", "--format=%cs", r + "^{commit}").decode().strip()
    o = []
    o.append("# TAPPaaS Source Statistics\n")
    o.append(f"Generated: {datetime.date.today()} by `src/generate-statistics.py` — **{cl}** (`{sha(a.current)}`, "
             f"{when(a.current)}) against the last release **{ll}** (`{sha(a.last)}`, {when(a.last)}). "
             f"The Δ column is what changed between them.\n")
    o.append("The snapshot of 2026-04-02 is kept in [STATISTICS-v1.md](STATISTICS-v1.md).\n")
    o.append("Counts are physical lines over `src/`, from git, by the same rules on both sides. Counted: `.sh` "
             "(and extensionless files with a bash shebang), `.ts`/`.tsx`, `.py`, `.nix`, `.md`, `.php`. Data and "
             "config files are reported apart and are **not** in the totals. Excluded: `foundation/Deprecated/`, "
             "any `00-Template/`, `__pycache__/`, `node_modules/`, the console's built `web/dist/`, these "
             "`STATISTICS*.md` files, lock files. Stack modules are `src/<stack>/<module>/`; before the stacks "
             "they were `src/apps/<module>/`, so a module is compared by its name.\n")
    o.append("## Summary\n")
    o.append(table("Area", [("area", "foundation"), ("area", "stacks"), ("area", "top")], L, C, lab,
                   label=lambda k: {"foundation": "Foundation (`src/foundation/`)", "stacks": "Stack modules",
                                    "top": "`src/` top level"}[k[1]]))
    o.append("\n## By file type\n")
    o.append(table("File type", [("type", t) for t in TYPE_ORDER], L, C, lab, label=lambda k: k[1]))
    for ar, name in (("foundation", "Foundation"), ("stacks", "Stack modules")):
        o.append(f"\n### {name}\n")
        o.append(table("File type", [("area-type", ar, t) for t in TYPE_ORDER], L, C, lab, label=lambda k: k[2]))
    o.append("\n## Foundation by subsystem\n")
    o.append(table("Subsystem", by_size("sub", L, C), L, C, lab,
                   label=lambda k: k[1] if k[1].startswith("(") else f"`{k[1]}`"))
    o.append("\n### Inside `tappaas-cicd`\n")
    o.append(table("Layer", by_size("cicd", L, C), L, C, lab,
                   label=lambda k: k[1] if k[1].startswith("(") else f"`{k[1]}`"))
    o.append("\n## TypeScript by component\n")
    o.append(table("Component", by_size("ts", L, C), L, C, lab, label=lambda k: f"`{k[1]}`"))
    o.append("\n## Stack modules by module\n")
    mods = by_size("module", L, C)
    stack_now = {k[1]: k[2] for k in C if k[0] == "module"}
    merged = collections.OrderedDict()
    for k in mods:
        merged.setdefault(k[1], [0, 0, 0, 0])
    for k, v in L.items():
        if k[0] == "module":
            merged[k[1]][0] += v[0]; merged[k[1]][2] += v[1]
    for k, v in C.items():
        if k[0] == "module":
            merged[k[1]][1] += v[0]; merged[k[1]][3] += v[1]
    rows = [f"| Module | Stack | Files {ll} | Files {cl} | Lines {ll} | Lines {cl} | Δ lines |", "|---|---|---:|---:|---:|---:|---:|"]
    t = [0, 0, 0, 0]
    for m, (fl, fc, l1, l2) in sorted(merged.items(), key=lambda kv: (-kv[1][3], -kv[1][2], kv[0])):
        if m == "(stack README)":
            continue
        t = [t[0] + fl, t[1] + fc, t[2] + l1, t[3] + l2]
        rows.append(f"| `{m}` | {stack_now.get(m, '— (gone)')} | {fl} | {fc} | {fmt(l1)} | {fmt(l2)} | {delta(l1, l2)} |")
    fl, fc, l1, l2 = merged.get("(stack README)", [0, 0, 0, 0])
    if fl or fc:
        t = [t[0] + fl, t[1] + fc, t[2] + l1, t[3] + l2]
        rows.append(f"| (stack READMEs) | | {fl} | {fc} | {fmt(l1)} | {fmt(l2)} | {delta(l1, l2)} |")
    rows.append(f"| **Total** | | **{t[0]}** | **{t[1]}** | **{fmt(t[2])}** | **{fmt(t[3])}** | **{delta(t[2], t[3])}** |")
    o.append("\n".join(rows))
    nl = sum(1 for m, v in merged.items() if v[0] and m != "(stack README)")
    nc = sum(1 for m, v in merged.items() if v[1] and m != "(stack README)")
    o.append(f"\n{nc} modules in {cl}, {nl} in {ll}.")
    o.append("\n## Test vs production code (.sh, .ts/.tsx, .py)\n")
    code = ["Bash (.sh)", "TypeScript (.ts/.tsx)", "Python (.py)"]
    rows = [f"| Language | Production {ll} | Production {cl} | Test {ll} | Test {cl} | Test share {ll} | Test share {cl} |",
            "|---|---:|---:|---:|---:|---:|---:|"]
    tot = {s: [0, 0, 0, 0] for s in ("prod", "test")}
    def share(p, t):
        return f"{round(100 * t / (p + t))}%" if p + t else "—"
    for typ in code:
        pl, pc = cell(L, ("prod", typ))[1], cell(C, ("prod", typ))[1]
        tl, tc = cell(L, ("test", typ))[1], cell(C, ("test", typ))[1]
        tot["prod"][0] += pl; tot["prod"][1] += pc; tot["test"][0] += tl; tot["test"][1] += tc
        rows.append(f"| {typ} | {fmt(pl)} | {fmt(pc)} | {fmt(tl)} | {fmt(tc)} | {share(pl, tl)} | {share(pc, tc)} |")
    p, t = tot["prod"], tot["test"]
    rows.append(f"| **Total** | **{fmt(p[0])}** | **{fmt(p[1])}** | **{fmt(t[0])}** | **{fmt(t[1])}** | **{share(p[0], t[0])}** | **{share(p[1], t[1])}** |")
    o.append("\n".join(rows))
    o.append("\nTest code by path and name: `test/`, `tests/`, `test-*`, `test_*.py`, `test*.sh`, `*.test.ts(x)`, `*.spec.ts(x)`.")
    o.append("\n## Data and config files (not in the totals)\n")
    dkeys = sorted({k for k in list(L) + list(C) if k[0] == "data"}, key=lambda k: (k[2], k[1]))
    o.append(table("Type", dkeys, L, C, lab, total=False, label=lambda k: f"{k[2]} ({'foundation' if k[1] == 'foundation' else 'stacks'})"))
    o.append("\n## Excluded from every count\n")
    ekeys = sorted({k for k in list(L) + list(C) if k[0] == "excluded"})
    o.append(table("Path", ekeys, L, C, lab, total=False, label=lambda k: k[1] if k[1].startswith("`") else f"`{k[1]}`"))
    print("\n".join(o))


if __name__ == "__main__":
    sys.exit(main())
