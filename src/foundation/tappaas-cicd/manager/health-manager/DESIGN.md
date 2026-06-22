# health-manager — design notes

## Language and build

- **Language:** Bash throughout.
- **`install.sh`** links every `*.sh` (except the verb scripts) into `~/bin`
  (`${TAPPAAS_BIN:-/home/tappaas/bin}`): `inspect-cluster.sh`, `inspect-vm.sh`,
  `check-disk-threshold.sh`, `update-os.sh`. Nothing to compile.
- **`update.sh`** re-runs `install.sh` (idempotent relink).
- **No `validate` operation.** This component owns no config domain — it reads
  existing module/zone config and the live cluster — so it is the one
  manager-area component that intentionally omits the manager `validate`
  operation.

## State it reads

- **Module config** `config/<module>.json` (vmid, node, zone, diskSize, vmname,
  location, environment/variant, and the `status` field — `archived` / `external`
  / implicit-active).
- **Zone config** `config/zones.json` for the zone→VLAN mapping used in NIC drift
  comparison.
- **The git source JSON** (via the module's `location` field) for the
  Released-vs-Desired comparison in `inspect-vm.sh`.
- **Live cluster state** via Proxmox.

## How it talks to the cluster

Directly over SSH to the Proxmox nodes (`root@<node>.mgmt.internal`), with `ping`
reachability probes. It uses `pvesh get /cluster/resources` to enumerate VMs/CTs,
`qm config` / `qm status` for live VM detail, `qm guest cmd <vmid>
network-get-interfaces` (with a DHCP-lease fallback) for IP discovery,
`qm guest cmd <vmid> ping` for guest-agent health, and `qm reboot`. It drives no
control-plane controller. NIC comparison normalizes trunk ordering and resolves
the "ALL" sentinel to the actual zone VLANs so the live list and the config-derived
tags line up. NixOS rebuilds in `update-os.sh` are pinned to a known
`flake.lock` revision for reproducibility and run locally on the target VM.

## Testing

`test.sh` is a **fast smoke test only**: it confirms every entry script parses
(`bash -n`) and resolves on `PATH`. There is **no deep tier** and no
`TAPPAAS_TEST_DEEP` gate — the tools operate on the live cluster, so there is no
self-contained disruptive test to run here.

## Pending / not yet implemented

- **No deep / live test tier.** Coverage is limited to the parse + on-PATH smoke;
  the inspection and OS-update logic is not exercised against a live cluster in
  `test.sh`.
- **External resize helper.** `check-disk-threshold.sh` delegates the actual
  growth to a `resize-disk.sh` helper expected on the system; the threshold
  check, unit conversion, and 50%-increase (with a floor) live here, the resize
  itself does not.
- **Operational guards** carried in the scripts: `update-os.sh` refuses to
  reboot/stop the controller VM that is running the updater, and waits for
  cloud-init + passwordless sudo before any privileged step to avoid a
  first-install race.
