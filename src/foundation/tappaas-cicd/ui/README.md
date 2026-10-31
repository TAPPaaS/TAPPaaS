# console — the TAPPaaS console (ADR-034)

The site's web UI: its health at a glance, the site drawn as it is cabled, the modules and
what the sweep did, and every change to the site as a job that runs a manager verb with its own
preview. A service of the mothership (`tappaas-console.service`, run as `tappaas`), published
through Caddy and the Authentik gate by the thin `console` module
([`../../console/`](../../console/)). Phases **P1 — see**, **P2 — operate** and **P3 —
ask** (the assistant, below); agents (P4) come later
([ADR-034](../../../../docs/ADR/ADR-034%20-%20TAPPaaS%20User%20Interface.md), Implementation plan).

```
ui/
├── src/            the backend (TypeScript, no npm dependencies, built like a manager)
├── web/            the front end (Vite, React, React Flow; built by default.nix)
├── test/           unit tests over hrossen's captured outputs (test/fixtures)
└── default.nix, install.sh, update.sh, test.sh
```

## Pages

**Setup** (ADR-034 D10) — shown first while the site is incomplete: the checklist `GET
/api/v1/setup` derives from the records each time (`src/setup.ts`, so it resumes): TLS
(wildcard: `config/cert-refids.json` names the default environment; per-service: nothing to
issue), backup, identity and logging (`config/<m>.json`, and `module test` passed the last
time it ran — the three tests run only as jobs, never on a read: the page's Check button
(`POST /api/v1/setup/check`, a read job per installed module, each with its status line, its
Stop and its output above the checklist) or a step's Test; each result and its time is kept in
`<state dir>/setup-tests.json`), the
identity bootstrap (`config/identities` has an organization and a user),
the nodes (every registered node — its `pvehost` instance — a cluster member, lib/ts `queryClusterNodes`), the switch
(registered, ports discovered), the admin VPN (a peer in `wgvpn list`), the physical site
(optional: a room recorded and every node and switch placed, from `config/positions.json`), stacks (optional).
Each step is a form over its verbs as jobs. Secrets go through `POST /api/v1/secrets/<name>`
(an installer or the setup token): `acme-dns` → `~/.acme-dns-credentials.txt`, `unifi` →
`~/.unifi-os-credentials.txt`, mode 0600; `wlan` is handed to `ap-manager ssid set-passphrase <ssid>`
on stdin (never in argv), which stores it in `~/.wlan-secrets.txt` and marks the SSID for the next
reconcile; `backup-keys` (Day 2's Write the backup keys) starts `backup-manager key export --usb …
--password-stdin` as a job, the password on its stdin and in no record, so the write shows its
output and can be stopped. Each is in Activity with its keys and never their values; `GET
/api/v1/secrets` names the keys set. The WiFi step lists the site's SSIDs (`ap-manager ssid list`, the `ssids` read) with their
zone, security, the access points that broadcast each and the passphrase state (set, changed and not
pushed yet, or not set — a personal SSID without one cannot be created on the access points), and a
"Set passphrase…" link to its Day 2 form. Day 2's WiFi form declares the SSID site-wide (`ssid add`,
or `ssid modify`, or `ssid remove` then `add` for a new name), takes the passphrase, then shows the
reconcile's delta and applies it; the zone card shows the zone's SSID read-only with a link to it. The same flows serve
day 2: add a node, adopt a running machine (`module-manager adopt`), an environment, a stack; enrol a
device (the wg-quick file to download). Day 2's **physical site** is a step with that state and
its sequence: record the rooms (by location), add a rack, place the nodes and switches, record
what the cluster cannot see (the modem, a patch panel). Every form that takes a location (room
add and modify, asset add and record, machine add and adopt, a switch's or AP's Location…, a
buddy's peer add) offers the site's locations as a dropdown, the primary preselected (not for a
buddy, which is elsewhere), with a link to the Site page's Locations section (`/site#locations`)
for one the site does not have yet.

**Overview** — the site at a glance, top to bottom. **Four tiles**, two by two, each an overview of
one area drawn from what its own page reads, its header a link to that page and its colour the worst
open condition on the area's objects (from `health/summary`; without conditions, the worst of what
the tile itself shows): **Site** (the site's name, its locations with the primary first, each node
with its state, the cluster's quorum from the `quorum` gate, storage used of total over every
pool), **Environment** (each environment with its zone, its modules' maturity and how many modules
it holds), **Modules** (how many are running, stopped, updating — an update job running — and
archived, the last updates of a module or the sweep, the modules whose health fails or warns) and
**Identity** (users, groups and roles, and the identity provider, the `identity` module: its run
state and health). **Health**: the health line (critical, warning and ok objects, the open root
causes, what is silenced and unknown), the last sweep, backups, the release and security.
**Alerts**: the ten open events from `operations`, critical first and the newest first within each,
one line each (status, class and name, what is wrong, since) opening it on the Operations page with
its Health panel; a link to the Operations page for the rest. **Site** — the site as built, in four tabs, each at its own address: Overview
(`/site/overview`, also `/site`), Physical (`/site/physical`), Devices (`/site/devices`) and Storage
(`/site/storage`); the earlier addresses (`/physical`, `/site/physical/<view>`) redirect to them.
**Overview** sums the other three: the site in one line (nodes, switches, APs, racks, pools,
disks, the public address) with Add node and Register joined nodes (`site-manager node
reconcile`) beside it, Update now (`site update`, its plan first) at the top, the locations (the primary first, each
a link to its record) with their rooms, each rack a thumbnail of its units (a click opens the
Physical view), what is at the location placed nowhere and a buddy or satellite there,
the Device view as counts with the findings on devices, each node's
pools with a fill bar coloured by state and its disks with a problem, and every finding of the
topology and the storage inventory, each linked to the view and the object it is on. Below
that, the site's records: `site.json` (Modify), the update schedule, the release train's preview
and status, and the repositories (sync, hold, release, stashes, reconcile).
**Physical** (`/site/physical`): every location of the site, one above the other with the primary
first (fit shows the first, the drawing scrolls down to the others), each as an area
headed by its name — a link to its row in the Site page's Locations — and its address (on the first,
"the primary location"), around its
rooms and, after them, what is at it placed nowhere (with no room: somewhere there) and a backup
buddy or satellite that is there; each room of
asset-manager's `config/positions.json` as a box the size of what it holds, its racks and, beside them, the devices
standing loose in it — the rooms with racks side by side across the location, the small rooms
in columns beside them, each column no taller than the rack rooms; each rack as a frame with its units numbered as the rack numbers them, each placed device as its
faceplate at its units and width with its ports' live state (link, LAG), the cabled ports
underlined (a patch panel's rear-cabled ports overlined), the cables port to port — each one thin curve
leaving its ports vertically (up from a plate's upper row, down from a lower row, toward the other end
from a single row and from a patch panel's port, front or rear), a
bundle between two devices fanning out, a dot at each end, one long curve to another rack or a loose device —
an access link in its zone's colour, a trunk in its kind's (node trunk, switch uplink, peer link, access point,
device, patch), highlighted with a label on hover, a selected cable labelled midway with its ports — a link
through a patch panel as its two wires —, a
device only a cable record places beside the rack, and, left of the racks, an Unplaced tray of the devices placed
nowhere, by location, each with Place… (one form: a rack and its units, or loose in a room;
`asset-manager place`) — or, for a device a switch port sees and nobody recorded, Record…
(`asset-manager asset record`: its MAC kept on its port, the port's link recorded as its cable); the header's
Add a room… (`asset-manager room add`, at one of the site's locations), Add a
rack…, Record a device… (`asset-manager asset add`: kind, a catalog model or free text, ports, location; the
site's own plates first in the model list), the last also in a rack's and a room's card, and Add a faceplate…
(`asset-manager faceplate add`: a plate for a model the catalog lacks — its key, units, width, kind and ports as a
port spec the form explains, drawn as the rack will draw it while the fields change), and a How to card under the Unplaced tray; a click on a cable opens its link, whose panel
lists the wires, its Details the pages of its ends, where Attach to patch panel… is on the port's cable; a click on a patch panel's port (on its plate or in its port table) opens the link through it, a free one its port, whose Details offer Attach a wire here… (the links that could run through it) (`asset-manager cable split`, its `--check` the
preview, the free panel ports to choose from), and Remove patch panel (`cable join`) on the cable; a click on a plate or a port
opens the side card to the right of the racks (as everywhere in the console), with the device's location and placement as two
lines — the location a link to its row on the Site page, the placement to its rack or room in the
Physical view, from any view — and at its top the Details link to the device's page under Assets,
where Place… (the rooms and racks at the device's own location only;
with none there, Add a room… at it), Move to…, Change placement… and Unplace… are, besides the
object's own changes; a machine module's page shows the same two lines with the same actions; a seen device's card shows the port it is seen at, its MAC, what LLDP and
the lease say, its Details the Assets page where Record… is.
An operator also places by dragging: a device from the Unplaced tray onto a rack's units or into a
room's area, a placed device (in a rack or loose in a room) to other units of its rack, another rack
or a room. While it is dragged the units it would take (its height, its column for a half- or
third-wide plate) are green when free and red when they overlap another device, run past the end of
the rack, or the rack or room is at another location than the device's (a room not recorded is red
too); a label beside the pointer says which. A release on green runs one job — the check, then the
apply — `asset-manager place <device> --rack <rack> --u <n> --height <n>` with the plate, width and
column the Place… form would start with (`--room <room>` into a room), or `place modify <device>
--set rack=… --set u=…` (`--set room=…`) for a placed one; the device's card opens on the right with
the job's state, Stop, and its output. The plate stands at its target in a pulsing, dashed style while
the job runs, and the page keeps reading the positions when it ends until the console's refresh
behind it is done, so the plate is at its new units without a reload. Escape or a
release anywhere else changes nothing. Place…, Move to… and Change placement… stay for the
keyboard and for what a drag does not set (the face, the plate, a label). Below 900 px wide the
tray, the racks and the card stack. **Devices** (`/site/devices`, formerly `/site/assets` and `/site/device`) — a view on the assets that are physical devices (the cluster nodes, the
switches, the access points, the machines and devices a placement or a cable record names, the devices a switch port sees (marked as seen), the internet
and the backup buddies) as a card with its kind's icon and its name, a server's with its bay row (a
small cell per disk in it, by bay, coloured by the disk's health), coloured by
its state as the Storage view colours its cards (its findings' worst level; a drifting port, a
node's uplink leg down or a buddy down are warnings; the reason on hover; one legend for both
views); one line per pair of devices a cable joins (several cables or a LAG thicker, the internet's
hand-off and the WAN dashed, a buddy's tunnel dotted, a cable down red), labelled with its ports.
The graph is laid out by force around the selected device: it moves to the middle, the devices one
link away on a ring around it, the rest further out, animated from where they were; cards can be
dragged, Fit shows every device, `?select=` selects and centres; a click on a line opens its link.
The Physical view opens the same side panel: a device selected in a rack shows its drawing,
records and actions as in the Device view; a cable clicked there opens its link, highlighted in
the rack with its ports ringed; a rack keeps its own record in the same panel.
A click opens the side panel: on top the device's faceplate drawn as the Physical view draws it
(the rack catalog's plate, or a generic one from the ports the topology knows), its cabled ports
underlined and the selected link's ports ringed, a click on a port selecting that switch port or
that port's link; under it a server's bay row (each disk by bay, coloured by its health, a link to
the disk's page); below it the device's records (a switch's ports and what hangs on them, a node's
memory, uplinks and guests), what it is connected to and its findings; its day-2 changes — a switch
port's record (`switch-manager update-port`) then `switch-manager reconcile`, a node's
`node network show / set` — are on the page its Details link opens. **Storage** (`/site/storage`, `storage-manager inventory`) — in
columns: the cluster nodes, each node's boot device and pools (with the pool's fill bar), each
pool's disks (a mirror's or a raidz's disks carry its label and a bracket), lines node → pool →
disk; every card coloured by its state (ok green, warn amber, fail red, the reason on hover),
raised by the storage-pools and storage-replication findings on it (a disk's own health is its
CMDB record's, on its asset). A disk an asset records carries its tag and bay on its card. A
disk's card: model, serial, size, SMART, life left, temperature, sector counts, its ZFS errors, the
jump to the node's Disks in Proxmox, and its asset: its tag (a link to its page), its health and
pool as the CMDB has them, the assets it has been in, and its CMDB record; a disk no asset records
says how to record it. A pool's: size, used, free, health, scrub, its members — each vdev with its
disks and their state, a click opening the disk's card, a member that is gone marked missing — and
a pie of what it holds — one
slice per guest with its own disks there (linked to its module page), the HA mirror copies of
other nodes' guests as one slice (expandable to the guests), datastores and shares, other
datasets, free. **Modules** — tabs: Installed (the list with its badges, grouped by stack, foundation
first) and one per registered repository (`GET /api/v1/catalogs`: `site-manager repository list`, each
repository's module-catalog.json and each module's own JSON; installed = a deployed instance whose
`moduleSource` is the module's directory, with the instances named and linked; Install = `module-manager
add <m>`, one button; a catalogue that cannot be read says why); a module's page has
Overview, Config, Drift (on demand), Backup and Activity. Overview is a list of sections, composed
by the backend (`GET /api/v1/modules/<m>/sections`) from three layers, each able to add, reorder or
replace what the layer below put there, by section id. Generic, every module: `health`, `operate`
(update, reconcile, test, snapshot, suspend/resume, delete with the typed name), `about`. Kind, built
into the console (`src/kindsections.ts`): a vm or lxc has `resources` (memory declared, allocated and
used as the balloon reports it, disks and their pools, node and HA state, snapshots) and `backups`; a
machine `guests` (what runs on it, with memory and run state), `pools` (fill and health), `ports`
(ports and links), `cluster` (membership); a device `ports` (what each connects) and, for an access
point, `radios` (radios and SSIDs). Module, declared: a module's `console.json` beside its module JSON
(`src/consolefile.ts`, `schemas/console-fields.json`). Its `sections[]` each name an `id`, a `title`, a
`read` (`{bin, verb, args[]}`, `$module` for the module's name, run with `--json` through the cached
runner) and a `render`: `kv`, `table` with `columns[]`, `gauges` with `fields[]` naming the JSON paths;
`rows` says where the rows are in the answer. An entry with an id the page already has replaces that
section, a new id goes before Operate, and `before`/`after` move either; an entry with only those moves
a section. Its `operations[]` name verbs that carry a manifest, shown through the operate dialog.
A declared read runs only if the bin's manifest declares it as a read, so a module's file never names
a command of its own. A section the schema refuses, a read that fails and an operation with no
manifest are each an error in their place; the rest of the page stands, and the generic three show
while the list is read. A kind section reads the CMDB first (conditions, `runs-on`, `member-of`, the
observations the controllers recorded), `health-manager guests --json` gives its live numbers, and the
topology and storage inventory stand in where the CMDB has no record; each says what it could not read.
pvehost declares Memory by module and Storage used by modules, and migrating its guests and rebooting
the node. Config draws the module as
a tree of cards: the module's own (kind, node, environment, zone and the fields no service owns)
on top, one per service in dependsOn below. Each card's Modify lists every field it owns, typed
from the field schema, its value configured or default, its change class; the fields changed go
to one `module-manager modify <m> --set a=b --set c=d` job (`GET /api/v1/modules/<m>/fields`:
`module-manager fields` + `resolve` + `config/module-fields.json`). **Environments** — one card per
environment (its name, display name, type, whether it is the default, its public domain, how many
zones and modules), and inside it one box per zone it owns (every zone naming it: its own Service
zone and the client and IoT zones that serve it; a zone its modules use but it does not own, like the DMZ, as a dashed shared box),
each with the modules installed there as their icons (`GET /api/v1/modules/<m>/icon`: the file the
module's config declares as `icon`, else `icon.svg` or `icon.png` in its module directory; SVG and
PNG only, nothing outside the config or module directory; none: a tile with the initial), each
coloured by its health. A click on a card's head opens its panel left of the cards (`?env=<name>`):
the whole record, its zones and modules, and environment-manager's verbs (Modify through the
schema's form, Reconcile, Delete behind the typed name, Show); a zone's head opens it on the Zones
page, a module its page. Adding an environment says for each
input whether it must be given or what the manager uses when it is left empty (owner: the first
organization; zone and display name: from the name; DNS mode: the schema's default). **Zones**
(`/zones`; `/environments?zone=<z>` redirects there) — the zones with network-manager's verbs,
drawn as cards coloured by type, with an arrow for each `access-to` and a dashed one for each
`pinhole-allowed-from`; a click on a card, or on the zone's row in the table below, opens its card
(`?zone=<z>`), the one place for its verbs (Modify, Enable/Disable, Bind, Reconcile, Add one
like it, Delete, as network-manager takes them for the zone's state and type; a manual zone — the
overlays, the WAN, mgmt — is kept by its own module and offers no Enable, Disable or Delete;
`network-manager manual` stays on the command line), and Modify lists every field of
`zones-fields.json` with its value, default and class (one `network-manager modify <zone> --set …`). **Identity** — organizations,
groups, users and roles as a graph of their relations (a group's owning organization, a user's
groups, the roles of users and groups, an organization's owner and parent; `GET /api/v1/identity/records`:
`identity-manager <kind> show` for each), the list beside it, a click for the record and its verbs
(`?select=<kind>:<name>` opens one: `user:lars`, `group:admins`, `org:…`, `role:…`); a change is staged with `--no-reconcile` and pushed by `identity-manager
reconcile`, previewed. A group a module or Authentik declares (`identity-manager group list --declared`:
`forgejo-admins`, `authentik Read-only`) is listed with its origin as a muted tag (`module forgejo`,
`Authentik built-in`) and offers Show only: it is changed where it is declared, and a user's groups
field does not offer it. Authentik's own users (`identity-manager user list --declared`: `akadmin`,
an outpost's `ak-outpost-<hex>`) are listed the same way, `Authentik built-in`, with Show only (no
password reset), and no form offers them as a user. **Assets** — see [Assets](#assets) below. **Backup** — the policy of every module, peers, pulse, restore points;
modify, purge (typed). **Site** — the four tabs above. Add node is a guided sequence in Setup's step rows: declare
the node (`site-manager node add tappaasN`: its switch port or MAC, boot disks; the wizard
always installs, adopting a hand-installed Proxmox is the CLI's `--adopt`; the form, then one
Declare button, which starts the job at once: one line then says where the job is; a refusal
shows the last lines and Try again with the values kept), boot it from the
network or the USB stick by hand, the install and join watched live (`GET
/api/v1/nodes/<name>/progress`: the provisioning registration, `node-provisioner status`, cluster
membership, the node's `pvehost` record; every 10 s), then `node network set` and `node network test`, previewed. **Activity** — the console's jobs, the sweep's runs, the failures ledger and the last
result. Security is a later phase.

**Remove a node** (Day 2) has three steps and no change/preview/apply/result flow of its own.
1 · the node, and the way: power it off then remove it, wipe its disks first, or it is down for
good. 2 · *Remove it*: as the step opens the console checks at once (`site-manager node delete
<node> --<way>`, the dry run) and shows the outcome as findings, not console text
(`web/src/noderemove.ts`): "tappaas4 can be removed", or what still needs it — a guest on it
(a link to its module's page, to move it to another node), a module that replicates to or from it
or may fail over to it (its module), the site's backup server (the Backup page); for a node that is
down for good, what is lost with it. Once the check passes, the machine's record is kept (back to
stock, its place in the rack and its cables recorded, ready for its next role; the default) or
removed (record, place and cables: the machine leaves the site); a lost machine's record is always
removed, and the step says so. The node's name typed, one **Remove tappaas4** button runs `node
delete <node> --<way> --asset <keep|remove> --yes --apply` and shows what was done: out of the
cluster, its switch ports parked, the machine's record kept or removed; a failure shows the last
lines and **Check again**. Both outputs are a click away under a fold. 3 · *Afterwards*: what is
true now, with links — gone from the cluster and from Modules, its switch ports parked (the switch
in the Physical view), the machine in stock (its asset page) or removed, and Add node to replace
it, which recognises a stocked machine by serial or MAC. Closed while it runs, the wizard finds the
removal again when reopened.

**Health** (in the menu under Day 2 wizards, above Site, at `/health`) — three panes, one selected
object: a tree to find it, an ego graph around it, its CI panel beside them.

**The tree (left)** is a walk over the CMDB's relations, read a level at a time. Which relation nests
what is the metamodel's (`tree` on a relation type), so a new class or relation joins the tree with
no console change; the console only says where each facet starts. **Physical**: the locations, the
site, rooms and racks, the assets, the node on each asset, the guests on a machine and the software
on a guest, and under an asset its ports with what each connects, as a leaf. **Environments**: each
environment, its nodes, their software and services, the zones that serve it. **Identity**:
organizations, their groups and environments, the users in a group. **Elsewhere**, only when there
is any, holds what no facet reaches, so nothing is lost. An object with several containers is listed
under each. Every row carries the roll-up of its subtree: a dot with the worst status and a count of
the objects that need a look (warning or critical and not silenced; an unknown is grey in the dot and
named in the tooltip, not counted, and the roll-up condition of a place or collection is not one
more object). The current root causes stand above the facets, worst first; the search finds any
object by name or class and says where it is. What is open is remembered in the browser.

**The ego graph (centre)** is laid out by dagre: the selected object, a pill per relation type and
its neighbours through them, what it needs above it and what needs it below. Each pill's neighbours
stand as its own cluster, the pill centred on them and pills of one side next to each other. A
cluster too wide for the canvas wraps into rows, as many as let the graph fill the canvas's height.
A pill of more than eight stands folded with what needs a look still out; a click opens it. A **+**
on a neighbour opens one more hop from it, a **−** folds that and what was opened through it. **To the root cause** and
**What this impacts** add the chain of the derivation in strong lines; a dashed line is `assess`'s
word where no relation shows the way, which usually means a relation is missing. Cards carry the
class (or module) icon, the name and the one-line reason; red critical, amber warning, grey unknown,
green ok, hatched acknowledged, dotted in a maintenance window, ↯ flapping; a root is ringed. It is
laid out once per shape; a colour is patched over it, so a filter, the time slider or a change in
the CMDB never moves a card.

**The CI panel (right)**: conditions with their `since`, the root cause or what it impacts, drift,
the conditions' history, the changes to it, relations both ways, the health verbs as jobs (Ack…,
Unack…, Maintenance…, health-manager's own, offered once its manifest declares them), **Details**
at its top, the page that shows the object in full and where its operations are, and **Show in tree**, which opens the tree
down to it. A panel shows status, not operations.

**The CMDB record** (`web/src/pages/CiPanel.tsx`), opened by **CMDB record and trace** in the CI
panel and in a device's side panel on the Site page (a node or machine looked up as a `machine`,
a switch or AP as a `device`, by name): what the CMDB holds of one CI. **Open events**: its
conditions that are not ok, the worst first, with since, source and whether acknowledged or in
maintenance. **Trace**, up the backbone: the asset a port is part of, the CI an asset is allocated
to, the machine a guest or a piece of software runs on, the cluster (else the environment) a node
is a member of, to the top or eight hops; then the desired record (`config/<name>.json`), the
release (module and version) and the module of the nearest CI on the way that records them, the
module's open issues on the forge and the ADRs its design names. **Attributes**: each value with
the source that reported it and since when. **Drift** against its record. **Relations** both ways,
with source and since. **History**, folded: every period of every attribute and relation and every
change that touched it, the newest first, a change with its verb, actor and job. Every CI named in
the record opens its own record in the panel; Back returns the way it came.

**Entry.** `/health?select=<id>` opens on one object; a root opens with its symptoms expanded. With nothing asked for the page opens on the worst root, and
on the site when nothing is wrong. A site that has not run `assess` gets grey dots and says so.
**Filters** (condition type, class, environment) dim what they leave out in the tree and the graph,
and a type recolours the graph by that type; the slider replays a week of colours in the graph from
the attribute history (`health/ego/<id>?at=`). **Live:** roll-ups and colours follow `health/stream`
without a reload; a new root shows in the tree and nothing moves the selection. On a phone the tree
is a sheet and the panel a drawer.

The Overview's tile colours, its health line (which links here) and its Backups card, the Backup page's
Health section, the Modules list's health badge and a module page's Health section read
the worst condition of their objects from `health/summary` and `modules`, so every page agrees with the
view; each falls back to `health` (validate) while the CMDB holds no conditions or does not answer.

**Operations** (`/operations`) — what is wrong now and what changed. **Open events** are the objects
with a failing condition of their own: critical or warning, not derived, not acknowledged and not in
a maintenance window (an `impact` condition is a symptom, shown as its root's impact, never an event
of its own). They are grouped by root cause: an event that another open event explains goes under
it, following the chain to the top; the head of a group is marked *root cause* when other objects
fail because of it. Critical groups come first, then the one that impacts most, then the oldest; in
a group the head first, then critical before warning. Under each group, **impacts N** lists the
objects that fail because of its head (the dependants whose derived condition names it). Beside
each event, **what changed** on that object in the last 24 hours, newest first, from its CMDB
history: each change with its verb or kind, source, actor and job, drift, and what it set — the
attributes, a relation made (`+`) or ended (`−`). The assessment's own heartbeat (an observation
that set only `conditions`, `lastSeen`, `used` or `leaseUntil`) is left out. The histories of the
first 40 events are read, each at most a minute old. A row opens the object's panel, the same as
on the Health page (`/operations?select=<id>`), with **Show in tree** to go there; the page reads
again every 30 seconds and whenever the CMDB changes.

**Discovery sweep** on the same page: **Run discovery sweep** (an installer's; it changes nothing
on the site, it asks every source for everything and compares with the last sweep and with
`config/`) runs `cmdb sweep` behind the request and is disabled while one started here runs; the
CMDB refuses a second one, from anywhere, while one runs, and the page says so. Below it the last
sweep's record: when, its status, the sweep it compared with (none: the baseline), the counts, the
sources that failed or were asked without `--discover`, and the findings — what no change explains:
drift, differences from desired, unmanaged and missing objects — each object a link to its panel.
The nightly sweep's record shows here the same way.

Every change is the operate dialog (`web/src/operate.tsx`, the flows in `web/src/flows.tsx`): a
form built from the verb's manifest, the exact command (copyable), disruptions as labelled
checkboxes, and a flow of several steps run in order. What the operator does next follows from how
the verb previews (`stepFlow` in `web/src/argv.ts`; a step can override it with `flow`):

| The verb | What the operator sees |
|---|---|
| **No dry run** (`module add`, `backup modify`, `ssid add`, an acknowledgement…) | The form and one button. The job's status line with Stop and its output show in place, folded to its last lines when it ends. A failure says why, shows the last lines, and Try again goes back to the form as filled in. A destructive one (`module delete`, `backup purge`) needs the object's name typed first. |
| **A dry run that only says yes or no** (asset-manager's verbs, `site modify`, location and zone add, `module modify`) | The same one button: one job runs the dry run first and goes on only on a clean one. A refusal comes back in place, as findings in the verb's own words, with Try again. The change classes of a field form show above the button. |
| **The same, destructive** (asset dispose and remove, `unplace`, room, rack and location delete, zone and environment delete) | The check runs as the step opens, with Stop. What stands against it is listed, with Check again; once it is clean, the typed name and one button. A form to fill in first (a required option): a Check button instead. |
| **A plan to read** (every reconcile, `site update`, `add-stack`, `repository sync`, `node reconcile`, `node network test`) | The preview runs as the step opens, its output streamed, and one Apply under it applies that preview. A form still to fill in: a Preview button first, and a changed form is previewed again before anything can apply. `node network set` previews on the button, because its preview writes the declaration. |
| **A read** (`show`, `test`, `peer check`) | One Run, or at once where it is a wizard stage's result (`peer check`, a satellite's `test`). `test --deep` is a change with no dry run. |

Activity shows a job that ran its dry run first in its two phases.

A wizard is the same flows in its stages (`web/src/wizard.tsx`): a stage that decides is a form
with Continue, which locks its fields, and Change, until something has run on them (`DecideStep`);
a job found again on opening is offered with Continue (`ResumeOffer`), Add a node's with Done with
it as well. An assistant's card runs by the same table, except that nothing starts by itself: only
the operator's click runs it, so a plan or a destructive dry run has a Preview button, and a read
one Run.

## Assets

**Assets** (`/assets`, between Identity and Backup in the menu) lists every asset of the site in a
tree by where it stands: location → room → rack → asset, each rack's assets from the top unit down
with their units, the assets standing loose in a room under it, the racks in no room under the
location's *in no room*. Under each location, **Not placed**: the assets in stock or ordered, the
devices the topology knows that no asset records, and the devices a switch port sees that nobody
recorded (last); **Disposed** apart, folded. Each asset shows its display name (a link to its page),
kind, stage (ordered, stock, placed, operational, disposed), the faulty flag, the role it plays,
vendor and model, and *CMDB differs* when the CMDB has it allocated to another role than the
record says; its ports fold out with their connector, speed, MAC, role and where each cable goes
(recorded or seen by the topology, a label, the patch panel ports it runs through), and so do its
disks: each disk in it by bay, a link to its own page, with its serial, size, kind, health (its
CMDB record's condition, else the node's health word) and the pool built on it, and how many disks
its CMDB record lists that no asset records. A disk is an asset of its own (`dsk-NN`, its by-id
name shown): one in a server is listed under that server, one in stock under its location's Not
placed. A filter keeps the rows whose name, kind, model, vendor, serial, tag, role or stage match,
or a disk in it by its tag, by-id name or serial. The header has Add a
room…, Add a rack…, Record a device… and Add a faceplate….

A location, a room, a rack or a device no asset records opens beside the tree
(`/assets?select=location:<name>`, `room:`, `rack:`, `device:`) with its facts and its operations:
a location's Add a room…; a room's Change…, Add a rack…, Record a device…, Delete… (empty only), or
Record the room… while only a rack's text names it; a rack's Change…, Record a device…, Delete…
(empty only); a device the topology knows that no asset records its placement (Place…, Move to…,
Unplace…) and Record a device…; a device a switch port sees its port, MAC, LLDP and lease, and
Record…. Each links to it in the Physical view.

**An asset's page** (`/assets/<name>`, by the asset's own name or the role it plays) shows its
record — display name, name, kind, vendor, model, serial, asset tag, stage, faulty and its note,
description, procurement and disposal (the last three from its CMDB record) — the role it plays and
since when, its location and placement, the CMDB's allocation of it, its ports (connector, MAC, the
cables on each, the far end a link to its own asset's port row), and the history of its
allocations: every role it has played, from when until when, from its CMDB history (the periods
of its `allocated-to` relation). Below, its CMDB record: open events, trace, drift, relations and
history, each CI named there opening its own record in place. The operations on it are here
(an installer's): the lifecycle — Receive… (ordered → stock), Allocate… (to a role the topology
knows that no other asset plays), Release…, Faulty… and Repaired…, Dispose… (once it has no role,
no placement and no recorded cable); its placement — Place…, Move to…, Change placement…, Unplace…;
its record — Change the record…, Remove the record… (once nothing places or cables it); a node's
Network: show and Network: set…; a switch's or an access point's Location…; and per port: Port… (its
record: kind, speed, MAC, role), a switch port's Change port… (its record, then reconcile) and
Park…, Record a cable… or Remove the cable…, Attach to patch panel… or Remove patch panel on a
cable, and on a patch panel's free port Attach a wire here…. `#port-<name>` in the address marks
and scrolls to a port's row. On an asset that holds disks, Remove the record… and Dispose… ask in
their form what becomes of the disks: *the disks' records go with it* (disposed of with it, for
Dispose…; `--with-disks`, the default) or *the disks go to stock* (taken out first, kept for
another asset; `--disks-to-stock`). A node's disks and pools are in the Storage view, linked from the page.

**Disks.** An asset's page lists the disks in it with their bay row and, per disk, its bay, its
page, serial, size, kind, health and pool, with Move to… (`asset-manager place <disk> --in
<asset> [--bay]`) and Take out… (`unplace`: into stock). Record a disk… (`disk add <asset>`) records
one by its serial; Adopt the disks the CMDB knows… (`disk adopt <asset>`) is offered when the
asset's CMDB record lists disks with a serial no asset records, and names them. **A disk's page**
(`/assets/dsk-NN`) shows its record (serial, model, medium and bus, size, WWN, firmware, asset tag),
where it is (the asset it is in, its bay, its health and the pool built on it), its placements —
every asset it has been in, from when until when, from the CMDB history of its disk records (a
disk moved ends its record in the old asset and begins one in the new) — and its CMDB record. Its
operations: Move to… (or Put in… from stock), Take out…, Change… (`disk modify`), Faulty… and
Repaired…, Dispose… once it is in no asset (`asset dispose --how …`, the form asking *Was it
wiped?*, which the disposal record keeps as `--wiped`), and Remove the record… (`disk remove`, a
record made by mistake). A place form offers a disk's `in` and `bay` only, and a device's rack or
room fields only.

## Side panels: the Details link

A selection in the Physical, Devices (`/site/devices`) and Storage views, and an object in the Health
and Operations views, opens a side panel with a condensed overview of it: its records, findings or
conditions, where it is, what it is connected to. The panel changes nothing. At its top, **Details**
opens the page that shows the object in full and where it is changed (`web/src/details.ts`):

| Selected | Details opens |
|---|---|
| a server, switch, access point, recorded device, patch panel | its asset's page, `/assets/<name>` |
| a switch port, a patch panel's port | its row on the asset's page, `/assets/<name>#port-<port>` |
| a node | its module page when it has one (`/modules/<name>`), with **Asset** beside it; else its asset's page |
| a disk in the Storage view | the disk's page when an asset records it (by its serial), with **Node** beside it; else the node's asset |
| a disk's CI | the disk's page, `/assets/dsk-NN` |
| a pool | the node's page |
| a link | each end that is an asset |
| a rack, a room, a location | the Assets page with it selected |
| a device a switch port only sees | the Assets page with it selected, where Record… is |
| a guest, the firewall, a module's CI | the module's page |
| a zone | the Network page, `/zones?zone=<zone>` |
| a user, a group, an organization, a role | the Identity page with it selected |
| an environment; the site or the cluster; a datastore or backup peer | Environments; the Site page; Backup |

The CMDB record of a device stays one click away in the panel (**CMDB record and trace**).

## The status route — `status.<domain>` (off)

A request whose host is `status.…` is refused (403) whoever sends it (access.ts). The owner's
summary is still built (`GET /api/v1/owner`, `src/owner.ts`: one sentence about the site, every
service in plain words, the site in numbers) for the status page that comes with differentiated
roles, a later step; the front end shows no owner's view until then.

## How it reads the site

Only through the managers' `--json` (and `lib/ts`), never `pvesh` or `ssh` of its own:

| Read | Verb | Refreshed |
|---|---|---|
| health, gates, pulse, Attention, badges | `health-manager validate --json` | every 10 min |
| modules | `module-manager list --json`, with `backup-manager list --json` for the backup badge | every 5 min (backup 10) |
| a module | `module-manager show / resolve <m> --json`, `backup-manager show / coverage <m> --json` | 5 min, on first view |
| a module's drift | `module-manager drift <m> --json` | on demand only |
| a module's fields (its Modify forms) | `module-manager fields <m> --json` with `resolve` and `config/module-fields.json` | 5 min, on first view |
| the repositories' catalogues (`catalogs`) | `site-manager repository list --json`, `<path>/<catalog>`, each module's JSON, `config/<m>.json` moduleSource | 10 min, and after a job |
| a form's schema (`schemas/zones`, `schemas/environment`, the rack, room and placement `$defs` of `positions-fields`) | `src/foundation/schemas/<name>-fields.json` of `$CONSOLE_REPO` | 10 min |
| topology (the Physical page) | `network-manager topology --json --health <the cached validate>` | every 5 min |
| the faceplate catalog (a placement's faceplate choices) | `asset-manager faceplates list --json` | 10 min |
| storage (Physical › Storage and Overview) | `storage-manager inventory --json` (SMART included, ≈15 s on three nodes) | 10 min, read when a page asks; no timer of its own |
| zones | `network-manager list --json`, `show <zone> --json` | every 5 min |
| the site's IPv6 prefix (`ipv6`: each zone's /64 on the Zones page) | `site.json` `ipv6` and `network.wan.ipv6`; for a dynamic WAN, `ipv6-manager wan --json` (ssh to the firewall) | 10 min, read when a page asks; no timer of its own |
| environments | `environment-manager list --json` | every 5 min |
| site | `site-manager site show / node list / repository list --json`, `config/last-update-result.json` | every 5 min |
| security | `health-manager report security --json` | every 10 min |
| peers | `backup-manager peers --json` | every 10 min |
| activity | `journalctl -u update-tappaas.service -o short-iso` (7 days), `config/update-tappaas.failures` | every 5 min |
| the health document (`health/*`, the Health view and the worst condition on the other pages) | the CMDB's API on `127.0.0.1:9098` with the token (`src/cmdb.ts`: `query`, `relations`, `classes`, `rules`, `show`, `history`; a CMDB record also `find`, each read when it is opened) | when the change stream says something changed; every 5 min while the stream is down |
| the current root causes (`health/roots`) | `health-manager roots --json`, else the document's | when asked |

A page is served from the last answer with its age; a failed refresh keeps the last good
answer and says why. `POST /api/v1/refresh[?what=<read>]` refreshes the console's own cache
now (it changes nothing on the site).

## API (`/api/v1`)

`POST setup/check` starts the foundation modules' tests, a read job each, for whoever may read
Setup; JSON only. Reads (GET): `me` · `status` · `health` · `gates` · `pulse` · `site` · `modules` · `modules/<m>` ·
`modules/<m>/drift[?refresh=1]` · `modules/<m>/sections` (its page's sections with their data) · `zones` · `ipv6` · `environments` · `topology` · `storage` · `security` ·
`activity[?module=<m>]` (the sweep's runs, and `jobs`) · `manifests` ·
`modules/<m>/icon` (SVG or PNG, 404 when it has none) · `jumps/<kind>/<id>[?switch=<s>]` (kind: node, module, switch, port, lag, ap, zone, peer, site;
disk and pool, whose id is the node: its Disks and ZFS panels in Proxmox).

The Health view's reads (`src/health.ts` builds them; `src/healthlive.ts` keeps them fresh; a
change is a job as ever, `health-manager ack|unack|maintenance`, taken from its manifest):

| Route | Answers |
|---|---|
| `health/tree` | `{generated, hasConditions, site, counts, roots[], facets[]}`: a tree node is `{id, class, name, label, isRoot, children, status, notOk, unknown, acknowledged, maintenance, flapping, types{}, classes[], environments[]}`, `children` how many to open, the rest the roll-up of its subtree; a root is `{id, class, label, type, status, reason, message, since, acknowledged, flapping, impactedCount, impacted[], environments[]}` |
| `health/tree?q=<text>` | up to 50 tree nodes by name or class, worst first, each with `where`, the way down to it as a line |
| `health/tree/<id>/children` | one level: a facet's tops (`physical`, `environments`, `identity`, `elsewhere`) or an object's children |
| `health/tree/<id>/path` | the first way down to an object, its facet first |
| `health/ego/<id>[?depth=1..3][&at=<time>]` | `{generated, at, id, center, nodes[], groups[], edges[]}`: a node is the object with its worst condition `{id, class, name, label, environment, module, rootCause[], isRoot, types{}, issues[], status, type, reason, since, acknowledged, maintenance, flapping, more}`, `more` true when it has neighbours beyond those shown; a group `{key, anchor, type, direction, side, label, neighbours[]}`, `side` up for what the anchor needs. With `at`, the CMDB as of that moment, not cached |
| `health/ego/<id>/path?to=root\|impact[&at=<time>]` | `{generated, at, id, to, nodes[], edges[]}`: the chain of the derivation, an edge `{id, type, provider, dependant, virtual}`, `virtual` when no relation shows the way |
| `health/object/<id>` | the CI panel: `{id, class, ancestors, name, label, module, view, conditions[], drift, relations[], history[], changes[], rootCauses[], impacts[]}` |
| `health/roots` | `{roots, from: "health-manager"\|"graph", error}`, `graph` being the console's own list |
| `health/summary` | the worst per page: `{available, generated, site, counts, roots, byType{}, attention[]}`; `counts` the objects per colour, an object whose every failure is silenced in none, and `acknowledged` the silenced conditions, one by one (an acknowledged condition beside an open one on the same object counts); `available` false: keep `health` |
| `cmdb/ci/<id>`, `cmdb/ci?name=<name>[&class=<class>]` | a CI's record: `{id, class, ancestors, name, label, attributes[] {name, value, source, since}, relations[] {id, type, direction, other, source, since}, drift, events[]}`, `events` its conditions that are not ok; by name, the class (or an ancestor of it) where the name is not unique |
| `cmdb/ci/<id>/history` | `[{at, what: attribute\|relation\|change, name, value, source, until, detail, drift}]`, the newest first, 300 at most |
| `cmdb/ci/<id>/trace` | `[{class, name, id, relation, link}]`: the CI, what it is part of, allocated to, runs on or is a member of (eight hops at most), then `desired`, `release`, `module`, `issues` and `adr` steps, which carry a `link` and no `id` |
| `assets/tree` | the Assets view: `{locations[], assets[], allocationsError, disksError}`; a location `{name, displayName, primary, rooms[], unplaced[], disposed[]}`, a room `{name, displayName, recorded, racks[], loose[]}` (`name` "" for the racks in no room), a rack `{name, displayName, units, items[]}`, an item `{device, asset, kind, at, seen}` (`asset` null: no asset records the device); an asset as the positions list it plus `{placedAs, where{location, room, rack, at}, ports[] {…, listed, cables[] {to, kind, source, label, via[]}}, disks[], unrecordedDisks[] {name, serial, model, size, type}, asDisk, cmdb {id, allocatedTo}, allocationDrift}` — a disk `{name, displayName, serial, size, kind, stage, faulty, host, bay, ci, health, state, reason, pool {name, node, vdev}}` (`state` ok, warn, fail or unknown: its CI's worst condition, else Proxmox's health word), `asDisk` a disk asset's own — from the topology's positions, the CMDB's `allocated-to` relations, its disk CIs, the pools' `built-on` relations and the server CIs' `disks[]` (each read at most a minute old; `allocationsError`, `disksError` when the CMDB did not answer) |
| `assets/disk/<disk>/placements` | a disk's placements: `[{asset, bay, ci, from, until}]`, the newest first, from every disk CI of its name (live or ended) and its `part-of` periods |
| `health/stream` | server-sent events: `hello`, then `health` `{topology, relayout, generated, patches[], rollups{}, roots, counts, hasConditions}`, one read per burst of CMDB changes; `patches` the objects whose colour moved, `rollups` the tree nodes whose roll-up did; `relayout` true: an object or a relation changed, read again |

`modules` and `modules/<m>` add `condition` to a module's summary (the worst of its node and the
services it provides) and take `badges.health` from it, a silenced condition counting as passing.
The client's address and token: `CMDB_URL`, `CMDB_TOKEN_FILE` (default `http://127.0.0.1:9098`,
`/etc/secrets/cmdb-token`).

The Operations view (`src/operations.ts` shapes it):

| Route | Answers |
|---|---|
| `GET operations` | `{generated, hasConditions, counts{critical, warning, groups, silenced}, groups[], windowHours, changes{}, changesError{}, changesSkipped[]}`: a group `{root, status, since, events[], impact{count, objects[]}}`, an event `{id, class, name, label, environment, module, type, status, reason, message, since, flapping, conditions[], isRoot, rootCause[]}`; `changes` by object id, each `{id, time, kind, source, verb, job, actor, drift, what[]}`, from `GET /v1/objects/<id>/history` |
| `GET operations/sweep` | `{last, lastError, running, failed}`: `last` the last sweep's record (`GET /v1/sweep`) as `{id, time, since, status, counts{}, sources[], findings[], findingsTotal, expectedTotal}`, the first 200 findings; `running` `{started, by}` while one started here runs; `failed` when it did not finish |
| `POST operations/sweep` | an installer's (or the setup token's), as JSON: starts `cmdb sweep --json` and answers 202 `{running}`; 409 while one runs, here or anywhere; 502 when the CMDB does not answer |
Each answers `{data, at, ageSeconds, refreshing, error}`.

## Jobs — every change (ADR-034 D4)

| | |
|---|---|
| `POST /jobs {argv, preview: true}` | a **preview**: the verb's own dry run (`reconcile` without `--apply`, `--check`, `--dry-run`, `modify`'s pre-gate). A verb with no dry run gets a preview that runs nothing and says what the verb touches and the exact command apply will run. |
| `POST /jobs {argv}` | a **read** verb (`module test`, `node network show`, `wgvpn list`): runs at once. A write without a preview is refused (T3). A read verb's `writeWhen` option (`test --deep`, which creates and removes guests; a disruption flag) makes that call a write with no dry run: previewed and queued like any change, never beside the sweep. |
| `POST /jobs/<id>/apply {confirm?}` | the **apply** of a finished preview, less than an hour old: its own argv plus the applying flag (or without the dry run). A destructive call (`delete`, `purge`, `retire`, `erase`, `--remove`, `--decommission`, `key import`, …) needs `confirm` = the object's name. |
| `GET /jobs` | every job (newest first), the queue, and the sweep's state |
| `GET /jobs/<id>` | the job with its output; with `Accept: text/event-stream` its output as it comes (`job`, `output`, `state`, `end` events) |

A job is posted as `application/json` (a cross-site form cannot). Who may: the gate's installer
(every verb), or the setup token while setup is open; loopback without the gate's headers
starts no job (T1, T6).
**One runner**: previews and applies run one at a time, in order (a second operator's job
queues; `GET /jobs` shows the queue); reads run beside it. **The sweep**: while
`update-tappaas.service` is active (or starting or stopping) no job starts; the refusal says
since when and in which stage (`config/.update-stage`), and a queued job whose turn comes
during a sweep is refused too. The other way round, the runner holds
`<state dir>/console-job.lock` while a write job runs and the sweep's prepare step waits for
it (`tappaas-self-prepare.sh`, bounded at two hours; `DESIGN.md`). **Activity**: every job — who, via, route, the argv as asked and
as run, its preview, exit code and duration — is a summary line in `<state dir>/jobs.jsonl`;
its output (1 MiB at most) is `<state dir>/jobs/<id>.log`, read when the job is asked for.
The console holds the last 500 summaries in memory and reads them back at start; past 10 MiB
`jobs.jsonl` is rewritten with those 500 and the other jobs' logs are removed. A job is
recorded when it starts and again when it ends, so one the console stopped on (a restart)
is read back as **cut off** — no exit code, a note in its output. After an apply the module
list, topology, zones, environments, site and backup reads are refreshed.
Every verb a job runs (a secret's owner verb too) has the job's id in `TAPPAAS_JOB_ID` and the
console user in `TAPPAAS_ACTOR`, so the change it reports to the CMDB names its job (ADR-040 D6).

**A new build while a job runs.** `ui/install.sh` restarts the service when it has linked a
new build — but `module update tappaas-cicd` reaches that script from inside a console job
(`pre-update.sh` → `refresh-control-plane.sh`), and a restart then would kill the job. So it
asks the console first (`GET /jobs` → `busy`): if a job runs or waits it leaves
`<state dir>/restart-pending` instead, and the console exits into the new build the moment
its runner is idle (the unit's `Restart=always`).

## The assistant (ADR-034 D7, P3)

An assistant one can ask about the site, through the site's LiteLLM; present only when the AI
stack is installed. It **reads freely and proposes; it never applies.**

| | |
|---|---|
| **Where** | the backend (`src/assistant.ts`), so its tools, its trail and the caller's role are a click's; the Assistant drawer on every page; `tappaas ask` in a shell |
| **Transport** | LiteLLM's OpenAI-compatible chat completions, streamed, with tool calling (`src/litellm.ts`) |
| **Key** | `/etc/secrets/litellm-svckey.env` on the mothership, written by `litellm:models` (the console module integrates it): read directly, else with the unit's `sudo -n cat`; re-read while missing, so no restart when it arrives |
| **Reach** | mgmt → `litellm.<zone>.internal:4000`: mgmt's `access-to` covers every zone, so `rules-manager` writes no pinhole (`expected-pinholes console --for litellm:models` says so) |
| **Model** | `console.json` `assistantModel` when set; else LiteLLM's model named `default`; else the first model LiteLLM lists for the key |
| **Tools** | `modules_list`, `module_show` (with the fields `modify --set` may change and their class), `module_drift`, `zones`, `environments`, `topology`, `health`, `backup`, `pulse`, `activity` — the console's own cached reads; `logs` (Loki's `query_range` for a host, with the admin credential `~/.loki-admin-password`, only when logging is installed); `help(manager)` (the manifest and the README from `$CONSOLE_REPO`); `propose_job(argv, rationale)`; `open_console(target, values?)`: a page or a wizard of `web/src/consoletargets.ts` (add-node, add-wifi <zone>, modify-module <module>, …), opened in the operator's console with its form filled in (`src/assistant-tools.ts`) |
| **Never** | an apply tool: none exists, a tool name outside the list is refused and recorded, `propose_job` creates no job (it validates the argv against the manifests, without `--apply`/`--dry-run`), `open_console` only moves the console to a form. An invented tool's refusal names the real ones and spells out the call it probably meant; a call the model writes as text instead of making it is taken as made, once a turn, and marked `written` |
| **Context** | the system prompt: the site, the caller's name and role, the page and object in view (sent by the front end), the tools by their exact names (no tool per verb), when to open a form and when to propose, the wizards, the managers' verbs in short form as what `propose_job` may propose |
| **Trail** | a card's jobs (Preview, Run) carry `{conversation, proposal}`: the job checks the proposal is in the caller's own conversation with the same argv, and carries `origin: assistant` and the turn; Activity shows "lars · via assistant" |
| **Store** | `<state dir>/assistant/<user>/<id>.json`, 0600: the newest 50 per user, 40 turns and 256 KiB each; never in `config/` |

API: `GET /assistant/status` (available, and why not; the status route has none) · `POST
/assistant/chat {conversation?, message, focus?}` (one turn as server-sent events:
`conversation`, `step`, `delta`, `proposal`, `navigate`, `done`, `error`; `navigate` {target, values, path, title, url}: the drawer routes there and the wizard opens filled in, `web/src/opener.ts`; the turn records it as `opened`) · `GET
/assistant/conversations[/<id>]` (the caller's own). A turn reads; it changes nothing but the
caller's conversation file. Asked to run something, the assistant says that the card's Run
does it, so the record shows a person decided.

`tappaas ask "<question>"` (bin `tappaas`, packaged with the console): a client of the backend
on loopback, so the read role; a proposal is printed as its preview and apply command lines,
never run; an opened wizard as its address, `https://console.<domain>/…`. `tappaas ask` with no question is a short conversation; `--conversation <id>` goes
on with one. Without the AI stack, or with the console down, it says why and exits 1.

## The verb manifest

At start the console reads every manager's `--help --json` (lib/ts `renderManifest`) and the
declared bash verbs in [`manifest/bash-verbs.json`](manifest/bash-verbs.json)
(switch-manager, ap-manager, `tappaas-train.sh`, `acme-setup.sh`); `GET
/api/v1/manifests` serves them. A job's argv must be a verb one of them declares, with options
that verb declares (`src/manifest.ts`, ADR-034 T2): an undeclared verb or option, a value
outside an option's choices, a missing or surplus positional, `--config-dir` or `--help` is
refused before any job exists. The manifest also says how the verb previews (`--apply` absent,
`--check` / `--dry-run` present, or no dry run and what it touches), whether a call is
destructive, and which options make a read verb's call a write (`writeWhen`: `--deep` on a
`test` verb, a disruption flag).

## Who may reach it

| From | Accepted | Identity |
|---|---|---|
| the firewall (Caddy + the Authentik gate) | always | the gate's token `X-Authentik-Jwt`, verified (below): its user and groups; without it 401 (a route without the gate, or not the gate at all) |
| loopback (and `--allow`) | always | none: role `read`, for reads only (a dev port-forward arrives as loopback) |
| mgmt and the admin VPN | only while setup is open (below), with the token | `setup`, role `installer` |
| anything else | refused on connect | — |

A client cannot smuggle its own `X-Authentik-*` past the gate: the handler
`identity:accessControl` installs is os-caddy's `forward_auth` block with `copy_headers`
for the twelve Authentik headers (the firewall's template
`/usr/local/opnsense/service/templates/OPNsense/Caddy/includeAuthProvider`), and Caddy's
`forward_auth` deletes every `copy_headers` header from the client's request before it sets
the one the outpost answered with (`modules/caddyhttp/reverseproxy/forwardauth/caddyfile.go`,
"Always delete the client-supplied header"; in Caddy since 2.11 — hrossen's firewall runs
2.11.4). On an older Caddy the outpost's answer still overwrites the four headers the console
reads (username, groups, name, email), which Authentik always sends; only a header the
outpost omits would pass through. Nothing is added in the handler for it.

The firewall's address alone is not proof: a host on mgmt can take it (ARP, or the address
itself). So from the firewall the console verifies the token the outpost sends with every
request (`src/gate.ts`): HS256 with the route's proxy provider's client secret (the provider has
no signing key, so this is how Authentik signs it), the provider's client id as audience, the
issuer ending in `/application/o/<app>/`, and the expiry (a minute's leeway). The user and the
groups are the token's; a `X-Authentik-Username` that differs from it is refused. The key is
read from Authentik's API with the controllers' credentials (`~/.authentik-credentials.txt`,
`CONSOLE_AUTHENTIK_CREDENTIALS`) by the route's external host, for `console.<domain>` and
`status.<domain>` only, and cached; a token the cached key refuses marks it for a refetch, at
most every 30 s, while the key stays in use. No key (Authentik unreachable): 503.

Only the firewall may connect at all, besides loopback. The firewall's address is the gateway of mgmt's network in `zones.json`
(its `ip`, first address: `10.0.0.0/24` → `10.0.0.1`); only when that is unreadable does the
console ask DNS for `firewall.<mgmt domain>` (`CONSOLE_FIREWALL` overrides both).

The console is for one group, `installer` (identity creates it, `identity/USERS.md`),
compared without case: a gate caller in it gets the role `installer` and may do everything,
destructive verbs included (behind the typed name); a gate caller outside it gets 403 with a
reason naming the group, `admin` and `users` included. A service account (a client-credentials
token through the gate) follows the same rule by the token's groups; its scopes grant nothing.
The setup token acts as `installer` while setup is open; loopback without the gate's headers
reads only (role `read`, the health checks and `tappaas ask`). The gate's application is bound
to `installer` alone (`console.json` `gateGroups`), so others are refused at the login first.

**The setup token (ADR-034 D10).** `bootstrap.sh` writes `~/config/console-setup-token`; the
install summary names the file and the operator reads it with `cat` — the token is never
printed, so it reaches no log. While `config/identity.json` does not exist, the console
accepts the mgmt and admin networks with that token (`?token=` once, then an HttpOnly
cookie; or `Authorization: Bearer`). Once identity is installed the token is refused, even if
its file is still there — delete it.

## Running it

```bash
console serve                                   # as the unit does: mgmt address + loopback, :9097
console serve --listen 127.0.0.1:9197 --web web/dist --state-dir ~/tmp/console   # a dev run
```

Development without installing: build with `nix-shell -p typescript nodejs_22 --run "tsc -p
tsconfig.json"` and `cd web && npm ci && npm run build`, run `node dist/ui/src/main.js serve
--listen 127.0.0.1:<port> --web web/dist --state-dir <dir>`, and `ssh -L <port>:127.0.0.1:<port>`
from the laptop.

## Tests

`test.sh`: `tsc` on the backend and the unit suite (`test/unit/*.test.ts`) — the Health view over
`test/fixtures/health-site.json` (`fake-cmdb.ts`: one node down with its guests impacted, one
acknowledged root, one flapping condition, a guest in a window): `health` the document, the client,
the tree and its roll-ups, the ego graph and the chains, the live feed and the routes, `healthgraph` the cards and lines a page draws (there is no DOM here); `cipanel` a CI's record from fixtures: open events, the history's order, the trace up the backbone and where it stops; `assets` the Assets view's tree (places, not placed, disposed, ports and cables, the CMDB's allocations and their drift), an asset found by its role, the history of its allocations, the filter, and where every side panel's Details link goes; `disks` the disks in the tree (under their server by bay, in stock, their health and pool from the CMDB, what a server's CI lists that no asset records), a disk's placements, the bay row and the page's helpers, which placement fields a form offers, a disk's Details, the storage gates and a pool's members;
the assistant
against a fake LiteLLM streaming the recorded exchanges of `test/fixtures/litellm-exchange.json`
(the loop, the allow-list, ADR-034 T5: asked to run a change it proposes a card and applies
nothing, and the card's job carries the turn; the context in the prompt, the store's caps), the connection
filter, the gate's headers, the installer group and the refused status route, the setup-token rule (ADR-034 T6),
the reads and their cache, every route, Activity and the jumps; the verb manifest and the argv
check (T2); the job model: preview before apply (T3), the installer on every write (T1), the typed
confirmation, the sweep refusal, the serial runner and jobs.jsonl — over hrossen's captured
outputs with a fake runner. `--deep`: the installed service answers `/api/v1/status`.
