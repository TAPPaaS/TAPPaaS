#!/usr/bin/env python3
"""pin-preview.py — the last release against "if released now" (#788).

The release train's `preview` (and its boundary, before the deep test) asks it.
Nothing is built and nothing new runs: both sides are EVALUATED or fetched.

  release side    the last release's tree evaluated against its own nixpkgs pin,
                  and the container images it pinned
  now side        this tree evaluated against the pin the next boundary takes,
                  and the images it pins

Every TAPPaaS module counts the same, whatever it is built from: a NixOS guest's
packages and a container image's are matched with today's CVE database on both
sides, so the difference is what the release changes, not what was published
meanwhile. Per module: critical/high now, and against the release: in it, fixed,
new, unchanged. A module the build system does not run is evaluated from its
closure without knowing which packages run — counted, marked approximate (≈).
The nodes and the firewall patch continuously and are not part of a release:
their row has only "now", from the last security scan.

What needs an operator's acknowledgement (`tappaas-train ack`): a MAJOR version
change against the release, a critical/high CVE that is new against it, and a
match that failed. `gate` lists them, `digest` names the set.

Usage:
  pin-preview.py --inventory site.cdx.json --status cve-status.json
                 --base-label v2.1 --base-closures DIR --base-images FILE --base-nix-scanner CMD
                 --now-closures DIR --now-images FILE --now-nix-scanner CMD
                 --image-scanner CMD --from REV --to REV --out preview.json [--ignore FILE]
                 [--details FILE]
  A scanner CMD carries {file}: the JSON list it is handed.
  --details writes, per module, each side's critical/high CVEs (id, package,
  version, severity, nixos|image), its image references and the package versions
  that change — for working out what to fix.

  pin-preview.py --show MODULE --details FILE    one module from a details file:
                                                 NEW, FIXED and SAME, each CVE listed
Exit: 0 written (findings or not), 2 bad input; --show: 1 no such module.
"""
import argparse, hashlib, json, os, re, shlex, subprocess, sys, tempfile

OUTPUTS = {"bin", "lib", "dev", "out", "man", "doc", "info", "debug", "static", "data", "dist", "py"}
# A closure of derivations holds sources (glibc-2.42.tar.xz.drv) and generated
# files (polkit-1.pam, php-extra-init-8.4.25.ini) too: never a version that runs.
SOURCE = re.compile(r"\.(tar(\.[a-z0-9]+)?|tgz|tbz2?|txz|zip|xz|gz|bz2|zst|lz|7z|patch|diff|deb|rpm|whl|gem|jar|crate|nupkg"
                    r"|pam|ini|conf|cfg|service|socket|timer|json|yaml|yml|toml|nix|sh|py|txt|rules|xml)$")
CH = ("Critical", "High")


def parse_name(path):
    """`<hash>-<pname>-<version>[-<output>][.drv]` -> (pname, version); None without a version.
    The same split as health-manager's parseStorePath (nixpkgs' parseDrvName)."""
    base = path.rstrip("/").split("/")[-1]
    if base.endswith(".drv"):
        base = base[:-4]
    m = re.match(r"^[0-9a-z]{32}-(.+)$", base)
    if not m:
        return None
    parts = m.group(1).split("-")
    if len(parts) > 1 and parts[-1] in OUTPUTS:
        parts = parts[:-1]
    for i in range(1, len(parts)):
        if not parts[i][:1].isdigit():
            continue
        ver = parts[i:]
        while len(ver) > 1 and not ver[-1][:1].isdigit():
            ver = ver[:-1]
        return "-".join(parts[:i]), "-".join(ver)
    return None


def vkey(v):
    return [(0, int(x)) if x.isdigit() else (1, x) for x in re.split(r"[.\-+_]", v) if x != ""]


def major(v):
    m = re.match(r"(\d+)", v)
    return m.group(1) if m else v


def semantic_major(old, new):
    """Does old -> new change the MAJOR as an API break means it? Not when the first
    number is a date or a sequence (20260107, 2025_09_19, less 692, systemd 260):
    those count up with every release, so each step is an update, not a break."""
    a, b = major(old), major(new)
    if a.isdigit() and b.isdigit() and (int(a) >= 100 or int(b) >= 100):
        return False
    return a != b


def inventory(cdx):
    """target name -> {pname: set(versions)} for every Nix target of the last scan."""
    out = {}
    for t in cdx.get("components", []):
        props = {p.get("name"): p.get("value") for p in t.get("properties", []) or []}
        if props.get("tappaas:layer") != "nix":
            continue
        pk = {}
        for c in t.get("components", []) or []:
            if c.get("name") and c.get("version"):
                pk.setdefault(c["name"], set()).add(c["version"])
        out[t["name"]] = pk
    return out


def closures(d):
    """module -> {pname: set(versions)} from <module>.txt files of .drv paths."""
    out = {}
    if not d or not os.path.isdir(d):
        return out
    for f in sorted(os.listdir(d)):
        if not f.endswith(".txt"):
            continue
        pk = {}
        for line in open(os.path.join(d, f)):
            pv = parse_name(line.strip())
            if pv and not SOURCE.search(pv[1]):
                pk.setdefault(pv[0], set()).add(pv[1])
        out[f[:-4]] = pk
    return out


def pick(running, versions):
    """The version a side holds for a package that runs today in `running`."""
    if running in versions:
        return running
    same = [v for v in versions if major(v) == major(running)]
    return max(same or versions, key=vkey)


def side_packages(module, clo, inv, union):
    """{pname: version} a side ships for a module; approximate when it runs nowhere."""
    if module in inv:
        out = {}
        for pname, runs in inv[module].items():
            if pname in clo:
                for r in sorted(runs, key=vkey):
                    out.setdefault(pname, set()).add(pick(r, clo[pname]))
        return out, False
    return {p: {max(vs, key=vkey)} for p, vs in clo.items() if p in union}, True


def run_scanner(cmd, payload):
    """Hand `payload` (a JSON list) to a scanner command; return (parsed stdout, error)."""
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "in.json")
        json.dump(payload, open(f, "w"))
        r = subprocess.run([x.replace("{file}", f) for x in shlex.split(cmd)], capture_output=True, text=True)
    try:
        return json.loads(r.stdout or "null"), ("" if r.returncode == 0 else f"exit {r.returncode}")
    except ValueError:
        return None, f"output not parseable (exit {r.returncode}): {(r.stderr or '').strip()[-200:]}"


def ids(findings):
    """Critical/high findings as CVE ids: the unit health-manager's scan counts in —
    one CVE that hits two packages (libssl3 and openssl) is one."""
    return {f["id"] for f in findings if f.get("severity") in CH}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for a in ("--inventory", "--status", "--base-label", "--base-closures", "--base-images", "--base-nix-scanner",
              "--now-closures", "--now-images", "--now-nix-scanner", "--image-scanner", "--from", "--to", "--out"):
        ap.add_argument(a, required=True)
    ap.add_argument("--ignore", help="release/pin-watch-ignore.json: packages whose major is not gated, with the reason")
    ap.add_argument("--details", help="write the per-module details here")
    ap.add_argument("--check-scan", action="store_true",
                    help="'now' is the pin in the tree: compare each module with the nightly scan's count")
    a = ap.parse_args()
    try:
        inv = inventory(json.load(open(a.inventory)))
        status = json.load(open(a.status))
        base_img = json.load(open(a.base_images))
        now_img = json.load(open(a.now_images))
    except (OSError, ValueError) as e:
        print(f"pin-preview: bad input: {e}", file=sys.stderr)
        return 2
    ignore = {}
    if a.ignore and os.path.exists(a.ignore):
        try:
            ignore = json.load(open(a.ignore)).get("packages", {})
        except ValueError:
            print(f"pin-preview: {a.ignore} is not JSON — nothing is ignored", file=sys.stderr)
    union = {p for pk in inv.values() for p in pk}
    clo = {"base": closures(a.base_closures), "now": closures(a.now_closures)}
    modules = sorted(set(clo["base"]) | set(clo["now"]) | set(base_img) | set(now_img))

    # What each side ships, per module.
    pkgs, approx = {"base": {}, "now": {}}, {}
    for m in modules:
        for side in ("base", "now"):
            if m in clo[side]:
                pkgs[side][m], ap_ = side_packages(m, clo[side][m], inv, union)
                approx[m] = approx.get(m, False) or ap_

    # Majors: the release's version against the one it would ship now.
    majors, quiet = {}, {}
    for m in modules:
        b, n = pkgs["base"].get(m, {}), pkgs["now"].get(m, {})
        for pname in sorted(set(b) & set(n)):
            old, new = max(b[pname], key=vkey), max(n[pname], key=vkey)
            if old == new or major(old) == major(new):
                continue
            if semantic_major(old, new) and pname not in ignore:
                majors.setdefault((pname, major(old), major(new)),
                                  {"pkg": pname, "from": old, "to": new, "downgrade": vkey(new) < vkey(old), "modules": []})["modules"].append(m)
            else:
                quiet[pname] = ignore.get(pname) or "date or sequence version"

    # One match per side for the Nix packages, one for every image.
    errors, nix, nix_sup = [], {}, {}
    for side, cmd in (("base", a.base_nix_scanner), ("now", a.now_nix_scanner)):
        uniq = sorted({(p, v) for mp in pkgs[side].values() for p, vs in mp.items() for v in vs})
        res, err = run_scanner(cmd, [{"name": p, "version": v} for p, v in uniq])
        err = err or (res or {}).get("error", "")
        if err:
            errors.append(f"{a.base_label if side == 'base' else 'now'} packages: {err}")
        by, sup = {}, {}
        for f in (res or {}).get("findings", []):
            by.setdefault((f.get("pkg"), f.get("installed")), []).append(f)
        for f in (res or {}).get("suppressed", []):
            sup.setdefault((f.get("pkg"), f.get("installed")), []).append(f)
        nix[side] = by
        nix_sup[side] = sup
    refs = sorted(set(base_img.values()) | set(now_img.values()))
    img, err = run_scanner(a.image_scanner, refs) if refs else ({}, "")
    if err:
        errors.append(f"images: {err}")
    img = img or {}
    for ref in refs:
        e = (img.get(ref) or {}).get("error") if ref in img else "not scanned"
        if e:
            errors.append(f"image {ref}: {e}")

    def side_findings(side, m, suppressed=False):
        """A module's findings on one side: its NixOS packages' and its image's."""
        out = []
        src = nix_sup if suppressed else nix
        for p, vs in pkgs[side].get(m, {}).items():
            for v in vs:
                out += [dict(f, **{"from": "nixos"}) for f in src[side].get((p, v), [])]
        ref = (base_img if side == "base" else now_img).get(m)
        if ref:
            out += [dict(f, **{"from": "image"}) for f in (img.get(ref) or {}).get("suppressed" if suppressed else "findings", [])]
        return out

    def by_id(findings):
        """CVE id -> the CVE, with every package it hits (version, fixed in, nixos|image)."""
        out = {}
        for f in findings:
            if f.get("severity") not in CH:
                continue
            e = out.setdefault(f["id"], {"id": f["id"], "severity": f["severity"], "packages": []})
            if f["severity"] == "Critical":
                e["severity"] = "Critical"
            pk = {"pkg": f.get("pkg"), "version": f.get("installed", ""), "fixed": f.get("fixed", ""), "from": f["from"]}
            if pk not in e["packages"]:
                e["packages"].append(pk)
        return out

    def ordered(d, ks):
        return sorted((d[k] for k in ks), key=lambda f: (f["severity"] != "Critical", f["packages"][0]["pkg"] or "", f["id"]))

    details = {}
    rows, introduced, total = [], {}, {"now": 0, "base": 0, "fixed": 0, "new": 0, "same": 0, "vex": 0}
    for m in modules:
        in_base = m in pkgs["base"] or m in base_img
        in_now = m in pkgs["now"] or m in now_img
        bf = by_id(side_findings("base", m)) if in_base else {}
        nf = by_id(side_findings("now", m)) if in_now else {}
        vx = by_id(side_findings("now", m, suppressed=True)) if in_now else {}
        bk, nk = set(bf), set(nf)
        row = {"module": m, "now": len(nk) if in_now else None, "base": len(bk) if in_base else None,
               "fixed": len(bk - nk), "new": len(nk - bk), "same": len(nk & bk), "vex": len(vx), "approximate": approx.get(m, False),
               "note": "new since " + a.base_label if not in_base else ("removed" if not in_now else ""),
               "image": now_img.get(m) or base_img.get(m)}
        rows.append(row)
        bp, np_ = pkgs["base"].get(m, {}), pkgs["now"].get(m, {})
        details[m] = {
            "module": m, "approximate": approx.get(m, False), "note": row["note"],
            "image": {"base": base_img.get(m), "now": now_img.get(m)},
            "packages": [{"pkg": p, "base": max(bp[p], key=vkey) if p in bp else None, "now": max(np_[p], key=vkey) if p in np_ else None}
                         for p in sorted(set(bp) | set(np_))
                         if (max(bp[p], key=vkey) if p in bp else None) != (max(np_[p], key=vkey) if p in np_ else None)],
            "cves": {"new": ordered(nf, nk - bk), "fixed": ordered(bf, bk - nk), "same": ordered(nf, nk & bk),
                     "vex": ordered(vx, set(vx))},
        }
        for k in nk - bk:
            introduced.setdefault(k, []).append(m)
        for f in ("fixed", "new", "same", "vex"):
            total[f] += row[f]
        total["now"] += len(nk)
        total["base"] += len(bk)

    # The platform: not released, patched continuously — "now" from the last scan.
    platform = [{"target": t.get("name"), "layer": t.get("layer"), "now": (t.get("critical") or 0) + (t.get("high") or 0),
                 "coverage": t.get("coverage")}
                for t in status.get("targets", []) if t.get("layer") in ("debian", "opnsense")]
    # A Nix target that is no evaluated module (the mothership is a flake of its
    # own): counted as it runs, not compared — said so, never dropped.
    for t in status.get("targets", []):
        if t.get("layer") == "nix" and t.get("name") not in modules and t.get("name", "").split(" ")[0] not in modules:
            platform.append({"target": t.get("name"), "layer": "nix, not compared",
                             "now": (t.get("critical") or 0) + (t.get("high") or 0), "coverage": t.get("coverage")})

    # With no pin move, a module that runs here must count what the nightly scan
    # counted for it (its NixOS system and its images, by CVE id) — the two use
    # one matcher and one VEX; a difference is a bug in one of them (#788).
    scan_check = None
    if a.check_scan:
        scanned = {}
        for t in status.get("targets", []):
            if t.get("layer") not in ("nix", "image"):
                continue
            n = t.get("name", "")
            mod = n[n.rfind("(") + 1:-1] if t["layer"] == "image" and n.endswith(")") else n.split(" ")[0]
            scanned.setdefault(mod, set()).update(k.split(" ")[0] for k in t.get("critHighKeys", []))
        scan_check = []
        for r in rows:
            if r["module"] in scanned and r["now"] is not None:
                nowids = {c["id"] for c in details[r["module"]]["cves"]["new"] + details[r["module"]]["cves"]["same"]}
                s = scanned[r["module"]]
                scan_check.append({"module": r["module"], "preview": len(nowids), "scan": len(s),
                                   "previewOnly": sorted(nowids - s), "scanOnly": sorted(s - nowids)})

    gate = sorted([f"major {m['pkg']} {x}->{y}" for (p, x, y), m in majors.items()]
                  + [f"cve {k}" for k in introduced]
                  + (["cve-match-failed"] if errors else []))
    out = {
        "baseLabel": a.base_label, "from": a.__dict__["from"], "to": a.to,
        "modules": rows, "platform": platform, "total": total,
        "platformTotal": sum(p["now"] for p in platform),
        "majors": sorted(majors.values(), key=lambda m: m["pkg"]),
        "notGated": [{"pkg": p, "why": w} for p, w in sorted(quiet.items())],
        "introduced": [{"key": k, "modules": sorted(set(v))} for k, v in sorted(introduced.items())],
        "errors": errors, "gate": gate, "digest": hashlib.sha256("\n".join(gate).encode()).hexdigest()[:16],
        "scanCheck": scan_check,
    }
    json.dump(out, open(a.out, "w"), indent=1)
    if a.details:
        json.dump({"baseLabel": a.base_label, "from": a.__dict__["from"], "to": a.to, "modules": details},
                  open(a.details, "w"), indent=1)
    render(out)
    return 0


def show(module, path):
    """One module from a details file: what changes, then NEW, FIXED, SAME."""
    try:
        d = json.load(open(path))
    except (OSError, ValueError) as e:
        print(f"no details to show ({path}): {e} — run the preview first", file=sys.stderr)
        return 1
    m = d.get("modules", {}).get(module)
    if m is None:
        print(f"no module '{module}' in the preview; it has: {', '.join(sorted(d.get('modules', {})))}", file=sys.stderr)
        return 1
    b = d.get("baseLabel", "the release")
    c = m["cves"]
    # A details file from before #788's alignment holds one flat package per entry.
    for lst in c.values():
        for f in lst:
            if "packages" not in f:
                f["packages"] = [{"pkg": f.get("pkg"), "version": f.get("version", ""), "fixed": "", "from": f.get("from", "")}]
    print(f"{module} — if released now (pin {d.get('to', '')[:12]}) against {b} (pin {d.get('from', '')[:12]})"
          + ("   ≈ approximate: runs nowhere on the build system" if m.get("approximate") else "")
          + (f"   [{m['note']}]" if m.get("note") else ""))
    i = m.get("image") or {}
    if i.get("base") or i.get("now"):
        same = i.get("base") == i.get("now")
        print(f"  image: {i.get('now') or '—'}" + ("   (unchanged)" if same else f"   ({b}: {i.get('base') or '—'})"))
    moved = [p for p in m.get("packages", []) if p["base"] and p["now"]]
    gone = [p["pkg"] for p in m.get("packages", []) if p["base"] and not p["now"]]
    added = [p["pkg"] for p in m.get("packages", []) if p["now"] and not p["base"]]
    def names(xs):
        return ", ".join(xs[:8]) + (f" +{len(xs) - 8}" if len(xs) > 8 else "")
    if moved:
        print(f"  packages whose version changes ({len(moved)}):")
        for p in moved:
            print(f"    {p['pkg']:<32} {p['base']:>14} -> {p['now']}")
    if gone:
        print(f"  no longer shipped ({len(gone)}): {names(gone)}")
    if added:
        print(f"  newly shipped ({len(added)}): {names(added)}")
    print(f"  critical/high CVEs: now {len(c['new']) + len(c['same'])}, {b} {len(c['fixed']) + len(c['same'])}"
          f"   (+{len(c.get('vex', []))} decided by VEX)")
    lists = (("NEW — in now, not in " + b, c["new"]), ("FIXED — in " + b + ", gone now", c["fixed"]),
             ("SAME — in both", c["same"]), ("VEX — decided by a recorded statement, not counted", c.get("vex", [])))
    for title, rows in lists:
        print(f"\n  {title} ({len(rows)}):")
        for f in rows:
            for i, p in enumerate(f["packages"]):
                head = f"{f['severity']:<8} {f['id']:<20}" if i == 0 else " " * 29
                fix = f"  fixed in {p['fixed']}" if p.get("fixed") else ""
                print(f"    {head} {p['pkg'] or '':<28} {p['version'] or '':<24} {p['from']}{fix}")
    return 0


def render(o):
    """The table an operator reads."""
    def tl(xs):
        return ", ".join(xs[:4]) + (f" +{len(xs) - 4}" if len(xs) > 4 else "")
    def n(v):
        return "—" if v is None else str(v)
    b = o["baseLabel"]
    print(f"Release CVE preview — critical/high CVEs, today's CVE database on both sides, after VEX")
    print(f"  if released now: this tree, pin {o['to'][:12]}, its image pins   ·   {b}: its tree, pin {o['from'][:12]}, its image pins")
    print()
    print(f"  {'MODULE':<16} {'NOW':>5} │ {b.upper():>6} {'FIXED':>6} {'NEW':>5} {'SAME':>5} │ {'VEX':>4}  NOTE")
    for r in sorted(o["modules"], key=lambda r: (-(r["now"] or 0), r["module"])):
        note = ("≈ approximate (runs nowhere here)" if r["approximate"] else "") + (("; " if r["approximate"] and r["note"] else "") + r["note"])
        print(f"  {r['module']:<16} {n(r['now']):>5} │ {n(r['base']):>6} {r['fixed']:>6} {r['new']:>5} {r['same']:>5} │ {r.get('vex', 0):>4}  {note}")
    t = o["total"]
    print(f"  {'MODULES':<16} {t['now']:>5} │ {t['base']:>6} {t['fixed']:>6} {t['new']:>5} {t['same']:>5} │ {t.get('vex', 0):>4}")
    if o["platform"]:
        print(f"  — not compared: the platform (patched continuously) and the mothership (now = last scan) —")
        for p in sorted(o["platform"], key=lambda p: -p["now"]):
            print(f"  {p['target']:<16} {p['now']:>5} │")
        print(f"  {'TOTAL':<16} {t['now'] + o['platformTotal']:>5} │")
    print()
    if o["majors"]:
        print(f"  MAJOR version changes since {b} ({len(o['majors'])}):")
        for m in o["majors"]:
            print(f"    {m['pkg']:<28} {m['from']} -> {m['to']}{'  (a DOWNGRADE)' if m.get('downgrade') else ''}   [{tl(sorted(set(m['modules'])))}]")
    else:
        print(f"  no major version changes since {b}")
    if o["notGated"]:
        print(f"  not counted as major ({len(o['notGated'])}): {tl([q['pkg'] for q in o['notGated']])} — date/sequence versions or pin-watch-ignore.json")
    for e in o["errors"]:
        print(f"  CVE match FAILED — {e}")
    if o.get("scanCheck") is not None:
        bad = [c for c in o["scanCheck"] if c["previewOnly"] or c["scanOnly"]]
        print(f"  against the nightly scan: {len(o['scanCheck']) - len(bad)} of {len(o['scanCheck'])} module(s) that run here agree"
              + ("" if not bad else " — differ: " + "; ".join(
                  f"{c['module']} {c['preview']} vs {c['scan']} (preview only {','.join(c['previewOnly'][:3]) or '—'}, scan only {','.join(c['scanOnly'][:3]) or '—'})"
                  for c in bad)))
    print(f"  VEX: our recorded triage (<module>-vex.json), the same statements the nightly scan applies — not in NOW")
    print(f"  to acknowledge: {len(o['gate'])} item(s) ({len(o['introduced'])} new critical/high, {len(o['majors'])} majors)"
          if o["gate"] else "  nothing to acknowledge")


if __name__ == "__main__":
    if "--show" in sys.argv:
        _a = argparse.ArgumentParser()
        _a.add_argument("--show", required=True)
        _a.add_argument("--details", required=True)
        _s = _a.parse_args()
        sys.exit(show(_s.show, _s.details))
    sys.exit(main())
