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
- **Its verdict needs a TTY (#714, #715).** The NixOS `nextcloud-occ` wrapper
  execs `systemd-run --pty --wait`. Over a non-interactive ssh the command
  *runs* — writes take effect, and `--check` does rewrite `settings_error` — but
  its stdout is lost and it returns 0. So the verdict, which is read from what
  the check says, needs `ssh -tt`. With a TTY a passing check answers in about
  **1.5 seconds**.
  The nightly euro-office failures once blamed on this were real rather than
  replayed: each night's check ran and wrote a fresh error. On the test site the
  cause was clock skew between the two guests (#716, met by the JWT leeway in
  `nextcloud.nix`); on another site it was an HTTP 400 from an empty
  `trusted_domains` (#715). Both surface as the same message.
- **It has to wait for the document server.** The sweep reaches the check
  straight after euro-office's OS update restarts the container. Measured on
  the test site: after a restart `/healthcheck` answers `true` at **22 s** and
  the round trip succeeds at **23 s**. A check inside that window fails for
  real, writes the error, and the verifier reads it back. So the check is gated
  on the healthcheck, polled from the Nextcloud side (`OO_READY_TIMEOUT`, 120s).
- **The verdict comes from what the check says.** `… is successfully
  connected` is working; `Error connection: …` or `Document server is not
  configured` is broken; anything else is *no verdict*. Not from the exit code
  alone — 1 is the command's way of saying "broken", not "did not run" — and
  not from an unchanged DB row, which proves nothing when the wrapper ran
  nothing. Only *broken* fails the module; *no verdict* is a warning.

To refresh it by hand:

```bash
ssh -t tappaas@<nextcloud>.<zone>.internal sudo nextcloud-occ onlyoffice:documentserver --check
```
