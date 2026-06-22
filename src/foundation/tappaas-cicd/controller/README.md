# controller/

This directory holds the TAPPaaS **controllers**. A controller is the lowest
layer of the TAPPaaS automation stack: it drives real infrastructure.

## What a controller is

A **controller owns runtime / device state.** It talks directly to
infrastructure — REST APIs, network devices, VMs, hypervisors — and converges
the *real* state of that infrastructure onto a *desired* state. A controller is
the only thing in TAPPaaS that touches a live device or API.

A controller deliberately does **not**:

- own configuration files (that is a *manager*'s job — managers own the
  declarative config, e.g. `zones.json`, and call controllers to apply it);
- ship a `validate.sh` (validating config files is also a manager's job);
- decide *what* the desired state should be — it is told, or it reads the
  config a manager points it at.

In short: a **manager** owns the config and the policy; it **calls a
controller** to make the world match that config. The controller is the
imperative arm — idempotent, re-runnable, and safe to call repeatedly.

```
   operator / config files
            │
        manager            owns config, validates it, decides desired state
            │  calls
        controller         talks to the live API / device, converges state
            │
   OPNsense │ Proxmox │ switch │ AP │ Authentik   (real infrastructure)
```

## The verb contract

The TAPPaaS "mothership" (the `tappaas-cicd` VM) drives every manager and
controller **generically**, through a small fixed set of verb scripts. It never
needs to know what a particular component does — only that it answers the same
verbs. Each controller component therefore exposes:

| Verb         | Meaning |
|--------------|---------|
| `install.sh` | First-time setup. Build the artifact (for compiled components) and place the CLI entry point(s) on `PATH`. Idempotent. |
| `update.sh`  | Re-run after a code change: rebuild + re-link so the new code is live. Usually delegates to `install.sh`. Idempotent. |
| `test.sh`    | Self-contained tests for this component. Exit non-zero on failure. |

Controllers do **not** ship `validate.sh` — config validation belongs to the
manager layer.

`install.sh` / `update.sh` / `test.sh` must all be **idempotent**: running them
twice in a row must be safe and must not change the result of the first run.

### How the parent dispatcher runs them

`controller/install.sh`, `controller/update.sh` and `controller/test.sh` are a
thin **two-level dispatcher**. Each one walks every immediate sub-directory of
`controller/`, **skips `TEMPLATE/`**, and runs the matching child verb script
(`<child>/install.sh`, etc.) if it exists and is executable. A failing child
does not abort the others; the worst return code is propagated, so CI can gate
on overall convergence.

```
controller/install.sh
  ├─ ap-controller/install.sh
  ├─ identity-controller/install.sh
  ├─ proxmox-controller/install.sh
  ├─ switch-controller/install.sh
  └─ (TEMPLATE/ — skipped)
```

A child that has no executable verb script is simply skipped — for example the
`opnsense-controller` Python package is built and linked centrally by the
mothership installer rather than by a local `install.sh`, so the dispatcher
passes over it.

## The controllers

| Controller | Language | Plane it controls |
|------------|----------|-------------------|
| [`opnsense-controller`](opnsense-controller/) | Python package | The OPNsense firewall: VLANs/zones, DHCP, split-horizon DNS, the Caddy reverse proxy, NAT port-forwards, firewall rules, ACME/TLS, and syslog. Exposes a family of `*-manager` CLIs. |
| [`proxmox-controller`](proxmox-controller/) | Bash | The Proxmox hypervisor L2 layer: per-VM NIC trunk lists and node `lan` bridge VLAN sets, plus VM/node migration and disk resize helpers. |
| [`switch-controller`](switch-controller/) | Bash | Physical managed switches: which VLANs are tagged on which ports, reconciled to `zones.json` via vendor plugins (or printed for manual application). |
| [`ap-controller`](ap-controller/) | Bash | Wireless access points: the mapping of WiFi SSIDs to VLANs, reconciled to `zones.json` via vendor plugins. |
| [`identity-controller`](identity-controller/) | Python package | The Authentik identity server (admin REST API): users, groups/roles and membership, proxy/OIDC applications, and the forward-auth outpost. |

Each controller directory contains a `README.md` (user-facing: what it does and
how to drive its CLI) and a `DESIGN.md` (implementation notes: language, build,
internal structure, how a manager calls it, and what is not yet implemented).

`TEMPLATE/` is the skeleton you copy to scaffold a new controller; the
dispatcher always skips it. See [`TEMPLATE/README.md`](TEMPLATE/README.md).
