#!/usr/bin/env bash
#
# test-alert-rules.sh — tappaas-alert-rules.py (ADR-039), offline: no Grafana, no
# logging VM. The validator's rules, the query the platform builds (always the
# computed host list, whatever the module writes), the Grafana rule shape, and
# the hosts a scope reads from a fixture config/.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${HERE}/../tappaas-alert-rules.py"
[[ -f "${S}" ]] || { echo "tappaas-alert-rules.py not found"; exit 77; }
command -v python3 >/dev/null || { echo "needs python3"; exit 77; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/alertrules.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# A fixture site: a Community module with two instances (one archived), a
# foundation module, and the logging:logs consumers that make up "all".
mkdir -p "${TMP}/config" "${TMP}/repo/src/foundation/cluster" "${TMP}/community/hosting" "${TMP}/repo/src/foundation/pvehost"
cat > "${TMP}/config/site1.json"  <<EOF
{"vmname": "site1", "moduleSource": "${TMP}/community/hosting", "integratesWith": ["logging:logs"]}
EOF
cat > "${TMP}/config/site2.json"  <<EOF
{"vmname": "site2", "location": "${TMP}/community/hosting/"}
EOF
# A site.json migration 0019 has not reached: its location is an object (#912).
cat > "${TMP}/config/site.json" <<EOF
{"name": "t", "location": {"country": "DK", "timezone": "Europe/Copenhagen"}}
EOF
cat > "${TMP}/config/oldsite.json" <<EOF
{"vmname": "oldsite", "moduleSource": "${TMP}/community/hosting", "status": "archived"}
EOF
cat > "${TMP}/config/tappaas1.json" <<EOF
{"moduleSource": "${TMP}/repo/src/foundation/pvehost", "integratesWith": ["logging:logs"]}
EOF
cat > "${TMP}/config/cluster.json" <<EOF
{"moduleSource": "${TMP}/repo/src/foundation/cluster"}
EOF

TAPPAAS_REPO_SRC="${TMP}/repo/src" python3 -I - "${S}" "${TMP}" <<'PYEOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ar", sys.argv[1]); ar = importlib.util.module_from_spec(spec); spec.loader.exec_module(ar)
T = sys.argv[2]; cfg = f"{T}/config"
passed = failed = 0
def ck(cond, msg):
    global passed, failed
    if cond: passed += 1
    else: failed += 1; print(f"  FAIL: {msg}")

ok = {"name": "sig-rejected", "title": "Release signature rejected", "kind": "event",
      "match": "tappaas-site: signature rejected", "window": 300, "summary": "A release was refused."}
def rules(*r): return {"rules": list(r)}
def errs(r, foundation=False): return ar.validate(rules(r), foundation)

# ── the validator ──
ck(errs(ok) == [], f"a plain rule validates ({errs(ok)})")
ck(ar.validate({"rules": []}) != [], "an empty rule list is refused")
ck(ar.validate({"rules": [ok], "extra": 1}) != [], "an unknown top-level key is refused")
ck(ar.validate({"rules": [ok], "_comment": "x"}) == [], "a _comment is allowed")
ck(errs({**ok, "name": "Bad Name"}) != [], "a name that is not a DNS label is refused")
ck(ar.validate(rules(ok, ok)) != [], "a name used twice is refused")
ck(errs({**ok, "title": "Släpp"}) != [], "a non-ASCII title is refused (mail subject)")
ck(errs({**ok, "kind": "maybe"}) != [], "an unknown kind is refused")
ck(errs({**ok, "window": 30}) != [] and errs({**ok, "window": 90000}) != [], "a window out of 60–86400 is refused")
ck(errs({k: v for k, v in ok.items() if k != "match"}) != [], "a rule without match (not absent) is refused")
ck(errs({**ok, "match": "a\nb"}) != [], "a multi-line match is refused")
ck(errs({**ok, "colour": "red"}) != [], "an unknown key is refused")
for k, v in (("scope", "all"), ("expr", "sum(__SELECTOR__)"), ("query", "{a}")):
    ck(any("foundation" in e for e in errs({**ok, k: v})), f"'{k}' is refused for a Community module")
ck(errs({**ok, "scope": ["pvehost"]}, True) == [], "a foundation rule may scope to another module")
ck(errs({**ok, "scope": "nodes"}, True) != [], "an unknown scope word is refused")
ck(errs({"name": "e", "title": "E", "kind": "event", "window": 300, "summary": "s", "expr": "sum(__SELECTOR__)"}, True) != [], "an expr rule needs its query")
ck(errs({"name": "e", "title": "E", "kind": "event", "window": 300, "summary": "s", "expr": "sum(count_over_time({host=~\".+\"}[5m]))", "query": "q"}, True) != [], "an expr with a selector of its own is refused")
ck(errs({"name": "e", "title": "E", "kind": "event", "window": 300, "summary": "s", "expr": "sum(count_over_time(__SELECTOR__ [5m]))", "query": "q"}, True) == [], "an expr through __SELECTOR__ validates")
ck(ar.expression(["n1"], {"expr": "sum(count_over_time(__SELECTOR__ [5m]))"}) == 'sum(count_over_time({host=~"^(n1)$"} [5m]))', "__SELECTOR__ becomes the computed selector")
ck(errs({"name": "e", "title": "E", "kind": "event", "window": 300, "summary": "s", "expr": "sum(__SELECTOR__)", "query": "{a}", "match": "x"}, True) != [], "match does not go with expr")
ck(errs({**ok, "capture": {"site": "site=(?P<site>[a-z]+)"}}) == [], "a capture with its named group validates")
ck(errs({**ok, "capture": {"site": "site=([a-z]+)"}}) != [], "a capture without its named group is refused")
ck(errs({**ok, "capture": {"host": "(?P<host>x)"}}) != [], "a reserved label cannot be captured")
ck(errs({**ok, "absent": True, "capture": {"s": "(?P<s>x)"}}) != [], "an absent rule cannot capture")
ck(errs({**ok, "absent": True, "above": 2}) != [], "above does not go with absent")
ck(errs({**ok, "repeat": "24h"}) == [] and errs({**ok, "repeat": "48h"}) != [] and errs({**ok, "repeat": "30m"}) != [], "repeat is 1h–24h")
ck(errs({**ok, "include": ["lines", "bundle"]}) == [], "include lines and bundle validates for any module")
ck(errs({**ok, "include": ["config"]}) != [] and errs({**ok, "include": ["lines", "lines"]}) != [], "include takes lines/bundle once each")
ck(errs({**ok, "mail": {"subject": "{state}: {title} on {host}"}}) == [], "known placeholders validate")
ck(errs({**ok, "mail": {"subject": "{secret}"}}) != [], "an unknown placeholder is refused")
ck(errs({**ok, "mail": {"body": "{lines}"}}) != [], "{lines} without include lines is refused")
ck(errs({**ok, "include": ["lines"], "mail": {"body": "{lines}"}}) == [], "{lines} with include lines validates")
ck(errs({**ok, "mail": {"body": "{label.site}"}}) != [], "a placeholder for a label the rule does not capture is refused")
ck(ar.validate(rules(*[{**ok, "name": f"r{i}"} for i in range(21)])) != [], "more than 20 rules are refused")

# ── the query: the platform's host list, the module's text kept inside its string ──
e = ar.expression(["site2", "site1"], ok)
ck(e == 'sum by (host) (count_over_time({host=~"^(site1|site2)$"} |~ "tappaas-site: signature rejected" [300s]))', f"plain rule expression ({e})")
hostile = {**ok, "match": 'x"} or {host=~".+"} |= "', "unit": 'a"}|{b'}
e = ar.expression(["site1"], hostile)
ck(e.startswith('sum by (host) (count_over_time({host=~"^(site1)$", unit=~"a\\"}|{b"} |~ "x\\"} or {host=~\\".+\\"} |= \\"" [300s]))'),
   f"a hostile match and unit stay inside their string literals ({e})")
ck(f"|~ {ar._q(hostile['match'])} [" in e and e.count('{host=~"^(') == 1, "a hostile match is one quoted literal: no second stream selector")
e = ar.expression(["site1"], {**ok, "capture": {"site": "site=(?P<site>[a-z]+)"}, "above": 1})
ck(e == 'sum by (host, site) (count_over_time({host=~"^(site1)$"} |~ "tappaas-site: signature rejected" | regexp "site=(?P<site>[a-z]+)" [300s])) > 1', f"captures and above ({e})")
e = ar.expression(["site1"], {**ok, "absent": True, "window": 900, "unit": "agent\\.service"})
ck(e == 'count by (host) (count_over_time({host=~"^(site1)$", unit=~"agent\\\\.service"} |~ "tappaas-site: signature rejected" [1h] offset 900s)) unless count by (host) (count_over_time({host=~"^(site1)$", unit=~"agent\\\\.service"} |~ "tappaas-site: signature rejected" [900s]))', f"absent form ({e})")
try: ar.selector(["bad host"], ok); ck(False, "a bad host name is refused")
except ValueError: ck(True, "")
try: ar.selector([], ok); ck(False, "an empty host list is refused")
except ValueError: ck(True, "")

# ── the Grafana rule ──
g = ar.grafana_rule("hosting", {**ok, "include": ["bundle", "lines"], "repeat": "24h", "headline": "Signature rejected",
                                "mail": {"subject": "{state}: {title}"}}, ["site1"])
ck(g["uid"] == "hosting-sig-rejected" and g["ruleGroup"] == "module-hosting" and g["folderUID"] == ar.FOLDER_UID, "uid and group are the module's")
ck(g["labels"] == {"kind": "event", "module": "hosting", "bundle": "true", "lines": "true"}, f"labels ({g['labels']})")
ck(g["annotations"]["headline"] == "Signature rejected" and g["annotations"]["mailSubject"] == "{state}: {title}", "headline and mail template travel as annotations")
ck(g["annotations"]["query"] == '{host=~"^(site1)$"} |~ "tappaas-site: signature rejected"', f"the Explore query ({g['annotations']['query']})")
ck(g["annotations"]["linesQuery"] == '{host="__HOST__"} |~ "tappaas-site: signature rejected"' and g["annotations"]["linesWindow"] == "300", f"include lines carries the per-host lines query ({g['annotations'].get('linesQuery')})")
ck(errs({**ok, "absent": True, "include": ["lines"]}) != [], "include lines is refused on an absent rule")
ck(g["notification_settings"]["repeat_interval"] == "24h" and g["notification_settings"]["receiver"] == ar.RECEIVER, "repeat becomes the rule's routing")
ck([d["refId"] for d in g["data"]] == ["A", "B", "C"] and g["data"][0]["relativeTimeRange"]["from"] == 300 and g["noDataState"] == "OK", "the A/B/C shape of the core rules")
ck(ar.grafana_rule("m", {**ok, "absent": True, "window": 900}, ["a"])["data"][0]["relativeTimeRange"]["from"] == 4500, "an absent rule looks back the window plus an hour")
try: ar.rule_uid("a-very-long-community-module-name", {**ok, "name": "and-a-long-rule-name"}); ck(False, "a uid over 40 characters is refused")
except ValueError: ck(True, "")

# ── config/: whose instances, which hosts ──
ck(ar.scope_hosts(cfg, "hosting") == ["site1", "site2"], f"a module's hosts: its instances, archived left out ({ar.scope_hosts(cfg, 'hosting')})")
ck(ar.scope_hosts(cfg, "pvehost") == ["tappaas1"], "an instance without vmname is named by its config")
ck(ar.scope_hosts(cfg, "*all*") == ["site1", "tappaas1"], f"'all' is every instance that declares logging:logs ({ar.scope_hosts(cfg, '*all*')})")
ck(ar.is_foundation(f"{T}/repo/src/foundation/cluster") and not ar.is_foundation(f"{T}/community/hosting"), "foundation is where the source lives")
ck(not ar.is_foundation(f"{T}/repo/src/foundation/../../evil"), "a path that only starts like the foundation tree is not foundation")
grp = ar.render_group("cluster", rules({**ok, "scope": ["pvehost"]}), lambda m: ar.scope_hosts(cfg, m))
ck(len(grp["rules"]) == 1 and "tappaas1" in grp["rules"][0]["data"][0]["model"]["expr"], "a foundation rule reads its scope's hosts")
grp = ar.render_group("nobody", rules(ok), lambda m: ar.scope_hosts(cfg, m))
ck(grp["rules"] == [], "a module with no instance renders no rule")

# ── the mothership's rules (ADR-041 D4): the journal lines they read ──
import os, re
root = os.path.join(os.path.dirname(sys.argv[1]), "..")
hm = json.load(open(os.path.join(root, "tappaas-cicd-alerts.json")))
ck(ar.validate(hm, True) == [], f"tappaas-cicd-alerts.json validates as foundation ({ar.validate(hm, True)})")
hg = ar.render_group("tappaas-cicd", hm, lambda m: ["tappaas-cicd"])
ck(ar.validate(hm, False) == [], "…and needs nothing a foundation rule alone may do")
ck([r["title"] for r in hg["rules"]] == ["HealthDailyDigest", "CveNewCritical", "CveLevelUp"], "the three rules render (health-manager emit mails a critical root itself)")
line = lambda **k: json.dumps({"event": "transition", "name": "tappaas2", "from": k.get("frm", "ok"), "to": k.get("to", "critical"), "reason": "node-down", "kind": k["kind"], "root": k["root"], "symptoms": 6, "impacted": "4 vm, 2 service", "silenced": k["silenced"]}, separators=(",", ":"))
sweep = lambda expected: json.dumps({"kind": "changed", "class": "node", "name": "tappaas2", "source": "site-manager", "attribute": "memory", "before": 1, "after": 2, "expected": expected}, separators=(",", ":"))
digest, cvenew, levelup = [re.compile(r["match"]) for r in hm["rules"]]
ck(not digest.search(line(kind="causal", root=True, silenced=False)), "the digest does not take a critical root: emit mails it")
ck(digest.search(line(kind="causal", root=True, silenced=False, to="warning")), "the digest takes a warning root")
ck(not digest.search(line(kind="causal", root=True, silenced=True, to="warning")), "…not a silenced one")
ck(not digest.search(line(kind="symptom", root=False, silenced=False, to="warning")), "…not a symptom")
ck(digest.search(sweep(False)), "the digest takes a sweep difference nothing explains")
ck(not digest.search(sweep(True)), "…not an expected one")
ck(hm["rules"][0]["repeat"] == "24h" and hm["rules"][0]["window"] == 86400, "the digest is one mail a day")
# ADR-045 D4: the security scan's lines, and a module's level rising
cnew = lambda silenced=False: json.dumps({"event": "cve-new", "scan": "2026-11-08T03:00:00Z", "count": 2, "modules": "immich", "items": "CVE-2026-1 critical brotli 1.1.0 (immich); CVE-2026-2 high zlib 1.3 (immich)", "silenced": silenced}, separators=(",", ":"))
cchg = json.dumps({"event": "cve-changes", "scan": "x", "count": 1, "what": "immich: 1 new risk", "silenced": False}, separators=(",", ":"))
lvl = lambda up, silenced=False, cls="vm": json.dumps({"event": "transition", "class": cls, "name": "immich", "type": "security", "from": "warning", "to": "warning", "reason": "cve-high", "message": "score 20, high: 1 critical", "kind": "causal", "silenced": silenced, **({"levelUp": True} if up else {})}, separators=(",", ":"))
ck(cvenew.search(cnew()), "cve-new-critical takes the scan's new open items")
ck(not cvenew.search(cchg), "…not the other changes")
ck(digest.search(cchg), "the digest takes the other changes")
ck(levelup.search(lvl(True)), "cve-level-up takes a module's level rising")
ck(not levelup.search(lvl(False)), "…not a level change that is no rise")
ck(not levelup.search(lvl(True, silenced=True)), "…not an acknowledged module")
crit = lambda up: lvl(up).replace('"to":"warning"', '"to":"critical"').replace('"reason":"cve-high"', '"reason":"cve-critical"')
ck(levelup.search(crit(True)), "a module rising to critical is mailed by cve-level-up (a CVE level is no root notice of its own)")
for lbl, rx in hm["rules"][1]["capture"].items():
    ck(re.search(rx, cnew()), f"cve-new-critical: {lbl} is read from the line")
ck(re.search(hm["rules"][1]["capture"]["items"], cnew()).group("items").startswith("CVE-2026-1 critical brotli"), "the mail lists the items")
for lbl, rx in hm["rules"][2]["capture"].items():
    ck(re.search(rx, lvl(True)), f"cve-level-up: {lbl} is read from the line")
ck(re.search(hm["rules"][2]["capture"]["level"], lvl(True)).group("level") == "high", "the level-up mail names the level")

# ── the core rules, moved out of logging.nix into their modules (ADR-039 D6) ──
import os
root = os.path.join(os.path.dirname(sys.argv[1]), "..", "..")
gold = json.load(open(os.path.join(os.path.dirname(sys.argv[1]), "test", "fixtures", "core-alert-rules.json")))
hosts = {"pvehost": ["tappaas1", "tappaas2"], "tappaas-cicd": ["tappaas-cicd"], "*all*": ["logging", "tappaas-cicd"]}
seen = set()
for m in ("pvehost", "cluster", "network", "backup", "logging"):
    doc = json.load(open(os.path.join(root, m, f"{m}-alerts.json")))
    ck(ar.validate(doc, True) == [], f"{m}-alerts.json validates as foundation ({ar.validate(doc, True)})")
    for r in ar.render_group(m, doc, lambda x, m=m: hosts.get(x, hosts["pvehost"] if x == m == "pvehost" else []))["rules"]:
        g = gold.get(r["title"]); seen.add(r["title"])
        if not g:
            ck(False, f"{r['title']}: not a core rule"); continue
        got = {"module": m, "kind": r["labels"]["kind"], "bundle": r["labels"].get("bundle") == "true",
               "from": r["data"][0]["relativeTimeRange"]["from"], "expr": r["data"][0]["model"]["expr"],
               "query": r["annotations"]["query"], "summary": r["annotations"]["summary"],
               "headline": r["annotations"].get("headline"), "repeat": r.get("notification_settings", {}).get("repeat_interval")}
        for k in g:
            ck(got[k] == g[k], f"{r['title']}.{k}: {got[k]!r} != {g[k]!r}")
ck(seen == set(gold), f"every core rule is in a module file ({sorted(set(gold) - seen)})")

# ── source: metrics (ADR-046 D6) ────────────────────────────────────
mr = {"name": "slow-logins", "title": "Logins slow", "kind": "state", "source": "metrics", "signal": "http_p95_seconds",
      "above": 1.5, "window": 900, "summary": "The login page's p95 stayed over 1.5 s for 15 minutes.",
      "mail": {"subject": "{state}: {title}", "body": "{summary}\n{query}"}}
ck(ar.validate({"rules": [mr]}) == [], f"a metrics rule validates ({ar.validate({'rules': [mr]})})")
bad = dict(mr, signal="made_up", above="1", match="x")
errs = ar.validate({"rules": [bad]})
ck(any("signal" in e for e in errs) and any("'above'" in e for e in errs) and any("'match' does not go" in e for e in errs), f"a bad metrics rule says why ({errs})")
ck(any("'signal' goes with" in e for e in ar.validate({"rules": [dict(mr, source="logs", match="y")]})), "a signal on a log rule is refused")
ck(any("label." in e for e in ar.validate({"rules": [dict(mr, mail={"body": "{label.x}"})]})), "a metrics rule has no captured labels")
g = ar.render_group("identity", {"rules": [mr]}, lambda m: ["identity"])["rules"][0]
ck(g["data"][0]["datasourceUid"] == "prometheus", "a metrics rule reads Prometheus")
ck(g["data"][0]["model"]["expr"] == 'min_over_time((histogram_quantile(0.95, sum by (tappaas_ci_id, le) (rate(caddy_http_request_duration_seconds_bucket{tappaas_module=~"^(identity)$"}[5m]))))[900s:1m]) > 1.5',
   f"held over the threshold for the window, on the module's routes ({g['data'][0]['model']['expr']})")
ck(g["labels"] == {"kind": "state", "module": "identity", "source": "metrics"}, f"its labels ({g['labels']})")
ck(g["data"][1]["model"]["reducer"] == "last" and g["data"][2]["model"]["conditions"][0]["evaluator"] == {"type": "gt", "params": [0]}, "delivery as a log rule's")
ck(g["annotations"]["mailSubject"] == "{state}: {title}", "the mail unchanged")
gm = ar.render_group("nextcloud", {"rules": [dict(mr, signal="memory_pressure_percent", above=20)]}, lambda m: ["nextcloud"])["rules"][0]
ck('service_name=~"^(nextcloud)$"' in gm["data"][0]["model"]["expr"], "a guest signal: the module's guests by name")
ck(ar.render_group("nextcloud", {"rules": [dict(mr, signal="memory_pressure_percent")]}, lambda m: [])["rules"] == [], "no guest in scope: no rule")

print(f"alert-rules: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PYEOF
rc=$?

# The CLI: validate's exit code and messages.
printf '{"rules":[{"name":"x","title":"X","kind":"event","match":"y","window":300,"summary":"s","scope":"all"}]}' > "${TMP}/c.json"
if python3 -I "${S}" validate "${TMP}/c.json" 2>/dev/null; then echo "  FAIL: CLI validate accepted a Community scope"; rc=1; fi
python3 -I "${S}" validate --foundation "${TMP}/c.json" || { echo "  FAIL: CLI validate --foundation refused a foundation scope"; rc=1; }
exit "${rc}"
