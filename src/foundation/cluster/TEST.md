# cluster — tests

## How to run
- Fast: `./test.sh` (runs from `src/foundation/cluster/`, or via `test-module.sh cluster`). Takes seconds.
- Deep: `TAPPAAS_TEST_DEEP=1 ./test.sh` — there is no `--deep` flag; the deep tier is gated solely on the `TAPPAAS_TEST_DEEP` env var. Takes minutes (creates and deletes real VMs/containers).
- `TAPPAAS_DEBUG=1` adds debug output.
- Prerequisites: sources `/home/tappaas/bin/common-install-routines.sh`; needs `jq`, `dns-manager`, `install-module.sh`, `delete-module.sh` on PATH. Deep tests require at least one reachable Proxmox node over SSH (`root@<node>.mgmt.internal`) and a working `srvHome`/VLAN-210 trunk across nodes.

## Standard (fast) tests
- **Test 1: Cluster scripts present** — asserts all 16 required files exist (`Create-TAPPaaS-VM.sh`, `Create-TAPPaaS-LXC.sh`, `lib/vm-net.sh`, `lib/test-vm-net.sh`, and the `services/{vm,ha,lxc}/{install,update,delete,test}-service.sh` set); and that the vm + ha `update-service.sh` reconcilers are executable.
- **Test 2: vm-net.sh helper unit tests** — runs `lib/test-vm-net.sh` (the network-helper unit suite) and asserts it exits clean.
- **Test 3: Drift reconciler --check (read-only)** — picks an installed module that `dependsOn cluster:vm` (skipping the test fixtures) and runs `services/vm/update-service.sh --check <module>`, asserting it parses live `qm config` without error. Skips if no Proxmox node is reachable or no eligible module is installed.

## Deep tests (live; TAPPAAS_TEST_DEEP=1)
- **cluster:vm drift reconcile (#192)** — installs disposable VM `test-vmdrift` (NixOS clone, VMID 920) on `mgmt`; verifies post-install "in sync"; induces zone drift `mgmt→srvHome` in config; asserts `--check` detects `net0:` drift; applies the reconcile (qm set net0 tag=210, reboot, wait IP, DNS); then verifies the **live VM** is tagged onto VLAN 210 and the **DNS record** `test-vmdrift.srvHome.internal` is registered at the new IP. Exercises live Proxmox + dns-manager. Without it, the VM zone-change/net0/DNS reconcile path is unverified.
- **cluster:ha drift reconcile (#193)** — installs HA-managed `test-hadrift` (VMID 921) on `srvHome/210`; verifies post-install "in sync"; induces replication-schedule drift `*/15→*/30` (asserts detect + live `pvesh /cluster/replication` schedule reconciled); then mangles the **live HA rule** nodes via `ha-manager rules set` (asserts detect + live `/cluster/ha/rules` normalized back to `tappaas1:2,tappaas2:1`). Exercises live HA-manager + replication + ha rules. The placement-migrate path is deliberately NOT triggered (primary stays tappaas1 to avoid a slow online migration).
- **cluster:lxc provisioner + drift reconcile (#203)** — installs disposable Debian CT `test-lxcdrift` (VMID 922) on `srvHome/210`; asserts container `net0` bound to VLAN tag 210 (proves zone→tag for LXC), post-install "in sync", DNS record registered; induces cores drift `1→2` (asserts detect + live `pct config` cores=2). Exercises live LXC provisioning + reconcile + DNS.
- Each deep block has its own `trap`-based cleanup (`delete-module.sh --force` + `dns-manager delete`), run on EXIT and after the block.

## Coverage notes
- When `TAPPAAS_TEST_DEEP` is unset, all three deep drift reconcilers are skipped — fast mode only confirms script presence, the vm-net unit suite, and a single read-only `--check`. The HA and LXC reconcile apply-paths are entirely unverified without the deep tier.
- Deep HA test intentionally does NOT exercise live VM migration / placement-migrate (logic-only) to keep runtime down.
- `delete-service.sh` and `test-service.sh` for each plane are checked only for presence, never executed.
- Fast Test 3 reconcile `--check` only covers `cluster:vm`; the ha/lxc `--check` paths have no fast-tier coverage (they only run inside the deep blocks).
- Tests assume the standard cluster topology (tappaas1/2/3, srvHome VLAN 210 trunked cross-node); a different zones/VLAN layout would break the deep assertions.
