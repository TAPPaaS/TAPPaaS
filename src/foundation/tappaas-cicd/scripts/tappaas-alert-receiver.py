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

Every request is authenticated with a bearer token both sides read from a file
(the receiver's, and Grafana's copy that logging/update.sh delivers). Every
notice, sent or not, is a line in the breadcrumb file.

Usage: tappaas-alert-receiver.py [--listen ADDR:PORT] [--token-file F]
                                 [--notify CMD] [--breadcrumb F]
       tappaas-alert-receiver.py --render < webhook.json   (print the mail; tests)
"""

import argparse
import hmac
import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULTS = {
    "listen": "0.0.0.0:9095",
    "token_file": "/etc/secrets/tappaas-alert-token",
    "notify": "/home/tappaas/bin/site-notify.sh",
    "breadcrumb": "/home/tappaas/config/alerts.log",
    "heartbeat_file": "/var/lib/tappaas/alert-heartbeat",
}
MAX_BODY = 1 << 20  # a Grafana notification is a few KB; refuse anything absurd


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
    subject = f"{word}: {headline or name}{where}"

    lines = []
    for a in alerts:
        labels = a.get("labels") or {}
        ann = a.get("annotations") or {}
        lines.append(f"== {labels.get('alertname', name)}"
                     + (f" — {labels['host']}" if labels.get("host") else ""))
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


def notify(args, subject, body):
    cmd = [args.notify, "--subject", subject, "--what", "alert", "--breadcrumb", args.breadcrumb]
    try:
        r = subprocess.run(cmd, input=body, text=True, capture_output=True, timeout=120)
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)


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
            mail = render(payload)
            if mail is None:
                self.reply(200, "nothing to send")
                return
            ok, out = notify(args, *mail)
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
    p.add_argument("--breadcrumb", default=DEFAULTS["breadcrumb"])
    p.add_argument("--heartbeat-file", default=DEFAULTS["heartbeat_file"])
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
