# Restore rehearsal (#729) — test plan

Primary audience: whoever runs the rehearsal of `src/foundation/backup/RESTORE.md` §2, §3 and
§5.2. Test site: **hrossen** (unstable/main, also home production). Nothing here runs on
makerfloss. Transcripts go to `docs/design/ADR-012-implementation.md`; each section's label in
RESTORE.md changes to **Rehearsed** (or rehearsed-in-part, saying which part) when its phase
passes.

## Decisions this plan rests on (operator, 2026-10-02)

- **The lost node is `tappaas2`.** It holds no PBS (that is `tappaas3`, `placementState: node`),
  no WAN cable (it can never carry `network`), and today no HA-managed guest.
- **§3 tests HA too, with a test VM — not with a production module.** A guest that HA protects
  is **not restored from backup** when its node dies: HA restarts it on a survivor from its
  replica, and recovery is *moving the node back into the HA setup and migrating the guest
  back* onto the new `tappaas2`. A dedicated HA test VM placed on `tappaas2` proves that path;
  the four non-HA guests prove the restore path.
- **The window is agreed:** litellm, openwebui, vllm-amd and nextcloud-hpb (Talk's signalling)
  are down while `tappaas2` is out — about 2–3 hours. `network`, `tappaas-cicd`, `identity`,
  Nextcloud, logging and Home Assistant are not on `tappaas2` and stay up.
- **§5.2 is restored beside the original only** — spare VMID, no network — and checked against
  the live mothership. No cutover, no `cicd-key.sh recover` run.
- **Order:** §5.2, then §2 (both need no window and no presence), then §3 in the window.

## Before the window — prerequisites

| # | What | Why |
|---|---|---|
| P1 | **`restore.sh` restores containers** (open, defect found writing this plan) | vllm-amd (312) is an LXC; its backup is `backup/ct/312/…`. `restore.sh` always runs `pvesh create /nodes/<n>/qemu --archive …` and probes `qm status`, so §3.3 would fail on it. Fix: take the guest type from the volid (`backup/vm/` → `qemu`, `backup/ct/` → `lxc`, `pct` for status/stop/destroy), with a unit test. |
| P2 | **Replacement install method** (open, operator) | §3.2 has two entries: `site-manager node add tappaas2 --pxe --boot-disk <disk>` (also proves unattended PXE), or Proxmox from USB then `node add tappaas2 --pool tanka1=single:<disk>` (adopt). Needs: does tappaas2 network-boot, which disk is the boot disk, is `tanka1` on its own disk. |
| P3 | Fresh backups of 310, 311, 312, 342 the same day | the restore must not lose a day of AI-stack state; `backup-manager` run on demand, then `list` shows today's |
| P4 | Mothership `config/` capture of the same day (backup:filesystem) | §5.2 compares against it |
| P5 | `module-manager list --diff` clean, sweep green | so every finding afterwards is the rehearsal's |

## Phase 1 — §5.2: rebuild the mothership beside the original

On `tappaas1` (a node — the mothership cannot restore itself):

1. Pick last night's 130 snapshot; `qmrestore <volid> 930 --storage tanka1 --unique 1`.
2. **Before the first start**, detach its network: `qm set 930 --delete net0`; `onboot 0`. It
   carries the mothership's hostname and keys — on the network it would be a second mothership.
3. Start it; work through the QEMU guest agent (`qm guest exec 930 …`) only.
4. RESTORE.md §5.2 step 1: `backup-manager key import` from a file pushed in with
   `qm guest file-write` (stands in for the USB stick). Expect: key accepted, fingerprint equals
   the live one.
5. Step 2: restore `config/` from the file capture (§5.1) into the beside-VM; compare
   `find config -type f | sort | xargs sha256sum` with the live mothership. Expect: equal but for
   files written after the capture (list them).
6. Step 3 (`site-manager update`) is **not run** — it would act on the estate. Instead
   `site-manager validate` and `module-manager list` inside 930 must read the restored config
   without error.

**Pass:** the beside-mothership boots from the backup, imports the key, holds a `config/` equal to
the live one, and its managers read it. **Teardown:** `qm stop 930 && qm destroy 930 --purge 1`.

## Phase 2 — §2: a module onto a system that never had it

1. **Declare first:** a second openwebui instance, `module-manager module add openwebui
   --instance openwebui-r` (new VMID, `config/openwebui-r.json`, its own DNS name).
2. **Restore second:** `backup-manager restore restore openwebui-r --vmid 311 --target-vmid
   <new VMID>` — the backup's VMID is the source, the installed one the target.
3. `module-manager module update openwebui-r`; `module-manager module test openwebui-r --deep`.
4. Check the data came across: the restored instance lists openwebui's users and chats
   (compare counts with the original).
5. Record what the guest carried from its old identity — hostname, SSH host keys, certificates,
   its old address — and what had to be reconciled by hand.

**Pass:** the restored instance runs under its declared name with the backed-up data, and the
deep test passes; every manual step is written into RESTORE.md §2. **Teardown:** `module-manager
delete openwebui-r --force`, then the leftover check below.

## Phase 3 — §3: `tappaas2` is lost

### 3a. Set up the HA test VM (the day before or at the start of the window)

- `test-nixos` (VMID 911, `stack: test`) is the HA test module: `dependsOn cluster:ha`,
  `HANode` + `replicationSchedule: */15`. Install it **declared on `tappaas2`**, `HANode:
  tappaas3`: `module-manager module add test-nixos`, then `module modify test-nixos --set
  node=tappaas2`.
- Expect: HA resource `vm:911` started on tappaas2, node-affinity rule, replication job
  `911 -> tappaas3 */15` in sync.
- Write a marker inside it (`date > /var/tmp/marker-1`), let one replication run complete, then
  write `marker-2` **just before** the power is pulled — 2 survives only if replication ran after
  it. This measures the recovery point instead of assuming it.

### 3b. Lose it (operator, on site)

Record first: `pvesh get /cluster/resources`, `ha-manager status`, `/cluster/replication`,
`module-manager list`, and the guest configs under `/etc/pve/nodes/tappaas2/`.
Then **pull tappaas2's power cord.** Note the time.

### 3c. §3.0 — what is running, and where

Run RESTORE.md §3.0's three queries as written. Expect: `vm:911` fenced and restarted on
tappaas3 by HA (watchdog fencing takes ~2 minutes; note the actual time to running), `marker-1`
present, `marker-2` per the replication timing; 310, 311, 312, 342 **not running anywhere**;
`module-manager list` shows test-nixos declared tappaas2, running tappaas3. Quorum holds (2 of 3).

### 3d. §3.1 — evict the node

`ha-manager config`, `pvecm nodes`, `pvecm delnode tappaas2`, copy
`/etc/pve/nodes/tappaas2/{qemu-server,lxc}` aside first (the record of what lived there), then
`rm -rf /etc/pve/nodes/tappaas2`; `site-manager node delete tappaas2`. Watch for: the `tappaas2`
**`pvehost` instance** (`config/tappaas2.json`, #665) — what `node delete` does with it, and what
`node add` expects to find.

### 3e. §3.2 — the replacement, same hardware, same name

Reinstall Proxmox on tappaas2 by the method chosen in P2, then `site-manager node add tappaas2 …`.
Expect: joined, quorum 3, `site.json` captured, `tanka1` registered, the `pvehost` instance back,
and **the backup client reconciled onto it** (ADR-012 §2.4: `backup-manager validate` clean;
`tappaas_backup` active on tappaas2).

### 3f. §3.3 — restore the guests that are not HA

For 310, 311, 342, then 312 (after P1), one at a time, as RESTORE.md §3.3 writes it:
`backup-manager restore restore <module> --node tappaas2 --storage tanka1`, `module update`,
`module test --deep`. Expect each restored from this morning's backup (P3) and green before the
next starts. **Not** test-nixos: it is HA-protected and running.

### 3g. §3.4 — HA guests come home; re-fold HA and replication

1. `module-manager migrate test-nixos` — declaration-driven, back to tappaas2. **No restore from
   backup.** Expect: running on tappaas2, both markers intact (it is the same disk), downtime only
   the migration's.
2. Replication: the job was `911 -> tappaas3` from tappaas2; after recovery the guest ran *on*
   tappaas3. Record what Proxmox did with the job, then what `site-manager update` makes of it —
   expect `911 -> tappaas3` from tappaas2 again, in sync.
3. `site-manager update`; `module-manager list --diff` **clean**; `ha-manager status` shows
   vm:911 on tappaas2 and 110/130/140 unchanged on tappaas1.

**Pass:** every §3 step ran as written, or the runbook says what it should have said; HA
recovered the test VM without a restore and it went home by migration; the four other guests came
back from backup and pass their deep tests; the estate shows no diff.

## Phase 4 — teardown (its own result row)

1. `module-manager delete test-nixos --force` (HA resource, affinity rule and replication job go
   with it — check each).
2. Phase 1's VM 930 and Phase 2's `openwebui-r` gone (done in their phases; checked here).
3. The empty, stale `/etc/pve/nodes/tappaas4/` (found 2026-10-02, from an earlier node) removed.
4. **Leftover check:** no guest in 900–999 on any node; `ha-manager config` lists only 110, 130,
   140; `/cluster/replication` only 110, 130, 140; no `config/test-nixos*.json`,
   `config/openwebui-r*.json`; their DNS names do not resolve; no stray backups of 911/930 or the
   openwebui-r VMID left on the PBS (or note them as kept on purpose); `module-manager list --diff`
   clean; the next sweep green.

## Results

| Phase | Date | Result |
|---|---|---|
| P1 | | |
| 1 (§5.2) | | |
| 2 (§2) | | |
| 3 (§3) | | |
| 4 teardown | | |
