# nextcloud:fileservice service

<!-- Describe what this service provides and how a module uses it. This prose is yours; the generated block below is not. -->

<!-- BEGIN GENERATED FIELDS -- edit the manifest, not this block -->

## Fields

`nextcloud:fileservice` owns **1** declared field(s). Each table below carries the field's full definition and, where the service applies it, its ADR-020 change semantics.

### `connector`

The Nextcloud integration this consumer provides. update-service.sh re-applies 'onlyoffice' (the ADR-COM-0002 document-server wiring for euro-office); 'talk' (coturn) and 'hpb' (nextcloud-hpb) name the consumer's role and are not re-applied by this service.

| Attribute | Value |
|---|---|
| Type | `string` |
| Default | *(none)* |
| Format | `^(onlyoffice|talk|hpb)$` |
| Example | `onlyoffice` |
| Required by | *(none)* |
| Used by | `nextcloud:fileservice` |
| Change class | `in-place` |
| Apply mode | `reconcile` |

**Why this change class.** Which connector the consumer is. update-service.sh reconciles the onlyoffice wiring on every run; changing the value changes what that reconcile does, with no guest downtime.

<!-- END GENERATED FIELDS -->

## The OnlyOffice verdict is stored, not probed (#687)

Nextcloud's OnlyOffice app keeps its last self-check in `oc_appconfig`
(`appid='onlyoffice'`, `configkey='settings_error'`), and hides the editor
entirely while that value is set — the user sees no "open in Euro-Office"
action at all, with nothing else failing.

Two consequences worth knowing before reading a red test:

- **`test-service.sh` reads that value, it does not re-probe.** A read-only
  verifier must not mutate, and `onlyoffice:documentserver --check` rewrites
  app config. So a failing test means "the last completed check failed", not
  necessarily "it is broken now".
- **The refresh can take minutes.** `--check` performs the round trip through
  the document server; on the test site it has been measured running **over
  eight minutes** without returning. `update-service.sh` therefore bounds it
  (`OO_CHECK_TIMEOUT`, 120s by default) and says plainly when a run could not
  refresh the verdict — unbounded, a stuck check both stalls the sweep and
  leaves the previous answer in place for ever, which is how four consecutive
  nightlies reported a failure that no run could clear.

To refresh it by hand:

```bash
ssh tappaas@<nextcloud>.<zone>.internal sudo nextcloud-occ onlyoffice:documentserver --check
```
