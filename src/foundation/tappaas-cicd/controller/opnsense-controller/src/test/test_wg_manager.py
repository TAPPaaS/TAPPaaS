"""Dry-run tests for the ADR-010 home-side WireGuard manager (P2 scaffold).

These run under the cicd Python (3.10+); they assert the PLANNED operations
without touching OPNsense. The live os-wireguard binding is hardware-gated
(P2 deep test) and is not exercised here.
"""

import pytest

from opnsense_controller.config import Config
from opnsense_controller.wg_manager import WgPeer, WgServer, WireGuardManager


def _cfg() -> Config:
    # placeholder creds: dry-run never connects, but Config requires *some* auth.
    return Config(firewall="firewall.test", token="dry", secret="dry", credential_file=None)


def test_dry_run_plans_server_peer_apply():
    m = WireGuardManager(_cfg(), dry_run=True)
    m.ensure_server(WgServer(name="edge-s1", address="10.255.0.1/31"))
    m.ensure_peer("edge-s1", WgPeer(
        name="satellite-s1", public_key="PUBKEY=",
        endpoint="203.0.113.10:51820", allowed_ips=["10.255.0.0/32"]))
    m.apply()

    assert [p["op"] for p in m.planned] == ["ensure_server", "ensure_peer", "apply"]
    peer = m.planned[1]["params"]
    assert peer["endpoint"] == "203.0.113.10:51820"   # home dials OUT to the satellite
    assert peer["keepalive"] == 25                      # keeps the CGNAT pinhole open
    assert peer["allowed_ips"] == ["10.255.0.0/32"]


def test_live_execution_is_gated_until_confirmed():
    m = WireGuardManager(_cfg(), dry_run=False)
    with pytest.raises(NotImplementedError):
        m.ensure_server(WgServer(name="edge-s1", address="10.255.0.1/31"))
