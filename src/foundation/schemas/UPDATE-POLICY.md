# Update policy — the module-level fields

**Manifest:** [`fields.json`](fields.json) · **Schema:** [`module-fields.json`](module-fields.json)
· **Vocabulary:** [the seven change classes and five apply modes](../tappaas-cicd/UPDATE-POLICY.md#1-the-seven-change-classes)
· **Index:** [all manifests](../tappaas-cicd/UPDATE-POLICY.md#4-the-per-service-manifests)

19 fields — all `in-place`, `manual` or `immutable`; all `apply: "none"`.

`module-fields.json` declares 74 fields. 55 name a `<module>:<service>` coordinate
in their `usedBy` and are classified by that service's own
`services/<svc>/fields.json`. The **19** here name none — their `usedBy` is empty
or `general` — so they describe the **module itself**: its provenance, its
lifecycle, and its wiring, rather than anything a provider configures.

They are declared the same way every other field is, in [`fields.json`](fields.json)
beside the schema, using the same vocabulary. Two things follow from having no
provider, and the manifest's lint enforces both:

- **every entry is `apply: "none"`** — there is no provider call to batch, no hook
  to dispatch. For these fields, writing the config *is* the change.
- **no entry carries a `liveKey`** — there is no `report-service.sh` for a module,
  because there is nothing to ask. So there is no actual state and no drift.

That makes `in-place` mean something slightly different here than it does for a
service-owned field: *takes effect at once, nothing to refuse*, rather than *the
converge applies it live*. `converge.ts` already calls this situation
`config-only`; see the enforcement gap below.

| Field | Class | Apply | Normalize | Why this class |
|---|---|---|---|---|
| `description` | in-place | none | — | Authored in source module file. Cosmetic. Set on the Proxmox summary page at creation and never pushed again — editing it after install changes the config, not the VM. |
| `version` | in-place | none | — | Authored in source module file. Module semver. Read to decide whether an upgrade exists. |
| `appVersion` | in-place | none | — | Authored in source module file. Upstream app version, informational; no format enforced. |
| `releaseDate` | in-place | none | — | Authored in source module file. Informational. |
| `maintainer` | in-place | none | — | Authored in source module file. Informational. |
| `status` | in-place | none | — | Authored in source module file (+ tooling). `archived` and `external` take the module **out of the update lifecycle** — `update-module.sh` skips it unless `--force`. Set automatically by `delete-module.sh --archive`. |
| `tier` | in-place | none | — | Authored in source module file. `foundation` means mgmt-only, single-instance, and `--force` to delete; it also makes `source: official` a lint requirement. Changing it changes what the platform will let you do to the module. |
| `source` | in-place | none | — | Authored in inferred at deploy; pinned only when the module file must. Trust marker. A `foundation` module from a non-`official` source fails the tier/source lint unless `--allow-fork`. |
| `rebootOk` | in-place | none | — | Authored in source module file. The [D8 disruption authorization](../tappaas-cicd/UPDATE-POLICY.md#reading-the-columns). `false` (the default) means an unattended converge **defers** every `in-place-reboot` and `migrate` change instead of applying it. This is the one unowned field that directly gates the converge. |
| `dependsOn` | manual | none | — | Authored in source module file. The service wiring. See the hazard below. |
| `integratesWith` | manual | none | — | Authored in source module file. Optional wiring; a missing provider is ignored rather than fatal (#501). Same delta mechanism as `dependsOn`. |
| `provides` | manual | none | — | Authored in source module file. What other modules may declare a dependency on. Removing an entry breaks every consumer's resolution. |
| `config` | in-place | none | — | Authored in source module file. Pattern-A nesting (#161). Normalized to the flat form at deploy and at validation, so it is an authoring convenience, not a distinct state. |
| `environment` | immutable | none | — | Authored in tooling — `copy-update-json.sh --environment`. How `update-module.sh` and `delete-module.sh` resolve the source module file. A wrong value points the lifecycle at the wrong module. |
| `location` | immutable | none | — | Authored in tooling — `copy-update-json.sh`. Absolute path to the module directory. `update-module.sh` finds `install.sh`, `update.sh` and the service scripts through it. |
| `kind` | immutable | none | — | Authored in tooling — `install-module.sh`. Stamped `module` so `module-manager list/show` can tell a deployed module from other objects in `config/`. |
| `installTime` | immutable | none | — | Authored in tooling — `copy-update-json.sh`. Reporting only. |
| `updateTime` | immutable | none | — | Authored in tooling — `update-module.sh`. Reporting only. |
| `variant` | immutable | none | — | Authored in —. Superseded by `environment` (#438). Never write it; installs strip it. Retained in the schema only so a pre-migration config carrying it is classified rather than reported unknown. |

### Two things this list does not protect against

**The pre-gate accepts all 19 unconditionally.** A field with no service
coordinate is classified `config-only` and written without consulting any
manifest — which is right for `description` and wrong for the rest. All of these
are accepted today:

```
$ module-manager module modify web --set kind=widget
kind=widget  (config-only)
[Info]   set kind=widget in /home/tappaas/config/web.json
```

`variant`, `installTime`, `location` and `environment` behave the same way. There
is no operation that *needs* to write them by hand, and clobbering `location` or
`environment` breaks the module's own lifecycle scripts.

**`--set dependsOn=…` declares without wiring.** `install-service.sh` and
`delete-service.sh` are driven by a **delta** that `update-module.sh` computes
across the 3-way merge: the union of `dependsOn` + `integratesWith` before the
merge, against the same union after. A `--set` writes the *deployed* side, so the
merge sees an operator customization and pins it — before and after agree, the
delta is empty, and **no service script runs**. The config ends up claiming a
dependency that was never wired, or dropping one whose wiring is still in place.

Dependencies are changed by editing the **source module file** and running
`update-module.sh`, which is what makes the delta visible to the merge.

### The enforcement gap (#567)

**This manifest is declaration only — nothing reads it yet.** `module-manager`'s
pre-gate still waves every one of these fields through as `config-only` without
consulting a class, which is why `--set kind=widget` and `--set location=/tmp`
are accepted on a live module today.

The sibling manager already does the opposite. `network-manager modify` reads
`changeClass` from [`zones-fields.json`](zones-fields.json) — declared on all 17
zone fields — and **refuses** a field that has none:

> `has no declared changeClass in zones-fields.json, so what changing it costs is`
> `unknown — declare one before it can be set through a verb (ADR-020 D6)`

Two managers, one taxonomy, opposite defaults: network-manager treats "I do not
know what this costs" as a reason to stop; module-manager treats "nobody owns it"
as a reason to proceed. Closing that is **issue #567** — teaching `converge.ts`
the same refusal, against this manifest. It is deliberately deferred until
ADR-020 has landed across the estate, because it changes what `modify` accepts.

The machinery is not new: the schema-level `changeClass` path already exists and
is exercised by `network-manager`. #567 points it at a second manifest.
