#!/usr/bin/env python3
"""tappaas-alert-receiver — Grafana alert webhooks to the site's mail (#126).

The logging module's Grafana evaluates LogQL alert rules over every host's logs
and posts what fires here. This hands each notification to site-notify.sh, the
mail path every site notice shares (#651: a Proxmox node's own mail system,
node fallback, the site.json address), so an operator hears about a log
condition the same way they hear about a failed sweep.

Stateless on purpose: Grafana groups alerts, waits, and repeats (every 4 h at
most); this only turns one webhook into one mail. Two kinds of rule, from the
`kind` label the rules carry:

  event   something happened (quorum lost, an OOM kill). It "resolves" only
          because its time window moved on, so a resolve is not mailed.
  state   something is so (a host has gone silent). Resolving is news: mailed.
  heartbeat  Grafana's proof that the whole path works (logs arrive, rules run,
          this webhook is reached with the token). Never mailed: its time is
          written to the heartbeat file, and tappaas-alert-watchdog.sh — a timer
          on this host, independent of the logging VM — mails when it stops.

A state alert is one condition from its ALERT to its RESOLVED (#883): its key,
grafana:<alertname>:<host> (Grafana groups by those two), tells site-notify.sh
to send the RESOLVED as a reply to the ALERT, and only while one is open.

A rule labelled bundle="true" gets a support bundle attached
(tappaas-support-bundle.sh: the cluster's state and the anonymized config since
half an hour before it fired). Building one takes a while, longer than Grafana
waits for a webhook, so that alert is acknowledged at once and mailed from a
worker thread, which retries the mail itself; without a bundle the reply waits
for the mail, and a 502 makes Grafana retry.

A node down is one notice, not one per host (the one stateful part). A node
that dies takes its guests with it, and each guest that ships logs goes silent:
tappaas2 on hrossen made nine HostSilent ALERTs and nine RESOLVEDs. So before a
HostSilent is mailed, the cluster (tappaas-cluster-state.sh) is asked whether
its host is an offline node or a guest on one. If so it belongs to that node's
incident (a file in the node-down directory): the first one mails "node X is
down" with the guests down with it, the HA guests the CRM moved and where to,
and the ones it is still moving or could not; the rest are only recorded. The
mail repeats every 4 h while the node is down, as Grafana's would. When the
node is online again, one RESOLVED goes out as a reply, saying which guests
run again. The folded hosts' own RESOLVEDs find no open condition in
site-notify.sh and send nothing. When the cluster cannot be asked, every
HostSilent is mailed on its own, as before.

Many hosts silent at once is one notice too, when their nodes are up. A shared
cause — the firewall restarting, its rules, the logging VM — silences every
guest that ships logs through it: the firewall's restart on hrossen made 13
HostSilent ALERTs and 13 RESOLVEDs. So a HostSilent waits --silent-hold seconds
before it is mailed. When --burst-min hosts have gone silent within
--burst-window seconds, one "N hosts stopped logging at once" ALERT goes out
naming them, and the held ones fold into it, as do the ones that follow; when
they all log again, one RESOLVED answers it. A host mailed on its own before the
burst opened keeps its own ALERT and RESOLVED.

A planned disruption is quiet. Before an update restarts a guest it is allowed
to restart, it opens a maintenance window (tappaas-maintenance.sh: a file in
--maintenance-dir naming the hosts, or the whole site for the firewall, and an
end time). A HostSilent from inside one is recorded, not mailed, and so is its
RESOLVED, which finds no ALERT to answer.

A module's rule (ADR-039, tappaas-alert-rules.py) may carry its mail as
templates (the mailSubject and mailBody annotations): `{placeholder}`
substitution and nothing else, so a module's text is never run. Without them the
mail is the one below, unchanged. A rule labelled lines="true" gets up to 20 of
its matching log lines, fetched from Loki for the alert's host and put through
support-anonymize.py's scrubbing, as a bundle's journals are, but only on a
site that opted in: site.json `alerts.includeLines` (default false).

Every alert that arrives, ALERT or RESOLVED, also moves the site's health
(ADR-041 D2): the host or module it is about is resolved as health-manager's
alerts.ts places it, and a worker thread runs `health-manager assess --only
<ci>` and then `health-manager emit`, so a webhook never waits for them. A burst
is one worker: what arrives while it runs joins its next round. An alert about
no object assesses the site. health-manager's own rules are not assessed again:
they read what emit wrote.

The daily digest (HealthDailyDigest) is a mail health-manager writes: `digest
--json` says what is new since the last one, and whether that makes it an ALERT
or a STATUS. Sent from a worker thread as a bundle's alert is; once it went,
`digest --mark` records what it told. When health-manager cannot say, the rule's
own template goes out, as an ALERT.

Every request is authenticated with a bearer token both sides read from a file
(the receiver's, and Grafana's copy that logging/update.sh delivers). Every
notice, sent or not, is a line in the breadcrumb file.

Usage: tappaas-alert-receiver.py [--listen ADDR:PORT] [--token-file F]
                                 [--notify CMD] [--bundle CMD] [--breadcrumb F]
                                 [--cluster CMD] [--node-down-dir D]
                                 [--health CMD] [--maintenance-dir D]
                                 [--silent-hold S] [--burst-min N] [--burst-window S]
       tappaas-alert-receiver.py --render < webhook.json   (print the mail; tests)
"""

import argparse
import glob
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULTS = {
    "listen": "0.0.0.0:9095",
    "token_file": "/etc/secrets/tappaas-alert-token",
    "notify": "/home/tappaas/bin/site-notify.sh",
    "bundle": "/home/tappaas/bin/tappaas-support-bundle.sh",
    "breadcrumb": "/home/tappaas/config/alerts.log",
    "heartbeat_file": "/var/lib/tappaas/alert-heartbeat",
    "cluster": "/home/tappaas/bin/tappaas-cluster-state.sh",
    "node_down_dir": "/var/lib/tappaas/node-down",
    "cluster_cache": 60,  # seconds: a burst of webhooks asks the cluster once
    "config_dir": "/home/tappaas/config",
    "loki": "http://logging.mgmt.internal:3100",
    "loki_admin_file": "/home/tappaas/.loki-admin-password",
    "alerts_log": "/var/lib/tappaas/alerts.jsonl",
    "health": "/home/tappaas/bin/health-manager",
    "maintenance_dir": "/var/lib/tappaas/maintenance",
    "silent_burst_file": "/var/lib/tappaas/silent-burst.json",
    "silent_hold": 150,  # seconds a HostSilent waits for others before it is mailed
    "burst_min": 3,  # hosts silent within the window that make one notice
    "burst_window": 600,
}
ALERTS_LOG_MAX = 2 << 20  # past 2 MB the record keeps its newer half
MAX_LINES = 20
NO_LINES = "(log lines not mailed on this site — see the Explore link)"
MAX_BODY = 1 << 20  # a Grafana notification is a few KB; refuse anything absurd


# Labels every alert carries; the rest are the series' own (a replication job,
# a unit…) and are what tells one alert from the next, so the mail names them.
_PLAIN_LABELS = {"alertname", "host", "kind", "grafana_folder", "bundle", "module", "lines"}


def extra_labels(labels):
    return {k: v for k, v in sorted(labels.items())
            if k not in _PLAIN_LABELS and not k.startswith("__") and v}


def is_heartbeat(alert):
    return (alert.get("labels") or {}).get("kind") == "heartbeat"


def is_beat(alert):
    """A heartbeat that proves the path: the Heartbeat rule itself, firing. A
    Grafana error alert (DatasourceError) carries the rule's labels too, but it
    says the rules cannot run, so it must not refresh the heartbeat (#905)."""
    labels = alert.get("labels") or {}
    return (is_heartbeat(alert) and labels.get("alertname") == "Heartbeat"
            and alert.get("status", "firing") == "firing")


_PH = re.compile(r"\{([a-z]+(?:\.[a-z_][a-z0-9_]*)?)\}")


def fill(template, values):
    """{placeholder} substitution, nothing more: an unknown one stays as written."""
    return _PH.sub(lambda m: values.get(m.group(1), m.group(0)), template)


def render(payload, lines_for=None):
    """One webhook -> (subject, body), or None when there is nothing to mail.
    lines_for(alert) gives an alert's log lines (text) for a rule labelled
    lines="true", or None when it has none to give."""
    status = payload.get("status", "firing")
    alerts = [a for a in (payload.get("alerts") or []) if not is_heartbeat(a)]
    if status == "resolved":
        # Only state rules are news when they clear (see the module doc).
        alerts = [a for a in alerts if (a.get("labels") or {}).get("kind") == "state"]
    else:
        alerts = [a for a in alerts if a.get("status", "firing") == "firing"]
    if not alerts:
        return None

    common = payload.get("commonLabels") or {}
    name = common.get("alertname") or (alerts[0].get("labels") or {}).get("alertname", "alert")
    hosts = sorted({(a.get("labels") or {}).get("host", "") for a in alerts} - {""})
    where = f" on {', '.join(hosts)}" if hosts else ""
    # A rule may name itself for the inbox (its `headline` annotation, e.g.
    # "Out of Memory Kill"); otherwise its rule name stands. site-notify.sh
    # puts "[TAPPaaS <site>] " in front: "[TAPPaaS hrossen.dk] ALERT: Out of
    # Memory Kill on tappaas3".
    headline = ((payload.get("commonAnnotations") or {}).get("headline")
                or (alerts[0].get("annotations") or {}).get("headline"))
    word = "RESOLVED" if status == "resolved" else "ALERT"
    # One alert: its own labels in the subject too ("… on tappaas1 (job 110-0)").
    extra = extra_labels(alerts[0].get("labels") or {}) if len(alerts) == 1 else {}
    what = f" ({', '.join(f'{k} {v}' for k, v in extra.items())})" if extra else ""
    subject = f"{word}: {headline or name}{where}{what}"

    ann0 = alerts[0].get("annotations") or {}
    if ann0.get("mailSubject") or ann0.get("mailBody"):
        return render_templated(payload, alerts, status, word, headline or name, hosts, lines_for)

    lines = []
    for a in alerts:
        labels = a.get("labels") or {}
        ann = a.get("annotations") or {}
        lines.append(f"== {labels.get('alertname', name)}"
                     + (f" — {labels['host']}" if labels.get("host") else ""))
        for k, v in extra_labels(labels).items():
            lines.append(f"{k}: {v}")
        if ann.get("summary"):
            lines.append(ann["summary"])
        if ann.get("description"):
            lines.append(ann["description"])
        lines.append(f"since: {a.get('startsAt', '?')}"
                     + (f"   resolved: {a.get('endsAt')}" if status == "resolved" else ""))
        if ann.get("query"):
            lines.append(f"In Grafana (Explore, Loki): {ann['query']}")
        if labels.get("lines") == "true" and status != "resolved":
            lines.append("Log lines (anonymized):")
            lines.append(_lines_text(a, lines_for))
        lines.append("")
    lines.append("Sent by the logging module's alert rules through tappaas-alert-receiver.")
    return subject, "\n".join(lines) + "\n"


def _lines_text(alert, lines_for):
    got = lines_for(alert) if lines_for else None
    return got if got else NO_LINES


def _values(alert, status, word, title, hosts, lines_for):
    labels = alert.get("labels") or {}
    ann = alert.get("annotations") or {}
    extra = extra_labels(labels)
    v = {
        "state": word,
        "title": title,
        "host": labels.get("host", ""),
        "hosts": ", ".join(hosts),
        "module": labels.get("module", ""),
        "labels": ", ".join(f"{k} {x}" for k, x in extra.items()),
        "summary": ann.get("summary", ""),
        "since": alert.get("startsAt", "?"),
        "resolved": alert.get("endsAt", "") if status == "resolved" else "",
        "query": ann.get("query", ""),
    }
    v["lines"] = _lines_text(alert, lines_for) if labels.get("lines") == "true" and status != "resolved" else ""
    for k, x in extra.items():
        v[f"label.{k}"] = x
    return v


def render_templated(payload, alerts, status, word, title, hosts, lines_for):
    """A rule's own mail (ADR-039 D7): its subject once, its body per alert."""
    ann0 = alerts[0].get("annotations") or {}
    first = _values(alerts[0], status, word, title, hosts, lines_for)
    subject = fill(ann0.get("mailSubject") or "{state}: {title} on {hosts}", first)
    # One line, as a subject must be; site-notify.sh blanks what is not ASCII.
    subject = " ".join(subject.split())
    parts = []
    for a in alerts:
        ann = a.get("annotations") or {}
        v = _values(a, status, word, title, hosts, lines_for)
        if ann.get("mailBody"):
            parts.append(fill(ann["mailBody"], v).rstrip("\n"))
        else:
            parts.append(f"== {title}" + (f" — {v['host']}" if v["host"] else "") + f"\n{v['summary']}\nsince: {v['since']}")
        if ann.get("query") and "{query}" not in (ann.get("mailBody") or ""):
            parts.append(f"In Grafana (Explore, Loki): {ann['query']}")
        parts.append("")
    parts.append("Sent by the logging module's alert rules through tappaas-alert-receiver.")
    return subject, "\n".join(parts) + "\n"


# ── log lines for a rule labelled lines="true" (ADR-039 D7) ───────────────

def lines_allowed(config_dir):
    try:
        with open(os.path.join(config_dir, "site.json"), encoding="utf-8") as f:
            return ((json.load(f).get("alerts") or {}).get("includeLines")) is True
    except (OSError, ValueError, AttributeError):
        return False


def _anonymizer(config_dir, bundle_cmd):
    """support-anonymize.py's Anonymizer, taught the site's people and places.
    It sits beside this script in the checkout, and beside the bundle script the
    receiver already calls (this file itself may run from the Nix store)."""
    import importlib.util
    path = ""
    for d in (os.path.dirname(os.path.abspath(__file__)), os.path.dirname(os.path.realpath(bundle_cmd))):
        if os.path.exists(os.path.join(d, "support-anonymize.py")):
            path = os.path.join(d, "support-anonymize.py")
            break
    if not path:
        raise OSError("support-anonymize.py not found: no lines without it")
    spec = importlib.util.spec_from_file_location("support_anonymize", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    an = mod.Anonymizer()
    mod.collect(an, config_dir)
    return an


def make_lines_for(args):
    """lines_for(alert): the alert's host's matching lines from Loki, newest
    first, anonymized — or None when the site has not opted in or Loki cannot
    say. The selector is the rule's linesQuery with the alert's own host."""
    def lines_for(alert):
        if not lines_allowed(args.config_dir):
            return None
        ann = alert.get("annotations") or {}
        host = (alert.get("labels") or {}).get("host", "")
        q = ann.get("linesQuery", "")
        if "__HOST__" not in q or not re.match(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$", host):
            return None
        q = q.replace("__HOST__", host)
        try:
            window = max(60, min(86400, int(ann.get("linesWindow", "300"))))
            with open(args.loki_admin_file, encoding="utf-8") as f:
                pw = f.read().strip()
            end = time.time()
            r = subprocess.run(
                ["curl", "-sfG", "--max-time", "20", "-u", f"tappaas:{pw}",
                 f"{args.loki}/loki/api/v1/query_range",
                 "--data-urlencode", f"query={q}", "--data-urlencode", f"limit={MAX_LINES}",
                 "--data-urlencode", "direction=backward",
                 "--data-urlencode", f"start={int((end - window - 60) * 1e9)}",
                 "--data-urlencode", f"end={int(end * 1e9)}"],
                capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                return None
            vals = []
            for st in json.loads(r.stdout).get("data", {}).get("result", []):
                vals += st.get("values", [])
            vals.sort(key=lambda x: x[0], reverse=True)
            text = "\n".join(v[1] for v in vals[:MAX_LINES])
            if not text:
                return None
            return _anonymizer(args.config_dir, args.bundle).text(text)
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            print(f"log lines NOT fetched: {e}", flush=True)
            return None
    return lines_for


def digest_doc(args):
    """health-manager's digest {subject, body, keys, …}, or None when it cannot say."""
    try:
        r = subprocess.run([args.health, "digest", "--json"], text=True, capture_output=True, timeout=HEALTH_TIMEOUT)
        doc = json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError) as e:
        print(f"digest NOT built: {e}", flush=True)
        return None
    if not isinstance(doc, dict) or not doc.get("subject") or not doc.get("body"):
        print(f"digest NOT built: {r.stderr.strip()[-300:]}", flush=True)
        return None
    return doc


def is_digest(payload):
    return any((a.get("labels") or {}).get("alertname") == DIGEST_RULE for a in payload.get("alerts") or [])


def send_digest(args, template, tries=3, pause=60):
    doc = digest_doc(args)
    subject, body = (doc["subject"], doc["body"]) if doc else template
    for i in range(tries):
        ok, out = notify(args, subject, body)
        print(f"{'sent' if ok else 'NOT sent'}: {subject}" + (f" — {out}" if out and not ok else ""), flush=True)
        if ok:
            if doc:
                _health_run([args.health, "digest", "--mark"], json.dumps({"keys": doc.get("keys", [])}))
            return True
        if i + 1 < tries:
            time.sleep(pause)
    return False


def meta(payload):
    """What goes with the mail: its key (state rules), whether it resolves, and
    whether it carries a bundle — with the time to start the bundle from."""
    alerts = [a for a in (payload.get("alerts") or []) if not is_heartbeat(a)]
    first = (alerts[0].get("labels") or {}) if alerts else {}
    common = payload.get("commonLabels") or {}
    labels = {**first, **common}
    resolved = payload.get("status") == "resolved"
    key = None
    if labels.get("kind") == "state":
        hosts = sorted({(a.get("labels") or {}).get("host", "") for a in alerts} - {""})
        key = re.sub(r"[^A-Za-z0-9_.:@-]", "-", f"grafana:{labels.get('alertname', 'alert')}:{','.join(hosts) or 'site'}")[:128]
    since = None
    if labels.get("bundle") == "true" and not resolved:
        starts = [a.get("startsAt", "") for a in alerts if a.get("startsAt")]
        try:
            t = datetime.fromisoformat(min(starts).replace("Z", "+00:00"))
        except ValueError:
            t = datetime.now(timezone.utc)
        since = (t.astimezone(timezone.utc) - timedelta(minutes=30)).strftime("%Y-%m-%d %H:%M:%S UTC")
    return {"key": key, "resolve": resolved and key is not None, "bundle_since": since}


def make_bundle(args, subject, since):
    """A support bundle's path, or None (the mail then goes without one)."""
    try:
        r = subprocess.run([args.bundle, "--reason", subject, "--since", since],
                           text=True, capture_output=True, timeout=600)
        path = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
        if not path:
            print(f"bundle NOT made: {r.stderr.strip()[-300:]}", flush=True)
        return path or None
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"bundle NOT made: {e}", flush=True)
        return None


def notify(args, subject, body, key=None, resolve=False, attach=None):
    cmd = [args.notify, "--subject", subject, "--what", "alert", "--breadcrumb", args.breadcrumb]
    if key:
        cmd += ["--key", key] + (["--resolve"] if resolve else [])
    if attach:
        cmd += ["--attach", attach]
    try:
        r = subprocess.run(cmd, input=body, text=True, capture_output=True, timeout=120)
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)


def send_with_bundle(args, mail, m, tries=3, pause=60):
    subject, body = mail
    path = make_bundle(args, subject, m["bundle_since"]) if m["bundle_since"] else None
    for i in range(tries):
        ok, out = notify(args, subject, body, key=m["key"], attach=path)
        print(f"{'sent' if ok else 'NOT sent'}: {subject}" + (" (with bundle)" if path else "")
              + (f" — {out}" if out and not ok else ""), flush=True)
        if ok:
            return True
        if i + 1 < tries:
            time.sleep(pause)
    return False


# ── a node down: one notice for the node and its guests ──────────────────
NODE_DOWN_REPEAT = 4 * 3600  # as Grafana repeats a firing alert
_node_lock = threading.Lock()  # webhooks arrive together; one decides at a time
_cluster_cache = {"at": 0.0, "state": None}

_RE_NODE = re.compile(r"node '([^']+)': state changed from '(\w+)' => '(\w+)'")
_RE_MOVED = re.compile(r"recover service '(?:vm|ct):(\d+)' from fenced node '([^']+)' to node '([^']+)'")
_RE_STUCK = re.compile(r"recovering service '(?:vm|ct):(\d+)' from fenced node '([^']+)' failed")


def breadcrumb(args, text):
    try:
        with open(args.breadcrumb, "a", encoding="utf-8") as f:
            f.write(f"{datetime.now().astimezone().isoformat(timespec='seconds')} {text}\n")
    except OSError:
        pass


def cluster_state(args):
    """tappaas-cluster-state.sh's document, at most --cluster-cache old, or None."""
    if _cluster_cache["state"] is not None and time.time() - _cluster_cache["at"] < args.cluster_cache:
        return _cluster_cache["state"]
    try:
        r = subprocess.run([args.cluster], text=True, capture_output=True, timeout=90)
        state = json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError) as e:
        print(f"cluster state NOT read: {e}", flush=True)
        return None
    if not isinstance(state, dict) or not state.get("nodes"):
        print(f"cluster state NOT read: {r.stderr.strip()[-300:]}", flush=True)
        return None
    _cluster_cache.update(at=time.time(), state=state)
    return state


def offline_nodes(state):
    return {n["name"] for n in state.get("nodes", []) if not n.get("online")}


def down_node_of(host, state):
    """The offline node that explains a silent host: the host itself, or its guest's node."""
    offline = offline_nodes(state)
    if host in offline:
        return host
    for g in state.get("guests", []):
        if g.get("name") == host and g.get("node") in offline:
            return g["node"]
    return None


def node_events(node, state):
    """When the node went down (the CRM's last online => unknown/fence), its
    HA moves since then {vmid: target}, and the HA guests it could not move."""
    down_at, moved, stuck = "", {}, set()
    for line in state.get("ha_log", []):
        m = _RE_NODE.search(line)
        if m and m.group(1) == node and m.group(2) == "online":
            down_at, moved, stuck = line.split(" ", 1)[0], {}, set()
        m = _RE_MOVED.search(line)
        if m and m.group(2) == node:
            moved[int(m.group(1))] = m.group(3)
            stuck.discard(int(m.group(1)))
        m = _RE_STUCK.search(line)
        if m and m.group(2) == node and int(m.group(1)) not in moved:
            stuck.add(int(m.group(1)))
    return down_at, moved, stuck


def _guest(g):
    return f"{g.get('name') or '?'} ({g.get('vmid')})"


def node_down_mail(node, state, members):
    """The ALERT for a node down: (subject, body)."""
    down_at, moved, stuck = node_events(node, state)
    by_id = {g.get("vmid"): g for g in state.get("guests", [])}
    on_node = sorted((g for g in state.get("guests", []) if g.get("node") == node), key=_guest)
    down = [g for g in on_node if not g.get("ha")]
    ha_left = [g for g in on_node if g.get("ha") and g.get("vmid") not in stuck]
    others = sorted(n["name"] for n in state.get("nodes", []) if n.get("online"))

    parts = [f"{len(down)} guest{'s' * (len(down) != 1)} down"]
    if moved:
        parts.append(f"{len(moved)} moved by HA")
    if ha_left or stuck:
        parts.append(f"{len(ha_left) + len(stuck)} HA not moved yet")
    subject = f"ALERT: node {node} is down ({', '.join(parts)})"

    lines = [f"Node {node} has left the cluster"
             + (f" (the HA manager saw it go at {down_at})." if down_at else "."),
             f"Still in the cluster: {', '.join(others) or 'none'}"
             + ("" if state.get("quorate") else " — WITHOUT QUORUM: nothing is moved or started") + ".",
             ""]
    lines.append(f"Down with it, not HA-protected ({len(down)}) — they come back with {node}:")
    lines += [f"  {_guest(g)}" for g in down] or ["  none"]
    lines.append("")
    lines.append(f"HA-protected, moved to another node ({len(moved)}):")
    lines += [f"  {_guest(by_id.get(v, {'vmid': v}))}  {node} -> {to}"
              + ("" if by_id.get(v, {}).get("status") in ("running", None) else f"  (now {by_id[v]['status']})")
              for v, to in sorted(moved.items())] or ["  none"]
    if ha_left or stuck:
        lines.append("")
        lines.append(f"HA-protected, not moved (yet) ({len(ha_left) + len(stuck)}) — the HA manager fences {node} first:")
        lines += [f"  {_guest(g)}  HA state: {g['ha']}" for g in ha_left]
        lines += [f"  {_guest(by_id.get(v, {'vmid': v}))}  no node could take it" for v in sorted(stuck)]
    lines += ["",
              f"Silent hosts folded into this notice so far: {', '.join(sorted(members))}.",
              f"Their own HostSilent alerts are not mailed; one RESOLVED follows when {node} is back.",
              "",
              f"Look at {node}: power, network, console. The Proxmox UI on {others[0] if others else 'another node'}"
              " shows the cluster and HA state (Datacenter > HA).",
              "",
              "Sent by the logging module's alert rules through tappaas-alert-receiver."]
    return subject, "\n".join(lines) + "\n"


def node_back_mail(node, state, incident):
    """The RESOLVED for a node down: (subject, body)."""
    by_name = {g.get("name"): g for g in state.get("guests", [])}
    lines = [f"Node {node} is back in the cluster (down since {incident.get('since', '?')}).", ""]
    back, still = [], []
    for name in incident.get("guests", []):
        g = by_name.get(name)
        (back if g and g.get("status") == "running" else still).append(
            f"  {name}" + (f" on {g['node']}" if g and g.get("node") else "")
            + ("" if g and g.get("status") == "running" else f"  ({g.get('status') if g else 'gone'})"))
    lines.append(f"Running again ({len(back)}):")
    lines += back or ["  none"]
    if still:
        lines += ["", f"NOT running ({len(still)}) — start them, or they alert on their own:"] + still
    if incident.get("moved"):
        lines += ["", "Moved by HA while it was down (they stay where they are until HA moves them back):"]
        lines += [f"  {name} -> {to}" for name, to in sorted(incident["moved"].items())]
    lines += ["", "Sent by the logging module's alert rules through tappaas-alert-receiver."]
    return f"RESOLVED: node {node} is back", "\n".join(lines) + "\n"


def _incident_path(args, node):
    return f"{args.node_down_dir}/{re.sub(r'[^A-Za-z0-9_.-]', '-', node)}.json"


def load_incidents(args):
    out = {}
    for p in glob.glob(f"{args.node_down_dir}/*.json"):
        try:
            with open(p, encoding="utf-8") as f:
                inc = json.load(f)
            out[inc["node"]] = inc
        except (OSError, ValueError, KeyError):
            continue
    return out


def save_incident(args, inc):
    os.makedirs(args.node_down_dir, exist_ok=True)
    with open(_incident_path(args, inc["node"]), "w", encoding="utf-8") as f:
        json.dump(inc, f)


def mail_node_down(args, node, state, inc, bundle_since):
    subject, body = node_down_mail(node, state, inc["members"])
    m = {"key": f"grafana:NodeDown:{node}", "resolve": False, "bundle_since": bundle_since}
    inc["mailed"] = time.time()
    save_incident(args, inc)
    threading.Thread(target=send_with_bundle, args=(args, (subject, body), m), daemon=True).start()


def fold_node_down(args, payload):
    """Take the HostSilent alerts an offline node explains out of the payload,
    mailing that node's notice instead (see the module doc). Closes the
    incidents of nodes that are back. Returns what is left to mail as usual, or
    None when nothing is."""
    alerts = payload.get("alerts") or []
    silent = [a for a in alerts
              if (a.get("labels") or {}).get("alertname") == "HostSilent"
              and (a.get("labels") or {}).get("host") and a.get("status", "firing") == "firing"]
    with _node_lock:
        incidents = load_incidents(args)
        has_silent = any((a.get("labels") or {}).get("alertname") == "HostSilent" for a in alerts)
        if not has_silent and not incidents:
            return payload
        state = cluster_state(args)
        if state is None:
            return payload  # cannot tell: every host is mailed on its own
        offline = offline_nodes(state)
        for node, inc in incidents.items():
            if node not in offline:
                subject, body = node_back_mail(node, state, inc)
                ok, out = notify(args, subject, body, key=f"grafana:NodeDown:{node}", resolve=True)
                print(f"{'sent' if ok else 'NOT sent'}: {subject}" + (f" — {out}" if out and not ok else ""), flush=True)
                if ok:
                    try:
                        os.remove(_incident_path(args, node))
                    except OSError:
                        pass
        incidents = {n: i for n, i in incidents.items() if n in offline}

        keep = [a for a in alerts if a not in silent]
        for a in silent:
            host = a["labels"]["host"]
            node = down_node_of(host, state)
            if node is None:
                keep.append(a)
                continue
            inc = incidents.get(node)
            new = inc is None
            if new:
                down_at, moved, _ = node_events(node, state)
                by_id = {g.get("vmid"): g.get("name") for g in state.get("guests", [])}
                inc = incidents[node] = {
                    "node": node, "since": down_at or a.get("startsAt", ""), "members": [], "mailed": 0,
                    "guests": sorted(g.get("name") for g in state.get("guests", []) if g.get("node") == node),
                    "moved": {by_id.get(v, str(v)): to for v, to in moved.items()}}
            if host not in inc["members"]:
                inc["members"].append(host)
            if new or time.time() - inc.get("mailed", 0) >= NODE_DOWN_REPEAT:
                mail_node_down(args, node, state, inc, meta({"alerts": [a]})["bundle_since"])
            else:
                save_incident(args, inc)
                print(f"folded: HostSilent on {host} into node {node} down", flush=True)
                breadcrumb(args, f"alert folded into node {node} down: HostSilent on {host}")
        if not keep:
            return None
        return payload if len(keep) == len(alerts) else {**payload, "alerts": keep}


# ── planned disruption and many hosts silent at once ─────────────────────
BURST_STALE = 24 * 3600  # a burst nobody resolved is forgotten after a day
_burst_lock = threading.Lock()


def _host(a):
    return (a.get("labels") or {}).get("host", "")


def _is_silent(a, status="firing"):
    return (a.get("labels") or {}).get("alertname") == "HostSilent" and _host(a) \
        and a.get("status", "firing") == status


def maintenance_reason(args, host, now=None):
    """The reason of an open maintenance window that covers host, or None."""
    now = now or time.time()
    short = host.split(".")[0]
    for p in sorted(glob.glob(f"{args.maintenance_dir}/*.json")):
        try:
            with open(p, encoding="utf-8") as f:
                w = json.load(f)
            if float(w.get("until", 0)) < now:
                continue
            scope = w.get("scope")
            if scope == "site" or (isinstance(scope, list) and short in [str(h).split(".")[0] for h in scope]):
                return str(w.get("reason") or "maintenance")
        except (OSError, ValueError, TypeError):
            continue
    return None


def _load_burst(args):
    try:
        with open(args.silent_burst_file, encoding="utf-8") as f:
            b = json.load(f)
        return b if isinstance(b, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_burst(args, b):
    try:
        os.makedirs(os.path.dirname(args.silent_burst_file) or ".", exist_ok=True)
        with open(args.silent_burst_file, "w", encoding="utf-8") as f:
            json.dump(b, f)
    except OSError as e:
        print(f"silent burst NOT recorded: {e}", flush=True)


def burst_mail(b):
    members = sorted(b["members"])
    since = datetime.fromtimestamp(b["since"]).astimezone().strftime("%Y-%m-%d %H:%M")
    lines = [f"{len(members)} hosts stopped logging within minutes of each other, from {since}:",
             "", *[f"  {h}" for h in members], "",
             "Their nodes are up, so the cause is most likely shared: the firewall (restarted, or its",
             "rules), the logging VM, or the network between them. Check those first.",
             "",
             "Their own HostSilent alerts are not mailed; one RESOLVED follows when they all log again.",
             "", "Sent by the logging module's alert rules through tappaas-alert-receiver."]
    return f"ALERT: {len(members)} hosts stopped logging at once", "\n".join(lines) + "\n"


def burst_back_mail(b):
    members = sorted(b["members"])
    lines = [f"The {len(members)} hosts that stopped logging together log again:", "",
             *[f"  {h}" for h in members], "",
             "Sent by the logging module's alert rules through tappaas-alert-receiver."]
    return f"RESOLVED: {len(members)} hosts log again", "\n".join(lines) + "\n"


def in_burst(args, host):
    with _burst_lock:
        b = _load_burst(args)
        return bool(b.get("open")) and host in b.get("members", [])


def fold_quiet(args, payload):
    """Take out of the payload the HostSilent alerts a maintenance window covers
    and those that join a burst of hosts silent at once (see the module doc).
    Closes a burst whose hosts all log again. Returns what is left to mail as
    usual, or None when nothing is."""
    alerts = payload.get("alerts") or []
    if not any((a.get("labels") or {}).get("alertname") == "HostSilent" for a in alerts):
        return payload
    now = time.time()
    keep = []
    with _burst_lock:
        b = _load_burst(args)
        if b.get("open") and now - b.get("since", now) > BURST_STALE:
            b = {}
        recent = {h: t for h, t in (b.get("recent") or {}).items() if now - t <= args.burst_window}
        changed = False
        for a in alerts:
            host = _host(a)
            if _is_silent(a, "resolved"):
                if b.get("open") and host in b.get("members", []):
                    b.setdefault("back", [])
                    if host not in b["back"]:
                        b["back"].append(host)
                    changed = True
                    if set(b["back"]) >= set(b["members"]):
                        subject, body = burst_back_mail(b)
                        ok, out = notify(args, subject, body, key="grafana:SilentBurst:site", resolve=True)
                        print(f"{'sent' if ok else 'NOT sent'}: {subject}" + (f" — {out}" if out and not ok else ""), flush=True)
                        b = {}
                keep.append(a)
                continue
            if not _is_silent(a):
                keep.append(a)
                continue
            why = maintenance_reason(args, host, now)
            if why:
                print(f"folded: HostSilent on {host} into maintenance ({why})", flush=True)
                breadcrumb(args, f"alert folded into maintenance ({why}): HostSilent on {host}")
                continue
            if b.get("open"):
                if host not in b["members"]:
                    b["members"].append(host)
                    changed = True
                print(f"folded: HostSilent on {host} into the silent burst", flush=True)
                breadcrumb(args, f"alert folded into the silent burst: HostSilent on {host}")
                continue
            recent[host] = now
            changed = True
            if len(recent) >= args.burst_min:
                b = {"open": True, "since": min(recent.values()), "members": sorted(recent), "mailed": now}
                subject, body = burst_mail(b)
                threading.Thread(target=send_with_bundle,
                                 args=(args, (subject, body),
                                       {"key": "grafana:SilentBurst:site", "resolve": False,
                                        "bundle_since": meta({"alerts": [a]})["bundle_since"]}),
                                 daemon=True).start()
                print(f"folded: HostSilent on {host} opens a silent burst of {len(recent)}", flush=True)
                breadcrumb(args, f"silent burst opened: {', '.join(sorted(recent))}")
                continue
            keep.append(a)
        if not b.get("open"):
            b = {"recent": recent} if recent else {}
        if changed or not b:
            _save_burst(args, b)
    if not keep:
        return None
    return payload if len(keep) == len(alerts) else {**payload, "alerts": keep}


def send_held(args, mail, m, hosts):
    """A HostSilent's mail, after --silent-hold: unless its host joined a burst
    (or a maintenance window) meanwhile."""
    time.sleep(args.silent_hold)
    left = [h for h in hosts if not in_burst(args, h) and not maintenance_reason(args, h)]
    if hosts and not left:
        print(f"folded after the hold: HostSilent on {', '.join(hosts)}", flush=True)
        return True
    if m["bundle_since"]:
        return send_with_bundle(args, mail, m)
    ok, out = notify(args, *mail, key=m["key"], resolve=m["resolve"])
    print(f"{'sent' if ok else 'NOT sent'}: {mail[0]}" + (f" — {out}" if out and not ok else ""), flush=True)
    return ok


def record(args, payload):
    """One JSON line per alert that arrives, mailed or not (ADR-039 D8): what
    `health-manager alerts` lists as recent. The heartbeat is left out."""
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    lines = []
    for a in payload.get("alerts") or []:
        if is_heartbeat(a):
            continue
        labels = a.get("labels") or {}
        lines.append(json.dumps({
            "time": now, "status": a.get("status", payload.get("status", "firing")),
            "alertname": labels.get("alertname", ""), "host": labels.get("host", ""),
            "module": labels.get("module", ""), "kind": labels.get("kind", ""),
            "labels": extra_labels(labels), "startsAt": a.get("startsAt", ""),
        }, sort_keys=True))
    if not lines:
        return
    try:
        if os.path.exists(args.alerts_log) and os.path.getsize(args.alerts_log) > ALERTS_LOG_MAX:
            with open(args.alerts_log, encoding="utf-8") as f:
                keep = f.readlines()
            with open(args.alerts_log, "w", encoding="utf-8") as f:
                f.writelines(keep[len(keep) // 2:])
        with open(args.alerts_log, "a", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    except OSError as e:
        print(f"alert record NOT written: {e}", flush=True)


# ── the health hook (ADR-041 D2) ─────────────────────────────────────────
DIGEST_RULE = "HealthDailyDigest"
HEALTH_RULES = {"HealthRootCause", "HealthRootRecovered", DIGEST_RULE}  # health-manager's own
HEALTH_TIMEOUT = 300
_health_lock = threading.Lock()
_health_pending = set()
_health_running = [False]


def place_alert(host, module, config_dir):
    """The object an alert is about, as alerts.ts's placeAlert: the instance
    whose vmname (or config name) is its host, else the rule's module."""
    short = host.split(".")[0]
    if short and re.match(r"^[A-Za-z0-9][A-Za-z0-9-]*$", short):
        for path in sorted(glob.glob(f"{config_dir}/*.json")):
            inst = os.path.basename(path)[:-5]
            try:
                with open(path, encoding="utf-8") as f:
                    raw = json.load(f)
            except (OSError, ValueError):
                continue
            if not isinstance(raw, dict) or str(raw.get("status") or "").lower() == "archived":
                continue
            if (raw.get("vmname") or inst) == short and (raw.get("moduleSource") or raw.get("location")):
                return inst
    return module or None


def health_targets(payload, config_dir):
    """What the webhook's alerts are about; None stands for the whole site."""
    out = set()
    for a in payload.get("alerts") or []:
        labels = a.get("labels") or {}
        if is_heartbeat(a) or labels.get("alertname") in HEALTH_RULES:
            continue
        out.add(place_alert(labels.get("host", ""), labels.get("module", ""), config_dir))
    return out


def _health_run(cmd, stdin=None):
    try:
        r = subprocess.run(cmd, text=True, input=stdin, capture_output=True, timeout=HEALTH_TIMEOUT)
        if r.returncode != 0:
            print(f"health hook: {' '.join(cmd[1:])} exited {r.returncode}: {r.stderr.strip()[-300:]}", flush=True)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"health hook: {' '.join(cmd[1:])} NOT run: {e}", flush=True)
        return False


def _health_worker(args):
    while True:
        with _health_lock:
            if not _health_pending:
                _health_running[0] = False
                return
            batch = set(_health_pending)
            _health_pending.clear()
        # The whole site covers every object in the round.
        rounds = [[]] if None in batch else [["--only", ci] for ci in sorted(batch)]
        ok = [_health_run([args.health, "assess"] + r) for r in rounds]
        if any(ok):
            _health_run([args.health, "emit"])


def health_hook(args, payload):
    targets = health_targets(payload, args.config_dir)
    if not targets or not os.path.exists(args.health):
        return
    with _health_lock:
        _health_pending.update(targets)
        if _health_running[0]:
            return
        _health_running[0] = True
    threading.Thread(target=_health_worker, args=(args,), daemon=True).start()


def make_handler(args):
    def token():
        try:
            with open(args.token_file, encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            return ""

    class Handler(BaseHTTPRequestHandler):
        server_version = "tappaas-alert-receiver"

        def reply(self, code, text):
            data = (text + "\n").encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):  # noqa: N802 (http.server's naming)
            want = token()
            got = self.headers.get("Authorization", "")
            # Read once per request, so a rotated token needs no restart. An
            # empty token file refuses everything rather than accepting anything.
            if not want or not hmac.compare_digest(got, f"Bearer {want}"):
                self.reply(401, "unauthorized")
                return
            if self.path.rstrip("/") != "/alert":
                self.reply(404, "not found")
                return
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > MAX_BODY:
                self.reply(400, "bad length")
                return
            try:
                payload = json.loads(self.rfile.read(n))
            except ValueError:
                self.reply(400, "not JSON")
                return
            beats = [a for a in (payload.get("alerts") or []) if is_beat(a)]
            if beats:
                try:
                    with open(args.heartbeat_file, "w", encoding="utf-8") as f:
                        f.write(beats[0].get("startsAt", "") + "\n")
                except OSError as e:
                    print(f"heartbeat NOT recorded: {e}", flush=True)
            record(args, payload)
            health_hook(args, payload)
            payload = fold_node_down(args, payload)
            if payload is None:
                self.reply(200, "folded into a node-down notice")
                return
            payload = fold_quiet(args, payload)
            if payload is None:
                self.reply(200, "folded: maintenance or many hosts silent")
                return
            mail = render(payload, make_lines_for(args))
            if mail is None:
                self.reply(200, "nothing to send")
                return
            if is_digest(payload) and os.path.exists(args.health):
                threading.Thread(target=send_digest, args=(args, mail), daemon=True).start()
                self.reply(200, "queued")
                return
            m = meta(payload)
            held = [_host(a) for a in payload.get("alerts") or [] if _is_silent(a)]
            if held and args.silent_hold > 0:
                threading.Thread(target=send_held, args=(args, mail, m, held), daemon=True).start()
                self.reply(200, "held")
                return
            if m["bundle_since"]:
                threading.Thread(target=send_with_bundle, args=(args, mail, m), daemon=True).start()
                self.reply(200, "queued")
                return
            ok, out = notify(args, *mail, key=m["key"], resolve=m["resolve"])
            print(f"{'sent' if ok else 'NOT sent'}: {mail[0]}" + (f" — {out}" if out and not ok else ""),
                  flush=True)
            # 5xx makes Grafana retry a notice that did not go out.
            self.reply(200 if ok else 502, "sent" if ok else "notify failed")

        def log_message(self, fmt, *a):  # one line per request, to the journal
            print(f"{self.address_string()} {fmt % a}", flush=True)

    return Handler


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--listen", default=DEFAULTS["listen"])
    p.add_argument("--token-file", default=DEFAULTS["token_file"])
    p.add_argument("--notify", default=DEFAULTS["notify"])
    p.add_argument("--bundle", default=DEFAULTS["bundle"])
    p.add_argument("--breadcrumb", default=DEFAULTS["breadcrumb"])
    p.add_argument("--heartbeat-file", default=DEFAULTS["heartbeat_file"])
    p.add_argument("--cluster", default=DEFAULTS["cluster"], help="prints the cluster's state (tappaas-cluster-state.sh)")
    p.add_argument("--node-down-dir", default=DEFAULTS["node_down_dir"])
    p.add_argument("--cluster-cache", type=float, default=DEFAULTS["cluster_cache"])
    p.add_argument("--config-dir", default=DEFAULTS["config_dir"])
    p.add_argument("--alerts-log", default=DEFAULTS["alerts_log"])
    p.add_argument("--loki", default=DEFAULTS["loki"])
    p.add_argument("--loki-admin-file", default=DEFAULTS["loki_admin_file"])
    p.add_argument("--health", default=DEFAULTS["health"], help="health-manager, or nothing to run")
    p.add_argument("--maintenance-dir", default=DEFAULTS["maintenance_dir"])
    p.add_argument("--silent-burst-file", default=DEFAULTS["silent_burst_file"])
    p.add_argument("--silent-hold", type=float, default=DEFAULTS["silent_hold"])
    p.add_argument("--burst-min", type=int, default=DEFAULTS["burst_min"])
    p.add_argument("--burst-window", type=float, default=DEFAULTS["burst_window"])
    p.add_argument("--render", action="store_true", help="read one webhook on stdin, print the mail")
    p.add_argument("--lines-file", help="--render only: the log lines a lines=\"true\" alert gets (tests)")
    args = p.parse_args()

    if args.render:
        fixed = None
        if args.lines_file:
            with open(args.lines_file, encoding="utf-8") as f:
                fixed = f.read().rstrip("\n")
        mail = render(json.load(sys.stdin), (lambda _a: fixed) if args.lines_file else None)
        if mail is None:
            print("(nothing to send)")
        else:
            print(f"Subject: {mail[0]}\n\n{mail[1]}", end="")
        return 0

    host, _, port = args.listen.rpartition(":")
    srv = ThreadingHTTPServer((host or "0.0.0.0", int(port)), make_handler(args))
    print(f"listening on {args.listen}", flush=True)
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
