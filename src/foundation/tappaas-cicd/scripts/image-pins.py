#!/usr/bin/env python3
"""image-pins.py — how old is each container image pin, and is upstream ahead (#750).

The estate's nixpkgs pin has a cadence (ADR-028 D2) and a tripwire (D4). A
container image pin had neither: a tag moves only when someone moves it, and
nothing said when nobody had — identity ran a 2025.2 Authentik for seven and a
half months, end of life, with critical advisories open (#748).

src/image-pins.json lists the pins. Each entry says where its value lives (a
module file and a regex whose first group is the value) — the module's own file
stays the one place a maintainer edits. For each pin this reports:

  * the pinned value and its age: when the line holding it last changed (git blame)
  * a tag: the newest upstream tag of the same form, and how many are newer
  * a digest: its age only — a digest cannot be compared with "latest"

A pin is STALE when it is older than the tripwire (45 days, as D4) and upstream
has something newer. Stale is a warning, never a failure: moving a pin is a
reviewed change by the module's maintainer (ADR-028 D4: a stale pin is a release
decision). Images referenced in the tree but not in the list are reported as
unlisted, so a new pin cannot hide.

Usage: image-pins.py [--repo DIR] [--json] [--offline] [--tags-file F]
  --offline     do not ask any registry (age and listing only)
  --tags-file   JSON {image: [tags...]} used instead of the registries (tests)
Exit: 0 always when the list could be read (report-only); 2 when it could not.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

TRIPWIRE_DAYS = 45
REF_RE = re.compile(
    r'(?:image\s*[=:]\s*"?|IMAGE="|^\s+)'
    r'((?:[a-z0-9.-]+\.(?:io|com|org|net)/)?[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._/-]*)'
    r'(?::[A-Za-z0-9.${}_-]+|@(?:sha256:|\$\{))', re.M)
SCAN_SUFFIXES = (".nix", ".sh", ".yml", ".yaml")


def run(cmd: list[str], cwd: str) -> str:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True).stdout


def canon(image: str) -> str:
    """docker.io/x/y, x/y and index.docker.io/x/y are one image."""
    image = image.strip().rstrip("/")
    for p in ("index.docker.io/", "docker.io/"):
        if image.startswith(p):
            image = image[len(p):]
    return image


def read_pin(repo: str, pin: dict) -> tuple[str | None, int | None]:
    """The pinned value and the line number it sits on (1-based)."""
    path = os.path.join(repo, pin["file"])
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None, None
    m = None
    for m in re.finditer(pin["match"], text, re.S):
        pass  # the LAST match: a list's last element is its target
    if not m:
        return None, None
    line = text.count("\n", 0, m.start(1)) + 1
    return m.group(1), line


def age_days(repo: str, file: str, line: int) -> int | None:
    out = run(["git", "blame", "--line-porcelain", "-L", f"{line},{line}", "--", file], repo)
    m = re.search(r"^committer-time (\d+)$", out, re.M)
    if not m:
        return None
    return int((time.time() - int(m.group(1))) // 86400)


def _get(url: str, headers: dict | None = None) -> tuple[bytes, dict]:
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read(), dict(r.headers)


def registry_tags(image: str) -> list[str]:
    """Every tag of an image on ghcr.io or Docker Hub, anonymously."""
    if image.startswith("ghcr.io/"):
        name = image[len("ghcr.io/"):]
        tok = json.loads(_get(f"https://ghcr.io/token?scope=repository:{name}:pull")[0])["token"]
        tags, url = [], f"https://ghcr.io/v2/{name}/tags/list?n=1000"
        while url:
            body, hdr = _get(url, {"Authorization": f"Bearer {tok}"})
            tags += json.loads(body).get("tags") or []
            link = hdr.get("Link") or hdr.get("link") or ""
            m = re.search(r"<([^>]+)>", link)
            url = ("https://ghcr.io" + m.group(1)) if m else None
        return tags
    name = canon(image)
    if "/" not in name or "." in name.split("/")[0]:
        raise ValueError(f"registry of {image} not supported")
    tags, url = [], f"https://hub.docker.com/v2/repositories/{name}/tags?page_size=100"
    for _ in range(20):            # newest first; 2000 tags is ample
        if not url:
            break
        data = json.loads(_get(url)[0])
        tags += [t["name"] for t in data.get("results", [])]
        url = data.get("next")
    return tags


def vkey(tag: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", tag))


def copies_differ(repo: str, pin: dict, value: str) -> list[str]:
    """Other places that must hold the same value (``also``); those that do not."""
    bad = []
    for c in pin.get("also", []):
        v, _ = read_pin(repo, {"file": c["file"], "match": c["match"]})
        if v != value:
            bad.append(f"{c['file']} has {v or 'nothing'}")
    return bad


def judge(pin: dict, value: str, age: int | None, tags: list[str] | None,
          mismatch: list[str] | None = None) -> dict:
    r = {"module": pin["module"], "image": pin["image"], "kind": pin.get("kind", "tag"),
         "pinned": value, "ageDays": age, "file": pin["file"],
         "maintainer": pin.get("maintainer", ""), "latest": None, "newer": None, "status": "ok",
         "mismatch": mismatch or []}
    if r["kind"] == "digest":
        r["status"] = "digest"
        return r
    if tags is None:
        r["status"] = "unknown"
        return r
    pat = re.compile(pin.get("tagPattern", r"^v?\d+(\.\d+)*$"))
    same = sorted({t for t in tags if pat.match(t)}, key=vkey)
    if not same:
        r["status"] = "unknown"
        return r
    r["latest"] = same[-1]
    r["newer"] = sum(1 for t in same if vkey(t) > vkey(value))
    if r["newer"] and age is not None and age > TRIPWIRE_DAYS:
        r["status"] = "stale"
    elif r["newer"]:
        r["status"] = "behind"
    return r


def unlisted(repo: str, listed: set[str]) -> list[dict]:
    """Image references in the tree that the list does not name."""
    found: dict[str, str] = {}
    src = os.path.join(repo, "src")
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules") and not d.startswith("test")]
        for f in files:
            if not f.endswith(SCAN_SUFFIXES) or f.startswith("test"):
                continue
            p = os.path.join(root, f)
            try:
                text = open(p, encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            for m in REF_RE.finditer(text):
                img = canon(m.group(1))
                if img not in listed and img not in found and "/" in img and "$" not in img:
                    found[img] = os.path.relpath(p, repo)
    return [{"image": i, "file": f} for i, f in sorted(found.items())]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=os.environ.get("TAPPAAS_REPO_DIR", "/home/tappaas/TAPPaaS"))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--tags-file")
    a = ap.parse_args()

    try:
        pins = json.load(open(os.path.join(a.repo, "src", "image-pins.json")))["pins"]
    except (OSError, ValueError, KeyError) as e:
        print(f"image-pins: cannot read src/image-pins.json: {e}", file=sys.stderr)
        return 2
    fixed = json.load(open(a.tags_file)) if a.tags_file else None

    results = []
    for pin in pins:
        value, line = read_pin(a.repo, pin)
        if value is None:
            results.append({"module": pin.get("module"), "image": pin.get("image"),
                            "status": "unreadable", "file": pin.get("file")})
            continue
        age = age_days(a.repo, pin["file"], line)
        tags = None
        if pin.get("kind", "tag") == "tag":
            if fixed is not None:
                tags = fixed.get(pin["image"])
            elif not a.offline:
                try:
                    tags = registry_tags(pin["image"])
                except Exception:
                    tags = None
        results.append(judge(pin, value, age, tags, copies_differ(a.repo, pin, value)))

    listed = {canon(p["image"]) for p in pins}
    report = {"tripwireDays": TRIPWIRE_DAYS, "pins": results,
              "unlisted": unlisted(a.repo, listed),
              "stale": sum(1 for r in results if r["status"] == "stale"),
              "mismatched": sum(1 for r in results if r.get("mismatch"))}
    if a.json:
        print(json.dumps(report))
        return 0
    for r in results:
        if r["status"] == "unreadable":
            print(f"  ! {r['module']}: pin not found in {r['file']}")
            continue
        age = "?" if r["ageDays"] is None else f"{r['ageDays']}d"
        if r["status"] == "digest":
            print(f"  · {r['module']}: {r['image']} by digest, {age} old (reviewed by hand)")
        elif r["status"] == "unknown":
            print(f"  ? {r['module']}: {r['image']}:{r['pinned']}, {age} old — upstream not checked")
        else:
            mark = {"ok": "✓", "behind": "→", "stale": "✗"}[r["status"]]
            tail = "current" if not r["newer"] else f"{r['newer']} newer, latest {r['latest']}"
            print(f"  {mark} {r['module']}: {r['image']}:{r['pinned']}, {age} old — {tail}")
        for m in r.get("mismatch") or []:
            print(f"    ✗ a copy of the pin differs: {m}")
    for u in report["unlisted"]:
        print(f"  · not yet listed: {u['image']} ({u['file']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
