#!/usr/bin/env python3
"""pin-preview.py — what would the next nixpkgs pin bring to what runs here? (#788)

The release train's `preview` (and its boundary, before the deep test) asks it.
Nothing is built: the guests' systems are EVALUATED against the new pin by the
caller, and each one's derivation closure handed in as a list of .drv paths. A
closure holds build tools too, so only packages that run TODAY are compared —
the last security scan's inventory (config/sbom/site.cdx.json) says which, and
its findings (cve-status.json) are the baseline for the CVE side.

  majors      a package whose major version changes (3.7.7 -> 4.0.1), per target
  CVEs        the next pin's packages matched by `health-manager scan nix-list`:
              critical/high ones it INTRODUCES, the ones that REMAIN, and how
              many it FIXES

What needs an operator's acknowledgement (`tappaas-train ack`) is the majors and
the introduced critical/high CVEs; `gate` lists them, `digest` names the set.

Usage:
  pin-preview.py --inventory site.cdx.json --status cve-status.json
                 --closures DIR (one <target>.txt of .drv paths each)
                 --scanner "<command> --components {file}" --from REV --to REV
                 --out preview.json
Exit: 0 written (findings or not), 2 bad input.
"""
import argparse, hashlib, json, os, re, shlex, subprocess, sys, tempfile

OUTPUTS = {"bin", "lib", "dev", "out", "man", "doc", "info", "debug", "static", "data", "dist", "py"}
# A closure of derivations holds sources (glibc-2.42.tar.xz.drv) and generated
# files (polkit-1.pam, php-extra-init-8.4.25.ini) too: never a version that runs.
SOURCE = re.compile(r"\.(tar(\.[a-z0-9]+)?|tgz|tbz2?|txz|zip|xz|gz|bz2|zst|lz|7z|patch|diff|deb|rpm|whl|gem|jar|crate|nupkg"
                    r"|pam|ini|conf|cfg|service|socket|timer|json|yaml|yml|toml|nix|sh|py|txt|rules|xml)$")


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


def baseline(status):
    """target name -> set of "<id> <pkg>" critical/high keys of the last scan."""
    return {t.get("name"): set(t.get("critHighKeys") or []) for t in status.get("targets", []) if t.get("layer") == "nix"}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    for a in ("--inventory", "--status", "--closures", "--scanner", "--from", "--to", "--out"):
        ap.add_argument(a, required=True)
    ap.add_argument("--ignore", help="release/pin-watch-ignore.json: packages whose major is not gated, each with its reason")
    args = ap.parse_args()
    ignore = {}
    if args.ignore and os.path.exists(args.ignore):
        try:
            ignore = json.load(open(args.ignore)).get("packages", {})
        except ValueError:
            print(f"pin-preview: {args.ignore} is not JSON — nothing is ignored", file=sys.stderr)
    try:
        inv = inventory(json.load(open(args.inventory)))
        base = baseline(json.load(open(args.status)))
    except (OSError, ValueError) as e:
        print(f"pin-preview: cannot read the last security scan: {e}", file=sys.stderr)
        return 2

    targets, majors, new_comps, skipped, quiet = {}, {}, {}, [], {}
    for name in sorted(inv):
        f = os.path.join(args.closures, f"{name}.txt")
        if not os.path.exists(f):
            skipped.append(name)
            continue
        nxt = {}
        for line in open(f):
            pv = parse_name(line.strip())
            if pv and not SOURCE.search(pv[1]):
                nxt.setdefault(pv[0], set()).add(pv[1])
        comps, changes = [], []
        for pname, olds in sorted(inv[name].items()):
            news = nxt.get(pname)
            if not news:
                continue                      # gone from the closure, or not found by name
            for old in sorted(olds, key=vkey):
                if old in news:
                    comps.append((pname, old)); continue
                same = [v for v in news if major(v) == major(old)]
                new = max(same or news, key=vkey)
                comps.append((pname, new))
                is_major = not same and semantic_major(old, new) and pname not in ignore
                down = vkey(new) < vkey(old)
                changes.append({"pkg": pname, "from": old, "to": new, "major": is_major, "downgrade": down})
                if is_major:
                    majors.setdefault((pname, major(old), major(new)),
                                      {"pkg": pname, "from": old, "to": new, "downgrade": down, "targets": []})["targets"].append(name)
                elif not same:
                    # A first number that moved but is not gated: say why, once.
                    quiet[pname] = ignore.get(pname) or "date or sequence version"
        targets[name] = {"changes": changes, "packages": len(comps)}
        new_comps[name] = comps

    # One match for every package of every target: the next pin's CVEs.
    uniq = sorted({c for cs in new_comps.values() for c in cs})
    findings, scan_error = [], ""
    with tempfile.TemporaryDirectory() as d:
        lf = os.path.join(d, "components.json")
        json.dump([{"name": n, "version": v} for n, v in uniq], open(lf, "w"))
        cmd = [x.replace("{file}", lf) for x in shlex.split(args.scanner)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        try:
            res = json.loads(r.stdout or "{}")
            findings, scan_error = res.get("findings", []), res.get("error", "")
        except ValueError:
            scan_error = f"scanner output not parseable (exit {r.returncode}): {(r.stderr or '').strip()[-200:]}"
        if r.returncode != 0 and not scan_error:
            scan_error = f"scanner exit {r.returncode}"

    by_pkg = {}
    for f in findings:
        if f.get("severity") in ("Critical", "High"):
            by_pkg.setdefault((f.get("pkg"), f.get("installed")), []).append(f)
    introduced, remaining, fixed = {}, {}, 0
    for name, comps in new_comps.items():
        now = {f"{f['id']} {f['pkg']}" for c in comps for f in by_pkg.get(c, [])}
        sev = {f"{f['id']} {f['pkg']}": f.get("severity") for c in comps for f in by_pkg.get(c, [])}
        before = base.get(name, set())
        for k in now - before:
            introduced.setdefault(k, {"key": k, "severity": sev[k], "targets": []})["targets"].append(name)
        for k in now & before:
            remaining.setdefault(k, {"key": k, "severity": sev[k], "targets": []})["targets"].append(name)
        fixed += len(before - now)

    # An unknown CVE side is no clean one: it is acknowledged like a finding.
    gate = sorted([f"major {m['pkg']} {a}->{b}" for (p, a, b), m in majors.items()]
                  + [f"cve {k}" for k in introduced]
                  + (["cve-match-failed"] if scan_error else []))
    out = {
        "from": args.__dict__["from"], "to": args.to,
        "majors": sorted(majors.values(), key=lambda m: m["pkg"]),
        "cves": {"introduced": sorted(introduced.values(), key=lambda x: x["key"]),
                 "remaining": sorted(remaining.values(), key=lambda x: x["key"]),
                 "fixed": fixed},
        "targets": targets, "notCompared": skipped, "scanError": scan_error,
        "notGated": [{"pkg": p, "why": w} for p, w in sorted(quiet.items())],
        "gate": gate, "digest": hashlib.sha256("\n".join(gate).encode()).hexdigest()[:16],
    }
    json.dump(out, open(args.out, "w"), indent=1)

    # The summary an operator reads.
    def tl(xs):
        return ", ".join(xs[:4]) + (f" +{len(xs) - 4}" if len(xs) > 4 else "")
    print(f"Pin preview {out['from'][:12]} -> {out['to'][:12]}: {len(targets)} targets compared"
          + (f" ({len(skipped)} not evaluated: {tl(skipped)})" if skipped else ""))
    if out["majors"]:
        print(f"  MAJOR version changes ({len(out['majors'])}):")
        for m in out["majors"]:
            print(f"    {m['pkg']:<28} {m['from']} -> {m['to']}{'  (a DOWNGRADE)' if m.get('downgrade') else ''}"
                  f"   [{tl(sorted(set(m['targets'])))}]")
    else:
        print("  no major version changes")
    if quiet:
        print(f"  not counted as major ({len(quiet)}): {tl(sorted(quiet))} — date/sequence versions or pin-watch-ignore.json")
    if scan_error:
        print(f"  CVE match FAILED: {scan_error} — the CVE side is unknown")
    else:
        print(f"  CVEs: {fixed} critical/high fixed, {len(introduced)} introduced, {len(remaining)} remain")
        for x in out["cves"]["introduced"]:
            print(f"    NEW {x['severity']:<8} {x['key']:<48} [{tl(sorted(set(x['targets'])))}]")
    print(f"  to acknowledge: {len(gate)} item(s), digest {out['digest']}" if gate else "  nothing to acknowledge")
    return 0


if __name__ == "__main__":
    sys.exit(main())
