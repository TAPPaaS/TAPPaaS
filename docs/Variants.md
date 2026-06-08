# Variants & Domains (ADR-005)

A **variant** is an isolated instance of a module — a separate tenant or
environment — with its own public **domain**, optional dedicated **zone**, TLS
certificate, and DNS mode. Variants are registered in
`/home/tappaas/config/configuration.json` under `tappaas.variants`. The
empty-string key `""` is the **default variant**, used by installs without
`--variant`.

See `docs/ADR/ADR-005-variant-domain-architecture.md` for the full design.

## Bootstrap (default variant)

```bash
# 1. Register the default variant's domain (create-configuration.sh already seeds
#    variants[""] from --domain; verify or set it explicitly):
variant-manager show ""
#    (or, on an older install: migrate-to-variants.sh)

# 2. Issue the wildcard TLS cert for the default domain (Cloudflare example):
#    create a Cloudflare API token with Zone:DNS:Edit + Zone:Read on the parent
#    zone, then:
acme-setup.sh --staging      # dry-run against LE staging
acme-setup.sh                # production: issues *.<domain>, stores the refid in
                             # variants[""].tlsCertRefid, and (wildcard mode)
                             # registers *.<domain> -> DMZ gateway in Dnsmasq
```

## Adding a variant

```bash
# Shared zone (uses the module's own zone0), wildcard DNS:
variant-manager add demo --domain demo.example.com

# Per-service DNS (no DNS API needed — Caddy issues per-domain via HTTP-01):
variant-manager add acme --domain acme-corp.eu --dns-mode per-service

# Dedicated zone (camelCase name; VLAN auto-allocated backwards from x99):
variant-manager add tenant1 --domain t1.example.com --add-zone --from-zone srvHome

variant-manager list           # table of variants (domain / zone / dnsMode / cert / modules)
variant-manager show demo
variant-manager remove demo    # refuses if modules are still deployed (--force to override)
```

For a `wildcard` variant, issue its cert with `acme-setup.sh --variant <name>`.

## Installing a module into a variant

```bash
install-module.sh nextcloud --variant demo
```

- The variant must be registered first (install fails fast otherwise).
- The install produces `nextcloud-demo` (config `nextcloud-demo.json`), with
  `proxyDomain = nextcloud.<variant-domain>`, `zone0` from the variant's zone (if
  any), and `variant = demo` recorded.
- Dependencies prefer the **same variant** (`litellm:api` → `litellm-demo.json`
  first, then `litellm.json`); foundation deps (`cluster:vm`, …) stay
  variant-agnostic.

## DNS modes

| Mode | Cert | DNS | When |
| ---- | ---- | --- | ---- |
| `wildcard` (default) | one `*.<domain>` cert (DNS-01), shared | one `*.<domain>` → DMZ gateway entry (split-horizon) | you control DNS via an ACME-supported provider |
| `per-service` | per-domain cert via HTTP-01 | one `<module>.<domain>` → DMZ gateway entry per module | the domain has no ACME DNS API |

Split-horizon DNS points the public name at the firewall's **DMZ gateway** (where
Caddy listens), derived from `zones.json` — so internal clients reach Caddy over
the DMZ instead of hair-pinning through the WAN (which would trip Caddy's zone
ACL with an HTTP 403). #269.

## OPNsense firewall alias

firewall:rules provisions an alias `tm_<vmname>` per module (≤32 chars). When a
vmname (incl. variant suffix) reaches 28 characters the alias is shortened with a
deterministic hash (`tm_<prefix>_<6hex>`) — collision-free, no manual action
needed.

## Migrating a legacy single-domain install

```bash
migrate-to-variants.sh              # creates variants[""] from tappaas.domain
migrate-to-variants.sh --dry-run    # preview
migrate-to-variants.sh --remove-legacy   # drop tappaas.domain once nothing reads it
```

`tappaas.domain` / `tappaas.tlsCertRefid` remain as backwards-compatible aliases
of `variants[""]`; code reading them directly logs a deprecation warning.
