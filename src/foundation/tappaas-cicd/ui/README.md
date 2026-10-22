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
time it ran — the three tests run only on `GET /setup?refresh=1`, the page's Check button,
never on a read; each result and its time is kept in `<state dir>/setup-tests.json`), the
identity bootstrap (`config/identities` has an organization and a user),
the nodes (every `site.json` node a cluster member, lib/ts `queryClusterNodes`), the switch
(registered, ports discovered), the admin VPN (a peer in `wgvpn list`), stacks (optional).
Each step is a form over its verbs as jobs. Secrets go through `POST /api/v1/secrets/<name>`
(Installer or the setup token): `acme-dns` → `~/.acme-dns-credentials.txt`, `unifi` →
`~/.unifi-os-credentials.txt`, `wlan` → `~/.wlan-secrets.txt`, mode 0600, in Activity with their
keys and never their values; `GET /api/v1/secrets` names the keys set. The same flows serve
day 2: add a node, an environment, a stack; enrol a device (the wg-quick file to download).

**Overview** — the strip (gates, pulse, last sweep, backups, release, security) and Attention:
every FAIL and WARN with the object it names, a link to it in the console and its "Open in"
jumps. **Site** — the site as built, in four tabs, each at its own address: Overview
(`/site/overview`, also `/site`), Physical (`/site/physical`), Device (`/site/device`) and Storage
(`/site/storage`); the earlier addresses (`/physical`, `/site/physical/<view>`) redirect to them.
**Overview** sums the other three: the site in one line (nodes, switches, APs, racks, pools,
disks, the public address) with Add node and Register joined nodes (`site-manager node
reconcile`) beside it, Update now (`site update`, its plan first) at the top, each rack as a thumbnail of its units (a click opens the Physical view),
the Device view as counts with the findings on devices, each node's
pools with a fill bar coloured by state and its disks with a problem, and every finding of the
topology and the storage inventory, each linked to the view and the object it is on. Below
that, the site's records: `site.json` (Modify), the update schedule, the release train's preview
and status, and the repositories (sync, hold, release, stashes, reconcile).
**Physical** (`/site/physical`): each rack of rack-manager's
`config/racks.json` as a frame with its units numbered as the rack numbers them, each mount as its
faceplate at its units and width with its ports' live state (link, LAG), the cables port to port in
the zone colours below with a label on hover, a device only a cable record places beside the rack,
and an Unplaced tray of the devices mounted nowhere, each with Mount…; a click on a plate or a port
opens the side card to the left of the racks, with Mount…, Move to… and Unmount… besides the
object's own changes. **Device** (`/site/device`) — the topology laid out under the spike's rules (ISP top-left, the firewall
as a callout on the WAN path, the switch in the centre with its ports coloured by VLAN, the
nodes to the right with their uplinks and guests, APs below, buddies and the satellite on the
left), each card and each switch port coloured by its state as the Storage view colours its cards
(its findings' worst level; a drifting port, a node's uplink leg down or a buddy down are warnings;
the reason on hover; one legend for both views); a click opens the object's records, findings, jumps and its day-2 change: a switch
port's record (`switch-manager update-port`) then `switch-manager reconcile`, a node's
`node network show / set`. **Storage** (`/site/storage`, `storage-manager inventory`) — in
columns: the cluster nodes, each node's boot device and pools (with the pool's fill bar), each
pool's disks (a mirror's or a raidz's disks carry its label and a bracket), lines node → pool →
disk; every card coloured by its state (ok green, warn amber, fail red, the reason on hover),
raised by the storage-pools and storage-disks findings on it. A disk's card: model, serial, size,
SMART, life left, temperature, sector counts, its ZFS errors and the jump to the node's Disks in
Proxmox; a pool's: size, used, free, health, scrub, its vdevs and a pie of what it holds — one
slice per guest with its own disks there (linked to its module page), the HA mirror copies of
other nodes' guests as one slice (expandable to the guests), datastores and shares, other
datasets, free. **Modules** — tabs: Installed (the list with its badges, grouped by stack, foundation
first) and one per registered repository (`GET /api/v1/catalogs`: `site-manager repository list`, each
repository's module-catalog.json and each module's own JSON; installed = a deployed instance whose
`moduleSource` is the module's directory, with the instances named and linked; Install = `module-manager
add <m>`, previewed then applied; a catalogue that cannot be read says why); a module's page has
Overview (with the operate column: update, reconcile, test, snapshot, suspend/resume, delete
with the typed name), Config, Drift (on demand), Backup and Activity. Config draws the module as
a tree of cards: the module's own (kind, node, environment, zone and the fields no service owns)
on top, one per service in dependsOn below. Each card's Modify lists every field it owns, typed
from the field schema, its value configured or default, its change class; the fields changed go
to one `module-manager modify <m> --set a=b --set c=d` job (`GET /api/v1/modules/<m>/fields`:
`module-manager fields` + `resolve` + `config/module-fields.json`). **Environments** — environments and
zones with environment-manager's and network-manager's verbs; adding an environment says for each
input whether it must be given or what the manager uses when it is left empty (owner: the first
organization; zone and display name: from the name; DNS mode: the schema's default). The zones
are drawn as cards coloured by type, with an arrow for each `access-to` and a dashed one for each
`pinhole-allowed-from`; a click opens the zone's fields and verbs, and Modify lists every field of
`zones-fields.json` with its value, default and class (one `network-manager modify <zone> --set …`). **Identity** — organizations,
groups, users and roles as a graph of their relations (a group's owning organization, a user's
groups, the roles of users and groups, an organization's owner and parent; `GET /api/v1/identity/records`:
`identity-manager <kind> show` for each), the list beside it, a click for the record and its verbs; a change is staged with `--no-reconcile` and pushed by `identity-manager
reconcile`, previewed. **Backup** — the policy of every module, peers, pulse, restore points;
modify, purge (typed). **Site** — the four tabs above. Add node is a guided sequence in Setup's step rows: declare
the node (`site-manager node add tappaasN --pxe` with its PXE port's MAC, boot disk, WAN and lan
ports, pools), boot it from the network by hand, the install and join watched live (`GET
/api/v1/nodes/<name>/progress`: the provisioning registration, `node-provisioner status`, cluster
membership, site.json; every 10 s), then `node network set` and `node network test`, previewed. **Activity** — the console's jobs, the sweep's runs, the failures ledger and the last
result. Security is a later phase.

Every change is the operate dialog (`web/src/operate.tsx`, spike §5.4): a form built from the
verb's manifest, the exact command (copyable), Preview (the verb's own dry run, streamed), Apply
(enabled by the preview; disruptions are labelled checkboxes; a destructive verb needs the
object's name typed and Installer), Result; a flow of several steps runs them in order.

## The owner's view — `status.<domain>`

A request whose host is `status.…` is read-only whatever its groups (access.ts: the route caps
the role): no job, no setup, no secret, no jump. The front end then shows three pages: the
owner's Overview (`GET /api/v1/owner`, `src/owner.ts` — one sentence about the site, every
service with its displayName, published address and state in plain words: running, backed
up, short of memory, inside the site only; the site in numbers, the off-site copy, the channel,
the operator's address), Physical and Modules (without Config and Drift), and no operate
control anywhere. The route itself is not declared yet: `proxyRoutes` publishes no gated route
(see `../../console/INSTALL.md`, *The owner's route*).

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
| a form's schema (`schemas/zones`, `schemas/environment`, the rack and mount `$defs` of `racks-fields`) | `src/foundation/schemas/<name>-fields.json` of `$CONSOLE_REPO` | 10 min |
| topology (the Physical page) | `network-manager topology --json --health <the cached validate>` | every 5 min |
| the faceplate catalog (a mount's faceplate choices) | `rack-manager faceplates list --json` | 10 min |
| storage (Physical › Storage and Overview) | `storage-manager inventory --json` (SMART included, ≈15 s on three nodes) | 10 min, read when a page asks; no timer of its own |
| zones | `network-manager list --json`, `show <zone> --json` | every 5 min |
| environments | `environment-manager list --json` | every 5 min |
| site | `site-manager site show / node list / repository list --json`, `config/last-update-result.json` | every 5 min |
| security | `health-manager report security --json` | every 10 min |
| peers | `backup-manager peers --json` | every 10 min |
| activity | `journalctl -u update-tappaas.service -o short-iso` (7 days), `config/update-tappaas.failures` | every 5 min |

A page is served from the last answer with its age; a failed refresh keeps the last good
answer and says why. `POST /api/v1/refresh[?what=<read>]` refreshes the console's own cache
now (it changes nothing on the site).

## API (`/api/v1`)

Reads (GET): `me` · `status` · `health` · `gates` · `pulse` · `site` · `modules` · `modules/<m>` ·
`modules/<m>/drift[?refresh=1]` · `zones` · `environments` · `topology` · `storage` · `security` ·
`activity[?module=<m>]` (the sweep's runs, and `jobs`) · `manifests` ·
`jumps/<kind>/<id>[?switch=<s>]` (kind: node, module, switch, port, lag, ap, zone, peer, site;
disk and pool, whose id is the node: its Disks and ZFS panels in Proxmox).
Each answers `{data, at, ageSeconds, refreshing, error}`.

## Jobs — every change (ADR-034 D4)

| | |
|---|---|
| `POST /jobs {argv, preview: true}` | a **preview**: the verb's own dry run (`reconcile` without `--apply`, `--check`, `--dry-run`, `modify`'s pre-gate). A verb with no dry run gets a preview that runs nothing and says what the verb touches and the exact command apply will run. |
| `POST /jobs {argv}` | a **read** verb (`module test`, `node network show`, `wgvpn list`): runs at once. A write without a preview is refused (T3). A read verb's `writeWhen` option (`test --deep`, which creates and removes guests; a disruption flag) makes that call a write with no dry run: previewed and queued like any change, never beside the sweep. |
| `POST /jobs/<id>/apply {confirm?}` | the **apply** of a finished preview, less than an hour old: its own argv plus the applying flag (or without the dry run). A destructive call (`delete`, `purge`, `retire`, `erase`, `--remove`, `--decommission`, `key import`, …) needs `confirm` = the object's name, and the Installer role. |
| `GET /jobs` | every job (newest first), the queue, and the sweep's state |
| `GET /jobs/<id>` | the job with its output; with `Accept: text/event-stream` its output as it comes (`job`, `output`, `state`, `end` events) |

A job is posted as `application/json` (a cross-site form cannot). Who may: the gate's Admin
(every non-destructive verb) or Installer (every verb), or the setup token while setup is
open; loopback without the gate's headers and the `status` route start no job (T1, T6).
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
| **Trail** | a card's Preview/Run are the P2 job flow with `{conversation, proposal}`: the job checks the proposal is in the caller's own conversation with the same argv, and carries `origin: assistant` and the turn; Activity shows "lars · via assistant" |
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
| the firewall (Caddy + the Authentik gate) | always | `X-Authentik-Username` / `-Groups`; a request without them is 401 (a route without the gate) |
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

The headers are believed only from the firewall's address, which is why nothing else on
mgmt may connect. The firewall's address is the gateway of mgmt's network in `zones.json`
(its `ip`, first address: `10.0.0.0/24` → `10.0.0.1`); only when that is unreadable does the
console ask DNS for `firewall.<mgmt domain>` (`CONSOLE_FIREWALL` overrides both).

Roles come from the Authentik groups, by their TAPPaaS names (identity creates them,
`identity/USERS.md`): `installer` → **Installer**, `admin` (the `admin` role, which Authentik
carries as a group) → **Admin**, `users` → read; `status.<domain>` caps every role at read.
A write — any job — needs the gate (Admin, or Installer for a destructive verb) or the setup
token while it is active; loopback without the gate's headers reads only.

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

`test.sh`: `tsc` on the backend and the unit suite (`test/unit/*.test.ts`) — the assistant
against a fake LiteLLM streaming the recorded exchanges of `test/fixtures/litellm-exchange.json`
(the loop, the allow-list, ADR-034 T5: asked to run a change it proposes a card and applies
nothing, and the card's job carries the turn; the context in the prompt, the store's caps), the connection
filter, the gate's headers, the role table and route cap, the setup-token rule (ADR-034 T6),
the reads and their cache, every route, Activity and the jumps; the verb manifest and the argv
check (T2); the job model: preview before apply (T3), the roles on every write (T1), the typed
confirmation, the sweep refusal, the serial runner and jobs.jsonl — over hrossen's captured
outputs with a fake runner. `--deep`: the installed service answers `/api/v1/status`.
