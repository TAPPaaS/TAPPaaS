# Appendix C — Adding a satellite

A satellite is a small server with a stable public address that you rent, typically a low cost
EU cloud server, joined to the site by a WireGuard tunnel the site dials out. It is optional.

## When you need one

- **No public address** at the site (CGNAT, a dynamic address, no port forwarding) and you want
  to publish services: the satellite's **reverse-proxy** role passes HTTPS through to the site's
  own reverse proxy. The certificates stay at the site.
- **Your admin VPN from outside** without a public address: the **admin-vpn** role relays it.
- **An off-site backup copy**: the **backup** role keeps a copy of the site's backups that the
  site itself cannot delete.
- **A tie-breaker for a two machine cluster**: the satellite can be the cluster's QDevice
  (`qdevice.sh add <satellite address>` on the management VM).

A site with a public address and backup on another machine needs none.

## 1. Rent the server

1. Create a server with a **stable public IPv4**. At Hetzner Cloud, for example: image
   **Debian 12 or 13**, type `cx23` (or `cax11`, ARM). Note its address and where it is
   (country, city): a backup copy only counts as off-site when it is somewhere else.
2. **Attach your own SSH key**, the one on your computer, not one of the site's. It is your way
   in when the site is down; the install gives the site's management VM its own access.
3. Ask the provider to allow **outbound mail (port 25)** (Hetzner: Limits → port 25, after the
   first invoice). The satellite mails you when the site goes dark; until then its mail waits.

## 2. Add it from the console

On the Day 2 page, **Add a satellite**. The wizard asks for:

- its **address**;
- the **roles** it carries: reverse-proxy and admin-vpn by default (backup comes later, below);
- **where it is**: a location of the site, or a country and city;
- its **name**: empty for the first (`satellite`); a second one needs its own, e.g.
  `satellite-hel1`.

The install logs in to the new server with **your** SSH key, through a forwarded agent. The
console has no agent, so run the install command the wizard shows from a session that has one:

```bash
ssh -A tappaas@tappaas-cicd.mgmt.internal
```

```bash
module-manager module add satellite --address <public-ip> --country FI --city Helsinki
```

It then:

1. creates the site's end of the tunnel on the firewall;
2. sets up the server: WireGuard, its firewall, the reverse proxy and the VPN relay for the roles
   it carries;
3. joins the two ends and adds the firewall rules for the roles;
4. gives the management VM access, so the nightly updates patch the satellite like any other
   machine of the site.

A failed install removes what it made.

## 3. Point your DNS at it

For the **reverse-proxy** role, point your public DNS records for the published names at the
satellite's address. They are in your DNS provider, not in TAPPaaS.

## 4. Check it

The wizard's last step runs the satellite's test: the tunnel, the management VM's login, the
reverse proxy and the relay. From outside the site, a published name should open the service.
With admin-vpn, a device enrolled in the admin VPN now gets the satellite as its endpoint.

## Later

- **Off-site backup:** locking the satellite down as the off-site vault, and making it the
  site's backup copy, is described in the satellite's
  [install reference](../src/foundation/satellite/INSTALL.md#locking-it-down-as-the-off-site-vault).
- **SSH to the management VM through the satellite**, from allow-listed addresses: same
  reference, [SSH through the satellite](../src/foundation/satellite/INSTALL.md#ssh-to-the-mothership-through-the-satellite).
- **Removing it:** `module-manager module delete <name>` forgets it;
  `--decommission` also takes the tunnel and its rules down at the site. The server itself is
  deleted in the provider's console.
