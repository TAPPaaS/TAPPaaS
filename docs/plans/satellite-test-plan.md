# `satellite` as a module — test plan (#671)

Primary audience: whoever verifies ADR-010 §8.4 (the satellite as a module, #670) end to end.
Test site: **hrossen**, which runs `main`. Nothing here runs on makerfloss: converting its
existing satellite is #775.

## What is being tested

#670 retired `satellite-manager`: the satellite is now a module like any other.
`module-manager module add satellite …` provisions a Debian VPS over the operator's key, the
nightly sweep patches it, `module test satellite` checks it, `module delete` removes it. This
plan proves that against a real VPS with a public IPv4, every role, and the backup and lockdown
paths. Each phase ends with its own teardown, so a failure leaves nothing half-built.

## Decisions this plan rests on (operator)

| # | Question | Default proposed here |
|---|---|---|
| D1 | Which VPS | a fresh Hetzner Cloud **`cx23`**, **Debian 13**, the operator's own SSH key attached (not a `tappaas-cicd` key) — created by the operator, not by TAPPaaS (Tier B, an API token, is not exercised) |
| D2 | A volume for the PBS phase | a **20 GB** Hetzner volume attached to the same VPS, used only in phase 4 |
| D3 | A public name for the reverse-proxy check | one DNS record the operator creates, e.g. **`sat-test.hrossen.dk`** → the VPS's IPv4. hrossen's real names are **not** moved: hrossen has a public IP of its own, and its ingress must keep working throughout |
| D4 | Moving hrossen's backups onto the satellite (phase 4) | **yes, temporarily**: placement to the satellite for one backup run and one restore, then back home. hrossen's existing backups on its home PBS are not touched |
| D5 | Lockdown (phase 5) | the **same** VPS, after phase 4 moves placement home — a second VPS is not needed |
| D6 | Cost and lifetime | the VPS and volume exist for the test only, and are deleted by the operator in the provider console after phase 6 |

## Test bed

| Item | Value |
|---|---|
| VPS | `<public-ip>`, Debian 13, `cx23`, location recorded as `--physicalLocation '{"country":"…","city":"…"}'` |
| Instance name | `satellite` (hrossen has none today) |
| Operator key | the operator's agent, forwarded: `ssh -A cicd-hrossen` |
| Public test name | `sat-test.hrossen.dk` (D3) |
| Home side | hrossen's OPNsense: `tappaas-edge-satellite` (the `edge` zone's `/31`), peer `tappaas-satellite` |

## Phase 1 — add, managed

`module-manager module add satellite --address <ip> --physicalLocation '{…}'`, over `ssh -A`.

Expected:

- `config/satellite.json` with `moduleSource`, `management: managed`, `physicalLocation`, and
  the operator key recorded as `host.operatorSshKeys` (never the mothership's own key);
- OPNsense: the tunnel server and the peer `tappaas-satellite`, a handshake under 5 minutes;
- `satellite.mgmt.internal` → `10.255.0.0`, and the mothership logs in there by its own key;
- the `edge` rules for both roles present, and nothing else in `edge` changed;
- `module list --resolution` resolves it; `module test satellite` green (the `debianhost`
  checks included);
- reverse-proxy: `https://sat-test.hrossen.dk` from **off-LAN** (a phone on mobile data) is
  served by Caddy at home **through the satellite** — and hrossen's own names still resolve to
  and are served from its own address.

Refusals: a second `module add` for the same instance; an `add` while OPNsense already has this
tunnel (must name `--decommission`); an unreachable address (nothing written).

Teardown: none — phase 2 builds on it.

## Phase 2 — patched by the sweep

- `update-module.sh satellite` (and the nightly sweep) runs apt on it, in the update unit's
  context (`tappaas-unit-run.sh`), not from a console;
- a pending reboot is **deferred** without `rebootOk`, taken with it;
- unattended-upgrades stays off; key-only SSH stays on (#756).

## Phase 3 — admin VPN

- `network-manager wgvpn setup` twice: the second run changes nothing;
- `wgvpn add-peer --name test-laptop --pubkey …`: the printed `Endpoint` is the satellite; the
  laptop, **off-LAN**, reaches a node's `:8006`, the OPNsense UI and SSH;
- `wgvpn remove-peer test-laptop`: the laptop is cut off at once.

Teardown: the test peer removed; `wgvpn list` as before the phase.

## Phase 4 — the satellite as the Site's PBS (D2, D4)

1. On the VPS, as root: `zpool create tankc1 /dev/sdb` on the attached volume.
2. Placement to the satellite (`placementState: node`, `node: satellite`); the backup module
   installs PBS there. The PBS name is a CNAME of the satellite.
3. One backup run: the nodes push **through the tunnel**; the backups are encrypted (#760).
4. Restore one small guest from it, beside the original (VMID in `900–999`, no network), and
   compare.
5. `backup-manager validate` warns that no locked-down buddy exists.

Teardown: the restored guest destroyed; placement back home; hrossen's next backup run lands on
its home PBS again. The satellite's PBS datastore stays for phase 5.

## Phase 5 — lockdown (D5)

`--lockdown` on the same satellite, now that it is no longer the placement node:

- it pulls hrossen's home PBS (one sync run);
- the mothership's SSH and home-initiated PBS administration are **refused**;
- `management: unmanaged` recorded; the sweep skips it; `module test satellite` still reports
  the last pull, from OPNsense;
- a home credential **cannot** delete a snapshot on it;
- lockdown is **refused** while the satellite is the placement node (checked before step 1 by
  attempting it during phase 4).

## Phase 6 — delete and decommission

- `module delete satellite`: unregistered; the tunnel stays up;
- `module delete satellite --decommission`: the OPNsense peer and tunnel server, the edge rules
  (when no other satellite needs them) and the DNS records go; **the VPS itself is untouched**;
- leftover check: no `tappaas-edge-satellite`, no `edge` rule for it, no `satellite.mgmt.internal`,
  no `config/satellite.json`, no wgvpn peer pointing at it.

Then the operator deletes the VPS, its volume and the `sat-test` DNS record (D6).

## makerfloss's `satellite1` — not in this plan

Converting makerfloss's existing satellite (ADR-010 §8.4.7) is **#775**, split out on
2026-10-05: it can only happen once makerfloss runs a release containing #670 (2.2), and it must
not hold this test open. #775 reuses phases 1 and 2's checks against `satellite1`.

## Seen during preparation (2026-10-05)

makerfloss lost all three nodes on 2026-10-03 at 11:45–11:53 (no clean shutdown on any; a power
loss, most likely) and stayed down for two and a half days. Nothing reported it: the alerting of
#126, the sweep and its failure mail all run inside the cluster that was down. Only a heartbeat
watched from **outside** the site catches that — the satellite is the natural place. That is
#776, not part of #671 — but this test's satellite is where it will first be exercised.

## Done when

Phases 1–6 green on hrossen with their teardowns run, and the results recorded below.

## Results

| Phase | Date | Result |
|---|---|---|
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |
| 6 | | |
