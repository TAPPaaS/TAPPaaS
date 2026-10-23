# #871 — every device record names its location

Working survey and plan for #871, step 3 of ADR-036's implementation plan (D2). A machine
module instance and a switch or access point name the location they are at with one field,
`location`, holding the name of one of the site's locations (`site.json` `locations{}`,
site-manager); absent, the device is at the primary location. A machine's
`physicalLocation {country, city, building}` goes, and so does a switch's or AP's free-text
`location`.

Out of scope (the rest of step 3 and later steps): `storagePools` on the `pvehost` instance
and `site.hardware` removed (D6); the Overview's thumbnails by location and the Setup
wizard's step (step 4). Recorded devices already carry `location` (#870).

## The shape

```jsonc
// config/satellite-hel1.json (kind machine)
{ "kind": "machine", "moduleSource": ".../src/foundation/satellite", "address": "37.27.5.237",
  "location": "hetzner-hel1" }          // was "physicalLocation": {"country": "FI", "city": "Helsinki"}

// config/switch-configuration-desired.json (and -actual.json, which update-desired copies from)
{ "switches":     { "crs-a":   { "location": "knudanchersvej95", "description": "rack 1, top" } },
  "accessPoints": { "Nano HD": { "location": "knudanchersvej95" } } }
```

| field | | change class |
|---|---|---|
| machine `location` | a name of `site.json` `locations{}` (`references: locations`); absent = the primary | in-place: changing it moves nothing, it only changes where the topology, the console and the off-site check put the machine |
| machine `physicalLocation` | retired; migration 0021 makes it a location; read until then | immutable (classified, never written) |
| switch / AP `location` | a location name; absent = the primary | written by `add-switch`/`modify-switch`, `ap-manager add`/`modify` |
| switch / AP `description` | free text; the migration moves a `location` that names no location here | as today |

### The module `location` field's two meanings

`location` was the module's source directory until #609 (migration 0006 renamed it to
`moduleSource` in every config). Its reader rule since #869: **a string with a `/` is the old
directory field, never a place; a string without one is a location name.** `moduleSource`
always wins over it, and copy-update-json writes `moduleSource` on every install, so a
module's directory is never read from a location name. The few places that still *write* or
*delete* the old field are changed so a name survives (copy-update-json's `del(.location)`,
site-manager repository's re-point).

## Readers and writers

### Machine module `physicalLocation` → `location`

| where | today | becomes |
|---|---|---|
| `schemas/module-fields.json` `physicalLocation` (definition + class in-place) | `{country, city, building}`, general | retired: `deprecated`, class immutable, read until 0021 |
| `schemas/module-fields.json` `location` (definition + class immutable, deprecated) | the old directory field | `location`: string, `references: locations`, usedBy general (a machine), class in-place, apply none; the old meaning noted |
| `schemas/fields.json` `physicalLocation` (the composed copy) | same | same as module-fields |
| `schemas/satellite-fields.json` `physicalLocation.*` | the satellite's place | `location` (a name; `--location` or `--country/--city/--building` at add) |
| module-manager `add` (main.ts → install-module.sh → copy-update-json `--<field>`) | `--physicalLocation '{…}'` passed through as a field | `--location <name>` (must exist); for a machine module `--country [--city] [--building]` find or add a location of kind `remote` (lib/ts `ensureLocation`, as `peer add` does) and pass `--location`; `--physicalLocation` refused with the new spelling |
| module-manager `adopt` (main.ts → adopt-module.sh `--set`) | `--set physicalLocation=…` would be written | `--location <name>` and `--country/--city/--building` as for add, forwarded as `--set location=<name>` |
| module-manager `modify --set location=<name>` | — | in-place; the gate checks the name exists |
| module-manager `validate` (validate.ts) | — | a machine's `location` names a location of the site; a `physicalLocation` left is reported (migration 0021) |
| copy-update-json.sh (install) `del(.location)` | drops the old directory field | drops it only when it is a path (has a `/`) |
| apply-json-merge.sh `_MERGE_AUTO_FIELDS` has `location` | installed value always kept | unchanged: a location name is the site's, kept across the release merge |
| module-manager inspect.ts `DEPLOYMENT_OWNED` has `location`; `getField(cfg,"moduleSource") \|\| getField(cfg,"location")` | | the fallback only for a path |
| module-manager config.ts module directory (`.moduleSource // .location`) | | the fallback only for a path |
| bash `.moduleSource // .location` readers (common-install-routines get_module_dir/find, apply-json-merge, Create-TAPPaaS-VM, rules install-service, nfs-converge, update-os, repository.sh, satellite-lib `isSatellite`, wgvpn-lib) | `moduleSource` first | unchanged: `moduleSource` is on every module (0006, written at every install), so the fallback never reaches a name; common-install-routines' and apply-json-merge's fallback take a path only |
| site-manager repository.sh re-point (`.moduleSource = $loc \| del(.location)`) | | deletes only a path |
| opnsense-controller `instance.py` `module_source_of` | already ignores a name (#869) | unchanged |
| update-tappaas `main.py` (is-a-module; module dir) | `moduleSource` or `location` | unchanged (moduleSource first; a machine is a module either way) |
| backup-manager `offsite.ts` `targetPlace` | a `location` name, else `physicalLocation` | unchanged in shape; the warning for a satellite with neither names `location` (`module modify <i> --set location=<name>`) |
| backup-manager `offsite.ts` `isSatellite` (`moduleSource ?? location`) | | path only |
| lib/ts `locations.ts` `locationReferences` | a config's top-level `location` name | unchanged for machines; adds each switch's and AP's `location` from the switch configuration, so `location delete` refuses a named one |
| network-manager `topology.ts` | nodes and machine devices at the primary; satellites on the Outside lane with no location | a node's location is its `pvehost` instance's `location`, a machine device's its own, a satellite's Outside row shows its location's name and place; each defaulting to the primary |
| satellite `lib/satellite-lib.sh` lockdown (`peer add remote … --country --city --building`) | from `physicalLocation` | `--location <name>` from the instance's `location`; `physicalLocation` still read until 0021 |
| satellite `test.sh` (instance test: place recorded; template carries no place; lockdown fixture) | `physicalLocation` | `location` naming a site location (a `physicalLocation` still passes with a note) |
| satellite `install.sh` usage line, `satellite.json` `_address_note`, `INSTALL.md` (install, conversion recipe) | `--physicalLocation` | `--location` / `--country --city` |
| console `wizards.ts` `satelliteSpec` (`--physicalLocation {…}`) and its unit test | | `--location <name>` when a location is chosen, else `--country/--city` |
| console module add form (Modules.tsx `fieldsStep` kind module) | no place | a machine module's form shows `--location` as a dropdown of the site's locations (`references: locations` already gives one) |
| console ModulePage | no place | a "location" line for a machine: the name, its place, a link to the location on the Site page |
| docs: ADR-010, ADR-012, ADR-022b, `docs/plans/satellite-test-plan.md` | `physicalLocation` | ADRs keep their history; the plan's commands follow |

### Switch and AP `location`

| where | today | becomes |
|---|---|---|
| `network/switch-configuration-schema.json` switch / AP `location` | `{type: string}` free text | a location name (`references: locations`, description); AP gets `description` |
| switch-manager `add-switch --location` (writes actual; update-desired copies to desired) | free text | a location name, checked against site.json; `--description` for text |
| switch-manager `modify-switch` | — (none) | new: `modify-switch <name> [--location <n>] [--description <d>] [--model <m>] [--ip <ip>] [--unset location,description]` on actual and desired |
| switch-manager `interrogate` (`.switches[k] * $controller`) | a controller's `location` would overwrite | the controller's `location`/`description` never overwrite the record's |
| switch-manager `list --json`, `show` | passes `location` | unchanged (the name); `validate`-style check in `list`: none |
| switch-manager `validate` | — (none) | new verb: each switch's and AP's `location` names a location; free text is reported with the fix (`modify-switch … --location`, the text into `--description`) |
| ap-manager `add --location` | free text | a location name; `--description` |
| ap-manager `modify` | — (none) | new: `modify <name> [--location] [--description] [--model] [--ip] [--unset …]` |
| ap-manager `list --json` / `show` | passes `location` | unchanged |
| ap-manager `validate` | — | the same check for APs (switch-manager's covers both files; ap-manager's names APs only) |
| setup-switches.sh | no location | unchanged |
| network-manager `topology.ts` `switchLoc` / AP location | `known(text) ?? primary` | unchanged: the name, else the primary; a seen device at a port takes its switch's (already) |
| console SidePanel (switch, AP) | location line from the topology | the name linked to the location (Site page); a "Location…" form: `modify-switch --location` / `ap-manager modify --location` with the locations as a dropdown |
| `lib/ts/src/locations.ts` `locationReferences` | — | names the switches and APs (`switch-configuration-desired.json switch <n>`) |

### Tests

module-manager `test.sh` + unit (validate, add flag translation), backup-manager
`cascade.test.ts` (a machine's `location`), network-manager `topology.test.ts` (node,
machine, satellite, switch/AP and seen locations), switch-manager `test-switch-manager.sh`
(`--location` refused when unknown, `modify-switch`, interrogate keeps it, `validate`),
ap-manager `test-ap-manager.sh` (the same), satellite `test.sh`, ui `wizards.test.ts`,
`fieldmanifest.test.ts`, a new `test-migration-0021-device-locations.sh`.

## Migration 0021 — `0021-device-locations.sh`

Idempotent; `--check` previews; refuses (writes nothing) when site.json has no `locations`
(0019 first).

1. **Machines.** Every `config/*.json` of `kind: machine` (not `*.orig`, not a peer file)
   with a `physicalLocation` object:
   - no country → refused with the file named (a person decides);
   - the location at the same place — country, city, building as the address, matched the
     way 0019 matches (case and spaces ignored, absent equal only to absent) — else a new
     location of kind `remote` named from the building, else the city, else the instance
     (the same transliteration as `locationName`), made free with `-2`, `-3`…;
   - the module gets `location: <name>`, `physicalLocation` goes;
   - a machine with both a `location` name and a `physicalLocation`: refused.
   An empty or null `physicalLocation` is dropped.
2. **Switches and APs.** In `switch-configuration-desired.json` and
   `switch-configuration-actual.json`, each switch's and AP's `location`:
   - a name of the site's locations → kept;
   - `""` or `null` → unset;
   - other text → appended to `description` (kept as it was when there is none, else
     `<description> · <text>` unless the description already contains it), `location` unset.
3. Reports one line per change.

Fixture test: hrossen's config copy (site.json with knudanchersvej95 and hareskov; tappaas1-3
pvehost with no place; the switch configuration with null and empty locations) plus a
synthetic satellite with `physicalLocation {FI, Helsinki}`, one at the primary's place, a
switch with the text "Rack 1" and one naming `hareskov`. Run, run again (no change), `--check`
writes nothing.

## As built

- The bash managers read the site's locations through `lib/locations.sh`
  (`site_location_refusal`), the TypeScript ones through `lib/ts/src/locations.ts`;
  module-manager's own rules are `src/location.ts`.
- `module-manager fields` probes every field with no value: a machine's `location` is then
  settable without a name being checked, a guest's is refused (not a machine).
- `ap-manager list` / `switch-manager list` show `at <location>` when one is named.
- The console's verb manifest for the bash managers (`ui/manifest/bash-verbs.json`) gained
  `modify-switch`, `validate`, `ap-manager modify` and `ap-manager validate`.
- The topology's Outside row for a satellite carries `at` (the location's name) beside its
  place text, so the device panel can link it.
- 0021 matches against the site's locations as they are before it adds any; two machines at
  one new place share the location it adds; a name another place holds gets `-2`.
