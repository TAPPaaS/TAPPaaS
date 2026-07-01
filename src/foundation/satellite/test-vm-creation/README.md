# satellite/test-vm-creation — reverse-proxy deep test

A disposable **`sat-hello`** module + a `test.sh` driver that exercise the ADR-010
satellite **reverse-proxy** role end-to-end against a live cluster. Modelled on
`tappaas-cicd/test-vm-creation` (install-module → verify → delete-module).

## What it proves

Stands up `sat-hello` (a minimal nginx published via `network:proxy`, bound to the
environment's wildcard cert) and verifies the **full public path through the satellite**:

```
client → satellite:443 (public IP) → WireGuard tunnel → Caddy-on-OPNsense
       → sat-hello VM:80   ⇒   HTTP 200  +  valid Let's Encrypt wildcard cert
```

`test.sh` forces DNS resolution to the satellite's public IP (`curl --resolve`), so the
request traverses the real relay even when run from inside the cluster (where split-horizon
would otherwise resolve the name to the internal DMZ gateway and bypass the satellite).

## Files

| File | Purpose |
| ---- | ------- |
| `sat-hello.json` | module config: `cluster:vm` (2c/4G — enough headroom that `nixos-rebuild` does not OOM) + `network:proxy` (`proxyTls: dns01`, `proxyAllowedZones: [internet]`) |
| `sat-hello.nix`  | full NixOS baseline (incl. `zramSwap`/`oomd`, issue #323) + a trivial nginx on `:80` |
| `install.sh` / `update.sh` | no-op module hooks (nginx is fully declarative) |
| `test.sh` | the deep-test driver (install → probe-through-satellite → teardown) |

## Running

Run from `satellite/test.sh --deep` (preferred), or standalone on the cicd host:

```bash
cd src/foundation/satellite/test-vm-creation
./test.sh --env test4          # explicit environment
./test.sh --skip-delete        # leave the VM up for inspection
```

## Prerequisites (else it SKIPs, exit 0 — not a failure)

- a provisioned **satellite** with the `reverse-proxy` role (`config/satellite-*.json`),
- a **wildcard cert** issued for the target environment (`cert-refids.json`; run `acme-setup.sh`),
- the target **environment** (`config/environments/<env>.json` with `domains.primary`).

Everything here is **disposable** (`vmtag: TAPPaaS,Test`). Safe to delete.
