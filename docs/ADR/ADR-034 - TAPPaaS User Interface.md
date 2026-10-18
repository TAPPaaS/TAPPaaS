# ADR-034 — TAPPaaS User Interface

| | |
|---|---|
| **Status** | **Draft** |
| **Version** | 0.3 |
| **Date** | 2026-10-18 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | **#844** (the UI design spike and this ADR). Related: #839 (the UI, physical view first), #183 (service catalog), #91 (Backstage), #142 (agent access to `tappaas-cicd`), #843 (SIEM); caused #853, #854, #855 (switch-controller and console gaps) and #856 (the admin tunnel). Builds on ADR-007 (taxonomy, 007e Health, 007f managers and controllers), ADR-020 (declared-field changes), ADR-021 / ADR-023 / ADR-032 (reachability, routes, exposure), ADR-031 (pulse). |
| **Changelog** | v0.3 (2026-10-18) — as built through P3 and reviewed on hrossen: **D2** the route is `console.<domain>` through Caddy and the gate from `mgmt` and `admin` only, certificate by HTTP-01, 403 to the internet, `internet` refused in the zone list, the admin tunnel's DNS and routes (#856) a prerequisite; `status.<domain>` waits for gated `proxyRoutes`; **O1** closed (`console.<domain>`, passed as `--proxyDomain`), **O2** and **O3** closed as built; D1, D3, D4, D7 and D10 say where the build differs; *As built* added to the Implementation plan; Consequences gain #853 to #856; A15 (an `.internal` name with a site CA). · v0.2 (2026-10-17) — **D10 installation**: after `bootstrap.sh` the rest of the install is a Setup wizard over the same jobs, with a setup token before identity exists (operator agreed 2026-10-17); P1 and P2 amended. · v0.1 — first draft, from the design spike [`docs/design/ui-spike.md`](../design/ui-spike.md) and the operator's decisions of 2026-10-17 (homelable is inspiration, not the product; operators plus a read-only owner view; every verb reachable, destructive ones behind a typed name; the assistant proposes and never applies). |

One web UI for a TAPPaaS site: it shows the site and its health, draws the site as it is cabled,
operates it through the managers and nothing else, and carries an assistant one can talk to.

## Context

TAPPaaS is operated from the command line on `tappaas-cicd` and through the web UIs of the parts
it is built from: Proxmox, OPNsense, PBS, Authentik, Grafana, the UniFi controller. There is no
picture of a site as a whole, no place where its health is read at a glance, and no way to operate
it without a shell. #839 asks for a UI with the physical view first; #844 asked for a spike before
the decision. The spike is done: it maps every manager verb to a place in the UI, derives the
physical view of hrossen from manager output alone, and draws seven wireframes from hrossen's real
records. This ADR takes the decisions the spike left open. The mockups stay in the spike and are
not repeated here.

### What exists today

| Need | What answers it today | Gap |
|---|---|---|
| Health at a glance | `health-manager validate` (text), the sweep's failure mail, Grafana alerts | no one page; ADR-007e's Site-level Health page does not exist |
| The site as cabled | `site-manager node network show`, `switch-controller list-ports`, `ap-controller list`, `zones.json` | five outputs, no join, no picture; the WAN path is visible on no screen |
| Operate | every manager and controller as a CLI, with `--help` first and a dry run on most write verbs (#644, ADR-020) | shell only; the intent of a change is in nobody's trail but the journal |
| A service catalog (#183) | `src/module-catalog.json`, `module-manager module list` | no browse, no add without the CLI |
| An assistant | Open WebUI against LiteLLM, with no knowledge of the site | cannot read the managers |
| Agent access (#142) | SSH as `tappaas` | the same power as the operator, no scopes, no trail of intent |

The control plane already has what a UI needs underneath: managers answer `--json`, refuse an
option they do not declare, and preview before they write (`--check`, `reconcile` without
`--apply`, the ADR-020 pre-gate). `lib/ts/src/cluster.ts` is the one reader of runtime state
(F12 in `tappaas-cicd/DESIGN.md`). Caddy and the Authentik gate publish a hostname per route with
its own zones and policy (ADR-023, ADR-032). The UI is a client of all this, not a replacement.

### The decisions taken before the spike (operator, 2026-10-17)

- **homelable is a library and an inspiration, not the product.** The UI is TAPPaaS's own; the
  physical view borrows homelable's canvas approach.
- **Audience: operators, and the site owner read-only.** End-user badges on the Authentik start
  page and a cross-site view are later.
- **Every manager verb is reachable, destructive ones behind a typed name.**
- **The assistant proposes; the operator runs.** It reads freely and never applies a change.

## Requirements

| | Requirement | From |
|---|---|---|
| **U1** | Show a running site and its health at a glance: the gates, the pulse, the last sweep, backups, the release, CVEs, and what needs a person. | #839, ADR-007e |
| **U2** | Draw the site as it is cabled: nodes and their ports, switches and ports, APs and SSIDs, the firewall, the WAN, the satellite and the buddies, with what runs where and live state on it. | #839 |
| **U3** | Operate the site: every manager and every verb, through the managers, never around them. | brief, #844 |
| **U4** | A change is previewed before it is applied, and recorded afterwards. | ADR-020, #844 |
| **U5** | Jump to Proxmox, OPNsense, Grafana, PBS, Authentik, the switch controller and the SIEM at the object in view, for debugging only. | brief |
| **U6** | An assistant one can ask about the site, through LiteLLM when the AI stack is installed. | brief |
| **U7** | Runs on `tappaas-cicd` as `tappaas`; authenticates through identity; authorizes by role; reachable inside the site through the proxy. | brief, #844 |
| **U8** | A read-only view for the site owner, from the trusted client zones. | operator |
| **U9** | Fed from TAPPaaS's own records, never a hand-drawn diagram. | #839, #844 |
| **U10** | Machine callers use the same API with their own identity. | #142 |
| **U11** | The SIEM's findings are visible where the operator already looks; its dashboard is a jump. | #843 |
| **U12** | Once the mothership exists, the rest of the installation is done from the UI, resumable; the same wizard pattern adds a node, a satellite, an environment, a stack or a device later. | operator, 2026-10-17 |

Out of scope: a service desk or ITSM (#63), replacing Grafana, Proxmox or OPNsense screens,
multi-site operation (ADR-024), end-user self-service.

## Decision

### D1. A native TAPPaaS UI, `console`, as a service of the mothership with a thin published face

The UI is TAPPaaS's own: a TypeScript backend on `tappaas-cicd`, running as the `tappaas` user,
and a browser front end it serves. The backend is the only thing that talks to the managers.

It is built in two halves:

- **The service** lives with the mothership: code under `tappaas-cicd/ui/`, a systemd unit in
  `tappaas-cicd.nix`, as the alert receiver does. The mothership's NixOS config owns what runs on
  it (#675). `~/bin/console` is built by the control-plane refresh after the system is built, so
  a path unit starts the service when the bin appears.
- **The published face** is a thin **`console` module** (`kind: application`, `vmname`
  `tappaas-cicd`, under `src/foundation/console/`): `console.json` whose `dependsOn` gives it
  `network:proxy`, `network:rules` and `identity:accessControl`, and whose `integratesWith` gives
  it `litellm:models` for the assistant's virtual key (D7); its `fields.json` holds
  `assistantModel`, and its `test.sh` checks the service and the gated route. The module is how
  the route, the gate and the key are declared; it installs no VM.

The backend is a manager-shaped reader and a verb runner. It reads runtime state through
`lib/ts/src/cluster.ts` like a manager and writes only by running manager verbs: never a
controller, never `pvesh` or `ssh`. It caches its reads on a timer (health every 10 minutes, the
module list and the topology every 5, drift on demand) and streams job output over server-sent
events. It owns no state the managers do not. Under `/var/lib/tappaas/console/` it writes
**Activity**, an append-only job log (`jobs.jsonl`), and the assistant's conversations (D7); the
only other files it writes itself are the Setup wizard's three declared secrets (D10).

The module and the hostname are `console`: the route is `console.<domain>` (O1, closed).

### D2. `console.<domain>` through Caddy and the gate, from `mgmt` and `admin` only; the backend accepts the firewall only

The console follows the TAPPaaS rule: **`name.<domain>` goes through Caddy, `name.<zone>.internal`
is direct** (ADR-021). It is a gated service, so it is published as `console.<domain>` through
Caddy and the Authentik gate. The `console` module has two routes (ADR-023, ADR-032 E4), both
`proxyAuth: gate`:

| Route | `proxyAllowedZones` | Who | May |
|---|---|---|---|
| `console.<domain>` | `mgmt`, `admin` (the admin VPN, ADR-010) | Authentik groups `installer`, `admin` | read and operate; destructive verbs `installer` only |
| `status.<domain>` | the trusted client zones of the default environment | group `users` | read the owner view: Overview, Physical, Modules; no actions, no jumps, no assistant |
| `/api/v1` on either | as the route | an Authentik app password or JWT at the gate (ADR-032 D3) | by scope: `read`, `operate`; never destructive |

- **The name is public, the service is not.** `console.<domain>` has a public DNS record and its
  certificate comes by HTTP-01 (Caddy answers the challenge on :80), or from the wildcard where
  the site has one. Every source outside the route's zones, the internet included, gets 403 from
  Caddy before the gate.
- **`internet` is refused** in the console module's `proxyAllowedZones`: its install stops on
  a zone list that contains it.
- **The name is passed at install.** The module's `vmname` is `tappaas-cicd`, so its route would
  default to `tappaas-cicd.<domain>`; the install passes `--proxyDomain console.<domain>`.
- **Over the admin VPN** the tunnel's peer config must carry the site's DNS and host routes to the
  DMZ gateway (#856): the site's resolver answers the published name with the DMZ gateway, the
  host routes carry it through the tunnel, and it arrives from the admin overlay. Without them a
  laptop resolves the public address, crosses the internet and gets the 403. ADR-021 D3a covers
  the firewall side. #856 is a prerequisite of the install.
- **`status.<domain>` waits for gated `proxyRoutes`.** `proxyRoutes` (ADR-023) publishes a further
  name with its own zones but never behind forward-auth; declared today, the route would reach the
  backend without the gate's headers and be refused (401). The backend side is built; the route is
  declared once a further route can be gated (ADR-032 D1, `proxyAuth` per route).

The backend listens on the mothership's `mgmt` address and loopback and **accepts connections
only from the firewall's address** (the gateway of `mgmt` in `zones.json`) and loopback, so the
`X-Authentik-*` headers cannot be presented by anything else on `mgmt`. A request from the
firewall without them came through an ungated route and is refused. Loopback without the headers
reads only (`tappaas ask`, a development forward). Before identity exists, `mgmt` and the admin VPN
are accepted with the setup token (D10). The backend treats the `status` route as read-only
whatever the caller's group: the route caps the role, defence in depth over the group mapping
(D3).

Jumps into the component UIs (U5) open a new tab at the object in view: Proxmox at the node or
guest, OPNsense at the interface or its rules, Grafana Explore with the host pre-filled, PBS at the
datastore, Authentik at the object, UniFi at the device, the SIEM at the agent. They are offered
only when the viewer's zone can reach the target; the `status` route never shows them. The UI
never embeds these in an iframe and never re-implements them.

### D3. Authentication by the gate, authorization by Authentik group, capped by the route

Authentication is `identity:accessControl`: Authentik forward-auth at Caddy, one provider per
hostname, the groups in `X-Authentik-Groups`. The UI has no login code of its own.

Authorization is a role table in the backend, keyed by group by its TAPPaaS name
(`identity/USERS.md`), compared without case:

| Group | Role | May |
|---|---|---|
| `installer` | Installer: operate + destructive | every verb, including `delete`, `purge`, `retire`, `erase`, `--remove`, `--decommission`, `key import` |
| `admin` | Admin: operate | every read and every write verb that is not destructive |
| `users` | read | the reads the owner view shows |

`admin` is the TAPPaaS `admin` role, which Authentik already carries as a group; a config group
of that name would collide with it. `installer` is a new group, created by the identity bootstrap
with the installer in it and by `module-manager update identity` on an existing site.

A destructive verb needs the object's name typed and the Installer role; the purge of backups is
a second, separate confirmation, never a side effect of a delete. The route caps the role (D2):
`status` is read whatever the group. Machine callers (D8) get the same table through the
provider's policy and a scope, and never the destructive role.

### D4. Read-only first; then every change is a job that runs a manager verb with its own preview

**P1 is read-only** (see the Implementation plan): typed reads over the managers' `--json`, the
jumps, and Activity from the sweep's journal. Nothing in P1 writes.

From P2, every change, whatever the page, is one pattern: **Change → Preview → Apply → Result.**

1. **Change** — a form built from the verb's **manifest**, its declared options, pre-filled with
   the current value. Fields show their ADR-020 change class before anything is typed; an
   immutable field is refused up front.
2. **Preview** — the manager's own dry run: `--check`, `--dry-run`, `reconcile` without
   `--apply`, `delta`, the `modify` pre-gate, `tappaas-train preview`. A preview is never skipped;
   it enables Apply. A verb with no dry run declares *no preview*, and the preview is the command
   and what the manifest says it touches.
3. **Apply** — the same argv with the applying flag, only from a finished preview of that argv
   less than an hour old. A disruption (`--force`, `rebootOk`, `--yes`) is a checkbox that names
   its consequence; a destructive verb needs the typed name (D3), the name the manifest gives as
   the call's object.
4. **Result** — streamed output, exit code, duration; the read caches refresh. The job is in
   Activity with who, from where (UI, assistant, agent), the argv, the preview and the output.

The API is a **hybrid**: typed reads, and a **job model** for writes. A job carries the exact
command line, validated against the manifest derived from each manager's `--help` (every manager
answers `--help` first and refuses an option it does not declare, #644). What the UI can do is
exactly what the CLI can do; a verb absent from the manifest is absent from the UI. The UI never
runs a controller directly: a switch port is changed through `switch-controller` behind
`network-manager`'s pages, a VM through `module-manager`, never through `pvesh`.

Long-running verbs (`module update`, `add-stack`, `site update`, `update-os`, `test --deep`) run
as jobs the browser may leave. Writes are serialized through one job runner; it refuses to start
while `update-tappaas.service` is active and says so, with the sweep's stage. A second operator's
job queues behind the first and both see the queue; a queued job whose turn comes during a sweep
is refused too. Reads never need confirmation.

As built (P2), where it differs from the above:

- **The manifest has two sources.** The TypeScript managers answer `<manager> --help --json`
  (`lib/ts` `renderManifest`); the bash verbs (`switch-controller`, `ap-controller`,
  `tappaas-train.sh`, `acme-setup.sh`) are declared in `ui/manifest/bash-verbs.json`, with how
  each previews and what it touches.
- **Read verbs are jobs without a preview.** A verb that changes nothing (`module test`, `node
  network show`, `wgvpn list`) runs at once, beside the queue, and is in Activity.
- **No manager lock is taken.** The one runner and the sweep refusal are the serialization.
- **`module-manager` grew `fields <m>` and `modify --set … --dry-run [--json]`**, the pre-gate as
  a preview and the change class of each field for the form.
- **A destructive call's object is the verb's first positional.** For `switch-controller
  remove-port <switch> <port>` that is the switch, not the port; #855 makes the manifest name the
  object.
- **A preview is not always free of side effects.** `site-manager node network set` without
  `--apply` writes the declaration into `config/<node>.json`; the console trusts the manager's
  dry run, so the manager must make it one.

### D5. The physical view is derived from one topology document, owned by `network-manager`

The UI owns no model of the physical site, and G6.1 (the switching fabric) builds no second one.
A new read-only verb joins what the managers already produce:

```
network-manager topology [--json]
```

Its sources: `site-manager node list` and `node network show` (members, pools, bonds, legs, LLDP
partners, the `wan` port), `switch-controller list / list-ports / lag list` (switches, ports,
VLANs, LAGs, drift), `ap-controller list` (APs, uplink port, SSIDs), `network-manager list`
(zones, VLANs, state), `module-manager module list` (guests per node), `site.json` `network` (the
WAN), `backup-manager peers` and `pulse` (buddies, the satellite, liveness), `pvesh
/cluster/resources` through `lib/ts` (run state), and `health-manager validate`'s fabric gates
(`lan-uplink`, `pulse`, `quorum`) as findings placed on the object they mention. The document's
shape is in the spike (§5.5); it is versioned with the manager.

The UI lays it out automatically and places nothing by hand (U9). The same document feeds an
**SVG export** for the documentation and the site-down mail (ADR-031). When G6.1 adds a systematic
switch model (trunk planning at install, several switches, MC-LAG), it extends this document and
the view follows.

### D6. The service catalog is the Modules page; Backstage is not adopted

**#183 is folded into Modules.** The Modules page is the catalog: the catalogues of every
registered repository, *Add module* and *Add stack*, badges for run state, health, backup, drift,
CVE and maturity, RBAC by group (D3). Its success criteria hold: a module in under five clicks,
no CLI for the standard cases. A module's page has the tabs Overview · Config (`module resolve`)
· Drift (`module drift`) · Services (the fields each owns and their change class) · Backup ·
Logs (a Grafana jump) · Security · Activity, with every `module-manager` verb in its operate
column.

**#91 (Backstage) is not adopted** and is closed with this ADR: a developer portal, not an
operations console; its catalog entities duplicate `module-catalog.json`; nothing of the physical
view.

### D7. The assistant runs in the backend, through LiteLLM, proposes, and never applies

The agent loop runs **in the UI backend**, so its tools, its audit and its role are the same as
for a click.

- **Transport:** LiteLLM's OpenAI-compatible chat completions, streamed, with tool calling; the
  virtual key from `litellm:models` as for Open WebUI (`/etc/secrets/litellm-svckey.env`, re-read
  while missing, so no restart when it arrives). The model is `assistantModel` in the console's
  fields when set, else LiteLLM's model named `default`, else the first the key may use (O3).
  Nothing leaves the site that LiteLLM does not send.
- **Tools:** the console's own cached reads (`modules_list`, `module_show` with the fields
  `modify --set` may change and their class, `module_drift`, `zones`, `environments`, `topology`,
  `health`, `backup`, `pulse`, `activity`), `logs` (Loki's `query_range` for a host, when logging
  is installed), `help(manager)` (the manifest and the README), and **`propose_job(argv,
  rationale)`**, which validates the argv against the manifest and creates no job. **No apply
  tool exists**; a tool name outside the list is refused and recorded. A proposed job is a card
  with Preview and Run; only the operator's click runs it, under the operator's role (D3).
- **Context:** the page and object in view, the site's name, the operator's name and role.
- **Trail:** a card's Preview and Run are D4's jobs; the job checks the proposal is in the caller's
  own conversation with the same argv and records the turn that proposed it. Activity shows
  "`<operator>` · via assistant" on jobs that came from a card.
- **Conversations** are kept per user in the state directory
  (`assistant/<user>/<id>.json`, mode 0600, the newest 50, 40 turns and 256 KiB each), never in
  `config/`; a caller sees only their own.
- **Elsewhere:** `tappaas ask "…"` on `tappaas-cicd`, a client of the backend on loopback, so with
  the read role: a proposal is printed as its preview and apply command lines, never run. An MCP
  façade over the read API may follow for Claude Code and Open WebUI; it is not part of this ADR.
- **Without the AI stack** the drawer and its buttons are absent and `tappaas ask` says why and
  exits 1. The `status` route has no assistant.

### D8. Agents use the same API through the same gate, with an Authentik identity and scopes

#142 is answered by D2 and D3, not by a second token scheme. An external agent is an Authentik
user or service account with an **app password or a client-credentials JWT**, presented at the
gate (ADR-032 D3) on `/api/v1`. Who may call is the provider's policy; what it may do is a
**scope** (`read`, `operate`) mapped by the backend's role table; the destructive role is never
granted to a machine caller. Every agent job is in Activity with the agent's own identity. The
firewall rule is the route's zone list; an agent outside `mgmt` and `admin` reaches nothing.

### D9. Technology: TypeScript backend on `lib/ts`, React, React Flow with automatic layout

- **Backend: TypeScript.** The F12 rule (`tappaas-cicd/DESIGN.md`) lets a reader of runtime
  state use only `lib/ts/src/cluster.ts`, and the typed reads reuse the managers' own types
  (`ClusterInspection`, drift records, resolved desired state). The verb manifest comes from
  `lib/ts/help.ts`, which already renders the help. Python would shell out for everything.
- **Front end: React.** Served by the backend; one bundle, no second service.
- **Physical view: React Flow** (`@xyflow/react`, MIT) with **automatic layout** (dagre or ELK)
  from the topology document, under layout rules (WAN top-left, switches centre, nodes right, APs
  and outside parties on the edges). Nodes are React components, so a node card holds its guests
  and a port is clickable.
- **homelable** (`Pouzor/homelable`, MIT) is a reference, not a dependency: its canvas library,
  its visual grammar (a status dot on every node, links coloured by what they carry, a side panel
  on click, ports drawn on the switch) and its OIDC and MCP patterns are what is borrowed.

### D10. After the mothership exists, the installation continues in a Setup wizard over the same jobs

The install has a hard boundary: before `bootstrap.sh` has rebuilt VM 130 no TAPPaaS process can
serve a page. After it, every remaining step is a manager verb — the site and zone setup,
`acme-setup.sh`, backup, identity, logging and the identity bootstrap (`rest-of-foundation.sh`),
more nodes (`node add --pxe`), environments, the satellite, the admin VPN peer, the switch
registration, `add-stack`. Therefore:

- **The console is part of the mothership's own build.** Its unit is in `tappaas-cicd.nix` (D1),
  started by a path unit once the control-plane refresh has built `~/bin/console`, so it is up
  when `bootstrap.sh` finishes, and a fresh install ends with the console reachable.
- **A Setup wizard drives the rest.** It is a thin layer over D4's job model: an ordered checklist
  whose state is **derived from the records**, never stored, so it resumes for free. As built
  (`ui/src/setup.ts`): TLS (wildcard: `cert-refids.json` names the default environment;
  per-service: nothing to issue, Caddy gets each route's certificate), backup, identity and
  logging (their config exists and their module test passes), the identity bootstrap (an
  organization and a user), the nodes (every `site.json` node a cluster member), the switch
  (registered, ports discovered), the admin VPN (a peer in `wgvpn list`), stacks (optional). Each
  step is a form over its verbs with the preview and apply of D4 and progress for the slow steps.
  The wizard runs the verbs step by step; the scripts stay for headless installs.
- **A setup token bridges the window before identity.** The gate of D3 does not exist until the
  identity step has run. `bootstrap.sh` writes a one-time token (`~/config/console-setup-token`),
  the install summary prints the address with it, and while `config/identity.json` does not exist
  the console accepts `mgmt` and the admin VPN with that token (`?token=` once, then an HttpOnly
  cookie, or a bearer header) and nothing else; the token acts as Installer. Once identity exists
  the token is refused even if its file remains, and the file is deleted after the identity step
  and at start. This is a necessity of install order, not an SSO-optional mode; it closes itself.
- **Secrets are entered in the wizard** into the places the scripts already read, mode 0600, and
  never shown again; Activity records their keys, never their values. As built, three declared
  files only: the DNS provider credential (`~/.acme-dns-credentials.txt`), the UniFi controller's
  (`~/.unifi-os-credentials.txt`) and the WLAN passphrases (`~/.wlan-secrets.txt`). A satellite's
  address and key and a buddy's tunnel are not yet among them.
- **The same pattern serves day 2:** add a node, a satellite, an environment, a stack; enrol a
  device in the admin VPN. Each is a wizard of a few steps over verbs already on the pages.
- **The pre-mothership chain stays a script.** Later, a preparation wizard (a page that collects
  what `preparation.md` asks for and emits the answers the chain reads) removes its questions; an
  installer image with its own page on the first node is further out and not required.

## Alternatives considered

| | Alternative | Why not |
|---|---|---|
| A1 | **Fork and extend homelable** with a TAPPaaS feeder and manager actions | Its model is a hand-placed canvas with its own state; TAPPaaS truth would be synced *into* it, two sources of truth and a reconciliation of our own. No zone on a port, no bond, no trunk from `zones.json`; no operate flows; a Python backend beside our TypeScript managers; one maintainer, moving fast, a fork diverges at once. Fails U9 and U3. |
| A2 | **Embed homelable as a module**, fed by a sync, a thin console beside it | The same two-truths problem plus a VM and two UIs; the sync is a controller for a visualiser; its own scanner shows a second, drifting picture. |
| A3 | **Backstage** (#91) | A developer portal, not an operations console; a heavy monorepo with a plugin for everything; its catalog duplicates `module-catalog.json`; nothing of the physical view. Closed by D6. |
| A4 | **Grafana as the UI** (dashboards, Node Graph, button plugins) | A visualisation tool: no forms, no preview and apply, no typed confirmation, no verb manifest. Operate would be bolted on with plugins calling an API we must build anyway. Kept as the jump for logs and metrics (D2). |
| A5 | **A web terminal** (ttyd, Cockpit) to the CLIs | No understanding view; no preview or audit of intent; a shell as `tappaas` behind forward-auth is SSH with a weaker trail. Cockpit's login is PAM, not Authentik. Not even as a stop-gap. |
| A6 | **Cytoscape.js** or **server-side SVG** (d2, Graphviz) for the physical view | Cytoscape's nodes are not components, so a node card is hard. Server-side SVG is not interactive; a port cannot be clicked. Kept as the export of D5. |
| A7 | **A generic verb pass-through** (`POST /run {argv}`) | The UI invents nothing but knows nothing: no forms, no typed results, an API that is a shell. |
| A8 | **A typed resource API** (`POST /modules/immich/modify`) | A second copy of every verb's semantics that drifts from the managers. D4's hybrid keeps the reads typed and the writes as the CLI's own argv. |
| A9 | **One hostname with roles** instead of two routes | A read-only owner from the client zones would share a route with operators on `mgmt`; two routes let the zone list and the gate's policy differ, and the route caps the role (D2). |
| A10 | **OIDC in the app** (`identity:identity`) instead of the gate | Login code of our own and a second token scheme for agents. The gate gives groups in headers and machine credentials for free (ADR-032 D3). It is also what A15 would force, since a direct name has no gate. |
| A11 | **The agent loop in Open WebUI** or as an MCP server only | Tools, audit and role would differ from a click. An MCP façade over the same API can come later (D7). |
| A12 | **An agentic assistant** that applies within a scope | Decided against: the record must show that a person decided. |
| A13 | **A separate installer UI** (a web page on the first node's installer image, or on the laptop) for the whole of stage 3 | Different work from this ADR: it needs an image and runs before any manager exists. D10 takes the half the managers already cover and leaves the chain a script, fed later by a preparation wizard. |
| A14 | **Keep the install on the command line** and start the UI at operate | Leaves the longest, most error-prone stretch of a new site's life without the preview, the record and the resumable checklist that the UI gives every other change; the wizard is a thin layer once D4 exists. |
| A15 | **An `.internal` name** (`console.mgmt.internal`) **with a site CA**, so that no public DNS record names the console | Breaks the TAPPaaS rule: `name.<zone>.internal` is direct, around Caddy and the gate, so the console would need login code of its own (A10) or a second kind of gated route; and every operator's browser would have to trust a CA of the site's. A public name that answers 403 outside `mgmt` and `admin` (D2) discloses only that the console exists. |

## Consequences

- One UI, one API, one auth. The browser, the assistant and agents are three clients of
  `/api/v1`; what any of them can do is what the CLI can do, under the same gate and the same
  role table.
- Everything is ours to build and keep: the backend, the front end and the physical canvas, which
  is the hardest part.
- **The managers must grow**, each in its own place; none of it is large:

  | Gap | Where | Why |
  |---|---|---|
  | `health-manager validate --json` | health-manager | the strip, Attention and badges are built from gate results; today they are text |
  | `network-manager topology [--json]` | network-manager | D5; shared with G6.1 |
  | `switch-controller list-ports --json`, `lag list --json`, `ap-controller list --json` | the controllers | the topology join |
  | A verb manifest, `<manager> --help --json` | every manager, through `lib/ts/help.ts` | forms and validation from the declared options (D4) |
  | Sweep state, a progress file beside the failures ledger | `update-tappaas` | "the sweep is running, 12 of 24"; the job runner's refusal |
  | `tappaas-train preview --json` | the train | the release card |
  | A dry run for every write verb, or a declared *no preview* | the managers | D4 refuses to apply without one; `identity-manager <kind> add` and `storage-manager share add` already preview through `reconcile`; a few bash verbs do not |
  | The job log format and location | tappaas-cicd | Activity; `/var/lib/tappaas/console/jobs.jsonl`, one line per job, rotated with the journal |
  | A setup token written by `bootstrap.sh`, printed by the install summary, deleted by the identity step | tappaas-cicd | D10, the wizard before the gate exists |
  | A "done" predicate per install step, from the records | the managers' reads | D10, the checklist's state is derived, never stored |

  P1 to P3 filled the first, second, third, fourth, eighth, ninth and tenth rows, and added
  `module-manager fields` and `modify --dry-run` (D4). Open: the sweep's progress (the runner
  reads the stage `update-tappaas` already writes, `config/.update-stage`), `tappaas-train preview
  --json`, a dry run for every write verb, and a `node network set` preview that writes nothing.
- **Work this ADR caused**, found by the live tests on hrossen, each in its own issue:

  | Issue | Where | What |
  |---|---|---|
  | #853 | `switch-controller`, `health-manager` | unallocated ports parked as `iotLocal` access ports; a verb that parks a port (no verb today returns a port from an override to the controller's default); `validate` warns on an unparked or drifted port |
  | #854 | `switch-controller` | a LAG member follows its lead port: no VLANs, no drift and no push of its own (port 12's drift on hrossen recurs on every reconcile) |
  | #855 | the console's manifest | a destructive verb's typed confirmation names its object: the port for `remove-port`, the aggregate for `lag remove` |
  | #856 | `network-manager wgvpn config`, `ADMIN-VPN.md` | the admin peer's config carries the site's DNS and host routes to the DMZ gateway, so `mgmt`/`admin`-only published services work over the tunnel; a prerequisite of the console's install (D2) |

- `tappaas-cicd.nix` gains a unit and a new place in the mothership's attack surface: a web
  service as `tappaas`. It is reachable only through the gate and only from the firewall's
  address (and loopback, for reads), and it holds no credentials the managers do not already
  hold. Its sandbox is wide: the verbs it runs write across `/home/tappaas` and `/tmp` as they do
  from a shell, and the unit's comment justifies each path; login keys, shell rc files and the
  git config stay read-only.
- `identity:accessControl` gets one more provider now and one with `status.<domain>`, a new
  `installer` group and a group-to-role mapping to document; `network:proxy` gets one route now
  and a gated `proxyRoutes` entry later (D2). `litellm:models` gets one more consumer.
- The site-owner view is the first step toward ADR-007e's end-user badges without building them;
  the same cache can feed badges on the Authentik start page later.
- #183 and #91 close with this ADR; #142 is answered by it; #63 is deliberately not addressed.
  Attention and Activity are the operations record of one site, not a service desk; a ticket
  system stays a separate decision, and Attention could post into one.
- #843's findings surface on the Security page and in Attention through the alert receiver, as
  Grafana's do; the SIEM dashboard stays the place for an investigation.

## Implementation plan

Each phase is live on hrossen before the next starts; the first three are each one release train
or less.

| Phase | Delivers | Exit on hrossen |
|---|---|---|
| **P1 — see** | the backend with typed reads and the cache; Overview (strip, Attention read-only), Physical (view and side panel, no actions), Modules (list and page, read tabs), Activity (the sweep's journal); the jumps; `console.<domain>` behind the gate; the unit in `tappaas-cicd.nix` and the setup token (D10), so a fresh install ends with the console up; `network-manager topology`, `health-manager validate --json` | hrossen drawn correctly, including the WAN path and the LAG; every gate of `validate` visible; an operator finds the cause of a FAIL without a shell; a fresh install on the test system ends with the console reachable |
| **P2 — operate** | the job model with preview and apply; the verb manifest; **the Setup wizard first** (TLS, backup, identity, logging, the identity bootstrap, nodes, the switch, the admin VPN peer, stacks; D10), then every manager's verbs on their pages; typed confirmations; the `status` route for the owner | a fresh install finished from the wizard with no shell after `bootstrap.sh`; the three day-2 changes of #844 done from the UI (a port's zone, a module's memory, a node's uplink mode) with their previews in Activity; the sweep and a UI job never overlap |
| **P3 — ask** | the assistant drawer, the tools, proposed-job cards; `tappaas ask` | the memory question of the spike's mockup answered and its proposal applied by a click; no change ever applied by the assistant (a test) |
| **P4 — secure** | agents through the gate with scopes (#142); the SIEM summary and jumps (after #843); the end-user badges if wanted | an agent lists modules and proposes a job with its own identity in Activity; a Wazuh alert appears in Attention |

### As built (v0.3)

P1 to P3 are built (#839) and were reviewed on hrossen on 2026-10-17 and 2026-10-18 from a
scratch tree: the console ran on loopback behind a proxy that plays the gate's headers (`console
serve --trust-local-headers`, development only), reached from the laptop by `ssh -L`. Nothing was
installed or switched on the mothership.

| Phase | State | Verified on hrossen | Not yet verified |
|---|---|---|---|
| **P1 — see** | done | the fast suites (health-manager, network-manager, both controllers, `ui`) green; the controllers' text output byte-identical to the installed ones; `network-manager topology` live in 4.8 s; `nix build .#console` and a system eval of `tappaas-cicd.nix` with the unit; the four pages drew hrossen correctly | the unit under its sandbox; the gated route `console.<domain>`; the setup token on a fresh install; the jump URLs |
| **P2 — operate** | done; `status.<domain>` built in the backend, not declared (D2) | a module's memory changed and reverted from the Modules page (`deconz-test`, 4096 → 4608 → 4096, no pending change); a switch port set to an access zone and reverted, both applies clicked by the operator, which exposed #853, #854 and #855; a node's uplink mode, network and environment reconciles previewed only; the owner's view through the header proxy as a member of `users` | a fresh install finished from the wizard; the owner's route; a sweep and a job contending live |
| **P3 — ask** | done | the spike's memory conversation against the site's LiteLLM with a temporary key, deleted after: the assistant read that `immich` passes `guest-memory`, proposed `module-manager modify immich --set memory=10240` as a card, refused "ok, run it" and pointed at Run; the card's Preview ran, its Run was not clicked; `tappaas ask` refused a tool that does not exist and then proposed; without a key the drawer is absent and `tappaas ask` exits 1; T5 as a unit test | the key provisioned by `litellm:models` at registration; a card's Run end to end |
| **Install** | open | — | the module registered with `--proxyDomain console.<domain>` and `internet` refused in its zone list, after #856 |
| **P4 — secure** | open | — | — |

## Testing

- **T1 — the gate and the route cap.** A member of `users` on `status.<domain>` sees the owner
  view and gets 403 on every write; an Admin on `console.<domain>` is refused a destructive verb;
  a connection to the backend from a `mgmt` address other than the firewall's is refused.
- **T2 — the manifest.** Every verb in the UI exists in its manager's `--help`; an option the
  manager does not declare is refused by the UI before the job is created.
- **T3 — preview before apply.** No job reaches Apply without a preview or a declared *no
  preview*; the argv applied is the argv previewed plus the applying flag.
- **T4 — the topology.** `network-manager topology --json` on hrossen names every node port,
  switch port, LAG, AP and buddy that the five source verbs name; a finding of `validate` is
  attached to the object it mentions.
- **T6 — the setup token.** It is accepted only before identity's config exists and only from
  the `mgmt` and admin-VPN networks; after the identity step it is gone from disk and a request
  with it gets 401.
- **T5 — the assistant.** Asked to run a change, it proposes a card and applies nothing; the card's
  job carries the conversation turn.
- Unit: the role table, the route cap, the manifest parser, the topology join.
- Module test for `console` (`console/test.sh`): the service answers `/api/v1/status` and every
  cached read answered at its last refresh; an anonymous request to `console.<domain>` is sent to
  the gate (302 or 401), or stopped by the zone filter (403, a warning), and never answered.

## Open questions

1. **O1 — The name.** *Closed (v0.3):* `console.<domain>`, passed as `--proxyDomain` at install
   because the module's `vmname` is `tappaas-cicd` (D2).
2. **O2 — Module or fields.** *Closed (v0.3):* a `console` module, `src/foundation/console/`,
   which declares the route, the gate and the key and installs nothing (D1).
3. **O3 — Where the agent loop's model is pinned.** *Closed (v0.3):* `assistantModel` in the
   console's fields when set, else LiteLLM's `default`, else the first model the key may use (D7).

## Documentation impact (ADR-013)

| File | Change |
|---|---|
| `src/foundation/tappaas-cicd/README.md`, `DESIGN.md` | the `console` service, its unit, Activity under `/var/lib/tappaas/console/` |
| `src/foundation/tappaas-cicd/ui/README.md` (new) | the API, the job model, the role table, the manifest |
| `src/foundation/console/README.md`, `INSTALL.md` (new) | the module, `--proxyDomain console.<domain>`, the setup token, the owner's route that waits, the assistant's key |
| `src/foundation/tappaas-cicd/manager/network-manager/README.md` | `topology` |
| `src/foundation/tappaas-cicd/manager/health-manager/README.md` | `validate --json` |
| `src/foundation/identity/README.md` | the two providers, groups to roles, app passwords for agents |
| `INSTALL.md`, `src/foundation/INSTALL.md`, `src/foundation/tappaas-cicd/INSTALL.md` | stage 3b onward is the Setup wizard; the scripts remain the headless path |
| `docs/design/ui-spike.md` | stays as the mockups and the verb map (Appendix A); points here for the decisions |
| `docs/ADR/README.md` | this row |
