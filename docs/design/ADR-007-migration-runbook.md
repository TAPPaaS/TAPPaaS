# ADR-007 Migration Runbook — converting a live mainline system

**Audience:** operators upgrading an existing, fully-updated *mainline* TAPPaaS
system (one not yet aligned to ADR-007) to the ADR-007 model
(`site.json` + environments + the renamed `network` module).

**Companion documents:**
- [ADR-007-migration-design.md](ADR-007-migration-design.md) — *why* each step
  exists and what the automatic path does/doesn't do.
- [ADR-007-implementation.md](ADR-007-implementation.md) /
  [-tracker.md](ADR-007-implementation-tracker.md) — the full design + stage status.

> **Read this first.** The conversion is **mostly automatic** (one orchestrator,
> idempotent) **except the firewall→network cutover, which is supervised** — it
> renames the OPNsense VM and touches the cicd's control lifeline, so you run it
> deliberately, with snapshots, in [§5](#5-firewall--network-cutover-supervised).
> Until you do, the system keeps working on `firewall.json` via back-compat
> aliases — there is no rush.

---

## 0. What you are migrating

| From (mainline) | To (ADR-007) |
|---|---|
| `config/configuration.json` | `config/site.json` |
| variants (in `configuration.json`) | `config/environments/{mgmt,<name>}.json` |
| `srv`/`home`/… zones | org-named zone `<name>` + `mgmt`, legacy zones inactivated |
| `config/firewall.json`, VM `firewall` | `config/network.json`, VM `network` (host alias kept) |

`<name>` is your installation/org name (e.g. `acme`). It is derived automatically
from `configuration.json` (`.tappaas.name` / first label of `.tappaas.domain`).

---

## 1. Pre-flight

Run these **before** changing anything.

1. **Confirm cluster health** (quorate, all nodes up):
   ```bash
   ssh root@tappaas1.mgmt.internal pvecm status | grep -i quorate
   ```
2. **Take PBS snapshots** of the cicd and the OPNsense/firewall VM (the two
   highest-risk VMs in this migration):
   ```bash
   snapshot-vm.sh tappaas-cicd        # the mothership
   snapshot-vm.sh firewall            # the OPNsense VM (still named 'firewall' pre-cutover)
   ```
3. **Back up the config directory** (belt-and-braces; the tooling also makes its
   own `.bak` / `.adr007-backup-*` copies):
   ```bash
   cp -a /home/tappaas/config /home/tappaas/config.pre-adr007
   ```
4. **Note the current state** so you can compare afterwards:
   ```bash
   ls /home/tappaas/config/*.json
   ls /home/tappaas/config/environments/ 2>/dev/null || echo "(no environments yet — expected)"
   ```

---

## 2. Pin the repository branch to ADR-007 (the easy-to-miss prerequisite)

`update-tappaas` pulls and **`git checkout`s** the branch named in your repository
config — so a manual `git checkout ADR007` in the working tree is **reverted on the
next run** unless you also pin the branch. On a mainline system the branch lives in
`configuration.json`:

```bash
jq -r '.tappaas.repositories[] | "\(.name): \(.branch)"' /home/tappaas/config/configuration.json
```

Set the TAPPaaS repository's branch to `ADR007` (adjust `.name` if yours differs):

```bash
cd /home/tappaas/config
jq '(.tappaas.repositories[] | select(.name=="TAPPaaS") | .branch) = "ADR007"' \
   configuration.json > configuration.json.tmp && mv configuration.json.tmp configuration.json
# verify
jq -r '.tappaas.repositories[] | "\(.name): \(.branch)"' configuration.json
```

> If no repositories are configured at all, `update-tappaas` instead pulls the
> *current* branch of `~/TAPPaaS`; in that case just `git -C ~/TAPPaaS checkout ADR007`
> and skip the jq edit.

---

## 3. Run the migration

The conversion needs **two `update-tappaas` runs** to fully settle, because the
*installed* `update-tappaas`/managers are the mainline build until the first run
rebuilds them (the new logic — including the Phase-0 migration — only takes effect
on the *next* invocation). This is expected and safe.

### Pass 1 — bootstrap the ADR-007 toolchain

```bash
update-tappaas --force --dry-run     # review the plan first
update-tappaas --force               # real run
```

What happens: the repo checks out `ADR007`, the managers/controllers and
`update-tappaas` itself are rebuilt and relinked, and the legacy guard in
`tappaas-cicd/pre-update.sh` creates `config/site.json` from `configuration.json`.
(`config/environments/` is still empty after pass 1 — that is fixed in pass 2.)

### Pass 2 — converge onto the full model (now Phase 0 is live)

```bash
update-tappaas --force --dry-run     # you should now see "Phase 0 - ADR-007 migration pass"
update-tappaas --force
```

Pass 2's **Phase 0** runs the orchestrator before any module is touched:
`config→site` (already done → skipped) → `zones-init --name <name>` →
`create-minimal-environments` (mgmt + `<name>`) → firewall **detect+warn** →
validation.

> **Equivalent manual control.** Instead of relying on pass 2, you may drive the
> orchestrator directly at any time (idempotent):
> ```bash
> migrate-to-adr007.sh --dry-run       # preview
> migrate-to-adr007.sh --yes           # apply (config→site, zones, environments)
> ```
> It exits **0** when fully converged, **2** when a manual action remains (the
> firewall cutover), **1** on a hard error.

---

## 4. Verify the conversion

```bash
# 4.1 site.json exists and has a name
jq -r '{name, version}' /home/tappaas/config/site.json

# 4.2 both base environments exist (mgmt + your org name)
ls /home/tappaas/config/environments/        # expect: mgmt.json  <name>.json

# 4.3 zones are consistent (org zone Active, legacy inactivated, mgmt present)
network-manager zones-check

# 4.4 the orchestrator reports a clean structure
migrate-to-adr007.sh --dry-run               # expect: "✓ system is on the ADR-007 model"
#                                              (or "ACTION REQUIRED" only for firewall — see §5)

# 4.5 services still healthy — deep-test a couple of representative modules
test-module.sh --deep network
test-module.sh --deep nextcloud              # substitute any installed app
```

Green criteria: `site.json` valid with a `.name`; `environments/mgmt.json` and
`environments/<name>.json` present; `zones-check` clean; module deep tests pass.
At this point the **only** expected outstanding item is the firewall→network
cutover (§5).

---

## 5. Firewall → network cutover (supervised)

This is the deliberate, supervised half. It renames `config/firewall.json` →
`network.json`, renames the Proxmox VM `firewall` → `network`, and **adds**
`network.mgmt.internal` while **keeping** `firewall.mgmt.internal` as the cicd's
control lifeline. Each step is idempotent and individually guarded.

> **Why not automatic:** the OPNsense host (`firewall.mgmt.internal`,
> `FIREWALL_FQDN`) is how the cicd reaches the firewall. The cutover must be run
> with a fresh snapshot and an operator watching. The host hostname is *not*
> retired here — that is a separate, even-more-careful step done only after every
> consumer is re-pointed.

### 5.1 Snapshot, then dry-run

```bash
snapshot-vm.sh firewall                       # fresh PBS snapshot of the OPNsense VM
snapshot-vm.sh tappaas-cicd                    # and the mothership

# Preview every action without changing anything (node auto-derived from site.json):
migrate-firewall-to-network.sh --dry-run
# or, equivalently, via the orchestrator:
migrate-to-adr007.sh --include-firewall --node tappaas1.mgmt.internal --dry-run
```

### 5.2 Execute

```bash
migrate-firewall-to-network.sh --yes
# or:
migrate-to-adr007.sh --include-firewall --node tappaas1.mgmt.internal --yes
```

(`--node` defaults to the primary node from `site.json`; pass it explicitly if you
want to target a specific Proxmox node for the `qm` rename.)

### 5.3 Verify the cutover

```bash
# config renamed, no stale firewall.json
ls /home/tappaas/config/network.json
test ! -f /home/tappaas/config/firewall.json && echo "firewall.json gone ✓"

# VM renamed in Proxmox
ssh root@tappaas1.mgmt.internal "qm config 110 | grep -i name"   # expect: name: network

# both DNS names resolve to the OPNsense (lifeline kept)
getent hosts firewall.mgmt.internal network.mgmt.internal

# the network module is healthy under its new name
test-module.sh --deep network

# orchestrator now fully converged
migrate-to-adr007.sh --dry-run                 # expect: "✓ system is on the ADR-007 model"
```

After this, a subsequent `update-tappaas` run drives the `network` slot via
`network.json` directly (no more back-compat fallback).

---

## 6. Rollback

The migration is layered and reversible:

- **Config-level:** restore from the automatic backups — `configuration.json.bak`,
  the `config/.adr007-backup-*` directory created by the orchestrator before
  zones/environments mutation, or your `config.pre-adr007` copy from §1.
- **VM-level:** roll back the PBS snapshots taken in §1/§5:
  ```bash
  snapshot-vm.sh firewall --list
  snapshot-vm.sh firewall --restore 1          # most recent
  snapshot-vm.sh tappaas-cicd --restore 1
  ```
- **Branch:** re-pin `repositories[].branch` back to your previous branch
  (e.g. `stable`) and run `update-tappaas --force` to return the toolchain.

Because every step is idempotent, a partial run can simply be re-run after fixing
the underlying issue rather than rolled back.

---

## 7. Command quick-reference

| Goal | Command |
|---|---|
| Pin branch | `jq '… .branch="ADR007"' configuration.json` (see §2) |
| Bootstrap toolchain | `update-tappaas --force` (pass 1) |
| Converge model | `update-tappaas --force` (pass 2) **or** `migrate-to-adr007.sh --yes` |
| Preview migration | `migrate-to-adr007.sh --dry-run` |
| Verify structure | `migrate-to-adr007.sh --dry-run`; `network-manager zones-check` |
| Snapshot a VM | `snapshot-vm.sh <module>` |
| Firewall cutover (preview) | `migrate-firewall-to-network.sh --dry-run` |
| Firewall cutover (apply) | `migrate-firewall-to-network.sh --yes` |
| Deep-test a module | `test-module.sh --deep <module>` |
| Roll back a VM | `snapshot-vm.sh <module> --restore 1` |

**Exit codes for `migrate-to-adr007.sh`:** `0` fully converged · `1` hard error ·
`2` action required (firewall cutover still pending).
