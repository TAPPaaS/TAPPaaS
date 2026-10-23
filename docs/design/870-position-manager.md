# #870 — position-manager: placements in rooms in a location

Working survey and plan for #870, step 2 of ADR-036's implementation plan (D3 and D4).
rack-manager becomes **position-manager**, its file `racks.json` becomes `positions.json`,
a room is in a location, `mounts{}` become `placements{}`, and `network-manager topology`
gives every device its `location`, its `placement` and the record it came from (`source`),
with the devices a switch port sees but nobody recorded among them.

Out of scope (later steps of the ADR): `location` on a node's `pvehost` instance, on a
machine module, a switch or an AP (step 3: until then those devices are at the primary
location, except a switch whose free-text `location` already names a location); the
Overview's thumbnails by location, the Setup wizard's step (step 4).

## The shape

```jsonc
// config/positions.json (schema: schemas/positions-fields.json)
{
  "version": 1,
  "rooms":  { "basement": { "displayName": "Basement", "location": "knudanchersvej95" } },
  "racks":  { "rack1": { "units": 37, "width": "19in", "numbering": "bottom-up", "room": "basement" } },
  "placements": {
    "tappaas1":  { "rack": "rack1", "u": 1, "height": 2, "width": "full", "face": "front", "faceplate": "generic/server-2u" },
    "ISP modem": { "room": "basement", "faceplate": "generic/isp-modem" }
  },
  "devices": {
    "ISP modem": { "kind": "modem", "model": "generic/isp-modem" },
    "printer":   { "kind": "other", "ports": ["1"], "mac": "aa:bb:cc:00:11:22", "location": "knudanchersvej95" }
  },
  "cables": [ { "from": { "device": "USW Pro XG 10 PoE", "port": "5" }, "to": { "device": "ISP modem", "port": "LAN 1" }, "kind": "uplink" } ]
}
```

| field | | change class |
|---|---|---|
| `rooms.<r>.location` | names a location of `site.json` (`references: locations`); absent = the primary | in-place (validate refuses a move that strands a device whose own location differs) |
| `racks.<r>.*` | as today | as today |
| `placements` | was `mounts`; key = the device's name | manual: `place`, `place modify`, `unplace` |
| `placements.<d>` in a rack | `rack`, `u`, `height`, `width`, `slot`, `face`, `faceplate`, `label`, `description` | in-place |
| `placements.<d>` loose | `room`, `faceplate`, `label`, `description` (no unit, height, width or face: the plate gives its size) | in-place |
| `devices.<d>.location` | new; names a location; absent = the primary | in-place |
| `devices.<d>.mac` | new; the MAC a switch saw it by (`device record`), so the topology knows it is recorded | in-place |
| `devices`, `cables` | otherwise as today | as today |

Validation (`position-manager validate`, in `lib/ts`, after the existing checks):

- a room's `location` and a recorded device's `location` name a location of `site.json`;
- a placement's room (its own, or its rack's) is at the device's own location, where the
  device record has one (recorded devices now; other kinds from step 3);
- a device at a location that has no room is reported (a warning): it is somewhere at that
  location, unplaced. Only once the site records any room, as "mounted nowhere" waits for a rack.

## Readers and writers

✱ = writes. Each row: today → after.

### The manager (`manager/rack-manager` → `manager/position-manager`)

| where | today | after |
|---|---|---|
| `package.json`, `default.nix`, `install.sh`, `update.sh`, `validate.sh` | `rack-manager` | `position-manager`; the package also links `bin/rack-manager` (the alias); install links both into `~/bin` |
| ✱ `src/main.ts` (HELP, the verbs), `src/verbs.ts`, `src/store.ts` | `rack-manager`, `mount add/modify/remove`, `racks.json`, `.racks.lock` | `position-manager`; `place`, `place modify`, `unplace` with `mount add/modify/remove` as verb aliases; `device record`; `room add --location`; `device add --location`; reads `positions.json`, and `racks.json` while the migration has not run (read only: a write is refused until it has); `.positions.lock` |
| `test.sh`, `test/unit/*.test.ts` | the verbs above, `racks.json` | the new verbs, the aliases, `positions.json`, locations, `device record` |
| `README.md`, `DESIGN.md` | rack-manager | position-manager; the alias paragraph |
| `faceplates/` | the catalog | unchanged (moves with the directory) |

`RM_FIXTURE_DIR`, `RM_CATALOG_DIR`, `TAPPAAS_FACEPLATES` stay as they are (test plumbing).

### Shared code (`lib/ts`)

| where | today | after |
|---|---|---|
| `src/racks.ts` | `RACKS_FILE`, `RacksDoc`, `Mount`, `mountsOf`, `checkRacks`, `resolveRacks`, `RacksView` | `src/positions.ts`: `POSITIONS_FILE` (+ `LEGACY_RACKS_FILE`), `PositionsDoc`, `Placement`, `placementsOf` (reads `mounts` of an unmigrated document), `checkPositions(doc, catalog, seen, locations)`, `resolvePositions(…)` → `PositionsView` with `locations[]`; `racks.ts` goes |
| `src/locations.ts` `locationReferences` | already reads `racks.json` / `positions.json` rooms and devices | unchanged |

### Registry and build

| where | today | after |
|---|---|---|
| `components.json` | `rack-manager`, path `manager/rack-manager` | `position-manager`, path `manager/position-manager`, `aliases: ["rack-manager"]` |
| `scripts/control-plane-registry.sh` | copies `aliases` | unchanged; the site's `control-plane.json` gets the new entry at the next prepare step, the alias listed |
| `lib/control-plane-components.sh` | a name or an alias is owned | unchanged: `rack-manager` stays owned (an alias), so the refresh keeps its link |
| `flake.nix` | `rack-manager = component ./manager/rack-manager` | `position-manager = …/position-manager` |
| `scripts/refresh-control-plane.sh` | builds each `manager/*/install.sh` | unchanged: position-manager's install relinks `~/bin/rack-manager` to the new package |
| `scripts/tappaas-selfcheck.sh` | `rack-manager` in the manager list | `position-manager` |
| `scripts/test/test-control-plane-registry.sh` | directories = components | unchanged (the directory moves with the name) |
| `manager/README.md` | the rack-manager row | position-manager (rack-manager answers for one release) |

### The topology (`manager/network-manager`)

| where | today | after |
|---|---|---|
| `src/topology.ts` `collectSources` | `rack-manager export --json` | `position-manager export --json` (source name "position-manager export") |
| `src/topology.ts` `Topology.racks` | `RacksView`: racks with `mounts`, rooms with `loose`, `unplaced`, `cables`, `outside`, `findings` | `positions`: `PositionsView` — `locations[]` (name, displayName, kind, primary, place, its rooms, the devices there in no room), rooms with `location`, racks with `placements`, `unplaced` with `location`, cables, outside, findings |
| `src/topology.ts` nodes, switches, accessPoints, devices | no place | each carries `location` (a name), `placement` (`{room, rack, u}` or null) and `source`: `cluster` (a node), `switch-configuration` (a switch, an AP, a device a port names), `module` (a machine), `recorded`, `seen` |
| `src/topology.ts` seen devices | — | a switch port whose controller reports neighbours (`neighbors: [{mac, lldp?, lease?}]` in `switch-configuration-actual.json`, passed through by `switch-manager list-ports --json`) or that is up with nothing recorded on it, and that no node, AP, switch, configured or recorded device (by name, by MAC, by a recorded cable on the port) accounts for: a device `source: "seen"`, named by its MAC (else `<switch>:<port>`), shown by its LLDP name or lease hostname, at the switch's location, unplaced |
| `src/main.ts` `topology --no-racks` | leaves the racks out | `--no-positions`; `--no-racks` hidden for one release |
| `test/unit/topology.test.ts` | the racks block | `positions`, location/placement/source per device, seen devices |
| `README.md` | the racks paragraph | positions |

### The switch side (the port's neighbours)

| where | today | after |
|---|---|---|
| `manager/switch-manager/switch-manager` `list-ports --json` | a port's facts | also `neighbors` (empty when the controller reports none) |
| `src/foundation/network/switch-configuration-schema.json` | a port | `neighbors[]`: `mac`, `lldp {name, port}`, `lease {hostname, address}` |
| the UniFi and MikroTik controllers (Community repository) | report no neighbours | unchanged here: a follow-up there fills `neighbors` from the UniFi client list and RouterOS's bridge hosts / LLDP neighbours. Until then a seen device is a port that is up with nothing on it |

### Schemas

| file | today | after |
|---|---|---|
| `schemas/racks-fields.json` | `$defs` rack, mount, room, device, cable | `schemas/positions-fields.json`: rack, `placement` (was mount), room with `location` (`references: locations`), device with `location` and `mac`, cable |
| `schemas/fields-schema.json` `references` enum | … `devices`, `racks`, `faceplates` | + `rooms`, `locations` |
| `schemas/README.md` | the Racks row | the Positions row |

### Console (`ui/`)

| where | today | after |
|---|---|---|
| `src/manifest.ts` | `rack-manager` in the manager list | `position-manager` |
| `src/reads.ts` faceplates, `fields(rack/mount/room)` | `rack-manager faceplates list`, `racks-fields.json`, `t.racks` | `position-manager`, `positions-fields.json`, `t.positions`; kind `placement` |
| `src/fieldmanifest.ts` | kinds `rack`, `mount`, `room`; `FLAGS.mount.add` | `placement` (add: `--rack --u --room …` for `place`); room add gains `--location`; refs `rooms`, `locations` |
| `src/server.ts` | the comment naming rack-manager | position-manager |
| `web/src/types.ts` | `racks?: RacksView`, `RackMount`, `RoomInfo` | `positions?: PositionsView`, `Placement`, `RoomInfo.location`, `LocationInfo`; `location`, `placement`, `source`, `seen` on devices |
| `web/src/physical/rackops.tsx` | Mount…, Place in a room…, Move to…, Change mount…, Unmount…, Record a device… | one **Place…** form (a rack and unit, or a room), Move to…, Change placement…, **Unplace…**; Record a device…; **Record…** for a seen device (`device record`) |
| `web/src/physical/rack.tsx` | rooms with their racks | locations, each with its rooms and racks, and the devices at the location in no room |
| `web/src/pages/Physical.tsx` | heading = the site's place, Unplaced tray | a heading per location in the canvas; the tray lists the unplaced by location |
| `web/src/physical/SidePanel.tsx` | mount/room/rack cards | placement wording; a device's Location and Placement lines; a seen device's panel (port, MAC, LLDP, lease) with Record… |
| `web/src/physical/devicegraph.ts`, `devicedrawing.tsx`, `overview.tsx`, `pages/Day2.tsx` | `t.racks`, `mounts` | `t.positions`, `placements`; seen devices drawn on their port |
| `web/src/consoletargets.ts` | `mount-device` → `rack-manager mount add` | `place-device` → `position-manager place` (`mount-device` kept as the old target word) |
| `test/unit/*` (device, fieldmanifest, flags, consoletargets, manifest, zonegraph) and `test/fixtures/topology-racks.json` | racks | positions (`topology-positions.json`) |
| `README.md` | Physical: rack-manager, racks.json | position-manager, positions.json, by location |

### Docs

`src/DATAMODEL.md` (the Physical subgraph: positions.json, rooms → location, placements),
ADR-036 step 2 marked built, `migrations/README.md` (0020's row), the console README,
`manager/README.md`, `network-manager/README.md`, `schemas/README.md`. ADRs and design
notes that name rack-manager historically are left as written.

## Migration 0020 — `0020-racks-become-positions.sh`

Touches `config/racks.json` → `config/positions.json` only; reads `config/site.json`.
bash + jq. Reversible: restore `config/.migrations/backup/0020/racks.json` and remove
`positions.json`.

1. No `racks.json`: nothing to do (a site without racks, or one migrated already).
2. `racks.json` and `positions.json` both present: refuse (a person decides which is the site's).
3. Otherwise, from `racks.json`:
   - `mounts{}` → `placements{}`; a rack placement keeps `rack, u, height, width, slot, face,
     faceplate, label, description`; a loose one keeps `room, faceplate, label, description`
     (its height, width and face drawn nothing a plate does not give, and are reported);
   - every room without a `location` gets `site.json`'s `primaryLocation`; when `site.json`
     has none (no site.json yet), rooms stay without one — absent is the primary — and that
     is reported;
   - racks, devices, cables, rooms' other fields: unchanged;
   - written as `positions.json`, then `racks.json` removed (its copy is the backup).
4. Refuses, changing nothing: `racks.json` not a JSON object; `mounts` not an object; a mount
   with both `rack` and `room` or neither; a room's `location` naming no location; `site.json`
   still carrying the retired `location` (0019 has not run).

`--check` reports and writes nothing. A second run finds no `racks.json` and does nothing.

Fixture test (`scripts/test/test-migration-0020-positions.sh`): hrossen's `racks.json` and
`site.json` (rack1 in basement, six rack mounts, the ISP modem loose in basement, Nano HD loose
in stue, patchpanel1, one cable) → placements with the loose ones reduced, both rooms at
`knudanchersvej95`, racks/devices/cables byte-equal; `--check` writes nothing; twice is a
no-op; the backup holds `racks.json`; each refusal leaves every file as it was; no site.json →
rooms without location.

## Order of the work (one commit each)

1. This survey.
2. The rename: directory, package, aliases (`rack-manager` the binary, the old verbs),
   `positions.json` read and written (racks.json read), registry, flake, selfcheck, console
   manifest list.
3. The model: `lib/ts/src/positions.ts`, rooms' `location`, `placements`, devices' `location`
   and `mac`, `positions-fields.json`, validate's location rules.
4. The verbs: `place`, `place modify`, `unplace`, `device record`; help, README, DESIGN.
5. The topology and the console.
6. Migration 0020 and its fixture test.
7. Docs.
