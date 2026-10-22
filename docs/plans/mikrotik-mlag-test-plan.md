# MikroTik MLAG pair on hrossen — setup and test plan (#847)

Two CRS317-1G-16S+RM (`crs-a`, `crs-b`) become an MLAG pair. tappaas1's lan bond
moves from the UniFi switch to the pair (one leg on each), and the pair uplinks to the
UniFi switch with one aggregate across both. What it proves: `mikrotik-controller`
reads and programs RouterOS, switch-manager drives an MLAG pair, a node's `lacp`
uplink survives a switch reboot.

## Target topology

| Link | From | To | In TAPPaaS |
|---|---|---|---|
| tappaas1 leg 1 | tappaas1 `nic2` | crs-a `sfp-sfpplus1` | port type `node`, LAG `tappaas1-lan` across the pair |
| tappaas1 leg 2 | tappaas1 `nic3` | crs-b `sfp-sfpplus1` | (same LAG, same mlag-id) |
| peer link | crs-a `sfp-sfpplus15`+`16` | crs-b `sfp-sfpplus15`+`16` | bond `peer-link`, the MLAG peer port — never programmed |
| uplink 1 | crs-a `sfp-sfpplus14` | USW port 11 | type `switch`, LAG `usw-uplink` across the pair |
| uplink 2 | crs-b `sfp-sfpplus14` | USW port 12 | USW LAG `crs-uplink` on 11+12 |
| out-of-band | crs-a/crs-b `ether1` | a laptop, when needed | not on the bridge: reported disabled, never touched |

USW ports 11 and 12 are the SFP+ cages tappaas1 uses today (the CRS317 has only
SFP+). Management: `crs-a` 10.0.0.21, `crs-b` 10.0.0.22 on the bridge, untagged (the
mgmt zone, PVID 1). Agreed 2026-10-21 (operator): these ports and addresses, and the
outage of tappaas1's non-HA guests during the swap.

## Reaching the switches from the Mac

- **Phase 1 (bench): the Mac straight into `ether1`**, one switch at a time — both come
  up as 192.168.88.1 (RouterOS default configuration: every port on `bridge`, that
  address on it, no DHCP server). The Mac runs no DHCP: give its USB/Thunderbolt
  Ethernet adapter a fixed 192.168.88.10/24, no router. Log in with `ssh
  admin@192.168.88.1`, or WinBox, which also connects by MAC address and so survives
  the address moves below. The password is on the sticker (recent units) or empty.
- **Not into hrossen's trunk at first:** an unconfigured CRS bridges every port
  without VLAN filtering and answers at 192.168.88.1 on the untagged mgmt network —
  a foreign subnet on mgmt and, with two cables to anything, a loop.
- **Phase 2 onwards: through hrossen.** Once a CRS has 10.0.0.2x and an uplink, it is
  reached on mgmt like any other device: from the Mac over the admin VPN
  (`network-manager wgvpn`), or from the mothership. `ether1` stays the rescue path.

## Today — prepared (no hardware)

- [x] `mikrotik-controller` (Community `mikrotik` module), switch-manager MLAG pairs,
  lan-uplink over a pair, health `mlag-pairs` gate — offline tests green.
- [x] The MLAG peer link is never programmed, and every VLAN a managed port carries is
  tagged on it too (`fe797a3`).
- [ ] After the push: refresh hrossen, `module-manager module add mikrotik` — the
  controller is linked and registered; no switch yet, nothing changes on the site.

## Phase 1 — each CRS on the bench (operator, laptop on `ether1`)

Both units run RouterOS 7.16.2 with firmware 7.16.2 (checked 2026-10-21): MLAG is
supported, and the peers match. No upgrade here: the CRS317 has 16 MB of flash with
3.7 MB free, too little to upload a package; a later upgrade is Netinstall's.

Work in **Safe Mode** (Ctrl-X in the terminal, or WinBox's Safe Mode button): if a
step cuts the session, RouterOS undoes it. Leave Safe Mode (Ctrl-X again) at the end
to keep the changes. With `X` = 21 on crs-a, 22 on crs-b. Both peers need the same
STP priority and the heartbeat on (MikroTik's MLAG page); a 7.16→7.23 upgrade left
crs-a with `mlag-heartbeat=none`, and 0x4000/0x5000 (an earlier version of this plan)
was wrong:

```routeros
/user set admin password=<long, in your password manager>
/system identity set name=crs-a
# ether1 off the bridge, keeping the bench address on it — one line, so the
# session moves with the address:
/ip address set [find address="192.168.88.1/24"] interface=ether1; /interface bridge port remove [find interface=ether1]
# the peer link: sfp15+16 off the bridge, bonded, back on it as the MLAG peer port
/interface bridge port remove [find interface=sfp-sfpplus15]
/interface bridge port remove [find interface=sfp-sfpplus16]
/interface bonding add name=peer-link mode=802.3ad lacp-rate=1sec transmit-hash-policy=layer-2-and-3 slaves=sfp-sfpplus15,sfp-sfpplus16
/interface bridge port add bridge=bridge interface=peer-link pvid=99
/interface bridge vlan add bridge=bridge vlan-ids=200,299,310,410,420,430,510,610 tagged=peer-link
/interface bridge vlan add bridge=bridge vlan-ids=1 tagged=peer-link   # untagged mgmt crosses the pair too
/interface bridge mlag set bridge=bridge peer-port=peer-link
/interface bridge set bridge protocol-mode=rstp priority=0x4000   # the SAME on both peers (MikroTik)
/interface bridge set bridge mlag-heartbeat=5s mlag-priority=50     # 50 on crs-a (primary); crs-b: leave 128
# management on mgmt (untagged, PVID 1), the API for the mothership only
/ip address add address=10.0.0.X/24 interface=bridge
/ip route add gateway=10.0.0.1
/ip dns set servers=10.0.0.1
/user group add name=tappaas policy=read,write,api,test
/user add name=tappaas group=tappaas password=<long, in your password manager>
/ip service set api address=10.0.0.144/32
/ip service disable telnet,ftp,www,api-ssl
# last: VLAN filtering (the session is on ether1, off the bridge)
/interface bridge set bridge vlan-filtering=yes
```

VLAN 99 is the peer port's own untagged VLAN, which MLAG's ICCP uses; no zone uses
it. Check: `/interface bridge mlag print`, `/interface bridge vlan print`,
`/ip address print`. Then the second switch, then cable the peer link (both
`sfp15`, both `sfp16`) and check on both: `/interface bridge mlag monitor` →
connected; `/interface bonding monitor peer-link` → both ports active.

## Phase 1b — the controller against the real switches (nothing in service on them)

crs-a's uplink port goes in first, on an RJ45 SFP+ module: crs-a `sfp-sfpplus14` →
USW port 1 (parked today, RJ45). crs-b is reached across the peer link (VLAN 1 tagged
on it). In Phase 2 that cable moves to USW SFP+ port 11; only the USW end changes.

1. On both CRS: `/interface bridge vlan add bridge=bridge vlan-ids=1 tagged=peer-link`.
2. Cable crs-a `sfp14` (module) → USW 1.
3. USW port 1 as a switch port: `switch-manager update-port "USW Pro XG 10 PoE" 1
   --type switch --target crs-a --target-port sfp-sfpplus14`; `reconcile` (preview: only
   port 1, trunk, native mgmt) then `reconcile --apply`. The mothership reaches 10.0.0.21
   and 10.0.0.22.
4. Operator: `setup-credentials.sh crs-a --ip 10.0.0.21` and `… crs-b --ip 10.0.0.22`.
5. `mikrotik-controller check-access`, `switch-manager interrogate --no-park`,
   `list-ports crs-a|crs-b` against RouterOS; `mlag-pair set crs-a crs-b --peer-port
   peer-link`, `mlag-pair list` (connected, crs-a primary).
6. One real apply on a spare port: `add-port crs-a sfp-sfpplus5 --type device --zone srv`,
   `reconcile --apply`, check in RouterOS (PVID 200 on sfp5, VLAN 200 on `peer-link`),
   then `remove-port crs-a sfp-sfpplus5` (parks it: PVID 430), check, and the port is
   left parked as interrogate would have.

## Phase 2 — the swap (tappaas1 drained)

Downtime: guests on tappaas1 that are not HA (logging, nextcloud, coturn, jellyfin,
nomad, karakeep) lose the network for ~15–30 min, unless moved to tappaas2 first.
The HA ones (network — the firewall —, tappaas-cicd, identity, immich, vaultwarden)
move to tappaas3 with the drain; the firewall's routing blips once.

Watch first: nothing else running (`pgrep` for sweeps and other sessions' tests).

1. **Drain** tappaas1: `ha-manager crm-command node-maintenance enable tappaas1`;
   wait until `ha-manager status` shows its HA guests on tappaas3.
2. **USW side** (switch-manager, from the mothership now on tappaas3):
   `lag remove "USW Pro XG 10 PoE" tappaas1-lan --apply`, then ports 11 and 12 as
   switch ports: `update-port "USW Pro XG 10 PoE" 11 --type switch --target crs-a
   --target-port sfp-sfpplus14` (12 → crs-b), and
   `lag set "USW Pro XG 10 PoE" crs-uplink --ports 11,12` (declared, not applied).
3. **Cabling:** tappaas1 `nic2` → crs-a `sfp1`, `nic3` → crs-b `sfp1`; crs-a `sfp14`
   from USW 1 (RJ45 module) → USW 11 (SFP+), and its record moves with it. crs-b `sfp14` stays unplugged until step 6 (RSTP would block the loop,
   but one uplink keeps it simple while nothing is aggregated).
4. **Register** (operator types the passwords):
   `setup-credentials.sh crs-a --ip 10.0.0.21`, the same for crs-b;
   `switch-manager mlag-pair set crs-a crs-b --peer-port peer-link`;
   `switch-manager mlag-pair list` → both peers connected.
5. **Read only:** `switch-manager interrogate --no-park`, then `list-ports crs-a`
   and `crs-b` — compare with RouterOS (`/interface bridge port print`,
   `/interface bridge vlan print`): ether1 and the peer link read disabled, every
   other port as the switch has it.
6. **Declare and program:**
   `add-port crs-a sfp-sfpplus1 --type node --target tappaas1 --target-port nic2`,
   `add-port crs-b sfp-sfpplus1 --type node --target tappaas1 --target-port nic3`,
   `add-port crs-a sfp-sfpplus14 --type switch --target "USW Pro XG 10 PoE" --target-port 11`
   (crs-b → 12);
   `lag set crs-a tappaas1-lan --ports crs-a:sfp-sfpplus1,crs-b:sfp-sfpplus1`,
   `lag set crs-a usw-uplink --ports crs-a:sfp-sfpplus14,crs-b:sfp-sfpplus14`;
   plug crs-b `sfp14` → USW 12; `switch-manager reconcile` (the preview: VLAN entries,
   PVIDs, two bonds per CRS with one mlag-id each, the USW LAG) — read it — then
   `reconcile --apply`.
7. **Check:** `site-manager node network show tappaas1` → `lacp`, one aggregator,
   both legs up, LLDP: two chassis; `switch-manager lag list`, `mlag-pair list`;
   `health-manager validate` → lan-uplink, `mlag-pairs`, `switch-ports` clean
   (or each warning understood). Ping tappaas1 and a guest on each VLAN.
8. **Undrain:** `ha-manager crm-command node-maintenance disable tappaas1`; the HA
   guests return.

**Rollback** (if step 7 does not come good within ~20 min): cables back (tappaas1
`nic2`/`nic3` → USW 12/11), `lag set "USW Pro XG 10 PoE" tappaas1-lan --ports 11,12
--apply` after taking `crs-uplink` off 11/12, undrain. The CRS pair stays as it is.

## Results 2026-10-21

- **Phase 1/1b done.** Both CRS on RouterOS 7.23.8 (long-term) and RouterBOARD
  7.23.8. Mixed versions (7.16.2/7.20.8, then 7.23.8/7.20.8) kept MLAG's ICCP
  "connected" but passed no data across the peer link — upgrade both together. 7.23
  moved MLAG into the bridge (`mlag-peer-port`, the bridge monitor's `mlag-state`);
  the controller reads both forms. On this model `/system package update install`
  reboots and downloads during startup (16 MB flash): the switch needs a way out.
  The controller programmed, read back and parked on both (27 changes in one apply).
- **Phase 2 done, on one uplink.** tappaas1 `nic2` → crs-a `sfp1`, `nic3` → crs-b
  `sfp1`, LAG `tappaas1-lan` with mlag-id 10: one aggregator over two chassis,
  partner the pair's ID, lan-uplink "nothing to report". crs-a `sfp14` → USW 11 (DAC)
  carries everything; crs-b `sfp14` → USW 12 is cabled but off its bridge.
- **The drain overloads tappaas3.** tappaas1's HA guests may only run on tappaas1 or
  tappaas3 (node affinity): 37 GB declared on tappaas3's 30 GB beside its own unifi-os
  and PBS. The OOM killer killed the mothership's VM two minutes after it arrived (HA
  restarted it); immich was stopped for the window. A drained node with an armed
  watchdog also had to have `pve-ha-lrm` stopped before its cables moved.

## The reflection — found and fixed (2026-10-22)

Cause: crs-a ran without the MLAG heartbeat (`mlag-heartbeat=none`, left by its
7.16→7.23 upgrade; crs-b had the default 5s, and logged "MLAG: remote heartbeat
timeout"). The peers' state sync broke, so crs-b treated crs-a's legs of the MLAG
bonds as down and flooded peer-link traffic into its own. Turning the heartbeat on
(and the STP priorities alike) did not resync a running session: flapping the peer
link from crs-a did (`/interface bonding disable peer-link`, 8 s, enable — crs-b's
own legs were disabled meanwhile). Then both legs of `tappaas1-lan` and both members
of `usw-uplink` were enabled: 30/30 pings mothership → unifi-os, HTTPS 10/10,
tappaas2/3 → mothership loss-free; health lan-uplink, switch-ports, mlag-pairs PASS.
Residual: the first broadcast of a burst can still come back once (1 of 10); the
rest are suppressed. switch-manager `mlag-pair list` and health's `mlag-pairs` now
flag a peer without the heartbeat, or peers with different STP priorities.

### Earlier notes (2026-10-21)

With both legs of `tappaas1-lan` up, every broadcast tappaas1 sends to crs-a comes
back to it from crs-b (`tcpdump -Q in -i nic3`, its own source MAC): crs-b floods
peer-link traffic into its `mlag-id 10` bond, which MikroTik does only while it
believes the remote leg is down. tappaas1's bridge then relearns the sender on
`lanbond`, and replies in that window are lost (the mothership could not reach
unifi-os). Aligning `mlag-heartbeat` (none → 5s), the STP priority (0x5000 → 0x4000)
and `mlag-priority` did not stop it. Interim: crs-b `sfp1` and `sfp14` disabled —
tappaas1 on one leg, the uplink on crs-a's member. Next: each bond's MLAG state on
both peers (`/interface bonding monitor`, `/interface bridge port monitor` for the
bonds, the log of `mlag`), MikroTik's MLAG page for 7.23 specifics, and whether the
bonds made through the API differ from ones made in the console.

## Still to do

- ~~**The uplink aggregate**~~ — done 2026-10-21 (no drain: tappaas1's HA services
  `ignored` and its LRM stopped, UniFi's side first, the CRS side over tappaas1's
  legs; 25 s), live on both members since 2026-10-22. Original notes: both ends
  change on the link that carries the switches' management and tappaas1's corosync.
  In a window: tappaas1 drained, its LRM stopped, immich stopped (tappaas3's memory),
  the Mac on crs-a `ether1` as console. Then crs-b `sfp14` back on its bridge, `lag set
  crs-a usw-uplink --ports crs-a:sfp-sfpplus14,crs-b:sfp-sfpplus14`, `lag set "USW Pro XG
  10 PoE" crs-uplink --ports 11,12`, preview, apply.
- Phase 3 (failure tests) after the aggregate.

## Phase 3 — failure tests

Continuous pings from the mothership to tappaas1, to a guest on tappaas1 and to the
firewall; `corosync-cfgtool -s` and `ha-manager status` watched on tappaas2.

| Test | Expect |
|---|---|
| reboot crs-a (`/system reboot`) | tappaas1 stays up on its crs-b leg: a few lost pings at most, no fencing, corosync link stays; the uplink LAG runs on crs-b's leg |
| crs-a back | both legs active again, one aggregator (`node network show`) |
| reboot crs-b | the same, mirrored |
| pull the peer link | MLAG secondary behaviour per MikroTik (its MLAG ports go down); tappaas1 keeps the primary's leg |
| pull one USW uplink | traffic on the other; `lag list` live shows one member |

## Phase 4 — TAPPaaS features on the pair

- Park a spare port (`update-port crs-a sfp-sfpplus5 --park`), check it in RouterOS
  (PVID 430, admit only untagged), then take it back (`remove-port`, or as it was).
- `mikrotik-controller apply --switch crs-a --check` → nothing to do.
- The nightly sweep's switch read covers crs-a and crs-b; the console's site view shows
  both, the pair and the LAGs.
- A zone change that adds a VLAN (if one is due): it lands on the node ports, the
  uplinks and the peer link on both CRS.

## Teardown

The pair stays in service. Test leftovers: the parked test port back as it was, and
no `/tmp/p-*` snapshots; the credentials files stay (they are the site's).
