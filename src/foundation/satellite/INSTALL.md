# satellite — Installation

Primary audience: TAPPaaS admin.

> **When do I need this?** Only if your site has **no usable public IP** (CGNAT, dynamic
> IP, no inbound port-forwarding) and you want to publish services, reach the management
> plane remotely, or hold an off-site backup. A site with a real public IP does **not**
> need a satellite. This step is **optional** — the TAPPaaS install never runs it.

The satellite is a module like any other (ADR-010 §8.4): `module-manager module add`
creates it, the nightly sweep patches it, `module-manager module test` checks it. Design
reference: [ADR-010](../../../docs/ADR/ADR-010-vps-satellite-reverse-proxy-backup.md).

## Prerequisites

1. A running TAPPaaS foundation (`network` + `tappaas-cicd`).
2. Decide which **roles** you need: `reverse-proxy` (public HTTPS ingress) and/or
   `admin-vpn` (relay for the admin VPN). Both are the default.
3. Allocate a host with a **stable public IPv4** and root SSH — in the Hetzner Cloud
   console, for example:
   1. Create a server: image **Debian 12 or 13**, type **`cx23`** (x86, cheapest current
      line; `cax11` is the ARM alternative).
   2. **SSH key — attach your OPERATOR key (your workstation), not a `tappaas-cicd`
      key.** It is your out-of-band access; the install authorizes the mothership's key
      itself.
   3. Note its **public IP**, and where it is (country, city).

> Tier B (opt-in): a Hetzner **API token** lets TAPPaaS create the server through the
> `hcloud` API. The token can create **and destroy** servers — see ADR-010 §7.3 first.

## Install

Log in to `tappaas-cicd` with your agent forwarded (`ssh -A`) — the install reaches the new
host with your operator key — then:

    module-manager module add satellite \
        --address <public-ip> \
        --physicalLocation '{"country":"FI","city":"Helsinki"}'

- **Instance name:** `satellite` (config `~/config/satellite.json`). A second satellite
  needs `--instance <name>`, e.g. `--instance satellite-hel1`. The install also registers
  `<name>.mgmt.internal` at its tunnel end, `10.255.0.0`.
- **Roles:** `reverse-proxy` and `admin-vpn` by default; one of them only with
  `--roles '["reverse-proxy"]'`. The `backup` role is not given here — it comes with
  locking the satellite down as the vault (below).
- **`--physicalLocation` (#609):** where the satellite physically runs. A backup copy is
  only off-site if it is somewhere else, and only this record shows it:
  `backup-manager validate` compares it with `site.json`'s `location`. Give the city when
  the Site is in the same country.
- **Operator key:** recorded from your forwarded agent (`ssh-add -L`) as
  `host.operatorSshKeys`; set `TAPPAAS_OPERATOR_KEY` (a key or a `.pub` file) instead when
  the agent holds other keys too. The mothership's own key is never recorded as one.

The module then:

1. Creates the home end of the tunnel on OPNsense (`tappaas-edge-<name>`, the `edge` zone's
   `/31`).
2. Provisions Debian on the host over your key: WireGuard, the host firewall, nginx for
   `reverse-proxy`, the UDP relay for `admin-vpn` (see `debian/README.md`).
3. Reads back the satellite's WireGuard **public** key (its private key never leaves it)
   and adds the peer `tappaas-<name>` on OPNsense, which dials out to it.
4. Adds the role-gated `edge` firewall rules.
5. **Authorizes the mothership's key** — the satellite is `managed`: the nightly sweep
   patches it like any Debian machine (`debianhost`), reboots only when `rebootOk` or
   `--allow-disruption` allows. Unattended-upgrades stays off.

A failed install removes the config it wrote. If OPNsense already has this satellite's
tunnel, the install refuses: take it down first with `--decommission` (below).

Point your public DNS records at the satellite's address yourself — they are in your DNS
provider, not in TAPPaaS.

## Verification

    module-manager module test satellite

| Check | Expected |
|-------|----------|
| `module test` | OPNsense server + peer present, the mothership logs in, tunnel handshake under 5 minutes, nginx active (reverse-proxy), relay rules loaded (admin-vpn), the `debianhost` checks green |
| reverse-proxy: browse a published name from off-LAN | resolves to the satellite, served by Caddy at home |
| admin-vpn: `network-manager wgvpn add-peer --name <device> --pubkey <key>` | the printed config's Endpoint is the satellite; the device reaches a node `:8006`, the OPNsense UI and SSH |

## The satellite as the Site's PBS

A Site with no PBS of its own (the backup module a **shim**) can put it on a managed
satellite: the nodes push their backups to it through the tunnel (ADR-010 §8.4.3).

1. Attach a volume to the VPS in the provider's console, and make a ZFS pool on it named
   `tankc…` (e.g. `zpool create tankc1 /dev/sdb` as root on the satellite) — the same rule
   the backup module applies to every PBS Host.
2. Point the backup module at the satellite and update it:

       module-manager module modify backup --set node=<instance>

   The update finds the pool, installs the official PBS on the satellite, opens the nodes'
   path — an OPNsense rule `mgmt → 10.255.0.0:8007`, and the satellite's tunnel and firewall
   admitting the mgmt subnet to `:8007` only — points `backup.mgmt.internal` at
   `<instance>.mgmt.internal` (the tunnel end, `10.255.0.0`), and registers the storage.
   The sweep keeps the path open while the satellite is the PBS Host, and closes it after.

This is then the Site's **only** copy, and home can reach it: `backup-manager validate` warns
until something home cannot reach pulls it — a second satellite, locked down (below), or a
backup buddy (`backup-manager peer add remote …`). A satellite that is the PBS Host cannot
itself be locked down, and cannot be decommissioned until the PBS is moved.

## Locking it down as the off-site vault

A managed satellite can become the Site's **off-site backup vault**: it pulls the Site's PBS,
and nothing at home can log in to it or delete its copy — the property ADR-010 §7.3 exists
for. This is one-way:

    module-manager module modify <instance> --lockdown

It needs a PBS of the Site's own (backup placement `node`) to pull, an operator key recorded
on the satellite, and the satellite must not be the Site's PBS Host itself. Then, over the
mothership's key:

1. On the Site's PBS: a read-only login `<name>@pbs`, granted like any `remote` peer —
   `DatastoreReader` on the root namespace, not propagated, so `fs/` (config and secrets) and
   other peers' data stay out of reach (`backup-manager peers` lists it).
2. On OPNsense: `edge → <PBS>:8007`, so the satellite reaches the PBS through the tunnel.
3. On the satellite: the official PBS, a datastore (`/srv/pbs/tappaas-offsite`), a daily pull
   (`--remove-vanished false`: home deleting a snapshot never deletes the copy) and the vault's
   own prune; security-only unattended-upgrades; and **last**, the mothership's key removed.
4. It checks the mothership can no longer log in, then records `management: unmanaged`,
   `roles` + `backup`, and `vault.pull`.

A failure before the last step leaves a managed satellite: fix the cause and run
`--lockdown` again. Afterwards the sweep skips it, `module test` checks it from OPNsense
only, and only your operator key reaches it. Returning it to managed is by hand, on the
machine, with that key.

## Removing it

- `module-manager module delete <instance>` **unregisters** it, like any machine: the tunnel
  stays up and nothing is touched.
- `module-manager module delete <instance> --decommission` also takes the Site's side down:
  the OPNsense peer and tunnel server, a vault's read access to the Site's PBS, and the
  `edge` rules when no other satellite needs them. **The machine itself — and any copy a
  vault holds — is never touched**: delete it in the provider's console.

## Converting an existing satellite

A satellite set up with the retired `satellite-manager` is `config/satellite-<name>.json`,
`status: external`. Migration 0008 already recorded its `moduleSource`. To make it a managed
module (ADR-010 §8.4.7), on `tappaas-cicd`:

1. Rename it, keeping the name so the OPNsense peer and tunnel keep theirs:
   `mv ~/config/satellite-<name>.json ~/config/<name>.json`
2. Record its address and management, drop the stop-gap status, add where it is:

       jq '.address = .host.publicIp | .management = "managed" | del(.status)
           | .physicalLocation = {"country":"FI","city":"Helsinki"}' \
           ~/config/<name>.json > /tmp/sat.json && mv /tmp/sat.json ~/config/<name>.json

3. Authorize the mothership's key on it, from your workstation:
   `ssh root@<address> "cat >> ~/.ssh/authorized_keys" < <(ssh tappaas@<cicd> cat .ssh/id_ed25519.pub)`
4. Check: `module-manager module list --resolution` names it `satellite`, and
   `module-manager module test <name>` is green. From then on the sweep patches it.

## Where does this fit in the TAPPaaS install?

The main install does **not** run this. At the *"does this site need a satellite?"*
decision point (after `network` and `tappaas-cicd`), the install guide points here.
