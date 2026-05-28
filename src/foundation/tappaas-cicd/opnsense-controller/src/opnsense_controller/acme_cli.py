"""TAPPaaS acme-manager CLI — drive os-acme-client end-to-end (issue #254).

Single entrypoint that, given the TAPPaaS domain and the operator's DNS-API
credentials, **idempotently** sets up:

  * an ACME account (Let's Encrypt — prod by default, ``--staging`` for testing),
  * a DNS-01 validation against any os-acme-client-supported provider,
  * a ``configd_reload_caddy`` automation hook (so Caddy picks up renewed certs),
  * a wildcard certificate (``*.<domain>`` + bare apex), and
  * triggers issuance, waits for it, prints the OPNsense Trust **refid** — the
    value ``caddy-manager add-domain --custom-certificate <refid>`` consumes.

Provider is selected with ``--provider`` (default ``cloudflare``); credential
fields with ``--provider-field KEY=VALUE`` (repeatable). Cloudflare example:

    acme-manager setup --domain tapaas.org --email admin@example.com \\
        --provider cloudflare \\
        --provider-field dns_cf_token=<CF_TOKEN> \\
        --no-ssl-verify

For any of the other 120 os-acme-client DNS-API plugins (deSEC, Hetzner, OVH,
Route 53, …) pass the right ``dns_<provider>_<field>`` keys — same flow.

This CLI is normally driven by ``acme-setup.sh``, which prompts for the values
and then exec's this binary.
"""

from __future__ import annotations

import argparse
import os
import sys

from .acme_manager import (
    AcmeAccount,
    AcmeAction,
    AcmeCertificate,
    AcmeManager,
    AcmeValidation,
)
from .config import Config


# Map a friendly --provider name to the os-acme-client `dns_service` key.
# Operators can also pass --provider with a literal `dns_*` key for providers
# not on this list (any of the 120 plugins works).
PROVIDER_ALIASES = {
    "cloudflare": "dns_cf",
    "desec": "dns_desec",
    "hetzner": "dns_hetzner",
    "ovh": "dns_ovh",
    "route53": "dns_aws",
    "aws": "dns_aws",
    "namecheap": "dns_namecheap",
    "namecom": "dns_namecom",
    "godaddy": "dns_godaddy",
    "powerdns": "dns_pdns",
    "njalla": "dns_njalla",
    "inwx": "dns_inwx",
    "gandi": "dns_gandi",
    "he": "dns_he",
}


def _resolve_provider(name: str) -> str:
    if name.startswith("dns_"):
        return name
    if name in PROVIDER_ALIASES:
        return PROVIDER_ALIASES[name]
    raise SystemExit(
        f"unknown --provider '{name}'. Either pass a friendly name "
        f"({', '.join(sorted(PROVIDER_ALIASES))}) or the os-acme-client key "
        f"(e.g. dns_cf, dns_desec, dns_hetzner — see os-acme-client GUI for the full list)."
    )


def _parse_fields(items: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            raise SystemExit(f"--provider-field must be KEY=VALUE, got: {item!r}")
        k, v = item.split("=", 1)
        out[k.strip()] = v
    return out


def cmd_setup(mgr: AcmeManager, args: argparse.Namespace) -> int:
    """Provision the full wildcard-cert chain (idempotent)."""
    domain = args.domain
    wildcard_cn = f"*.{domain}"
    ca = "letsencrypt_test" if args.staging else "letsencrypt"
    dns_service = _resolve_provider(args.provider)
    provider_fields = _parse_fields(args.provider_field)
    if not provider_fields:
        print(
            f"warning: no --provider-field set; os-acme-client may not be able to "
            f"authenticate against {dns_service}",
            file=sys.stderr,
        )

    print(f"==> account ({args.account_name}, CA={ca})")
    account_uuid = mgr.account_ensure(AcmeAccount(
        name=args.account_name, email=args.email, ca=ca,
    ))
    print(f"    uuid={account_uuid}")

    print(f"==> validation ({args.validation_name}, dns_service={dns_service})")
    validation_uuid = mgr.validation_ensure(AcmeValidation(
        name=args.validation_name,
        dns_service=dns_service,
        provider_params=provider_fields,
    ))
    print(f"    uuid={validation_uuid}")

    print(f"==> action ({args.action_name}, type=configd_reload_caddy)")
    action_uuid = mgr.action_ensure(AcmeAction(
        name=args.action_name,
        action_type="configd_reload_caddy",
        description="TAPPaaS: reload Caddy on cert renewal (#254)",
    ))
    print(f"    uuid={action_uuid}")

    print(f"==> certificate ({wildcard_cn}, alt_names={[domain]})")
    cert_uuid = mgr.certificate_ensure(AcmeCertificate(
        name=wildcard_cn,
        account_uuid=account_uuid,
        validation_uuid=validation_uuid,
        restart_action_uuid=action_uuid,
        alt_names=[domain] if args.include_apex else [],
        key_length=args.key_length,
        description=f"TAPPaaS wildcard for {domain} (#254)",
    ))
    print(f"    uuid={cert_uuid}")

    # Pick up the new objects before signing.
    mgr.service_reconfigure()

    print(f"==> sign + wait (timeout={args.timeout}s)")
    mgr.certificate_sign(cert_uuid)
    info = mgr.certificate_wait(cert_uuid, timeout=args.timeout, poll_interval=5)
    print(f"    ✓ issued; refid={info.cert_refid}  status={info.status_code}")

    print()
    print("==> NEXT STEP")
    print(f"    Save the refid in /home/tappaas/config/configuration.json under")
    print(f"    tappaas.tlsCertRefid so caddy_manager can bind it to every")
    print(f"    proxyTls=dns01 domain (the acme-setup.sh wrapper does this for you).")
    print()
    print(f"    refid: {info.cert_refid}")
    return 0


def cmd_status(mgr: AcmeManager, args: argparse.Namespace) -> int:
    """Print the current state of the wildcard cert."""
    wildcard_cn = f"*.{args.domain}"
    rows = mgr._api_get("Certificates", "search").get("rows", [])  # noqa: SLF001
    match = next((r for r in rows if r.get("name") == wildcard_cn), None)
    if not match:
        print(f"no certificate '{wildcard_cn}' configured")
        return 1
    info = mgr.certificate_get(match["uuid"])
    print(f"name        : {info.name}")
    print(f"uuid        : {info.uuid}")
    print(f"statusCode  : {info.status_code}  (200 = issued)")
    print(f"certRefId   : {info.cert_refid}")
    print(f"lastUpdate  : {info.last_update}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="acme-manager",
        description="Drive OPNsense os-acme-client end-to-end (issue #254).",
    )
    # Shared connection args (mirrors the other TAPPaaS CLIs).
    parser.add_argument("--firewall", default=os.environ.get("OPNSENSE_HOST", "firewall.mgmt.internal"))
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--credential-file", default=None)
    parser.add_argument("--no-ssl-verify", action="store_true")
    parser.add_argument("--debug", action="store_true")

    sub = parser.add_subparsers(dest="command", required=True)

    p_setup = sub.add_parser(
        "setup",
        help="Idempotently provision LE account + DNS-01 validation + caddy-reload "
        "action + wildcard cert; sign and wait. Prints the OPNsense Trust refid.",
    )
    p_setup.add_argument("--domain", required=True,
                         help="TAPPaaS domain (cert subject becomes *.<domain>)")
    p_setup.add_argument("--email", required=True,
                         help="Contact email for the ACME account / expiry warnings")
    p_setup.add_argument("--provider", default="cloudflare",
                         help="DNS provider — friendly name (cloudflare/desec/hetzner/...) "
                         "or the os-acme-client key (dns_cf/dns_desec/...). Default: cloudflare.")
    p_setup.add_argument("--provider-field", action="append", default=[], metavar="KEY=VALUE",
                         help="Provider credential field (e.g. dns_cf_token=...). "
                         "Repeatable. Field names match os-acme-client's model.")
    p_setup.add_argument("--account-name", default="letsencrypt", help="ACME account name")
    p_setup.add_argument("--validation-name", default="acme-dns01", help="Validation name")
    p_setup.add_argument("--action-name", default="caddy-reload", help="Action name")
    p_setup.add_argument("--staging", action="store_true",
                         help="Use Let's Encrypt staging CA (untrusted but no rate limits — for testing)")
    p_setup.add_argument("--no-include-apex", dest="include_apex", action="store_false",
                         help="Don't add the bare apex (<domain>) to the cert's SAN")
    p_setup.add_argument("--key-length", default="key_2048",
                         choices=["key_2048", "key_3072", "key_4096", "key_ec_256", "key_ec_384"])
    p_setup.add_argument("--timeout", type=int, default=180,
                         help="Seconds to wait for issuance (default 180)")
    p_setup.set_defaults(handler=cmd_setup)

    p_status = sub.add_parser("status",
                              help="Show the current state of the wildcard certificate")
    p_status.add_argument("--domain", required=True)
    p_status.set_defaults(handler=cmd_status)

    args = parser.parse_args(argv)

    config_kwargs: dict = {
        "firewall": args.firewall,
        "ssl_verify": not args.no_ssl_verify,
        "debug": args.debug,
    }
    if args.port is not None:
        config_kwargs["port"] = args.port
    if args.credential_file:
        config_kwargs["credential_file"] = args.credential_file
    config = Config(**config_kwargs)

    with AcmeManager(config) as mgr:
        return args.handler(mgr, args)


if __name__ == "__main__":
    sys.exit(main())
