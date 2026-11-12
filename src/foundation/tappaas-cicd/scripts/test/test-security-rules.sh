#!/usr/bin/env bash
#
# test-security-rules.sh — the security rules of the foundation modules
# (ADR-050), offline: each rule's line filter against lines it must catch and
# lines it must not, and the address it captures. Python's re stands in for
# RE2: the rules use only what both read the same.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="${HERE}/../../.."
command -v python3 >/dev/null || { echo "needs python3"; exit 77; }

python3 -I - "${F}" <<'PYEOF'
import json, re, sys
F = sys.argv[1]
rules = {}
for m in ("logging", "identity", "pvehost", "network"):
    for r in json.load(open(f"{F}/{m}/{m}-alerts.json"))["rules"]:
        if r.get("security"):
            rules[r["name"]] = r
passed = failed = 0
def ck(c, msg):
    global passed, failed
    if c: passed += 1
    else: failed += 1; print(f"  FAIL: {msg}")

def catches(name, line, ip=None):
    r = rules[name]
    ck(re.search(r["match"], line) is not None, f"{name} catches: {line}")
    if ip:
        cap = r["capture"]["src_ip"]
        m = re.search(cap, line)
        ck(m is not None and m.group("src_ip") == ip, f"{name} captures {ip} from: {line} ({m and m.group('src_ip')})")
def ignores(name, line):
    ck(re.search(rules[name]["match"], line) is None, f"{name} ignores: {line}")

catches("ssh-brute-force", "Failed password for root from 203.0.113.9 port 51022 ssh2", "203.0.113.9")
catches("ssh-brute-force", "Invalid user admin from 2001:db8::7 port 4022", "2001:db8::7")
catches("ssh-brute-force", "Invalid user tappaas from 10.0.0.144 port 60122", "10.0.0.144")
catches("ssh-brute-force", "Connection closed by authenticating user root 198.51.100.4 port 40112 [preauth]", "198.51.100.4")
ignores("ssh-brute-force", "Accepted publickey for tappaas from 10.0.0.209 port 50122 ssh2: ED25519 SHA256:x")
ignores("ssh-brute-force", 'level=info msg="query" query="{host=~\\"^(a)$\\"} |~ \\"^(Failed password for|Invalid user)\\""')
catches("ssh-password-login", "Accepted password for root from 203.0.113.9 port 51022 ssh2", "203.0.113.9")
ignores("ssh-password-login", "Accepted publickey for root from 10.0.0.209 port 50122 ssh2: ED25519 SHA256:x")
catches("sudo-refused", "pam_unix(sudo:auth): authentication failure; logname=lars uid=1000 euid=0 tty=/dev/pts/0")
catches("sudo-refused", "lars : user NOT in sudoers ; TTY=pts/0 ; PWD=/home/lars ; USER=root ; COMMAND=/bin/sh")
catches("sudo-refused", "lars : 3 incorrect password attempts ; TTY=pts/0 ; PWD=/home/lars ; USER=root")
ignores("sudo-refused", "tappaas : TTY=pts/0 ; PWD=/home/tappaas ; USER=root ; COMMAND=/run/current-system/sw/bin/systemctl status")
catches("audit-stopped", "Stopping Security Auditing Service...")
catches("audit-stopped", "Stopped auditd.service - Linux Audit daemon.")
catches("audit-stopped", "audit: type=1305 audit(1731398400.123:42): op=set audit_enabled=0 old=1 auid=0 ses=3 res=1")
ignores("audit-stopped", "Started Security Auditing Service.")
catches("authentik-login-bf", '{"action": "login_failed", "client_ip": "203.0.113.9", "event": "Created Event", "context": {"username": "lars"}}', "203.0.113.9")
catches("authentik-login-bf", '{"action":"login_failed","client_ip":"2001:db8::1"}', "2001:db8::1")
ignores("authentik-login-bf", '{"action": "login", "client_ip": "203.0.113.9", "event": "Created Event"}')
catches("authentik-suspicious", '{"action": "suspicious_request", "client_ip": "203.0.113.9"}', "203.0.113.9")
catches("authentik-impersonation", '{"action": "impersonation_started", "user": {"username": "admin"}}')
catches("pve-auth-failure", " authentication failure; rhost=::ffff:203.0.113.9 user=root@pam msg=Authentication failure", "203.0.113.9")
catches("pve-auth-failure", "authentication failure; rhost=10.0.0.5 user=lars@pve msg=no such user", "10.0.0.5")
catches("opnsense-login-failed", "/index.php: Web GUI authentication error for user 'root' from: 203.0.113.9", "203.0.113.9")
catches("opnsense-login-failed", "/index.php: Web GUI authentication error for 'root' from 203.0.113.9", "203.0.113.9")
ignores("opnsense-login-failed", "/index.php: Successful login for user 'root' from: 10.0.0.209")
catches("kernel-module-session", 'SYSCALL arch=c000003e syscall=313 success=yes exit=0 a0=3 items=0 ppid=1200 pid=1301 auid=1000 uid=0 comm="modprobe" exe="/run/current-system/sw/bin/kmod" key="tappaas-module"')
ignores("kernel-module-session", 'SYSCALL arch=c000003e syscall=257 success=yes auid=1000 comm="install" key="tappaas-secrets"')
ignores("kernel-module-session", 'level=info msg="query" query="{transport=\\"audit\\"} |~ \\"^SYSCALL .*key=\\\\\\"tappaas-module\\\\\\"\\""')
# The success-after-burst rule is an expression; its two filters, alone:
e = rules["ssh-login-after-bf"]["expr"]
fails, oks = re.findall(r'\|~ "(.*?)"', e)
ck(re.search(fails, "Failed password for root from 203.0.113.9 port 1 ssh2") and re.search(oks, "Accepted publickey for root from 203.0.113.9 port 2 ssh2"), "ssh-login-after-bf: its two line filters")
ck(len({r["name"] for r in rules.values()}) == len(rules) and all(r["security"] in ("info", "warning", "critical") for r in rules.values()), "every security rule has a level")
print(f"security-rules: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PYEOF
