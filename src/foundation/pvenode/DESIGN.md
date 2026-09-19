# pvenode — design

Primary audience: developers.

**Why a module of its own.** ADR-026 D7 picks the machine module by operating system, and a
Proxmox node's OS is Debian (`/etc/os-release` `ID=debian`; ADR-022f D7). But a node is Debian
*plus a role* — cluster member, patched through the cluster's own path, joined and removed by
`site-manager`. Operator decision (2026-09-19): nodes are **`pvenode`**, not `debianhost`, so
the module can own that role's lifecycle in stages 2 and 3 without making `debianhost` branch on
it. `adopt` chooses by OS first and then by role: Debian with `pveversion` answering →
`pvenode`, Debian without → `debianhost` (`adopt_module_for_os`).

**Stage 1 is inert (#665).** `install.sh` verifies and changes nothing: root by key,
`ID=debian`, `pveversion`, hostname = instance name, and membership in `site.json`
`hardware.nodes`. `update.sh` is a documented no-op. Nothing about patching, reboots or cluster
membership moves.

**Who registers.** The cluster module's `update.sh` Step 7 runs `adopt-module.sh
<node>.mgmt.internal --wait 0` for each node without `config/<node>.json`; a failure there is a
warning, never a failed cluster update. `site-manager node add` does the same after a join. A
`config/<node>.json` that exists but belongs to another module is reported and left alone.

**Address.** The instance records `address: <node>.mgmt.internal`; `lib/pvenode-lib.sh` reaches
the node only through it.
