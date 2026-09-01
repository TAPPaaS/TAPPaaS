"""firewall_identity.py — the firewall's dedicated SSH key, and a visible
signal when a site is running without it (#226, #536).

``root@firewall`` accepts ONLY the dedicated ``tappaas-fw`` key — the general
``id_ed25519`` is not authorized there. ``config-firewall.sh`` /
``grant_cicd_firewall_access()`` (#226) provision it. A site bootstrapped before
that has no key; without a signal, the fallback to the ambient identity — which
fails under sudo/root per ADR-018 — is silent and indistinguishable from the
intended design (#536). ``firewall_key_present()`` makes that state visible.
"""

import os

from .log import warn

FIREWALL_KEY = "/home/tappaas/.ssh/tappaas-fw"

# Warn at most once per process — _fw_sh/_firewall_ssh may be called repeatedly.
_warned = False


def firewall_key_present() -> bool:
    """True if the dedicated firewall key exists.

    On the first observed absence, emit a one-time ``[Warning]`` (later calls
    stay quiet) so a site on the unprovisioned fallback path is not left
    guessing. Preserves the callers' behaviour: they still add ``-i`` only when
    this returns True.
    """
    global _warned
    if os.path.isfile(FIREWALL_KEY):
        return True
    if not _warned:
        _warned = True
        warn(
            f"firewall key {FIREWALL_KEY} is not provisioned — the general "
            "id_ed25519 is NOT authorized on the firewall, so this SSH falls "
            "back to the ambient identity and will fail under sudo/root. "
            "Provision it with config-firewall.sh (grant_cicd_firewall_access, "
            "#226)."
        )
    return False
