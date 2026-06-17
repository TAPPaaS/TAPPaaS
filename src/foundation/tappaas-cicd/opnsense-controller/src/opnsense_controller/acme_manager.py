"""os-acme-client management for TAPPaaS (issue #254).

Drives the OPNsense `os-acme-client` plugin via its REST API to obtain ACME
certificates (typically a single wildcard per TAPPaaS domain) via DNS-01,
independent of the os-caddy DNS-provider lockdown introduced in os-caddy 2.0.0.
The issued certificate lands in OPNsense's System → Trust → Certificates with a
stable refid; ``caddy_manager`` then binds it per-domain via ``CustomCertificate``.

Architecture (proven end-to-end by the PoC under #254):

    ACME account (LE prod)  ──┐
                               ├──> Certificate ── sign ──> Trust store (refid)
    DNS-01 validation         ─┘                                    │
       (provider-agnostic;                                          │
        Cloudflare/deSEC/...)                                       │
                                                                    ▼
    Action (configd_reload_caddy) ─── attached to cert ── reloads caddy on renew

This manager is provider-agnostic: callers pass the DNS-API field names + values
in ``provider_params`` (e.g. ``{"dns_cf_token": "...", "dns_cf_account_id": "..."}``
for Cloudflare; ``{"dns_desec_token": "..."}`` for deSEC). The 120 DNS-API
plugins os-acme-client ships are all addressable this way; the operator-facing
``acme-setup.sh`` wrapper adds a Cloudflare-specific interactive flow on top.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

from oxl_opnsense_client import Client

from .config import Config


# ─────────────────────────────────────────────────────────────────────────────
# Exceptions
# ─────────────────────────────────────────────────────────────────────────────


class PluginDisabledError(RuntimeError):
    """Raised when the os-acme-client plugin is disabled on OPNsense.

    The plugin ships disabled by default. Certificate operations will fail
    with status 400 if the plugin is not enabled first. This exception
    provides a clear, actionable error message guiding the operator to
    enable the plugin via the GUI or API.
    """


# ─────────────────────────────────────────────────────────────────────────────
# Dataclasses
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class AcmeAccount:
    """An ACME account registered with a CA (e.g. Let's Encrypt)."""

    name: str
    email: str
    # ca values defined by os-acme-client: letsencrypt, letsencrypt_test,
    # buypass, buypass_test, google, google_test, zerossl.
    ca: str = "letsencrypt"
    enabled: bool = True


@dataclass
class AcmeValidation:
    """A DNS-01 validation method backed by one of acme.sh's 120 DNS APIs.

    ``dns_service`` is the os-acme-client key for the provider (e.g. ``dns_cf``
    for Cloudflare, ``dns_desec`` for deSEC). ``provider_params`` carries the
    provider-specific credential field names, e.g.::

        AcmeValidation(name="cloudflare", dns_service="dns_cf",
                       provider_params={"dns_cf_token": "..."})
    """

    name: str
    dns_service: str
    provider_params: dict[str, str] = field(default_factory=dict)
    # Seconds acme.sh waits after writing the challenge TXT before triggering
    # Let's Encrypt validation. os-acme-client defaults this to 0, which fires
    # LE immediately — before the DNS provider has propagated the record — so
    # issuance fails with "No TXT record found" (#328). 45s covers the common
    # providers (deSEC, Cloudflare, Hetzner); raise per-provider if needed.
    dns_sleep: int = 45
    enabled: bool = True


@dataclass
class AcmeAction:
    """An automation action fired on cert issuance/renewal.

    For TAPPaaS the canonical action is ``configd_reload_caddy`` which calls
    ``configctl caddy reload`` to swap the in-memory cert (required — the os-caddy
    ``service/reconfigure`` endpoint regenerates the Caddyfile but does NOT
    clear Caddy's cert cache).
    """

    name: str
    action_type: str = "configd_reload_caddy"
    description: str = ""
    enabled: bool = True


@dataclass
class AcmeCertificate:
    """A certificate request handled by os-acme-client.

    ``name`` is the Common Name (typically ``*.<domain>`` for the TAPPaaS
    wildcard); ``alt_names`` adds SANs (e.g. the bare apex). ``restart_actions``
    is a comma-separated list of action UUIDs to fire on renewal.
    """

    name: str
    account_uuid: str
    validation_uuid: str
    restart_action_uuid: str = ""
    alt_names: list[str] = field(default_factory=list)
    key_length: str = "key_4096"  # or key_2048 for faster issuance
    auto_renewal: bool = True
    renew_interval: int = 60
    aliasmode: str = "none"
    description: str = ""
    enabled: bool = True


@dataclass
class AcmeCertInfo:
    """Snapshot of an existing certificate's state from the API."""

    uuid: str
    name: str
    status_code: int   # 200 = issued; 100 = initial; 400+ = error
    cert_refid: str    # the OPNsense Trust store refid (stable across renewals)
    last_update: str
    account_uuid: str
    validation_uuid: str


# ─────────────────────────────────────────────────────────────────────────────
# Manager
# ─────────────────────────────────────────────────────────────────────────────


class AcmeManager:
    """Drive os-acme-client on OPNsense via its REST API.

    Mirrors the DhcpManager pattern: Config-driven, context manager, oxl
    client under the hood. All ``*_ensure`` methods are idempotent.
    """

    def __init__(self, config: Config):
        self.config = config
        self._client: Client | None = None

    # ── connection (mirrors DhcpManager) ────────────────────────────────

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

    def connect(self) -> "AcmeManager":
        self._client = Client(**self._get_client_kwargs())
        return self

    def disconnect(self):
        self._client = None

    def __enter__(self) -> "AcmeManager":
        return self.connect()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()

    @property
    def client(self) -> Client:
        if not self._client:
            raise RuntimeError("Not connected. Use connect() or context manager.")
        return self._client

    # ── raw API helpers ─────────────────────────────────────────────────

    def _api_post(
        self,
        controller: str,
        command: str,
        data: dict | None = None,
        url_params: list[str] | None = None,
    ) -> dict:
        params: dict = {
            "module": "acmeclient",
            "controller": controller,
            "command": command,
            "action": "post",
        }
        if data:
            params["data"] = data
        if url_params:
            params["params"] = url_params
        return self.client.run_module("raw", params=params).get("result", {}).get("response", {})

    def _api_get(
        self,
        controller: str,
        command: str,
        url_params: list[str] | None = None,
    ) -> dict:
        params: dict = {
            "module": "acmeclient",
            "controller": controller,
            "command": command,
            "action": "get",
        }
        if url_params:
            params["params"] = url_params
        return self.client.run_module("raw", params=params).get("result", {}).get("response", {})

    # ── plugin status ──────────────────────────────────────────────────

    def is_plugin_enabled(self) -> bool:
        """Check if the os-acme-client plugin is enabled.

        The plugin ships disabled by default (<enabled>0</enabled> in model.xml).
        Cert operations fail with status 400 if the plugin isn't enabled.
        """
        settings = self._api_get("Settings", "get")
        # The response is {"settings": {"enabled": "0"|"1", ...}}
        enabled = settings.get("settings", {}).get("enabled", "0")
        return enabled == "1"

    def require_plugin_enabled(self) -> None:
        """Verify the plugin is enabled; raise a helpful error if not.

        Call this before any certificate operations to fail fast with a
        clear message instead of the opaque status=400 from os-acme-client.
        """
        if not self.is_plugin_enabled():
            raise PluginDisabledError(
                "The os-acme-client plugin is disabled on OPNsense.\n"
                "\n"
                "To enable it:\n"
                "  1. OPNsense GUI: Services → ACME Client → Settings → Enable plugin\n"
                "  2. Or run: acme-manager enable-plugin (if available)\n"
                "  3. Or via API: POST /api/acmeclient/settings/set "
                '{"settings":{"enabled":"1"}}\n'
                "\n"
                "The TAPPaaS setup-caddy.sh script should have enabled this automatically.\n"
                "If you're seeing this error, the enable step may have failed — check\n"
                "the setup-caddy.sh output or enable the plugin manually via the GUI."
            )

    # ── search helpers (find existing by name; case-sensitive) ──────────

    @staticmethod
    def _find_by_name(rows: list[dict], name: str) -> dict | None:
        for r in rows:
            if r.get("name") == name:
                return r
        return None

    # ── Accounts ────────────────────────────────────────────────────────

    def account_ensure(self, account: AcmeAccount) -> str:
        """Create or update the account, then register with the CA. Returns its UUID."""
        existing = self._find_by_name(
            self._api_get("Accounts", "search").get("rows", []),
            account.name,
        )
        body = {
            "account": {
                "enabled": "1" if account.enabled else "0",
                "name": account.name,
                "email": account.email,
                "ca": account.ca,
            }
        }
        if existing:
            uuid = existing["uuid"]
            self._api_post("Accounts", "update", body, url_params=[uuid])
        else:
            res = self._api_post("Accounts", "add", body)
            uuid = res.get("uuid", "")
            if not uuid:
                raise RuntimeError(f"account add failed: {res}")
        # Idempotent re-register (returns OK either way).
        self._api_post("Accounts", "register", url_params=[uuid])
        return uuid

    # ── Validations (DNS-01) ────────────────────────────────────────────

    def validation_ensure(self, validation: AcmeValidation) -> str:
        """Create or update a DNS-01 validation. Returns its UUID.

        ``provider_params`` are merged into the body verbatim. Callers control
        the exact field names (``dns_cf_token`` for Cloudflare,
        ``dns_desec_token`` for deSEC, etc.) — this manager stays provider-agnostic.
        """
        existing = self._find_by_name(
            self._api_get("Validations", "search").get("rows", []),
            validation.name,
        )
        body = {
            "validation": {
                "enabled": "1" if validation.enabled else "0",
                "name": validation.name,
                "method": "dns01",
                "dns_service": validation.dns_service,
                "dns_sleep": str(validation.dns_sleep),
                **validation.provider_params,
            }
        }
        if existing:
            uuid = existing["uuid"]
            self._api_post("Validations", "update", body, url_params=[uuid])
            return uuid
        res = self._api_post("Validations", "add", body)
        uuid = res.get("uuid", "")
        if not uuid:
            raise RuntimeError(f"validation add failed: {res}")
        return uuid

    # ── Actions (renewal hooks) ─────────────────────────────────────────

    def action_ensure(self, action: AcmeAction) -> str:
        """Create or update an automation action (e.g. configd_reload_caddy)."""
        existing = self._find_by_name(
            self._api_get("Actions", "search").get("rows", []),
            action.name,
        )
        body = {
            "action": {
                "enabled": "1" if action.enabled else "0",
                "name": action.name,
                "type": action.action_type,
                "description": action.description,
            }
        }
        if existing:
            uuid = existing["uuid"]
            self._api_post("Actions", "update", body, url_params=[uuid])
            return uuid
        res = self._api_post("Actions", "add", body)
        uuid = res.get("uuid", "")
        if not uuid:
            raise RuntimeError(f"action add failed: {res}")
        return uuid

    # ── Certificates ────────────────────────────────────────────────────

    def certificate_ensure(self, cert: AcmeCertificate) -> str:
        """Create or update a certificate request. Returns its UUID."""
        existing = self._find_by_name(
            self._api_get("Certificates", "search").get("rows", []),
            cert.name,
        )
        body = {
            "certificate": {
                "enabled": "1" if cert.enabled else "0",
                "name": cert.name,
                "description": cert.description,
                "account": cert.account_uuid,
                "validationMethod": cert.validation_uuid,
                "keyLength": cert.key_length,
                "autoRenewal": "1" if cert.auto_renewal else "0",
                "renewInterval": str(cert.renew_interval),
                "aliasmode": cert.aliasmode,
                "restartActions": cert.restart_action_uuid,
                "altNames": ",".join(cert.alt_names),
            }
        }
        if existing:
            uuid = existing["uuid"]
            self._api_post("Certificates", "update", body, url_params=[uuid])
            return uuid
        res = self._api_post("Certificates", "add", body)
        uuid = res.get("uuid", "")
        if not uuid:
            raise RuntimeError(f"certificate add failed: {res}")
        return uuid

    def certificate_sign(self, uuid: str) -> None:
        """Trigger issuance/renewal for the certificate (background)."""
        self._api_post("Certificates", "sign", url_params=[uuid])

    def certificate_get(self, uuid: str) -> AcmeCertInfo:
        """Read a single cert's current state."""
        d = self._api_get("Certificates", "get", url_params=[uuid]).get("certificate", {})

        def selected(field_name: str) -> str:
            v = d.get(field_name, "")
            if isinstance(v, dict):
                for k, sub in v.items():
                    if isinstance(sub, dict) and sub.get("selected") in (1, "1"):
                        return k
                return ""
            return v or ""

        return AcmeCertInfo(
            uuid=uuid,
            name=d.get("name", ""),
            status_code=int(d.get("statusCode") or 0),
            cert_refid=d.get("certRefId") or "",
            last_update=str(d.get("lastUpdate") or ""),
            account_uuid=selected("account"),
            validation_uuid=selected("validationMethod"),
        )

    def certificate_wait(
        self,
        uuid: str,
        timeout: int = 180,
        poll_interval: int = 5,
    ) -> AcmeCertInfo:
        """Poll until cert is issued (status 200) or timeout. Raises on error/timeout.

        ``poll_interval`` is short because DNS-01 propagation + LE issuance is
        typically <15 s for Cloudflare (PoC observed <10 s).
        """
        deadline = time.time() + timeout
        last: AcmeCertInfo | None = None
        while time.time() < deadline:
            last = self.certificate_get(uuid)
            if last.status_code == 200 and last.cert_refid:
                return last
            if 400 <= last.status_code < 600:
                raise RuntimeError(
                    f"certificate {uuid} ({last.name}) failed: status={last.status_code}"
                )
            time.sleep(poll_interval)
        raise TimeoutError(
            f"certificate {uuid} ({last.name if last else '?'}) did not issue "
            f"within {timeout}s (last status={last.status_code if last else '?'})"
        )

    # ── Service control ─────────────────────────────────────────────────

    def service_reconfigure(self) -> dict:
        """Reconfigure the os-acme-client service (pick up config changes)."""
        return self._api_post("Service", "reconfigure")
