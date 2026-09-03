# Providing a service — `services/<name>/`

Most modules **consume** services (`"dependsOn": ["cluster:vm", "network:proxy"]`)
and never need this file. Read it only if your module *provides* something other
modules declare — a `<yourmodule>:<service>` coordinate.

A provider service is a directory `services/<service>/` holding the lifecycle
scripts other modules' installs and converges call:

| Script | Called when | Required |
|---|---|---|
| `install-service.sh <consumer>` | a consumer is installed, or gains this dependency | yes |
| `update-service.sh <consumer>` | every converge (`module modify`, `reconcile --apply`) | **yes** — a service that cannot converge is a contract violation `test.sh` catches |
| `delete-service.sh <consumer>` | a consumer is removed, or drops this dependency | yes |
| `test-service.sh <consumer>` | `module test`, and the read-only drift report | yes |
| `fields.json` | — | only if your service **owns declared fields** (below) |
| `report-service.sh <consumer>` | the drift computation | only if some field is applied per-field (below) |

---

## Does your service own any fields?

Look in [`schemas/module-fields.json`](../../foundation/schemas/module-fields.json):
a field whose `usedBy` names your coordinate is yours.

**If it owns none — you are done.** Fourteen of the twenty-five services in
TAPPaaS own no declared field: they do registration, wiring and app
configuration, which is not field drift. No `fields.json`, no
`report-service.sh`, and `module-manager validate` expects neither.

**If it owns fields, you must ship `fields.json`** — `validate` errors otherwise.
It declares, per field, what changing it costs after install (ADR-020 D3/D4).

## `fields.json`

```jsonc
{
  "$schema": "../../../../foundation/schemas/service-fields.json",
  "service": "mymodule:myservice",
  "description": "One line: what this service owns.",

  "fields": {
    "someScalar": {
      "class": "in-place",        // what changing it COSTS — see the table below
      "apply": "set",             // how it is applied
      "liveKey": "some_scalar",   // the key report-service.sh reports it under
      "setFlag": "--some-scalar",
      "normalize": "integer",
      "note": "Why this class. Write the reason, not the restatement."
    },

    "somePolicyList": {
      "class": "in-place",
      "apply": "reconcile",       // ← the common case; see below
      "note": "Reconciled by <your controller>, which adds, changes and removes."
    }
  }
}
```

### Choosing the class

| Class | Use when | Refused |
|---|---|---|
| `in-place` | a safe live change | — |
| `in-place-reboot` | the guest must reboot to pick it up | deferred unless authorized |
| `grow-only` | one-way; a shrink is not reconcilable | at apply time |
| `migrate` | it relocates or rebuilds runtime state | at apply time |
| `manual` | an operator action the tool must not take silently | reported by the converge |
| `recreate` | it only takes effect at creation | **before any write** |
| `immutable` | it cannot change in place at all | **before any write** |

Read the class off **what your script already does**, not off what seems tidy.
If it warns rather than acting, that is `manual`. If it refuses, that is
`immutable` or `recreate`. Getting this wrong is how a converge acquires a
behaviour nobody asked for.

Two extras worth knowing:

- **undeclared fields are still compared.** A module that declares nothing for a
  field gets the `module-fields.json` default as its desired value, gated by
  `usedBy`. That is safe as long as your INSTALL path builds with the same
  default — TAPPaaS's creators read `vmtag`, `diskSize`, `storage` and `bios`
  from exactly those values, so an undeclared guest already matches. If your
  provider can produce a guest that does *not* match the default, record what
  you actually built in the deployed config at install (ADR-020 D9), the way
  `cluster:vm/install-service.sh` records the observed firmware.
- **composites** — when several declared fields become one provider value (a NIC
  built from bridge/zone/mac/trunks). The composite carries the class, the hook
  and the side effects; each input declares `apply: "composite"` and points at it.

### `apply: "reconcile"` — usually the right answer

If your service already reconciles the thing properly — adding, changing **and
removing** entries against the provider's own model — declare `reconcile` and
keep that logic. A firewall rule set, a Caddy handler, a job membership are not
scalars a generic differ can compare; flattening one to a string so it could
would *lose* fidelity.

You still get what ADR-020 is for: the class is declared, so
`module-manager module modify <m> --set yourField=…` becomes a sanctioned,
classified operation instead of a hand-edit, and `validate` can insist you
classify everything you own.

With `reconcile` (or `none`) on every field, **no `report-service.sh` is needed**.

## `report-service.sh` — only for per-field apply

Needed when some field uses `set`, `hook` or `composite`, because the differ must
know the live value.

```bash
#!/usr/bin/env bash
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

# STDOUT IS THE CONTRACT: exactly one JSON object, nothing else.
# info/warn/debug and check_json all write to STDOUT, so hold the real stdout
# on fd 3 and point stdout at stderr. Skipping this is the single most common
# way to break a reporter: one schema warning ahead of the JSON and every
# consumer's parse fails.
exec 3>&1 1>&2

MODULE="${1:?usage: report-service.sh <module>}"
# … read live state …

jq -n --arg someScalar "${live_value}" \
   '{some_scalar: $someScalar}' >&3
```

Rules:

- **every declared `liveKey` is always present**; an absent value is `""`, so a
  consumer can tell "the provider does not have this" from "nobody looked";
- **every value is a string** — the manager normalizes per the manifest;
- **raw values only** — no resolving, no normalizing, no comparing, no writes;
- **decode your own spelling here.** If your provider calls `cputype` `cpu`, this
  is the one place that knows. Report a composite both whole and split
  (`net0`, `net0.bridge`, …) so nothing above you parses your strings;
- **exit codes carry meaning**: `0` reported · `2` usage · `3` not deployed ·
  `4` the provider could not be reached · `5` the thing is absent · `6` found but
  unreadable. Callers say different things about each.

## `update-service.sh` — apply

With a manifest, `update-service.sh` stops computing drift: it asks the manager
for a record and hands it to the shared runner.

```bash
. "${SCRIPT_DIR}/../../../tappaas-cicd/lib/converge-lib.sh"

module-manager module drift "${MODULE}" --service mymodule:myservice --json > "${DRIFT_FILE}"

converge_apply_set() { : ; }            # ONE batched provider call
converge_side_effect_reboot() { : ; }   # …and _wait_ip / _dns as declared

converge_apply "${MODULE}" "${SCRIPT_DIR}" "${DRIFT_FILE}" "${CHECK}" "${ALLOW_DISRUPTION}" "${FORCE}"
```

**Everything that is not field drift stays in your script**, around that call —
setup, registration, side tasks. The refactor extracts the drift loop, not the
script.

---

Full detail, including the hook contract and the disruption model:
[`docs/design/ADR-020-field-change-realization.md`](../../../docs/design/ADR-020-field-change-realization.md).
