# Develop a Module — quick start

You have an application; you want it on TAPPaaS. What you build is a **module**: your app
plus a small json contract and a few lifecycle scripts, running in its own VM. In return
the platform gives you — without further work — VM provisioning, network zones and
firewall rules, a public URL behind the reverse proxy, scheduled updates, backup, and
health monitoring.

## Before you start

- **A TAPPaaS to develop against.** Ideally a test instance; a sufficiently stand-alone
  module can be developed on a production system — its own VM and, if you want, a
  dedicated zone keep experiments away from production. See
  [Git & repository topology](../../foundation/tappaas-cicd/DESIGN-GIT.md) for the
  dev-instance setup.
- **Decide where your module will be maintained** — the open-source TAPPaaS repo (via
  pull request), a community repository, or a private one. This shapes your git
  workflow: [Git & repository topology](../../foundation/tappaas-cicd/DESIGN-GIT.md).
- **Know how your app ships.** The default module VM is **NixOS** (configured
  declaratively in a `.nix` file); Debian cloud-images, ISO installs and even Windows
  are supported when your app needs them.

## Quick start — template to running VM

Work on the CICD mothership (`tappaas-cicd`), in its checkout of the source repo. A module
lives in the directory of its stack — `src/<stack>/<module>`, where `<stack>` is the `stack`
in its JSON (`ai`, `collaboration`, `devops`, `home`, `security`, or `misc` for one with no
natural stack; #421):

```bash
cd ~/TAPPaaS/src/home                      # the module's stack
cp -r ../misc/00-Template myapp && cd myapp
mv README-template.md README.md
mv template.json myapp.json        # + template.nix -> myapp.nix, or delete it
```

The copied scripts are stubs: each warns that it has not been implemented until you
replace it. `services/myservice/` is a stubbed service — rename it if your module provides
one, otherwise delete `services/` and the `provides` entry in `myapp.json`.

Edit `myapp.json` — at minimum a free `vmid`, sizing (`cores`, `memory`, `diskSize`)
and the zone (`zone0`, typically `srv`), and set `stack` to what the module is for
(the values are listed in [module-fields.json](../../foundation/schemas/module-fields.json)).
The stack also decides the module's **scope** (ADR-022e): only the `foundation`
stack is site-scoped (installed in `mgmt`, official source, `--force` to delete);
every other stack is environment-scoped, which is what an application wants. Then:

```bash
module-manager module add myapp
```

The platform creates the VM, wires its network, and runs your `install.sh`.
**[README.md](README.md) documents every file you just copied** — the json fields,
image/OS choices, providing services, debugging, naming.

## Make it run your application

- **`install.sh`** — called once with the module name; puts your software in the VM.
  For NixOS modules the default `install.sh` rebuilds the VM from `myapp.nix` — porting
  your app is mostly writing that nix configuration.
- **`update.sh`** — called on the platform's update schedule; keeps the app patched
  without operator attention.
- **`test.sh`** — your regression check; the same tests gate updates.
- **`icon.svg`** and **`displayName`** — if your app signs in through the identity provider,
  its tile on the start page shows this icon (square, SVG or PNG) and this name. Without an
  icon the tile is generated from the name.

## Iterate and debug

```bash
module-manager module test myapp        # run your test.sh
module-manager module reconcile myapp   # re-apply the current config to the VM
module-manager module update myapp      # release update: snapshot + test + merge
module-manager module delete myapp      # --archive by default
```

Can't SSH in? [README.md](README.md) shows how to take a VM console screenshot through
Proxmox — works on any OS, including mid-install.

## Output: Info, Debug and the first install

Your scripts run inside every nightly update of the site, next to thirty other modules. What
they print at `[Info]` is what the operator reads; everything else is noise there. The helpers
come from `common-install-routines.sh`:

| Level | Use it for | Example |
|---|---|---|
| `info` | one `✓` line per thing your script established or checked, naming the object | `info "  ${GN}✓${CL} forgejo:repo wired for lazysite: websites/lazysite, read-only deploy key"` |
| `install_note` | where the new module is and how to use it — worth reading once | `install_note "  Site: https://${DOMAIN}"` |
| `debug` | the steps on the way, what already existed, IDs, paths, raw tool output | `debug "  deploy key tappaas-lazysite already in place"` |
| `warn` / `error` | something the operator must know or act on | unchanged |

- **One line per outcome.** Not a header, the steps, then a result: the `✓` line says what is now
  true. A step that only confirms what already existed is `debug`.
- **No banners and no "complete" blocks.** module-manager already announces each step and says
  when the module is done.
- **No progress dots into a log.** Dots are for someone at a terminal (`[ -t 1 ]`); a nightly
  run's journal gets nothing.
- **A failing test** prints the checks that failed (`✗`, `[FAIL]`) and where its full output is
  kept (`~/logs/tests/`), not the whole run.
- **`install_note`** prints at `[Info]` while module-manager installs the module for the first
  time (`TAPPAAS_FIRST_INSTALL=1`, also `first_install` to test it) and at `[Debug]` on every
  update and reconcile after. Use it for addresses, first steps and how-to.
- **A tool's own output** (an API client, `nix`, `curl`) goes to `debug`, not straight through;
  print it when the call fails.
- `--debug` on any module-manager verb shows everything.

## Secrets your module generates

A password, token or key your scripts generate for an instance (a database password, an admin
login, an API token) is kept on the mothership as well as in the guest, so a rebuilt guest gets
the same one back. It has one place:

| What | Where |
|---|---|
| `KEY=value` secrets | `/home/tappaas/secrets/<module>/<instance>.env` |
| secrets that are files (a token, a key) | `/home/tappaas/secrets/<module>/<instance>/` |

`<module>` is your module's name and `<instance>` the instance's (its `config/<instance>.json`;
the same as the module name unless it was installed with `--instance`). Directories are 0700,
files 0600, owned by `tappaas`. The helpers from `common-install-routines.sh` create them that way
and print the path:

```bash
secrets="$(module_secrets_file myapp "${INSTANCE}")"      # .../myapp/<instance>.env
keys="$(module_secrets_dir myapp "${INSTANCE}")"          # .../myapp/<instance>/
grep -q '^DB_PASSWORD=' "${secrets}" || printf 'DB_PASSWORD=%s\n' "$(openssl rand -hex 24)" >> "${secrets}"
```

- Generate a secret only when the file does not hold it yet: install, update and reconcile all run
  the same code, and a secret that changes on every run locks the guest out of itself.
- The mothership's file backup includes `/home/tappaas/secrets`, encrypted like every backup.
- `module delete` (archive, the default) keeps them with the config; `module delete --remove`
  deletes them.
- Encrypting a copy to an operator's key (with `age`, say) is your module's choice; the files are
  readable only by `tappaas` either way.
- Never write a secret to a module config in `config/`, to a log line, or to the command line of
  another host (`ssh host "cmd SECRET"`): pipe it on stdin.

## Alert rules for your module

Your module can tell the operator by mail when one of its log lines says something went wrong.
Put `myapp-alerts.json` next to `myapp.json`. You say **which lines** matter; TAPPaaS builds the
log query, limits it to your module's own guests, loads it into the site's Grafana and mails it
like every other alert. Your module needs `"integratesWith": ["logging:logs"]` so its journal is
shipped at all.

```json
{
  "rules": [
    {
      "name": "sync-failed",
      "title": "Myapp sync failed",
      "kind": "event",
      "match": "myapp: sync failed",
      "capture": { "account": "account=(?P<account>[a-z0-9-]+)" },
      "window": 300,
      "summary": "A sync run failed. The account is named in the subject; the next run retries it."
    },
    {
      "name": "worker-silent",
      "title": "Myapp worker stopped",
      "kind": "state",
      "unit": "myapp-worker\\.service",
      "match": "heartbeat",
      "absent": true,
      "window": 900,
      "summary": "The worker has not logged its heartbeat for 15 minutes.",
      "mail": { "subject": "{state}: {title} on {host}" }
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | short DNS-style name, unique in the file |
| `title` | the alert's name in the mail subject (plain ASCII); `headline` overrides it in the subject |
| `kind` | `event` — something happened, mailed once; `state` — something is so, mailed again when it clears |
| `match` | a regular expression (RE2) a log line must match |
| `unit` | optional: only lines of systemd units matching this expression |
| `capture` | optional: up to 3 labels taken from the line, each an expression with a named group of the label's name; one alert per value |
| `window` | seconds the rule looks back, 60–86400 |
| `above` | optional: fire only when more than this many lines matched in the window |
| `absent` | optional: fire when **no** line matched in the window (a heartbeat that stopped) |
| `repeat` | optional: how often a firing alert is mailed again, `1h`–`24h` (default 4 h) |
| `security` | optional: `info`, `warning` or `critical` — the rule is a security hit (ADR-050). Each hit is kept per rule and machine with its count; a warning holds its threat condition 24 h from the last hit, a critical until someone acknowledges it (`health-manager ack <ci> --type threat --note …`), and info raises nothing. Rendered only while the site's security monitoring is on (`site.json` `security.monitoring`; off on a small site) |
| `summary` | the explanation in the mail |
| `mail` | optional: your own `subject` and `body`, with `{state}`, `{title}`, `{host}`, `{hosts}`, `{module}`, `{labels}`, `{label.<name>}`, `{summary}`, `{since}`, `{resolved}`, `{query}`, `{lines}` |
| `include` | optional: `"bundle"` attaches the site's support bundle; `"lines"` adds up to 20 matching log lines |

- **You never write LogQL.** The query only reads lines your own guests wrote; a rule cannot
  watch another module.
- **Log lines leave the site** when you `include` them: they go by mail. They are anonymized like a
  support bundle (addresses, names, secrets replaced), and only on a site whose operator turned on
  `alerts.includeLines` in `site.json`. Include them only when your lines carry nothing a site's
  users would not want in an operator's mailbox.
- **At most 20 rules.** The file is checked at install and at every release: a rule that does not
  validate stops the install with the reason.
- **Your rules follow your instances:** they are applied when your module is installed or updated,
  and an instance you delete leaves them at once, so its silence raises nothing.
- **See them working:** `health-manager alerts --module myapp` lists what is open now and what
  fired in the last day. The foundation's own rules are worked examples: `pvehost-alerts.json`,
  `cluster-alerts.json`, `logging-alerts.json` (they also use fields only foundation modules may:
  `scope`, `expr`, `query`).

## Going deeper

The module details — every file, field and convention — are in **[README.md](README.md)**.
The contract and machinery behind it:

- [Schemas](../../foundation/schemas/README.md) — every `module.json` field, defined once.
- [Network zones](../../foundation/tappaas-cicd/manager/network-manager/ZONES.md) — where
  your module runs; a `network:proxy` dependency + `proxyPort` gives it a public
  TLS URL.
- [Backup design](../../foundation/backup/DESIGN.md) — data-bearing modules opt in with
  `backup:vm`.
- [Module Manager](../../foundation/tappaas-cicd/manager/module-manager/README.md) — the
  full verb and script reference.
- [CICD mothership design](../../foundation/tappaas-cicd/DESIGN.md) and the
  [module dependency graph](../../module-dependencies.md) — what the automation does
  with your json (optional reading).

## Ship it

A finished module is a **good platform citizen**: it updates unattended, its tests pass,
its data is backed up, it reports into health, and it carries its own `README.md` (what
it is) and `INSTALL.md` (what automation can't do for you).

Check it against the blueprint ([ADR-027](../../../docs/ADR/ADR-027%20-%20Module%20Blueprint.md))
before you contribute — the same check the release boundary runs on the official repository
every fortnight, where a missing required file stops the release:

```bash
module-manager validate --blueprint ~/TAPPaaS/src/home/myapp
```

A missing required file is an error, a missing test a warning. It never stops an install.

Then contribute it — via pull request to
[TAPPaaS](https://codeberg.org/TAPPaaS/TAPPaaS), a community repository, or keep it
private ([where modules live](../../foundation/tappaas-cicd/DESIGN-GIT.md)). Good first
step: open an issue describing the app — someone may already be packaging it. See the
[contribution guide](https://tappaas.org/community/contributing/).
