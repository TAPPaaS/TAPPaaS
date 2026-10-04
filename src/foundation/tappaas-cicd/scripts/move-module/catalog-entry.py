#!/usr/bin/env python3
"""catalog-entry.py — take a module's entry out of one catalogue, put one into another.

    catalog-entry.py remove <catalog> <moduleJson>       prints {"list": …, "entry": …}
    catalog-entry.py add    <catalog> <list> <entry-json>

Used by move-module.sh for a move between repositories. A catalogue is edited as
TEXT, never re-serialised: the catalogues are not all in one JSON style (the
TAPPaaS one mixes \\u escapes with raw UTF-8, Community indents by four), and a
round trip through a JSON writer rewrites every line it did not mean to touch.
Each edit is checked by parsing the result: it must equal the intended change,
or nothing is written and the exit is 1 (edit that catalogue by hand).
"""
import json
import re
import sys


def fail(msg):
    print(f"catalog-entry: {msg}", file=sys.stderr)
    sys.exit(1)


def indent_unit(text):
    m = re.search(r'\n( +)"', text)
    return len(m.group(1)) if m else 2


def remove(path, module_json):
    text = open(path, encoding="utf-8").read()
    data = json.loads(text)
    found = [(k, i) for k, v in data.items() if isinstance(v, list)
             for i, e in enumerate(v) if isinstance(e, dict) and e.get("moduleJson") == module_json]
    if len(found) != 1:
        fail(f"{path}: {module_json} is not listed exactly once")
    key, idx = found[0]
    entry = data[key][idx]
    expected = json.loads(text)
    del expected[key][idx]

    lines = text.splitlines(keepends=True)
    pat = re.compile(r'"moduleJson"\s*:\s*' + re.escape(json.dumps(module_json)))
    hits = [n for n, l in enumerate(lines) if pat.search(l)]
    if len(hits) != 1:
        fail(f"{path}: {module_json} is not on exactly one line")
    start = end = hits[0]
    if not lines[start].lstrip().startswith("{"):
        while start > 0 and not lines[start].lstrip().startswith("{"):
            start -= 1
        while end < len(lines) - 1 and not lines[end].lstrip().startswith("}"):
            end += 1
    last = not lines[end].rstrip().endswith(",")
    del lines[start:end + 1]
    if last:   # it closed the list: the entry before it loses its comma
        p = start - 1
        while p >= 0 and not lines[p].strip():
            p -= 1
        if p >= 0 and lines[p].rstrip().endswith(","):
            body = lines[p].rstrip()
            lines[p] = body[:-1] + lines[p][len(body):]
    out = "".join(lines)
    try:
        ok = json.loads(out) == expected
    except ValueError:
        ok = False
    if not ok:
        fail(f"{path}: could not take {module_json} out cleanly — edit it by hand")
    open(path, "w", encoding="utf-8").write(out)
    print(json.dumps({"list": key, "entry": entry}))


def add(path, key, entry_json):
    entry = json.loads(entry_json)
    text = open(path, encoding="utf-8").read()
    data = json.loads(text)
    if not isinstance(data.get(key), list):
        fail(f"{path} has no list {key}")
    expected = json.loads(text)
    expected[key].append(entry)

    m = list(re.finditer(r'"' + re.escape(key) + r'"\s*:\s*\[', text))
    if len(m) != 1:
        fail(f"{path}: the list {key} is not named exactly once")
    open_at = m[0].end() - 1
    depth, i, in_str = 0, open_at, False
    while i < len(text):   # find the matching ], skipping strings
        c = text[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "[{":
            depth += 1
        elif c in "]}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    close_at = i
    unit = indent_unit(text)
    # the ] sits at the indent of the line that opens the list ("key": [ … ])
    key_line = text[text.rfind("\n", 0, open_at) + 1:]
    close_indent = key_line[:len(key_line) - len(key_line.lstrip(" "))]
    item = re.search(r'\[\s*\n( *)\S', text[open_at:close_at + 1])
    item_indent = item.group(1) if item else close_indent + " " * unit
    rendered = "\n".join(item_indent + l for l in json.dumps(entry, indent=unit).splitlines())
    before = text[:close_at].rstrip()
    if before.endswith("["):
        out = before + "\n" + rendered + "\n" + close_indent + text[close_at:]
    else:
        out = before + ",\n" + rendered + "\n" + close_indent + text[close_at:]
    try:
        ok = json.loads(out) == expected
    except ValueError:
        ok = False
    if not ok:
        fail(f"{path}: could not add the entry to {key} cleanly — edit it by hand")
    open(path, "w", encoding="utf-8").write(out)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "remove":
        remove(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 5 and sys.argv[1] == "add":
        add(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        sys.exit(2)
