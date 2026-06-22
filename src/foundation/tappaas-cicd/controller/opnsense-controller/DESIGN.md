# opnsense-controller — design notes

## Language & build

**Python package**, built with nix. `src/` is a setuptools project
(`pyproject.toml`) whose `[project.scripts]` table declares all eleven CLI entry
points. `default.nix` builds two packages:

- `opnsense-api-client` — the upstream OXL OPNsense API client
  (`oxl-opnsense-client`), pinned and fetched from GitHub (not in nixpkgs).
- `opnsense-controller` — this project, depending on the client above.

The default attribute is a Python environment that exposes every CLI on `bin/`.

### Where it is built and linked

Unlike the other controllers, this directory has **no local
`install.sh`/`update.sh`/`test.sh`** — so the parent `controller/` dispatcher
skips it. Instead it is built and linked centrally by the mothership: the cicd
`pre-update.sh` runs `nix-build -A default default.nix` here and then `ln -sf`s
each tool from `result/bin/` into `/home/tappaas/bin/`:

```
opnsense-controller  zone-manager     dns-manager   unbound-manager
caddy-manager        nat-manager      opnsense-firewall
rules-manager        syslog-manager   test-network-manager  acme-manager
```

The package is also imported into `tappaas-cicd.nix` so it is part of the VM's
system closure. The `result` symlink in this directory points at the last
nix build.

## Internal structure

```
src/opnsense_controller/
  config.py            # connection config, credential file, port auto-detect
  log.py               # logging helpers
  main.py              # opnsense-controller (low-level VLAN/DHCP/fw driver)
  zone_manager.py      # zone-manager: VLANs + DHCP + rules from zones.json
  vlan_manager.py      # VLAN primitives
  dhcp_manager.py      # DHCP primitives
  dns_manager_cli.py   # dns-manager (Dnsmasq host entries)
  unbound_cli.py       # unbound-manager (split-horizon overrides)
  caddy_manager.py / caddy_cli.py     # Caddy reverse proxy
  nat_manager.py  / nat_cli.py        # destination-NAT
  firewall_manager.py / firewall_cli.py   # opnsense-firewall
  rules_manager.py     # rules-manager (per-module rules)
  acme_manager.py / acme_cli.py       # ACME wildcard certs
  syslog_manager.py / syslog_cli.py   # syslog destinations
  test_network_manager.py / test_network_cli.py   # test-network-manager
src/test/               # co-located unittest suite + zones.json fixture
```

The split is consistent: a `*_manager.py` holds the API logic against the
OPNsense client, and a `*_cli.py` (or the manager's own `main`) holds the
argparse surface. All write operations are idempotent and the managers default
to check/dry-run mode, applying only when explicitly told to.

## How a manager calls it

The network manager (owner of `zones.json` and the per-module JSON) is the main
caller. It runs `zone-manager --execute` to converge VLANs/DHCP/rules,
`rules-manager reconcile <module>` for per-module firewall rules, and the
single-purpose CLIs (`caddy-manager`, `nat-manager`, `dns-manager`,
`acme-manager`, `syslog-manager`) to converge their respective slices. The
controller owns all OPNsense-API interaction; the manager owns the config and
the decision of what the desired state is.

## Tests

Co-located `unittest` tests under `src/test/` (zone/dhcp/rules/caddy/acme/dns).
They run against fixtures (`src/test/zones.json`) and the built package
environment; they do not require a live firewall. There is no local `test.sh`
verb — the suite is driven from the mothership build/test path rather than the
`controller/` dispatcher.

## Pending / not yet implemented

- **No local verb scripts.** Because build + link happen in the mothership
  `pre-update.sh`, this component is *not* self-contained the way the other
  controllers are (no `install.sh`/`update.sh`/`test.sh` of its own). Adding
  them would make it follow the same pattern as `identity-controller`.
- **VLAN interface assignment** in the low-level `opnsense-controller`
  (`--assign`) is noted as requiring a custom OPNsense PHP extension.
- The pinned `oxl-opnsense-client` relaxes its `ansible-core` dependency
  (nixpkgs ships 2.18.x, the client wants 2.19.x); `ansible-core` is only used
  for module-spec validation, not at runtime.
