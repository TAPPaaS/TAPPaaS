"""Home-side WireGuard (os-wireguard) management for the ADR-010 satellite tunnel.

SCAFFOLD (ADR-010 implementation P2). TAPPaaS does not drive os-wireguard today
(NetBird is configured manually), so this is new control-plane code. It mirrors
the FirewallManager pattern (Config -> Client -> run_module).

The HOME (OPNsense) end is the *initiator*: it dials OUT to the satellite's public
IP (peer endpoint + PersistentKeepalive); the satellite only listens. Each end
generates its OWN keypair; only public keys are exchanged (D19).

IMPORTANT: the exact os-wireguard REST endpoint / parameter shapes are marked
CONFIRM-ON-LIVE and are verified against a live OPNsense with the os-wireguard
plugin installed (P2 deep test, hardware-gated). Until then, only `dry_run`
execution is supported — it records the intended operations (the reviewable
home-side spec) without touching OPNsense. Live execution raises until confirmed.
"""

from __future__ import annotations

from dataclasses import dataclass

from .config import Config


@dataclass
class WgServer:
    """The home-side WireGuard interface (one per satellite tunnel)."""

    name: str  # e.g. "edge-<satellite>"
    address: str  # home /31 end, e.g. "10.255.0.1/31"
    listen_port: int = 51820  # home may listen too; not required as initiator


@dataclass
class WgPeer:
    """The satellite peer as seen from OPNsense (home dials out to it)."""

    name: str  # e.g. "satellite-<name>"
    public_key: str  # satellite's infra-tunnel public key (read back over SSH)
    endpoint: str  # "<satellite-public-ip>:<wgPort>"  <-- home dials this
    allowed_ips: list[str]  # what home routes TO the satellite (its /32 + relay)
    keepalive: int = 25  # keeps the CGNAT pinhole open


class WireGuardManager:
    """Create/read the home WireGuard server + satellite peer on OPNsense.

    Use `dry_run=True` to record intended operations without connecting (the
    only supported mode until the os-wireguard REST binding is confirmed live).
    """

    def __init__(self, config: Config, dry_run: bool = True):
        self.config = config
        self.dry_run = dry_run
        self._client = None
        self.planned: list[dict] = []

    # -- connection (live only) ------------------------------------------------
    def connect(self) -> "WireGuardManager":
        if self.dry_run:
            return self
        from oxl_opnsense_client import Client  # imported lazily (live only)

        kwargs = {
            "firewall": self.config.firewall,
            "port": self.config.resolve_port(),
            "ssl_verify": self.config.ssl_verify,
            "debug": self.config.debug,
        }
        if self.config.credential_file:
            kwargs["credential_file"] = self.config.credential_file
        elif self.config.token and self.config.secret:
            kwargs["token"] = self.config.token
            kwargs["secret"] = self.config.secret
        self._client = Client(**kwargs)
        return self

    def __enter__(self) -> "WireGuardManager":
        return self.connect()

    def __exit__(self, *_):
        self._client = None

    def _record(self, op: str, **params) -> dict:
        entry = {"op": op, "params": params}
        self.planned.append(entry)
        return entry

    def _live(self, op: str, **params):
        # CONFIRM-ON-LIVE: bind to the os-wireguard REST API here. The controller's
        # `raw` run-module passthrough is the mechanism (cf. FirewallManager):
        #   self._client.run_module("raw", params={"module": "wireguard",
        #       "controller": <server|client|general>, "command": <add|set|get>,
        #       "action": <add|set|get>, ...})
        # The exact controller/command/param names are verified on a live OPNsense
        # with os-wireguard installed (P2 deep test). Until then, refuse to run.
        raise NotImplementedError(
            f"os-wireguard live binding pending hardware confirmation for '{op}' "
            f"(ADR-010 P2 deep test). Re-run with --dry-run."
        )

    def _do(self, op: str, **params):
        self._record(op, **params)
        if not self.dry_run:
            return self._live(op, **params)
        return None

    # -- operations ------------------------------------------------------------
    def ensure_server(self, server: WgServer):
        """Create/update the home WireGuard interface (generates its own keypair)."""
        return self._do(
            "ensure_server",
            name=server.name,
            address=server.address,
            listen_port=server.listen_port,
        )

    def get_server_public_key(self, name: str) -> str | None:
        """Read the home interface's PUBLIC key (to hand to the satellite peer)."""
        self._do("get_server_public_key", name=name)
        return None  # live: parse from the os-wireguard 'get'

    def ensure_peer(self, server_name: str, peer: WgPeer):
        """Create/update the satellite peer (home dials out: endpoint + keepalive)."""
        return self._do(
            "ensure_peer",
            server=server_name,
            name=peer.name,
            public_key=peer.public_key,
            endpoint=peer.endpoint,
            allowed_ips=peer.allowed_ips,
            keepalive=peer.keepalive,
        )

    def remove_peer(self, server_name: str, peer_name: str):
        """Remove the satellite peer (decommission, P3)."""
        return self._do("remove_peer", server=server_name, name=peer_name)

    def apply(self):
        """Apply buffered os-wireguard changes (reconfigure the service)."""
        return self._do("apply")
