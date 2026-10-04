#!/usr/bin/env python3
"""Generate the module lists of each stack's README.md and INSTALL.md from the catalogue (#421).

A stack directory, src/<stack>/, holds the modules whose `stack` is <stack> (ADR-004,
"Where a module's directory is"). Two documents describe it, each a hand-written part
and a generated block:

  README.md   what the stack is — the block lists its members and their status;
  INSTALL.md  how to install it — the block lists its modules in install order.

The order is the dependsOn and integratesWith order inside the stack: a module comes
after every module of the stack it needs or integrates with (#501 — an integration
also works when its provider comes later, but this order wires it on first install).
A dependency outside the stack (foundation, another stack) must be installed first
and is listed beside the module. `module-manager add-stack` (#763) reads the same
catalogue, so the documents and the command cannot disagree. A stack with no module
yet (a planned stack) needs no INSTALL.md.

    gen-stack-readme.py            # rewrite every stack's generated blocks
    gen-stack-readme.py --check    # exit 1 if any is out of date (the release boundary runs this)

Run from anywhere inside a TAPPaaS checkout; --repo <dir> names another one.
"""

import json
import os
import sys

BEGIN = "<!-- BEGIN GENERATED MODULES -- edit the module JSONs and src/module-catalog.json, not this block -->"
END = "<!-- END GENERATED MODULES -->"
# (file, block) per stack document; the same markers in both.
DOCS = ["README.md", "INSTALL.md"]
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


def edges(mj, field, names, me):
    return {d.split(":")[0] for d in (mj.get(field) or []) if d.split(":")[0] in names and d.split(":")[0] != me}


def install_order(mods):
    """Topological order by dependsOn and integratesWith inside the stack; ties by
    name. A cycle is reported, not guessed: its modules come last, flagged."""
    names = {m[0] for m in mods}
    deps = {m[0]: edges(m[3], "dependsOn", names, m[0]) | edges(m[3], "integratesWith", names, m[0]) for m in mods}
    order, done = [], set()
    while len(done) < len(names):
        ready = sorted(n for n in names - done if all(d in done for d in deps[n]))
        if not ready:
            return order + [(n, True) for n in sorted(names - done)]
        for n in ready:
            order.append((n, False))
            done.add(n)
    return order


def cell(text):
    return (text or "").replace("|", "\\|")


def readme_block(mods):
    """The members: what each module is, and how far along."""
    if not mods:
        return "\n".join([BEGIN, "", "No module in this stack yet.", "", END])
    by = {m[0]: m for m in mods}
    lines = [BEGIN, "",
             "| Module | What it is | Status |",
             "|---|---|---|"]
    for name, _cyc in install_order(mods):
        mj = by[name][3]
        link = "[{}]({}/README.md)".format(name, os.path.basename(os.path.dirname(by[name][2])))
        lines.append("| {} | {} | {} |".format(link, cell(mj.get("description")), cell(mj.get("status")) or "—"))
    lines += ["", "Install them as [INSTALL.md](INSTALL.md) says.", "", END]
    return "\n".join(lines)


def install_block(mods, all_stacks):
    """The install order, with what each module needs before it."""
    by = {m[0]: m for m in mods}
    where = {m[0]: m[1] for m in all_stacks}

    def named(d):
        prov = d.split(":")[0]
        return "`{}`".format(d) if prov in by else "`{}` ({})".format(d, where.get(prov, "?"))

    lines = [BEGIN, "",
             "Install order: a module is listed after every module of this stack it needs or integrates with.", "",
             "| # | Module | Needs, in this stack | Integrates with, if installed | Needs, installed first |",
             "|---|---|---|---|---|"]
    for i, (name, cyc) in enumerate(install_order(mods), 1):
        mj = by[name][3]
        inside, outside = [], []
        for d in sorted(set(mj.get("dependsOn") or [])):
            prov = d.split(":")[0]
            (inside if prov in by and prov != name else outside).append(named(d))
        soft = [named(d) for d in sorted(set(mj.get("integratesWith") or []))]
        link = "[{}]({}/INSTALL.md)".format(name, os.path.basename(os.path.dirname(by[name][2])))
        lines.append("| {}{} | {} | {} | {} | {} |".format(
            i, " ⚠ cycle" if cyc else "", link, ", ".join(inside) or "—", ", ".join(soft) or "—",
            ", ".join(outside) or "—"))
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
        mods = [m for m in allmods if m[1] == stack]
        blocks = {"README.md": readme_block(mods)}
        if mods:  # a planned stack has nothing to install yet
            blocks["INSTALL.md"] = install_block(mods, allmods)
        for doc in DOCS:
            if doc not in blocks:
                continue
            path = os.path.join(d, doc)
            rel = os.path.relpath(path, root)
            if not os.path.isfile(path):
                missing.append(rel)
                continue
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            if BEGIN not in text or END not in text:
                missing.append("{} (no generated block)".format(rel))
                continue
            new = text[:text.index(BEGIN)] + blocks[doc] + text[text.index(END) + len(END):]
            if new != text:
                stale.append(rel)
                if not check:
                    with open(path, "w", encoding="utf-8") as fh:
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
