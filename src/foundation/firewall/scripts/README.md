# Network orchestration scripts (ADR-008)

These scripts keep the network in sync with **`zones.json`** — the single source
of truth for zones and VLAN tags — across every control point: OPNsense (L3),
Proxmox (L2 bridges/trunks), physical switches, and WiFi APs. See
[ADR-008](../../../../docs/ADR/ADR-008-switch-module-network-infrastructure.md).

They run on the **tappaas-cicd** mothership and are symlinked into `~/bin`, so
`switch-manager`, `ap-manager`, `zone-reconcile`, `setup-switches.sh`, and
`setup-wlan-secrets.sh` are on `PATH`.

## Model: orchestrator + providers

```
zones.json ──► zone-reconcile ──► opnsense ─ proxmox ─ switch ─ ap   (providers)
 (truth)        (orchestrator)         each: a 5-verb reconcile contract
```

Each provider keeps two files under `~/config/` (`$CONFIG_DIR`):

| File | Meaning |
|------|---------|
| `switch-configuration-actual.json`  | **reality** — what is really in the network (inventory + live/applied config). Shared by `switch-manager` (`.controllers`/`.switches`) and `ap-manager` (`.accessPoints`). |
| `switch-configuration-desired.json` | **goal** — *regenerated* from `actual` + `zones.json`; never hand-edited. |

The **5-verb contract** (run in this order):

1. `interrogate` — read reality into `actual` (controllers/auto switches via plugin; manual = the operator's registration).
2. `update-desired` — regenerate `desired` from `actual`'s topology + the active VLAN set.
3. `delta` — diff `desired` vs `actual`.
4. `apply` — push via the vendor plugin, or print manual steps.
5. `confirm` — record the applied config back into `actual`.

`reconcile [--apply]` runs all five (apply only with `--apply`). On `--apply` the
`confirm` step runs automatically — for a **manual** switch it prints the VLANs to
tag *and* records the intended config into `actual` in one step (you then apply
those VLANs on the hardware). Bare `apply` does not confirm; run `confirm` after.

---

## `zone-reconcile` — the orchestrator

Runs every provider in dependency order (opnsense → proxmox → switch → ap).

```
zone-reconcile [--apply] [--only <provider>]
  --apply            converge (default is dry-run / report only)
  --only <provider>  opnsense | proxmox | switch | ap
```

Exit code is non-zero if any provider still reports drift. (Transitional name;
becomes `zone-manager` once the OPNsense reconciler is renamed.)

---

## `switch-manager` — physical switches

Three-tier inventory in `actual`: **controllers** (a management plane such as
UniFi OS that adopts switches), **switches**, and per-switch **ports**. A port
records its topology — `type` ∈ `node|switch|ap|device|uplink`, `target`,
`targetPort` — and `desired` derives the VLANs from it (node/switch/ap/uplink →
trunk carrying the active VLAN set; `device` + `zone` → access on that VLAN).

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
switch-manager show <controller|switch>

# Reconcile (5-verb contract)
switch-manager interrogate | update-desired | delta | apply | confirm
switch-manager reconcile [--apply]
```

- `--managed manual` configures the switch **by hand**: TAPPaaS prints which
  VLANs to tag (via `plugins/manual.sh`) — even for a brand that *has* a plugin
  (e.g. a UniFi switch you want to manage yourself). Apply them on the device,
  then run `switch-manager confirm`.
- `--managed auto` lets the vendor plugin program the switch on `reconcile --apply`.
- `--ip` is optional for manual switches (only plugin interrogate/apply needs it).

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

Stores APs + SSIDs under `.accessPoints` in the same config files. SSID *names*
and VLANs come from `zones.json` (the `SSID` field per zone); the security level
is chosen per SSID here; passphrases live in a separate secrets file (below).

```
ap-manager add <name> --vendor <v> [--ip <ip>] [--model <m>] [--location <l>]
ap-manager remove <name> | list | show <name>
ap-manager ssid <ap> add <ssid> --zone <z> --security <sec> [--vlan <n>] [--radius <srv>] [--captive] [--disabled]
ap-manager ssid <ap> remove <ssid> | list
ap-manager link <ap> --switch <switch> --port <port>      # AP uplink (VLAN cross-check)
ap-manager update-desired | interrogate | delta | apply | confirm
ap-manager reconcile [--apply]
```
`security`: `open | wpa2-personal | wpa3-personal | wpa2-enterprise | wpa3-enterprise`
(enterprise needs a RADIUS profile — currently flagged for manual setup).

---

## `proxmox-manager` — Proxmox L2 (node bridges + VM trunks)

```
proxmox-manager reconcile  [--apply]   # per-VM trunks (applied) + node bridge-vids (reported)
proxmox-manager trunks     [--apply]   # per-VM trunks= for all trunk-bearing VMs
proxmox-manager bridge-vids [--apply]  # node lan bridge-vids (apply operator-gated)
proxmox-manager show <vmname>          # resolved-vs-actual trunks for one VM
```

---

## `setup-switches.sh` — interactive switch registration (bootstrap, #351)

Run on cicd (offered at the end of `install-platform.sh`, re-runnable any time).
It first lists any already-registered switches, then walks you through registering
each switch **brand**, one at a time:

1. Pick the vendor (brands auto-discovered from `plugins/`, plus **Other**). Menu
   input is validated — an invalid entry re-prompts (1..N or Ctrl-C), never exits.
2. Choose how to manage it — choices depend on the brand's plugin architecture:
   - **controller** brand (UniFi): it first **detects an existing controller**
     (a registered one, or saved credentials) and offers to *use it*; otherwise
     *manual* / *use an existing controller* / *install a controller*.
   - **device** brand (MikroTik, planned): *manual* / *register each switch by IP*
   - **Other** (no plugin): *manual* only
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

## Vendor plugins (`plugins/<vendor>.sh`)

`switch-manager`/`ap-manager` auto-discover plugins and pick the first whose
`plugin_supports <vendor>` matches; `manual.sh` is the catch-all fallback.

A plugin is sourced (not exec'd) and implements:

| Function | Purpose |
|----------|---------|
| `plugin_supports <vendor>` | rc 0 if this plugin handles the brand |
| `plugin_arch` | `controller` or `device` — drives `setup-switches.sh`'s management menu |
| `plugin_controller_module` | TAPPaaS module to install for the "install a controller" path |
| `plugin_controller_interrogate <ctrl> <ip>` | controller-arch: enumerate its switches+ports → `{switches:{...}}` |
| `plugin_interrogate <switch> <ip>` | device-arch: one switch's live ports |
| `plugin_apply <switch> <delta>` | push the desired port config (rc 1 ⇒ manual action required) |
| `plugin_ap_interrogate` / `plugin_ap_apply` | AP/SSID equivalents (used by `ap-manager`) |

Shipped plugins:
- **`unifi.sh`** — UniFi OS (controller arch; module `unifi-os`). Maps ports to
  UniFi `port_overrides`, SSIDs to `wlanconf`, VLANs to VLAN-only networks.
- **`manual.sh`** — fallback; `interrogate` returns `{}`, `apply` prints the
  delta as copy-paste instructions.

**To add a brand:** drop a `plugins/<vendor>.sh` implementing the contract; it is
wired in automatically (no changes to the managers or `setup-switches.sh`).

---

## Credential / secret files (on cicd, mode 0600, never committed)

| File | Used by |
|------|---------|
| `~/.unifi-os-credentials.txt` | `unifi.sh` (controller login: `url`/`username`/`password`) |
| `~/.wlan-secrets.txt`         | WLAN passphrases (`<ssid>=<psk>`), written by `setup-wlan-secrets.sh` |

## Tests

Each script has an offline test (`test-<name>.sh`) — black-box against a temp
`CONFIG_DIR`, stubbed plugins/managers, and pty-driven interactive runs. Run them
all from this directory: `for t in test-*.sh; do bash "$t"; done`.
