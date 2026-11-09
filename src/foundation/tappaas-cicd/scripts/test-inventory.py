#!/usr/bin/env python3
"""test-inventory.py — count the tests in the TAPPaaS repository, per module and level.

Usage: test-inventory.py [--repo DIR] [--json]

Prints a Markdown table (or JSON) of every module under src/<category>/<module>/
(a directory holding <module>.json; the 00-Template skeleton is skipped) with the
checks it carries at each test level (see TESTING.md at the repository root):

  component  offline code tests: unit suites (*.test.ts, Python unittest, lib/ and
             scripts/test/ shell suites) and the manager/controller/ui test.sh
             files of tappaas-cicd. Run anywhere, the Mac included.
  service    services/<svc>/test-service.sh: run by test-module.sh for every
             module that consumes the service (so they guard other modules).
  module     the module's own test.sh, fast part (what every update runs).
  deep       the module's own test.sh, deep-only part (--deep), plus the live
             suites it drives (test-vm-creation/, test-variants/, *deep*/*live*).

A "check" is one positive assertion site in the source: pass/ok/check/assert_*/
expect calls or printed "ok:"/"✓"/"[PASS]" lines in shell, check()/eq()/ok()/assert*()/expect() in TypeScript,
assert* in Python. Its fail branch is not counted again. This is a static count:
a check inside a loop counts once, a skipped check still counts, and the deep/fast
split follows `if` blocks that test DEEP / RUN_DEEP / TAPPAAS_TEST_DEEP.
"""
import argparse
import json
import os
import re
import sys

SKIP_DIRS = {"node_modules", "dist", "dist-test", "result", ".git", "__pycache__"}
LIVE_DIRS = ("test-vm-creation", "test-variants")

SH_CHECK = re.compile(
    r"(?:^|[\s;&|({!])(?:pass|ok|check|check_pass|record_pass|run_test|expect|assert(?:_[a-z_]+)?)"
    r"(?=\s+[\"'$\w(]|\s*$)")
# A check reported as a printed line: echo "  ok: ...", printf '  ✓ ...', echo "[PASS] ...".
SH_ECHO_CHECK = re.compile(
    r"\b(?:echo|printf|info|log)\b[^#]*?[\"'\s](?:\$\{?\w+\}?|\\0?33\[[\d;]*m|\\e\[[\d;]*m)*\s*"
    r"(?:ok:|✓|\[PASS\]|PASS\b)")
# Scripts that only tally failures: one check per failure increment.
SH_FAIL_INC = re.compile(r"\(\(\s*\w*FAIL\w*\s*(?:\+\+|\+=\s*1)|\b\w*FAIL\w*=\$\(\(\s*\$?\w*FAIL\w*\s*\+\s*1")
SH_FUNC_DEF = re.compile(r"^\s*(?:function\s+)?[A-Za-z_][\w-]*\s*\(\)\s*\{?")
TS_CHECK = re.compile(r"\b(?:check|eq|ok|expect|assert(?:\.\w+)?|assert[A-Z]\w*)\(")
PY_CHECK = re.compile(r"\bself\.assert\w+\(|^\s*assert\s")
DEEP_VAR = re.compile(r"\b(?:RUN_DEEP|DEEP|TAPPAAS_TEST_DEEP)\b")
IF_OPEN = re.compile(r"^\s*if\b")
FI = re.compile(r"^\s*fi\b|\bfi\s*$|;\s*fi\b")
ELSE = re.compile(r"^\s*else\b")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return []


PASS_BODY = re.compile(r"\b(?:PASS|pass|ok|passed|OK)\w*=\$\(\(|\(\(\s*\w*(?:PASS|pass|ok)\w*\s*(?:\+\+|\+=)")
DEF_NAME = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)")
NOT_HELPERS = {"info", "log", "warn", "error", "debug", "echo", "fail", "bad", "no", "skip", "die", "msg"}


class ShCounter:
    """Counts check sites in one shell file, learning its own pass-style helpers."""

    def __init__(self, lines):
        self.lines = lines
        self.helpers = set()
        self.skip = set()       # line numbers inside a pass-style helper's body
        i = 0
        while i < len(lines):
            m = DEF_NAME.match(strip_comment(lines[i]))
            if not m:
                i += 1
                continue
            j = i
            if "}" not in lines[i].split("{", 1)[-1]:
                while j + 1 < len(lines) and not re.match(r"^\s*\}", lines[j + 1]):
                    j += 1
                j += 1
            body = "\n".join(lines[i:j + 1])
            name = m.group(1)
            if name not in NOT_HELPERS and (PASS_BODY.search(body) or SH_ECHO_CHECK.search(body)
                                            or name in ("pass", "ok", "check_pass", "record_pass")):
                self.helpers.add(name)
                self.skip.update(range(i, j + 1))
            i = j + 1
        names = "|".join(sorted(map(re.escape, self.helpers))) or "(?!)"
        self.helper_re = re.compile(r"(?:^|[\s;&|({!])(?:" + names + r")(?=\s+[\"'$\w(]|\s*$)")

    def checks(self, idx, line):
        if idx in self.skip or SH_FUNC_DEF.match(line):
            return 0
        n = len(SH_CHECK.findall(line))
        if not n:
            n = len(self.helper_re.findall(line))
        return n if n else (1 if SH_ECHO_CHECK.search(line) else 0)


def strip_comment(line):
    s = line.lstrip()
    return "" if s.startswith("#") else line


def count_sh(lines):
    c = ShCounter(lines)
    n = fails = 0
    for idx, raw in enumerate(lines):
        line = strip_comment(raw)
        if not line:
            continue
        n += c.checks(idx, line)
        if idx not in c.skip:
            fails += len(SH_FAIL_INC.findall(line))
    return n or fails


def count_file(path):
    lines = read(path)
    if path.endswith(".ts"):
        return sum(len(TS_CHECK.findall(l)) for l in lines if not l.lstrip().startswith("//"))
    if path.endswith(".py"):
        return sum(len(PY_CHECK.findall(l)) for l in lines)
    return count_sh(lines)


def split_deep(lines):
    """(fast, deep) check counts of a module test.sh, following deep-gated if blocks."""
    c = ShCounter(lines)
    fast = deep = 0
    stack = []          # per open if: "deep" | "fast-then-deep" | None
    rest_deep = False   # an early `exit` for the non-deep case: everything after is deep
    for idx, raw in enumerate(lines):
        line = strip_comment(raw)
        if not line:
            continue
        one_line_if = IF_OPEN.match(line) and FI.search(line)
        if IF_OPEN.match(line) and not one_line_if:
            cond = line.split("then")[0]
            kind = None
            if DEEP_VAR.search(cond):
                negated = re.search(r"!=|-ne\b|!\s*\[\[", cond)
                kind = "neg" if negated else "deep"
            stack.append(kind)
            continue
        if ELSE.match(line) and stack:
            stack[-1] = {"deep": "fast", "neg": "deep"}.get(stack[-1], stack[-1])
            continue
        if FI.match(line) and stack:
            stack.pop()
            continue
        if stack and stack[-1] == "neg" and re.search(r"\bexit\b", line):
            rest_deep = True
        n = c.checks(idx, line)
        if n == 0:
            continue
        in_deep = rest_deep or any(k == "deep" for k in stack) or \
            (re.search(r"&&", line) and DEEP_VAR.search(line.split("&&")[0]) and IF_OPEN.match(line))
        if in_deep:
            deep += n
        else:
            fast += n
    return fast, deep


def is_test_file(name):
    return (name.endswith(".test.ts") or name.endswith(".bats")
            or (name.endswith(".py") and (name.startswith("test_") or name.endswith("_test.py")))
            or (name.endswith(".sh") and (name == "test.sh" or name.startswith("test-"))))


def modules(repo):
    src = os.path.join(repo, "src")
    for cat in sorted(os.listdir(src)):
        cdir = os.path.join(src, cat)
        if not os.path.isdir(cdir):
            continue
        for mod in sorted(os.listdir(cdir)):
            mdir = os.path.join(cdir, mod)
            if mod.startswith("00-") or not os.path.isfile(os.path.join(mdir, mod + ".json")):
                continue
            yield cat, mod, mdir


def inventory(repo):
    rows = []
    for cat, mod, mdir in modules(repo):
        row = {"module": f"{cat}/{mod}", "component": 0, "component_files": 0,
               "service": 0, "service_files": 0, "module_fast": 0, "deep": 0,
               "deep_files": 0, "has_test_sh": False, "has_deep": False}
        root_test = os.path.join(mdir, "test.sh")
        if os.path.isfile(root_test):
            row["has_test_sh"] = True
            fast, deep = split_deep(read(root_test))
            row["module_fast"], row["deep"] = fast, deep
        for dirpath, dirnames, filenames in os.walk(mdir):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and d != "fixtures"]
            rel = os.path.relpath(dirpath, mdir)
            for name in filenames:
                path = os.path.join(dirpath, name)
                if path == root_test or not is_test_file(name):
                    continue
                parts = rel.split(os.sep)
                n = count_file(path)
                if parts[0] == "services" and name == "test-service.sh":
                    row["service"] += n
                    row["service_files"] += 1
                elif any(p in LIVE_DIRS for p in parts) or re.search(r"deep|live", name):
                    row["deep"] += n
                    row["deep_files"] += 1
                else:
                    row["component"] += n
                    row["component_files"] += 1
        row["has_deep"] = row["deep"] > 0
        rows.append(row)
    return rows


def markdown(rows):
    out = ["| Module | Component checks (files) | Service checks (files) | Module test.sh: fast | Deep checks | Total |",
           "|---|--:|--:|--:|--:|--:|"]
    tot = {k: 0 for k in ("component", "component_files", "service", "service_files", "module_fast", "deep")}
    for r in rows:
        total = r["component"] + r["service"] + r["module_fast"] + r["deep"]
        fast = str(r["module_fast"]) if r["has_test_sh"] else "no test.sh"
        comp = f'{r["component"]} ({r["component_files"]})' if r["component_files"] else "–"
        svc = f'{r["service"]} ({r["service_files"]})' if r["service_files"] else "–"
        deep = str(r["deep"]) if r["deep"] else "–"
        out.append(f'| {r["module"]} | {comp} | {svc} | {fast} | {deep} | {total} |')
        for k in tot:
            tot[k] += r[k]
    grand = tot["component"] + tot["service"] + tot["module_fast"] + tot["deep"]
    out.append(f'| **All {len(rows)} modules** | **{tot["component"]} ({tot["component_files"]})** | '
               f'**{tot["service"]} ({tot["service_files"]})** | **{tot["module_fast"]}** | '
               f'**{tot["deep"]}** | **{grand}** |')
    with_sh = sum(r["has_test_sh"] for r in rows)
    with_deep = sum(r["has_deep"] for r in rows)
    with_comp = sum(1 for r in rows if r["component_files"])
    out.append("")
    out.append(f"{with_sh} of {len(rows)} modules have a test.sh, {with_deep} have deep checks, "
               f"{with_comp} have component tests.")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--repo", default=os.path.abspath(os.path.join(here, "../../../..")))
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    rows = inventory(a.repo)
    print(json.dumps(rows, indent=2) if a.json else markdown(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
