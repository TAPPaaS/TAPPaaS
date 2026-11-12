# ADR-047: deploy and verify

Branch `feat/adr047-cve-decisions` (worktree `~/src/TAPPaaS-adr047`), on top of
`design/cve-vex` and current `main`. Nothing is pushed or deployed.

## Before the push

1. Merge `feat/adr047-cve-decisions` into `main` (it contains `design/cve-vex`).
2. The console's web dist is not rebuilt in the branch. Build it on hrossen's nix
   and commit it as `build(console): web dist with the security queues`
   (the console-gui procedure). The lock file did not change.
3. Push.

## Deploy on hrossen

The scan, the rescan and the new timer are NixOS units, so the OS has to be
rebuilt, not only the checkout refreshed:

```bash
ssh cicd-hrossen '~/bin/refresh-control-plane.sh; module-manager update tappaas-cicd'
```

Then:

```bash
ssh cicd-hrossen 'systemctl list-timers tappaas-pin-candidates.timer; systemctl cat tappaas-pin-candidates.service | grep Condition'
```

## The first night: the scan fix and the source packages

The rescan matches by source package only on an inventory the new scan took.
Run one full scan by hand after the deploy, so the next rescan agrees with it:

```bash
ssh cicd-hrossen 'flock ~/config/.security-scan.lock health-manager scan security'
```

Verify the next morning:

- `jq '[.targets[].findings] | add' ~/config/sbom/cve-status.json` is the same
  after the 02:00 scan and the 04:30 rescan (scratch proof: 6213 both).
- `journalctl -t tappaas-security --since yesterday` has no `cve-new` with
  hundreds of items (the first-seen ledger, `config/sbom/first-seen.json`).

## Migrating the VEX

The records committed on the branch were migrated in the scratch proof from
hrossen's inventory of 2026-11-12. Check them before the first boundary:

```bash
cve-triage.sh export          # regenerates every <module>-vex.json for the versions hrossen runs now
health-manager report security --cves | less
```

The export on hrossen will pin the generated statements to today's package
versions; commit what it changes. The scan does not read the generated files,
so this is for people and tools that want CycloneDX VEX.

Every migrated record is marked `migrated` and lists "needs its use statement"
in the maintainers' Review queue. Its decisions work as they are until its
review date (180 days for code reasons, a year for deployment reasons).

## Daily checks after the deploy

| Check | Where | Expected |
|---|---|---|
| Queues | `health-manager report security` | opens with FOR YOU / WAITING / FOR THE MAINTAINERS |
| Console | Security page | the cards above the table; a module's CVEs show their mark |
| Health | `health-manager list --type security` | messages end with "· N unread" where something is unread |
| Pin candidates | `cat ~/config/pin-candidates.json` after 05:30 | proposals, or notes saying why none |
| Acceptance | `health-manager accept <unit> <CVE> --note … --until …`, then a rescan | the CVE shows as accepted and the unit's score drops |

## What is not done

- Units set only by the baseline: the cve source labels their finding
  `labels.setBy = baseline` and adds one site finding, reason `cve-baseline`.
  Making the labelled ones derived (never a root) is ADR-049's
  `core.classify.cve-baseline`, agreed with the ADR-049 session; until that
  lands they are roots as today.
- Known-exploited CVEs: on hrossen today brotli (CVE-2026-111497) and redis
  (CVE-2022-0543) reopen judgements made before they were listed. Each needs a
  person to read it again (`cve-triage.sh read …`) or a new decision.
- The release preview applies named component decisions but not CVSS rules
  (the preview has no vectors): an item only a rule lowers still counts at its
  upstream level in the preview's gate. Conservative; noted in ADR-047.
- The decision feed and the patch line are ADR-048's.
