#!/usr/bin/env python3
"""Generate the module list of each stack README from the catalogue (#421).

A stack directory, src/<stack>/, holds the modules whose `stack` is <stack> (ADR-004,
"Where a module's directory is"). Its README.md is the stack's solution document: a
hand-written part saying what the stack delivers, and a generated block listing its
modules in install order. The order is the dependsOn order inside the stack; a
dependency outside it (foundation, another stack) must be installed first and is
listed beside the module. `module-manager add-stack` (#763) reads the same catalogue,
so the README and the command cannot disagree.

    gen-stack-readme.py            # rewrite every stack README's generated block
    gen-stack-readme.py --check    # exit 1 if any is out of date (the release boundary runs this)

Run from anywhere inside a TAPPaaS checkout; --repo <dir> names another one.
"""

import json
import os
import sys

BEGIN = "<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->"
END = "<!-- END GENERATED MODULES -->"
# The stacks that get a directory: what a module is FOR. foundation keeps its own
# directory and README; template and test say what a module IS (ADR-004).
PURPOSE = ["ai", "collaboration", "devops", "home", "security", "misc"]


def repo_root(argv):
    if "--repo" in argv:
        return os.path.abspath(argv[argv.index("--repo") + 1])
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "..", ".."))


def modules_of(root):
    """[(name, stack, json-path, module-json)] for every catalogue entry."""
    with open(os.path.join(root, "src", "module-catalog.json"), encoding="utf-8") as fh:
        cat = json.load(fh)
    out = []
    for e in cat.get("modules", []):
        path = os.path.join(root, e["moduleJson"])
        try:
            with open(path, encoding="utf-8") as fh:
                mj = json.load(fh)
        except (OSError, ValueError):
            mj = {}
        out.append((e["moduleName"], e.get("stack", ""), e["moduleJson"], mj))
    return out


def install_order(mods):
    """Topological order by dependsOn inside the stack; ties by name. A cycle is
    reported, not guessed: its modules come last, flagged."""
    names = {m[0] for m in mods}
    deps = {m[0]: sorted({d.split(":")[0] for d in (m[3].get("dependsOn") or []) if d.split(":")[0] in names and d.split(":")[0] != m[0]}) for m in mods}
    order, done = [], set()
    while len(done) < len(names):
        ready = sorted(n for n in names - done if all(d in done for d in deps[n]))
        if not ready:
            return order + [(n, True) for n in sorted(names - done)]
        for n in ready:
            order.append((n, False))
            done.add(n)
    return order


def block(stack, mods, all_stacks):
    if not mods:
        return "\n".join([BEGIN, "", "No module in this stack yet.", "", END])
    by = {m[0]: m for m in mods}
    where = {m[0]: m[1] for m in all_stacks}
    lines = [BEGIN, "",
             "Install order: a module is listed after every module of this stack it depends on.", "",
             "| # | Module | What it is | Needs, in this stack | Needs, installed first |",
             "|---|---|---|---|---|"]
    for i, (name, cyc) in enumerate(install_order(mods), 1):
        mj = by[name][3]
        desc = (mj.get("description") or "").replace("|", "\\|")
        inside, outside = [], []
        for d in sorted(set(mj.get("dependsOn") or [])):
            prov = d.split(":")[0]
            (inside if prov in by and prov != name else outside).append(
                "`{}`".format(d) if prov in by else "`{}` ({})".format(d, where.get(prov, "?")))
        link = "[{}]({}/README.md)".format(name, os.path.basename(os.path.dirname(by[name][2])))
        lines.append("| {}{} | {} | {} | {} | {} |".format(
            i, " ⚠ cycle" if cyc else "", link, desc, ", ".join(inside) or "—", ", ".join(outside) or "—"))
    lines += ["", END]
    return "\n".join(lines)


def main(argv):
    root = repo_root(argv)
    check = "--check" in argv
    allmods = modules_of(root)
    stale, missing = [], []
    for stack in PURPOSE:
        d = os.path.join(root, "src", stack)
        if not os.path.isdir(d):
            continue
        readme = os.path.join(d, "README.md")
        if not os.path.isfile(readme):
            missing.append(os.path.relpath(readme, root))
            continue
        with open(readme, encoding="utf-8") as fh:
            text = fh.read()
        if BEGIN not in text or END not in text:
            missing.append("{} (no generated block)".format(os.path.relpath(readme, root)))
            continue
        mods = [m for m in allmods if m[1] == stack]
        new = text[:text.index(BEGIN)] + block(stack, mods, allmods) + text[text.index(END) + len(END):]
        if new != text:
            stale.append(os.path.relpath(readme, root))
            if not check:
                with open(readme, "w", encoding="utf-8") as fh:
                    fh.write(new)
    for m in missing:
        print("missing: {}".format(m), file=sys.stderr)
    if check:
        for s in stale:
            print("stale: {} — run gen-stack-readme.py".format(s), file=sys.stderr)
        return 1 if (stale or missing) else 0
    for s in stale:
        print("wrote {}".format(s))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
