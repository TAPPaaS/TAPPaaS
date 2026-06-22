# opnsense-controller

The **OPNsense firewall controller** for TAPPaaS. It drives the OPNsense
firewall over its REST API to converge the network plane onto a desired state:
VLANs/zones, DHCP, split-horizon DNS, the Caddy reverse proxy, NAT
port-forwards, firewall rules, ACME/TLS certificates, and syslog.

It is a single Python package that ships a **family of CLIs**, one per concern.
Each is its own command on `PATH`.

> A long worked-example reference (per-command examples, credential setup,
> port auto-detection) lives in [`CLI-REFERENCE.md`](CLI-REFERENCE.md). This
> README is the overview/index of every command.

| Command | Purpose |
|---------|---------|
| `opnsense-controller` | Low-level example/driver for VLAN, DHCP and firewall managers. |
| `zone-manager` | Reconcile VLANs + DHCP + firewall rules from `zones.json`. The everyday network reconcile. |
| `dns-manager` | DNS host entries in OPNsense Dnsmasq (and static DHCP reservations). |
| `unbound-manager` | Unbound host overrides (split-horizon / internal DNS). |
| `caddy-manager` | The Caddy reverse proxy: domains, handlers, access lists. |
| `nat-manager` | Destination-NAT (port-forward) rules. |
| `opnsense-firewall` | Individual firewall rules (create/list/delete/apply). |
| `rules-manager` | Per-module firewall rules compiled from module JSON + `zones.json`. |
| `acme-manager` | ACME (Let's Encrypt) wildcard certificates via DNS-01. |
| `syslog-manager` | OPNsense built-in syslog destinations. |
| `test-network-manager` | A throwaway isolated test network (create/delete/status). |

## Credentials & common flags

Credentials live in `~/.opnsense-credentials.txt` (token on line 1, secret on
line 2). Most commands share these flags:

- `--firewall <host>` — firewall hostname (default `firewall.mgmt.internal`; env `OPNSENSE_HOST`).
- `--port <n>` / `--api-port <n>` — API port (default: probe 443 then 8443).
- `--credential-file <path>` — override the credential file.
- `--no-ssl-verify` — skip TLS verification.
- `--debug` — debug logging.
- `--check-mode` (most managers) or `--execute` (`opnsense-controller`) — dry-run vs apply.

Most managers **default to dry-run / check mode** and require an explicit apply
(`--execute`, or simply running without `--check-mode`, depending on the
command — check `--help`).

## The commands

### `zone-manager` — VLANs, DHCP and firewall from `zones.json`

Reads `zones.json` and configures VLANs, DHCP scopes and access-based firewall
rules to match. Key flags: `--zones-file`, `--execute` (apply; default is
dry-run), `--interface <if>` (physical interface, default `vtnet1`),
`--vlans-only` / `--dhcp-only` / `--rules-only` / `--no-rules`, `--summary`
(zone summary + pinhole report), `--list-zones`, `--no-assign`,
`--reconcile-labels`, `--skip-health-gate` / `--skip-egress-probe`.

```bash
zone-manager                 # dry-run: show what would change
zone-manager --execute       # apply VLANs + DHCP + rules
zone-manager --summary       # zone summary + which pinholes are allowed
```

### `dns-manager` — Dnsmasq host entries

```
dns-manager add <hostname> <domain> <ip> [--description <d>] [--mac <mac>]
dns-manager delete <hostname> <domain>
dns-manager list
dns-manager check-range <ip>           # exit 1 if <ip> is inside a DHCP pool
```
`--mac` makes the entry a static DHCP reservation (MAC → IP). `--check-mode`
for dry-run.

### `unbound-manager` — split-horizon host overrides

```
unbound-manager add <hostname> <domain> <ip> [--description <d>]
unbound-manager delete <hostname> <domain>
unbound-manager list
```
Use `*` as the hostname for a wildcard override. `--check-mode` for dry-run.

### `caddy-manager` — reverse proxy

```
caddy-manager add-domain <domain> [--description <d>] [--acme-dns | --cert-refid <id>]
caddy-manager add-handler <domain> (--upstream <host> | --redir <url>)
        [--redir-path <p>] [--port <n>] [--description <d>] [--access-list <name>]
        [--upstream-tls] [--upstream-http1] [--preserve-host] [--forward-auth]
caddy-manager add-accesslist <name> --clients <ip,cidr,...>
        [--matcher remote_ip|client_ip] [--invert] [--response-code <n>] [--description <d>]
caddy-manager delete-accesslist <name>
caddy-manager delete-domain <domain>
caddy-manager delete-handler <domain> (--description <d> | --uuid <u>)
caddy-manager list
caddy-manager reconfigure
```
Notable handler flags: `--forward-auth` (route unauthenticated clients to the
identity outpost), `--upstream-tls` (HTTPS upstream), `--upstream-http1` +
`--preserve-host` (needed for some WebSocket apps).

### `nat-manager` — destination-NAT / port-forward

```
nat-manager add --description <d> --external-port <p> --target <ip> --target-port <p>
        [--protocol tcp|udp] [--interface <if>] [--destination <addr>] [--source <addr>]
        [--ip-version inet|inet6] [--disabled] [--no-apply]
nat-manager list-rules [--search <s>]
nat-manager delete-rule (--description <d> | --uuid <u>) [--no-apply]
nat-manager apply
nat-manager test
```
The `--description` is the idempotency key.

### `opnsense-firewall` — individual firewall rules

```
opnsense-firewall create --description <d> --interface <if> [--action pass|block|reject]
        [--direction in|out] [--protocol <p>] [--source <s>] [--destination <d>]
        [--source-port <p>] [--destination-port <p>] [--sequence <n>] [--disabled] [...]
opnsense-firewall list [--search <s>]
opnsense-firewall delete (--description <d> | --uuid <u>) [--no-apply]
opnsense-firewall apply
opnsense-firewall test
```

### `rules-manager` — per-module firewall rules

Compiles a module's firewall rules from its module JSON + `zones.json` +
`aliases.json`.

```
rules-manager add-rules <module>        # compile and apply
rules-manager reconcile <module>        # diff live vs module.json; apply + prune
rules-manager remove-rules <module>     # remove all rules/aliases owned by a module
rules-manager verify-rules <module> [--deep]   # presence (+ connectivity probes)
rules-manager list-rules [--module <m>] [--orphans]
rules-manager create-alias <name> --addresses <a,...> [--type host] [--description <d>]
rules-manager remove-alias <name>
```
Common flags: `--zones-file`, `--aliases-file`, `--modules-dir`, `--check-mode`,
`--output text|json`, `--firewall-type opnsense|NONE`.

### `acme-manager` — wildcard TLS via DNS-01

```
acme-manager setup --domain <d> --email <e> [--provider cloudflare]
        [--provider-field KEY=VALUE ...] [--staging] [--no-include-apex]
        [--dns-sleep <s>] [--timeout <s>] [--key-length key_2048] [...]
acme-manager status --domain <d>
```
`setup` idempotently provisions the LE account + DNS-01 validation +
caddy-reload action and issues a `*.<domain>` certificate.

### `syslog-manager` — syslog destinations

```
syslog-manager add-destination --hostname <h> --description <d>
        [--port 514] [--transport tcp4|...] [--rfc5424] [--level <a,b>] [--facility <...>]
        [--program <...>] [--certificate <uuid>]
syslog-manager delete-destination (--description <d> | --uuid <u>)
syslog-manager list
syslog-manager reconfigure
```

### `test-network-manager` — isolated test network

```
test-network-manager create [--guest-if <dev>] [--gateway <cidr>]
        [--dhcp-start <ip>] [--dhcp-end <ip>] [--mgmt-net <cidr>] [--mgmt-if <if>]
        [--domain test.internal] [--check-mode] [...]
test-network-manager delete
test-network-manager status
```

### `opnsense-controller` — low-level driver

The base CLI used mostly for examples/diagnostics: `--mode vlan|dhcp|firewall`,
`--example <name>`, `--execute` (default is check/dry-run), `--interface`,
`--assign`. Day-to-day work uses the higher-level commands above.
