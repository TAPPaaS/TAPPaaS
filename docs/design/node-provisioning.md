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

## 7. V-2 execution plan — hardware validation (two stages)

**Stage 1 — Intel Atom C3758 box (Intel ethernet):** validates the whole
PXE/answer/install pipeline with a NIC the PVE installer definitely drives —
isolating mechanism bugs from driver problems. Two Atom-specific notes:
(a) **UEFI vs legacy PXE** — the DHCP boot entry defaults to `ipxe.efi`
(UEFI netboot); if the board only does legacy PXE, stage `undionly.kpxe`
and pass `--bootfile undionly.kpxe`; prefer UEFI if the firmware offers it.
(b) **RAM floor ~4 GB** — the netboot initrd embeds the full PVE ISO.

**Stage 2 — Minisforum MS-S1 Max:** repeats the flow on the target hardware,
where the open question is the Realtek NIC (below). Only differences from
stage 1 are steps 1 (NIC check) and any driver workarounds.

Ordered plan (each step gates the next; stage 1 skips step 1):

1. **NIC reality check (MS-S1 Max; it can sink the plan for that box).** The
   fleet's Minisforum boxes need `setup-realtek-nic.sh` (r8127 DKMS) on the
   *installed* system — and the PVE **installer** kernel may not drive that
   NIC either. On the MS-S1 Max, check which port will carry mgmt/PXE: if it
   only has the Realtek 5GbE ports, verify the PVE 9 installer detects them
   (boot the stock ISO once, check the network step); if it also has Intel
   10GbE, prefer that port for provisioning. If the installer lacks the
   driver, PXE-provisioning this box needs a custom-initrd detour — record
   the finding and stop; the flow still works for Intel-NIC hardware.
2. **N2 media dry-run (V-4, no PXE needed):** build the preconfigured ISO on
   tappaas1 (`apt install proxmox-auto-install-assistant`, then
   `make-install-media.sh --iso proxmox-ve_9.x.iso ...`) — `validate-answer`
   passing pins the answer schema (V-2 #5) for the deployed PVE version.
   Optionally USB-install the MS-S1 from it once: that validates the whole
   answer-file mechanism independent of netboot.
3. **Assets + fetch-mode ISO (V-2 #1, #3):** on tappaas1, prepare a
   fetch-from-http ISO (`prepare-iso --fetch-from http --url
   http://<cicd-mgmt-ip>:8090/answer`), copy it to cicd, run
   `node-provisioner prepare --iso <it>` — validates the loop-mount/extract
   recipe against the real ISO layout.
4. **Registration + service:** `node-provisioner register tappaas4 --mac
   <MS-S1 mgmt MAC> --pool 'tanka1=single:<disk>'`, then `node-provisioner
   enable --ttl 7200` — verify `dhcp-manager pxe status` (rc 0), the units
   (`node-provisioner status`), and that `curl http://<cicd>:8090/boot.ipxe`
   serves the script.
5. **The boot (V-2 #2, #4, #6):** PXE-boot the MS-S1 (BIOS boot menu). Watch
   for: DHCP offer carries next-server (option-175 chainload accepted?),
   iPXE loads kernel/initrd, installer starts in auto mode, POSTs system
   info (confirm the JSON shape in `serve`'s log — V-2 #4), fetches the
   answer, installs unattended.
6. **Post-install:** confirm root ssh-key access (cicd + tappaas1 keys),
   run the join (`install.sh --join` — manual this round; N4 automates it),
   then on cicd `update-tappaas --force` → Phase 0.5 captures tappaas4 WITH
   its pools; `site-manager node list` shows it; deep suites green.
7. **Teardown of the trap:** `node-provisioner disable` (or let the TTL
   fire) — `dhcp-manager pxe status` must report disabled.

Record every deviation in this doc's V-2 list; N4 (first-boot auto-join)
is built only after 1–7 pass.

### 7.1 Stage-1 findings (Intel Atom C3758, 2026-07-06/07) — all fixed in code

Each PXE boot attempt advanced one layer deeper; every fix below is now part
of the shipped flow (fixes marked ⚠ are still transient / pending):

1. **cicd firewall**: 69/UDP + 8090/TCP had to be opened in the NixOS config
   (`tappaas-cicd.nix` `networking.firewall.*`); dnsmasq added to the closure.
2. **OPNsense dnsmasq template collapses empty fields**: `set_boot_entry`
   must pass BOTH `servername` and `address` (else the IP lands in the
   servername slot and next-server falls back to the firewall → PXE-E18).
3. **`snp.efi`, not `ipxe.efi`**: iPXE's native drivers could not drive the
   Atom's X553 NICs ("Link status: Unknown"); the firmware-SNP build works
   on any UEFI NIC that can PXE at all → now the default bootfile.
4. **iPXE self-download loop**: the base dhcp-boot entry must carry a
   negated tag (`tag:!tappaas-ipxe` from the option-175 match) so iPXE gets
   the chainload URL instead of snp.efi again. The OPNsense API REJECTS
   negated tag references ("Option [!uuid] not in list", probed on 25.7),
   so `dhcp-manager pxe enable/disable` now deploys the whole PXE trap as
   ONE owned drop-in, `/usr/local/etc/dnsmasq.conf.d/tappaas-pxe.conf`
   (the dnsmasq plugin's sanctioned `conf-dir` extension point, over ssh
   root@firewall + `configctl dnsmasq restart`). Verified to survive
   OPNsense reconfigures; legacy API-object entries are migrated away on
   the next enable/disable.
5. **Concrete asset-server IP in boot.ipxe**: `${next-server}` resolves to
   the firewall in the tagged iPXE DHCP round — the template now bakes in
   the detected cicd mgmt IP; `enable` refreshes the script.
6. **Initramfs segment alignment**: the kernel SILENTLY ignores a trailing
   concatenated cpio unless it starts 4-byte-aligned; PVE 9.2's initrd is
   ≡1 mod 4 → zero-pad before appending the ISO cpio ("no device with valid
   ISO found" otherwise).
7. **Installer DHCP window too small**: the installer environment runs
   dhclient with `timeout 10;` and fetches the answer exactly once — the
   X553 link re-train after kernel takeover (+ any switch STP hold) misses
   the window ("Network unreachable"). Fixed by shipping a patched `/init`
   in the appended cpio (overrides the initrd's copy) that seds the
   timeout to 60 s inside the installer's writable overlay before
   switch_root.
8. **Disk standard corrected (operator review)**: registrations now carry
   `--boot-disk` (default `sda`) — the installer formats ONLY that disk,
   ext4/LVM (the tappaas1 standard, stock `pve-root`); `--pool` specs are
   post-join metadata for the storage plane, never given to the installer.
   (The first cut wrongly installed ZFS onto the first declared pool.)
9. **PVE 9.2 ISO note**: the netboot pipeline itself works against the
   PVE 9.2 ISO layout (`/proxmox.iso` checked first by its init, line 288);
   TAPPaaS platform support for 9.2 is a separate matter (INSTALL.md pins
   9.1).
10. **Standard-IP reservation (operator review + static-bake subtlety)**: a fresh
   node used to come up on a random pool lease (10.0.0.100+) until the
   join re-IPs it. The answer server now pins the node's POSTed MACs to
   its standard mgmt IP (`dhcp-manager host set` → the SHIPPED tappaas1-9
   dnsmasq host entries gain a `hwaddr`, upgrading the DNS pin to a
   dhcp-host reservation — outside the dynamic pool by design). The
   installed node boots straight onto 10.0.0.1x and is reachable as
   `<name>.mgmt.internal`; `dhcp-manager host del <name>` clears the
   pinning (DNS entry kept). Note the ansible-style `dnsmasq_host` module
   silently fails to persist `hwaddr` — the raw `setHost` API is used
   instead.
11. **Root-context credentials**: sudo/TTL/service invocations of
   node-provisioner found no OPNsense credentials (`/root` lookup only)
   and silently left DHCP armed — node-provisioner now probes the
   operator's `~tappaas/.opnsense-credentials.txt` and passes it to
   dhcp-manager explicitly.

### 7.2 Round-2 e2e (`site-manager node add tappaas4 --pxe`, 2026-07-07) — PASSED

The operator front door is now `site-manager node add <name>` (design's
`--provision` renamed): **default = adopt** (probe the node's designated
mgmt IP for an existing hand-installed Proxmox, verify hostname, then join
+ capture over ssh), **`--pxe`** = bare-machine netboot install first,
**`--config-only`** = write the site.json entry only. Ask-at-boot boot
disk (register without `--boot-disk` → kernel-flag-armed console prompt in
the injected /init → `?bootdisk=` on the answer URL) validated on
hardware; WAN port + pool specs are asked interactively at join time with
the node's real NICs/disks listed (`--wan-port`/`--no-wan`/`--pool` skip
the questions). Full pass with all three interactions: console `sda`,
WAN none, pools `tanka1=single:nvme0n1 tankb1=single:nvme1n1` — node
installed, joined, pools created and captured. Findings (all fixed):

1. Function-local `from .util import detect_mgmt_ip` in enable() shadowed
   the module-level name used earlier in the SAME function (Python scoping)
   — crash on every enable.
2. Root-context ssh to the firewall needs the operator's DEDICATED
   `~tappaas/.ssh/tappaas-fw` identity (the general cicd key is NOT
   authorized on the firewall; ssh config maps it for the tappaas user).
3. The node-step completion poll read `tail -3` of the install log — the
   success marker sits above a longer epilogue, so the watcher hung
   forever; now a 50-line window, plus fail-fast polling at the INSTALL IP
   for failures before the network reshape moves the node.
4. The boot-disk console prompt was buried under late device-probe kernel
   chatter — the prompt block now settles 3s and drops the console
   loglevel first.
5. `lib/ts cluster.ts ssh()` used strict BatchMode — every query against a
   freshly (re)installed node (unknown host key) failed, which is why N1
   pool discovery reported "discovery failed" on both captures; now
   `StrictHostKeyChecking=accept-new` (changed keys still refused).
6. The serve unit's journal was empty: python block-buffers stdout on
   non-ttys and the process is SIGTERMed at disable — log functions now
   flush.

Known warts for the node-add follow-up: `foundation/install.sh` demands
`--name` even for `--join`; the installer bakes the install-time lease
into `/etc/hosts` (node add corrects it before `pvecm add`); repeatable
`--mac`/`--pool` flags are limited by site-manager's parseOpts (last one
wins; pools also accepted as trailing positionals).

## 8. Regression tests (coded, run under `TAPPAAS_TEST_DEEP=1`)

| Suite | Deep test | Guards |
|---|---|---|
| `manager/site-manager/test.sh` | live `node reconcile` preview: must run, cluster must be reachable, plan must be EMPTY | node/pool capture stays converged (N1); F12 read path works |
| `controller/opnsense-controller/test.sh` | `dhcp-manager pxe` enable→status→disable→status round-trip against the live firewall (skips if PXE already enabled; self-cleaning) | the dnsmasq dhcp_boot verbs (N3) |
| `controller/node-provisioner/test.sh` | localhost E2E: register (zztest MAC) → `serve` → POST system-info → 200 + answer.toml → second POST 404 → cleanup | the answer server, MAC matching and one-shot consume (N3) |
| (existing) module deep suites | full update cycle incl. update-tappaas Phase 0.5 | capture wired into the update path |

## 9. Open decision points

- D-1: N2 media — bake in the four operator answers vs interactive-on-media.
- D-2: N4 capture — push from the new node vs next-update-cycle pull.
- D-3: node-provisioner language: Python (matches opnsense-controller; HTTP
  answer server fits) vs bash+dnsmasq/darkhttpd glue. Proposal: Python.
- D-4: does `node add --provision` also pre-create the ZFS pool declaration
  in site.json (so N1's "empty storagePools" warning never fires for
  provisioned nodes)? Proposal: yes.
