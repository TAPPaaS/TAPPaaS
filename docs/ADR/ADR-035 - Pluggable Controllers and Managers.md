# ADR-035 — Pluggable Controllers and Managers: Modules Bring Their Own Control Plane

| | |
|---|---|
| **Status** | **Proposed** — draft for review |
| **Version** | 0.1 |
| **Date** | 2026-10-20 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen, @ErikDaniel007 |
| **Closes / addresses** | Answers **#430** (the controller/manager pattern beyond the foundation) and the registration half of **#731**. First uses: the UniFi controller in the `unifi-os` module, then **#847** (a MikroTik controller and module). Related: #170 (LiteLLM's control plane), #761 (composite modules: `kind` decides which controller acts), #250 (who owns what when community modules hook into core ones). Builds on ADR-007f, ADR-008, ADR-027, ADR-033, ADR-034. |
| **Changelog** | v0.1 (2026-10-20) — first draft. |

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
  the mothership): it comes only from a repository the site trusts.
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
`src/`, `test/`, `DESIGN.md`). A component built with Nix brings its own `default.nix`; the shared
builders (`lib/nix/ts-manager.nix`, Python's `buildPythonPackage`) are made usable from outside
the tappaas-cicd tree.

The implementation language is the component's choice — bash, Python, TypeScript, or an
executable that runs an Ansible playbook (#430 asked whether Ansible comes first: this ADR does not
mandate a tool; it fixes the interface).

### D3. The module declares what it contributes

```json
"controllers": [
  { "name": "unifi-controller", "path": "controller/unifi-controller", "plugsInto": "switch-manager" },
  { "name": "unifi-controller", "path": "controller/unifi-controller", "plugsInto": "ap-manager" }
],
"managers": []
```

The two fields are module-level fields (`schemas/module-fields.json`, owned by no service), checked
by `module-manager validate --blueprint` (ADR-027): every declared path exists and has the layout
of D2, every `plugsInto` names a manager the site has.

### D4. A contract per manager, versioned

Each manager that takes controllers publishes its **controller contract**: the functions or verbs
a controller must answer, and their input and output — for the switch manager the ADR-008
provider verbs as the vendor plugins implement them today (`supports`, `arch`, `interrogate`,
`controller_interrogate`, `apply`, and for APs `ap_interrogate`, `ap_apply`). The contract is
written down in the manager's `DESIGN.md` and carries a version (`switch/1`). A controller's
`contract.json` names the contract and version it implements and the vendors it supports:

```json
{ "contract": "switch/1", "vendors": ["unifi"], "arch": "controller", "module": "unifi-os" }
```

A manager refuses a controller whose contract major version it does not know, and says so; it
never guesses.

### D5. Registration is done by module-manager, recorded in one registry

Installing or updating a module that declares controllers or managers:

1. runs the component's own `install.sh` (build when needed);
2. links its executables into `/home/tappaas/bin` — refused if a name is already taken by a
   standard component or another module (no silent shadowing);
3. records it in `config/control-plane.json`: name, module, instance, path, `plugsInto`, contract,
   version, the repository it came from.

Deleting the module removes its links and its entries. The managers find their controllers in the
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
module's config, so no fact is invented; adopting the physical switches and APs behind it stays
the operator's (`add-switch`, `add-port`), because which device is which is not in any config.

The routine check #731 also asks for is #860: the switches are read after every sweep, and an
unregistered controller now shows as a manager with no controller for a vendor the site declares.

### D7. Trust: contributed code runs only from a trusted repository

A contributed controller or manager runs as `tappaas` on the mothership, with the SSH keys to every
node. module-manager links it only when its repository is one the site has declared
(`site.json` `repositories`) and the repository's verification state (ADR-033) allows it:
verified, or declared unsigned by the operator (ADR-033 D9). The registry records which, and
`health-manager validate` shows a contributed component from an unsigned repository as a WARN. A
site-scoped component (one the foundation depends on) comes from an `official` source only
(ADR-007b's lint).

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

## Use cases

1. **UniFi (the first).** `unifi.sh` moves from `network/scripts/plugins/` into the module that
   runs the UniFi controller, as `controller/unifi-controller/`. Installing that module links
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
- **Ansible as the controller technology (#430).** Allowed as an implementation behind the
  interface, not required: the interface, not the tool, is what managers depend on.

## Consequences

- Vendor support becomes a module: adding a switch vendor no longer touches the foundation.
- The control plane is described by one registry instead of a dozen lists; the console, the
  self-check and the sweep all read it.
- The switch and AP code changes names (`switch-manager`, `ap-manager`), with aliases for a
  release so scripts and docs keep working.
- More code runs on the mothership from outside tappaas-cicd; D7 is what keeps that to repositories
  the site trusts.
- Where `unifi-os` lives decides where the UniFi controller lives (O1).

## Implementation plan

| Phase | What | Done when |
|---|---|---|
| P1 | The registry (`config/control-plane.json`) with the built-in components as entries; refresh, self-check and the console read it; module JSON `controllers`/`managers` fields and the blueprint check. No component moves. | The sweep, the self-check and the console work from the registry on hrossen, nothing else changed |
| P2 | `switch-manager`/`ap-manager` names (aliases kept); the switch contract `switch/1` written down; the managers find controllers in the registry; `manual` as the built-in controller | `unifi.sh` still works, now found through the registry |
| P3 | UniFi: the controller moves into its module (O1); install/update/delete link and register it (D5) and register the instance (D6, #731) | Installing the module on hrossen makes the switch and APs manageable with no operator step; deleting it leaves nothing |
| P4 | MikroTik (#847): module and controller | A MikroTik switch reconciled on a test site |
| P5 | An app controller (#170, LiteLLM), after the conversation #430 asks for | — |

## Testing

- Offline: the registry's reader and writer, name clashes refused, an unknown contract version
  refused, the blueprint check over a module with a controller.
- On hrossen: P1 without behaviour change (a sweep and the self-check green); P3 install and delete
  of the UniFi controller's module with a leftover check (links, registry entries, the instance in
  `switch-manager list`).

## Open questions

- **O1. Where `unifi-os` lives.** It is in the Community repository today, while the UniFi plugin is
  official code in the foundation. Moving the plugin into a Community module lowers its trust
  (D7); moving the module into the TAPPaaS repository makes it official. To decide before P3.
- **O2. Names.** A contributed component's name is global in `~/bin`. Required prefix (the module's
  name), or first come first served with clashes refused (D5 as written)?
- **O3. Building outside tappaas-cicd.** `ts-manager.nix` builds only inside the tappaas-cicd tree.
  Generalise it, or require a contributed manager to bring a complete `default.nix`?
- **O4. #430's points that need Erik.** Ansible first (D2 leaves it open), and the line between
  foundational and domain configuration (D9). This draft takes positions; they are for the
  conversation #430 asks for.

## Documentation impact (ADR-013)

- ADR-007f: managers and controllers may live in modules (this ADR); its component tables point to
  the registry.
- ADR-008: the vendor plugins become controllers in modules; their location note changes.
- ADR-027: the module blueprint gains `controller/<name>/` and `manager/<name>/`.
- ADR-034 D4: the console's managers come from the registry.
- tappaas-cicd's `controller/README.md` and `manager/README.md`; the switch and AP managers'
  `DESIGN.md` (the contract); `src/misc/00-Template` (an example controller).
