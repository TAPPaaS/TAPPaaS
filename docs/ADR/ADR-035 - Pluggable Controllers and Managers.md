# ADR-035 — Pluggable Controllers and Managers: Modules Bring Their Own Control Plane

| | |
|---|---|
| **Status** | **Proposed** — draft for review |
| **Version** | 0.7 |
| **Date** | 2026-10-20 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | Answers **#430** (the controller/manager pattern beyond the foundation) and the registration half of **#731**. First uses: the UniFi controller in the `unifi-os` module, then **#847** (a MikroTik controller and module). Related: #170 (LiteLLM's control plane), #761 (composite modules: `kind` decides which controller acts), #250 (who owns what when community modules hook into core ones). Builds on ADR-007f, ADR-008, ADR-027, ADR-033, ADR-034. |
| **Changelog** | v0.7 (2026-10-20) — **P3 built.** module-manager registers a module's components (`lib/control-plane-components.sh`): install Step 5c and update Step 3.4 before the module's own script, delete Step 4b after it, and a failed install rolls them back with the rest; refresh relinks them every sweep and removes links nobody registers. The registry entry records repository, `verified`, contracts and version. D7's standing finding is health-manager's `control-plane-trust` gate. D6 made precise: the instance is registered once its credentials exist (before that a registered controller could only fail every read); a controller already at its address, under any name, is kept; APs come through the same switch-manager entry (ap-manager keeps no controller list). `unifi-controller` now ships with the Community `unifi-os` module. v0.6 (2026-10-20) — **P2 built.** The managers run controllers as executables and never source them (D4: `lib/controller-lib.sh` finds them in the registry by `plugsInto`); a bash controller may keep its logic as `plugin_*` functions behind `lib/controller-shim.sh`, as `unifi-controller` does; the manual controller is built into tappaas-cicd. `unifi-controller` sits in `tappaas-cicd/controller/` until P3 moves it to `unifi-os`. The TypeScript builder is exported as the flake's `lib.tsComponent`, called by `build_and_link_ts_component` from a component's install (D2, replacing the `default.nix` sketch); the self-check accepts the store links of a registered module's components. v0.5 (2026-10-20) — **the `switch/1` contract written down** (D4): the verbs, options, output shapes and exit codes a switch controller answers, `ap/1` beside it, what `<contract>/<major>` means, and UniFi and MikroTik side by side. v0.4 (2026-10-20) — **operator's second review.** Two different modules bringing the same controller are **refused**, like managers (replaces v0.3's warning). Contributed components use the same shared libraries as the standard ones (D2). Ansible is an option, not the default; D10 sketches `mikrotik-controller` (the operator's name, over `routeros-controller`) built with it. A controller's or manager's own declarations live in `<name>.json` beside the module JSON, never in it (D11). v0.3 (2026-10-20) — **one application, several modules; one module, several copies** (operator, D3 and D5). Two different modules that run the same application and bring the same controller are a warning with an undefined result, not a refusal. Two copies of one module (instances) run install and update once each, with the same result: the controller is registered once with both instances, and removing one copy leaves it for the other. v0.2 (2026-10-20) — **after the operator's review.** Naming (D3): a controller is `<application>-controller`, named for the application it controls, not the module; a manager's name is first come, first served. Trust (D7) is a warning, not a refusal: a controller from an unverified repository may plug into a foundation manager, and the site says so. UniFi is not FLOSS and stays outside the TAPPaaS repository: its controller lives in the module that runs it, in the Community repository (O1 answered). O3 answered: module-manager builds a module's TypeScript or Python components on tappaas-cicd with tappaas-cicd's own builders and libraries (D2). O4 written out for the conversation with Erik. "Component" now means a controller or a manager, never a module. v0.1 (2026-10-20) — first draft. |

## Context

ADR-007f split the control plane into **managers** (TypeScript orchestrators for a domain, the
verbs an operator and the console use) and **controllers** (Python or bash, the code that talks to
one system, called by a manager). Every manager and controller lives in
`src/foundation/tappaas-cicd/{manager,controller}/` and is linked into `/home/tappaas/bin` by
tappaas-cicd's own install and by every sweep's prepare step.

That was right while every system TAPPaaS drove was part of the foundation. It no longer holds:

1. **Vendor code lives outside the module that owns the vendor.** The switch and AP controllers
   pick a vendor plugin by globbing one fixed directory inside the TAPPaaS checkout,
   `src/foundation/network/scripts/plugins/` (`unifi.sh`, `manual.sh`). The UniFi plugin names
   the module that runs the UniFi controller (`plugin_controller_module` → `unifi-os`), but that
   module lives in the Community repository and cannot ship, update or test its own plugin. A
   MikroTik switch (#847) would need a third plugin in the same foundation directory.
2. **A controller module registers with nothing (#731).** Installing `unifi-os` brings the UniFi
   controller up; `switch-controller` and `ap-controller` are not told. On the reference site a
   controller, two switches and four APs went unmanaged for three weeks without an error.
3. **App modules need controllers too (#430, #170).** LiteLLM's models, keys and teams live inside
   LiteLLM; declaring them needs code that reconciles them, and that code belongs with LiteLLM, not
   in tappaas-cicd.
4. **Everything is a hard-coded list.** The flake's packages, the self-check (any `~/bin` link into
   the Nix store the flake does not build fails the rebuild), the console's list of managers
   (`ui/src/manifest.ts`), the bash verbs it may run (`ui/manifest/bash-verbs.json`) and
   network-manager's planes are all written down in tappaas-cicd. A component a module brought
   would be refused, or flagged as a stale link and roll the sweep back.

The module's own lifecycle scripts — `install.sh`, `update.sh`, `test.sh`, `delete.sh` and the
other hooks module-manager calls (`pre-update.sh`, `ready.sh`, `revoke-sessions.sh`, `lockdown.sh`,
`services/<svc>/*-service.sh`) — are already a small controller for that module, found through
the module's own directory (`get_module_dir`), from any registered repository. What is missing is
the same for code that serves **other** modules or a whole domain.

## Requirements

- **R1.** A controller lives with the module it controls, in the same layout as the controllers in
  tappaas-cicd, and is installed, updated, tested and removed with that module.
- **R2.** A module can also contribute a manager.
- **R3.** Installing or updating a module links its controllers and managers into
  `/home/tappaas/bin`, next to the standard ones; deleting it removes them. Nothing is copied by
  hand and nothing is left behind.
- **R4.** A contributed controller registers with the manager that drives it — the code (*this
  manager can now use a UniFi controller*) and the instance (*the UniFi controller at this
  address manages these switches*) — without an operator step.
- **R5.** Contributed components are documented and visible like the standard ones: in `--help`,
  in the console, on tappaas.org.
- **R6.** A contributed component runs with the same power as tappaas-cicd's own (as `tappaas`, on
  the mothership): it comes only from a repository the site has declared, and the site can see
  which of them are not verified.
- **R7.** The standard managers and controllers keep working unchanged while this is introduced.

## Decision

### D1. Terms: basic and extended controllers, managers

- A module's **basic controller** is what every module has: its lifecycle scripts and hooks
  (ADR-027 D2), driven by module-manager. Nothing in this ADR changes it.
- An **extended controller** is code a module contributes that does more than run that module's
  own lifecycle: it drives a system for a manager (the UniFi controller programs switches and APs
  for the switch and AP managers), or reconciles state inside the module's application (LiteLLM's
  models and keys, #170).
- A **manager** stays what ADR-007f says: the operator's and the console's verbs for a domain,
  orchestrating controllers. A module may contribute one when its domain is new (a manager for
  something no standard manager covers).
- A **component** is a controller or a manager. A module *contributes* components; it is not one.
- **Vendor-neutral code is a manager; vendor code is a controller.** The switch and AP domains
  follow this from now on: today's `switch-controller` and `ap-controller` are the switch and AP
  *managers* (`switch-manager`, `ap-manager`; the old names stay as aliases, `ap-manager` already
  exists), and each vendor plugin becomes a controller (`unifi-controller`, `mikrotik-controller`,
  and the built-in `manual` fallback).

### D2. Where they live: in the module, in tappaas-cicd's layout

A module that contributes control-plane code has, beside its lifecycle scripts:

```
<module>/
  <module>.json            "controllers": [...], "managers": [...] (D3)
  install.sh update.sh test.sh delete.sh ...        the basic controller (ADR-027)
  controller/<name>/       an extended controller, laid out as tappaas-cicd/controller/<name>/
      README.md  DESIGN.md
      install.sh  update.sh  test.sh               build/link, self-test (offline)
      <name>                                       the entry point (bash, Python, TS, or a wrapper)
      contract.json                                what it plugs into (D4)
      default.nix                                  when it is built (Python, TS)
  manager/<name>/          a contributed manager, laid out as tappaas-cicd/manager/<name>/
```

The layout is the one tappaas-cicd's components already share (survey 2026-10-20: every
component has `install.sh`, `update.sh`, `test.sh`, `README.md`; managers add `default.nix`,
`src/`, `test/`, `DESIGN.md`).

**Building.** module-manager runs a module's component install on tappaas-cicd, so a TypeScript
or Python component is built there, with the same builders and shared libraries as the standard
ones: the TypeScript builder (`lib/nix/ts-manager.nix`) and the shared TypeScript library
(`lib/ts`, which gives every manager its `--help`/`--help --json`, logging and the CLI gate), and
Python's packaging. Today the TypeScript builder can only build inside the tappaas-cicd tree: it
finds its sources by a path relative to tappaas-cicd (`cicd = ../..`), so a component in another
repository's module cannot use it. It becomes a function of the component's own source directory,
exported by tappaas-cicd as its flake's `lib.tsComponent`, and a component's `install.sh` calls
it through the shared install library:

```bash
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. /home/tappaas/TAPPaaS/src/foundation/tappaas-cicd/lib/component-install-lib.sh
build_and_link_ts_component "${here}" foo-manager manager   # or: … foo-controller controller
```

The builder stages the component beside `lib/ts` at `<kind>/<name>`, the depth a standard
component sits at, so it is written exactly like one (its `tsconfig.json` extends
`../../lib/ts/tsconfig.base.json`, its code imports `../../../lib/ts/src/…`), and builds it with
the nixpkgs tappaas-cicd's `flake.lock` pins. The component needs no flake of its own.

A bash component needs no build.

**Shared libraries.** A contributed component uses the same shared libraries as the standard
ones, and is expected to:

- bash: `common-install-routines.sh` (logging, config reads, the module's config and zone),
  `cli-gate.sh` (one CLI spec checks every verb's flags), and the other `lib/*.sh`, which are
  already linked into `/home/tappaas/bin` on every mothership;
- TypeScript: `lib/ts` (`--help` and `--help --json` from one HelpSpec, logging, config I/O, zones,
  module discovery), through the exported builder above;
- Python: the libraries the Python controllers use, as a package the exported builder adds.

What the shared libraries offer becomes part of the platform's contract: a change that breaks a
caller is a breaking change of tappaas-cicd, released and noted as one, not an internal refactor.

The implementation language is the component's choice — bash, Python, TypeScript, or an
executable that runs an Ansible playbook (#430 asked whether Ansible comes first: this ADR does not
mandate a tool; it fixes the interface).

### D3. The module declares what it contributes, under these names

```json
"controllers": [
  { "name": "unifi-controller", "path": "controller/unifi-controller", "plugsInto": ["switch-manager", "ap-manager"] }
],
"managers": []
```

**Names.**

- A **controller** is named **`<application>-controller`**, for the application it controls, not for
  the module that runs it: `opnsense-controller`, `authentik-controller`, `unifi-controller`,
  `mikrotik-controller`. The name is the application or product as people know it — MikroTik's
  switches run RouterOS, but `mikrotik-controller` is the name. A module's name can be more general than its
  application, and one module can run several applications, each with its own controller.
- A **manager**'s name is first come, first served: the first module to register a name keeps it.
- A name already registered by another module, or by a standard component, is **refused** with the
  owner named (D5) — for a manager and for a controller alike. **Two different modules that run the
  same application** (two UniFi modules, each bringing `unifi-controller`): the second module's
  install stops at that step and rolls back, naming the module that owns the controller. To swap
  one for the other, the first is removed first.
- **Two copies of the same module** (instances, such as `unifi-os` and `unifi-os-lab`) bring the same
  controller from the same module source. That is not a clash: see D5.

The standard components follow the controller rule where they do not yet:
`identity-controller` becomes `authentik-controller`, `backup-controller` becomes
`pbs-controller` (Proxmox Backup Server), and the switch and AP code becomes managers (D1). The old
names stay as aliases for a release.

The two fields are module-level fields (`schemas/module-fields.json`, owned by no service), checked
by `module-manager validate --blueprint` (ADR-027): every declared path exists and has the layout
of D2, every `plugsInto` names a manager the site has.

### D4. A contract per manager, versioned — `switch/1`

Each manager that takes controllers publishes its **controller contract**: the verbs a controller
answers, their options, the JSON they return and their exit codes. It is written down in the
manager's `DESIGN.md` and named `<contract>/<major>`.

- **`<contract>`** names the agreement, normally after the manager's domain: `switch` is what
  `switch-manager` expects of every switch controller, `ap` what `ap-manager` expects.
- **`<major>`** is the contract's major version. It goes up only when an existing controller would
  stop working: a verb renamed or removed, an output field that changes meaning, a new required
  option. A new optional option, a new capability or a new optional output field keep it.
- A controller's `contract.json` names the contracts and versions it answers; a manager names the
  versions it drives, and **refuses a controller whose major version it does not know**, saying
  so — it never calls it and guesses. (The form follows API versioning such as Kubernetes'
  `apps/v1`; it refers to no other document.)

```json
{ "contracts": ["switch/1", "ap/1"], "vendors": ["unifi"], "arch": "controller",
  "capabilities": ["vlans", "lag", "park", "ap"], "module": "unifi-os" }
```

#### The `switch/1` contract

A controller is an executable answering these verbs. Differences between vendors are facts in
`describe`, never different verbs.

| Verb | Required | Optional | What it does, and what it returns |
|---|---|---|---|
| `describe` | — | — | The controller's facts, as in its `contract.json`, and where its credentials are. |
| `check-access` | `--ip` | `--credentials`, `--session` | Can it log in: `{ok, apiVersion, user}`. For setup and health. |
| `interrogate` | `--ip` — the controller's address for `arch: controller`, the switch's for `arch: device` | `--switch NAME`, `--credentials`, `--session` | Reads, never changes. `{switches: {<name>: {vendor, model, managementIp, firmware, ports: {<id>: {mode, nativeVlan, taggedVlans, link, disabled, lagMembers}}}}, aps: {…}}`. One verb and one shape for both architectures: a controller returns every switch and AP it has adopted, a device only itself. |
| `apply` | `--switch NAME`, `--desired FILE` | `--check`, `--credentials`, `--session`, `--timeout` | Brings the ports the desired file names to it, aggregates included, and waits until they have settled; a port the file does not name is left as it is. `{switch, changed: [{port, from, to}], unchanged, lags}`. `--check` changes nothing and returns what it would change. |
| `mlag-status` | `--switch NAME`, `--ip` | `--credentials` | With the `mlag` capability only: `{peer, state, ids}`. |

The `ap/1` contract, answered by a controller with the `ap` capability, has the same shape:
`describe`, `check-access`, `ap-interrogate` (`{aps: {<name>: {vendor, model, ssids: {<ssid>: {vlan,
enabled, security}}}}}`) and `ap-apply --ap NAME --desired FILE [--check]`, which creates and
updates SSIDs and their VLAN networks and never deletes one.

**Common to every verb.** JSON on stdout and nothing else; the reason on stderr when something fails
or is refused. Exit 0 done, 1 the device refused or could not be reached, 2 bad usage, 3 not this
controller's (a vendor or a capability it does not have). `--credentials FILE` per controller,
defaulting to the file it documents; `--session DIR`, created by the manager for one run, so a
controller logs in once per run, not per call; `--config-dir`, `--debug`, `--help` and
`--help --json`. Port ids are opaque strings (`"1"` on UniFi, `"ether1"` on MikroTik): the manager
stores and compares them and never reads meaning into them.

**What stays with the manager.** Which ports TAPPaaS manages, the desired state from `zones.json`,
parking (an `apply` with a desired file holding only that port), confirming a manual switch, the
inventory and the controller instances (D6). A controller only reads and writes devices.

**UniFi and MikroTik side by side:**

| | `unifi-controller` | `mikrotik-controller` |
|---|---|---|
| `arch` | `controller` — one UniFi OS for every switch and AP | `device` — each switch at its own address |
| `capabilities` | `vlans`, `lag`, `park`, `ap` | `vlans`, `lag`, `park`, `mlag` |
| `interrogate --ip` | the controller's address; every adopted device | the switch's address; that switch |
| Login | a session cookie, kept in `--session` | the RouterOS API's own, per call; `--session` unused |
| Credentials | `~/.unifi-os-credentials.txt` | one file per switch, `~/.mikrotik-credentials/<switch>.txt` |
| Aggregates | the lead port's override lists its members | a bonding interface on the bridge |
| `apply --check` | computes the difference itself | Ansible's check mode with `--diff` (D10) |
| Own option | — | `--bridge NAME` (default `bridge`) |

**How a manager runs a controller.** A manager never sources a controller's code: it runs the
executable, and only through `lib/controller-lib.sh` — `ctl_list <manager>` (the registry's
controllers whose `plugsInto` names it), `ctl_for_vendor <manager> <vendor>` (the one whose
`describe` names the vendor, or that answers `supports <vendor>`; else `manual`), `ctl_run <id>
<verb> …`. The manual controller is built in (`lib/controller-manual.sh`), not a registry entry.
A bash controller may keep its vendor logic as a file of `plugin_*` functions and make its entry
point `lib/controller-shim.sh --plugin <file> --contract contract.json "$@"`, which answers the
verbs from those functions; `unifi-controller` is built that way. `PLUGIN_DIR` (tests only) adds
every `*.sh` in it as such a controller.

### D5. Registration is done by module-manager, recorded in one registry

Installing or updating a module that declares controllers or managers:

1. runs the component's own `install.sh` (build when needed);
2. links its executables into `/home/tappaas/bin` — refused if the name is already taken by a
   standard component or another module, saying which (D3; no silent shadowing);
3. records it in `config/control-plane.json`: name, module, instance, path, `plugsInto`, contract,
   version, the repository it came from.

A registry entry is one component from one module source, with the list of instances of that
module that use it. That keeps several copies of one module from confusing it:

- **Install and update run per instance**, so a module installed twice runs its component's
  `install.sh` twice. Both runs build and link the same code from the same source to the same
  name, so the second changes nothing; it only adds its instance to the entry. Each instance still
  registers *itself* with its manager (D6): two controller instances, one controller.
- **Deleting an instance** removes its instance from the entry and its own registration with the
  manager. The component's links and the entry go only with the **last** instance.
- **Two copies of one module at different versions** (one updated, one not yet) build from the
  same module source in the checkout, so they share one version of the code: the newer. The entry
  records it, and the older instance's update brings it up to that code.
- The registry is written under a lock, so two installs or updates of instances at the same time
  cannot lose an entry.

Deleting a module's last instance removes its links and its entries. The managers find their controllers in the
registry, not by globbing a directory: `switch-manager` asks for the controllers that plug into
it. The built-in components are entries too (`module: tappaas-cicd`), so one list describes the
whole control plane.

What reads the registry instead of a hard-coded list:

- **refresh-control-plane** relinks registered components on every sweep's prepare step, as it
  does tappaas-cicd's own, and removes links to components no longer registered;
- the **self-check** counts registered components as implied, so a module's controller is not a
  "stale link" and does not roll the rebuild back;
- the **console** loads managers from the registry, and a contributed manager's verbs come from its
  `--help --json` like the standard ones;
- **network-manager**'s planes and the other places listed in the survey that name components.

### D6. The instance registers with its manager

Code registration (D5) says *the switch manager can use a UniFi controller*. A controller module
also has an **instance** (#731): this `unifi-os`, at this address, manages these switches and APs.
The module's install and update register it with the manager's own verb —
`switch-manager add-controller <instance> --vendor unifi --ip <ip> --managed auto`, and
`ap-manager` likewise — and its delete removes it. The address and vendor are already in the
module's config, so no fact is invented. As built for `unifi-os` (`register-controller.sh`): the
instance is registered once a local admin is in its credentials file (`setup-credentials.sh`
registers it then; before the owner setup there is nobody to log in as, and a controller that
cannot log in would fail every switch read); a controller already registered at its address,
under any name, is the instance's and kept; the APs come through that same entry, as
switch-manager's interrogate hands what a controller adopts to ap-manager, so ap-manager keeps
no controller list of its own. Delete removes it unless another instance of the module still
uses the address; adopting the physical switches and APs behind it stays
the operator's (`add-switch`, `add-port`), because which device is which is not in any config.

The routine check #731 also asks for is #860: the switches are read after every sweep, and an
unregistered controller now shows as a manager with no controller for a vendor the site declares.

### D7. Trust: a warning, not a refusal

A contributed controller or manager runs as `tappaas` on the mothership, with the SSH keys to every
node. It can only come from a repository the site has declared (`site.json` `repositories`):
module-manager installs nothing else. Within that:

- A controller from a repository that is not verified (ADR-033: unsigned, or a verification that
  failed) may still be linked and may plug into a **foundation manager** (`switch-manager`,
  `ap-manager`, `network-manager`, …). It is not refused; it is **a warning**, said at install and
  update and kept as a standing finding of `health-manager validate`, naming the controller, its
  repository and the manager it plugs into. The UniFi controller from the Community repository is
  the first such case.
- The registry records each component's repository and its verification state, so the warning and
  the console show where the code came from.
- A failed verification of a repository that was verified before is not a warning but the update
  stopping, as ADR-033 D6 already does: the site keeps the last verified code.

### D8. Documentation

A contributed component's `README.md` and `DESIGN.md` are published with its module on tappaas.org
(the docs sync, which already takes each module's README, is extended to `controller/*/README.md` and `manager/*/README.md` in module directories),
and its module's README links them. The manager's README lists the contract and the controllers
that implement it; `switch-manager list-controllers` shows the registered ones at a site.

### D9. Where a controller stops (from #430)

A controller automates what a module needs to work in TAPPaaS — keys, identity, the wiring to
other modules, the configuration that would otherwise be clicked by hand at every install. It does
not re-implement the application's UI or API, and domain configuration (LiteLLM's models and
budgets) is automated only where it is a recurring operator burden. Foundational concerns
(identity, keys, network) stay with the foundation modules that own them.

### D10. Ansible is an option, not the default — `mikrotik-controller` as the example

A controller may be written in bash, Python or TypeScript, or run Ansible playbooks behind an
executable. None is the default; the manager's contract (D4) is what every controller answers.
Ansible fits where maintained collections already do the work: MikroTik's RouterOS has
`community.routeros`, which the first new controller (#847) can build on.

`mikrotik-controller`, in the MikroTik module:

```
controller/mikrotik-controller/
  mikrotik-controller        the entry point: answers switch/1 (describe, check-access, interrogate, apply, mlag-status)
  playbooks/interrogate.yml  community.routeros.api_info: bridge ports, bridge VLANs, bonding
  playbooks/apply.yml        community.routeros.api_modify: VLAN entries, PVIDs, bonds
  default.nix                ansible (with its collections) and python3Packages.librouteros, pinned
  contract.json              { "contracts": ["switch/1"], "vendors": ["mikrotik"], "arch": "device", "capabilities": ["vlans", "lag", "park", "mlag"] }
  test.sh                    offline: playbook syntax checks and the JSON mapping over fixtures
```

- **The runtime comes with the controller.** `default.nix` brings `ansible` and `librouteros` from the
  release's nixpkgs (both present: ansible 2.21, librouteros 3.4). Nothing is installed on the
  mothership's system, and the version moves with the release like every other package.
- **The entry point is the contract.** It runs a playbook with the switch's address and credentials
  file, reads the playbook's JSON result, and prints it in the shape switch-manager expects. The
  manager never sees Ansible.
- **Interrogate and apply stay apart.** `interrogate` only reads (`api_info`). `apply` changes only
  the ports TAPPaaS has annotated, as the UniFi controller does: `api_modify` with entries for those
  ports and `handle_absent_entries: ignore`, never `remove`, so a port nobody declared is not
  touched. A preview is `apply` in Ansible's check mode with `--diff`.
- **Tests.** Offline: `ansible-playbook --syntax-check`, `ansible-lint`, and the mapping between
  RouterOS's answers and switch/1 over recorded fixtures. Live: a RouterOS CHR (MikroTik's virtual
  RouterOS image) as a VM on the test site stands in for a switch before real hardware.

### D11. A controller's or manager's own declarations live in `<name>.json`

What a controller reconciles inside its application (LiteLLM's models, teams, budgets, #170) is not
put in the module JSON: its fields are defined for every module and do not grow per application.
A controller or manager that takes declarations has its own file, named after it:

- `<module>/<name>.json` — the release's declaration, beside `<module>.json` (`litellm-controller.json`);
- `controller/<name>/schema.json` — the controller's own schema for that file, checked by
  `module-manager validate --blueprint`;
- the site's copy is deployed with the module and kept in step with the release by the same
  three-way merge as the module's config (ADR-020), so an operator's change survives an update.

How much the declaration rules — whether a change made in the application's own UI is reverted at
the next update, or the declaration is only seeded once — is for the conversation with Erik (O4).

## Use cases

1. **UniFi (the first).** UniFi is not FLOSS, so neither it nor its controller lives in the TAPPaaS
   repository. `unifi.sh` moves from `network/scripts/plugins/` into the module that runs the UniFi
   controller, `unifi-os` in the Community repository, as `controller/unifi-controller/`. Installing that module links
   `unifi-controller`, registers it with `switch-manager` and `ap-manager` (D5) and registers the
   controller instance (D6). Its delete takes all of that back.
2. **MikroTik (#847).** A new module for MikroTik switches contributes `controller/mikrotik-controller/`
   (contract `switch/1`, `arch: device`), built and tested in the module. No foundation file
   changes for it.
3. **LiteLLM (#170).** LiteLLM contributes a controller that reconciles its models and keys from
   the module's config. It plugs into module-manager's reconcile (its own module), not into another
   manager.

## Alternatives considered

- **Keep the plugins in the foundation.** Simple, but every vendor is a foundation change and the
  module that runs the vendor cannot ship or test its own driver; #731 stays a manual step.
- **A plugin directory per manager that modules copy into.** The manager stays a glob, but nothing
  records who put a file there, a delete leaves it behind, and the self-check cannot tell a
  module's file from a stray one.
- **Every controller a flake package in tappaas-cicd.** Keeps one build, but a community module
  could never contribute one.
- **Ansible as the default controller technology (#430).** An option behind the interface (D10),
  not the default: the interface, not the tool, is what managers depend on.

## Consequences

- Vendor support becomes a module: adding a switch vendor no longer touches the foundation.
- The control plane is described by one registry instead of a dozen lists; the console, the
  self-check and the sweep all read it.
- The switch and AP code changes names (`switch-manager`, `ap-manager`), with aliases for a
  release so scripts and docs keep working.
- More code runs on the mothership from outside tappaas-cicd. D7 keeps it to repositories the site
  declared and makes an unverified one visible; it does not stop it.
- The TAPPaaS repository no longer carries UniFi code. A site with UniFi switches declares the
  Community repository and sees D7's warning for `unifi-controller`.
- Renames for the controller naming rule (D3), with aliases for a release.

## Implementation plan

| Phase | What | Done when |
|---|---|---|
| P1 | The registry (`config/control-plane.json`) with the built-in components as entries; refresh, self-check and the console read it; module JSON `controllers`/`managers` fields and the blueprint check. No component moves. | The sweep, the self-check and the console work from the registry on hrossen, nothing else changed |
| P2 | The renames (D1, D3; aliases kept); the switch contract `switch/1` written down; the managers find controllers in the registry; `manual` as the built-in controller; the TypeScript builder exported for components outside tappaas-cicd (D2) | `unifi.sh` still works, now found through the registry. **Built 2026-10-20** (offline tests green; a TypeScript manager outside the tree built and ran on hrossen); live on hrossen after the push |
| P3 | UniFi: the controller moves into `unifi-os` in the Community repository; install/update/delete link and register it (D5, with D7's warning) and register the instance (D6, #731) | Installing the module on hrossen makes the switch and APs manageable with no operator step; deleting it leaves nothing. **Built 2026-10-20** (offline tests green); live on hrossen after the push |
| P4 | MikroTik (#847): module and `mikrotik-controller`, with Ansible (D10) | A MikroTik switch reconciled on a test site |
| P5 | An app controller (#170, LiteLLM), after the conversation #430 asks for | — |

## Testing

- Offline: the registry's reader and writer, name clashes refused, an unknown contract version
  refused, the blueprint check over a module with a controller.
- On hrossen: P1 without behaviour change (a sweep and the self-check green); P3 install and delete
  of the UniFi controller's module with a leftover check (links, registry entries, the instance in
  `switch-manager list`).

## Open questions

- **O1. Where `unifi-os` lives** — *answered (v0.2)*: UniFi is not FLOSS, so it stays in the
  Community repository, and its controller with it (Use case 1, D7).
- **O2. Names** — *answered (v0.2)*: D3.
- **O3. Building outside tappaas-cicd** — *answered (v0.2)*: D2.
- **O4. #430's two points, for the conversation with Erik.** #430 (Erik, 2026-08-07) proposed
  five principles. Three are in this ADR as written: controllers beyond the foundation (D1), a
  consistent verb set (a contract per manager, D4), and no re-implementing the application (D9).
  Two need agreeing:

  1. **"Ansible first: build a custom controller only when Ansible cannot do it."** This draft
     fixes the interface (D4) and leaves the implementation free, Ansible included. The case for
     Ansible first: maintained modules exist for many of the systems a controller drives
     (`community.routeros` for MikroTik, OPNsense collections, Proxmox), and a playbook is
     declarative and idempotent by design. The case against making it the default: it adds a
     runtime the mothership does not have today; every existing controller is bash, Python or
     TypeScript and would not change; a controller must still answer the manager's contract
     (JSON in, JSON out, `interrogate` and `apply` separately), which a playbook needs a wrapper
     for; and offline tests (the switch controller has 149) are harder to write against playbooks.
     *Decided (operator, v0.4):* an option, not the default (D10); MikroTik is the first controller
     to try it.
  2. **Where foundational configuration ends and domain configuration starts.** D9 says a
     controller always automates what wires a module into TAPPaaS, and automates the
     application's own configuration only where it is a recurring burden. LiteLLM shows the line:
     - *Foundational*, always automated, and already a service contract today: a consumer's
       virtual key (`litellm:models`), its sign-in, its backup, its network.
     - *Domain*: LiteLLM's models, teams, budgets and rate limits, held inside LiteLLM (#170).

     Three things to agree for the domain side:
     - **Authority:** once a controller reconciles domain state, a change made in the
       application's own UI is reverted on the next update. The choice is per item: the
       declaration wins, or the declaration is only seeded once and the UI owns it afterwards.
     - **Where the declaration lives:** *decided (operator, v0.4)*: in `<name>.json`, not the module
       JSON (D11).
     - **The test for "a recurring burden":** done at every install, or redone after every
       restore or rebuild — or a lower bar.

## Documentation impact (ADR-013)

- ADR-007f: managers and controllers may live in modules (this ADR); its component tables point to
  the registry.
- ADR-008: the vendor plugins become controllers in modules; their location note changes.
- ADR-027: the module blueprint gains `controller/<name>/` and `manager/<name>/`.
- ADR-034 D4: the console's managers come from the registry.
- tappaas-cicd's `controller/README.md` and `manager/README.md`; the switch and AP managers'
  `DESIGN.md` (the contract); `src/misc/00-Template` (an example controller).
