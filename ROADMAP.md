# TAPPaaS Roadmap

What we are building, in the order we build it, and what each release has delivered. The open
work is at the top; the further down you read, the more of it has already shipped. The bottom of
this file is the first release.

The current plan is **security and stability**: order the backlog so that the changes that break
or migrate an existing installation land first, while there are still few installations and few
community modules depending on today's names, schemas and layouts. It is built in **waves** — make
upgrades safe (0), make the breaking changes (1), harden the network (2), stability (3), new
capabilities (4) — each made of **groups** of related issues.

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
4. **The releases, newest first** — what shipped, grouped by the wave and group it came from.

Markers:

- **✅** in front of a row means done: the issue is closed on the forge, or the question in the
  row is answered. A ✅ row still in a wave is done on `main` and ships with the **next release**.
- A group heading says where its rows are: `released in 2.1: 8 · done for 2.2: 1 · open: 3`. A
  group with nothing left keeps its place in the wave with **✅ … released in 2.1** and a link to
  the release that carried it.
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

**When a release is cut** (a release-train boundary, [ADR-028](docs/ADR/ADR-028%20-%20Release%20Cadence%20and%20Patching.md)
D13): every ✅ row whose fix is in the new tag moves out of its wave into that release's section,
under the same wave and group heading, and the group's marker is updated. Which tag carries a fix:
`git merge-base --is-ancestor <commit> v<version>`.

### The scores

Every issue and every group has three scores. A group's **R is its riskiest item**, not an
average. **Wave** follows from R and L: R ≥ 4 with L = H goes in the breaking-change window
(Wave 1); the things that make those migrations survivable go before it (Wave 0).

**Ease (E)** — how cheap it is to build.

| E | Meaning |
|---|---------|
| 5 | trivial — under half a day, one file |
| 4 | small — 1–2 days, contained |
| 3 | medium — up to a week, several files, needs a test |
| 2 | large — multi-week or crosses managers/controllers; needs a decision first |
| 1 | very large or open design — new subsystem or rebuild procedure |

**Upgrade risk (R)** — what an *existing* installation goes through when the change reaches it
through `update-tappaas`.

| R | Meaning |
|---|---------|
| 1 | none — docs, tests, new opt-in capability; existing installs unchanged |
| 2 | low — tool/manager behaviour changes; deployed config and live state untouched; `git revert` is the rollback |
| 3 | medium — the sweep changes live state automatically (firewall rules, DNS, VM config, restarts); reversible, but a mistake is an outage |
| 4 | high — persisted config, schema, paths or CLI names change and must be migrated on every install; rollback needs a reverse migration |
| 5 | very high — needs rebuild, reinstall or renumbering of VMs/nodes, or can lock the operator out |

**Lock-in (L)** — the cost of waiting.

| L | Meaning |
|---|---------|
| H | gets more expensive with every new install or community module (names, schemas, paths, IDs, the module template) |
| M | the blast radius grows with installs, but the change itself does not get harder |
| L | no change over time |

### Test level by upgrade risk

How deeply a change is tested before it merges to `main`, by its R. Each level includes everything
above it. From `main` a change follows the release train ([RELEASE-TRAIN.md](src/foundation/tappaas-cicd/RELEASE-TRAIN.md)):
cut into `staging` as the next version, `stable` (production) one boundary later. Test site:
hrossen.dk, which runs `main`; staging site: makerfloss.

| R | Required before merging to `main` |
|---|-----------------------------------|
| 1 | Fast tier + deep test of the touched module/manager on the test system |
| 2 | Deep test of every consumer of the changed tool; the revert is a plain `git revert` |
| 3 | `network-manager reconcile` / `module-manager modify` dry-run diff reviewed (#645); applied live on the test system; one full scheduled sweep with no failure notice (#651) |
| 4 | Migration `--check`, then apply, against a **copy** of each site's `config/`; upgrade test on the test system from the current `stable`; restoring from `config/.migrations/backup/NNNN/` rehearsed once |
| 5 | Operator-initiated only, never in the unattended sweep; runbook rehearsed on the test system |

Standing rules: one branch per group, merged to `main` as a whole after its gate; a change that
renames or re-schemas anything under `config/` ships with its migration and a fixture test
(ADR-025); data-safety bugs skip the queue (ADR-028 D12); `stable` never moves backwards — a bad
release is fixed forward.

## At a glance

Per group: its scores, and where its rows are. *2.1* = shipped in 2.1; *2.2* = done on `main`, ships at the next boundary; *open* = still to do.

| Wave | Group | E | R | L | 2.1 | 2.2 | open |
|------|-------|:-:|:-:|:-:|---:|---:|---:|
| 4 | G4.1 Alerting & cluster resilience | 3 | 3 | M | – | 3 | 5 |
| 4 | G4.2 Proxy & ingress | 3 | 2 | L | 1 | – | 4 |
| 4 | G4.3 Manager verb gaps | 3 | 2 | L | 4 | 2 | 8 |
| 4 | G4.4 Storage & physical devices | 2 | 2 | M | 2 | 2 | 6 |
| 4 | G4.5 Governance, CI & sign-offs | 3 | 1 | L | 2 | 1 | 7 |
| 3 | G3.1 cluster:vm lifecycle & capacity | 4 | 3 | L | 7 | 5 | 8 |
| 3 | G3.2 Identity & SSO wiring | 3 | 2 | L | 1 | 2 | 6 |
| 3 | G3.3 App module fixes | 4 | 2 | L | 5 | 2 | 10 |
| 3 | G3.4 AI stack maturity | 3 | 3 | L | 1 | – | 6 |
| 3 | G3.5 Installer UX | 4 | 1 | L | – | – | 4 |
| 2 | G2.1 Firewall exposure & rule order | 3 | 4 | M | 3 | 4 | 13 |
| 2 | G2.2 DNS resolver robustness | 4 | 3 | M | 4 | – | 5 |
| 1 | ✅ G1.1 Vocabulary & classification (ADR-022 family) | 2 | 4 | H | 11 | 3 | – |
| 1 | G1.2 Backup placement model + managed machines (ADR-012, ADR-026) | 3 | 4 | H | 20 | 6 | 2 |
| 1 | ✅ G1.3 Module contract & repo layout | 2 | 5 | H | 6 | 2 | – |
| 1 | ✅ G1.4 Common NixOS baseline | 2 | 4 | H | 14 | 5 | – |
| 1 | ✅ G1.5 Rebuild & recovery paths | 3 | 4 | M | 7 | 9 | – |
| 1 | G1.6 Secrets & privileged access | 1 | 5 | H | 3 | 1 | 2 |
| 1 | G1.7 Parked for Erik discussion | – | – | – | – | – | 5 |
| 0 | ✅ G0.1 Migration & rollback framework | 2 | 2 | H | 8 | 1 | – |
| 0 | ✅ G0.2 Trustworthy gates | 4 | 2 | M | all | – | – |
| 0 | ✅ G0.3 Update channel & failure notice | 3 | 3 | M | all | – | – |
| 0 | ✅ G0.4 Merge trust | – | – | – | all | – | – |

---

## Planning items still open

### Decisions

| # | Question | Waits on |
|---|----------|----------|
| #294 | VMID scheme: zone-aligned ranges for new installs only, or not at all — never renumber in place | Lars and @ErikDaniel007 (G1.7) |
| #430 | Controller/manager pattern for app modules (Ansible first?) — decide before #170 | Lars and @ErikDaniel007 (G1.7) |
| #142 | AI-agent access to the mothership: SSH + sudo, or a REST API (which would need an ADR) | RFC outcome (G1.6) |
| #675 | What a managed repository may contribute to the control plane's own NixOS configuration, and what happens when that fails to build. Today a site's own host-level modules are dropped by every scheduled rebuild while the unit reports success (`tappaas-cicd.nix` has no extension point — confirmed) | An ADR first; E2 · R3 |
| #488 | `apply-json-merge`: should a field that `.orig` never recorded be adopted from the release, or kept? #736 made each refused value visible; the rule itself is open | Operator |
| #444 / #582 | What reading back a static DHCP reservation means (MAC pinning) — one question, not two | Lars and @ErikDaniel007 |
| #154 | Is `firewall:internal-proxy` needed at all? | Operator (questioned 2026-05-31) |

### Gates

What must be true before the named wave or group starts (entry) or reaches `stable` (exit). The
met gates are recorded in the releases that carried their waves.

| Wave · group | Still open |
|--------------|------------|
| 1 · G1.6 | #142 RFC outcome; a *Secrets management* ADR only once #58 comes back from Future Work |
| 2 | Entry: ADR-014 amended for the `all` sentinel (#375, built), `serves` as an array (#576), anti-spoofing always on (#159, built) and mDNS in zones.json (#257); ADR-021 amended for DNSSEC with split horizon (#263) and the IPv6 stance (#149). Exit: a lockout check on each site — mgmt and NetBird reach 8443 and 22, other zones do not; done on hrossen 2026-10-02 (NetBird untested there) |
| 3 | ADR-019 Proposed → Accepted (#36 / #127 boot order) |
| 4 | ADR-023 Proposed → Accepted (#642, #643; render check open); ADR-015 Draft → Accepted (#486); ADR-011 Proposed → Accepted (#143 built); ADR-010 P7 sign-off (#406); ADR-008 amended (#236); ADR-019 amended for a second corosync link (#590) and the migrate verb (#429); ADR-007e amended for logging v2 (#165), or a new ADR if Zabbix is chosen; ADR-029 Proposed → Accepted (#772); the MAC pinning question (#444 / #582); #154 closed or kept; #430 decided before #170 |

### ADRs still to write

| ADR | Covers | Gates |
|-----|--------|-------|
| Controller pattern for app modules | #430 (Ansible first); later #170 | G1.7, then #170 |
| Composite modules | #761: `cluster`, `kubernetes`, and modules that only provide artefacts (`templates`) — a `kind` for them; with @ErikDaniel007 | G3.1 |
| Control-plane extension | #675 | — |
| Secrets management | #58 (in Future Work since 2026-10-02): one secrets-access helper every module uses instead of reading `/etc/secrets`, OpenBao behind it later | G1.6, when #58 returns |
| VMID convention | #294 — only if it is adopted | G1.7 |
| Legal/processor | #359 | Wave 4 |

### Housekeeping

- **Merge pairs** the issues themselves say belong together: #36 + #127, #385 + #222,
  #160 + #256, #642 + #643, #444 + #582, #119 / #120 / #121.
- **Close or park:** #154, #223 → (#284 went to Future Work 2026-10-06)
  *Parking lot*. The forge's *Release 2.0: Build out Stacks* milestone still has 4 open issues —
  move them per this plan and close it.
- **Parked, half of #656:** a proxy access list kept current from a provider's published feed (an
  Azure service tag, say) is a subsystem, not a field — an outbound fetch on a schedule, a trust
  decision about a third party deciding who reaches a site, and a defined behaviour when the feed
  is unreachable or changes shape. It needs its own decision in ADR-023. The static CIDR half is in
  G4.2.
- **Tracked on the forge as open, built here:** FW #357, FW #122 and FW #143 are done in this
  plan's rows (2.1, 2.1, 2.2); close them on the forge.

---

## Future Work — not yet in a wave

**Roll in** — small, and cheaper done with the group they sit in:

| # | Issue | Group | Why now |
|---|-------|-------|---------|
| #162 | Firewall sequence-map artifact | G2.1 | Falls out of #160 / #645 |
| #83 | Reuse downloaded images | G3.5 | An installer change — but a cache location and staleness policy to decide (re-scored E2) |
| #40 | Sync-network recipe | G4.1 | Documentation half of #590 |

**Optional roll-ins:** #157 default DNS blocklists (G2.2, after #387), #158 multi-NIC module
firewall rules (G4.4), #39 power saving (docs).

**Moved out of a wave:**

| # | Issue | From | When |
|---|-------|------|------|
| #250 | `dependsOn` ownership for community modules (option D, `dependsOn.sh`) | G1.3 | 2026-09-20 (operator) |
| #58 | Secrets management (OpenBao) — the proposal stands: one secrets-access helper every module uses instead of reading `/etc/secrets`, OpenBao swapped in behind it later | G1.6 | 2026-10-02 (operator) |

**Close or re-scope:**

| # | Issue | Proposal |
|---|-------|----------|
| #11 | NextCloud | Close: `src/collaboration/nextcloud` exists |
| #12 | HomeAssistant | Close: `src/home/hass` exists |
| #71 | Backup of user data inside the VM | Re-scope: the `backup:filesystem` service exists; document it for app data |
| #93 | App-level backups to PBS as pxar | Same as #71 |
| #98 | Create the DevOps stack | Close, or keep as the stack epic: `src/devops` exists since 2026-10-04 with forgejo, moved from Community and live-tested |

**Parking lot** (on the forge, outside the waves):

| # | Issue | Note |
|---|-------|------|
| #488 | apply-json-merge pins fields the operator never changed | The general case of #736 — see *Decisions* above |
| #464 | migrate-firewall-to-network: dry-run reports a step it cannot predict | A dry run that overstates what it will do — the kind of thing that teaches an operator to distrust dry runs |

**Done, ships in 2.2:** #52 Jellyfin — closed 2026-10-06, in TAPPaaS at status Testing, media on a
`storage:nfs` share, installed on hrossen.

**Keep in Future Work:** #26 IPv6 (write the stance under #149), #284 forgejo SQLite → PostgreSQL (moved out of G3.3 2026-10-06, operator — SQLite stays the default until load says otherwise), #129 Project Nomad, #89 binary repository, #91 Backstage, #156 pfSense alias import, #170 LiteLLM
declarative state (decide with #430), #183 service catalog, #678 Windows guests' time zone (from
G1.4), #757 `debianhost` over PXE (ADR-026 D8a — `adopt` covers every known site), #771 NFS over
TLS (ADR-029 v0.7 — OpenZFS `sharenfs` cannot carry `xprtsec`).

---

## Wave 4 — additive capabilities

New capabilities with low upgrade risk.

### G4.1 Alerting & cluster resilience — E3 · R3 · L-M · done for 2.2: 3 · open: 5

Be told when something breaks, and survive more of it. Built: alerts from Loki by mail, every VM's logs in Loki. Next: a notice when a whole site goes dark (#776), Loki authentication (#165), a mail relay (#125), a second corosync link (#590).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #126 | Alerting from Loki through the #651 channel (was: no alerts for quorum loss / node dropout) | 3 | 3 | M | **Closed 2026-10-04.** Grafana alerting from Loki: 9 rules, mailed via `site-notify.sh`, heartbeat watchdog; all fired live on hrossen. Follow-up: app VMs ship no logs (#770) |
| #125 | Mail relay via M365 Graph API | 3 | 2 | L | |
| #165 | logging v2: Loki auth, Grafana OIDC | 2 | 3 | M | Turning on Loki auth breaks existing pushes unless clients change in the same sweep; since #770 every client comes from `lib/log-shipping.sh`, so the credential goes in one renderer |
| ✅ #770 | App VMs do not ship their logs to Loki | 3 | 3 | M | **Done 2026-10-06**, live on hrossen: every NixOS VM integrating `logging:logs` ships its journal from one renderer (`lib/log-shipping.sh`) to a push-only `:3101`; Loki's `:3100` stays mgmt-only |
| #776 | Report a site that has gone dark (outside heartbeat) | 3 | 2 | M | **Opened 2026-10-06** after makerfloss was dark 2½ days unreported. Proposed: the satellite mails when the home WireGuard handshake is >15 min stale. **Decide:** its mail path (#125?) |
| ✅ #774 | Build guest systems on tappaas-cicd — guests neither evaluate, compile nor download | 2 | 3 | M | **Closed 2026-10-06.** NixOS guests are built on the mothership in a mount namespace and copied over (`a0a4b66e`); offline and release-move proven on hrossen. Guest sizing continues in #663 |
| #590 | Second corosync link | 2 | 3 | M | |
| FW #40 | Dedicated sync network recipe | 4 | 1 | L | Roll in with #590 |

### G4.2 Proxy & ingress — E3 · R2 · L-L · released in 2.1: 1 · open: 4

Publish less of each app: limit a route to some paths (#642), some zones (#643) or a provider's source addresses (#656), as ADR-023 describes. Decide whether an internal proxy is needed at all (#154).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| #642 | Limit a route to paths | 3 | 2 | L | ADR-023, approved by Erik 2026-09-14 |
| #643 | Per-route allowed zones | 3 | 2 | L | Same ADR |
| #656 | Limit a route to a provider's source ranges | 3 | 2 | L | Split, folded into ADR-023: a route names explicit CIDRs (`remote_ip`) — an exposure reduction beside #642/#643. The provider-feed half is parked (*Housekeeping*) |
| #154 | `firewall:internal-proxy` | — | — | — | Close? Lars questioned the need (2026-05-31) |

### G4.3 Manager verb gaps — E3 · R2 · L-L · released in 2.1: 4 · done for 2.2: 2 · open: 8

The verbs operators otherwise do by hand: install a whole stack (#763), suspend a module (#428), migrate by changing `.node` (#429), `test` verbs (#499), private repositories (#634), module-level `--set` rules (#654). #444/#582 wait on a discussion.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| #763 | `module-manager add-stack`: install a stack's modules in `dependsOn` order | 3 | 1 | L | **Opened 2026-10-03:** the *solution* concept from #421 — install a stack's modules in order; refuses a missing outside dependency, skips installed ones, resumable, `--dry-run` |
| #428 | module-manager `suspend` | 3 | 2 | L | |
| #429 | Migrate by modifying `.node` | 3 | 2 | L | Relates to ADR-019 and #498 |
| #499 | `test` verbs on managers | 2 | 1 | L | |
| ✅ #759 | `backup-manager`: no verb to take a module's backup now | 4 | 1 | L | **Closed 2026-10-02.** `backup-manager backup <module>…`: the covering job's storage and mode, VM or container, names the snapshot or fails. Live on hrossen (coturn, vllm-amd) |
| #444 | IP → device lookup | 4 | 1 | L | Blocked on the MAC-pinning question (#582). **Do not implement (operator, 2026-09-26)** until Lars and @ErikDaniel007 have discussed it |
| #582 | Read back static reservations | 4 | 1 | L | **Do not implement (operator, 2026-09-26):** one question with #444, pending the same discussion. There is no `dhcp-manager`; read back means dnsmasq's own state |
| #634 | Private repositories in `repository add` | 5 | 1 | L | Adopt-mode: won't fix; document the deploy-key method |
| #654 | `module-manager`: the `--set` pre-gate ignores the module-level field declarations (ADR-020 D10) | 3 | 2 | M | ADR-020 D10 lets a module declare its own field rules; the `--set` pre-gate ignores them, so such a declaration is inert. Belongs with the ADR-020 verb work (#453, #655) |
| ✅ #739 | After reinstalling a provider, `dependsOn` consumers stay unwired | 3 | 3 | M | **Closed 2026-09-25** via `integrate/nc35` (`c998ca5f`): a (re)installed provider re-wires its `dependsOn` consumers, not only `integratesWith` ones. Reported by @AndreasJe |

### G4.4 Storage & physical devices — E2 · R2 · L-M · released in 2.1: 2 · done for 2.2: 2 · open: 6

Shared storage and the physical network as managed parts of a site: the rest of the NFS service (#772), a machine's zone enforced at its switch port (#668, #697), controller modules that register their devices (#731), device modules (#155).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #388 | `cluster:storage` (NFS first) | 1 | 2 | M | **Closed 2026-10-06:** met by `storage:nfs` (ADR-029, built in #766, live with Jellyfin's share on hrossen). Remaining work: #772; NFS over TLS: #771 |
| ✅ #766 | Implement ADR-029: NFS service (`pvehost:nfs`) | — | — | — | **Closed 2026-10-04:** node exports, guest mounts, the two-key check and its firewall rule, plus the `validate` check; live on hrossen. TLS deferred (#771), the rest in #772 |
| #772 | ADR-029 NFS: remaining work packages from #766 | 3 | 2 | M | Export backup, NAS servers, storage zone, LXC consumers, quota health, `show`/`purge`. **2026-10-05:** ADR-029 v0.8 (shares by name, pending mounts, `subdir`) built, smoke-tested |
| #155 | Modules for physical devices | 5 | 1 | L | Docs and examples only (Lars, 2026-05-15) |
| #668 | A machine's zone is recorded, not enforced | 2 | 3 | M | A machine's `zone0` says which network its physical NIC is cabled to, and nothing checks the switch port. Record switch and port per NIC, report VLAN drift. Decide with #697 |
| #697 | Node `lan` trunks and their switch ports are set once at install, maintained by nothing | 3 | 4 | M | Node trunks and switch ports are set at install and maintained by nothing; untagged mgmt survives on PVID 1 by accident. Five candidate fixes on the issue — **decide with #668** |
| #731 | Controller-architecture modules never register themselves, and inventory drift has no routine check | 3 | 2 | M | A controller plugin (`unifi-os`) installs without registering in `switch-controller`/`ap-controller`; inventory drift is never checked. Reported by @ErikDaniel007 |
| FW #158 | Multi-NIC module firewall rules | 3 | 1 | L | Optional roll-in |

### G4.5 Governance, CI & sign-offs — E3 · R1 · L-L · released in 2.1: 2 · done for 2.2: 1 · open: 7

The project's own machinery: CI runners (#415), community-health files (#486), the remaining sign-offs and ADRs (#406, #359), a tool for urgent patches (#746), a logging-function lint (#747), a service-desk spike (#63).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| #486 | ADR-015 community-health files | 4 | 1 | L | |
| #415 | Self-hosted KVM Woodpecker runners | 2 | 1 | L | |
| #406 | ADR-010 P7 hardening + sign-off | 2 | 2 | L | |
| #359 | legal/processor ADR | 3 | 1 | L | |
| #63 | Service desk tooling spike | 3 | 1 | L | |
| ✅ FW #143 | CVE tracking / SBOM (ADR-011) | 3 | 1 | L | **Closed 2026-09-27 — built.** ADR-011 v0.5 Proposed: `health-manager scan/report security` after every sweep, a WARN-only `cve-status` gate, notice on what is new |
| #746 | Emergency patching as ADR-028 D12 describes it | 3 | 1 | M | ADR-028 D12 urgent fixes exist only as prose. Wants a `tappaas-train` verb for the channel-tip → `main` → fast-forward move, and the carried fix shown in `status` |
| #747 | A script that defines its own logging set must define all of it, `debug` included | 4 | 1 | L | Three `debug: command not found` in one day. Wants a lint: a script defining some of `info`/`warn`/`error`/`die` defines `debug` too |

---

## Wave 3 — stability & correctness

Low upgrade risk. Build continuously, in any order within a group.

### G3.1 cluster:vm lifecycle & capacity — E4 · R3 · L-L · released in 2.1: 7 · done for 2.2: 5 · open: 8

Guests sized, placed, started and stopped right: memory defaults from measurement (#663), hardware drift (#531), shutdown and boot order (#36, #127), storage growth and placement (#100, #403), a composite-module ADR (#761), and a sweep that survives a guest restarting itself (#753).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #392 | Never attempt a disk shrink | 5 | 1 | L | **Closed 2026-09-26 — already fixed:** the converge adopts a larger actual size (ADR-020 D9); `update-disk.sh` refuses a shrink (exit 20), `--force` cannot override it |
| ✅ #393 | A failed migration must not block later steps | 4 | 2 | L | **Fixed 2026-09-26:** a failed `qm migrate` of a guest still running returns exit 11 — deferred, drift recorded, no rollback — instead of failing a healthy guest's update |
| #531 | Detect hardware-spec drift | 4 | 3 | L | Once detected, pending changes get applied (reboots): gate on `rebootOk` |
| ✅ #532 | Pending vs applied hardware changes | 3 | 2 | L | **Fixed 2026-09-26:** a held change (memory without hotplug) is read from `qm pending` and reported as deferred, not applied. Verified against ground truth on hrossen |
| #36 | VM shutdown timeout | 4 | 2 | L | Land with #127 |
| #127 | Boot order: firewall (and secrets) first | 4 | 2 | L | |
| #100 | Automatic storage extension | 3 | 2 | L | |
| #403 | Install on the root disk; smarter placement | 3 | 2 | L | |
| #663 | Memory defaults are not based on measurement | 4 | 2 | M | Shipped memory defaults were never measured (hrossen: 60G declared, ~20G used). Over-declaring costs commitment. `network` 8G→4G parked until the operator has physical access |
| ✅ #37 | Optimise RAM (ballooning, swap) | 3 | 3 | L | **Closed 2026-10-06, folded into #663** (operator): measuring is #663's sampler; no ballooning — right-sizing removes over-commitment; the ARC cap and swap are the Proxmox installer's |
| ✅ #423 | `Create-TAPPaaS-LXC.sh` has no `debug()` | 5 | 1 | L | Verified still missing — **Closed 2026-09-26** (`34508ed2`): the LXC creator defines the `debug()` it calls, as `Create-TAPPaaS-VM.sh` does. The same trap elsewhere is #747 |
| #761 | A composite-module ADR: `cluster`, `kubernetes`, and modules that only provide artefacts | 2 | 3 | M | ADR-022d and ADR-026 defer `cluster`/`kubernetes` to an ADR that does not exist, and `templates` fits no `kind`; interim values in ADR-022d v1.2. With @ErikDaniel007 |
| #753 | A guest restarting during its own update fails the sweep | 3 | 2 | L | coturn restarted inside its own update on hrossen (2026-10-01); the post-apply SSH check raced its boot and failed the sweep. The restart's trigger is not yet known |

### G3.2 Identity & SSO wiring — E3 · R2 · L-L · released in 2.1: 1 · done for 2.2: 2 · open: 6

Every app wired to the identity provider the same way: OIDC for hass, Nextcloud and forgejo (#345, #401, #282), a site-specific login page (#479), logging's SSO dependency (#701), and a test for forward-auth (#752).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| #345 | hass: appliance-aware OIDC staging | 3 | 2 | L | |
| #401 | Nextcloud: OIDC redirect, trusted domains | 3 | 2 | L | |
| #282 | forgejo SSO (Community repo) | 3 | 1 | L | |
| #479 | Site-specific login page | 4 | 1 | L | |
| #701 | logging depends on identity though its own code makes SSO optional | — | — | — | **Open, not yet scored** — SSO is conditional on publication since `4c9c846a`. Added in the 2026-09-24 issue sweep |
| ✅ #738 | `identity:identity` discovery check fails on a changed host key and blames the firewall | 4 | 2 | M | **Closed 2026-09-25** via `integrate/nc35` (`c998ca5f`): the stale host key is cleared before the OIDC check, and an ssh failure is named as one. Reported by @AndreasJe |
| #752 | identity:accessControl has no test-service | 3 | 1 | L | `test-service.sh` is an ADR-027 stub, so forward-auth is never tested. Check the Authentik provider, Caddy's ForwardAuth, and that an anonymous request is redirected |
| ✅ #769 | vaultwarden: SSO is registered but never wired into the app | 3 | 2 | L | **Closed 2026-10-04** (SSO wired, `e184ea9d`). **Reversed 2026-10-06, vaultwarden 0.6.0:** no SSO for the password vault, by decision — see vaultwarden DESIGN.md |

### G3.3 App module fixes — E4 · R2 · L-L · released in 2.1: 5 · done for 2.2: 2 · open: 10

The known rough edges of the app modules, fixed and tested so they stay fixed: Nextcloud Talk end to end (#715), Home Assistant (#552, #568, #571 — maintainer-owned), Nextcloud and euro-office (#332, #658, #751), litellm consumers (#553), windows-server (#411), forgejo (#283, #284), in-guest backups (#754).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| #552 | hass: a lost LLAT blocks every update | 4 | 1 | L | **Assigned to @ErikDaniel007 — do not fix (operator, 2026-09-26).** `ha-llat.sh` has no recovery path, so a lost token blocks every update |
| #568 | hass: backup freeze leaves Frigate unhealthy | 3 | 1 | L | |
| #571 | hassanova has no release baseline | 5 | 3 | L | Fix exists unmerged (`ed8a9799`), but landing it makes the merge reconcile a Production module for the first time (R=3). **Needs its owner or a decision** |
| #553 | litellm:models cannot reach an appliance consumer | 3 | 1 | L | |
| #715 | Nextcloud-hub revisited: Talk never worked end to end; races, retries and tests hid real failures | 2 | 3 | M | Talk stack and Nextcloud 35 on `main` (`c998ca5f`). Open: how @AndreasJe's branch lands, one `/etc/secrets` mode, rotating early OIDC secrets — until an off-network Talk call works |
| #411 | windows-server: `deploy-instances.sh` missing | 4 | 1 | L | **Verified open 2026-09-26** (R=1 sweep): the script does not exist; writing it is the work |
| #332 | euro-office / Nextcloud install findings | 3 | 2 | L | |
| ✅ #51 | Immich | — | — | — | **Closed 2026-10-06.** In `src/home/immich`: Immich 3 from pinned nixos-unstable, 500G thin disk under `cluster:ha`, OIDC; live-tested on hrossen, status Testing. Failover untried |
| ✅ #283 | forgejo central logging (moved to `src/devops`, 2026-10-04) | 4 | 1 | L | **Closed 2026-10-06** by #770: `forgejo.json` declares `integratesWith: logging:logs`; the baseline journal client ships it. Forgejo was not installed on hrossen when #770 rolled out — its next install is its own test |
| #658 | nextcloud test 12 probes the browser URL from wherever it runs | 4 | 1 | L | Maintainer-owned (@ErikDaniel007). Not "403 = pass": skip with a reason when the test host is outside the route's `proxyAllowedZones` (exit 77), as Test 9z does |
| #751 | nextcloud:fileservice has no teardown | 3 | 2 | L | `delete-service.sh` is an ADR-027 stub, so a deleted consumer leaves its connector settings in Nextcloud. Remove the env file and unset what `occ` applied; test on hrossen |
| #754 | In-guest backup timers in six modules: drop for PBS or say why they stay | 4 | 2 | L | After Nextcloud dropped its failing in-guest dump (`ed663fe8`): six modules still dump inside the guest. Per module: drop it (PBS takes the VM) or keep it with the reason in DESIGN.md |

### G3.4 AI stack maturity — E3 · R3 · L-L · released in 2.1: 1 · open: 6

A production-grade AI stack: LiteLLM and Open WebUI tested (#119, #120), hardened (#121) and kept current (#621), LiteLLM sized for its workers (#677), and vLLM's models recoverable after a restore (#758).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| #120 | litellm test.sh conventions | 4 | 1 | L | 2 of 6 items done |
| #119 | openwebui test coverage | 4 | 1 | L | |
| #121 | litellm production-grade | 3 | 2 | L | Renamed backups: old backup files must still restore |
| #621 | Bump litellm / openwebui | 3 | 3 | L | After #121 LLM-003 gives update.sh a health gate |
| #758 | vllm-amd: the models bind mount is in no backup | 3 | 2 | L | The 33 GB `/tanka1/vllm-models` bind mount is in no backup, so a restored container has no models. Maintainer @ErikDaniel007: re-download, back it up, or call it cache |
| #677 | litellm's default workers do not fit its default 4 GB | 4 | 2 | M | Found 2026-09-20 by `--deep`: litellm plus four workers leave 43 MB free in the default 4 GB. Either the default memory covers the workers, or the workers follow the memory |

### G3.5 Installer UX — E4 · R1 · L-L · open: 4

A first install that is easier to get through: resumable (#377), showing its progress (#266), asking only what the hardware needs (#405), reusing what it already downloaded (#83).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| #377 | Installer cannot restart; mgmt-net routing | 3 | 1 | L | |
| #266 | Progress indicator during the PVE update | 5 | 1 | L | **Verified open 2026-09-26** (R=1 sweep): `cluster/install.sh` has no progress, dots or spinner |
| #405 | Do not ask for tanks without free disks | 4 | 1 | L | |
| FW #83 | Reuse already-downloaded images | 2 | 1 | L | **Re-scored E4 → E2 (2026-09-26):** the img download lives in a temp dir deleted on exit. Reuse needs a cache location and a staleness policy (moving tags) — a decision first |

---

## Wave 2 — network behaviour hardening

Changes to live firewall and DNS behaviour on every installation. Restrictive defaults get harder to introduce the longer users rely on permissive ones, so they come early; every change shows its dry-run diff (#645) before `--apply`.

### G2.1 Firewall exposure & rule order — E3 · R4 · L-M · released in 2.1: 3 · done for 2.2: 4 · open: 13

Tighter firewall defaults that keep what modules need. Built: the gateway, GUI/SSH and anti-spoofing rules. Next: pinholes shadowed by private-range blocks (#386), lasting NetBird rules (#385, #222), a pinned OPNsense CA (#310), and the rules manager's zones, aliases and overlaps.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #399 | Zone → gateway rule allows every port | 4 | 4 | M | **Closed 2026-10-02**, with #384: the all-ports gateway rule is now DNS, NTP, DHCP and ICMP only, chosen from hrossen's filter log; applied on hrossen, module tests green |
| ✅ #384 | Restrict webgui 8443 to mgmt + NetBird | 4 | 4 | M | **Closed 2026-10-02**, with #399: 8443 and 22 on the firewall blocked from every rule-managed zone; mgmt and the admin VPN keep access. NetBird path untested (not on hrossen) |
| #386 | block-private rules shadow auto-pinholes | 3 | 3 | M | Opens intended paths that are silently blocked today |
| #385 | Persist the NetBird OPT1 pass rule | 4 | 3 | M | Land with #222 |
| #222 | NetBird → srv floating rule is fragile | 4 | 3 | M | |
| ✅ #159 | Anti-spoofing + drop fragments, always on | 4 | 3 | M | **Closed 2026-10-02:** a spoofed-source block heads every rule-managed zone (pf already reassembles fragments). Fixed on the way: inverted rules were never created (`source_invert`) |
| #310 | Pin the OPNsense CA instead of `--no-ssl-verify` | 3 | 3 | M | A rotated cert must fail loudly, not silently stop the sweep |
| ✅ #375 | `mgmt.access-to: "all"` sentinel | 4 | 2 | M | **Closed 2026-10-02:** `mgmt.access-to` is `["internet", "all"]`, expanded where the zones file is read; migration 0012. Identical rules on hrossen before and after; Wave 2 entry gate met |
| #576 | Zone `serves` as string or array | 3 | 2 | M | Backward compatible |
| #257 | mDNS in zones.json | 3 | 3 | M | |
| #160 | Overlap detection in the rules manager | 3 | 1 | L | Land with #256 |
| #256 | Skip pinholes already covered by zone access | 3 | 2 | L | |
| FW #162 | Persistent sequence-map artifact | 4 | 1 | L | **Verified open 2026-09-26** (R=1 sweep): nothing writes `config/firewall/sequence-map.json`. Roll in with #160/#645 |
| #660 | A declared `aliasType` change cannot be applied | 3 | 3 | M | OPNsense refuses an alias type change, so the apply dies and the alias stays `host` — rules match nothing (#542). Needs detach/delete/create/reattach, and a change class in the schema |
| #683 | Declared `ports` without `network:rules` are inert | 4 | 2 | L | Modules declaring `ports` but no `network:rules` (makerfloss) get no validation or rules, silently. Decide what such `ports` mean — a `validate` finding or documentation — with 0010's rule |
| #223 | OPNsense 26.1 InterfaceAssignController | — | — | — | Park (agreed 2026-05-27); move to *Parking lot* |
| #706 | A wireless device zone cannot be checked against its type | — | — | — | **Open, not yet scored** — zone model. Added in the 2026-09-24 issue sweep |

### G2.2 DNS resolver robustness — E4 · R3 · L-M · released in 2.1: 4 · open: 5

A resolver that holds up: a working Unbound restart (#387), a written IPv6 stance (#149), DNSSEC with split horizon (#263), public DNS that follows a dynamic WAN address (#383), and optional blocklists (#157).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| #387 | Unbound rc.d restart fails (Python mismatch) | 4 | 2 | M | |
| #149 | IPv6 root lookups fail → `do-ip6: no` | 4 | 2 | M | Also write down the IPv6 stance (FW #26) |
| #263 | DNSSEC on Unbound | 4 | 3 | M | Internal split-horizon zones need `domain-insecure` |
| #383 | Keep wildcard public DNS current on dynamic WAN | 3 | 2 | L | |
| FW #157 | Default DNS blocklists (DNSBL / maltrail) | 3 | 3 | M | Stretch; only after #387 |

---

## Wave 1 — the breaking-change window

Everything that renames, re-schemas or rebuilds, landed while few installations depend on today's shapes — each change with its migration and an upgrade test from the current `stable`, not only a fresh install.

### ✅ G1.1 Vocabulary & classification (ADR-022 family) — E2 · R4 · L-H · released in 2.1: 11 · done for 2.2: 3

Settle the words before they spread into schemas, CLI names and `config/` paths: the ADR-022 vocabulary — `kind`, scope derived from stack, People → Identity — everywhere. Left for a later release: removing the `tier` fallback.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #676 | `tier` → `scope` migration (ADR-022e) | 3 | 4 | M | **Landed 2026-09-28** (operator): scope is derived from `stack` (ADR-022e v1.1), so no `scope` field and no migration; `tier` removed from the module JSONs, read as a fallback for one release |
| ✅ #705 | cluster and templates carry a kind ADR-022d denies them | 5 | 1 | L | **Closed 2026-10-02:** the interim kinds (`cluster` = application, `templates` = vm) are recorded in ADR-022d v1.2; what they really are is the composite-module ADR, #761 |
| ✅ #741 | `update-tappaas` sweeps a Proxmox VM template as if it were a module | — | — | — | **Closed 2026-09-25** (`912b50b9`): a config whose `stack` is `template` no longer enters the update queue (it failed every sweep for 13 days on the reporter's site) |

### G1.2 Backup placement model + managed machines (ADR-012, ADR-026) — E3 · R4 · L-H · released in 2.1: 20 · done for 2.2: 6 · open: 2

Backups where the operator chooses — a node, a managed machine, an external PBS or the satellite — encrypted, with every machine TAPPaaS manages a module (ADR-012, ADR-026). Left: the satellite's live test on a real VPS (#671) and converting makerfloss's satellite (#775).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #756 | `debianhost`: key-only SSH as an explicit step | 4 | 2 | L | **Done 2026-10-02**, live on hrossen: `sshKeyOnly`, true by default (ADR-026 v0.7), re-applied nightly; machines adopted earlier keep passwords (migration 0013); one script with #19 |
| ✅ #760 | VM and container backups are not encrypted, against ADR-012 | 3 | 4 | H | **Closed 2026-10-03:** every VM and container backup is encrypted (`--encryption-key`, escrowed); restore with and without the key proven on hrossen. Old plaintext snapshots: the operator's |
| #671 | Deep test: satellite as a module on a real VPS | 2 | 1 | L | **Test plan written 2026-10-05** (`docs/plans/satellite-test-plan.md`): six phases on hrossen, each with a teardown. Waits for the operator's VPS and a `sat-test` DNS record |
| #775 | Convert makerfloss's `satellite1` into a module instance | 2 | 2 | L | Split from #671: ADR-010 §8.4.7 with the operator, then #671's phase 1–2 checks. Not before makerfloss runs 2.2; keep a second way in — `satellite1` carries its admin VPN |
| ✅ #737 | `site.json` `backup: true` fails validation and has no migration | 4 | 2 | M | **Closed 2026-09-25** via `integrate/nc35` (`c998ca5f`): migration 0011 turns an old `backup: true` into `{}` (`false` → `null`), so older sites validate. Reported by @AndreasJe |
| ✅ #742 | `backup:filesystem` update never creates a missing encryption key, so a capture can fail forever | 4 | 3 | M | **Closed 2026-09-26** (`85d3ccf3`): an absent `backup:filesystem` key is created and escrowed on update — makerfloss's mothership `config/` had never been backed up. Escrow fix `c53576a0` |

#### ADR-012 close-out (original scope)

ADR-012 v1.0's design decisions, built.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #407 | ADR-012 3-node live validation gate | 2 | 1 | L | **Closed 2026-10-03:** push write-no-delete, ±key restore and relocation green 2026-09-19; node-add client proven in the #729 rejoin; ADR-012 v1.0 accepted; immutability deferred (F.1) |
| ✅ #749 | Installing `backup` on a PVE node silently removed its PVE apt repository | 4 | 2 | M | **Opened and closed 2026-09-27:** `backup/install.sh` wrote its apt stanza over the PVE one, so tappaas3 silently stopped getting Proxmox updates |

### ✅ G1.3 Module contract & repo layout — E2 · R5 · L-H · released in 2.1: 6 · done for 2.2: 2

One module contract — what community modules copy and deployed configs point at: version and status rules, one catalogue, the blueprint check at every release, modules grouped by stack, and a tool to move them ([MOVE-MODULE.md](src/foundation/tappaas-cicd/MOVE-MODULE.md)).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #421 | Restructure `src/apps` into stacks | 2 | 4 | H | **Done 2026-10-03**, live on hrossen: modules live in `src/<stack>/<module>`, `src/apps` gone; 13 moves by `move-module.sh`, migration 0014; stack READMEs generated. Agreed with @ErikDaniel007 |
| ✅ #674 | Implement the ADR-027 blueprint check | 3 | 1 | M | **Landed 2026-09-28:** `module-manager validate --blueprint`, run at every release boundary (not every push); every TAPPaaS module passes. Community: 78 errors, reported to its maintainers |

### ✅ G1.4 Common NixOS baseline — E2 · R4 · L-H · released in 2.1: 14 · done for 2.2: 5

One NixOS baseline every VM imports, carrying the site's time zone, locale, keyboard and time source — the same facts applied to Debian guests and nodes — and pins with a cadence. Left: hass locale (#348, G1.7) and Windows guests (#678, Future Work).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #324 | App VMs do not import `tappaas-common.nix` | 2 | 4 | H | **Closed 2026-10-04:** every NixOS VM and the mothership import the baseline (`0ce65c14`, `b07743ef`, `60c115f6`), guarded by two tests; sweeps 19/19, deep tests unchanged |
| ✅ #740 | `update-os.sh` ships only `*.nix` siblings, so a module cannot carry a patch or data file | 4 | 2 | L | **Closed 2026-09-25** via `integrate/nc35` (`c998ca5f`): `.patch`/`.diff` siblings ship with a module's `.nix`; other data files remain undecided. Reported by @AndreasJe |
| ✅ #748 | identity: the Authentik pin has not moved since 2026-02-21, and nothing tracks it | 2 | 4 | M | **Closed 2026-10-03:** Authentik walked 2025.2.1 → 2026.8.3 on hrossen in nine hops, one release line per update (`ak-step.nix`). Plan and results: `docs/plans/authentik-upgrade-plan.md` |
| ✅ #750 | Container image pins have no cadence and no tripwire, unlike the nixpkgs pin | 3 | 1 | M | **Closed 2026-10-03:** `src/image-pins.json` lists container pins; `tappaas-train` reports age and newer upstream at each boundary, a warning past 45 days (ADR-028 D14 draft). Rest: #765 |
| ✅ #777 | Release train: lock nixos-unstable beside the pin, so Immich 3 follows release moves | 3 | 3 | M | **Closed 2026-10-06, not built (decision):** Immich keeps its own nixos-unstable revision in `immich.nix` until NixOS 26.11 is pinned; until then an Immich update is a deliberate edit |

### ✅ G1.5 Rebuild & recovery paths — E3 · R4 · L-M · released in 2.1: 7 · done for 2.2: 9

A proven way back before anything breaking: `config/` backed up and restorable, mothership keys that can be reissued, restores of a module, a node and the mothership rehearsed, and a control plane that checks itself and rolls back.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #755 | `cicd-key.sh` ignores `kind: machine` modules — `rotate` locks the mothership out of satellite and `debianhost` | 4 | 2 | M | **Closed 2026-10-02:** `cicd-key.sh` now covers machine modules — `rotate` had locked the mothership out of satellites and adopted machines. Reproduced and fixed live on hrossen |
| ✅ #729 | Rehearse RESTORE.md §2, §3 and §5.2 on the test system | 3 | 1 | L | **Closed 2026-10-03:** RESTORE.md §3 (lost node) rehearsed end to end, §2 and §5.2 in part; 14 findings fixed. Plan and results: `docs/plans/restore-rehearsal-plan.md` |
| ✅ #314 | PVE 9.2 default + upgrade path | 4 | 1 | L | **Closed 2026-10-03:** 9.2 is the install default, and the sweep upgrades nodes within 9.x. Fixed with it: `install.sh` refused past 9.4; first-node media named the boot disk by kernel name |
| ✅ #417 | `node delete` does not remove the node | 3 | 3 | L | **Closed 2026-10-03:** `site-manager node delete` previews; `--apply` refuses while the node holds work; `--shutdown`, `--erase` (typed confirmation), `--lost`. Dry-run on hrossen |
| ✅ #711 | templates:nixos re-apply fails with no cause and rolls the VM back | — | — | — | **Closed 2026-09-25** (`e5481865`): a failed OS update now says where and why it stopped (ERR trap under `set -E`). Added in the 2026-09-24 issue sweep |
| ✅ #720 | update-os.sh hangs indefinitely when the rebuild's ssh session dies | — | — | — | **Closed 2026-09-26** (`1aefd916`): keepalives and a ceiling on the rebuild ssh, so a switch that restarts sshd fails instead of hanging 93 minutes |
| ✅ #700 | The pre-update gate tests guests that are still booting | 4 | 1 | L | **Done 2026-10-03:** `module update` waits until the guest has booted and its `ready.sh` passes (up to 300 s) before the gate; a timeout is reported, not fatal. `ready.sh` is an ADR-027 MAY |
| ✅ #767 | The sweep's systemd unit is not the operator's console — align it (ADR-017 D3) | 4 | 3 | M | **Closed 2026-10-04:** the sweep unit runs steps as the console does (login shell, `sudo -n`, no sandbox); `tappaas-unit-run.sh` tests in that context. Two sweeps 18/18. ADR-017 D3 draft |
| ✅ #768 | `module update`: a failed dependency (the OS rebuild) should stop the update, not run update.sh first | 4 | 2 | L | **Opened and closed 2026-10-04:** with a snapshot taken, `reconcile --apply --fail-fast` stops at the first failed dependency and skips Step 3. Found in the Authentik walk |

### G1.6 Secrets & privileged access — E1 · R5 · L-H · released in 2.1: 3 · done for 2.2: 1 · open: 2

Least privilege on the platform. Built: nodes hardened to the Proxmox guide, key-only SSH, encrypted backups. Next: how an AI agent may reach the mothership (#142), and SSH to the mothership through the satellite (#762). Secrets management (#58) waits in Future Work.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #128 | Security hardening (Proxmox hardening guide) | 2 | 3 | M | **Closed 2026-10-04** (`383f8d5e`): of seven guide gaps, sshd (#19), backup encryption (#760), microcode and auditd → Loki done; unattended-upgrades and fail2ban not adopted; Corosync → #590 |
| #142 | RFC: AI-agent access to cicd | 2 | 1 | M | Decision |
| #762 | satellite: build the `sshPort` SSH passthrough to `tappaas-cicd` (ADR-010 §4.4.2) | 3 | 2 | M | Designed in ADR-010, never built: a TCP relay satellite `:sshPort` → tunnel → mothership `:22` for sites with no public inbound address. Decide how to limit it; live test needs #671 |

### G1.7 Parked for Erik discussion · open: 5

Waiting on a conversation between Lars and @ErikDaniel007, not on work: the firewall rebuild runbook (#439), the controller pattern (#430), VMID ranges (#294), hass locale (#348) and Erik's image pins (#765).

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| #439 | Firewall rebuild: **document the procedure, do not run it** | 3 | 1 | L | Decided 2026-09-14: only one installation runs the nano image. Write a runbook (build beside on a spare VMID, move config, cut over, keep the old VM); no automation |
| #430 | Controller/manager pattern for app modules | 3 | 1 | M | Decision (Ansible first) — **parked 2026-09-20** until the operator has agreed it with Erik |
| #294 | Zone-aligned VMID ranges | 2 | 5 | H | Renumbering means backup/restore to a new VMID. **Proposal:** new scheme for new installs and variants only; never renumber in place. Spikes from 2026-06-04 still open |
| #348 | hass locale from site master data | 3 | 2 | L | **Parked 2026-09-21:** no test site runs hass. The fix is written on the issue — `core_config` at `lib/config.sh:158` plus a converge for onboarded instances, from `.location` |
| #765 | Container image pins: list litellm, openwebui, vllm-amd, deconz; move the stale ones | 4 | 2 | L | From #750, for @ErikDaniel007: list his modules in `src/image-pins.json` and move the stale pins — euro-office v9.3.1 → v9.3.4 first; litellm and openwebui overlap #621 |

---

## Wave 0 — make upgrades safe

Make updates safe before anything breaking travels through them: versioned migrations, honest gates, a scheduled update channel with failure notices, and a merge that cannot skip a module.

### ✅ G0.1 Migration & rollback framework — E2 · R2 · L-H · released in 2.1: 8 · done for 2.2: 1

Changes to `config/` that every site can take safely: versioned migrations with backup, dry-run and a ledger (the contract is ADR-025), rollback in install and update, and one meaning for `--force`.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #736 | update merge pins a field that a release moves to a new place | 3 | 3 | M | **Closed 2026-09-26** (`2d25aaf3`): merge rule 5 tells "the operator changed it" from "`.orig` never recorded it" and names each refused value with its remedy. The rule itself: #488 |

### ✅ G0.2 Trustworthy gates — E4 · R2 · L-M · released in 2.1

Tests that tell the truth, so every later migration can be verified. Every item shipped in 2.1 — see [Release 2.1, G0.2](#rel21-g02).

### ✅ G0.3 Update channel & failure notice — E3 · R3 · L-M · released in 2.1

A scheduled update on a channel, with a mail when a sweep fails — the path every later fix takes to a site. Every item shipped in 2.1 — see [Release 2.1, G0.3](#rel21-g03).

### ✅ G0.4 Merge trust · released in 2.1

A 3-way merge that can no longer skip a module silently, so Wave 1's re-schemas reach every deployed config. Every item shipped in 2.1 — see [Release 2.1, G0.4](#rel21-g04).

## Release 2.1 — staging 2026-09-25 · production at the next boundary

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

#### G0.1 Migration & rollback framework — E2 · R2 · L-H

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #652 | Versioned config-migration step | 3 | 2 | H | Ordered, idempotent `migrations/NNNN-*.sh` with backup, dry-run and a ledger in `config/`; a failed migration stops the sweep before any module update (ADR-025) |
| ✅ #584 | Rollback in install/modify | 2 | 2 | M | `modify` Step 0 rewrites config before the snapshot and tests; snapshot `config/<module>.json` together with the VM |
| ✅ #453 | `--force` overwrites deployed config | 3 | 2 | M | **Decided 2026-09-16:** `add --force` refuses on a deployed module and names `module update` / `add --reinstall`; only `--reinstall` overwrites a deployed config (ADR-020 v0.10 D5) |
| ✅ #655 | `module-manager update` verb | 3 | 2 | M | The release update gets its own word; `modify` is the field change. Bare `modify` stays an alias for one release (ADR-020 v0.10 D5) |
| ✅ *(with #655)* | one meaning for `--force` | 3 | 2 | H | `--force` = proceed (failed pre-update test, archived/external) at every level; downtime is `--allow-disruption`; `--ignore-test-failure` retired (ADR-020 v0.10 D8, ADR-017 v0.3 D5) |
| ✅ #648 | `--unset` for stale fields | 4 | 1 | L | Option 2 chosen (2026-09-14): `--unset`, deep test, README |
| ✅ #572 | repo-sync auto-stash never restored | 4 | 1 | L | Pick pop or drop; warn with count |
| ✅ #727 | `module-manager`: `--allow-disruption` reaches services that reject it | — | — | — | **Closed** (@ErikDaniel007): disruption consent travels as `TAPPAAS_ALLOW_DISRUPTION=1` in the environment, so services that reject unknown options no longer roll a healthy module back |

<a id="rel21-g02"></a>

#### G0.2 Trustworthy gates — E4 · R2 · L-M

Tests that tell the truth, so every later migration can be verified.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #644 | `network-manager <verb> --help` runs the verb | 5 | 1 | L | **Do first.** `distribute --help` pushed zones.json for real (2026-09-14). Still open: `main.ts` checks only `argv[0]` |
| ✅ #635 | Pre-update gate collapses test severity | 4 | 2 | M | exit 1 → warn and proceed; the post-update test fails only on new failures, with a `TEST-WARN:` line for old ones (ADR-020 v0.8 D8) |
| ✅ #633 | `site-manager update --force` overrides every `rebootOk` | 3 | 2 | M | Fleet-wide reboot authority from one flag. Decided 2026-09-15: `--force` = run now, respects `rebootOk` (ADR-020 v0.8) |
| ✅ #636 | backup:vm Check 1 fatal while a backup runs | 4 | 1 | L | Timeout → "unknown", not fatal |
| ✅ #555 | network:proxy checks cannot fail without a refid | 3 | 1 | L | |
| ✅ #560 | identity:identity never checks the consumer side | 3 | 2 | L | Stricter test: existing silent SSO gaps turn red on first run (expected) |
| ✅ #620 | Tier lattice authored on 9 of 26 zones | 4 | 2 | M | The check reports coverage. `tier` drives no rule; the repo already tiers every non-exempt zone, the untiered ones are site-local (retire them, or `modify <zone> --set tier=`), so no migration |
| ✅ #645 | Reconcile dry-run hides firewall rule changes | 4 | 1 | L | Needed before the Wave 2 rule changes |
| ✅ #689 | Service tests cannot tell an absent pinhole from one never requested | — | — | — | **Closed 2026-09-21** (`cdc78215`). Added in the 2026-09-24 issue sweep |

<a id="rel21-g03"></a>

#### G0.3 Update channel & failure notice — E3 · R3 · L-M

A scheduled update on a channel, with a mail when a sweep fails — the path every later fix takes to a site.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #471 | ADR-017 update scheduling | 3 | 3 | M | Replaces the update unit on every cicd; mind the first-activation bootstrap gap (Erik, 2026-08-19) |
| ✅ #447 | site-manager cannot modify the schedule | 4 | 1 | L | |
| ✅ #651 | A failed sweep notifies no one | 3 | 1 | L | Adds a site-level notification target (additive schema); #126 reuses it |
| ✅ FW #357 | Define `updateWindow` / `updateChannel` | 4 | 1 | L | Roll in: design only, belongs next to ADR-017 |
| ✅ #653 | Hold the scheduled pull on one site | 4 | 2 | L | A per-repository marker with a reason and an expiry makes the scheduled sweep skip the pull, so the test site runs unpushed work through real sweeps; an expired hold warns and pulls |

<a id="rel21-g04"></a>

#### G0.4 Merge trust

A 3-way merge that can no longer skip a module silently, so Wave 1's re-schemas reach every deployed config.

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #659 | Step 0 skipped when a config has no `.location`, update still reports success | 4 | 3 | H | An unresolvable location, a missing merge script and a failing merge were all logged and followed by `exit 0`. Now resolved through the catalogue too, and all three are fatal |
| ✅ #688 | The 3-way merge reports adopting fields it does not write | — | — | — | **Closed 2026-09-21** (`687a363f`). Added in the 2026-09-24 issue sweep |

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

#### G1.1 Vocabulary & classification (ADR-022 family) — E2 · R4 · L-H

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #624 | ADR-022 review comments | 3 | 1 | H | **Applied 2026-09-17** in Erik's PR #664 — close |
| ✅ #637 | ADR-022 comments (second pass) | 4 | 1 | H | **Applied 2026-09-17** in PR #664 (changelogs cut, Appendix A removed, `kind` defined, 022e–h proposed) — close |
| ✅ #610 | Site = administrative domain × location × zone | 3 | 1 | H | **Decided**: ADR-022a separates the Administrative Domain, 022b the Location; the zone dimension stays ADR-014's. Close on the decision; anything left is implementation under #611 |
| ✅ #611 | `kind` values; retire `external-host` (ADR-022d/f) | 2 | 4 | H | **Implemented 2026-09-18** (`21e3adc7`, migration 0004): every module authors its `kind`; the `kind: module` marker retired; `external-host` → `machine` |
| ✅ #599 | Glossary: node vs host vs cluster member | 4 | 1 | H | **Done 2026-09-18**: ADR-022c D1/D2/D3 restore `Node` to its ArchiMate meaning and add **cluster member** and **Host**; `GLOSSARY.md` §B now carries all three — close |
| ✅ #628 | People → Identity (`people-manager` → `identity-manager`) | 2 | 4 | H | **Implemented 2026-09-18** (`5d15c7f9`, migration 0005): `people-manager` → `identity-manager`, `config/people/` → `config/identities/`; aliases for one stable cycle |
| ✅ #422 | Glossary rewrite | 3 | 1 | L | **Done 2026-09-18**: `GLOSSARY.md` rewritten to the ADR-022 vocabulary, with a §E "what changed" table for reviewers — close |
| ✅ *(in #624)* | `module.tier` → `stack`? | 3 | 4 | H | **Answered 2026-09-17 (ADR-022e):** `module.tier` becomes `scope: site \| environment`, not `stack`; `tier` stays only as `zone.tier` |
| ✅ #707 | ADR-014: zone.tier has no stated relation to IEC 62443 levels | — | — | — | **Closed 2026-09-23** (`972e5c22`). Added in the 2026-09-24 issue sweep |
| ✅ #708 | ADR-004: stack is defined three times, with three value sets | — | — | — | **Closed 2026-09-23** (`469ce9a3`). Added in the 2026-09-24 issue sweep |
| ✅ #669 | `module-manager list` and other verbs should handle `Kind` | — | — | — | **Added in the 2026-09-25 issue sweep.** **Closed.** Part of the ADR-022d `kind` work with #611 |

<a id="rel21-g12"></a>

#### G1.2 Backup placement model + managed machines (ADR-012, ADR-026) — E3 · R4 · L-H

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #780 | `debianhost` module + `module-manager module adopt` | 3 | 2 | M | **Built 2026-09-18:** a `debianhost` module (verify, apt upgrade, test) and `module adopt` (reach by key, learn OS, register). Live on hrossen; leftovers split into #755, #756, #757 |
| ✅ #781 | ADR-012 topology §1.3 verified | 3 | 2 | M | **Verified 2026-09-19** on hrossen: a PBS on a non-member machine adopted from an empty placement, patched by its `debianhost`. Installing PBS onto a bare machine stays manual |
| ✅ #782 | instance vs module name | 3 | 3 | M | **Implemented 2026-09-18** (`8439c54f`, ADR-026 D6.3/D6.4): an instance's module is its source directory, not its name; `module add --instance NAME`. Unblocked #665 |
| ✅ #665 | Register cluster nodes as machine modules | 3 | 2 | M | **Stage 1 built 2026-09-19:** module `pvehost` — each Proxmox node a registered instance, no change on the node. Stages 2–3 (patching, installs through the module) are separate |
| ✅ #670 | Satellite as a module: retire `satellite-manager` | 3 | 3 | M | **Closed 2026-09-20:** the satellite is a module (`module add satellite`, managed, patched by the sweep, `--lockdown`, `--decommission`); `satellite-manager` retired. Live test: #671 |
| ✅ #783 | `placementState` revisit | 4 | 2 | M | **Answered 2026-09-18:** ADR-012 v0.9 settles backup (`node` \| `shim` \| `external`); in general `node` names an instance (ADR-026 D6.5). No separate decision needed |
| ✅ #691 | backup:filesystem ignores its schedule; every capture fires at once | — | — | — | **Closed 2026-09-21** (`a77c498c`). Added in the 2026-09-24 issue sweep |
| ✅ #435 | backup: pass the required module argument in the deep PBS check | 5 | 1 | L | **Closed 2026-09-26 — already fixed** by `a36538f2`: the deep check probes with `job-status` + `namespaces`. A fix without the issue number left both issue and plan stale |
| ✅ #712 | Retire the satellite's `--os nixos` path (unpinned, untested) | — | — | — | **Closed 2026-09-22** (`a1342322`). Added in the 2026-09-24 issue sweep |

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #602 | Empty `placementState` resolves onto the wrong host | 4 | 4 | H | **Built 2026-09-18** (`31bec1b2`): an empty state asks every candidate Host which holds the datastore and adopts it under its own name — no second PBS. 63 unit cases; live on hrossen |
| ✅ #600 | PBS on a non-cluster host | 3 | 4 | H | **Built 2026-09-19:** stored as `placementState: node` + `.node` = the Host (ADR-012 v1.0 §1.3); migration 0007 rewrites `node:<host>` |
| ✅ #612 | `vmname` → the instance name, as a DNS alias; `shim` stays | 4 | 3 | M | **Built 2026-09-19:** `dns-manager alias`; the PBS's name is the backup instance's, a CNAME of its Host renewed on every update; `vmname` gone from `backup.json` |
| ✅ #601 | Placement discovery is PVE-only | 3 | 2 | M | **Built 2026-09-19:** a machine Host is reached by `address` and its storage found from ZFS pools; install refuses a Host with only a pool. PBS onto a bare machine is not automated |
| ✅ #456 | `external` placement for a pre-existing PBS | 3 | 2 | M | **Finished 2026-09-19:** one verb, `backup-manager placement use-external <url>`; an update of an `external` placement fails, named, when its storage is missing |
| ✅ #607 | Exit from `external` placement | 4 | 1 | L | **Built 2026-09-18:** `placement reset` / `finish-reset` keep the old storage as `<name>_former` so history stays restorable, then onboard locally. Not rehearsed end to end (needs an external PBS) |
| ✅ #457 | `pbs_node` uses placement, not the registered name | 4 | 2 | M | **Built 2026-09-19:** the Host and the PBS name cannot diverge; every PBS ssh goes through `pbs_node_addr`, and `pbs_node` fails instead of guessing the first node |
| ✅ #603 | PBS on a non-PVE host has no update path | 3 | 2 | M | **Built 2026-09-19:** the Host's owner patches the PBS — the cluster module for a node, the machine's `debianhost` otherwise; install adopts an unregistered machine |
| ✅ #554 | Reconcile creates duplicate job coverage | 3 | 2 | M | **Built 2026-09-19:** coverage is asked of every cluster backup job; foreign jobs are reported, never duplicated blindly. New `backup-manager coverage <module>` |
| ✅ #609 | Off-site location recorded | 4 | 2 | M | **Built 2026-09-18:** `physicalLocation` on backup peers and satellites; `validate` warns about an off-site target not shown to be elsewhere. (`location` became `moduleSource`, 0006) |
| ✅ #605 | Split ADR-012 acceptance list | 5 | 1 | L | **Done in v1.0:** a Decision list (accepted) and an Implementation list (tracked in #407) |

<a id="rel21-g13"></a>

#### G1.3 Module contract & repo layout — E2 · R5 · L-H

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #500 | Automate moving a module | 2 | 3 | H | **Built 2026-09-19:** `move-module.sh` moves the files, rewrites the catalogue and writes the `NNNN-modules-moved.sh` migration (ADR-025 D14). How to use: `MOVE-MODULE.md` |
| ✅ #349 | Drop the zone tag from released modules | 3 | 3 | H | **Built 2026-09-19:** `zone0: mgmt` dropped from the foundation modules (recorded at install); placed-by-role modules keep theirs; the merge keeps a deployed `zone0`. ADR-007c v1.5 |
| ✅ #566 | Legacy name → variant convention | 2 | 3 | H | **Built 2026-09-20:** `module modify <instance> --set instance=<new>` renames an instance (config, `.orig`, `.meta`, `node` references); the reported breakage was already gone (ADR-026 D6.3) |
| ✅ #248 | Module version/status standard | 4 | 1 | M | **Built 2026-09-20:** SemVer 0.x until someone else has run it; Development → Testing → Production, enforced by the classification lint. Absorbed into ADR-027 |
| ✅ #363 | Module lifecycle blueprint ADR | 3 | 1 | M | **Closed 2026-09-20:** [ADR-027 Module Blueprint](<docs/ADR/ADR-027 - Module Blueprint.md>) Proposed — the artifact set, a service's six files, one severity for all. The check is #674 |
| ✅ #463 | module-catalog schema is stale | 4 | 1 | M | **Built 2026-09-20:** the catalogue repeats nothing a module's JSON says — one flat `modules` list; `stack` decides what a module is; `site-manager repository validate-catalog`. ADR-004 amended |

<a id="rel21-g14"></a>

#### G1.4 Common NixOS baseline — E2 · R4 · L-H

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #390 | 00-Template fails canon C4/C7 | 5 | 1 | H | **Closed 2026-09-24:** C4 already fixed (#446); C7: the template and the baseline declare the firewall explicitly, kept by `test-nixos-canon.sh`. Supersedes PR #391 |
| ✅ #448 | NIC rename race (kernel / udev / cloud-init) | 3 | 4 | M | **Closed 2026-09-24, through #324:** the baseline disables cloud-init's network stage, so NetworkManager alone names the NICs and they stay `ens18` (NixOS only) |
| ✅ #472 | NixOS clock two hours off | 4 | 2 | M | **Built and verified 2026-09-21:** each module had picked its own time zone; now the site fragment from `site.json` (#408), with #87 and #324, in one rebuild |
| ✅ #408 | Locale/keyboard: tappaas1 is the master | 3 | 2 | M | **Built 2026-09-21:** `site add` reads time zone, keyboard and locale from the first node; `.location` gained `keyboard`, `latitude`, `longitude`; PXE and USB installers use them |
| ✅ #87 | NTP on OPNsense, consumed by modules | 4 | 2 | M | **Built 2026-09-21:** the firewall already served NTP and nothing used it; each guest now syncs from its zone's gateway (NixOS fragment, Debian timesyncd drop-in) |
| ✅ #716 | A guest can boot into a 17–34 min window with no usable time source | 4 | 2 | M | **Closed 2026-10-04:** firewall ntpd fixed (`663e0c7e`), a second source where a zone has internet (`7f0a23df`), a back-off cap for gateway-only zones, and `NTPSynchronized` awaited after boot |
| ✅ #220 | Nix sandbox disabled on cicd | 4 | 2 | L | **Closed 2026-09-24**, nothing to remove: the workaround lived only in a site repo. Every mothership and guest builds with the sandbox on (checked on both pins) |
| ✅ #680 | The baseline `flake.lock` decides every site's nixpkgs | 3 | 4 | H | **Built 2026-09-21:** the mothership's rebuild names a pin that would move it backwards. Cadence answered by ADR-028: one estate pin, moved at each boundary, tripwire at 45 days |
| ✅ #699 | Guests created with `-localtime 1` boot two hours ahead | — | — | — | **Closed 2026-09-22** (`cd87f4dc`). Added in the 2026-09-24 issue sweep |
| ✅ #721 | promtail is removed in nixos-26.05 | — | — | — | **Closed 2026-09-24** (`15ca633f`) — replaced by Grafana Alloy; closed in this sweep. Added in the 2026-09-24 issue sweep |
| ✅ #722 | Grafana's `secret_key` has no default in 26.05 | — | — | — | **Closed 2026-09-24** (`c6e4db68`) — a per-site key beside the admin password; closed in this sweep. Added in the 2026-09-24 issue sweep |
| ✅ #726 | A release move leaves every Postgres guest permanently warning about collation | — | — | — | **Closed 2026-09-25:** after a release move, Postgres collation versions are refreshed in the sweep — each only after `bt_index_check` verifies that database's indexes |
| ✅ #728 | update-os: guests switch across a nixpkgs release and fail on exit 4 | — | — | — | **Closed 2026-09-24** (`0afac5d5`): a guest's release move is staged with `nixos-rebuild boot` and taken by the reboot, as the mothership does (#725). Likely root cause of #711 |
| ✅ #709 | Nextcloud cannot advance past 33 | — | — | — | **Closed 2026-09-24:** the pin is on 26.05 (`3e07ca7d`), which ships Nextcloud 33–35, and the train can move releases (`7b3af58f`). `ncMajor` is the maintainers' call |

<a id="rel21-g15"></a>

#### G1.5 Rebuild & recovery paths — E3 · R4 · L-M

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #545 | Foundation backup + tested recovery (incl. `config/`) | 2 | 2 | M | **Done 2026-09-18:** ADR-012 D20 deployed — `network` and `tappaas-cicd` in the daily job; `config/` restore rehearsed (173/173 files, refused without the key). G1.5's exit gate met |
| ✅ FW #122 | Reissue **and revoke** tappaas-cicd SSH keys | 3 | 3 | M | **Done 2026-09-18:** `cicd-key.sh status`, `rotate` (new key proven everywhere, every other key revoked) and `recover` (through the guest agent). On hrossen: 18 stale root keys removed |
| ✅ #43 | Test and document backup/restore | 3 | 1 | L | **Closed 2026-09-24** as superseded: RESTORE.md is published as *Disaster Recovery*, each procedure labelled rehearsed or not; the rest went to #439, #407 and #729 |
| ✅ #710 | templates:nixos re-apply fails with no cause and rolls the VM back | — | — | — | **Closed 2026-09-22** as a duplicate of #711. Added in the 2026-09-24 issue sweep |
| ✅ #713 | The mothership cannot undo a bad rebuild | — | — | — | **Closed 2026-09-24** (`4024c510`, `c615f5dc`): the mothership checks itself after a rebuild and rolls back, bounded. The check's scope continued in #719 |
| ✅ #725 | A switch across a nixpkgs release reports failure and its rollback live-locks | — | — | — | **Closed 2026-09-24** (`6f9568bd, c615f5dc`) — a release move is staged with `nixos-rebuild boot` and a reboot; closed in this sweep. Added in the 2026-09-24 issue sweep |
| ✅ #719 | The control-plane self-check does not verify what it claims | 3 | 3 | M | **Closed 2026-10-03:** the self-check evaluates all 11 control-plane components and rolls back unless each is built at its implied path and linked from `~/bin` (ADR-028 D10) |

<a id="rel21-g16"></a>

#### G1.6 Secrets & privileged access — E1 · R5 · L-H

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #19 | Disable SSH password login on PVE nodes | 4 | 3 | M | **Decided and live 2026-09-18:** every node key-only (`PermitRootLogin prohibit-password`, never `no` — PVE needs root over key), applied by `cluster/update.sh`, asserted by Test 4 |
| ✅ #378 | Default-on secret scanning on cicd | 4 | 1 | L | **Closed 2026-10-03:** gitleaks gates every release boundary (not every push); a pre-commit hook on the mothership. History holds old tokens — **rotate them**; rewriting history is the operator's call |
| ✅ #724 | The journal secret-scrub never worked (it redacted the key, not the secret) | — | — | — | **Closed 2026-09-23** (`eda1eb9d`) — secrets that reached Loki before the fix need rotating; see #715. Added in the 2026-09-24 issue sweep |

### Wave 2 — network behaviour hardening

<a id="rel21-g21"></a>

#### G2.1 Firewall exposure & rule order — E3 · R4 · L-M

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #682 | `rules_manager.py` reads the provider from `location`, not `moduleSource` | 4 | 5 | M | **Done 2026-09-21** (`0d0272d1`): the rules manager reads `moduleSource` (then `location`) — reading only the old field had deleted 24 live rules on Erik's site |
| ✅ #684 | `test-module.sh` fills its dependency set from `dependsOn` alone | 4 | 3 | M | **Done 2026-09-21** (`3948f7b1`): module tests walk `dependsOn` and `integratesWith`, so every auto-pinhole is verified — the blind spot behind #682 |
| ✅ #704 | network:proxy: aliasType and firewallType warn as orphans | — | — | — | **Closed 2026-09-22** (`c7dd7870`). Added in the 2026-09-24 issue sweep |

<a id="rel21-g22"></a>

#### G2.2 DNS resolver robustness — E4 · R3 · L-M

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #693 | An unpublishable name returns rc=0 where D5 expects 3 | 4 | 2 | L | **Closed** (`a4af3ee0`): a name that cannot be published exits 3, as ADR-021 D5 says, instead of 0. Found by the makerfloss deep sweep |
| ✅ #657 | Standard 4 invents an FQDN when a config lookup fails | 5 | 1 | L | **Done 2026-09-17:** the DNS sample carries each module's own zone instead of guessing `srvHome`, so the test stops asserting names the estate never declared |
| ✅ #702 | dns-manager add matches an entry by description, not by name | — | — | — | **Closed 2026-09-22** (`148b920b`). Added in the 2026-09-24 issue sweep |
| ✅ #703 | acme-setup: wildcard DNS is skipped when only the apex is unpublished | — | — | — | **Closed 2026-09-22** (`dd0a0763`). Added in the 2026-09-24 issue sweep |

### Wave 3 — stability & correctness

<a id="rel21-g31"></a>

#### G3.1 cluster:vm lifecycle & capacity — E4 · R3 · L-L

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #665 | Register cluster nodes as `kind: machine` modules | 3 | 2 | M | Stage 1 of ADR-026 D4 — registration only: existing nodes become instances of one module, after the instance work (ADR-026 D6). Built as `pvehost` — see G1.2 |
| ✅ #662 | PVE host configuration is not backed up | 4 | 2 | M | **Closed 2026-09-21** (`ffaf45fc`): a machine's own configuration (`/etc/pve`, network, ssh, root) is captured as `backup:filesystem`, so a cluster-wide loss is recoverable |
| ✅ #692 | A guest is built on `tanka1` whatever node it lands on | 4 | 4 | M | **Fixed 2026-09-21:** a guest's pool is resolved against its node (`tanka1` if active, else the node's first ZFS pool); a declared pool the node lacks is refused before any download |
| ✅ #686 | A backup lock fails an update that succeeded | 4 | 2 | M | **Closed** (`f8b528f6`): a VM held by a running backup is waited on and then deferred, never updated without its rollback snapshot |
| ✅ #679 | An immutable field's schema default can make a module unreconcilable | 3 | 4 | M | **Done 2026-09-21** (`37d2c04f`): a field still at its schema default whose change cannot apply is recorded as skipped, not as immutable drift needing a reinstall |
| ✅ #569 | Node capacity / overcommit verb | 4 | 1 | L | **Done 2026-09-17** (`71799221`): `health-manager validate` reports memory commitment per node (committed vs physical, `--memory-threshold PCT`) |
| ✅ #673 | Cluster nodes are a fixed list of nine, not a sequence | — | — | — | **Added in the 2026-09-25 issue sweep.** **Closed** |

<a id="rel21-g32"></a>

#### G3.2 Identity & SSO wiring — E3 · R2 · L-L

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #698 | logging update fails on makerfloss: the mgmt environment has no domain | — | — | — | **Closed 2026-09-21** (`c1cdf960`). Added in the 2026-09-24 issue sweep |

<a id="rel21-g33"></a>

#### G3.3 App module fixes — E4 · R2 · L-L

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #687 | OnlyOffice: the document server cannot download from Nextcloud | 3 | 1 | M | **Closed** (`d4d34aae`): the document server could not fetch from Nextcloud over the internal name, which has no TLS — users silently lost document editing |
| ✅ #412 | coturn reads an undefined `publicDomain` | 5 | 1 | L | |
| ✅ #622 | deconz probe uses a name that never resolves | 5 | 1 | L | Looks fixed on `main` (both services now resolve the deconz FQDN): verify and close |
| ✅ #714 | nextcloud:fileservice fails euro-office on a verdict the run could not make | — | — | — | **Closed 2026-09-23** (`287bad27`) — TTY, readiness gate, verdict from the check's own words, JWT leeway. Added in the 2026-09-24 issue sweep |
| ✅ #667 | `nextcloud:fileservice` declares no fields, so its connector is undefined | — | — | — | **Added in the 2026-09-25 issue sweep.** **Closed.** Sits with #714, the other fileservice defect |

<a id="rel21-g34"></a>

#### G3.4 AI stack maturity — E3 · R3 · L-L

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #690 | litellm VK provisioning has no readiness wait and discards the key | — | — | — | **Closed 2026-09-21** (`3358e3ec`). Added in the 2026-09-24 issue sweep |

### Wave 4 — additive capabilities

<a id="rel21-g42"></a>

#### G4.2 Proxy & ingress — E3 · R2 · L-L

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #696 | A blocked client gets a blank page: access lists carry no message | — | — | — | **Closed 2026-09-21** (`5110a84b`). Added in the 2026-09-24 issue sweep |

<a id="rel21-g43"></a>

#### G4.3 Manager verb gaps — E3 · R2 · L-L

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #681 | Auto-stash entries nothing lists or resolves | 4 | 2 | L | **Done 2026-09-21** (`ed6aa6a7`): `site-manager repository stash list/show/restore/discard` for repo-sync's kept stashes; the sweep names the oldest one's age |
| ✅ #672 | `module delete` of a machine leaves its dnsmasq Host entry behind | — | — | — | **Added in the 2026-09-25 issue sweep.** **Closed.** A delete that does not finish is a drift source |
| ✅ #730 | health-manager: no reboot verb, and pending reboots go unrecorded | — | — | — | **Added in the 2026-09-25 issue sweep.** **Closed** (@ErikDaniel007). A reboot that is not taken is now reported as a `DEFERRED:` line the sweep collects |
| ✅ #718 | module-manager: the dependency test misses an environment's provider | — | — | — | **Closed 2026-09-23** (`6bc1f92e`) — delete-module's reverse check fixed with it. Added in the 2026-09-24 issue sweep |

<a id="rel21-g44"></a>

#### G4.4 Storage & physical devices — E2 · R2 · L-M

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #734 | ap-controller: an unfilled placeholder SSID reads as live drift | — | — | — | **Added in the 2026-09-25 issue sweep.** **Closed** (@ErikDaniel007). **#732 is the same issue filed twice** — both are closed; worth confirming one was closed as a duplicate rather than fixed twice |
| ✅ #733 | `unifi.sh`: one message covers four failure causes, and a `jq` crash | — | — | — | **Added in the 2026-09-25 issue sweep.** **Closed** (@ErikDaniel007). One error string for four distinct causes taught operators nothing; the `jq` crash made it worse |

<a id="rel21-g45"></a>

#### G4.5 Governance, CI & sign-offs — E3 · R1 · L-L

| # | Issue | E | R | L | Note |
|---|-------|:-:|:-:|:-:|------|
| ✅ #695 | The deep VM suite leaves a guest behind, and the next run fails on it | 4 | 2 | L | **Closed** (`e2dacf7e`): a leftover VM from an earlier deep run made the next run report a false rollback failure. Teardown is now checked |
| ✅ #694 | Service README field sections are stale | 5 | 1 | L | **Closed** (`93872f32`): the generated service field docs were regenerated, and the question whether a generated file may drift at all was raised |

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
