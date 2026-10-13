# Dynamic public DNS for wildcard domains (#383) — design

**Status:** proposal, 2026-10-13. Not built: hrossen cannot test it (per-service certificates,
DNS at one.com without an API); the first site to build and test it on is one with a wildcard
domain at a DNS-API provider (makerfloss, or a test domain).

## Problem

A domain in `dnsMode: wildcard` has public `@` and `*` A records pointing at the WAN address,
written once. When the ISP changes the WAN address — a new lease, re-provisioning, a new edge
device — they keep pointing at the old one, and every published name of that domain is
unreachable from outside until someone corrects them by hand. Inbound IPv6 (ADR-030 D9, built)
adds the same problem for the AAAA record: a dynamic WAN's IPv6 address can change too.

## Decision (proposed)

**The firewall keeps the records current, with OPNsense's own dynamic-DNS client.**

- **Where:** `os-ddclient`, which TAPPaaS already installs on every firewall (#254). It runs on
  the firewall, reads the address **from the WAN interface** (no external "what is my IP"
  service), and updates on change and on a timer (`daemon_delay`).
- **What:** one ddclient account per wildcard domain, updating the domain's `@` and `*` records:
  A from the WAN's IPv4 address; AAAA from its IPv6 address when the site runs IPv6
  (`site.json` `ipv6`, and `allowipv6` on the client). The account is TAPPaaS's: named
  `TAPPaaS: <domain>`, so it is reconciled and removed like any other managed object.
- **Credentials:** the DNS-API credential the domain's wildcard certificate already uses
  (DNS-01, `acme-setup.sh`) — one provider, one token per domain. The providers both support:
  Cloudflare, Hetzner, INWX, Gandi, OVH, Porkbun, deSEC (dyndns2). A provider ddclient does not
  support keeps manual records, and the network update says so.
- **Who writes it:** a converge step in the network update (as `ipv6-manager` and
  `unbound-manager dnssec` are): for every environment domain in wildcard mode, the account
  exists and matches; for a domain that left wildcard mode, the account is removed.
- **Per-service domains** (HTTP-01) are unchanged: TAPPaaS writes no public records for them;
  the operator keeps A (and, with IPv6, AAAA) where the domain is hosted.

## What it does not do

- It does not make public records for names TAPPaaS does not publish.
- It does not move DNS hosting, or create zones: the domain's records must already be at a
  provider with an API.
- It does not change split horizon: inside the site, published names still answer the DMZ
  gateway (and its IPv6 address).

## Open points for the operator

1. **The credential's scope.** A DNS-01 token can usually edit TXT records only, or the whole
   zone; ddclient needs A/AAAA write. Either the operator issues a token with both, or a second
   token for ddclient — which is simpler to reason about, but another secret.
2. **Where the credential lives.** On the firewall (ddclient's config) — unavoidable for this
   design — versus only on the mothership today. Acceptable for a credential limited to the
   domain's records.
3. **IPv6 on a dynamic WAN.** With a dynamic WAN the AAAA follows the WAN's IPv6 address
   automatically; with a static one it never changes and the account is still harmless.

## Test plan (on a wildcard site)

1. Create the account through the converge step; check the provider shows `@` and `*` at the
   WAN addresses.
2. Change the record at the provider by hand to a wrong address; ddclient corrects it within
   `daemon_delay`.
3. Switch the domain to per-service; the account is removed, the records stay as they were.
4. With `ipv6: true`, the AAAA records appear and follow the WAN's IPv6 address.
