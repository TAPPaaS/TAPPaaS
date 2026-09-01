"""Shared service-health probes for the OPNsense controller.

Centralises the "is the shared service still answering?" check so both the
zone-manager pre/post-flight gates and the unbound-manager post-write guard
(#516) use one implementation instead of copies. IP literals only: a probe of
the resolver must never itself depend on the resolver.
"""

import socket
import subprocess
import time

from .firewall_identity import FIREWALL_KEY, firewall_key_present
from .log import debug, warn

# The Unbound config + validator on OPNsense. checkconf MUST run from
# /var/unbound: the DNSBL python module is referenced by a RELATIVE path, so
# running it elsewhere yields a misleading "can't open dnsbl_module.py" instead
# of the real error (see src/foundation/network/DESIGN.md). Run from there and
# it prints the deterministic fatal line, e.g. "local-data in redirect zone
# must reside at top of zone" — better evidence than scraping the rotated log.
_UNBOUND_CHECKCONF = (
    "cd /var/unbound && /usr/local/sbin/unbound-checkconf /var/unbound/unbound.conf"
)


def check_unbound_dns(host: str = "10.0.0.1", label: str = "",
                      retries: int = 1, delay: float = 2.0) -> bool:
    """True if Unbound at <host>:53 answers a UDP query, False otherwise.

    `retries` > 1 tolerates a briefly-stabilising Unbound: right after the
    firewall regenerates its config, OPNsense restarts Unbound, so a single 2s
    probe can miss it even though it comes up moments later (the update.sh `dig`
    check retries for the same reason). Gating callers pass a few retries so a
    momentary miss does not trip them; instrumentation callers keep the default
    single probe.
    """
    prefix = f"[UNBOUND-CHECK {label}] " if label else "[UNBOUND-CHECK] "
    # Minimal DNS query for firewall.mgmt.internal A. Header: ID=0x1234,
    # flags=0x0100 (standard query), 1 question.
    query = (
        b'\x12\x34'  # Transaction ID
        b'\x01\x00'  # Flags: standard query
        b'\x00\x01'  # Questions: 1
        b'\x00\x00'  # Answer RRs: 0
        b'\x00\x00'  # Authority RRs: 0
        b'\x00\x00'  # Additional RRs: 0
        b'\x08firewall\x04mgmt\x08internal\x00'
        b'\x00\x01'  # Type: A
        b'\x00\x01'  # Class: IN
    )
    attempts = max(1, retries)
    for attempt in range(attempts):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.settimeout(2.0)
            sock.sendto(query, (host, 53))
            response, _ = sock.recvfrom(512)
            if len(response) >= 12:  # a DNS header at minimum
                debug(f"{prefix}DNS OK - Unbound responding on {host}:53")
                return True
        except socket.timeout:
            pass  # fall through to retry / final failure
        except OSError as e:
            warn(f"{prefix}DNS FAILED - Unbound check error: {e}")
            return False
        finally:
            sock.close()
        if attempt < attempts - 1:
            debug(f"{prefix}no response (attempt {attempt + 1}/{attempts}) — "
                  f"retrying in {delay}s")
            time.sleep(delay)
    warn(f"{prefix}DNS FAILED - Unbound NOT responding on {host}:53 "
         f"(timeout after {attempts} attempt(s))")
    return False


def _firewall_ssh(host: str, script: str, timeout: float = 15.0) -> subprocess.CompletedProcess:
    """Run a bourne script on the firewall over ssh (root@firewall runs csh, so
    pipe to `sh -s`). Sibling of dhcp_manager_cli._fw_sh, but pins the dedicated
    firewall key explicitly and connects by whatever `host` is given: this is
    called when the resolver is (suspected) DOWN, so `host` must be an IP — a
    name would not resolve, and ~/.ssh/config's per-hostname key mapping would
    not match the IP either, hence the explicit -i.
    """
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
           "-o", "StrictHostKeyChecking=accept-new"]
    if firewall_key_present():  # warns once (#536) when unprovisioned
        cmd += ["-i", FIREWALL_KEY, "-o", "IdentitiesOnly=yes"]
    cmd += [f"root@{host}", "sh -s"]
    return subprocess.run(cmd, input=script, text=True,
                          capture_output=True, timeout=timeout)


def unbound_checkconf(host: str) -> tuple[bool, str]:
    """Validate the firewall's live Unbound config, returning (valid, output).

    Runs unbound-checkconf on the firewall over ssh (by IP — see _firewall_ssh).
    `output` is the validator's combined stderr/stdout, which on failure carries
    the deterministic fatal line. BEST-EFFORT evidence: any ssh/spawn failure
    returns (False, "<why the validator could not run>") and never raises, so a
    caller can enrich its diagnostics without risking its own control flow.
    """
    try:
        r = _firewall_ssh(host, _UNBOUND_CHECKCONF + "\n")
    except (OSError, subprocess.SubprocessError) as e:
        return False, f"could not run unbound-checkconf on {host}: {e}"
    out = ((r.stderr or "") + (r.stdout or "")).strip()
    return r.returncode == 0, out
