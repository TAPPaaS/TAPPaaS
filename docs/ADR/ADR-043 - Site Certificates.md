# ADR-043 — Site Certificates

| | |
|---|---|
| **Status** | **Draft** — for the operator's review, nothing built |
| **Version** | 0.1 |
| **Date** | 2026-11-02 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | Unblocks #787 (TLS for logging's syslog and Loki ports, "needs a TAPPaaS CA"). Gives #771 (NFS over TLS) the certificates it needs once its ZFS block is gone. Replaces the "Local DNS mode" build list in `docs/plans/install-simplification-plan.md`. Amends ADR-021 R2 and its unpublished-service table (D5 below), ADR-034 D2 and D10 (D10 below; A15 stays rejected), ADR-012 §2.5.1 (the CA key joins the escrow), ADR-007c (a third `dnsMode`). |
| **Changelog** | v0.1 (2026-11-02) — first draft, from the operator's direction of 2026-11-02: a site CA has two reasons to exist and one implementation; `ca-manager` also holds the DNS providers. |

Every TAPPaaS site gets its own certificate authority at install. It serves two needs with one
implementation: HTTPS for site names that have no public DNS, and trusted encrypted traffic
between modules on `<module>.<zone>.internal`. `ca-manager` becomes the single owner of the site's
certificates, whoever issues them, and the single place to register a DNS provider. How a
published name gets its certificate becomes a choice of issuer, and changing that choice changes
nothing else.

## Context

- **What ACME does today.** Three parts on two levels. `acme_manager.py` (`acme-manager`, in the
  opnsense-controller) drives the firewall's `os-acme-client`: account, DNS-01 validation, a
  wildcard for `*.<domain>` and the apex, and a reload of Caddy on renewal. `acme-setup.sh` is the
  operator's script on top: it reads `~/.acme-dns-credentials.txt` or asks, runs the chain, and
  writes the Trust refid into `config/cert-refids.json`. `environment-manager` reads the refid
  through `acme-manager status`, and calls `acme-setup.sh` when a certificate is missing and
  credentials are on disk.
- **Who actually issues.** Caddy does not get wildcards itself: os-caddy 2.0 locked out DNS
  providers, so `os-acme-client` gets the certificate and `network:proxy` binds its refid to each
  domain as a `CustomCertificate`. In `per-service` mode Caddy issues through HTTP-01 alone, and
  no DNS provider is involved.
- **The credential has no owner.** It is a dotfile that a script reads, and the console's
  `acme-dns` secret writes. One file means one provider per site, though environments can have
  domains at different providers. The dynamic DNS design (#383, `docs/design/dynamic-public-dns.md`)
  wants the same credential for keeping public records current.
- **What was found on lab2, 2026-11-02.** A site with no public DNS works: a site CA, a wildcard
  from it, `cert-refids.json` pointing at it, and an Unbound wildcard to the DMZ gateway. A person
  signed in to Grafana over the admin VPN, by SSO, in Firefox with the CA imported. All of this
  was done by hand, with the CA and its key in the firewall's trust store. Without the CA in a
  guest's trust store, an app's OIDC discovery fails with an unknown-CA error, and the install
  still ended in congratulations. Guests got the CA through `tappaas-site.nix`
  (`site-locale.sh`), which reaches every NixOS guest on its normal rebuild.
- **Internal traffic is cleartext.** Logging's syslog (1514, 1515) and Loki and push ports (3100,
  3101) carry basic-auth credentials in the clear inside the site. ADR-021 says an unpublished
  service has no TLS at all. Issues that need TLS are parked for lack of a CA.

## Decision

### D1. Every site has one CA, always

The CA is not a mode. `ca-manager init` runs in the install, before any guest but the firewall and
the mothership is built, so that every guest has its trust from its first build. A site that will
always use ACME for its public names has a CA too, for its internal names.

The CA is a self-signed root with no intermediate, valid for 10 years, named
`TAPPaaS <site> site CA`. One level is enough: the mothership is the only signer, and an
intermediate on the same machine as the root protects nothing.

### D2. Name constraints limit what the CA can sign

An operator imports this CA into browsers and devices, so a stolen key must not be able to
impersonate an unrelated site. The root carries a critical X.509 Name Constraints extension
permitting only `internal`, `home.arpa`, and the domains of the site's environments at the time it
is made.

A domain added later needs a new CA (D9). That is the cost of the constraint, and it is accepted.
A client that ignores the extension loses this protection, and nothing else.

### D3. The key lives on the mothership, and is escrowed

The private key is a mode-600 file on the mothership, outside `config/`, read only by `ca-manager`.
It joins the backup encryption keys in the escrow, so `backup-manager key export` writes it to the
USB stick and a rebuilt mothership gets the same CA back (ADR-012 §2.5.1). Losing it means every
guest and browser has to trust a new CA.

The mothership already holds the keys to every host, so the CA adds no new class of compromise. The
firewall does not hold the CA key: it is the edge device. It holds the CA's certificate, and the
key of the wildcard it serves.

Not a `step-ca` VM: automatic ACME renewal for guests is attractive, but it is one more machine,
needed before anything else exists and restored before anything else can start.

### D4. `dnsMode` chooses the issuer of published names, and nothing else

| `dnsMode` | Published names issued by | Needs |
|---|---|---|
| `local` (new) | the site CA, a wildcard | nothing public; each client trusts the CA |
| `wildcard` | ACME DNS-01 through `os-acme-client` | a registered DNS provider (D6) |
| `per-service` | ACME HTTP-01 through Caddy | public records, ports 80 and 443 |

Internal names come from the site CA in all three. The refid in `cert-refids.json` means the same
in `local` and `wildcard`, so `network:proxy` needs no new branch for how a route binds its
certificate; `local` only joins `wildcard` in skipping the public DNS check. An explicit
`proxyTls: http01` under a `local` environment is refused: there is nothing public for it to use.

Going public is `environment-manager modify --dnsMode wildcard|per-service`. The CA, guest trust,
internal certificates and every name stay as they are.

`local` is the default for a new site. With no domain given, the domain is `<site>.home.arpa`.

### D5. Internal names get certificates on request

A module declares that it serves TLS on its internal name, and `ca-manager cert issue` makes it a
certificate for `<vmname>.<zone>.internal`, delivered to the VM beside its other secrets. Nothing
changes for a module that does not ask. `.internal` still goes around Caddy and the identity gate,
so this is encryption and trust, not access control.

This amends ADR-021's table: an unpublished service has no TLS **unless its module provides it**.

### D6. `ca-manager` holds the DNS providers

A provider is a named record: its type (the `os-acme-client` plugin), the domains it serves, and
its credential. `ca-manager provider add <name> --type <t> --domain <d>` takes the secret on stdin,
never in an argument. Records are in `config/`; secrets are in a mode-600 file beside the CA key.
`provider test` proves a credential against Let's Encrypt's staging CA, before anything depends on
it. Several providers can exist; a domain has one.

The console's `acme-dns` secret becomes a call to this verb, through the existing secrets path. The
#383 design reads the same record. The credential also has to reach the firewall, because
`os-acme-client` renews there: `ca-manager` puts it there, and says so.

### D7. How the ACME parts fit

| Part | Today | Under this ADR |
|---|---|---|
| `acme-manager` (controller) | drives `os-acme-client` | unchanged: `ca-manager`'s tool for the firewall |
| `acme-setup.sh` | operator script, credential reader, refid writer | a shim calling `ca-manager` for one release, then removed |
| `~/.acme-dns-credentials.txt` | one site-wide credential | moved into a provider record by a migration (ADR-025) |
| `config/cert-refids.json` | written by two callers | kept, with `ca-manager` its only writer |
| `environment-manager` | reads refids, starts issuance | asks `ca-manager`; owns `dnsMode` and the Unbound wildcard, as today |

`ca-manager` follows the manager and controller split: it decides and records, and calls
`acme-manager`, the firewall trust API and `caddy-manager` to act. The wildcard's key reaches the
firewall through the trust API, as it did by hand on lab2.

`environment-manager modify` must work before the identity bootstrap: changing a domain or
`dnsMode` does not need `ownerOrg`.

### D8. One path for trust

`ca-manager` writes `config/site-ca.pem`, holding every CA the site currently trusts (D9).

- **NixOS guests:** `tappaas-site.nix`, as proven on lab2.
- **Debian guests and Proxmox nodes:** `update-ca-certificates`, through `site-locale.sh`.
- **The firewall:** the Trust store.
- **Containers:** a container has its own trust store. Modules mount the host's bundle read-only
  and set the variable their runtime reads (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`,
  `REQUESTS_CA_BUNDLE`). Runtimes that ignore all of these are handled per module (O1).
- **People:** the admin VPN step in Day 1 offers the CA file, with what to do for each browser.

An app whose SSO cannot be wired fails the install. Today that is a warning, and the install then
congratulates the operator on a login that does not work.

### D9. Renewal, rotation, expiry

| | Renewed by | When |
|---|---|---|
| ACME wildcard | `os-acme-client` on the firewall | its own schedule |
| HTTP-01 | Caddy | its own schedule |
| Site CA certificates | `ca-manager cert renew`, in the sweep | 60 days before expiry |

Certificates from the site CA last one year: Apple clients refuse anything over 825 days, and a
year gives every site at least one sweep-driven renewal to prove the path. A site whose sweep stops
gets 60 days of warning, not a sudden outage. `ca-manager status` lists every certificate
whoever issued it, and a health gate raises expiry the same way for all of them.

`ca-manager rotate` makes a new CA, needed for a new domain (D2), near the end of the 10 years, or
after a compromise. Both CAs stay in `site-ca.pem` while guests rebuild and certificates are
reissued; the old one leaves when nothing uses it. Browsers need the new CA imported by hand, and
the verb says so.

### D10. Effect on Day 1

The order Lars confirmed on 2026-11-02 stands: first node, more nodes, VPN, foundation with publish
and sign-in, repositories, switches, Wi-Fi, physical, stacks, and an optional "Make it public".
"Make it public" is D4's change of issuer, and it is where a DNS provider is registered. The TLS
step goes. This replaces ADR-034 D2's and D10's assumption that the console needs a public name
before sign-in.

ADR-034 A15 stays rejected: the console keeps its gated published name, on the same terms in every
`dnsMode`.

## Alternatives

| | Alternative | Why not |
|---|---|---|
| A1 | The CA and its key in OPNsense's trust store (what lab2 runs by hand) | Quick, and the API exists, but it puts the key that every client trusts on the edge device, and a firewall rebuild must restore it. |
| A2 | A `step-ca` VM with ACME for guests | D3. Worth revisiting if many modules need short-lived certificates. |
| A3 | A CA only for `local` sites | Two code paths, and internal TLS would depend on how a site publishes. This is the hack this ADR exists to avoid. |
| A4 | No name constraints | No re-issue when a domain is added, but a stolen key could impersonate any website to every browser that imported the CA. |
| A5 | Keep `acme-setup.sh` and add a separate CA script | Two owners of `cert-refids.json` and of "which certificate does this domain have". |

## Open questions

- **O1. Containers.** Only a NixOS service (Grafana) is proven. Test a container that calls
  Authentik, Immich being the candidate, before the mount in D8 becomes the rule.
- **O2. Browser support for name constraints.** Test Firefox, Chrome and Safari, and iOS and
  Android, with a constrained root on lab2 before D2 is final. `home.arpa` and `internal` in the
  permitted list need the same test.
- **O3. Where a module declares D5**, and which service delivers and reloads the certificate. This
  is a blueprint question (ADR-027); logging is the first case to design from.
- **O4. Existing sites.** A migration adds the CA to hrossen and makerfloss, and guests pick it up on
  their next rebuild. Decide whether the domains they have at that moment are the whole constraint
  list, and whether that migration needs the operator.
- **O5. CMDB.** Whether a certificate is a CI of its own (ADR-040) or only a health check.

## Consequences

- One verb family answers "what certificates does this site have, and who issues them".
- A site can be installed, used and signed in to with no public DNS, and go public later with no
  rename.
- Mothership recovery must restore the CA key, or every client has to trust a new CA. The escrow
  covers this; the restore runbook has to say so.
- A provider token is stored on the mothership and on the firewall.
- `local` asks each operator to import a CA on each device. That is the price of no public
  certificate, and the site loses it by going public.
- More traffic can be verified, so the many `--no-ssl-verify` and `curl -k` calls can go, one at a
  time, starting with the firewall's API certificate.

## Delivery

1. `ca-manager`: `init`, `status`, `cert issue|renew`, with the name constraints tested on lab2 (O2).
2. Trust from `ca-manager` (D8), with the install calling `init`, and the SSO failure made fatal.
3. `dnsMode: local`, the Unbound wildcard, and `environment-manager` working before the bootstrap.
4. Providers (D6), then `acme-setup.sh` as a shim and the credential migration.
5. Day 1 in the new order.
6. #787 logging, as the proof of D5.
7. A fresh lab2 through the whole path, replacing the hand-made CA.

## Testing

- Unit tests for constraint building, the renewal window, and refusal of a name outside the
  constraints.
- A live test on lab2: a fresh install to a Grafana sign-in with no public DNS, then a switch to
  `wildcard` with a test domain, with nothing renamed and internal certificates unchanged.
- A rotation on lab2, with an app staying signed-in-capable throughout.
- A restore of the CA key from the USB stick to a rebuilt mothership.
