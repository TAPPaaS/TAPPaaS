# SIEM for TAPPaaS: analysis and plan

Analysis for [#843](https://codeberg.org/TAPPaaS/TAPPaaS/issues/843) (*Create a SIEM for
TAPPaaS*), with [#886](https://codeberg.org/TAPPaaS/TAPPaaS/issues/886) (the console's security
view) as its first consumer. Written 2026-11-12. This is analysis only: no code was written, and
no live system was read or changed. The decision it argues for is drafted as
[ADR-050](<../ADR/ADR-050 - Security Monitoring.md>) (Proposed).

Sources:

- The ADRs on logging and alerting (039), the CMDB (040, 041, 049), sizing (044), CVEs (011,
  045, 047) and performance (046).
- The code on `main` at `a09ebb09`. Paths below are relative to `src/foundation/` unless they
  start with `docs/`.
- Upstream releases, licences and nixpkgs (master, `nixos-25.11`, `nixos-26.05`), checked
  2026-11-12. Figures marked *est.* are estimates, not measurements.

## Summary

**Recommendation: build the SIEM in two layers. Do not make Wazuh the base.**

1. **Layer 1, every site at every size: detection on the stack TAPPaaS already runs.**
   - Loki already holds every guest's journal, the firewall log and the Proxmox audit log. Add
     the missing sources: auditd on NixOS guests, Caddy's access logs, CrowdSec's decisions and
     Suricata's alerts.
   - A security rule pack (Sigma rules converted to LogQL, plus our own rules) runs on the
     ADR-039 path.
   - One CrowdSec log processor on the logging VM reads Loki, and its bans land in the
     firewall's existing pf bouncer.
   - A NixOS-native integrity check compares each guest's running system with what the
     mothership built for it.
   - Findings become `security` conditions on CMDB objects, so they show up in health, mail and
     the console with no new pipeline.
   - Cost: about 0.5–1 GiB more memory and some disk on the logging VM, and Suricata on the
     firewall at medium and large.
2. **Layer 2, optional, medium and large: a `wazuh` module**, installed after Wazuh 5.0 is GA.
   - Agents run on what Wazuh understands: the Proxmox nodes, Debian hosts and guests, OPNsense
     and Windows.
   - It adds CIS checks (SCA), file-integrity monitoring and rootcheck on those machines, plus
     its dashboard for investigations.
   - Its alerts go into Loki and from there along the same path as layer 1.

Why not Wazuh first, as #843 assumed:

- **Blind on NixOS.** Wazuh's strongest features are its vulnerability detector, its CIS checks
  (SCA) and syscheck. The first two have no NixOS support: Wazuh has no NixOS package inventory
  and no NixOS CIS policy. Most TAPPaaS guests are NixOS, and our own scanner (ADR-011) already
  does better on them.
- **Too heavy for small.** It needs 8 GiB for the indexer, against a `small` budget with 0.25
  GiB to spare (ADR-044 D6).
- **Not in nixpkgs.** There is no package or module for either the server or the agent.
- **A rebuild is coming.** 5.0 has no in-place upgrade from 4.x, and it drops frequency and
  threshold rules (brute force) until a later minor release.

## 1. What TAPPaaS already has

| Area | What exists | Gaps a SIEM must close |
|---|---|---|
| **Log collection** | The logging VM (`logging`, mgmt): Loki for 30 days, Grafana, Alloy, Prometheus, Tempo (`logging/logging.nix:16-65`). Every NixOS guest ships its whole journal through Alloy with a push credential per VM, and the server stamps `host` from that credential (`logging.nix:740-753`). Debian VMs and LXCs use Alloy from apt. OPNsense (including `filterlog`) and the Proxmox nodes send syslog on 1514/1515, over TLS on 6514/6515 (#787). | Log lines carry no `tappaas_ci_id` (ADR-040 implementation step 5 is open). Caddy's access logs and CrowdSec's log stay on the firewall. `debianhost` ships nothing. HAOS and Windows guests ship nothing. Everything is kept 30 days, security streams included. |
| **Host audit** | auditd on the Proxmox nodes: changes to `/etc/pve`, `/etc/ssh`, `/root/.ssh` and `/etc/network` made from a login session go to Loki (`cluster/setup-host-hardening.sh`). There is also the `RootKeyChanged` alert. | No auditd on NixOS guests or on `debianhost`. No FIM beyond those paths. |
| **Alerting** | ADR-039: `<module>-alerts.json` rules applied to Grafana per module, scoped to the hosts in `config/`. One webhook goes to `tappaas-alert-receiver` (`tappaas-cicd/scripts/tappaas-alert-receiver.py`, bearer token), which mails through `site-notify.sh` and runs `health-manager assess --alert`. | Rules match single lines and count them. There is no correlation across sources and no security rule set. |
| **Health on the CMDB** | ADR-041 and ADR-049: `conditions[]` on every object, including a `security` type. `classify` records turn a finding into a condition. Root cause and impact follow the relations. Events are typed causal or symptom. The Operations view exists. | Only `RootKeyChanged` and `FirewallCertChanged` become `security` conditions (`health-manager/src/assess-sources.ts:110-137`). There is no idea of a security event that ages out. |
| **Inbound defence** | CrowdSec on OPNsense (#851). It reads Caddy's access log per name and runs `http-login-bf` (Jellyfin and Authentik), `http-cve` and bad user agents. Bans go into pf for 4 hours. The LAPI is local and no CAPI is registered (`network/scripts/crowdsec-converge.sh`). There are DNS blocklists (FW #157), with IP blocklists (#925) and the community list (#926) opened as issues. | Only the published names are watched. SSH, the Proxmox UI, OPNsense's own UI and the internal zones are not. Decisions are visible nowhere outside the firewall. |
| **Vulnerabilities** | ADR-011, ADR-045 and ADR-047 use one scanner per layer: grype for Nix closures, trivy for images and Debian, `pkg audit` for OPNsense. VEX is kept as component records, and each CVE has a state: decided, risk, open or carried. A risk score is kept per module, zone and site, and feeds the `security` condition. | None: this is better than any SIEM's detector on NixOS. What it lacks is a link to attacks: an exploit attempt against a CVE that is open on that module. |
| **Network IDS** | None. Suricata is in OPNsense but not configured (`network/docs/pfblockerng-replacement.md:85-94`). | No IDS, no flow analysis. ADR-046 D2 also leaves out NetFlow. |
| **Drift** | The CMDB discovery sweep (ADR-040 D15): actual against desired, actual without desired, desired without actual. It covers firewall rules, users, guests and VLANs. | It does not cover the inside of a guest: files, packages, a `nixos-rebuild` done by hand. |
| **Identity** | Authentik is always installed. Its events (failed logins, policy denials, admin changes) are journal JSON lines in Loki (`identity/identity.nix:488-495`). Grafana already signs in through it (#165). | Nothing reads those events for security. |

Two things follow from this. First, most of a SIEM's *collection* already exists, and what
TAPPaaS lacks is *detection content* and a few sources. Second, TAPPaaS already has a
correlation engine of its own (root cause and impact over the CMDB), which no SIEM can bring.

## 2. The open source options

The criteria come from the task. "Overlap" means overlap with Loki and Alloy, ADR-039 alerting,
the ADR-045/047 CVE handling and ADR-046 performance monitoring.

| | Licence | Footprint for ~20 hosts | NixOS fit | Agent | Authentik SSO (free) | Upstream, 2026-11 | Overlap with TAPPaaS |
|---|---|---|---|---|---|---|---|
| **Wazuh** | GPLv2 (4.14). AGPL-3.0 for the 5.x engine. Apache-2.0 indexer. All OSI | **4 vCPU, 8 GiB, 50 GB** all-in-one, by the vendor's quickstart | **Not in nixpkgs**: both agent PRs (#308041, #309573) closed unmerged. Vendor images exist, so it would run as pinned OCI containers on a NixOS VM | Agent, with an agentless option over SSH. Official OPNsense plugin `os-wazuh-agent` | Yes, SAML through the OpenSearch security plugin. There is an official Authentik guide | Very active: 4.14.10 (2026-11-09). **5.0 is at rc2**: no in-place upgrade, frequency rules dropped for now, XML rules to be rewritten | Its own indexer duplicates Loki. Its vulnerability detector duplicates ADR-011 and is blind on NixOS. SCA has no NixOS policy |
| **Security Onion** | **Elastic License 2.0** (not OSI) | **24 GB minimum**, 32 GB advised, 2 NICs | A whole distribution (Oracle Linux) | Elastic Agent | **OIDC only in Pro** (paid) | Active (3.4.0, 2026-11-02) | Duplicates all of it |
| **Graylog Open** | Server **SSPL** (not OSI) | ~8 GB *est.* (Graylog, MongoDB, OpenSearch) | `services.graylog` exists but is stuck at 6.1; upstream is at 7.2 | Agentless (syslog, GELF), or Sidecar | **OIDC and SAML only in Enterprise** | Active | Duplicates Loki. Sigma and correlation are in the paid Graylog Security |
| **OpenSearch with Security Analytics** | Apache-2.0, Linux Foundation | 4–8 GiB *est.*, JVM | `services.opensearch` (3.5 on master). OpenSearch Dashboards is probably not packaged | Bring your own shipper (Fluent Bit, Vector, Data Prepper) | Yes: OIDC and SAML in the free security plugin | Active (3.9.0) | Duplicates Loki. Sigma detectors and correlation are its value. No FIM, SCA or host agent |
| **Elastic (ELK) Basic** | AGPLv3 *source*, but the binaries are ELv2 | 4–8 GiB *est.* | nixpkgs has only 7.17, marked unfree | Elastic Agent | **No**: SSO needs Platinum. Webhook actions reportedly need Gold | Active (9.5.6) | Duplicates Loki. Free detection rules, but no SSO and no outbound webhook |
| **CrowdSec** | MIT (engine, bouncers). The console is SaaS and optional | ~100–250 MB *est.* | **`services.crowdsec` and `services.crowdsec-firewall-bouncer`** in nixpkgs (1.7.8 in 26.05). `os-crowdsec` already runs on our firewall | A log processor per source, or one central processor. One LAPI takes many processors | Not applicable (no UI to sign in to) | Active (1.8.2) | Already in use (#851). **It responds; it is not a SIEM**: no search, no retention |
| **Suricata** (sensor) | GPL-2.0 | ~1–1.5 GB *est.* with ET Open rules | Built into OPNsense. Also `services.suricata` | Network sensor | Not applicable | Active (8.0.8) | None: it adds network IDS |
| **Zeek** (sensor) | BSD-3 | ~1–2 GB *est.* | Package only, no module. **No OPNsense plugin** | Needs a SPAN port or a tap | Not applicable | Active (9.0.1) | None, but it needs a mirror port that TAPPaaS's switch model does not yet set up |
| **Falco** | Apache-2.0, CNCF | ~100–200 MB *est.* | `services.falco` on **master only** | eBPF agent | Not applicable | Active (0.45.2) | Fits the container guests (Karakeep, Immich and others). Wait for a stable NixOS release |
| **osquery** (+ Fleet) | Apache-2.0/GPL-2.0. Fleet is MIT with an `ee/` part | small | `services.osquery`. Fleet as a package only | Agent | Fleet SSO: SAML (check the tier) | Active | Inventory and queries. Overlaps the CMDB discovery sweep |
| **Velociraptor** | AGPL-3.0 | moderate | Not packaged | Agent | OIDC | Active (Rapid7) | Forensics and hunting. Later, if ever |
| **Loki + Sigma** (pySigma-backend-loki) | AGPL-3.0 | **0** beyond today | `services.loki` and `services.alloy`, already in use. `sigma-cli` and the backend are in nixpkgs | None beyond Alloy | Grafana OIDC, already live | Loki very active. The Sigma backend is maintained by one person (0.16.0, 2026-10-28) and is fine for single-event and count rules | **This is the stack we run** |
| Malcolm (CISA) | Mixed OSS | **8 cores, 24 GB** | No | Sensors | – | Active | Too heavy |
| OpenObserve | AGPL for the OSS edition. The nixpkgs build is the unfree EE binary | small | Mixed | Bring your own | – | Active | Another log store |
| Matano, SIEMonster | – | – | – | – | – | Matano is dead; SIEMonster is not OSS | Skip |

### Reading the table

- **Ruled out by licence or paid SSO:** Security Onion (ELv2, OIDC in Pro, 24 GB), Graylog
  Open (SSPL, no SSO), Elastic Basic (ELv2 binaries, no SSO, no webhook, unfree 7.17 in
  nixpkgs). Identity is always installed, and a SIEM whose sign-in is a local admin account does
  not meet the platform's rule.
- **A second log store is a cost, not a feature.** Wazuh's indexer, OpenSearch and Graylog each
  bring a JVM search cluster beside Loki and hold the same lines twice. On a 32 GB node at
  `small` there is no room for it (ADR-044 D6: 26.25 GiB of guest memory against about 26.7
  available).
- **OpenSearch Security Analytics** is the most capable *open* detection engine (Sigma rules
  with correlation). It brings no host agent, FIM or compliance, and we would still have to
  build the shipping and the SSO. It wins only if we decide to replace Loki, which nothing here
  argues for.
- **Wazuh** is the only complete free SIEM with OSI licences, free SSO and an OPNsense agent. Its
  value on TAPPaaS sits on the *non-NixOS* machines: the Proxmox nodes (the most privileged hosts
  on the site), Debian hosts and guests, OPNsense and Windows. On NixOS guests it would add
  little that auditd, the closure check and our scanner do not already cover.
- **CrowdSec** is already the response arm. One LAPI with several log processors is supported,
  so it can grow from "published names" to "every log in Loki" without agents on the guests (see
  §5, P1). This needs CrowdSec's Loki data source, which has existed since 1.5; confirm it in the
  P1 spike.
- **Suricata** is free on our firewall and fills the one gap nothing else does: a network IDS.

### Recommendation

**Layer 1, the SIEM itself, everywhere: Loki, a security rule pack, CrowdSec, Suricata, auditd
and the CMDB.**

- Detection content goes on the stack we have. Response comes through CrowdSec into the firewall
  we have. Findings become CMDB conditions through the health path we have.
- It runs at `small`, it is packaged in nixpkgs or in OPNsense, it needs no new sign-in, and it
  adds no second store or second alert pipeline.

**Layer 2, deep host checks where they work: an optional `wazuh` module at medium and large,
after 5.0 GA.**

- It covers CIS (SCA), syscheck and rootcheck on the Proxmox nodes, Debian, OPNsense and Windows,
  and gives an investigation UI.
- Its alerts feed layer 1 (Loki, then the ADR-039 rules, then health), so the operator still has
  one inbox and one Health view.
- We start on 5.0 so we do not build twice.

Rejected: Security Onion, Graylog Open, Elastic Basic (licence or paid SSO); OpenSearch Security
Analytics as the base (a second store, no host side); Wazuh as the base (§ Summary).

## 3. CMDB integration

The CMDB (ADR-040) is the actual state of the site: a PostgreSQL store behind `cmdb-controller`
on `tappaas-cicd`, reached through the `cmdb` verbs and an HTTP API on a socket and localhost.
Every manager reports what it sees (`POST /v1/report`: observations and changes). CIs are created
from their desired record and retired with it, and are never reused. `module-manager` ends a
module's CIs on delete (`delete-module.sh:632-637`). `site-manager node delete` retires the node's
CI and what is known by it, and keeps or removes the asset. `cmdb resolve` maps OpenTelemetry
resource attributes to a CI. Health conditions are written only by `health-manager assess`.

### 3.1 Assets and owners into the SIEM: enrichment

Each event should name its CI, and everything else follows from the relations.

| What the analyst wants | Where it comes from |
|---|---|
| Which CI | the `tappaas_ci_id` label on the log line (ADR-040 D14). **Prerequisite (P0)**: Alloy stamps it on guests from the CI id the mothership writes at deploy. Syslog sources (OPNsense, the nodes) are stamped on the logging VM from the CMDB identity map that metrics already use (`logging.nix:102-140`) |
| Module, zone and tier, environment | the CI's `module` attribute (ADR-049 D13), `member-of` its zone (with the tier), and its environment relation |
| Owner | environment `owned-by` organization; the groups that use it (`identity` CIs); the site's notify address for the operator |
| Exposure | `proxy-route` CIs: published or not, gated or not, allowed zones. A failed login burst on a published, ungated route matters more than one inside mgmt |
| Physical | `runs-on` machine, `allocated-to` asset, location: "which box, which rack" for a node-level finding |
| Risk | the module's CVE units and score (ADR-045 D3), with each CVE's state |

How each layer uses it:

- **Layer 1** needs nothing new. The rules match on `tappaas_ci_id`, and `health-manager assess`
  already places an alert by that label (`assess-sources.ts`).
- **Layer 2 (Wazuh).** The agent's *name* is the CI's name and its *labels*
  (`<labels>` in `ossec.conf`) carry `tappaas.ci.id`, module, zone, tier and environment, written
  by the service that installs the agent (§3.4). Wazuh *agent groups* are derived from the CMDB:
  one per module, one per zone tier, one per environment. So a Wazuh alert carries the same
  identity as a log line, and a Wazuh policy can be set per group: a stricter FIM set for tier 0,
  say.
- **No copy of the CMDB inside the SIEM.** It reads labels at the source, and the console
  resolves the rest at display time (ADR-040 D11: the Event component owns events, the
  Configuration component owns CIs and impact).

### 3.2 Findings back into the CMDB: state and alerts

One path, the one that exists:

```
source (Loki rule | CrowdSec decision | Suricata alert | Wazuh alert, all in Loki)
  → ADR-039 rule in <module>-alerts.json with labels kind, type=security, tappaas_ci_id
  → Grafana → tappaas-alert-receiver → health-manager assess --alert
  → classify record (ADR-049) → condition {type: security, owner: siem} on the CI
  → emit: health event, mail per the notify records, Operations view, console #886
```

What has to change:

1. **`assess` takes the condition type from the alert's labels** (`type=security`) instead of a
   hard-coded list of two alert names. Shipped `classify` records then set the severity:
   `core.classify.siem`, plus per-rule records for criticals such as "root login from outside
   mgmt" or "FIM change on a tier-0 host".
2. **A security event is not a state.** A brute force burst ends, a FIM change happened once.
   Today an `event` alert from outside Grafana's state would be visible from the breadcrumb for
   24 hours. For SIEM findings, the condition should stay at its level until **acknowledged or
   aged out** (a `ttl` on the classify record: 24 h for a warning, until ack for a critical).
   This is a small amendment to ADR-041/049 (Q5).
3. **What does not go into the CMDB.** Attacker IPs, single log lines and CrowdSec decisions are
   not CIs. They stay in Loki (and in Wazuh). The CMDB gets the *state* of the CI that was hit,
   and a count per CI (bans per published route) as a metric for ADR-046.
4. **Drift belongs to the sweep.** The closure check (§4.4) reports per guest `runningSystem`
   against `expectedSystem`. A difference is drift on the CI (ADR-040 D6), raised as `security`
   when it is not explained by a `change`. A Wazuh SCA result becomes a `security` warning per
   failed check group, not per check.
5. **Root cause still works.** A compromised node is a `security` critical on the machine, and
   its guests show it as impact through ADR-041's derivation, which is the correlation a SIEM
   cannot do without a CMDB.

### 3.3 CVE/VEX and the SIEM's vulnerability detection

- **The ADR-011/045/047 pipeline stays the single authority for "what is vulnerable".** It has
  one scanner per layer that understands NixOS, decisions as component records, CVE states, the
  risk score and the daily stream (ADR-048).
- **Wazuh's vulnerability detector stays off** for Debian, PVE and OPNsense, where trivy and
  `pkg audit` already cover them. A second opinion with different matching would be a second
  truth to triage. It may be turned on for **Windows** guests, the one layer our scanner lacks,
  with its findings imported as a CVE layer (`windows`) into the same states and score. That is
  an ADR-011 amendment if wanted (Q6).
- **Where the two meet is prioritisation:**
  - **An attack on a known CVE.** CrowdSec's `http-cve` scenarios and Suricata's ET rules name
    the CVE they detect. A hit against a CI is looked up in that module's CVE units:
    - `open` or `risk` there, or on the KEV list: critical, and "exploit attempt against an
      unpatched CVE" is mailed at once;
    - `decided` (not affected): a warning, logged.
    - This is the correlation that makes the CVE work pay off operationally.
  - **The decision feed improves detection.** A `not_affected` record lowers the noise of
    exploit scenarios for that component.
  - **The risk score raises severity.** A login burst on a module whose security level is
    `high` gets one step up.

### 3.4 Lifecycle: the agent and its config follow the module

TAPPaaS already has the mechanism: the **provider service**. `logging:logs` opens the pinhole,
creates the push credential, installs Alloy and applies the module's alert rules for each
consumer, and undoes it all on delete (`logging/services/logs/install-service.sh`,
`_common.sh`). `backup:vm` works the same way. The SIEM uses the same pattern:

| Event | Layer 1 (`logging:security`, a new service of `logging`) | Layer 2 (`wazuh:agent`) |
|---|---|---|
| `module add` of a consumer | `install-service.sh <consumer>`: auditd and the FIM watch set in the guest's generated fragment (`templates/tappaas-common.nix` imports `/etc/nixos/tappaas-*.nix`), the module's security rules applied, its log files added to the CrowdSec acquisition | the agent installed (Debian package, OPNsense plugin, an MSI for Windows), enrolled with its own key, named after the CI, labels and groups from the CMDB |
| `module modify` / update | `update-service.sh`: the watch set and rules re-rendered | groups and labels re-synced |
| `module delete` | `delete-service.sh`: rules removed in the same delete, so no "silent host" alert for a deleted guest (ADR-039 D4) | the agent removed from the manager (API `DELETE /agents`) and its key revoked |
| `node add` (a `pvehost` instance) | the node is a consumer at install: auditd rules exist already, plus the security rules | agent on the node |
| `node delete` | as a module delete; the CMDB retires the CI | as a module delete |
| Provider installed late | consumers pick it up at their next update (`integratesWith`), as with `logging:logs` | same |

Rules for the lifecycle:

- **`integratesWith`, not `dependsOn`.** A module never fails to install because the SIEM is
  absent.
- **Defaults.** The NixOS templates make every guest a `logging:security` consumer by default, as
  with `logging:logs`. `pvehost`, `debianhost`, `network` and `windows-server` declare
  `wazuh:agent` in `integratesWith`.
- **Reconciliation from the CMDB.** A `siem` report in the discovery sweep compares the
  operational node CIs with the monitored hosts (Loki's security streams; Wazuh's agent list).
  - A CI without coverage is a `security` warning: *unmonitored*.
  - An agent without a CI is removed and logged. A machine that is not ours enrolling as an
    agent is itself a finding.
  - This is ADR-040 D15's "actual without desired", applied to the SIEM.
- **Scope comes from `config/`, never from "who logged last hour"**, so a deleted node raises
  nothing (ADR-039 D4).

## 4. What it detects and protects

Key: **D** detects (alert, condition), **R** also responds automatically. Layer 1 is the default.
Layer 2 is the optional Wazuh module. *New* marks a source that does not reach Loki today.

### 4.1 Authentication attacks and brute force

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| SSH brute force on a guest, node or the firewall (N failures per source IP in a window; also many users from one IP) | **R**: CrowdSec bans the IP in pf for traffic that crosses the firewall (WAN and between zones) | sshd in the journal (guests), syslog (nodes, OPNsense) | Layer 1: CrowdSec processor on the logging VM with Loki as data source, `crowdsecurity/sshd`; LAPI on the firewall |
| SSH login that succeeds after a burst of failures from the same IP | D (critical) | same | Layer 1 rule |
| SSH login from outside mgmt or the admin VPN, or as root | D | sshd and the zone of the source address | Layer 1 rule (zones from `zones.json`) |
| Authentik: failed login bursts, `suspicious_request`, password reset storms, MFA removed, a login from a new country | **R** for bursts (CrowdSec scenario on Authentik's events), D for the rest | Authentik events (journal JSON) | Layer 1: rules and a `tappaas/authentik-bf` scenario |
| Authentik admin actions: impersonation, a user added to `admin` or to a `<module>-admins` group, a new provider or outpost, a flow changed | D; also drift in the CMDB when no identity-manager change explains it | Authentik events, plus the CMDB identity CIs | Layer 1 rule plus the sweep |
| Web app logins on published names (Jellyfin and Authentik today; Nextcloud, Immich, Forgejo, Vaultwarden next) | **R** (CrowdSec `http-login-bf`, as today, widened per module) | Caddy access log per name (*new* into Loki), the app's own log | Layer 1: CrowdSec on the firewall, as today; the scenario per module declared in its `logging:security` fields |
| Proxmox UI or API auth failures (`pvedaemon` "authentication failure") | **R** (ban, if the source crosses the firewall), D | syslog from the nodes | Layer 1 |
| OPNsense UI auth failures and config changes (the audit log) | D | OPNsense syslog (`audit`) | Layer 1 |
| PBS UI auth failures | D | PBS journal | Layer 1 |
| Password spraying across apps (one IP, many names, many apps) | **R** | Caddy access logs | CrowdSec `http-bf` over all names, with a site whitelist |

### 4.2 Firewall and IDS events

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| Port scans and probing from the WAN | **R** (CrowdSec on `filterlog`: `crowdsecurity/pf-scan-multi_ports`) | OPNsense `filterlog` | Layer 1 (CrowdSec on the firewall reads it locally) |
| Blocked outbound bursts from a guest (a compromised guest calling out) | D | `filterlog` (outbound blocks per source) | Layer 1 rule |
| Lateral movement: blocked attempts from one zone into mgmt or into another tenant's zone | D (critical into tier 0) | `filterlog` | Layer 1 rule |
| IDS alerts: exploit attempts, malware command-and-control, known-bad TLS fingerprints, policy hits | D. IPS mode (drop) later, per zone (Q8) | Suricata `eve.json` (*new*) → syslog → Loki | Layer 1: Suricata on OPNsense, ET Open rules, IDS mode on the WAN and on the client zones |
| Exploit attempt against a CVE open on the target module (§3.3) | D, critical; **R** through the CrowdSec ban | CrowdSec `http-cve`, Suricata ET with CVE metadata | Layer 1 correlation |
| DNS requests to blocklisted or threat domains | D (repeated hits from one guest) | Unbound blocklist hits | Layer 1 rule |
| CrowdSec decisions themselves (who was banned, why, how often) | D (a summary, and a warning when one site user is banned) | CrowdSec log (*new*) → syslog → Loki | Layer 1 |
| A firewall rule changed outside TAPPaaS | D | the CMDB sweep (`opnsense-controller report --discover`), OPNsense audit log | already in ADR-040 D15. Layer 1 raises it as `security` |

### 4.3 File integrity

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| A NixOS guest runs a system the mothership did not build (`/run/current-system` differs from the expected closure) | D, critical | a guest report over the existing ssh trust | Layer 1 closure check (nightly, and after each update) |
| The Nix store has been tampered with (`nix-store --verify --check-contents` on the running closure) | D, critical | the guest | Layer 1, weekly and staggered (I/O cost) |
| Writes to sensitive mutable paths: `/etc/secrets`, `/root/.ssh`, `/home/*/.ssh/authorized_keys`, `/etc/ssh`, the module's config under `/var/lib/<module>`, `/etc/nixos` | D | auditd watch rules → journal → Loki | Layer 1 auditd on NixOS guests (*new*). The nodes already have it |
| `/etc/pve`, `/etc/network` and SSH keys changed on a node from a login session | D | auditd (exists) | Layer 1 rule over the existing audit log |
| Changed Debian package files (`debsums`) | D | `debianhost`, Debian guests | Layer 1 timer on Debian, or Layer 2 syscheck |
| Full FIM with hashes and who-data on Debian, PVE, Windows and the OPNsense config | D | the Wazuh agent | Layer 2 syscheck |

### 4.4 Privilege escalation

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| `sudo` or `su` by an unexpected user, or failed sudo | D | journal (`sudo`), auditd execve with `auid` | Layer 1 |
| A setuid binary run from outside `/run/wrappers` (NixOS) or `/usr` (Debian) | D | auditd `execve` rule | Layer 1 |
| Kernel module loads (`init_module`, `finit_module`) after boot | D | auditd | Layer 1 |
| Users, groups or `wheel` changed at runtime (NixOS `mutableUsers` off: any change is drift) | D | auditd on `/etc/passwd`, `/etc/group`, `/etc/shadow` | Layer 1 |
| Authentik privilege changes | D | §4.1 | Layer 1 |
| A Proxmox user, role or token created outside TAPPaaS | D | node syslog plus the sweep | Layer 1 |

### 4.5 Malware and rootkits

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| Command-and-control traffic, known malware downloads | D | Suricata ET (§4.2), DNS blocklist hits | Layer 1 |
| Kernel or rootkit tampering on NixOS: closure and store verification, module loads | D | §4.3, §4.4 | Layer 1 |
| Rootkit checks on Debian, PVE and Windows (hidden processes and ports, known rootkit files) | D | Wazuh rootcheck | Layer 2 |
| Malware in user uploads (Nextcloud and others) | D, and the app quarantines | ClamAV in the app module (Nextcloud's antivirus app) | Per module, opt-in: ~1 GiB for signatures, so not by default |
| YARA or VirusTotal on FIM hits | D | Wazuh integrations | Layer 2, opt-in. VirusTotal sends hashes off-site (Q9) |

### 4.6 Config drift and CIS/hardening compliance

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| Firewall rules, VLANs, users, guests and shares outside `config/` | D | the CMDB discovery sweep (exists) | ADR-040 D15. Layer 1 raises the security-relevant differences as `security` |
| A NixOS guest changed outside TAPPaaS | D | the closure check (§4.3) | Layer 1 |
| Hardening baseline on NixOS: sshd password auth off, root login off, firewall on, no password sudo where it should not be | D, at build time | the module's evaluated NixOS config | Layer 1: a `security` check over each guest's evaluated config, run by `module-manager validate` (NixOS hardening is declarative, so it is checked before deploy, not scanned after) |
| CIS benchmark on Debian 12/13, PVE and Windows | D | Wazuh SCA | Layer 2 |
| Lynis audit on Debian hosts (score and warnings) | D | Lynis (GPL, in nixpkgs and Debian) on a timer | Layer 1 alternative where Wazuh is not installed |
| OPNsense hardening (GUI exposure, SSH, the admin VPN rules) | D | the network module's test, as today | already exists |

### 4.7 Vulnerable packages

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| CVEs by layer, with states, score and the decision feed | D. Response is the daily patch stream (ADR-048) | ADR-011 scanners | **unchanged**: the authority |
| An exploit attempt against an open CVE | D critical, **R** ban | §3.3 | Layer 1 correlation |
| Windows guest CVEs | D | the Wazuh vulnerability detector | Layer 2, imported as a CVE layer (Q6) |

### 4.8 Anomalous network flows

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| A guest talking to a destination class it never used (server zone to internet on new ports) | D | `filterlog` pass logs on outbound rules (*new*: logging turned on for zone egress rules) | Layer 1: a LogQL baseline per CI, over the last 7 days against today |
| Beaconing (regular small connections to one address) | D | Suricata flow and TLS events | Layer 1 rule, best effort |
| Volume anomalies per guest | D | ADR-046 NIC metrics | an ADR-046 metric rule (`source: metrics`) |
| Full flow records (NetFlow, Zeek) | – | needs a mirror port | **later** (P6): Zeek on a switch SPAN once the switch model can set one |

### 4.9 Container and VM events

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| A VM or LXC created, destroyed, migrated or given a console without a TAPPaaS change | D | Proxmox task log (syslog `pvedaemon`/`pvestatd`) plus the CMDB `change` rows | Layer 1: correlate the Proxmox task with a CMDB change of the same VMID within minutes, else `security` warning |
| A guest disk attached to another VM, or a snapshot or backup restored outside a job | D | Proxmox task log | Layer 1 |
| Containers on guests: a new container or image not in the module's pins, privileged runs, `docker exec` into a container | D | Docker/Podman events in the journal | Layer 1 rule. **Falco** later, when `services.falco` reaches a stable NixOS release (P6) |
| A container image digest that is not the pinned one | D | the module test and CVE scan (they read the running digest) | already exists, raised as `security` |

### 4.10 Log tampering and loss of visibility

| Detection | D/R | Log source | Collector / layer |
|---|---|---|---|
| A host stops shipping (Alloy stopped, network cut) | D | HostSilent (exists), scoped from `config/` | exists |
| Journal vacuumed or rotated by hand, journald or Alloy config changed, Alloy stopped by a user | D | auditd on `/var/log/journal`, the Alloy unit, journald.conf; systemd unit stop events | Layer 1 |
| auditd stopped or its rules changed | D, critical | the kernel audit "config change" record, plus the absence of the audit heartbeat | Layer 1 |
| Loki write attempts under another host's name | prevented: the server sets `host` from the credential | exists |
| Deleting lines from Loki | prevented for guests (push-only credential). Admin-only on the logging VM, and every use of the delete API is logged | Layer 1 rule on the logging VM's nginx log |
| The logging VM itself down | D | the alert watchdog on the mothership and the backup pulse (exist) | exists |
| Security streams kept longer than the general 30 days | – | Loki per-stream retention: 90 days for `{type="security"}`, auditd and `filterlog` blocks (Q3) | Layer 1 |

## 5. Phased plan

Each phase ends in something that runs on hrossen and is tested there before the next starts.
The order front-loads the cheap and high-value parts: logins and bans first.

| Phase | Content | Done when | Size (ease/risk) |
|---|---|---|---|
| **P0: prerequisites** | (1) The `tappaas_ci_id` label on log lines: Alloy on guests from the deploy-time CI id; syslog stamped on the logging VM from the identity map (ADR-040 step 5). (2) Caddy access logs and CrowdSec's log into Loki over the existing OPNsense syslog path. (3) Loki per-stream retention for security streams. (4) `assess` takes `type` from alert labels; `core.classify.siem`; the security condition's `ttl` (Q5) | A test alert labelled `type=security, tappaas_ci_id=…` becomes a `security` warning on that CI and ages out | M / L |
| **P1: logins and bans** | The `logging:security` service. A CrowdSec log processor on the logging VM with Loki as data source (sshd, Authentik, pvedaemon, PBS), registered with the firewall's LAPI over a mgmt pinhole. Scenarios: sshd, Authentik, the per-module web logins. The first rule pack: §4.1 and the decisions summary | An SSH brute force from a test VM in another zone is banned at the firewall within a minute, the ban shows in Grafana, and the target CI carries a `security` condition that ages out | M / M |
| **P2: host integrity** | auditd on NixOS guests and `debianhost` through the generated fragment; the FIM watch set per module (`logging:security` fields); the privilege, module-load and tamper rules (§4.3, §4.4, §4.10); the closure check and weekly store verification; the build-time hardening check | A hand-edited `authorized_keys`, a `nixos-rebuild` done on a guest by hand, and a stopped auditd each raise their condition on hrossen | M / M |
| **P3: network IDS** | Suricata on OPNsense in IDS mode (ET Open), converged by the network module like CrowdSec; `eve.json` to Loki; the §4.2 rules; logging on zone egress rules and the flow baseline (§4.8); the network VM's sizing measured | An ET test signature (`testmyids`) from a guest raises an alert on that CI; the network VM stays inside its medium memory | M / M |
| **P4: correlation and views** | CVE-aware severity (§3.3); Proxmox tasks correlated with CMDB changes (§4.9); the sweep's `siem` coverage report (*unmonitored*); the console's security view (#886) reading conditions and the Loki summary | A `http-cve` hit on a module with that CVE open mails a critical; a VM created by hand in the PVE UI is flagged; #886 lists open security conditions per node and module | M / L |
| **P5: the `wazuh` module** (optional, after Wazuh 5.0 GA) | A NixOS VM in the `security` stack running Wazuh manager, indexer and dashboard as pinned OCI images; Authentik SAML; the `wazuh:agent` service for `pvehost`, `debianhost`, `network` (`os-wazuh-agent`), Debian guests and `windows-server`; CMDB-derived names, labels and groups; agent removal on delete; SCA, syscheck and rootcheck on; the vulnerability detector off except Windows (Q6); alerts shipped to Loki by the VM's own Alloy and matched by `wazuh-alerts.json` | Every node, the firewall and a Debian guest report SCA results; deleting a test Debian guest removes its agent; a Wazuh level ≥ 10 alert becomes a `security` condition on the right CI | H / M |
| **P6: later** | Falco on container guests when `services.falco` is in a stable NixOS release; Zeek on a SPAN port; host bouncers (nftables) on guests for traffic within a zone; Suricata IPS per zone; CrowdSec community list (#926), already its own issue | each its own issue | – |

### Sizing (ADR-044)

| Module / component | cores (min / med / max) | memory MiB (min / med / max) | disk (min / med / max) | Notes |
|---|---|---|---|---|
| `logging` today | 1 / 2 / 4 | 2048 / 4096 / 8192 | 16G / 32G / 256G | |
| `logging` with layer 1 | 1 / 2 / 4 | **2560** / **4608** / 8192 | **24G** / **48G** / 256G | *est.*: CrowdSec processor ~150–250 MB, more Loki streams and ruler queries, 90-day security retention. Confirm by measuring on hrossen in P1/P2 (ADR-044 D6 says small minimums are first estimates) |
| `network` with Suricata | 2 / 4 / 8 | 2048 / 4096 / 8192 (unchanged) | – | Suricata **off by default at `small`**. At medium, 4 GiB is expected to hold OPNsense, Caddy, CrowdSec (~140 MiB) and Suricata with ET Open (~1–1.5 GB *est.*); measured in P3, raised if not |
| NixOS guests (auditd) | – | +10–20 MiB each *est.* | – | auditd plus rules, negligible |
| `wazuh` (layer 2) | 4 / 4 / 8 | **6144** / 8192 / 16384 | 64G / 100G / 500G | vendor: 4 vCPU, 8 GiB, 50 GB for 1–25 agents at 90 days. Small is a hint, not a block (ADR-044 D1), but the install guide says "not for small sites" and the module is not in any default stack |

**The small budget.** Layer 1 adds about 512 MiB at `small` (logging only). ADR-044 D6 leaves
0.25 GiB of margin on a 32 GB node, and its note says the next module that grows its small memory
has to give it back elsewhere. Candidates: `identity` 2048 → 1792, or `logging`'s Prometheus at
`performance` level `off` by default at small. This is Q2.

Note: the task brief described hrossen as having 4 GB-class nodes. The repository records its
nodes at about 30–32 GB (`docs/plans/mikrotik-mlag-test-plan.md:179`; the ADR-044 32 GB install
at small). The binding limit is ADR-044's small budget, not a single node's size.

### Effort, roughly

P0–P4 (layer 1) is content and wiring on existing components, about the size of #851 plus #165
per phase. P5 (Wazuh) is a new module with images, SSO, an agent service for four platforms and
a 5.0 upgrade path to watch: the largest piece, and optional.

## 6. Open questions for Lars

1. **Two layers instead of Wazuh first.** Do you accept layer 1 (Loki, rules, CrowdSec,
   Suricata, auditd, CMDB) as *the* SIEM, with Wazuh as an optional module? Or should Wazuh be
   the base even though it is blind on NixOS and too heavy for small?
2. **The small budget.** Layer 1 needs about 512 MiB more on `logging` at small. Where does it
   come from (identity down 256 MiB, Prometheus off at small, or accept a thinner margin)?
3. **Retention.** 90 days for security streams (auditd, `filterlog` blocks, security alerts,
   Authentik events), against 30 for the rest? Longer at large?
4. **The service name and shape.** Is `logging:security` a new service of `logging`, or should
   `logging:logs` carry the security part for every consumer with no extra declaration? (The
   first lets a module declare its FIM paths and login scenarios; the second is zero-config.)
5. **How security events age.** A `ttl` on classify records (warning 24 h; critical until
   acknowledged), as an amendment to ADR-041/049?
6. **Windows CVEs.** Turn on Wazuh's vulnerability detector for `windows-server` guests and import
   it as a CVE layer under ADR-011, or leave Windows outside the CVE score?
7. **Response reach.** Bans at the firewall only cover traffic that crosses it. Do you also want
   host bouncers (nftables on guests) for attacks inside a zone, at the cost of an agent per
   guest (P6)?
8. **Suricata mode.** IDS only (alert), or IPS (drop) on the WAN from the start? IPS can break a
   published service on a false positive.
9. **Off-site lookups.** VirusTotal hash lookups in Wazuh and the CrowdSec community list (#926)
   send data off-site. Both off by default, as #926 already proposes?
10. **Wazuh timing.** Wait for 5.0 GA (rc2 on 2026-10-30) before P5, or start on 4.14 and accept a
    rebuild?
11. **Event management (ADR-040 O6).** This plan settles the SIEM part of O6 (events stay in
    Loki and Wazuh; the CMDB holds the CI state). Is incidents and on-call still a separate ADR,
    or out of scope for now?
