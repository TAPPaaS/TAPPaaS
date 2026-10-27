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

Every request is authenticated with a bearer token both sides read from a file
(the receiver's, and Grafana's copy that logging/update.sh delivers). Every
notice, sent or not, is a line in the breadcrumb file.

Usage: tappaas-alert-receiver.py [--listen ADDR:PORT] [--token-file F]
                                 [--notify CMD] [--bundle CMD] [--breadcrumb F]
                                 [--cluster CMD] [--node-down-dir D]
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
}
MAX_BODY = 1 << 20  # a Grafana notification is a few KB; refuse anything absurd


# Labels every alert carries; the rest are the series' own (a replication job,
# a unit…) and are what tells one alert from the next, so the mail names them.
_PLAIN_LABELS = {"alertname", "host", "kind", "grafana_folder", "bundle"}


def extra_labels(labels):
    return {k: v for k, v in sorted(labels.items())
            if k not in _PLAIN_LABELS and not k.startswith("__") and v}


def is_heartbeat(alert):
    return (alert.get("labels") or {}).get("kind") == "heartbeat"


def render(payload):
    """One webhook -> (subject, body), or None when there is nothing to mail."""
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
        lines.append("")
    lines.append("Sent by the logging module's alert rules (#126) through tappaas-alert-receiver.")
    return subject, "\n".join(lines) + "\n"


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
              "Sent by the logging module's alert rules (#126) through tappaas-alert-receiver."]
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
    lines += ["", "Sent by the logging module's alert rules (#126) through tappaas-alert-receiver."]
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
            beats = [a for a in (payload.get("alerts") or [])
                     if is_heartbeat(a) and a.get("status", "firing") == "firing"]
            if beats:
                try:
                    with open(args.heartbeat_file, "w", encoding="utf-8") as f:
                        f.write(beats[0].get("startsAt", "") + "\n")
                except OSError as e:
                    print(f"heartbeat NOT recorded: {e}", flush=True)
            payload = fold_node_down(args, payload)
            if payload is None:
                self.reply(200, "folded into a node-down notice")
                return
            mail = render(payload)
            if mail is None:
                self.reply(200, "nothing to send")
                return
            m = meta(payload)
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
    p.add_argument("--render", action="store_true", help="read one webhook on stdin, print the mail")
    args = p.parse_args()

    if args.render:
        mail = render(json.load(sys.stdin))
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
