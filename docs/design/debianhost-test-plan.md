# `debianhost` and `module adopt` — test plan

Primary audience: whoever builds and verifies ADR-026 D3 (`debianhost`) and D8 (`module adopt`,
`module add --pxe`). Test site: **hrossen**. Nothing here runs on makerfloss.

## Decisions this plan rests on (operator, 2026-09-18)

- **Order:** `debianhost` + `module adopt` come **before** #665. Phases 1–4 need nothing from
  #665, and #665 can then register the cluster nodes *through* `adopt`.
- **`adopt` logs in as `root`** with the mothership's key — the same as the cluster nodes, and
  what `apt` needs anyway.
- **Key-only SSH (#19) is a separate, explicit step**, never a side effect of `adopt`: a
  hand-built machine may be someone's only way in by password.

## Test bed

| VM | VMID | Made by | Stands in for |
|---|---|---|---|
| `dh-test1` | 990 | `qm create` over SSH on a node; Debian 13 cloud image; cloud-init sets hostname `dh-test1` and a static address in `mgmt` (10.0.0.0/24) | a machine that already runs (phases 1–4, 6) |
| `dh-test2` | 991 | `qm create` with network boot first and an empty disk | a bare machine (phase 5) |

- VMIDs from the test range `900–999` (`src/module-catalog.json` `vmidConventions`); hrossen uses
  none of it.
- Neither VM gets a `config/*.json` when it is created: to TAPPaaS they are machines it has
  never heard of. 1 core, 1–2 GB RAM, 10 GB disk.
- To Proxmox they are VMs; for the test they are machines. `adopt` only speaks SSH to them, and
  the plan checks that nothing reaches for `qm` on them.
- Teardown is `qm destroy` plus removing the config. Every phase can start over from a fresh VM.

## Phase 1 — `module adopt`, happy path

`module-manager module adopt 10.0.0.90`, twice:

1. with the mothership's key **pre-seeded** by cloud-init (as if the operator ran the printed command);
2. with **no key** — `adopt` must print the one command that authorises it, and wait.

Expected afterwards:

- `config/dh-test1.json`, named after the machine's hostname (ADR-026 D8.1 step 4);
- `.moduleSource` → the `debianhost` module, so `module_of dh-test1` = `debianhost` (D6.3);
- `kind: machine`, `os: debian` (ADR-022f D7 as built: the family is derived), `zone0: mgmt`
  (from the address), `management: managed`, and **no** `vmname`;
- `debianhost`'s `install.sh` ran and verified;
- the instance appears in `module-manager module list`, **with its module shown** — an
  instance named after a machine must be recognisable as a `debianhost`.

## Phase 2 — `module adopt`, refusals

| Case | Expected |
|---|---|
| `config/dh-test1.json` already exists | refused, naming the conflict; `--instance dh-test1b` succeeds |
| the machine does not authorise the key | prints the command, waits, stops on timeout; **nothing written** |
| an Ubuntu VM (`os.id: ubuntu`) | refused: no machine module for that OS (ADR-026 D7) — no near match |
| an address in no zone | refused, naming the choice (off-site Location, or outside the Administrative Domain); `--zone` overrides. **Unit-tested** — an unreachable VM proves nothing live |
| a cluster node's address | refused, or directed to #665 — never adopted as a plain `debianhost` by accident |
| run twice | the second run changes nothing |

## Phase 3 — lifecycle

- **`update`** — install an older version of a package first, so `apt upgrade` has real work.
  It is upgraded, under the sweep's rules.
- **Reboot consent** — with `/var/run/reboot-required` present, the reboot is **deferred**
  without `rebootOk`, and happens only with `rebootOk` plus `--allow-disruption`: the rule a
  cluster node follows.
- **`test`** — reachable, patched, no pending reboot, disk and time sane. Each check is proven by
  **breaking it on purpose**: fill the disk, stop time sync, leave a reboot pending.
- **The nightly** — after a `site-manager update`, `dh-test1` is in `last-update-result.json`
  like any other module.
- **The mothership key (#122)** — `cicd-key.sh status` and `rotate` cover adopted machines.
  Today they know only nodes and VMs; this phase catches it if that is not closed first.
- **Key-only SSH (#19), as its own step** — applied deliberately, then: password SSH refused,
  key login works, and the console still takes the root password.

## Phase 4 — removal is safe

`module delete dh-test1` **unregisters only**: the config goes, the machine keeps running and
is untouched. For a machine, *delete* must never mean *wipe*. ADR-026 states this before the
verb is built; this phase proves it.

## Phase 5 — PXE: create, then adopt

`module add debianhost --pxe` with `dh-test2` booting from the network: the node-provisioner PXE
trap serves a **Debian netboot and preseed that already carry the key** (ADR-026 D8a — today the
trap installs only Proxmox). After the install it joins phase 1 at step 2, and phases 1–4 are
rerun against this machine. The trap's time limit is tested too: a VM that never network-boots
must not leave the trap armed.

## Phase 6 — backup on a machine (ADR-012 §1.3)

Install PBS on `dh-test1` — the setup Erik runs, and ADR-012's fourth topology. This is also
the **first live test of #602's machine-hosted case**: with the backup module's placement
empty, resolution must adopt `node:dh-test1` and install nothing on a cluster node. Until now
that case was unit-tested only.

## Results

| Phase | Date | Result |
|---|---|---|
| 1 | 2026-09-18 | ✅ adopted as `dh-test1` (debianhost, zone `mgmt`, no `vmname`); key pre-seeded, and key arriving while `adopt` waits |
| 2 | 2026-09-18 | ✅ live: run twice (config unchanged), name taken, address taken under another name, PVE node (`tappaas3`), unknown `--zone`, reserved name, key never arrives (nothing written). Unit-tested only (`scripts/test/test-adopt.sh`): Ubuntu, address in no zone |
| 3 | 2026-09-18 | ✅ update deferred without consent, rebooted with `--allow-disruption` (boot id checked), waits for the clock; disk-fill test fails. **Open:** `cicd-key.sh`, key-only SSH. **The nightly:** it never selected a machine instance (its module rule was the retired `kind: module` marker or a `vmname`) — fixed 2026-09-19; confirm `dh-test1` in `last-update-result.json` after the next nightly |
| 4 | 2026-09-18 | ✅ `delete` unregisters (same boot id), `--vmid` refused |
| 5 | — | not started (D8a) |
| 6 | 2026-09-19 | ✅ PBS 4.2.6 installed **by hand** on `dh-test1` (datastore on a directory). Run against a copy of `config/` with an empty placement and `.node = dh-test1`, under a second instance name (`pbs6`) so the live `backup.mgmt.internal` was never touched: resolution **adopted `node` = dh-test1** and provisioned nothing on a cluster node (#602's machine case, first live run); `pbs6.mgmt.internal` became a CNAME of dh-test1, which got a DNS entry from its `address` (#612); dh-test1 is its `debianhost` instance's to patch (#603); the update created the verify job on dh-test1's PBS; PBS came back after a reboot; the `debianhost` update upgraded 12 packages with PBS running. Not shown: a PBS package upgrade (it was freshly installed) |

**Found in phase 2:** Debian 13's OpenSSH penalises a source address for failed logins
(`PerSourcePenalties`, 5s per failure, enforced from 15s, up to 10 min). `adopt` polling every
5s locked the mothership out of the machine — the operator's own ssh from it included. It now
tries every 20s.

**Found in phase 6:**
- **The first run went to tappaas3** — the test's fault, not the code's: hrossen's checkout was behind (pre-#601 code reached `dh-test1.mgmt.internal`, which does not resolve), and under instance `pbs6` the shared `get_config_value` read `pbs6.json`, so the `.node` constraint was empty. It ran install's idempotent path against the real PBS; nothing there changed.
- **It overwrote `~/.pbs-credentials.txt`** with a fresh, never-applied password — a real, older bug: `install.sh` generated and saved a password before checking whether `tappaas@pbs` existed. Fixed: an existing user's known password is used and the file is never rewritten; the file was restored from `/etc/pve/priv/storage/tappaas_backup.pw` and verified by login.
- **`pbs_ensure_zfs_ordering` would have required `zfs-mount.service` on a host without it**, stopping PBS at boot. dh-test1 has it (PBS pulls in the ZFS utilities); the step now does nothing where it is absent.
- **The backup module is effectively single-instance**: its placement libraries read `backup.json` whatever the instance name. Fine for a site-scoped module; recorded, not changed.

## What each phase proves

| Phase | Proves |
|---|---|
| 1–2 | `adopt` makes a module of a machine, and refuses everything it should (ADR-026 D8.1) |
| 3 | `debianhost` gives a machine the OS lifecycle a cluster node has (D3) |
| 4 | removing a machine from TAPPaaS never harms it |
| 5 | `add --pxe` = create + adopt (D8.2) |
| 6 | ADR-012 §1.3 works, and #602 holds on a machine |
