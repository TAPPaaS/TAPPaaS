# ADR-050 — Security Monitoring (SIEM)

| | |
|---|---|
| **Status** | **Proposed**: draft for the operator's review; open questions below |
| **Version** | 0.1 |
| **Date** | 2026-11-12 |
| **Author** | Lars Rossen |
| **Deciders** | @LarsRossen |
| **Closes / addresses** | #843 (a SIEM for TAPPaaS); the basis for #886 (the console's security view). Settles the SIEM part of ADR-040 O6. Would amend ADR-039 (a `type` label on security rules), ADR-041 and ADR-049 (security conditions that age out), and ADR-011 (a Windows layer, if Q6 says so). Analysis: [`docs/plans/siem-analysis.md`](../plans/siem-analysis.md). |
| **Changelog** | v0.1 (2026-11-12): first draft from the analysis. Two layers: detection on the existing logging stack at every size, with Wazuh as an optional module at medium and large. |

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
| **1: security monitoring** | every site, every size; the `logging` and `network` modules and the NixOS templates | security sources into Loki; a security rule pack on the ADR-039 path; CrowdSec as the response; Suricata as the network IDS; auditd and a closure check on guests; findings as `security` conditions on CIs |
| **2: deep host checks** | optional `wazuh` module in the `security` stack, for medium and large sites | Wazuh manager, indexer and dashboard for the machines Wazuh understands: Proxmox nodes, Debian hosts and guests, OPNsense, Windows. CIS checks (SCA), syscheck, rootcheck, and an investigation UI |

Layer 1 is the SIEM. Layer 2 adds depth where Wazuh's checks apply, and reports through layer 1.

### D2. Sources

These reach Loki, each line labelled with its CI (`tappaas_ci_id`):

- the existing ones: journals (sshd, sudo, Authentik's events, the apps), OPNsense syslog
  (`filterlog`, `audit`), the nodes' syslog and auditd;
- new: auditd on NixOS guests and `debianhost`, Caddy's access logs, CrowdSec's log, and
  Suricata's `eve.json`, all over the existing syslog path.

Security streams are kept 90 days by Loki's per-stream retention (Q3), the rest 30.

### D3. Detection content

- A **security rule pack** of Sigma rules converted to LogQL at build time (`sigma-cli` with the
  Loki backend, both in nixpkgs), plus TAPPaaS's own rules.
- It is shipped as ADR-039 rule files: `logging-security-alerts.json` for site-wide rules, and a
  module's own file for its app.
- Each rule carries `type=security`.

### D4. Response through CrowdSec

- A CrowdSec **log processor on the logging VM** reads Loki and registers with the **LAPI on the
  firewall**, the one that already runs. Its decisions go into pf through the existing bouncer.
- Scenarios cover sshd, Authentik, the Proxmox and PBS interfaces, and the web logins each module
  declares.
- No agent runs on the guests. Bans affect traffic that crosses the firewall. Bans inside a zone
  are deferred (Q7).

### D5. Network IDS

Suricata on OPNsense in **IDS mode** with ET Open, converged by the network module as CrowdSec is.
It is off by default at `small`. IPS is a later, per-zone choice (Q8).

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
  (Q5).
- Attacker addresses, log lines and decisions are not CIs and stay in Loki. Wazuh alerts take
  the same path: the `wazuh` VM's own Alloy ships them to Loki, and `wazuh-alerts.json` matches
  them.

### D8. CVEs stay with ADR-011/045/047

- The CVE pipeline remains the one authority on vulnerable packages.
- Wazuh's vulnerability detector is **off**, except for Windows if Q6 says so, as a new CVE layer.
- The SIEM uses the CVE states for severity: an exploit attempt (CrowdSec `http-cve`, Suricata
  ET) against a CVE that is `open` or `risk` on the target module, or on the KEV list, is
  critical.

### D9. The agent follows the module

Coverage uses the provider-service pattern of `logging:logs`. There are two new services:

- **`logging:security`** (layer 1). `install-service` writes the guest's auditd and FIM fragment,
  adds the module's log files and scenarios to CrowdSec's acquisition, and applies its security
  rules. `delete-service` undoes it.
- **`wazuh:agent`** (layer 2). It installs and enrols the agent under the CI's name, with labels
  and agent groups from the CMDB (module, zone tier, environment). On delete it removes the agent
  and revokes its key.

Both are `integratesWith`, so a module never needs the SIEM to install. NixOS guests consume
`logging:security` by default. A `siem` source in the discovery sweep (ADR-040 D15) compares
operational node CIs with what is monitored: a CI without coverage is *unmonitored*, and an agent
without a CI is removed.

### D10. Sign-in and reach

The `wazuh` dashboard signs in through Authentik (SAML, Wazuh's documented integration) and is
reached inside the site only, behind the identity gate. Layer 1 has no UI of its own beyond
Grafana (already on Authentik) and the console.

### D11. Sizing (ADR-044)

| Module | cores | memory MiB | disk |
|---|---|---|---|
| `logging` | 1 / 2 / 4 (unchanged) | **2560 / 4608** / 8192 | **24G / 48G** / 256G |
| `network` | unchanged | unchanged; Suricata off at small, measured at medium in P3 | – |
| `wazuh` | 4 / 4 / 8 | 6144 / 8192 / 16384 | 64G / 100G / 500G |

The values are first estimates, to be confirmed by measurement. The 512 MiB that `logging` adds
at small must be given back elsewhere (Q2).

## Consequences

- **Good.**
  - Every site gets security detection and response at no new store, sign-in or alert pipeline.
  - Findings sit on CIs, so root cause and impact (ADR-041) correlate them with everything else.
  - The CVE work gains an operational use: exploit attempts are rated by it.
- **Cost.**
  - A rule pack to maintain. Sigma upstream carries most of it; the TAPPaaS rules are ours.
  - auditd and a closure check on every guest.
  - Suricata on the firewall.
  - A Wazuh module to package and follow upstream, for those who want it.
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

| Phase | Content | Done when |
|---|---|---|
| P0 | CI id on log lines; Caddy and CrowdSec logs into Loki; security retention; `assess` reads `type`; security conditions age out | a labelled test alert becomes an ageing `security` condition on its CI |
| P1 | `logging:security`; CrowdSec processor on the logging VM with the firewall's LAPI; auth scenarios and rules | an SSH brute force from another zone is banned within a minute and shows on the CI |
| P2 | auditd on guests; FIM paths; privilege, module-load and tamper rules; closure and store checks; hardening check at validate | a hand edit of `authorized_keys`, a hand `nixos-rebuild`, a stopped auditd each raise a condition |
| P3 | Suricata IDS; egress logging and the flow baseline | an ET test signature raises an alert on the right CI |
| P4 | CVE-aware severity; Proxmox tasks against CMDB changes; the sweep's coverage report; #886 | an exploit attempt against an open CVE mails a critical; a VM made by hand is flagged |
| P5 | the `wazuh` module, after Wazuh 5.0 GA | nodes, firewall and a Debian guest report SCA; a deleted guest's agent is removed |

## Open questions

1. Two layers, or Wazuh as the base?
2. Where the 512 MiB for `logging` at small comes from.
3. Retention for security streams: 90 days?
4. `logging:security` as its own service, or folded into `logging:logs`?
5. Ageing of security conditions: a `ttl` on classify records (warning 24 h, critical until ack)?
6. Windows CVEs from Wazuh as an ADR-011 layer?
7. Host bouncers on guests for attacks inside a zone?
8. Suricata IDS only, or IPS on the WAN from the start?
9. Off-site lookups (VirusTotal, the CrowdSec community list) off by default?
10. Wait for Wazuh 5.0 GA, or start on 4.14?
11. Incidents and on-call: a separate event-management ADR, or out of scope?
