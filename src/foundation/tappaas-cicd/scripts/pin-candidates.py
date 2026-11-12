#!/usr/bin/env python3
"""pin-candidates.py — would moving a pin help? The daily check, for every module.

Runs where the release train runs, after the rescan. It needs no running guest
and changes nothing in the repository:

  container images   the newest tag of the pinned minor (a patch-level move) and
                     the newest tag of the same form, each scanned by reference
                     (health-manager scan images: the same VEX and component
                     records the site's scan applies) and compared with the pin
  the nixpkgs pin    the last release preview (tappaas-train.sh preview): what the
                     pin the next boundary takes clears and adds, per module
  Debian, nodes,     nothing: they patch themselves, or with one channel update
  the firewall       (the operator's Update queue says so)

For each module one proposal goes into config/pin-candidates.json:
  move    from → to, the critical/high CVEs it clears and adds, whether it is a
          patch-level move (the daily patch line) or a minor/major (the train)
  draft   nothing helps: a draft component record for each undecided component,
          with the CVSS rule that would cover most of its CVEs. A person writes it.

  pin-candidates.py [--repo DIR] [--config DIR] [--out FILE] [--image-scanner CMD] [--pins CMD]
  pin-candidates.py apply <module> [--repo DIR] [--config DIR]
      writes the proposed pin move to a branch pin/<module>-<to> (its own worktree:
      the checkout does not move) and stops; the live test and the merge are the
      maintainer's.
Exit: 0 written, 1 apply found no move, 2 bad input.
"""
import argparse, datetime, json, os, re, shlex, subprocess, sys, tempfile
from collections import Counter

HOME = os.environ.get("HOME", "/home/tappaas")
CONFIG = os.environ.get("TAPPAAS_CONFIG_DIR", os.path.join(HOME, "config"))
REPO = os.environ.get("TAPPAAS_REPO_DIR", os.path.join(HOME, "TAPPaaS"))
HERE = os.path.dirname(os.path.abspath(__file__))
CH = ("Critical", "High")
PREVIEW_FRESH_DAYS = 3


def now_utc():
    t = os.environ.get("TAPPAAS_TRAIN_NOW")
    return datetime.datetime.fromtimestamp(int(t), datetime.timezone.utc) if t else datetime.datetime.now(datetime.timezone.utc)


def vkey(tag):
    return tuple(int(x) for x in re.findall(r"\d+", tag or ""))


def run_json(cmd, payload=None):
    """Run a command with {file} replaced by a JSON file holding payload."""
    with tempfile.TemporaryDirectory() as d:
        argv = shlex.split(cmd)
        if payload is not None:
            f = os.path.join(d, "in.json")
            json.dump(payload, open(f, "w"))
            argv = [a.replace("{file}", f) for a in argv]
        r = subprocess.run(argv, capture_output=True, text=True, timeout=3600)
    if r.returncode not in (0, 1) or not r.stdout.strip():
        raise RuntimeError((r.stderr or r.stdout or f"exit {r.returncode}").strip().splitlines()[-1][:200])
    return json.loads(r.stdout)


def ch_ids(scan):
    return {f["id"] for f in (scan or {}).get("findings", []) if f.get("severity") in CH and f.get("id")}


def image_proposals(pins, scanner, notes):
    """One move per tag pin whose newer tag clears a critical/high CVE."""
    out = []
    wanted = []
    for p in pins:
        if p.get("kind") != "tag" or not p.get("pinned"):
            continue
        cands = [t for t in [p.get("latestPatch"), p.get("latest")] if t and vkey(t) > vkey(p["pinned"])]
        if cands:
            wanted.append((p, list(dict.fromkeys(cands))))
    refs = sorted({f"{p['image']}:{t}" for p, cs in wanted for t in [p["pinned"], *cs]})
    if not refs:
        return out
    try:
        scans = run_json(scanner, refs)
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        notes.append(f"the image scan failed, no image proposal: {e}")
        return out
    for p, cands in wanted:
        cur = scans.get(f"{p['image']}:{p['pinned']}") or {}
        if cur.get("error"):
            notes.append(f"{p['module']}: {p['image']}:{p['pinned']} could not be scanned: {cur['error']}")
            continue
        best = None
        for t in cands:
            s = scans.get(f"{p['image']}:{t}") or {}
            if s.get("error"):
                notes.append(f"{p['module']}: {p['image']}:{t} could not be scanned: {s['error']}")
                continue
            clears, adds = sorted(ch_ids(cur) - ch_ids(s)), sorted(ch_ids(s) - ch_ids(cur))
            patch = vkey(t)[:2] == vkey(p["pinned"])[:2]
            if clears and (best is None or (patch and not adds) or len(clears) - len(adds) > len(best["clears"]) - len(best["adds"])):
                best = {"kind": "move", "module": p["module"], "image": p["image"], "from": p["pinned"], "to": t,
                        "clears": clears, "adds": adds, "patchLevel": patch, "file": p.get("file", "")}
                if patch and not adds:
                    break
        if best:
            best["text"] = (f"{p['image'].split('/')[-1]} {best['from']} → {best['to']} clears {len(best['clears'])} critical/high, adds "
                            f"{len(best['adds'])}; {'patch-level: the daily patch line' if best['patchLevel'] else 'a minor or major: the release train'}")
            out.append(best)
    return out


def nixpkgs_proposal(config, notes):
    """What the pin the next boundary takes clears and adds, from the last preview."""
    pv = os.path.join(config, "train-preview.json")
    dt = os.path.join(config, "train-preview-details.json")
    if not (os.path.exists(pv) and os.path.exists(dt)):
        return None
    age = (now_utc().timestamp() - os.path.getmtime(dt)) / 86400
    if age > PREVIEW_FRESH_DAYS:
        notes.append(f"the release preview is {int(age)} days old: run tappaas-train.sh preview for the nixpkgs pin")
        return None
    d = json.load(open(dt))
    p = json.load(open(pv))
    clears, adds = set(), set()
    for m, v in (d.get("modules") or {}).items():
        c = v.get("cves") or {}
        clears |= {x["id"] for x in c.get("fixed") or [] if x.get("severity") in CH}
        adds |= {x["id"] for x in c.get("new") or [] if x.get("severity") in CH}
    if not clears:
        return None
    return {"kind": "move", "module": "nixpkgs", "from": (p.get("from") or "")[:12], "to": (p.get("to") or "")[:12],
            "clears": sorted(clears), "adds": sorted(adds), "patchLevel": True,
            "text": f"the next boundary's nixpkgs pin clears {len(clears)} critical/high, adds {len(adds)} (from the release preview)"}


def drafts(status, moved):
    """For each undecided component no move clears: a draft record with the rule
    that would cover most of its CVEs."""
    out = []
    groups = {}
    for t in (status or {}).get("targets", []):
        for i in t.get("items") or []:
            if i.get("mark") == "unread" and i.get("severity") in CH and i.get("component") and i["id"] not in moved:
                groups.setdefault(i["component"], {})[i["id"]] = i
    for comp, items in sorted(groups.items()):
        vecs = [dict(x.split(":", 1) for x in (i.get("vector") or "").split("/")[1:] if ":" in x) for i in items.values() if i.get("vector")]
        rule = None
        if vecs:
            av, ui = Counter(v.get("AV") for v in vecs).most_common(1)[0][0], Counter(v.get("UI") for v in vecs).most_common(1)[0][0]
            covered = [v for v in vecs if v.get("AV") == av and v.get("UI") == ui]
            rule = {"match": {"AV": [av], "UI": [ui]}, "covers": len(covered), "of": len(items)}
        module = comp.split("/", 1)[0]
        out.append({"kind": "draft", "module": module, "component": comp, "cves": sorted(items),
                    "rule": rule, "text": f"{len(items)} undecided critical/high; no pin move clears them"
                    + (f"; a rule on AV:{rule['match']['AV'][0]}/UI:{rule['match']['UI'][0]} would cover {rule['covers']}" if rule else "")})
    return out


def cmd_check(a):
    notes = []
    status_path = os.path.join(a.config, "sbom", "cve-status.json")
    status = json.load(open(status_path)) if os.path.exists(status_path) else None
    try:
        pins = run_json(a.pins).get("pins", [])
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        notes.append(f"the image pins could not be read: {e}")
        pins = []
    props = image_proposals(pins, a.image_scanner, notes)
    nx = nixpkgs_proposal(a.config, notes)
    if nx:
        props.append(nx)
    moved = {c for p in props for c in p["clears"]}
    props += drafts(status, moved)
    doc = {"generated": now_utc().strftime("%Y-%m-%dT%H:%M:%SZ"), "proposals": props, "notes": notes}
    json.dump(doc, open(a.out, "w"), indent=1)
    mv = [p for p in props if p["kind"] == "move"]
    print(f"{len(mv)} pin move(s) would help, {len(props) - len(mv)} component(s) need a decision instead")
    for p in mv:
        print(f"  {p['module']:<14} {p['text']}")
    for n in notes:
        print(f"  note: {n}")
    print(f"written: {a.out}")
    return 0


def read_pin_entry(repo, module, image):
    doc = json.load(open(os.path.join(repo, "src", "image-pins.json")))
    for p in doc.get("pins", []):
        if p.get("module") == module and (not image or p.get("image") == image):
            return p
    return None


def replace_last(text, pattern, value):
    ms = list(re.finditer(pattern, text, re.M))
    if not ms:
        return None
    m = ms[-1]
    return text[:m.start(1)] + value + text[m.end(1):]


def cmd_apply(a):
    doc = json.load(open(a.out)) if os.path.exists(a.out) else {"proposals": []}
    p = next((x for x in doc.get("proposals", []) if x.get("kind") == "move" and x.get("module") == a.module and x.get("image")), None)
    if not p:
        print(f"pin-candidates: no image pin move proposed for {a.module} (run the check first)", file=sys.stderr)
        return 1
    pin = read_pin_entry(a.repo, a.module, p["image"])
    if not pin:
        print(f"pin-candidates: {a.module} {p['image']} is not in src/image-pins.json", file=sys.stderr)
        return 2
    branch = f"pin/{a.module}-{p['to']}"
    wt = tempfile.mkdtemp(prefix="pin-candidate-")
    git = lambda *x, cwd=a.repo: subprocess.run(["git", "-C", cwd, *x], capture_output=True, text=True)
    r = git("worktree", "add", "-q", "-b", branch, wt, "HEAD")
    if r.returncode != 0:
        print(f"pin-candidates: could not make the branch {branch}: {r.stderr.strip()}", file=sys.stderr)
        return 2
    try:
        for place in [{"file": pin["file"], "match": pin["match"]}] + list(pin.get("also", [])):
            f = os.path.join(wt, place["file"])
            new = replace_last(open(f).read(), place["match"], p["to"])
            if new is None:
                print(f"pin-candidates: the pin was not found in {place['file']}", file=sys.stderr)
                return 2
            open(f, "w").write(new)
            git("add", "--", place["file"], cwd=wt)
        msg = f"build(pin): {a.module} {p['image'].split('/')[-1]} {p['from']} to {p['to']}"
        body = f"Clears {len(p['clears'])} critical/high, adds {len(p['adds'])} (daily pin candidates)."
        r = git("commit", "-q", "-m", msg[:72], "-m", body, cwd=wt)
        if r.returncode != 0:
            print(f"pin-candidates: could not commit: {r.stderr.strip()}", file=sys.stderr)
            return 2
    finally:
        git("worktree", "remove", "--force", wt)
    print(f"written to the branch {branch}: {p['image']} {p['from']} → {p['to']}")
    print("The checkout did not move. Live-test the branch, then merge it.")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="pin-candidates.py", description=__doc__.split("\n")[0])
    ap.add_argument("cmd", nargs="?", default="check", choices=("check", "apply"))
    ap.add_argument("module", nargs="?")
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--config", default=CONFIG)
    ap.add_argument("--out")
    ap.add_argument("--pins")
    ap.add_argument("--image-scanner", default=f"{os.environ.get('HEALTH_MANAGER', 'health-manager')} scan images --refs {{file}}")
    a = ap.parse_args()
    a.out = a.out or os.path.join(a.config, "pin-candidates.json")
    a.pins = a.pins or f"python3 {os.path.join(HERE, 'image-pins.py')} --repo {a.repo} --json"
    if a.cmd == "apply":
        if not a.module:
            print("pin-candidates: apply <module>", file=sys.stderr)
            return 2
        return cmd_apply(a)
    return cmd_check(a)


if __name__ == "__main__":
    sys.exit(main())
