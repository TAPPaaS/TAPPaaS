# #865 — the zone names its environment

Working survey and checklist for #865 (src/DATAMODEL.md finding 1). Today the
environment ↔ zone link runs both ways:

- `environments/<env>.json` → `network.zone` names the environment's service zone;
- `zones.json` → `<zone>.serves` (a string or a list) names the environment(s) a
  Client, IoT or Guest zone serves.

Decision: the zone references the environment; nothing points the other way. A zone
gets one field, `environment`:

| zone type | `environment` means | |
|---|---|---|
| Service | the environment whose service zone this is | exactly one Service zone per environment |
| Management | the `mgmt` environment (its zone is the Management zone) | counts as that environment's own zone |
| Client, IoT, Guest | the environment it serves (derives the edges `serves` derived) | optional |
| DMZ, Overlay, WAN | — | must not carry it |

`environment.network.zone` and `zone.serves` go. An environment's zone is the
Service (or Management) zone naming it; the zones an environment owns are the zones
naming it.

## Several environments per zone — decided, then revised

The brief said: a zone serves one environment only; if hrossen or the docs rely on a zone
serving several, say so and stop before breaking it.

- **hrossen** does not: every `serves` was a single string (`home`, `iotLocal`, `iotCloud`,
  `iotCams` → `rossen`), and its three environments map one-to-one: `mgmt`→`mgmt`
  (Management), `rossen`→`rossen`, `test`→`test` (Service).
- **The docs** did: ADR-014 v1.3 D2 (`serves` as a list, `bind --add`) and ZONES.md (a
  workstation zone reaching a production and a development environment).

First decision (operator, 2026-10-23): one `environment` per zone (ADR-014 v1.4).

Revised the same day (ADR-014 v1.5), after the operator checked the v1.3 history: another
installation has a client zone reaching every work environment (one service zone per client of
the business), where naming the environments is more natural than authoring `access-to`
entries. The direction stays zone → environment, but:

- a Service or Management zone names exactly one environment, as a string, and every
  environment is named by exactly one such zone;
- a Client, IoT, Guest or DMZ zone names one environment or a non-empty list of distinct,
  existing ones; the render takes the union (`access-to` for Client/Guest,
  `pinhole-allowed-from` for IoT), as v1.3 did;
- `bind --environment` replaces, `--add` adds one, `--unbind --environment` removes one (the
  field goes with the last); `zoneEnvironments(z)` reads the list where a reader means
  "serves", `zoneEnvironment(z)` the single string where it means "is the service zone of"
  (environment-manager's lookup, `environment_zone`, `install-module.sh`, `environmentZoneIn`);
- migration 0018 (amended in place before any release) carries a `serves` list over as the
  list; it refuses only a zone two environments name as their own, and a `serves` or existing
  `environment` that disagrees with the environment naming the zone as its own.

`environment` keeps the change class `serves` had, `manual` ("has a verb of its own"), not
`in-place`: `modify --set` would bypass `bind`'s one-zone-per-environment guard, and the
console's zone form already offers Bind for it.

## Readers and writers

Each row: where, what it does with the link today, what it becomes. ✱ = writes the field.

### Schemas

| where | today | becomes |
|---|---|---|
| `schemas/environment-fields.json` `network` (required, `network.zone` references zones) | the env's zone | `network` removed; `required` loses it; description no longer mentions a zone |
| `schemas/zones-fields.json` `serves` (string or array, references environments, `changeClass: manual`, appliesTo Client/IoT/Guest) | consumer link | replaced by `environment` (string, references environments, in-place, appliesTo Service/Management/Client/IoT/Guest) |
| `schemas/module-fields.json` `zone0.note` | "defaults to the target environment's network.zone" | "the zone naming the target environment" |

### network-manager (TypeScript)

| where | today | becomes |
|---|---|---|
| `src/serves.ts` `environmentZone(configDir, env)` | reads `environments/<env>.json` `.network.zone` | lookup by zone: the Service/Management zone in the same zones doc whose `environment` is env |
| `serves.ts` `servesList`/`servesValue` | string-or-list reader/writer | one `zoneEnvironment(z)` reader |
| `serves.ts` `resolveServes` | per consumer zone, per environment: derive `access-to` (Client/Guest) or `pinhole-allowed-from` (IoT) += the env's service zone | same derivation from `environment` on Client/IoT/Guest; the env's service zone found in the same doc; errors: env file absent, no service zone names it, two do, `environment` on DMZ/Overlay/WAN |
| `serves.ts` `environmentZoneMap`, `backfillServes` (merge) | literal service-zone ref → `serves` | literal → `environment`, the map from the Service zones' own `environment` |
| `src/types.ts`, `src/zones.ts` (`Zone.serves`, `add` writes `serves`) ✱ | field + writer | `environment` |
| `src/main.ts` `add --serves` ✱ | binds a new consumer zone | `add --environment` (Service archetype too); `--serves` kept as an alias for one cycle |
| `src/main.ts` `bind <zone> --environment [--add] [--unbind]` ✱ | edits `serves` on Client/IoT/Guest | sets/clears `environment` on any zone that may carry it; refuses a second Service zone for an environment; `--add` goes |
| `src/main.ts` `list --type Client` | serves column | environment column, all types |
| `src/main.ts` `render`/`reconcile` messages | "serves link(s)" | "environment link(s)" |
| `src/zonescheck.ts` `checkServes` (validate) | resolves `serves`, errors | checks `environment`: it exists; one Service zone per environment; every environment has one (when `environments/` is present); type allowed |
| `src/zonesmerge.ts` `AUTO_FIELDS = {state, serves}` | operator-pinned on merge | `{state, environment}` |
| `src/zonesinit.ts` rename `srv`→`<N>` rewrites `serves` | template placeholder follows the rename | rewrites `environment` (the service zone's and the consumers') |
| `src/topology.ts` `serves: string[]` per zone | topology read for the console | `environment: string \| null` |
| `src/zonelifecycle.ts`, `src/reconcile.ts` | call `refreshEffective` (comments only) | wording |
| `zones.json` (template) `serves: "srv"` on home/iot*; `_README.authored_vs_effective` | placeholders | `environment: "srv"` on the consumers and on `srv`; `environment: "mgmt"` on `mgmt` |
| `test/unit/network.test.ts` (~60 sites), `test.sh` zinit check, `test/fixtures/topology-hrossen/zones.json` | serves fixtures + #576 tests | environment fixtures; env files lose `network` |

### environment-manager (TypeScript)

| where | today | becomes |
|---|---|---|
| `src/types.ts` `Environment.network: NetworkRef` | the env's zone | removed; `RefSources` gains `zones: Map<name, {type, environment}>` |
| `src/config.ts` load (`network: {zone}`), `semanticCheck` (zone exists) | | load drops it; check: exactly one Service/Management zone names the env (warning when zones.json absent) |
| `src/validate.ts` (schema + refs, `network.zone` must exist) | | same rule as above |
| `src/bootstrap.ts` ✱ `mgmt`→`mgmt`, `<N>`→`<N>` | writes `network.zone` | writes no zone; the template's `mgmt`/`srv`→`<N>` zones carry `environment` already |
| `src/main.ts` `list`, `show` (zone column/row) | reads `network.zone` | the zone naming it |
| `src/main.ts` `add --zone Z [--create-zone]` ✱ (default Z = env name) | writes `network.zone` | writes the env, then `network-manager bind Z --environment <env>` (or `add Z --archetype service --environment <env>` with `--create-zone`); rolls the env file back if that fails |
| `src/main.ts` `modify --zone Z` ✱ | rewrites `network.zone` | `bind` Z, `bind --unbind` the old one |
| `src/reconcile.ts` `computePlan` (create-service-zone, Client/IoT zone error, wildcard zone) | reads `network.zone` | no Service zone names it → create `<env>` with `--environment`; `<env>` exists but is not Service → error |
| `src/clients.ts` `NetworkClient` | `createServiceZone(zone)` | `createServiceZone(zone, env)`, `bindZone(zone, env)`, `unbindZone(zone)` |
| `test.sh`, `test/unit/{config,validate,main,reconcile}.test.ts` | env fixtures with `network` | zones fixtures name the env |

### module-manager and shared bash

| where | today | becomes |
|---|---|---|
| `lib/common-install-routines.sh` `get_variant_config` → `.zone` | `.network.zone` | new `environment_zone <env>`: the Service/Management zone in zones.json whose `environment` is env |
| `module-manager/install-module.sh` `env_zone` (l.222) and default-zone step 3 (l.149) | `.network.zone` of the env file | `environment_zone` |
| `module-manager/test.sh` (default zone, `--environment foo → fooZone`), `test/fixtures/config/environments/dev.json` | env fixtures | zones fixtures carry `environment` |
| `lib/test-config-readers.sh` (`.zone` of get_variant_config) | | fixture zones name the envs |
| `test-variants/test-variant-{config,dns,install,zone-node}.sh`, `network/test-variant-public.sh` ✱ | write env files with `network.zone` | write the zone's `environment` |
| `scripts/test/test-identity-unpublished.sh`, `backup-manager/test.sh`, `network-manager/test.sh` fixtures | env files carry `network` | drop it (schema would refuse it) |
| `cluster/lib/vm-net.sh` | reads neither (zone → vlantag only) | nothing to move |

### Module test.sh scripts

| where | today | becomes |
|---|---|---|
| `identity/test.sh` l.371 | default env's `.network.zone` → OIDC test VM FQDN | `environment_zone` |
| `network/test.sh` l.1457 / 2220 | default env's `.network.zone` → SNAT source zone | `environment_zone` |
| `network/test-fixtures/test-zones.json` `snat_note` | text | wording |

### Console (ui/)

| where | today | becomes |
|---|---|---|
| `src/reads.ts` l.374 `envs[].zone` | `e.network?.zone` | the zone naming the env (from the zones read) |
| `src/fieldmanifest.ts` env add/modify `network.zone` → `--zone`, add default `<name>` | form field | a non-schema `zone` field kept on the env form, still `--zone`; zone form gains `environment` (`bind --environment`) |
| `web/src/envcards.ts` owned = `network.zone` + zones serving it | | zones naming it; own zone = the Service/Management one |
| `web/src/pages/Environments.tsx` "its own zone" / "serves it" | | own zone vs serves it, from the zone's type |
| `web/src/pages/Zones.tsx` sub-line "serves …", graph | | "environment …" |
| `web/src/consoletargets.ts` assistant target text names `network.zone` | | `zone` |
| `test/fixtures/{zones,environments,topology,topology-racks}.json`, `test/unit/{forms,fieldmanifest,server,wizards}.test.ts` | serves / network.zone | environment |
| `web/src/wizards.ts`, `pages/Buddy.tsx` | "serves" is English there (tunnels) | nothing to move |

### Python controllers

None read either field: zone-manager, rules_manager and the Caddy access lists read
`zones.effective.json`, whose derived edges stay the same.

### Docs

| where | becomes |
|---|---|
| ADR-014 (D1, D2 incl. v1.3 several-environments, lifecycle text) | the zone names its environment |
| ADR-007c (Environment fields, `network.zone`) | an environment's zone is the zone naming it |
| environment-manager README / DESIGN | `--zone` binds a zone; no `network` |
| network-manager README, DESIGN, ZONES.md, FIREWALL-RULES.md (example, diagram edge) | `environment` |
| module-manager DESIGN l.282, cluster lxc/vm README zone0 note | the zone naming the environment |
| `src/DATAMODEL.md` diagram `ENV -- network.zone --> ZONE`, table, finding 1 | edge reversed `ZONE -- environment --> ENV`, finding 1 resolved |
| `migrations/README.md` | row for 0018 |

Design and history docs (`docs/design/ADR-0*-implementation*.md`, zone-rules-review,
plans) record what was done at the time and are left as they are.

## Migration 0018

`0018-zone-names-its-environment.sh`, zones.json and environments/*.json:

1. each environment's `network.zone` Z → `zones.Z.environment = <env>`;
2. each zone's `serves` → `environment`;
3. refuses, changing nothing, when a zone would get two environments (two env files
   naming it, a `serves` list of more than one, or `serves` disagreeing with the env file
   naming it), when an env names a zone that does not exist, or when two Service zones
   would name one environment;
4. removes `network` from every env file and `serves` from every zone; backs up both.

hrossen's expected result: `mgmt`→mgmt, `rossen`→rossen, `test`→test,
`home`/`iotLocal`/`iotCloud`/`iotCams`→rossen.

## Appendix — shared service zones (#876, ADR-014 v1.6)

Found on a site update on 2026-10-24: a business runs one work environment per customer, each with
a Service zone of its own (`gridtefy`, …), and a Service zone `srvWork` that all of them use. Before
#865 `srvWork` carried `serves: [gridtefy, …]`; the #865 rule "every environment is named by exactly
one Service or Management zone" then refused the site (`srvWork` was counted as a second zone of
`gridtefy`), the network module rolled back and every module needing pinholes drifted.

Decision: the shape of a Service zone's `environment` says its role.

| `environment` on a Service zone | role |
|---|---|
| a string | the environment's **own** zone: its default install place, its domain; exactly one per environment (Service or Management) |
| a list, even of one | a **shared service zone**: serves the environments it lists, owns none, a valid `zone0` for a module of any of them, derives no edge |

What changed, per reader and writer of the survey above:

| where | becomes |
|---|---|
| network-manager `linkErrors` (validate, render) | a list on a Service zone is shared: each name must exist; only single-string Service/Management zones count as own; a list on the Management zone stays an error |
| network-manager `resolveServes` | unchanged: consumer zones reach the own zone; a shared zone derives nothing, so the effective graph is the same with or without it (unit-tested over the fixture `test/fixtures/shared-service-zone`) |
| network-manager `bind` | `--add` on a Service zone makes it shared (string → list); a plain `bind` on a shared zone is refused; `--unbind --environment` back to one leaves a list of one, `--own` turns it into that environment's own zone; `add --environment a,b` on a Service zone authors a shared one |
| network-manager `serves.ts` | `isSharedServiceZone`, `sharedZonesOf`; `zoneEnvironment` (the single string) already excluded lists |
| environment-manager `config.ts` | `ZoneLink.shared`, `sharedZones()`; `zoneLinkErrors` names a shared zone that serves an environment without an own zone |
| environment-manager `list` / `show` | own zone, then the shared zones; `add|modify --zone` refuse a shared zone |
| `lib/common-install-routines.sh` | `environment_zone` unchanged (own only); new `environment_shared_zones`, `validate_zone_environment` |
| `install-module.sh` | an explicit `zone0` that is a shared zone not listing the module's environment is refused |
| module-manager `validate` | the same check, `zoneEnvironmentRefusal` |
| console `reads.ts`, `envcards.ts`, `Environments.tsx`, `Zones.tsx`, `zonegraph.ts` | `sharedZones` on the environments read; a card shows its own zone, then each shared zone marked "shared with <others>"; the graph labels a shared zone's edges `shared · <envs>` |
| `schemas/zones-fields.json` | `environment` description and change note |
| migration 0018 | a Service zone no environment names as its own that carries `serves` becomes a shared zone, its list kept even of one (it was refused, and an already-migrated list of one would have been collapsed into a second own zone); the fixture test gains the shape |

Validate on the fixture, before: `✗ environment: zone 'srvWork' is a Service zone and names
["gridtefy","acmeco"] — a Service zone is the zone of exactly one environment, named as a string`
(rc 1). After: `✓ environment: 8 zone(s) name an environment …` and `· environment: shared service
zone(s): srvWork→gridtefy,acmeco` (rc 0); environment-manager validate passes both times.
