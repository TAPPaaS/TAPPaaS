# Network orchestration scripts (ADR-008)

These scripts keep the network in sync with **`zones.json`** — the single source
of truth for zones and VLAN tags — across every control point: OPNsense (L3),
Proxmox (L2 bridges/trunks), physical switches, and WiFi APs. See
[ADR-008](../../../../docs/ADR/ADR-008-switch-module-network-infrastructure.md).

They run on the **tappaas-cicd** mothership and are symlinked into `~/bin`, so
`switch-manager`, `ap-manager`, `network-manager`, `setup-switches.sh`, and
`setup-wlan-secrets.sh` are on `PATH`.

## Model: orchestrator + providers

```
zones.json ──► network-manager ──► opnsense ─ proxmox ─ switch ─ ap   (providers)
 (truth)        (orchestrator)         each: a 5-verb reconcile contract
```

Each provider keeps two files under `~/config/` (`$CONFIG_DIR`):

| File | Meaning |
|------|---------|
| `switch-configuration-actual.json`  | **reality** — what is really in the network (inventory + live/applied config). Shared by `switch-manager` (`.controllers`/`.switches`) and `ap-manager` (`.accessPoints`). |
| `switch-configuration-desired.json` | **goal** — *regenerated* from `actual` + `zones.json`; never hand-edited. |

The **5-verb contract** (run in this order):

1. `interrogate` — read reality into `actual` (controllers/auto switches via their controller; manual = the operator's registration).
2. `update-desired` — regenerate `desired` from `actual`'s topology + the active VLAN set.
3. `delta` — diff `desired` vs `actual`.
4. `apply` — push via the vendor controller, or print manual steps.
5. `confirm` — record the applied config back into `actual`.

`reconcile [--apply]` runs all five (apply only with `--apply`). On `--apply` the
`confirm` step runs automatically — for a **manual** switch it prints the VLANs to
tag *and* records the intended config into `actual` in one step (you then apply
those VLANs on the hardware). Bare `apply` does not confirm; run `confirm` after.

---

## `network-manager reconcile` — the orchestrator

Runs every provider in dependency order (opnsense → proxmox → switch → ap).

```
network-manager reconcile [--apply] [--only <plane>]
  --apply          converge (default is dry-run / report only)
  --only <plane>   opnsense | proxmox | switch | ap
```

Exit code is non-zero if any provider still reports drift. (`network-manager` is
the ADR-007 network owner/orchestrator; the OPNsense plane reconciler is
`zone-manager`. The legacy `zone-reconcile` alias still resolves.)

---

## `switch-manager` — physical switches

Three-tier inventory in `actual`: **controllers** (a management plane such as
UniFi OS that adopts switches), **switches**, and per-switch **ports**. A port
records its topology — `type` ∈ `node|switch|ap|device|uplink`, `target`,
`targetPort` — and `desired` derives the VLANs from it (node/switch/uplink/ap →
trunk carrying the full active VLAN set; `device` + `zone` → access on that VLAN).
(AP-uplink ports also carry the full active set: a UniFi controller auto-manages
AP ports as "all VLANs" and reverts any attempt to restrict them, so TAPPaaS
matches that — the AP still only broadcasts the SSIDs you configure.)

```
# Inventory (written to switch-configuration-actual.json)
switch-manager add-controller <name> --vendor <v> --ip <ip>     # uploads its switches+ports on interrogate
switch-manager add-switch <name> --vendor <v> --managed auto|manual \
        [--controller <c>] [--ip <ip>] [--model <m>] [--location <l>] [--description <d>]
switch-manager add-port <switch> <port> --type node|switch|ap|device|uplink \
        [--target <t>] [--target-port <tp>] [--mode trunk|access] \
        [--zone <z>] [--native <vlan>] [--tagged 210,220] [--description <d>]
switch-manager update-port <switch> <port> [ ...same flags... ]
switch-manager remove-controller|remove-switch|remove-port ...
switch-manager list
switch-manager list-ports [<switch>]   # one line per port: actual config + drift vs zones.json
switch-manager show <controller|switch>

# Reconcile (5-verb contract)
switch-manager interrogate | update-desired | delta | apply | confirm
switch-manager reconcile [--apply]
```

- `--managed manual` configures the switch **by hand**: TAPPaaS prints which
  VLANs to tag (via the manual controller) — even for a brand that *has* one
  (e.g. a UniFi switch you want to manage yourself). Apply them on the device,
  then run `switch-manager confirm`.
- `--managed auto` lets the vendor controller program the switch on `reconcile --apply`.
- `--ip` is optional for manual switches (only a controller's interrogate/apply needs it).
- **TAPPaaS only manages ports you've annotated** (`add-port`/`update-port` set a
  `type`) or that are auto-detected (AP uplinks). Other ports a controller reports
  are left exactly as the switch has them — TAPPaaS won't touch them.

**Example — a manual TP-Link with two node uplinks:**
```
switch-manager add-switch core --vendor tplink --managed manual
switch-manager add-port core 9  --type node --target tappaas1 --target-port eth0
switch-manager add-port core 10 --type node --target tappaas2 --target-port eth0
switch-manager reconcile --apply    # prints the VLANs to tag on ports 9 & 10 AND records them
#   ...tag those VLANs in the switch UI...
# (no separate confirm needed — reconcile --apply already recorded the intent)
```

---

## `ap-manager` — WiFi access points (SSID → VLAN)

Stores the APs under `.accessPoints` and the site-wide SSIDs under `.ssids` in the
same config files. An SSID is declared once, bridged to one zone (its VLAN, and the
zone's `SSID` names it) and broadcast by every AP unless it names some; its passphrase
lives in a separate secrets file (below).

**Auto-population:** when `switch-manager interrogate` runs against a UniFi
controller, it also enumerates the controller's **APs** — registering each into
the AP inventory (vendor/model/IP) and detecting its **wired uplink** (which
switch + port). That switch port is automatically marked `type:ap`, so it becomes
a trunk carrying the WiFi VLANs. So adopting a controller populates the AP list
and wires up the AP's switch port with no manual steps.

```
ap-manager add <name> --vendor <v> [--ip <ip>] [--model <m>] [--location <l>]
ap-manager remove <name> | list | show <name>
ap-manager ssid add <ssid> --zone <z> --security <sec> [--radius <srv>] [--captive] [--disabled] [--broadcast-on all|<ap>,…]
ap-manager ssid modify <ssid> [--zone <z>] [--security <sec>] … | remove <ssid> | list [--json]
ap-manager ssid set-passphrase <ssid> [--file <path>]      # stdin or the file, never an argument
ap-manager link <ap> --switch <switch> --port <port>      # AP uplink (VLAN cross-check)
ap-manager update-desired | interrogate | delta | apply | confirm
ap-manager reconcile [--apply]
```
`security`: `open | wpa2-personal | wpa3-personal | wpa2-enterprise | wpa3-enterprise`
(enterprise needs a RADIUS profile — currently flagged for manual setup).

---

## `proxmox-controller` — Proxmox L2 (node bridges + VM trunks)

```
proxmox-controller reconcile  [--apply]   # per-VM trunks (applied) + node bridge-vids (reported)
proxmox-controller trunks     [--apply]   # per-VM trunks= for all trunk-bearing VMs
proxmox-controller bridge-vids [--apply]  # node lan bridge-vids (apply operator-gated)
proxmox-controller show <vmname>          # resolved-vs-actual trunks for one VM
```

---

## `setup-switches.sh` — interactive switch registration (bootstrap, #351)

Run on cicd (offered at the end of `install-platform.sh`, re-runnable any time).
It first lists any already-registered switches, then walks you through registering
each switch **brand**, one at a time:

1. Pick the vendor (brands auto-discovered from switch-manager's controllers, plus **Other**). Menu
   input is validated — an invalid entry re-prompts (1..N or Ctrl-C), never exits.
2. Choose how to manage it — choices depend on the brand's controller architecture:
   - **controller** brand (UniFi): it first **detects an existing controller**
     (a registered one, or saved credentials) and offers to *use it*; otherwise
     *manual* / *use an existing controller* / *install a controller*.
   - **device** brand (MikroTik, planned): *manual* / *register each switch by IP*
   - **Other** (no controller): *manual* only
3. Register the switch(es) and their node-uplink ports (loops for several
   switches of the brand).
4. Prints a **condensed summary** (one line per switch, ports indented), then
   asks whether to register another brand.
5. When done, it **automatically runs `switch-manager reconcile --apply`** —
   applying auto switches and printing the VLANs to tag (and recording them) for
   manual ones.

```
setup-switches.sh                  # interactive
setup-switches.sh --non-interactive  # skip (CI/bootstrap default)
```
Switch-only; WiFi is handled by `setup-wlan-secrets.sh` + `ap-manager`.

---

## `setup-wlan-secrets.sh` — WiFi SSID names + passphrases

Interactive. For each active zone that declares an `SSID` in `zones.json`, it
sets the real SSID **name** (replacing the shipped `<PLACEHOLDER>`) and stores
the WPA **passphrase** (hidden, confirmed, 8–63 chars; blank = open/unchanged)
in a separate 0600 secrets file — **never** the committed config.

```
setup-wlan-secrets.sh          # set SSID names + passphrases
setup-wlan-secrets.sh --list   # show SSIDs and whether a secret is set
```
Secrets file: `~/.wlan-secrets.txt` (env `WLAN_SECRETS`), format `<ssid>=<passphrase>`.

---

## Vendor controllers

`switch-manager` and `ap-manager` drive a brand through a **controller**: an
executable answering the `switch/1` and `ap/1` verbs (`describe`,
`check-access`, `interrogate`, `apply`, `ap-interrogate`, `ap-apply`), found in
the control plane's registry (`config/control-plane.json`) by what it plugs
into. ADR-035 D4 is the contract. When no controller drives a brand, the
built-in manual controller prints the delta as copy-paste instructions.

A controller answers JSON on **stdout and nothing else**; warnings and errors go
to **stderr**, which the managers show. A device it could not read answers `{}`
with **exit 1**, so the manager leaves `actual.json` alone for it and exits
non-zero; exit 3 means "not mine" (a device-arch controller asked for a
controller's devices, an unknown vendor).

Shipped controllers:
- **`unifi-controller`** (in the Community `unifi-os` module, which installs and
  registers it) — UniFi
  OS (controller arch; module `unifi-os`). Maps ports to UniFi
  `port_overrides`, SSIDs to `wlanconf`, VLANs to VLAN-only networks. A failed
  call names its cause: no connection (host, port in `url=`, TLS), HTTP 401/403
  (the credentials — a **local** admin, no SSO/MFA), 404 (`url=` or site), 429
  (rate-limited), or a 200 whose body is not JSON. The managers give every run
  a private session directory, so all devices share one login instead of
  logging in once each — which is what triggers UniFi OS's login rate limit.
- **manual** (`tappaas-cicd/lib/controller-manual.sh`) — the fallback;
  `interrogate` returns `{}`, `apply` prints the delta.

**To add a brand:** write a `<brand>-controller` in the module that runs it
(its `controller/<brand>-controller/` directory and `<brand>-controller.json`),
plugging into `switch-manager`; installing the module registers it. A bash
controller can keep its logic as `plugin_*` functions behind
`tappaas-cicd/lib/controller-shim.sh`, as `unifi-controller` does.

---

## Credential / secret files (on cicd, mode 0600, never committed)

| File | Used by |
|------|---------|
| `~/.unifi-os-credentials.txt` | `unifi-controller` (controller login: `url`/`username`/`password`) |
| `~/.wlan-secrets.txt`         | WLAN passphrases (`<ssid>=<psk>`), written by `setup-wlan-secrets.sh` |

## Tests

Each script has an offline test (`test-<name>.sh`) — black-box against a temp
`CONFIG_DIR`, stubbed controllers/managers, and pty-driven interactive runs. Run them
all from this directory: `for t in test-*.sh; do bash "$t"; done`.
