# ADR-040 step 4: the topology from the CMDB

Design note for `network-manager topology` as a view of the CMDB (ADR-040 D10, plan step 4;
ADR-036 D4 as amended). Written against the live CMDB on hrossen, 2026-10-30, before coding.

## The approach

`buildTopology()` is pure: it takes a `TopoSources` and joins it. It stays the one join.
A new reader, `sourcesFromCmdb()` (`manager/network-manager/src/topology-cmdb.ts`), turns the CMDB's
objects and relations into a `TopoSources`, and `buildTopology()` builds the same document from it.
Every reconciliation rule (LLDP spelling, MLAG, LAG leads, WAN roles, seen devices, findings) keeps
one implementation, so the two paths cannot disagree on logic, only on data. `topology --diff`
measures that disagreement.

The read is two calls: `POST /v1/query {class: "object"}` and `POST /v1/relations {}`.

Fallback: the live join runs, with a line on stderr saying why, when the CMDB does not answer, when
`TAPPAAS_CMDB=off`, or when it answers without the data this note adds. The last case is what makes
the rollout safe: until the new reports have run, `topology` behaves as it does today.

## Field by field

"Report" names the owner who sends it; **new** is a field added to the metamodel by this step. In
the live CMDB of 2026-10-30, everything marked new is absent.

### `site`

| Field | Today | CMDB |
|---|---|---|
| `name`, `displayName` | site.json | `site` name, displayName |
| `wan.publicIp`, `wan.isp`, `wan.ipv6` | site.json | **new** `site.publicIp`, `isp`, `ipv6` (site-manager) |
| `wan.discovered` | wan-address.json | stays read: see the exceptions |
| `wan.zone`, `wan.vlan` | zones.json | `zone` (below) |
| `wan.handoff`, `wan.paths` | derived | derived in `buildTopology` |
| `wan.firewall` | module list, network.json | `vm` network: `vmid`, `runs-on`, **new** `node.haNode` (module-manager) |
| locations (used by `positions`, `outside`) | site.json | `location` objects; primary from the site's `at` relation |

The live CMDB holds a stray `site` object `s` beside `rossen`; the reader takes the site that has an
`at` relation, the one every site-manager report makes.

### `nodes[]`

| Field | Today | CMDB |
|---|---|---|
| `name`, `storagePools` | site-manager node list | `machine` with `clusterMember`, `storagePools` |
| `uplinks`, `ha`, `corosync`, `lldpd` | `node network show`, one ssh per node | **new** `machine.network`, volatile: that verb's document (site-manager) |
| `guests[]` | module list | `vm`, `lxc`, `app` with `desired`: `vmid`, `release`, `stack`, `runs-on`, `member-of` environment, **new** `node.zone`, `node.maturity`, `node.state` (volatile), and on `app` **new** `moduleNode` (the node the module names; a CI needs a host, the module may name none) |
| `roles` | derived | derived |
| `location` | machine's config | `at` relation |
| `placement` | positions | `placed-in` through `allocated-to` |

`machine.network` is one attribute rather than a CI per NIC, for the reason `cmdb-discover.ts`
gives: a port cannot exist without an asset, and a sweep never invents one. Keeping the verb's
document also keeps `buildTopology`'s LLDP reconciliation unchanged.

### `switches[]`, `mlagPairs[]`

| Field | Today | CMDB |
|---|---|---|
| `name`, `model`, `managementIp`, `controller` | switch-manager list | `device`: name, `model`, `managementAddress`, `controller` |
| `vendor`, `managed`, `controllerAddress` | switch-manager list | **new** `device.vendor`, `managed`, `controllerAddress`, and `deviceType` to tell a switch from an AP |
| `ports[]` | list-ports (the actual file, plus drift against zones.json) | **new** `port.assignment`, volatile: that verb's row, the actual's peer-link facts, and the switch it belongs to |
| `lags[]`, `mlagPairs[]` | lag list, actual file | **new** `device.lags`, `device.mlag` (carries the pair) |
| `location` | inventory | `at` relation, each in its own report (the location may not exist yet) |

A port carries its switch's name in `assignment`: `part-of` leads to the asset, and the
asset-to-device link cannot be relied on (see below). When two port objects claim one switch port,
the one seen last wins.

### `accessPoints[]`

Today ap-manager list, which reads the desired file. **New** `device.uplink`, `device.ssids`,
`device.vendor`, `device.deviceType` (ap-manager); `model`, `managementAddress` exist; location by
`at`. The uplink is an attribute although a `connects` exists: following that relation needs the
same asset-to-device link.

### `zones[]`

`zone`: `vlan`, `subnet`, `tier`, `serves` relation for environments; **new** `zone.state`, `type`,
`bridge` (network-manager). `tier` is stored as a string and read back as a number. A CMDB answer is
ordered by name, zones.json is not: the order changes, `--diff` compares by name.

### `outside[]`

Buddies: `backup-peer`, `at` relation to its `location`; **new** `backup-peer.role`, `remoteHost`,
`tunnel` (backup-manager). Satellites: `machine` not in the cluster whose `release.module` is
`satellite`, `addresses`, `at`. The pulse's `state` comes from the health below.

### `devices[]`, `positions`

Machines and devices: the node CIs with a module `desired` record. Recorded devices, racks, rooms,
placements and cables: `asset`, `port`, `rack`, `room`, `placed-in`, `connects` and `allocated-to`,
through `positionsFromCmdb()`, which moves from asset-manager to `lib/ts/src/positions-cmdb.ts` so
network-manager can use it. It now reads only what asset-manager recorded (`recorded: true`): the
store also holds switch-manager's assets and cables, which are not positions. The faceplate catalog
stays read from asset-manager: see the exceptions.

### `findings[]`

`--health <file>` works as today. Otherwise the health is `site.attributes.assessment.gates`, which
`health-manager assess` stores with the same findings and subjects as `validate --json`; the
topology no longer runs validate. Per-object `conditions` are the same assessment split by object
and carry no gate, so the gate document is the one read. Topology findings are derived.

### `sources`

The read names what it read: `cmdb`, `asset-manager export`, `wan-address.json`. Two rows,
`cmdb: nodes` and `cmdb: switches`, go `ok: false` with the age when no report has come for more
than 30 minutes, which the console already shows as a source not answering.

## Gaps

Each is a richer report from the owner unless it is listed under exceptions.

| Gap | Owner | Fix |
|---|---|---|
| WAN settings on the site | site-manager | `site.publicIp`, `isp`, `ipv6` |
| A node's uplinks, HA, corosync, lldpd | site-manager | `machine.network`, one more read per node in `report` |
| Guest run state | module-manager, site-manager | `node.state` |
| Maturity, zone, HA node, an app's named node | module-manager | `node.maturity`, `zone`, `haNode`, `app.moduleNode` (and the same on `app`) |
| Port assignment, drift, LAG, MLAG | switch-manager | `port.assignment`, `device.lags`, `mlag` |
| Switch vendor, managed, controller address, type | switch-manager | `device` fields |
| AP uplink and SSIDs per AP | ap-manager | `device.uplink`, `ssids` |
| Zone state, type, bridge | network-manager | `zone` fields |
| Peer role, host, tunnel | backup-manager | `backup-peer` fields |
| Which ports are the plate's, switch order | asset-manager, switch-manager | `port.plate`, `device.order` |

### Exceptions: what keeps being read

- **`wan-address.json`.** network-manager's own record, on this host, written by its own update.
  Reading it touches no plane, and copying it into the CMDB would give network-manager a report
  to itself.
- **The faceplate catalog.** A static catalog shipped with asset-manager and the module faceplates:
  reference data, not actual state. ADR-040 does not model it.

### Data problems found on hrossen

- `allocated-to` on hrossen says `sw-02` → `usw`, `ap-01` → `ap1`, and positions.json says `crs-a`
  and `Nano HD`: the relations are older than the record. A placement read through them lands on
  a stale name until `asset-manager report` runs again. Report it with the diff; do not work
  around it.
- The sweep marks `allocated-to` drift on switches because asset-manager's relation replaces
  switch-manager's. Neither is used for ports or APs here, for that reason. A separate fix.

### Found by the comparison on hrossen

- A gate of the stored assessment holds its findings in `rows`, `findings` or both, and neither when
  it passed. `validate --json` prints them together; the reader does the same.
- A recorded cable to a NIC the server does not list (hrossen's panel to `tappaas2`) was skipped by
  asset-manager's report, so panel chains lost their second half. The cable now makes the port.
- The CMDB holds an asset's plate ports as well as its own, and positions.json only the own: **new**
  `port.plate` (asset-manager) tells them apart.
- Which end a cable between two switches starts at, and so which LAG name it shows, follows the
  inventory's order, which a CMDB answer does not keep: **new** `device.order` (switch-manager).
- `asset-manager report` joins `cmdb-refresh`: it also ends the stale `allocated-to` above.

### Found at the first deployment, 2026-10-31

- The reader needed `network-manager report` and `backup-manager report` too (zone state, peer
  roles) and fell back to the live join until they had run once: both join `cmdb-refresh`.
- The store answers objects by class then name, so a server's ports (`port` < `server`) came
  before the server and were dropped: tappaas4's nine NICs were missing, and a panel's ports read
  back as `1, 10, 11, …`. `positionsFromCmdb` now takes the assets first and keeps ports in natural
  order.
- The live CMDB held test fixtures: four switches, three access points and a probe from
  switch-manager and ap-manager test runs made before their asset-manager stub existed, and a site
  with two locations from a site-manager unit test run by hand. `cmdbReport` ignored
  `TAPPAAS_CMDB=off` (only the reporter above it checked), and a unit test run outside `test.sh` set
  nothing. Both fixed; the fixtures were ended in the CMDB by hand.
- Two NICs the CMDB knew from cables and site-manager's reads (srv-02 enp97s0, srv-03 eno1) were not
  in positions.json, which predates D8's recording of a new node's NICs: recorded with `port add`.
  After that, `topology --diff` on hrossen: the CMDB and the planes agree.

## Freshness

The live join is as fresh as its last read. The CMDB is as fresh as its last report, and the two
reports that matter do not run on a cadence: site-manager and module-manager report on change and
at the nightly sweep. A link going down, or a guest stopping, would reach the Physical view up to a
day late, where the console sees it within 5 minutes today.

So a new unit, `cmdb-refresh`, runs `site-manager report`, `module-manager report`,
`switch-manager report`, `ap-manager report`, `asset-manager report`, `network-manager report` (the
zones' state) and `backup-manager report` (the peers' roles) every 5 minutes. D4's "no new polling" holds in
substance: the console's 5-minute `topology` stops doing the same ssh per node, so the planes see
the same load, once. The switch and asset reports read files, as `list-ports` does, and need no
switch traffic. The stale rows in `sources` say when the unit is not doing its job.

A node that cannot be read keeps its last `network`: the health findings say it is down, the
uplinks show how it was. The live join shows it with no uplinks instead. This is a change, and
`--diff` shows it.

## The comparison, 2026-10-30

Nothing here was deployed, so the live CMDB lacks the new fields and `topology --diff` on hrossen
exits 2, naming them; `topology` falls back as designed. For the comparison, a scratch build printed
every report with `report --json` (read-only), overlaid them in memory on the live CMDB's answer,
and built both documents: **no difference** in nodes, switches, ports, LAGs, access points, zones,
WAN, outside, devices, positions or findings, on hrossen's real data (`generated` and `sources`
aside). One line remained, the primary location's `displayName`, caused by the overlay dropping a
location object: not a report's or the reader's. Zones were overlaid from zones.json, not from
network-manager's report, which asks the firewall. The real `--diff` is step 4 below.

## Migration order

1. This note.
2. Metamodel fields, the reports, `positions-cmdb.ts`, `cmdb-refresh`.
3. `topology-cmdb.ts`, `--live`, `--diff`, tests. `topology` falls back while the data is missing.
4. Deploy, first reports run, `topology --diff` on hrossen: the differences left go into this note.
5. Physical view from the CMDB in the console (the rest of plan step 4), which this does not do.
   Later, per field, `--live` can go once `--diff` stays empty.
