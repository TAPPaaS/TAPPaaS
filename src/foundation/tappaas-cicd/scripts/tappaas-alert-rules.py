#!/usr/bin/env python3
"""tappaas-alert-rules — a module's alert rules over its logs (ADR-039).

A module ships <module>-alerts.json next to its module JSON. It names WHICH
lines matter (a pattern, an optional unit, labels captured from the line), a
window, a kind, and optionally the mail's text and attachments. It never writes
LogQL: this builds the query, with a host selector computed from config/, so a
rule counts only lines its own guests wrote (the logging VM sets `host` from the
push credential, #165 §1). Foundation modules may scope a rule to other
modules' hosts or to every shipping host, and give an expression as written.

The rules go to the logging VM's Grafana through its provisioning API, one rule
group per module in the folder "TAPPaaS modules", beside the core rules, and
are mailed through the existing contact point (tappaas-alert-receiver).

A rule with `source: "metrics"` (ADR-046 D6) names a signal the platform
measures (lib/ts/src/perf-signals.ts; SIGNALS below), a threshold (`above`) and a
window: it fires when the signal has stayed over the threshold for the whole
window on one of the module's guests or published services. It is built over
Prometheus, never written as PromQL by the module; delivery, labels and the
mail are a log rule's.

A rule with `security: "info" | "warning" | "critical"` (ADR-050) is a security
hit: it carries the labels type=security and level=<value>, the receiver keeps
each hit (first, last, count) and health-manager holds the condition it raises
(warning 24 h from the last hit, critical until acknowledged). Security rules
are rendered only while the site's security monitoring is on (site.json
security.monitoring; not set: off on a small site).

Usage:
  tappaas-alert-rules.py validate <file> [--foundation]
  tappaas-alert-rules.py render   <module> [--file F] [--hosts a,b] [--foundation] [--config-dir D]
  tappaas-alert-rules.py hosts    <module> [--config-dir D]
  tappaas-alert-rules.py apply    <module> [--without INSTANCE] [--config-dir D] [--dry-run]
  tappaas-alert-rules.py remove   <module> [--dry-run]
  tappaas-alert-rules.py apply-all [--config-dir D] [--dry-run]

Exit: 0 ok · 1 the file does not validate, or Grafana refused · 2 bad arguments.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

CONFIG_DIR = os.environ.get("TAPPAAS_CONFIG", "/home/tappaas/config")
REPO_SRC = os.environ.get("TAPPAAS_REPO_SRC", "/home/tappaas/TAPPaaS/src")
FOLDER_TITLE = "TAPPaaS modules"
FOLDER_UID = "tappaas-modules"
RECEIVER = "tappaas-site-notify"
GROUP_INTERVAL = 60
MAX_RULES = 20

DNS = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
NAME = re.compile(r"^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$")
LABEL = re.compile(r"^[a-z_][a-z0-9_]{0,30}$")
REPEAT = re.compile(r"^([1-9]|1[0-9]|2[0-4])h$")
PLACEHOLDER = re.compile(r"\{([a-z]+(?:\.[a-z_][a-z0-9_]*)?)\}")
PLACEHOLDERS = {"state", "title", "host", "hosts", "module", "labels", "summary",
                "since", "resolved", "query", "lines"}
# Labels Grafana, Loki or the receiver already mean something by.
RESERVED_LABELS = {"host", "kind", "module", "bundle", "lines", "alertname", "unit",
                   "severity", "zone", "source", "job", "grafana_folder", "container"}
RULE_KEYS = {"name", "title", "headline", "kind", "match", "unit", "capture", "window",
             "above", "absent", "repeat", "summary", "mail", "include", "source", "signal",
             "security"}
SECURITY_LEVELS = ("info", "warning", "critical")
# The signals a metrics rule may name: lib/ts/src/perf-signals.ts's names and
# expressions (a test holds the two equal). __SEL__ is the label selector.
SIGNALS = {
    "pool_write_latency_seconds": ("storage-pool", "max by (tappaas_ci_id, pool) (tappaas_zpool_write_wait_seconds{__SEL__})"),
    "pool_read_latency_seconds": ("storage-pool", "max by (tappaas_ci_id, pool) (tappaas_zpool_read_wait_seconds{__SEL__})"),
    "cpu_pressure_percent": ("guest", "max by (tappaas_ci_id) (proxmox_vm_pressurecpusome{__SEL__})"),
    "memory_pressure_percent": ("guest", "max by (tappaas_ci_id) (proxmox_vm_pressurememorysome{__SEL__})"),
    "io_pressure_percent": ("guest", "max by (tappaas_ci_id) (proxmox_vm_pressureiosome{__SEL__})"),
    "node_memory_pressure_percent": ("machine", 'max by (tappaas_ci_id) (tappaas_node_psi_some_avg60{__SEL__, resource="memory"})'),
    "node_io_pressure_percent": ("machine", 'max by (tappaas_ci_id) (tappaas_node_psi_some_avg60{__SEL__, resource="io"})'),
    "http_p95_seconds": ("route", "histogram_quantile(0.95, sum by (tappaas_ci_id, le) (rate(caddy_http_request_duration_seconds_bucket{__SEL__}[5m])))"),
    "http_5xx_ratio": ("route", 'sum by (tappaas_ci_id) (rate(caddy_http_request_duration_seconds_count{__SEL__, code="5xx"}[5m])) / sum by (tappaas_ci_id) (rate(caddy_http_request_duration_seconds_count{__SEL__}[5m]))'),
    "probe_seconds": ("route", "max by (tappaas_ci_id) (probe_duration_seconds{__SEL__})"),
}
FOUNDATION_KEYS = {"scope", "expr", "query"}


# ── validation ──────────────────────────────────────────────────────────

def _ascii_line(v, n):
    return isinstance(v, str) and 0 < len(v) <= n and v.isascii() and v.isprintable()


def _regex_ok(v, n):
    return isinstance(v, str) and 0 < len(v) <= n and "\n" not in v and "\r" not in v


def validate(doc, foundation=False):
    """Every finding in a parsed <module>-alerts.json, as strings; [] is valid."""
    errs = []
    if not isinstance(doc, dict):
        return ["the file is not a JSON object"]
    for k in doc:
        if k != "rules" and not k.startswith("_"):
            errs.append(f"unknown top-level key '{k}' (only 'rules')")
    rules = doc.get("rules")
    if not isinstance(rules, list) or not rules:
        return errs + ["'rules' must be a non-empty list"]
    if len(rules) > MAX_RULES:
        errs.append(f"{len(rules)} rules: at most {MAX_RULES}")
    seen = set()
    for i, r in enumerate(rules):
        where = f"rules[{i}]"
        if not isinstance(r, dict):
            errs.append(f"{where}: not an object")
            continue
        name = r.get("name")
        if isinstance(name, str):
            where = f"rule '{name}'"
        allowed = RULE_KEYS | (FOUNDATION_KEYS if foundation else set())
        for k in r:
            if k.startswith("_"):
                continue
            if k in FOUNDATION_KEYS and not foundation:
                errs.append(f"{where}: '{k}' is for foundation modules only")
            elif k not in allowed:
                errs.append(f"{where}: unknown key '{k}'")
        if not (isinstance(name, str) and NAME.match(name)):
            errs.append(f"{where}: 'name' must be a DNS label of at most 40 characters")
        elif name in seen:
            errs.append(f"{where}: name used twice")
        else:
            seen.add(name)
        if not _ascii_line(r.get("title"), 80):
            errs.append(f"{where}: 'title' must be printable ASCII, 1–80 characters (it is the mail subject)")
        if "headline" in r and not _ascii_line(r["headline"], 80):
            errs.append(f"{where}: 'headline' must be printable ASCII, 1–80 characters")
        if r.get("kind") not in ("event", "state"):
            errs.append(f"{where}: 'kind' must be 'event' or 'state'")
        if not (isinstance(r.get("summary"), str) and 0 < len(r["summary"]) <= 1000):
            errs.append(f"{where}: 'summary' is required, at most 1000 characters")
        w = r.get("window")
        if not (isinstance(w, int) and not isinstance(w, bool) and 60 <= w <= 86400):
            errs.append(f"{where}: 'window' must be whole seconds, 60–86400")
        if "security" in r and r["security"] not in SECURITY_LEVELS:
            errs.append(f"{where}: 'security' is info, warning or critical")
        if r.get("source", "logs") not in ("logs", "metrics"):
            errs.append(f"{where}: 'source' is 'logs' (the default) or 'metrics'")
        if r.get("source") == "metrics":
            if r.get("signal") not in SIGNALS:
                errs.append(f"{where}: 'signal' must be one the platform measures: {', '.join(sorted(SIGNALS))}")
            a = r.get("above")
            if not (isinstance(a, (int, float)) and not isinstance(a, bool) and a >= 0):
                errs.append(f"{where}: a metrics rule needs 'above', the threshold, a number in the signal's unit")
            for k in ("match", "unit", "capture", "absent", "expr", "query", "include"):
                if k in r:
                    errs.append(f"{where}: '{k}' does not go with a metrics rule (the signal says it)")
            for part in ("subject", "body"):
                t = (r.get("mail") or {}).get(part) if isinstance(r.get("mail"), dict) else None
                for ph in PLACEHOLDER.findall(t or ""):
                    if ph.startswith("label.") or ph.split(".")[0] not in PLACEHOLDERS - {"lines"}:
                        errs.append(f"{where}: mail.{part} uses {{{ph}}}, which a metrics rule has not")
            continue
        elif "signal" in r:
            errs.append(f"{where}: 'signal' goes with source 'metrics'")
        expr = r.get("expr")
        absent = r.get("absent", False)
        if not isinstance(absent, bool):
            errs.append(f"{where}: 'absent' must be true or false")
        if expr is not None:
            if not (isinstance(expr, str) and 0 < len(expr) <= 4000):
                errs.append(f"{where}: 'expr' must be a LogQL expression, at most 4000 characters")
            elif "__SELECTOR__" not in expr or "{" in expr.replace("__SELECTOR__", ""):
                errs.append(f"{where}: 'expr' selects streams only through __SELECTOR__ (the computed host list), never a {{…}} of its own")
            for k in ("match", "unit", "capture", "above", "absent"):
                if k in r:
                    errs.append(f"{where}: '{k}' does not go with 'expr' (the expression says it)")
            if "query" not in r:
                errs.append(f"{where}: a rule with 'expr' needs its 'query' (the Explore line)")
        else:
            if "match" in r and not _regex_ok(r["match"], 512):
                errs.append(f"{where}: 'match' must be one line of RE2, at most 512 characters")
            if "match" not in r and not absent:
                errs.append(f"{where}: 'match' is required (except for an absent rule)")
        if "unit" in r and not _regex_ok(r["unit"], 256):
            errs.append(f"{where}: 'unit' must be one line of RE2, at most 256 characters")
        cap = r.get("capture", {})
        if not isinstance(cap, dict):
            errs.append(f"{where}: 'capture' must map a label to its RE2")
            cap = {}
        if len(cap) > 3:
            errs.append(f"{where}: at most 3 captured labels")
        if cap and absent:
            errs.append(f"{where}: an absent rule cannot capture labels (there is no line to take them from)")
        for lbl, rx in cap.items():
            if not LABEL.match(lbl) or lbl in RESERVED_LABELS:
                errs.append(f"{where}: capture label '{lbl}' is not a free label name")
            elif not _regex_ok(rx, 256) or f"(?P<{lbl}>" not in rx:
                errs.append(f"{where}: capture '{lbl}' must be one line of RE2 with a group (?P<{lbl}>…)")
        if "above" in r:
            a = r["above"]
            if not (isinstance(a, int) and not isinstance(a, bool) and 0 <= a <= 10000):
                errs.append(f"{where}: 'above' must be a whole number, 0–10000")
            if absent:
                errs.append(f"{where}: 'above' does not go with 'absent'")
        if "repeat" in r and not (isinstance(r["repeat"], str) and REPEAT.match(r["repeat"])):
            errs.append(f"{where}: 'repeat' must be 1h–24h")
        inc = r.get("include", [])
        if not (isinstance(inc, list) and all(x in ("lines", "bundle") for x in inc) and len(set(inc)) == len(inc)):
            errs.append(f"{where}: 'include' must list 'lines' and/or 'bundle', each once")
        elif "lines" in inc and (absent or expr is not None):
            errs.append(f"{where}: include 'lines' needs a match rule (an absent or expr rule has no lines to send)")
        mail = r.get("mail")
        if mail is not None:
            if not isinstance(mail, dict) or set(mail) - {"subject", "body"} or not mail:
                errs.append(f"{where}: 'mail' takes 'subject' and/or 'body'")
            else:
                for part, n in (("subject", 200), ("body", 4000)):
                    t = mail.get(part)
                    if t is None:
                        continue
                    if not (isinstance(t, str) and 0 < len(t) <= n) or (part == "subject" and not _ascii_line(t, n)):
                        errs.append(f"{where}: mail.{part} must be text of at most {n} characters"
                                    + (" (printable ASCII)" if part == "subject" else ""))
                        continue
                    for ph in PLACEHOLDER.findall(t):
                        base = ph.split(".")[0]
                        if ph.startswith("label."):
                            if ph[6:] not in cap:
                                errs.append(f"{where}: mail.{part} uses {{{ph}}}, which the rule does not capture")
                        elif base not in PLACEHOLDERS:
                            errs.append(f"{where}: mail.{part} uses unknown placeholder {{{ph}}}")
                        elif base == "lines" and "lines" not in inc:
                            errs.append(f"{where}: mail.{part} uses {{lines}} without include: [\"lines\"]")
        if foundation and "scope" in r:
            sc = r["scope"]
            if sc != "all" and not (isinstance(sc, list) and 0 < len(sc) <= 10 and all(isinstance(m, str) and DNS.match(m) for m in sc)):
                errs.append(f"{where}: 'scope' is \"all\" or a list of module names")
        if foundation and "query" in r and not (isinstance(r["query"], str) and 0 < len(r["query"]) <= 1000):
            errs.append(f"{where}: 'query' must be at most 1000 characters")
    return errs


# ── the query and the Grafana rule ──────────────────────────────────────

def _q(s):
    """A LogQL string literal: Go-quoted, which JSON's escaping is for ASCII."""
    return json.dumps(s, ensure_ascii=True)


def selector(hosts, rule):
    """The stream selector: always the computed host list, never the module's."""
    if hosts == "*":
        m = 'host=~".+"'
    else:
        for h in hosts:
            if not DNS.match(h):
                raise ValueError(f"bad host name '{h}'")
        if not hosts:
            raise ValueError("no hosts in scope")
        m = "host=~" + _q("^(" + "|".join(sorted(set(hosts))) + ")$")
    if "unit" in rule:
        m += ", unit=~" + _q(rule["unit"])
    return "{" + m + "}"


def expression(hosts, rule):
    if "expr" in rule:
        return rule["expr"].replace("__SELECTOR__", selector(hosts, rule))
    sel = selector(hosts, rule)
    flt = f" |~ {_q(rule['match'])}" if "match" in rule else ""
    w = rule["window"]
    if rule.get("absent"):
        return (f"count by (host) (count_over_time({sel}{flt} [1h] offset {w}s))"
                f" unless count by (host) (count_over_time({sel}{flt} [{w}s]))")
    caps = rule.get("capture", {})
    for lbl in sorted(caps):
        flt += f" | regexp {_q(caps[lbl])}"
    by = ", ".join(["host"] + sorted(caps))
    e = f"sum by ({by}) (count_over_time({sel}{flt} [{w}s]))"
    if rule.get("above"):
        e += f" > {rule['above']}"
    return e


def metrics_selector(hosts, rule):
    """A metrics rule's series: its module's guests (by their name, the
    identity the store stamps), or for a route signal its module's published
    services (tappaas_module, stamped from the mothership's map)."""
    cls = SIGNALS[rule["signal"]][0]
    if hosts == "*":
        return 'tappaas_ci_id!=""'
    for h in hosts:
        if not DNS.match(h):
            raise ValueError(f"bad name '{h}'")
    if not hosts:
        raise ValueError("no hosts in scope")
    key = "tappaas_module" if cls == "route" else "service_name"
    return f"{key}=~" + _q("^(" + "|".join(sorted(set(hosts))) + ")$")


def metrics_expression(hosts, rule):
    base = SIGNALS[rule["signal"]][1].replace("__SEL__", metrics_selector(hosts, rule))
    return f"min_over_time(({base})[{rule['window']}s:1m]) > {rule['above']}"


def explore_query(hosts, rule):
    if rule.get("source") == "metrics":
        return SIGNALS[rule["signal"]][1].replace("__SEL__", metrics_selector(hosts, rule))
    if "query" in rule:
        return rule["query"].replace("__SELECTOR__", selector(hosts, rule))
    sel = selector(hosts, rule)
    return sel + (f" |~ {_q(rule['match'])}" if "match" in rule else "")


def rule_uid(module, rule):
    uid = f"{module}-{rule['name']}"
    if len(uid) > 40:  # Grafana's limit for a rule uid
        raise ValueError(f"rule uid '{uid}' is longer than 40 characters: shorten the rule's name")
    return uid


def grafana_rule(module, rule, hosts):
    """One rule in Grafana's provisioning shape — the same shape logging.nix's
    alertRule builds for the core rules (A: Loki, B: last, C: > 0)."""
    metrics = rule.get("source") == "metrics"
    w = rule["window"] + (3600 if rule.get("absent") else 0)
    labels = {"kind": rule["kind"], "module": module}
    if metrics:
        labels["source"] = "metrics"
    if rule.get("security"):
        labels["type"] = "security"
        labels["level"] = rule["security"]
    for x in rule.get("include", []):
        labels[x] = "true"
    ann = {"summary": rule["summary"], "query": explore_query(hosts, rule)}
    if "headline" in rule:
        ann["headline"] = rule["headline"]
    if "lines" in rule.get("include", []):
        # The receiver fetches the alert's own host's lines: the same filter,
        # with __HOST__ replaced by the alert's host label.
        sel = "{host=\"__HOST__\"" + (", unit=~" + _q(rule["unit"]) if "unit" in rule else "") + "}"
        ann["linesQuery"] = sel + f" |~ {_q(rule['match'])}"
        ann["linesWindow"] = str(rule["window"])
    mail = rule.get("mail") or {}
    if "subject" in mail:
        ann["mailSubject"] = mail["subject"]
    if "body" in mail:
        ann["mailBody"] = mail["body"]
    out = {
        "uid": rule_uid(module, rule),
        "title": rule["title"],
        "condition": "C",
        "data": [
            {"refId": "A", "datasourceUid": "prometheus" if metrics else "loki",
             "relativeTimeRange": {"from": w, "to": 0},
             "model": {"refId": "A", "expr": metrics_expression(hosts, rule) if metrics else expression(hosts, rule), "instant": True, "queryType": "instant", "editorMode": "code"}},
            {"refId": "B", "datasourceUid": "__expr__",
             "model": {"refId": "B", "type": "reduce", "expression": "A", "reducer": "last",
                       "datasource": {"type": "__expr__", "uid": "__expr__"}}},
            {"refId": "C", "datasourceUid": "__expr__",
             "model": {"refId": "C", "type": "threshold", "expression": "B",
                       "conditions": [{"evaluator": {"type": "gt", "params": [0]}}],
                       "datasource": {"type": "__expr__", "uid": "__expr__"}}},
        ],
        "noDataState": "OK",
        # A query that cannot run keeps the rule's last state (#905): no mail
        # under its name; a Loki that stays down stops the Heartbeat instead.
        "execErrState": "KeepLast",
        "for": "0s",
        "labels": labels,
        "annotations": ann,
        "folderUID": FOLDER_UID,
        "ruleGroup": f"module-{module}",
        "orgID": 1,
    }
    if "repeat" in rule:
        # Grafana's per-rule routing: the repeat without touching the policy
        # tree logging.nix provisions.
        out["notification_settings"] = {
            "receiver": RECEIVER,
            "group_by": ["alertname", "host"] + sorted(rule.get("capture", {})),
            "repeat_interval": rule["repeat"],
        }
    return out


def rule_hosts(module, rule, scopes):
    """The hosts a rule reads: its module's instances, or (foundation) the scope."""
    sc = rule.get("scope")
    if sc == "all":
        return scopes("*all*")
    if isinstance(sc, list):
        hs = []
        for m in sc:
            hs += scopes(m)
        return hs
    return scopes(module)


def security_on(config_dir):
    """The site's security monitoring (ADR-050 D1): site.json security.monitoring,
    else off on a small site and on otherwise (lib/security-monitoring.sh)."""
    try:
        with open(os.path.join(config_dir, "site.json"), encoding="utf-8") as f:
            site = json.load(f)
    except (OSError, ValueError):
        site = {}
    m = (site.get("security") or {}).get("monitoring")
    if m in ("on", "off"):
        return m == "on"
    return site.get("size", "medium") != "small"


def render_group(module, doc, scopes, security=True):
    rules = []
    for r in doc["rules"]:
        if r.get("security") and not security:
            continue  # security monitoring is off on this site
        if r.get("source") == "metrics" and SIGNALS[r["signal"]][0] == "route":
            sc = r.get("scope")
            hs = "*" if sc == "all" else (sc if isinstance(sc, list) else [module])
            rules.append(grafana_rule(module, r, hs))
            continue
        hs = rule_hosts(module, r, scopes)
        if not hs and "expr" not in r:
            continue  # nothing in scope yet (no instance): no rule to evaluate
        rules.append(grafana_rule(module, r, hs or ["none"]))
    return {"title": f"module-{module}", "folderUid": FOLDER_UID, "interval": GROUP_INTERVAL, "rules": rules}


# ── config/: whose instances, which hosts ───────────────────────────────

def _configs(config_dir):
    for f in sorted(os.listdir(config_dir)):
        if not f.endswith(".json"):
            continue
        try:
            with open(os.path.join(config_dir, f)) as fh:
                c = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(c, dict) and (c.get("status") or "").lower() != "archived":
            yield f[:-5], c


def source_of(cfg):
    """Where the module lives. Only a string is a path: a site.json that has not
    been through migration 0019 has `location` as an object (#912)."""
    src = cfg.get("moduleSource") or cfg.get("location")
    return src if isinstance(src, str) and src else None


def module_of(cfg):
    src = source_of(cfg)
    return os.path.basename(src.rstrip("/")) if src else ""


def _vmname(inst, cfg):
    v = cfg.get("vmname")
    return v if isinstance(v, str) and DNS.match(v) else (inst if DNS.match(inst) else None)


def declares_logs(cfg):
    deps = list(cfg.get("dependsOn") or []) + list(cfg.get("integratesWith") or [])
    return "logging:logs" in deps


def scope_hosts(config_dir, what, without=()):
    hs = []
    for inst, cfg in _configs(config_dir):
        if inst in without:
            continue  # an instance being deleted: out of every selector at once (D4)
        if what == "*all*":
            # Every instance that declares logging:logs, and the logging VM
            # itself, which ships to itself and declares nothing.
            ok = declares_logs(cfg) or module_of(cfg) == "logging"
        else:
            ok = module_of(cfg) == what
        if ok:
            v = _vmname(inst, cfg)
            if v:
                hs.append(v)
    return sorted(set(hs))


def module_source(config_dir, module):
    for _inst, cfg in _configs(config_dir):
        if module_of(cfg) == module:
            return source_of(cfg)
    return None


def is_foundation(src):
    """A module whose source is inside the TAPPaaS repository's foundation tree.
    Not its `stack`: a Community module could write that itself."""
    if not src:
        return False
    real = os.path.realpath(src)
    return real.startswith(os.path.realpath(os.path.join(REPO_SRC, "foundation")) + os.sep)


def alerts_file(src, module):
    return os.path.join(src, f"{module}-alerts.json") if src else None


# ── Grafana on the logging VM ───────────────────────────────────────────

def logging_vm(config_dir):
    try:
        with open(os.path.join(config_dir, "logging.json")) as fh:
            c = json.load(fh)
    except (OSError, ValueError):
        return None
    return f"tappaas@{c.get('vmname') or 'logging'}.{c.get('zone0') or 'mgmt'}.internal"


GRAFANA_WAIT = 90  # seconds a restarting Grafana gets to answer again


def grafana(vm, method, path, body=None):
    """One call to Grafana's API on the logging VM, retried while Grafana does
    not answer yet (no connection, or 502/503 during its start)."""
    deadline = time.monotonic() + GRAFANA_WAIT
    while True:
        code, text = grafana_once(vm, method, path, body)
        if code not in (0, 502, 503) or time.monotonic() >= deadline:
            return code, text
        time.sleep(3)


def grafana_once(vm, method, path, body=None):
    """One call to Grafana's API on the logging VM, as admin, from that VM's
    localhost: the admin password never leaves it."""
    remote = ("P=$(sudo cat /etc/secrets/grafana-admin-password) && "
              f"curl -sS -o /dev/stdout -w '\\n%{{http_code}}' -u \"admin:$P\" -X {method} "
              "-H 'Content-Type: application/json' "
              + ("--data-binary @- " if body is not None else "")
              + f"'http://127.0.0.1:3000{path}'")
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", vm, remote],
                       input=json.dumps(body) if body is not None else None,
                       capture_output=True, text=True, timeout=120)
    out = r.stdout.rstrip("\n")
    text, _, code = out.rpartition("\n")
    try:
        return int(code), text
    except ValueError:
        return 0, (r.stderr or out).strip()


def ensure_folder(vm):
    code, _ = grafana(vm, "GET", f"/api/folders/{FOLDER_UID}")
    if code == 200:
        return True
    code, text = grafana(vm, "POST", "/api/folders", {"uid": FOLDER_UID, "title": FOLDER_TITLE})
    if code in (200, 409, 412):  # created, or another run made it first
        return True
    print(f"cannot create the folder '{FOLDER_TITLE}': {code} {text[:300]}", file=sys.stderr)
    return False


def put_group(vm, module, group):
    code, text = grafana(vm, "PUT", f"/api/v1/provisioning/folder/{FOLDER_UID}/rule-groups/module-{module}", group)
    return code, text


def delete_group(vm, module):
    code, text = grafana(vm, "DELETE", f"/api/v1/provisioning/folder/{FOLDER_UID}/rule-groups/module-{module}")
    return code in (200, 204, 404), f"{code} {text}"


# ── commands ────────────────────────────────────────────────────────────

def load(path):
    with open(path) as fh:
        return json.load(fh)


def cmd_validate(a):
    try:
        doc = load(a.file)
    except (OSError, ValueError) as e:
        print(f"{a.file}: {e}", file=sys.stderr)
        return 1
    errs = validate(doc, a.foundation)
    for e in errs:
        print(f"{a.file}: {e}", file=sys.stderr)
    return 1 if errs else 0


def _resolve(a):
    src = module_source(a.config_dir, a.module)
    path = a.file if getattr(a, "file", None) else alerts_file(src, a.module)
    foundation = getattr(a, "foundation", False) or is_foundation(src)
    return path, foundation


def cmd_render(a):
    path, foundation = _resolve(a)
    if not path or not os.path.exists(path):
        print(f"no {a.module}-alerts.json", file=sys.stderr)
        return 1
    doc = load(path)
    errs = validate(doc, foundation)
    if errs:
        for e in errs:
            print(f"{path}: {e}", file=sys.stderr)
        return 1
    if a.hosts is not None:
        fixed = [h for h in a.hosts.split(",") if h]
        scopes = lambda _m: fixed  # noqa: E731
    else:
        scopes = lambda m: scope_hosts(a.config_dir, m)  # noqa: E731
    try:
        group = render_group(a.module, doc, scopes, security_on(a.config_dir))
    except ValueError as e:
        print(f"{path}: {e}", file=sys.stderr)
        return 1
    json.dump(group, sys.stdout, indent=2)
    print()
    return 0


def cmd_hosts(a):
    print("\n".join(scope_hosts(a.config_dir, a.module)))
    return 0


def apply_module(module, config_dir, dry_run=False, vm=None, without=()):
    """Apply (or remove) one module's group. Returns (ok, message)."""
    src = module_source(config_dir, module)
    path = alerts_file(src, module)
    vm = vm or logging_vm(config_dir)
    if not path or not os.path.exists(path):
        if dry_run or not vm:
            return True, "no rules file"
        ok, msg = delete_group(vm, module)
        return ok, "no rules file" + ("" if ok else f" (could not remove its group: {msg})")
    foundation = is_foundation(src)
    try:
        doc = load(path)
    except (OSError, ValueError) as e:
        return False, f"{path}: {e}"
    errs = validate(doc, foundation)
    if errs:
        return False, "; ".join(errs)
    try:
        group = render_group(module, doc, lambda m: scope_hosts(config_dir, m, without), security_on(config_dir))
    except ValueError as e:
        return False, str(e)
    if dry_run:
        return True, f"{len(group['rules'])} rule(s) (dry run)"
    if not vm:
        return False, "logging is not deployed (no config/logging.json)"
    if not group["rules"]:
        ok, msg = delete_group(vm, module)
        return ok, "no instance in scope: group removed" if ok else msg
    if not ensure_folder(vm):
        return False, "cannot create the Grafana folder"
    code, text = put_group(vm, module, group)
    if code not in (200, 201, 202):
        return False, f"Grafana refused module-{module}: {code} {text[:400]}"
    return True, f"{len(group['rules'])} rule(s) in module-{module}"


def readers_of(config_dir, module):
    """The other modules whose rules read this module's hosts: a scope that
    names it, or "all". Their host lists change with this module's instances."""
    out = []
    for m in sorted({module_of(c) for _i, c in _configs(config_dir)} - {"", module}):
        src = module_source(config_dir, m)
        f = alerts_file(src, m)
        if not (f and os.path.exists(f) and is_foundation(src)):
            continue
        try:
            doc = load(f)
        except (OSError, ValueError):
            continue
        for r in doc.get("rules", []) if isinstance(doc, dict) else []:
            sc = r.get("scope") if isinstance(r, dict) else None
            if sc == "all" or (isinstance(sc, list) and module in sc):
                out.append(m)
                break
    return out


def cmd_apply(a):
    without = tuple(a.without or ())
    ok, msg = apply_module(a.module, a.config_dir, a.dry_run, without=without)
    print(f"{a.module}: {msg}", file=sys.stdout if ok else sys.stderr)
    rc = 0 if ok else 1
    for m in readers_of(a.config_dir, a.module):
        ok, msg = apply_module(m, a.config_dir, a.dry_run, without=without)
        print(f"{m}: {msg}", file=sys.stdout if ok else sys.stderr)
        rc = rc if ok else 1
    return rc


def cmd_remove(a):
    if a.dry_run:
        print(f"{a.module}: would remove module-{a.module}")
        return 0
    vm = logging_vm(a.config_dir)
    if not vm:
        return 0
    ok, msg = delete_group(vm, a.module)
    print(f"{a.module}: {'removed' if ok else msg}", file=sys.stdout if ok else sys.stderr)
    return 0 if ok else 1


def cmd_apply_all(a):
    mods = sorted({module_of(c) for _i, c in _configs(a.config_dir)} - {""})
    rc = 0
    vm = logging_vm(a.config_dir)
    for m in mods:
        src = module_source(a.config_dir, m)
        if not (src and os.path.exists(alerts_file(src, m))):
            continue
        ok, msg = apply_module(m, a.config_dir, a.dry_run, vm)
        print(f"{m}: {msg}", file=sys.stdout if ok else sys.stderr)
        rc = rc if ok else 1
    return rc


def main(argv=None):
    p = argparse.ArgumentParser(prog="tappaas-alert-rules.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("validate"); s.add_argument("file"); s.add_argument("--foundation", action="store_true")
    s = sub.add_parser("render"); s.add_argument("module"); s.add_argument("--file"); s.add_argument("--hosts")
    s.add_argument("--foundation", action="store_true"); s.add_argument("--config-dir", default=CONFIG_DIR)
    s = sub.add_parser("hosts"); s.add_argument("module"); s.add_argument("--config-dir", default=CONFIG_DIR)
    for n in ("apply", "remove"):
        s = sub.add_parser(n); s.add_argument("module"); s.add_argument("--config-dir", default=CONFIG_DIR)
        s.add_argument("--dry-run", action="store_true")
        if n == "apply":
            s.add_argument("--without", action="append", help="leave this instance out (it is being deleted)")
    s = sub.add_parser("apply-all"); s.add_argument("--config-dir", default=CONFIG_DIR); s.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)
    if getattr(a, "module", None) is not None and not DNS.match(a.module):
        print(f"bad module name '{a.module}'", file=sys.stderr)
        return 2
    return {"validate": cmd_validate, "render": cmd_render, "hosts": cmd_hosts, "apply": cmd_apply,
            "remove": cmd_remove, "apply-all": cmd_apply_all}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
