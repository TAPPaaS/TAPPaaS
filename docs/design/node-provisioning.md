# Node provisioning — guided bootstrap of additional TAPPaaS nodes

**Status:** PROPOSAL (2026-07-06) — addresses issue
[#404](https://github.com/TAPPaaS/TAPPaaS/issues/404) plus the node-capture
gap found on the 2-node test install (ROF/HA "semi-failure").

## 1. Problems

**P-a (hit today): a joining node is never captured in site.json.**
`foundation/install.sh` on a secondary node joins the Proxmox cluster and
stops ("run `update-tappaas --force` to fold this node into HA +
replication"). But HA/replication candidates come from
`get_all_node_hostnames` → `site.json .hardware.nodes` — and *nothing ever
adds the new node there*. The legacy path re-discovered nodes on every update
(`create-configuration.sh --update`); the site.json-native path lost that.
Result: a 2-node cluster whose site.json knows one node; HA fold and zone
distribution silently under-cover.

**P-b (#404): standing up nodes is manual and error-prone.** Today: install
Proxmox by hand from USB (answering every installer question), then curl +
run install.sh. Issue #404 asks for (1) preconfigured install media and (2) a
PXE server on tappaas-cicd so follow-on nodes boot and install hands-free.

## 2. Key enabling technology

Proxmox VE ≥ 8.2 ships **first-class automated installation**
(`proxmox-auto-install-assistant`): an `answer.toml` (keyboard/country/tz,
root password *or* SSH keys, disk selection incl. ZFS layout, network
static/DHCP) consumed three ways — embedded in a prepared ISO, on a
`proxmox-ais` partition, or **fetched over HTTP(S)**, where the installer
POSTs the machine's system info (DMI serials, MAC addresses) so the answer
server can return a *per-node* answer. Since 8.3 the answer file also carries
a **`[first-boot]` hook** (script from ISO or URL) — exactly the "how does
install.sh start automatically" mechanism #404 asks about. The test cluster
runs PVE 9.x, so all of this is available. *(Verification task V-1: confirm
the exact answer-file schema for the deployed PVE version.)*

## 3. Design — four phases, each independently shippable

### Phase N1 — node capture (small; fixes P-a now) — IMPLEMENTED 2026-07-06

Not a bolt-on verb: `site-manager reconcile` was ALWAYS documented as
converging "site.json / nodes / repositories" but only implemented the
repository slice (operator observation). N1 completes the engine:

- `computePlan` gains the **node slice**: live cluster membership (read via
  the F12-blessed `lib/ts/cluster.ts` path — `pvesh get /cluster/resources
  --type node` through the first reachable known node) diffed against
  `site.json .hardware.nodes`. Missing → `register-node` action (appends with
  `storagePools: []` + a declare-pools reminder); departed → warning only,
  never auto-removed; unreachable cluster → warning, no actions.
- Scoped subverbs mirror each other: **`node reconcile [--apply]`** is the
  node slice exactly as `repository reconcile` is the repo slice; the full
  `reconcile` runs both (+ `--deep` cascade).
- **`update-tappaas` runs `site-manager node reconcile --apply` as Phase 0.5**
  (before the foundation loop, non-fatal) — capture is automatic on every
  update cycle; the `install.sh` secondary-node epilogue points at it.

**Pools discovery added (operator feedback, same day):** registration alone
left `storagePools: []` — the reconcile now also runs create-site.sh's pool
discovery (`zpool list` on the node, `tank*` filter, via `lib/ts
cluster.ts queryNodeTankPools`): new nodes register WITH their pools; a
known node with an EMPTY declared list gets an `update-node-pools` fill
action; a non-empty declared list is never auto-changed (mismatch = warning
— operator-authored subsets are legitimate).

**Live-verified 2026-07-06 on the operator's 2-node cluster:** `node
reconcile` discovered + registered `tappaas3`, and the follow-up pass filled
its pools `[tanka1, tankc1]` — site.json now carries the complete inventory
with zero hand-editing; unit suite 23/0.

### Phase N2 — preconfigured FIRST-node media (#404 item 1) — IMPLEMENTED 2026-07-06

`src/foundation/cluster/make-install-media.sh`: prompts for (or takes as
flags) exactly the #404 four — email, locale (country/keyboard/timezone),
root password, boot disk — plus FQDN, and bakes them into an answer file
(D-1 resolved: **bake-in**, so the target install is fully unattended);
network from DHCP; ext4 (default) or zfs single-disk. The assistant's
`validate-answer` runs before `prepare-iso`, so PVE answer-schema drift
fails at BUILD time. Runs anywhere `proxmox-auto-install-assistant` is
installed (any existing PVE node: `apt install
proxmox-auto-install-assistant`). Output is USB-writable; the media embeds
the root password — treat it as a credential. *(V-4: build + install once on
scratch hardware to pin the exact schema for the deployed PVE version.)*

### Phase N3 — PXE provisioning service for follow-on nodes (#404 item 2) — IMPLEMENTED-PENDING-HARDWARE-VALIDATION 2026-07-06

New component **`controller/node-provisioner/`** on tappaas-cicd (a
controller: it drives real infrastructure):
- **Netboot stack**: iPXE chainload; serves the PVE installer kernel/initrd +
  ISO payload over HTTP (the repack is a known-good recipe; *V-2: validate
  against the current ISO*). Bound to the **mgmt VLAN only**, and **disabled
  by default** — `node-provisioner enable [--ttl 2h]` / `disable` (auto-off
  timer so an always-on network boot trap never lingers).
- **DHCP PXE options**: opnsense-controller gains a verb to set/clear
  `next-server`/bootfile options on the mgmt DHCP scope (OPNsense owns DHCP —
  matches #404's note). `node-provisioner enable` calls it; `disable` clears.
- **Answer server**: per-node `answer.toml` generated from site.json + the
  registration created by the NEW operator front door:

      site-manager node add --name tappaas3 --pool 'tanka1=single:nvme0n1' --provision

  registers the intent (name, pools, optionally a MAC); the answer endpoint
  matches the installer's posted system info (MAC/serial) to a registered
  pending node and returns its answer. Unknown machines get **no answer**
  (installer stops) — the allowlist is the safety interlock.

**N3 implementation (2026-07-06):**
`controller/node-provisioner/` (Python, per D-3) with verbs
`register/unregister/list/prepare/serve/enable/disable/status` (README has
the operator flow), plus `dhcp-manager pxe enable/disable/status` in
opnsense-controller (drives the OPNsense dnsmasq `dhcp_boot` API =
next-server + bootfile, with an optional dnsmasq option-175 match that
chainloads stock iPXE to `boot.ipxe`). The `site-manager node add
--provision` front door is NOT yet wired (parallel work in manager/;
`node-provisioner register` is the direct front door until then, and takes
D-4's pool declaration as `--pool 'tanka1=single:nvme0n1'`). Offline unit
tests cover registration CRUD, answer matching (MAC / single-pending /
refusal), answer.toml rendering, and one-shot consumption.

**V-2 verification TODOs (hardware gate — PXE-boot a scratch box/VM):**
1. **ISO repack recipe**: `prepare` loop-mounts the PVE ISO, extracts
   `boot/linux26` + `boot/initrd.img`, and appends the whole ISO to the
   initrd as a newc cpio (`proxmox.iso`) — validate against the current
   PVE 9.x ISO layout and early-userspace behaviour.
2. **Kernel cmdline**: `boot.ipxe` boots
   `linux26 ro ramdisk_size=16777216 rw splash=silent
   proxmox-start-auto-installer` (no `proxdebug`) — confirm args for the
   deployed installer.
3. **Answer fetch**: the answer URL is baked into the ISO
   (`proxmox-auto-install-assistant prepare-iso --fetch-from http --url
   http://<cicd>:8090/answer` — run on a PVE node before `prepare`);
   confirm auto-installer-mode.toml survives the initrd embedding and
   whether a netboot answer-url kernel param exists as an alternative.
4. **System-info payload shape**: matching reads
   `network_interfaces[].mac` + `dmi.system.serial` — confirm the exact
   POSTed JSON of the deployed installer.
5. **answer.toml schema**: kebab-case keys, `zfs.raid` values and
   `root-password` (plaintext) per the PVE ≥ 8.2 docs — run
   `proxmox-auto-install-assistant validate-answer` on a generated file.
6. **iPXE chainload conditional**: OPNsense validates the dnsmasq option
   number against its catalogue — confirm option "175" is accepted; if
   rejected, dhcp-manager degrades to plain next-server+bootfile and an
   embedded-script iPXE build is required instead.
7. **cicd closure**: dnsmasq (TFTP-only unit) and an `ipxe.efi` must be
   available on tappaas-cicd — add `pkgs.dnsmasq` (and optionally
   `pkgs.ipxe`) to the cicd NixOS config if `enable` warns.
8. **Transport**: answers are served over plain HTTP (mgmt VLAN only);
   V-3 (HTTPS + assistant `--cert-fingerprint` pinning) still open.
9. **No-pool fallback**: with no `--pool`, the answer falls back to
   `ext4` on `sda` with a TODO marker — decide whether to hard-refuse
   instead (per D-4, pools should always be declared).

### Phase N4 — hands-free join + capture (closes the loop)

The generated answer file carries:
- **root auth**: a generated random root password that is *not shown* to
  anyone (or shown once), plus the **tappaas1 + tappaas-cicd public keys**
  in the answer file's root SSH-keys field — #404's "locked down" option,
  which the existing ssh-driven tooling needs anyway;
- **`[first-boot]` hook**: fetches `install.sh` from the provisioner's HTTP
  service (same LAN-serving pattern as docs/SERVE-CODE-LOCALLY.md) and runs
  `install.sh <repo> <branch> --join --non-interactive --pool <declared>`;
  the join path already works today;
- after the join, Phase N1's reconcile captures the node on the next
  update-tappaas run (or the first-boot hook finishes with
  `ssh cicd site-manager node reconcile --apply` — *decision point D-2:
  push vs next-cycle capture*).

Operator experience end-to-end: rack the box → `site-manager node add
--name tappaasN --pool ... --provision` on cicd → `node-provisioner enable`
→ power the box on (PXE first in BIOS) → walk away. The node installs PVE,
joins the cluster, registers itself, and the next update folds HA.

## 4. Security model

- Provisioning service **off by default**, TTL-limited, mgmt-VLAN-bound.
- Answer files contain secrets (root pw hash, keys) → served only to
  MAC/serial-matched pending registrations, over HTTPS with the cicd cert
  (*V-3: check assistant's cert-fingerprint pinning option*), one-shot
  (registration consumed on successful fetch).
- Root passwords: generated, stored (0600) under cicd `/etc/secrets/nodes/`
  or not at all; day-2 access is via SSH keys only.

## 5. What this replaces / touches

- `install.sh` secondary-node path: stays (N4 drives it); its epilogue gains
  the N1 reconcile instruction until capture is automatic.
- `create-configuration.sh --update` node re-discovery (legacy): N1 is its
  site-native successor — one more step toward retiring the legacy pair
  (Phase 7 no-go list).
- No change to first-node install flow besides optional N2 media.

## 6. Suggested build order + effort

| Phase | Effort | Value | Gate |
|---|---|---|---|
| N1 node reconcile | S (one TS verb + wiring) | fixes today's P-a | 2-node test cluster: join → reconcile → HA fold green |
| N2 install media | S–M (script around the assistant) | first-node QoL | manual: install from generated ISO |
| N3 provisioner + DHCP verb | M–L (new controller + opnsense verb) | the #404 core | PXE-boot a scratch box/VM |
| N4 first-boot join | M (answer-file plumbing) | hands-free | wipe + full auto-standup of node 2 |

## 7. Open decision points

- D-1: N2 media — bake in the four operator answers vs interactive-on-media.
- D-2: N4 capture — push from the new node vs next-update-cycle pull.
- D-3: node-provisioner language: Python (matches opnsense-controller; HTTP
  answer server fits) vs bash+dnsmasq/darkhttpd glue. Proposal: Python.
- D-4: does `node add --provision` also pre-create the ZFS pool declaration
  in site.json (so N1's "empty storagePools" warning never fires for
  provisioned nodes)? Proposal: yes.
