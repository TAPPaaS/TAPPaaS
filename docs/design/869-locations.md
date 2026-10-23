# #869 — site-manager owns locations, with a primary one

Working survey and plan for #869, step 1 of ADR-036's implementation plan (D1 and D5).
Today a place is recorded twice: `site.json` `location` (the site's own, with its time
and locale) and a backup peer's `physicalLocation` (`remote-`/`pull-`/`receive-<peer>.json`,
from `backup-manager peer add --country --city --building`). After this step both are
entries of one list, `site.json` `locations{}`, and the site's own is `primaryLocation`.

Out of scope (later steps of the ADR): a machine module's `physicalLocation` (the
satellite: step 3), rooms with a location (position-manager: step 2), a switch's
free-text `location` (step 3), the console's Physical view by location (step 4).

## The shape

```jsonc
"locations": {
  "rodovre":  { "displayName": "Rødovre", "country": "DK", "city": "Rodovre",
                "timezone": "Europe/Copenhagen" },
  "hareskov": { "kind": "remote", "country": "DK", "city": "Hareskov" }
},
"primaryLocation": "rodovre",
"locale": "en_US",
"keyboard": "dk"
```

| field | | change class |
|---|---|---|
| `locations` | map, key = the location's name (`^[a-z][a-z0-9-]{0,62}$`) | manual: its own verbs (`site-manager location …`) |
| `locations.<n>.name` | optional echo of the key | immutable: devices, rooms and peers name it |
| `locations.<n>.displayName` | the name shown; default the key | in-place |
| `locations.<n>.kind` | `site` (default: a place of this site's own equipment — its building, a provider's data centre) or `remote` (another site's place: a backup buddy) | in-place |
| `locations.<n>.country` | ISO 3166-1 alpha-2, **required** | in-place |
| `locations.<n>.city`, `.address` | the city; the street address or the provider and data centre (was `building`) | in-place |
| `locations.<n>.timezone` | IANA; **required on the primary** (it is the site's timezone) | in-place |
| `locations.<n>.latitude`, `.longitude` | a position is the place's, so they move with it (Home Assistant's core config, #348) | in-place |
| `primaryLocation` | names a location (`references: locations`) | in-place |
| `locale`, `keyboard` | site-wide (ADR-036 O3), no longer under `location` | in-place |
| `location` | **retired**: kept in the schema, described RETIRED, so a pre-0019 `site.json` is classified; `site-manager validate` refuses a `site.json` that still carries it (as for `organizations`, 0017) | — |

`required` gains `locations` and `primaryLocation` and loses `location`.

Validation (`site-manager validate`, TypeScript, after the schema check):

- `primaryLocation` names a location, and that location records a timezone;
- every location that something names exists (a peer's `location`; later rooms and devices);
- `site.json` carries no `location`.

`location delete` refuses the primary location and a location anything names; the error
lists what names it. Scanned: every `config/*.json` whose top-level `location` is a string
without a `/` (a peer today; a machine instance and a device from step 3 — a string with
`/` is the module directory field 0006 renamed, never a place), and `racks.json` /
`positions.json` `rooms{}.location` and `devices{}.location` (step 2).

## The helper — `lib/ts/src/locations.ts`

One implementation every manager uses; site-manager's verbs and backup-manager's
`peer add` both write through it.

| export | |
|---|---|
| `siteLocation(name?, configDir?)` | the named location, or the primary when no name; `null` when absent |
| `primaryLocation(configDir?)` | `siteLocation()` |
| `readLocations(site)` | `{ locations, primary }` from a parsed `site.json`; a pre-0019 one (only `location`) reads as one location named as the migration would name it, so a reader works in the window between the pull and the migration |
| `locationName(text)` | the name a migration or `--country/--city` gives: lower-case, ASCII (æ→ae, ø→oe, å→aa, ä/ö/ü→ae/oe/ue, ß→ss, accents dropped), non-alphanumerics → `-` |
| `findLocation(locations, place)` | the location with the same country, city and address (case and spaces ignored, absent = absent), or `null` |
| `addLocation` / `modifyLocation` / `deleteLocation` | the edits, returning the new document or throwing with the reason |
| `locationNamers(configDir, name)` | what names a location (above) |
| `locationErrors(site, configDir)` | the validation rules above |
| `siteLocale(site)` | `{ locale, keyboard }`: top level, else the retired `location.*` |

## Readers and writers

✱ = writes. Each row: today → after.

### Schemas

| file | today | after |
|---|---|---|
| `schemas/site-fields.json` | `location{country, timezone, locale, keyboard, city, building, latitude, longitude}`, required | `locations{}` (via `$defs.location`), `primaryLocation`, `locale`, `keyboard`; `location` RETIRED |
| `schemas/racks-fields.json` | a room's "building is the site's (site.json location)" | text only: "the site's primary location" (rooms get a location in step 2) |

### bash and jq

| where | reads | becomes |
|---|---|---|
| `lib/site-locale.sh` `site_locale_value` (timezone, locale, keyboard; every NixOS, Debian and Proxmox guest's time and keymap) | `.location[$k]` | timezone (and the other place fields) from `.locations[.primaryLocation]`, locale and keyboard from the top level; each falls back to `.location[$k]` until 0019 has run |
| `cluster/update.sh` step 5e (node timezone) | `.location.timezone` | the primary location's timezone, same fallback |
| `cluster/make-install-media.sh` `site_location` (country, keyboard, timezone defaults) | `.location[$k]` | as `site_locale_value` |
| `backup/lib/pbs-tunnel.sh` `bt_dial_command` (the `peer add pull` line for the other operator) | `.location.country/.city` | the primary location's; the printed command keeps `--country/--city` (the other site makes or matches a location from them) |
| `backup/scripts/remote/onboard.sh` (warns when no country) | `.location.country` | the primary location's country; the hint names `site-manager location modify` |
| `satellite/lib/satellite-lib.sh` (adds the vault's `remote` peer) | the satellite's `physicalLocation` → `peer add --country --city --building` | unchanged: `peer add` still accepts them and creates or matches a location |
| ✱ `manager/site-manager/create-site.sh` | writes `location{country, timezone, locale, keyboard}` | writes `locations{<name>: {country, timezone}}`, `primaryLocation`, `locale`, `keyboard`; the name from the site code (create-site knows no city) |
| `manager/site-manager/validate-site.sh` | the schema | unchanged (the schema changed); the reference rules are the TS validate's |

### Python

| where | reads | becomes |
|---|---|---|
| `controller/node-provisioner/answer.py` `answer_settings_from_site` (the PXE answer file's country, keyboard, timezone) | `site["location"]` | `locations[primaryLocation]` for country and timezone, `site["keyboard"]`; the retired shape still read |

### TypeScript

| where | reads | becomes |
|---|---|---|
| ✱ site-manager `site show` / `site modify` (`--locationCountry/Timezone/Locale/Keyboard/City/Building/Latitude/Longitude`) | `site.location` | `site show` prints the primary location and the others' names; `site modify` gains `--primaryLocation`, `--locale`, `--keyboard`; the `--location*` flags stay one release as hidden aliases (`--locationLocale/Keyboard` → the top level, the others → the primary location) |
| ✱ site-manager `location list/show/add/modify/delete` | — | new; `add/modify/delete` take `--check` (the console's preview); `delete` is destructive (typed name) |
| site-manager `config.ts` `loadSite`, `types.ts` `Site.location` | `location` | `locations`, `primaryLocation`, `locale`, `keyboard` through `readLocations` |
| health-manager `checkSiteTimezone` (the `site-timezone` gate) | `location.timezone` | `primaryLocation()`; the fix hint becomes `site-manager location modify <primary> --timezone <tz>` |
| backup-manager `offsite.ts` `sitePlace` / `offsiteTargets` / `offsiteWarnings` (validate's off-site check) | `site.json` `location` vs a peer's `physicalLocation` | the primary location vs the peer's `location`, both through the helper; same rule (country, city, address; `address` is the old `building`); a peer naming the primary itself is "same". A satellite's `physicalLocation` is read as before (step 3), and a machine's `location` name is resolved when present |
| ✱ backup-manager `peer add` (`--country --city --building`, `physicalLocation`) | writes `physicalLocation` | `--location <name>` (must exist); `--country [--city] [--building]` still accepted: `findLocation` or a new `kind: remote` location, then the peer gets `location`; both refused together |
| backup-manager `listPeers` / `peers` (text and `--json`) | `physicalLocation` | `location` (the name) and `place` (resolved: displayName, country, city, address); an unmigrated `physicalLocation` still shows as the place |
| network-manager `topology.ts` (a buddy's `location` text on the Outside lane) | `backup-manager peers --json` `physicalLocation` | the row's `place` (displayName, else city, country), the old field as fallback |

### Console (`ui/`)

| where | today | after |
|---|---|---|
| `src/fieldmanifest.ts` `FLAGS.site.modify` | `location.*` → `--location*` | `primaryLocation`, `locale`, `keyboard`; new kind `location` (add and modify flags), name field `name`; `RefContext.locations` for `primaryLocation`'s choices |
| `src/reads.ts` `fields(site)` | `site-fields.json` | unchanged for `site`; `fields(location[/<name>])` from `$defs.location` with the record from the site read |
| `web/src/pages/Site.tsx` Site card | the `location` block | the primary location (name, address, timezone, coordinates), locale and keyboard; a Locations section listing the others with Add, Modify (the schema forms) and Delete (destructive: the typed name) |
| `web/src/pages/Backup.tsx` (buddies) | `physicalLocation` city, country | the buddy's location by name, its place as the title |
| `web/src/physical/SidePanel.tsx` (a buddy's panel) | the topology's `location` text | unchanged (the topology resolves it) |
| `web/src/wizards.ts` (satellite add `--physicalLocation`) | | unchanged (step 3) |

### Tests that build a `site.json` with `location`

`site-manager/test.sh` (the location block), `scripts/test/test-site-locale.sh`,
`node-provisioner/src/test/test_answer.py`, `health-manager/test/unit/timezone.test.ts`,
`backup-manager/test/unit/cascade.test.ts` (off-site), `backup/lib/test-pbs-tunnel.sh`,
`network-manager` topology fixtures. Each keeps its old-shape case (the fallback) and gains
the new shape. Fixtures that only need some `site.json` (`environment-manager/test.sh`,
`update-tappaas/test.sh`, migration 0010's test, `test-nix-site-key.sh`) are left: they do
not read the place.

### Docs

`site-manager/README.md` (location verbs, `site modify` flags, the locale section),
`backup-manager/README.md` (peer add, the off-site check), `backup/README.md` and the peer
templates `scripts/pull/pull.json`, `scripts/remote/remote.json` (`location` instead of
`physicalLocation`), `health-manager` README/DESIGN (the gate's source), `cluster/README.md`
(step 5e), `src/DATAMODEL.md` (locations in the diagram; site → locations, peer → location;
finding 2 partly closed), ADR-036 implementation plan step 1 marked built,
`migrations/README.md` (0019's row).

## Migration 0019 — `0019-site-location-becomes-locations.sh`

Touches `config/site.json` and `config/{remote,pull,receive}-*.json`. bash + jq only.
Reversible: restore `config/.migrations/backup/0019/`.

1. **The site.** When `site.json` has `location` (an object):
   - name = `locationName(building)`, else `locationName(city)`, else `locationName(site.name)`,
     else `site`;
   - `locations[name] = {country, city?, address: building?, timezone, latitude?, longitude?}`
     (`displayName` = the building or city as written, when either is);
   - `primaryLocation = name`; `locale` and `keyboard` move to the top level (an existing
     top-level value wins and the difference is reported);
   - `location` is deleted.
   When `site.json` already has `locations` and `primaryLocation` and no `location`, this
   part has nothing to do.
2. **The peers.** For each peer file with a `physicalLocation` object:
   - an existing location with the same country, city and address (building) — compared
     trimmed and case-insensitive, absent equal only to absent — is reused; this is
     stricter than country and city alone on purpose, so no peer's off-site verdict
     changes (a peer in the site's city but another building stays "separate", and one
     that recorded no building stays "unproven");
   - otherwise a new location `kind: remote`, named `locationName(building)`, else
     `locationName(city)`, else `<peer>`; a name already taken by a different place gets
     `-2`, `-3`, …;
   - the peer gets `location: <name>`, `physicalLocation` is deleted.
   A peer already naming a location is left alone.
3. **Refuses**, changing nothing: a `site.json` that is not an object; a `location` that is
   not an object or has no country; a `primaryLocation` naming no location; a peer's
   `physicalLocation` with no country; a peer carrying both `location` and
   `physicalLocation`; a peer's `location` naming no location.

`--check` reports each rewrite and writes nothing. A second run finds nothing to do. Every
file it writes is backed up first.

Fixture test (`scripts/test/test-migration-0019-locations.sh`): hrossen's `site.json`
(the topology fixture's, city Rodovre) and its buddy `rasmus` (`remote-rasmus.json`,
DK/Hareskov): → `rodovre` primary, `hareskov` kind remote, the peer names it, `locale` and
`keyboard` at the top; `--check` writes nothing; twice is a no-op; the backups hold the
pre-images; a second peer at the same place shares the location; a peer in the site's own
place maps to the primary; a name clash gets `-2`; each refusal leaves every file as it was.

## As built

- The peers recorded their place as `physicalLocation {country, city, building}`, not as
  top-level `country`/`city`; the building became the location's `address`.
- Two readers the survey missed: the console's Physical heading (`web/src/physical/views.ts`
  `sitePlace`) now reads the primary location, and the buddy wizard offers `--location`.
- `lib/ts` `moduleSourceOf` and `isModuleConfig`, and the opnsense-controller's
  `module_source_of`, read a top-level `location` as a module directory only when it holds a
  `/`: a location's name never does, so a peer's or (later) a device's `location` is never
  taken for a module path. The bash `.moduleSource // .location` readers are left as they
  are — every module config has `moduleSource` since 0006, so they never reach `location`.
- `site modify --locationCountry/Timezone/City/Building/Latitude/Longitude` stay hidden for one
  release and write the primary location; `--locationLocale/Keyboard` write `locale`/`keyboard`.
- On hrossen's config copy, 0019 names the primary `knudanchersvej95` (its building) and the
  buddy rasmus's place `hareskov` (kind remote); `site-manager validate` and
  `backup-manager validate` pass, and rasmus stays "separate" (no off-site warning).
