# Backup recovery runbook (ADR-012 #545)

**What this is:** the tested recovery path for the things a TAPPaaS site cannot
rebuild from git — the firewall, the mothership, and `config/`. Every procedure
here has been **rehearsed on a live cluster**, and the transcript of that
rehearsal is in [ADR-012-implementation.md](ADR-012-implementation.md#package-logs).
A backup with no rehearsed restore is not a backup.

**Companion to:** [ADR-012 §2.5.1, §3.1, §4](../ADR/ADR-012-backup-enhancement.md)

---

## 0. Before you need it — the one thing that is not automatic

Backups are **encrypted client-side**. The keys are escrowed on the mothership,
which is inside the system a full-site rebuild is recreating, so that escrow
cannot be the only copy:

```bash
backup-manager key list                     # what is escrowed
backup-manager key export /media/usb-stick  # the mandatory out-of-band copy
```

Store that media somewhere safe and off-site. **Losing every copy of a key makes
the backups it encrypted permanently unreadable** — the compromise isolation
that protects you from an attacker protects you from yourself just as well.

---

## 1. What is covered, and how

| What | How it is backed up | Why that shape |
|---|---|---|
| **Firewall** (`network`, VMID 110) | `backup:vm` via `integratesWith` | Boots before the backup server, so it cannot `dependsOn` it (#501). Its config is not reproducible from git — OPNsense state is live state. |
| **Mothership** (`tappaas-cicd`, VMID 130) | `backup:vm` via `integratesWith` **and** `backup:filesystem` for `config/` | Two shapes on purpose: see §3. |
| **`config/`** (the cluster's declared state) | `backup:filesystem` → `fs/tappaas-cicd`, daily 20:30 | Restores in seconds into a running system, and — unlike a VM snapshot — onto a *different* mothership. |
| **`cluster`, `templates`** | *nothing, deliberately* | They hold no state outside `config/`; install rebuilds them. Backup is opt-in, and covering things that do not need it is how a backup set becomes noise. |

Check coverage at any time:

```bash
backup-manager list          # IN-PBS-JOB per module
backup-controller job-status # the live job and its members
```

---

## 2. Restoring `config/` (minutes, non-disruptive)

The common case: a bad edit, a lost file, a config drift you want to compare.

```bash
# What captures exist
backup-controller key list                       # confirm the key is escrowed
ssh root@<pbs-node> proxmox-backup-debug api get \
    /admin/datastore/tappaas_backup/snapshots --ns fs/tappaas-cicd --output-format json

# Restore into a scratch directory — NEVER straight over the live config
export PBS_PASSWORD="$(sudo cat /etc/secrets/backup-fs.pw)"
export PBS_FINGERPRINT="$(jq -r .fingerprint ~/config/tappaas-cicd.fsbackup.json)"
proxmox-backup-client restore host/tappaas-cicd/<TIME> home-tappaas-config.pxar /tmp/restore \
    --repository "$(jq -r .repository ~/config/tappaas-cicd.fsbackup.json)" \
    --ns fs/tappaas-cicd --keyfile /etc/secrets/backup-fs.key

diff -r /home/tappaas/config /tmp/restore     # look before you copy
```

Then copy back only what you meant to. Restoring the whole tree over a live
`config/` would also roll back every module installed since the capture.

**Rehearsed 2026-09-09:** 85 files, `diff -r` clean; the same restore **without**
`--keyfile` is refused (`missing key - manifest was created with key …`).

---

## 3. Restoring the mothership

Two paths, and which you want depends on what broke:

**3a. The mothership is intact, its config is not.** Use §2. Faster, and it does
not disturb anything else.

**3b. The mothership is gone.** Restore the VM:

```bash
cd ~/TAPPaaS/src/foundation/backup
./restore.sh --vmid 130 --list                    # pick a snapshot
./restore.sh --vmid 130 --target-vmid 930 --node tappaas1 --storage tanka1
```

`--target-vmid` restores **alongside** the original, **stopped**, with **fresh
MAC addresses** — so you can inspect it before committing, and so a rehearsal
can never eat the thing it is rehearsing. Drop `--target-vmid` to restore in
place over the original (it will ask before overwriting).

Do **not** start a restored copy on the same network as a running original.

**In a real DR, the order matters:**

1. Rebuild `tappaas-cicd` (VM restore, or a fresh install).
2. `backup-manager key import /media/usb-stick` — **before** any restore that
   must decrypt (§0).
3. Restore `config/` (§2), then the rest of the site from it.

---

## 4. Restoring the firewall

```bash
cd ~/TAPPaaS/src/foundation/backup
./restore.sh --vmid 110 --target-vmid 910 --node tappaas1 --storage tanka1
```

Same rules: stopped, fresh MACs, inspect first. The firewall owns the network
every other guest reaches the world through, so two of them answering for one
identity is worse than a firewall being down.

To cut over for real: stop the original, then start the restored copy — do not
overlap them.

**Rehearsed 2026-09-09:** restored to VMID 910, GPT intact (EFI + FreeBSD boot +
FreeBSD UFS, 3.2 GiB referenced), fresh MACs on both NICs, never started, then
destroyed.

---

## 5. Verifying, without waiting for a disaster

```bash
backup-manager validate                    # the hierarchy is consistent
backup-manager list                        # every module's effective policy
TAPPAAS_TEST_DEEP=1 ~/TAPPaaS/src/foundation/backup/test.sh
TAPPAAS_TEST_DEEP=1 .../services/vm/test-service.sh <module>          # a VM's backup age + job coverage
TAPPAAS_TEST_DEEP=1 .../services/filesystem/test-service.sh <module>  # a file capture's age
```

PBS verifies its own chunks nightly (04:00 verify-job, plus verify-on-write —
issue #228). That catches bit-rot. It does **not** catch "we never actually
backed this up", which is what the coverage checks above are for, or "the
restore does not work", which is what a rehearsal is for.

**Rehearse §2 and §4 at least once per release.** The three bugs found while
rehearsing them the first time (2026-09-09) — a backup lookup that parsed a
table header, a failed restore reporting success, and a mothership that had
never been in the backup job at all — were all invisible from the outside, and
all of them would have surfaced only during a real recovery.
