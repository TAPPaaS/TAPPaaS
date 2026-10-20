# TAPPaaS Roadmap

What we are building, in the order we build it, and what each release has delivered. The open
work is at the top; the further down you read, the more of it has already shipped. The bottom of
this file is the first release.

The current plan is **security and stability**: order the backlog so that the changes that break
or migrate an existing installation land first, while there are still few installations and few
community modules depending on today's names, schemas and layouts. It is built in **waves** — make
upgrades safe (0), make the breaking changes (1), harden the network (2), stability (3), new
capabilities (4) — each made of **groups** of related issues. Two waves stand beside that order:
**live verification (5)** — tests and sign-offs on real systems, kept apart from development and
fixes — **site fabric and user experience (6)**, the switching fabric designed together with
the physical view of the UI — and **enhance the stacks (7)**: new modules and significant upgrades.

This file replaces the security & stability plan (2026-10-06) — kept, closed, as
[docs/plans/security-and-stability-plan.md](docs/plans/security-and-stability-plan.md) — which was compiled
on 2026-09-14 from the forge milestones *Release 2.0: Build out Stacks*, *Release 2.0
Documentation*, *Release 2.1: Security and stability release* and *Future Work*. The forge
milestone keeps its old name. Which version reached which channel on which day is in
[RELEASES.md](RELEASES.md); this file says what each version carried.

## How to read it

From the top:

1. **Planning items still open** — decisions, gates and ADRs the waves wait on.
2. **Future Work** — known, not yet in a wave.
3. **The waves, latest first** — Wave 4 down to Wave 0, each group with its open issues.
4. **Next release** — what the next release will deliver, kept current as work lands.
5. **The releases, newest first** — what shipped, grouped by the wave and group it came from.

Markers:

- **✅** in front of a row means done: the issue is closed on the forge, or the question in the
  row is answered. A ✅ row still in a wave is done on `main` and ships with the **next release**.
- A group heading says where its rows are: `released: 8 · done for 2.2: 1 · open: 3` — *released*
  counts every release; the release sections say which one carried what. A
  group, or a whole wave, that a release carried completely is no longer listed above the
  releases — it lives only in the section of the release that carried it.
- A row with no tick is still to do. Planning the next step is reading down a wave and stopping at
  the first unticked line.
- A group opens with **what it is for and what it still intends to do**, in at most three lines.
  How it got there — status logs, measurements, decisions on the way — is on the issues and in
  git; the full group text as it was is [ROADMAP.md at `a23ca653`](https://codeberg.org/TAPPaaS/TAPPaaS/src/commit/a23ca653d20996314f473beee1e9b07db8b3304c/ROADMAP.md).
- An issue's note is **at most two lines** (200 characters): its status, the date, the commit and the
  one fact that matters. The detail — investigation, decision, how it was proven — belongs on the
  issue. Notes were cut to this on 2026-10-06; the full text as it was is
  [ROADMAP.md at `a6f7074f`](https://codeberg.org/TAPPaaS/TAPPaaS/src/commit/a6f7074f778fb2877b1c22026301327a8ae9ff3a/ROADMAP.md) and the closed
  [plan](docs/plans/security-and-stability-plan.md).

**When a release is cut**, the release-train boundary does it — `release/roadmap-cut.py`, run just
before `main` is promoted to staging, so the new version's tag already holds its own roadmap.
Every ✅ row in a wave or in Future Work moves into a new `## Release <version>` section, under the
same wave and group heading; the group counts are updated; a group or wave with nothing left leaves
the waves, *At a glance* included; and **`## Next release` becomes the release's summary** — keep it
current as work lands, since nobody edits ROADMAP.md during a boundary. ([ADR-028](docs/ADR/ADR-028%20-%20Release%20Cadence%20and%20Patching.md) D13)

### The scores

Every issue and every group has two scores, each **L**ow, **M**edium or **H**igh. A group's **Risk
is its riskiest item**, not an average. **Wave** follows from the risk: Wave 1 holds the high-risk
changes that rename, re-schema or rebuild; the things that make them survivable go before it
(Wave 0).

**Ease** — how much work it is to build. *Low is easy, High is complicated.*

| Ease | Meaning |
|------|---------|
| L | small — up to 2 days, contained, often one file |
| M | medium — up to a week, several files, needs a test |
| H | large — multi-week, crosses managers/controllers, or open design; needs a decision first |

**Risk** — what an *existing* installation goes through when the change reaches it through
`update-tappaas`.

| Risk | Meaning |
|------|---------|
| L | none or low — docs, tests, opt-in capability, or tool/manager behaviour; deployed config and live state untouched; `git revert` is the rollback |
| M | the sweep changes live state automatically (firewall rules, DNS, VM config, restarts); reversible, but a mistake is an outage |
| H | persisted config, schema, paths or CLI names change and must be migrated on every install — or it needs a rebuild, reinstall or renumbering, or can lock the operator out |

### Test effort needed based on Risk

How deeply a change is tested before it merges to `main`, by its Risk. Each level includes everything
above it. From `main` a change follows the release train ([RELEASE-TRAIN.md](src/foundation/tappaas-cicd/RELEASE-TRAIN.md)):
cut into `staging` as the next version, `stable` (production) one boundary later. Test site:
hrossen.dk, which runs `main`; staging site: makerfloss.

| Risk | Required before merging to `main` |
|------|-----------------------------------|
| L | Fast tier + deep test of the touched module/manager on the test system, and of every consumer of a changed tool; the revert is a plain `git revert` |
| M | `network-manager reconcile` / `module-manager modify` dry-run diff reviewed (#645); applied live on the test system; one full scheduled sweep with no failure notice (#651) |
| H | Migration `--check`, then apply, against a **copy** of each site's `config/`; upgrade test on the test system from the current `stable`; restoring from `config/.migrations/backup/NNNN/` rehearsed once. A change that needs a rebuild or reinstall, or can lock the operator out, is operator-initiated only — never in the unattended sweep — with its runbook rehearsed on the test system |

Standing rules: one branch per group, merged to `main` as a whole after its gate; a change that
renames or re-schemas anything under `config/` ships with its migration and a fixture test
(ADR-025); data-safety bugs skip the queue (ADR-028 D12); `stable` never moves backwards — a bad
release is fixed forward.

## At a glance

Per group: its scores, and where its rows are. *released* = shipped in a release (the release sections say which); *done for 2.3* = done on `main`, ships at the next boundary; *open* = still to do.

| Wave | Group | Ease | Risk | released | done for 2.3 | open |
|------|-------|:-:|:-:|---:|---:|---:|
| 7 | G7.1 DevOps stack | H | M | – | 1 | 2 |
| 7 | G7.2 New and reworked app modules | H | M | – | 3 | 1 |
| 6 | G6.1 Switching fabric, WAN, ISP & site operations | H | H | – | 7 | 13 |
| 6 | G6.2 User interface & physical view | H | L | – | 1 | 4 |
| 5 | G5.1 Satellite & off-site | H | M | – | – | 7 |
| 5 | G5.2 Test coverage & conventions | H | L | – | – | 5 |
| 4 | ✅ G4.1 Alerting & cluster resilience | M | M | 7 | 4 | – |
| 4 | ✅ G4.2 Proxy & ingress | M | L | 3 | 5 | – |
| 4 | ✅ G4.3 Manager verb gaps | M | L | 9 | 9 | – |
| 4 | G4.4 Storage & physical devices | H | L | 5 | – | 1 |
| 4 | G4.5 Governance, CI & sign-offs | M | L | 5 | – | 2 |
| 3 | G3.1 cluster:vm lifecycle & capacity | L | M | 18 | 9 | 3 |
| 3 | G3.2 Identity & SSO wiring | M | L | 10 | 4 | 1 |
| 3 | G3.3 App module fixes | L | L | 10 | 5 | 7 |
| 3 | G3.4 AI stack maturity | M | M | 1 | 3 | 5 |
| 3 | G3.5 Installer UX | L | L | 1 | 1 | 2 |
| 2 | G2.1 Firewall exposure & rule order | M | H | 7 | 18 | 2 |
| 2 | G2.2 DNS resolver robustness | L | M | 4 | 3 | 1 |
| 1 | ✅ G1.2 Backup placement model + managed machines (ADR-012, ADR-026) | M | H | 27 | – | – |
| 1 | G1.6 Secrets & privileged access | H | H | 4 | – | 1 |
| 1 | G1.7 Parked for Erik discussion | – | – | – | – | 3 |

## Planning items still open

### Decisions

| # | Question | Waits on |
|---|----------|----------|
| #801 | Default update schedule: daily on every channel — on `stable`/`staging` 13 of 14 runs change nothing, but urgent fixes and OS patches arrive within a day; what to do with sites on the old weekly default | Operator (proposed 2026-10-08, from #797) |
| #294 | VMID scheme: zone-aligned ranges for new installs only, or not at all — never renumber in place | Lars and @ErikDaniel007 (Future Work) |
| #430 | Controller/manager pattern for app modules — **ADR-035 v0.6 (2026-10-20)** (pluggable controllers and managers; P1 registry and P2 renames, `switch/1` executables, exported TS builder live on hrossen); Ansible first and the foundational/domain line are its O4 | Lars and @ErikDaniel007 (G1.7) |
| #142 | AI-agent access to the mothership: SSH + sudo, or a REST API (which would need an ADR) | RFC outcome (G1.6) |
| #675 | What a managed repository may contribute to the control plane's own NixOS configuration, and what happens when that fails to build. Today a site's own host-level modules are dropped by every scheduled rebuild while the unit reports success (`tappaas-cicd.nix` has no extension point — confirmed) | An ADR first; Ease H · Risk M |
| #488 | `apply-json-merge`: should a field that `.orig` never recorded be adopted from the release, or kept? #736 made each refused value visible; the rule itself is open | Operator |
| #385 / #222 | NetBird: keep its server-side integration (zone, OPT1 and floating rules), or make it a pure client-side tool and reserve management access to the WireGuard admin VPN | Operator (considering, 2026-10-12) |

### Gates

What must be true before the named wave or group starts (entry) or reaches `stable` (exit). The
met gates are recorded in the releases that carried their waves.

| Wave · group | Still open |
|--------------|------------|
| 1 · G1.6 | #142 RFC outcome; a *Secrets management* ADR only once #58 comes back from Future Work |
| 2 | Entry: ADR-014 amended for the `all` sentinel (#375, built), `serves` as an array (#576), anti-spoofing always on (#159, built) and mDNS in zones.json (#257); ADR-021 amended for DNSSEC with split horizon (#263); `site.json` `ipv6` (#149) — the IPv6 stance is its own ADR (#26). Exit: a lockout check on each site — mgmt and the admin VPN reach 8443 and 22, other zones do not; done on hrossen 2026-10-02. NetBird only if the NetBird decision keeps it server-side |
| 3 | Met 2026-10-13: ADR-019 Accepted (v1.0), verified by `cluster/test.sh --deep` — live migrate to the HANode and back. Open from it: HA's automatic failback to a node with an older CPU (#827) |
| 4 | ADR-023 Accepted and built (#642, #643, #656; done 2026-10-15); ADR-015 Draft → Accepted (#486); ADR-011 Proposed → Accepted (#143 built); ADR-010 P7 sign-off (#406); ADR-008 amended (#236); ADR-019 amended for the bonded lan uplink (#40) and the migrate verb (#429); ADR-007e amended for logging v2 (#165), or a new ADR if Zabbix is chosen; ADR-029 Proposed → Accepted (#772); #154 closed or kept; #430 decided before #170 |

### ADRs still to write

| ADR | Covers | Gates |
|-----|--------|-------|
| Controller pattern for app modules | #430 → ADR-035 (Proposed v0.6; P1–P2 live on hrossen 2026-10-20; P3 next): controllers and managers live in modules, registered by module-manager; then #731 (P3), #847 (P4), #170 (P5) | G1.7, then G6.1 |
| Composite modules | #761: `cluster`, `kubernetes`, and modules that only provide artefacts (`templates`) — a `kind` for them; with @ErikDaniel007 | G3.1 |
| Control-plane extension | #675 | — |
| Secrets management | #58 (in Future Work since 2026-10-02): one secrets-access helper every module uses instead of reading `/etc/secrets`, OpenBao behind it later | G1.6, when #58 returns |
| VMID convention | #294 — only if it is adopted | Future Work |
| Legal/processor | #359 | Wave 4 |
| IPv6 | #26 — [ADR-030](docs/ADR/ADR-030%20-%20IPv6.md) **Accepted v1.0 2026-10-13**: built and on `main`; inbound verified from a phone over IPv6 via the public AAAA. Remaining outside it: public DNS that follows a dynamic WAN (#383) | #26 closable |
| Service exposure | #845 — [ADR-032](docs/ADR/ADR-032%20-%20Service%20Exposure.md) **Accepted v1.0, built** (2026-10-17): the gate authenticates machine callers (service accounts, client-credentials JWT); a module without `network:proxy` is unpublished by design, in the DMZ when it runs third-party code without user data (ADR-021 R1 amended); Jellyfin published without the gate for friends and family, hardened. all phases built (P0–P4); rate limiting is #851 | #845 closed |

### Housekeeping

- **Merge pairs** the issues themselves say belong together: #385 + #222,
  #160 + #256, #642 + #643, #119 / #120 / #121.
- **Close or park:** #154 → *Parking lot* (#223 parked 2026-10-13) (#284 went to Future Work 2026-10-06). The forge's *Release 2.0: Build out Stacks* milestone still has 4 open issues —
  move them per this plan and close it.
- **Parked, half of #656:** a proxy access list kept current from a provider's published feed (an
  Azure service tag, say) is a subsystem, not a field — an outbound fetch on a schedule, a trust
  decision about a third party deciding who reaches a site, and a defined behaviour when the feed
  is unreachable or changes shape. It needs its own decision in ADR-023. The static CIDR half is in
  G4.2.

---

## Future Work — not yet in a wave

Known work that no wave holds yet. A ✅ row is done and ships with the next release. (Small
items that belong to a group — FW #40, #83, #157, #158, #162 — are rows in that group.)

| # | Issue | Note |
|---|-------|------|
| ✅ #26 | IPv6, opt-in per site after install | **Built 2026-10-12/13 (ADR-030, on `main`), live on hrossen:** `site.json` `ipv6` + `network.wan.ipv6`; each zone with an `ipv6Subnet` gets its `/64` (migration 0016); dnsmasq `ra-names` gives every VM an AAAA; dual-stack rules (#815); AAAA for published names and IPv6 in Caddy access lists; services listen on IPv6 and trust Caddy's IPv6 address; switch-off withdraws the route first; operator page `IPV6.md`. **Left:** inbound — public AAAA and a Caddy IPv6 pass on the WAN (with #383); IPv6 anti-spoofing; a static WAN proven live (hrossen when Netnørden switches); `network.wan.ipv4` applied; an automated IPv6 deep-test tier incl. a simulated prefix change; Euro-Office and Open WebUI stay IPv4 |
| #39 | Power saving | Documentation |
| #58 | Secrets management | One secrets-access helper every module uses instead of reading `/etc/secrets`, OpenBao behind it later. Out of G1.6 since 2026-10-02 (operator) |
| #71 | TAPPaaS way to back up, export and restore user data inside a VM | Open: `backup:filesystem` does not solve it |
| #89 | Manage binaries for TAPPaaS | |
| #156 | pfSense `aliases.xml` import script | |
| #223 | OPNsense 26.1 InterfaceAssignController may break on a future upgrade | Parked 2026-10-13 (agreed 2026-05-27): works on 26.1 as deployed; revisit when an upgrade breaks it. Parking lot on the forge |
| #250 | `dependsOn` ownership for community modules | Option D, `dependsOn.sh`. Out of G1.3 since 2026-09-20 (operator) |
| #294 | Zone-aligned VMID ranges | Renumbering means backup/restore to a new VMID. **Proposal:** new scheme for new installs and variants only; never renumber in place. Out of G1.7 since 2026-10-16 (operator) |
| #464 | migrate-firewall-to-network: dry-run reports a step it cannot predict | A dry run that overstates what it will do teaches an operator to distrust dry runs. Parking lot on the forge |
| #488 | apply-json-merge pins fields the operator never changed | The general case of #736 — see *Decisions*. Parking lot on the forge |
| #678 | windows-server: time zone, keyboard and locale from the site | From G1.4: its own time-zone vocabulary and a Windows test |
| #757 | `debianhost` over PXE (ADR-026 D8a) | `adopt` covers every known site |
| #771 | NFS over TLS for `pvehost:nfs` | ADR-029 v0.7: OpenZFS `sharenfs` cannot carry `xprtsec` |
| #787 | logging: TLS for syslog ingest and Loki's ports | From #165 §3 (2026-10-06). Waits for a TAPPaaS CA; traffic stays inside mgmt / the site network meanwhile |
| #310 | Firewall API certificate verified, not skipped (`--no-ssl-verify`) | **Follows #787:** the same TAPPaaS CA issues the firewall a certificate for `firewall.mgmt.internal`, and the controllers verify it. Rescoped 2026-10-08 out of G2.1: blocking on a pinned self-signed certificate would stop the sweep at every rebuild or renewal for a narrow risk (a foothold on mgmt). Meanwhile a change is detected — `check-firewall-cert`, hourly, mails FirewallCertChanged (`ddf94cdb`) |
| #847 | switch-controller: MikroTik (RouterOS) support, including MLAG | From #40 (2026-10-17): a MikroTik plugin (REST API: VLAN trunks, 802.3ad bonds) and MLAG pairs, so a node's `lacp` uplink can span two switches — 20G when healthy, still connected while one switch reboots. Also `lan-uplink` falls back to manual switch steps instead of refusing. Needs MikroTik MLAG hardware for the live test. **ADR-035** (Proposed): `mikrotik-controller` (Ansible, D10) lives in its own module (P4) and answers `switch/1` |
| #849 | node network: USB NICs as bond members, and `set --wan-port` | From #40 (2026-10-17): a USB NIC as an `active-backup` lan leg (udev re-adds it after a late boot or replug, autosuspend off) for nodes without a free PCIe slot; and `--wan-port` to give the wan bridge a port again, so the firewall's WAN role can move between nodes |

---

## Wave 7 — enhance the stacks

New modules and significant upgrades of existing ones: what a site can run, beyond the foundation and its fixes.

### G7.1 DevOps stack — Ease H · Risk M · done for 2.3: 1 · open: 2

Forgejo gets its CI: a Woodpecker module wired to it (#840), whose agents can also build TAPPaaS itself (#415), and Forgejo on PostgreSQL when load asks for it (#284).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #840 | devops: a Woodpecker CI module next to Forgejo | H | L | **Closed 2026-10-19** (`fa66039e`…`56115a1e`): `src/devops/woodpecker`, server + one Docker agent in Forgejo's zone, behind the Authentik gate (group `users`, a tile) and open to the internet; Login with Forgejo through the new `forgejo:oauth` service (`forgejo:repo` and it share `service-lib.sh`); no privileged plugins, `woodpeckerAdmins`; pipeline containers reach the internet, DNS and Forgejo's address only (`woodpecker-egress`). Live on hrossen: module test 13/13, gate 5/5, `forgejo:oauth` 4/4; end to end, a push ran a pipeline that cloned through Caddy, reached the internet, was refused by Forgejo's VM, and showed success on the commit in Forgejo. KVM agents stay with #415 |
| #415 | Self-hosted KVM Woodpecker runners | H | L | |
| #284 | forgejo: SQLite → PostgreSQL | M | M | Out of G3.3 2026-10-06 (operator): SQLite stays the default until load says otherwise |

### G7.2 New and reworked app modules — Ease H · Risk M · done for 2.3: 3 · open: 1

New modules — a Markdown website (#841), N.O.M.A.D. for the home stack (#129), Karakeep for bookmarks (#842) — and a rework of LiteLLM's control plane (#170, decided with #430).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #841 | A lazysite module: a Markdown website for the site owner | M | L | **Closed 2026-10-18** (`dbfa2ad9`…`540bb81b`): `src/collaboration/lazysite`, lazysite 0.15.9 in the DMZ — nginx and a FastCGI pool (systemd socket, sandboxed, not root); manager, sign-in, WebDAV and CGI unwired, identity headers stripped. Pages from Forgejo through the new `forgejo:repo` service: repo `websites/<vmname>`, a read-only deploy key, `repoEditors`; the VM pulls every minute (Forgejo cannot reach the DMZ). Live on hrossen at lazysite.hrossen.dk: module test 19/19, commit to site in ≤ 62 s, from the internet Let's Encrypt, 308 to HTTPS, closed paths 404, the visitor's address reaches it |
| ✅ #129 | Project N.O.M.A.D. in the home stack | M | L | **Closed 2026-10-16** (`34fe2f3b`…`c41b1885`): `src/home/nomad`, inside the site only (no proxy, no identity), pinned images, secrets on the VM; installed and tested on hrossen (11/11). Kiwix has Wikipedia in Danish. **2026-10-17:** in the `dmz` zone (ADR-032 D2): it runs containers it installs itself and keeps no user data, so a compromised NOMAD reaches only the internet |
| ✅ #842 | A Karakeep module: bookmarks and read-later, AI tagging via the AI stack | M | L | **Closed 2026-10-18** (`267f85ce`…`bdfc6b23`): `src/home/karakeep`, Karakeep 0.34.0 with Chromium and Meilisearch, pinned images; Authentik sign-in only (password sign-up and sign-in refused, sign-ins only from its own address); AI tagging through LiteLLM via `integratesWith` (its key provisioned by the `litellm:models` contract). Live on hrossen at karakeep.hrossen.dk: module test 11/11, end-to-end 7/7, security from outside 11/11 and inside 8/8. VEX: esbuild's Go stdlib and npm's own packages never run; xmldom in pdf2json counted, low risk |
| #170 | LiteLLM declarative control plane | H | M | Decide with #430 (G1.7); an app controller per ADR-035 (P5) |

## Wave 6 — site fabric and user experience

The physical site and how an operator sees and runs it. Not ordered by upgrade risk like Waves 0–4:
these two groups are designed together — the fabric is what the physical view shows and changes.

### G6.1 Switching fabric, WAN, ISP & site operations — Ease H · Risk H · done for 2.3: 7 · open: 13

The links a site stands on: node uplinks (a bond under `lan`, #40), switch ports and trunks kept in line with the zones (#668, #697, #706, #731), the WAN and the ISP (public DNS that follows the WAN, #383, #830; mail when the ISP blocks port 25, #125). Switch setup needs a systematic model, at install and on day 2. Operating the site belongs here too: a service desk (#63) and a SIEM (#843, Wazuh the best candidate). Linked to G6.2: the physical view shows and later changes it.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ FW #40 | Redundant lan uplinks: a bond under the `lan` bridge | M | M | **Closed 2026-10-16** (`01730e51`): `site-manager node network show\|set\|test`, declared as the node's `uplinks` (ports by MAC). `set --apply` drains the node and re-carries `lan` under a rollback confirmed from the mothership; into `lacp` it forms the switch aggregate through `switch-controller lag` (UniFi), out of it takes it apart first. `lan-uplink` health gate (single uplink with fencing armed, legs, LACP state, slow-rate partner, same switch, drift) and the `LanLegDown` alert. Live on hrossen: tappaas2 10G + 1G active-backup, tappaas1 10G + 10G LACP — both survived pulling either cable (a flaky fibre on tappaas1 found on the way) |
| #383 | Keep wildcard public DNS current on dynamic WAN | M | L | |
| #830 | `environment-manager`: no verb creates the public DNS record | M | L | **Deferred (operator, 2026-10-15).** A name under an environment's domain gets a certificate and a route only once it resolves publicly, and nothing creates that record: an environment added after bootstrap needs the A record by hand at the DNS provider. Related to #383. Reported by @ErikDaniel007 |
| #125 | Mail relay via M365 Graph API | M | L | |
| ✅ #853 | switch-controller: unallocated ports parked in `iotLocal`; a verb to park a port; `validate` warns | M | L | **Closed 2026-10-18** (`b91a3f77`): at `interrogate` every port without a record becomes an `iotLocal` access port (a device plugged in gets an address and reaches nothing); `update-port --park` and `remove-port` park a port on the switch before the record goes; a `switch-ports` health gate warns on an unrecorded port that is not parked. Found by the console's first live port change; hrossen's ports 1, 4, 8 and 10 are parked |
| ✅ #854 | switch-controller: a LAG member follows its lead port | M | L | **Closed 2026-10-18** (`af42829a`): UniFi takes an aggregate's VLANs from its lead port, so a non-lead member no longer reports or receives VLAN drift (hrossen's port 12 was "applied" on every reconcile without effect) |
| ✅ #860 | switch-controller: read the switches after every sweep, so `switch-ports` is not judged on a stale read | M | L | **Closed 2026-10-19** (`659a71be`): `interrogate --no-park` reads and parks nothing, every read stamps `lastRead`; `tappaas-switch-read` runs after each real sweep (OnSuccess/OnFailure of update-tappaas, like the security scan), runs the `switch-ports` gate and mails only a finding that is new since the last read; the gate shows the read's age and warns past 26 h. On hrossen: a read in 36 s that changed nothing but `lastRead`, `--if-new-sweep` skipping without a sweep, the mail dry-run sent once and not repeated. The unit arrives with the next self-rebuild |
| ✅ #856 | admin VPN: the peer config carries the site's DNS and routes to the DMZ gateway | M | L | **Closed 2026-10-18** (`cddd049c`): `wgvpn config` v2 adds `DNS = <mgmt gateway>` and host routes to the DMZ gateway (IPv4 and IPv6), so a published name with `admin` in its zone list is reached over the tunnel; `wgvpn list` names peers still on v1. Needed by the console (#839) |
| #668 | A machine's zone is recorded, not enforced | H | M | A machine's `zone0` says which network its physical NIC is cabled to, and nothing checks the switch port. Record switch and port per NIC, report VLAN drift. Decide with #697 |
| #697 | Node `lan` trunks and their switch ports are set once at install, maintained by nothing | M | H | Node trunks and switch ports are set at install and maintained by nothing; untagged mgmt survives on PVID 1 by accident. Five candidate fixes on the issue — **decide with #668** |
| #706 | A wireless device zone cannot be checked against its SSID | M | L | **Scored 2026-10-13:** an attachment field (`port`/`ssid`) for `kind: device` and the #668 check extended to SSIDs. Additive check; after #668 (the wired half, open). Moved from G2.1 2026-10-13: it needs #668's attachment record first |
| #731 | Controller-architecture modules never register themselves, and inventory drift has no routine check | M | L | A controller plugin (`unifi-os`) installs without registering in `switch-manager`/`ap-manager`; inventory drift is never checked. Reported by @ErikDaniel007. **ADR-035 D5/D6** (Proposed): module-manager registers a module's controller (code and instance) — P3, now that P2 runs `unifi-controller` from the registry; the routine check is #860 |
| #155 | Modules for physical devices | L | L | Docs and examples only (Lars, 2026-05-15) |
| FW #158 | Multi-NIC module firewall rules | M | L | Optional roll-in |
| #236 | RADIUS MAC Auth Bypass: a device's VLAN from its MAC, on Wi-Fi and wired ports | H | M | Future idea; depends on how switch ports and APs are managed (this group) |
| #63 | Service desk tooling spike | M | L | |
| ✅ #861 | Moving a 2.2 site to main: four bugs and the workarounds used | L | L | **Closed 2026-10-20** (`7e588af2`). Opened 2026-10-19 by @AndreasJe. Two were already on main: the Jellyfin policy race (#859, `a9dd2f5e`) and the console's first-update rollback (`842e9797`; one rollback for a site whose installed self-prepare predates it, the second update passes). Fixed (`a372b2f7`, `ce1109b6`): the network test accepts an empty CrowdSec whitelist on an IPv4-only site; templates:nixos `update-service.sh` runs `update-os.sh` from the module directory, so `build-facts.sh` is collected from anywhere. Left: the zones template's `wan` (VLAN 100, 10.1.0.0/24) collides with a site zone on that VLAN and the merge does not check |
| #862 | A VLAN tag or subnet already on the firewall is not detected when a zone is authored: template `wan` (VLAN 100, 10.1.0.0/24), `zones init`/`merge`, and `add` | M | M | **Opened 2026-10-20** from #861. **Built 2026-10-20** on branch `vlan-collision-862` (`794613de`, `be9475f7`), to merge: `opnsense-firewall segments` lists every VLAN device and interface; `add`, `init` and `merge` ask it and refuse a held tag or subnet with the holder named, nothing re-allocated; a firewall that cannot be asked is said. On hrossen: a probe VLAN refused by name, a free allocation and a live `merge --diff` unchanged, probe torn down. Before: every path checked a tag only against zones.json: `add` (auto-allocation and `--vlan`), `zones init` and `zones merge` (`614d35cc` refuses when a zones.json zone holds the tag). A VLAN or interface built by hand on the firewall is not seen; on reconcile `zone_manager` adopts it by tag, rewrites its description and, under `--force-rename-labels`, its label. On Andreas's site the template's `wan` landed on a hand-built NAS segment on VLAN 100. **Detect only, never reallocate** (operator, 2026-10-20): one "tag and subnet are free" check, zones.json ∪ the firewall's VLANs and interface subnets, used by `add`, `init` and `merge` and shown in `--check`; a hit refuses with the holder named. TAPPaaS's own numbers (the template's and the band allocation) stay as they are — a changed number would confuse every site — and the operator moves the site's own segment to a free tag. Whether the later DHCP and rule steps act on an adopted interface is unverified; the check is what keeps that from mattering |
| #843 | Create a SIEM for TAPPaaS | H | M | **Opened 2026-10-16.** Wazuh the best candidate (agents, syslog from OPNsense/Proxmox, FIM, vulnerability detection); placement, sizing and its overlap with logging to decide |
| ✅ #851 | CrowdSec on the firewall: rate limiting and bans for published names | M | M | **Closed 2026-10-18.** Opened 2026-10-17 from ADR-032 O1: os-caddy takes extra config only globally, so Caddy's built-in `rate_limit` cannot be scoped to one site. CrowdSec (`os-crowdsec`) reads Caddy's log and bans by pf on the WAN; scenarios for Jellyfin's and Authentik's logins and probing; then Jellyfin's per-account lockout can be relaxed (today a known username can be locked out). Complements #843. **Built 2026-10-17** (`5bb4b7be`, `ab38382f`), live on hrossen: local only (no central API — operator), bans by pf on the sign-in scenario `tappaas/http-login-bf` (6 × 400/401 in ~3 min at Jellyfin's login/Quick Connect or Authentik's token endpoint), `http-cve` and bad user agents; generic probing left out (Jellyfin's missing-image 404s); the site's IPv6 /64s whitelisted; Caddy writes one access log per name; ~140 MiB. Tested: replay into the scenario, whitelist, a real ban into pf. Jellyfin's accounts turned out to have no lockout (-1), so nothing to relax. Verified 2026-10-18: the network update converges it (`--check` clean after); its first day banned 56 cloud-hosted port scanners, no site user |

### G6.2 User interface & physical view — Ease H · Risk L · done for 2.3: 1 · open: 4

A general TAPPaaS user experience, starting with a physical view of the site: nodes, bonds, switches and ports, APs, WAN and satellite, with zones, guests and live state on them (#839; homelable as a starting point), designed first in a spike and an ADR (#844). The service catalog (#183) and Backstage (#91) are decided against it. Linked to G6.1.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #844 | Spike and ADR: design the TAPPaaS user interface | M | L | **Spike done 2026-10-17** (`docs/design/ui-spike.md`, seven mockups from hrossen's records; `ef11be1e`): homelable is a library and an inspiration, not the product; the UI is TAPPaaS's own. **ADR-034 drafted** (`6195dd87`, v0.3; v0.4 with the install findings): a TypeScript backend on the mothership behind Caddy and the Authentik gate at `console.<domain>`, every change a job over a manager verb with its own dry run, the physical view derived from `network-manager topology`. Closes when the ADR is Accepted |
| ✅ #855 | console: a destructive verb's typed confirmation names the object, not the switch | L | L | **Closed 2026-10-18** (`11439bf0`): the verb manifest names the positional that identifies the object; `remove-port` asks for the port |
| #839 | TAPPaaS user interface: a general UX, starting with a physical view of the site | H | L | **P1–P3 built and live on hrossen 2026-10-18** (`839-console-p1/p2/p3`, the review fixes and the operator's UX review, on `main` as `1d9c897a`): the `console` — see, operate (jobs with preview and apply, the Setup wizard, the owner's route) and ask (the assistant through LiteLLM, proposing and never applying) — installed at `console.hrossen.dk` behind the gate, with `network-manager topology`, `health-manager validate --json` and the verb manifests (`--help --json`) in the managers. **Open:** P4 (agents through the gate, #142; the SIEM surface after #843; the end-user badges), the `status.<domain>` route (needs gated `proxyRoutes`), the install fixes and the schema-driven field forms from the first inspection (in progress) |
| #183 | TAPPaaS service catalog | H | L | **Folded into #839** (ADR-034 D6): the console's Modules page is the catalog — every registered repository's modules, installed or not, with Install. To close with the ADR |
| #91 | Backstage as a component of tappaas-cicd | H | L | **Not adopted** (ADR-034 A3): a developer portal, not an operations console. To close with the ADR |

## Wave 5 — live verification

Tests, proofs and sign-offs on real systems, kept apart from development and bug fixes: what is built and waits for a real VPS, a real buddy or a real failure, and the test conventions themselves.

### G5.1 Satellite & off-site — Ease H · Risk M · open: 7

Everything the satellite and the off-site copy still have to prove: the satellite as a module on a real VPS (#671) and makerfloss's satellite converted (#775), the site-liveness watchers in a real outage (#776), the buddy tunnel and relay (#796, #795), the sshPort passthrough (#762) and the ADR-010 hardening sign-off (#406).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #671 | Deep test: satellite as a module on a real VPS | H | L | **Test plan written 2026-10-05** (`docs/plans/satellite-test-plan.md`): six phases on hrossen, each with a teardown. Waits for the operator's VPS and a `sat-test` DNS record |
| #775 | Convert makerfloss's `satellite1` into a module instance | H | L | Split from #671: ADR-010 §8.4.7 with the operator, then #671's phase 1–2 checks. Not before makerfloss runs 2.2; keep a second way in — `satellite1` carries its admin VPN |
| #776 | Report a site that has gone dark (outside heartbeat) | M | L | **Built 2026-10-15** (ADR-031, `7654bedd`, `5cdaf047`, `0005a687`, `8a06e666`): the backup node's pulse watches each buddy we pull (mails both operators), the buddies that pull us (last pull), and this site (uplink, firewall, mothership, PBS); a standalone pulse for a non-TAPPaaS buddy (BUDDY.md Setup 3); a satellite watches its home site's tunnel. Mail via postfix (nodes, debianhosts, satellites: direct). Open before closing: a real alert mail delivered, and a real satellite (#775) |
| #796 | backup: a buddy's WireGuard tunnel set up with the peer (`peer add … --tunnel`) | H | M | **Built 2026-10-07** on `buddy-tunnel-796`: `peer add … --tunnel serve\|dial` creates and removes the PBS-only tunnel; `peer check`; serving side live-tested on hrossen 2026-10-08, dialling side needs a second site |
| #795 | satellite: relay a buddy's WireGuard tunnel to the home firewall | M | M | **Opened 2026-10-07** from BUDDY.md: a `buddy-relay` role relaying declared UDP ports (the admin VPN's P5 pattern), so a site reached only through its satellite can serve a buddy |
| #406 | ADR-010 P7 hardening + sign-off | H | L | |
| #762 | satellite: build the `sshPort` SSH passthrough to `tappaas-cicd` (ADR-010 §4.4.2) | M | L | Designed in ADR-010, never built: a TCP relay satellite `:sshPort` → tunnel → mothership `:22` for sites with no public inbound address. Decide how to limit it; live test needs #671 |

### G5.2 Test coverage & conventions — Ease H · Risk L · open: 5

How tests run (a `test` verb on the managers, #499) and the module tests that still miss their conventions or probe the wrong thing (#119, #120, #409, #658).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #499 | `test` verbs on managers | H | L | |
| #658 | nextcloud test 12 probes the browser URL from wherever it runs | L | L | Maintainer-owned (@ErikDaniel007). Not "403 = pass": skip with a reason when the test host is outside the route's `proxyAllowedZones` (exit 77), as Test 9z does |
| #120 | litellm test.sh conventions | L | L | 2 of 6 items done |
| #119 | openwebui test coverage | L | L | |
| #409 | vllm-amd: `test-model.sh` drifted from the compose `update.sh` generates | L | L | |

## Wave 4 — additive capabilities

New capabilities with low upgrade risk.

### ✅ G4.1 Alerting & cluster resilience — Ease M · Risk M · released: 7 · done for 2.3: 4

Be told when something breaks, and survive more of it. Built: alerts from Loki by mail, every VM's logs in Loki, a credential per pushing VM, container severities from the line, each line's own timestamp, a release CVE preview with majors gated at the boundary (#788); two-node quorum with a QDevice verb (#835), HA failover only to nodes that carry the guest's bridges (#836), a site-timezone gate (#837). A site gone dark is now watched from outside (#776, built — its proof is in G5.1); the bonded lan uplink (#40) and the mail relay (#125) moved to G6.1.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #590 | Second corosync link | H | M | **Closed 2026-10-15, not built (decision):** a node quorate over a private ring keeps its HA resources while its lan is gone, so HA never fails over. Redundancy goes into the lan link instead → #40 |
| ✅ #835 | Two-node clusters self-fence: warn in `node add`, support a QDevice | M | M | **Closed 2026-10-15** (`618411e4`, `ba4c18c6`): `node add` and a `quorum` health gate warn on two votes without a QDevice; `site-manager node qdevice add <host> \| remove \| status`. Added and removed live on hrossen with a test container (5 votes with it, 3 after) |
| ✅ #836 | HA placement only on nodes that have every bridge the VM uses (firewall WAN) | M | M | **Closed 2026-10-15** (`2b0360da`): a declared HANode without one of the guest's bridges is refused; the default picks the first node that has them all; the HA test checks it. With strict rules (`b9d40e98`) and the KVM check in `node add` |
| ✅ #837 | Health check: `site.json` location and timezone vs the nodes and guests | L | L | **Closed 2026-10-15** (`290d2790`): `site-timezone` gate per node and guest; the cluster update sets the nodes' timezone (hrossen's tappaas3 was on Europe/Amsterdam) |

### ✅ G4.2 Proxy & ingress — Ease M · Risk L · released: 3 · done for 2.3: 5

Publish less of each app: limit a route to some paths (#642), some zones (#643) or a provider's source addresses (#656), as ADR-023 describes. One model for how a module's routes are authenticated — several ports, native app clients, machine callers (#845, ADR-032). Decide whether an internal proxy is needed at all (#154).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #642 | Limit a route to paths | M | L | **Closed 2026-10-15** (`537631a8`): ADR-023 P2/P3 — `proxyAccess` path rules on any route (one handle per path with its own access list), `none` (shared deny-all), `identityGate: false`; undeclared path handles and rule lists pruned. Live on hrossen (nextcloud-hpb): an internet path proxied, a mgmt path only from mgmt, everything else 403, teardown pruned clean |
| ✅ #643 | Per-route allowed zones | M | L | **Closed 2026-10-15** (`447f4efa`): ADR-023 P1 — a `proxyRoutes` entry may set its own `proxyAllowedZones` and gets its own access list; undeclared lists pruned; the same-port trap warns |
| ✅ #656 | Limit a route to a provider's source ranges | M | L | **Closed 2026-10-15** (`e85c7da6`): `proxyAllowedZones` takes a network (CIDR) beside zone names, for a provider's caller range; a malformed one is refused at install. A feed that refreshes the ranges stays a follow-up |
| ✅ #845 | ADR: how a module's services are exposed — several ports, native app clients, API access | M | M | **Opened 2026-10-16.** ADR-032 Proposed (`e75b04df`). P0 on hrossen 2026-10-17, torn down clean: **T1** a gate on another port of the same hostname (`:9443`, own Authentik provider) — sign-in, callback and session work, separate from the 443 gate; **T2** an app password (Basic) and a client-credentials JWT pass the gate, Caddy can strip `Authorization`; a bad credential gets a 302, not 401; an app password opens every gate its user may use, a JWT only its own provider; revocation takes up to 60 s; **T3** Jellyfin native login against Authentik over LDAP (outpost + LDAP-Auth plugin 23/24), Quick Connect, group removal refused at the next login — but an existing Jellyfin session survives it. **v0.2 2026-10-17** (`9e41dd79`), operator decisions: NetBird is not the answer for friends and family, so Jellyfin goes without the gate (SSO for the web, Quick Connect for apps, hardening at Caddy and in Jellyfin — D3); the smaller ADR (no `proxyAuth` field, no LDAP); NOMAD in the DMZ. **P1 done:** NOMAD moved to `dmz` on hrossen (`e566222e`; module test 11/11, home reaches it, it reaches only the internet), which needed two module-manager fixes — `modify --set zone0` was refused (`0de41b1b`) and its pre-update gate tested the guest at the new zone (`6600d010`).. **Accepted 2026-10-17. P3 done** (`e70c5a65`, `eb24de47`): Jellyfin published without the gate — `identity:accessControl` dropped (its delete hook now turns the gate off when the route stays), the firewall a known proxy, admin and diagnostic paths closed outside the site, `admin` site-only via a TAPPaaS API key. Live on hrossen: module test 17/17; **T4 from the internet 17/17** — Sign in with Authentik and a Quick Connect sign-in from outside, eleven admin paths 403 in any letter case, Jellyfin logs the client's real address. Rate limiting is #851.. **P2 done** (`df3818bc`, T5 12/12): `caddy-manager set-gate`, gated handles drop `Authorization`, header auth asserted, `authentik-manager service-account-ensure`, `identityGate: false` needs a description. **P4 done, closed 2026-10-17**: identity-manager runs a module's `revoke-sessions.sh` after a reconcile takes access (Jellyfin's ends the person's devices); T6 — a removed person's web and TV sessions get 401 at once. ADR-032 v1.0, built |
| ✅ #154 | `firewall:internal-proxy` | — | — | **Closed 2026-10-17**: answered by ADR-032 D2 — a module that is not published is reached at `.internal` from the zones its ingress allows; no second, internal proxy |

### ✅ G4.3 Manager verb gaps — Ease M · Risk L · released: 9 · done for 2.3: 9

The verbs operators otherwise do by hand (the `test` verbs, #499, are in G5.2): install a whole stack (#763), suspend a module (#428), migrate by changing `.node` (#429), private repositories (#634), module-level `--set` rules (#654).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #763 | `module-manager add-stack`: install a stack's modules in `dependsOn` order | M | L | **Closed 2026-10-15** (`b894e996`): `module-manager add-stack <stack>` — the INSTALL.md order, skips what is installed, refuses missing outside dependencies and cycles, a free VMID in the module's block for an environment install, `--dry-run`. Live on hrossen: devops into `test` installed and torn down |
| ✅ #428 | module-manager `suspend` | M | L | **Closed 2026-10-15** (`b894e996`): `module-manager suspend` / `resume` — the guest stays stopped (HA, or `onboot` off), the config is marked `suspended`; the sweep skips it, the health check reports it. Live on hrossen with deconz-test |
| ✅ #429 | Migrate by modifying `.node` | M | L | **Closed 2026-10-13** per ADR-019 (Accepted v1.0): `module-manager modify <m> --set node=<n>` relocates a module and migrates a running guest (#498, #825); `module-manager migrate <m> [--force]` moves it between node and HANode, live only when `live-ok` says so |
| ✅ #634 | Private repositories in `repository add` | L | L | **Closed 2026-10-15** (`f5acb156`), docs only as decided: DESIGN-GIT.md *Adding a private repository* — a read-only deploy key and a narrow SSH `insteadOf` rewrite |
| ✅ #654 | `module-manager`: the `--set` pre-gate ignores the module-level field declarations (ADR-020 D10) | M | L | **Closed 2026-10-15** (`a49e111f`): `--set` reads `schemas/fields.json` for a field no service owns — `immutable` and `manual` (wiring) refused, an unclassed field refused, `in-place` written; `config-only` stays a label (ADR-020 D10) |
| ✅ #831 | `module-manager delete`: an archived module still counts as a dependent | L | L | **Closed 2026-10-15** (`13c7fda9`): the reverse-dependency check skips archived configs, so archiving a consumer and then its provider needs no `--force`. Reported by @ErikDaniel007 |
| ✅ #857 | Every update on main rolls back: `suspend-module.sh` committed without the executable bit | L | L | **Closed 2026-10-18** (`f6022566`), reported by @AndreasJe: Nix hashes the executable bit, and module-manager's `install.sh` chmods the scripts it links — prepare built it at 644, the self-check evaluated it at 755, so every rebuild on a checkout with `core.fileMode=true` rolled back (hrossen has `false` and never showed it). Committed 100755 (and `wgvpn.test.sh`); `test-tracked-exec-mode.sh` now sweeps every control-plane script. A stuck site recovers on its next pull |
| ✅ #852 | `modify --set zone0` fails its own pre-update tests | L | L | **Closed 2026-10-18**, reported by @AndreasJe: already fixed by `0de41b1b` and `6600d010` (2026-10-17, from the NOMAD move), which his site never received because of #857. Verified live on hrossen with lazysite, dmz → rossen → dmz without `--force`: the gate tests the guest where it is, the converge moves it, 19/19 after, no leftovers |
| ✅ #829 | `backup-manager restore restore` over a module's own guest fails without a terminal | L | L | **Closed 2026-10-15** (`2ce73897`): `--yes` confirms an in-place restore up front and reaches `restore.sh`, whose error names it. Not `--replace`, which restores another guest's backup and leaves it stopped. Reported by @ErikDaniel007 |

### G4.4 Storage & physical devices — Ease H · Risk L · released: 5 · open: 1

Shared storage as a managed part of a site: the rest of the NFS service (#772). The physical network (#668, #697, #706, #731, #155, #158) moved to G6.1.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #772 | ADR-029 NFS: remaining work packages from #766 | M | L | Export backup, NAS servers, storage zone, LXC consumers, quota health, `show`/`purge`. **2026-10-05:** ADR-029 v0.8 (shares by name, pending mounts, `subdir`) built, smoke-tested |

### G4.5 Governance, CI & sign-offs — Ease M · Risk L · released: 5 · open: 2

The project's own machinery (CI runners, #415, moved to G7.1 with the Woodpecker module): community-health files (#486), the remaining ADRs (#359; the ADR-010 sign-off, #406, is in G5.1), a tool for urgent patches (#746), a logging-function lint (#747); the service-desk spike (#63) is in G7.2.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #486 | ADR-015 community-health files | L | L | |
| #359 | legal/processor ADR | M | L | |

---

## Wave 3 — stability & correctness

Low upgrade risk. Build continuously, in any order within a group.

### G3.1 cluster:vm lifecycle & capacity — Ease L · Risk M · released: 18 · done for 2.3: 9 · open: 3

Guests sized, placed, started and stopped right: memory defaults from measurement (#663), moving a running guest to another node (#825), a readiness wait that skips UDP ports (#826), hardware drift (#531), shutdown and boot order (#36, #127), storage growth and placement (#100, #403), a composite-module ADR (#761), and a sweep that survives a guest restarting itself (#753). Built from the 2.0→2.2 field report (#832): a capacity pre-flight before the sweep (#833) and visible size changes on legacy sites (#834). Next by design: dynamic placement on PVE 9.2's load balancer (#838).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #531 | Detect hardware-spec drift | L | M | **Closed 2026-10-14** (`52c4a1bd`): cores, memory and disk drift were already detected and applied; held cores/memory now restart the VM when authorized (`--force` / `rebootOk`), a smaller disk warns and config adopts the real size. Deep test covers VM and LXC; found and fixed an HA start race in migrate (`d5737177`) |
| ✅ #827 | HA failback can move a host-CPU guest live to a node with an older CPU | M | M | **Closed 2026-10-14** (`625e99a3`, `51dc79f2`, `413510b6`, `d4dde5f8`, `fbc3338b`, `d00c28ae`): the risky move on hrossen was the nightly drain tappaas1 (Zen 4) → tappaas3 (Zen 3), not the failback. Node drains refuse live-unsafe moves; `proxmox-controller cpu-inventory` (KVM-probed levels, n×n live-move matrix); `cluster:ha` `haCpu` common (shared x86-64 level, host for alike pairs) / host (failback off, relocate on drain); `cpu-impact` health gate (AVX-512 use per HA guest). hrossen's five HA guests await a restart onto x86-64-v3 |
| ✅ #100 | Automatic storage extension | M | L | **Closed 2026-10-14** (`18427e2c`): every update grows a VM disk whose / is ≥80% by 50% (min 5G, cap `diskSizeMax`) when its pool, and the HA replica's, stays ≤80% — else `DEFERRED:`. Opt-out `diskAutoGrow: false`; settings in `site.json` `diskAutoGrow`. New `storage-pools` health gate (warn 80%, fail 90%, thin overcommit). Rollback after a grow verified clean. Deep test on hrossen 127/0 |
| #403 | Install on the root disk; smarter placement | M | L | |
| #838 | Dynamic placement of workloads (PVE 9.2 CRS load balancer) | H | M | **Opened 2026-10-15.** Opt-in next to the fixed default: `HANode` as a list, an empty list = dynamic; the CPU level the candidate set shares (#827), capable nodes only (#836). ADR first |
| ✅ #833 | Sweep pre-flight: refuse an over-committed node; a minimum host size | M | L | **Closed 2026-10-15** (`b0622eeb`): `health-manager capacity` projects each node's memory after the update; the sweep updates nothing when a node would pass 95% (`--force` overrides). The hardware guide lists the real default sizes (~32 GB for the foundation) |
| ✅ #834 | First converge on a legacy site applies config sizes over those tuned in Proxmox | M | M | **Closed 2026-10-15** (`dd0311ae`): every size set from config is said at info; with #833 it never takes a node past its RAM. Config stays the source of truth |
| ✅ #832 | Field report: a 2.0 site upgraded to 2.2, then a second node | M | M | **Closed 2026-10-15**, reported by @AndreasJe: 27 findings — fixed on `main` (certificate renewal cron and expiry, zones merge and shared VLANs, legacy-site migrations, PXE MAC pinning and NIC, never-deployed modules in the sweep, NFS grant notify, KVM check, strict HA rules, …), the design items split into #833–#838 |
| ✅ #663 | Memory defaults are not based on measurement | L | L | **Closed 2026-10-13** (operator): 7-day measurement on hrossen. vaultwarden was too small — 1→1.5 GiB (`bac670ce`); euro-office and deconz-test moved tappaas1→tappaas2, tappaas1 commitment 63→51.5 GiB of 61. The other proposed reductions (nextcloud-hpb, jellyfin, forgejo, litellm default) not applied; `network` 8G→4G still parked |
| ✅ #825 | update-module: changing a running guest's node does not migrate it | M | M | **Closed 2026-10-13** (`fix(cluster): move a running guest when its node changes`): snapshot and OS update act where the guest runs; `live-ok` refuses local disks with snapshots; `--allow-disruption` does stop → offline migrate → start. Proven on hrossen (`g2.1-firewall`): deconz-test deferred, then moved tappaas2→tappaas3 and back by `update-module`. Found moving guests for #663 |
| ✅ #826 | Readiness wait probes UDP ports over TCP — 180 s lost per update | L | L | **Closed 2026-10-13** (`fix(module-ready): do not probe UDP or ICMP ports over TCP`): only TCP, TCP/UDP and unset protocols are probed; deconz-test's wait went 180 s → 0 s; a full `update-module deconz-test` on hrossen now takes 79 s. Found during the #825 test |
| #761 | A composite-module ADR: `cluster`, `kubernetes`, and modules that only provide artefacts | H | M | ADR-022d and ADR-026 defer `cluster`/`kubernetes` to an ADR that does not exist, and `templates` fits no `kind`; interim values in ADR-022d v1.2. With @ErikDaniel007 |

### G3.2 Identity & SSO wiring — Ease M · Risk L · released: 10 · done for 2.3: 4 · open: 1

Every app wired to the identity provider the same way: OIDC for hass, Nextcloud and forgejo (#345, #401, #282), a site-specific login page (#479), logging's SSO dependency (#701), a test for forward-auth (#752), and Jellyfin behind forward-auth (#805) with Authentik sign-in (#806).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #345 | hass: appliance-aware OIDC staging | M | L | |
| ✅ #401 | Nextcloud: OIDC redirect, trusted domains | M | L | **Closed 2026-10-14 — already met:** login redirects straight to Authentik (`caface4d`, local `/login?direct=1` kept); trusted domains from the module config (`3ea124b0`). Verified on hrossen |
| ✅ #479 | Site-specific login page | L | L | **Closed 2026-10-14** (`1a065ddb`, `17ecfb92`): the sign-in page shows the site name and its own logo from `site.json` `branding` (light/dark); live on hrossen. Extended 2026-10-14 (`44724af2`): start-page tiles show each module's icon (dashboard-icons) and `displayName`, generated tile otherwise; providers keyed by slug so a rename keeps the OIDC client |
| ✅ #858 | identity: tile icons and the site logo need `/admin/file/`, so a site below Authentik 2025.12 can never update | M | L | **Closed 2026-10-19** (`370ec3d6`), reported by @AndreasJe: the files API is new in 2025.12 (absent at 2025.10.3), and every app ensure uploaded an icon, so identity and every SSO module rolled back on 2025.6.4 and the site could never climb. Below 2025.12 icons and the logo are skipped (title and flow heading still set); an unreadable version is taken as new. Unit tests 87/87; on hrossen (2026.8.3) identity and Karakeep updated with apps and brand unchanged |
| ✅ #701 | logging depends on identity though its own code makes SSO optional | L | L | **Closed 2026-10-14** (`344bc8b8`): logging lists identity in `integratesWith`; Grafana's OIDC switch follows identity. Other consumers keep `dependsOn` — identity is always installed |

### G3.3 App module fixes — Ease L · Risk L · released: 10 · done for 2.3: 5 · open: 7

The known rough edges of the app modules, fixed and tested so they stay fixed: Nextcloud Talk end to end (#715), Home Assistant (#552, #568, #571 — maintainer-owned), Nextcloud and euro-office (#332, #751; its test 12, #658, is in G5.2), litellm consumers (#553), windows-server (#411), forgejo (#283, #284), in-guest backups (#754), container stop timeouts (#786).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #552 | hass: a lost LLAT blocks every update | L | L | **Assigned to @ErikDaniel007 — do not fix (operator, 2026-09-26).** `ha-llat.sh` has no recovery path, so a lost token blocks every update |
| #568 | hass: backup freeze leaves Frigate unhealthy | M | L | |
| #571 | hassanova has no release baseline | L | M | Fix exists unmerged (`ed8a9799`), but landing it makes the merge reconcile a Production module for the first time (Risk M). **Needs its owner or a decision** |
| #553 | litellm:models cannot reach an appliance consumer | M | L | |
| #715 | Nextcloud-hub revisited: Talk never worked end to end; races, retries and tests hid real failures | H | M | Talk stack and Nextcloud 35 on `main` (`c998ca5f`). Open: how @AndreasJe's branch lands, one `/etc/secrets` mode, rotating early OIDC secrets — until an off-network Talk call works |
| #411 | windows-server: `deploy-instances.sh` missing | L | L | **Verified open 2026-09-26** (low-risk sweep): the script does not exist; writing it is the work |
| ✅ #332 | euro-office / Nextcloud install findings | M | L | **Closed 2026-10-15** (`aa92f901`): memory and cores are integers in every module (21 wrote strings; compared numerically, so no drift); nextcloud and euro-office no longer declare the default `proxyPort` 80; euro-office's README says why it needs no `identity:identity`. The other findings were already resolved: the connector is re-applied on update and declared in the schema, `nextcloud:fileservice` is the name, zones follow the default zone, coturn finds its WAN address and NAT itself, tappaas2 trunks the service VLANs |
| ✅ #807 | Immich: bump `unstableSrc` once `jellyfin-ffmpeg` fixes six upload-reachable CVEs | M | L | **Opened 2026-10-09** from the #788 triage (`cc6790a2`): immich-server's jellyfin-ffmpeg 8.1.2-5 has six heap-corruption flaws any logged-in uploader reaches (RISK medium in `immich-vex.json`); nixos-unstable has no fixed jellyfin-ffmpeg yet, and plain ffmpeg 9.0.1 lacks the `tonemapx` filter immich needs. **2026-10-17:** Jellyfin 12.2 (#850) runs the same jellyfin-ffmpeg 8.1.2-5, so the bump covers both modules. **Closed 2026-10-18** (`a8aea117`, `291e28ad`): jellyfin-ffmpeg 8.1.3-1 for Jellyfin and Immich ahead of the channel (pinned package, new source, the 8.1.2 patch it contains dropped); FFmpeg 8.1.3 fixes VobSub, ADX, TDSC, TY, MACE, DVB subtitles, CFHD, RTP/ASF and the HLS loop. Live on hrossen, both module tests green; Jellyfin 46 → 23 high (18 shared), Immich 27 → 21; the rest decided in VEX (96611/52297/52296 need FFmpeg 9.0, 107696 unfixed upstream). Drop the override when nixos-unstable carries 8.1.3 |
| ✅ #850 | Upgrade Jellyfin to 12.x and the SSO plugin to the maintained fork | M | M | **Closed 2026-10-17** (`ce3021a0`, `9fe72ca3`, `3a6e54cb`): Jellyfin 12.2 from a pinned nixos-unstable (10.11 gets no more releases; GHSA-hw73 unauthenticated file read open there), SSO plugin K0lin 5.1.1 (an SSO account had no password, so an empty-password login worked — the `lars` account on hrossen; sealed now), the modern `Authorization` header, a start-up guard on case-clashing user names, test checks for the version and for passwordless accounts. Live on hrossen: in-place migration, module test 11/11, Authentik sign-in through the gate verified. VEX re-triaged: 13 jellyfin-ffmpeg findings exploitable (crafted library file or network source), the rest not reachable |
| ✅ #859 | jellyfin: `jellyfin-tappaas-policy` fails the activation on first run | L | L | **Closed 2026-10-19** (`a9dd2f5e`), reported by @AndreasJe: while Jellyfin starts (and migrates on a version upgrade) its setup server answers `/health` 200 "Degraded" and the API 503, so the unit's `/Users` call failed (exit 22). It now waits on `/System/Info/Public`, adds the key after the start, and is no longer oneshot: an activation neither waits on nor fails over policy. On hrossen: first run with Jellyfin started together, and with its port unreachable for 90 s — the key is made the second Jellyfin answers; module test 17/17. Same day: `pkgs.getent` in karakeep's and nomad's DNS waits (`ff40fa9c`), which had waited out 5 min on every start |
| ✅ #751 | nextcloud:fileservice has no teardown | M | L | **Closed 2026-10-15** (`2b6c7672`): `delete-service.sh` removes the consumer's env file on the Nextcloud VM and the settings `occ` applied — euro-office's document-server settings, coturn's TURN/STUN, the HPB's signaling server — only when the file names that consumer; never fails the delete. Live on hrossen: each connector removed, re-wired by its update, service tests pass |
| #754 | In-guest backup timers: drop for PBS or say why they stay | L | L | **2026-10-14:** identity, coturn, euro-office, vaultwarden dropped (three had produced empty archives every night). **litellm and openwebui assigned to @ErikDaniel007** — openwebui's `restore.sh` reads `/var/backup` |

### G3.4 AI stack maturity — Ease M · Risk M · released: 1 · done for 2.3: 3 · open: 5

A production-grade AI stack (its test conventions, #119 and #120, are in G5.2): hardened (#121) and kept current (#621), LiteLLM sized for its workers (#677), and vLLM's models recoverable after a restore (#758).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #121 | litellm production-grade | M | L | Renamed backups: old backup files must still restore |
| #621 | Bump litellm / openwebui | M | M | After #121 LLM-003 gives update.sh a health gate |
| ✅ #810 | openwebui: container runs as root on the host network, with server-side STT on | M | L | **Closed** (`784f1075`, `046980d6`): unprivileged container root, speech-to-text in the browser only; VEX updated |
| ✅ #811 | CVE scan: native libraries bundled in Python wheels are not seen | M | M | **Closed 2026-10-14** (`279fcfbb`, `6729b7a9`, `977a3255`): the CVE scan sees native libraries bundled in Python wheels (distro-owned ones skipped); findings triaged into VEX |
| #812 | vllm-amd: privileged LXC, unauthenticated vLLM API, sshd password auth | M | L | **Opened 2026-10-09** from the #788 triage of its Debian LXC: root in ct312 is root on tappaas2 (Docker inside, GPU devices); vLLM :8000 on all interfaces with no `--api-key`, bypassing LiteLLM; `PasswordAuthentication yes` |
| ✅ #813 | tappaas-cicd: Nix store fills the mothership disk between weekly GCs | L | L | **Closed** (`56b9eca3`, `5711707c`): Nix store GC on the mothership, options 1–2; 3–5 decided against |
| #758 | vllm-amd: the models bind mount is in no backup | M | L | The 33 GB `/tanka1/vllm-models` bind mount is in no backup, so a restored container has no models. Maintainer @ErikDaniel007: re-download, back it up, or call it cache |
| #677 | litellm's default workers do not fit its default 4 GB | L | L | Found 2026-09-20 by `--deep`: litellm plus four workers leave 43 MB free in the default 4 GB. Either the default memory covers the workers, or the workers follow the memory |

### G3.5 Installer UX — Ease L · Risk L · released: 1 · done for 2.3: 1 · open: 2

A first install that is easier to get through: resumable (#377), showing its progress (#266), asking only what the hardware needs (#405), reusing what it already downloaded (#83).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #377 | Installer cannot restart; mgmt-net routing | M | L | |
| ✅ #266 | Progress indicator during the PVE update | L | L | **Closed 2026-10-15** (`d92b3ad0`): `cluster/install.sh` prints a dot per line of the Proxmox VE update, logs it to `/root/tappaas/pve-update.log` and shows the tail on failure |
| FW #83 | Reuse already-downloaded images | H | L | **Re-scored Ease L → H (2026-09-26):** the img download lives in a temp dir deleted on exit. Reuse needs a cache location and a staleness policy (moving tags) — a decision first |

---

## Wave 2 — network behaviour hardening

Changes to live firewall and DNS behaviour on every installation. Restrictive defaults get harder to introduce the longer users rely on permissive ones, so they come early; every change shows its dry-run diff (#645) before `--apply`.

### G2.1 Firewall exposure & rule order — Ease M · Risk H · released: 7 · done for 2.3: 18 · open: 2

Tighter firewall defaults that keep what modules need. Built: the gateway, GUI/SSH and anti-spoofing rules. Sprint from 2026-10-12: the review of the tier model and rule creation is done and published (#816), with most of its findings fixed; pinholes no longer shadowed (#386); every zone policy covers IPv6 (#815), and IPv6 itself is built (#26). The rules manager's overlap report, covered pinholes and sequence map are built (#160, #256, #162, on the branch). The review findings are done: #817, #818, #822 closed; #819–#821, #823 and the ADR amendments (#824) closed — on `main` 2026-10-13 after a clean `--deep` (144/0). Inbound IPv6 to Caddy, IPv6 anti-spoofing, DNSSEC (#263), #576, #257, #660 and #683 followed, on `main` 2026-10-13 after a clean `--deep` (144/0). Lockout check re-run on hrossen 2026-10-13 against the current rules, IPv4 and IPv6: only mgmt reaches the firewall's GUI and SSH, on any address; the WAN passes 80/443 and nothing else (the admin VPN not re-probed). Open: the NetBird rules below, pending the NetBird decision; #706 moved to G4.4 behind #668. NetBird rules (#385, #222) are low priority until the NetBird decision.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #816 | Review the zone tiers and rule-set creation; publish how it works | M | L | **Closed 2026-10-13:** review (`docs/design/zone-rules-review.md`, 18 findings, 11 fixed on `main`); published on tappaas.org as *Firewall Rules*, a slimmer *Network Zones* and *IPv6*; open findings are #817–#823, the ADR amendments #824 |
| ✅ #386 | block-private rules shadow auto-pinholes | M | M | **Closed 2026-10-12:** pinholes sit in a band before the zone baseline; pf order verified on hrossen |
| ✅ #815 | IPv6 parity: zone policy covers IPv6 before any zone gets an address | M | M | **Done 2026-10-12, on `main` 2026-10-13:** zone and module rules `inet46`, a zone-networks table and ULA blocks for IPv6, ICMPv6 declarable; forced sweep 24/24, isolation over IPv6 verified. Anti-spoofing stays IPv4 (in #26's remainder) |
| ✅ #817 | Egress `to: internet` also passes every private and zone network | M | M | **Closed 2026-10-13** (`g2.1-firewall`): written as "not `tappaas_not_internet`" (private, special ranges, every zone's network); reproduced and verified on hrossen |
| ✅ #818 | `alias:` peers skip the zone-policy check | M | M | **Closed 2026-10-13** (`g2.1-firewall`): an alias counts as the zones its addresses are in; one spanning zones is refused; derived NFS paths keep their grant. No deployed module affected |
| ✅ #819 | `alias:` ingress bound to `lan`; a failed interface lookup falls back silently | M | L | **Closed 2026-10-13** (on `main`): alias ingress on its zones' interfaces; a missing interface refuses the module. All 12 modules on hrossen compile |
| ✅ #820 | A description change duplicates a module rule | L | L | **Closed 2026-10-13** (on `main`): one rule per identity; reproduced and fixed live with coturn |
| ✅ #821 | The pinhole check exists twice and the copies can disagree | L | L | **Closed 2026-10-13** (on `main`): zone-manager's validator calls rules-manager's predicate; zone peers allowed by `access-to` too. `--summary` identical on hrossen |
| ✅ #822 | Block-private misses 100.64/10, 169.254/16 and the firewall's other addresses | M | M | **Closed 2026-10-13** (`g2.1-firewall`): zones with internet block `(self)`, 100.64/10, 169.254/16; Caddy reached on `(self)`. WAN 53053/53 closed, verified on hrossen |
| ✅ #823 | Gateway lookup is one unretried API call per zone | L | L | **Closed 2026-10-13** (on `main`): one batched read per step, a miss re-read with retry; zone reconcile identical on hrossen |
| ✅ #824 | Amend ADR-014 and ADR-021 to the zone and rule model as built | L | L | **Closed 2026-10-13** (on `main`): ADR-014 v1.2 (new D9), ADR-021 v1.1 |
| ✅ #576 | Zone `serves` as string or array | M | L | **Closed 2026-10-13** (on `main` 2026-10-13 after a clean `--deep` (144/0)): `serves` is one environment or a list; `bind --add` / `--unbind --environment`; ADR-014 v1.3 |
| ✅ #257 | mDNS in zones.json | M | M | **Closed 2026-10-13** (on `main` 2026-10-13 after a clean `--deep` (144/0)): zone field `mdns`; `mdns-manager` converges os-mdns-repeater and one rule (975) from zones and modules' `discoveryMdns`; relay verified on hrossen; ADR-014 D10 |
| ✅ #160 | Overlap detection in the rules manager | M | L | **Closed 2026-10-13** (`g2.1-firewall`): `rules-manager overlaps` / `verify-rules --detect-overlap` — shadowed, redundant and conflicting rules on the live rule set, both families; read-only. hrossen: 136 rules, 0 findings |
| ✅ #256 | Skip pinholes already covered by zone access | M | L | **Closed 2026-10-13** (`g2.1-firewall`): a rule `access-to` already passes is left out and recorded; the network update re-checks (`recheck-covered`) and writes it again when `access-to` narrows. Live round trip with coturn on hrossen |
| ✅ #162 | Persistent sequence-map artifact | L | L | **Closed 2026-10-13** (`g2.1-firewall`): the map gains `generated`, `covered` and stale-entry clean-up; slot sharing warned; `rules-manager list-slots` |
| ✅ #660 | A declared `aliasType` change cannot be applied | M | M | **Closed 2026-10-13** (on `main` 2026-10-13 after a clean `--deep` (144/0)): the type is changed in place through OPNsense's own API, rules referencing it and all; verified live |
| ✅ #683 | Declared `ports` without `network:rules` are inert | L | L | **Closed 2026-10-13** (on `main` 2026-10-13 after a clean `--deep` (144/0)): operator decision — such `ports` are documentation (`unwired: documentation`); validate and the merge stay silent |
| #385 | Persist the NetBird OPT1 pass rule | L | M | **Low priority this sprint (2026-10-12)**, pending the NetBird decision (*Decisions*). Land with #222 |
| #222 | NetBird → srv floating rule is fragile | L | M | **Low priority this sprint (2026-10-12)**, pending the NetBird decision. The #816 review found no code that creates NetBird rules |

### G2.2 DNS resolver robustness — Ease L · Risk M · released: 4 · done for 2.3: 3 · open: 1

A resolver that holds up: a working Unbound restart (#387), a written IPv6 stance (#149), DNSSEC with split horizon (#263), and optional blocklists (#157). Public DNS that follows the WAN (#383, #830) moved to G6.1.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #387 | Unbound rc.d restart fails (Python mismatch) | L | L | **Closed 2026-10-13** (operator): TAPPaaS restarts Unbound through `configctl`, never rc.d |
| ✅ #149 | IPv6 root lookups fail → `do-ip6: no` | L | L | **Done 2026-10-12** (`b03a4840`, awaits push): `ipv6-manager`, round trip live on hrossen with no IPv4 gap. **Every site turns IPv6 off at its next sweep unless `ipv6: true`.** Decided: a `site.json` `ipv6` field, default `false`, says whether the site supports IPv6; Unbound's `do-ip6` follows it. The stance is the IPv6 ADR (#26) |
| ✅ #263 | DNSSEC on Unbound | L | M | **Closed 2026-10-13** (on `main` 2026-10-13 after a clean `--deep` (144/0)): site.json `dnssec` (default true); split horizon unaffected; ADR-021 |
| FW #157 | Default DNS blocklists (DNSBL / maltrail) | M | M | **Built 2026-10-13** (`e919308b`): `site.json` `dnsBlocklists` drive Unbound's blocklists; the pfBlockerNG replacement guide (`network/docs/pfblockerng-replacement.md`) awaits @ErikDaniel007's review before the issue closes |

---

## Wave 1 — the breaking-change window

Everything that renames, re-schemas or rebuilds, landed while few installations depend on today's shapes — each change with its migration and an upgrade test from the current `stable`, not only a fresh install.

### ✅ G1.2 Backup placement model + managed machines (ADR-012, ADR-026) — Ease M · Risk H · released: 27

Backups where the operator chooses — a node, a managed machine, an external PBS or the satellite — encrypted, with every machine TAPPaaS manages a module (ADR-012, ADR-026). The satellite's live test (#671), makerfloss's satellite (#775) and the buddy tunnel and relay (#795, #796) moved to G5.1.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|

### G1.6 Secrets & privileged access — Ease H · Risk H · released: 4 · open: 1

Least privilege on the platform. Built: nodes hardened to the Proxmox guide, key-only SSH, encrypted backups. Next: how an AI agent may reach the mothership (#142), SSH to the mothership through the satellite (#762) moved to G5.1. Secrets management (#58) waits in Future Work.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #142 | RFC: AI-agent access to cicd | H | L | Decision |

### G1.7 Parked for Erik discussion · open: 3

Waiting on a conversation between Lars and @ErikDaniel007, not on work: the controller pattern (#430), hass locale (#348) and Erik's image pins (#765).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| #430 | Controller/manager pattern for app modules | M | L | **ADR-035 v0.6 (2026-10-20)** (operator; P1–P2 live on hrossen 2026-10-20; P3 next): controllers and managers live with their module in tappaas-cicd's layout, declared in its JSON, linked and registered by module-manager in one registry; vendor code a controller, vendor-neutral code a manager. Open for Erik: O4 (Ansible first, the foundational/domain line) |
| #348 | hass locale from site master data | M | L | **Parked 2026-09-21:** no test site runs hass. The fix is written on the issue — `core_config` at `lib/config.sh:158` plus a converge for onboarded instances, from `.location` |
| #765 | Container image pins: list litellm, openwebui, vllm-amd, deconz; move the stale ones | L | L | From #750, for @ErikDaniel007: list his modules in `src/image-pins.json` and move the stale pins — euro-office v9.3.1 → v9.3.4 first; litellm and openwebui overlap #621 |

---

## Next release

What the next release delivers, kept current as work lands — one short paragraph, written for
someone deciding whether to upgrade. The release-train boundary turns it into that release's
summary (`release/roadmap-cut.py`) and leaves this block empty again.

<!-- next-release summary -->

**IPv6, opt-in per site.** A site turns it on with `site.json` `ipv6: true` (default `false`): each zone gets a `/64` from the WAN's prefix, every VM's name resolves to its IPv6 address too, the firewall rules cover both families, names published through Caddy answer over IPv6 inside the site, and Caddy is reachable from the internet over IPv6 — publish the address `ipv6-manager` reports as the AAAA; everything still works over IPv4, and switching it off withdraws IPv6 cleanly. **The first sweep after upgrading turns IPv6 off on the firewall** — inbound IPv6 dropped, DNS over IPv4 only — unless the site sets `site-manager site modify --ipv6 true` first. Existing zones are given an IPv6 number (migration 0016); it does nothing while `ipv6` is `false`. See *IPv6* and *Firewall Rules* on tappaas.org.

**Firewall and DNS.** Unbound validates DNSSEC: **the first sweep turns it on** (`site.json` `dnssec`, default `true`; set it `false` to opt out); internal and published names are unaffected. A zone can share mDNS discovery with other zones (`"mdns": true`; discovery only, reach is still the zone rules). A client zone can serve several environments (`serves` as a list, `network-manager bind --add`). A module's `aliasType` can now be changed and is applied in place; `ports` on a module without `network:rules` is documentation and no longer warns. `rules-manager overlaps` reports shadowed, redundant and conflicting rules, and a pinhole a zone's `access-to` already covers is no longer written. Every zone with internet access now also blocks CGNAT, link-local and the firewall's own addresses, and a module's egress `to: internet` excludes the site.

<!-- /next-release summary -->

## Release 2.2 — staging 2026-10-10 · production at the next boundary

Tag `v2.2`, cut into staging 2026-10-10 by a release-train boundary.

**Safer by default, and you hear when something breaks.** Every VM and container backup is now
encrypted; the firewall admits its GUI and SSH only from management, gives other zones nothing but
DNS, NTP and DHCP, and drops spoofed traffic; nodes are hardened to the Proxmox guide; Authentik is
current again (2026.8), and a CVE scan runs after every update. Alerts reach you by mail — quorum
loss, failing disks, out-of-memory kills, failed backups — with every VM's logs in Loki. Guests are
built on the mothership, so updates work without internet, and restores of a node and of the
mothership have been rehearsed. New: NFS shares from the nodes, Immich and Jellyfin (Testing), and
forgejo with single sign-on in a DevOps stack. *Upgrading:* each guest's first backup afterwards is a
full upload, and Authentik steps through its versions over several updates.

The rows below are what it carried, by the wave and group they came from.

### Wave 0 — make upgrades safe

#### G0.1 Migration & rollback framework — Ease H · Risk L

Changes to `config/` that every site can take safely: versioned migrations with backup, dry-run and a ledger (the contract is ADR-025), rollback in install and update, and one meaning for `--force`.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #736 | update merge pins a field that a release moves to a new place | M | M | **Closed 2026-09-26** (`2d25aaf3`): merge rule 5 tells "the operator changed it" from "`.orig` never recorded it" and names each refused value with its remedy. The rule itself: #488 |

### Wave 1 — the breaking-change window

#### G1.1 Vocabulary & classification (ADR-022 family) — Ease H · Risk H

Settle the words before they spread into schemas, CLI names and `config/` paths: the ADR-022 vocabulary — `kind`, scope derived from stack, People → Identity — everywhere. Left for a later release: removing the `tier` fallback.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #676 | `tier` → `scope` migration (ADR-022e) | M | H | **Landed 2026-09-28** (operator): scope is derived from `stack` (ADR-022e v1.1), so no `scope` field and no migration; `tier` removed from the module JSONs, read as a fallback for one release |
| ✅ #705 | cluster and templates carry a kind ADR-022d denies them | L | L | **Closed 2026-10-02:** the interim kinds (`cluster` = application, `templates` = vm) are recorded in ADR-022d v1.2; what they really are is the composite-module ADR, #761 |
| ✅ #741 | `update-tappaas` sweeps a Proxmox VM template as if it were a module | — | — | **Closed 2026-09-25** (`912b50b9`): a config whose `stack` is `template` no longer enters the update queue (it failed every sweep for 13 days on the reporter's site) |

#### G1.2 Backup placement model + managed machines (ADR-012, ADR-026) — Ease M · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #756 | `debianhost`: key-only SSH as an explicit step | L | L | **Done 2026-10-02**, live on hrossen: `sshKeyOnly`, true by default (ADR-026 v0.7), re-applied nightly; machines adopted earlier keep passwords (migration 0013); one script with #19 |
| ✅ #760 | VM and container backups are not encrypted, against ADR-012 | M | H | **Closed 2026-10-03:** every VM and container backup is encrypted (`--encryption-key`, escrowed); restore with and without the key proven on hrossen. Old plaintext snapshots: the operator's |
| ✅ #737 | `site.json` `backup: true` fails validation and has no migration | L | L | **Closed 2026-09-25** via `integrate/nc35` (`c998ca5f`): migration 0011 turns an old `backup: true` into `{}` (`false` → `null`), so older sites validate. Reported by @AndreasJe |
| ✅ #742 | `backup:filesystem` update never creates a missing encryption key, so a capture can fail forever | L | M | **Closed 2026-09-26** (`85d3ccf3`): an absent `backup:filesystem` key is created and escrowed on update — makerfloss's mothership `config/` had never been backed up. Escrow fix `c53576a0` |
| ✅ #745 | A dangling symlink in a declared path refuses the whole capture | M | M | **Closed 2026-09-26** (`backup:filesystem`). Added to the roadmap 2026-10-07 |

##### ADR-012 close-out (original scope)

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #407 | ADR-012 3-node live validation gate | H | L | **Closed 2026-10-03:** push write-no-delete, ±key restore and relocation green 2026-09-19; node-add client proven in the #729 rejoin; ADR-012 v1.0 accepted; immutability deferred (F.1) |
| ✅ #749 | Installing `backup` on a PVE node silently removed its PVE apt repository | L | L | **Opened and closed 2026-09-27:** `backup/install.sh` wrote its apt stanza over the PVE one, so tappaas3 silently stopped getting Proxmox updates |

#### G1.3 Module contract & repo layout — Ease H · Risk H

One module contract — what community modules copy and deployed configs point at: version and status rules, one catalogue, the blueprint check at every release, modules grouped by stack, and a tool to move them ([MOVE-MODULE.md](src/foundation/tappaas-cicd/MOVE-MODULE.md)).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #421 | Restructure `src/apps` into stacks | H | H | **Done 2026-10-03**, live on hrossen: modules live in `src/<stack>/<module>`, `src/apps` gone; 13 moves by `move-module.sh`, migration 0014; stack READMEs generated. Agreed with @ErikDaniel007 |
| ✅ #674 | Implement the ADR-027 blueprint check | M | L | **Landed 2026-09-28:** `module-manager validate --blueprint`, run at every release boundary (not every push); every TAPPaaS module passes. Community: 78 errors, reported to its maintainers |

#### G1.4 Common NixOS baseline — Ease H · Risk H

One NixOS baseline every VM imports, carrying the site's time zone, locale, keyboard and time source — the same facts applied to Debian guests and nodes — and pins with a cadence. Left: hass locale (#348, G1.7) and Windows guests (#678, Future Work).

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #324 | App VMs do not import `tappaas-common.nix` | H | H | **Closed 2026-10-04:** every NixOS VM and the mothership import the baseline (`0ce65c14`, `b07743ef`, `60c115f6`), guarded by two tests; sweeps 19/19, deep tests unchanged |
| ✅ #740 | `update-os.sh` ships only `*.nix` siblings, so a module cannot carry a patch or data file | L | L | **Closed 2026-09-25** via `integrate/nc35` (`c998ca5f`): `.patch`/`.diff` siblings ship with a module's `.nix`; other data files remain undecided. Reported by @AndreasJe |
| ✅ #748 | identity: the Authentik pin has not moved since 2026-02-21, and nothing tracks it | H | H | **Closed 2026-10-03:** Authentik walked 2025.2.1 → 2026.8.3 on hrossen in nine hops, one release line per update (`ak-step.nix`). Plan and results: `docs/plans/authentik-upgrade-plan.md` |
| ✅ #750 | Container image pins have no cadence and no tripwire, unlike the nixpkgs pin | M | L | **Closed 2026-10-03:** `src/image-pins.json` lists container pins; `tappaas-train` reports age and newer upstream at each boundary, a warning past 45 days (ADR-028 D14 draft). Rest: #765 |
| ✅ #777 | Release train: lock nixos-unstable beside the pin, so Immich 3 follows release moves | M | M | **Closed 2026-10-06, not built (decision):** Immich keeps its own nixos-unstable revision in `immich.nix` until NixOS 26.11 is pinned; until then an Immich update is a deliberate edit |

#### G1.5 Rebuild & recovery paths — Ease M · Risk H

A proven way back before anything breaking: `config/` backed up and restorable, mothership keys that can be reissued, restores of a module, a node and the mothership rehearsed, and a control plane that checks itself and rolls back.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #755 | `cicd-key.sh` ignores `kind: machine` modules — `rotate` locks the mothership out of satellite and `debianhost` | L | L | **Closed 2026-10-02:** `cicd-key.sh` now covers machine modules — `rotate` had locked the mothership out of satellites and adopted machines. Reproduced and fixed live on hrossen |
| ✅ #729 | Rehearse RESTORE.md §2, §3 and §5.2 on the test system | M | L | **Closed 2026-10-03:** RESTORE.md §3 (lost node) rehearsed end to end, §2 and §5.2 in part; 14 findings fixed. Plan and results: `docs/plans/restore-rehearsal-plan.md` |
| ✅ #314 | PVE 9.2 default + upgrade path | L | L | **Closed 2026-10-03:** 9.2 is the install default, and the sweep upgrades nodes within 9.x. Fixed with it: `install.sh` refused past 9.4; first-node media named the boot disk by kernel name |
| ✅ #417 | `node delete` does not remove the node | M | M | **Closed 2026-10-03:** `site-manager node delete` previews; `--apply` refuses while the node holds work; `--shutdown`, `--erase` (typed confirmation), `--lost`. Dry-run on hrossen |
| ✅ #711 | templates:nixos re-apply fails with no cause and rolls the VM back | — | — | **Closed 2026-09-25** (`e5481865`): a failed OS update now says where and why it stopped (ERR trap under `set -E`). Added in the 2026-09-24 issue sweep |
| ✅ #720 | update-os.sh hangs indefinitely when the rebuild's ssh session dies | — | — | **Closed 2026-09-26** (`1aefd916`): keepalives and a ceiling on the rebuild ssh, so a switch that restarts sshd fails instead of hanging 93 minutes |
| ✅ #700 | The pre-update gate tests guests that are still booting | L | L | **Done 2026-10-03:** `module update` waits until the guest has booted and its `ready.sh` passes (up to 300 s) before the gate; a timeout is reported, not fatal. `ready.sh` is an ADR-027 MAY |
| ✅ #767 | The sweep's systemd unit is not the operator's console — align it (ADR-017 D3) | L | M | **Closed 2026-10-04:** the sweep unit runs steps as the console does (login shell, `sudo -n`, no sandbox); `tappaas-unit-run.sh` tests in that context. Two sweeps 18/18. ADR-017 D3 draft |
| ✅ #768 | `module update`: a failed dependency (the OS rebuild) should stop the update, not run update.sh first | L | L | **Opened and closed 2026-10-04:** with a snapshot taken, `reconcile --apply --fail-fast` stops at the first failed dependency and skips Step 3. Found in the Authentik walk |
| ✅ #744 | A mothership release move ends the sweep with no record, no re-arm and no notice | M | H | **Closed 2026-09-26.** Added to the roadmap 2026-10-07 |

#### G1.6 Secrets & privileged access — Ease H · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #128 | Security hardening (Proxmox hardening guide) | H | M | **Closed 2026-10-04** (`383f8d5e`): of seven guide gaps, sshd (#19), backup encryption (#760), microcode and auditd → Loki done; unattended-upgrades and fail2ban not adopted; Corosync → #590 |

### Wave 2 — network behaviour hardening

#### G2.1 Firewall exposure & rule order — Ease M · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #399 | Zone → gateway rule allows every port | L | H | **Closed 2026-10-02**, with #384: the all-ports gateway rule is now DNS, NTP, DHCP and ICMP only, chosen from hrossen's filter log; applied on hrossen, module tests green |
| ✅ #384 | Restrict webgui 8443 to mgmt + NetBird | L | H | **Closed 2026-10-02**, with #399: 8443 and 22 on the firewall blocked from every rule-managed zone; mgmt and the admin VPN keep access. NetBird path untested (not on hrossen) |
| ✅ #159 | Anti-spoofing + drop fragments, always on | L | M | **Closed 2026-10-02:** a spoofed-source block heads every rule-managed zone (pf already reassembles fragments). Fixed on the way: inverted rules were never created (`source_invert`) |
| ✅ #375 | `mgmt.access-to: "all"` sentinel | L | L | **Closed 2026-10-02:** `mgmt.access-to` is `["internet", "all"]`, expanded where the zones file is read; migration 0012. Identical rules on hrossen before and after; Wave 2 entry gate met |

### Wave 3 — stability & correctness

#### G3.1 cluster:vm lifecycle & capacity — Ease L · Risk M

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #392 | Never attempt a disk shrink | L | L | **Closed 2026-09-26 — already fixed:** the converge adopts a larger actual size (ADR-020 D9); `update-disk.sh` refuses a shrink (exit 20), `--force` cannot override it |
| ✅ #393 | A failed migration must not block later steps | L | L | **Fixed 2026-09-26:** a failed `qm migrate` of a guest still running returns exit 11 — deferred, drift recorded, no rollback — instead of failing a healthy guest's update |
| ✅ #532 | Pending vs applied hardware changes | M | L | **Fixed 2026-09-26:** a held change (memory without hotplug) is read from `qm pending` and reported as deferred, not applied. Verified against ground truth on hrossen |
| ✅ #36 | VM shutdown timeout | L | L | **Closed 2026-10-08 — already met:** `pve-guests` stops each guest with its `down=` or 180 s, then a hard stop (`force-stop` defaults on); every TAPPaaS stop path passes a timeout. hrossen reboots: guests stopped in 4–33 s |
| ✅ #127 | Boot order: firewall (and secrets) first | L | L | **Closed 2026-10-08** (`fb461a1d`): a pre-start hookscript on every guest but the firewall waits until it answers DNS (180 s at most), so a cold start no longer boots guests without DHCP — `startup: order=` cannot do it (HA ignores it). `cluster` update Step 5d, Test 5d |
| ✅ #37 | Optimise RAM (ballooning, swap) | M | M | **Closed 2026-10-06, folded into #663** (operator): measuring is #663's sampler; no ballooning — right-sizing removes over-commitment; the ARC cap and swap are the Proxmox installer's |
| ✅ #423 | `Create-TAPPaaS-LXC.sh` has no `debug()` | L | L | Verified still missing — **Closed 2026-09-26** (`34508ed2`): the LXC creator defines the `debug()` it calls, as `Create-TAPPaaS-VM.sh` does. The same trap elsewhere is #747 |
| ✅ #753 | A guest restarting during its own update fails the sweep | M | L | **Closed 2026-10-08** (`2fe116df`): the "restart" was the rollback, which also erased the guest's journal; what failed was one SSH attempt seconds after the OS update. update-os now waits until systemd on the guest has no queued job after a switch or a reboot, and `cluster:vm`'s SSH check retries for 60 s and names ssh's own error before it reports drift |
| ✅ #793 | A live migration leaves a FreeBSD guest's agent dead (firewall) | L | L | **Closed 2026-10-07** (`4543af5f`): the network update adds `-r` to the firewall's qemu-ga via `/usr/local/etc/rc.conf.d`; agent answered after live migrations both ways on hrossen |
| ✅ #773 | `cluster:vm` thinDisk — opt-in thin provisioning per module | M | M | **Closed 2026-10-04.** `thinDisk: true` keeps a module's disk thin on its storage and on the HA replica (immich first: 500G that takes what the library uses). Watch the pool — a thin disk can overcommit it |
| ✅ #764 | The Proxmox VM summary note links "Discussions": make the links docs, code, issues | H | L | **Done 2026-10-07.** The note `cluster:vm` writes on a new VM: the turtle (the old logo URL was dead), then *docs* (tappaas.org), *code* (the module's own directory in the repo) and *Issues*. Existing VMs keep their note |

#### G3.2 Identity & SSO wiring — Ease M · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #282 | forgejo SSO (Community repo) | M | L | **Done 2026-10-06** (`b3c19be6`, `115328ca`), live on hrossen: `identity:identity` + `forgejo-configure-oidc` keep one `authentik` login source (groups claim `admin` for `forgejo-admins` → site admin); `ROOT_URL` from the published name; local sign-up off, first SSO login creates the account; `tappaas-admin` is the local break-glass admin. The live test also found every nightly backup failing (user `git` never existed) — fixed |
| ✅ #738 | `identity:identity` discovery check fails on a changed host key and blames the firewall | L | L | **Closed 2026-09-25** via `integrate/nc35` (`c998ca5f`): the stale host key is cleared before the OIDC check, and an ssh failure is named as one. Reported by @AndreasJe |
| ✅ #797 | identity: an update skips Authentik release lines when the guest is built on the mothership | M | M | **Closed 2026-10-08** (`fc8383f8`, `68c4af51`): the step logic read guest files the mothership build cannot see, so every guest looked fresh and jumped to the target (Nextcloud majors too). `build-facts.sh` now reports the version — from the record, else the server container — staged as `/etc/nixos/tappaas-build-facts.env`; missing or unknown facts stop the build before it switches; no step below the running container; a refused version ends the wait in a minute, not 45. Reported by @ErikDaniel007; live on hrossen |
| ✅ #752 | identity:accessControl has no test-service | M | L | **Done 2026-10-09** with #805 (`d08e8d21`): `test-service.sh` checks the proxy app and its provider on the embedded outpost, a group binding, Caddy's ForwardAuth, and that an anonymous request gets the Authentik login; a 403 from the zone filter is a warning. Failed on jellyfin before the change, passes after (hrossen) |
| ✅ #805 | jellyfin: put the published instance behind Authentik forward-auth | M | M | **Closed 2026-10-09** (`d08e8d21`, `328a2581`, `16b55013`), live on hrossen: Jellyfin was reachable from the internet behind its own login only. `identity:accessControl` after `network:proxy`; accessControl now binds `users` (it bound nothing, so every Authentik user passed). **Browser only:** native TV/mobile apps cannot pass forward-auth, and Jellyfin's Service zone takes pinholes from `dmz` only — apps return with an ADR-023 path bypass. OIDC SSO plugin alone rejected (archived upstream, leaves the API open) — added behind the gate in #806 |
| ✅ #806 | jellyfin: sign in with Authentik (SSO-Auth plugin behind forward-auth) | M | M | **Closed 2026-10-09** (`7d7a10ec`, `8dc3a15a`, `e5d67560`, `5124e2bb`, `e3c71779`, `7ff29db5`), live on hrossen, browser sign-in confirmed: after #805 Jellyfin still asked for its own password. SSO-Auth plugin 4.0.0.4 (pinned store path) + `jellyfin-configure-oidc` give "Sign in with Authentik"; the Authentik tile goes straight in; `jellyfin-admins` → Jellyfin admin. ADR-006 §4 exception: gate and OIDC on one app, the gate as hidden `<module>-gate`. Found on the way: `app-delete` detached every app's provider from the outpost; network:proxy's update dropped `proxyPreserveHost`/`proxyUpstreamHttp1`; and every proxy reconcile wrote ForwardAuth=0, leaving a gated module open until accessControl re-ran (now kept; 98/98 probes gated through an update). Limitation: an Authentik user named `admin`/`stream`/`local` would get that local account |
| ✅ #794 | The groups claim mapping uses `User.ak_groups`, deprecated since 2026.2 | L | L | **Closed 2026-10-07** (`b7b5d242`): the mapping reads `user.groups` (same groups for all users); forgejo and nextcloud re-applied on hrossen, no deprecation |
| ✅ #769 | vaultwarden: SSO is registered but never wired into the app | M | L | **Closed 2026-10-04** (SSO wired, `e184ea9d`). **Reversed 2026-10-06, vaultwarden 0.6.0:** no SSO for the password vault, by decision — see vaultwarden DESIGN.md |
| ✅ #779 | identity: `authentik-env-secrets-only` calls `cmp` without diffutils | L | M | **Closed 2026-10-06** (`3f34f63e`): `! cmp` was always true, so the clean `authentik.env` was replaced and logged every boot. Live-tested on hrossen |

#### G3.3 App module fixes — Ease L · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #51 | Immich | — | — | **Closed 2026-10-06.** In `src/home/immich`: Immich 3 from pinned nixos-unstable, 500G thin disk under `cluster:ha`, OIDC; live-tested on hrossen, status Testing. Failover untried |
| ✅ #808 | euro-office: test.sh fails a healthy DocumentServer, 50 s too short | L | L | **Closed 2026-10-09** (`6e553818`), live on hrossen: the post-rollback test ran straight after the snapshot restore, with no readiness gate; it now waits for the guest and `ready.sh` like the post-update test. Tests 4 and 4b poll up to 180 s (Test 4 probed `/` once and failed a 1 s old container). A forced rollback passed its test. Reported by @ErikDaniel007 |
| ✅ #283 | forgejo central logging (moved to `src/devops`, 2026-10-04) | L | L | **Closed 2026-10-06** by #770: `forgejo.json` declares `integratesWith: logging:logs`; the baseline journal client ships it. Forgejo was not installed on hrossen when #770 rolled out — its next install is its own test |
| ✅ #786 | identity, litellm: containers get SIGKILL on every stop (10 s timeout) | L | M | **Closed 2026-10-06** (`b7af4b14`): worker `--stop-timeout=90` (drains 16-32 s); litellm `--init`, as PID 1 it ignored SIGTERM while starting. Live-tested on hrossen |
| ✅ #743 | nextcloud:fileservice test contradicts euro-office UPGRADE.md | L | L | **Closed 2026-09-26** (@ErikDaniel007). Added to the roadmap 2026-10-07 |

#### G3.5 Installer UX — Ease L · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #405 | Do not ask for tanks without free disks | L | L | **Closed 2026-10-08** (`e46f0429`): the installer skips a pool when no disk is free — a disk in an imported pool is no choice, an old unimported label still is |

### Wave 4 — additive capabilities

#### G4.1 Alerting & cluster resilience — Ease M · Risk M

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #126 | Alerting from Loki through the #651 channel (was: no alerts for quorum loss / node dropout) | M | M | **Closed 2026-10-04.** Grafana alerting from Loki: 9 rules, mailed via `site-notify.sh`, heartbeat watchdog; all fired live on hrossen. Follow-up: app VMs ship no logs (#770) |
| ✅ #165 | logging v2: Loki auth, Grafana OIDC | H | M | **Closed 2026-10-06** (`f69d536e`, `48cc4683`), live on hrossen: nginx fronts Loki — 3101 push only with a credential per VM (username = vmname; `host` is set from it, so a VM writes as itself only), 3100 Loki's API behind an admin credential held by the mothership; Loki and Alloy on localhost. Grafana OIDC (#513), the OPNsense syslog target and the consumer hooks (#770) were done before. TLS moved to #787, version pins re-scoped as #788 |
| ✅ #788 | Release train: flag a major version change at a pin move | M | L | **Done 2026-10-08** (`93f535f7`), broadened from Loki/Grafana to every package that runs: `tappaas-train preview [--to <release>]` evaluates the guests against the next pin in about a minute (nothing built) and reports major version changes and critical/high CVEs introduced, kept and fixed; `ack` accepts them; a boundary checks the pin it takes right after moving it — before the deep test — and stops on anything not accepted. Accepted items are recorded on the release. **Extended 2026-10-08:** the preview compares the last release with "if released now" per module — NixOS modules and container images alike, today's CVE database on both sides (now, then in the release, fixed, new, same; the platform as now only). **VEX 2026-10-09** (`c7e734f1`, `dc5c8be4`, `a826cc0e`): the preview and the nightly scan apply the same committed triage; a module's `<module>-vex.json` decides for its own targets only, `templates-vex.json` for every one (ADR-011 §8). Statements written for the shared baseline (wpa_supplicant also turned off on every guest) and for identity, nextcloud, nextcloud-hpb, immich, jellyfin, logging, euro-office, deconz and the mothership — pinned to the analysed versions, so a version change asks again. If released now, most modules carry only glibc and vim; still counted: Authentik's libxml2/urllib3 (5, low), jellyfin's ffmpeg (10), diyHue's image (5, low). The scan now matches ffmpeg forks: `jellyfin-ffmpeg`, the ffmpeg Jellyfin runs, had no findings (#804, closed: `8a138cb1`, `de7ec83c`). **Reporting 2026-10-09** (`d4d8ee15`, `c628ed2b`, `573e9bf5`, live on hrossen): the firewall's CVEs get a severity (VuXML has none — it showed 0 of 29 critical/high); kernel headers and compilers count apart (tappaas1/2: 990); the nodes are one `cluster ×3` row and backup has its own; the preview splits NOW into OPEN / RISK (analysed, `exploitable` with its risk here) / ACK (`ack --module`, acks add up), the shared baseline is one row and the mothership is compared; CVEs named in nixpkgs `patches` count as resolved (64 on hrossen); records with no version range are flagged; `cve-triage.sh` lists a module's open CVEs and writes the decisions |
| ✅ #770 | App VMs do not ship their logs to Loki | M | M | **Done 2026-10-06**, live on hrossen: every NixOS VM integrating `logging:logs` ships its journal from one renderer (`lib/log-shipping.sh`) to a push-only `:3101`; Loki's `:3100` stays mgmt-only |
| ✅ #784 | Loki stores receive time — backfill and reboot entries collapse | M | L | **Closed 2026-10-07** (`cc997ea3`): logging's push receiver restamped lines on arrival (and doubled re-sent ones); `use_incoming_timestamp = true`. Proven on hrossen |
| ✅ #785 | Container stderr is labelled severity=error regardless of level | L | L | **Closed 2026-10-06** (`lib/log-shipping.sh`): a container line naming its level (JSON, `level=`, `\| INFO \|`, `[ERROR]`) sets severity; new `container` label. Live on hrossen |
| ✅ #774 | Build guest systems on tappaas-cicd — guests neither evaluate, compile nor download | H | M | **Closed 2026-10-06.** NixOS guests are built on the mothership in a mount namespace and copied over (`a0a4b66e`); offline and release-move proven on hrossen. Guest sizing continues in #663 |

#### G4.2 Proxy & ingress — Ease M · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #778 | `network:proxy` publishes names with no public DNS record: failing ACME, dead SSO tiles | M | L | **Closed 2026-10-06.** On a per-service site a name without a public A record gets no Caddy route (Caddy retried ACME on every reload) and no Authentik app (a dead tile); an existing one is withdrawn on update. Live on hrossen: logging, network and unifi-os unpublished, ~46k failed ACME lines stopped |
| ✅ #809 | `network:proxy` update keeps the old domain after a `proxyDomain` change | M | L | **Closed 2026-10-09** (`525ac696`), live on hrossen: since #495 a change reaches only `update-service.sh`, which had no prune, so the old name stayed in Caddy and served a blank page. One `proxy_prune_domains` for install, update, proxyRoutes and unpublish; it also removes the old name's Unbound override, only when that override carries the module's description. The proxy test fails on a leftover domain. Reported by @ErikDaniel007 |

#### G4.3 Manager verb gaps — Ease M · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #759 | `backup-manager`: no verb to take a module's backup now | L | L | **Closed 2026-10-02.** `backup-manager backup <module>…`: the covering job's storage and mode, VM or container, names the snapshot or fails. Live on hrossen (coturn, vllm-amd) |
| ✅ #739 | After reinstalling a provider, `dependsOn` consumers stay unwired | M | M | **Closed 2026-09-25** via `integrate/nc35` (`c998ca5f`): a (re)installed provider re-wires its `dependsOn` consumers, not only `integratesWith` ones. Reported by @AndreasJe |
| ✅ #789 | `backup-manager`: no verb to delete a module's restore points | M | L | **Done 2026-10-07**: `backup-manager purge <module\|vmid>` (and `backup-controller purge <vmid>`) shows the restore points, asks you to type the VMID (or `--yes`), deletes the group `vm/<vmid>` (root namespace only) and starts GC. Refuses a deployed module's VMID, one a job lists, or when the cluster cannot be asked. `delete --remove` now says how many restore points remain; RESTORE.md §11 |
| ✅ #790 | `environment-manager delete` leaves the env's DNS override, cert and refid | M | L | **Done 2026-10-07**: delete also removes the `*.<domain>` Unbound override(s), the `cert-refids.json` entry and the ACME certificate with its Trust certificate (new `acme-manager delete`); never a domain another env uses, nor the shared ACME account/validation/action. `--check` plans; the output names the public DNS records only the operator can remove |
| ✅ #791 | `network-manager delete` leaves the zone in other zones' lists | H | L | **Done 2026-10-07**: delete strips the zone from every other zone's `access-to`/`pinhole-allowed-from` before its reconcile, so one run converges and `validate` stays green; `--check` names the zones. `retire` and `delete` share the helper |

#### G4.4 Storage & physical devices — Ease H · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #388 | `cluster:storage` (NFS first) | H | L | **Closed 2026-10-06:** met by `storage:nfs` (ADR-029, built in #766, live with Jellyfin's share on hrossen). Remaining work: #772; NFS over TLS: #771 |
| ✅ #766 | Implement ADR-029: NFS service (`pvehost:nfs`) | — | — | **Closed 2026-10-04:** node exports, guest mounts, the two-key check and its firewall rule, plus the `validate` check; live on hrossen. TLS deferred (#771), the rest in #772 |
| ✅ #792 | `unifi.sh`: whole API payloads as jq arguments fail on large sites | H | M | **Done 2026-10-07**: interrogate (switch, controller, AP) and the port-override builder pass payloads by file (`--slurpfile`), never argv — Linux caps one argument at 128 KiB. Reproduced offline with a 165 KiB device list (old: "Argument list too long"; new: same answer as small) |

#### G4.5 Governance, CI & sign-offs — Ease M · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ FW #143 | CVE tracking / SBOM (ADR-011) | M | L | **Closed 2026-09-27 — built.** ADR-011 v0.5 Proposed: `health-manager scan/report security` after every sweep, a WARN-only `cve-status` gate, notice on what is new |
| ✅ #746 | Emergency patching as ADR-028 D12 describes it | M | L | **Closed 2026-10-08** (`3f732eb9`): `tappaas-train patch` (built under D13) now requires `--why` to name its D12 case; the next boundary records the urgent fixes it supersedes; `status` and the self-check report code running ahead of the checkout (`lib/deployed-drift.sh`). Production moves stay the operator's, by hand (D12). Live on hrossen |
| ✅ #747 | A script that defines its own logging set must define all of it, `debug` included | L | L | **Closed 2026-10-08** (`fb557bbc`): the 24 scripts with a private `info`/`warn`/`error`/`die` set and no `debug` define it; `scripts/test/test-log-set-lint.sh` (Test 9z) checks definitions, so the 25th cannot land |

### Future Work

| # | Issue | Note |
|---|-------|------|
| ✅ #11 | NextCloud | **Closed 2026-10-06:** a TAPPaaS module, `src/collaboration/nextcloud` |
| ✅ #12 | HomeAssistant | **Closed 2026-10-06:** a TAPPaaS module, `src/home/hass` |
| ✅ #52 | Jellyfin | **Closed 2026-10-06:** in TAPPaaS at status Testing, media on a `storage:nfs` share, installed on hrossen |
| ✅ #93 | App-level backups to PBS as pxar archives | **Closed 2026-10-06:** what `backup:filesystem` does (`proxmox-backup-client`) |
| ✅ #98 | Create the DevOps stack | **Closed 2026-10-06:** `src/devops`, with forgejo moved from Community and live-tested |

## Release 2.1 — staging 2026-09-25 · production 2026-10-10

Tag `v2.1` (`83ccb49837d1`), the first release-train boundary (forced), numbered retroactively on
2026-10-02 when versions were introduced. Estate pin: nixpkgs `c508844df6c2` (nixos-26.05). 718
commits after 2.0. Much of it is already in production: `stable` moved on to `d796e254` (2.0+466)
on 2026-09-18, before versions existed.

What it delivered: **Wave 0 complete** — a versioned config-migration runner with backup, dry-run
and a ledger (ADR-025); honest pre-update gates; scheduled updates on a channel with an email
when a sweep fails (ADR-017); a 3-way merge that can no longer skip a module silently. **Most of
Wave 1** — the ADR-022 vocabulary (`kind`, People → Identity); managed machines as modules
(ADR-026: `debianhost`, `module adopt`, `pvehost`) and the backup placement model (ADR-012 v1.0);
the module contract (`moduleSource`, the module catalogue, version/status claims, `move-module.sh`);
site-wide time zone, locale, keyboard and time source on every guest; the move to NixOS 26.05,
staged for the next boot; mothership keys that can be reissued and revoked, and key-only SSH on the
nodes. Plus a first set of Wave 2–4 fixes.

The rows below are what it carried, by the wave and group they came from.

### Wave 0 — make upgrades safe

<a id="rel21-g01"></a>

#### G0.1 Migration & rollback framework — Ease H · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #652 | Versioned config-migration step | M | L | Ordered, idempotent `migrations/NNNN-*.sh` with backup, dry-run and a ledger in `config/`; a failed migration stops the sweep before any module update (ADR-025) |
| ✅ #584 | Rollback in install/modify | H | L | `modify` Step 0 rewrites config before the snapshot and tests; snapshot `config/<module>.json` together with the VM |
| ✅ #453 | `--force` overwrites deployed config | M | L | **Decided 2026-09-16:** `add --force` refuses on a deployed module and names `module update` / `add --reinstall`; only `--reinstall` overwrites a deployed config (ADR-020 v0.10 D5) |
| ✅ #655 | `module-manager update` verb | M | L | The release update gets its own word; `modify` is the field change. Bare `modify` stays an alias for one release (ADR-020 v0.10 D5) |
| ✅ *(with #655)* | one meaning for `--force` | M | L | `--force` = proceed (failed pre-update test, archived/external) at every level; downtime is `--allow-disruption`; `--ignore-test-failure` retired (ADR-020 v0.10 D8, ADR-017 v0.3 D5) |
| ✅ #648 | `--unset` for stale fields | L | L | Option 2 chosen (2026-09-14): `--unset`, deep test, README |
| ✅ #572 | repo-sync auto-stash never restored | L | L | Pick pop or drop; warn with count |
| ✅ #727 | `module-manager`: `--allow-disruption` reaches services that reject it | — | — | **Closed** (@ErikDaniel007): disruption consent travels as `TAPPAAS_ALLOW_DISRUPTION=1` in the environment, so services that reject unknown options no longer roll a healthy module back |

<a id="rel21-g02"></a>

#### G0.2 Trustworthy gates — Ease L · Risk L

Tests that tell the truth, so every later migration can be verified.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #644 | `network-manager <verb> --help` runs the verb | L | L | **Do first.** `distribute --help` pushed zones.json for real (2026-09-14). Still open: `main.ts` checks only `argv[0]` |
| ✅ #635 | Pre-update gate collapses test severity | L | L | exit 1 → warn and proceed; the post-update test fails only on new failures, with a `TEST-WARN:` line for old ones (ADR-020 v0.8 D8) |
| ✅ #633 | `site-manager update --force` overrides every `rebootOk` | M | L | Fleet-wide reboot authority from one flag. Decided 2026-09-15: `--force` = run now, respects `rebootOk` (ADR-020 v0.8) |
| ✅ #636 | backup:vm Check 1 fatal while a backup runs | L | L | Timeout → "unknown", not fatal |
| ✅ #555 | network:proxy checks cannot fail without a refid | M | L | |
| ✅ #560 | identity:identity never checks the consumer side | M | L | Stricter test: existing silent SSO gaps turn red on first run (expected) |
| ✅ #620 | Tier lattice authored on 9 of 26 zones | L | L | The check reports coverage. `tier` drives no rule; the repo already tiers every non-exempt zone, the untiered ones are site-local (retire them, or `modify <zone> --set tier=`), so no migration |
| ✅ #645 | Reconcile dry-run hides firewall rule changes | L | L | Needed before the Wave 2 rule changes |
| ✅ #689 | Service tests cannot tell an absent pinhole from one never requested | — | — | **Closed 2026-09-21** (`cdc78215`). Added in the 2026-09-24 issue sweep |

<a id="rel21-g03"></a>

#### G0.3 Update channel & failure notice — Ease M · Risk M

A scheduled update on a channel, with a mail when a sweep fails — the path every later fix takes to a site.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #471 | ADR-017 update scheduling | M | M | Replaces the update unit on every cicd; mind the first-activation bootstrap gap (Erik, 2026-08-19) |
| ✅ #447 | site-manager cannot modify the schedule | L | L | |
| ✅ #651 | A failed sweep notifies no one | M | L | Adds a site-level notification target (additive schema); #126 reuses it |
| ✅ FW #357 | Define `updateWindow` / `updateChannel` | L | L | Roll in: design only, belongs next to ADR-017 |
| ✅ #653 | Hold the scheduled pull on one site | L | L | A per-repository marker with a reason and an expiry makes the scheduled sweep skip the pull, so the test site runs unpushed work through real sweeps; an expired hold warns and pulls |

<a id="rel21-g04"></a>

#### G0.4 Merge trust

A 3-way merge that can no longer skip a module silently, so Wave 1's re-schemas reach every deployed config.

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #659 | Step 0 skipped when a config has no `.location`, update still reports success | L | M | An unresolvable location, a missing merge script and a failing merge were all logged and followed by `exit 0`. Now resolved through the catalogue too, and all three are fatal |
| ✅ #688 | The 3-way merge reports adopting fields it does not write | — | — | **Closed 2026-09-21** (`687a363f`). Added in the 2026-09-24 issue sweep |

**Landed 2026-09-17** (bdf15dcf, 51d1bae3), once makerfloss's satellite was marked
`status: external` — see below. Measured before landing:
hrossen's 13 modules all resolve via `.location`, so the change is a no-op there.
On makerfloss exactly one module is affected — `satellite-satellite1`, which has
neither a `.location` nor a catalog entry and would REFUSE after this lands.
(`portainer-lab1` also has a broken `.location`, but it is `status: archived`
and the archived check sits *before* Step 0, so it never reaches the new fatal
path — an earlier note here said otherwise and was wrong.)

The satellite config is not a module config at all: it is a host record written
by a documented manual copy step in `src/foundation/satellite/install.sh`
("Copy satellite.json -> ~/config/satellite-<name>.json and edit it"), which is
why it has no `.location` — the installer that would have recorded one was
bypassed by design. It is therefore fixed by the satellite conversion (G1.2),
not by this issue. Unblocked 2026-09-17 by marking it `status: external`, which the archived/external
check skips before Step 0 — semantically true today, since the config is
created outside the module lifecycle. Recording a `.location` instead was
rejected: it would make satellite PARTICIPATE, and `reconcile` would then call
`satellite/update.sh` with the module name `satellite-satellite1` while
`satellite-manager` knows the satellite as `satellite1` — trading a silent skip
for a nightly failure. The real fix stays the G1.2 conversion, which removes the
`status: external` again.

The branch also carries the inverse of the effective-name rule (76e27d9c): a
deployed `podman-lab1` resolves to `podman` because `lab1` is a DECLARED
environment, while `vllm-amd` stays whole because `amd` is not — the declared
environment set is what makes that decidable, since module names contain
hyphens too.

### Wave 1 — the breaking-change window

<a id="rel21-g11"></a>

#### G1.1 Vocabulary & classification (ADR-022 family) — Ease H · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #624 | ADR-022 review comments | M | L | **Applied 2026-09-17** in Erik's PR #664 — close |
| ✅ #637 | ADR-022 comments (second pass) | L | L | **Applied 2026-09-17** in PR #664 (changelogs cut, Appendix A removed, `kind` defined, 022e–h proposed) — close |
| ✅ #610 | Site = administrative domain × location × zone | M | L | **Decided**: ADR-022a separates the Administrative Domain, 022b the Location; the zone dimension stays ADR-014's. Close on the decision; anything left is implementation under #611 |
| ✅ #611 | `kind` values; retire `external-host` (ADR-022d/f) | H | H | **Implemented 2026-09-18** (`21e3adc7`, migration 0004): every module authors its `kind`; the `kind: module` marker retired; `external-host` → `machine` |
| ✅ #599 | Glossary: node vs host vs cluster member | L | L | **Done 2026-09-18**: ADR-022c D1/D2/D3 restore `Node` to its ArchiMate meaning and add **cluster member** and **Host**; `GLOSSARY.md` §B now carries all three — close |
| ✅ #628 | People → Identity (`people-manager` → `identity-manager`) | H | H | **Implemented 2026-09-18** (`5d15c7f9`, migration 0005): `people-manager` → `identity-manager`, `config/people/` → `config/identities/`; aliases for one stable cycle |
| ✅ #422 | Glossary rewrite | M | L | **Done 2026-09-18**: `GLOSSARY.md` rewritten to the ADR-022 vocabulary, with a §E "what changed" table for reviewers — close |
| ✅ *(in #624)* | `module.tier` → `stack`? | M | H | **Answered 2026-09-17 (ADR-022e):** `module.tier` becomes `scope: site \| environment`, not `stack`; `tier` stays only as `zone.tier` |
| ✅ #707 | ADR-014: zone.tier has no stated relation to IEC 62443 levels | — | — | **Closed 2026-09-23** (`972e5c22`). Added in the 2026-09-24 issue sweep |
| ✅ #708 | ADR-004: stack is defined three times, with three value sets | — | — | **Closed 2026-09-23** (`469ce9a3`). Added in the 2026-09-24 issue sweep |
| ✅ #669 | `module-manager list` and other verbs should handle `Kind` | — | — | **Added in the 2026-09-25 issue sweep.** **Closed.** Part of the ADR-022d `kind` work with #611 |

<a id="rel21-g12"></a>

#### G1.2 Backup placement model + managed machines (ADR-012, ADR-026) — Ease M · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #780 | `debianhost` module + `module-manager module adopt` | M | L | **Built 2026-09-18:** a `debianhost` module (verify, apt upgrade, test) and `module adopt` (reach by key, learn OS, register). Live on hrossen; leftovers split into #755, #756, #757 |
| ✅ #781 | ADR-012 topology §1.3 verified | M | L | **Verified 2026-09-19** on hrossen: a PBS on a non-member machine adopted from an empty placement, patched by its `debianhost`. Installing PBS onto a bare machine stays manual |
| ✅ #782 | instance vs module name | M | M | **Implemented 2026-09-18** (`8439c54f`, ADR-026 D6.3/D6.4): an instance's module is its source directory, not its name; `module add --instance NAME`. Unblocked #665 |
| ✅ #665 | Register cluster nodes as machine modules | M | L | **Stage 1 built 2026-09-19:** module `pvehost` — each Proxmox node a registered instance, no change on the node. Stages 2–3 (patching, installs through the module) are separate |
| ✅ #670 | Satellite as a module: retire `satellite-manager` | M | M | **Closed 2026-09-20:** the satellite is a module (`module add satellite`, managed, patched by the sweep, `--lockdown`, `--decommission`); `satellite-manager` retired. Live test: #671 |
| ✅ #783 | `placementState` revisit | L | L | **Answered 2026-09-18:** ADR-012 v0.9 settles backup (`node` \| `shim` \| `external`); in general `node` names an instance (ADR-026 D6.5). No separate decision needed |
| ✅ #691 | backup:filesystem ignores its schedule; every capture fires at once | — | — | **Closed 2026-09-21** (`a77c498c`). Added in the 2026-09-24 issue sweep |
| ✅ #435 | backup: pass the required module argument in the deep PBS check | L | L | **Closed 2026-09-26 — already fixed** by `a36538f2`: the deep check probes with `job-status` + `namespaces`. A fix without the issue number left both issue and plan stale |
| ✅ #712 | Retire the satellite's `--os nixos` path (unpinned, untested) | — | — | **Closed 2026-09-22** (`a1342322`). Added in the 2026-09-24 issue sweep |

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #602 | Empty `placementState` resolves onto the wrong host | L | H | **Built 2026-09-18** (`31bec1b2`): an empty state asks every candidate Host which holds the datastore and adopts it under its own name — no second PBS. 63 unit cases; live on hrossen |
| ✅ #600 | PBS on a non-cluster host | M | H | **Built 2026-09-19:** stored as `placementState: node` + `.node` = the Host (ADR-012 v1.0 §1.3); migration 0007 rewrites `node:<host>` |
| ✅ #612 | `vmname` → the instance name, as a DNS alias; `shim` stays | L | M | **Built 2026-09-19:** `dns-manager alias`; the PBS's name is the backup instance's, a CNAME of its Host renewed on every update; `vmname` gone from `backup.json` |
| ✅ #601 | Placement discovery is PVE-only | M | L | **Built 2026-09-19:** a machine Host is reached by `address` and its storage found from ZFS pools; install refuses a Host with only a pool. PBS onto a bare machine is not automated |
| ✅ #456 | `external` placement for a pre-existing PBS | M | L | **Finished 2026-09-19:** one verb, `backup-manager placement use-external <url>`; an update of an `external` placement fails, named, when its storage is missing |
| ✅ #607 | Exit from `external` placement | L | L | **Built 2026-09-18:** `placement reset` / `finish-reset` keep the old storage as `<name>_former` so history stays restorable, then onboard locally. Not rehearsed end to end (needs an external PBS) |
| ✅ #457 | `pbs_node` uses placement, not the registered name | L | L | **Built 2026-09-19:** the Host and the PBS name cannot diverge; every PBS ssh goes through `pbs_node_addr`, and `pbs_node` fails instead of guessing the first node |
| ✅ #603 | PBS on a non-PVE host has no update path | M | L | **Built 2026-09-19:** the Host's owner patches the PBS — the cluster module for a node, the machine's `debianhost` otherwise; install adopts an unregistered machine |
| ✅ #554 | Reconcile creates duplicate job coverage | M | L | **Built 2026-09-19:** coverage is asked of every cluster backup job; foreign jobs are reported, never duplicated blindly. New `backup-manager coverage <module>` |
| ✅ #609 | Off-site location recorded | L | L | **Built 2026-09-18:** `physicalLocation` on backup peers and satellites; `validate` warns about an off-site target not shown to be elsewhere. (`location` became `moduleSource`, 0006) |
| ✅ #605 | Split ADR-012 acceptance list | L | L | **Done in v1.0:** a Decision list (accepted) and an Implementation list (tracked in #407) |

<a id="rel21-g13"></a>

#### G1.3 Module contract & repo layout — Ease H · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #500 | Automate moving a module | H | M | **Built 2026-09-19:** `move-module.sh` moves the files, rewrites the catalogue and writes the `NNNN-modules-moved.sh` migration (ADR-025 D14). How to use: `MOVE-MODULE.md` |
| ✅ #349 | Drop the zone tag from released modules | M | M | **Built 2026-09-19:** `zone0: mgmt` dropped from the foundation modules (recorded at install); placed-by-role modules keep theirs; the merge keeps a deployed `zone0`. ADR-007c v1.5 |
| ✅ #566 | Legacy name → variant convention | H | M | **Built 2026-09-20:** `module modify <instance> --set instance=<new>` renames an instance (config, `.orig`, `.meta`, `node` references); the reported breakage was already gone (ADR-026 D6.3) |
| ✅ #248 | Module version/status standard | L | L | **Built 2026-09-20:** SemVer 0.x until someone else has run it; Development → Testing → Production, enforced by the classification lint. Absorbed into ADR-027 |
| ✅ #363 | Module lifecycle blueprint ADR | M | L | **Closed 2026-09-20:** [ADR-027 Module Blueprint](<docs/ADR/ADR-027 - Module Blueprint.md>) Proposed — the artifact set, a service's six files, one severity for all. The check is #674 |
| ✅ #463 | module-catalog schema is stale | L | L | **Built 2026-09-20:** the catalogue repeats nothing a module's JSON says — one flat `modules` list; `stack` decides what a module is; `site-manager repository validate-catalog`. ADR-004 amended |

<a id="rel21-g14"></a>

#### G1.4 Common NixOS baseline — Ease H · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #390 | 00-Template fails canon C4/C7 | L | L | **Closed 2026-09-24:** C4 already fixed (#446); C7: the template and the baseline declare the firewall explicitly, kept by `test-nixos-canon.sh`. Supersedes PR #391 |
| ✅ #448 | NIC rename race (kernel / udev / cloud-init) | M | H | **Closed 2026-09-24, through #324:** the baseline disables cloud-init's network stage, so NetworkManager alone names the NICs and they stay `ens18` (NixOS only) |
| ✅ #472 | NixOS clock two hours off | L | L | **Built and verified 2026-09-21:** each module had picked its own time zone; now the site fragment from `site.json` (#408), with #87 and #324, in one rebuild |
| ✅ #408 | Locale/keyboard: tappaas1 is the master | M | L | **Built 2026-09-21:** `site add` reads time zone, keyboard and locale from the first node; `.location` gained `keyboard`, `latitude`, `longitude`; PXE and USB installers use them |
| ✅ #87 | NTP on OPNsense, consumed by modules | L | L | **Built 2026-09-21:** the firewall already served NTP and nothing used it; each guest now syncs from its zone's gateway (NixOS fragment, Debian timesyncd drop-in) |
| ✅ #716 | A guest can boot into a 17–34 min window with no usable time source | L | L | **Closed 2026-10-04:** firewall ntpd fixed (`663e0c7e`), a second source where a zone has internet (`7f0a23df`), a back-off cap for gateway-only zones, and `NTPSynchronized` awaited after boot |
| ✅ #220 | Nix sandbox disabled on cicd | L | L | **Closed 2026-09-24**, nothing to remove: the workaround lived only in a site repo. Every mothership and guest builds with the sandbox on (checked on both pins) |
| ✅ #680 | The baseline `flake.lock` decides every site's nixpkgs | M | H | **Built 2026-09-21:** the mothership's rebuild names a pin that would move it backwards. Cadence answered by ADR-028: one estate pin, moved at each boundary, tripwire at 45 days |
| ✅ #699 | Guests created with `-localtime 1` boot two hours ahead | — | — | **Closed 2026-09-22** (`cd87f4dc`). Added in the 2026-09-24 issue sweep |
| ✅ #721 | promtail is removed in nixos-26.05 | — | — | **Closed 2026-09-24** (`15ca633f`) — replaced by Grafana Alloy; closed in this sweep. Added in the 2026-09-24 issue sweep |
| ✅ #722 | Grafana's `secret_key` has no default in 26.05 | — | — | **Closed 2026-09-24** (`c6e4db68`) — a per-site key beside the admin password; closed in this sweep. Added in the 2026-09-24 issue sweep |
| ✅ #726 | A release move leaves every Postgres guest permanently warning about collation | — | — | **Closed 2026-09-25:** after a release move, Postgres collation versions are refreshed in the sweep — each only after `bt_index_check` verifies that database's indexes |
| ✅ #728 | update-os: guests switch across a nixpkgs release and fail on exit 4 | — | — | **Closed 2026-09-24** (`0afac5d5`): a guest's release move is staged with `nixos-rebuild boot` and taken by the reboot, as the mothership does (#725). Likely root cause of #711 |
| ✅ #709 | Nextcloud cannot advance past 33 | — | — | **Closed 2026-09-24:** the pin is on 26.05 (`3e07ca7d`), which ships Nextcloud 33–35, and the train can move releases (`7b3af58f`). `ncMajor` is the maintainers' call |

<a id="rel21-g15"></a>

#### G1.5 Rebuild & recovery paths — Ease M · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #545 | Foundation backup + tested recovery (incl. `config/`) | H | L | **Done 2026-09-18:** ADR-012 D20 deployed — `network` and `tappaas-cicd` in the daily job; `config/` restore rehearsed (173/173 files, refused without the key). G1.5's exit gate met |
| ✅ FW #122 | Reissue **and revoke** tappaas-cicd SSH keys | M | M | **Done 2026-09-18:** `cicd-key.sh status`, `rotate` (new key proven everywhere, every other key revoked) and `recover` (through the guest agent). On hrossen: 18 stale root keys removed |
| ✅ #43 | Test and document backup/restore | M | L | **Closed 2026-09-24** as superseded: RESTORE.md is published as *Disaster Recovery*, each procedure labelled rehearsed or not; the rest went to #439, #407 and #729 |
| ✅ #710 | templates:nixos re-apply fails with no cause and rolls the VM back | — | — | **Closed 2026-09-22** as a duplicate of #711. Added in the 2026-09-24 issue sweep |
| ✅ #713 | The mothership cannot undo a bad rebuild | — | — | **Closed 2026-09-24** (`4024c510`, `c615f5dc`): the mothership checks itself after a rebuild and rolls back, bounded. The check's scope continued in #719 |
| ✅ #725 | A switch across a nixpkgs release reports failure and its rollback live-locks | — | — | **Closed 2026-09-24** (`6f9568bd, c615f5dc`) — a release move is staged with `nixos-rebuild boot` and a reboot; closed in this sweep. Added in the 2026-09-24 issue sweep |
| ✅ #719 | The control-plane self-check does not verify what it claims | M | M | **Closed 2026-10-03:** the self-check evaluates all 11 control-plane components and rolls back unless each is built at its implied path and linked from `~/bin` (ADR-028 D10) |

<a id="rel21-g16"></a>

#### G1.6 Secrets & privileged access — Ease H · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #19 | Disable SSH password login on PVE nodes | L | M | **Decided and live 2026-09-18:** every node key-only (`PermitRootLogin prohibit-password`, never `no` — PVE needs root over key), applied by `cluster/update.sh`, asserted by Test 4 |
| ✅ #378 | Default-on secret scanning on cicd | L | L | **Closed 2026-10-03:** gitleaks gates every release boundary (not every push); a pre-commit hook on the mothership. History holds old tokens — **rotate them**; rewriting history is the operator's call |
| ✅ #724 | The journal secret-scrub never worked (it redacted the key, not the secret) | — | — | **Closed 2026-09-23** (`eda1eb9d`) — secrets that reached Loki before the fix need rotating; see #715. Added in the 2026-09-24 issue sweep |

### Wave 2 — network behaviour hardening

<a id="rel21-g21"></a>

#### G2.1 Firewall exposure & rule order — Ease M · Risk H

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #682 | `rules_manager.py` reads the provider from `location`, not `moduleSource` | L | H | **Done 2026-09-21** (`0d0272d1`): the rules manager reads `moduleSource` (then `location`) — reading only the old field had deleted 24 live rules on Erik's site |
| ✅ #684 | `test-module.sh` fills its dependency set from `dependsOn` alone | L | M | **Done 2026-09-21** (`3948f7b1`): module tests walk `dependsOn` and `integratesWith`, so every auto-pinhole is verified — the blind spot behind #682 |
| ✅ #704 | network:proxy: aliasType and firewallType warn as orphans | — | — | **Closed 2026-09-22** (`c7dd7870`). Added in the 2026-09-24 issue sweep |

<a id="rel21-g22"></a>

#### G2.2 DNS resolver robustness — Ease L · Risk M

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #693 | An unpublishable name returns rc=0 where D5 expects 3 | L | L | **Closed** (`a4af3ee0`): a name that cannot be published exits 3, as ADR-021 D5 says, instead of 0. Found by the makerfloss deep sweep |
| ✅ #657 | Standard 4 invents an FQDN when a config lookup fails | L | L | **Done 2026-09-17:** the DNS sample carries each module's own zone instead of guessing `srvHome`, so the test stops asserting names the estate never declared |
| ✅ #702 | dns-manager add matches an entry by description, not by name | — | — | **Closed 2026-09-22** (`148b920b`). Added in the 2026-09-24 issue sweep |
| ✅ #703 | acme-setup: wildcard DNS is skipped when only the apex is unpublished | — | — | **Closed 2026-09-22** (`dd0a0763`). Added in the 2026-09-24 issue sweep |

### Wave 3 — stability & correctness

<a id="rel21-g31"></a>

#### G3.1 cluster:vm lifecycle & capacity — Ease L · Risk M

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #665 | Register cluster nodes as `kind: machine` modules | M | L | Stage 1 of ADR-026 D4 — registration only: existing nodes become instances of one module, after the instance work (ADR-026 D6). Built as `pvehost` — see G1.2 |
| ✅ #662 | PVE host configuration is not backed up | L | L | **Closed 2026-09-21** (`ffaf45fc`): a machine's own configuration (`/etc/pve`, network, ssh, root) is captured as `backup:filesystem`, so a cluster-wide loss is recoverable |
| ✅ #692 | A guest is built on `tanka1` whatever node it lands on | L | H | **Fixed 2026-09-21:** a guest's pool is resolved against its node (`tanka1` if active, else the node's first ZFS pool); a declared pool the node lacks is refused before any download |
| ✅ #686 | A backup lock fails an update that succeeded | L | L | **Closed** (`f8b528f6`): a VM held by a running backup is waited on and then deferred, never updated without its rollback snapshot |
| ✅ #679 | An immutable field's schema default can make a module unreconcilable | M | H | **Done 2026-09-21** (`37d2c04f`): a field still at its schema default whose change cannot apply is recorded as skipped, not as immutable drift needing a reinstall |
| ✅ #569 | Node capacity / overcommit verb | L | L | **Done 2026-09-17** (`71799221`): `health-manager validate` reports memory commitment per node (committed vs physical, `--memory-threshold PCT`) |
| ✅ #673 | Cluster nodes are a fixed list of nine, not a sequence | — | — | **Added in the 2026-09-25 issue sweep.** **Closed** |

<a id="rel21-g32"></a>

#### G3.2 Identity & SSO wiring — Ease M · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #698 | logging update fails on makerfloss: the mgmt environment has no domain | — | — | **Closed 2026-09-21** (`c1cdf960`). Added in the 2026-09-24 issue sweep |

<a id="rel21-g33"></a>

#### G3.3 App module fixes — Ease L · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #687 | OnlyOffice: the document server cannot download from Nextcloud | M | L | **Closed** (`d4d34aae`): the document server could not fetch from Nextcloud over the internal name, which has no TLS — users silently lost document editing |
| ✅ #412 | coturn reads an undefined `publicDomain` | L | L | |
| ✅ #622 | deconz probe uses a name that never resolves | L | L | Looks fixed on `main` (both services now resolve the deconz FQDN): verify and close |
| ✅ #714 | nextcloud:fileservice fails euro-office on a verdict the run could not make | — | — | **Closed 2026-09-23** (`287bad27`) — TTY, readiness gate, verdict from the check's own words, JWT leeway. Added in the 2026-09-24 issue sweep |
| ✅ #667 | `nextcloud:fileservice` declares no fields, so its connector is undefined | — | — | **Added in the 2026-09-25 issue sweep.** **Closed.** Sits with #714, the other fileservice defect |

<a id="rel21-g34"></a>

#### G3.4 AI stack maturity — Ease M · Risk M

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #690 | litellm VK provisioning has no readiness wait and discards the key | — | — | **Closed 2026-09-21** (`3358e3ec`). Added in the 2026-09-24 issue sweep |

### Wave 4 — additive capabilities

<a id="rel21-g42"></a>

#### G4.2 Proxy & ingress — Ease M · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #696 | A blocked client gets a blank page: access lists carry no message | — | — | **Closed 2026-09-21** (`5110a84b`). Added in the 2026-09-24 issue sweep |

<a id="rel21-g43"></a>

#### G4.3 Manager verb gaps — Ease M · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #681 | Auto-stash entries nothing lists or resolves | L | L | **Done 2026-09-21** (`ed6aa6a7`): `site-manager repository stash list/show/restore/discard` for repo-sync's kept stashes; the sweep names the oldest one's age |
| ✅ #672 | `module delete` of a machine leaves its dnsmasq Host entry behind | — | — | **Added in the 2026-09-25 issue sweep.** **Closed.** A delete that does not finish is a drift source |
| ✅ #730 | health-manager: no reboot verb, and pending reboots go unrecorded | — | — | **Added in the 2026-09-25 issue sweep.** **Closed** (@ErikDaniel007). A reboot that is not taken is now reported as a `DEFERRED:` line the sweep collects |
| ✅ #718 | module-manager: the dependency test misses an environment's provider | — | — | **Closed 2026-09-23** (`6bc1f92e`) — delete-module's reverse check fixed with it. Added in the 2026-09-24 issue sweep |

<a id="rel21-g44"></a>

#### G4.4 Storage & physical devices — Ease H · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #734 | ap-controller: an unfilled placeholder SSID reads as live drift | — | — | **Added in the 2026-09-25 issue sweep.** **Closed** (@ErikDaniel007). **#732 is the same issue filed twice** — both are closed; worth confirming one was closed as a duplicate rather than fixed twice |
| ✅ #733 | `unifi.sh`: one message covers four failure causes, and a `jq` crash | — | — | **Added in the 2026-09-25 issue sweep.** **Closed** (@ErikDaniel007). One error string for four distinct causes taught operators nothing; the `jq` crash made it worse |

<a id="rel21-g45"></a>

#### G4.5 Governance, CI & sign-offs — Ease M · Risk L

| # | Issue | Ease | Risk | Note |
|---|-------|:-:|:-:|------|
| ✅ #695 | The deep VM suite leaves a guest behind, and the next run fails on it | L | L | **Closed** (`e2dacf7e`): a leftover VM from an earlier deep run made the next run report a false rollback failure. Teardown is now checked |
| ✅ #694 | Service README field sections are stale | L | L | **Closed** (`93872f32`): the generated service field docs were regenerated, and the question whether a generated file may drift at all was raised |

---

## Release 2.0 — production 2026-07-21

Tag `v2.0` (`61e91f080e01`), tagged and released straight to `stable` before the release train
existed; 259 commits after 1.1. The forge milestones *Release 2.0: Build out Stacks* (33 closed)
and *Release 2.0 Documentation* (3 closed) tracked it; the rest of their issues moved into the
waves above.

**One model and a control plane.** The ADR-007 taxonomy, drafted during 1.x, implemented: one
**Site**, classified by People, Apps and Environments, with health as a cross-cutting concern.
The `tappaas-cicd` mothership gained the managers that run a site — `module-manager`,
`network-manager`, `people-manager` (now `identity-manager`), `environment-manager`,
`site-manager`, `health-manager`, `backup-manager`, `satellite-manager` — and the controllers
behind them: `opnsense-controller`, `proxmox-controller`, `identity-controller`,
`backup-controller`, `switch-controller`, `ap-controller` and the `node-provisioner`.

**Platform.** The firewall became the `network` foundation module (OPNsense zones, DNS, reverse
proxy); the optional **satellite** VPS for public ingress, off-site backup and an admin VPN
(ADR-010, with a Debian option); new nodes installed over PXE (`site-manager node add`); an
unattended install; and an operator runbook to migrate a 1.x site onto the new model.

**Website.** tappaas.org rebuilt and served from Codeberg (cutover 2026-07-21, the day of the
release).

New ADRs: ADR-003 (dependency management), ADR-012 (backup enhancement), ADR-013 (documentation
structure); the ADR-007 family implemented and reconciled with the as-built code.

## Release 1.1 — production 2026-07-12

Tag `v1.1` (`889c61a2c848`), the last 1.x release; 442 commits after 1.0.

**Stacks fill out.** The collaboration hub — `nextcloud`, `euro-office`, `coturn` and
`nextcloud-hpb` for Talk — the `deconz` Zigbee gateway, Home Assistant as a sealed appliance
(`hass`), and `windows-server`; LiteLLM credential management, vLLM model tooling and Open WebUI
0.10. **Foundation:** central `logging`; Authentik-based identity with users, groups, roles and
OIDC for modules (ADR-006); certificates through ACME.

**Design for 2.0.** The ADR series that 2.0 implemented: ADR-004 (module catalogue and config
cascade), ADR-005 (variants), ADR-006 (identity), the ADR-007 taxonomy family (007, 007a–f),
ADR-008 (switches and APs), ADR-009 (composition meta-model), ADR-010 (satellite), ADR-011 (SBOM).

## Release 1.0.0 — production 2026-04-13

Tag `v1.0.0` (`682b87ce3087`), *the first production-ready release of TAPPaaS*; 673 commits from
the first one (2025-05-10).

The first release: an automated installation of a self-hosted platform for a home or a small
business, running on real systems — Proxmox nodes, an OPNsense firewall, a NixOS template, the
`tappaas-cicd` mothership, backup with Proxmox Backup Server and Authentik identity as the
foundation; on top of it the first app modules: Home Assistant, LiteLLM, Open WebUI, vLLM on AMD,
Vaultwarden, the NetBird client and a UniFi controller. Zones are VLANs on trunk ports (ADR-001,
ADR-002).
