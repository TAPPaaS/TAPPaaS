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

The scan and the rescan run in their units' sandbox (ProtectSystem=strict); the
new files they write (`first-seen.json`, `decision-state.json`,
`security-acceptances.json`) are all under `config/`, which both units may write.
Check it in the unit's own context before the first night:

```bash
ssh cicd-hrossen '~/TAPPaaS/src/foundation/tappaas-cicd/scripts/tappaas-unit-run.sh --unit tappaas-security-rescan.service -- health-manager report security --table'
```

## The first night: the scan fix and the source packages

The rescan matches by source package only on an inventory the new scan took.
Run one full scan by hand after the deploy, so the next rescan agrees with it:

```bash
ssh cicd-hrossen 'flock ~/config/.security-scan.lock health-manager scan security'
```

Verify the next morning:

- `jq '[.targets[].findings] | add' ~/config/sbom/cve-status.json` is the same
  after the scan that follows the nightly sweep and the 04:30 rescan
  (scratch proof: 6227 and 6226).
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
| Health | `health-manager list --type security` | messages end with "· N unread" where something is unread; a condition keeps its message until its status changes, so old conditions show the old wording |
| Pin candidates | `cat ~/config/pin-candidates.json` after 05:30 | proposals, or notes saying why none |
| Acceptance | `health-manager accept <unit> <CVE> --note … --until …`, then a rescan | the CVE shows as accepted and the unit's score drops |

## Deployed on hrossen, 2026-11-12

Main at a09ebb09, OS rebuilt, one full scan in the scan unit's context:
6557 findings before the scan fix, 6226 after; the rescan agrees (6226).
The acceptance check found that an accepted row hidden behind another row of
the same CVE (jellyfin's own glibc and the baseline's) ended as "gone" at the
same scan; fixed on the branch after the deploy, so it needs the next deploy.

## The NixOS baseline CI, deployed on hrossen 2026-11-12

Main at d25735c4, OS rebuilt (the CMDB loads the new class at start; the
console builds the new symbol). The first sweep created the one
`nixos-baseline` CI with 15 templates/* components and listed it once as
"appeared" (a drift warning on it until the next sweep, which does not list
it); its `cve-baseline` condition is a security root and in the digest's NEW.

## What is not done

- Units set only by the baseline: the cve source labels their finding
  `labels.setBy = baseline`; ADR-049's `core.classify.cve-baseline` makes them
  derived (never a root) once that branch is deployed. The baseline's own
  finding, reason `cve-baseline`, is on the `nixos-baseline` CI, which
  `health-manager report` creates from the templates/* component records when
  the CMDB sweep runs it; until the first sweep after the deploy it falls back
  to the site, where the site's roll-up hides it. Check after the deploy:
  `cmdb query nixos-baseline` shows one CI, and
  `health-manager list --type security` shows its condition. The console's
  class symbol for it needs the web dist rebuilt.
- Known-exploited CVEs: brotli (CVE-2026-111497) reopens judgements made
  before it was listed; each needs a person to read it again
  (`cve-triage.sh read …`). redis (CVE-2022-0543) is a recorded false
  positive, which a listing does not reopen.
- The U/R/C/V/A column counts the row a CVE is shown by: an acceptance of a
  row hidden behind another row of the same CVE lowers the score but shows
  as 0 accepted; `health-manager accept --list` shows it.
- The release preview applies named component decisions but not CVSS rules
  (the preview has no vectors): an item only a rule lowers still counts at its
  upstream level in the preview's gate. Conservative; noted in ADR-047.
- The decision feed and the patch line are ADR-048's.
