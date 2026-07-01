"""Home-side WireGuard (os-wireguard) management for the ADR-010 satellite tunnel.

SCAFFOLD (ADR-010 implementation P2). TAPPaaS does not drive os-wireguard today
(NetBird is configured manually), so this is new control-plane code. It mirrors
the FirewallManager pattern (Config -> Client -> run_module).

The HOME (OPNsense) end is the *initiator*: it dials OUT to the satellite's public
IP (peer endpoint + PersistentKeepalive); the satellite only listens. Each end
generates its OWN keypair; only public keys are exchanged (D19).

CONFIRMED against a live OPNsense test firewall (2026-07-01). WireGuard is in the
OPNsense base (no os-wireguard package needed); the REST API is live:

  Home INSTANCE ("server"):   /api/wireguard/server/{addServer,setServer,getServer,searchServer,delServer}
    fields: name, instance, enabled, pubkey, privkey (empty => OPNsense generates),
            port (listen; optional as we are the initiator), tunneladdress (home /31),
            peers (list of client UUIDs), mtu, dns, gateway, disableroutes, ...
  Satellite PEER ("client"):  /api/wireguard/client/{addClient,setClient,getClient,searchClient,delClient}
    fields: name, enabled, pubkey (satellite pubkey), endpoint (satellite:wgPort <- home dials here),
            keepalive (25), tunneladdress (allowed-IPs; satellite /32), servers (list of server UUIDs), psk
  Enable + apply:  /api/wireguard/general/set  then  /api/wireguard/service/reconfigure

Driven via the controller's `raw` run-module passthrough (module="wireguard").

`dry_run` records the intended operations (the reviewable home-side spec) without
touching OPNsense. `_live` is the next P2 step (create instance -> read back its
generated pubkey -> add peer -> link -> reconfigure), validated create/read/delete
on the test firewall before use.
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
        # RECIPE VALIDATED end-to-end on the test OPNsense (2026-07-01):
        # create server -> read-back pubkey (matched) -> create client -> delete
        # both -> 0/0 clean. Exact calls (POST JSON to :8443, self-signed => no
        # verify; creds file is `key=`/`secret=` prefixed):
        #
        #   keygen: `wg genkey | wg pubkey`  (needs wireguard-tools; OPNsense has
        #           NO genKeys endpoint and addServer will NOT auto-generate —
        #           a real pubkey+privkey MUST be supplied).
        #   ensure_server -> POST /api/wireguard/server/addServer  (body:
        #       {"server":{"enabled":"1","name":..,"pubkey":H_PUB,"privkey":H_PRIV,
        #                  "tunneladdress":"10.255.0.1/31"}}) -> {"result":"saved","uuid":..}
        #       read back: GET /api/wireguard/server/getServer/<uuid> -> .server.pubkey
        #   ensure_peer   -> POST /api/wireguard/client/addClient  (body:
        #       {"client":{"enabled":"1","name":..,"pubkey":SAT_PUB,
        #                  "endpoint":"<sat-ip>:<wgPort>",   # host:port in ONE field
        #                  "keepalive":"25","tunneladdress":"10.255.0.0/32",
        #                  "servers":"<server-uuid>"}})
        #   remove -> POST /api/wireguard/{client/delClient,server/delServer}/<uuid>
        #   apply  -> POST /api/wireguard/general/set (enabled=1) + service/reconfigure
        #
        # Wiring this recipe into requests/oxl calls is the remaining P2 code step
        # (needs a satellite for a real endpoint + handshake — P3). Until wired:
        raise NotImplementedError(
            f"wg-manager live binding not yet wired for '{op}' (OPNsense WireGuard "
            f"recipe VALIDATED live 2026-07-01 — see above; wiring is the remaining "
            f"P2 code step). Re-run with --dry-run."
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
