# health-manager — design notes

## Language and build

- **Language:** TypeScript (ADR-007 §Health / Remaining-outstanding #3), built
  with `tsc` and zero npm dependencies (the shared ambient
  `../../lib/ts/src/env.d.ts` declares the Node built-ins used). `default.nix`
  is a thin import of the shared `../../lib/nix/ts-manager.nix` builder, which
  compiles + wraps a `bin/health-manager` Node entry. Shared CLI plumbing
  (colors/`die`/`guarded`, the `--help` renderer) and the ssh/pvesh cluster
  helpers come from `../../lib/ts/src/`. The legacy
  `*.sh` scripts stay live and on `PATH`; **`install.sh` is not yet wired to the
  nix build** (deliberate, this pass).
- **`update.sh`** re-runs `install.sh` (idempotent relink of the `*.sh`).

## Verb surface (read-only manager)

health-manager owns **no config domain** — it reads existing module/zone config
and the live cluster — so the CRUD verbs (`add`/`modify`/`delete`/`reconcile`)
are **N/A**. The surface:

| Verb | Maps to | Notes |
|------|---------|-------|
| `list vm` | — | **MOVED out of health-manager** (was the port of the retired `inspect-cluster.sh`) |
| `list vm --diff` | — | **MOVED** → `module-manager list --diff` (per-module drift rollup) |
| `show vm <name>` | — | **MOVED** → `module-manager reconcile <m>` (read-only), native `module-manager/src/inspect.ts` |
| `validate` | the `check-*.sh` gates | **special**: asserts the *live* system is healthy (below) |
| `update-os <name> <vmid> <node>` | `update-os.sh` | special **action**; thin pass-through to the script |
| `reboot <module>` | `reboot-guest.sh` | special **action** (#730): resolves the module to its VMID and live node, then update-os.sh's own `reboot_guest` path |

Common options: `--config-dir DIR` (config root), `--json` (machine output for
`list`/`show`), `--diff` (`list vm` rollup), `--threshold PCT` (`validate` disk
gate). `--json` emits the typed result object (`ClusterInspection` /
`ClusterDiff` / `VmInspection`) so the verbs are scriptable.

### `validate` — the health gate (special meaning)

For the config managers `validate` means "config is well-formed". For **health**
it means "**the live system is healthy**": `validate` aggregates gates against
the running cluster and **exits non-zero if any FAIL**.

| Gate | Source | FAIL condition | SKIP condition |
|------|--------|----------------|----------------|
| `service-liveness` | `pvesh /cluster/resources` | a managed config module's VM is not `running` | — |
| `disk-threshold` | SSH `df /` per managed guest | reachable guest `/` usage ≥ threshold (default **80%**) | no guest reachable |
| `memory-commitment` | one `pvesh /cluster/resources` | a node's memory committed to RUNNING guests ≥ threshold of its physical RAM (default **100%**) | cluster unreachable / no nodes |
| `guest-memory` | `pvesh` + one `ps` / `qm status` per node | a module using ≥ 90% of its declared memory (WARN ≥ 75%), or allocated above the declared limit | cluster unreachable / nothing running |
| `backup-status` | `backup-manager list --json` | a module disabled, or enabled-but-not-in-PBS-job | backup tooling absent / unparseable |
| `pending-reboot` | one SSH probe per guest (booted system vs profile; Debian `reboot-required`) | never — **WARN** per waiting guest (#730) | no reachable guest |
| `site-timezone` | the primary location's timezone (`site.json` `locations[primaryLocation].timezone`) + one `timedatectl` per node and per guest | never — **WARN** per node or guest on another zone, or when site.json has none (#837) | nothing answered |
| `pulse` | the backup node's `tappaas-pulse --status` | never — **WARN** when its timer is not running or a target is down (ADR-031) | no backup node, or it does not answer |
| `quorum` | `pvecm status` on the first answering node | never — **WARN** on two votes without a QDevice (#835) | no node answers |
| `switch-ports` | `switch-manager list-ports --json` (read-only: the switch as last read, by the delta's rules) | never — **WARN** per port with no record that is not parked, and per port set otherwise than its record (#853) | no switch-manager, or no switch |
| `cve-status` | `config/sbom/cve-status.json` | never — **WARN** on a failed scan, an ACT, or a scan older than 8 days (ADR-011) | no scan yet |

`--threshold` (default 80) and `--memory-threshold` (default 100) apply
cluster-wide. The disk gate is **read-only**: the 50%-auto-grow that
`check-disk-threshold.sh` performs is a *mutation* and stays in the script — it
is not part of the health assertion. The gate order is service-liveness →
disk-threshold → memory-commitment → guest-memory → backup-status →
pending-reboot → site-timezone → quorum → lan-uplink → switch-ports → pulse →
cve-status; `validate`
returns 0 only when zero gates FAIL (SKIP does not fail the assertion).

`guest-memory` renders one row per module beneath its own line (`CheckResult.rows`),
ordered by reclaimable gap and totalled per column. Its row status measures a
module against ITS OWN declaration — short of memory is a fault, over-declared is
not — while the gap column measures what ballooning could return. Those are
different questions and a single number cannot answer both. `warn` is a status
that reports without failing the assertion.

**Why the two thresholds differ.** A full disk stops a guest, so 80% leaves
runway to act. Committed memory at 100% is not yet a fault: a node may promise
every byte it physically has. It becomes one past that, where the node has
promised memory it does not own — which is why the memory gate accepts 1..500
rather than 1..99. A site running deliberate overcommit with ballooning can say
so (`--memory-threshold 150`) instead of switching the gate off.

**Committed, not used**, and the distinction is load-bearing: without ballooning
a guest's declared memory is pinned by the host whether the guest wants it or
not, so committed is what decides whether another guest fits. A node's *used*
figure may legitimately exceed its committed one, because ZFS ARC and host
overhead are not guest memory — a gate written against `used` would fail a
healthy node with a warm cache. Stopped guests are excluded (they hold nothing),
and an idle node is reported at 0% rather than omitted, so an empty node beside
a full one shows up as the placement problem it is.

## Architecture (TS modules)

- `src/types.ts` — entity model (`RunningGuest`, `ConfigModule`, `ClusterRow`,
  `DriftRow`, `VmInspection`, `ClusterDiff`, `CheckResult`, `HealthReport`) +
  the **`ClusterClient`** interface (the Proxmox/cluster boundary).
- `src/config.ts` — loads module JSONs from `config/` (skips non-module configs
  with no `vmid`), resolves the git source JSON via `moduleSource`, and reads the
  `site.json` node list (`siteNodeHostnames`).
- `src/inspect.ts` — pure inspection logic: `inspectCluster` (`list vm`),
  `inspectVm` (`show vm` three-way), `clusterDiff` (`list vm --diff` rollup).
- `src/checks.ts` — the health gates + `runHealthGates` aggregation.
- `src/client.ts` — `CliClusterClient`: the real `ssh`/`ping`/`pvesh`/`qm`
  shell-out FFI. Inspection + gate logic depend only on `ClusterClient`, so unit
  tests inject `FakeClusterClient` and never touch SSH.
- `src/main.ts` — verb dispatch, option parsing, table/JSON rendering, entry guard.

## State it reads

- **Module config** `config/<module>.json` (vmid, node, zone, diskSize, vmname,
  location, the `status` field — `archived` / `external` / implicit-active).
- **Site config** `config/site.json` — `.hardware.nodes[].name` for the cluster
  node list (with a `tappaas1..9` scan fallback).
- **Zone config** `config/zones.json` — for the NIC-drift VLAN mapping (consumed
  by the deferred NIC follow-up, not the scalar diff in this pass).
- **The git source JSON** (via the module's `moduleSource`) for the Released column.
- **Live cluster state** via Proxmox over SSH.

## How it talks to the cluster

Directly over SSH to the Proxmox nodes (`root@<node>.mgmt.internal`), with `ping`
reachability probes against the `site.json` node list. `pvesh get
/cluster/resources` enumerates VMs/CTs; `qm config` / `qm status` give live VM
detail; the disk gate SSHes to the guest (`tappaas@<vmname>.<zone0>.internal`)
and reads `df /`. It drives no control-plane controller.

## Testing

- **`test.sh`** keeps the fast bash smoke (every `*.sh` parses + resolves on
  `PATH`) and adds the TS unit tier: `tsc --noEmit` on `src` and the unit
  tsconfig, then runs the offline unit suite.
- **`test/unit/inspect.test.ts`** — offline unit tests (no SSH, no Proxmox) with
  an injected `FakeClusterClient`: cluster classification, the three-way `show vm`
  drift levels, the `--diff` rollup (managed-only, unreachable degradation), the
  health gates (pass/fail/skip), and the `site.json` node source. 23 assertions,
  no deep/live tier (the live tooling has no self-contained disruptive test).

## Deferred follow-ups (coordinator-approved, TODOs in source)

- **NIC-drift rows** (`show vm` / rollup): port `cluster/lib/vm-net.sh`
  (`vmnet_parse` / `vmnet_resolve_trunks` / `vmnet_zone_vlantag`) for the
  bridge/zone/VLAN/trunks/MAC rows + the `ALL` trunk-sentinel expansion; HANode /
  description rows fold in here.
- **Nested-config normalizer** — the bash `normalize_module_config`
  ("Pattern A → flat"); the TS port reads flat keys only for now.
- **`cluster` / `node` entities** — ADR-007 lists them alongside `vm`; entity
  model TBD.
- **Guest-agent liveness** — extend `service-liveness` with `qm guest cmd <vmid>
  ping` beyond `pvesh` running-state.
### How a guest rebuild classifies its own failure

`update-os.sh` retries a rebuild **only** on a lost connection; every other exit is
`nixos-rebuild`'s own deterministic verdict, and retrying it repeats the failure under a
misleading connectivity banner.

| exit | meaning | what happens |
|---|---|---|
| 0 | activated | done |
| 255 | ssh lost the connection | probe, then retry (up to 3) |
| 124 / 137 | **our** ceiling (`REBUILD_MAX_SECONDS`, default 3600) fired | treated as 255 |
| anything else | the configuration was rejected — including exit 4, units that failed to reload | fails immediately, no retry |

Two things make that work rather than hang (#720). The rebuild's ssh carries
`ServerAliveInterval=30 ServerAliveCountMax=6`, because `ConnectTimeout` bounds only the
handshake: once connected, ssh waits for a peer that is never coming, and a `switch` restarting
sshd or dbus-broker is exactly how the peer stops coming. That stranded one guest for 93 minutes
with no output, the retry unreachable because the attempt never ended. Keepalives turn the silence
into a 255 within ~3 minutes, which is the case the retry already handled.

And before calling a lost connection a failure it asks the guest what is activated, comparing
`/run/current-system` against its value before the attempt. In #720 the remote had already printed
*Done. The new configuration is …* — the switch had succeeded and only the connection was lost, so
"done, connection lost" is the correct verdict, not "failed". `/run/current-system` is the right
signal because a switch that reached activation moves it; comparing the running nixpkgs revision
instead would lie whenever the guest was already on the pinned revision and only its config
changed.

- **Full `update-os` TS port** — today the verb pass-throughs to `update-os.sh`.
- **`install.sh` → nix build** — link the compiled `health-manager` bin (kept on
  the `.sh` link path for now).

## The security scan (`security.ts`, ADR-011 v0.3)

`scan security` is three steps over one I/O boundary, `SecurityIO`, so the unit
tests run it whole against canned probe and scanner output:

1. **Probe.** One POSIX script (`LINUX_PROBE`) for every Linux target, over three
   transports — `sh -s` on the mothership, `ssh tappaas@<guest> sh -s`,
   `ssh root@<node> pct exec <vmid> -- sh -s` for an LXC. It prints the closure
   (NixOS) or `os-release`/`debian_version`/dpkg status (Debian), then one line
   per running container with its registry digests, then `@@end` — output
   without the marker was cut short and fails coverage. The firewall runs
   `OPNSENSE_PROBE` (`pkg query`, `pkg audit`, `pkg upgrade -nU`) with its own
   key; `-U` keeps the catalogue as OPNsense last fetched it, so nothing on the
   firewall changes.
2. **Inventory.** Store paths → components (`parseStorePath`: the version starts
   at the first segment that begins with a digit; trailing output names and
   API-level directories such as `dbus-1` are dropped). One `nix-instantiate`
   for every Nix package name on the site maps names to
   `meta.identifiers.cpeParts`; a name nixpkgs gives no vendor keeps
   vendor = product and says so (`tappaas:cpe-source`).
3. **Match and judge.** grype for Nix (CPE, no fix-state → *triage*), trivy for
   Debian roots rebuilt in a temp dir and for images by digest, `pkg audit` for
   OPNsense. `summarize` applies VEX, counts unique CVE ids, checks coverage and
   picks the verdict. `diffScans` against the previous status sets `new` and
   decides the notice.

The scan writes nothing but `config/sbom/`; its exit code is non-zero only when
every target failed (a scan with findings has succeeded). The scanner databases
are updated once per run, before any target is matched; a database that cannot
be fetched and is too old fails the targets that need it, through coverage,
rather than reading clean.

