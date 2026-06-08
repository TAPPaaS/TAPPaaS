# Installing a Variant (multi-tenant) — worked example

A **variant** is an isolated instance of one or more modules for a tenant or
environment, with its own public **domain**, its own dedicated network **zone**,
and its own TLS certificate. See `docs/ADR/ADR-005-variant-domain-architecture.md`
for the design and `docs/Variants.md` for the command reference.

This guide walks one concrete scenario end to end.

## Scenario

You want to host **Nextcloud** and **EURO Office** for a client, isolated from
your own services and from other clients, reachable at the client's domain
**`client1.<your-tappaas-domain>`** (written `client1.tappaas.org` below — replace
`tappaas.org` with your configured domain).

You will create a variant **`client1`** in a dedicated **`client1`** zone, and
install both modules into it. `euro-office` depends on `nextcloud:vm`, so the
variant install of euro-office automatically wires to the **variant's** Nextcloud
(`nextcloud-client1`), not your default one.

Result:

| Module | VM name | Zone | Public URL |
| ------ | ------- | ---- | ---------- |
| nextcloud | `nextcloud-client1` | `client1` | `nextcloud.client1.tappaas.org` |
| euro-office | `euro-office-client1` | `client1` | `euro-office.client1.tappaas.org` |

### Prerequisites

- A working TAPPaaS install (foundation up; default variant `""` registered and,
  if you use it publicly, its wildcard cert issued — see `INSTALL.md` §2.3).
- Run everything below on the **tappaas-cicd** mothership.
- DNS: you control public DNS for `tappaas.org` (and can add records under
  `client1.tappaas.org`).

---

## Step 1 — Register the variant and create its dedicated zone

Pick one DNS/cert mode now (see the **[Appendix: Which certificate should I pick?](#appendix-which-certificate-should-i-pick)**):

- **wildcard** (default): one shared cert + one wildcard DNS entry. Needs a DNS
  provider API for the cert.
- **per-service**: Caddy issues a separate cert per service over HTTP-01. No DNS
  API needed.

```bash
# Wildcard mode (shared *.client1.tappaas.org cert)
variant-manager add client1 --domain client1.tappaas.org \
    --add-zone --from-zone srv --dns-mode wildcard

# …or per-service mode (Caddy issues per-domain certs)
variant-manager add client1 --domain client1.tappaas.org \
    --add-zone --from-zone srv --dns-mode per-service
```

`--from-zone srv` makes the new `client1` zone inherit `srv`'s `type`, `bridge`,
`access-to` and `pinhole-allowed-from` (so it can reach the internet and be
reached by the DMZ reverse proxy). The zone name must be camelCase
(`^[a-z][a-zA-Z0-9]*$`); `client1` qualifies.

**What this changes**

- **configuration.json** — adds the variant under `tappaas.variants`:
  ```json
  "tappaas": { "variants": {
    "client1": {
      "domain": "client1.tappaas.org",
      "tlsCertRefid": "",
      "dnsMode": "wildcard",
      "zone": "client1",
      "description": ""
    }
  }}
  ```
- **zones.json** (`/home/tappaas/config/zones.json` only — never the git source) —
  adds the dedicated zone, VLAN auto-allocated backwards from x99 within the
  Service range, IP derived as `10.<typeId>.<subId>.0/24`:
  ```json
  "client1": {
    "type": "Service", "typeId": "2", "subId": "99",
    "vlantag": 299, "ip": "10.2.99.0/24", "bridge": "lan",
    "state": "Active",
    "access-to": ["internet"], "pinhole-allowed-from": ["dmz"],
    "parent": "srv", "variant": "client1"
  }
  ```
- It then runs `zone-manager --execute` (creates the VLAN interface, DHCP scope
  and rules on OPNsense) and **distributes zones.json to every Proxmox node** so a
  VM can be created in the new zone.

> Add `--vlan <num>` to choose the VLAN explicitly instead of auto-allocation.
> Use `variant-manager show client1` / `variant-manager list` to inspect.

---

## Step 2 — Public DNS

Internal split-horizon DNS (so cluster clients reach Caddy over the DMZ rather
than hair-pinning out the WAN) is handled **automatically** in Step 3 — you only
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
provider. (configuration.json / zones.json are untouched by this step.)

---

## Step 3 — TLS certificate (pick the mode you chose in Step 1)

Not sure which? See the **[Appendix: Which certificate should I pick?](#appendix-which-certificate-should-i-pick)**.

### Option A — Wildcard certificate (dnsMode=wildcard)

One `*.client1.tappaas.org` certificate, shared by every service in the variant,
issued via DNS-01:

```bash
acme-setup.sh --variant client1            # add --staging first to dry-run
```

This issues the wildcard cert on the firewall, and **also** registers the
split-horizon override `*.client1.tappaas.org → DMZ gateway` in **Unbound** so
internal clients resolve the variant's services to the reverse proxy.

**What this changes**

- **configuration.json** — writes the cert reference into the variant:
  `tappaas.variants.client1.tlsCertRefid = "<refid>"`. (For the default variant it
  also mirrors the legacy `tappaas.tlsCertRefid`; for a named variant only the
  variant entry is written.)
- Firewall (not a config file): the cert lands in OPNsense Trust, and an Unbound
  host override `*` / `client1.tappaas.org → <DMZ gateway>` is created.

### Option B — Per-service certificates (dnsMode=per-service)

Do **nothing** here. With `dnsMode=per-service`, each module's `firewall:proxy`
install (Step 4) makes Caddy issue that domain's own certificate via Let's Encrypt
**HTTP-01**, and registers a per-service Unbound split-horizon override
(`nextcloud.client1.tappaas.org → DMZ gateway`). No `acme-setup.sh`, no DNS API —
but the names must be publicly reachable on `:80`.

**What this changes:** `tlsCertRefid` stays empty; the per-service Unbound
overrides are created during Step 4.

---

## Step 4 — Install the two modules into the variant

These Community modules live under `~/Community`. `install-module.sh` reads the
module JSON from the current directory, so `cd` into each module first.

```bash
# Nextcloud first (euro-office depends on it)
cd ~/Community/src/AndreasJe/nextcloud-hub/nextcloud
install-module.sh nextcloud --variant client1

# Then EURO Office — its nextcloud:vm dependency resolves to the VARIANT one
cd ~/Community/src/AndreasJe/nextcloud-hub/euro-office
install-module.sh euro-office --variant client1
```

`install-module.sh` validates the variant is registered, then for each module:

- derives the variant config (vmname `…-client1`, `zone0=client1` from the variant
  registry, `proxyDomain=<module>.client1.tappaas.org`, `variant=client1`);
- creates the VM **in the `client1` zone**;
- wires `firewall:proxy` to the variant's cert (wildcard) or issues one (per-service);
- for `euro-office`, the `nextcloud:vm` dependency **prefers the same variant** —
  it resolves to `nextcloud-client1` (your default Nextcloud is left alone).

**What this changes**

- **configuration.json** — unchanged by the installs themselves (the variant entry
  from Step 1 already holds domain/zone/cert/dnsMode).
- New per-module deployed configs (in `/home/tappaas/config/`, not zones.json):
  `nextcloud-client1.json` and `euro-office-client1.json`, each carrying
  `vmname`, `vmid` (auto-allocated, distinct from your default VMs),
  `zone0: "client1"`, `proxyDomain`, and `variant: "client1"`.
- **zones.json** — unchanged (the `client1` zone already exists from Step 1).
- Firewall: a Caddy domain+handler per service, the `dmz → service:port` pinhole
  (from each module's `ingress`), and the split-horizon Unbound override (wildcard
  from Step 3A, or per-service created here in 3B/4).

---

## Step 5 — Verify

```bash
variant-manager show client1          # domain, zone, dnsMode, cert, module count
variant-manager list                  # all variants at a glance

# External (from anywhere): the client's public URL serves the app over HTTPS
curl -fsSI https://nextcloud.client1.tappaas.org/ | head -1

# Internal split-horizon: cluster clients resolve to the DMZ gateway, not the WAN
getent hosts nextcloud.client1.tappaas.org      # -> the DMZ gateway IP
```

Both `nextcloud-client1` and `euro-office-client1` VMs run in the `client1` zone
(VLAN 299 / 10.2.99.0/24 in the example), isolated from your default services and
from any other client variant.

---

## Removing the variant (clean teardown)

```bash
# Delete the deployed modules first (consumer before provider)
delete-module.sh euro-office-client1
delete-module.sh nextcloud-client1

# Deregister the variant (removes tappaas.variants.client1 from configuration.json)
variant-manager remove client1

# variant-manager does NOT remove the zone. Retire the client1 zone explicitly:
jq '.client1.state = "Inactive"' /home/tappaas/config/zones.json > /tmp/z.json \
    && mv /tmp/z.json /home/tappaas/config/zones.json
zone-manager --no-ssl-verify --execute        # removes the VLAN/DHCP/rules on OPNsense
jq 'del(.client1)' /home/tappaas/config/zones.json > /tmp/z.json \
    && mv /tmp/z.json /home/tappaas/config/zones.json   # drop the zone key
```

`delete-module.sh` removes the VMs, their Caddy entries and (per-service) DNS
overrides. `variant-manager remove` deletes `tappaas.variants.client1` from
configuration.json (it refuses while modules are still deployed unless you pass
`--force`). The two `jq` + `zone-manager` steps deactivate the zone on OPNsense
first (so its VLAN/DHCP/rules are torn down) and then remove the key from the
runtime `zones.json` — the git-tracked source `zones.json` is never touched.

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

The variant registry (`configuration.json`) and zone (`zones.json`) are identical
in both cases — only the cert/DNS mechanics differ.
