#!/usr/bin/env python3
# redact.py <dir> — what capture.sh runs over a capture before it reaches the
# repository, which is public. The rules are in README.md; the real values are
# nowhere here. Every address that is global is rewritten unless it is on KEEP,
# so a new one is redacted without anyone naming it, and a second pass has
# nothing left to do. It exits 1, and capture.sh keeps nothing, if one survives.
import ipaddress
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OWN = {"README.md", "capture.sh", "redact.py", "security-scan.synthetic.json"}
SCAN = os.path.join("reads", "health-manager-report-security-json.out")

# Public resolvers: the world's, not the site's.
KEEP = {"1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", "2606:4700:4700::1111", "2606:4700:4700::1001", "2001:4860:4860::8888", "2001:4860:4860::8844", "2620:fe::fe", "2620:fe::9"}
NETS4 = ["192.0.2", "198.51.100", "203.0.113"]  # then 198.18.<n>: benchmark space, also never routed

EMAIL = re.compile(r"[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
V4 = re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])")
V6 = re.compile(r"(?<![0-9A-Za-z:.])(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(?![0-9A-Za-z:])")


def fakes_email(e):
    return e.split("@")[0] == "git" or re.search(r"@(?:[^@]+\.)?(?:example\.(?:org|com|net)|example|invalid|localhost)$", e, re.I) is not None


def address(token):
    try:
        a = ipaddress.ip_address(token)
    except ValueError:
        return None
    return a if a.is_global and token not in KEEP and a.compressed not in KEEP else None


def files(root):
    for d, _, names in os.walk(root):
        for n in names:
            if n not in OWN:
                yield os.path.join(d, n)


def read(p):
    with open(p, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()


def found(root):
    emails, v4, v6 = set(), set(), set()
    for p in files(root):
        s = read(p)
        emails.update(e.lower() for e in EMAIL.findall(s) if not fakes_email(e))
        v4.update(a for a in map(address, V4.findall(s)) if a)
        v6.update(a for a in map(address, V6.findall(s)) if a)
    return emails, v4, v6


def main(root):
    scan = os.path.join(root, SCAN)
    if os.path.isdir(os.path.dirname(scan)):
        shutil.copyfile(os.path.join(HERE, "security-scan.synthetic.json"), scan)
    emails, v4, v6 = found(root)

    site = {}
    if os.path.exists(os.path.join(root, "config", "site.json")):
        site = json.loads(read(os.path.join(root, "config", "site.json")))
    owner = str(site.get("email", "")).lower()
    mail = {owner: "operator@example.org"} if owner in emails else {}
    for i, e in enumerate(sorted(emails - set(mail)), 1):
        mail[e] = f"user{i}@example.org"

    nets = sorted({str(a).rsplit(".", 1)[0] for a in v4}, key=lambda n: [int(x) for x in n.split(".")])
    net4 = {n: NETS4[i] if i < len(NETS4) else f"198.18.{i - len(NETS4)}" for i, n in enumerate(nets)}

    # The /48 goes; the subnet and the host stay, so a zone's /64 is still its zone's.
    heads = sorted({tuple(a.exploded.split(":")[:3]) for a in v6})
    net6 = {h: i for i, h in enumerate(heads, 1)}

    def to6(a):
        rest = a.exploded.split(":")[3:]
        return str(ipaddress.ip_address(":".join(["2001", "db8", format(net6[tuple(a.exploded.split(":")[:3])], "x")] + rest)))

    def sub4(m):
        a = address(m.group(0))
        return f"{net4[m.group(0).rsplit('.', 1)[0]]}.{m.group(0).rsplit('.', 1)[1]}" if a else m.group(0)

    def sub6(m):
        a = address(m.group(0))
        return to6(a) if a else m.group(0)

    # A prefix written without its zeros or its tail, which is no address of its own.
    texts = sorted({(":".join(x.lstrip("0") or "0" for x in h), i) for h, i in net6.items()}, reverse=True)
    for p in files(root):
        s = t = read(p)
        t = EMAIL.sub(lambda m: mail.get(m.group(0).lower(), m.group(0)), t)
        t = V4.sub(sub4, t)
        t = V6.sub(sub6, t)
        for text, i in texts:
            t = t.replace(text + ":", f"2001:db8:{i:x}:")
        if t != s:
            with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(t)

    left = found(root)
    heads32 = {":".join(x.lstrip("0") for x in h[:2]) + ":" for h in heads}
    partial = sum(1 for p in files(root) if any(h in read(p) for h in heads32))
    if any(left) or partial:
        print(f"redact: not clean: {len(left[0])} email(s), {len(left[1])} IPv4, {len(left[2])} IPv6, {partial} file(s) with a site prefix", file=sys.stderr)
        return 1
    print(f"redacted {len(mail)} email(s), {len(v4)} IPv4 in {len(net4)} /24, {len(v6)} IPv6 in {len(net6)} /48; the scan is the synthetic one")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
