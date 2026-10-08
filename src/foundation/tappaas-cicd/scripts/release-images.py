#!/usr/bin/env python3
"""release-images.py — the container images a release ships, by module (#788).

Reads src/image-pins.json (the list of every pinned image, ADR-028 D14) and, for
each pin, the value its `match` finds in its `file` — at a git ref (a release
tag) or in the working tree. Files moved between releases (src/apps/ became
src/ai/, src/home/, …), so a file the pin names that the ref lacks is looked up
by its last two path parts (`openwebui/openwebui.nix`), and a value whose form
changed is read with the pin's `earlierMatch` patterns. A module the ref does not
have is left out: it is new since that release.

Usage: release-images.py --repo DIR [--ref TAG] [--pins FILE]
Prints {"<module>": "<image>:<tag>" | "<image>@sha256:…"} on stdout.
"""
import argparse, json, re, subprocess, sys


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def read(repo, ref, path, tree):
    if ref is None:
        try:
            return open(f"{repo}/{path}").read()
        except OSError:
            return None
    text = git(repo, "show", f"{ref}:{path}")
    if text is not None:
        return text
    tail = "/" + "/".join(path.split("/")[-2:])
    for p in tree:
        if p.endswith(tail):
            return git(repo, "show", f"{ref}:{p}")
    return None


def resolve(repo, ref, pins):
    tree = (git(repo, "ls-tree", "-r", "--name-only", ref) or "").split("\n") if ref else []
    out = {}
    for pin in pins:
        text = read(repo, ref, pin["file"], tree)
        if text is None:
            continue
        found = []
        for pattern in [pin["match"], *pin.get("earlierMatch", [])]:
            found = re.findall(pattern, text, re.S)
            if found:
                break
        if not found:
            continue
        value = found[-1] if isinstance(found[-1], str) else found[-1][0]
        out[pin["module"]] = f"{pin['image']}@{value}" if pin.get("kind") == "digest" else f"{pin['image']}:{value}"
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--ref")
    ap.add_argument("--pins", help="default: <repo>/src/image-pins.json (the CURRENT list, also for an older ref)")
    a = ap.parse_args()
    try:
        pins = json.load(open(a.pins or f"{a.repo}/src/image-pins.json"))["pins"]
    except (OSError, ValueError, KeyError) as e:
        print(f"release-images: no pin list: {e}", file=sys.stderr)
        return 2
    print(json.dumps(resolve(a.repo, a.ref, pins), indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
