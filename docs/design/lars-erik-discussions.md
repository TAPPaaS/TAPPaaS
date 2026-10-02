# Lars ↔ Erik — open discussions

**Compiled:** 2026-10-02 from the [security & stability plan](security-and-stability-plan.md).
Two lists: questions that need both of us before work can move, and items that are Erik's to
finish. Tick a line (✅) when it is settled, and record the outcome in the plan row it points at.

## Discussion

1. **#421 — `src/apps` into stacks.** What a *solution* is (2026-08-03), so the *Stacks &
   solutions* ADR can be written. #500 (moving a module) is built, so this decision is the only
   thing blocking it. It changes the module path in every deployed config, which is cheapest
   while installations are few. Plan: G1.3.
2. **#430 + #675 — how modules extend the platform.**
   - #430: a controller/manager pattern for app modules, Ansible first? The answer also
     decides #170 (LiteLLM declarative state) and #731 (controller-architecture modules never
     register themselves).
   - #675: what a repository the site already tracks may contribute to the mothership's own
     NixOS configuration, and what happens when that contribution fails to build. ADR first,
     code after.

   Plan: G1.3 (#430), §12 (#675).
3. **#444 + #582 — static DHCP reservations.** What a reservation means when read back from
   dnsmasq. One question; both issues wait on it. Plan: G4.3.
4. **#754 — backup copies inside the VM.** Agree the rule: does PBS (`backup:vm`) cover a module
   by default, with an in-guest dump kept only where something reads it (openwebui's
   `restore.sh`) or where it buys a consistent copy (vaultwarden's SQLite)? Decides six modules
   at once — coturn, euro-office, litellm, openwebui, identity, vaultwarden. Plan: G3.3.
5. **#407 — ADR-012 sign-off on Erik's estate.** A PBS on a machine outside the cluster
   (ADR-012 §1.3) is Erik's real setup but has only been live-tested on `dh-test1`. Will he
   validate it on his site, or let us? With it, a heads-up: **#755** — before the fix,
   `cicd-key.sh rotate` locked the mothership out of adopted machines and the satellite. Fixed
   2026-10-02; a site should take that release before it rotates. Plan: G1.2.
6. **#294 — zone-aligned VMID ranges.** Adopt for new installs and variants only, or drop it.
   Existing VMs are never renumbered in place. Plan: G1.3.

## Open items assigned to Erik

- **ADR-007a and ADR-006 — People → Identity wording (#628).** The implementation is done
  (5d15c7f9: `identity-manager`, migration 0005, glossary; on `staging`, not yet `stable`). Left
  is the ADR text Erik offered to write: ADR-007a is still titled *People* and names
  `people-manager` (4×) and `config/people` (6×); ADR-006 the same (5×, 4×). In that edit, confirm
  `config/identities/` as the directory (`config/identity.json` already belongs to the Authentik
  module). The old-name aliases are removed by us one stable cycle after the rename reaches
  `stable`.
- **#571 — hassanova release baseline.** His branch `fix/hassanova-release-baseline`
  (`ed8a9799`) is unmerged. Landing it reconciles a Production module (VM 200) against a baseline
  for the first time. Land it, and when?
- **#552 — hass: a lost long-lived access token blocks every update.** Assigned to him; still
  on his list?
- **#758 — vllm-amd: the models are in no backup.** The models live in a host bind mount, which
  vzdump skips; a restored container comes back without them, and the host GPU prep must rerun on
  a new node. Which option (re-download, back up the dataset, or document as cache)?
- **#658 — nextcloud test 12.** Agree the approach: skip with a reason when the test runs from
  outside the route's `proxyAllowedZones`, the way `tappaas-cicd` Test 9z does — not "treat 403
  as pass".
- **#488 — apply-json-merge pins a field the operator never changed.** Lars proposed on
  2026-08-20 to fix the one affected site by hand rather than change the merge rule (only an
  installation that predates `.orig` can hit it). Erik reported it from such a site (forgejo's
  `dependsOn` still carries `firewall:`). Confirm that is the only one, hand-fix it, then close
  #488.
