#!/usr/bin/env python3
"""support-anonymize — the anonymizing half of tappaas-support-bundle.sh (#883).

Copies the site's configuration into a support bundle's staging directory with
personal data and secrets removed, then scrubs every text file already in the
staging directory (the logs) with the same replacements, so a log cannot give
away what the configuration hid.

What goes in is an allowlist: the files that describe how the site is built
(site, network, zones, cluster, storage, backup, the control plane, the
switches, the environments and every module's own JSON). Never the people and
identities, the VPN peers, the backup peers, provisioning records, the firewall
state, the SBOM, backups of files (*.orig, *.bak*) or anything not listed.

Replacements:
  secrets      any field named like a password, secret, token, key, psk, hash
               → "REDACTED"; `password=…`-style values in logs likewise
  people       the site's owner and display name, every user's name, display
               name and address, the VPN and backup peers' names → person-N
  places       the locations' addresses, cities, buildings, coordinates → place-N
  addresses    every e-mail address → user-N@<its domain>; not a login at an
               internal host (tappaas@nextcloud.rossen.internal)
  public IPs   every global IPv4/IPv6 address → 203.0.113.N / 2001:db8::N; not
               the public resolvers (1.1.1.1, 8.8.8.8, 9.9.9.9 …)
Kept: domains (operator, 2026-10-27), private and management addresses, MACs,
module, environment and zone names — they are what a supporter debugs with.
JSON keys get the same replacements as values (a location is named by its key).
A person's name that is also a module, environment, zone or domain label is
kept too: replacing it would garble the configuration.

The map (original → replacement) is written to --map, mode 0600, and stays on
the site: the operator can decode a supporter's question with it. It never
goes into the bundle.

Usage: support-anonymize.py --config-dir DIR --stage DIR --map FILE
Prints a JSON summary (counts per category, files included) on stdout.
"""

import argparse
import glob
import ipaddress
import json
import os
import re
import sys

# Config files that describe how the site is built. Module JSONs are added by
# looks (below); everything else stays out.
ALLOW = [
    "site.json", "network.json", "zones.json", "zones.effective.json", "cluster.json",
    "cluster-cpu.json", "storage.json", "backup.json", "control-plane.json",
    "last-update-result.json", "release-train.json", "templates.json", "positions.json",
    "switch-configuration-desired.json", "switch-configuration-actual.json", "switch-read.json",
    "firewall-cert.json", "shares.json",
]
DENY_DIRS = {"people", "identities", "wgvpn", "provision", "firewall", "sbom", "branding", "support"}
DENY_NAME = re.compile(r"(\.orig|\.bak.*|\.pre-.*|\.consumed|\.lock)$|^remote-|^train-preview|^module-fields\.json$|\.meta\.json$|\.fsbackup\.json$")

SECRET_KEY = re.compile(r"(pass(word|wd|phrase)?|secret|token|psk|private|api.?key|credential|hash|salt|cookie|bearer|peerkey|presharedkey)$|^(key|.*_key)$", re.I)
PLACE_KEYS = {"address", "street", "city", "building", "latitude", "longitude", "postcode", "zip"}
# Values never treated as a person, however a record names them.
GENERIC = {"admin", "root", "tappaas", "test", "user", "operator", "owner", "default", "guest",
           "home", "site", "local", "none", "unknown", "true", "false"}

EMAIL = re.compile(r"(?<![\w.+-])([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)")
IPV4 = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.]|\.\d)")
IPV6 = re.compile(r"(?<![0-9A-Za-z:.])([0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7})(?![0-9A-Za-z:])")
INLINE_SECRET = re.compile(r"(?i)\b(password|passwd|secret|token|api[_-]?key)(\s*[=:]\s*)([^\s,;'\"]+)")
BEARER = re.compile(r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}")
# Logins at internal hosts, not mail: tappaas@nextcloud.rossen.internal.
INTERNAL_DOMAIN = re.compile(r"(?i)\.(internal|local|lan|localdomain|arpa)$")
# Well-known public resolvers: no one's address, and what egress tests name.
PUBLIC_RESOLVERS = {"1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
                    "208.67.222.222", "208.67.220.220", "2606:4700:4700::1111", "2606:4700:4700::1001",
                    "2001:4860:4860::8888", "2001:4860:4860::8844", "2620:fe::fe", "2620:fe::9"}
PEM = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S)


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


class Anonymizer:
    def __init__(self):
        self.map = {}       # original -> replacement
        self.count = {"secrets": 0, "people": 0, "places": 0, "emails": 0, "public_ips": 0}
        self.n = {"person": 0, "place": 0, "user": 0, "ip4": 0, "ip6": 0}
        self.people = {}    # value -> placeholder, matched in text
        self.protected = set()

    def _new(self, kind):
        self.n[kind] += 1
        return self.n[kind]

    # ── what counts as a person or a place ──
    def person(self, value, kind="person"):
        if not isinstance(value, str):
            return
        v = value.strip()
        if len(v) < 3 or v.lower() in GENERIC or v.lower() in self.protected or "@" in v:
            return
        if v not in self.people:
            self.people[v] = f"{kind}-{self._new(kind)}"
            self.map[v] = self.people[v]

    def place(self, value):
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return
        self.person(value, "place")

    # ── text ──
    def email(self, m):
        local, domain = m.group(1), m.group(2)
        orig = f"{local}@{domain}"
        if INTERNAL_DOMAIN.search(domain):
            return orig
        if orig not in self.map:
            self.map[orig] = f"user-{self._new('user')}@{domain}"
        self.count["emails"] += 1
        return self.map[orig]

    def ip(self, m, v6):
        s = m.group(1)
        try:
            a = ipaddress.ip_address(s)
        except ValueError:
            return s
        if not a.is_global or s in PUBLIC_RESOLVERS:
            return s
        if s not in self.map:
            n = self._new("ip6" if v6 else "ip4")
            self.map[s] = f"2001:db8::{n:x}" if v6 else (f"203.0.113.{n}" if n < 255 else f"198.51.100.{n % 255}")
        self.count["public_ips"] += 1
        return self.map[s]

    def text(self, s):
        s, k = PEM.subn("[REDACTED PRIVATE KEY]", s)
        self.count["secrets"] += k
        s, k = INLINE_SECRET.subn(lambda m: f"{m.group(1)}{m.group(2)}REDACTED", s)
        self.count["secrets"] += k
        s, k = BEARER.subn(lambda m: f"{m.group(1)}REDACTED", s)
        self.count["secrets"] += k
        s = EMAIL.sub(self.email, s)
        if self.people:
            alt = "|".join(re.escape(v) for v in sorted(self.people, key=len, reverse=True))
            rx = re.compile(rf"(?<![\w-])({alt})(?![\w-])", re.I)
            lower = {k.lower(): v for k, v in self.people.items()}

            def who(m):
                r = lower[m.group(1).lower()]
                self.count["places" if r.startswith("place-") else "people"] += 1
                return r
            s = rx.sub(who, s)
        s = IPV4.sub(lambda m: self.ip(m, False), s)
        s = IPV6.sub(lambda m: self.ip(m, True), s)
        return s

    # ── JSON: secrets by field name, then the text rules on every string ──
    def json(self, o, key=""):
        if isinstance(o, dict):
            return {self.text(k): self.json(v, k) for k, v in o.items()}
        if isinstance(o, list):
            return [self.json(v, key) for v in o]
        if isinstance(o, str) and SECRET_KEY.search(key or "") and o:
            self.count["secrets"] += 1
            return "REDACTED"
        if key in ("latitude", "longitude") and isinstance(o, (int, float)) and not isinstance(o, bool):
            self.count["places"] += 1
            return 0
        if isinstance(o, str):
            return self.text(o)
        return o


def collect(an, cfg):
    """Learn the people and places from the records that hold them."""
    site = load(os.path.join(cfg, "site.json")) or {}
    # Names a supporter needs as they are: never a person.
    prot = {site.get("name"), site.get("defaultEnvironment")}
    for f in glob.glob(os.path.join(cfg, "*.json")) + glob.glob(os.path.join(cfg, "environments", "*.json")):
        prot.add(os.path.basename(f).split(".")[0])
    for f in glob.glob(os.path.join(cfg, "environments", "*.json")):
        env = load(f) or {}
        for d in (env.get("domains") or {}).values():
            for d1 in (d if isinstance(d, list) else [d]):
                if isinstance(d1, str):
                    prot.update(d1.split("."))
    zones = load(os.path.join(cfg, "zones.json")) or {}
    prot.update(k for k in zones if not k.startswith("_"))
    an.protected = {p.lower() for p in prot if isinstance(p, str) and p}

    for k in ("owner", "displayName"):
        an.person(site.get(k))
    for name, loc in (site.get("locations") or {}).items():
        an.place(name)
        if isinstance(loc, dict):
            for k in PLACE_KEYS | {"displayName"}:
                an.place(loc.get(k))
    for d in ("identities", "people"):
        for f in glob.glob(os.path.join(cfg, d, "users", "*.json")):
            u = load(f) or {}
            for k in ("name", "displayName", "givenName", "familyName", "username"):
                an.person(u.get(k))
            an.person(os.path.basename(f)[:-5])
    peers = load(os.path.join(cfg, "wgvpn", "peers.json")) or {}
    for name in (peers if isinstance(peers, dict) else {}):
        an.person(name)
    for f in glob.glob(os.path.join(cfg, "remote-*.json")):
        an.person((load(f) or {}).get("name"))
        an.person(os.path.basename(f)[len("remote-"):-5])


def included(cfg):
    """The config files that go in, relative to cfg."""
    out = []
    for f in sorted(glob.glob(os.path.join(cfg, "*.json"))):
        b = os.path.basename(f)
        if DENY_NAME.search(b):
            continue
        if b in ALLOW:
            out.append(b)
            continue
        o = load(f)
        # A module's own JSON: it names its VM or its dependencies.
        if isinstance(o, dict) and ("vmname" in o or "dependsOn" in o or "vmid" in o):
            out.append(b)
    for f in sorted(glob.glob(os.path.join(cfg, "environments", "*.json"))):
        if not DENY_NAME.search(os.path.basename(f)):
            out.append(os.path.relpath(f, cfg))
    return [p for p in out if p.split(os.sep)[0] not in DENY_DIRS]


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--config-dir", required=True)
    p.add_argument("--stage", required=True)
    p.add_argument("--map", required=True)
    a = p.parse_args()

    an = Anonymizer()
    collect(an, a.config_dir)

    # The logs and status already in the stage.
    scrubbed = 0
    for root, _, files in os.walk(a.stage):
        for fn in files:
            path = os.path.join(root, fn)
            try:
                with open(path, encoding="utf-8", errors="replace") as f:
                    s = f.read()
            except OSError:
                continue
            with open(path, "w", encoding="utf-8") as f:
                f.write(an.text(s))
            scrubbed += 1

    files = included(a.config_dir)
    for rel in files:
        o = load(os.path.join(a.config_dir, rel))
        if o is None:
            continue
        dst = os.path.join(a.stage, "config", rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w", encoding="utf-8") as f:
            json.dump(an.json(o), f, indent=2)
            f.write("\n")

    os.makedirs(os.path.dirname(os.path.abspath(a.map)), exist_ok=True)
    fd = os.open(a.map, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(an.map, f, indent=2, sort_keys=True)
        f.write("\n")

    json.dump({"redacted": an.count, "config_files": files, "scrubbed_files": scrubbed,
               "kept": ["domains", "private addresses", "MAC addresses", "module, environment and zone names"]},
              sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
