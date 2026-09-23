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
- **It needs a TTY, or it does not run at all (#714).** The NixOS
  `nextcloud-occ` wrapper execs `systemd-run --pty --wait`. Over a
  non-interactive ssh the command prints nothing *and does nothing*, returning
  0 — so `settings_error` is never refreshed and the last stored answer stands
  for ever. That is what made several consecutive nightlies fail on a string no
  run could clear, while the connector was healthy throughout. The earlier
  reading of this — "measured running over eight minutes without returning" —
  was the pty waiting, not the check working. `update-service.sh` uses
  `ssh -tt`; with a TTY the check answers in about **1.5 seconds**.
  `OO_CHECK_TIMEOUT` (120s) remains as a safety net, not as the normal path.
- **Three outcomes, not two.** Working, broken, and *nobody could tell*. The
  third is reported as a warning and leaves the module's status alone: a check
  that did not run is not evidence of a fault. The stored row is cleared before
  the check, so what is read back is that run's own answer.

To refresh it by hand:

```bash
ssh tappaas@<nextcloud>.<zone>.internal sudo nextcloud-occ onlyoffice:documentserver --check
```
