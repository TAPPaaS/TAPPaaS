# Config migrations

One-time rewrites of the **shape** a site's `config/` is written in — a renamed field, a
changed type, a moved file (ADR-025). Changing a declared field's *value* is not a migration:
that is `module-manager module modify --set` (ADR-020).

> **Ordering (ADR-025 D9 rule 3).** A site receives the runner in one update before it receives
> anything for the runner to run: the runner reached `stable` with this directory empty, and only
> then did `0003` land. A Wave 1 migration (`0004` on) does not merge to `main` until Wave 0 is on
> `stable`. The gate is the release process — from inside a checkout the two cases look identical.

The directory is **empty in the release that introduces the runner** (ADR-025 D11), which is
the Wave 0 exit gate.

## What ships here now

| id | what it does | reversible |
|---|---|---|
| `0003-update-schedule-object.sh` | `site.json` `updateSchedule` becomes `{frequency, weekday, hour}` (ADR-017 D7). A weekday under `daily`/`none` was never read, so it is dropped — and **reported**, because it is the only trace of what the operator believed they had asked for. | yes — restore `.migrations/backup/0003/site.json` |
| `0004-kind-names-the-workload.sh` | `kind` names the workload (ADR-022f: vm, lxc, machine, application, device), authored in each module's source; the ADR-007 marker `"kind": "module"` is removed from deployed configs so the next update's merge can adopt the authored value — except where it is a config's **only** module signal, where it is kept and named, since removing it would hide the module. `"external-host"` → `"machine"`. (#611) | yes — restore `.migrations/backup/0004/<file>` |
| `0005-people-becomes-identities.sh` | `config/people/` becomes `config/identities/` (#628); `people` is left as a symlink to it for one stable cycle, the path's twin of the `people-manager` alias. Refuses when both are real directories — two copies of the domain are a person's to reconcile. | yes — remove the symlink, restore `.migrations/backup/0005/people/` |
| `0006-location-becomes-module-source.sh` | A deployed config's `location` (the module's source directory) becomes `moduleSource`, in place (#609): `location` is for a physical place (`physicalLocation`, and `site.json`'s own). A non-string `location` is a place and is left alone. Refuses a config carrying both with different paths. Every reader accepts both names for one stable cycle. | yes — restore `.migrations/backup/0006/<file>` |
| `0007-placement-node-names-the-host.sh` | The backup module's `placementState: "node:<host>"` becomes `"node"` with the Host in `.node` (ADR-012 §2.1, #600). A different `.node` was a discovery constraint the resolution already acted on; it is reported and kept in the backup. Refuses `node:` naming no Host. The module reads both shapes for one stable cycle. | yes — restore `.migrations/backup/0007/<file>` |
| `0008-satellite-records-its-module.sh` | A `satellite-<name>.json` that records no module source gets `moduleSource` — the satellite module's directory beside the recorded `tappaas-cicd` source, never the script's own location. Before it, `module list --resolution` reported the satellite `unresolvable`. Refuses when that directory cannot be derived or does not exist. | yes — restore `.migrations/backup/0008/<file>` |
| `0012-mgmt-reaches-all-zones.sh` | `zones.json` `mgmt.access-to` becomes `["internet", "all"]` (#375): `all` is every other standard zone (not Disabled, not Overlay or WAN), expanded by the controller when it reads the file, so a zone add or delete never edits `mgmt` again. Reports the zones the old list did not name and drops names that are no zone. No firewall rule changes: `mgmt` is `Manual`. Refuses a list without `internet` (the sentinel would add egress) and anything that is not a list of names. | yes — restore `.migrations/backup/0012/zones.json` |
| `0011-site-backup-is-an-object.sh` | `site.json` `backup: true` becomes `{}` (configured, every setting at its default) and `false` becomes `null` (#737): the schema wants the settings object or null, so `site-manager validate` failed on the boolean. `true` never named a target, so the migration reports that rather than inventing one. Refuses any other non-object value. | yes — restore `.migrations/backup/0011/site.json` |
| `0013-adopted-machines-keep-password-ssh.sh` | A `debianhost` config that does not state `sshKeyOnly` gets `false` (#756): from #756 a machine is key-only over SSH unless its config says otherwise, and a machine adopted before that was promised that adoption changes nothing about how it is reached. The satellite and `pvehost` are not touched — they take the key-only default. Refuses a non-boolean `sshKeyOnly`. | yes — restore `.migrations/backup/0013/<file>` |
| `0014-modules-moved.sh` | The modules grouped by stack (#421): `src/apps/<m>` → `src/<stack>/<m>` for the 13 modules that moved. Installed modules follow the moves in its table (written by `scripts/move-module.sh`, #500): a config whose `moduleSource` is a moved module's old directory points at the new one, in this site's checkout of the target repository. Refuses a target repository the site has not registered, a missing target directory, and a rename another config still depends on. | yes — restore `.migrations/backup/0014/<file>` |
| `0015-modules-moved.sh` | Installed modules follow the moves in its table (written by `scripts/move-module.sh`, #500): a config whose `moduleSource` is a moved module's old directory points at the new one, in this site's checkout of the target repository. Refuses a target repository the site has not registered, a missing target directory, and a rename another config still depends on. | yes — restore `.migrations/backup/0015/<file>` |
| `0016-zones-get-ipv6-subnets.sh` | Every zone that can carry IPv6 gets `ipv6Subnet` (ADR-030 D4): its VLAN tag read as hex where that fits (VLAN 310 → `0x31`), else the lowest free number, in VLAN order. Management, Overlay and WAN zones are skipped, and so is a zone that already has one. The number alone gives no IPv6: that needs `site.json` `ipv6: true` and a WAN prefix. `network-manager modify <zone> --unset ipv6Subnet` keeps a zone IPv4-only. Refuses a non-integer or shared number. | yes — restore `.migrations/backup/0016/zones.json` |
| `0017-site-organizations-removed.sh` | `site.json` loses `organizations`, a list of paths to the organization files that nothing read: the organizations are the files in `config/identities/organizations/`, which identity-manager owns. `site-manager validate` refuses a `site.json` that still carries it. The organization files are not touched. Refuses a `site.json` that is not a JSON object. | yes — restore `.migrations/backup/0017/site.json` |
| `0018-zone-names-its-environment.sh` | Each zone names its environment, and environments name no zone: a zone gets `environment` from the environment file naming it as its `network.zone` (its own zone) and from its `serves` (the environment it serves — a `serves` list stays a list); `network` leaves every environment file and `serves` every zone. The firewall graph is unchanged. Refuses, changing nothing, a zone two environments name as their zone, a zone whose `serves` or existing `environment` disagrees with the environment naming it as its zone, an environment naming a zone that is missing or not a Service/Management zone, and `serves` on a zone that is not Client, IoT or Guest. | yes — restore `.migrations/backup/0018/zones.json` and `environments/` |
| `0019-site-location-becomes-locations.sh` | `site.json` `location` becomes `locations{<name>}` with `primaryLocation` naming it: country, city, the building as `address`, timezone, latitude and longitude; the name is the building's, else the city's, else the site code's, lower-case. `locale` and `keyboard` move to the top level (a value already there wins, and the difference is reported). Each backup peer's `physicalLocation` becomes a `location` it names: the site's location at the same country, city and building, or a new one of `kind: remote` named after its building, city or the peer. Refuses, changing nothing, a `location` with no country or beside `locations`, a `primaryLocation` naming no location, a peer's place with no country, and a peer with both fields or naming a location the site lacks. Readers accept both shapes until it has run. | yes — restore `.migrations/backup/0019/` (`site.json` and the peer files) |
| `0020-racks-become-positions.sh` | `racks.json` becomes `positions.json` (position-manager, was rack-manager): `mounts` become `placements` — one in a rack keeps its rack, unit, height, width, slot, face, plate, label and description; one loose in a room keeps its room, plate, label and description (its height, width and face are dropped and reported: its plate gives its size) — and every room without a location gets `site.json`'s primary location (with no `site.json` yet the rooms keep none: absent is the primary). Racks, devices and cables are carried over as they are; `racks.json` is removed once `positions.json` is written. position-manager reads `racks.json` until then and refuses to change it. Refuses, changing nothing, both files present, a `racks.json` or `mounts` that is not an object, a mount with both a rack and a room or neither, a room naming a location `site.json` lacks, and a `site.json` still carrying the retired `location`. | yes — restore `.migrations/backup/0020/racks.json` and remove `positions.json` |

Its readers accept both shapes: `lib/update-schedule.sh` (the timer renderer and
`site-manager validate` share it) and `site-manager site show` / `site modify`. That is
deliberate — a restored backup or a site on an older release can still hold the triple, and a
reader that refused one would take that site's updates away. `site modify` always *writes* the
object, so a modify cannot undo a migration the ledger says is done.

## Writing one

A migration is `NNNN-<slug>.sh`. The number is allocated when the migration is written, is
never reused and never changes meaning — the ledger records numbers, so renumbering would
silently re-run or silently skip. Line 2 is the summary the runner prints in
`--list`; the rest of the header states what it changes, which release introduced it, whether
restoring its backup reverses it, and the issue or ADR that required it.

```bash
#!/usr/bin/env bash
# 0003-update-schedule-object.sh — updateSchedule becomes a named object
#
# Introduced: 2.1 (Wave 0, G0.1).  Required by: ADR-017 D7.
# Touches: config/site.json.  Reversible: yes — restore .migrations/backup/0003/.
```

The contract (ADR-025 D3), all of it enforced by review and by the migration's own fixture
test:

| Rule | Why |
|---|---|
| **Idempotent** — a second run changes nothing and exits 0 | the ledger is an audit trail, not the safety mechanism |
| **`--check` writes nothing** and reports what an apply would change | `site-manager update --dry-run` shows an operator what is coming |
| **Back up before the first write**, into `${TAPPAAS_MIGRATION_BACKUP_DIR}` | that copy *is* the rollback (D8); there are no down-migrations |
| **Exit non-zero on any doubt** | stopping costs one night's sweep; guessing costs a site's config |
| **`bash`, `jq`, coreutils and `config/` only** | it runs before the `nixos-rebuild`, so the new system generation and the manager bins may not exist yet |
| **`config/` only** | VMs, the firewall, the cluster and the repository belong to other paths |

The runner exports `CONFIG_DIR`, `TAPPAAS_CONFIG_DIR` and `TAPPAAS_MIGRATION_BACKUP_DIR`
(`config/.migrations/backup/NNNN`); a migration creates that directory itself if it writes.

## Moving a module (#500, ADR-025 D14)

Don't write a move by hand — `0009` was the last one. From the root of a TAPPaaS checkout:

```bash
src/foundation/tappaas-cicd/scripts/move-module.sh TAPPaaS:src/misc/foo TAPPaaS:src/home/foo
```

The tool moves the files, rewrites the catalogue entry, and adds the move to
`NNNN-modules-moved.sh` with its fixture test and a row in the table above. How to use it, what it
leaves to you, and what each site does with the migration: [MOVE-MODULE.md](../MOVE-MODULE.md).

## Its test ships with it

A change under `config/` with no migration is incomplete; a migration with no fixture test is
untested (ADR-025 D7). Drop `scripts/test/test-migration-NNNN-<slug>.sh` next to the others —
`tappaas-cicd/test.sh` Test 9z sweeps that directory, so it joins the fast tier by existing.
Each fixture builds a throwaway `config/` in a temp dir, runs `--check` (asserting nothing was
written), applies, compares against the expected output, and applies again to prove
idempotence.

## How they run

`scripts/run-migrations.sh`, from `tappaas-self-prepare.sh` — after the control-plane refresh,
before the `nixos-rebuild` and before the sweep's first module (ADR-025 D2). A failure stops
the unit: no rebuild, no sweep, and the #651 notice names the stage `migrate`.

```bash
site-manager update --dry-run        # what is pending, without running anything
run-migrations.sh --list             # the same list, on the cicd
run-migrations.sh --check            # each pending migration's own --check
run-migrations.sh --rerun 0003       # apply one again, deliberately
```
