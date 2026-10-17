# console — the TAPPaaS console (ADR-034)

The site's web UI: its health at a glance, the site drawn as it is cabled, the modules and
what the sweep did. A service of the mothership (`tappaas-console.service`, run as
`tappaas`), published through Caddy and the Authentik gate by the thin `console` module
([`../../console/`](../../console/)). This is phase **P1 — see**: every page reads; nothing
writes. The job model (P2), the assistant (P3) and agents (P4) come later
([ADR-034](../../../../docs/ADR/ADR-034%20-%20TAPPaaS%20User%20Interface.md), Implementation plan).

```
ui/
├── src/            the backend (TypeScript, no npm dependencies, built like a manager)
├── web/            the front end (Vite, React, React Flow; built by default.nix)
├── test/           unit tests over hrossen's captured outputs (test/fixtures)
└── default.nix, install.sh, update.sh, test.sh
```

## Pages (P1)

**Overview** — the strip (gates, pulse, last sweep, backups, release, security) and Attention:
every FAIL and WARN with the object it names, a link to it in the console and its "Open in"
jumps. **Physical** — the topology laid out under the spike's rules (ISP top-left, the firewall
as a callout on the WAN path, the switch in the centre with its ports coloured by VLAN, the
nodes to the right with their uplinks and guests, APs below, buddies and the satellite on the
left); a click opens the object's records, findings and jumps. **Modules** — the list with its
badges; a module's page has Overview, Config, Drift (on demand), Services, Backup and Activity.
**Activity** — the sweep's runs, the failures ledger and the last result. The other navigation
entries are later phases.

## How it reads the site

Only through the managers' `--json` (and `lib/ts`), never `pvesh` or `ssh` of its own:

| Read | Verb | Refreshed |
|---|---|---|
| health, gates, pulse, Attention, badges | `health-manager validate --json` | every 10 min |
| modules | `module-manager list --json`, with `backup-manager list --json` for the backup badge | every 5 min (backup 10) |
| a module | `module-manager show / resolve <m> --json`, `backup-manager show / coverage <m> --json` | 5 min, on first view |
| a module's drift | `module-manager drift <m> --json` | on demand only |
| topology (the Physical page) | `network-manager topology --json --health <the cached validate>` | every 5 min |
| zones | `network-manager list --json`, `show <zone> --json` | every 5 min |
| environments | `environment-manager list --json` | every 5 min |
| site | `site-manager site show / node list / repository list --json`, `config/last-update-result.json` | every 5 min |
| security | `health-manager report security --json` | every 10 min |
| peers | `backup-manager peers --json` | every 10 min |
| activity | `journalctl -u update-tappaas.service -o short-iso` (7 days), `config/update-tappaas.failures` | every 5 min |

A page is served from the last answer with its age; a failed refresh keeps the last good
answer and says why. `POST /api/v1/refresh[?what=<read>]` refreshes the console's own cache
now (it changes nothing on the site).

## API (`/api/v1`, all GET)

`me` · `status` · `health` · `gates` · `pulse` · `site` · `modules` · `modules/<m>` ·
`modules/<m>/drift[?refresh=1]` · `zones` · `environments` · `topology` · `security` ·
`activity[?module=<m>]` · `jumps/<kind>/<id>[?switch=<s>]` (kind: node, module, switch, port,
lag, ap, zone, peer, site). Each answers `{data, at, ageSeconds, refreshing, error}`. Any
other method is 405: P1 has no write endpoint.

## Who may reach it

| From | Accepted | Identity |
|---|---|---|
| the firewall (Caddy + the Authentik gate) | always | `X-Authentik-Username` / `-Groups`; a request without them is 401 (a route without the gate) |
| loopback (and `--allow`) | always | none: role `read` (a dev port-forward arrives as loopback) |
| mgmt and the admin VPN | only while setup is open (below), with the token | `setup`, role `installer` |
| anything else | refused on connect | — |

The headers are believed only from the firewall's address, which is why nothing else on
mgmt may connect. Roles come from the Authentik groups: **Installer** → installer,
**Admin** → admin, **users** → read; `status.<domain>` caps every role at read. P1 reports
the role (`/api/v1/me`); P2 enforces it on the jobs.

**The setup token (ADR-034 D10).** `bootstrap.sh` writes `~/config/console-setup-token` and
the install summary prints it. While `config/identity.json` does not exist, the console
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

`test.sh`: `tsc` on the backend and the unit suite (`test/unit/*.test.ts`) — the connection
filter, the gate's headers, the role table and route cap, the setup-token rule (ADR-034 T6),
the reads and their cache, every route, Activity and the jumps — over hrossen's captured
outputs with a fake runner. `--deep`: the installed service answers `/api/v1/status`.
