# ADR-050 — Security Monitoring (SIEM)

| | |
|---|---|
| **Status** | **Accepted** (operator, 2026-11-12; no question open). Layer 1 (P0–P4) is this iteration; the Wazuh module is future work |
| **Version** | 1.1 |
| **Date** | 2026-11-12 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #843 (a SIEM for TAPPaaS); the basis for #886 (the console's security view). Settles the SIEM part of ADR-040 O6. Would amend ADR-039 (a `type` label on security rules), ADR-041 and ADR-049 (security conditions that age out), and ADR-011 (a Windows layer, with the future Wazuh work). Analysis: [`docs/plans/siem-analysis.md`](../plans/siem-analysis.md). |
| **Changelog** | v1.1 (2026-11-12): **as built, first part** (see *Implementation status*): the switch is `site.json` `security.monitoring` beside `performance`, not a field of the logging module; guests' audit records go through journald's audit socket, no auditd daemon; the closure check is a health-manager gate over the systems update-os.sh records. · v1.0 (2026-11-12): **Accepted** by the operator. Implementation starts with P0. · v0.5 (2026-11-12): D12, the ageing of security conditions, approved by the operator as proposed. No question is open. · v0.4 (2026-11-12): Suricata alerts first; IPS later on the WAN only (D5, operator). Only D12 is left for review. · v0.3 (2026-11-12): **operator's answers**: layer 1 is off at `small` (D1, D11); security streams kept 90 days at medium and 180 at large (D2); the security part rides on `logging:logs`, no new service (D9); host bouncers are future work, off-site lookups off by default, event management parked. **D12 proposes how a security condition ages.** Open: Suricata IDS or IPS. · v0.2 (2026-11-12): **operator's decisions**: this iteration builds layer 1 only, and the Wazuh module is future work (D1, Phases); security streams are kept 90 days (D2). The Sigma claim is corrected: Sigma gives about a third of the rules, the platform-specific rules are TAPPaaS's own (D3, Consequences). · v0.1 (2026-11-12): first draft from the analysis. Two layers: detection on the existing logging stack at every size, with Wazuh as an optional module at medium and large. |

TAPPaaS collects every guest's journal, the firewall log and the nodes' audit log in Loki. It
alerts on single lines, bans abusive clients of published names with CrowdSec, and scans for
CVEs. Nothing looks at security events as a whole. This ADR decides what the SIEM is, where it
runs, and how it meets the CMDB.

## Context

- **Collection exists, detection does not.** The logging module ships journals with a credential
  per host, and syslog from OPNsense and the nodes over TLS (#787). ADR-039 turns lines into
  mailed alerts, and ADR-041/049 turn findings into conditions on CMDB objects, a `security` type
  among them. The rule set has no security content, and log lines carry no CI id yet (ADR-040,
  implementation step 5).
- **The estate is mostly NixOS.** Guests are built by the mothership from a pinned nixpkgs.
  Their integrity can be checked against what was built, and their vulnerabilities are scanned by
  ADR-011's per-layer scanners with ADR-045/047's states and score.
- **The small size is tight.** ADR-044 D6 fits foundation, home and office into 26.25 GiB of
  guest memory on a 32 GB node, with 0.25 GiB to spare.
- **The candidates** (compared in the analysis, §2):
  - **Wazuh**: GPL/AGPL, free SAML with Authentik, an OPNsense agent. 8 GiB all-in-one and not in
    nixpkgs. Its vulnerability detector and CIS checks do not cover NixOS. 5.0 needs a fresh
    install and drops frequency rules for now.
  - **Ruled out by licence or paid SSO**: Security Onion (ELv2, OIDC in Pro, 24 GB), Graylog Open
    (SSPL, no SSO), Elastic Basic (ELv2 binaries, no SSO).
  - **OpenSearch Security Analytics**: open, but a second log store with no host side.
  - **CrowdSec** (MIT, in nixpkgs, already on the firewall) and **Suricata** (in OPNsense) fill
    response and network IDS.

## Decision

### D1. Two layers

| Layer | Where | What |
|---|---|---|
| **1: security monitoring** | medium and large sites, **off at `small`**; the `logging` and `network` modules and the NixOS templates | security sources into Loki; a security rule pack on the ADR-039 path; CrowdSec as the response; Suricata as the network IDS; auditd and a closure check on guests; findings as `security` conditions on CIs |
| **2: deep host checks** (future work) | optional `wazuh` module in the `security` stack, for medium and large sites | Wazuh manager, indexer and dashboard for the machines Wazuh understands: Proxmox nodes, Debian hosts and guests, OPNsense, Windows. CIS checks (SCA), syscheck, rootcheck, and an investigation UI |

Layer 1 is the SIEM. Layer 2 adds depth where Wazuh's checks apply, and reports through layer 1.

**At `small`, layer 1 is off** (operator, 2026-11-12). A small site keeps what it has today:
CrowdSec on published names (#851), the nodes' auditd, the existing alerts. `site.json`
`security.monitoring: on | off` decides; not set, it is off at small and on at medium and large
(the site's size, ADR-044 D3), as `performance.level` is. An operator may set `on` at small and
take the memory.

**This iteration builds layer 1 only** (operator, 2026-11-12). Layer 2 is future work. What
this ADR says about Wazuh (D7–D11) is the design to start from when it is taken up, not part of
this iteration's scope.

### D2. Sources

These reach Loki, each line labelled with its CI (`tappaas_ci_id`):

- the existing ones: journals (sshd, sudo, Authentik's events, the apps), OPNsense syslog
  (`filterlog`, `audit`), the nodes' syslog and auditd;
- new: auditd on NixOS guests and `debianhost`, Caddy's access logs, CrowdSec's log, and
  Suricata's `eve.json`, all over the existing syslog path.

Security streams are kept by Loki's per-stream retention for **90 days at medium and 180 days at
large** (operator, 2026-11-12), or `site.json` `security.retentionDays`. Everything else keeps
30.

### D3. Detection content

- A **security rule pack**, shipped as ADR-039 rule files: `logging-security-alerts.json` for
  site-wide rules, and a module's own file for its app. Each rule carries `type=security`.
- **About a third comes from Sigma.** These are the generic Linux rules (auditd, sshd, sudo:
  privilege escalation, persistence, log clearing) and the web-attack rules for Caddy's logs. They
  are converted to LogQL at build time (`sigma-cli` with the Loki backend, both in nixpkgs),
  through a field mapping from Sigma's names to auditd's, the journal's and Caddy's. The converted
  rules are committed.
- **The rest are TAPPaaS's own.** Sigma has nothing for Authentik, Proxmox, PBS, OPNsense's
  `filterlog` and audit log, Suricata, CrowdSec, the closure check, or anything that needs the
  CMDB. Most of Sigma (Windows, cloud) does not apply.

### D4. Response through CrowdSec

- A CrowdSec **log processor on the logging VM** reads Loki and registers with the **LAPI on the
  firewall**, the one that already runs. Its decisions go into pf through the existing bouncer.
- Scenarios cover sshd, Authentik, the Proxmox and PBS interfaces, and the web logins each module
  declares.
- No agent runs on the guests. Bans affect traffic that crosses the firewall. Bans inside a zone
  are future work (settled).

### D5. Network IDS

Suricata on OPNsense in **IDS mode** with ET Open, converged by the network module as CrowdSec is.
It is off by default at `small`. **It alerts first** (operator, 2026-11-12). After 2–4 weeks
of alerts, IPS (drop) may be turned on for the WAN only, with only the categories that rarely
misfire (known-bad networks, command-and-control, compromised hosts). Internal zones stay
alert-only. That step is its own issue, with a rollback switch and a netmap test on the firewall
VM.

### D6. Integrity of NixOS guests is checked against the build

- **Closure check.** The mothership compares each guest's running system with the closure it
  built for that guest (nightly and after each update). A difference that no `change` explains is
  drift and a `security` critical.
- **Store check.** `nix-store --verify --check-contents` runs on the running closure weekly.
- **Watched paths.** auditd watches the mutable paths that matter: secrets, SSH keys, the
  module's state.
- **Hardening.** It is checked on the evaluated configuration by `module-manager validate`, not
  scanned after deploy.

### D7. One path for findings, into the CMDB

```
rule or source (in Loki) → ADR-039 rule (type=security, tappaas_ci_id) → Grafana
  → tappaas-alert-receiver → health-manager assess → classify (ADR-049)
  → condition {type: security, owner: siem} on the CI → emit, mail, Operations, #886
```

- `assess` takes the condition type from the alert's labels.
- A security condition **ages out or waits for an acknowledgement** as its classify record says
  (D12).
- Attacker addresses, log lines and decisions are not CIs and stay in Loki. Wazuh alerts take
  the same path: the `wazuh` VM's own Alloy ships them to Loki, and `wazuh-alerts.json` matches
  them.

### D8. CVEs stay with ADR-011/045/047

- The CVE pipeline remains the one authority on vulnerable packages.
- Wazuh's vulnerability detector is **off**, except perhaps for Windows as a new CVE layer, decided with the Wazuh work.
- The SIEM uses the CVE states for severity: an exploit attempt (CrowdSec `http-cve`, Suricata
  ET) against a CVE that is `open` or `risk` on the target module, or on the KEV list, is
  critical.

### D9. The agent follows the module

Coverage uses the provider-service pattern that `logging:logs` already follows.

- **Layer 1 rides on `logging:logs`** (operator, 2026-11-12). No new service: every module that
  ships logs is covered. When security monitoring is on, `logging:logs`'s `install-service`
  also writes the guest's audit and FIM fragment, adds the module's log files and scenarios to
  CrowdSec's acquisition, and applies its security rules. `delete-service` undoes it. A module
  adds to it through optional fields beside `dropUnits`: `securityPaths` (extra FIM watches) and
  `loginScenarios` (its web login).
- **`wazuh:agent`** (layer 2, future). It installs and enrols the agent under the CI's name, with
  labels and agent groups from the CMDB (module, zone tier, environment). On delete it removes
  the agent and revokes its key. It is `integratesWith`, so a module never needs Wazuh to
  install.

A `siem` source in the discovery sweep (ADR-040 D15) compares
operational node CIs with what is monitored: a CI without coverage is *unmonitored*, and an agent
without a CI is removed.

### D10. Sign-in and reach

The `wazuh` dashboard signs in through Authentik (SAML, Wazuh's documented integration) and is
reached inside the site only, behind the identity gate. Layer 1 has no UI of its own beyond
Grafana (already on Authentik) and the console.

### D11. Sizing (ADR-044)

| Module | cores | memory MiB | disk |
|---|---|---|---|
| `logging` | 1 / 2 / 4 (unchanged) | 2048 (unchanged, off at small) / **4608** / 8192 | 16G / **48G** / 256G |
| `network` | unchanged | unchanged; Suricata off at small, measured at medium in P3 | – |
| `wazuh` | 4 / 4 / 8 | 6144 / 8192 / 16384 | 64G / 100G / 500G |

The values are first estimates, to be confirmed by measurement. The small budget of ADR-044 D6 is
untouched, because layer 1 is off at small.

### D12. How a security condition ages

A security finding is an event; the condition it raises is a **hold** on the CI.

- **One finding per CI and rule**, with `count`, first and last hit. Repeats update it and do not
  mail again. The CI's `security` condition is its worst held finding (ADR-049 D2).
- **A hold per severity**, set by a new classify outcome `hold`:
  - info is `quiet`: no condition;
  - a warning is held `24h` from the last hit, mailed on the first, and ages out without a mail
    (the digest lists it);
  - a critical is held `until-ack`, mailed at once. `health-manager ack <ci> --reason` ends it;
    the reason is required and recorded as a CMDB `change`.
  - Shipped criticals: a login after a failure burst, a root login from outside mgmt, a closure
    mismatch, a failed store check, auditd stopped, FIM on tier 0, and an exploit against an open
    CVE.
- **An ack covers the finding, not the future.** A new hit opens a new finding. To silence a rule
  for good, a site writes a `quiet` classify record.
- **Maintenance windows do not hide security criticals.** The exception is a finding a record
  names as expected in a window, such as a closure mismatch on the guest being updated.
- **A retired CI closes its findings** without a mail.
- **The receiver keeps the times.** It stores first and last event and count per CI and rule,
  and `assess` reads that, not Grafana's alert state.

D12 amends ADR-041 D1 and D4 and ADR-049 D5.

## Consequences

- **Good.**
  - Medium and large sites get security detection and response at no new store, sign-in or alert
    pipeline; small sites pay nothing.
  - Findings sit on CIs, so root cause and impact (ADR-041) correlate them with everything else.
  - The CVE work gains an operational use: exploit attempts are rated by it.
- **Cost.**
  - A rule pack to write and maintain. Sigma gives about a third (generic Linux and web
    rules); the platform-specific two thirds are ours, written and tested phase by phase.
  - auditd and a closure check on every guest.
  - Suricata on the firewall.
  - Later, a Wazuh module to package and follow upstream, for those who want it.
- **Risk.**
  - LogQL's correlation is weaker than a SIEM engine's. Mitigated by doing correlation over the
    CMDB, not in queries.
  - The Sigma-to-LogQL backend has a single maintainer. The converted rules are committed, so a
    stalled backend stops new conversions, not detection.
  - False-positive bans of site users. CrowdSec's site whitelist and a warning when a known user
    is banned.

## Alternatives considered

- **Wazuh as the base** (#843's starting assumption). It is blind on NixOS for vulnerabilities
  and CIS, 8 GiB does not fit small, it is not in nixpkgs, and a 4-to-5 rebuild is near. Kept as
  layer 2.
- **OpenSearch with Security Analytics.** It is the strongest open detection engine, but a
  second store beside Loki, with no host side.
- **Security Onion, Graylog Open, Elastic Basic.** Licence or paid SSO.
- **CrowdSec alone.** It responds well but has no search, retention or host integrity.

## Phases

This iteration is P0–P4.

| Phase | Content | Done when |
|---|---|---|
| P0 | CI id on log lines; Caddy and CrowdSec logs into Loki; security retention; `assess` reads `type`; the hold and ack of D12; `security.monitoring` by size | a labelled test alert becomes an ageing `security` condition on its CI |
| P1 | the security part of `logging:logs`; CrowdSec processor on the logging VM with the firewall's LAPI; auth scenarios and rules | an SSH brute force from another zone is banned within a minute and shows on the CI |
| P2 | auditd on guests; FIM paths; privilege, module-load and tamper rules; closure and store checks; hardening check at validate | a hand edit of `authorized_keys`, a hand `nixos-rebuild`, a stopped auditd each raise a condition |
| P3 | Suricata IDS; egress logging and the flow baseline | an ET test signature raises an alert on the right CI |
| P4 | CVE-aware severity; Proxmox tasks against CMDB changes; the sweep's coverage report; #886 | an exploit attempt against an open CVE mails a critical; a VM made by hand is flagged |
| Future | the `wazuh` module, after Wazuh 5.0 GA; not this iteration | nodes, firewall and a Debian guest report SCA; a deleted guest's agent is removed |

## Implementation status

Merged to `main` 2026-11-12 (`00745bfe`), live-tested on hrossen the same day.

**Live test, hrossen, 2026-11-12** (deployed from the branch under a pull hold):

- tappaas-cicd and logging updated, their module tests pass; the 11 security rules are in
  Grafana with their levels; Loki reloaded its runtime config (the security streams at 90 days).
- lazysite updated: audit rules loaded, journald `Audit=true`, its system recorded. A write in
  `/etc/secrets` and a kernel module loaded from a session reached Loki as `transport="audit"`
  records; the module load raised KernelModuleFromSession (warning).
- Seven failed SSH logins as an unknown user, then a key login, from the mothership: sshd's own
  `PerSourcePenalties` dropped the later attempts, and SshLoginAfterBruteForce raised a
  **critical** security condition on lazysite, owner `siem`, not in maintenance. An ack with a
  note closed it at the next assess; the 24 h warning stayed.
- The guest-system gate passed for lazysite, failed critical when its record was swapped for a
  foreign system, and passed again when it was restored.
- Real logs changed four things (`23091a53`, `736e3f86`): health-manager's gates probed the
  firewall as `tappaas` every 5 minutes (four "Invalid user" lines each run, which made a false
  critical on `network`); the mothership's internet-facing sshd sees 75–150 failed logins a day
  per scanning address, so SSH brute force is `info` (recorded, not mailed, no condition);
  pvedaemon's message starts with a space; each boot's `audit_enabled=0` initialisation line is
  no switch-off.
- Found: an ack is per condition type (ADR-041), so an ack given on a security hit also silences
  a CVE warning on the same object until the status changes. D12's "an ack covers the finding"
  needs acks per finding.

| Part | State |
|---|---|
| D12 hold and ack | **Built.** `siem.ts` (a source, owner `siem`); classify outcome `hold`; core records `core.classify.siem-warning` (24 h) and `siem-critical` (until-ack); a siem critical is never put in maintenance; a security alert is not also an operational one |
| Hits recorded | **Built.** The alert receiver folds every `type=security` alert into `/var/lib/tappaas/siem-findings.json`: per rule, host and CI id, first, last and count; pruned at 7, 30 and 90 days by level |
| Rule format | **Built.** `security: info \| warning \| critical` on an ADR-039 rule adds `type` and `level` labels; security rules are rendered only while monitoring is on |
| Switch and retention (D1, D2) | **Built.** `site.json` `security` (`monitoring`, `retentionDays`); Loki's runtime config (`/etc/tappaas-loki/runtime.yaml`) keeps the security streams, written by logging's update |
| Rule pack (D3) | **First part built**, hand-written: SSH brute force (info), login after a brute force (critical), password login, sudo refused, audit stopped, kernel module from a session (logging, scope all); Authentik login brute force, suspicious request, impersonation (identity); Proxmox sign-in failures (pvehost); firewall sign-in failures (network). The Sigma conversion is not done |
| Guests' audit records (D6) | **Built.** NixOS guests: journald's audit socket, rules on `/etc/secrets`, `/root/.ssh`, `/etc/ssh` and kernel modules from a session, plus a module's `securityPaths` that exist; labelled `transport="audit"` |
| Closure check (D6) | **Built** as the `guest-system` gate (critical): update-os.sh records each system it activates or stages in `config/.guest-systems/<vmname>` (the last 20); a profile or running system not in it fails. The weekly store verification is not built |
| CrowdSec processor (D4), Suricata (D5), Caddy and CrowdSec logs into Loki (P0) | **Not built**: they change OPNsense's plugins and the logging VM's NixOS, and need a live firewall to be written against |
| CI id on log lines (P0) | **Not built.** Placement by the authenticated `host` label works without it |
| CVE-aware severity, coverage report, #886 (P4) | **Not built**: they wait for the sources above |
| `debianhost` audit, the hardening check at validate | **Not built** |

## Settled in review

Settled 2026-11-12 (operator):

- Two layers, with layer 1 built in this iteration and the Wazuh module as future work.
- Layer 1 is off at `small`.
- Security streams are kept 90 days at medium and 180 days at large.
- The security part rides on `logging:logs`; no new service.
- Host bouncers on guests for attacks inside a zone are future work.
- Off-site lookups (the CrowdSec community list, later VirusTotal) are off by default.
- Event management (incidents, on-call; ADR-040 O6) is parked.
- Windows CVEs through Wazuh, and whether to wait for Wazuh 5.0, are decided with the Wazuh work.
- Suricata alerts first; IPS later, on the WAN only.
- D12, the ageing of security conditions, as proposed.

## Open questions

None.
