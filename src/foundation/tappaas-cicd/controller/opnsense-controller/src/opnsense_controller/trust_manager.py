"""OPNsense trust store management for TAPPaaS (ADR-043 D7).

ca-manager makes the site's CAs and certificates on the mothership; this puts
them where the firewall uses them. A CA goes in with its certificate only, never
its key. A served certificate (a domain CA's wildcard) goes in with its key,
because Caddy terminates TLS on the firewall and binds it by refid.

Proven against OPNsense on lab2, 2026-11-03: an imported certificate links
itself to its CA (``caref``), and ``cert/set`` replaces its content in place with
the refid unchanged — so a renewal never breaks Caddy's binding. Entries are
found by their description, which TAPPaaS owns: ``TAPPaaS: …``.
"""

from __future__ import annotations

import base64
import hashlib
from dataclasses import dataclass

from oxl_opnsense_client import Client

from .config import Config


@dataclass
class TrustEntry:
    """One CA or certificate in the trust store, as search returns it."""

    uuid: str
    refid: str
    descr: str
    caref: str
    pem: str

    @property
    def fingerprint(self) -> str:
        """SHA-256 of the PEM text, for telling whether two entries hold the same certificate."""
        return pem_fingerprint(self.pem)


def pem_fingerprint(pem: str) -> str:
    return hashlib.sha256(pem.strip().encode()).hexdigest()


def _decode(crt: str) -> str:
    try:
        return base64.b64decode(crt).decode()
    except (ValueError, UnicodeDecodeError):
        return ""


class TrustManager:
    """Drive System → Trust on OPNsense through its REST API. Every ``*_ensure`` is idempotent."""

    def __init__(self, config: Config):
        self.config = config
        self._client: Client | None = None

    def _get_client_kwargs(self) -> dict:
        kwargs = {
            "firewall": self.config.firewall,
            "port": self.config.resolve_port(),
            "ssl_verify": self.config.ssl_verify,
            "debug": self.config.debug,
            "api_timeout": self.config.api_timeout,
            "api_retries": self.config.api_retries,
        }
        if self.config.credential_file:
            kwargs["credential_file"] = self.config.credential_file
        elif self.config.token and self.config.secret:
            kwargs["token"] = self.config.token
            kwargs["secret"] = self.config.secret
        if self.config.ssl_ca_file:
            kwargs["ssl_ca_file"] = self.config.ssl_ca_file
        return kwargs

    def connect(self) -> "TrustManager":
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        self._client = None

    def __enter__(self) -> "TrustManager":
        return self.connect()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()

    @property
    def client(self) -> Client:
        if not self._client:
            raise RuntimeError("Not connected. Use connect() or context manager.")
        return self._client

    def _api(self, controller: str, command: str, data: dict | None = None, url_params: list[str] | None = None) -> dict:
        params: dict = {"module": "trust", "controller": controller, "command": command, "action": "post"}
        # Search answers only a POST with a body.
        params["data"] = data if data is not None else {}
        if url_params:
            params["params"] = url_params
        return self.client.run_module("raw", params=params).get("result", {}).get("response", {})

    # ── reads ──

    def _search(self, kind: str) -> list[TrustEntry]:
        rows = self._api(kind, "search").get("rows", []) or []
        return [
            TrustEntry(
                uuid=r.get("uuid", ""),
                refid=r.get("refid", ""),
                descr=r.get("descr", ""),
                caref=r.get("caref", ""),
                pem=_decode(r.get("crt", "")),
            )
            for r in rows
        ]

    def cas(self) -> list[TrustEntry]:
        return self._search("ca")

    def certs(self) -> list[TrustEntry]:
        return self._search("cert")

    @staticmethod
    def _named(entries: list[TrustEntry], name: str) -> list[TrustEntry]:
        return [e for e in entries if e.descr == name]

    # ── writes ──

    def ca_ensure(self, name: str, pem: str) -> tuple[str, bool]:
        """The CA called ``name`` holds ``pem``. Returns (refid, changed).

        An existing CA of that name with another certificate is refused: a CA is
        never replaced in place (ADR-043 D9 — a new CA is a new entry)."""
        found = self._named(self.cas(), name)
        if len(found) > 1:
            raise RuntimeError(f"{len(found)} CAs are called '{name}' in the trust store — remove the extra ones by hand")
        if found:
            if found[0].fingerprint != pem_fingerprint(pem):
                raise RuntimeError(f"the trust store's CA '{name}' is another certificate — a CA is never replaced in place")
            return found[0].refid, False
        r = self._api("ca", "add", {"ca": {"action": "existing", "descr": name, "crt_payload": pem}})
        if r.get("result") != "saved":
            raise RuntimeError(f"trust ca add '{name}': {r}")
        return self._refid_of(self.cas(), name), True

    def cert_ensure(self, name: str, pem: str, key: str) -> tuple[str, bool]:
        """The certificate called ``name`` holds ``pem`` and ``key``. Returns (refid, changed).

        A certificate that changed (a renewal) is replaced in place, so its refid —
        what Caddy binds — stays the same."""
        found = self._named(self.certs(), name)
        if len(found) > 1:
            raise RuntimeError(f"{len(found)} certificates are called '{name}' in the trust store — remove the extra ones by hand")
        body = {"cert": {"action": "import", "descr": name, "crt_payload": pem, "prv_payload": key}}
        if found:
            if found[0].fingerprint == pem_fingerprint(pem):
                return found[0].refid, False
            r = self._api("cert", "set", body, [found[0].uuid])
            if r.get("result") != "saved":
                raise RuntimeError(f"trust cert set '{name}': {r}")
            return found[0].refid, True
        r = self._api("cert", "add", body)
        if r.get("result") != "saved":
            raise RuntimeError(f"trust cert add '{name}': {r}")
        return self._refid_of(self.certs(), name), True

    def _refid_of(self, entries: list[TrustEntry], name: str) -> str:
        found = self._named(entries, name)
        if not found or not found[0].refid:
            raise RuntimeError(f"'{name}' was saved but is not in the trust store")
        return found[0].refid
