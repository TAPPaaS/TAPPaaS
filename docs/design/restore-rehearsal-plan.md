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
- **The replacement is PXE-installed** (operator, 2026-10-02): `site-manager node add tappaas2
  --pxe`, which also proves the unattended path.

## `tappaas2` as it is (recorded 2026-10-02)

| | |
|---|---|
| Proxmox | pve-manager 9.2.21, kernel 7.0.14-20-pve |
| Boot disk | `nvme0n1` — SanDisk SSD Plus 500GB (serial 25414A800205): EFI + LVM `pve` (root 96G, swap 8G, `data` thin pool 338G, empty) |
| Data disk | `nvme1n1` — Kingston OM8TAP42048K1 2TB (serial 50026B73842AD86F): ZFS pool `tanka1`, 1.86T, 100G allocated |
| NICs | `enp97s0` (MAC `38:05:25:33:b5:f7`) = `lan`, up — the PXE NIC (UEFI entry `Boot000A`); `enp98s0` (`…:f8`) = `wan`, **no carrier** (no WAN cable: `--no-wan`) |
| Boot order | `proxmox` first, PXE third — the old install boots unless told otherwise |
| Guests | VMs 310 litellm, 311 openwebui, 342 nextcloud-hpb; LXC 312 vllm-amd (AMD GPU via `/dev/kfd`, `/dev/dri/renderD128`) |
| On `tanka1` | `subvol-312-disk-0` 28.8G (**90% of its 32G**); `vllm-models` 33.3G, bind-mounted into 312 as `/opt/vllm/models`; disks of 310/311/342; and **stale replicas of 110, 130, 140** (created 2026-08-05/09, ~117G with snapshots) although their replication targets tappaas3 today |

What follows from it:

- **vllm-amd's models are not in any backup** (#758, maintainer @ErikDaniel007).
  `mp0: /tanka1/vllm-models` is a host bind mount, which vzdump skips. The fix is the module's;
  for this rehearsal the models are **re-downloaded by hand** (3f) and the time recorded.
- **The stale 110/130/140 replicas** vanish with the reinstall. They are worth a check on other
  sites (a replica left behind when a job moved), not a step here.
- **The old install must not come back.** It is first in the boot order; if tappaas2 powers on
  before the cluster has evicted it, it rejoins as the old node.

## Before the window — prerequisites

| # | What | Why |
|---|---|---|
| P1 | ✅ **`restore.sh` restores containers** — fixed on `fix/restore-containers` 2026-10-02 (see Results) | vllm-amd (312) is an LXC; its backup is `backup/ct/312/…`. `restore.sh` always runs `pvesh create /nodes/<n>/qemu --archive …` and probes `qm status`, so §3.3 would fail on it. Fix: take the guest type from the volid (`backup/vm/` → `qemu`, `backup/ct/` → `lxc`, `pct` for status/stop/destroy), with a unit test. |
| P2 | **PXE, decided:** `site-manager node add tappaas2 --pxe --boot-disk nvme0n1 --mac 38:05:25:33:b5:f7 --no-wan --pool tanka1=single:nvme1n1` | disks and NIC recorded above. Before the power is pulled: `efibootmgr -n 000A` on tappaas2 (one-time PXE on the next boot) |
| P3 | Fresh backups of 310, 311, 312, 342 **after the last `cicd-key.sh rotate`** (2026-10-02 10:17) and on the day | a guest restored from an older backup trusts only the revoked mothership key — nothing can log in to it (§2, 2026-10-02). `backup-manager backup litellm openwebui vllm-amd nextcloud-hpb` (#759, built 2026-10-02) — it names each snapshot it wrote |
| P4 | Mothership `config/` capture of the same day (backup:filesystem) | §5.2 compares against it |
| P5 | `module-manager list --diff` clean, sweep green | so every finding afterwards is the rehearsal's |
| P6 | **DNS baseline** — every module's name and address: `for m in $(module-manager list --json \| jq -r '.modules[].name'); do echo "$m $(dig +short $m.<zone>.internal @10.0.0.1)"; done` | §2 showed a restored guest can take another guest's DNS name, and Caddy proxies public sites by those names. Re-run after every restore and start in 3f and 3g, and compare |
| P7 | `fix/restore-from` merged (✅ 2026-10-02) | before it, a restore over an existing guest stopped at `root@root@<node>`, and `--node` did not default to the module's node |

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
`module-manager list`, the guest configs under `/etc/pve/nodes/tappaas2/`, and **which models
vllm-amd serves** (`ls /tanka1/vllm-models`, its served-model list) — 3f re-downloads them.
Set the one-time PXE boot (`efibootmgr -n 000A`), then **pull tappaas2's power cord.** Note the
time. **It stays unplugged until 3e says otherwise** — powered on early, it boots its old
install and rejoins the cluster as the node 3d just evicted.

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

Run the P2 command **first** — it arms the PXE offer (TTL 7200 s) and waits. **Then** plug
tappaas2 back in and watch its console: it must PXE-boot into the Proxmox installer. If it boots
the old install instead, power it off at once (the node is evicted; it must not run) and set
PXE from the firmware boot menu. Two things to watch in the new install:

- the **old `tanka1`** on `nvme1n1` must not be imported (a foreign hostid normally stops
  `zfs-import-scan`); if it is, stop — its old 310/311/342 disks would make the restores below
  meaningless. `node add`'s pool step should erase and recreate it.
- **vllm-amd's GPU**: `/dev/kfd` and `/dev/dri/renderD128` exist on the fresh install.

Expect: joined, quorum 3, `site.json` captured, `tanka1` registered, the `pvehost` instance back,
and **the backup client reconciled onto it** (ADR-012 §2.4: `backup-manager validate` clean;
`tappaas_backup` active on tappaas2).

### 3f. §3.3 — restore the guests that are not HA

For 310, 311, 342, then 312 (after P1), one at a time, as RESTORE.md §3.3 writes it — with the
order §2 taught (2026-10-02):

1. `backup-manager restore restore <module> --node tappaas2 --storage tanka1`, **interactively**
   (it asks whether to start the guest — answer no). Expect: the backup of P3, today's.
2. **Start it yourself** — `qm start <vmid>` (`pct start 312`). `module update` does not start a
   stopped guest: its pre-update tests fail on "not running" and it aborts (§2).
3. **DNS:** the guest's own name resolves to its address, and P6's list is otherwise
   unchanged. This is a restore of a guest's *own* backup under its own VMID — same MAC, same
   hostname, the original is gone with the node — so no name should move; checking it is what
   would have caught §2's incident in seconds instead of minutes. If one moves: stop the
   restored guest, then `sudo nmcli c up tappaas-ethernet` on the guest that owns the name.
4. **SSH:** it answers to the current mothership key (P3 is what makes this true). If not:
   `cicd-key.sh recover`. Its host key is its own, unchanged — `known_hosts` should accept it.
   Do not retry a refused login in a loop: sshd's per-source penalty then refuses the
   mothership for a while ("connection reset", §2).
5. `module update <module>`, `module test <module> --deep`; green before the next starts.

**Not** test-nixos: it is HA-protected and running.

vllm-amd (312) needs two more steps, both because of what a backup cannot carry (#758):

Its restore needs `--storage` (a container restore refuses without one), and restore.sh warns
that `/tanka1/vllm-models` is not in the backup and does not exist on the new tappaas2 — that
warning is expected.

1. `module-manager module update vllm-amd` re-runs `patch-host-gpu.sh` on the **new** host —
   GPU devices, render group, and the empty `/tanka1/vllm-models`. Check `/dev/kfd` and
   `/dev/dri/renderD128` inside the container.
2. Re-download its models with the module's `download-model.sh` (inside the container, as its
   README says), the same models it served before (list them in 3b). Record size and time; then
   `module test vllm-amd --deep`.

Record per guest: restore time and size (§2: 2 min 17 s for 32G; P1: 10 min for the 28.8G
container), start-to-green time, and anything done by hand.

### 3g. §3.4 — HA guests come home; re-fold HA and replication

1. `module-manager migrate test-nixos` — declaration-driven, back to tappaas2. **No restore from
   backup.** Expect: running on tappaas2, both markers intact (it is the same disk), downtime only
   the migration's. P6's DNS list unchanged afterwards (same guest, same MAC — a migration
   moves no names; checking it costs one command).
2. Replication: the job was `911 -> tappaas3` from tappaas2; after recovery the guest ran *on*
   tappaas3. Record what Proxmox did with the job, then what `site-manager update` makes of it —
   expect `911 -> tappaas3` from tappaas2 again, in sync.
3. `site-manager update`; `module-manager list --diff` **clean**; `ha-manager status` shows
   vm:911 on tappaas2 and 110/130/140 unchanged on tappaas1.

**Firewall changes are the operator's.** If anything in §3 needs a change on the firewall
itself (a dnsmasq lease, a rule), the operator makes it — Claude's session is not permitted to
write there (2026-10-02). The fix for a moved DNS name does not need it (step 3 above).

**Pass:** every §3 step ran as written, or the runbook says what it should have said; HA
recovered the test VM without a restore and it went home by migration; the four other guests came
back from backup and pass their deep tests; the estate shows no diff.

## Phase 4 — teardown (its own result row)

1. `module-manager delete test-nixos --force` (HA resource, affinity rule and replication job go
   with it — check each).
2. Phase 1's VM 930 and Phase 2's `openwebui-r` gone (done in their phases; checked here).
3. The empty, stale `/etc/pve/nodes/tappaas4/` (found 2026-10-02, from an earlier node) removed.
4. **Leftover check:** P6's DNS list matches the baseline (a lease of a deleted guest keeps
   its name until it expires — note it, as §2 had to); no guest in 900–999 on any node; `ha-manager config` lists only 110, 130,
   140; `/cluster/replication` only 110, 130, 140; no `config/test-nixos*.json`,
   `config/openwebui-r*.json`; their DNS names do not resolve; no stray backups of 911/930 or the
   openwebui-r VMID left on the PBS (or note them as kept on purpose); `module-manager list --diff`
   clean; the next sweep green.

## Results

| Phase | Date | Result |
|---|---|---|
| P1 | 2026-10-02 | ✅ `restore.sh` takes the guest type from the volid (`backup/ct/` → `pct`, `pvesh create …/lxc --ostemplate <volid> --restore 1`), refuses a container without `--storage` and a VM↔container swap, reports host bind mounts, and leaves a `--target-vmid` copy `onboot 0` (it inherited the original's `onboot 1` — found restoring 312). Live on hrossen: vllm-amd's backup restored as CT 931 on tappaas1 in **10 min for 28.8G**, warning that `/tanka1/vllm-models` is not in the backup and missing there; nextcloud-hpb's as VM 932, `onboot 0`; the no-storage refusal; both destroyed, no volumes left. `lib/test-restore-guest.sh` 18/18 |
| 1 (§5.2) | 2026-10-02 | ✅ **in part** (beside, offline, as decided). Last night's 130 restored on tappaas1 as VM 930 in **6 min for 64G** (184 MB/s), `net0` removed, `onboot 0`, 4G RAM; booted `running`, no failed units, loopback only; every timer stopped and masked through the agent. Its checkout was `7a53e3cb` (2026-09-28 — four days behind the live one). **Key import:** escrow moved aside, `key list` empty; the live `key export` pushed in through the agent (`pvesh …/agent/file-write`); `key import` brought back 4 keys byte-identical to the live escrow (and to the copy's own). **Finding:** imported escrow was `root:root` 755, the live one `tappaas:users` 700 — the sweep (NoNewPrivileges) cannot write a root-owned one; the tmpfiles `Z` rule repairs it at the next rebuild (verified), and `key import` now writes it tappaas-owned (`fix/restore-from`). **config/**: 104 files, 22 differ from live — only `updateTime` (and the scan reports), i.e. today's sweep. `site-manager`, `network-manager`, `identity-manager`, `backup-manager validate` pass inside; `module-manager list` reports config-only. Not run: `config/` from the file capture (needs network), `site-manager update`, cutover. Torn down: VM 930 destroyed, no volumes/HA/replication left, the plaintext key exports deleted from the mothership and tappaas1 |
| 2 (§2) | 2026-10-02 | ✅ after fixes — and **it took the production openwebui offline twice** (below). `openwebui-r` installed as VM 921 (proxy restricted to mgmt; no public name). **RESTORE.md §2 as written could not run:** `backup-manager restore restore` takes no `--vmid`, `--target-vmid` refuses a VMID in use, and the `--backup-id` route would have restored 311's MAC beside it. Built `--from` (`fix/restore-from`): `restore restore openwebui-r --from openwebui` → `restore.sh --vmid 311 --target-vmid 921 --replace --node tappaas2`. Found on the way: `restore.sh` passed `root@<node>` to ha-vm-lib (ssh `root@root@…`), so **every restore over an existing guest** stopped there; `--node` never defaulted to the module's node. Restored in **2 min 17 s**, identity kept (name, MAC, onboot). **Incident 1:** first boot online — the guest (311's system) asked DHCP for `openwebui`; dnsmasq gave it the name, Caddy proxies `openwebui.hrossen.dk` by it: the public site served the copy, then 502 once it was stopped (~15 min). Fixed by `nmcli c up` on production. → NICs now come back `link_down=1`. **Incident 2:** with `hostname` = `openwebui-r` (transient, cloud-init) the link went up — NetworkManager sent the **static** name, still `openwebui` (NixOS config): the guard stopped 921 within 5 s, production repaired the same way (seconds). → set `ipv4.dhcp-hostname` before raising the link: third attempt correct (`openwebui` stayed .163, `openwebui-r` → .148). **Finding:** the backup predates this morning's `cicd-key.sh rotate`, so the guest trusted only the revoked key — key installed through the agent (= `cicd-key.sh recover`). Then `module update` ✅ (static hostname rebuilt), `module test --deep` ✅, data 1 user / 4 chats as production, back in the backup job. Torn down: config, guest, disks, job, HA/replication, PBS backups, Caddy route, known_hosts, LiteLLM key all gone; the dnsmasq lease name `openwebui-r` → .148 left to expire (≤1 day, firewall edits not permitted here). RESTORE.md §2 rewritten |
| 3 (§3) | 2026-10-03 | ✅ after fixes. **3b** power pulled 10:47–10:48. **3c (§3.0)** HA: last heartbeat 10:47:31, fenced 10:48:40, vm:911 started on tappaas3 10:49:55 → running 10:55:06; `marker-1` (before the last sync) kept, `marker-2` (after) lost — as designed. Proxmox reversed 911's replication job (tappaas3 → tappaas2) while it ran there. The 5-minute start ("generating cloud-init ISO") coincided with ATA resets on tappaas3's `sda` — **`tankc1`, the PBS datastore's single disk, is failing** (DEGRADED, 534 reallocated / 64 pending sectors, ~3 000 kernel errors a day since 2026-10-01; no data errors yet) — operator's. **3d (§3.1)** `pvecm delnode`, node directory, `site-manager node delete`. **3e (§3.2)** PXE install 1: a reset during first boot left `authorized_keys` and the apt lists at 0 bytes → clean reinstall (BootNext, remote reboot); installed PVE 9.2.2, the join's dist-upgrade took it to 9.2.21 (kernel until the next reboot). Joined 11:46, 3 nodes quorate. **The NVMe names had swapped** between installer and system — `config-storage` refused the declared data disk because it was now the boot disk; `tanka1` created on the Kingston by id. `tappaas_backup` active, storage key on the cluster. **3f (§3.3)** from encrypted backups: litellm 70 s, openwebui 113 s, nextcloud-hpb 35 s, vllm-amd (container) with `tanka1/vllm-models` created first and qwen2.5-14b re-downloaded (28 GB); DNS identical to the baseline; all deep tests green; litellm's update only after vllm-amd (it integrates with it). **3g (§3.4)** no migrate needed: HA failback moved vm:911 home at 11:47 — four aborts, then success 5 s after `tanka1` existed; replication back to tappaas2 → tappaas3, in sync; markers as above. **Findings, all fixed in the closing change:** (1) PXE first after the install → node add puts the installed disk first in the UEFI order; (2) the answer's key lost → node add puts it back with the generated root password; (3) that password's place documented (root-only); (4) `node delete` left the pvehost instance → archived with it; (5) misleading "no data pool" message; (6) RESTORE.md §3.0 query listed `declared null`; (7) slow HA start = the failing disk; (8) PXE image older than the cluster → the join upgrades it; (9) **kernel disk names** → boot disk by serial (udev `ID_SERIAL` filter), `--pxe` refuses kernel names, `config-storage` resolves by-id paths and serials and guards on the resolved name; (10) `config-storage` prefixed `/dev/` to an absolute by-id path; (11) `restore.sh` prompted with no terminal → `--start`/`--no-start`, never prompts without one; (12) restore order → §3.3 restores providers first; (13) the rejoined node took root passwords over ssh → node add applies key-only SSH; (14) HA placed a guest on the half-built node → node add holds it in HA maintenance until its storage is registered |
| 4 teardown | | |
