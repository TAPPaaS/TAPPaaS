# Enhancement issue draft: `mgmt.access-to: ["internet","all"]` sentinel

Ready to file. `gh` is not authenticated in the cicd environment, so file it with:

```bash
gh issue create --repo TAPPaaS/TAPPaaS \
  --title 'enhancement: declarative "all" sentinel for mgmt.access-to (self-maintaining zone invariant)' \
  --label enhancement --label Foundation \
  --body-file docs/design/issue-mgmt-all-sentinel.md
```

(Strip this header block first, or keep it — GitHub renders it harmlessly.)

---

## Summary

Replace the hand-maintained, explicit `mgmt.access-to` zone list with a single
`"all"` sentinel that the rule/access tooling expands to "every defined managed
zone" at apply time. This makes the `zones.json._README.isolation_invariant`
`mgmt_exception` **self-maintaining**: adding or removing a zone never requires
editing `mgmt.access-to`, so it can never drift (the root of #372 / #373).

```jsonc
// before — must be edited on every zone add/delete
"mgmt": { "access-to": ["internet","srv","srvHome","srvWork","srvCust","srvDev",
                        "srvTest","home","work","guest","iot","iotLocal",
                        "iotCloud","iotCams","iotUntrust","dmz"] }
// after — expands to the same set, automatically
"mgmt": { "access-to": ["internet","all"] }
```

## Motivation

- #372 / #373: zone CRUD currently must remember to append/remove the new zone in
  `mgmt.access-to`. The new `zone-controller` (see `docs/design/zone-controller.md`)
  does this explicitly, but the explicit list is still drift-prone if any path
  bypasses the controller. The sentinel removes the failure mode entirely.
- Auditability: `mgmt: ["internet","all"]` reads more clearly than a 16-element
  list a reviewer must diff against the live zone set.

## Design

- Introduce a shared expansion helper: when `access-to` contains `all` (case-
  insensitive), expand to every real zone entry (`state`/`vlantag` present),
  minus `self`, `internet`, and the `_README`. Applied in **both** consumers:
  `zone_manager.configure_firewall_rules` and `rules_manager` (pinhole
  suppression), so they see the same set.
- Replace the dead `has_all`→"pass to any" branch with this expansion (no zone
  uses `all` today, so the old semantics is unused).
- **Invariant guard:** permit `all` **only in `mgmt`** — it pulls in the Tier-4
  zones (`iotCams`/`iotUntrust`) that `_README` says only mgmt may list. Any
  other zone using `all` → hard validation error (strengthens the invariant in
  code, not just review).
- Update `zones.json._README.mgmt_exception` to document the sentinel.
- `zone-controller` add:step-2 / delete:step-1 (explicit append/remove) become
  no-ops once adopted — forward-compatible.

## Caveats / scope

- Orphaned `Zone mgmt -> <gone>` rules on *full* zone deletion are a pre-existing
  reconcile gap (the disabled-zone cleanup only deletes by the removed zone's own
  prefix). Out of scope here; consider a follow-up to prune any `Zone X -> Y`
  whose `Y` is no longer a defined zone.
- `mgmt` is currently a `Manual` zone, so it generates no firewall rules today
  regardless; the sentinel is primarily about invariant correctness and
  future-proofing (if mgmt rules ever become generated).

## References

- `docs/design/zone-controller.md`
- `src/foundation/firewall/zones.json` `_README.isolation_invariant`
- #372, #373, #335
