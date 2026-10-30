# ADR-040 live test plan (hrossen)

First run of branch `adr-040` on real hardware. hrossen runs `main` and the
operator's home production, so the test is built to be undone.

## How the branch gets onto the site

The code cannot run from a scratch directory alone: managers, `lib/cmdb.sh`,
`components.json`, the rebuild unit's `WorkingDirectory` and the sweep's sources
all name `/home/tappaas/TAPPaaS` literally.

**Decision: a bind mount.** `~/dev/adr040-live` is a git clone of the branch
(made from a bundle; nothing is pushed). `mount --bind` puts it over
`/home/tappaas/TAPPaaS`. The site's checkout stays byte for byte as it was
underneath; every hard-coded path, unit and git flake then sees the branch. A
reboot or `umount` ends it. `~/dev/adr040-live` is a real clone because the flake
needs git's root (`../` paths); harness scratch copies have no `.git` and are
removed on each sync.

- Refresh of `~/bin` (compiled managers, console, cmdb): `TAPPAAS_NO_GIT_PULL=1
  refresh-control-plane.sh` from the clone. Without that flag the pull would
  point the clone at `main`.
- OS rebuild: `sudo systemctl start --wait tappaas-rebuild@tappaas-cicd` with the
  mount in place. Not `module-manager update`: its pre-update pulls.
- A fix: commit on the Mac, send a bundle, fast-forward the clone, refresh.

## Migration 0027: on the real config, with restore

**Decision: run on the real `config/positions.json`, restore at teardown.** A copy
would prove little: the console, the sweep and asset-manager in units all read
`config/`. Baseline tarball first; teardown restores `positions.json` and
`.migrations/` from it (the 0027 ledger line goes with it, and the run-snapshot
pruning that the runner does is undone too).

## Baseline (taken before anything changes)

`~/dev/adr040-baseline/`, mode 0700: `config.tgz`, `bin.txt` (`ls -l ~/bin`),
`gcroots.txt`, `units.txt` (`systemctl list-units/timers`), system generation
(114, `7l847fcp…-nixos-system-tappaas-cicd-26.05.20261025.1f607aa`).

## Teardown (written first, runs last)

`~/dev/adr040-teardown.sh`, idempotent, in this order:

1. Remove the rendered `/run/systemd/system/cmdb-sweep.timer`; stop the timer.
2. `umount /home/tappaas/TAPPaaS`; check HEAD is `f092c05f` or the site's later tip.
3. Roll back the OS: `nix-env -p /nix/var/nix/profiles/system --switch-generation
   114`, then that generation's `switch-to-configuration switch`; delete the
   branch's generation link. Unless the operator says keep.
4. `TAPPAAS_NO_GIT_PULL=1 ~/TAPPaaS/.../refresh-control-plane.sh`: `~/bin`,
   console, `control-plane.json`, `module-fields.json` back to `main`.
5. Remove links `main` does not know (`asset-manager`, `cmdb`, `cmdb-controller`, …).
6. Restore `config/positions.json` and `config/.migrations/` from the baseline.
7. Leftover check: `ls -l ~/bin` names equal baseline, `git status` clean,
   `findmnt` shows no mount, `readlink /run/current-system` equals baseline,
   `systemctl --failed` no worse than baseline, console active, `~/config` diff
   against the baseline holds only the site's own changes, the clone gone.
8. Delete the baseline tarball (it holds config) and the clone.

**May stay:** `/var/lib/postgresql` (the database `cmdb`), `/var/lib/cmdb/dump`,
`/etc/secrets/cmdb-token`, `config/.cmdb-spool/` (empty). With the rollback nothing
reads them and a later install takes them up. Listed in the final report.

## Safety rules for this run

- `pgrep` on the test processes as a call of its own before each phase.
- Long runs in the background with a 10-minute log-growth watcher.
- No reboots, nothing destructive on tappaas3, no update sweep. Must finish before
  the 02:00 `update-tappaas.timer`, or the teardown runs first.
- Reports are read-only for the planes. Writes to a plane are only the ones in
  phase 5, each chosen by what it costs if it goes wrong.

## Phases

| # | Phase | Check | Result |
|---|---|---|---|
| 0 | Baseline, clone, teardown script | files present, clone at branch tip | | PASS. Baseline, clone, teardown script in place. Baseline already had `update-tappaas.service` failed (the 02:00 sweep) |
| 1a | TypeScript build | `tsc` of all components / `nix build` | | PASS. 15 flake packages |
| 1b | cmdb-controller `test.sh` | throwaway PostgreSQL | | PASS. 134, 135 with the new check |
| 1c | switch-manager, ap-manager CLI halves | `test-cmdb-report.sh` | | PASS. 38 and 27, run with the mount in place (they need `/home/tappaas/TAPPaaS`) |
| 1d | `test-migrate-vm.sh` | passes | | PASS. 33 |
| 1e | opnsense-controller, pbs-controller tests | passes | | PASS. opnsense (unittest) and pbs 52 |
| 1f | registry test | `test-control-plane-registry.sh` | | PASS. 20; migration 0027 test 51 |
| 1g | x86 system evaluates | `nix eval … toplevel.drvPath` | | PASS |
| 2a | OS rebuild from the branch | unit exits 0; which services restarted | | PASS. Generation 115; flake.lock unchanged |
| 2b | Services up | postgresql, cmdb-db, cmdb-paths, cmdb as `tappaas` | | PASS. Schemas 1-4 applied, 46 classes. `cmdb-paths` is a oneshot, inactive after its run |
| 2c | Socket and listener | socket 0660 in a 0750 dir; 9098 loopback with token, 401 without | | PASS. srw-rw---- in drwxr-x---; 401 without the token, 200 with it |
| 2d | Metamodel | `cmdb class list` | | PASS. 46 lines |
| 2e | Dump and backup path | `cmdb-dump`; `backup:filesystem` would capture it | | PARTLY. Dump written (28 KB). The live `config/tappaas-cicd.json` and manifest lack the path until the next module update merges it and `update-service.sh` rewrites the manifest; read in code, no capture run |
| 3a | 0027 `--check`, apply | exit 0, ledger line | | PASS. 3 devices + 7 assets, ledger line |
| 3b | `asset-manager validate`, aliases | answers as all three names | | PASS. 10 assets; three warnings on placement heights, old data |
| 3c | Console Physical view | Record, Change, Remove the record | | PASS. Scratch console in the browser, Physical renders; Record by the form, Change and Remove by the job API. Remove ends the CI (`disposed`) |
| 4a | site-manager | report, discover, second run no-op | | PASS after fixes. Accepted; disks, partitions, vdev members with serials, 22 PCI devices, corosync links stored. No-op on repeat |
| 4b | identity-manager | same | | PASS after fix: no user or group arrived until the uuid fix; now 5 users, 9 groups. No-op |
| 4c | module-manager | same | | PASS. 78 objects, no-op. Its machine `addresses` fought site-manager: fixed |
| 4d | environment-manager | same | | PASS. No-op |
| 4e | network-manager | same; rule `position` is evaluation order? | | PASS after fixes. All API paths answered (172 rules, 71 routes, 16 certs, 215 packages). **`position` was not the evaluation order**: compared with `rules.debug`, now sorted by sequence. Overrides flipped `public`: fixed |
| 4f | switch-manager, ap-manager | same | | PASS after fixes. No-op; `kind` and `speed` no longer fight the plate. Device uptime empty (controllers give none), AP firmware empty |
| 4g | backup-manager | same | | PASS after fixes. `/config/datastore`, GC, restore points read; datastore `size` is volatile now. Writes only volatile values |
| 4h | storage-manager | same | | PASS. Writes only `used`-like volatile values |
| 4i | health-manager | `validate` writes health | | PASS. 37 health rows each run: `health` carries its time, so every validate writes history |
| 4j | asset-manager | not refused; second run writes nothing, no drift; allocations resolve | | PASS. Second run writes nothing, no drift. `report --discover` refused by design; the sweep falls back. 3 allocations stay placeholders (see below) |
| 5a | Console job: module-manager modify | job id + actor in `cmdb history` | | PASS, with a finding: job id and `lars` in the change row (asset and module verbs). The preview said `config-only`, the apply ran a full module update on `deconz-test`. Tests passed after it; file restored |
| 5b | wlan passphrase from Setup | only if safe | | NOT RUN. A passphrase change hits the home wifi. CLI half covered by `test-cmdb-report.sh` |
| 5c | `migrate-vm` from a job | only if a cheap guest can move | | NOT RUN. Every guest here serves the household; `test-migrate-vm.sh` covers the report |
| 5d | `control-plane.json` shows `cmdbSource` | after refresh | | PASS. 11 components |
| 6a | `cmdb rescan` in the unit context | sandbox: spool, known_hosts | | PASS after a finding. 11 sources ok, 87 s; spool write ok, config read-only, sudo refused. `known_hosts` was read-only after a module update renamed it, until restart (documented in DESIGN). Outage: spooled, replayed |
| 6b | `cmdb sweep` in the unit context | record, exit code | | PASS. Unit run: exit 2 (critical), 97 s, 0 sources failed; a baseline. 9 unmanaged, 1 missing |
| 6c | Journal reaches Loki | `cmdb-sweep` lines | | PARTLY. 10 JSON lines in the journal; Alloy ships the whole journal with no errors. Lines in Loki **not read**: the query needs a credential this session was not given |
| 6d | health-manager gate `cmdb` | reads the last sweep | | PASS. `cmdb` gate fail, with the same counts |
| 6e | Timer placement | before the update window | | PASS. Timer 01:00, update 02:00, Persistent |
| 6f | Second sweep | only expected changes | | PASS. Unchanged site: 0 expected, 0 drift. With an `asset add` job and a hand edit: 3 expected, 1 drift, each named |
| 7a | Teardown | script exit 0 | | PASS. Rolled back to generation 114, 115 deleted, `~/bin` link for link equal to baseline |
| 7b | Leftover check | every item above | | PASS. No mount, checkout clean at f092c05f, ledger ends 0026, `devices{}` back, no listeners, no cmdb timer, console 200. By hand: `deconz-test.json.operator` and a scratch console. `config/` differs only in timestamps |

## Fixes made during the run

| Commit | What |
|---|---|
| `44abb3a0` | the linker left the checkout dirty: it chmod'ed and linked `*.jq` |
| `de7e788a`, `0849e301` | a node's environment closed its cluster membership (store) |
| `64e1b031` | a DNS override flipped `public` |
| `4e8a4c68` | NVMe by-id name flipped between two links |
| `2a2975ba` | module-manager overwrote a machine's addresses |
| `006abd20`, `36bd0a84` | switch-manager invented speed and kind, fighting the plate |
| `1f892d42` | a file backup's host made a `machine` placeholder |
| `b3b895ba`, reverted `0d398006` | skipping a self-played device's allocation lost `asset.role` on read back |
| `bf6d83b0` | identity: normalizers dropped `uuid`, no user or group reported |
| `6ce62ab3` | firewall rules in evaluation order, `outOfOrder` gone |
| `5778b807` | DESIGN: the known_hosts mount after an outside rename |

## Still broken or unverified

- Lines in Loki not read (6c).
- `module-manager modify` preview says `config-only`, apply runs a full update (5a). Not fixed; may predate this branch.
- A recorded device playing itself leaves a `node` placeholder (ISP modem, patch panels); `asset.role` depends on that allocation. Needs a design decision.
- `{class: node}` to a name held by a stale placeholder of another class is refused as ambiguous; seen once from the first run's placeholder, gone on a clean store.
- `known_hosts` read-only in the unit after a host's key is removed outside, until the service restarts. ssh still connects.
- `health` writes a history row for each CI at every validate, because of its `time`.
- site-manager `schedule` unit test fails: "every in-place field has a site modify option (missing: alerts)". The branch does not touch `alerts`.
- ADR-039 alert rules for `cmdb-sweep` do not exist yet.
- 5b and 5c not run; `backup:filesystem` capture of the dump not run (2e).
- Spool replay was run for one source only.

## For the operator to decide

- Rolled back as planned: the branch's generation and the migrated `positions.json` are gone. Rerun when `adr-040` lands.
- `config/tappaas4.json` has no node behind it, so this site's sweep will be critical until it goes or the node returns.
- 9 unmanaged: 6 groups, 2 users, `tappaas-nixos`. Record them, or exempt system accounts and templates.
- Left on hrossen: `/var/lib/postgresql` (66 MB), `/var/lib/cmdb/dump`, `/etc/secrets/cmdb-token`, empty `config/.cmdb-spool/`. Nothing reads them.
