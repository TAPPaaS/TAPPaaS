# ADR-043 — Site Certificates

| | |
|---|---|
| **Status** | **Draft** — for the operator's review, nothing built |
| **Version** | 0.3 |
| **Date** | 2026-11-02 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | Unblocks #787 (TLS for logging's syslog and Loki ports, "needs a TAPPaaS CA"). Gives #771 (NFS over TLS) the certificates it needs once its ZFS block is gone. Replaces the "Local DNS mode" build list in `docs/plans/install-simplification-plan.md`. Amends ADR-021 R2 and its unpublished-service table (D5 below), ADR-034 D2 and D10 (D10 below; A15 stays rejected), ADR-012 §2.5.1 (the CA key joins the escrow), ADR-007c (a third `dnsMode`), ADR-040 D3 (a `certificate-authority` class). |
| **Changelog** | v0.1 (2026-11-02) — first draft, from the operator's direction of 2026-11-02: a site CA has two reasons to exist and one implementation; `ca-manager` also holds the DNS providers. v0.2 (2026-11-02) — the operator's direction: a domain's subdomains never need a new CA, and an unrelated domain gets a CA of its own. So one internal CA, plus one CA per `local` domain tree; rotation is no longer how a domain is added. v0.3 (2026-11-02) — the operator's direction: CAs are CIs (D11, closes O5 for CAs). |

Every TAPPaaS site gets its own certificate authority at install, for trusted encrypted traffic
between modules on `<module>.<zone>.internal`, and one more for each domain tree that has no public
certificates, for HTTPS on those names. One implementation serves both. `ca-manager` becomes the single owner of the site's
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

### D1. One internal CA, and one CA per `local` domain tree

The site has two kinds of CA, made and held the same way, differing only in what they may sign:

| CA | May sign | Exists | Who trusts it |
|---|---|---|---|
| **Internal CA** | `internal` | always, from the install | every guest, node and the firewall |
| **Domain CA** | one domain and its subdomains | while an environment in that tree is `local` | every guest, node and the firewall, and the people using that domain |

`ca-manager init` makes the internal CA in the install, before any guest but the firewall and the
mothership is built, so that every guest has its trust from its first build. A domain CA is made
when an environment first needs one.

The rule for a new domain CA: **an environment needs one only when it is `local` and its domain is
neither a domain CA's domain nor a subdomain of one.**

| Environment's domain, in `local` | Result |
|---|---|
| `my-org.tld` (the default) | a domain CA for `my-org.tld` |
| `test.my-org.tld` | none: that CA covers it |
| `other-org.tld` | a second, separate domain CA |
| `my-org.tld`, replacing `<site>.home.arpa` | a new domain CA replaces the `home.arpa` one |

Separate trees get separate CAs on purpose. A person who works with `other-org.tld` imports only
that CA, and it can sign nothing for `my-org.tld`.

A site that publishes only through ACME has the internal CA alone, and asks no one to import
anything. Internal names are served to modules, not people, so a browser rarely needs the internal
CA. Replacing a domain leaves the internal CA and every internal certificate untouched.

Each CA is a self-signed root with no intermediate, valid for 10 years, named `TAPPaaS <site>
internal CA` or `TAPPaaS <domain> CA`. One level is enough: the mothership is the only signer, and
an intermediate on the same machine as the root protects nothing.

### D2. Name constraints limit what each CA can sign

An operator imports a domain CA into browsers and devices, so a stolen key must not be able to
impersonate an unrelated site. Every root carries a critical X.509 Name Constraints extension
permitting only what D1's table says. A constraint on a domain covers all its subdomains.

Certificates are a separate matter from CAs: `*.my-org.tld` does not match
`app.test.my-org.tld`, so each environment gets its own wildcard, from the same CA.

A client that ignores the extension loses this protection, and nothing else.

### D3. The key lives on the mothership, and is escrowed

Each CA's private key is a mode-600 file on the mothership, outside `config/`, read only by
`ca-manager`. They join the backup encryption keys in the escrow, so `backup-manager key export` writes it to the
USB stick and a rebuilt mothership gets the same CAs back (ADR-012 §2.5.1). Losing one means
everything that trusts it has to trust a new one.

The mothership already holds the keys to every host, so the CA adds no new class of compromise. The
firewall holds no CA key: it is the edge device. It holds the CAs' certificates, and the keys of
the wildcards it serves.

Not a `step-ca` VM: automatic ACME renewal for guests is attractive, but it is one more machine,
needed before anything else exists and restored before anything else can start.

### D4. `dnsMode` chooses the issuer of published names, and nothing else

| `dnsMode` | Published names issued by | Needs |
|---|---|---|
| `local` (new) | the tree's domain CA, a wildcard per environment | nothing public; each person trusts that CA |
| `wildcard` | ACME DNS-01 through `os-acme-client` | a registered DNS provider (D6) |
| `per-service` | ACME HTTP-01 through Caddy | public records, ports 80 and 443 |

Internal names come from the internal CA in all three. The refid in `cert-refids.json` means the same
in `local` and `wildcard`, so `network:proxy` needs no new branch for how a route binds its
certificate; `local` only joins `wildcard` in skipping the public DNS check. An explicit
`proxyTls: http01` under a `local` environment is refused: there is nothing public for it to use.

Going public is `environment-manager modify --dnsMode wildcard|per-service`. Guest trust, internal
certificates and every name stay as they are. A domain CA with no `local` environment left is
retired (D9).

`local` is the default for a new site. With no domain given, the domain is `<site>.home.arpa`.

### D5. Internal names get certificates on request

A module declares that it serves TLS on its internal name, and `ca-manager cert issue` makes it a
certificate for `<vmname>.<zone>.internal` from the internal CA, delivered to the VM beside its other secrets. Nothing
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

`ca-manager` writes `config/site-ca.pem`, holding every CA the site currently trusts. Guests and
nodes trust them all: a module may call a name in any tree.

- **NixOS guests:** `tappaas-site.nix`, as proven on lab2.
- **Debian guests and Proxmox nodes:** `update-ca-certificates`, through `site-locale.sh`.
- **The firewall:** the Trust store.
- **Containers:** a container has its own trust store. Modules mount the host's bundle read-only
  and set the variable their runtime reads (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`,
  `REQUESTS_CA_BUNDLE`). Runtimes that ignore all of these are handled per module (O1).
- **People:** the admin VPN step in Day 1 offers the CA file of the domain they will use, with what
  to do for each browser. Never the internal CA by default.

An app whose SSO cannot be wired fails the install. Today that is a warning, and the install then
congratulates the operator on a login that does not work.

### D9. Renewal, rotation, expiry

| | Renewed by | When |
|---|---|---|
| ACME wildcard | `os-acme-client` on the firewall | its own schedule |
| HTTP-01 | Caddy | its own schedule |
| Certificates from the site's CAs | `ca-manager cert renew`, in the sweep | 60 days before expiry |

Certificates from the site's CAs last one year: Apple clients refuse anything over 825 days, and a
year gives every site at least one sweep-driven renewal to prove the path. A site whose sweep stops
gets 60 days of warning, not a sudden outage. `ca-manager status` lists every certificate
whoever issued it, and a health gate raises expiry the same way for all of them.

A CA is replaced only when its domain changes, near the end of its 10 years, or after a compromise.
Adding an environment never replaces one (D1). `ca-manager rotate` keeps the old and new CA in
`site-ca.pem` while guests rebuild and certificates are reissued; the old one leaves when nothing
uses it, and a retired domain CA leaves the same way. People need a new domain CA imported by hand,
and the verb says so.

### D10. Effect on Day 1

The order Lars confirmed on 2026-11-02 stands: first node, more nodes, VPN, foundation with publish
and sign-in, repositories, switches, Wi-Fi, physical, stacks, and an optional "Make it public".
"Make it public" is D4's change of issuer, and it is where a DNS provider is registered. The TLS
step goes. This replaces ADR-034 D2's and D10's assumption that the console needs a public name
before sign-in.

ADR-034 A15 stays rejected: the console keeps its gated published name, on the same terms in every
`dnsMode`.

### D11. Each CA is a CI

cmdb-controller's metamodel (ADR-040 D3) gets a class **`certificate-authority`** under
`network-element`, beside `dns-name` and `proxy-route`, through the gate of ADR-022h. `ca-manager`
reports it, as every manager that looks or changes does (ADR-040 D4). Its keys are its name and
its certificate's fingerprint, so a replaced CA is a new CI, and its history stays with the old one.

| Attribute | Meaning |
|---|---|
| `scope` | `internal` or `domain` (D1) |
| `permitted` | the names it may sign (D2) |
| `fingerprint` | SHA-256 of its certificate |
| `notBefore`, `notAfter` | its validity |
| `state` | `active`, `retiring` (D9: a rotation under way, or no `local` environment left) |
| `escrowed` | when its key last reached the USB stick, or none |
| `certificates` | what it has issued: name, `notAfter`, where it is delivered |

| Relation | Example |
|---|---|
| `runs-on` | the CA → the mothership, the node that holds its key |
| `serves` | a domain CA → each `environment` in its tree |
| `depends-on` | a `proxy-route` → the domain CA that signed its certificate; a module's service → the internal CA |

With those relations, health works as for anything else (ADR-041): a CA expiring, or a certificate
of its near expiry with renewal failing, is a condition on the CA, and what depends on it is impact,
not separate root causes. A key never escrowed is a warning on the CA, since losing it costs a new
import on every device.

The private key is never reported, nor is anything derived from it but the certificate's public
fingerprint.

## Alternatives

| | Alternative | Why not |
|---|---|---|
| A1 | The CA and its key in OPNsense's trust store (what lab2 runs by hand) | Quick, and the API exists, but it puts the key that every client trusts on the edge device, and a firewall rebuild must restore it. |
| A2 | A `step-ca` VM with ACME for guests | D3. Worth revisiting if many modules need short-lived certificates. |
| A3 | A CA only for `local` sites | Two code paths, and internal TLS would depend on how a site publishes. This is the hack this ADR exists to avoid. |
| A4 | No name constraints | No new CA for a new domain, but a stolen key could impersonate any website to every browser that imported the CA. |
| A6 | One CA holding `internal` and every domain | One import, but a new unrelated domain would replace the CA for everything, and everyone using one domain would trust a CA that can sign for all of them. |
| A5 | Keep `acme-setup.sh` and add a separate CA script | Two owners of `cert-refids.json` and of "which certificate does this domain have". |

## Open questions

- **O1. Containers.** Only a NixOS service (Grafana) is proven. Test a container that calls
  Authentik, Immich being the candidate, before the mount in D8 becomes the rule.
- **O2. Browser support for name constraints.** Tested 2026-11-03 on a Mac with throwaway
  constrained roots (`internal`, `lab2.hrossen.dk`, `lab2.home.arpa`): OpenSSL 4.1, Node, Python,
  curl, macOS's own verifier (Safari's) and Firefox all accept the permitted names, a wildcard and
  a subdomain environment included, and all refuse names outside them, the parent domain included.
  Firefox reports `SEC_ERROR_CERT_NOT_IN_NAME_SPACE`. Still to test: Chrome, iOS and Android.
- **O3. Where a module declares D5**, and which service delivers and reloads the certificate. This
  is a blueprint question (ADR-027); logging is the first case to design from.
- **O4. Existing sites.** Answered: no operator and no migration. The mothership's pre-update runs
  `ca-manager init`, so an existing site gets its internal CA at its next update, and its guests
  and nodes trust it from then. Neither hrossen nor makerfloss is `local`, so neither gets a domain
  CA. A site whose bundle holds a CA put there by hand (lab2) is refused, not overwritten, until
  that CA is replaced.
- **O5. Certificates in the CMDB.** CAs are CIs (D11). Whether an issued certificate should be a CI
  too, or stay an attribute of its CA, and how an ACME certificate appears, which has no CA CI.

## Consequences

- One verb family answers "what certificates does this site have, and who issues them".
- A site can be installed, used and signed in to with no public DNS, and go public later with no
  rename.
- Mothership recovery must restore the CA keys, or every client has to trust new CAs. The escrow
  covers this; the restore runbook has to say so.
- A provider token is stored on the mothership and on the firewall.
- `local` asks each person to import their domain's CA on each device. That is the price of no
  public certificate, and going public ends it.
- A site with several unrelated `local` domains has several CAs to escrow and to watch.
- More traffic can be verified, so the many `--no-ssl-verify` and `curl -k` calls can go, one at a
  time, starting with the firewall's API certificate.

## Delivery

1. `ca-manager`: `init`, `status`, `cert issue|renew`, both kinds of CA, with the name constraints
   tested on lab2 (O2).
2. Trust from `ca-manager` (D8), with the install calling `init`, and the SSO failure made fatal.
3. `dnsMode: local`, the Unbound wildcard, and `environment-manager` working before the bootstrap.
4. Providers (D6), then `acme-setup.sh` as a shim and the credential migration.
5. Day 1 in the new order.
6. #787 logging, as the proof of D5.
7. A fresh lab2 through the whole path, replacing the hand-made CA.

## Findings from the lab2 replacement, 2026-11-03

lab2's hand-made CA was replaced through steps 1 to 3: `ca-manager init --replace-bundle`, both
environments set to `local`, `environment-manager reconcile --apply`, then the modules updated.
Every name then served a wildcard from `TAPPaaS lab2.hrossen.dk CA`, and the old entries were
removed from the firewall. It needed four things by hand, each a gap to close:

- **The mothership must trust a new CA before the modules' tests run.** A CA added outside the
  sweep left it trusting only the old bundle, and the console's test failed with HTTP 000. It
  needed `tappaas-render-fragments.sh` and `tappaas-rebuild@tappaas-cicd`.
- **A new refid needs a reload of Caddy.** The routes were rebound, but Caddy served its cached
  certificate until `configctl caddy reload`.
- **Every route on the domain must move together.** `network` was not updated and kept the old
  refid, so two certificates for `*.<domain>` were loaded at once. A change of refid should
  update every module on that domain.
- **The old trust entries are ca-manager's to retire.** They were deleted by hand once no route
  used them.

Logging's update failed once on the way, its OIDC setup meeting Caddy's cached certificate, and
passed when rerun after the reload.

All four are closed, and proven on lab2 the same day: a throwaway TAPPaaS certificate bound to
the `network` route was moved off by `ca-manager wildcard`, Caddy reloaded, and the throwaway
removed while its CA, still signing, stayed; a throwaway domain CA rebuilt the mothership, which
then trusted it, and rebuilt again when it was removed. How it works: a new CA rebuilds the mothership (`--no-rebuild`
for the install and the update, which rebuild anyway); a changed refid moves every route with
`caddy-manager rebind-certificate`, reloads Caddy, and retires the old certificate with
`trust-manager cert-retire`, which removes only what TAPPaaS made and nothing still served.

## Progress, 2026-11-03

| Step | State |
|---|---|
| 1 `ca-manager` | built and proven on lab2: `init`, `domain add`, `cert issue|renew`, `wildcard`, `status`, `validate`, `report` |
| 2 trust, `init` in the install, SSO failure fatal | built; the Debian and node path is unproven on a real host |
| 3 `dnsMode: local` | built and proven on lab2; a new site defaults to it, with `<site>.home.arpa` when no domain is given (unproven until a fresh install) |
| D11 CAs in the CMDB | built: `certificate-authority` CIs; `depends-on` relations and `escrowed` still to do |
| 4 providers, `acme-setup.sh` shim | built: `provider add|list|for|remove`, `acme`, the shim, migration 0029, the console's form; not run against a real DNS provider, and `provider test` not built |
| 5 Day 1 order | not started |
| 6 #787 logging TLS | not started |
| 7 fresh lab2 | not started |

## Testing

- Unit tests for D1's rule, constraint building, the renewal window, and refusal of a name outside
  a CA's constraints.
- A live test on lab2: a fresh install to a Grafana sign-in with no public DNS, then a second
  environment on a subdomain (no new CA) and one on an unrelated domain (a CA of its own), then a
  switch to `wildcard` with a test domain, with nothing renamed and internal certificates unchanged.
- A rotation on lab2, with an app staying signed-in-capable throughout.
- A restore of the CA keys from the USB stick to a rebuilt mothership.
