# Zone tiers and firewall rule creation — review (#816)

**Status:** working document for G2.1, 2026-10-12, read against `main` at `9fe8c5ad`. It records how
the zone model and the rule set are built *today* and what looks wrong. The publishable design page
is written from it; each confirmed defect becomes its own issue. Severity is a first guess.

Paths below are under `src/foundation/`:
**ZM** `tappaas-cicd/controller/opnsense-controller/src/opnsense_controller/zone_manager.py` ·
**RM** `…/rules_manager.py` · **FM** `…/firewall_manager.py` · **ZA** `…/zone_access.py` ·
**NM** `tappaas-cicd/manager/network-manager/src/` · **ZJ** the `zones.json` template ·
**SCH** `schemas/zones-fields.json` · **DES** `network/DESIGN.md` · **NT** `network/test.sh` ·
**T-ZM / T-RM** the controller's `test_zone_manager.py` / `test_rules_manager.py`.

## 1. Pipeline: inputs → derivation → OPNsense

**A. Authored inputs.**
- `config/zones.json`: per zone `type`, `state`, `typeId`/`subId`, `vlantag`, one IPv4 `ip`, `bridge`, `access-to`, `pinhole-allowed-from`, `snat-allowed-from`, `tier`, `isolated`, `serves` (a string), DHCP and boot options.
- `config/environments/<env>.json` `.network.zone`.
- `config/<module>.json`: `zone0`, `ingress`/`egress`/`ports`/`aliases`, `aliasType`, top level first, then `config."network:rules"` (RM:461-491); `dependsOn`, `integratesWith`, `kind`/`address`, `config."storage:nfs".mounts`.
- `<provider>/services/<svc>/pinhole.json` (ports; `fromZones: "any"` for foundation providers only, RM:388-401).
- `network/aliases.json`, `config/shares.json`.

**B. Effective zones (network-manager).** `reconcile` (NM `main.ts`:872-904) writes `zones.effective.json`. `serves` is derived **locally**: a Client or Guest zone gets `access-to += S` (`serves.ts`:225-228), an IoT zone gets `pinhole-allowed-from += S` (:219-224). A non-string `serves` (an array) is skipped silently (:182). `all` stays literal.

**C. `all` expansion (#375).** Done on read in Python (ZA:29-54, from ZM `load_zones`, RM `load_zones`, snat_policy): `internet` + every zone not `Disabled` and not `Overlay`/`WAN` — Inactive and Manual zones included.

**D. Zone rules (zone-manager).** `update.sh` → `network-manager reconcile --only opnsense --apply` → `zone-manager --zones-file <effective> --execute`. `configure_firewall_rules` (ZM:1870-2123): delete disabled zones' rules, create/repair each enabled zone with a non-empty `access-to`, caddy-reach (ZM:2220-2340), reap stale and orphan rules (ZM:2125-2218), apply once. Owned by the description prefix `Zone <name> `.

**E. Module rules (rules-manager).** Install `add-rules` (no prune), update `reconcile` (prune), delete `remove-rules`; NFS also `reconcile`. Zones file: `zones.effective.json` **only if its mtime ≥ `zones.json`**, else the authored file, else the repo template (RM:2205-2254). `_apply` (RM:899-1004): compile, upsert aliases, reconfigure aliases, savepoint, upsert rules by description, prune, apply, drop derived NFS aliases, write the sequence map (RM:999, 2140-2179). Owned by `tappaas-module:<vm>:…`, `tappaas-svcdep:<consumer>:…`, aliases `tm_*`/`nfs_*`.

**F. Writers outside both managers** — see §3.

**G. OPNsense.** MVC filter rules via `/api/firewall/filter` (matched on `description`, FM:320-389); aliases then `alias/reconfigure`; NAT rdr-pass (`nat_manager`), outbound NAT (`snat_manager`).

**Checks, warn-only:** `network-manager validate` (`zonescheck.ts`: integrity, mgmt present, I1–I5, `serves`) — on the *authored* file unless `--effective`; `zone-manager --summary` runs `validate_pinhole_allowed_from` (ZM:519-719).

## 2. The tier model: ADR-014 against the code

Built: `tier` 0–6 (internet counts as 5, `archetypes.ts`:16), `isolated`, the archetype catalogue, Overlay/WAN exempt, invariants I1–I5 (`zonescheck.ts`:334-512). **No rule generator reads `tier`, `isolated` or `serves`** — the lattice exists only as warnings.

| # | ADR-014 says | The code does | Evidence |
|---|---|---|---|
| T1 | D5 service seed `internet, dmz` | seed `["internet"]`; I5 warns on `dmz` in a non-mgmt `access-to` (ADR-021 D3b superseded it; ADR-014's table not updated) | `archetypes.ts`:47; `zonescheck.ts`:452-467 |
| T2 | D6/I2: `all` is a destination-any pass | `all` is expanded since #375; mgmt is `Manual`, so zone-manager writes **no** mgmt zone rules — its reach is the template's "Default allow LAN (IPv6) to any". The `-> all` branch is dead | ZM:160-163, 1966-1983; `firewall-config.xml.template`:240-262 |
| T3 | Tier 0: no inbound | foundation `fromZones: "any"` pinholes (logging, #770), `tappaas-admin admin->mgmt`, satellite mgmt→pbs reach mgmt; none is in the lattice | RM:388-401, 1661-1670; `wgvpn-lib.sh`:146-157 |
| T4 | F2: exactly one I1 warning (home → env) | Guest zones also derive zone-wide `access-to += S` (tier 3 → 1); SCH `appliesTo` includes Guest, its description says "Client or IoT" | `serves.ts`:89, 225-228 |
| T5 | a pinhole is source-IP → port | manual `ingress.from: <zone>` compiles to the whole source subnet; only auto-pinholes and module peers are per VM | RM:1150-1155, 1474-1483 |
| T6 | R2: an isolated zone is reached only via `pinhole-allowed-from` | not enforced at compile: egress to an isolated zone/module/alias/internet warns or is unchecked; module-peer, `alias:`, `internet` ingress is not policy-checked; NAT has no zone gate (§4) | RM:1389-1400, 1428-1433; `nat_manager.py`:40-64 |
| T7 | "isolated" = the flag | ZM's `isolated_zones` = empty `access-to`. `iotUntrust` (`isolated: true`) gets the full internet set; `iotLocal` gets **no** rules — no anti-spoofing, no admin guard, no gateway DNS/NTP | ZM:1903-1906, 2101-2103 |
| T8 | ADR-021 D3: `<zone net> → dmzgw/32` | source hard-coded `10.0.0.0/8`; narrowed by anti-spoofing on VLANs, but on the `wireguard` group (no anti-spoofing) it covers every tunnel | ZM:816, 2280-2340 |
| T9 | `pinhole-allowed-from` lists zones | `"internet"` in dmz's list is read by nothing | RM:1389; ZM ~598 |
| T10 | `serves` single-valued (#576) | still a string; arrays silently ignored, not reported | `serves.ts`:182; `zonescheck.ts`:534 |
| T11 | I1–I4 checks | warn-only, wired to no `--strict`; I1 skips untiered/exempt zones and mgmt | `zonescheck.ts`:356-400 |

## 3. Rule catalogue

Every rule written through FM is `in`, `quick`, `log`; `ip_protocol` defaults to **inet** (FM:57-76): ZM never sets it, RM forces IPv4 (RM:1895).

**zone-manager** (`_create_or_skip_rule`, ZM:1740-1868; interface = the zone's VLAN or bridge; zone base = 30000 + (sha256(name) mod 100)·100, ZM:840-844):

| Description | Seq | Action | Source → destination | When |
|---|---|---|---|---|
| `Zone Z block spoofed source` | 970 | block any | ! zone CIDR → any | enabled, non-manual, non-empty `access-to` |
| `Zone Z block firewall webgui` / `ssh` | 980 / 981 | block TCP 8443 / 22 | zone → (self) | same |
| `Zone Z -> caddy https` / `http` | 990 / 991 | pass TCP 443 / 80 | `10.0.0.0/8` → dmzgw/32 | `access-to` has internet/all, or an Overlay with `access-to`; Manual zones included |
| `Zone Z -> gateway dns` | base+0 | pass TCP/UDP 53 | zone → own gw/32 | as 970 |
| `Zone Z -> <target>` | base+1…85 | pass any | zone → target CIDR | each non-internet target |
| `Zone Z -> gateway ntp` / `dhcp` / `icmp` | +86/+87/+88 | pass UDP 123 / UDP 67 / ICMP(v4) | zone → gw/32 | as 970 |
| `Zone Z block rfc1918-10/172/192` | +90…92 | block any | zone → RFC 1918 | `internet` in `access-to` |
| `Zone Z -> internet` | +99 | pass any | zone → any | same |
| `Zone Z -> all` | +0 | pass any | zone → any | dead (always expanded first) |

**rules-manager** (all pass, quick, inet; slot = sha256(vm) mod 100; ingress 10000 + slot·100 + i, egress 20000 + slot·100 + i, ≤ 100 each, RM:80-83, 1875-1884):
- `tappaas-module:<vm>:ingress:<peer>:<port>` → `tm_<self>`: zone peer on that zone's interface (source zone CIDR); module peer on its zone (source `tm_<peer>`); `alias:X` on **lan**; `internet` on **wan** from any (RM:1145-1182, 1807-1822).
- `tappaas-module:<vm>:egress:<peer>:<port>` on the module's zone from `tm_<self>` to zone CIDR / `tm_<peer>` / alias / **any for internet** (RM:1184-1220, 1474-1483). NFS egress the same shape to `alias:nfs_*` (RM:529-598).
- Auto-pinhole `tappaas-svcdep:<consumer>:<svc>:<provider>:<port>` in the ingress band, when the predicate passes (RM:1231-1320, 1579-1669).
- Stored description = `canonical | freetext`; OPNsense matches the **whole** string (RM:1888, FM:345).

**Outside both managers:**

| Writer | What | How |
|---|---|---|
| `network-manager/wgvpn/wgvpn-lib.sh`:131-205 | `tappaas-admin admin->mgmt` (wireguard group, 10.255.1/24 → 10.0.0/24 any), `tappaas-admin WAN :<port>` | raw REST or `opnsense-firewall`, inet, no sequence |
| `satellite/lib/provision.sh`:316-339 | `tappaas-satellite edge->caddy 80/443`, `edge->admin-wg`, `edge->home-pbs` | raw REST, inet |
| `satellite/lib/satellite-lib.sh`:436-462 | `tappaas-satellite mgmt->pbs <name>` (interface from the *authored* `.mgmt.bridge`) | raw REST, inet |
| `backup/lib/pbs-tunnel.sh`:94-135 | `buddy-<n> serve wg` (wan), `buddy-<n> pull` (mgmt) | `opnsense-firewall`, inet |
| `tappaas-cicd/scripts/setup-caddy.sh`:160-262 | `TAPPaaS: Allow HTTP/HTTPS to Caddy` (wan) | CLI, PHP `config.xml` fallback |
| `nat_manager.py` / `snat_manager.py` | rdr-pass on wan; outbound NAT | inet |
| NetBird `wt0`/OPT1 | — | **nothing in the repo creates them** (#385, #222) |

**Evaluation order on one interface** (first match wins): OPNsense system rules (unverified) → 970 anti-spoofing → 980/981 admin guard → 990/991 caddy-reach → 10000–19999 module ingress and auto-pinholes → 20000–29999 module egress → 30000+ zone band (gateway, `access-to`, NTP/DHCP/ICMP, RFC 1918 block, internet) → unsequenced bash and legacy GUI rules (position unverified) → default deny. DES:232-241 documents bands 2, 6 and 7, which nothing emits.

Shadowing: only the band-1 blocks sit ahead of module passes (anti-spoofing; the admin guard, intended). Band 3/4 passes are not shadowed by the RFC 1918 block — they **override** it (§4, D3).

## 4. Suspected defects

| # | Defect | Sev. | Evidence | Test |
|---|---|---|---|---|
| D1 | ✅ **Fixed on `g2.1-firewall` (`dcd6e652`), live-tested on hrossen 2026-10-12.** **Orphan reaper misses anti-spoofing and admin-guard rules.** `ZONE_RULE_RE` predates #159/#384, so `Zone <old> block spoofed source` / `block firewall ssh/webgui` survive a zone rename or delete. On a reassigned optN (#641) a stale `block from ! <old subnet>` blocks **all** traffic on the new interface | High | ZM:324, 2193-2218 | T-ZM:952-1015 covers `->`/rfc1918 only |
| D2 | ✅ **Fixed on `g2.1-firewall` (`6432dabe`), live-tested on hrossen 2026-10-12; the live rule set showed no drift.** **Drift check ignores protocol, `ip_protocol`, enabled, log, direction**; `FirewallRuleInfo` has no `ip_protocol`. A default change to inet46 would not re-cut existing rules; a rule disabled in the GUI stays disabled | Med (blocks #815) | ZM:1789-1798; FM:85-122, 226-265 | none |
| D3 | Egress `to: internet` compiles to destination any in band 4, passing every RFC 1918 zone on that port ahead of the band-5 block | Med (latent; no module uses it) | RM:1476-1477 | none |
| D4 | Egress never checked against the target's `pinhole-allowed-from` or `isolated`; only a warning when not in `access-to`, nothing for module/alias peers | Med | RM:1428-1433 | none |
| D5 | Module-peer, `alias:` and `internet` ingress skip the compile-time policy check; ZM's static validator does warn for module peers — the two disagree | Med | RM:1389; ZM ~602-648 | validator only (T-ZM:245) |
| D6 | NAT port-forwards (rdr-pass) have no zone gate: any module in any zone can expose itself; dmz's `pinhole-allowed-from: ["internet"]` is decorative | Med | `nat_manager.py` | none |
| D7 | `alias:X` ingress is bound to `lan`, not floating; failed VLAN lookups fall back to lan/bridge silently (ZM fails instead) | Low/Med | RM:1811-1813, 1819-1822, 1848-1853 | none |
| D8 | ICMPv6 cannot be declared: `IPV6-ICMP` ≠ enum `IPv6-ICMP`, falls back to **TCP** silently, as does any unknown protocol | Low now (IPv6) | RM:256-264, 1887 | passthrough only |
| D9 | Changing a rule's free-text description duplicates it on install (upsert key includes it; `add-rules` does not prune) | Low | RM:1888; FM:345 | — |
| D10 | Self alias ignores a machine's `address` (always the FQDN); peers honour it — empty table for `kind: machine` (#542 class) | Low/Med | RM:1501-1505, 1786-1792 | none |
| D11 | `_alias_is_orphan` matches substrings: `tm_foo` matches `tm_foobar` | Low | RM:2034 | none |
| D12 | A second copy of the pinhole predicate in ZM resolves providers by bare name and reads top-level `ingress` only (#632 drift class) | Low/Med | ZM:574, 676; RM:1556-1565 | none |
| D13 | A stale `zones.effective.json` makes rules-manager fall back to `zones.json` and lose the `serves` edges; a `reconcile` then prunes the auto-pinholes they allowed | Med (transient) | RM:2223-2241 | none |
| D14 | The private-range block is RFC 1918 only: 100.64/10 (NetBird), 169.254/16 and the firewall's other ports are reachable from every `internet` zone | Med (live check) | ZM:752-756 | none |
| D15 | No-egress zones get no gateway DNS/NTP, no anti-spoofing, no guard | design gap | ZM:1903-1906, 2101-2103 | T-ZM:858 caddy only |
| D16 | DES claims that do not match: slot collisions "detected at compile time" (nothing does); band 1 "DHCP, NTP, ICMP" (they are band 5); band 2 deny defaults (nothing emits); `tappaas_module_<vm>` (prefix is `tm_`) | Low | DES:103, 232-244 | — |
| D17 | Dead `all` handling | Low | ZM:1046-1050, 1975-1983, 2283; RM:1653 | — |
| D18 | Gateway lookup is one API call per zone without retry (not the batched resolver) | Low | ZM:1944, 2303 vs 999-1044 | — |

**The G2.1 issues against today's code**

| Issue | Finding |
|---|---|
| #386 | **The described mechanism no longer exists:** nothing is emitted in band 2; the RFC 1918 blocks are at 30000+, after band 3. NT:1850 says an alias failure was misattributed to #386, and NT's skip classifier labels any block on the consumer VLAN as #386. Possible real cause (unverified): an empty *source* table `tm_<consumer>` — NT waits for the destination alias only (NT:1885). Re-test before closing |
| #385 / #222 | Open: netbird is Manual with empty `access-to`, so no rules and no caddy-reach; no code creates `wt0`/OPT1 rules |
| #160 | Not implemented; `verify --deep` is a stub (RM:829-830) |
| #256 | Partly done: auto-pinholes are skipped when `access-to` covers the provider zone (RM:1650-1659, #770); manual ingress/egress never are |
| FW #162 | **The code does write the map** after each apply (RM:999, 2140-2179) — the roadmap row says nothing writes it. Missing: a timestamp, `list-slots`, removal on `remove-rules`. Live check needed |
| #660 | Open: `_upsert_alias` never reads the stored type; no delete/recreate path (RM:1906-1929) |
| #683 | Open: `ports` only validates ingress, and only when non-empty; the install gate does not count `ports` |
| #576 | Single-valued; arrays silently ignored. The issue says a hand-written extra edge is removed again — by the code it should survive (render only adds, backfill drops only the literal equal to `serves`). Live check |
| #257 | Open: mDNS is per module (`network:discovery`), not in zones.json; no filter rule models 224.0.0.251 / ff02::fb |

## 5. IPv4 assumptions (input to #815)

- **Family:** FM:60 default inet (ZM inherits), RM:1895 forces IPv4; `FirewallRuleInfo` cannot read `ipprotocol` (D2); `opnsense-firewall` default inet; `nat_manager.py`:43, `snat_manager.py`:72 (`snat_cli` offers no inet46); raw REST `"ipprotocol":"inet"` in `wgvpn-lib.sh`:156,188, `satellite-lib.sh`:452, `provision.sh`:322; `setup-caddy.sh` PHP fallback.
- **Zone model:** one `ip` (SCH computes `10.typeId.subId.0/24`); `Zone.network` is `IPv4Network`, gateway and DHCP offsets build on it (ZM:180-200); PXE check `IPv4Address` (ZM:1443).
- **Rules needing a v6 counterpart:** private ranges RFC 1918 only (needs fc00::/7, fe80::/10; arguably 100.64/10); the orphan regex hard-codes `block rfc1918-`; anti-spoofing uses the v4 CIDR; gateway rules `/32` and ICMP v4 (IPv6 needs ICMPv6 for NDP/RA); `CADDY_REACH_SOURCE` 10.0.0.0/8.
- **Aliases:** the `network` alias holds the v4 subnet (RM:1757-1766); `_expected_alias_addresses` is A-only (RM:1083, 1089); ICMPv6 not declarable (D8).
- Already dual-stack: the legacy LAN rules and the WAN's `dhcp6`.

## 6. Test gaps

Not covered: reaping of anti-spoofing/guard rules (D1); drift on protocol/family/enabled; egress to internet; egress and module-peer policy at compile; NAT gating; the `alias:` interface; protocol normalisation; a machine's self alias; alias orphan matching; the sequence map; slot collisions; `aliasType` change; ZM/RM predicate parity; the stale-effective fallback; `serves` arrays.

Live, missing: a pf-order assertion (`pfctl -sr`); anti-spoofing and the admin guard (only the manual lockout check); isolated and no-egress zones; overlays (wireguard group, NetBird); anything IPv6; zone rename and orphan reaping; where unsequenced bash rules land relative to MVC and legacy rules.
