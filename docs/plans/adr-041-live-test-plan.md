# ADR-041 live test plan (hrossen)

First run of branch `adr-041` (ADR-040 with its live-test fixes, plus health in
the CMDB) on real hardware. Method and safety as in
[adr-040-live-test-plan.md](adr-040-live-test-plan.md): a git clone of the branch
bind-mounted over `/home/tappaas/TAPPaaS`, `tappaas-rebuild@tappaas-cicd` for the OS,
`TAPPAAS_NO_GIT_PULL=1 refresh-control-plane.sh` for `~/bin`.

## Decisions

- **Migration 0027 on the real config, restored at teardown**, as before.
- **Rollback at teardown**: the operator is away. Generation 114, `~/bin`, `positions.json`.
- **The ADR-040 run's store is kept** for phase 3: its old `health` rows must not break
  `assess`, `show` or the console now that the metamodel no longer declares `health`.
- **Root-cause case: `tappaas4`.** `config/tappaas4.json` has no node behind it, already
  critical. No guest is stopped. Nothing touches `deconz-test` or any household service.
- **The ADR-039 rule file is validated and dry-run only.** `HealthRootCause` would mail
  the operator about `tappaas4` on apply. Applying it is his call.
- **The receiver hook** is tested only if a synthetic ALERT can avoid a mail.
- **Loki** is read on the logging VM with `logcli` and the VM's own admin credential
  (logging README), read-only. The credential is not copied off the VM or printed.

## Teardown (written first, runs last)

`~/dev/adr041-teardown.sh`, idempotent, as ADR-040's plus the health state:

1. Remove the rendered `cmdb-sweep.timer` and `health-assess.timer`.
2. `umount`; the checkout must be at the site's own HEAD.
3. Roll back to generation 114, delete the branch's generation.
4. Refresh `~/bin` and the console from the site's checkout.
5. Remove links and gcroots `main` does not know.
6. Restore `positions.json` and `.migrations/` from the baseline; remove
   `config/.health-emit-cursor` and its lock.
7. Leftovers: `~/bin` link for link against the baseline, no mount, checkout clean, current
   system equal to the baseline, console 200, no listener on 9098/5432/9197/9198, no cmdb or
   health timer, `config/` differing only in timestamps.
8. Delete baseline, clone, logs, scripts.

**May stay:** `/var/lib/postgresql`, `/var/lib/cmdb/dump`, `/etc/secrets/cmdb-token`,
empty `config/.cmdb-spool/`.

## Phases

| # | Phase | Check | Result |
|---|---|---|---|
| 0 | Baseline, clone, teardown script | present | | PASS |
| 1a | Build | every flake package | | PASS. All flake packages |
| 1b | health-manager fast tests | on the site | | PASS |
| 1c | ui fast tests | on the site | | PASS. 42 |
| 1d | cmdb-controller, alert-rules tests | pass | | PASS. cmdb 141, alert rules 177 |
| 1e | x86 evaluation | toplevel drvPath | | PASS |
| 2a | OS rebuild from the branch | unit exits 0 | | PASS. Generation 115, schema 5 applied at start |
| 2b | `health-assess.timer` | rendered from `site.json`, default 5 | | PASS. Every 5 minutes (`OnCalendar=*:0/5`) with no `health` in `site.json` |
| 2c | `health-assess.service` | assess && emit as `tappaas`, in its sandbox | | PASS, one finding: the first timer run fired 4 s before `cmdb` was back and failed. The next run: 61 s, 39 events, as `tappaas` in its sandbox |
| 3a | `assess` on the real site | each gate's condition on its object | | PASS. 66 objects assessed, 41 failing, 39 roots |
| 3b | Objects | a vm, a machine, a pool, the cluster, the backup-peer | | PASS. `vm/nextcloud`, `machine/tappaas3`, `storage-pool/tankc1` (disk-failing, true), `cluster/rossen` roll-up, `backup-peer/rasmus` |
| 3c | `validate` as a read | same verdict as `--live`, and as before | | PASS. Read and `--live` give the same 2 failed gates, guest-memory and cmdb, exit 1 |
| 3d | Second assess | changes only `lastChecked` | | PASS. `lastChecked` moved, 0 change rows, 0 transitions |
| 3e | Old `health` rows | reads survive them; dropped or dead | | PASS. Schema 5 closed the open rows; 320 stay as history. `show`, `query`, `history`, `--at` and the console all work on them. Dead rows, no fix needed. A site with them gets one sweep of `gone` drift (31 here); no site but hrossen ever had them |
| 4a | `rootCauses[]` on the site | names tappaas4 | | PASS, with a correction: the tappaas4 root was false, see fixes. Roots on the site: 39 entries |
| 4b | `impact` on dependants; `roots` | as derived | | PASS on a fixture. tappaas4 has no object, so it impacts nothing. CMDB-only fixture: two fake assets cabled, one link down: root, `impact` on the other port, `roots` names it. Only `connects` was exercised live; `runs-on` and `depends-on` by unit test |
| 4c | `ack` the root | symptoms silenced | | PASS. Root acked; symptom shows `ack(root)` with `via`. The site roll-up of `impact` stays unsilenced |
| 4d | `unack` | restored | | PASS. Both cleared. Fixture recovered and ended |
| 5a | `emit` lines | kinds causal, symptom, recovery | | PASS. causal, symptom, recovery, rootcause, ack, unack all seen in the journal |
| 5b | Cursor and flapping | cursor moves; no flapping on a steady site | | PASS. Cursor at the last change; 0 flapping lines. No flapping case produced |
| 5c | Receiver hook | synthetic ALERT, no mail | | PASS. Scratch receiver in the unit context with a fake notifier: `assess --only lazysite`, `emit`; 0 real mails. The hook is proved; a real alert record was not written |
| 5d | ADR-039 rule file | validate, apply --dry-run | | PASS. `validate` and `apply --dry-run`. **Not applied**: it would mail |
| 6a | `/health` as installer | graph on the roots | | PASS after fix. Scratch console through the dev gate. Roots listed worst first; the graph is small even on its first six roots, 349 objects lay out very wide |
| 6b | Sub-flows, CI panel | open and read | | PARTLY. CI panel read in full; member cards of a group appear, the open itself not seen on screen |
| 6c | Ack as a job | change row with job and actor | | PASS. `ack` job from the panel: job id and `lars` in the change row; `Unack…` offered, undone from the CLI |
| 6d | SSE through Caddy | `health/stream` on the real route | | NOT VERIFIED. Stream answers on the console directly and through the dev proxy. `console.hrossen.dk` stops at sign-in, which is the operator's |
| 6e | `health/graph?at=` | real history | | PASS. Before the first assess: all unknown; at 09:46 UTC: 24 ok, 284 unknown, 32 warning, 9 critical |
| 6f | Overview, Backup, Modules | read conditions, agree with the graph | | PASS. Overview, Backup and Modules read conditions and agree with the graph |
| 7a | `cmdb-sweep` in Loki | read on the logging VM | | PASS. 54 lines, unit `cmdb.service` |
| 7b | `tappaas-health` in Loki | same | | PASS. 89 lines. The password file is on the mothership, not the logging VM; read-only `query_range`, never printed |
| 8a | Teardown | script exit 0 | | PASS. Rolled back to 114, 115 deleted |
| 8b | Leftover check | every item above | | PASS. All items; `~/bin` link for link equal; `config/` differs only in timestamps; no 19095 listener; `.health-emit-*` gone |

## Fixes made during the run

| Commit | What |
|---|---|
| `919d8404` | console: open on the worst six roots, critical roots before warnings |
| `e2e19c78` | sweep: an archived instance is desired of nothing. `tappaas4` is archived: the critical was false |
| `9d8be5db` | site-manager: an all-digit serial is not an NVMe namespace. My own ADR-040 fix (`4e8a4c68`) cut `srv-01`'s serial; `adr-040` still has that bug |

## Still broken or unverified

- SSE through Caddy and `/health` through the real gate (6d): needs a signed-in operator.
- Group sub-flows opened only by what the page held (6b).
- `impact` across `runs-on` and `depends-on` not run live: no safe real failure.
- Flapping not produced live; the ADR-039 rules not applied, so no mail path run.
- ~~`health-assess.service` fails when `cmdb` is restarting: assess exits 1, unlike emit. Next run recovers.~~ Fixed 2026-10-31: a CMDB that does not answer, on the read or the write, is a warning and exit 0; a refusal still fails. Not yet deployed.
- `assess` takes about 60 s (the gates), not the few seconds D2 says. Measurable now: `health-manager assess --dry-run --timing` prints each phase and each gate on stderr. From reading the code, not yet measured: the CMDB reads and the working out are a second or two; the rest is the gates asking the planes, every ssh a fresh handshake (no ControlMaster), one after another:
  - per guest, serially: `disk-threshold` (2 ssh: probe + `df`), `pending-reboot` (1), `site-timezone` (1 per node + 1 per guest), `cpu-impact` (1 per HA guest on a common CPU); an LXC adds a `pvesh` ssh for its node in the first two. About 4 ssh per guest, 25-35 s on ~20 guests; an unreachable guest costs the 5 s ConnectTimeout per call.
  - `storage-disks`: `storage-manager inventory` with SMART on every disk of every node, its own help calls it slow; likely 5-15 s.
  - per node: `memory-commitment` and `guest-memory` each read `nodeCapacity()` (pvesh + one ssh per node + rrddata per container), so twice; `storage-pools` (2 pvesh + zfs per node); `lan-uplink` (`lan-uplink.sh show` per node); `quorum` (pvecm). Each of these, and `service-liveness`, pings every node again first. About 5-10 s.
  - one plane call each: `backup-status`, `backup-keys` (pbs-controller), `ipv6-egress` (ipv6-manager wan, then a curl or a guest ssh), `pulse` (1 ssh), `open-alerts` (ssh to logging + Grafana), and the `alerts` source fetches Grafana a second time. About 3-6 s.
  - no plane: `switch-ports` (actual file + jq), `mlag-pairs`, `signature-status`, `control-plane-trust`, `cve-status` (files), `cmdb` and the `sweep` source (CMDB `GET /v1/sweep`, twice), `thresholds`, `observations`, `settle`, `derive`.
  Gates unchanged (O3); first cheap wins without restructuring would be one `nodeCapacity()`, one Grafana fetch, one ping round, and ssh ControlMaster.
- 284 of 349 objects stayed `unknown`. Fixed by plan step 2 (ADR-041 v1.3); replayed over the live objects, 0 of 424 stay grey. Not yet deployed.
- The graph is a thin strip at a narrow width even on six roots.
- ~~The summary shows `0 silenced` with a condition acked while the object has another open one.~~ Fixed 2026-10-31: the console counted silenced per object, and only when its colour was all silenced; it now counts silenced conditions, the colours stay per object (console backend, `ui/src/health.ts`). Not yet deployed.
- ~~`health.assessInterval` has no `site modify` option.~~ Fixed 2026-10-30: `site modify --set health.assessInterval=<min>` (`--healthAssessInterval`), 1-1440.
- From the ADR-040 run, unchanged: `module-manager modify` preview says `config-only` but runs a full update; the site-manager `schedule` test on `alerts`.

## For the operator to decide

- **The ADR-040 report was wrong about `tappaas4`.** It is archived; nothing to do.
- **39 roots on a working site.** Every warning is a root, and `HealthRootCause` mails each `causal` event: applying the rules as they are means dozens of mails, some at each sweep. Decide before applying: critical only, or a digest.
- **`guest-memory` critical on 6 guests**, including `tappaas-cicd`. The gate already failed before this work; as conditions they are 6 critical roots at all times.
- Left on hrossen: `/var/lib/postgresql`, `/var/lib/cmdb/dump`, `/etc/secrets/cmdb-token`, empty `config/.cmdb-spool/`.

## Memory measurement, 2026-10-30 (second deploy, kept running)

`adr-041` at `5b906ebc` deployed again from a clone bind-mounted over the checkout, generation 115 restored from the store in seconds. Left running for the operator's inspection under a 3-day pull hold (`site-manager repository hold TAPPaaS`), so neither a module update nor the 02:00 sweep pulls the clone back to `main`. Baseline for a later rollback in `~/dev/adr041m-baseline/`.

**Why tappaas-cicd reads "93 % used".** Inside the VM: 16 GB total, about 1.0 GB in use, 15.0 GB available; 14.6 GB is page cache from Nix builds (Buffers 2.2 GB, Cached 10.4 GB, reclaimable slab 2.2 GB). Proxmox computes a guest's `mem` as the balloon's `total_mem − free_mem` (`QemuServer.pm` line 2683), and `free_mem` is Linux's MemFree, which is always near zero on a busy Linux guest. `guest-memory` takes that number as "used" (`client.ts`, `usedMem: row.mem`), so every Linux guest with a balloon driver reads about 90 %. The balloon's statistics do carry the right numbers — `stat-available-memory` 15.6 GB and `stat-disk-caches` 12.7 GB, read with `qom-get /machine/peripheral/balloon0 guest-stats` on the node — Proxmox just does not expose them. The fix is in health-manager, not the guests: used = total − available.

**What the CMDB costs** (cgroup `memory.current`, idle after a sweep and an assess; peak = `memory.peak`):

| unit | idle | peak | of which anonymous |
|---|---|---|---|
| postgresql.service (PostgreSQL 16, shared_buffers 128 MB default, database 11 MB, 405 objects) | 41 MB | 44 MB | 7 MB + 19 MB shared |
| cmdb.service (cmdb-controller serve) | 56 MB | 113 MB during the sweep | 39 MB |
| cmdb-sweep.service (the client) | – | 12 MB | |
| health-assess.service | – | 57 MB | |
| tappaas-console.service | 62 MB | 225 MB (the build at refresh) | 62 MB |

About 100 MB resident at rest, 170 MB at the sweep's peak, under 1.1 % of the VM. The sweep took 187 s (122 drift, 1 source failed), the assess 61 s.

**Under load.** `module-manager update tappaas-cicd` (snapshot, pre-update tests, hook, reconcile, post-update tests; the OS closure was unchanged so no build) ran 60 s and raised the VM's used memory from 1.06 GB to a peak of 1.28 GB. A forced full evaluation of the NixOS closure (`nix build --option eval-cache false` of `toplevel`) took 3.9 s with a 758 MB client peak. The large cgroup figures (`nix-daemon.service` 2.9 GB, `user.slice` 5.4 GB) are file-backed page cache charged to those cgroups (anonymous 5 MB and 9 MB), reclaimable at once.

**Conclusion.** tappaas-cicd is not short of memory; the check is reading the wrong number. The CMDB adds about 0.1 GB. The 16 GB declaration is generous: 4 GB would hold every measured peak with cache to spare, and the host would see the page cache shrink to fit.
