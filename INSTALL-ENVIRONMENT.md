# Installing into an Environment (multi-tenant) — worked example

An **environment** is a per-tenant / per-context **deployment target**: it gives a
set of modules their own public **domain**, their own dedicated network **zone**,
its own DNS/cert mode, and an owning organization. Environments replace the
retired ADR-005 *variant* system — there is no `variant-manager` anymore. See
`docs/design/ADR-007-implementation.md` (package P3 and ADR-007c) for the design.

An environment is just a small JSON file under `config/environments/<env>.json`
(on the target system, i.e. `/home/tappaas/config/`):

```json
{
  "name": "client1",
  "displayName": "Client One",
  "ownerOrg": "client1-company",
  "domains": { "primary": "client1.tappaas.org", "dnsMode": "wildcard" },
  "network": { "zone": "client1" }
}
```

Key fields: `network.zone` (which zone its VMs run in — validated against
`zones.json`), `domains.primary` (the public domain), `domains.dnsMode`
(`per-service` default, or `wildcard`), and `ownerOrg` (a People Organization,
validated). These files are managed by **`environment-manager`** (CRUD,
validate); zones are owned by **`network-manager`** (see
`src/foundation/tappaas-cicd/manager/network-manager/ZONES.md`).

### The always-present environments

Every TAPPaaS system ships two environments, created at install time by
`create-minimal-environments.sh`:

- **`mgmt`** — the management environment (zone `mgmt`); foundation modules live
  here, reached over internal DNS only, so it needs no `domains`.
- **`<system-name>`** (the default environment, named after the installation) —
  where your own services land unless you ask for another environment.

This guide walks one concrete additional environment end to end.

## Scenario

You want to host **Nextcloud** and **EURO Office** for a client, isolated from
your own services and from other clients, reachable at the client's domain
**`client1.<your-tappaas-domain>`** (written `client1.tappaas.org` below — replace
`tappaas.org` with your configured domain).

You will create an environment **`client1`** in a dedicated **`client1`** zone, and
install both modules into it. `euro-office` depends on `nextcloud:vm`, so the
environment install of euro-office automatically wires to the **environment's**
Nextcloud (`nextcloud-client1`), not your default one.

Result (the effective module name gains a `-<env>` suffix for non-default
environments):

| Module | VM name | Zone | Public URL |
| ------ | ------- | ---- | ---------- |
| nextcloud | `nextcloud-client1` | `client1` | `nextcloud.client1.tappaas.org` |
| euro-office | `euro-office-client1` | `client1` | `euro-office.client1.tappaas.org` |

### Prerequisites

- A working TAPPaaS install (foundation up; the `mgmt` + default environments
  exist; if you publish the default environment, its cert is issued — see
  `INSTALL.md`).
- Run everything below on the **tappaas-cicd** mothership.
- DNS: you control public DNS for `tappaas.org` (and can add records under
  `client1.tappaas.org`).

---

## Step 1 — Create the environment and its dedicated zone

Pick one DNS/cert mode now (see the **[Appendix: Which certificate should I pick?](#appendix-which-certificate-should-i-pick)**):

- **per-service** (default): Caddy issues a separate cert per service over
  HTTP-01. No DNS API needed.
- **wildcard**: one shared cert + one wildcard DNS entry. Needs a DNS provider
  API for the cert.

First author the dedicated zone (network-manager owns zones), then create the
environment that references it:

```bash
# A dedicated zone for the tenant, inheriting srv's reachability profile.
network-manager zone add client1 --from-zone srv

# Create the environment file referencing that zone.
environment-manager create client1 \
    --display-name "Client One" \
    --owner-org client1-company \
    --domain client1.tappaas.org \
    --dns-mode wildcard \
    --zone client1
```

`network-manager zone add` authors the zone in `zones.json` **and reconciles all
four planes** (OPNsense interface + DHCP + rules, the Proxmox nodes, the switch,
the WiFi APs) so the new VLAN actually reaches everything. `--from-zone srv`
makes the new `client1` zone inherit `srv`'s `type`, `bridge`, `access-to` and
`pinhole-allowed-from` (so it can reach the internet and be reached by the DMZ
reverse proxy). VLAN is auto-allocated in the type band unless you pass `--vlan`.

**What this changes**

- **`config/environments/client1.json`** — the environment file (`network.zone`,
  `domains.primary`, `domains.dnsMode`, `ownerOrg`).
- **`config/zones.json`** (the live, per-installation file — never the git
  source template) — adds the `client1` zone, then network-manager reconciles the
  planes and distributes `zones.json` to every Proxmox node so a VM can be created
  in the new zone.

> `ownerOrg` must reference an existing People Organization. Use
> `environment-manager list` / `environment-manager get client1` to inspect.

---

## Step 2 — Public DNS

Internal split-horizon DNS (so cluster clients reach Caddy over the DMZ rather
than hair-pinning out the WAN) is handled **automatically** in Step 3/4 — you only
need to set up the **public** records here. Point them at your firewall's WAN IP.

**Option A — wildcard record** (simplest; works with either cert mode):

```
*.client1.tappaas.org   A   <your-WAN-IP>
```

**Option B — dedicated per-service records**:

```
nextcloud.client1.tappaas.org     A   <your-WAN-IP>
euro-office.client1.tappaas.org   A   <your-WAN-IP>
```

For the **wildcard cert** in Step 3 you also need a DNS provider with an ACME API
(e.g. Cloudflare) so `acme-setup.sh` can solve the DNS-01 challenge. The
**per-service cert** path needs the names public on **:80** for HTTP-01 instead.

**What this changes:** nothing in TAPPaaS — these records live at your DNS
provider.

---

## Step 3 — TLS certificate (pick the mode you chose in Step 1)

Not sure which? See the **[Appendix: Which certificate should I pick?](#appendix-which-certificate-should-i-pick)**.

### Option A — Wildcard certificate (dnsMode=wildcard)

One `*.client1.tappaas.org` certificate, shared by every service in the
environment, issued via DNS-01:

```bash
acme-setup.sh --environment client1        # never use --staging (see #329)
```

This issues the wildcard cert on the firewall, and **also** registers the
split-horizon override `*.client1.tappaas.org → DMZ gateway` in **Unbound** so
internal clients resolve the environment's services to the reverse proxy.

**What this changes:** the wildcard cert lands in OPNsense Trust and an Unbound
host override for `client1.tappaas.org → <DMZ gateway>` is created. The cert's
OPNsense **refid** is reconciler-populated runtime state owned by the network/cert
layer — it is **not** written into `environment.json`.

### Option B — Per-service certificates (dnsMode=per-service, the default)

Do **nothing** here. With `dnsMode=per-service`, each module's `firewall:proxy`
install (Step 4) makes Caddy issue that domain's own certificate via Let's Encrypt
**HTTP-01**, and registers a per-service Unbound split-horizon override
(`nextcloud.client1.tappaas.org → DMZ gateway`). No `acme-setup.sh`, no DNS API —
but the names must be publicly reachable on `:80`.

---

## Step 4 — Install the two modules into the environment

These Community modules live under `~/Community`. `install-module.sh` reads the
module JSON from the current directory, so `cd` into each module first.

```bash
# Nextcloud first (euro-office depends on it)
cd ~/Community/src/AndreasJe/nextcloud-hub/nextcloud
install-module.sh nextcloud --environment client1

# Then EURO Office — its nextcloud:vm dependency resolves to the ENVIRONMENT one
cd ~/Community/src/AndreasJe/nextcloud-hub/euro-office
install-module.sh euro-office --environment client1
```

> `--variant` is a **deprecated alias** for `--environment` (kept only until the
> single production site is cut over). New work should use `--environment`.

`install-module.sh` validates the environment exists, then for each module:

- derives the effective module name `<module>-client1` (the `-<env>` suffix is
  added for any non-default environment), sets `zone0` from the environment's
  `network.zone`, and `proxyDomain=<module>.client1.tappaas.org`;
- creates the VM **in the `client1` zone**;
- wires `firewall:proxy` to the environment's cert (wildcard) or issues one
  (per-service);
- for `euro-office`, the `nextcloud:vm` dependency **prefers the same
  environment** — it resolves to `nextcloud-client1` (your default Nextcloud is
  left alone).

**What this changes**

- **`config/environments/client1.json`** — unchanged by the installs (it already
  holds domain/zone/dnsMode/ownerOrg from Step 1).
- New per-module deployed configs (in `/home/tappaas/config/`):
  `nextcloud-client1.json` and `euro-office-client1.json`, each carrying `vmname`,
  `vmid` (auto-allocated, distinct from your default VMs), `zone0: "client1"`,
  `proxyDomain`, and the environment reference.
- **`zones.json`** — unchanged (the `client1` zone already exists from Step 1).
- Firewall: a Caddy domain+handler per service, the `dmz → service:port` pinhole
  (from each module's `ingress`), and the split-horizon Unbound override.

---

## Step 5 — Verify

```bash
environment-manager get client1       # domain, zone, dnsMode, owner
environment-manager list              # all environments at a glance

# External (from anywhere): the client's public URL serves the app over HTTPS
curl -fsSI https://nextcloud.client1.tappaas.org/ | head -1

# Internal split-horizon: cluster clients resolve to the DMZ gateway, not the WAN
getent hosts nextcloud.client1.tappaas.org      # -> the DMZ gateway IP
```

Both `nextcloud-client1` and `euro-office-client1` VMs run in the `client1` zone,
isolated from your default services and from any other client environment.

---

## Removing the environment (clean teardown)

```bash
# Delete the deployed modules first (consumer before provider)
delete-module.sh euro-office-client1
delete-module.sh nextcloud-client1

# Remove the environment file
environment-manager delete client1

# network-manager owns the zone lifecycle: deleting the zone disables it on
# OPNsense (tears down its VLAN/DHCP/rules across all planes) and drops the key.
network-manager zone delete client1
```

`delete-module.sh` removes the VMs, their Caddy entries and (per-service) DNS
overrides. `environment-manager delete` removes `config/environments/client1.json`
(it refuses while modules are still deployed unless you force it).
`network-manager zone delete` deactivates the zone across every plane and then
removes the key from the runtime `zones.json` — the git-tracked source template is
never touched.

---

## Appendix: Which certificate should I pick?

First, two terms that sound alike but are different:

- A **wildcard domain** is a single **DNS** record like `*.client1.tappaas.org`
  that resolves *every* subdomain (`nextcloud.…`, `euro-office.…`) to one address.
  It is about **name resolution**.
- A **wildcard certificate** is one **TLS** certificate whose subject covers
  `*.client1.tappaas.org`, so every service presents the same cert. It is about
  **encryption**. Issuing it uses a DNS-01 challenge, which is why it needs a DNS
  provider API.

They are independent — you can use a wildcard DNS record with per-service
certificates, or per-service DNS records with… per-service certificates. The
choice below is about the **certificate** strategy (Step 3A vs 3B).

| | Wildcard Cert (3A) | per-Service Cert (3B) |
| --- | --- | --- |
| DNS records (Step 2) | wildcard DNS A record | wildcard **or** per-service DNS A records |
| DNS provider API | **required** (DNS-01) | not required |
| Inbound :80 reachable | not required | **required** (HTTP-01) |
| Certs | one shared `*.client1.tappaas.org` | one per service |
| Best when | you have services that need public DNS names but are **not** reachable from the internet | the client's domain has no ACME DNS API |

The environment file (`config/environments/client1.json`) and zone
(`zones.json`) are identical in both cases — only the cert/DNS mechanics differ
(`domains.dnsMode`).

---

## Provider notes & troubleshooting

### DNS provider — deSEC

```bash
acme-setup.sh --environment client1 --provider desec   # reads the token from ~/.acme-dns-credentials.txt
```

- The environment subdomain (`client1.tappaas.org`) is a **plain subname** under the parent deSEC zone
  (`tappaas.org`). Do **not** register it as a delegated child zone — acme.sh writes the
  `_acme-challenge` TXT directly in the parent zone, which resolves and propagates fastest.
- **Never use `--staging`.** os-acme-client keys the ACME account by name; staging flips the single
  shared account to the staging CA, which then breaks production issuance and renewals (see #329).

### Cert fails with `statusCode 400`

The controller only surfaces the status code, and `/var/log/acme.sh.log` stays empty — the real
error is elsewhere:

1. os-acme-client logs to **syslog tag `AcmeClient`** (not `acme.sh.log`).
2. For the actual Let's Encrypt / DNS error, run acme.sh directly with `--debug 2` using the exact
   args from the syslog `AcmeClient: The shell command ...` line. It prints e.g. "Cannot find DNS
   API hook" (#327), "No TXT record found" (dns_sleep, #328), or the LE problem document.

### Guest in the environment zone gets no IP

A new environment VLAN `N` must be carried by **every** L2 layer, not just OPNsense L3.
`network-manager zone add` / `reconcile` drives all four planes (OPNsense, Proxmox, switch, AP),
but if a guest's DHCP DISCOVER never reaches OPNsense (check `netstat -I vlan0.N` Ipkts on the
firewall) the VLAN is being dropped at an L2 layer — most often the firewall VM's Proxmox
`net trunks=` (verify with `qm config <firewall-vmid> | grep ^net`; #335) or a switch/AP trunk
profile (#333). Re-run `network-manager reconcile --apply` to converge the planes.
