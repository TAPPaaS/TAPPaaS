"""cve_components — component records (<module>-components.json) for cve-triage.py.

A record says how one module uses one upstream component and what that makes of
its CVEs. The scan applies them (health-manager, lib/ts/src/cve-decisions.ts);
this writes them, migrates hand-kept VEX into them, and generates VEX from them.
The rules on levels live in the TypeScript library only; nothing here computes
a CVSS score.
"""
import datetime, json, os, re, subprocess

REASONS_CODE = ("not-used", "feature-disabled", "client-only", "admin-input-only", "other")
REASONS_DEPLOYMENT = ("internal-only", "local-access-required", "mitigated-by-rule", "data-not-sensitive")
REASONS = REASONS_CODE + REASONS_DEPLOYMENT
LEVELS = ("critical", "high", "medium", "low")
STATES = ("not_affected", "false_positive", "resolved")
JUSTIFICATIONS = ("code_not_present", "code_not_reachable", "requires_configuration", "requires_dependency",
                  "requires_environment", "protected_by_compiler", "protected_at_runtime", "protected_at_perimeter",
                  "protected_by_mitigating_control")
REVIEW_CODE_DAYS, REVIEW_CODE_MAX, REVIEW_DEPLOYMENT_DAYS = 90, 180, 365
MIN_USE = 80
SUFFIX = "-components.json"


def today():
    t = os.environ.get("TAPPAAS_TRAIN_NOW")
    d = datetime.datetime.fromtimestamp(int(t), datetime.timezone.utc) if t else datetime.datetime.now(datetime.timezone.utc)
    return d.strftime("%Y-%m-%d")


def add_days(date, days):
    return (datetime.date.fromisoformat(date[:10]) + datetime.timedelta(days=days)).isoformat()


def default_review(reason, decided):
    return add_days(decided, REVIEW_DEPLOYMENT_DAYS if reason in REASONS_DEPLOYMENT else REVIEW_CODE_DAYS)


def max_review(reason, decided):
    return add_days(decided, REVIEW_DEPLOYMENT_DAYS if reason in REASONS_DEPLOYMENT else REVIEW_CODE_MAX)


def author(repo):
    who = os.environ.get("TAPPAAS_AUTHOR")
    if who:
        return who
    try:
        n = subprocess.run(["git", "-C", repo, "config", "user.name"], capture_output=True, text=True).stdout.strip()
    except OSError:
        n = ""
    return re.sub(r"\s+", "", n).lower() or os.environ.get("USER", "unknown")


def empty():
    return {"schema": 1, "components": {}}


def load(path):
    if not os.path.exists(path):
        return empty()
    doc = json.load(open(path))
    doc.setdefault("schema", 1)
    doc.setdefault("components", {})
    return doc


def save(path, doc):
    doc["components"] = dict(sorted(doc["components"].items()))
    with open(path, "w") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")


def key(module, eco, source):
    return f"{module}/{eco}:{source.lower()}"


def split_key(k):
    m = re.match(r"^([^/]+)/([^:]+):(.+)$", k)
    return (m.group(1), m.group(2), m.group(3)) if m else None


def purl_parts(purl):
    """(eco, name) of a purl, as lib/ts purlParts."""
    m = re.match(r"^pkg:([^/]+)/(.+?)(?:@[^?#]*)?(?:[?#].*)?$", purl.strip())
    if not m:
        return "", ""
    t = m.group(1).lower()
    from urllib.parse import unquote
    path = [unquote(p) for p in m.group(2).split("/")]
    name = path[-1]
    if t == "generic" and len(path) > 1 and path[0] == "opnsense":
        return "opnsense", name
    if t == "golang":
        return "go", "/".join(path)
    if t == "npm" and len(path) > 1 and path[0].startswith("@"):
        return "npm", f"{path[0]}/{name}"
    return t, name


def major(version):
    v = re.sub(r"^\d+:", "", version or "")
    m = re.match(r"^(\d+)", v)
    return m.group(1) if m else ""


def versions_spec(versions):
    ms = sorted({major(v) for v in versions if major(v)}, key=int)
    return ",".join(f"{m}.*" for m in ms) if ms else "*"


def in_versions(spec, version):
    if not spec or spec.strip() == "*":
        return True
    for s in (x.strip() for x in spec.split(",") if x.strip()):
        if s == "*":
            return True
        mm = re.match(r"^(\d+)\.\*$", s)
        if mm and major(version) == mm.group(1):
            return True
        if s == version or s == re.sub(r"^\d+:", "", version or ""):
            return True
    return False


def scan_items(status):
    """component → [(target id, item)] from a cve-status.json document."""
    out = {}
    for t in (status or {}).get("targets", []):
        for i in t.get("items") or []:
            if i.get("component"):
                out.setdefault(i["component"], []).append((t.get("id", ""), i))
    return out


def basis_of(item):
    b = {"severity": (item.get("severity") or "").lower()}
    if item.get("vector"):
        b["vector"] = item["vector"]
    if item.get("kev"):
        b["kev"] = item["kev"]
    if isinstance(item.get("epss"), (int, float)):
        b["epss"] = item["epss"]
    return b


def validate(doc, module):
    """What is wrong, one line each (the same rules as lib/ts validateComponents)."""
    out = []
    if doc.get("schema") != 1 or not isinstance(doc.get("components"), dict):
        return ["not a components file (schema 1)"]
    for k, r in doc["components"].items():
        sk = split_key(k)
        if not sk:
            out.append(f"{k}: not a component key"); continue
        if sk[0] != module:
            out.append(f"{k}: belongs to {sk[0]}, not {module}")
        if not r.get("migrated") and len((r.get("use") or "").strip()) < MIN_USE:
            out.append(f"{k}: use must say how the module uses the component ({MIN_USE}+ characters)")
        if r.get("reason") not in REASONS:
            out.append(f"{k}: reason {r.get('reason')} is not one of {', '.join(REASONS)}")
        if r.get("reason") in REASONS_DEPLOYMENT and not r.get("migrated") and not r.get("assumes"):
            out.append(f"{k}: a deployment reason needs assumes")
        if r.get("decided") and r.get("reviewBy") and r["reviewBy"] > max_review(r.get("reason", ""), r["decided"]):
            out.append(f"{k}: reviewBy {r['reviewBy']} is later than {max_review(r.get('reason', ''), r['decided'])}")
        for cid, e in (r.get("cves") or {}).items():
            if e.get("level") == "none":
                if e.get("state") not in STATES:
                    out.append(f"{k} {cid}: none needs a VEX state")
                if e.get("state") == "not_affected" and e.get("justification") not in JUSTIFICATIONS:
                    out.append(f"{k} {cid}: not_affected needs a justification")
                if not e.get("why"):
                    out.append(f"{k} {cid}: none needs a why")
    return out


# ── VEX generated from records ─────────────────────────────────────────

def vex_from_records(doc, module, instances, generated):
    """CycloneDX VEX for every standing decision of the records.

    instances: component key → [(purl base, version)] the channels and the site run.
    A decision is stated for each instance inside the record's versions; with none
    known, for the component's package names without a version, plus the
    version range the record holds for.
    """
    vulns = []
    for k, r in sorted(doc.get("components", {}).items()):
        sk = split_key(k)
        if not sk:
            continue
        inst = [(b, v) for b, v in instances.get(k, []) if in_versions(r.get("versions", "*"), v)]
        for cid, e in sorted((r.get("cves") or {}).items()):
            if e.get("deferred") and not (e.get("level") or e.get("modified") or e.get("rule")):
                continue  # a deferral is not an analysis
            ok = [(b, v) for b, v in inst if in_versions(e.get("versions", "*"), v)]
            refs = sorted({f"{b}@{v}" for b, v in ok}) if ok else []
            detail = " ".join(x for x in [k + ".", (r.get("use") or "").strip(), (e.get("why") or "").strip(),
                                           f"Decided by {r.get('author', '?')} {r.get('decided', '?')}; review by {r.get('reviewBy', '?')}."] if x)
            v = {"id": cid, "affects": [{"ref": x} for x in refs] or [{"ref": f"tappaas:component:{k}"}]}
            if not refs:
                v["affects"][0]["versions"] = [{"range": f"vers:{sk[1]}/{_range(r.get('versions', '*'))}"}]
            if e.get("level") == "none":
                v["analysis"] = {"state": e.get("state", "not_affected"), "detail": detail}
                if e.get("justification"):
                    v["analysis"]["justification"] = e["justification"]
            else:
                rating = {"source": {"name": "TAPPaaS"}, "method": "other",
                          "justification": f"{r.get('reason', 'other')}: {(e.get('why') or '').strip() or (r.get('use') or '').strip()}"}
                if e.get("level") in LEVELS:
                    rating["severity"] = e["level"]
                elif e.get("level") == "same":
                    rating["severity"] = (r.get("basis", {}).get(cid, {}).get("severity") or "unknown")
                else:
                    rule = next((x for x in r.get("rules") or [] if x.get("id") == e.get("rule")), None)
                    mod = e.get("modified") or (rule or {}).get("modified") or {}
                    vec = r.get("basis", {}).get(cid, {}).get("vector")
                    if vec and str(vec).startswith("CVSS:3"):
                        rating["method"] = "CVSSv31"
                        rating["vector"] = vec + "".join(f"/{m}:{x}" for m, x in mod.items() if x and x != "X")
                    rating["severity"] = e.get("level") or "unknown"
                v["ratings"] = [rating]
                v["analysis"] = {"state": "exploitable", "detail": detail}
            vulns.append(v)
    return {"bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
            "metadata": {"timestamp": generated, "component": {"type": "application", "name": module,
                         "description": f"TAPPaaS module {module}: generated from {module}{SUFFIX}; do not edit."}},
            "vulnerabilities": vulns}


def _range(spec):
    if not spec or spec.strip() == "*":
        return "*"
    parts = []
    for s in (x.strip() for x in spec.split(",") if x.strip()):
        mm = re.match(r"^(\d+)\.\*$", s)
        parts.append(f">={mm.group(1)}|<{int(mm.group(1)) + 1}" if mm else s)
    return "|".join(parts)


# ── migration of hand-kept VEX ────────────────────────────────────────

def migrate_statements(vex_doc, module, src_of, date, who="migration"):
    """Records from one module's hand-kept VEX file.

    src_of(eco, name) → the source package (Debian), or the name itself.
    Returns (components dict, report). One decision per component and CVE: when
    statements for different packages of one component disagree, the one that
    counts the most is kept (exploitable at its rating over not affected), and
    the report says so.
    """
    comps = {}
    report = {"statements": 0, "records": 0, "decisions": 0, "conflicts": [], "unkeyed": 0}
    rank = {"critical": 4, "high": 3, "medium": 2, "low": 1}
    weight = lambda e: 0 if e.get("level") == "none" else rank.get(e.get("level"), 3)
    for v in vex_doc.get("vulnerabilities") or []:
        report["statements"] += 1
        cid = v.get("id")
        an = v.get("analysis") or {}
        state = an.get("state")
        if not cid or not state:
            report["unkeyed"] += 1
            continue
        refs = [x.get("ref", "") for x in v.get("affects") or [] if x.get("ref")]
        targets = {}
        for r in refs:
            eco, name = purl_parts(r)
            if not eco:
                continue
            ver = r.split("?")[0].rsplit("@", 1)[1] if "@" in r.split("?")[0].split("/", 1)[-1] else ""
            k = key(module, eco, src_of(eco, name) or name)
            targets.setdefault(k, []).append(ver)
        if not targets:
            report["unkeyed"] += 1
            continue
        why = " ".join(x.strip() for x in [an.get("detail") or ""] if x and x.strip())
        if state in ("not_affected", "false_positive", "resolved", "resolved_with_pedigree"):
            entry = {"level": "none", "state": "resolved" if state.startswith("resolved") else state, "why": why or f"{state} (migrated)"}
            if state == "not_affected":
                entry["justification"] = an.get("justification") if an.get("justification") in JUSTIFICATIONS else "code_not_reachable"
        else:
            r = next((x.get("severity", "").lower() for x in v.get("ratings") or [] if (x.get("source") or {}).get("name") == "TAPPaaS"), "")
            entry = {"level": r if r in LEVELS else "same", "why": why or "exploitable here (migrated)"}
        for k, vers in targets.items():
            rec = comps.setdefault(k, {"use": "", "reason": "other", "versions": "*", "cves": {}, "author": who,
                                       "decided": date, "reviewBy": add_days(date, REVIEW_CODE_DAYS), "migrated": True, "_versions": set(),
                                       "_just": {}})
            rec["_versions"].update(x for x in vers if x)
            e = dict(entry)
            if state.startswith("resolved") and vers and all(vers):
                e["versions"] = ",".join(sorted(set(vers)))
            had = rec["cves"].get(cid)
            if had and (had.get("level"), had.get("state")) != (e.get("level"), e.get("state")):
                report["conflicts"].append(f"{k} {cid}")
                if weight(e) <= weight(had):
                    continue
            rec["cves"][cid] = e
            j = e.get("justification") or ("rated" if e.get("level") != "none" else e.get("state"))
            rec["_just"][j] = rec["_just"].get(j, 0) + 1
    for k, rec in comps.items():
        rec["versions"] = versions_spec(rec.pop("_versions"))
        just = rec.pop("_just")
        top = max(just.items(), key=lambda x: x[1])[0] if just else ""
        rec["reason"] = {"code_not_reachable": "not-used", "code_not_present": "not-used", "requires_configuration": "feature-disabled",
                         "requires_dependency": "not-used", "requires_environment": "internal-only",
                         "protected_by_mitigating_control": "mitigated-by-rule", "protected_at_perimeter": "internal-only"}.get(top, "other")
        # The longest period the reason allows: a migrated record needs a person's
        # use statement, and should not lapse before anyone had time to write it.
        rec["reviewBy"] = max_review(rec["reason"], date)
        report["decisions"] += len(rec["cves"])
    report["records"] = len(comps)
    return comps, report
